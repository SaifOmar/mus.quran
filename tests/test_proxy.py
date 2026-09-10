import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import json
import socket
import threading
import urllib.error
import urllib.request

import pytest

import mediavalidate
import proxyhandler
from proxyhandler import ProxyServer
from tests.conftest import FakeOrigin, LocalDialer


def _stream(base, args="tok=tok123&reciter=ar.alafasy&surah=1", rng=None):
    req = urllib.request.Request(f"{base}/stream?{args}")
    if rng:
        req.add_header("Range", rng)
    try:
        return urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        return e


@pytest.fixture
def srv(monkeypatch, tmp_path):
    body = bytes(range(256)) * 400  # 102400 bytes, byte-valued so ranges are checkable
    with FakeOrigin(body) as origin:
        monkeypatch.setattr(proxyhandler, "audio_url",
                            lambda rid, n, rec: origin.url + "/001.mp3")
        monkeypatch.setattr(proxyhandler, "Dialer", LocalDialer)
        monkeypatch.setattr(proxyhandler.ProxyServer, "_get_reciter",
                            lambda self, rid: {"identifier": rid} if rid == "ar.alafasy" else None)
        s = ProxyServer(str(tmp_path / "cache"), str(tmp_path / "quran.json"),
                        "tok123", state_dir="")  # state_dir empty: no promotion
        s.start()
        t = threading.Thread(target=s.serve_forever, daemon=True)
        t.start()
        try:
            yield s, body, f"http://127.0.0.1:{s._port}"
        finally:
            s.shutdown()


def test_control_socket_usage_and_clear(srv, tmp_path):
    # The unix control socket carries the same handlers the shell's readout and
    # cache-clear use (plain HTTP/1.1 over QLocalSocket). The fixture's
    # s.shutdown() tears the control socket down after the test.
    sock_path = str(tmp_path / "run" / "quranproxy.sock")
    s = srv[0]
    ctrl = s.start_control(sock_path)
    threading.Thread(target=ctrl.serve_forever, daemon=True).start()

    def http_over_unix(path, method="GET"):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sk:
            sk.settimeout(5)
            sk.connect(sock_path)
            sk.sendall(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
            buf = b""
            while True:
                chunk = sk.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf.split(b"\r\n\r\n", 1)[1])

    usage = http_over_unix("/cache/usage?tok=tok123")
    assert usage["files"] == 0 and usage["bytes"] == 0
    assert http_over_unix("/api/cache/clear?tok=tok123", method="POST") == {"cleared": True}
    assert os.path.exists(sock_path)
    # Control plane is token-gated: missing or wrong token -> 403.
    assert http_over_unix("/cache/usage") == {"error": "invalid token"}
    assert http_over_unix("/cache/usage?tok=deadbeef") == {"error": "invalid token"}


def test_healthz_and_auth(srv):
    base = srv[2]
    r = urllib.request.urlopen(f"{base}/healthz", timeout=10)
    assert r.status == 200
    assert json.load(r) == {"ok": True}

    e = _stream(base, "tok=WRONG&reciter=ar.alafasy&surah=1")
    assert e.code == 403

    e = _stream(base, "tok=tok123&reciter=zzz&surah=1")
    assert e.code == 400
    assert json.load(e) == {"error": "unknown reciter"}

    try:
        urllib.request.urlopen(f"{base}/cache/usage", timeout=10)
    except urllib.error.HTTPError as e2:
        assert e2.code == 403
    else:
        raise AssertionError("cache/usage without token should 403")

    r = urllib.request.urlopen(f"{base}/cache/usage?tok=tok123", timeout=10)
    assert json.load(r) == {"bytes": 0, "files": 0}


def test_stream_full_and_ranges(srv):
    _, body, base = srv
    tok = "tok123"

    r = _stream(base)
    assert r.status == 200
    assert r.read() == body

    usage = json.load(urllib.request.urlopen(f"{base}/cache/usage?tok={tok}", timeout=10))
    assert usage == {"bytes": len(body), "files": 1}

    r = _stream(base, rng="bytes=100-200")
    assert r.status == 206
    assert r.headers.get("Content-Range") == f"bytes 100-200/{len(body)}"
    assert r.read() == body[100:201]

    r = _stream(base, rng="bytes=-10")
    assert r.status == 206
    assert r.read() == body[-10:]

    for bad in ("bytes=999999-", "bytes=500-400", "bytes=-0"):
        e = _stream(base, rng=bad)
        assert e.code == 416, bad


def test_stream_promotes_when_full(monkeypatch, tmp_path):
    import proxyhandler as ph
    body = b"audio-promote-body" * 100
    with FakeOrigin(body) as origin:
        monkeypatch.setattr(ph, "audio_url", lambda rid, n, rec: origin.url + "/001.mp3")
        monkeypatch.setattr(ph, "Dialer", LocalDialer)
        monkeypatch.setattr(ph.ProxyServer, "_get_reciter",
                            lambda self, rid: {"identifier": rid})
        monkeypatch.setattr(mediavalidate, "validate_media_file", lambda p: True)
        s = ph.ProxyServer(str(tmp_path / "cache"), str(tmp_path / "quran.json"),
                           "tok123", state_dir=str(tmp_path / "data"))
        s.start()
        t = threading.Thread(target=s.serve_forever, daemon=True)
        t.start()
        base = f"http://127.0.0.1:{s._port}"
        try:
            r = _stream(base)
            assert r.status == 200
            assert r.read() == body
        finally:
            s.shutdown()

    promoted = tmp_path / "data" / "ar.alafasy" / "1.mp3"
    assert promoted.read_bytes() == body
    assert not (tmp_path / "cache" / "ar.alafasy" / "1.dat").exists()