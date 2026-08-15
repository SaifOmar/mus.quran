#!/usr/bin/env bash
# Tests for cache.sh. Uses a throwaway HOME so the derived cache/state roots
# are isolated; mockbin is NOT needed (cache.sh never calls curl).
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cache.sh"
WORK="$(mktemp -d /tmp/quran-cache-test.XXXXXX)"
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
ok() { # ok <name> <cond...>
  local name="$1"
  shift
  if "$@"; then PASS=$((PASS+1)); echo "PASS $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}
tnot() { # tnot <name> <cond...> — asserts the command exits nonzero
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL $name (unexpected success)"
  else PASS=$((PASS+1)); echo "PASS $name"; fi
}

export HOME="$WORK/home"
mkdir -p "$HOME"
CACHE="$HOME/.cache/omarchy/quran"
STATE="$HOME/.local/state/omarchy/quran"
OTHER="$WORK/elsewhere"

# ---------------------------------------------------------------------------
# check_dir: path validation (all subcommands take <dir> first)
# ---------------------------------------------------------------------------
t "scan: relative dir rejected" 2 "$SCRIPT" scan "rel/dir"
t "scan: traversal rejected" 2 "$SCRIPT" scan "$WORK/../etc"
t "scan: non-root absolute rejected" 2 "$SCRIPT" scan "$OTHER"
t "scan: missing cache root rejected" 2 "$SCRIPT" scan "$HOME/.cache/omarchy/quran/nope"
t "size: traversal rejected" 2 "$SCRIPT" size "$WORK/../etc"
t "promote: bad src rejected" 2 "$SCRIPT" promote "$WORK/../etc" "$STATE" ar.alafasy 1
t "promote: bad dst rejected" 2 "$SCRIPT" promote "$CACHE" "$WORK/x" ar.alafasy 1
t "evict: bad dir rejected" 2 "$SCRIPT" evict "$OTHER" 1
t "clear: bad dir rejected" 2 "$SCRIPT" clear "$OTHER"
t "remove: bad dir rejected" 2 "$SCRIPT" remove "$OTHER" ar.alafasy 1
t "unknown subcommand" 2 "$SCRIPT" frobnicate

# ---------------------------------------------------------------------------
# reciter / surah validation
# ---------------------------------------------------------------------------
t "promote: slash reciter rejected" 2 "$SCRIPT" promote "$CACHE" "$STATE" "a/b" 1
t "promote: dotdot reciter rejected" 2 "$SCRIPT" promote "$CACHE" "$STATE" ".." 1
t "promote: leading-dot reciter rejected" 2 "$SCRIPT" promote "$CACHE" "$STATE" ".x" 1
t "promote: space reciter rejected" 2 "$SCRIPT" promote "$CACHE" "$STATE" "a b" 1
t "promote: 65-char reciter rejected" 2 "$SCRIPT" promote "$CACHE" "$STATE" "$(printf 'a%.0s' {1..65})" 1
t "remove: bad reciter rejected" 2 "$SCRIPT" remove "$CACHE" "../etc" 1
t "remove: invalid surah rejected" 2 "$SCRIPT" remove "$CACHE" ar.alafasy 115
t "remove: junk surah rejected" 2 "$SCRIPT" remove "$CACHE" ar.alafasy "1junk"
t "remove: zero surah rejected" 2 "$SCRIPT" remove "$CACHE" ar.alafasy 0

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------
mkdir -p "$CACHE/ar.alafasy" "$CACHE/ar.ajamy"
printf x > "$CACHE/ar.alafasy/1.mp3"
printf x > "$CACHE/ar.alafasy/2.mp3"
printf x > "$CACHE/ar.ajamy/1.mp3"
printf x > "$CACHE/ar.alafasy/3.mp3.part"
ln -s "$CACHE/ar.alafasy/2.mp3" "$CACHE/ar.ajamy/3.mp3" # symlink must be ignored
OUT="$( "$SCRIPT" scan "$CACHE" )"
ok "scan: lists mp3s sorted" bash -c "test \"\$1\" = 'ar.ajamy/1.mp3
ar.alafasy/1.mp3
ar.alafasy/2.mp3'" -- "$OUT"
ok "scan: excludes .part" bash -c "! grep -q 'part' <<< \"\$1\"" -- "$OUT"
ok "scan: excludes symlinks" bash -c "! grep -q '3.mp3' <<< \"\$1\"" -- "$OUT"
t "scan: missing dir is empty" 0 bash -c "test -z \"\$(\"$SCRIPT\" scan \"$HOME/.local/state/omarchy/quran\")\""

# ---------------------------------------------------------------------------
# size
# ---------------------------------------------------------------------------
printf '12345' > "$CACHE/ar.alafasy/2.mp3"
printf '67890' > "$CACHE/ar.alafasy/3.mp3.part"
SZ="$( "$SCRIPT" size "$CACHE" )"
ok "size: sums regular files incl .part" test "$SZ" -eq 12
t "size: missing dir is 0" 0 bash -c "test \"\$(\"$SCRIPT\" size \"$STATE\")\" = 0"

# ---------------------------------------------------------------------------
# promote
# ---------------------------------------------------------------------------
printf 'aaa' > "$CACHE/ar.ajamy/1.mp3"
ln -s "$CACHE/ar.ajamy/1.mp3" "$CACHE/ar.ajamy/2.mp3" # symlink: never moved
OUT="$( "$SCRIPT" promote "$CACHE" "$STATE" ar.ajamy 1,2,999,0 )"
ok "promote: moves valid surah" test -f "$STATE/ar.ajamy/1.mp3"
ok "promote: prints moved" bash -c "grep -q 'moved ar.ajamy/1' <<< \"\$1\"" -- "$OUT"
ok "promote: leaves symlink behind" test -L "$CACHE/ar.ajamy/2.mp3"
ok "promote: original gone" test ! -e "$CACHE/ar.ajamy/1.mp3"
ok "promote: skips out-of-range surahs" bash -c "! grep -q '999' <<< \"\$1\"" -- "$OUT"
t "promote: traversal in csv ignored" 0 bash -c "\"$SCRIPT\" promote \"$CACHE\" \"$STATE\" ar.ajamy '1,../2'"

# ---------------------------------------------------------------------------
# evict (LRU by mtime, stop at budget)
# ---------------------------------------------------------------------------
rm -rf "$CACHE"
mkdir -p "$CACHE/ar.alafasy"
printf '1111111111' > "$CACHE/ar.alafasy/1.mp3"  # 10 B, oldest
printf '2222222222' > "$CACHE/ar.alafasy/2.mp3"  # 10 B
printf '3333333333' > "$CACHE/ar.alafasy/3.mp3"  # 10 B, newest
touch -d '2020-01-01' "$CACHE/ar.alafasy/1.mp3"
touch -d '2021-01-01' "$CACHE/ar.alafasy/2.mp3"
touch -d '2022-01-01' "$CACHE/ar.alafasy/3.mp3"
t "evict: invalid budget rejected" 2 "$SCRIPT" evict "$CACHE" abc
t "evict: over-max budget rejected" 2 "$SCRIPT" evict "$CACHE" 10001
t "evict: missing dir ok" 0 "$SCRIPT" evict "$STATE" 1
OUT="$( "$SCRIPT" evict "$CACHE" 0 )"
ok "evict: budget 0 deletes oldest first" bash -c "grep -q 'deleted ar.alafasy/1.mp3' <<< \"\$1\"" -- "$OUT"
ok "evict: deletes in order" bash -c "test \"\$(grep -c deleted <<< \"\$1\")\" -eq 3" -- "$OUT"
ok "evict: empty after budget 0" test -z "$(find "$CACHE" -type f)"

# budget leaves oldest removed only
printf '1111111111' > "$CACHE/ar.alafasy/1.mp3"
printf '2222222222' > "$CACHE/ar.alafasy/2.mp3"
printf '3333333333' > "$CACHE/ar.alafasy/3.mp3"
touch -d '2020-01-01' "$CACHE/ar.alafasy/1.mp3"
touch -d '2021-01-01' "$CACHE/ar.alafasy/2.mp3"
touch -d '2022-01-01' "$CACHE/ar.alafasy/3.mp3"
OUT="$( "$SCRIPT" evict "$CACHE" 1 )" # 1 MB budget: nothing over? total 30B <= 1MB
ok "evict: nothing deleted under budget" test -z "$OUT"
printf '1111111111' > "$CACHE/ar.alafasy/1.mp3"
printf '2222222222' > "$CACHE/ar.alafasy/2.mp3"
printf '3333333333' > "$CACHE/ar.alafasy/3.mp3"
touch -d '2020-01-01' "$CACHE/ar.alafasy/1.mp3"
touch -d '2021-01-01' "$CACHE/ar.alafasy/2.mp3"
touch -d '2022-01-01' "$CACHE/ar.alafasy/3.mp3"
# budget 2 MB with three 1 MB files: pinning the OLDEST (3) as "last played"
# must flip eviction order so 1 goes first and 3 survives
dd if=/dev/zero of="$CACHE/ar.alafasy/1.mp3" bs=1M count=1 status=none
dd if=/dev/zero of="$CACHE/ar.alafasy/2.mp3" bs=1M count=1 status=none
dd if=/dev/zero of="$CACHE/ar.alafasy/3.mp3" bs=1M count=1 status=none
touch -d '2021-01-01' "$CACHE/ar.alafasy/1.mp3"
touch -d '2022-01-01' "$CACHE/ar.alafasy/2.mp3"
touch -d '2020-01-01' "$CACHE/ar.alafasy/3.mp3" # oldest by mtime
OUT="$( "$SCRIPT" evict "$CACHE" 2 --last-played ar.alafasy:3=9999999999999 )"
ok "evict: last-played pins oldest key" test -f "$CACHE/ar.alafasy/3.mp3"
ok "evict: unpinned oldest evicted" test ! -e "$CACHE/ar.alafasy/1.mp3"
ok "evict: stops at budget (2 keeps 2)" test -f "$CACHE/ar.alafasy/2.mp3"
ok "evict: reports deleted file" bash -c "grep -q 'deleted ar.alafasy/1.mp3' <<< \"\$1\"" -- "$OUT"
ok "evict: part files never listed" bash -c "! grep -q 'part' <<< \"\$1\"" -- "$OUT"

# ---------------------------------------------------------------------------
# clear
# ---------------------------------------------------------------------------
rm -rf "$CACHE"
mkdir -p "$CACHE/ar.alafasy"
printf a > "$CACHE/ar.alafasy/1.mp3"
printf b > "$CACHE/ar.alafasy/2.mp3.part"
ln -s "$CACHE/ar.alafasy/1.mp3" "$CACHE/ar.alafasy/3.mp3"
t "clear: keep-list keeps matching file" 0 "$SCRIPT" clear "$CACHE" "$CACHE/ar.alafasy/2.mp3.part"
ok "clear: keeps .part on keep-list" test -f "$CACHE/ar.alafasy/2.mp3.part"
ok "clear: removes others" test ! -e "$CACHE/ar.alafasy/1.mp3"
ok "clear: symlink untouched (find -type f)" test -L "$CACHE/ar.alafasy/3.mp3"
t "clear: clears everything without keep-list" 0 "$SCRIPT" clear "$CACHE"
ok "clear: empties files" test -z "$(find "$CACHE" -type f)"
ok "clear: symlink untouched (find -type f)" test -L "$CACHE/ar.alafasy/3.mp3"
rm -f "$CACHE/ar.alafasy/3.mp3"
t "clear: prunes now-empty dirs" 0 "$SCRIPT" clear "$CACHE"
ok "clear: prunes empty dirs" test ! -d "$CACHE/ar.alafasy"

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------
mkdir -p "$CACHE/ar.alafasy"
printf x > "$CACHE/ar.alafasy/5.mp3"
t "remove: deletes surah file" 0 "$SCRIPT" remove "$CACHE" ar.alafasy 5
ok "remove: file gone" test ! -e "$CACHE/ar.alafasy/5.mp3"
t "remove: missing file no-op" 0 "$SCRIPT" remove "$CACHE" ar.alafasy 5
printf x > "$CACHE/ar.alafasy/6.mp3"
ln -s "$CACHE/ar.alafasy/6.mp3" "$CACHE/ar.alafasy/7.mp3"
t "remove: symlink ignored" 0 "$SCRIPT" remove "$CACHE" ar.alafasy 7
ok "remove: symlink still present" test -L "$CACHE/ar.alafasy/7.mp3"

echo
echo "cache.sh: $PASS passed, $FAIL failed"
(( FAIL == 0 ))