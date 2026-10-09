#!/usr/bin/env bash
# claude-code/bin/agent-vault-sync-gh.test.sh
# gh の OAuth token を agent-vault の credential に写す agent-vault-sync-gh のテスト。
#
# Usage: bash claude-code/bin/agent-vault-sync-gh.test.sh
#
# fake の gh（GH_CONFIG_DIR ごとに決まった token を返す）と fake の agent-vault（argv を記録する）を
# PATH 先頭に置く。本物の gh・vault には触れない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/agent-vault-sync-gh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-sync-gh-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

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

FAKE_BIN="$TMPROOT/fake-bin"
FAKE_HOME="$TMPROOT/home"
MAIN_DIR="$FAKE_HOME/.config/gh"
SUB_DIR="$FAKE_HOME/.config/gh-sub"
mkdir -p "$FAKE_BIN" "$MAIN_DIR" "$SUB_DIR"

cat >"$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
[ "\$*" = "auth token" ] || { echo "unexpected gh args: \$*" >&2; exit 2; }
case "\${GH_CONFIG_DIR-}" in
"$MAIN_DIR") echo gho_main ;;
"$SUB_DIR") echo gho_sub ;;
*) echo "no oauth token" >&2; exit 1 ;;
esac
EOF
cat >"$FAKE_BIN/agent-vault" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$TMPROOT/vault.argv"
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/agent-vault"

run_sync() {
  rm -f "$TMPROOT/vault.argv"
  set +e
  env PATH="$FAKE_BIN:$PATH" AGENT_VAULT_SYNC_GH_ACCOUNTS="$1" bash "$SYNC" 2>"$TMPROOT/err"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
  ARGV="$(cat "$TMPROOT/vault.argv" 2>/dev/null || echo '<not called>')"
}

echo "=== agent-vault-sync-gh tests ==="

# ---------------------------------------------------------------------------
# 1. 各アカウントの config dir の token を、対応する key で default vault に 1 回で入れる
# ---------------------------------------------------------------------------
run_sync "GH_TOKEN_MAIN=$MAIN_DIR GH_TOKEN_SUB=$SUB_DIR"
expected='vault
credential
set
--vault
default
GITHUB_GIT_USERNAME=x-access-token
GH_TOKEN_MAIN=gho_main
GH_TOKEN_SUB=gho_sub'
if [[ $RC -eq 0 && $ARGV == "$expected" ]]; then
  pass "01_copies_each_account_token"
else
  fail "01_copies_each_account_token" "rc=$RC argv=$ARGV err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. config dir が無いアカウントは飛ばし、残りは入れる
# ---------------------------------------------------------------------------
run_sync "GH_TOKEN_MAIN=$MAIN_DIR GH_TOKEN_SUB=$TMPROOT/missing"
if [[ $RC -eq 0 ]] && [[ $ARGV == *"GH_TOKEN_MAIN=gho_main"* ]] && [[ $ARGV != *GH_TOKEN_SUB* ]] &&
  [[ $ERR == *"skipping GH_TOKEN_SUB"* ]]; then
  pass "02_missing_config_dir_is_skipped"
else
  fail "02_missing_config_dir_is_skipped" "rc=$RC argv=$ARGV err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. ログインしていない（gh auth token が失敗）→ vault に何も書かずに非 0
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/config/gh-loggedout"
run_sync "GH_TOKEN_MAIN=$MAIN_DIR GH_TOKEN_SUB=$TMPROOT/config/gh-loggedout"
if [[ $RC -ne 0 && $ARGV == "<not called>" ]]; then
  pass "03_logged_out_account_aborts_without_writing"
else
  fail "03_logged_out_account_aborts_without_writing" "rc=$RC argv=$ARGV err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. AGENT_VAULT_SYNC_GH_ACCOUNTS 未指定 → main（$HOME/.config/gh）に、accounts file の行
#    （コメント・空行は飛ばし、~/ は $HOME に展開）を足す
# ---------------------------------------------------------------------------
run_sync_home() {
  rm -f "$TMPROOT/vault.argv"
  set +e
  env -u AGENT_VAULT_SYNC_GH_ACCOUNTS PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" \
    AGENT_VAULT_SYNC_GH_ACCOUNTS_FILE="$1" bash "$SYNC" 2>"$TMPROOT/err"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
  ARGV="$(cat "$TMPROOT/vault.argv" 2>/dev/null || echo '<not called>')"
}

printf '# private accounts\n\nGH_TOKEN_SUB=~/.config/gh-sub\n' >"$TMPROOT/accounts"
run_sync_home "$TMPROOT/accounts"
expected='vault
credential
set
--vault
default
GITHUB_GIT_USERNAME=x-access-token
GH_TOKEN_MAIN=gho_main
GH_TOKEN_SUB=gho_sub'
if [[ $RC -eq 0 && $ARGV == "$expected" ]]; then
  pass "04_accounts_file_adds_to_main"
else
  fail "04_accounts_file_adds_to_main" "rc=$RC argv=$ARGV err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. accounts file が無い（private repo を clone していないマシン）→ main だけ
# ---------------------------------------------------------------------------
run_sync_home "$TMPROOT/missing-accounts"
if [[ $RC -eq 0 ]] && [[ $ARGV == *"GH_TOKEN_MAIN=gho_main"* ]] && [[ $ARGV != *GH_TOKEN_SUB* ]]; then
  pass "05_without_accounts_file_syncs_main_only"
else
  fail "05_without_accounts_file_syncs_main_only" "rc=$RC argv=$ARGV err=$ERR"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: agent-vault-sync-gh"
