import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class _OriginHandler(BaseHTTPRequestHandler):
    body = b""  # overridden per instance by set_body

    def log_message(self, *args):
        pass

    def _send(self, status, headers, body):
        self.send_response(status)
        length = str(len(body))
        for k, v in headers.items():
            self.send_header(k, v)
            if k.lower() == "content-length":
                length = v
        self.send_header("Content-Length", length)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_HEAD(self):
        self._send(200, {
            "Content-Type": "audio/mpeg",
            "Content-Length": str(len(self.server.body)),
        }, b"")

    def do_GET(self):
        body = self.server.body
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            spec = rng[6:]
            a, _, b = spec.partition("-")
            start = int(a)
            end = int(b) if b else len(body) - 1
            end = min(end, len(body) - 1)
            if start >= len(body) or start > end:
                self._send(416, {}, b"")
                return
            chunk = body[start:end + 1]
            self._send(206, {
                "Content-Type": "audio/mpeg",
                "Content-Range": f"bytes {start}-{end}/{len(body)}",
            }, chunk)
        else:
            self._send(200, {"Content-Type": "audio/mpeg"}, body)


class FakeOrigin:
    """Local HTTP origin serving a fixed body for fetch/proxy tests."""

    def __init__(self, body):
        self.body = body

        class H(_OriginHandler):
            pass

        H.body = body
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self._server.body = body
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._thread.join()


class FakeResponse:
    """HTTPResponse-shaped object for a fake dialer."""

    def __init__(self, status, headers, body, chunk=65536):
        self.status = status
        self.headers = headers
        self._body = body
        self._off = 0
        self._chunk = chunk

    def read(self, amt=None):
        if self._off >= len(self._body):
            return b""
        n = amt or self._chunk
        end = min(self._off + n, len(self._body))
        data = self._body[self._off:end]
        self._off = end
        return data

    def close(self):
        self._off = len(self._body)


class FakeOpener:
    """urllib-style opener backed by FakeResponse for offline fetch tests."""

    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append((req.get_full_url(), req.get_method(), req.headers))
        if 400 <= self.status < 600:
            import urllib.error
            raise urllib.error.HTTPError(req.get_full_url(), self.status, "err", {}, None)
        return FakeResponse(self.status, self.headers, self.body)


class FakeDialer:
    """Stands in for Dialer: exposes .opener for fetch/quranctl tests."""

    def __init__(self, status=200, headers=None, body=b"fake-mp3-body"):
        self.opener = FakeOpener(status, headers or {"Content-Type": "audio/mpeg", "Content-Length": str(len(body))}, body)

    def request(self, url, data=None, headers=None, timeout=30):
        req = urllib.request.Request(url, data=data or None, headers=headers or {})
        return self.opener.open(req, timeout=timeout)


class LocalDialer:
    """Dialer-shaped object whose opener talks to a local HTTP origin."""

    def __init__(self):
        self.opener = urllib.request.build_opener()