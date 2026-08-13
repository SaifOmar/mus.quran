#!/usr/bin/env bash
# Download Quran surahs for a reciter from the islamic.app CDN.
# Usage:
#   download.sh <reciter-identifier>                  # whole mushaf (1..114)
#   download.sh <reciter-identifier> <n>              # single surah n (1..114)
#   download.sh <reciter-identifier> --only a,b,c     # just those surahs
#   download.sh <reciter-identifier> ... --dest PATH  # write files under PATH
# Default dest is ~/.local/state/omarchy/quran/<reciter> (explicit downloads).
# `--dest` is used for the streaming cache (the cache directory).
# Files are downloaded to `NNN.mp3.part` and renamed on success (atomic).
# Stdout progress: `progress <done>/<total>` lines (total = work-set size),
# then a final `complete <done> <failed>` line. `failed <n>` lines go to stderr.
# Exit codes: 0 = all requested files present, 1 = at least one failed.
set -u

# --- argument parsing -------------------------------------------------------
RECITER=""
DEST=""
ONLY=""
SERVER=""
POSITIONALS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      DEST="${2:-}"
      shift 2
      ;;
    --only)
      ONLY="${2:-}"
      shift 2
      ;;
    --server)
      SERVER="${2:-}"
      shift 2
      ;;
    *)
      POSITIONALS="${POSITIONALS:+${POSITIONALS} }$1"
      shift
      ;;
  esac
done

set -- $POSITIONALS
RECITER="${1:-}"
N="${2:-}"

if [[ -z "$RECITER" ]]; then
  echo "usage: download.sh <reciter-identifier> [surah-number|--only a,b,c] [--dest PATH] [--server URL]" >&2
  exit 2
fi

# Validate reciter id (dotted identifier, letters/digits/dots/dashes only).
if [[ ! "$RECITER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid reciter identifier" >&2
  exit 2
fi

BASE="https://cdn.islamic.app/quran/audio-surah"
if [[ -z "$DEST" ]]; then
  DEST="${HOME}/.local/state/omarchy/quran/${RECITER}"
fi
mkdir -p "$DEST"

# validate_surah <n> — exits 2 on invalid input.
validate_surah() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > 114 )); then
    echo "invalid surah number: $n" >&2
    exit 2
  fi
}

url_for() {
  local n="$1"
  if [[ -n "$SERVER" ]]; then
    local padded
    padded="$(printf "%03d" "$n")"
    echo "${SERVER}${padded}.mp3"
  else
    local provider_id="$RECITER"
    [[ "$provider_id" == "ar.ajamy" ]] && provider_id="ar.ahmedajamy"
    echo "${BASE}/${provider_id}/${n}.mp3"
  fi
}

# remote_size <n> — content length of the CDN file, or empty on failure.
remote_size() {
  local n="$1"
  local target
  target="$(url_for "$n")"
  curl -fsSL --max-time 15 -I "$target" \
    | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="content-length" {gsub(/[^0-9]/,"",$2); print $2}' \
    | tail -1
}

# complete <n> — 1 if the local file exists and matches the remote size.
complete() {
  local n="$1"
  local file="${DEST}/${n}.mp3"
  [[ -f "$file" ]] || return 1
  local want
  want="$(remote_size "$n")"
  [[ -n "$want" ]] || return 1
  local have
  have="$(stat -c%s "$file")"
  [[ "$have" -eq "$want" ]]
}

# fetch <n> — download one surah (resumable), echoing progress lines.
fetch() {
  local n="$1"
  if complete "$n"; then
    return 0
  fi
  local target
  target="$(url_for "$n")"
  if curl -fsSL --retry 3 -C - "$target" -o "${DEST}/${n}.mp3.part"; then
    mv "${DEST}/${n}.mp3.part" "${DEST}/${n}.mp3"
    return 0
  else
    rm -f "${DEST}/${n}.mp3.part"
    echo "failed ${n}" >&2
    return 1
  fi
}

# --- work set ---------------------------------------------------------------
TOTAL=0
declare -a SET
if [[ -n "$ONLY" ]]; then
  # --only a,b,c — validate each number and keep the order given.
  IFS=',' read -r -a RAW <<< "$ONLY"
  for n in "${RAW[@]}"; do
    n="${n//[[:space:]]/}"
    [[ -z "$n" ]] && continue
    validate_surah "$n"
    SET[$TOTAL]="$n"
    TOTAL=$((TOTAL + 1))
  done
  if (( TOTAL == 0 )); then
    echo "no surahs in --only list" >&2
    exit 2
  fi
elif [[ -n "$N" ]]; then
  validate_surah "$N"
  TOTAL=1
  SET[0]="$N"
else
  for n in $(seq 1 114); do
    SET[$((n - 1))]="$n"
  done
  TOTAL=114
fi

# --- download ---------------------------------------------------------------
DONE=0
FAILED=0
for n in "${SET[@]}"; do
  if fetch "$n"; then
    DONE=$((DONE + 1))
    echo "progress ${DONE}/${TOTAL}"
  else
    FAILED=$((FAILED + 1))
  fi
done

echo "complete ${DONE} ${FAILED}"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
