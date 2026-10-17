"""docker_proxy のテスト。

実行: python3 -m unittest docker_proxy_test（tests/docker-proxy.test.sh から呼ぶ）

実 docker は使わない。上流の docker.sock は StubUpstream（一時ディレクトリの Unix ソケット）が
受け、届いたリクエストを記録して決めた応答を返す。Claude の sandbox 内では、一時ディレクトリが
allowUnixSockets に入っている $TMPDIR/sock の下にできるので bind / connect できる。
"""

import io
import json
import os
import re
import shutil
import socket
import socketserver
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace

import docker_proxy

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
)
SECRET = "AWS_SECRET_ACCESS_KEY=do-not-leak"


def socket_tempdir(prefix):
    # Claude の sandbox は $TMPDIR/sock の下でだけ Unix socket の bind / connect を許す
    # （claude-code/settings.json の allowUnixSockets）。sandbox 外では普通の一時ディレクトリになる
    parent = os.path.join(tempfile.gettempdir(), "sock")
    os.makedirs(parent, exist_ok=True)
    return tempfile.mkdtemp(prefix=prefix, dir=parent)


def read_all(sock):
    sock.settimeout(60)
    chunks = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def request(method, target, headers=(), body=b""):
    lines = [f"{method} {target} HTTP/1.1", "Host: api.moby.localhost", *headers]
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


def parse_response(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    return int(lines[0].split()[1]), headers, body


def http_response(body, content_type="application/json", chunked=False):
    if chunked:
        middle = len(body) // 2
        framed = b"".join(
            f"{len(part):x}\r\n".encode() + part + b"\r\n"
            for part in (body[:middle], body[middle:])
        )
        return (
            (
                f"HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\n"
                "Transfer-Encoding: chunked\r\n\r\n"
            ).encode()
            + framed
            + b"0\r\n\r\n"
        )
    return (
        f"HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode() + body


class StubUpstream:
    """docker.sock の代わり。受けたリクエストを丸ごと記録し、response を返して切る。"""

    def __init__(self, response=None):
        self.root = socket_tempdir("dpx-")
        self.path = os.path.join(self.root, "docker.sock")
        self.response = response or http_response(b"{}")
        self.received = []
        stub = self

        class StubHandler(socketserver.BaseRequestHandler):
            def handle(self):
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = self.request.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                stub.received.append(data)
                self.request.sendall(stub.response)

        self.server = socketserver.UnixStreamServer(self.path, StubHandler)
        threading.Thread(
            target=self.server.serve_forever, args=(0.05,), daemon=True
        ).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.root, ignore_errors=True)


class ProxyTestCase(unittest.TestCase):
    def setUp(self):
        self.stderr = io.StringIO()
        redirect = redirect_stderr(self.stderr)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.upstream = StubUpstream()
        self.addCleanup(self.upstream.close)

    def exchange(self, raw):
        """socketpair の片側で Handler を動かし、もう片側から生の HTTP を 1 回で流す。"""
        client, server_side = socket.socketpair()
        # 送ってから Handler を動かす（最初の recv で全部が届いている状態にする）
        client.sendall(raw)

        def run():
            docker_proxy.Handler(
                server_side, "", SimpleNamespace(upstream=self.upstream.path)
            )
            server_side.close()

        thread = threading.Thread(target=run)
        thread.start()
        response = read_all(client)
        thread.join(5)
        client.close()
        return parse_response(response)

    def assert_relayed(self, raw, target):
        before = len(self.upstream.received)
        status, headers, body = self.exchange(raw)
        self.assertEqual(status, 200, (raw, body))
        self.assertEqual(len(self.upstream.received), before + 1, raw)
        sent = self.upstream.received[-1].decode("latin-1")
        self.assertTrue(sent.startswith(f"GET {target} HTTP/1.1\r\n"), sent)
        return status, headers, body

    def assert_rejected(self, raw, status=403):
        got, headers, body = self.exchange(raw)
        self.assertEqual(got, status, (raw, body))
        self.assertIn("docker-proxy:", json.loads(body)["message"])
        self.assertEqual(headers["connection"], ["close"])
        self.assertEqual(self.upstream.received, [], raw)


class AllowlistTest(ProxyTestCase):
    def test_read_only_routes_are_relayed(self):
        for path in (
            "/_ping",
            "/version",
            "/info",
            "/containers/json?all=1&filters=%7B%22name%22%3A%5B%22web%22%5D%7D",
            "/containers/web-1/json?size=1",
            "/containers/0123abcd/logs?stdout=1&stderr=1&tail=100",
            "/containers/web_1/stats?stream=0",
            "/containers/web.1/top?ps_args=aux",
            "/images/json",
            "/images/nginx/json",
            "/images/ghcr.io/acme/app:1.0/json",
            "/images/sha256:0123abcd/json",
            "/system/df",
        ):
            for target in (path, f"/v1.47{path}"):
                with self.subTest(target=target):
                    self.assert_relayed(request("GET", target), target)

    def test_head_is_relayed(self):
        self.upstream.response = b"HTTP/1.1 200 OK\r\nApi-Version: 1.47\r\n\r\n"
        status, headers, body = self.exchange(request("HEAD", "/_ping"))
        self.assertEqual((status, headers["api-version"], body), (200, ["1.47"], b""))
        sent = self.upstream.received[0].decode("latin-1")
        self.assertTrue(sent.startswith("HEAD /_ping HTTP/1.1\r\n"), sent)

    def test_write_and_unlisted_endpoints_are_403_without_contacting_upstream(self):
        for method, target in (
            ("POST", "/containers/create"),
            ("POST", "/v1.47/containers/create?name=x"),
            ("POST", "/containers/web/exec"),
            ("GET", "/exec/0123/json"),
            ("POST", "/exec/0123/start"),
            ("GET", "/containers/web/archive?path=/etc"),
            ("PUT", "/containers/web/archive?path=/"),
            ("HEAD", "/containers/web/archive?path=/"),
            ("GET", "/containers/web/export"),
            ("POST", "/containers/web/attach?stream=1"),
            ("GET", "/containers/web/attach/ws"),
            ("POST", "/containers/web/start"),
            ("DELETE", "/containers/web"),
            ("GET", "/grpc"),
            ("POST", "/grpc"),
            ("POST", "/session"),
            ("POST", "/build"),
            ("POST", "/images/create?fromImage=alpine"),
            ("GET", "/images/alpine/get"),
            ("GET", "/events"),
            ("GET", "/volumes"),
            ("POST", "/_ping"),
            ("PUT", "/containers/json"),
            ("OPTIONS", "/info"),
            ("GET", "/v1.47/containers/web/json/extra"),
            ("GET", "/containers/json/../create"),
            ("GET", "http://docker/containers/json"),
        ):
            with self.subTest(method=method, target=target):
                self.assert_rejected(request(method, target))


class StreamingTest(ProxyTestCase):
    def test_logs_with_follow_is_403(self):
        for query in (
            "follow=1",
            "follow=true",
            "follow=yes",
            "follow=TRUE",
            "follow=%31",
            "stdout=1&follow=0&follow=1",
        ):
            with self.subTest(query=query):
                self.assert_rejected(request("GET", f"/containers/web/logs?{query}"))

    def test_logs_without_follow_is_relayed(self):
        for query in ("stdout=1", "follow=0", "follow=false", "follow="):
            target = f"/v1.47/containers/web/logs?{query}"
            with self.subTest(query=query):
                self.assert_relayed(request("GET", target), target)

    def test_stats_unless_stream_is_false_is_403(self):
        for query in (
            "",
            "?one-shot=1",
            "?stream=1",
            "?stream=true",
            "?stream=0&stream=1",
        ):
            with self.subTest(query=query):
                self.assert_rejected(request("GET", f"/containers/web/stats{query}"))

    def test_stats_with_stream_false_is_relayed(self):
        for query in ("stream=0", "stream=false", "stream=0&one-shot=1"):
            target = f"/v1.47/containers/web/stats?{query}"
            with self.subTest(query=query):
                self.assert_relayed(request("GET", target), target)

    def test_top_with_ps_args_outside_the_allowlist_is_403(self):
        for query in (
            "ps_args=auxe",
            "ps_args=-ef%20e",
            "ps_args=-efe",
            "ps_args=aux&ps_args=auxe",
            "ps_args=-o%20pid,command",
        ):
            with self.subTest(query=query):
                self.assert_rejected(request("GET", f"/containers/web/top?{query}"))

    def test_top_with_allowed_ps_args_is_relayed(self):
        for query in ("", "?ps_args=-ef", "?ps_args=aux", "?ps_args=-ef&ps_args=aux"):
            target = f"/v1.47/containers/web/top{query}"
            with self.subTest(query=query):
                self.assert_relayed(request("GET", target), target)

    def test_relayed_body_is_passed_through(self):
        payload = b"\x01\x00\x00\x00\x00\x00\x00\x05hello"
        self.upstream.response = (
            b"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream"
            b"\r\nConnection: keep-alive\r\n\r\n" + payload
        )
        _, headers, body = self.exchange(
            request("GET", "/containers/web/logs?stdout=1")
        )
        self.assertEqual(body, payload)
        self.assertEqual(headers["connection"], ["close"])


class InspectEnvTest(ProxyTestCase):
    def inspect(self, path, payload, chunked):
        self.upstream.response = http_response(
            json.dumps(payload).encode(), chunked=chunked
        )
        _, headers, body = self.assert_relayed(request("GET", path), path)
        self.assertNotIn(SECRET.encode(), body)
        self.assertNotIn("transfer-encoding", headers)
        self.assertEqual(headers["content-length"], [str(len(body))])
        return json.loads(body)

    def test_container_inspect_drops_config_env(self):
        payload = {
            "Id": "0123abcd",
            "Name": "/web",
            "Config": {"Image": "nginx", "Env": [SECRET, "PATH=/usr/bin"]},
            "HostConfig": {"Binds": None},
        }
        for chunked in (False, True):
            with self.subTest(chunked=chunked):
                got = self.inspect("/v1.47/containers/web/json", payload, chunked)
                self.assertEqual(got["Config"], {"Image": "nginx"})
                self.assertEqual(got["Name"], "/web")
                self.assertEqual(got["HostConfig"], {"Binds": None})

    def test_image_inspect_drops_config_env(self):
        payload = {
            "Id": "sha256:0123",
            "RepoTags": ["ghcr.io/acme/app:1.0"],
            "Config": {"Cmd": ["serve"], "Env": [SECRET]},
        }
        for chunked in (False, True):
            with self.subTest(chunked=chunked):
                got = self.inspect(
                    "/images/ghcr.io/acme/app:1.0/json", payload, chunked
                )
                self.assertEqual(got["Config"], {"Cmd": ["serve"]})
                self.assertEqual(got["RepoTags"], ["ghcr.io/acme/app:1.0"])

    def test_inspect_that_is_not_json_is_not_returned(self):
        self.upstream.response = http_response(f"Env: {SECRET}".encode(), "text/plain")
        status, _, body = self.exchange(request("GET", "/containers/web/json"))
        self.assertEqual(status, 502)
        self.assertNotIn(SECRET.encode(), body)


class OneRequestPerConnectionTest(ProxyTestCase):
    def test_responses_close_the_connection(self):
        self.upstream.response = (
            b"HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\n"
            b"Content-Length: 2\r\n\r\nOK"
        )
        _, headers, _ = self.assert_relayed(request("GET", "/_ping"), "/_ping")
        self.assertEqual(headers["connection"], ["close"])
        self.assertNotIn("keep-alive", headers)
        sent = self.upstream.received[0].decode("latin-1")
        self.assertIn("\r\nConnection: close\r\n", sent)

    def test_upgrade_is_403(self):
        for target in ("/_ping", "/containers/web/logs?stdout=1"):
            with self.subTest(target=target):
                self.assert_rejected(
                    request("GET", target, ["Connection: Upgrade", "Upgrade: tcp"])
                )

    def test_request_bodies_are_403(self):
        for raw in (
            request(
                "GET",
                "/info",
                ["Transfer-Encoding: chunked", "Content-Length: 5"],
                b"0\r\n\r\n",
            ),
            request(
                "GET", "/info", ["Content-Length: 5", "Transfer-Encoding: chunked"]
            ),
            request("GET", "/info", ["Transfer-Encoding: chunked"], b"0\r\n\r\n"),
            request("GET", "/info", ["Content-Length: 2"], b"{}"),
            request("GET", "/info", ["Content-Length: 2"]),
            request("GET", "/info", [], b"{}"),
        ):
            with self.subTest(raw=raw):
                self.assert_rejected(raw)

    def test_encoded_and_traversing_paths_are_403(self):
        for target in (
            "/containers/web%2ejson",
            "/containers/web%2Ejson",
            "/containers%2fjson",
            "/containers%2Fjson",
            "/images/%2e%2e/json",
            "/containers//json",
            "//containers/json",
            "/v1.47//containers/json",
            "/images/../containers/create/json",
            "/images/a/../b/json",
        ):
            with self.subTest(target=target):
                self.assert_rejected(request("GET", target))

    def test_second_request_on_the_same_write_is_403(self):
        raw = request("GET", "/_ping") + request(
            "POST", "/containers/create", ["Content-Length: 2"], b"{}"
        )
        self.assert_rejected(raw)

    def test_second_request_after_the_response_is_not_relayed(self):
        client, server_side = socket.socketpair()
        client.sendall(request("GET", "/_ping"))

        def run():
            docker_proxy.Handler(
                server_side, "", SimpleNamespace(upstream=self.upstream.path)
            )
            server_side.close()

        thread = threading.Thread(target=run)
        thread.start()
        first = read_all(client)
        try:
            client.sendall(request("POST", "/containers/create"))
            second = read_all(client)
        except OSError:
            second = b""
        thread.join(5)
        client.close()
        self.assertEqual(parse_response(first)[0], 200)
        self.assertEqual(second, b"")
        self.assertEqual(len(self.upstream.received), 1)
        self.assertTrue(self.upstream.received[0].startswith(b"GET /_ping "))

    def test_header_smuggling_with_bare_line_feeds_is_rejected(self):
        for raw in (
            b"GET /_ping HTTP/1.1\r\nHost: x\nContent-Length: 2\r\n\r\n",
            b"GET /_ping HTTP/1.1\r\nHost: x\rUpgrade: tcp\r\n\r\n",
            b"GET /_ping HTTP/1.1\r\n Upgrade: tcp\r\n\r\n",
        ):
            with self.subTest(raw=raw):
                self.assert_rejected(raw, status=400)


class ServerTest(unittest.TestCase):
    """main() と同じ組み立てで Unix ソケットを待ち受け、上流へ中継する。"""

    def test_listens_on_a_socket_and_relays_to_the_upstream(self):
        upstream = StubUpstream()
        self.addCleanup(upstream.close)
        root = socket_tempdir("dpx-listen-")
        self.addCleanup(shutil.rmtree, root, True)
        socket_path = os.path.join(root, "state", "docker.sock")
        docker_proxy.prepare_socket_path(socket_path)
        server = docker_proxy.Server(socket_path, docker_proxy.Handler)
        server.upstream = upstream.path
        threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.assertEqual(os.stat(os.path.dirname(socket_path)).st_mode & 0o777, 0o700)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(socket_path)
            client.sendall(request("GET", "/v1.47/version"))
            status, _, body = parse_response(read_all(client))
        self.assertEqual((status, body), (200, b"{}"))
        self.assertEqual(len(upstream.received), 1)

    def test_socket_paths_default_to_orbstack_and_the_state_dir(self):
        home = os.path.expanduser("~")
        self.assertEqual(
            docker_proxy.socket_paths({}),
            (
                f"{home}/.local/state/docker-proxy/docker.sock",
                f"{home}/.orbstack/run/docker.sock",
            ),
        )
        self.assertEqual(
            docker_proxy.socket_paths(
                {
                    "DOCKER_PROXY_SOCKET": "/s/proxy.sock",
                    "DOCKER_PROXY_UPSTREAM": "/s/docker.sock",
                }
            ),
            ("/s/proxy.sock", "/s/docker.sock"),
        )


class WiringTest(unittest.TestCase):
    """待ち受けるソケットのパスが launchd agent・docker-sb・sandbox 設定で揃っているか。"""

    SOCKET = "/.local/state/docker-proxy/docker.sock"

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, "claude-code", "settings.json")) as f:
            sandbox = json.load(f)["sandbox"]
        cls.sockets = sandbox["network"]["allowUnixSockets"]
        cls.deny_read = sandbox["filesystem"]["denyRead"]
        programs = os.path.join(REPO_ROOT, "home-manager", "programs")
        with open(os.path.join(programs, "docker-proxy.nix")) as f:
            cls.nix = f.read()
        with open(os.path.join(programs, "default.nix")) as f:
            cls.imports = f.read()

    def test_proxy_socket_is_reachable_from_the_sandbox(self):
        self.assertIn("~" + self.SOCKET, self.sockets)
        self.assertEqual(docker_proxy.DEFAULT_SOCKET, "~" + self.SOCKET)

    def test_upstream_docker_socket_is_not_reachable_from_the_sandbox(self):
        for entry in self.sockets:
            self.assertFalse(
                entry.endswith("docker.sock") and not entry.endswith(self.SOCKET),
                entry,
            )
            self.assertNotIn("orbstack", entry)

    def test_orbstack_state_dir_is_not_readable_from_the_sandbox(self):
        # ~/.orbstack/ssh/id_ed25519 は OrbStack の ssh（127.0.0.1:32222。sandbox から TCP で届く）の鍵。
        # その先の Linux machine は Mac を /mnt/mac に mount しているので、読めれば sandbox の外に出る口になる
        self.assertIn("~/.orbstack/**", self.deny_read)

    def test_launchd_agent_and_docker_sb_use_the_proxy_socket(self):
        self.assertIn("./docker-proxy.nix", self.imports)
        self.assertIn(f'socket = "${{home}}{self.SOCKET}";', self.nix)
        self.assertIn("launchd.agents.docker-proxy", self.nix)
        self.assertIn("DOCKER_PROXY_SOCKET = socket;", self.nix)
        self.assertRegex(
            self.nix,
            re.compile(
                r'writeShellScriptBin "docker-sb" \'\'\s*'
                + re.escape('exec docker --host unix://${socket} "$@"')
            ),
        )


if __name__ == "__main__":
    unittest.main()
