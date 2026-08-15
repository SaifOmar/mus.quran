#!/usr/bin/env bash
# validate_media.sh <file> — media validation for downloaded/cached audio.
#
# Exit 0 only when ALL of the following hold:
#   - the file exists, is a regular file (not a symlink), and is non-empty
#   - file(1) reports an audio/* or application/octet-stream MIME type
#   - ffprobe (when available) can parse the file's duration
#
# Fails closed: if file(1) is missing, or ffprobe is present but rejects the
# file, the exit code is non-zero. Callers treat non-zero as "invalid" and
# drop the file from the download/cache maps (and delete it where applicable).
set -u

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: validate_media.sh <file>" >&2
  exit 2
fi
FILE="$1"

# Symlinks and non-regular files are rejected out of hand.
if [[ ! -f "$FILE" || -L "$FILE" ]]; then
  exit 1
fi

if [[ ! -s "$FILE" ]]; then
  exit 1
fi

if ! command -v file >/dev/null 2>&1; then
  echo "validate_media: file(1) not available — failing closed" >&2
  exit 1
fi

MTYPE="$(file -b --mime-type "$FILE" 2>/dev/null)"
case "${MTYPE,,}" in
  audio/*|application/octet-stream) : ;;
  *)
    echo "validate_media: unexpected mime type '$MTYPE'" >&2
    exit 1
    ;;
esac

if command -v ffprobe >/dev/null 2>&1; then
  if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FILE" >/dev/null 2>&1; then
    echo "validate_media: ffprobe rejected the file" >&2
    exit 1
  fi
fi

exit 0