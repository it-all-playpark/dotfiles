"""resource-watchdog: メモリが逼迫したら、mem-triage が「聞かずに消してよい」と判定したもの（safe_kill）だけを止める。
ディスクが逼迫したら、docker-vm（sandbox-docker VM）の dangling image と build cache だけを prune する。

launchd agent com.playpark.resource-watchdog（home-manager/programs/resource-watchdog.nix）が 120 秒ごとに起動する。
config（~/.config/resource-watchdog/config）を読み、enabled=false ならそこで終わる。そうでなければメモリの段、
ディスクの段の順に走らせる。片方が何もせずに終わっても（解決できない・測れない・prune が失敗した）、もう片方は走る。

メモリの段:

  1. ~/.claude/plugins/installed_plugins.json の playpark-skills の installPath から mem-triage を解決して実行する
  2. summary.free_percent が閾値以上なら何もしない
  3. 閾値未満なら safe_kill[] の pid にだけ SIGTERM を送る（SIGKILL は送らない）。送る直前に、その pid の今の
     ppid・tty・コマンドラインが mem-triage の出力と同じか（pid が再利用されていないか）を確かめる
  4. kill したら測り直す。まだ閾値未満なら（kill するものが無かったときは最初の計測のまま）、safe_kill 以外の units[] の上位 3 件を通知する（kill はしない）。
     通知は 30 分に 1 回まで（最後に通知した時刻を状態ファイルに残す）

orphan かどうかの判定はここに持たない（mem-triage の safe_kill に従うだけ）。

ディスクの段:

  1. df で Data ボリューム（/System/Volumes/Data）の空きを測る。閾値以上なら何もしない
  2. 閾値未満なら `docker image prune --force` と `docker builder prune --force` を sandbox-docker VM の docker socket
     （~/.lima/sandbox-docker/sock/docker.sock）に向けて実行する。消えるのは dangling image と build cache だけで、
     タグ付きのイメージ・volume・コンテナは消さない（-a / --volumes / system prune は使わない）。
     逼迫している間は起動のたびに prune する
  3. 測り直して、掃除の前後の空きを通知する。prune が失敗しても（VM が止まっている等）理由を stderr に書いて通知する。
     通知は 30 分に 1 回まで。最後に通知した時刻はメモリの段の状態ファイル（last-notified）とは別の
     disk-last-notified に残す

sandbox の外で動くので、sandbox の中から書ける場所のプログラムや設定は実行も source もしない。config は
key=value として読むだけ。mem-triage の出力（unit の name・args）は sandbox の中のプロセスが決められる文字列なので、
通知には argv のデータとしてだけ渡し、AppleScript やシェルの式には埋め込まない。
docker は docker-vm の wrapper を使わず（wrapper の BUILDX_CONFIG は sandbox の中からも書ける /private/tmp/claude の下）、
RESOURCE_WATCHDOG_DOCKER の docker CLI（nix store）を、DOCKER_CONFIG と BUILDX_CONFIG を sandbox から書けない
~/.local/state/resource-watchdog/ の下に向けて呼ぶ。PATH の docker は探さない。

解決できない・読めない・測れないときは、その段では kill も prune も通知もせず、理由を stderr に書いて終了 0 で終わる
（launchd に失敗として扱わせない。次の起動でまた試す）。

設定（key=value。# 以降はコメント）:
  enabled=false               次の起動から何もしない（メモリの段もディスクの段も）
  free_percent_threshold=20   memory_pressure の空き % がこれ未満なら逼迫とみなす
  disk_free_min_gb=50         Data ボリュームの空き（GiB）がこれ未満なら逼迫とみなす

installed_plugins.json・config・状態ファイルの場所は HOME から決まる（テストは HOME を一時ディレクトリにする）。
環境変数 RESOURCE_WATCHDOG_DOCKER は launchd agent が nix store の docker CLI を渡す（無ければ prune しない）。
RESOURCE_WATCHDOG_KILL / _PS / _OSASCRIPT / _DF / _RECHECK_DELAY はテストがコマンドと待ち時間を差し替えるための
もの。launchd agent では設定しない。
"""

import json
import os
import subprocess
import sys
import time

DEFAULT_THRESHOLD = 20
NOTIFY_INTERVAL_SEC = 30 * 60
NOTIFY_CANDIDATES = 3
PLUGIN = "playpark-skills@playpark"
# safe_kill の pid の ppid・tty は units[].root にしか無い。units[] は --top で切られるので全件出させる
TRIAGE_TOP = "100000"
TRIAGE_TIMEOUT_SEC = 60
# mem-triage が args を切り詰める長さ（117 文字 + "..."）
SHORT_LEN = 120
NOTIFY_TITLE = "resource-watchdog: メモリ逼迫"
DEFAULT_DISK_FREE_MIN_GB = 50
DISK_VOLUME = "/System/Volumes/Data"
DISK_NOTIFY_TITLE = "resource-watchdog: ディスク逼迫"
DF_TIMEOUT_SEC = 30
DOCKER_TIMEOUT_SEC = 300
# dangling image と build cache だけ。-a / --volumes / system prune は足さない（タグ付きのイメージ・volume・コンテナは消さない）
DOCKER_PRUNES = [
    ["image", "prune", "--force"],
    ["builder", "prune", "--force"],
]
# 文字列はすべて argv で受け取る。この 3 行にデータを埋め込まない
NOTIFY_SCRIPT = [
    "on run argv",
    "display notification (item 2 of argv) with title (item 1 of argv)",
    "end run",
]


class Skip(Exception):
    """何もせずに終わる理由。"""


def log(message, stream=sys.stdout):
    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S')} resource-watchdog: {message}",
        file=stream,
        flush=True,
    )


def env_command(name, default):
    return os.environ.get(f"RESOURCE_WATCHDOG_{name}") or default


def load_config(path):
    config = {
        "enabled": True,
        "threshold": DEFAULT_THRESHOLD,
        "disk_free_min_gb": DEFAULT_DISK_FREE_MIN_GB,
    }
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return config
    for line in lines:
        key, sep, value = line.split("#", 1)[0].partition("=")
        key, value = key.strip(), value.strip()
        if not sep:
            continue
        if key == "enabled":
            config["enabled"] = value != "false"
        elif key == "free_percent_threshold":
            if value.isdigit():
                config["threshold"] = int(value)
            else:
                log(
                    f"config の free_percent_threshold が整数でない（既定値 {DEFAULT_THRESHOLD} を使う）: {value!r}",
                    sys.stderr,
                )
        elif key == "disk_free_min_gb":
            if value.isdigit():
                config["disk_free_min_gb"] = int(value)
            else:
                log(
                    f"config の disk_free_min_gb が整数でない（既定値 {DEFAULT_DISK_FREE_MIN_GB} を使う）: {value!r}",
                    sys.stderr,
                )
    return config


def resolve_mem_triage(plugins_json):
    try:
        with open(plugins_json, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise Skip(f"{plugins_json} を読めない: {e}") from e
    try:
        install_path = data["plugins"][PLUGIN][0]["installPath"]
    except (KeyError, IndexError, TypeError):
        install_path = None
    if not isinstance(install_path, str) or not install_path:
        raise Skip(f"{plugins_json} に {PLUGIN} の installPath が無い")
    # 実行するのは installed_plugins.json と同じ plugins ディレクトリの下にあるものだけ
    # （installPath が sandbox から書ける checkout を指していたら、そこのスクリプトを sandbox の外で走らせることになる）
    plugins_dir = os.path.realpath(os.path.dirname(plugins_json))
    script = os.path.realpath(os.path.join(install_path, "bin", "mem-triage"))
    if os.path.commonpath([plugins_dir, script]) != plugins_dir:
        raise Skip(f"installPath が {plugins_dir} の外を指している: {install_path}")
    if not os.path.isfile(script):
        raise Skip(f"mem-triage が無い: {script}")
    return script


def measure(mem_triage):
    try:
        result = subprocess.run(
            [mem_triage, "--top", TRIAGE_TOP],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=TRIAGE_TIMEOUT_SEC,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Skip(f"mem-triage を実行できない: {e}") from e
    if result.returncode != 0:
        raise Skip(
            f"mem-triage が終了 {result.returncode}: {result.stderr.strip()[-300:]}"
        )
    try:
        report = json.loads(result.stdout)
        free = report["summary"]["free_percent"]
    except (ValueError, KeyError, TypeError) as e:
        raise Skip(f"mem-triage の出力を読めない: {e}") from e
    if isinstance(free, bool) or not isinstance(free, (int, float)):
        raise Skip(f"mem-triage の free_percent が数値でない: {free!r}")
    return report, free


def as_list(value):
    return value if isinstance(value, list) else []


def is_pid(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 1


def same_args(expected, actual):
    if len(expected) == SHORT_LEN and expected.endswith("..."):
        return actual.startswith(expected[: SHORT_LEN - 3])
    return expected == actual


def still_same_process(pid, root, ps):
    """pid の今の ppid・tty・コマンドラインが mem-triage の出力（units[].root）と同じか。"""
    try:
        result = subprocess.run(
            [ps, "-o", "ppid=,tty=,args=", "-p", str(pid)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return False
    fields = result.stdout.strip().split(None, 2)
    if result.returncode != 0 or len(fields) != 3:
        return False
    ppid, tty, args = fields
    expected_args = root.get("args")
    return (
        ppid == str(root.get("ppid"))
        and tty == root.get("tty")
        and isinstance(expected_args, str)
        and same_args(expected_args.strip(), args.strip())
    )


def kill_safe(report, kill, ps):
    roots = {}
    for unit in as_list(report.get("units")):
        if (
            isinstance(unit, dict)
            and unit.get("safe_kill") is True
            and isinstance(unit.get("root"), dict)
        ):
            roots[unit["root"].get("pid")] = unit["root"]
    killed = 0
    for entry in as_list(report.get("safe_kill")):
        pid = entry.get("pid") if isinstance(entry, dict) else None
        if not is_pid(pid):
            log(f"safe_kill の pid が不正なので送らない: {pid!r}", sys.stderr)
            continue
        label = f"pid={pid} name={json.dumps(entry.get('name'), ensure_ascii=False)} mem={json.dumps(entry.get('mem'))}"
        root = roots.get(pid)
        if root is None:
            log(f"units[] に対応する塊が無いので送らない: {label}", sys.stderr)
            continue
        if not still_same_process(pid, root, ps):
            log(
                f"ppid・tty・コマンドラインが mem-triage の出力と一致しないので送らない: {label}",
                sys.stderr,
            )
            continue
        try:
            code = subprocess.run(
                [kill, "-TERM", str(pid)], stdin=subprocess.DEVNULL, check=False
            ).returncode
        except OSError as e:
            log(f"kill を実行できない: {label}: {e}", sys.stderr)
            continue
        if code == 0:
            killed += 1
            log(f"SIGTERM を送った: {label}")
        else:
            log(f"kill が終了 {code}: {label}", sys.stderr)
    return killed


def candidates(report):
    units = [
        u
        for u in as_list(report.get("units"))
        if isinstance(u, dict) and u.get("safe_kill") is not True
    ]
    return [f"{u.get('name')} ({u.get('mem')})" for u in units[:NOTIFY_CANDIDATES]]


def notified_recently(state_file, now):
    try:
        with open(state_file, encoding="utf-8") as f:
            last = int(f.read().strip())
    except (OSError, ValueError):
        return False
    return 0 <= now - last < NOTIFY_INTERVAL_SEC


def notify(title, body, osascript, state_file, now):
    argv = [osascript]
    for line in NOTIFY_SCRIPT:
        argv += ["-e", line]
    argv += [title, body]
    try:
        code = subprocess.run(argv, stdin=subprocess.DEVNULL, check=False).returncode
    except OSError as e:
        log(f"通知を出せない: {e}", sys.stderr)
        return
    if code != 0:
        log(f"osascript が終了 {code}", sys.stderr)
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    with open(state_file, "w", encoding="utf-8") as f:
        f.write(f"{now}\n")
    if code == 0:
        log(f"通知した: {json.dumps(body, ensure_ascii=False)}")


def disk_free_gb(df):
    """Data ボリュームの空き（GiB）。"""
    try:
        result = subprocess.run(
            [df, "-Pk", DISK_VOLUME],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=DF_TIMEOUT_SEC,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Skip(f"df を実行できない: {e}") from e
    if result.returncode != 0:
        raise Skip(f"df が終了 {result.returncode}: {result.stderr.strip()[-300:]}")
    # 2 行目が Filesystem / 1024-blocks / Used / Available / …
    lines = result.stdout.strip().splitlines()
    fields = lines[-1].split() if len(lines) >= 2 else []
    if len(fields) < 4 or not fields[3].isdigit():
        raise Skip(f"df の出力を読めない: {result.stdout.strip()[-300:]!r}")
    return int(fields[3]) / (1024 * 1024)


def prune_docker(docker, home):
    """dangling image と build cache を prune する。失敗した理由のリストを返す（空なら全部成功）。"""
    if not docker:
        return ["RESOURCE_WATCHDOG_DOCKER が無い"]
    state_dir = os.path.join(home, ".local", "state", "resource-watchdog")
    # docker CLI が読む設定・plugin と buildx の状態を、sandbox から書けない watchdog 専用の場所にする。
    # 環境は引き継がない（DOCKER_HOST / DOCKER_CONTEXT 等で接続先や設定を差し替えさせない）
    env = {
        "HOME": home,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "DOCKER_CONFIG": os.path.join(state_dir, "docker-config"),
        "BUILDX_CONFIG": os.path.join(state_dir, "buildx"),
    }
    try:
        os.makedirs(env["DOCKER_CONFIG"], exist_ok=True)
        os.makedirs(env["BUILDX_CONFIG"], exist_ok=True)
    except OSError as e:
        return [f"{state_dir} の下にディレクトリを作れない: {e}"]
    host = "unix://" + os.path.join(
        home, ".lima", "sandbox-docker", "sock", "docker.sock"
    )
    failures = []
    for prune in DOCKER_PRUNES:
        label = "docker " + " ".join(prune)
        try:
            result = subprocess.run(
                [docker, "--host", host, *prune],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                timeout=DOCKER_TIMEOUT_SEC,
                env=env,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            failures.append(f"{label} を実行できない: {e}")
            continue
        if result.returncode != 0:
            failures.append(
                f"{label} が終了 {result.returncode}: {result.stderr.strip()[-300:]}"
            )
            continue
        # 最後の行が "Total reclaimed space: …" / "Total: …"
        last = result.stdout.strip().splitlines()[-1:]
        log(f"{label}: {json.dumps(last[0] if last else '', ensure_ascii=False)}")
    return failures


def disk_stage(config, home):
    df = env_command("DF", "/bin/df")
    threshold = config["disk_free_min_gb"]
    before = disk_free_gb(df)
    if before >= threshold:
        return
    log(f"ディスクの空き {before:.1f}GB が閾値 {threshold}GB 未満")
    failures = prune_docker(os.environ.get("RESOURCE_WATCHDOG_DOCKER"), home)
    for failure in failures:
        log(f"prune できない: {failure}", sys.stderr)
    after = disk_free_gb(df)
    state_file = os.path.join(
        home, ".local", "state", "resource-watchdog", "disk-last-notified"
    )
    now = int(time.time())
    if notified_recently(state_file, now):
        return
    body = (
        f"docker-vm の prune 前 {before:.1f}GB → 後 {after:.1f}GB（閾値 {threshold}GB）"
    )
    if failures:
        body += "。prune に失敗（resource-watchdog.err.log）"
    notify(
        DISK_NOTIFY_TITLE,
        body,
        env_command("OSASCRIPT", "/usr/bin/osascript"),
        state_file,
        now,
    )


def memory_stage(config, home):
    threshold = config["threshold"]
    mem_triage = resolve_mem_triage(
        os.path.join(home, ".claude", "plugins", "installed_plugins.json")
    )
    report, free = measure(mem_triage)
    if free >= threshold:
        return
    log(f"空き {free}% が閾値 {threshold}% 未満")
    if (
        kill_safe(
            report, env_command("KILL", "/bin/kill"), env_command("PS", "/bin/ps")
        )
        > 0
    ):
        # SIGTERM を受けたプロセスが終わってメモリが返るのを待ってから測り直す
        time.sleep(float(os.environ.get("RESOURCE_WATCHDOG_RECHECK_DELAY") or 5))
        report, free = measure(mem_triage)
        if free >= threshold:
            log(f"空き {free}% に回復した")
            return
    state_file = os.path.join(
        home, ".local", "state", "resource-watchdog", "last-notified"
    )
    now = int(time.time())
    if notified_recently(state_file, now):
        return
    body = f"空き {free}%（閾値 {threshold}%）。候補: " + " / ".join(candidates(report))
    notify(
        NOTIFY_TITLE,
        body,
        env_command("OSASCRIPT", "/usr/bin/osascript"),
        state_file,
        now,
    )


def main():
    home = os.path.expanduser("~")
    config = load_config(os.path.join(home, ".config", "resource-watchdog", "config"))
    if not config["enabled"]:
        return 0
    # メモリの段が先（prune は時間がかかりうる）。片方が何もせずに終わっても、もう片方は走らせる
    for name, stage in (("メモリ", memory_stage), ("ディスク", disk_stage)):
        try:
            stage(config, home)
        except Skip as e:
            log(f"{name}の段は何もしない: {e}", sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
