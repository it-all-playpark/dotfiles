"""pg-broker のクライアント。sandbox 内の Bash から使い捨ての Postgres を頼む。

  pg-broker create [--version 17]  -> stdout に {"id","database_url","socket_dir","expires_at"}
  pg-broker delete <id>            -> stdout に {"id","deleted":true}

なぜ要るか:
  claude-code/settings.json の permissions.deny に `Bash(curl *)` がある（外への持ち出し対策）。
  deny は allow より強いので、broker.sock 宛ての curl だけを許すことはできない。依頼口を
  宛先が broker.sock に固定されたこのコマンドに絞り、curl の deny はそのまま残す。
  コマンドの実体は nix store に置く（pg-broker.nix）ので sandbox から書き換えられない。

失敗したとき（broker に繋がらない / 2xx 以外）は stderr に理由を出して 1 で終わる。
"""

import argparse
import http.client
import json
import os
import re
import socket
import sys

DEFAULT_SOCKET = "~/.local/state/pg-broker/broker.sock"
# broker は initdb / bootstrap / pg_ctl start をそれぞれ 60 秒で打ち切る。その合計より長く待つ
TIMEOUT_SECONDS = 240
INSTANCE_ID = re.compile(r"[0-9a-f]{12}")


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, timeout):
        super().__init__("pg-broker", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.socket_path)
        except OSError:
            sock.close()
            raise
        self.sock = sock


def call(socket_path, method, path, body=None, timeout=TIMEOUT_SECONDS):
    """broker に 1 回だけ依頼し、(status, 本文の dict) を返す。"""
    conn = UnixHTTPConnection(socket_path, timeout)
    try:
        headers = {"Content-Type": "application/json"} if body is not None else {}
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        payload = response.read()
    finally:
        conn.close()
    try:
        data = json.loads(payload)
    except ValueError:
        data = {"error": payload.decode(errors="replace")}
    return response.status, data


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="pg-broker", description="使い捨ての Postgres を pg-broker に頼む"
    )
    parser.add_argument(
        "--socket",
        default=os.environ.get("PG_BROKER_SOCKET", DEFAULT_SOCKET),
        help=f"broker の依頼口（既定 {DEFAULT_SOCKET}）",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create", help="instance を作って接続先を出す")
    create.add_argument("--version", default=None, help="Postgres の major（既定 17）")
    delete = sub.add_parser("delete", help="instance を止めて消す")
    delete.add_argument("id")
    return parser.parse_args(argv)


def main(argv=None, stdout=sys.stdout, stderr=sys.stderr):
    args = parse_args(argv)
    socket_path = os.path.expanduser(args.socket)
    if args.command == "create":
        body = {} if args.version is None else {"version": args.version}
        request = ("POST", "/instances", json.dumps(body).encode())
    else:
        if not INSTANCE_ID.fullmatch(args.id):
            stderr.write(f"pg-broker: invalid instance id {args.id!r}\n")
            return 1
        request = ("DELETE", f"/instances/{args.id}", None)
    try:
        status, data = call(socket_path, *request)
    except OSError as exc:
        stderr.write(
            f"pg-broker: cannot reach {socket_path}: {exc}"
            "（LaunchAgent com.playpark.pg-broker が動いているか確認する）\n"
        )
        return 1
    if not 200 <= status < 300:
        message = data.get("error") if isinstance(data, dict) else None
        stderr.write(f"{message or f'pg-broker: HTTP {status}'} (HTTP {status})\n")
        return 1
    stdout.write(json.dumps(data) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
