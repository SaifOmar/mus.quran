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
#
# A file is "complete" iff it exists as <n>.mp3 (writes are atomic via the
# .part -> rename convention in download.sh). ".part" files are never evicted.
set -u

CMD="${1:-}"
shift || true

scan() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && find . -type f -name '*.mp3' | sed 's|^\./||' | sort )
}

size() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}'
  else
    echo 0
  fi
}

promote() {
  local src="$1" dst="$2" rec="$3" csv="$4"
  mkdir -p "$dst/$rec"
  local n
  IFS=',' read -r -a nums <<< "$csv"
  for n in "${nums[@]}"; do
    n="${n//[[:space:]]/}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [[ -f "$src/$rec/$n.mp3" ]]; then
      if mv -f "$src/$rec/$n.mp3" "$dst/$rec/$n.mp3"; then
        echo "moved $rec/$n"
      fi
    fi
  done
}

evict() {
  local dir="$1" budgetMb="$2"
  shift 2
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
  tmp="$(mktemp)"
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
  done < <(cd "$dir" && find . -type f -name '*.mp3' | sed 's|^\./||') \
    | sort -n > "$tmp"

  while IFS=' ' read -r sortkey sz rel; do
    (( total <= BUDGET )) && break
    if rm -f "$dir/$rel"; then
      total=$((total - sz))
      echo "deleted $rel"
    fi
  done < "$tmp"
  rm -f "$tmp"
}

clear_cache() {
  local dir="$1"
  shift || true
  mkdir -p "$dir"
  local f k skip
  while IFS= read -r -d '' f; do
    skip=0
    for k in "$@"; do
      [[ "$f" == "$k" ]] && { skip=1; break; }
    done
    (( skip )) && continue
    rm -f "$f"
  done < <(find "$dir" -type f -print0)
  find "$dir" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
}

case "$CMD" in
  scan)    scan "$@" ;;
  size)    size "$@" ;;
  promote) promote "$@" ;;
  evict)   evict "$@" ;;
  clear)   clear_cache "$@" ;;
  *)
    echo "usage: cache.sh {scan|size|promote|evict|clear} ..." >&2
    exit 2
    ;;
esac