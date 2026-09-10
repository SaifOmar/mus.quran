import json
import os
import socket
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from catalog import audio_url
from dialer import Dialer
from rangecache import RangeCache
from session import compare_tokens
from urlsafety import is_safe_reciter, is_safe_reciter_arg

COOLDOWN_MS = 10000


# ---- Bound handler factory ----

class ProxyHandler(BaseHTTPRequestHandler):
    """HTTP handler bound to a ProxyServer instance."""

    timeout = 30

    def log_message(self, format, *args):
        pass

    def _json(self, data, code=200):
        # Trailing newline so the client's line-based SplitParser emits the body.
        body = json.dumps(data).encode("utf-8") + b"\n"
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message):
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/healthz":
            self._json({"ok": True})
            return

        if parsed.path == "/cache/usage":
            tok = qs.get("tok", [""])[0]
            if not self._valid_token(tok):
                self._error(403, "invalid token")
                return
            self._json(self.server._get_cache_usage())
            return

        if parsed.path == "/stream":
            tok = qs.get("tok", [""])[0]
            if not self._valid_token(tok):
                self._error(403, "invalid token")
                return
            self._serve_stream(qs.get("reciter", [""])[0],
                               qs.get("surah", [""])[0])
            return

        self._error(404, "not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/api/cache/clear":
            tok = qs.get("tok", [""])[0]
            if not self._valid_token(tok):
                self._error(403, "invalid token")
                return
            self.server._clear_cache()
            self._json({"cleared": True})
            return

        self._error(404, "not found")

    # ---- Stream handler ----

    def _serve_stream(self, rec_id, surah_str):
        if not is_safe_reciter_arg(rec_id):
            self._error(400, "invalid reciter")
            return
        try:
            surah = int(surah_str)
            if surah < 1 or surah > 114:
                raise ValueError()
        except (ValueError, TypeError):
            self._error(400, "invalid surah")
            return

        reciter = self.server._get_reciter(rec_id)
        if not reciter:
            self._error(400, "unknown reciter")
            return

        origin_url = audio_url(rec_id, surah, reciter)
        if not origin_url:
            self._error(500, "cannot build origin URL")
            return

        if self.server._cooldown_active(rec_id, surah):
            self._error(425, "playback failed, retry later")
            return

        cache = self.server._cache

        # Probe origin size (HEAD, DNS-pinned)
        size = None
        content_type = "audio/mpeg"
        try:
            head_req = urllib.request.Request(origin_url, method="HEAD")
            resp = self.server._dialer.opener.open(head_req, timeout=30)
            size = int(resp.headers.get("Content-Length", 0))
            ct = resp.headers.get("Content-Type", "")
            if ct.startswith("audio/") or ct == "application/octet-stream":
                content_type = ct
            if size <= 0 or size > self.server._max_surah_bytes:
                self.server._arm_cooldown(rec_id, surah)
                self._error(413, "invalid size")
                return
        except urllib.error.HTTPError as e:
            self.server._arm_cooldown(rec_id, surah)
            self._error(502, f"origin HEAD failed: {e.code}")
            return
        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
            self.server._arm_cooldown(rec_id, surah)
            self._error(502, f"origin probe failed: {exc}")
            return

        # Init cache entry if needed
        if cache.get_size(rec_id, surah) is None:
            cache.set_size(rec_id, surah, size, content_type)

        # Parse Range header. Closed ranges are stored as half-open [start, end).
        range_header = self.headers.get("Range", "")
        rng_start = 0
        rng_end = 0  # 0 = full file
        if range_header.startswith("bytes="):
            spec = range_header[6:]
            if "-" in spec:
                parts = spec.split("-", 1)
                try:
                    if parts[0] != "" and parts[1] != "":
                        rng_start = int(parts[0])
                        rng_end = int(parts[1]) + 1  # inclusive -> exclusive
                    elif parts[0] == "" and parts[1] != "":  # suffix range bytes=-N
                        rng_start = max(0, size - int(parts[1]))
                        rng_end = size
                    elif parts[1] == "":  # open-ended bytes=S-
                        rng_start = int(parts[0])
                        rng_end = size  # to end of file
                except ValueError:
                    self._error(416, "invalid range")
                    return

        if rng_end > 0 and rng_start >= size:
            self._error(416, "range not satisfiable")
            return
        rng_end = min(rng_end, size)
        if 0 < rng_end <= rng_start:
            self._error(416, "range not satisfiable")
            return

        # Determine missing ranges and fill
        if rng_end > rng_start:
            missing = cache.get_missing_ranges(rec_id, surah, rng_start, rng_end)
        else:
            missing = cache.get_missing_ranges(rec_id, surah, 0, size)

        for start, end in missing:
            self._fill_range(rec_id, surah, origin_url, start, end)

        # Serve from cache
        if rng_end > rng_start:
            data = cache.read_range(rec_id, surah, rng_start, rng_end - rng_start)
            if data is not None:
                self._partial(data, size, rng_start, rng_end - 1, content_type)
                self._maybe_promote(rec_id, surah)
                return
            # Fallback: full file request
            data = cache.read_range(rec_id, surah, 0, size)
            if data is not None:
                self._full(data, size, content_type)
                self._maybe_promote(rec_id, surah)
                return
            self._error(502, "cache miss after fill")
            return

        # Full file request
        data = cache.read_range(rec_id, surah, 0, size)
        if data is not None:
            self._full(data, size, content_type)
            self._maybe_promote(rec_id, surah)
            return

        # Stream from origin directly
        self._stream_origin(origin_url, size, content_type)
        self._maybe_promote(rec_id, surah)

    def _maybe_promote(self, rec_id, surah):
        """M3 hook: validate + atomically move a fully-fetched surah into
        dataDir, print `promoted <id> <n>` on stdout. A validation failure
        deletes the cache entry and arms the per-surah cooldown."""
        if not self.server._state_dir:
            return
        dest = os.path.join(self.server._state_dir, rec_id, f"{surah}.mp3")
        status = self.server._cache.promote(rec_id, surah, dest, validate=True)
        if status == "ok":
            print(f"promoted {rec_id} {surah}", flush=True)
        elif status == "invalid":
            self.server._arm_cooldown(rec_id, surah)

    def _fill_range(self, rec_id, surah, url, start, end):
        """Fetch a byte range from origin and write to cache (streamed chunks)."""
        end_fill = self.server._cache.begin_fill(rec_id, surah)
        headers = {"Range": f"bytes={start}-{end - 1}"}
        req = urllib.request.Request(url, headers=headers)
        try:
            resp = self.server._dialer.opener.open(req, timeout=30)
        except Exception:
            end_fill()
            raise
        offset = start
        try:
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                self.server._cache.write_range(rec_id, surah, offset, chunk)
                offset += len(chunk)
        finally:
            resp.close()
            end_fill()

    def _stream_origin(self, url, size, content_type):
        """Stream directly from origin (no caching) in chunks."""
        req = urllib.request.Request(url)
        resp = self.server._dialer.opener.open(req, timeout=30)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        try:
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            resp.close()

    def _partial(self, data, total_size, start, end, content_type="audio/mpeg"):
        body = data
        self.send_response(206)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Range", f"bytes {start}-{end}/{total_size}")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(body)

    def _full(self, data, total_size, content_type="audio/mpeg"):
        body = data
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(body)

    def _valid_token(self, tok):
        return compare_tokens(tok, self.server._token)


# ---- State-carrying server ----

class ProxyHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer carrying proxy state for handlers (self.server.*)."""

    daemon_threads = True

    def __init__(self, addr, handler, proxy):
        self._cache = proxy._cache
        self._token = proxy._token
        self._dialer = proxy._dialer
        self._max_surah_bytes = proxy._max_surah_bytes
        self._state_dir = proxy._state_dir
        self._cooldowns = {}  # "reciter:surah" -> float epoch ms
        self._get_reciter = proxy._get_reciter
        self._get_cache_usage = proxy._get_cache_usage
        self._clear_cache = proxy._clear_cache
        super().__init__(addr, handler)

    def _cooldown_active(self, reciter, surah):
        key = f"{reciter}:{surah}"
        until = self._cooldowns.get(key, 0)
        return int(time.time() * 1000) < until

    def _arm_cooldown(self, reciter, surah):
        self._cooldowns[f"{reciter}:{surah}"] = int(time.time() * 1000) + COOLDOWN_MS


class UnixControlServer(ProxyHTTPServer):
    """AF_UNIX variant of the proxy server serving the same handlers.

    The shell's cache readout and cache-clear live on this socket: QLocalSocket
    connects here and talks plain HTTP/1.1 (same routes as the TCP listener).
    """

    address_family = socket.AF_UNIX

    def server_bind(self):
        try:
            os.unlink(self.server_address)
        except OSError:
            pass
        super().server_bind()
        os.chmod(self.server_address, 0o600)


# ---- Server shell ----

class ProxyServer:
    """Threading HTTP proxy server.

    Usage:
        server = ProxyServer(cache_dir, state_path, token, bind, port)
        server.start()
        server.serve_forever()
    """

    def __init__(self, cache_dir: str, state_path: str, token: str,
                 bind: str = "127.0.0.1", port: int = 0,
                 max_surah_bytes: int = 314572800, state_dir: str = ""):
        self._cache = RangeCache(cache_dir)
        self._state_path = state_path
        self._token = token
        self._bind = bind
        self._port = port
        self._max_surah_bytes = max_surah_bytes
        self._state_dir = state_dir
        self._dialer = Dialer()
        self._reciter_cache = {}
        self._catalog_mtime = 0
        self._server = None
        self._control = None
        self._handler = None

    def _load_catalog(self):
        import json
        try:
            st = os.stat(self._state_path)
            if st.st_mtime <= self._catalog_mtime:
                return
            self._catalog_mtime = st.st_mtime
            with open(self._state_path) as f:
                data = json.load(f)
            reciters = data.get("reciters", [])
            self._reciter_cache = {
                r["identifier"]: r for r in reciters if is_safe_reciter(r)
            }
        except (json.JSONDecodeError, OSError, KeyError):
            pass

    def _get_reciter(self, rec_id):
        self._load_catalog()
        return self._reciter_cache.get(rec_id)

    def _get_cache_usage(self):
        return {"bytes": self._cache.get_total_bytes(), "files": self._cache.get_file_count()}

    def _clear_cache(self):
        self._cache.clear()

    def start(self):
        addr = (self._bind, self._port)
        self._server = ProxyHTTPServer(addr, ProxyHandler, self)
        self._port = self._server.server_address[1]
        return self._server

    def start_control(self, socket_path: str):
        """Create the unix control-plane listener; returns it unstarted."""
        if self._control is not None:
            return self._control
        os.makedirs(os.path.dirname(os.path.abspath(socket_path)), mode=0o700, exist_ok=True)
        self._control = UnixControlServer(socket_path, ProxyHandler, self)
        return self._control

    def serve_forever(self):
        if self._server:
            self._server.serve_forever()

    def shutdown(self):
        if self._control:
            try:
                os.unlink(self._control.server_address)
            except OSError:
                pass
            try:
                self._control.shutdown()
            except OSError:
                pass
            self._control.server_close()
            self._control = None
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None