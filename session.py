import errno
import hmac
import json
import os
import secrets
import stat


def new_token():
    """Generate a random 32-hex token (16 random bytes)."""
    return secrets.token_hex(16)


def write_handoff(socket_path, port, token, handoff_path):
    """Write the handoff JSON file: {port, token, sock}.

    Creates parent dirs if needed if private and owner-checked. The temp
    file is created with O_EXCL|O_NOFOLLOW so a planted symlink can never
    redirect the write; the publish step is an atomic rename. Returns True
    on success.
    """
    try:
        dir_name = os.path.dirname(handoff_path)
        if dir_name:
            os.makedirs(dir_name, mode=0o700, exist_ok=True)
            st = os.lstat(dir_name)
            if not stat.S_ISDIR(st.st_mode):
                return False
            if st.st_uid != os.geteuid():
                return False
        tmp_path = handoff_path + ".tmp"
        data = {"port": str(port), "token": token, "sock": socket_path}
        tmp_name = create_exclusive_tmp(tmp_path)
        if not tmp_name:
            return False
        try:
            with open(tmp_name, "w", encoding="utf-8") as f:
                json.dump(data, f)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp_name, handoff_path)
        finally:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
        return True
    except (OSError, json.JSONEncodeError):
        return False


def create_exclusive_tmp(tmp_path):
    """Create tmp_path with O_EXCL|O_NOFOLLOW. Returns the path or None.

    Shared by write_handoff and RangeCache sidecar writes: a pre-existing
    regular file (stale from a crashed writer) is removed and retried once;
    a pre-existing symlink is never followed and causes refusal.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    for _ in range(2):
        try:
            fd = os.open(tmp_path, flags, 0o600)
            os.close(fd)
            return tmp_path
        except OSError as e:
            if e.errno != errno.EEXIST:
                return None
            try:
                st = os.lstat(tmp_path)
            except OSError:
                continue
            if stat.S_ISLNK(st.st_mode):
                return None
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                return None
            try:
                os.unlink(tmp_path)
            except OSError:
                return None
    return None


def read_handoff(handoff_path):
    """Read the handoff JSON file.

    Returns dict {port, token, sock} or None on failure.
    """
    if not os.path.exists(handoff_path):
        return None
    try:
        with open(handoff_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return None
        port = data.get("port")
        token = data.get("token")
        sock = data.get("sock")
        if not port or not token or not sock:
            return None
        return {"port": port, "token": token, "sock": sock}
    except (json.JSONDecodeError, OSError, ValueError):
        return None


def compare_tokens(token_a, token_b):
    """Constant-time comparison of two token strings.

    Returns True if equal, False otherwise (timing-safe).
    """
    if not isinstance(token_a, str) or not isinstance(token_b, str):
        return False
    return hmac.compare_digest(token_a, token_b)


def derive_socket_path(mpv_runtime_dir):
    """Derive the unix socket path from the mpv runtime dir.

    Falls under mpvRuntimeDir/mus-quran/mpv.sock,
    or HOME/.cache/omarchy/quran/run/mpv.sock if XDG_RUNTIME_DIR unset.
    """
    if mpv_runtime_dir:
        return os.path.join(mpv_runtime_dir, "mus-quran", "mpv.sock")
    home = os.environ.get("HOME", "")
    if home:
        return os.path.join(home, ".cache", "omarchy", "quran", "run", "mpv.sock")
    return ""


def is_safe_socket_path(socket_path, mpv_runtime_dir):
    """Validate socket path is absolute and under mpvRuntimeDir.

    No '..', no control characters, within allowed directory.
    """
    if not socket_path:
        return False
    if not os.path.isabs(socket_path):
        return False
    if ".." in socket_path:
        return False
    if any(ord(c) < 32 for c in socket_path):
        return False
    expected_prefix = mpv_runtime_dir + "/"
    if socket_path.startswith(expected_prefix):
        return True
    # Also accept fallback under cache dir when XDG_RUNTIME_DIR unset
    # This mirrors the QML _isSafeSocketPath logic
    home = os.environ.get("HOME", "")
    return bool(home and socket_path.startswith(home + "/.cache/omarchy/quran/run/"))