import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


from catalog import CDN_BASE, audio_url, parse_reciters


def _cat(reciters):
    return json.dumps({"version": 1, "reciters": reciters})


def test_parse_reciters_sanitize(tmp_path):
    cat = tmp_path / "quran.json"
    cat.write_text(_cat([
        {"identifier": "ar.alafasy", "name": "Alafasy"},
        {"identifier": "ar.hudhaify", "server": "https://server8.mp3quran.net/hud/"},
        {"identifier": "ar.jibreel", "server": "https://server6.mp3quran.net/thubti/"},
        {"identifier": "../evil"},
        {"identifier": "bad-srv", "server": "http://evil.com/"},
        {"identifier": "empty-srv", "server": ""},
        {"identifier": "toolong", "englishName": "x" * 201},
    ]))
    ids = [r["identifier"] for r in parse_reciters(str(cat))]
    assert ids == ["ar.alafasy", "ar.hudhaify", "ar.jibreel"]
    by_id = {r["identifier"]: r for r in parse_reciters(str(cat))}
    assert by_id["ar.hudhaify"]["server"] == "https://server8.mp3quran.net/hud/"
    assert by_id["ar.alafasy"]["server"] == ""


def test_parse_reciters_caps(tmp_path):
    cat = tmp_path / "quran.json"
    cat.write_text(_cat([{"identifier": f"r{i}"} for i in range(1050)]))
    assert len(parse_reciters(str(cat))) == 1000


def test_parse_reciters_bad_file(tmp_path):
    assert parse_reciters(str(tmp_path / "missing.json")) == []
    bad = tmp_path / "bad.json"
    bad.write_text("{corrupt")
    assert parse_reciters(str(bad)) == []


def test_audio_url_default_and_server():
    # default CDN, unpadded (Go catalog_test parity)
    assert audio_url("ar.alafasy", 1, {"identifier": "ar.alafasy", "server": ""}) == f"{CDN_BASE}/ar.alafasy/1.mp3"
    assert audio_url("ar.ajamy", 1, None) == f"{CDN_BASE}/ar.ahmedajamy/1.mp3"
    # server-backed, padded NNN.mp3
    rec = {"identifier": "mp3quran_49", "server": "https://server6.mp3quran.net/thubti/"}
    assert audio_url("mp3quran_49", 1, rec) == "https://server6.mp3quran.net/thubti/001.mp3"
    assert audio_url("mp3quran_49", 114, rec) == "https://server6.mp3quran.net/thubti/114.mp3"
    # invalid inputs rejected
    assert audio_url("ar.alafasy", 115, None) == ""
    assert audio_url("a/b", 1, None) == ""