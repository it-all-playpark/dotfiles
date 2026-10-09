#!/usr/bin/env bash
# claude-code/bin/wt-add.test.sh
# 書けないパスを追跡する repo でも worktree を作る wt-add のテスト。
#
# Usage: bash claude-code/bin/wt-add.test.sh
#
# sandbox の denyWrite（`.githooks` 等）の代わりに、macOS の継承 ACL で「worktree の中にディレクトリを作れない」
# 場所を用意する（`/bin/chmod +a "everyone deny add_subdirectory,directory_inherit,only_inherit"`）。その下に
# 作った worktree ではトップレベルのファイルは書けるが、`.githooks/` などのディレクトリ配下は取り出せない。
# sandbox の中でも外でも同じ条件になる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_ADD="$SCRIPT_DIR/wt-add"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/wt-add-test.XXXXXX")"
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

# 利用者の global / system の git 設定（hooksPath 等）を持ち込まない
export GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

REPO="$TMPROOT/repo"
git init -q "$REPO"
mkdir -p "$REPO/.githooks" "$REPO/.husky"
echo readme >"$REPO/README.md"
echo notes >"$REPO/notes.txt"
echo hook >"$REPO/.githooks/pre-commit"
echo hook >"$REPO/.husky/pre-push"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init
git -C "$REPO" switch -q -c existing
echo existing >"$REPO/existing.txt"
git -C "$REPO" add existing.txt
git -C "$REPO" commit -q -m existing
git -C "$REPO" switch -q main

# この下に作るディレクトリには、さらにサブディレクトリを作れない
LOCKED="$TMPROOT/locked"
mkdir "$LOCKED"
/bin/chmod +a "everyone deny add_subdirectory,directory_inherit,only_inherit" "$LOCKED"

UNWRITABLE='.githooks/pre-commit
.husky/pre-push'

run_wt_add() {
  set +e
  bash "$WT_ADD" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
  set -e
  OUT="$(cat "$TMPROOT/out")"
  ERR="$(cat "$TMPROOT/err")"
}

# check_partial <name> <wt> <branch> <file that must be checked out>...
#   書けないパスだけが skip-worktree（ls-files -v で S）になり stdout に並び、status は空、他は取り出されている
check_partial() {
  local name="$1" wt="$2" branch="$3" f missing="" status flags head
  shift 3
  for f in "$@"; do
    [ -f "$wt/$f" ] || missing+=" $f"
  done
  status="$(git -C "$wt" status --short 2>&1)"
  flags="$(git -C "$wt" ls-files -v -- .githooks .husky 2>&1)"
  head="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>&1)"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$UNWRITABLE" ] && [ -z "$status" ] &&
    [ "$flags" = "S .githooks/pre-commit
S .husky/pre-push" ] && [ -z "$missing" ] && [ "$head" = "$branch" ]; then
    pass "$name"
  else
    fail "$name" "rc=$RC out=[$OUT] status=[$status] flags=[$flags] missing=[$missing] head=$head err=$ERR"
  fi
}

echo "=== wt-add tests ==="

# ---------------------------------------------------------------------------
# 1. 素の git worktree add は同じ条件で checkout に失敗する（helper が無いと作れない）
# ---------------------------------------------------------------------------
set +e
plain_err="$(git -C "$REPO" worktree add -q --no-track -b plain "$LOCKED/wt-plain" 2>&1)"
plain_rc=$?
set -e
if [ "$plain_rc" -ne 0 ] && [[ $plain_err == *"cannot create directory"* ]]; then
  pass "01_plain_worktree_add_fails"
else
  fail "01_plain_worktree_add_fails" "rc=$plain_rc err=$plain_err"
fi

# ---------------------------------------------------------------------------
# 2. 新規 branch（<start> 省略 = repo の HEAD）: 書けないパスに skip-worktree を付けて作る
# ---------------------------------------------------------------------------
run_wt_add "$REPO" "$LOCKED/wt-new" feature/new
check_partial "02_new_branch_from_head" "$LOCKED/wt-new" feature/new README.md notes.txt
if [ -e "$LOCKED/wt-new/existing.txt" ]; then
  fail "02_new_branch_starts_at_head" "main に無い existing.txt が取り出された"
fi

# ---------------------------------------------------------------------------
# 3. 新規 branch を <start> から作る
# ---------------------------------------------------------------------------
run_wt_add "$REPO" "$LOCKED/wt-start" feature/from-start existing
check_partial "03_new_branch_from_start" "$LOCKED/wt-start" feature/from-start README.md notes.txt existing.txt

# ---------------------------------------------------------------------------
# 4. 既存 branch を checkout する
# ---------------------------------------------------------------------------
run_wt_add "$REPO" "$LOCKED/wt-existing" existing
check_partial "04_existing_branch" "$LOCKED/wt-existing" existing README.md notes.txt existing.txt

# ---------------------------------------------------------------------------
# 5. <path> が相対なら呼び出し元の cwd から解決する（<repo> からではない）
# ---------------------------------------------------------------------------
cd "$LOCKED"
run_wt_add "$REPO" wt-rel feature/rel
cd "$TMPROOT"
check_partial "05_relative_path_from_cwd" "$LOCKED/wt-rel" feature/rel README.md notes.txt

# ---------------------------------------------------------------------------
# 6. 書けないパスが無ければ full checkout で作り、stdout には何も出さない
# ---------------------------------------------------------------------------
run_wt_add "$REPO" "$TMPROOT/wt-full" feature/full
status="$(git -C "$TMPROOT/wt-full" status --short 2>&1)"
flags="$(git -C "$TMPROOT/wt-full" ls-files -v 2>&1 | grep -v '^H ' || true)"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$status" ] && [ -z "$flags" ] &&
  [ -f "$TMPROOT/wt-full/.githooks/pre-commit" ]; then
  pass "06_full_checkout_lists_nothing"
else
  fail "06_full_checkout_lists_nothing" "rc=$RC out=[$OUT] status=[$status] flags=[$flags] err=$ERR"
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
echo "PASS: wt-add"
