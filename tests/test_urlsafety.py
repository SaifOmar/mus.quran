import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


from catalog import CDN_BASE, audio_url
from urlsafety import (
    COOLDOWN_MS,
    MAX_IDENTIFIER_LENGTH,
    MAX_SURAH_BYTES,
    MAX_URL_LENGTH,
    is_safe_identifier,
    is_safe_reciter,
    is_safe_remote_url,
    is_safe_server_prefix,
    parse_seek_arg,
    parse_surah_arg,
    sanitize_server,
)


def test_safe_identifier():
    ok = ["ar.alafasy", "a.b-c_d.1", "123abc", "a", "a" * 64, "A9_.x"]
    bad = ["", "a" * 65, "a/b", "a\\b", "..", ".", ".hidden", "a b", "a%2f", "a\nb", "عبد", None]
    for s in ok:
        assert is_safe_identifier(s) is True, s
    for s in bad:
        assert is_safe_identifier(s) is False, s


def test_parse_surah_arg():
    ok = {"1": 1, "114": 114, "57": 57}
    for raw, want in ok.items():
        assert parse_surah_arg(raw) == want
    for raw in ["0", "115", "-1", "1junk", "junk1", "01", "1.5", "", " 1",
                "99999999999999999999999999", "+1", "002"]:
        assert parse_surah_arg(raw) is None, raw


def test_parse_seek_arg():
    assert parse_seek_arg("0") == 0
    assert parse_seek_arg("30") == 30
    assert parse_seek_arg("-15") == -15
    for raw in ["+5", "5s", "1.5", "", " -5"]:
        assert parse_seek_arg(raw) is None, raw


def test_safe_server_prefix():
    valid = [
        "https://cdn.islamic.app/quran/audio-surah/",
        "https://server8.mp3quran.net/afs/",
        "https://a.b.c.islamic.app/x/",
        "https://cdn.islamic.app:443/x/",
        "https://cdn.islamic.app:8080/x/",
        "https://cdn.islamic.app/quran",
        "https://islamic.app/x/",
        "https://cdn.islamic.app./x/",
    ]
    for u in valid:
        assert is_safe_server_prefix(u) is True, u

    invalid = [
        "http://cdn.islamic.app/x/",
        "ftp://cdn.islamic.app/x/",
        "//cdn.islamic.app/x/",
        "javascript:alert(1)",
        "https://user:pass@cdn.islamic.app/x/",
        "https://user@cdn.islamic.app/x/",
        "https://cdn.islamic.app/x/?a=1",
        "https://cdn.islamic.app/x/#frag",
        "https://cdn.islamic.app/x/\n/evil",
        "https://cdn.islamic.app/x/\t/evil",
        "https://cdn.islamic.app/x/ y",
        "",
        "   ",
        "https://cdn.islamic.app/" + "a" * 600,
        "https://cdn.islamic%2eapp/x/",
        "https://cdn.islamic.app%2fx/",
        "https://cdn.islamic.app/x%3fy",
        "https://cdn.islamic.app/x%23y",
        "https://user%40x@cdn.islamic.app/",
        "https://cdn.islamic.app/x%5cy",
        "https://cdn.islamic.app:0/x/",
        "https://cdn.islamic.app:65536/x/",
        "https://cdn.islamic.app:01/x/",
        "https://cdn.islamic.app:443a/x/",
        "https://cdn.islamic.app:/x/",
        "https://cdn.islamic.app:-1/x/",
        "https://93.184.216.34/x/",
        "https://evil.com/x/",
        "https://islamic.app.evil.com/x/",
        "https://islamicapp.com/x/",
        "https://localhost/x/",
        "https://foo.local/x/",
        "https://foo.internal/x/",
        "https://foo.localhost/x/",
        "https://intranet/x/",
        "https://127.0.0.1/x/",
        "https://10.0.0.1/x/",
        "https://172.16.0.1/x/",
        "https://172.31.255.255/x/",
        "https://192.168.1.1/x/",
        "https://169.254.0.1/x/",
        "https://100.64.0.1/x/",
        "https://0.0.0.0/x/",
        "https://224.0.0.1/x/",
        "https://255.255.255.255/x/",
        "https://192.0.0.1/x/",
        "https://192.0.2.1/x/",
        "https://198.51.100.1/x/",
        "https://203.0.113.1/x/",
        "https://0177.0.0.1/x/",
        "https://0x7f.0.0.1/x/",
        "https://2130706433/x/",
        "https://127.0.0.01/x/",
        "https://8.8.8.8/x/",
        "https://[::1]/x/",
        "https://[::]/x/",
        "https://[fe80::1]/x/",
        "https://[fc00::1]/x/",
        "https://[::ffff:127.0.0.1]/x/",
        "https://[::ffff:7f00:1]/x/",
        "https://[fe80::1%25eth0]/x/",
        "https://[g::1]/x/",
        "https://2001:db8::1/x/",
        "https://[2001:db8::1]:0/x/",
        "https://[2001:db8::1]:abc/x/",
    ]
    for u in invalid:
        assert is_safe_server_prefix(u) is False, u


def test_sanitize_server():
    assert sanitize_server("https://cdn.islamic.app/quran") == "https://cdn.islamic.app/quran/"
    assert sanitize_server("https://cdn.islamic.app/quran/") == "https://cdn.islamic.app/quran/"
    assert sanitize_server("http://evil.com/") == ""


def test_safe_remote_url():
    assert is_safe_remote_url("https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3") is True
    assert is_safe_remote_url("http://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3") is False


def test_audio_url_default_cdn():
    assert audio_url("ar.alafasy", 1, None) == f"{CDN_BASE}/ar.alafasy/1.mp3"
    assert audio_url("ar.ajamy", 1, None) == f"{CDN_BASE}/ar.ahmedajamy/1.mp3"
    assert audio_url("ar.alafasy", 114, None) != ""
    assert audio_url("ar.alafasy", 115, None) == ""
    assert audio_url("ar.alafasy", 0, None) == ""
    assert audio_url("../etc", 1, None) == ""
    assert audio_url("a/b", 1, None) == ""


def test_audio_url_server():
    rec = {"identifier": "x", "server": "https://server8.mp3quran.net/afs/"}
    assert audio_url("x", 1, rec) == "https://server8.mp3quran.net/afs/001.mp3"
    rec_bad = {"identifier": "x", "server": "http://evil.com/"}
    assert audio_url("x", 1, rec_bad) == ""


def test_safe_reciter():
    good = {"identifier": "ar.alafasy", "server": "https://cdn.islamic.app/x/"}
    assert is_safe_reciter(good) is True
    bad_srv = {"identifier": "ar.alafasy", "server": "http://x/"}
    assert is_safe_reciter(bad_srv) is False
    bad_id = {"identifier": "../x", "server": "https://cdn.islamic.app/x/"}
    assert is_safe_reciter(bad_id) is False
    no_server = {"identifier": "ar.alafasy"}
    assert is_safe_reciter(no_server) is True


def test_constants():
    assert MAX_IDENTIFIER_LENGTH == 64
    assert MAX_URL_LENGTH == 512
    assert MAX_SURAH_BYTES == 314572800
    assert COOLDOWN_MS == 10000