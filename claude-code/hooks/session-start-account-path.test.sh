#!/usr/bin/env bash
# Test suite for session-start-account-path.sh
#
# Usage: bash session-start-account-path.test.sh
#
# ~/.claude/bin (gh / gcloud shim) をセッション PATH 先頭に載せる SessionStart hook の
# テスト。$CLAUDE_ENV_FILE への export 追記が、PATH の状態に応じて正しく
# 起きる/起きないこと、CLAUDE_ENV_FILE 未設定時に何もしないこと、複数回呼ばれても
# 重複追加しないこと（resume / compact での再実行）を確認する。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/session-start-account-path.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-start-account-path-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

HOME_T="$TMPROOT/home"
mkdir -p "$HOME_T"

# env -i は PATH をテスト対象の値に差し替えるため、bash 自体の探索にもその PATH が
# 使われてしまう。事前に絶対パスへ解決しておき、探索対象から外す。
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
FAILURES=()

pass() {
  printf "  \033[32mPASS\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m %s\n" "$1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
}

echo "=== session-start-account-path tests ==="

# ---------------------------------------------------------------------------
# 1. PATH に ~/.claude/bin が無い → env file に export 行が 1 行追記される
# ---------------------------------------------------------------------------
ENV_FILE1="$TMPROOT/env1"
: >"$ENV_FILE1"
set +e
OUT="$(env -i PATH="/usr/bin:/bin" HOME="$HOME_T" CLAUDE_ENV_FILE="$ENV_FILE1" "$BASH_BIN" "$HOOK" 2>&1)"
RC=$?
set -e
EXPECTED="export PATH=\"$HOME_T/.claude/bin:\$PATH\""
ACTUAL="$(cat "$ENV_FILE1")"
if [[ $RC -eq 0 && $ACTUAL == "$EXPECTED" ]]; then
  pass "01_path_without_shim_dir_appends_export_line"
else
  fail "01_path_without_shim_dir_appends_export_line" "rc=$RC actual=[$ACTUAL] expected=[$EXPECTED] out=$OUT"
fi

# ---------------------------------------------------------------------------
# 2. PATH が既に ~/.claude/bin で始まる → env file は変更されない
# ---------------------------------------------------------------------------
ENV_FILE2="$TMPROOT/env2"
: >"$ENV_FILE2"
set +e
OUT="$(env -i PATH="$HOME_T/.claude/bin:/usr/bin" HOME="$HOME_T" CLAUDE_ENV_FILE="$ENV_FILE2" "$BASH_BIN" "$HOOK" 2>&1)"
RC=$?
set -e
ACTUAL="$(cat "$ENV_FILE2")"
if [[ $RC -eq 0 && -z $ACTUAL ]]; then
  pass "02_path_already_has_shim_dir_leaves_env_file_untouched"
else
  fail "02_path_already_has_shim_dir_leaves_env_file_untouched" "rc=$RC actual=[$ACTUAL] out=$OUT"
fi

# ---------------------------------------------------------------------------
# 3. CLAUDE_ENV_FILE 未設定 → exit 0、どこにも書き込まない
# ---------------------------------------------------------------------------
BEFORE="$(find "$TMPROOT" -type f | sort)"
set +e
OUT="$(env -i PATH="/usr/bin:/bin" HOME="$HOME_T" "$BASH_BIN" "$HOOK" 2>&1)"
RC=$?
set -e
AFTER="$(find "$TMPROOT" -type f | sort)"
if [[ $RC -eq 0 && $BEFORE == "$AFTER" ]]; then
  pass "03_missing_claude_env_file_is_a_noop"
else
  fail "03_missing_claude_env_file_is_a_noop" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------------------
# 4. 2 回呼ばれても（2 回目は PATH に shim dir が既にある）1 行のまま
#    （resume / compact での再実行を想定。hook 自体の冪等性は PATH の状態次第）
# ---------------------------------------------------------------------------
ENV_FILE4="$TMPROOT/env4"
: >"$ENV_FILE4"
set +e
env -i PATH="/usr/bin:/bin" HOME="$HOME_T" CLAUDE_ENV_FILE="$ENV_FILE4" "$BASH_BIN" "$HOOK" >/dev/null 2>&1
RC1=$?
env -i PATH="$HOME_T/.claude/bin:/usr/bin:/bin" HOME="$HOME_T" CLAUDE_ENV_FILE="$ENV_FILE4" "$BASH_BIN" "$HOOK" >/dev/null 2>&1
RC2=$?
set -e
LINE_COUNT="$(wc -l <"$ENV_FILE4" | tr -d ' ')"
if [[ $RC1 -eq 0 && $RC2 -eq 0 && $LINE_COUNT -eq 1 ]]; then
  pass "04_second_call_with_shim_dir_in_path_does_not_duplicate"
else
  fail "04_second_call_with_shim_dir_in_path_does_not_duplicate" "rc1=$RC1 rc2=$RC2 lines=$LINE_COUNT content=$(cat "$ENV_FILE4")"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: session-start-account-path"
