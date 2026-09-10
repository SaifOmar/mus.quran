import re

# Constants at module level for easy access
SAFE_IDENTIFIER_RE = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"
ALLOWED_AUDIO_HOST_SUFFIXES = ["mp3quran.net", "islamic.app"]
MAX_URL_LENGTH = 512
MAX_IDENTIFIER_LENGTH = 64
MAX_SURAH_BYTES = 314572800
COOLDOWN_MS = 10000

# Pre-compiled regexes for performance
SAFE_IDENTIFIER_PATTERN = re.compile(SAFE_IDENTIFIER_RE)
ENCODED_DELIM_RE = re.compile(r"%(?:2e|2f|3f|23|40|5c)", re.IGNORECASE)
CONTROL_RE = re.compile(r"[\x00-\x20\x7f]")
PORT_RE = re.compile(r"^[0-9]+$")
LEADING_ZERO_RE = re.compile(r"^0[0-9]+$")
IPV4_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")

# Blocked IP ranges (network, mask)
BLOCKED_IPV4_PREFIXES = [
    (0, 8), (10, 8), (127, 8), (169, 254, 16),
    (172, 16, 12), (192, 168, 16), (100, 64, 10),
    (192, 0, 0, 24), (192, 0, 2, 24), (198, 51, 100, 24),
    (203, 0, 113, 24),
]
BLOCKED_IPV4_MULTICAST = (224, 240)

BLOCKED_IPV6_ADDRESSES = ["::", "::1", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1"]
LINK_LOCAL_PREFIX = ("fe8", "fe9", "fea", "feb", "fec", "fc")
ULA_PREFIX = ("fd",)

IPV4_MAPPED_MARKERS = ["ffff:", ":ffff"]


def _strip_trailing_dots(host):
    h = str(host)
    while h and h[-1] == ".":
        h = h[:-1]
    return h


def _parse_ipv4(host):
    h = _strip_trailing_dots(host)
    parts = h.split(".")
    if len(parts) < 2 or len(parts) > 4:
        return None
    nums = []
    for p in parts:
        if not p.isdigit():
            return None
        if len(p) > 1 and p[0] == "0":
            return None
        n = int(p, 10)
        if n < 0 or n > 255:
            return None
        nums.append(n)
    while len(nums) < 4:
        nums.insert(0, 0)
    return nums


def _looks_like_ipv4(host):
    h = _strip_trailing_dots(str(host).lower())
    parts = h.split(".")
    if len(parts) < 2 or len(parts) > 4:
        return False
    for p in parts:
        if not re.match(r"^(0x[0-9a-f]+|0[0-7]*|[0-9]+)$", p, re.IGNORECASE):
            return False
    return True


def _is_blocked_ipv4(parts):
    if not parts or len(parts) != 4:
        return True
    a, b, c = parts[0], parts[1], parts[2]
    if a in (0, 10, 127):
        return True
    if a == 169 and b == 254:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    if a == 100 and 64 <= b <= 127:
        return True
    if a >= 224 and a <= 255:
        return True
    if a == 192 and b == 0 and c == 0:
        return True
    if a == 192 and b == 0 and c == 2:
        return True
    if a == 198 and b == 51 and c == 100:
        return True
    return a == 203 and b == 0 and c == 113


def is_blocked_host(host):
    if not host:
        return True
    h = _strip_trailing_dots(str(host).lower())
    if not h:
        return True
    if h in ("localhost", "local"):
        return True
    if h.endswith(".localhost"):
        return True
    if ".local" in h or ".internal" in h:
        return True
    if ":" in h:
        if h in BLOCKED_IPV6_ADDRESSES:
            return True
        for marker in IPV4_MAPPED_MARKERS:
            if marker in h:
                return True
        if re.search(r":\d+\.\d+\.\d+\.\d+$", h):
            return True
        return bool(
            any(h.startswith(p) for p in LINK_LOCAL_PREFIX)
            or any(h.startswith(p) for p in ULA_PREFIX)
        )
    if "." not in h:
        return True
    if _looks_like_ipv4(h):
        parts = _parse_ipv4(h)
        if parts is None:
            return True
        return _is_blocked_ipv4(parts)
    return False


def is_allowed_audio_host(host):
    if not host:
        return False
    h = _strip_trailing_dots(str(host).lower())
    for suffix in ALLOWED_AUDIO_HOST_SUFFIXES:
        if h == suffix:
            return True
        if len(h) > len(suffix) + 1 and h[-(len(suffix) + 1)] == "." and h.endswith(suffix):
            return True
    return False


def _is_valid_port(p):
    if not p or not PORT_RE.match(p):
        return False
    if LEADING_ZERO_RE.match(p):
        return False
    n = int(p, 10)
    return 1 <= n <= 65535


def is_safe_server_prefix(value):
    if not isinstance(value, str):
        return False
    url = value.strip()
    if not url or len(url) > MAX_URL_LENGTH:
        return False
    if CONTROL_RE.search(url):
        return False
    if ENCODED_DELIM_RE.search(url):
        return False
    if "#" in url or "?" in url:
        return False
    m = re.match(r"^(https)://([^/?#]+)", url)
    if not m:
        return False
    authority = m[2]
    if "@" in authority:
        return False
    host = authority
    if host.startswith("["):
        close = authority.find("]")
        if close == -1:
            return False
        inner = authority[1:close]
        if not re.match(r"^[0-9a-fA-F:]+$", inner):
            return False
        if ":" not in inner:
            return False
        if "%" in inner:
            return False
        host = inner
        after = authority[close + 1:]
        if after:
            if after[0] != ":":
                return False
            if not _is_valid_port(after[1:]):
                return False
    else:
        last_colon = host.rfind(":")
        if last_colon != -1:
            if not _is_valid_port(host[last_colon + 1:]):
                return False
            host = host[:last_colon]
    if not re.match(r"^[A-Za-z0-9.:-]+$", host) and ":" not in host:
        return False
    if is_blocked_host(host):
        return False
    return is_allowed_audio_host(host)


def sanitize_server(value):
    if not is_safe_server_prefix(value):
        return ""
    url = str(value).strip()
    if not url.endswith("/"):
        url += "/"
    return url


def is_safe_remote_url(url):
    return is_safe_server_prefix(url)


def is_safe_identifier(id):
    if not isinstance(id, str) or not id or len(id) > MAX_IDENTIFIER_LENGTH:
        return False
    if not SAFE_IDENTIFIER_PATTERN.match(id):
        return False
    return id not in (".", "..")


def is_safe_reciter_arg(id):
    return is_safe_identifier(id)


def parse_surah_arg(s):
    if not isinstance(s, str):
        return None
    if not s.isdigit():
        return None
    if len(s) > 1 and s[0] == "0":
        return None
    n = int(s, 10)
    if n < 1 or n > 114:
        return None
    return n


def parse_seek_arg(s):
    if not isinstance(s, str):
        return None
    if not re.match(r"^-?[0-9]+$", s):
        return None
    v = int(s, 10)
    return v


def is_safe_reciter(reciter):
    if not reciter:
        return False
    if not is_safe_identifier(reciter.get("identifier", "")):
        return False
    srv = reciter.get("server")
    return not (srv is not None and srv != "" and sanitize_server(srv) == "")
