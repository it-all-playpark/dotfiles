#!/usr/bin/env bash
# claude-code/bin/skills-worktree-add.test.sh
# skills-worktree-add（skills repo の worktree を skills-wt/<name> に作る）のテスト。
#
# Usage: bash claude-code/bin/skills-worktree-add.test.sh
#
# $TMPDIR 配下に一時 HOME を作り、bare の origin と、それを clone した
# ghq/github.com/it-all-playpark/skills を置く。スクリプトは $HOME から repo と作成先を決めるので、
# HOME を差し替えて実物のスクリプトを呼ぶ。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/skills-worktree-add"

if [[ ! -x $SUT ]]; then
  echo "FAIL: not executable: $SUT" >&2
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/skills-worktree-add-test.XXXXXX")"
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
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
}

HOME_T="$TMPROOT/home"
ORIGIN="$TMPROOT/origin.git"
REPO="$HOME_T/ghq/github.com/it-all-playpark/skills"
WT_ROOT="$HOME_T/ghq/github.com/it-all-playpark/skills-wt"

git init --quiet --bare --initial-branch=main "$ORIGIN"
git clone --quiet "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m init
git -C "$REPO" push --quiet origin HEAD:main
MAIN_SHA="$(git -C "$REPO" rev-parse HEAD)"
mkdir -p "$WT_ROOT"

# 実運用と同じく hook が走り得る状態にしておく（走ったら marker が残る）
MARKER="$TMPROOT/hook-ran"
mkdir -p "$REPO/.git/hooks"
printf '#!/bin/sh\ntouch %s\n' "$MARKER" >"$REPO/.git/hooks/post-checkout"
chmod +x "$REPO/.git/hooks/post-checkout"

run() {
  HOME="$HOME_T" bash "$SUT" "$@"
}

echo "== 正常系"
out="$(run feat-a 2>&1)" && rc=0 || rc=$?
if [[ $rc -eq 0 && $out == "$WT_ROOT/feat-a" && -d "$WT_ROOT/feat-a" ]]; then
  pass "skills-wt/feat-a を作り、そのパスを出力する"
else
  fail "正常系で作成できない (rc=$rc out=$out)"
fi
if [[ "$(git -C "$WT_ROOT/feat-a" rev-parse HEAD)" == "$MAIN_SHA" ]]; then
  pass "origin/main の commit から作る"
else
  fail "起点が origin/main ではない"
fi
if [[ "$(git -C "$WT_ROOT/feat-a" rev-parse --abbrev-ref HEAD)" == "feat-a" ]]; then
  pass "同名の branch を切る"
else
  fail "branch が feat-a ではない"
fi
if [[ ! -e $MARKER ]]; then
  pass "post-checkout hook を走らせない"
else
  fail "post-checkout hook が走った"
fi

echo "== 名前の検査"
for bad in "" "../x" "x/y" "Upper" "-x" "a..b" "x.lock" ".hidden" "$(printf 'a%.0s' {1..65})"; do
  if run "$bad" >/dev/null 2>&1; then
    fail "不正な名前を受け付けた: '$bad'"
  else
    pass "不正な名前を拒否: '${bad:0:20}'"
  fi
done
if run a b >/dev/null 2>&1; then
  fail "引数 2 個を受け付けた"
else
  pass "引数 2 個を拒否"
fi
if run >/dev/null 2>&1; then
  fail "引数なしを受け付けた"
else
  pass "引数なしを拒否"
fi
if [[ -z "$(find "$WT_ROOT" -mindepth 1 -maxdepth 1 ! -name feat-a)" ]]; then
  pass "拒否したケースで何も作らない"
else
  fail "拒否したケースで skills-wt に何か作られた"
fi

echo "== 既存の拒否"
mkdir -p "$WT_ROOT/exists-dir"
if run exists-dir >/dev/null 2>&1; then
  fail "既存のパスを受け付けた"
else
  pass "既存のパスを拒否"
fi
git -C "$REPO" branch --quiet taken origin/main
if run taken >/dev/null 2>&1; then
  fail "既存の branch を受け付けた"
else
  pass "既存の branch を拒否（-B で上書きしない）"
fi
if [[ "$(git -C "$REPO" rev-parse taken)" == "$MAIN_SHA" && ! -e "$WT_ROOT/taken" ]]; then
  pass "既存 branch を動かさず、worktree も作らない"
else
  fail "既存 branch か skills-wt が変わった"
fi

echo "== 環境変数"
if GIT_DIR="$TMPROOT/nowhere" GIT_WORK_TREE="$TMPROOT/nowhere" HOME="$HOME_T" bash "$SUT" env-ok >/dev/null 2>&1 &&
  [[ -d "$WT_ROOT/env-ok" ]]; then
  pass "GIT_DIR / GIT_WORK_TREE を無視する"
else
  fail "GIT_* 環境変数に影響された"
fi

echo
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
