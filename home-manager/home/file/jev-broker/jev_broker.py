"""jev-broker: Jev（TypeSafe の判定専用モデル）への呼び出しを Unix ソケットで中継する常駐プロセス。

なぜ要るか:
  API 鍵は login keychain にあるが、Keychain の解除は監査セッション（asid）ごとに効く。
  Claude Code の bg job は別の asid で動くので、解除済みでも security が exit 36 になる。
  sandbox 内の Bash は securityd に届かず、同じく 36 になる。gui ドメインの LaunchAgent は
  Aqua セッションで動くので鍵を読める。ここで鍵をメモリにだけ持ち、呼び出し側
  （jev-classify.sh）には鍵を渡さずに中継する。

不変条件:
  - 転送先の URL と model は固定。呼び出し側が送った model は上書きする
    （ソケットに届くプロセスに、鍵を Jev 以外の課金に使わせない）
  - 鍵はメモリにだけ置く。ログ・応答・ファイルに出さない
  - ソケットは 0600、親ディレクトリは 0700
"""

import http.server
import json
import os
import signal
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

UPSTREAM_URL = "https://ai-gateway.vercel.sh/typesafe/v1/systemone"
MODEL = "typesafe-ai/jev"
REQUEST_PATH = "/typesafe/v1/systemone"
MAX_BODY_BYTES = 256 * 1024
UPSTREAM_TIMEOUT_SECONDS = 30
DEFAULT_SOCKET = "~/.local/state/jev-broker/jev.sock"
DEFAULT_KEYCHAIN_SERVICE = "vercel-ai-gateway"


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    sys.stderr.write(f"{stamp} jev-broker: {message}\n")
    sys.stderr.flush()


def error_body(message):
    return json.dumps({"error": f"jev-broker: {message}"}).encode()


class KeyUnavailable(Exception):
    pass


class KeychainKey:
    """Keychain から鍵を 1 回だけ読み、メモリに保持する。forget() で次回読み直す。"""

    def __init__(self, service, runner=subprocess.run):
        self.service = service
        self._runner = runner
        self._key = None
        self._lock = threading.Lock()

    def get(self):
        with self._lock:
            if self._key is None:
                result = self._runner(
                    [
                        "/usr/bin/security",
                        "find-generic-password",
                        "-s",
                        self.service,
                        "-w",
                    ],
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    raise KeyUnavailable(
                        f"keychain read failed (item '{self.service}': security exit {result.returncode})"
                    )
                key = result.stdout.strip()
                if not key:
                    raise KeyUnavailable(f"keychain item '{self.service}' is empty")
                self._key = key
            return self._key

    def forget(self):
        with self._lock:
            self._key = None


def forward(body, key_source, opener, upstream_url, timeout):
    """リクエスト本文を Jev に転送し (status, 応答本文) を返す。上流の応答はそのまま返す。"""
    try:
        payload = json.loads(body)
    except ValueError:
        return 400, error_body("request body is not JSON")
    if not isinstance(payload, dict):
        return 400, error_body("request body must be a JSON object")
    payload["model"] = MODEL

    try:
        key = key_source.get()
    except KeyUnavailable as exc:
        return 503, error_body(str(exc))

    request = urllib.request.Request(
        upstream_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    try:
        with opener(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        # 鍵が差し替えられた・失効した場合に、次のリクエストで読み直す
        if exc.code in (401, 403):
            key_source.forget()
        return exc.code, exc.read()
    except TimeoutError:
        return 504, error_body(f"upstream timeout ({timeout}s)")
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            return 504, error_body(f"upstream timeout ({timeout}s)")
        return 502, error_body(f"upstream unreachable: {exc.reason}")


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1 にするのは Expect: 100-continue に即答するため。curl は 1KB 超の本文で
    # これを送り、応答が無いと 1 秒待つ（hook の上限は 2 秒）。
    protocol_version = "HTTP/1.1"
    server_version = "jev-broker"

    def do_POST(self):
        started = time.monotonic()
        if self.path != REQUEST_PATH:
            self._send(404, error_body(f"unknown path {self.path!r}"))
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._send(411, error_body("Content-Length required"))
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(413, error_body(f"body must be 1..{MAX_BODY_BYTES} bytes"))
            return
        body = self.rfile.read(length)
        status, payload = forward(
            body,
            self.server.key_source,
            self.server.opener,
            self.server.upstream_url,
            self.server.upstream_timeout,
        )
        self._send(status, payload)
        # hook は Bash のたびに呼ぶので、成功は記録しない（ログが際限なく育つ）
        if status != 200:
            log(
                f"POST {self.path} -> {status} ({(time.monotonic() - started) * 1000:.0f}ms)"
            )

    def do_GET(self):
        self._send(405, error_body("use POST"))

    def _send(self, status, payload):
        self.send_response_only(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, format, *args):
        # 既定の行ログは出さない（do_POST が status と所要時間だけ出す）
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def prepare_socket_path(path):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise SystemExit(
            f"jev-broker: {path} exists and is not a socket; refusing to remove it"
        )
    # 前回のプロセスが残したソケット（launchd の再起動・クラッシュ後）
    os.unlink(path)


def main():
    socket_path = os.path.expanduser(
        os.environ.get("JEV_BROKER_SOCKET", DEFAULT_SOCKET)
    )
    service = os.environ.get("JEV_KEYCHAIN_SERVICE", DEFAULT_KEYCHAIN_SERVICE)
    os.umask(0o077)
    prepare_socket_path(socket_path)

    key_source = KeychainKey(service)
    try:
        key_source.get()
        log(f"key loaded from keychain item '{service}'")
    except KeyUnavailable as exc:
        log(f"key not loaded yet ({exc}); retrying on each request")

    server = Server(socket_path, Handler)
    os.chmod(socket_path, 0o600)
    server.key_source = key_source
    server.opener = urllib.request.urlopen
    server.upstream_url = UPSTREAM_URL
    server.upstream_timeout = UPSTREAM_TIMEOUT_SECONDS

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"listening on {socket_path}")
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
