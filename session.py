import hmac
import json
import os
import secrets


def new_token():
    """Generate a random 32-hex token (16 random bytes)."""
    return secrets.token_hex(16)


def write_handoff(socket_path, port, token, handoff_path):
    """Write the handoff JSON file: {port, token, sock}.

    Creates parent dirs if needed. File written atomically via temp+rename.
    Returns True on success.
    """
    try:
        dir_name = os.path.dirname(handoff_path)
        if dir_name:
            os.makedirs(dir_name, mode=0o700, exist_ok=True)
        # Write to temp file then rename for atomicity
        tmp_path = handoff_path + ".tmp"
        data = {"port": str(port), "token": token, "sock": socket_path}
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(tmp_path, 0o600)
        os.rename(tmp_path, handoff_path)
        return True
    except (OSError, json.JSONEncodeError):
        return False


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