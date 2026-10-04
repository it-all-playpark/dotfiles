#!/usr/bin/env bash
# scripts/install-git-hooks.sh の検証。一時 repo に .githooks を置いてインストーラを走らせ、
# shim の設置・冪等性・他の hook を壊さないこと・CLAUDECODE での停止・worktree への委譲を確かめる。
# Run from the repo root: bash tests/install-git-hooks.test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-git-hooks.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/install-git-hooks-test.XXXXXX")"
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

# 外側の git 環境（hook 実行中の GIT_DIR など）と Claude の印を持ち込まない
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CLAUDECODE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# make_repo <dir> <marker>: .githooks/pre-push が "<marker>" を出力する repo を作る
make_repo() {
  git init -q "$1"
  mkdir -p "$1/.githooks"
  printf '#!/bin/sh\necho %s\n' "$2" >"$1/.githooks/pre-push"
  chmod +x "$1/.githooks/pre-push"
  git -C "$1" add .githooks
  git -C "$1" commit -q -m init
}

echo "=== install-git-hooks tests ==="
echo ""

REPO="$TMPROOT/repo"
make_repo "$REPO" main-hook
HOOKS="$REPO/.git/hooks"

echo "- installs_shim"
(cd "$REPO" && bash "$INSTALLER")
if [ -x "$HOOKS/pre-push" ] && grep -qF '# dotfiles: .githooks dispatcher' "$HOOKS/pre-push"; then
  pass "installs_shim"
else
  fail "installs_shim" "$HOOKS/pre-push is missing or not a dispatcher"
fi

echo "- idempotent"
before="$(cat "$HOOKS/pre-push")"
(cd "$REPO" && bash "$INSTALLER")
if [ "$(cat "$HOOKS/pre-push")" = "$before" ]; then
  pass "idempotent"
else
  fail "idempotent" "second run changed the shim"
fi

echo "- shim_dispatches_to_githooks"
out="$(cd "$REPO" && "$HOOKS/pre-push")"
if [ "$out" = "main-hook" ]; then
  pass "shim_dispatches_to_githooks"
else
  fail "shim_dispatches_to_githooks" "expected main-hook, got '$out'"
fi

echo "- shim_skips_in_claude_code"
out="$(cd "$REPO" && CLAUDECODE=1 "$HOOKS/pre-push")"
if [ -z "$out" ]; then
  pass "shim_skips_in_claude_code"
else
  fail "shim_skips_in_claude_code" "hook ran under CLAUDECODE=1: '$out'"
fi

echo "- shim_uses_worktree_hooks"
git -C "$REPO" worktree add -q -b wt "$TMPROOT/wt"
printf '#!/bin/sh\necho wt-hook\n' >"$TMPROOT/wt/.githooks/pre-push"
out="$(cd "$TMPROOT/wt" && "$HOOKS/pre-push")"
if [ "$out" = "wt-hook" ]; then
  pass "shim_uses_worktree_hooks"
else
  fail "shim_uses_worktree_hooks" "expected wt-hook, got '$out'"
fi

echo "- respects_absolute_hookspath"
# 絶対パスの core.hooksPath（実環境で見られる形）でも、その場所に shim を置く
REPO2="$TMPROOT/repo2"
make_repo "$REPO2" hook2
mkdir -p "$TMPROOT/custom-hooks"
git -C "$REPO2" config core.hooksPath "$TMPROOT/custom-hooks"
(cd "$REPO2" && bash "$INSTALLER")
if grep -qF '# dotfiles: .githooks dispatcher' "$TMPROOT/custom-hooks/pre-push" 2>/dev/null; then
  pass "respects_absolute_hookspath"
else
  fail "respects_absolute_hookspath" "shim not installed into core.hooksPath"
fi

echo "- keeps_foreign_hook"
REPO3="$TMPROOT/repo3"
make_repo "$REPO3" hook3
printf '#!/bin/sh\necho foreign\n' >"$REPO3/.git/hooks/pre-push"
(cd "$REPO3" && bash "$INSTALLER") 2>/dev/null
if [ "$(cat "$REPO3/.git/hooks/pre-push")" = "$(printf '#!/bin/sh\necho foreign')" ]; then
  pass "keeps_foreign_hook"
else
  fail "keeps_foreign_hook" "existing non-dispatcher hook was overwritten"
fi

echo "- noop_when_hookspath_is_githooks"
REPO4="$TMPROOT/repo4"
make_repo "$REPO4" hook4
git -C "$REPO4" config core.hooksPath .githooks
(cd "$REPO4" && bash "$INSTALLER")
if [ "$(cat "$REPO4/.githooks/pre-push")" = "$(printf '#!/bin/sh\necho hook4')" ]; then
  pass "noop_when_hookspath_is_githooks"
else
  fail "noop_when_hookspath_is_githooks" "tracked .githooks/pre-push was overwritten"
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
