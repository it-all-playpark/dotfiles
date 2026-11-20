#!/usr/bin/env bash
# tests/cloud-session-start.test.sh
# cloud/hooks/session-start.sh を偽の dockerd で検証する（本物の dockerd は起動しない）。
# socket の場所と待ち時間は CLOUD_DOCKER_SOCK / CLOUD_DOCKERD_WAIT_SECONDS で差し替える。
#
# 検証項目:
#   1. skips_when_not_remote     - CLAUDE_CODE_REMOTE が true でなければ dockerd を起動しない
#   2. skips_when_socket_exists  - socket が既にあれば dockerd を起動しない
#   3. starts_dockerd            - socket が無ければ dockerd を起動し、socket ができたら exit 0・stderr は空
#   4. timeout_exits_zero        - socket ができなくても exit 0 で終わり、stderr に理由を 1 行出す

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-ss.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

HOOK="$REPO_ROOT/cloud/hooks/session-start.sh"
FAKEBIN="$TMPROOT/bin"
mkdir -p "$FAKEBIN"

# UNIX socket を作って終わる（socket のファイルは残る）
cat >"$TMPROOT/mksock.py" <<'EOF'
import socket
import sys

socket.socket(socket.AF_UNIX).bind(sys.argv[1])
EOF

# 偽の dockerd: 呼ばれたことを記録し、FAKE_DOCKERD_MODE=socket なら socket を作る
cat >"$FAKEBIN/dockerd" <<'EOF'
#!/bin/sh
echo "dockerd $*" >>"$FAKE_DOCKERD_LOG"
if [ "$FAKE_DOCKERD_MODE" = socket ]; then
  python3 "$FAKE_MKSOCK" "$CLOUD_DOCKER_SOCK"
fi
EOF
chmod +x "$FAKEBIN/dockerd"

# run_hook <case 名> <CLAUDE_CODE_REMOTE> <FAKE_DOCKERD_MODE>: rc を RC に、stderr を $dir/err に、dockerd の記録を $dir/calls に残す
run_hook() {
  dir="$TMPROOT/$1"
  mkdir -p "$dir"
  : >"$dir/calls"
  set +e
  PATH="$FAKEBIN:$PATH" CLAUDE_CODE_REMOTE="$2" FAKE_DOCKERD_MODE="$3" \
    FAKE_DOCKERD_LOG="$dir/calls" FAKE_MKSOCK="$TMPROOT/mksock.py" \
    CLOUD_DOCKER_SOCK="$dir/d.sock" CLOUD_DOCKERD_WAIT_SECONDS="${WAIT:-5}" CLOUD_DOCKERD_LOG="$dir/dockerd.log" \
    bash "$HOOK" >"$dir/out" 2>"$dir/err"
  RC=$?
  set -e
}

# --- 1. skips_when_not_remote ---
run_hook c1 "" socket
run_hook c1b false socket
if [ "$RC" -eq 0 ] && [ ! -s "$TMPROOT/c1/calls" ] && [ ! -s "$TMPROOT/c1b/calls" ]; then
  pass "skips_when_not_remote"
else
  fail "skips_when_not_remote" "rc=$RC calls=$(cat "$TMPROOT/c1/calls" "$TMPROOT/c1b/calls")"
fi

# --- 2. skips_when_socket_exists ---
mkdir -p "$TMPROOT/c2"
python3 "$TMPROOT/mksock.py" "$TMPROOT/c2/d.sock"
run_hook c2 true socket
if [ "$RC" -eq 0 ] && [ ! -s "$TMPROOT/c2/calls" ]; then
  pass "skips_when_socket_exists"
else
  fail "skips_when_socket_exists" "rc=$RC calls=$(cat "$TMPROOT/c2/calls")"
fi

# --- 3. starts_dockerd ---
run_hook c3 true socket
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMPROOT/c3/calls" | tr -d ' ')" = 1 ] && [ -S "$TMPROOT/c3/d.sock" ] && [ ! -s "$TMPROOT/c3/err" ]; then
  pass "starts_dockerd"
else
  fail "starts_dockerd" "rc=$RC calls=$(cat "$TMPROOT/c3/calls") err=$(cat "$TMPROOT/c3/err")"
fi

# --- 4. timeout_exits_zero ---
WAIT=1 run_hook c4 true none
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMPROOT/c4/calls" | tr -d ' ')" = 1 ] && [ "$(wc -l <"$TMPROOT/c4/err" | tr -d ' ')" = 1 ]; then
  pass "timeout_exits_zero"
else
  fail "timeout_exits_zero" "rc=$RC calls=$(cat "$TMPROOT/c4/calls") err=$(cat "$TMPROOT/c4/err")"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: cloud-session-start"
