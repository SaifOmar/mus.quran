#!/usr/bin/env bash
# Tests for validate_media.sh. ffmpeg is used to generate a real mp3 so the
# ffprobe deep-probe path is exercised; a "no file(1)" run uses a mockbin
# PATH without `file`.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/validate_media.sh"
WORK="$(mktemp -d /tmp/quran-validate-test.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0
t() { # t <name> <expected-exit> <cmd...>
  local name="$1" want="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if (( got == want )); then PASS=$((PASS+1)); echo "PASS $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name (exit $got, want $want)"; fi
}
ok() {
  local name="$1"
  shift
  if "$@"; then PASS=$((PASS+1)); echo "PASS $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}

REAL="$WORK/real.mp3"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a libmp3lame -y "$REAL" 2>/dev/null
ok "fixture: ffmpeg generated an mp3" test -s "$REAL"

# ---------------------------------------------------------------------------
# arg validation
# ---------------------------------------------------------------------------
t "usage: no args" 2 "$SCRIPT"
t "usage: two args" 2 "$SCRIPT" a b
t "usage: empty arg" 2 "$SCRIPT" ""

# ---------------------------------------------------------------------------
# file shape
# ---------------------------------------------------------------------------
t "missing file" 1 "$SCRIPT" "$WORK/nope.mp3"
: > "$WORK/empty.mp3"
t "empty file" 1 "$SCRIPT" "$WORK/empty.mp3"
printf 'not audio at all' > "$WORK/text.mp3"
t "text file rejected" 1 "$SCRIPT" "$WORK/text.mp3"
ln -s "$REAL" "$WORK/link.mp3"
t "symlink rejected" 1 "$SCRIPT" "$WORK/link.mp3"
mkdir -p "$WORK/dir.mp3"
t "directory rejected" 1 "$SCRIPT" "$WORK/dir.mp3"

# ---------------------------------------------------------------------------
# happy path (file + ffprobe both present)
# ---------------------------------------------------------------------------
t "real mp3 accepted" 0 "$SCRIPT" "$REAL"

# ---------------------------------------------------------------------------
# application/octet-stream tolerated by mime check
# ---------------------------------------------------------------------------
cp "$REAL" "$WORK/octet.bin"
if command -v file >/dev/null 2>&1 && [[ "$(file -b --mime-type "$WORK/octet.bin")" == "application/octet-stream" ]]; then
  t "octet-stream accepted" 0 "$SCRIPT" "$WORK/octet.bin"
else
  echo "SKIP octet-stream accepted (file(1) classifies the fixture as audio/*)"
fi

# ---------------------------------------------------------------------------
# fail closed: no file(1) on PATH
# ---------------------------------------------------------------------------
link_bins() { # link_bins <dir> <skip...> — symlink every available command
  local dir="$1" skip
  shift
  local b
  for b in file ffprobe awk basename cat chmod cp dirname echo find grep head ls mkdir mv printf readlink rm sed sort stat tail test tr true uname which; do
    for skip in "$@"; do [[ "$b" == "$skip" ]] && b=""; done
    [[ -n "$b" ]] || continue
    if command -v "$b" >/dev/null 2>&1; then
      ln -s "$(command -v "$b")" "$dir/$b"
    fi
  done
}
NOPATH_DIR="$WORK/nofile"
mkdir -p "$NOPATH_DIR"
link_bins "$NOPATH_DIR" file ffprobe
t "missing file(1): fail closed" 1 env "PATH=$NOPATH_DIR" "$(command -v bash)" "$SCRIPT" "$REAL"

# ffprobe missing is fine as long as file(1) passes
NOFFPATH_DIR="$WORK/noffprobe"
mkdir -p "$NOFFPATH_DIR"
link_bins "$NOFFPATH_DIR" ffprobe
t "missing ffprobe: real mp3 accepted" 0 env "PATH=$NOFFPATH_DIR" "$(command -v bash)" "$SCRIPT" "$REAL"
t "missing ffprobe: text file still rejected" 1 env "PATH=$NOFFPATH_DIR" "$(command -v bash)" "$SCRIPT" "$WORK/text.mp3"
ok "mockbin: file(1) present in no-ffprobe dir" test -x "$NOFFPATH_DIR/file"

echo
echo "validate_media.sh: $PASS passed, $FAIL failed"
(( FAIL == 0 ))