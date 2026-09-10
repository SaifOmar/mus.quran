import os
import re
import time
import urllib.error
import urllib.request

from catalog import MAX_SURAH_BYTES
from urlsafety import is_safe_identifier

RECITER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
WRITE_BUF = 256 * 1024
OVERALL_TIMEOUT = 300
HEAD_TIMEOUT = 30


class FetchError(Exception):
    pass


class ErrComplete(FetchError):
    """The local file already exists and matches the remote size (fetch.go
    ErrComplete()): counted as success by the caller."""

    def __init__(self):
        super().__init__("fetch: already complete")


def fetch(dialer, dest_root, reciter, surah, url_builder, max_bytes=0, on_progress=None):
    """Download one surah into dest_root/<reciter>/<n>.mp3 (fetch.go port).

    - HEAD probes the remote (audio/* or application/octet-stream only,
      0 < size <= max); a local file of the exact remote size returns
      ErrComplete.
    - An existing <n>.mp3.part* file smaller than the remote is resumed via a
      conditional Range GET; a stale part (>= remote) is dropped.
    - Staging uses a unique temp name and an atomic rename.
    """
    if not is_safe_identifier(reciter) or reciter in (".", ".."):
        raise FetchError("fetch: invalid reciter identifier")
    if surah < 1 or surah > 114:
        raise FetchError("fetch: surah out of range")
    cap = max_bytes if max_bytes > 0 else MAX_SURAH_BYTES

    rec_dir = _resolve_reciter_dir(dest_root, reciter)
    target = os.path.join(rec_dir, f"{surah}.mp3")

    remote, u = _probe(dialer, url_builder, surah, cap)

    if os.path.islink(target):
        raise FetchError("fetch: target is a symlink")
    if os.path.isfile(target) and os.path.getsize(target) == remote:
        raise ErrComplete()

    part, part_size = _newest_part(rec_dir, surah)
    if part and part_size >= remote:
        try:
            os.remove(part)
        except OSError:
            pass
        part, part_size = "", 0

    req = urllib.request.Request(u, headers={"Accept-Encoding": "identity"})
    if part:
        req.add_header("Range", f"bytes={part_size}-")
    resp = _dial_with_timeout(dialer, req, OVERALL_TIMEOUT)

    start = 0
    if resp.status == 200:
        part_size = 0
    elif resp.status == 206:
        start = part_size
    else:
        resp.close()
        raise FetchError(f"fetch: origin returned status {resp.status}")

    import tempfile
    fd, tmp_name = tempfile.mkstemp(prefix=f"{surah}.mp3.part.", dir=rec_dir)
    tmp = os.fdopen(fd, "wb")
    cleanup = True
    try:
        if start > 0:
            with open(part, "rb") as pf:
                while True:
                    chunk = pf.read(WRITE_BUF)
                    if not chunk:
                        break
                    tmp.write(chunk)

        written = start
        last_emit = time.monotonic()
        if on_progress:
            on_progress(start, remote)
        while True:
            chunk = resp.read(WRITE_BUF)
            if chunk:
                tmp.write(chunk)
                written += len(chunk)
                if on_progress and (time.monotonic() - last_emit > 0.2):
                    on_progress(written, remote)
                    last_emit = time.monotonic()
                continue
            break

        if written != remote:
            raise FetchError(f"fetch: size mismatch (got {written}, want {remote})")
        tmp.flush()
        os.fsync(tmp.fileno())
        os.fchmod(tmp.fileno(), 0o600)
        tmp.close()
        os.rename(tmp_name, target)
        tmp_name = ""
        cleanup = False
        if on_progress:
            on_progress(remote, remote)
    finally:
        if cleanup or tmp_name:
            try:
                tmp.close()
            except (OSError, ValueError):
                pass
            try:
                os.remove(tmp_name)
            except OSError:
                pass
        resp.close()


def _probe(dialer, url_builder, n, cap):
    u = url_builder(n)
    if not u:
        raise FetchError("fetch: invalid origin URL")
    req = urllib.request.Request(u, method="HEAD")
    resp = _dial_with_timeout(dialer, req, HEAD_TIMEOUT)
    try:
        if resp.status != 200:
            raise FetchError(f"fetch: origin head status {resp.status}")
        ct = (resp.headers.get("Content-Type", "") or "").lower()
        if not ct.startswith("audio/") and ct != "application/octet-stream":
            raise FetchError(f"fetch: origin content type {ct!r} rejected")
        cl = resp.headers.get("Content-Length")
        if not cl:
            raise FetchError("fetch: origin missing content-length")
        size = int(cl)
        if size <= 0:
            raise FetchError("fetch: origin missing content-length")
        if size > cap:
            raise FetchError(f"fetch: origin size {size} exceeds cap {cap}")
        return size, u
    finally:
        resp.close()


def _dial_with_timeout(dialer, req, timeout):
    try:
        return dialer.opener.open(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        raise FetchError(f"fetch: origin status {e.code}") from e
    except Exception as e:
        raise FetchError(f"fetch: {e}") from e


def _newest_part(rec_dir, surah):
    try:
        matches = [f for f in os.listdir(rec_dir) if f.startswith(f"{surah}.mp3.part")]
    except OSError:
        return "", 0
    newest, newest_size = "", 0
    for name in matches:
        path = os.path.join(rec_dir, name)
        try:
            if not os.path.islink(path) and os.path.isfile(path):
                st = os.stat(path)
                if newest == "" or st.st_mtime > os.stat(os.path.join(rec_dir, newest)).st_mtime:
                    newest, newest_size = name, st.st_size
        except OSError:
            continue
    if newest and newest_size < 0:
        return "", 0
    return os.path.join(rec_dir, newest), newest_size


def _resolve_reciter_dir(dest_root, reciter):
    if not os.path.isabs(dest_root) or ".." in dest_root:
        raise FetchError("fetch: invalid destination root")
    os.makedirs(dest_root, mode=0o700, exist_ok=True)
    root = os.path.realpath(dest_root)
    rec_dir = os.path.join(root, reciter)
    os.makedirs(rec_dir, mode=0o700, exist_ok=True)
    if os.path.realpath(rec_dir) != os.path.join(root, reciter):
        raise FetchError("fetch: reciter directory escapes destination root")
    return rec_dir