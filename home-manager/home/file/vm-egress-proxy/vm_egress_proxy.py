"""vm-egress-proxy: VM sandbox-docker の外向き通信を、許可リストのホストにだけ中継する HTTP プロキシ。

なぜ要るか:
  sandbox 本体は allowedDomains（strictAllowlist）で通信先を絞るが、sandbox から docker-vm で使う VM は
  インターネットに素通しだった（build context や docker cp で任意のファイルを VM に渡せるので迂回路になる）。
  パッチ版 Lima（lib/lima-sandbox）の forwarder は VM からの接続を、このプロセスへの 1 経路
  （VM から見て 192.168.5.2:3128）を除いてすべて拒否する。VM の dockerd・apt・コンテナはこのプロキシを使う
  （home-manager/home/file/sandbox-docker/lima.yaml）。

経路:
  VM → 192.168.5.2:3128 → パッチ版 Lima の forwarder → このプロセスの Unix ソケット → 許可リストのホスト

不変条件:
  - 中継するのは CONNECT host:port と、絶対 URI（http://host/...）の HTTP リクエストだけ。host が
    許可リストに一致しなければ 403 を返し、拒否したホスト名を stderr（launchd の StandardErrorPath）に残す。
    拒否したものは上流に接続しない
  - 許可リストとの一致は sandbox の allowedDomains と同じ: `*.example.com` は example.com のサブドメイン
    （何段でも）に一致し、example.com 自体には一致しない。それ以外は完全一致。大文字小文字は区別しない
  - 許可したホストでも、名前を引いた結果にグローバルでない IP（loopback・LAN・link-local 等）が混ざれば 403
    （VM から Mac 自身・LAN に届かない性質を、名前の側からも崩さない）
  - HTTP は 1 接続 1 リクエスト。上流には origin-form に直したリクエスト行と、Host を URI のホストに
    置き換えたヘッダを送る（Host を書き換えて同じ IP の別のサイトに届かせない）
  - ソケットは 0600、親ディレクトリは 0700。sandbox の allowUnixSockets には載せない（sandbox から直接届かない）
"""

import ipaddress
import os
import re
import signal
import socket
import socketserver
import stat
import sys
import threading
import time
from urllib.parse import urlsplit

DEFAULT_SOCKET = "~/.local/state/vm-egress-proxy/proxy.sock"
MAX_HEAD_BYTES = 64 * 1024
CLIENT_TIMEOUT_SECONDS = 30
CONNECT_TIMEOUT_SECONDS = 30
# 中継中にどちらからも何も届かない時間の上限（張りっぱなしの接続でスレッドを残さない）
IDLE_TIMEOUT_SECONDS = 600

# 上流へ転送しないヘッダ（接続は proxy が Connection: close で張り直す。Host は URI から作り直す）
DROPPED_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-connection",
    "proxy-authorization",
    "host",
}
CONTROL = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
TOKEN = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
REASONS = {400: "Bad Request", 403: "Forbidden", 431: "Request Header Fields Too Large"}


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    sys.stderr.write(f"{stamp} vm-egress-proxy: {message}\n")
    sys.stderr.flush()


class Rejected(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def socket_path(environ):
    return os.path.expanduser(environ.get("VM_EGRESS_PROXY_SOCKET") or DEFAULT_SOCKET)


def load_allowlist(path):
    """1 行 1 パターン。空行と # で始まる行は飛ばす。"""
    with open(path) as f:
        lines = (line.strip() for line in f)
        return [line.lower() for line in lines if line and not line.startswith("#")]


def allowed(host, patterns):
    """host が許可リストのどれかに一致するか（sandbox の allowedDomains と同じ一致の仕方）。"""
    host = host.lower()
    for pattern in patterns:
        if pattern.startswith("*."):
            if host.endswith(pattern[1:]):
                return True
        elif host == pattern:
            return True
    return False


def split_head(data):
    """ヘッダ部を (開始行, [(名前, 値)]) に分ける。単独の CR / LF などの制御文字は拒否する。"""
    lines = data.decode("latin-1").split("\r\n")
    if any(CONTROL.search(line) for line in lines):
        raise Rejected(400, "control characters in the header")
    headers = []
    for line in lines[1:]:
        name, sep, value = line.partition(":")
        if not sep or not TOKEN.fullmatch(name):
            raise Rejected(400, f"malformed header line {line!r}")
        headers.append((name, value.strip()))
    return lines[0], headers


def parse_port(text):
    if not text.isdigit() or not 0 < int(text) < 65536:
        raise Rejected(400, f"invalid port {text!r}")
    return int(text)


def parse_request(head):
    """リクエストを (method, host, port, version, path, headers) に分ける。CONNECT の path は None。"""
    request_line, headers = split_head(head)
    parts = request_line.split(" ")
    if len(parts) != 3 or parts[2] not in ("HTTP/1.0", "HTTP/1.1"):
        raise Rejected(400, f"malformed request line {request_line!r}")
    method, target, version = parts
    if method == "CONNECT":
        host, sep, port = target.rpartition(":")
        if not sep or not host:
            raise Rejected(400, f"CONNECT target must be host:port, got {target!r}")
        return method, host.strip("[]"), parse_port(port), version, None, headers
    if not target.lower().startswith("http://"):
        raise Rejected(
            400, f"only CONNECT and absolute http:// URIs are proxied, got {target!r}"
        )
    url = urlsplit(target)
    try:
        port = url.port or 80
    except ValueError:
        raise Rejected(400, f"invalid port in {target!r}")
    if not url.hostname or "@" in url.netloc:
        raise Rejected(400, f"invalid URI {target!r}")
    path = url.path or "/"
    if url.query:
        path += "?" + url.query
    return method, url.hostname, port, version, path, headers


def connect_upstream(host, port):
    """host を引き、グローバルな IP だけなら繋いだ socket を返す。"""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise Rejected(502, f"cannot resolve {host}: {exc}")
    addresses = [info[4][0] for info in infos]
    local = [
        a for a in addresses if not ipaddress.ip_address(a.split("%")[0]).is_global
    ]
    if local:
        raise Rejected(403, f"{host} resolves to non-global addresses {local}")
    last = None
    for family, kind, proto, _, sockaddr in infos:
        sock = socket.socket(family, kind, proto)
        sock.settimeout(CONNECT_TIMEOUT_SECONDS)
        try:
            sock.connect(sockaddr)
            return sock
        except OSError as exc:
            sock.close()
            last = exc
    raise Rejected(502, f"cannot connect to {host}:{port}: {last}")


def read_head(sock, limit=MAX_HEAD_BYTES):
    """ヘッダの終わり（空行）まで読み、(ヘッダ部, その後に届いていたバイト列) を返す。"""
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > limit:
            raise Rejected(431, "header is too large")
        chunk = sock.recv(65536)
        if not chunk:
            raise Rejected(400, "connection closed before the end of the header")
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    return head, rest


def build_upstream_request(method, host, port, version, path, headers):
    lines = [
        f"{method} {path} {version}",
        f"Host: {host if port == 80 else f'{host}:{port}'}",
    ]
    for name, value in headers:
        if name.lower() not in DROPPED_HEADERS:
            lines.append(f"{name}: {value}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def error_response(status, message):
    body = f"vm-egress-proxy: {message}\n".encode()
    return (
        f"HTTP/1.1 {status} {REASONS.get(status, 'Bad Gateway')}\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + body


def pump(src, dst):
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def relay(client, upstream):
    """両方向に流し、両方が閉じる（か IDLE_TIMEOUT_SECONDS 黙る）まで待つ。"""
    client.settimeout(IDLE_TIMEOUT_SECONDS)
    upstream.settimeout(IDLE_TIMEOUT_SECONDS)
    back = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    back.start()
    pump(client, upstream)
    back.join()


class Handler(socketserver.BaseRequestHandler):
    """1 接続で 1 リクエスト（または 1 本の CONNECT トンネル）を検査して中継する。"""

    def handle(self):
        client = self.request
        client.settimeout(CLIENT_TIMEOUT_SECONDS)
        method = host = port = None
        try:
            head, rest = read_head(client)
            method, host, port, version, path, headers = parse_request(head)
            if not allowed(host, self.server.allowlist):
                raise Rejected(403, f"{host} is not in the allowlist")
            upstream = self.server.connect(host, port)
        except Rejected as exc:
            if exc.status == 403:
                log(f"denied {method} {host}:{port}: {exc}")
            else:
                log(f"{exc.status} {method or '-'} {host or '-'}:{port or '-'}: {exc}")
            self._send(error_response(exc.status, str(exc)))
            return
        except (OSError, ValueError) as exc:
            log(f"reading the request failed: {exc!r}")
            return
        with upstream:
            try:
                if path is None:
                    client.sendall(
                        f"{version} 200 Connection established\r\n\r\n".encode()
                    )
                else:
                    upstream.sendall(
                        build_upstream_request(
                            method, host, port, version, path, headers
                        )
                    )
                if rest:
                    upstream.sendall(rest)
                relay(client, upstream)
            except OSError as exc:
                log(f"{method} {host}:{port} failed: {exc!r}")

    def _send(self, data):
        try:
            self.request.sendall(data)
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def prepare_socket_path(path):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    os.chmod(os.path.dirname(path), 0o700)
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise SystemExit(
            f"vm-egress-proxy: {path} exists and is not a socket; refusing to remove it"
        )
    os.unlink(path)


def main():
    path = socket_path(os.environ)
    allowlist_path = os.environ.get("VM_EGRESS_PROXY_ALLOWLIST")
    if not allowlist_path:
        raise SystemExit("vm-egress-proxy: VM_EGRESS_PROXY_ALLOWLIST is not set")
    os.umask(0o077)
    prepare_socket_path(path)
    server = Server(path, Handler)
    os.chmod(path, 0o600)
    server.allowlist = load_allowlist(allowlist_path)
    server.connect = connect_upstream

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(
        f"listening on {path} ({len(server.allowlist)} allowed patterns from {allowlist_path})"
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
