import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


from session import (
    compare_tokens,
    derive_socket_path,
    is_safe_socket_path,
    new_token,
    read_handoff,
    write_handoff,
)


def test_token_roundtrip(tmp_path):
    token = new_token()
    assert len(token) == 32 and all(c in "0123456789abcdef" for c in token)
    assert new_token() != token


def test_handoff_roundtrip(tmp_path):
    path = str(tmp_path / "run" / "handoff.json")
    assert write_handoff("/run/mpv.sock", 53100, "tok123", path)
    data = read_handoff(path)
    assert data == {"port": "53100", "token": "tok123", "sock": "/run/mpv.sock"}
    st = os.stat(path)
    assert (st.st_mode & 0o777) == 0o600


def test_read_handoff_failures(tmp_path):
    assert read_handoff(str(tmp_path / "nope.json")) is None
    bad = tmp_path / "bad.json"
    bad.write_text("{corrupt")
    assert read_handoff(str(bad)) is None
    bad2 = tmp_path / "bad2.json"
    bad2.write_text(json.dumps({"port": 1}))
    assert read_handoff(str(bad2)) is None


def test_compare_tokens():
    assert compare_tokens("abc", "abc") is True
    assert compare_tokens("abc", "abd") is False
    assert compare_tokens("abc", "ABC") is False
    assert compare_tokens("abc", None) is False
    assert compare_tokens(None, "abc") is False


def test_derive_socket_path(tmp_path, monkeypatch):
    assert derive_socket_path("/run/user/1000") == "/run/user/1000/mus-quran/mpv.sock"
    monkeypatch.setenv("HOME", "/home/x")
    assert derive_socket_path("") == "/home/x/.cache/omarchy/quran/run/mpv.sock"
    monkeypatch.delenv("HOME", raising=False)
    assert derive_socket_path("") == ""


def test_is_safe_socket_path(tmp_path):
    runtime = "/run/user/1000"
    assert is_safe_socket_path(f"{runtime}/mus-quran/mpv.sock", runtime) is True
    assert is_safe_socket_path(f"{runtime}/../../etc/passwd", runtime) is False
    assert is_safe_socket_path("/tmp/other.sock", runtime) is False
    assert is_safe_socket_path("", runtime) is False


def test_handoff_rejects_planted_symlink(tmp_path):
    # A symlink planted at the deterministic .tmp path must be refused and
    # the victim file must stay untouched.
    run = tmp_path / "run"
    run.mkdir(mode=0o700)
    path = str(run / "handoff.json")
    victim = tmp_path / "victim.txt"
    victim.write_text("do not clobber")
    os.symlink(str(victim), path + ".tmp")

    assert write_handoff("/run/mpv.sock", 53100, "tok123", path) is False
    assert victim.read_text() == "do not clobber"
    assert not os.path.exists(path)


def test_handoff_replaces_stale_regular_tmp(tmp_path):
    # A stale regular .tmp from a crashed writer is cleaned up and retried.
    run = tmp_path / "run"
    run.mkdir(mode=0o700)
    path = str(run / "handoff.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write("stale")

    assert write_handoff("/run/mpv.sock", 53100, "tok123", path) is True
    assert not os.path.exists(path + ".tmp")
    data = read_handoff(path)
    assert data == {"port": "53100", "token": "tok123", "sock": "/run/mpv.sock"}