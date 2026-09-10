import socket
import ssl
import urllib.error
import urllib.request
from email.message import Message

from urlsafety import is_blocked_host


class Dialer:
    """DNS-pinned HTTP client.

    Resolves hostname once per request, validates all IPs are public,
    then connects to the first IPv4 address (IPv4-preferred), while keeping
    the original hostname for TLS SNI and certificate verification.

    Redirects are NEVER followed (return error on any 3xx).
    """

    def __init__(self):
        self.opener = urllib.request.build_opener(self._PinningHTTPSHandler())

    def request(self, url, data=None, headers=None, timeout=30):
        req = urllib.request.Request(url, data=data or None, headers=headers or {})
        req.timeout = timeout
        return self.opener.open(req, timeout=timeout)

    class _PinningHTTPSHandler(urllib.request.HTTPSHandler):
        def __init__(self, context=None):
            self._context = context or ssl.create_default_context()
            self._context.check_hostname = True
            super().__init__(context=self._context, check_hostname=True)

        def https_open(self, req):
            url = req.get_full_url()
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme != "https":
                raise urllib.error.URLError("Only HTTPS allowed")

            host = parsed.hostname
            if not host:
                raise urllib.error.URLError("Invalid host")

            port = parsed.port or 443
            if parsed.scheme != "https" or port != 443:
                raise urllib.error.URLError("Only https:443 is allowed")

            # Resolve and pin IPs
            try:
                infos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
            except socket.gaierror as e:
                raise urllib.error.URLError(f"DNS resolution failed: {e}")

            # Reject if any resolved address (IPv4 or IPv6) is private/internal.
            # urlsafety.is_blocked_host is the single policy source for both families.
            for family, _, _, _, sockaddr in infos:
                ip = sockaddr[0]
                if is_blocked_host(ip):
                    raise urllib.error.URLError("Resolved address is blocked (private/internal)")

            # Pick first IPv4 address (IPv4-preferred), fallback to IPv6
            target_addr = None
            for family, _, _, _, sockaddr in infos:
                if family == socket.AF_INET:
                    target_addr = sockaddr
                    break
                if family == socket.AF_INET6 and target_addr is None:
                    target_addr = sockaddr
            if not target_addr:
                raise urllib.error.URLError("No valid IP address found")

            # Create connection to pinned IP
            to = getattr(req, "timeout", 30) or 30
            sock = socket.create_connection(target_addr, timeout=to)

            # Wrap socket for TLS with SNI set to original hostname
            ssock = self._context.wrap_socket(sock, server_hostname=host)

            # Send HTTP request over the pinned socket
            method = req.get_method()
            body = req.data
            headers = req.headers.copy()

            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query

            request_line = f"{method} {path} HTTP/1.1\r\n"
            hdr_lines = [f"Host: {host}", "Connection: close"]
            for k, v in headers.items():
                if k.lower() not in ("host", "connection", "keep-alive", "proxy-authenticate",
                                    "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"):
                    hdr_lines.append(f"{k}: {v}")
            if body is not None and "Content-Length" not in headers:
                hdr_lines.append(f"Content-Length: {len(body)}")

            request = (request_line + "\r\n".join(hdr_lines) + "\r\n\r\n").encode("utf-8")
            if body:
                request += body

            ssock.sendall(request)

            # Read response headers
            response = ssock.makefile("rb", buffering=0)
            status_line = response.readline().decode("iso-8859-1").rstrip("\r\n")
            if not status_line:
                raise urllib.error.URLError("Empty response")
            parts = status_line.split(None, 2)
            if len(parts) < 2:
                raise urllib.error.URLError("Invalid status line")
            try:
                code = int(parts[1])
            except ValueError:
                raise urllib.error.URLError("Invalid status code")
            message = parts[2] if len(parts) > 2 else ""

            headers = Message()
            while True:
                line = response.readline().decode("iso-8859-1").rstrip("\r\n")
                if line in ("", "\r\n"):
                    break
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip()] = v.strip()

            # Reject redirects — never follow
            if 300 <= code < 400:
                raise urllib.error.HTTPError(url, code, message, headers, None)

            # Return a file-like object for the response body
            return self._SocketResponse(ssock, response, code, message, headers)

        class _SocketResponse:
            def __init__(self, sock, fp, status, msg, hdrs):
                self._sock = sock
                self._fp = fp
                self.status = status
                self.reason = msg
                self.headers = hdrs
                self._length = None
                cl = hdrs.get("Content-Length")
                if cl is not None:
                    try:
                        self._length = int(cl)
                    except ValueError:
                        pass
                self._bytes_read = 0

            @property
            def code(self):
                return self.status

            @property
            def msg(self):
                return self.reason

            def info(self):
                return self.headers

            def geturl(self):
                return ""

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                self.close()

            def read(self, amt=None):
                if self._length is not None and self._bytes_read >= self._length:
                    return b""
                if amt is None:
                    data = self._fp.read()
                else:
                    if self._length is not None:
                        amt = min(amt, self._length - self._bytes_read)
                    data = self._fp.read(amt or 0)
                self._bytes_read += len(data)
                return data

            def readline(self, limit=-1):
                line = self._fp.readline(limit)
                self._bytes_read += len(line)
                return line

            def __iter__(self):
                return self

            def __next__(self):
                line = self.readline()
                if not line:
                    raise StopIteration
                return line

            def close(self):
                self._fp.close()
                self._sock.close()

            @property
            def closed(self):
                return self._fp.closed
