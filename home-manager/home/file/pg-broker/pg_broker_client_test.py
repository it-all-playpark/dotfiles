"""pg_broker_client のテスト。

実行: python3 -m unittest pg_broker_client_test（tests/pg-broker.test.sh から呼ぶ）

docker-vm は PATH の先頭に置いた偽物（FAKE_DOCKER_VM）に差し替える。偽物は受けた引数を記録し、
コンテナの一覧を状態ファイルで持つ。sandbox-docker VM も Postgres も起動しない。
host 側の port の確認（bind / connect）は mock で差し替える。
"""

import calendar
import fnmatch
import io
import json
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

import pg_broker_client

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
)

FAKE_DOCKER_VM = """\
import hashlib, json, os, sys

state_path = os.environ["FAKE_DOCKER_STATE"]
with open(state_path) as f:
    state = json.load(f)
args = sys.argv[1:]
state["calls"].append(args)
code = 0

def value(flag):
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == flag]

if args[0] == "ps":
    containers = state["containers"]
    for spec in value("--filter"):
        key = spec.split("=", 1)[1]
        containers = [c for c in containers if key in c["labels"]]
    for c in containers:
        if value("--format") == ["{{.ID}}"]:
            print(c["id"] if "--no-trunc" in args else c["id"][:12])
        else:
            print(c["ports"])
elif args[0] == "run":
    cid = hashlib.sha256(str(len(state["calls"])).encode()).hexdigest()
    labels = {l.split("=", 1)[0]: "" for l in value("--label")}
    ports = ", ".join(f"0.0.0.0:{p.split(':')[0]}->5432/tcp" for p in value("-p"))
    state["containers"].append({"id": cid, "labels": labels, "ports": ports})
    print(cid)
elif args[0] == "exec":
    if state["not_ready"] > 0:
        state["not_ready"] -= 1
        code = 2
elif args[0] == "rm":
    before = len(state["containers"])
    state["containers"] = [c for c in state["containers"] if c["id"] != args[-1]]
    if len(state["containers"]) == before:
        sys.stderr.write("Error response from daemon: No such container\\n")
        code = 1
else:
    sys.stderr.write(f"fake docker-vm: unexpected {args}\\n")
    code = 125
with open(state_path, "w") as f:
    json.dump(state, f)
sys.exit(code)
"""

LABELED = "a" * 64
UNLABELED = "b" * 64


class PgBrokerTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="pgb-")
        self.addCleanup(shutil.rmtree, self.root, True)
        bin_dir = os.path.join(self.root, "bin")
        os.mkdir(bin_dir)
        fake = os.path.join(bin_dir, "docker-vm")
        with open(fake, "w") as f:
            f.write(f"#!{sys.executable} -I\n{FAKE_DOCKER_VM}")
        os.chmod(fake, 0o755)
        self.state_path = os.path.join(self.root, "state.json")
        self.write_state([])
        env = {
            "PATH": bin_dir + os.pathsep + os.environ.get("PATH", ""),
            "FAKE_DOCKER_STATE": self.state_path,
        }
        for patcher in (
            mock.patch.dict(os.environ, env),
            mock.patch.object(pg_broker_client, "port_free", lambda port: True),
            mock.patch.object(pg_broker_client, "host_port_open", lambda port: True),
            mock.patch.object(pg_broker_client, "POLL_SECONDS", 0),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_state(self, containers, not_ready=0):
        with open(self.state_path, "w") as f:
            json.dump(
                {"containers": containers, "calls": [], "not_ready": not_ready}, f
            )

    def state(self):
        with open(self.state_path) as f:
            return json.load(f)

    def calls(self, command):
        return [c for c in self.state()["calls"] if c[0] == command]

    def run_cli(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        code = pg_broker_client.main(list(argv), stdout, stderr)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_create_runs_the_pinned_image_and_prints_one_json_line(self):
        before = time.time()
        code, out, err = self.run_cli("create")
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(out.endswith("\n") and out.count("\n") == 1, out)
        instance = json.loads(out)
        self.assertEqual(set(instance), {"id", "database_url", "expires_at"})
        match = re.fullmatch(
            r"postgresql://app:([0-9a-f]{32})@127\.0\.0\.1:(\d+)/app",
            instance["database_url"],
        )
        self.assertIsNotNone(match, instance["database_url"])
        password, port = match.group(1), match.group(2)
        self.assertEqual(port, "5500")

        image = pg_broker_client.IMAGES["17"]
        self.assertRegex(image, r"^postgres:17-alpine@sha256:[0-9a-f]{64}$")
        [run] = self.calls("run")
        self.assertEqual(
            run,
            [
                "run", "-d", "--rm",
                "--label", "pg-broker",
                "-p", "5500:5432",
                "-e", "POSTGRES_USER=app",
                "-e", f"POSTGRES_PASSWORD={password}",
                "-e", "POSTGRES_DB=app",
                "--entrypoint", "timeout",
                image,
                "-s", "INT", "-k", "30", "5400",
                "docker-entrypoint.sh", "postgres",
            ],
        )  # fmt: skip
        [container] = self.state()["containers"]
        self.assertEqual(instance["id"], container["id"][:12])
        expires = calendar.timegm(
            time.strptime(instance["expires_at"], "%Y-%m-%dT%H:%M:%SZ")
        )
        self.assertLessEqual(int(before) + 90 * 60 - 1, expires)
        self.assertLessEqual(expires, time.time() + 90 * 60)

    def test_create_accepts_version_17(self):
        code, _, err = self.run_cli("create", "--version", "17")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(len(self.calls("run")), 1)

    def test_unsupported_version_fails_without_starting_anything(self):
        for version in ("16", "18", "latest", "17-alpine"):
            code, out, err = self.run_cli("create", "--version", version)
            self.assertEqual((code, out), (1, ""), version)
            self.assertIn("unsupported version", err)
        self.assertEqual(self.calls("run"), [])

    def test_image_settings_and_sql_are_not_accepted(self):
        for argv in (
            ["create", "--image", "postgres:latest"],
            ["create", "-c", "shared_preload_libraries=x"],
            ["create", "--version", "17", "SELECT 1"],
            ["create", "-e", "POSTGRES_HOST_AUTH_METHOD=trust"],
        ):
            with (
                self.assertRaises(SystemExit) as ctx,
                mock.patch.object(sys, "stderr", io.StringIO()),
            ):
                self.run_cli(*argv)
            self.assertNotEqual(ctx.exception.code, 0, argv)
        self.assertEqual(self.state()["calls"], [])

    def test_port_skips_published_and_bound_ports(self):
        self.write_state(
            [
                {
                    "id": UNLABELED,
                    "labels": {},
                    "ports": "0.0.0.0:5500->80/tcp, [::]:5500->80/tcp",
                }
            ]
        )
        with mock.patch.object(
            pg_broker_client, "port_free", lambda port: port != 5501
        ):
            code, out, err = self.run_cli("create")
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(json.loads(out)["database_url"].endswith("@127.0.0.1:5502/app"))
        [run] = self.calls("run")
        self.assertEqual(run[run.index("-p") + 1], "5502:5432")

    def test_no_free_port_in_range_fails(self):
        with mock.patch.object(
            pg_broker_client, "port_free", lambda port: not 5500 <= port <= 5599
        ):
            code, out, err = self.run_cli("create")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("5500-5599", err)
        self.assertEqual(self.calls("run"), [])

    def test_fifth_create_fails_with_the_reason(self):
        for _ in range(4):
            self.assertEqual(self.run_cli("create")[0], 0)
        code, out, err = self.run_cli("create")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("max 4", err)
        self.assertEqual(len(self.calls("run")), 4)

    def test_unlabeled_containers_do_not_count_toward_the_limit(self):
        self.write_state(
            [{"id": f"{i:064x}", "labels": {}, "ports": ""} for i in range(4)]
        )
        self.assertEqual(self.run_cli("create")[0], 0)

    def test_create_waits_until_postgres_is_ready(self):
        self.write_state([], not_ready=3)
        code, _, err = self.run_cli("create")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(len(self.calls("exec")), 4)
        self.assertEqual(
            self.calls("exec")[0][2:],
            ["pg_isready", "-q", "-h", "127.0.0.1", "-U", "app", "-d", "app"],
        )

    def test_container_that_never_gets_ready_is_removed(self):
        self.write_state([], not_ready=10**6)
        with mock.patch.object(pg_broker_client, "READY_TIMEOUT_SECONDS", 0):
            code, out, err = self.run_cli("create")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("not ready", err)
        self.assertEqual(self.state()["containers"], [])
        self.assertEqual([c[:3] for c in self.calls("rm")], [["rm", "-f", "-v"]])

    def test_delete_removes_the_labeled_container(self):
        self.write_state(
            [
                {"id": LABELED, "labels": {"pg-broker": ""}, "ports": ""},
                {"id": UNLABELED, "labels": {}, "ports": ""},
            ]
        )
        code, out, err = self.run_cli("delete", LABELED[:12])
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"id": LABELED[:12], "deleted": True})
        self.assertEqual(self.calls("rm"), [["rm", "-f", "-v", LABELED]])
        self.assertEqual([c["id"] for c in self.state()["containers"]], [UNLABELED])

    def test_delete_refuses_unlabeled_containers(self):
        containers = [{"id": UNLABELED, "labels": {}, "ports": ""}]
        self.write_state(containers)
        for instance_id in (UNLABELED[:12], UNLABELED):
            code, out, err = self.run_cli("delete", instance_id)
            self.assertEqual((code, out), (1, ""), instance_id)
            self.assertIn("no pg-broker instance", err)
        self.assertEqual(self.calls("rm"), [])
        self.assertEqual(self.state()["containers"], containers)

    def test_delete_rejects_malformed_ids_before_calling_docker(self):
        for instance_id in ("../../etc", "abc", "pg-broker", "A" * 12):
            code, out, err = self.run_cli("delete", instance_id)
            self.assertEqual((code, out), (1, ""), instance_id)
            self.assertIn("invalid instance id", err)
        self.assertEqual(self.state()["calls"], [])


class SettingsTest(unittest.TestCase):
    """claude-code/settings.json が pg-broker の前提と合っているか。"""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, "claude-code", "settings.json")) as f:
            cls.settings = json.load(f)

    def test_no_pg_broker_socket_is_allowed(self):
        # docker-vm の docker.sock（sandbox-docker.test.sh が確かめる）だけで動く
        sockets = self.settings["sandbox"]["network"]["allowUnixSockets"]
        self.assertEqual([s for s in sockets if "pg-broker" in s], [])

    def test_commands_are_not_denied(self):
        deny = [
            rule[len("Bash(") : -1]
            for rule in self.settings["permissions"]["deny"]
            if rule.startswith("Bash(") and rule.endswith(")")
        ]
        for command in ("pg-broker create", "pg-broker delete 0123456789ab"):
            denied = [p for p in deny if fnmatch.fnmatchcase(command, p)]
            self.assertEqual(denied, [], command)


if __name__ == "__main__":
    unittest.main()
