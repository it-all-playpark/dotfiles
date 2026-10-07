"""pg_broker_client のテスト。

実行: python3 -m unittest pg_broker_client_test（tests/pg-broker.test.sh から呼ぶ）

本物の pg_broker.Server を一時ディレクトリの Unix ソケットで立て、Postgres の起動は
pg_broker_test.FakeRunner が受ける。Claude の sandbox 内では、一時ディレクトリが
allowUnixSockets に入っている $TMPDIR の下にできるので bind / connect できる。
"""

import fnmatch
import io
import json
import os
import shutil
import tempfile
import threading
import unittest
from contextlib import redirect_stderr

import pg_broker
import pg_broker_client
from pg_broker_test import BIN, REPO_ROOT, FakeClock, FakeRunner


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="pgbc-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.broker_stderr = io.StringIO()
        redirect = redirect_stderr(self.broker_stderr)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.broker = pg_broker.Broker(
            self.root, {"17": BIN}, runner=FakeRunner(), clock=FakeClock()
        )
        self.broker.prepare()
        self.socket_path = os.path.join(self.root, "broker.sock")
        self.server = pg_broker.Server(self.socket_path, pg_broker.Handler)
        self.server.broker = self.broker
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def run_client(self, *argv, socket_path=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        code = pg_broker_client.main(
            ["--socket", socket_path or self.socket_path, *argv], stdout, stderr
        )
        return code, stdout.getvalue(), stderr.getvalue()

    def test_create_prints_the_instance_and_delete_removes_it(self):
        code, out, err = self.run_client("create")
        self.assertEqual((code, err), (0, ""))
        instance = json.loads(out)
        self.assertEqual(
            set(instance), {"id", "database_url", "socket_dir", "expires_at"}
        )
        self.assertTrue(instance["database_url"].startswith("postgresql://app@"))
        self.assertTrue(os.path.isdir(instance["socket_dir"]))

        code, out, err = self.run_client("delete", instance["id"])
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"id": instance["id"], "deleted": True})
        self.assertFalse(os.path.exists(instance["socket_dir"]))

    def test_create_passes_the_version(self):
        code, _, err = self.run_client("create", "--version", "16")
        self.assertEqual(code, 1)
        self.assertIn("(HTTP 400)", err)
        self.assertIn("16", err)

    def test_broker_errors_exit_1_with_the_message(self):
        for _ in range(pg_broker.MAX_INSTANCES):
            self.assertEqual(self.run_client("create")[0], 0)
        code, out, err = self.run_client("create")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("(HTTP 429)", err)
        self.assertIn("pg-broker:", err)

    def test_unknown_id_is_reported(self):
        code, _, err = self.run_client("delete", "0123456789ab")
        self.assertEqual(code, 1)
        self.assertIn("(HTTP 404)", err)

    def test_malformed_id_is_rejected_before_calling_the_broker(self):
        code, out, err = self.run_client("delete", "../../etc")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("invalid instance id", err)

    def test_unreachable_broker_names_the_launch_agent(self):
        missing = os.path.join(self.root, "missing.sock")
        code, out, err = self.run_client("create", socket_path=missing)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("com.playpark.pg-broker", err)


class PermissionsTest(unittest.TestCase):
    """claude-code/settings.json の permissions で、エージェントがこのクライアントを使えるか。"""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, "claude-code", "settings.json")) as f:
            cls.deny = [
                rule[len("Bash(") : -1]
                for rule in json.load(f)["permissions"]["deny"]
                if rule.startswith("Bash(") and rule.endswith(")")
            ]

    def denied(self, command):
        return [p for p in self.deny if fnmatch.fnmatchcase(command, p)]

    def test_client_commands_are_not_denied(self):
        for command in ("pg-broker create", "pg-broker delete 0123456789ab"):
            self.assertEqual(self.denied(command), [], command)

    def test_curl_stays_denied(self):
        # このクライアントがある理由。curl の deny を外して済ませない
        command = "curl --unix-socket ~/.local/state/pg-broker/broker.sock -X POST http://pg-broker/instances"
        self.assertNotEqual(self.denied(command), [])


if __name__ == "__main__":
    unittest.main()
