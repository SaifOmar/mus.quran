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

# --- security limits -------------------------------------------------------
# Per-surah cap (~300 MB) so an oversized/malicious URL can't exhaust disk.
MAX_SURAH_BYTES=314572800
# Only these CDN suffixes may appear in a catalog --server URL.
# A compromised catalog must not point curl/mpv at arbitrary hosts.
ALLOWED_HOST_PATTERNS='mp3quran.net|*.mp3quran.net|islamic.app|*.islamic.app'

# blocked_host <host> — exit 0 if the host is an internal/loopback/link-local
# literal or an obviously-internal hostname (localhost, *.local, *.internal,
# *.localhost, single-label, IPv4-mapped IPv6, short/hex/octal IPv4).
blocked_host() {
  local h="$1"
  [[ -z "$h" ]] && return 0
  h="${h,,}"
  h="${h%.}"
  [[ -z "$h" ]] && return 0
  [[ "$h" == "localhost" || "$h" == "local" || "$h" == *.localhost ]] && return 0
  [[ "$h" == *".local"* || "$h" == *".internal"* ]] && return 0
  if [[ "$h" == *":"* ]]; then
    [[ "$h" == "::" || "$h" == "::1" || "$h" == "0:0:0:0:0:0:0:1" || "$h" == "0:0:0:0:0:0:0:0" ]] && return 0
    # IPv4-mapped / IPv4-compatible (e.g. ::ffff:127.0.0.1)
    [[ "$h" == *ffff:* || "$h" == *:ffff* ]] && return 0
    [[ "$h" == *"."* ]] && return 0
    case "$h" in
      fe8*|fe9*|fea*|feb*|fec*|fc*|fd*) return 0 ;;
    esac
    return 1
  fi
  [[ "$h" != *"."* ]] && return 0
  local IFS='.'
  local -a o=($h)
  # Only dotted-quad/numeric-looking hosts are IPv4 literals; ordinary
  # hostnames (e.g. server6.mp3quran.net) must pass through unblocked.
  local part looks=1
  for part in "${o[@]}"; do
    if [[ ! "$part" =~ ^(0x[0-9a-f]+|0[0-7]*|[0-9]+)$ ]]; then looks=0; break; fi
  done
  (( looks == 0 )) && return 1
  # Hex/octal/short IPv4 encodings are treated as blocked.
  (( ${#o[@]} < 2 || ${#o[@]} > 4 )) && return 0
  for part in "${o[@]}"; do
    [[ "$part" =~ ^0x ]] && return 0
    [[ "$part" =~ ^0[0-9]+$ ]] && return 0
  done
  local a=0 b=0 c=0 d=0
  if (( ${#o[@]} == 4 )); then
    a="${o[0]}"; b="${o[1]}"; c="${o[2]}"; d="${o[3]}"
  elif (( ${#o[@]} == 3 )); then
    a="${o[0]}"; b="${o[1]}"; d="${o[2]}"
  else
    a="${o[0]}"; d="${o[1]}"
  fi
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 0
  (( a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255 )) || return 0
  if (( a == 0 || a == 10 || a == 127 )); then return 0; fi
  if (( a == 169 && b == 254 )); then return 0; fi
  if (( a == 172 && b >= 16 && b <= 31 )); then return 0; fi
  if (( a == 192 && b == 168 )); then return 0; fi
  if (( a == 100 && b >= 64 && b <= 127 )); then return 0; fi
  return 1
}

allowed_host() {
  local h="$1"
  [[ -z "$h" ]] && return 1
  h="${h,,}"
  h="${h%.}"
  case "$h" in
    mp3quran.net|*.mp3quran.net|islamic.app|*.islamic.app) return 0 ;;
    *) return 1 ;;
  esac
}

# validate_server <url> — exit 1 unless the value is an absolute https URL on
# an allowlisted audio CDN, public host, no userinfo/query/fragment.
validate_server() {
  local value="$1"
  [[ -z "$value" ]] && { echo "invalid server: empty" >&2; return 1; }
  (( ${#value} > 512 )) && { echo "invalid server: too long" >&2; return 1; }
  [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]] && {
    echo "invalid server: control characters" >&2; return 1
  }
  [[ "$value" =~ ^https?:// ]] || { echo "invalid server: scheme not http(s)" >&2; return 1; }
  [[ "$value" == *"#"* || "$value" == *"?"* ]] && { echo "invalid server: query/fragment not allowed" >&2; return 1; }
  local rest="${value#*://}"
  local authority="${rest%%/*}"
  [[ -z "$authority" ]] && { echo "invalid server: missing host" >&2; return 1; }
  [[ "$authority" == *"@"* ]] && { echo "invalid server: userinfo not allowed" >&2; return 1; }
  local host="$authority"
  if [[ "$host" == \[* ]]; then
    host="${host#\[}"
    host="${host%%\]*}"
  elif [[ "$host" == *":"* ]]; then
    host="${host%:*}"
  fi
  if blocked_host "$host"; then
    echo "invalid server: blocked host '$host'" >&2
    return 1
  fi
  if ! allowed_host "$host"; then
    echo "invalid server: host '$host' is not an allowlisted audio CDN" >&2
    return 1
  fi
  return 0
}

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

# Validate reciter id (dotted identifier, alnum first, letters/digits/dots/dashes).
if [[ ! "$RECITER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$RECITER" == "." || "$RECITER" == ".." ]]; then
  echo "invalid reciter identifier" >&2
  exit 2
fi

# Validate the --server base URL once up front (blocks non-http(s) schemes,
# internal hosts, userinfo/query/fragment smuggling). fail fast.
if [[ -n "$SERVER" ]] && ! validate_server "$SERVER"; then
  exit 2
fi

BASE="https://cdn.islamic.app/quran/audio-surah"
if [[ -z "$DEST" ]]; then
  DEST="${HOME}/.local/state/omarchy/quran/${RECITER}"
else
  if [[ "$DEST" != /* ]]; then
    echo "invalid dest: must be an absolute path" >&2
    exit 2
  fi
  if [[ "$DEST" == *..* ]]; then
    echo "invalid dest: path traversal rejected" >&2
    exit 2
  fi
fi
mkdir -p "$DEST"

# validate_surah <n> — exits 2 on invalid input. Base-10 forced so padded
# values like "08" don't trip bash's octal parsing.
validate_surah() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( 10#$n < 1 || 10#$n > 114 )); then
    echo "invalid surah number: $n" >&2
    exit 2
  fi
}

url_for() {
  local n="$1"
  n=$((10#$n))
  if [[ -n "$SERVER" ]]; then
    local padded
    padded="$(printf "%03d" "$n")"
    local url="${SERVER}${padded}.mp3"
    # Belt-and-suspenders: the final URL must also be safe (a prefix without a
    # trailing slash would otherwise fold the filename into the host).
    validate_server "$url" || return 1
    echo "$url"
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
  local len
  len="$(curl -fsSL --max-time 15 --max-redirs 0 --proto '=http,https' --proto-redir '=https' -I "$target" \
    | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="content-length" {gsub(/[^0-9]/,"",$2); print $2}' \
    | tail -1)"
  [[ -n "$len" ]] || return 1
  (( len > MAX_SURAH_BYTES )) && return 1
  echo "$len"
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
  local progress_dir progress_fifo curl_pid curl_status line pct
  progress_dir="$(mktemp -d "${TMPDIR:-/tmp}/quran-download.XXXXXX")" || return 1
  progress_fifo="${progress_dir}/stderr"
  mkfifo "$progress_fifo" || { rmdir "$progress_dir"; return 1; }

  # Keep curl's progress bar off the terminal, but forward its percentage as
  # machine-readable stdout. SplitParser in Service.qml receives these lines
  # while curl is still writing the file, instead of only seeing 1/1 at EOF.
  echo "progress_bytes 0/100"
  curl -fsSL --progress-bar --retry 3 -C - --max-redirs 0 \
      --proto '=http,https' --proto-redir '=https' \
      --max-filesize "$MAX_SURAH_BYTES" "$target" \
      -o "${DEST}/${n}.mp3.part" 2>"$progress_fifo" &
  curl_pid=$!
  while IFS= read -r -d $'\r' line; do
    if [[ "$line" =~ ([0-9]+)(\.[0-9]+)?% ]]; then
      pct="${BASH_REMATCH[1]}"
      echo "progress_bytes ${pct}/100"
    fi
  done < "$progress_fifo"
  wait "$curl_pid"
  curl_status=$?
  rm -f "$progress_fifo"
  rmdir "$progress_dir"

  if (( curl_status == 0 )); then
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
  # --only a,b,c — validate each number, normalize to base-10, keep order.
  IFS=',' read -r -a RAW <<< "$ONLY"
  for n in "${RAW[@]}"; do
    n="${n//[[:space:]]/}"
    [[ -z "$n" ]] && continue
    validate_surah "$n"
    SET[$TOTAL]="$((10#$n))"
    TOTAL=$((TOTAL + 1))
  done
  if (( TOTAL == 0 )); then
    echo "no surahs in --only list" >&2
    exit 2
  fi
elif [[ -n "$N" ]]; then
  validate_surah "$N"
  TOTAL=1
  SET[0]="$((10#$N))"
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
