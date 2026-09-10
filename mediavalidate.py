import os
import subprocess


def validate_media_file(filepath, require_nonempty=True):
    """Validate a media file using file(1) + ffprobe.

    Mirrors validate_media.sh semantics:
    - must be a regular file (not symlink)
    - file(1) report audio/* or application/octet-stream
    - ffprobe fails-open if absent, fails-closed if present and rejects

    Returns True if valid, False otherwise.
    """
    if not filepath or not os.path.isfile(filepath):
        return False
    if require_nonempty and os.path.getsize(filepath) == 0:
        return False
    if os.path.islink(filepath):
        return False

    try:
        result = subprocess.run(
            ["file", "--mime-type", "-b", filepath],
            capture_output=True, text=True, timeout=10, check=False,
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
             "-show_entries", "stream=codec_type",
             "-of", "default=noprint_wrappers=1", filepath],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if result.returncode != 0:
            return False
        output = result.stdout.strip().lower()
        if "codec_type" in output and "audio" not in output:
            return False
    except (OSError, subprocess.TimeoutExpired):
        pass

    return True