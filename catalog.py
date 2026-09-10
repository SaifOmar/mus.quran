import json
import os
import subprocess
import urllib.parse

from urlsafety import (
    is_safe_identifier,
    is_safe_remote_url,
    sanitize_server,
)

CDN_BASE = "https://cdn.islamic.app/quran/audio-surah"
MAX_SURAH_BYTES = 314572800

DEFAULT_RECITER = "ar.alafasy"


def _pad3(n):
    s = str(n)
    while len(s) < 3:
        s = "0" + s
    return s


def _host_from_url(url):
    """Extract hostname from a URL for host allowlist checks."""
    parsed = urllib.parse.urlparse(url)
    return parsed.hostname or ""


def parse_reciters(json_path):
    """Parse quran.json reciters list."""
    if not os.path.exists(json_path):
        return []
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return []

    if not data:
        return []

    reciters = []
    if isinstance(data, dict) and data.get("reciters"):
        reciters = data["reciters"]
    elif isinstance(data, list):
        reciters = data

    out = []
    max_reciters = 1000
    max_name_len = 200
    for r in reciters:
        if len(out) >= max_reciters:
            break
        if not r or not isinstance(r, dict):
            continue
        identifier = str(r.get("identifier", "")).strip()
        if not is_safe_identifier(identifier):
            continue
        name = str(r.get("name", "") or "").strip()
        english_name = str(r.get("englishName", "") or "").strip()
        if len(name) > max_name_len or len(english_name) > max_name_len:
            continue

        server = r.get("server")
        if server == "":
            continue
        if server is not None:
            sanitized = sanitize_server(str(server))
            if sanitized == "":
                continue
        else:
            sanitized = ""

        out.append({
            "identifier": identifier,
            "id": r.get("id", ""),
            "name": name,
            "englishName": english_name,
            "server": sanitized,
        })

    out.sort(key=lambda x: (x["englishName"] or "").lower())
    return out


def parse_surahs(json_path):
    """Parse quran.json surahs list."""
    if not os.path.exists(json_path):
        return []
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return []

    if not data:
        return []

    out = []
    for s in data:
        if not s or not isinstance(s, dict):
            continue
        if "number" not in s:
            continue
        try:
            num = int(s["number"])
            if num < 1 or num > 114:
                continue
        except (ValueError, TypeError):
            continue
        out.append({
            "number": num,
            "name": str(s.get("name", "") or ""),
            "transliteration": str(s.get("transliteration", "") or ""),
            "type": str(s.get("type", "") or ""),
            "totalVerses": int(s.get("total_verses", 0) or 0),
            "translations": s.get("translations", {}) or {},
        })
    out.sort(key=lambda x: x["number"])
    return out


def audio_url(reciter_id, surah_number, reciter_obj):
    """Build audio URL for a given reciter and surah number."""
    n = int(surah_number)
    if not (1 <= n <= 114):
        return ""

    if reciter_obj and isinstance(reciter_obj, dict):
        server = reciter_obj.get("server", "")
        if server:
            sanitized = sanitize_server(server)
            if sanitized:
                url = sanitized + _pad3(n) + ".mp3"
                if is_safe_remote_url(url):
                    return url
            return ""

    provider_id = reciter_id
    if provider_id == "ar.ajamy":
        provider_id = "ar.ahmedajamy"
    if not is_safe_identifier(provider_id):
        return ""

    url = f"{CDN_BASE}/{provider_id}/{n}.mp3"
    if is_safe_remote_url(url):
        return url

    return ""


def validate_media(data_dir, reciter_id, surah_number):
    """Validate a downloaded surah file using file(1) + ffprobe.

    Returns True if valid, False otherwise.
    """
    if not isinstance(data_dir, str) or ".." in data_dir:
        return False
    if not is_safe_identifier(reciter_id):
        return False
    try:
        n = int(surah_number)
        if n < 1 or n > 114:
            return False
    except (ValueError, TypeError):
        return False

    filepath = os.path.join(data_dir, reciter_id, _pad3(n) + ".mp3")
    if not os.path.isfile(filepath):
        return False

    try:
        result = subprocess.run(
            ["file", "--mime-type", "-b", filepath],
            capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode == 0:
            mime = result.stdout.strip()
            if not (mime.startswith("audio/") or mime == "application/octet-stream"):
                return False
    except (OSError, subprocess.TimeoutExpired):
        pass

    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_type", "-of", "default=noprint_wrappers=1",
             filepath],
            capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode != 0:
            return False
        output = result.stdout.strip().lower()
        if "codec_type" in output and "audio" not in output:
            return False
    except (OSError, subprocess.TimeoutExpired):
        pass

    return True
