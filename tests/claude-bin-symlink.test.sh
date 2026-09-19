#!/usr/bin/env bash
# tests/claude-bin-symlink.test.sh
# home-manager/home/default.nix の activation.setupClaudeCode 内、
# `# bin-symlink: begin` / `: end` と `# account-map-symlink: begin` / `: end` で
# 囲まれたブロックを抽出し、~/.claude/bin と ~/.claude/account-map.json の
# symlink 管理ロジックを単体で検証する。
#
# 検証項目:
#   1. marker_blocks_found               - 両マーカーブロックが見つかる
#   2. links_account_exec_and_tool_links  - account-exec と repo 内 symlink (gh, gcloud) が
#                                           ~/.claude/bin に symlink される（gh は
#                                           dotfiles 側 bin/gh を指す 2 段構成）
#   3. skips_test_sh                      - *.test.sh は symlink されない
#   4. removes_dangling_dotfiles_symlink  - dotfiles/claude-code/bin を指す dangling
#                                           symlink は削除される
#   5. keeps_dangling_foreign_symlink     - dotfiles 以外を指す dangling symlink は残る
#   6. keeps_real_file                    - dotfiles に無い名前の実ファイルは残る
#   7. links_account_map                  - account-map.json が symlink される
#   8. skips_account_map_when_absent      - dotfiles 側に無ければ何もしない（エラーなし）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-bin-symlink-test.XXXXXX")"
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
BIN_BLOCK="$(sed -n '/# bin-symlink: begin/,/# bin-symlink: end/p' "$DEFAULT_NIX")"
MAP_BLOCK="$(sed -n '/# account-map-symlink: begin/,/# account-map-symlink: end/p' "$DEFAULT_NIX")"

if [ -z "$BIN_BLOCK" ] || [ -z "$MAP_BLOCK" ]; then
  fail "marker_blocks_found" "$DEFAULT_NIX にマーカー # bin-symlink / # account-map-symlink の begin/end が揃っていない"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
else
  pass "marker_blocks_found"
fi

{
  echo "$MAP_BLOCK"
  echo "$BIN_BLOCK"
} >"$TMPROOT/block.sh"

run_block() {
  local dotfiles_claude="$1"
  local claude_dir="$2"
  DOTFILES_CLAUDE="$dotfiles_claude" CLAUDE_DIR="$claude_dir" bash -c 'set -eu; source "$1"' _ "$TMPROOT/block.sh"
}

# ---------------------------------------------------------------------------
# シナリオ 2 & 3 & 7: links_account_exec_and_tool_links / skips_test_sh / links_account_map
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s1/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s1/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR"
printf '#!/bin/sh\necho account-exec\n' >"$DOTFILES_CLAUDE/bin/account-exec"
chmod +x "$DOTFILES_CLAUDE/bin/account-exec"
ln -s account-exec "$DOTFILES_CLAUDE/bin/gh"
ln -s account-exec "$DOTFILES_CLAUDE/bin/gcloud"
echo "# test" >"$DOTFILES_CLAUDE/bin/account-exec.test.sh"
echo '{"orgs":{}}' >"$DOTFILES_CLAUDE/account-map.json"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s1.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/bin/account-exec" ] && [ "$(readlink "$CLAUDE_DIR/bin/account-exec")" = "$DOTFILES_CLAUDE/bin/account-exec" ] &&
  [ -L "$CLAUDE_DIR/bin/gh" ] && [ "$(readlink "$CLAUDE_DIR/bin/gh")" = "$DOTFILES_CLAUDE/bin/gh" ] &&
  [ -L "$CLAUDE_DIR/bin/gcloud" ] && [ "$(readlink "$CLAUDE_DIR/bin/gcloud")" = "$DOTFILES_CLAUDE/bin/gcloud" ] &&
  [ -x "$CLAUDE_DIR/bin/gh" ] && [ "$("$CLAUDE_DIR/bin/gh")" = "account-exec" ]; then
  pass "links_account_exec_and_tool_links"
else
  fail "links_account_exec_and_tool_links" "bin/* の symlink が期待通りでない (out=$(cat "$TMPROOT/s1.out"); ls=$(ls -l "$CLAUDE_DIR/bin" 2>&1))"
fi

if [ ! -e "$CLAUDE_DIR/bin/account-exec.test.sh" ] && [ ! -L "$CLAUDE_DIR/bin/account-exec.test.sh" ]; then
  pass "skips_test_sh"
else
  fail "skips_test_sh" "account-exec.test.sh が symlink されてしまっている"
fi

if [ -L "$CLAUDE_DIR/account-map.json" ] && [ "$(readlink "$CLAUDE_DIR/account-map.json")" = "$DOTFILES_CLAUDE/account-map.json" ]; then
  pass "links_account_map"
else
  fail "links_account_map" "account-map.json の symlink が期待通りでない (out=$(cat "$TMPROOT/s1.out"))"
fi

# ---------------------------------------------------------------------------
# シナリオ 4: removes_dangling_dotfiles_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s2/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s2/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin"
ln -sfn "$DOTFILES_CLAUDE/bin/gone" "$CLAUDE_DIR/bin/gone"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s2.out" 2>&1 || true

if [ ! -e "$CLAUDE_DIR/bin/gone" ] && [ ! -L "$CLAUDE_DIR/bin/gone" ]; then
  pass "removes_dangling_dotfiles_symlink"
else
  fail "removes_dangling_dotfiles_symlink" "gone の dangling symlink が削除されていない"
fi

# ---------------------------------------------------------------------------
# シナリオ 5: keeps_dangling_foreign_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s3/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s3/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin" "$TMPROOT/s3/elsewhere"
ln -sfn "$TMPROOT/s3/elsewhere/other" "$CLAUDE_DIR/bin/other"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s3.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/bin/other" ] && [ ! -e "$CLAUDE_DIR/bin/other" ] &&
  [ "$(readlink "$CLAUDE_DIR/bin/other")" = "$TMPROOT/s3/elsewhere/other" ]; then
  pass "keeps_dangling_foreign_symlink"
else
  fail "keeps_dangling_foreign_symlink" "他所を指す dangling symlink が誤って削除された、または状態が期待通りでない"
fi

# ---------------------------------------------------------------------------
# シナリオ 6 & 8: keeps_real_file / skips_account_map_when_absent
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s4/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s4/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin"
echo "#!/bin/sh" >"$CLAUDE_DIR/bin/local-tool"
if run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s4.out" 2>&1; then
  s4_rc=0
else
  s4_rc=$?
fi

if [ -f "$CLAUDE_DIR/bin/local-tool" ] && [ ! -L "$CLAUDE_DIR/bin/local-tool" ]; then
  pass "keeps_real_file"
else
  fail "keeps_real_file" "実ファイル local-tool が変更・削除されてしまった"
fi

if [ "$s4_rc" -eq 0 ] && [ ! -e "$CLAUDE_DIR/account-map.json" ] && [ ! -L "$CLAUDE_DIR/account-map.json" ]; then
  pass "skips_account_map_when_absent"
else
  fail "skips_account_map_when_absent" "account-map.json 不在時にエラー終了 (rc=$s4_rc) または symlink が作られた (out=$(cat "$TMPROOT/s4.out"))"
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

echo "PASS: claude-bin-symlink"
