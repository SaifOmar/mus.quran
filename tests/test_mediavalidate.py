import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

from mediavalidate import validate_media_file


def test_missing_file_false(tmp_path):
    assert validate_media_file(str(tmp_path / "nope.mp3")) is False
    assert validate_media_file("") is False


def test_empty_or_symlink_false(tmp_path):
    empty = tmp_path / "empty.mp3"
    empty.write_bytes(b"")
    assert validate_media_file(str(empty)) is False

    real = tmp_path / "real.bin"
    real.write_bytes(b"\xfb\x06\x00\x00\x64\x65\x66" * 4)
    link = tmp_path / "link.mp3"
    link.symlink_to(real)
    assert validate_media_file(str(link)) is False


def test_text_file_false(tmp_path):
    txt = tmp_path / "song.mp3"
    txt.write_text("this is not audio at all" * 10)
    assert validate_media_file(str(txt)) is False


def test_non_audio_rejected_by_ffprobe(tmp_path):
    data = tmp_path / "data.mp3"
    data.write_bytes(b"\x01\x02\x03" * 50)  # file() may say octet-stream, ffprobe rejects
    assert validate_media_file(str(data)) is False


def _real_mp3(tmp_path):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        pytest.skip("ffmpeg not available")
    out = tmp_path / "real.mp3"
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi",
           "-i", "sine=frequency=440:duration=0.2", "-c:a", "libmp3lame", str(out)]
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError:
        cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi",
               "-i", "sine=frequency=440:duration=0.2", str(out)]
        subprocess.run(cmd, check=True, capture_output=True)
    return out


def test_real_mp3_true(tmp_path):
    if not shutil.which("ffprobe"):
        pytest.skip("ffprobe not available")
    mp3 = _real_mp3(tmp_path)
    assert validate_media_file(str(mp3)) is True