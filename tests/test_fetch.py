import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

from fetch import ErrComplete, FetchError, fetch
from tests.conftest import FakeDialer, FakeOrigin, FakeResponse, LocalDialer


def _builder(origin_url):
    return lambda n: f"{origin_url}/{n}.mp3"


def test_fetch_writes_0600_atomic(tmp_path):
    body = b"ID3 fake mp3 " * 1000
    with FakeOrigin(body) as origin:
        fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url),
              on_progress=lambda w, r: None)
    dest = tmp_path / "ar.alafasy" / "1.mp3"
    assert dest.read_bytes() == body
    assert (dest.stat().st_mode & 0o777) == 0o600


def test_fetch_complete_skips_existing(tmp_path):
    body = b"x" * 5000
    with FakeOrigin(body) as origin:
        fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url))
        with pytest.raises(ErrComplete):
            fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url))


def test_fetch_resumes_part(tmp_path):
    body = (b"A" * 5000) + (b"B" * 5000)
    with FakeOrigin(body) as origin:
        rec_dir = tmp_path / "ar.alafasy"
        rec_dir.mkdir()
        part = rec_dir / "1.mp3.part.abc"
        part.write_bytes(body[:5000])
        fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url))
    assert (tmp_path / "ar.alafasy" / "1.mp3").read_bytes() == body


def test_fetch_stale_part_dropped(tmp_path):
    body = b"0123456789"
    with FakeOrigin(body) as origin:
        rec_dir = tmp_path / "ar.alafasy"
        rec_dir.mkdir()
        (rec_dir / "1.mp3.part.old").write_bytes(b"0123456789" + b"junk")
        fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url))
    assert (tmp_path / "ar.alafasy" / "1.mp3").read_bytes() == body


def test_fetch_404(tmp_path):
    with FakeOrigin(b"body") as origin:
        req = FakeDialer(status=404)
        with pytest.raises(FetchError, match="origin status 404"):
            fetch(req, str(tmp_path), "ar.alafasy", 1, _builder(origin.url))


def test_fetch_rejects_content_type(tmp_path):
    dialer = FakeDialer(headers={"Content-Type": "text/html", "Content-Length": "10"})
    with pytest.raises(FetchError, match="content type"):
        fetch(dialer, str(tmp_path), "ar.alafasy", 1, _builder("https://cdn.islamic.app/x"))


def test_fetch_size_mismatch_raises(tmp_path):
    class _Dialer:
        class opener:
            pass
    dialer = _Dialer()
    dialer.opener.open = lambda req, timeout=None: FakeResponse(
        200,
        {"Content-Type": "audio/mpeg", "Content-Length": "100"},
        b"short",
    )
    with pytest.raises(FetchError, match="size mismatch"):
        fetch(dialer, str(tmp_path), "ar.alafasy", 1, _builder("https://cdn.islamic.app/x"))


def test_fetch_rejects_symlink_target(tmp_path):
    with FakeOrigin(b"data") as origin:
        rec_dir = tmp_path / "ar.alafasy"
        rec_dir.mkdir()
        (rec_dir / "1.mp3").symlink_to(tmp_path / "elsewhere")
        with pytest.raises(FetchError, match="symlink"):
            fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 1, _builder(origin.url))


def test_fetch_rejects_bad_arg(tmp_path):
    with FakeOrigin(b"data") as origin:
        with pytest.raises(FetchError):
            fetch(LocalDialer(), str(tmp_path), "../etc", 1, _builder(origin.url))
        with pytest.raises(FetchError):
            fetch(LocalDialer(), str(tmp_path), "ar.alafasy", 115, _builder(origin.url))
        with pytest.raises(FetchError):
            fetch(LocalDialer(), "relative-root", "ar.alafasy", 1, _builder(origin.url))


def test_fetch_rejects_traversal_reciters(tmp_path):
    # Reciter ids become path segments; anything that could escape the reciter
    # directory (dot-dot, separators, backslashes) must be refused.
    with FakeOrigin(b"data") as origin:
        for bad in ("..", ".", "../x", "a/../b", "a\\..\\b", "..\\etc", "x%2f..%2f.."):
            with pytest.raises(FetchError):
                fetch(LocalDialer(), str(tmp_path), bad, 1, _builder(origin.url), on_progress=lambda w, r: None)