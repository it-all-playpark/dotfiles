#!/usr/bin/env bash
# claude-code/bin/dotfiles-sync.test.sh
# dotfiles のメイン checkout を origin/main まで fast-forward する dotfiles-sync のテスト。
#
# Usage: bash claude-code/bin/dotfiles-sync.test.sh
#
# ケースごとに bare の origin、メイン checkout 役の clone（DOTFILES_SYNC_REPO）、origin に push する別の clone を
# $TMPDIR に作る。本物の dotfiles には触れない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/dotfiles-sync"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-sync-test.XXXXXX")"
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

# setup_case <name>: $TMPROOT/<name>/{origin.git,main,pusher} を作り、REPO / PUSHER を設定する
setup_case() {
  local dir="$TMPROOT/$1"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/pusher" 2>/dev/null
  echo a >"$dir/pusher/a.txt"
  echo b >"$dir/pusher/b.txt"
  git -C "$dir/pusher" add -A
  git -C "$dir/pusher" commit -q -m init
  git -C "$dir/pusher" push -q origin main
  git clone -q "$dir/origin.git" "$dir/main"
  REPO="$dir/main"
  PUSHER="$dir/pusher"
}

# push_change <file> <content>: origin/main に <file> を <content> にする commit を足す
push_change() {
  printf '%s\n' "$2" >"$PUSHER/$1"
  git -C "$PUSHER" add -A
  git -C "$PUSHER" commit -q -m "change $1"
  git -C "$PUSHER" push -q origin main
}

run_sync() {
  set +e
  DOTFILES_SYNC_REPO="$REPO" bash "$SYNC" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
  set -e
  OUT="$(cat "$TMPROOT/out")"
  ERR="$(cat "$TMPROOT/err")"
}

origin_head() {
  git -C "$PUSHER" rev-parse HEAD
}

# snapshot: HEAD・status・作業ツリーのファイル内容を 1 つの文字列にする（変わっていないことの比較用）
snapshot() {
  local f
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" status --porcelain --untracked-files=all
  for f in "$REPO"/*; do
    printf '%s=%s\n' "${f##*/}" "$(cat "$f")"
  done
}

echo "=== dotfiles-sync tests ==="

# ---------------------------------------------------------------------------
# 1. ローカル変更が無ければ origin/main まで fast-forward する（fetch もスクリプトが行う）
# ---------------------------------------------------------------------------
setup_case clean
push_change a.txt a2
run_sync
head="$(git -C "$REPO" rev-parse HEAD)"
status="$(git -C "$REPO" status --porcelain)"
if [ "$RC" -eq 0 ] && [ "$head" = "$(origin_head)" ] && [ "$(cat "$REPO/a.txt")" = a2 ] && [ -z "$status" ]; then
  pass "01_fast_forward_without_local_changes"
else
  fail "01_fast_forward_without_local_changes" "rc=$RC head=$head status=[$status] out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. 取り込む差分とローカル変更が重なったら、HEAD も作業ツリーも変えずに非 0 で終わり、重なったファイルを出す
# ---------------------------------------------------------------------------
setup_case overlap
push_change a.txt a2
echo local >"$REPO/a.txt"
before="$(snapshot)"
run_sync
after="$(snapshot)"
if [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [[ $ERR == *"a.txt（ローカル変更は取り込む内容と異なる）"* ]] &&
  [[ $ERR != *b.txt* ]]; then
  pass "02_overlap_stops_and_lists_file"
else
  fail "02_overlap_stops_and_lists_file" "rc=$RC before=[$before] after=[$after] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. 重なったローカル変更が取り込む内容と同じでも止まり、「同じ」と表示する（staged の変更も重なりに数える）
# ---------------------------------------------------------------------------
setup_case overlap-same
push_change a.txt a2
echo a2 >"$REPO/a.txt"
git -C "$REPO" add a.txt
before="$(snapshot)"
run_sync
after="$(snapshot)"
if [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [[ $ERR == *"a.txt（ローカル変更は取り込む内容と同じ）"* ]]; then
  pass "03_overlap_same_content_stops_and_says_same"
else
  fail "03_overlap_same_content_stops_and_says_same" "rc=$RC before=[$before] after=[$after] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. 取り込む差分が足すファイルと同名の untracked ファイルも重なりとして止まる
# ---------------------------------------------------------------------------
setup_case overlap-untracked
push_change new.txt incoming
echo mine >"$REPO/new.txt"
before="$(snapshot)"
run_sync
after="$(snapshot)"
if [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [[ $ERR == *"new.txt（ローカル変更は取り込む内容と異なる）"* ]]; then
  pass "04_overlap_untracked_stops"
else
  fail "04_overlap_untracked_stops" "rc=$RC before=[$before] after=[$after] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. 重ならないローカル変更（modified / untracked）は残したまま fast-forward する
# ---------------------------------------------------------------------------
setup_case disjoint
push_change a.txt a2
echo local-b >"$REPO/b.txt"
echo untracked >"$REPO/c.txt"
run_sync
head="$(git -C "$REPO" rev-parse HEAD)"
status="$(git -C "$REPO" status --porcelain)"
if [ "$RC" -eq 0 ] && [ "$head" = "$(origin_head)" ] && [ "$(cat "$REPO/a.txt")" = a2 ] &&
  [ "$(cat "$REPO/b.txt")" = local-b ] && [ "$(cat "$REPO/c.txt")" = untracked ] &&
  [ "$status" = " M b.txt
?? c.txt" ]; then
  pass "05_fast_forward_keeps_disjoint_local_changes"
else
  fail "05_fast_forward_keeps_disjoint_local_changes" "rc=$RC head=$head status=[$status] out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 6. HEAD と origin/main が分岐していたら何も変えずに非 0 で終わる
# ---------------------------------------------------------------------------
setup_case diverged
push_change a.txt a2
echo local-b >"$REPO/b.txt"
git -C "$REPO" commit -q -am "local commit"
echo dirty >"$REPO/b.txt"
before="$(snapshot)"
run_sync
after="$(snapshot)"
if [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [[ $ERR == *"分岐"* ]]; then
  pass "06_diverged_stops_without_changes"
else
  fail "06_diverged_stops_without_changes" "rc=$RC before=[$before] after=[$after] err=$ERR"
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
echo "PASS: dotfiles-sync"
