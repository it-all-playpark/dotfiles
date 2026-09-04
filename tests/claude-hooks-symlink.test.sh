#!/usr/bin/env bash
# tests/claude-hooks-symlink.test.sh
# home-manager/home/default.nix の activation.setupClaudeCode 内、
# `# hooks-symlink: begin` / `: end` マーカーで囲まれたブロックを抽出し、
# ~/.claude/hooks の symlink 管理ロジック（新規作成 + dangling symlink 掃除）を
# 単体で検証する。
#
# 検証項目:
#   1. marker_block_found              - マーカーブロックが見つかる
#   2. links_sh_and_py                 - *.sh / *.py が symlink される
#   3. skips_test_sh                   - *.test.sh は symlink されない
#   4. removes_dangling_dotfiles_symlink - dotfiles/claude-code/hooks を指す
#                                         dangling symlink は削除される
#   5. keeps_dangling_foreign_symlink  - dotfiles 以外を指す dangling symlink は
#                                         残る
#   6. keeps_real_file                 - 実ファイル (herdr-agent-state.sh 等) は
#                                         残る

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-hooks-symlink-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
# ブロック抽出
# ---------------------------------------------------------------------------
DEFAULT_NIX="$REPO_ROOT/home-manager/home/default.nix"
BLOCK="$(sed -n '/# hooks-symlink: begin/,/# hooks-symlink: end/p' "$DEFAULT_NIX")"

if [ -z "$BLOCK" ]; then
  fail "marker_block_found" "$DEFAULT_NIX にマーカー # hooks-symlink: begin/end が見つからない"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
else
  pass "marker_block_found"
fi

echo "$BLOCK" >"$TMPROOT/block.sh"

run_block() {
  local dotfiles_claude="$1"
  local claude_dir="$2"
  DOTFILES_CLAUDE="$dotfiles_claude" CLAUDE_DIR="$claude_dir" bash -c 'set -eu; source "$1"' _ "$TMPROOT/block.sh"
}

# ---------------------------------------------------------------------------
# シナリオ 2 & 3: links_sh_and_py / skips_test_sh
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s1/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s1/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/hooks" "$CLAUDE_DIR"
echo "# foo.sh" >"$DOTFILES_CLAUDE/hooks/foo.sh"
echo "# bar.py" >"$DOTFILES_CLAUDE/hooks/bar.py"
echo "# foo.test.sh" >"$DOTFILES_CLAUDE/hooks/foo.test.sh"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s1.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/hooks/foo.sh" ] && [ "$(readlink "$CLAUDE_DIR/hooks/foo.sh")" = "$DOTFILES_CLAUDE/hooks/foo.sh" ] &&
  [ -L "$CLAUDE_DIR/hooks/bar.py" ] && [ "$(readlink "$CLAUDE_DIR/hooks/bar.py")" = "$DOTFILES_CLAUDE/hooks/bar.py" ]; then
  pass "links_sh_and_py"
else
  fail "links_sh_and_py" "foo.sh / bar.py の symlink が期待通りでない (out=$(cat "$TMPROOT/s1.out"))"
fi

if [ ! -e "$CLAUDE_DIR/hooks/foo.test.sh" ]; then
  pass "skips_test_sh"
else
  fail "skips_test_sh" "foo.test.sh が symlink されてしまっている"
fi

# ---------------------------------------------------------------------------
# シナリオ 4: removes_dangling_dotfiles_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s2/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s2/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/hooks" "$CLAUDE_DIR/hooks"
ln -sfn "$DOTFILES_CLAUDE/hooks/gone.sh" "$CLAUDE_DIR/hooks/gone.sh"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s2.out" 2>&1 || true

if [ ! -e "$CLAUDE_DIR/hooks/gone.sh" ] && [ ! -L "$CLAUDE_DIR/hooks/gone.sh" ]; then
  pass "removes_dangling_dotfiles_symlink"
else
  fail "removes_dangling_dotfiles_symlink" "gone.sh の dangling symlink が削除されていない"
fi

# ---------------------------------------------------------------------------
# シナリオ 5: keeps_dangling_foreign_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s3/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s3/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/hooks" "$CLAUDE_DIR/hooks" "$TMPROOT/s3/elsewhere"
ln -sfn "$TMPROOT/s3/elsewhere/other.sh" "$CLAUDE_DIR/hooks/other.sh"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s3.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/hooks/other.sh" ] && [ ! -e "$CLAUDE_DIR/hooks/other.sh" ] &&
  [ "$(readlink "$CLAUDE_DIR/hooks/other.sh")" = "$TMPROOT/s3/elsewhere/other.sh" ]; then
  pass "keeps_dangling_foreign_symlink"
else
  fail "keeps_dangling_foreign_symlink" "他所を指す dangling symlink が誤って削除された、または状態が期待通りでない"
fi

# ---------------------------------------------------------------------------
# シナリオ 6: keeps_real_file
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s4/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s4/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/hooks" "$CLAUDE_DIR/hooks"
echo "#!/bin/sh" >"$CLAUDE_DIR/hooks/herdr-agent-state.sh"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s4.out" 2>&1 || true

if [ -f "$CLAUDE_DIR/hooks/herdr-agent-state.sh" ] && [ ! -L "$CLAUDE_DIR/hooks/herdr-agent-state.sh" ]; then
  pass "keeps_real_file"
else
  fail "keeps_real_file" "実ファイル herdr-agent-state.sh が変更・削除されてしまった"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi

echo "PASS: claude-hooks-symlink"
