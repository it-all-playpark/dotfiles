"""pg_broker のテスト。

実行: python3 -m unittest pg_broker_test（tests/pg-broker.test.sh から呼ぶ）

- 単体テストは Postgres を起動しない。initdb / postgres / pg_ctl の呼び出しは FakeRunner が受ける
- PostgresIntegrationTest だけは PATH 上の nix store の Postgres 17（nix develop が入れる）を
  実際に起動し、app ロールで何ができて何が拒否されるかを確かめる。Claude の sandbox 内では
  shmget が EPERM になって起動できないので、そのときは skip する（CI では走る）
"""

import io
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace

import pg_broker

BIN = "/nix/store/0000-postgresql-17/bin"
REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
)


class FakeRunner:
    """subprocess.run の代わり。呼び出しを記録し、initdb / pg_ctl が作るファイルだけ再現する。"""

    def __init__(self, fail=None):
        # fail: 失敗させる手順（"initdb" / "bootstrap" / "pg_ctl start"）
        self.fail = fail
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        step = self.step(argv)
        if step == self.fail:
            return subprocess.CompletedProcess(
                argv, 1, stdout="progress\n", stderr=f"FATAL: {step} broke\n"
            )
        data_dir = argv[argv.index("-D") + 1]
        if step == "initdb":
            os.makedirs(data_dir)
            for name, content in (
                ("postgresql.conf", "# initdb\n"),
                ("pg_hba.conf", "local all all reject\n"),
                ("PG_VERSION", "17\n"),
            ):
                with open(os.path.join(data_dir, name), "w") as f:
                    f.write(content)
        elif step == "pg_ctl start":
            with open(os.path.join(data_dir, "postmaster.pid"), "w") as f:
                f.write("12345\n")
        elif step == "pg_ctl stop":
            os.unlink(os.path.join(data_dir, "postmaster.pid"))
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    @staticmethod
    def step(argv):
        name = os.path.basename(argv[0])
        if name == "postgres" and argv[1] == "--single":
            return "bootstrap"
        if name == "pg_ctl":
            return f"pg_ctl {argv[1]}"
        return name

    def steps(self):
        return [self.step(argv) for argv, _ in self.calls]

    def argv_of(self, step):
        return [argv for argv, _ in self.calls if self.step(argv) == step]


class FakeClock:
    def __init__(self, now=1_800_000_000):
        self.now = now

    def __call__(self):
        return self.now


class TempRootMixin:
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="pgb-test-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.stderr = io.StringIO()
        redirect = redirect_stderr(self.stderr)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def broker(self, runner=None, clock=None, **kwargs):
        broker = pg_broker.Broker(
            self.root,
            {"17": BIN},
            runner=runner or FakeRunner(),
            clock=clock or FakeClock(),
            **kwargs,
        )
        broker.prepare()
        return broker


class ParseRequestTest(unittest.TestCase):
    def test_empty_body_is_the_default_version(self):
        self.assertEqual(pg_broker.parse_request(b""), "17")
        self.assertEqual(pg_broker.parse_request(b"{}"), "17")

    def test_version_is_read(self):
        self.assertEqual(pg_broker.parse_request(b'{"version":"17"}'), "17")

    def test_settings_paths_and_sql_are_rejected(self):
        for body in (
            {"version": "17", "config": {"listen_addresses": "*"}},
            {"version": "17", "bin_dir": "/tmp/evil"},
            {"version": "17", "sql": "ALTER ROLE app SUPERUSER"},
        ):
            with self.assertRaises(pg_broker.BrokerError) as ctx:
                pg_broker.parse_request(json.dumps(body).encode())
            self.assertEqual(ctx.exception.status, 400)

    def test_malformed_bodies_are_400(self):
        for body in (b"not json", b"[1]", b'{"version":17}'):
            with self.assertRaises(pg_broker.BrokerError) as ctx:
                pg_broker.parse_request(body)
            self.assertEqual(ctx.exception.status, 400)


class LoadVersionsTest(unittest.TestCase):
    def test_only_nix_store_paths_are_used(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(
                pg_broker.load_versions({"PG_BROKER_POSTGRESQL_17": BIN}), {"17": BIN}
            )
            for value in ("/opt/homebrew/bin", "/nix/store/../tmp/bin", ""):
                self.assertEqual(
                    pg_broker.load_versions({"PG_BROKER_POSTGRESQL_17": value}), {}
                )

    def test_versions_outside_the_table_are_ignored(self):
        self.assertEqual(
            pg_broker.load_versions({"PG_BROKER_POSTGRESQL_16": BIN}),
            {},
        )


class CreateTest(TempRootMixin, unittest.TestCase):
    def test_returns_connection_info_for_the_app_role(self):
        clock = FakeClock()
        broker = self.broker(clock=clock)
        instance = broker.create("17")
        self.assertEqual(
            set(instance), {"id", "database_url", "socket_dir", "expires_at"}
        )
        socket_dir = os.path.join(self.root, "sock", instance["id"])
        self.assertEqual(instance["socket_dir"], socket_dir)
        self.assertEqual(
            instance["database_url"],
            f"postgresql://app@localhost/app?host={socket_dir}",
        )
        self.assertEqual(instance["expires_at"], pg_broker.iso_utc(clock.now + 90 * 60))
        self.assertTrue(os.path.isdir(socket_dir))

    def test_runs_only_the_binaries_from_the_version_table(self):
        runner = FakeRunner()
        self.broker(runner=runner).create("17")
        self.assertEqual(runner.steps(), ["initdb", "bootstrap", "pg_ctl start"])
        for argv, kwargs in runner.calls:
            self.assertTrue(argv[0].startswith(BIN + "/"), argv)
            self.assertEqual(kwargs["env"], pg_broker.CHILD_ENV)

    def test_superuser_cannot_connect_through_the_socket(self):
        broker = self.broker()
        instance = broker.create("17")
        data_dir = os.path.join(self.root, "data", instance["id"])
        with open(os.path.join(data_dir, "pg_hba.conf")) as f:
            rules = [
                line.split()
                for line in f
                if line.strip() and not line.lstrip().startswith("#")
            ]
        self.assertEqual(
            rules, [["local", "app", "app", "trust"], ["local", "all", "all", "reject"]]
        )

    def test_app_role_is_not_superuser(self):
        runner = FakeRunner()
        self.broker(runner=runner).create("17")
        argv, kwargs = next(
            call for call in runner.calls if runner.step(call[0]) == "bootstrap"
        )
        self.assertIn("exit_on_error=on", argv)
        sql = kwargs["input"]
        self.assertIn("CREATE ROLE app LOGIN NOSUPERUSER", sql)
        self.assertIn("NOCREATEROLE", sql)
        self.assertIn("CREATE DATABASE app OWNER app", sql)

    def test_listens_only_on_the_unix_socket(self):
        instance = self.broker().create("17")
        with open(
            os.path.join(self.root, "data", instance["id"], "postgresql.conf")
        ) as f:
            conf = f.read()
        self.assertIn("listen_addresses = ''\n", conf)
        self.assertIn(f"unix_socket_directories = '{instance['socket_dir']}'\n", conf)

    def test_unknown_version_is_rejected_without_running_anything(self):
        runner = FakeRunner()
        with self.assertRaises(pg_broker.BrokerError) as ctx:
            self.broker(runner=runner).create("16")
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(runner.calls, [])

    def test_fifth_instance_is_rejected(self):
        runner = FakeRunner()
        broker = self.broker(runner=runner)
        running = [broker.create("17") for _ in range(4)]
        with self.assertRaises(pg_broker.BrokerError) as ctx:
            broker.create("17")
        self.assertEqual(ctx.exception.status, 429)
        self.assertEqual(runner.steps().count("initdb"), 4)
        broker.delete(running[0]["id"])
        broker.create("17")

    def test_failed_start_cleans_up_and_frees_the_slot(self):
        for step in ("initdb", "bootstrap", "pg_ctl start"):
            broker = self.broker(runner=FakeRunner(fail=step))
            with self.assertRaises(pg_broker.BrokerError) as ctx:
                broker.create("17")
            self.assertEqual(ctx.exception.status, 500)
            self.assertIn(f"FATAL: {step} broke", str(ctx.exception))
            self.assertEqual(os.listdir(os.path.join(self.root, "data")), [])
            self.assertEqual(os.listdir(os.path.join(self.root, "sock")), [])
        broker = self.broker()
        for _ in range(4):
            broker.create("17")


class LifecycleTest(TempRootMixin, unittest.TestCase):
    def assert_gone(self, instance_id):
        self.assertFalse(os.path.exists(os.path.join(self.root, "data", instance_id)))
        self.assertFalse(os.path.exists(os.path.join(self.root, "sock", instance_id)))

    def test_delete_stops_and_removes(self):
        runner = FakeRunner()
        broker = self.broker(runner=runner)
        instance = broker.create("17")
        broker.delete(instance["id"])
        self.assertEqual(runner.steps()[-1], "pg_ctl stop")
        self.assertIn("immediate", runner.argv_of("pg_ctl stop")[0])
        self.assert_gone(instance["id"])
        with self.assertRaises(pg_broker.BrokerError) as ctx:
            broker.delete(instance["id"])
        self.assertEqual(ctx.exception.status, 404)

    def test_expired_instances_are_reaped(self):
        clock = FakeClock()
        runner = FakeRunner()
        broker = self.broker(runner=runner, clock=clock, ttl_seconds=60)
        old = broker.create("17")
        clock.now += 30
        young = broker.create("17")
        clock.now += 31
        self.assertEqual(broker.reap_expired(), [old["id"]])
        self.assert_gone(old["id"])
        self.assertTrue(os.path.isdir(young["socket_dir"]))
        self.assertEqual(runner.steps().count("pg_ctl stop"), 1)
        clock.now += 30
        self.assertEqual(broker.reap_expired(), [young["id"]])
        self.assert_gone(young["id"])
        # 枠が空いている
        for _ in range(4):
            broker.create("17")

    def test_restart_removes_the_previous_runs_clusters(self):
        before = self.broker()
        left = [before.create("17") for _ in range(2)]
        orphan_socket = os.path.join(self.root, "sock", "0123456789ab")
        os.makedirs(orphan_socket)

        runner = FakeRunner()
        after = self.broker(runner=runner)
        removed = after.cleanup_leftovers()
        self.assertEqual(
            sorted(removed), sorted([i["id"] for i in left] + ["0123456789ab"])
        )
        self.assertEqual(runner.steps(), ["pg_ctl stop", "pg_ctl stop"])
        for instance in left:
            self.assert_gone(instance["id"])
        self.assertFalse(os.path.exists(orphan_socket))
        for _ in range(4):
            after.create("17")

    def test_stop_all_removes_everything(self):
        broker = self.broker()
        for _ in range(3):
            broker.create("17")
        broker.stop_all()
        self.assertEqual(os.listdir(os.path.join(self.root, "data")), [])
        self.assertEqual(os.listdir(os.path.join(self.root, "sock")), [])


def read_all(sock):
    sock.settimeout(60)
    chunks = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def request(method, path, body=b""):
    return (
        f"{method} {path} HTTP/1.1\r\nHost: pg-broker\r\n"
        f"Content-Length: {len(body)}\r\n\r\n".encode()
        + body
    )


def parse_response(raw):
    head, _, payload = raw.partition(b"\r\n\r\n")
    return int(head.split()[1]), json.loads(payload)


class HandlerTest(TempRootMixin, unittest.TestCase):
    """socketpair の片側で Handler を動かし、もう片側から生の HTTP を流す。"""

    def exchange(self, broker, raw):
        client, server_side = socket.socketpair()

        def run():
            pg_broker.Handler(server_side, "", SimpleNamespace(broker=broker))
            server_side.close()

        thread = threading.Thread(target=run)
        thread.start()
        client.sendall(raw)
        response = read_all(client)
        thread.join(5)
        client.close()
        return parse_response(response)

    def test_post_creates_an_instance(self):
        broker = self.broker()
        status, body = self.exchange(broker, request("POST", "/instances"))
        self.assertEqual(status, 201)
        self.assertEqual(set(body), {"id", "database_url", "socket_dir", "expires_at"})
        status, body = self.exchange(
            broker, request("POST", "/instances", b'{"version":"17"}')
        )
        self.assertEqual(status, 201)

    def test_post_without_content_length_is_the_default_version(self):
        status, _ = self.exchange(
            self.broker(), b"POST /instances HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        self.assertEqual(status, 201)

    def test_post_with_settings_is_400(self):
        runner = FakeRunner()
        status, body = self.exchange(
            self.broker(runner=runner),
            request("POST", "/instances", b'{"version":"17","port":5432}'),
        )
        self.assertEqual(status, 400)
        self.assertIn("only 'version'", body["error"])
        self.assertEqual(runner.calls, [])

    def test_fifth_post_is_429(self):
        broker = self.broker()
        for _ in range(4):
            self.assertEqual(
                self.exchange(broker, request("POST", "/instances"))[0], 201
            )
        status, body = self.exchange(broker, request("POST", "/instances"))
        self.assertEqual(status, 429)
        self.assertIn("4 instances", body["error"])

    def test_delete(self):
        broker = self.broker()
        _, created = self.exchange(broker, request("POST", "/instances"))
        status, body = self.exchange(
            broker, request("DELETE", f"/instances/{created['id']}")
        )
        self.assertEqual((status, body), (200, {"id": created["id"], "deleted": True}))
        status, _ = self.exchange(
            broker, request("DELETE", f"/instances/{created['id']}")
        )
        self.assertEqual(status, 404)

    def test_delete_rejects_ids_that_are_not_ours(self):
        broker = self.broker()
        for path in ("/instances/../../data", "/instances/", "/instances/ZZZZZZZZZZZZ"):
            status, _ = self.exchange(broker, request("DELETE", path))
            self.assertEqual(status, 404, path)

    def test_unknown_path_and_get(self):
        broker = self.broker()
        self.assertEqual(self.exchange(broker, request("POST", "/sql"))[0], 404)
        self.assertEqual(self.exchange(broker, request("GET", "/instances"))[0], 405)


class SandboxSettingsTest(unittest.TestCase):
    """claude-code/settings.json の sandbox 設定が pg-broker の前提と合っているか。"""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, "claude-code", "settings.json")) as f:
            cls.sandbox = json.load(f)["sandbox"]

    def test_broker_and_instance_sockets_are_reachable(self):
        sockets = self.sandbox["network"]["allowUnixSockets"]
        for suffix in (
            "/.local/state/pg-broker/broker.sock",
            "/.local/state/pg-broker/sock",
        ):
            self.assertTrue(
                any(entry.endswith(suffix) for entry in sockets), (suffix, sockets)
            )

    def test_state_dir_is_not_writable_from_the_sandbox(self):
        state = "/HOME/.local/state/pg-broker/sock/x"
        for entry in self.sandbox["filesystem"]["allowWrite"]:
            if not entry.startswith("~/"):
                continue
            prefix = "/HOME/" + entry[2:].removesuffix("/**")
            self.assertFalse(
                state == prefix or state.startswith(prefix.rstrip("/") + "/"), entry
            )


def short_tempdir():
    # Postgres のソケットパスは 103 バイトまで。/var/folders/... の TMPDIR だと際どいので /tmp を先に試す
    try:
        return tempfile.mkdtemp(prefix="pgb-", dir="/tmp")
    except OSError:
        return tempfile.mkdtemp(prefix="pgb-")


def find_postgres_17():
    pg_ctl = shutil.which("pg_ctl")
    if pg_ctl is None:
        return None
    bin_dir = os.path.dirname(os.path.realpath(pg_ctl))
    version = subprocess.run(
        [pg_ctl, "--version"], capture_output=True, text=True, check=False
    ).stdout
    if not bin_dir.startswith(pg_broker.NIX_STORE) or " 17." not in version:
        return None
    return bin_dir


class PostgresIntegrationTest(unittest.TestCase):
    """実際に Postgres 17 を起動し、HTTP over Unix socket から psql での接続までを通す。"""

    @classmethod
    def setUpClass(cls):
        cls.bin_dir = find_postgres_17()
        if cls.bin_dir is None:
            raise unittest.SkipTest("nix store の Postgres 17 が PATH に無い")
        cls.root = short_tempdir()
        cls.stderr = io.StringIO()
        cls.broker = pg_broker.Broker(cls.root, {"17": cls.bin_dir})
        cls.broker.prepare()
        cls.socket_path = os.path.join(cls.root, "broker.sock")
        cls.server = pg_broker.Server(cls.socket_path, pg_broker.Handler)
        cls.server.broker = cls.broker
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        with redirect_stderr(cls.stderr):
            status, body = cls.http("POST", "/instances", b'{"version":"17"}')
        if status == 500 and "shmget" in body["error"]:
            cls.tearDownClass()
            raise unittest.SkipTest(
                "共有メモリが使えない（Claude の sandbox 内では shmget が EPERM）"
            )
        assert status == 201, (status, body)
        cls.instance = body

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        with redirect_stderr(cls.stderr):
            cls.broker.stop_all()
        shutil.rmtree(cls.root, ignore_errors=True)

    @classmethod
    def http(cls, method, path, body=b""):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(cls.socket_path)
            client.sendall(request(method, path, body))
            return parse_response(read_all(client))

    def psql(self, conninfo, sql):
        return subprocess.run(
            [
                os.path.join(self.bin_dir, "psql"),
                "-X",
                "-q",
                "-At",
                "-v",
                "ON_ERROR_STOP=1",
            ]
            + ["-d", conninfo, "-c", sql],
            capture_output=True,
            text=True,
            env=pg_broker.CHILD_ENV,
            timeout=60,
            check=False,
        )

    def test_app_can_create_table_and_insert(self):
        result = self.psql(
            self.instance["database_url"],
            "CREATE TABLE t (id int); INSERT INTO t VALUES (1), (2); "
            "SELECT count(*) FROM t",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2")
        result = self.psql(
            self.instance["database_url"],
            "SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user",
        )
        self.assertEqual(result.stdout.strip(), "app|f")

    def test_server_side_escapes_are_denied(self):
        for sql in (
            "COPY (SELECT 1) TO PROGRAM 'touch /tmp/pg-broker-escaped'",
            "SELECT pg_read_file('postgresql.conf')",
            "CREATE EXTENSION file_fdw",
            "ALTER SYSTEM SET work_mem = '64MB'",
        ):
            result = self.psql(self.instance["database_url"], sql)
            self.assertNotEqual(result.returncode, 0, sql)
            self.assertIn("permission denied", result.stderr, sql)

    def test_superuser_is_rejected_on_the_socket(self):
        host = self.instance["socket_dir"]
        for user, dbname in (
            ("postgres", "postgres"),
            ("postgres", "app"),
            ("app", "postgres"),
        ):
            result = self.psql(f"host={host} user={user} dbname={dbname}", "SELECT 1")
            self.assertNotEqual(result.returncode, 0, (user, dbname))
            self.assertIn("pg_hba.conf rejects connection", result.stderr)

    @staticmethod
    def postmaster_pid(root, instance):
        data_dir = os.path.join(root, "data", instance["id"])
        with open(os.path.join(data_dir, "postmaster.pid")) as f:
            return data_dir, int(f.readline())

    def wait_exit(self, pid):
        for _ in range(100):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        self.fail(f"postmaster {pid} is still running")

    def test_ttl_and_restart_stop_running_clusters(self):
        # setUpClass の instance を巻き込まないよう、別の root で broker を動かす
        root = short_tempdir()
        self.addCleanup(shutil.rmtree, root, True)
        clock = FakeClock(time.time())
        with redirect_stderr(self.stderr):
            broker = pg_broker.Broker(
                root, {"17": self.bin_dir}, ttl_seconds=5, clock=clock
            )
            broker.prepare()
            self.addCleanup(broker.stop_all)
            expiring = broker.create("17")
            data_dir, pid = self.postmaster_pid(root, expiring)
            clock.now += 6
            self.assertEqual(broker.reap_expired(), [expiring["id"]])
        self.wait_exit(pid)
        self.assertFalse(os.path.exists(data_dir))
        self.assertNotEqual(
            self.psql(expiring["database_url"], "SELECT 1").returncode, 0
        )

        with redirect_stderr(self.stderr):
            left = broker.create("17")
            data_dir, pid = self.postmaster_pid(root, left)
            restarted = pg_broker.Broker(root, {"17": self.bin_dir})
            self.assertEqual(restarted.cleanup_leftovers(), [left["id"]])
        self.wait_exit(pid)
        self.assertFalse(os.path.exists(data_dir))
        self.assertFalse(os.path.exists(left["socket_dir"]))


if __name__ == "__main__":
    unittest.main()
