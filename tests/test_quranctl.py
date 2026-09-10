import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

import quranctl
from tests.conftest import FakeDialer, FakeOrigin, LocalDialer


def _patch(fn, monkeypatch, origin_url=None):
    monkeypatch.setattr(quranctl, "_new_dialer", LocalDialer if origin_url else FakeDialer)
    if origin_url:
        monkeypatch.setattr(quranctl, "build_origin_url",
                            lambda reciter, server: lambda n: f"{origin_url}/{n}.mp3")


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


def test_download_success(monkeypatch, home, capsys):
    body = b"ID3v2 payload " * 1000
    with FakeOrigin(body) as origin:
        _patch(None, monkeypatch, origin.url)
        rc = quranctl.cmd_download(["ar.alafasy", "1"])
    assert rc == 0
    out = capsys.readouterr()
    assert "progress 1/1\n" in out.out
    assert "complete 1 0\n" in out.out
    assert "failed " not in out.err
    dest = home / ".local" / "state" / "omarchy" / "quran" / "ar.alafasy" / "1.mp3"
    assert dest.read_bytes() == body
    assert (dest.stat().st_mode & 0o777) == 0o600


def test_download_already_complete_skips(monkeypatch, home, capsys):
    body = b"x" * 4000
    with FakeOrigin(body) as origin:
        _patch(None, monkeypatch, origin.url)
        assert quranctl.cmd_download(["ar.alafasy", "1"]) == 0
        out = capsys.readouterr()
        n = out.out.count("progress_bytes")
        assert n >= 1
        # Second run: probe still happens, but no transfer/progress lines.
        assert quranctl.cmd_download(["ar.alafasy", "1"]) == 0
        out2 = capsys.readouterr()
        assert out2.out.count("progress_bytes") == 0
        assert "progress 1/1\n" in out2.out
        assert "complete 1 0\n" in out2.out


def test_download_404(monkeypatch, home, capsys):
    monkeypatch.setattr(quranctl, "_new_dialer", lambda: FakeDialer(status=404))
    monkeypatch.setattr(quranctl, "build_origin_url",
                        lambda reciter, server: lambda n: "https://cdn.islamic.app/x/1.mp3")
    rc = quranctl.cmd_download(["ar.alafasy", "1"])
    assert rc == 1
    out = capsys.readouterr()
    assert "complete 0 1\n" in out.out
    assert "failed 1: fetch: origin status 404\n" in out.err
    rec_dir = home / ".local" / "state" / "omarchy" / "quran" / "ar.alafasy"
    assert not (rec_dir / "1.mp3").exists()


def test_download_only_list(monkeypatch, home, capsys):
    body = b"bulk body " * 10
    with FakeOrigin(body) as origin:
        # server-based URL; reciter + server optional since build_origin_url is faked
        def builder(reciter, server):
            def b(n):
                return f"{origin.url}/{n}.mp3"
            return b
        monkeypatch.setattr(quranctl, "_new_dialer", LocalDialer)
        monkeypatch.setattr(quranctl, "build_origin_url", builder)
        rc = quranctl.cmd_download(["ar.alafasy", "--only", "1,2,3"])
    assert rc == 0
    out = capsys.readouterr()
    assert "progress 1/3\n" in out.out
    assert "progress 2/3\n" in out.out
    assert "progress 3/3\n" in out.out
    assert "complete 3 0\n" in out.out


def test_parse_download_args():
    assert quranctl.parse_download_args(["ar.alafasy", "1"]) == ("ar.alafasy", [1], None, False)
    reciter, surahs, server, err = quranctl.parse_download_args(
        ["ar.alafasy", "--only", "1, 2, 3", "--server", "https://server8.mp3quran.net/afs/"])
    assert not err and reciter == "ar.alafasy" and surahs == [1, 2, 3]
    assert server == "https://server8.mp3quran.net/afs/"
    # hostile / invalid inputs rejected
    assert quranctl.parse_download_args(["../x", "1"])[3]
    assert quranctl.parse_download_args(["ar.alafasy", "115"])[3]
    assert quranctl.parse_download_args(["ar.alafasy", "--server", "http://evil.com/"])[3]
    assert quranctl.parse_download_args(["ar.alafasy"])[3]
    assert quranctl.parse_download_args([])[3]
    assert quranctl.parse_download_args(["ar.alafasy", "--server"])[3]


def test_cmd_remove(tmp_path, capsys):
    state = tmp_path / "state"
    rec_dir = state / "ar.alafasy"
    rec_dir.mkdir(parents=True)
    target = rec_dir / "1.mp3"
    target.write_bytes(b"x" * 10)

    assert quranctl.cmd_remove(["--state-dir", str(state), "ar.alafasy", "1"]) == 0
    assert not target.exists()
    # missing file still rc 0; invalid args rc 2
    assert quranctl.cmd_remove(["--state-dir", str(state), "ar.alafasy", "1"]) == 0
    assert quranctl.cmd_remove(["--state-dir", str(state), "../x", "1"]) == 2
    assert quranctl.cmd_remove(["--state-dir", str(state), "ar.alafasy", "115"]) == 2
    assert quranctl.cmd_remove(["--state-dir", str(state), "ar.alafasy"]) == 2


def test_main_unknown_command(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["quranctl", "frobnicate"])
    assert quranctl.main() == 2
    assert "unknown command" in capsys.readouterr().err