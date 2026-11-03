#!/usr/bin/env bash
# scripts/sudo-keepalive.sh の検証。sudo を stub にして、最初に 1 回だけ対話の認証（sudo -v）をし、
# その後は呼び出し元が動いている間だけ非対話で延長（sudo -n -v）し続け、呼び出し元が終わると延長が止まること、
# 認証に失敗したら非 0 で終わり延長を始めないことを確かめる。
# Run from the repo root: bash tests/sudo-keepalive.test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sudo-keepalive.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sudo-keepalive-test.XXXXXX")"
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

# sudo の stub: 引数を $SUDO_LOG に 1 行ずつ残す。SUDO_FAIL=1 なら失敗する
mkdir -p "$TMPROOT/bin"
cat >"$TMPROOT/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SUDO_LOG"
[ -z "${SUDO_FAIL:-}" ]
EOF
chmod +x "$TMPROOT/bin/sudo"
export PATH="$TMPROOT/bin:$PATH" SUDO_KEEPALIVE_INTERVAL=0.1
export SUDO_LOG="$TMPROOT/sudo.log"

count() { grep -c -- "$1" "$SUDO_LOG" || true; }

echo "=== sudo-keepalive tests ==="
echo ""

echo "- authenticates_once_then_refreshes_while_caller_runs"
: >"$SUDO_LOG"
# 呼び出し元（update 役）: keepalive を呼び、延長が 3 回届くまで（最大 10 秒）動いて終わる。
# 固定時間で待つと CI の負荷で延長の回数が足りず落ちるので、回数が揃うのを待つ
OUT="$(bash -c 'bash "$1"; echo rc=$?; for _ in $(seq 100); do [ "$(grep -cx -- "-n -v" "$SUDO_LOG")" -ge 3 ] && exit 0; sleep 0.1; done' _ "$SCRIPT" 2>&1)"
first="$(head -n1 "$SUDO_LOG")"
interactive="$(grep -cx -- '-v' "$SUDO_LOG" || true)"
refresh_at_exit="$(count '^-n -v$')"
if [ "$OUT" = "rc=0" ] && [ "$first" = "-v" ] && [ "$interactive" -eq 1 ] && [ "$refresh_at_exit" -ge 3 ]; then
  pass "authenticates_once_then_refreshes_while_caller_runs"
else
  fail "authenticates_once_then_refreshes_while_caller_runs" "out=$OUT first=$first interactive=$interactive refresh=$refresh_at_exit log=$(tr '\n' ';' <"$SUDO_LOG")"
fi

echo "- refresh_stops_after_caller_exits"
sleep 0.5
before="$(count '^-n -v$')"
sleep 0.5
after="$(count '^-n -v$')"
if [ "$before" -eq "$after" ]; then
  pass "refresh_stops_after_caller_exits"
else
  fail "refresh_stops_after_caller_exits" "refreshes kept growing after caller exit: $before -> $after"
fi

echo "- auth_failure_exits_nonzero_without_refresh"
: >"$SUDO_LOG"
set +e
SUDO_FAIL=1 bash -c 'bash "$1"; rc=$?; sleep 0.5; exit "$rc"' _ "$SCRIPT" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ] && [ "$(count '^-n -v$')" -eq 0 ]; then
  pass "auth_failure_exits_nonzero_without_refresh"
else
  fail "auth_failure_exits_nonzero_without_refresh" "rc=$RC log=$(tr '\n' ';' <"$SUDO_LOG")"
fi

echo "- caller_output_not_held_by_refresh"
# 延長の間隔を長くして、延長のプロセスが呼び出し元の出力を握っていればコマンド置換が間隔ぶん待たされる形にする
: >"$SUDO_LOG"
start=$SECONDS
OUT="$(SUDO_KEEPALIVE_INTERVAL=30 bash -c 'bash "$1"; echo rc=$?' _ "$SCRIPT" 2>&1)"
elapsed=$((SECONDS - start))
if [ "$OUT" = "rc=0" ] && [ "$elapsed" -lt 10 ]; then
  pass "caller_output_not_held_by_refresh"
else
  fail "caller_output_not_held_by_refresh" "out=$OUT elapsed=$elapsed"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi
