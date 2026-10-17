"""docker-proxy: docker の読み取り専用 API だけを Unix ソケットで中継する常駐プロセス。

なぜ要るか:
  sandbox 内の Bash は docker.sock（allowUnixSockets に無い）に繋がらないので、docker ps 1 つにも
  host-exec の承認が要る。docker.sock をそのまま通すと `-v /:/host` や `--privileged` でホストの
  root 相当になるので通さない。LaunchAgent のこのプロセスが調査用の GET だけを上流の docker.sock へ
  中継し、sandbox からは allowUnixSockets に載せたこのプロセスのソケットに繋がせる（docker-sb）。

不変条件:
  - 中継するのは ROUTES の allowlist に一致する GET / HEAD だけ。それ以外は 403 を返し、上流には
    接続しない（API version が上がって増えたエンドポイントも既定で 403）
  - 1 接続 1 リクエスト。上流に送るのは検査したリクエスト行とヘッダから組み立て直した 1 本だけで、
    クライアントのバイト列をそのまま流さない。body・Upgrade・2 本目のリクエストは受け付けない
  - logs は follow しない、stats は stream しないものだけ（接続を張りっぱなしにさせない）
  - container / image の inspect 応答から Config.Env を取り除く（--env-file の資格情報がそこに出る）
  - ソケットは 0600、親ディレクトリは 0700
"""

import json
import os
import re
import signal
import socket
import socketserver
import stat
import sys
import threading
import time
from urllib.parse import parse_qsl

DEFAULT_SOCKET = "~/.local/state/docker-proxy/docker.sock"
DEFAULT_UPSTREAM = "~/.orbstack/run/docker.sock"
MAX_HEAD_BYTES = 64 * 1024
MAX_FILTERED_BODY_BYTES = 32 * 1024 * 1024
CLIENT_TIMEOUT_SECONDS = 10
UPSTREAM_TIMEOUT_SECONDS = 60

API_VERSION = re.compile(r"/v[0-9]+\.[0-9]+(?=/)")
CONTAINER = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
# image の参照は registry/repo:tag や repo@sha256:... のように / と : を含む
IMAGE = r"[A-Za-z0-9][A-Za-z0-9_.:@/-]*"
ROUTES = [
    ("ping", re.compile(r"/_ping")),
    ("version", re.compile(r"/version")),
    ("info", re.compile(r"/info")),
    ("container_list", re.compile(r"/containers/json")),
    ("container_inspect", re.compile(rf"/containers/{CONTAINER}/json")),
    ("container_logs", re.compile(rf"/containers/{CONTAINER}/logs")),
    ("container_stats", re.compile(rf"/containers/{CONTAINER}/stats")),
    ("container_top", re.compile(rf"/containers/{CONTAINER}/top")),
    ("image_list", re.compile(r"/images/json")),
    ("image_inspect", re.compile(rf"/images/{IMAGE}/json")),
    ("system_df", re.compile(r"/system/df")),
]
# Config.Env を取り除いてから返すルート
FILTERED = {"container_inspect", "image_inspect"}
METHODS = {"GET", "HEAD"}
SUSPICIOUS_PATH = re.compile(r"%2e|%2f|//|\.\.", re.IGNORECASE)
CONTROL = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
TOKEN = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
# 上流へ転送しないヘッダ（接続は proxy が Connection: close で張り直す）
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-connection",
    "te",
    "trailer",
    "accept-encoding",
}
# docker の httputils.BoolValue が偽と読む値
FALSY = {"", "0", "no", "false", "none"}
# container_top の ps_args は dockerd が host 側の ps にそのまま渡す。
# e 修飾子（auxe など）でプロセスの環境変数が出るため、決まった値だけ通す
TOP_PS_ARGS = {"", "-ef", "aux"}


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    sys.stderr.write(f"{stamp} docker-proxy: {message}\n")
    sys.stderr.flush()


class Rejected(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def socket_paths(environ):
    """待ち受けるソケットと上流の docker ソケットのパスを返す。"""
    listen = environ.get("DOCKER_PROXY_SOCKET") or DEFAULT_SOCKET
    upstream = environ.get("DOCKER_PROXY_UPSTREAM") or DEFAULT_UPSTREAM
    return os.path.expanduser(listen), os.path.expanduser(upstream)


def split_head(data):
    """HTTP のヘッダ部を (開始行, [(名前, 値)]) に分ける。

    単独の CR / LF などの制御文字は拒否する（上流の parser が行の区切りと読むと、
    検査していないヘッダを差し込める）。
    """
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


def header_values(headers, name):
    return [value for key, value in headers if key.lower() == name]


def is_true(value):
    return value.strip().lower() not in FALSY


def check_request(head):
    """クライアントのリクエストを検査し、(method, target, route, headers) を返す。"""
    request_line, headers = split_head(head)
    parts = request_line.split(" ")
    if len(parts) != 3 or parts[2] not in ("HTTP/1.0", "HTTP/1.1"):
        raise Rejected(400, f"malformed request line {request_line!r}")
    method, target, _ = parts
    if method not in METHODS:
        raise Rejected(403, f"method {method} is not allowed")
    if header_values(headers, "upgrade"):
        raise Rejected(403, "Upgrade is not allowed")
    if header_values(headers, "transfer-encoding"):
        raise Rejected(403, "request body is not allowed (Transfer-Encoding)")
    lengths = header_values(headers, "content-length")
    if lengths and lengths != ["0"]:
        raise Rejected(403, "request body is not allowed (Content-Length)")
    path, _, query = target.partition("?")
    if not path.startswith("/") or SUSPICIOUS_PATH.search(path):
        raise Rejected(403, f"path {path!r} is not allowed")
    match = API_VERSION.match(path)
    bare = path[match.end() :] if match else path
    route = next((name for name, rx in ROUTES if rx.fullmatch(bare)), None)
    if route is None:
        raise Rejected(403, f"{method} {bare} is not in the read-only allowlist")
    params = parse_qsl(query, keep_blank_values=True)
    if route == "container_logs" and any(
        is_true(v) for k, v in params if k == "follow"
    ):
        raise Rejected(403, "logs with follow is not allowed")
    if route == "container_stats":
        streams = [v for k, v in params if k == "stream"]
        if not streams or any(is_true(v) for v in streams):
            raise Rejected(403, "stats must be requested with stream=0")
    if route == "container_top" and any(
        v not in TOP_PS_ARGS for k, v in params if k == "ps_args"
    ):
        raise Rejected(403, "top accepts only ps_args=-ef or ps_args=aux")
    return method, target, route, headers


def build_upstream_request(method, target, headers):
    lines = [f"{method} {target} HTTP/1.1"]
    for name, value in headers:
        if name.lower() not in HOP_BY_HOP and name.lower() != "content-length":
            lines.append(f"{name}: {value}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


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


def read_exact_or_eof(sock, buffer, size):
    while len(buffer) < size:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buffer += chunk
    return buffer


def read_body(sock, rest, headers):
    """上流の応答 body を Content-Length / chunked / 切断まで読み切って返す。"""
    encodings = [v.strip().lower() for v in header_values(headers, "transfer-encoding")]
    if encodings:
        if encodings != ["chunked"]:
            raise Rejected(502, f"unsupported Transfer-Encoding {encodings}")
        return read_chunked(sock, rest)
    lengths = header_values(headers, "content-length")
    if lengths:
        size = int(lengths[0])
        if size > MAX_FILTERED_BODY_BYTES:
            raise Rejected(502, "upstream response is too large")
        body = read_exact_or_eof(sock, rest, size)
        if len(body) < size:
            raise Rejected(502, "upstream response was cut short")
        return body[:size]
    body = rest
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return body
        body += chunk
        if len(body) > MAX_FILTERED_BODY_BYTES:
            raise Rejected(502, "upstream response is too large")


def read_chunked(sock, buffer):
    body = b""
    while True:
        while b"\r\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                raise Rejected(502, "upstream chunked response was cut short")
            buffer += chunk
        size_line, _, buffer = buffer.partition(b"\r\n")
        size = int(size_line.split(b";")[0].strip(), 16)
        if size == 0:
            return body
        if len(body) + size > MAX_FILTERED_BODY_BYTES:
            raise Rejected(502, "upstream response is too large")
        buffer = read_exact_or_eof(sock, buffer, size + 2)
        if len(buffer) < size + 2:
            raise Rejected(502, "upstream chunked response was cut short")
        body += buffer[:size]
        buffer = buffer[size + 2 :]


def strip_env(body):
    """inspect の JSON から Config.Env を取り除く。JSON でなければ返さない（fail closed）。"""
    try:
        payload = json.loads(body)
    except ValueError:
        raise Rejected(502, "upstream inspect response is not JSON")
    if isinstance(payload, dict) and isinstance(payload.get("Config"), dict):
        payload["Config"].pop("Env", None)
    return (json.dumps(payload) + "\n").encode()


def response_head(status_line, headers, drop=(), extra=()):
    lines = [status_line]
    for name, value in headers:
        if name.lower() not in {"connection", "keep-alive", *drop}:
            lines.append(f"{name}: {value}")
    lines.extend(extra)
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def error_response(status, message):
    payload = json.dumps({"message": f"docker-proxy: {message}"}).encode()
    reason = {
        400: "Bad Request",
        403: "Forbidden",
        431: "Request Header Fields Too Large",
    }
    return (
        f"HTTP/1.1 {status} {reason.get(status, 'Bad Gateway')}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + payload


class Handler(socketserver.BaseRequestHandler):
    """1 接続で 1 リクエストだけを検査して中継し、応答を返したら切る。"""

    def handle(self):
        client = self.request
        client.settimeout(CLIENT_TIMEOUT_SECONDS)
        try:
            head, rest = read_head(client)
            if rest:
                # body か 2 本目のリクエスト。どちらも上流に送らない
                raise Rejected(403, "request body or a second request is not allowed")
            method, target, route, headers = check_request(head)
        except Rejected as exc:
            self._send(error_response(exc.status, str(exc)))
            return
        except (OSError, ValueError) as exc:
            log(f"reading the request failed: {exc!r}")
            return
        try:
            self._relay(method, target, route, headers)
        except Rejected as exc:
            log(f"{method} {target} -> {exc.status}: {exc}")
            self._send(error_response(exc.status, str(exc)))
        except (OSError, ValueError) as exc:
            log(f"{method} {target} failed: {exc!r}")
            self._send(error_response(502, f"upstream failed: {exc}"))

    def _relay(self, method, target, route, headers):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
            upstream.settimeout(UPSTREAM_TIMEOUT_SECONDS)
            upstream.connect(self.server.upstream)
            upstream.sendall(build_upstream_request(method, target, headers))
            try:
                head, rest = read_head(upstream)
                status_line, response_headers = split_head(head)
            except Rejected as exc:
                raise Rejected(502, f"upstream response: {exc}")
            if route in FILTERED and method == "GET":
                body = strip_env(read_body(upstream, rest, response_headers))
                self.request.sendall(
                    response_head(
                        status_line,
                        response_headers,
                        drop={"content-length", "transfer-encoding"},
                        extra=[f"Content-Length: {len(body)}"],
                    )
                    + body
                )
                return
            # HEAD の Content-Length は Config.Env を取り除く前の長さなので返さない
            drop = {"content-length"} if route in FILTERED else ()
            self.request.sendall(response_head(status_line, response_headers, drop))
            if method == "HEAD":
                return
            if rest:
                self.request.sendall(rest)
            while True:
                chunk = upstream.recv(65536)
                if not chunk:
                    return
                self.request.sendall(chunk)

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
            f"docker-proxy: {path} exists and is not a socket; refusing to remove it"
        )
    os.unlink(path)


def main():
    socket_path, upstream = socket_paths(os.environ)
    os.umask(0o077)
    prepare_socket_path(socket_path)
    server = Server(socket_path, Handler)
    os.chmod(socket_path, 0o600)
    server.upstream = upstream

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"listening on {socket_path} (upstream: {upstream})")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
