"""jev_broker のテスト。ネットワーク・Keychain・ソケットファイルを使わない。

実行: python3 -m unittest jev_broker_test（tests/jev-broker.test.sh から呼ぶ）
"""

import io
import json
import socket
import subprocess
import threading
import unittest
import urllib.error
from contextlib import redirect_stderr
from types import SimpleNamespace

import jev_broker

SECRET = "vck_test-secret-0123456789"


class FakeKey:
    def __init__(self, key=SECRET, error=None):
        self.key = key
        self.error = error
        self.forgotten = 0

    def get(self):
        if self.error:
            raise jev_broker.KeyUnavailable(self.error)
        return self.key

    def forget(self):
        self.forgotten += 1


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    """urlopen の代わり。受け取った Request を記録し、決めた応答か例外を返す。"""

    def __init__(self, status=200, body=b'{"answers":{}}', raises=None):
        self.status = status
        self.body = body
        self.raises = raises
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        if self.raises:
            raise self.raises
        return FakeResponse(self.status, self.body)


def http_error(code, body=b'{"message":"nope"}'):
    return urllib.error.HTTPError(
        "https://example.invalid", code, "err", {}, io.BytesIO(body)
    )


class ForwardTest(unittest.TestCase):
    def call(self, body, key=None, opener=None):
        key = key or FakeKey()
        opener = opener or FakeOpener()
        status, payload = jev_broker.forward(
            body, key, opener, "https://upstream.invalid/x", 7
        )
        return status, payload, key, opener

    def test_forwards_with_fixed_model_and_bearer_key(self):
        body = json.dumps(
            {"model": "openai/gpt-5", "state": "s", "questions": {"q": {}}}
        ).encode()
        status, payload, _, opener = self.call(body)
        self.assertEqual(status, 200)
        self.assertEqual(payload, b'{"answers":{}}')
        request, timeout = opener.requests[0]
        self.assertEqual(timeout, 7)
        self.assertEqual(request.full_url, "https://upstream.invalid/x")
        self.assertEqual(request.get_header("Authorization"), f"Bearer {SECRET}")
        sent = json.loads(request.data)
        self.assertEqual(sent["model"], jev_broker.MODEL)
        self.assertEqual(sent["state"], "s")

    def test_rejects_non_json_without_calling_upstream(self):
        status, _, _, opener = self.call(b"not json")
        self.assertEqual(status, 400)
        self.assertEqual(opener.requests, [])

    def test_rejects_non_object_json(self):
        status, _, _, opener = self.call(b"[1,2]")
        self.assertEqual(status, 400)
        self.assertEqual(opener.requests, [])

    def test_key_unavailable_is_503_and_skips_upstream(self):
        key = FakeKey(error="keychain read failed (item 'x': security exit 36)")
        status, payload, _, opener = self.call(b"{}", key=key)
        self.assertEqual(status, 503)
        self.assertIn("security exit 36", json.loads(payload)["error"])
        self.assertEqual(opener.requests, [])

    def test_upstream_401_passes_through_and_forgets_key(self):
        status, payload, key, _ = self.call(
            b"{}", opener=FakeOpener(raises=http_error(401))
        )
        self.assertEqual(status, 401)
        self.assertEqual(payload, b'{"message":"nope"}')
        self.assertEqual(key.forgotten, 1)

    def test_upstream_400_keeps_key(self):
        status, _, key, _ = self.call(b"{}", opener=FakeOpener(raises=http_error(400)))
        self.assertEqual(status, 400)
        self.assertEqual(key.forgotten, 0)

    def test_upstream_timeout_is_504(self):
        status, _, _, _ = self.call(b"{}", opener=FakeOpener(raises=TimeoutError()))
        self.assertEqual(status, 504)
        status, _, _, _ = self.call(
            b"{}", opener=FakeOpener(raises=urllib.error.URLError(TimeoutError()))
        )
        self.assertEqual(status, 504)

    def test_upstream_unreachable_is_502(self):
        status, payload, _, _ = self.call(
            b"{}", opener=FakeOpener(raises=urllib.error.URLError("dns"))
        )
        self.assertEqual(status, 502)
        self.assertIn("upstream unreachable", json.loads(payload)["error"])

    def test_errors_never_contain_the_key(self):
        for opener in (
            FakeOpener(raises=TimeoutError()),
            FakeOpener(raises=urllib.error.URLError("dns")),
        ):
            _, payload, _, _ = self.call(b"{}", opener=opener)
            self.assertNotIn(SECRET.encode(), payload)


class KeychainKeyTest(unittest.TestCase):
    def runner(self, returncode, stdout=""):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(
                argv, returncode, stdout=stdout, stderr=""
            )

        return run, calls

    def test_reads_once_and_caches(self):
        run, calls = self.runner(0, SECRET + "\n")
        key = jev_broker.KeychainKey("svc", runner=run)
        self.assertEqual(key.get(), SECRET)
        self.assertEqual(key.get(), SECRET)
        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0], ["/usr/bin/security", "find-generic-password", "-s", "svc", "-w"]
        )

    def test_forget_rereads(self):
        run, calls = self.runner(0, SECRET)
        key = jev_broker.KeychainKey("svc", runner=run)
        key.get()
        key.forget()
        key.get()
        self.assertEqual(len(calls), 2)

    def test_failure_reports_exit_code_and_retries_next_time(self):
        run, calls = self.runner(36)
        key = jev_broker.KeychainKey("svc", runner=run)
        with self.assertRaisesRegex(jev_broker.KeyUnavailable, "security exit 36"):
            key.get()
        with self.assertRaises(jev_broker.KeyUnavailable):
            key.get()
        self.assertEqual(len(calls), 2)

    def test_empty_item_is_unavailable(self):
        run, _ = self.runner(0, "\n")
        key = jev_broker.KeychainKey("svc", runner=run)
        with self.assertRaisesRegex(jev_broker.KeyUnavailable, "empty"):
            key.get()


class HandlerTest(unittest.TestCase):
    """socketpair の片側で Handler を動かし、もう片側から生の HTTP を流す。"""

    def serve(self, key=None, opener=None):
        client, server_side = socket.socketpair()
        fake_server = SimpleNamespace(
            key_source=key or FakeKey(),
            opener=opener or FakeOpener(),
            upstream_url="https://upstream.invalid/x",
            upstream_timeout=5,
        )
        stderr = io.StringIO()

        def run():
            with redirect_stderr(stderr):
                jev_broker.Handler(server_side, "", fake_server)
            server_side.close()

        thread = threading.Thread(target=run)
        thread.start()
        return client, thread, fake_server, stderr

    def exchange(self, raw, **kwargs):
        client, thread, fake_server, stderr = self.serve(**kwargs)
        client.sendall(raw)
        response = self.read_all(client)
        thread.join(5)
        client.close()
        return response, fake_server, stderr.getvalue()

    @staticmethod
    def read_all(sock):
        sock.settimeout(5)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)

    @staticmethod
    def post(body, path=jev_broker.REQUEST_PATH, extra=b""):
        return (
            f"POST {path} HTTP/1.1\r\nHost: jev-broker\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n".encode()
            + extra
            + b"\r\n"
            + body
        )

    def test_post_is_forwarded(self):
        response, fake_server, log = self.exchange(self.post(b'{"state":"s"}'))
        self.assertTrue(response.startswith(b"HTTP/1.1 200"), response)
        self.assertTrue(response.endswith(b'{"answers":{}}'))
        self.assertEqual(len(fake_server.opener.requests), 1)
        self.assertEqual(log, "")

    def test_failure_is_logged_without_the_key(self):
        response, _, log = self.exchange(
            self.post(b"{}"), opener=FakeOpener(raises=urllib.error.URLError("dns"))
        )
        self.assertTrue(response.startswith(b"HTTP/1.1 502"), response)
        self.assertIn("-> 502", log)
        self.assertNotIn(SECRET, log)

    def test_unknown_path_is_404(self):
        response, fake_server, _ = self.exchange(
            self.post(b"{}", path="/v1/chat/completions")
        )
        self.assertTrue(response.startswith(b"HTTP/1.1 404"), response)
        self.assertEqual(fake_server.opener.requests, [])

    def test_oversized_body_is_413(self):
        raw = (
            f"POST {jev_broker.REQUEST_PATH} HTTP/1.1\r\nHost: x\r\n"
            f"Content-Length: {jev_broker.MAX_BODY_BYTES + 1}\r\n\r\n"
        ).encode()
        response, fake_server, _ = self.exchange(raw)
        self.assertTrue(response.startswith(b"HTTP/1.1 413"), response)
        self.assertEqual(fake_server.opener.requests, [])

    def test_get_is_405(self):
        response, _, _ = self.exchange(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertTrue(response.startswith(b"HTTP/1.1 405"), response)

    def test_expect_100_continue_is_answered_before_body(self):
        body = b'{"state":"' + b"x" * 2000 + b'"}'
        client, thread, _, _ = self.serve()
        headers, _, _ = self.post(body, extra=b"Expect: 100-continue\r\n").partition(
            b"\r\n\r\n"
        )
        client.sendall(headers + b"\r\n\r\n")
        client.settimeout(5)
        interim = client.recv(65536)
        self.assertTrue(interim.startswith(b"HTTP/1.1 100"), interim)
        client.sendall(body)
        rest = self.read_all(client)
        thread.join(5)
        client.close()
        self.assertIn(b"HTTP/1.1 200", interim + rest)


if __name__ == "__main__":
    unittest.main()
