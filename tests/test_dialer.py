import os
import socket
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

from dialer import Dialer


def _req(url="https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3"):
    r = urllib.request.Request(url)
    r.timeout = 30
    return r


def _resolve_to(ip, family):
    if family == socket.AF_INET:
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 443))]
    if isinstance(ip, str):  # AF_INET6 sockaddr
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", (ip, 443, 0, 0))]
    raise AssertionError(f"unhandled family for {ip!r}")


@pytest.mark.parametrize("ip,family", [
    ("10.0.0.1", socket.AF_INET),
    ("127.0.0.1", socket.AF_INET),
    ("192.168.1.1", socket.AF_INET),
    ("169.254.0.1", socket.AF_INET),
    ("::1", socket.AF_INET6),
    ("fe80::1", socket.AF_INET6),
    ("fec0::1", socket.AF_INET6),
    ("fc00::1", socket.AF_INET6),
    ("::ffff:127.0.0.1", socket.AF_INET6),
])
def test_dns_rebind_private_ips_blocked(monkeypatch, ip, family):
    # A malicious catalog entry must never let the daemon reach private or
    # loopback addresses even if DNS resolves an allowlisted host to them.
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _resolve_to(ip, family))
    d = Dialer()
    with pytest.raises(urllib.error.URLError, match="blocked"):
        d.opener.open(_req(), timeout=30)


def test_public_ip_pinned_and_connected(monkeypatch):
    # For a public resolution the handler connects to the pinned IP address
    # (not the hostname), keeping the original host for TLS SNI/verify.
    public = "93.184.216.34"
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _resolve_to(public, socket.AF_INET))
    captured = {}

    def fake_connect(target, timeout=None):
        captured["target"] = target
        raise ConnectionRefusedError("simulated")

    monkeypatch.setattr(socket, "create_connection", fake_connect)
    d = Dialer()
    with pytest.raises(ConnectionRefusedError):
        d.opener.open(_req(), timeout=30)
    assert captured.get("target") == (public, 443)