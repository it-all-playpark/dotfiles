"""pg-broker: 使い捨ての Postgres を sandbox の外で起動し、Unix ソケットの接続先を返す常駐プロセス。

なぜ要るか:
  sandbox 内の Bash では Postgres を起動できない（initdb の shmget が EPERM で落ちる）。
  docker を sandbox 外に出すとホスト権限相当になるので取らない。LaunchAgent のこのプロセスが
  依頼を受けて cluster を作り、sandbox からは allowUnixSockets に載せたソケットで繋がせる。

API（HTTP over Unix socket、~/.local/state/pg-broker/broker.sock）:
  POST   /instances       {"version":"17"}（本文は省略可）
         -> 201 {"id","database_url","socket_dir","expires_at"}
  DELETE /instances/<id>  -> 200 停止して data dir を消す

不変条件:
  - エージェントに渡すのは非 superuser の app ロールだけ。pg_hba は local の app/app だけを通し、
    ほかは reject する（superuser は COPY ... TO PROGRAM や pg_read_server_files で sandbox の外の
    コマンド実行・ファイル読み出しができる）。app と DB は single-user mode で作るので、
    superuser がソケットから繋がる経路は最初から無い
  - 起動する binary は VERSIONS の表にある version の、nix store の固定パスだけ。
    依頼に含まれる設定値・パス・SQL は受け付けない（呼び出し側のコードを sandbox 外で実行させない）
  - data dir とソケットは ~/.local/state/pg-broker/ 配下（sandbox の allowWrite に足さない）
  - 同時に MAX_INSTANCES まで。TTL を過ぎたら停止・削除し、起動時には前回の残りを掃除する
    （dev-flow が abort しても DB が残り続けないようにする）
"""

import http.server
import json
import os
import re
import secrets
import shutil
import signal
import socketserver
import stat
import subprocess
import sys
import threading
import time

# 許可する version → bin ディレクトリを渡す環境変数（pg-broker.nix が nix store の固定パスを入れる）
VERSIONS = {"17": "PG_BROKER_POSTGRESQL_17"}
DEFAULT_VERSION = "17"
NIX_STORE = "/nix/store/"
MAX_INSTANCES = 4
TTL_SECONDS = 90 * 60
REAP_INTERVAL_SECONDS = 30
COMMAND_TIMEOUT_SECONDS = 60
MAX_BODY_BYTES = 1024
DEFAULT_ROOT = "~/.local/state/pg-broker"
ROLE = "app"
DATABASE = "app"
INSTANCE_ID = re.compile(r"[0-9a-f]{12}")
# 子プロセスに PG* などの環境変数を持ち込まない
CHILD_ENV = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}

# superuser は single-user mode でしか使わない。ソケットから通すのは app ロールの app DB だけ
PG_HBA = f"""# pg-broker が書く。app ロール以外（superuser を含む）はソケットから繋がせない
local {DATABASE} {ROLE} trust
local all all reject
"""

BOOTSTRAP_SQL = (
    f"CREATE ROLE {ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS\n"
    f"CREATE DATABASE {DATABASE} OWNER {ROLE}\n"
)


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    sys.stderr.write(f"{stamp} pg-broker: {message}\n")
    sys.stderr.flush()


def error_body(message):
    return json.dumps({"error": f"pg-broker: {message}"}).encode()


class BrokerError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def load_versions(environ):
    """VERSIONS の表から、環境変数に nix store のパスが入っている version だけを返す。"""
    versions = {}
    for version, variable in VERSIONS.items():
        bin_dir = environ.get(variable, "")
        if bin_dir.startswith(NIX_STORE) and ".." not in bin_dir.split("/"):
            versions[version] = bin_dir
        elif bin_dir:
            log(
                f"{variable}={bin_dir!r} is not under {NIX_STORE}; version {version} disabled"
            )
    return versions


def parse_request(body):
    """POST /instances の本文から version を取り出す。version 以外のキーは受け付けない。"""
    if not body.strip():
        return DEFAULT_VERSION
    try:
        payload = json.loads(body)
    except ValueError:
        raise BrokerError(400, "request body is not JSON")
    if not isinstance(payload, dict):
        raise BrokerError(400, "request body must be a JSON object")
    extra = sorted(set(payload) - {"version"})
    if extra:
        raise BrokerError(400, f"unsupported keys {extra}; only 'version' is accepted")
    version = payload.get("version", DEFAULT_VERSION)
    if not isinstance(version, str):
        raise BrokerError(400, "version must be a string")
    return version


def iso_utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class Broker:
    def __init__(
        self,
        root,
        versions,
        ttl_seconds=TTL_SECONDS,
        max_instances=MAX_INSTANCES,
        runner=subprocess.run,
        clock=time.time,
    ):
        self.root = root
        self.data_root = os.path.join(root, "data")
        self.sock_root = os.path.join(root, "sock")
        self.versions = versions
        self.ttl_seconds = ttl_seconds
        self.max_instances = max_instances
        self._runner = runner
        self._clock = clock
        self._instances = {}
        self._starting = 0
        self._lock = threading.Lock()

    def prepare(self):
        for directory in (self.root, self.data_root, self.sock_root):
            os.makedirs(directory, mode=0o700, exist_ok=True)
            os.chmod(directory, 0o700)

    def _run(self, argv, **kwargs):
        return self._runner(
            argv,
            capture_output=True,
            text=True,
            env=CHILD_ENV,
            timeout=COMMAND_TIMEOUT_SECONDS,
            **kwargs,
        )

    def _check(self, step, result):
        if result.returncode != 0:
            output = (result.stderr or "").strip() or (result.stdout or "").strip()
            tail = " | ".join(output.splitlines()[-5:])
            raise BrokerError(500, f"{step} failed (exit {result.returncode}): {tail}")

    def create(self, version):
        bin_dir = self.versions.get(version)
        if bin_dir is None:
            raise BrokerError(
                400,
                f"unsupported version {version!r}; available: {sorted(self.versions)}",
            )
        with self._lock:
            if len(self._instances) + self._starting >= self.max_instances:
                raise BrokerError(
                    429,
                    f"{self.max_instances} instances are already running; "
                    "DELETE one before creating another",
                )
            self._starting += 1
        instance_id = secrets.token_hex(6)
        data_dir = os.path.join(self.data_root, instance_id)
        socket_dir = os.path.join(self.sock_root, instance_id)
        failure = None
        try:
            self._start(bin_dir, data_dir, socket_dir)
        except BrokerError as exc:
            failure = exc
        except subprocess.TimeoutExpired as exc:
            failure = BrokerError(500, f"timed out: {os.path.basename(exc.cmd[0])}")
        except OSError as exc:
            failure = BrokerError(500, f"could not prepare the instance: {exc}")
        if failure is not None:
            self._remove(bin_dir, data_dir, socket_dir)
            with self._lock:
                self._starting -= 1
            raise failure
        expires = self._clock() + self.ttl_seconds
        instance = {
            "id": instance_id,
            "bin_dir": bin_dir,
            "data_dir": data_dir,
            "socket_dir": socket_dir,
            "expires": expires,
        }
        with self._lock:
            self._starting -= 1
            self._instances[instance_id] = instance
        log(f"started {instance_id} (version {version})")
        return {
            "id": instance_id,
            "database_url": f"postgresql://{ROLE}@localhost/{DATABASE}?host={socket_dir}",
            "socket_dir": socket_dir,
            "expires_at": iso_utc(expires),
        }

    def _start(self, bin_dir, data_dir, socket_dir):
        os.makedirs(socket_dir, mode=0o700)
        self._check(
            "initdb",
            self._run(
                [
                    os.path.join(bin_dir, "initdb"),
                    "-D",
                    data_dir,
                    "-U",
                    "postgres",
                    "--auth=reject",
                    "--no-locale",
                    "-E",
                    "UTF8",
                    "--no-instructions",
                    "--no-sync",
                ]
            ),
        )
        with open(os.path.join(data_dir, "pg_hba.conf"), "w") as f:
            f.write(PG_HBA)
        with open(os.path.join(data_dir, "postgresql.conf"), "a") as f:
            f.write(
                "\n# pg-broker\n"
                "listen_addresses = ''\n"
                f"unix_socket_directories = '{socket_dir}'\n"
                "unix_socket_permissions = 0700\n"
            )
        # ERROR で終了させる（single-user mode は既定だと ERROR のあとも exit 0 で続ける）
        self._check(
            "bootstrap",
            self._run(
                [
                    os.path.join(bin_dir, "postgres"),
                    "--single",
                    "-D",
                    data_dir,
                    "-c",
                    "exit_on_error=on",
                    "postgres",
                ],
                input=BOOTSTRAP_SQL,
            ),
        )
        self._check(
            "pg_ctl start",
            self._run(
                [
                    os.path.join(bin_dir, "pg_ctl"),
                    "start",
                    "-D",
                    data_dir,
                    "-l",
                    os.path.join(data_dir, "postmaster.log"),
                    "-w",
                    "-t",
                    "30",
                    "-s",
                ]
            ),
        )

    def _remove(self, bin_dir, data_dir, socket_dir):
        if bin_dir and os.path.exists(os.path.join(data_dir, "postmaster.pid")):
            try:
                result = self._run(
                    [
                        os.path.join(bin_dir, "pg_ctl"),
                        "stop",
                        "-D",
                        data_dir,
                        "-m",
                        "immediate",
                        "-w",
                        "-t",
                        "30",
                        "-s",
                    ]
                )
                if result.returncode != 0:
                    log(f"pg_ctl stop {data_dir} exited {result.returncode}")
            except subprocess.TimeoutExpired:
                log(f"pg_ctl stop {data_dir} timed out")
        shutil.rmtree(data_dir, ignore_errors=True)
        shutil.rmtree(socket_dir, ignore_errors=True)

    def delete(self, instance_id):
        with self._lock:
            instance = self._instances.pop(instance_id, None)
        if instance is None:
            raise BrokerError(404, f"no instance {instance_id!r}")
        self._remove(instance["bin_dir"], instance["data_dir"], instance["socket_dir"])
        log(f"deleted {instance_id}")

    def reap_expired(self):
        now = self._clock()
        with self._lock:
            expired = [i for i in self._instances.values() if i["expires"] <= now]
            for instance in expired:
                del self._instances[instance["id"]]
        for instance in expired:
            self._remove(
                instance["bin_dir"], instance["data_dir"], instance["socket_dir"]
            )
            log(f"expired {instance['id']}")
        return [instance["id"] for instance in expired]

    def stop_all(self):
        with self._lock:
            instances = list(self._instances.values())
            self._instances.clear()
        for instance in instances:
            self._remove(
                instance["bin_dir"], instance["data_dir"], instance["socket_dir"]
            )

    def cleanup_leftovers(self):
        """前回の broker が残した cluster を止めて消す（クラッシュ・再起動のあと）。"""
        removed = []
        for name in sorted(os.listdir(self.data_root)):
            data_dir = os.path.join(self.data_root, name)
            try:
                with open(os.path.join(data_dir, "PG_VERSION")) as f:
                    bin_dir = self.versions.get(f.read().strip())
            except OSError:
                bin_dir = None
            self._remove(bin_dir, data_dir, os.path.join(self.sock_root, name))
            removed.append(name)
        for name in sorted(os.listdir(self.sock_root)):
            shutil.rmtree(os.path.join(self.sock_root, name), ignore_errors=True)
            if name not in removed:
                removed.append(name)
        if removed:
            log(f"removed leftovers from the previous run: {', '.join(removed)}")
        return removed


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pg-broker"

    def do_POST(self):
        if self.path != "/instances":
            self._send(404, error_body(f"unknown path {self.path!r}"))
            return
        length_header = self.headers.get("Content-Length", "0")
        try:
            length = int(length_header)
        except ValueError:
            self._send(400, error_body("invalid Content-Length"))
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._send(413, error_body(f"body must be 0..{MAX_BODY_BYTES} bytes"))
            return
        body = self.rfile.read(length) if length else b""
        try:
            instance = self.server.broker.create(parse_request(body))
        except BrokerError as exc:
            self._fail(exc)
            return
        self._send(201, json.dumps(instance).encode())

    def do_DELETE(self):
        prefix = "/instances/"
        instance_id = self.path[len(prefix) :] if self.path.startswith(prefix) else ""
        if not INSTANCE_ID.fullmatch(instance_id):
            self._send(404, error_body(f"unknown path {self.path!r}"))
            return
        try:
            self.server.broker.delete(instance_id)
        except BrokerError as exc:
            self._fail(exc)
            return
        self._send(200, json.dumps({"id": instance_id, "deleted": True}).encode())

    def do_GET(self):
        self._send(405, error_body("use POST /instances or DELETE /instances/<id>"))

    def _fail(self, exc):
        if exc.status >= 500:
            log(f"{self.command} {self.path} -> {exc.status}: {exc}")
        self._send(exc.status, error_body(str(exc)))

    def _send(self, status, payload):
        self.send_response_only(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, format, *args):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def prepare_socket_path(path):
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise SystemExit(
            f"pg-broker: {path} exists and is not a socket; refusing to remove it"
        )
    os.unlink(path)


def reap_forever(broker, stopped, interval):
    while not stopped.wait(interval):
        try:
            broker.reap_expired()
        except (
            OSError,
            subprocess.SubprocessError,
        ) as exc:  # 1 回の失敗で掃除を止めない
            log(f"reap failed: {exc!r}")


def main():
    root = os.path.expanduser(os.environ.get("PG_BROKER_ROOT", DEFAULT_ROOT))
    os.umask(0o077)
    versions = load_versions(os.environ)
    if not versions:
        log("no postgres version is configured; every request will be rejected")
    broker = Broker(root, versions)
    broker.prepare()
    broker.cleanup_leftovers()

    socket_path = os.path.join(root, "broker.sock")
    prepare_socket_path(socket_path)
    server = Server(socket_path, Handler)
    os.chmod(socket_path, 0o600)
    server.broker = broker

    stopped = threading.Event()
    threading.Thread(
        target=reap_forever,
        args=(broker, stopped, REAP_INTERVAL_SECONDS),
        daemon=True,
    ).start()

    def stop(signum, frame):
        stopped.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"listening on {socket_path} (versions: {sorted(versions)})")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        broker.stop_all()
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
