"""resource-watchdog: メモリが逼迫したら、mem-triage が「聞かずに消してよい」と判定したもの（safe_kill）だけを止める。

launchd agent com.playpark.resource-watchdog（home-manager/programs/resource-watchdog.nix）が 120 秒ごとに起動する。

  1. config（~/.config/resource-watchdog/config）を読む。enabled=false ならここで終わる
  2. ~/.claude/plugins/installed_plugins.json の playpark-skills の installPath から mem-triage を解決して実行する
  3. summary.free_percent が閾値以上なら何もしない
  4. 閾値未満なら safe_kill[] の pid にだけ SIGTERM を送る（SIGKILL は送らない）。送る直前に、その pid の今の
     ppid・tty・コマンドラインが mem-triage の出力と同じか（pid が再利用されていないか）を確かめる
  5. kill したら測り直す。まだ閾値未満なら（kill するものが無かったときは最初の計測のまま）、safe_kill 以外の units[] の上位 3 件を通知する（kill はしない）。
     通知は 30 分に 1 回まで（最後に通知した時刻を状態ファイルに残す）

orphan かどうかの判定はここに持たない（mem-triage の safe_kill に従うだけ）。

sandbox の外で動くので、sandbox の中から書ける場所のプログラムや設定は実行も source もしない。config は
key=value として読むだけ。mem-triage の出力（unit の name・args）は sandbox の中のプロセスが決められる文字列なので、
通知には argv のデータとしてだけ渡し、AppleScript やシェルの式には埋め込まない。

解決できない・読めない・測れないときは、kill も通知もせず、理由を stderr に書いて終了 0 で終わる
（launchd に失敗として扱わせない。次の起動でまた試す）。

設定（key=value。# 以降はコメント）:
  enabled=false               次の起動から何もしない
  free_percent_threshold=20   memory_pressure の空き % がこれ未満なら逼迫とみなす

installed_plugins.json・config・状態ファイルの場所は HOME から決まる（テストは HOME を一時ディレクトリにする）。
環境変数 RESOURCE_WATCHDOG_KILL / _PS / _OSASCRIPT / _RECHECK_DELAY はテストがコマンドと待ち時間を差し替えるための
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
    config = {"enabled": True, "threshold": DEFAULT_THRESHOLD}
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


def notify(body, osascript, state_file, now):
    argv = [osascript]
    for line in NOTIFY_SCRIPT:
        argv += ["-e", line]
    argv += [NOTIFY_TITLE, body]
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


def run():
    home = os.path.expanduser("~")
    config = load_config(os.path.join(home, ".config", "resource-watchdog", "config"))
    if not config["enabled"]:
        return
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
    notify(body, env_command("OSASCRIPT", "/usr/bin/osascript"), state_file, now)


def main():
    try:
        run()
    except Skip as e:
        log(f"何もしない: {e}", sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
