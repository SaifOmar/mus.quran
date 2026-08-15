#!/usr/bin/env bash
# Cache-directory management for the quran player's auto-cache
# (~/.cache/omarchy/quran). NEVER touches the explicit-download directory
# (~/.local/state/omarchy/quran) except via `promote` (which moves files OUT
# of the cache INTO the state dir, making them permanent downloads).
#
# Subcommands:
#   scan <dir>                          # print <reciter>/<n>.mp3 per complete file
#   size <dir>                          # total bytes (complete + .part)
#   promote <src> <dst> <reciter> <csv> # move complete cached files src->dst
#   evict <dir> <budgetMb> [--last-played key=ms...]  # LRU eviction
#   clear <dir> [keepPart...]           # delete all but in-flight .part files
#   remove <dir> <reciter> <n>          # delete one cached surah file
#
# A file is "complete" iff it exists as <n>.mp3 (writes are atomic via the
# .part -> rename convention in download.sh). ".part" files are never evicted.
set -u

umask 077

CMD="${1:-}"
shift || true

CACHE_ROOT="$(realpath -m "${HOME:-}/.cache/omarchy/quran")"
STATE_ROOT="$(realpath -m "${HOME:-}/.local/state/omarchy/quran")"

# check_dir <dir> <label> — exits 2 unless dir is absolute, contains no "..",
# and its canonical path is exactly the cache or state root. This is what
# rejects symlink escapes: realpath -m surfaces any path that resolves outside
# the allowed roots.
check_dir() {
  local dir="$1" label="$2"
  [[ -n "$dir" && "$dir" == /* ]] || { echo "invalid $label: must be an absolute path" >&2; exit 2; }
  [[ "$dir" != *".."* ]] || { echo "invalid $label: path traversal rejected" >&2; exit 2; }
  local real
  real="$(realpath -m "$dir")"
  [[ "$real" == "$CACHE_ROOT" || "$real" == "$STATE_ROOT" ]] || {
    echo "invalid $label: not a quran state/cache root" >&2; exit 2
  }
}

# check_reciter <id> — exits 2 unless the id is usable as a path segment.
check_reciter() {
  local rec="$1"
  if [[ ! "$rec" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || (( ${#rec} > 64 )) \
      || [[ "$rec" == "." || "$rec" == ".." ]]; then
    echo "invalid reciter identifier" >&2
    exit 2
  fi
}

# check_surah <n> — 1 unless n is a decimal 1..114.
check_surah() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( 10#$n >= 1 && 10#$n <= 114 )) || return 1
  return 0
}

scan() {
  local dir="$1"
  check_dir "$dir" "dir"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && find . -type f ! -type l -name '*.mp3' | sed 's|^\./||' | sort )
}

size() {
  local dir="$1"
  check_dir "$dir" "dir"
  if [[ -d "$dir" ]]; then
    find "$dir" -type f ! -type l -printf '%s\n' | awk '{s+=$1} END {print s+0}'
  else
    echo 0
  fi
}

promote() {
  local src="$1" dst="$2" rec="$3" csv="$4"
  check_dir "$src" "src"
  check_dir "$dst" "dst"
  check_reciter "$rec"
  mkdir -p "$dst/$rec"
  local n
  IFS=',' read -r -a nums <<< "$csv"
  for n in "${nums[@]}"; do
    n="${n//[[:space:]]/}"
    check_surah "$n" || continue
    # Only ever move regular files found under the validated root; symlinks
    # are skipped so a malicious symlink cannot redirect the mv elsewhere.
    if [[ -f "$src/$rec/$n.mp3" && ! -L "$src/$rec/$n.mp3" ]]; then
      if mv -f "$src/$rec/$n.mp3" "$dst/$rec/$n.mp3"; then
        echo "moved $rec/$n"
      fi
    fi
  done
}

evict() {
  local dir="$1" budgetMb="$2"
  shift 2
  check_dir "$dir" "dir"
  [[ "$budgetMb" =~ ^[0-9]+$ ]] || { echo "invalid budget" >&2; exit 2; }
  (( budgetMb <= 10000 )) || { echo "invalid budget (max 10000)" >&2; exit 2; }
  local BUDGET=$((budgetMb * 1024 * 1024))
  [[ -d "$dir" ]] || exit 0
  local total
  total="$(size "$dir")"
  (( total <= BUDGET )) && exit 0

  # Collect last-played timestamps (key="reciter:n" -> ms), if provided.
  declare -A LP=()
  local lastMode=0 arg k v
  for arg in "$@"; do
    if [[ "$arg" == "--last-played" ]]; then lastMode=1; continue; fi
    if (( lastMode )); then
      k="${arg%%=*}"
      v="${arg#*=}"
      LP["$k"]="$v"
    fi
  done

  local tmp rel key ms sortkey sz
  tmp="$(mktemp)" || exit 1
  trap 'rm -f -- "${tmp:-}"' EXIT
  # Rows: "<sort-key> <size> <relpath>". Sort ascending = oldest first.
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    key="${rel%.mp3}"
    key="${key//\//:}"
    ms="${LP[$key]:-}"
    if [[ -n "$ms" ]]; then
      sortkey="$ms"
    else
      sortkey="$(stat -c %Y "$dir/$rel")"
    fi
    sz="$(stat -c %s "$dir/$rel")"
    printf '%s %s %s\n' "$sortkey" "$sz" "$rel"
  done < <(cd "$dir" && find . -type f ! -type l -name '*.mp3' | sed 's|^\./||') \
    | sort -n > "$tmp"

  while IFS=' ' read -r sortkey sz rel; do
    (( total <= BUDGET )) && break
    if rm -f "$dir/$rel"; then
      total=$((total - sz))
      echo "deleted $rel"
    fi
  done < "$tmp"
  rm -f "$tmp"
  trap - EXIT
}

clear_cache() {
  local dir="$1"
  shift || true
  check_dir "$dir" "dir"
  mkdir -p "$dir"
  local f k skip
  while IFS= read -r -d '' f; do
    skip=0
    for k in "$@"; do
      [[ "$f" == "$k" ]] && { skip=1; break; }
    done
    (( skip )) && continue
    rm -f "$f"
  done < <(find "$dir" -type f ! -type l -print0)
  find "$dir" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
}

remove_file() {
  local dir="$1" rec="$2" n="$3"
  check_dir "$dir" "dir"
  check_reciter "$rec"
  check_surah "$n" || { echo "invalid surah" >&2; exit 2; }
  local f="$dir/$rec/$n.mp3"
  if [[ -f "$f" && ! -L "$f" ]]; then
    rm -f -- "$f"
  fi
}

case "$CMD" in
  scan)    scan "$@" ;;
  size)    size "$@" ;;
  promote) promote "$@" ;;
  evict)   evict "$@" ;;
  clear)   clear_cache "$@" ;;
  remove)  remove_file "$@" ;;
  *)
    echo "usage: cache.sh {scan|size|promote|evict|clear|remove} ..." >&2
    exit 2
    ;;
esac