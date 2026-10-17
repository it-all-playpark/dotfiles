"""pg-broker: sandbox 内の Bash から、使い捨ての Postgres を sandbox-docker VM のコンテナで起動する。

  pg-broker create [--version 17]  -> stdout に {"id","database_url","expires_at"}
  pg-broker delete <id>            -> stdout に {"id","deleted":true}

なぜこの形か:
  sandbox 内の Bash では Postgres を起動できない（initdb の shmget が EPERM）。sandbox-docker VM
  （sandbox-docker.nix の docker-vm）ならコンテナで起動でき、superuser でも実行されるのは VM の中だけになる。
  以前は sandbox の外の LaunchAgent が cluster を起動していた（issue #243）が、常駐プロセスと
  Unix ソケットの許可が要らなくなった（issue #338）。
  コマンドの実体は nix store に置く（pg-broker.nix）ので sandbox から書き換えられない。

不変条件:
  - 起動する image は IMAGES の表にある version の、digest まで固定したものだけ。
    image・設定値・SQL は引数で受け付けない
  - コンテナには LABEL を付け、delete は LABEL 付きのコンテナしか触らない
  - 同時に MAX_INSTANCES まで。各コンテナはコンテナ内の timeout が TTL_SECONDS 後に postgres を止め、
    --rm で消える（create / delete が呼ばれなくても残らない）
  - host 側の port は PORT_RANGE から選ぶ（sandbox-docker の port forward は 1024〜9999。lima.yaml 参照）

失敗したときは stderr に理由を出して 1 で終わる。
"""

import argparse
import json
import re
import secrets
import socket
import subprocess
import sys
import time

DOCKER = "docker-vm"
# version → digest まで固定した image（multi-arch の index digest）
IMAGES = {
    "17": "postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24",
}
DEFAULT_VERSION = "17"
LABEL = "pg-broker"
MAX_INSTANCES = 4
TTL_SECONDS = 90 * 60
# timeout が postgres に送る signal（SIGINT は fast shutdown。SIGTERM は接続が切れるまで待つ）と、
# それでも残っていたときに SIGKILL を送るまでの秒数
STOP_SIGNAL = "INT"
KILL_AFTER_SECONDS = 30
PORT_RANGE = range(5500, 5600)
ROLE = "app"
DATABASE = "app"
# 初期化中の一時サーバーはソケットでしか待ち受けないので、-h 127.0.0.1 で本番のサーバーを待つ
PG_ISREADY = ("pg_isready", "-q", "-h", "127.0.0.1", "-U", ROLE, "-d", DATABASE)
# docker run は image が無ければ pull する（初回は約 20 秒）
DOCKER_TIMEOUT_SECONDS = 300
READY_TIMEOUT_SECONDS = 60
POLL_SECONDS = 0.2
INSTANCE_ID = re.compile(r"[0-9a-f]{12,64}")
CONTAINER_ID = re.compile(r"[0-9a-f]{64}")
HOST_PORT = re.compile(r":(\d+)->")


class PgBrokerError(Exception):
    pass


def docker(*args, check=True, timeout=DOCKER_TIMEOUT_SECONDS):
    try:
        result = subprocess.run(
            [DOCKER, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PgBrokerError(f"{DOCKER} {args[0]}: {exc}") from exc
    if check and result.returncode != 0:
        raise PgBrokerError(
            f"{DOCKER} {args[0]} failed (exit {result.returncode}): {result.stderr.strip()}"
        )
    return result


def labeled_ids():
    """LABEL 付きのコンテナ（停止中を含む）の full id。"""
    out = docker(
        "ps", "-a", "--no-trunc", "--filter", f"label={LABEL}", "--format", "{{.ID}}"
    ).stdout
    return out.split()


def used_ports():
    """VM のコンテナ（LABEL の有無を問わない）が host 側に publish している port。"""
    out = docker("ps", "-a", "--format", "{{.Ports}}").stdout
    return {int(port) for port in HOST_PORT.findall(out)}


def port_free(port):
    """host の 127.0.0.1:port を bind できるか（Lima の forward やほかのプロセスが使っていないか）。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def host_port_open(port):
    """Lima が host の 127.0.0.1:port に forward を張ったか。"""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def pick_port():
    used = used_ports()
    for port in PORT_RANGE:
        if port not in used and port_free(port):
            return port
    raise PgBrokerError(
        f"no free port in {PORT_RANGE.start}-{PORT_RANGE.stop - 1} on 127.0.0.1"
    )


def wait_ready(container_id, port):
    """コンテナの postgres が TCP で接続を受け、host 側の forward が張られるまで待つ。"""
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while True:
        ready = docker("exec", container_id, *PG_ISREADY, check=False).returncode == 0
        if ready and host_port_open(port):
            return
        if time.monotonic() >= deadline:
            raise PgBrokerError(
                f"postgres in {container_id[:12]} was not ready on 127.0.0.1:{port}"
                f" within {READY_TIMEOUT_SECONDS}s"
            )
        time.sleep(POLL_SECONDS)


def iso_utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def create(version):
    image = IMAGES.get(version)
    if image is None:
        raise PgBrokerError(
            f"unsupported version {version!r} (supported: {', '.join(sorted(IMAGES))})"
        )
    running = labeled_ids()
    if len(running) >= MAX_INSTANCES:
        raise PgBrokerError(
            f"{len(running)} instances already exist (max {MAX_INSTANCES});"
            " pg-broker delete <id> で使い終わったものを消す"
        )
    port = pick_port()
    password = secrets.token_hex(16)
    started = time.time()
    out = docker(
        "run",
        "-d",
        "--rm",
        "--label",
        LABEL,
        "-p",
        f"{port}:5432",
        "-e",
        f"POSTGRES_USER={ROLE}",
        "-e",
        f"POSTGRES_PASSWORD={password}",
        "-e",
        f"POSTGRES_DB={DATABASE}",
        # TTL を過ぎたら postgres を止める。PID 1 の postgres が終わると --rm でコンテナごと消える
        "--entrypoint",
        "timeout",
        image,
        "-s",
        STOP_SIGNAL,
        "-k",
        str(KILL_AFTER_SECONDS),
        str(TTL_SECONDS),
        "docker-entrypoint.sh",
        "postgres",
    ).stdout.strip()
    if not CONTAINER_ID.fullmatch(out):
        raise PgBrokerError(f"{DOCKER} run returned an unexpected id {out!r}")
    try:
        wait_ready(out, port)
    except PgBrokerError:
        docker("rm", "-f", out, check=False)
        raise
    return {
        "id": out[:12],
        "database_url": f"postgresql://{ROLE}:{password}@127.0.0.1:{port}/{DATABASE}",
        "expires_at": iso_utc(started + TTL_SECONDS),
    }


def delete(instance_id):
    if not INSTANCE_ID.fullmatch(instance_id):
        raise PgBrokerError(f"invalid instance id {instance_id!r}")
    matches = [full for full in labeled_ids() if full.startswith(instance_id)]
    if len(matches) != 1:
        raise PgBrokerError(f"no pg-broker instance {instance_id!r}")
    docker("rm", "-f", matches[0])
    return {"id": instance_id, "deleted": True}


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="pg-broker",
        description="使い捨ての Postgres を sandbox-docker VM のコンテナで起動する",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    create_parser = sub.add_parser("create", help="instance を作って接続先を出す")
    create_parser.add_argument(
        "--version",
        default=DEFAULT_VERSION,
        help=f"Postgres の major（既定 {DEFAULT_VERSION}）",
    )
    delete_parser = sub.add_parser("delete", help="instance を止めて消す")
    delete_parser.add_argument("id")
    return parser.parse_args(argv)


def main(argv=None, stdout=sys.stdout, stderr=sys.stderr):
    args = parse_args(argv)
    try:
        if args.command == "create":
            result = create(args.version)
        else:
            result = delete(args.id)
    except PgBrokerError as exc:
        stderr.write(f"pg-broker: {exc}\n")
        return 1
    stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
