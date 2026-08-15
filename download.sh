#!/usr/bin/env bash
# Download Quran surahs for a reciter from an allowlisted audio CDN.
# Usage:
#   download.sh <reciter-identifier>                  # whole mushaf (1..114)
#   download.sh <reciter-identifier> <n>              # single surah n (1..114)
#   download.sh <reciter-identifier> --only a,b,c     # just those surahs
#   download.sh <reciter-identifier> ... --dest PATH  # write files under PATH
#   download.sh <reciter-identifier> ... --server URL # catalog CDN base
#   download.sh <reciter-identifier> ... --budget-bytes N  # cache budget cap
# Default dest is ~/.local/state/omarchy/quran (explicit downloads); `--dest`
# is used for the streaming cache (the cache directory). Either way, files are
# always written to <dest>/<reciter>/NNN.mp3 — never flat.
# Files are downloaded to `NNN.mp3.part` and renamed on success (atomic).
# Stdout progress: `progress <done>/<total>` lines (total = work-set size),
# then a final `complete <done> <failed>` line. `failed <n>` lines go to stderr.
# Exit codes: 0 = all requested files present, 1 = at least one failed, 2 = usage.
set -u

umask 077

# --- security limits -------------------------------------------------------
# Per-surah cap (~300 MB) so an oversized/malicious URL can't exhaust disk.
MAX_SURAH_BYTES=314572800
# Only these CDN suffixes may appear in a catalog --server URL.
# A compromised catalog must not point curl at arbitrary hosts.
ALLOWED_HOST_PATTERNS='mp3quran.net|*.mp3quran.net|islamic.app|*.islamic.app'
# DNS-rebinding pinning: the host is resolved once per script run and every
# returned address must be public; the chosen address is passed to curl via
# --resolve so both the HEAD and the GET hit the same verified IP.
PINNED_IP=""
PINNED_HOST=""
SERVER_HOST=""
SERVER_PORT="443"

# blocked_host <host> — exit 0 if the host is an internal/loopback/link-local
# literal or an obviously-internal hostname (localhost, *.local, *.internal,
# *.localhost, single-label, IPv4-mapped IPv6, short/hex/octal IPv4, multicast,
# reserved, TEST-NET).
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
  if (( a >= 224 && a <= 255 )); then return 0; fi
  if (( a == 192 && b == 0 && c == 0 )); then return 0; fi
  if (( a == 192 && b == 0 && c == 2 )); then return 0; fi
  if (( a == 198 && b == 51 && c == 100 )); then return 0; fi
  if (( a == 203 && b == 0 && c == 113 )); then return 0; fi
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
# an allowlisted audio CDN, public host, valid port, no userinfo/query/
# fragment, no encoded delimiters. Also sets SERVER_HOST / SERVER_PORT.
validate_server() {
  local value="$1"
  [[ -z "$value" ]] && { echo "invalid server: empty" >&2; return 1; }
  (( ${#value} > 512 )) && { echo "invalid server: too long" >&2; return 1; }
  [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]] && {
    echo "invalid server: control characters" >&2; return 1
  }
  [[ "$value" =~ ^https:// ]] || { echo "invalid server: scheme not https" >&2; return 1; }
  # Encoded delimiters (case-insensitive) — %2e . %2f / %3f ? %23 # %40 @ %5c \
  [[ "$value" =~ %(2e|2f|3f|23|40|5c) ]] && { echo "invalid server: encoded delimiters" >&2; return 1; }
  [[ "$value" == *"#"* || "$value" == *"?"* ]] && { echo "invalid server: query/fragment not allowed" >&2; return 1; }
  local rest="${value#*://}"
  local authority="${rest%%/*}"
  [[ -z "$authority" ]] && { echo "invalid server: missing host" >&2; return 1; }
  [[ "$authority" == *"@"* ]] && { echo "invalid server: userinfo not allowed" >&2; return 1; }
  local host="$authority"
  local port=""
  if [[ "$host" == \[* ]]; then
    # Bracketed IPv6: inner literal must be hex/colon-only with >= 1 colon and
    # no zone id; anything after the bracket must be a valid port.
    host="${host#\[}"
    local close="${host%%\]*}"
    [[ -n "$close" && "$close" =~ ^[0-9a-fA-F:]+$ && "$close" == *":"* ]] || {
      echo "invalid server: bad ipv6 literal" >&2; return 1
    }
    [[ "$close" == *"%"* ]] && { echo "invalid server: ipv6 zone id not allowed" >&2; return 1; }
    host="$close"
    local after="${authority#*\]}"
    if [[ -n "$after" ]]; then
      [[ "$after" == :* ]] || { echo "invalid server: bad port" >&2; return 1; }
      port="${after#:}"
    fi
  elif [[ "$host" == *":"* ]]; then
    port="${host##*:}"
    host="${host%:*}"
  fi
  if [[ -n "$port" ]]; then
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "invalid server: bad port" >&2; return 1; }
    [[ "$port" =~ ^0[0-9]+$ ]] && { echo "invalid server: bad port" >&2; return 1; }
    (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo "invalid server: bad port" >&2; return 1; }
  fi
  if blocked_host "$host"; then
    echo "invalid server: blocked host '$host'" >&2
    return 1
  fi
  if ! allowed_host "$host"; then
    echo "invalid server: host '$host' is not an allowlisted audio CDN" >&2
    return 1
  fi
  SERVER_HOST="$host"
  [[ -n "$port" ]] && SERVER_PORT="$port"
  return 0
}

# pin_host <host> — resolve once per script run; every returned address must
# pass blocked_host (fail closed on ANY private/internal address — this is what
# stops DNS-rebinding). Sets PINNED_IP to the first IPv4 (else first IPv6).
pin_host() {
  local host="$1"
  if [[ -n "$PINNED_IP" && "$PINNED_HOST" == "$host" ]]; then
    return 0
  fi
  local v4="" v6="" line ip
  while IFS= read -r line; do
    ip="${line%%[[:space:]]*}"
    [[ -z "$ip" ]] && continue
    if blocked_host "$ip"; then
      echo "blocked resolved address '$ip' for '$host'" >&2
      return 1
    fi
    if [[ "$ip" == *":"* ]]; then
      [[ -z "$v6" ]] && v6="$ip"
    else
      [[ -z "$v4" ]] && v4="$ip"
    fi
  done < <(getent ahostsv4 "$host" 2>/dev/null; getent ahostsv6 "$host" 2>/dev/null)
  local chosen="${v4:-$v6}"
  if [[ -z "$chosen" ]]; then
    echo "could not resolve '$host'" >&2
    return 1
  fi
  PINNED_IP="$chosen"
  PINNED_HOST="$host"
  return 0
}

# --- argument parsing (array-based; no positional reconstruction) -----------
RECITER=""
DEST=""
ONLY=""
SERVER=""
BUDGET_BYTES=0
declare -a POSITIONALS=()
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
    --budget-bytes)
      BUDGET_BYTES="${2:-0}"
      shift 2
      ;;
    *)
      POSITIONALS+=("$1")
      shift
      ;;
  esac
done

RECITER="${POSITIONALS[0]:-}"
N="${POSITIONALS[1]:-}"

[[ -n "${HOME:-}" ]] || { echo "HOME is not set" >&2; exit 2; }

if [[ -z "$RECITER" ]]; then
  echo "usage: download.sh <reciter-identifier> [surah-number|--only a,b,c] [--dest PATH] [--server URL] [--budget-bytes N]" >&2
  exit 2
fi

# Validate reciter id ourselves (never trust that a caller already checked):
# alnum first, letters/digits/dots/dashes/underscores, <= 64 chars. This both
# keeps the id usable as a path segment and blocks traversal.
if [[ ! "$RECITER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || (( ${#RECITER} > 64 )) \
    || [[ "$RECITER" == "." || "$RECITER" == ".." ]]; then
  echo "invalid reciter identifier" >&2
  exit 2
fi

if [[ -n "$BUDGET_BYTES" && "$BUDGET_BYTES" != "0" ]]; then
  [[ "$BUDGET_BYTES" =~ ^[0-9]+$ ]] && (( BUDGET_BYTES > 0 )) || {
    echo "invalid budget bytes" >&2; exit 2
  }
fi

# Validate the --server base URL once up front (blocks non-https schemes,
# internal hosts, userinfo/query/fragment smuggling, bad ports). fail fast.
BASE="https://cdn.islamic.app/quran/audio-surah"
if [[ -n "$SERVER" ]]; then
  validate_server "$SERVER" || exit 2
else
  validate_server "$BASE" || exit 2
fi

# --- dest root validation + reciter subdirectory (the cache-path bug fix) ---
# Allowed roots, derived from $HOME; symlink escapes are rejected because the
# final realpath must still resolve under one of these roots.
STATE_ROOT="$(realpath -m "${HOME}/.local/state/omarchy/quran")" || exit 2
CACHE_ROOT="$(realpath -m "${HOME}/.cache/omarchy/quran")" || exit 2
if [[ -z "$DEST" ]]; then
  DEST="${STATE_ROOT}"
else
  [[ "$DEST" == /* ]] || { echo "invalid dest: must be an absolute path" >&2; exit 2; }
  [[ "$DEST" != *".."* ]] || { echo "invalid dest: path traversal rejected" >&2; exit 2; }
fi
DEST_ROOT_REAL="$(realpath -m "$DEST")" || exit 2
if [[ "$DEST_ROOT_REAL" != "$STATE_ROOT" && "$DEST_ROOT_REAL" != "$CACHE_ROOT" ]]; then
  echo "invalid dest: must be a quran state/cache root" >&2
  exit 2
fi
# Keep the original dest root for the cache-budget accounting (the reciter
# subdirectory is appended right below).
DEST_ROOT="$DEST"
# Files always land under <dest>/<reciter>/ — the fix that makes every
# downstream consumer (cache.sh scan/promote/evict/clear, Service.qml) agree
# on <cacheDir>/<reciter>/<n>.mp3 instead of a flat <cacheDir>/<n>.mp3.
DEST="${DEST}/${RECITER}"
DEST_REAL="$(realpath -m "$DEST")" || exit 2
case "$DEST_REAL" in
  "$STATE_ROOT"/*|"$CACHE_ROOT"/*) : ;;
  *)
    echo "invalid dest after reciter segment" >&2
    exit 2
    ;;
esac
mkdir -p "$DEST" || exit 2

# --- cleanup on all paths ---------------------------------------------------
# SIGTERM/SIGINT and every failure delete the in-flight .part file; the curl
# child is killed too so it can't recreate the file after we remove it.
PART=""
CURL_PID=""
cleanup_part() {
  [[ -n "$CURL_PID" ]] && kill "$CURL_PID" 2>/dev/null
  [[ -n "$PART" ]] && rm -f -- "$PART"
}
trap cleanup_part EXIT
trap 'cleanup_part; exit 130' INT TERM

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
# Also requires an audio/* or application/octet-stream content type (anything
# else is treated as missing) and pins the DNS-resolved address.
remote_size() {
  local n="$1"
  local target
  target="$(url_for "$n")" || return 1
  pin_host "$SERVER_HOST" || return 1
  local head
  head="$(curl -fsSL --connect-timeout 10 --max-time 30 --max-redirs 0 \
      --proto '=https' --proto-redir '=https' \
      --resolve "${SERVER_HOST}:${SERVER_PORT}:${PINNED_IP}" \
      --max-filesize "$MAX_SURAH_BYTES" -I "$target" 2>/dev/null | tr -d '\r')"
  [[ -n "$head" ]] || return 1
  local ctype
  ctype="$(printf '%s\n' "$head" | awk -F': ' 'tolower($1)=="content-type" {print $2; exit}')"
  case "${ctype,,}" in
    audio/*|application/octet-stream) : ;;
    *) return 1 ;;
  esac
  local len
  len="$(printf '%s\n' "$head" | awk -F': ' 'tolower($1)=="content-length" {gsub(/[^0-9]/,"",$2); print $2}' | tail -1)"
  [[ -n "$len" ]] || return 1
  (( len > MAX_SURAH_BYTES )) && return 1
  echo "$len"
}

# complete <n> — 1 if the local file exists and matches the remote size.
complete() {
  local n="$1"
  local file="${DEST}/${n}.mp3"
  [[ -f "$file" && ! -L "$file" ]] || return 1
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
  # Streaming-cache budget: existing bytes (complete + .part) in the dest root
  # plus this file's remote size must stay within --budget-bytes.
  if (( BUDGET_BYTES > 0 )); then
    local want existing
    want="$(remote_size "$n")" || return 1
    existing="$(find "$DEST_ROOT" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    if (( existing + want > BUDGET_BYTES )); then
      echo "budget exceeded for ${n}" >&2
      return 1
    fi
  fi
  local target
  target="$(url_for "$n")" || return 1
  pin_host "$SERVER_HOST" || return 1
  local progress_dir progress_fifo curl_status line pct
  progress_dir="$(mktemp -d "${TMPDIR:-/tmp}/quran-download.XXXXXX")" || return 1
  progress_fifo="${progress_dir}/stderr"
  mkfifo "$progress_fifo" || { rmdir "$progress_dir"; return 1; }

  # Keep curl's progress bar off the terminal, but forward its percentage as
  # machine-readable stdout. SplitParser in Service.qml receives these lines
  # while curl is still writing the file, instead of only seeing 1/1 at EOF.
  PART="${DEST}/${n}.mp3.part"
  echo "progress_bytes 0/100"
  curl -fsSL --progress-bar --retry 3 --retry-delay 2 --retry-max-time 60 -C - \
      --connect-timeout 10 --speed-limit 1024 --speed-time 30 --max-time 300 \
      --max-redirs 0 --proto '=https' --proto-redir '=https' \
      --resolve "${SERVER_HOST}:${SERVER_PORT}:${PINNED_IP}" \
      --max-filesize "$MAX_SURAH_BYTES" "$target" \
      -o "$PART" 2>"$progress_fifo" &
  CURL_PID=$!
  while IFS= read -r -d $'\r' line; do
    if [[ "$line" =~ ([0-9]+)(\.[0-9]+)?% ]]; then
      pct="${BASH_REMATCH[1]}"
      echo "progress_bytes ${pct}/100"
    fi
  done < "$progress_fifo"
  wait "$CURL_PID"
  curl_status=$?
  CURL_PID=""
  rm -f "$progress_fifo"
  rmdir "$progress_dir"

  if (( curl_status == 0 )); then
    mv "$PART" "${DEST}/${n}.mp3" || { rm -f "$PART"; PART=""; return 1; }
    PART=""
    return 0
  else
    rm -f "$PART"
    PART=""
    echo "failed ${n}" >&2
    return 1
  fi
}

# --- work set ---------------------------------------------------------------
TOTAL=0
declare -a SET=()
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