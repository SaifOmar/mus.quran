#!/usr/bin/env bash
# Tests for download.sh: security hardening + the reciter-subdirectory bug fix.
# Usage: bash tests/test_download.sh
set -u

cd "$(dirname "$0")/.."
SCRIPT="$PWD/download.sh"
WORK="$(mktemp -d /tmp/opencode/quran-dl-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"
CACHE="$HOME_DIR/.cache/omarchy/quran"
STATE="$HOME_DIR/.local/state/omarchy/quran"
mkdir -p "$CACHE" "$STATE"

PASS=0
FAIL=0

t() { # name expected actual
  if [[ "$3" -eq "$2" ]]; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected exit $2, got $3)"
  fi
}

tnot() { # name actual — expected non-zero
  if [[ "$2" -ne 0 ]]; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected non-zero exit)"
  fi
}

ok() { # name condition...
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); echo "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name"
  fi
}

setup() {
  export HOME="$HOME_DIR"
  export PATH="$PWD/tests/mockbin:$PATH"
  export MOCK_CURL_LOG="$WORK/curl.log"
  : > "$MOCK_CURL_LOG"
  rm -rf "$CACHE"/* "$STATE"/*
  export MOCK_GETENT_IPS="93.184.216.34 STREAM"
  export MOCK_HEAD_MODE="head-ok"
  export MOCK_GET_MODE="get-ok"
  unset MOCK_GETENT_FAIL MOCK_HEAD_FAIL_EXIT MOCK_HANG_SECS
}

# --- happy path + reciter-subdir regression (the bug fix) -------------------
setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "happy path exits 0" 0 $?
ok "file lands at <cache>/<reciter>/1.mp3" test -f "$CACHE/ar.alafasy/1.mp3"
ok "no flat <cache>/1.mp3" test ! -e "$CACHE/1.mp3"
ok "no .part left behind" bash -c "test -z \"\$(find '$CACHE' -name '*.part')\""

# explicit download (no --dest) still uses the state root + reciter
setup
bash "$SCRIPT" ar.alafasy 1 >/dev/null 2>&1
t "default dest exits 0" 0 $?
ok "explicit download lands at state root" test -f "$STATE/ar.alafasy/1.mp3"

# --- umask + root validation ------------------------------------------------
setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
ok "umask 077 on file" test "$(stat -c %a "$CACHE/ar.alafasy/1.mp3")" = "600"
ok "umask 077 on dir" test "$(stat -c %a "$CACHE/ar.alafasy")" = "700"

setup
bash "$SCRIPT" ar.alafasy 1 --dest /etc >/dev/null 2>&1
t "dest outside quran roots rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$WORK/../etc" >/dev/null 2>&1
t "dest with .. rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE/../../x" >/dev/null 2>&1
t "dest escaping home rejected" 2 $?

# --- server-side argument validation ----------------------------------------
setup
bash "$SCRIPT" "../x" 1 --dest "$CACHE" >/dev/null 2>&1
t "traversal reciter rejected" 2 $?

setup
bash "$SCRIPT" "x/y" 1 --dest "$CACHE" >/dev/null 2>&1
t "slash reciter rejected" 2 $?

setup
bash "$SCRIPT" "$(printf 'a%.0s' {1..70})" 1 >/dev/null 2>&1
t "oversized reciter rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 200 --dest "$CACHE" >/dev/null 2>&1
t "surah out of range rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1junk --dest "$CACHE" >/dev/null 2>&1
t "junk surah rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy --only 1,200 --dest "$CACHE" >/dev/null 2>&1
t "junk in --only list rejected" 2 $?

# --- server URL validation --------------------------------------------------
setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "http://cdn.islamic.app/x/" >/dev/null 2>&1
t "http server rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://evil.com/x/" >/dev/null 2>&1
t "non-allowlisted host rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app:0/x/" >/dev/null 2>&1
t "port 0 rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app:8a/x/" >/dev/null 2>&1
t "non-numeric port rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app:080/x/" >/dev/null 2>&1
t "leading-zero port rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app:99999/x/" >/dev/null 2>&1
t "oversized port rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app%2f/x/" >/dev/null 2>&1
t "encoded slash rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic%2eapp/x/" >/dev/null 2>&1
t "encoded dot rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app%40evil/x/" >/dev/null 2>&1
t "encoded at rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app/x/?q=1" >/dev/null 2>&1
t "query string rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://cdn.islamic.app/x/#frag" >/dev/null 2>&1
t "fragment rejected" 2 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --server "https://user@cdn.islamic.app/x/" >/dev/null 2>&1
t "userinfo rejected" 2 $?

# --- transfer failures ------------------------------------------------------
# remote_size (HEAD) only runs when a local file exists (complete()) or when
# --budget-bytes is set (fetch's budget branch) — these tests use the budget
# branch so the HEAD checks are exercised.
setup
export MOCK_HEAD_MODE="head-oversize"
export MOCK_GET_MODE="get-ok"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
t "oversized content-length fails" 1 $?

setup
export MOCK_HEAD_MODE="head-wrongtype"
export MOCK_GET_MODE="get-ok"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
t "wrong content-type treated as missing" 1 $?

setup
export MOCK_HEAD_MODE="head-noctype"
export MOCK_GET_MODE="get-ok"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
t "missing content-type fails closed" 1 $?

setup
export MOCK_HEAD_MODE="head-fail"
export MOCK_GET_MODE="get-ok"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
t "failed HEAD fails the fetch" 1 $?

setup
export MOCK_GET_MODE="get-slow"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "low-speed abort fails the fetch" 1 $?

setup
export MOCK_GET_MODE="get-truncate"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "truncated transfer fails" 1 $?
ok "truncated .part cleaned up" bash -c "test -z \"\$(find '$CACHE' -name '*.part')\""

setup
export MOCK_GET_MODE="get-fail"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "curl failure reported" 1 $?
ok "failed .part cleaned up" bash -c "test -z \"\$(find '$CACHE' -name '*.part')\""

# --- DNS-rebinding pinning --------------------------------------------------
setup
export MOCK_GETENT_IPS="127.0.0.1 STREAM"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "loopback resolution aborts" 1 $?
ok "no curl call after blocked resolution" test ! -s "$MOCK_CURL_LOG"

setup
export MOCK_GETENT_IPS="10.0.0.5 STREAM"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "private resolution aborts" 1 $?

setup
export MOCK_GETENT_IPS="169.254.9.9 STREAM"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "link-local resolution aborts" 1 $?

setup
export MOCK_GETENT_IPS="224.0.0.1 STREAM"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "multicast resolution aborts" 1 $?

setup
export MOCK_GETENT_FAIL=1
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "unresolvable host fails closed" 1 $?

# both curl calls must carry the same pinned --resolve (run with a budget so
# the HEAD and the GET both execute)
setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
ok "pinned resolve on HEAD" grep -q -- "--resolve cdn.islamic.app:443:93.184.216.34" "$MOCK_CURL_LOG"
ok "pinned resolve on GET" test "$(grep -c -- "--resolve cdn.islamic.app:443:93.184.216.34" "$MOCK_CURL_LOG")" -ge 2

# --- transfer hardening flags ------------------------------------------------
setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
export GET_LINE="$(grep -- "-o " "$MOCK_CURL_LOG" | tail -1)"
ok "https-only proto" bash -c "grep -q -- '--proto =https' <<< \"\$GET_LINE\""
# token-level exact equality (substring searches for "=http" are unreliable
# here because "http" is a prefix of "https"); verify the value directly
PROTO_TOKEN="$(awk '{for(i=1;i<=NF;i++){if($i=="--proto"){print $(i+1); exit}}}' <<< "$GET_LINE")"
ok "no http proto" test "$PROTO_TOKEN" = "=https"
URL_TOKEN="$(awk '{for(i=1;i<=NF;i++){if($i ~ /^https:\/\//){print $i; exit}}}' <<< "$GET_LINE")"
ok "no http url" test "${URL_TOKEN:0:8}" = "https://"
ok "retry bounds set" bash -c "grep -q -- '--retry 3 --retry-delay 2 --retry-max-time 60' <<< \"\$GET_LINE\""
ok "connect timeout" bash -c "grep -q -- '--connect-timeout 10' <<< \"\$GET_LINE\""
ok "speed abort set" bash -c "grep -q -- '--speed-limit 1024 --speed-time 30' <<< \"\$GET_LINE\""
ok "max time set" bash -c "grep -q -- '--max-time 300' <<< \"\$GET_LINE\""
ok "max filesize set" bash -c "grep -q -- '--max-filesize 314572800' <<< \"\$GET_LINE\""
ok "no redirects" bash -c "grep -q -- '--max-redirs 0' <<< \"\$GET_LINE\""
# the mock itself fails if --max-redirs is missing from the HEAD call

# --- budget enforcement ------------------------------------------------------
setup
mkdir -p "$CACHE/other.reciter"
head -c 4096 /dev/zero > "$CACHE/other.reciter/5.mp3"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 2048 >/dev/null 2>&1
t "over-budget fill skipped" 1 $?
ok "no file written over budget" test ! -e "$CACHE/ar.alafasy/1.mp3"

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes 1073741824 >/dev/null 2>&1
t "under-budget fill proceeds" 0 $?

setup
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" --budget-bytes abc >/dev/null 2>&1
t "non-numeric budget rejected" 2 $?

# --- SIGTERM / SIGINT cleanup ------------------------------------------------
# Bash ignores SIGINT in background children by default, so the SIGINT case is
# launched through python3 (which does not reset child signal dispositions);
# the script's own trap then runs and must clean the .part file up.
setup
export MOCK_GET_MODE="get-hang"
export MOCK_HANG_SECS=30
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1 &
PID=$!
sleep 1
kill -TERM "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
CODE=$?
t "SIGTERM exits via trap" 130 $CODE
ok "no .part after SIGTERM" bash -c "test -z \"\$(find '$CACHE' -name '*.part')\""

setup
export MOCK_GET_MODE="get-hang"
export MOCK_HANG_SECS=30
if command -v python3 >/dev/null 2>&1; then
  python3 - "$SCRIPT" "$CACHE" <<'PYEOF' >/dev/null 2>&1
import os, signal, subprocess, sys, time
script, cache = sys.argv[1], sys.argv[2]
env = dict(os.environ)
p = subprocess.Popen(["bash", script, "ar.alafasy", "1", "--dest", cache], env=env)
time.sleep(1)
p.send_signal(signal.SIGINT)
code = p.wait()
sys.exit(code)
PYEOF
  CODE=$?
  t "SIGINT exits via trap" 130 $CODE
  ok "no .part after SIGINT" bash -c "test -z \"\$(find '$CACHE' -name '*.part')\""
else
  echo "SKIP: SIGINT case (python3 not available)"
fi

# --- complete() no-op on healthy files ---------------------------------------
setup
mkdir -p "$CACHE/ar.alafasy"
printf 'fake-audio-bytes' > "$CACHE/ar.alafasy/1.mp3"
bash "$SCRIPT" ar.alafasy 1 --dest "$CACHE" >/dev/null 2>&1
t "healthy file passes complete()" 0 $?
ok "healthy file not rewritten" test "$(cat "$CACHE/ar.alafasy/1.mp3")" = "fake-audio-bytes"

echo
echo "download.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]