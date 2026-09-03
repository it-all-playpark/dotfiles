#!/usr/bin/env bash
# tests/hunk-review-symlink.test.sh
# home-manager/home/default.nix の activation.setupClaudeCode 内、
# `# hunk-review-symlink: begin` / `: end` マーカーで囲まれたブロックを抽出し、
# ~/.claude/skills/hunk-review symlink のロジックを単体で検証する。
#
# skills#571 (plugin 3 分割 / plugins 化) 以降、~/.claude/skills の repo symlink は
# 撤去される。hunk-review は plugin dir の外 (~/.claude/skills/hunk-review) に置く
# 必要があるため、`~/.claude/skills` を mkdir -p で実 dir 化してから symlink を貼る。
#
# 検証項目:
#   1. creates_skills_dir_and_symlink   - skills dir が無ければ作って symlink を貼る
#   2. keeps_repo_symlink_and_links_inside - skills が repo への symlink なら維持し内部に貼る
#   3. refreshes_stale_symlink          - 既存 symlink は新しい target へ張り替える
#   4. skips_real_directory             - hunk-review が実 dir なら触らず Warning
#   5. skips_dangling_skills_symlink    - skills が dangling symlink なら mkdir -p せず Warning
#   6. no_plugin_dir_placement          - 抽出ブロックが plugin dir を参照していない (静的検査)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/hunk-review-test.XXXXXX")"
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
BLOCK="$(sed -n '/# hunk-review-symlink: begin/,/# hunk-review-symlink: end/p' "$DEFAULT_NIX")"

if [ -z "$BLOCK" ]; then
  fail "marker_block_found" "$DEFAULT_NIX にマーカー # hunk-review-symlink: begin/end が見つからない"
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

FAKE_HUNK="$TMPROOT/store/hunkdiff-test"
mkdir -p "$FAKE_HUNK/skills/hunk-review"
echo "# fake hunk-review skill" >"$FAKE_HUNK/skills/hunk-review/SKILL.md"

# nix 補間 ${pkgs.hunk} を偽の store path に置換し、bash として source 可能な形にする
echo "${BLOCK//\$\{pkgs.hunk\}/$FAKE_HUNK}" >"$TMPROOT/block.sh"

run_block() {
  local claude_dir="$1"
  CLAUDE_DIR="$claude_dir" bash -c 'set -eu; source "$1"' _ "$TMPROOT/block.sh"
}

# ---------------------------------------------------------------------------
# シナリオ 1: creates_skills_dir_and_symlink
# ---------------------------------------------------------------------------
SCENARIO="$TMPROOT/s1/claude"
mkdir -p "$SCENARIO"
run_block "$SCENARIO" >"$TMPROOT/s1.out" 2>&1 || true

if [ -d "$SCENARIO/skills" ] && [ ! -L "$SCENARIO/skills" ]; then
  if [ -L "$SCENARIO/skills/hunk-review" ] && [ "$(readlink "$SCENARIO/skills/hunk-review")" = "$FAKE_HUNK/skills/hunk-review" ]; then
    pass "creates_skills_dir_and_symlink"
  else
    fail "creates_skills_dir_and_symlink" "hunk-review symlink target が期待値と異なる: $(readlink "$SCENARIO/skills/hunk-review" 2>&1 || echo 'not a symlink')"
  fi
else
  fail "creates_skills_dir_and_symlink" "$SCENARIO/skills が実 dir として作られていない"
fi

# ---------------------------------------------------------------------------
# シナリオ 2: keeps_repo_symlink_and_links_inside
# ---------------------------------------------------------------------------
SCENARIO="$TMPROOT/s2/claude"
REPO_SKILLS="$TMPROOT/s2/repo"
mkdir -p "$SCENARIO" "$REPO_SKILLS"
ln -sfn "$REPO_SKILLS" "$SCENARIO/skills"
run_block "$SCENARIO" >"$TMPROOT/s2.out" 2>&1 || true

if [ -L "$SCENARIO/skills" ] && [ "$(readlink "$SCENARIO/skills")" = "$REPO_SKILLS" ]; then
  if [ -L "$REPO_SKILLS/hunk-review" ] && [ "$(readlink "$REPO_SKILLS/hunk-review")" = "$FAKE_HUNK/skills/hunk-review" ]; then
    pass "keeps_repo_symlink_and_links_inside"
  else
    fail "keeps_repo_symlink_and_links_inside" "$REPO_SKILLS/hunk-review symlink が期待通りでない"
  fi
else
  fail "keeps_repo_symlink_and_links_inside" "$SCENARIO/skills の symlink が維持されていない"
fi

# ---------------------------------------------------------------------------
# シナリオ 3: refreshes_stale_symlink
# ---------------------------------------------------------------------------
SCENARIO="$TMPROOT/s3/claude"
OLD_STORE="$TMPROOT/old-store"
mkdir -p "$SCENARIO/skills" "$OLD_STORE"
ln -sfn "$OLD_STORE" "$SCENARIO/skills/hunk-review"
run_block "$SCENARIO" >"$TMPROOT/s3.out" 2>&1 || true

if [ -L "$SCENARIO/skills/hunk-review" ] && [ "$(readlink "$SCENARIO/skills/hunk-review")" = "$FAKE_HUNK/skills/hunk-review" ]; then
  pass "refreshes_stale_symlink"
else
  fail "refreshes_stale_symlink" "stale symlink が新 target へ張り替えられていない: $(readlink "$SCENARIO/skills/hunk-review" 2>&1 || echo 'not a symlink')"
fi

# ---------------------------------------------------------------------------
# シナリオ 4: skips_real_directory
# ---------------------------------------------------------------------------
SCENARIO="$TMPROOT/s4/claude"
mkdir -p "$SCENARIO/skills/hunk-review"
echo "manual content" >"$SCENARIO/skills/hunk-review/manual.txt"
OUT="$(run_block "$SCENARIO" 2>&1)"
RC=$?

if [ -d "$SCENARIO/skills/hunk-review" ] && [ ! -L "$SCENARIO/skills/hunk-review" ] &&
  echo "$OUT" | grep -q "Warning" && echo "$OUT" | grep -q "manual review needed" &&
  [ "$RC" -eq 0 ]; then
  pass "skips_real_directory"
else
  fail "skips_real_directory" "実 dir が保持されない、または Warning/manual review needed が出力されない、または exit != 0 (rc=$RC, out=$OUT)"
fi

# ---------------------------------------------------------------------------
# シナリオ 5: skips_dangling_skills_symlink
# ---------------------------------------------------------------------------
SCENARIO="$TMPROOT/s5/claude"
mkdir -p "$SCENARIO"
ln -sfn "$TMPROOT/s5/does-not-exist" "$SCENARIO/skills"
OUT="$(run_block "$SCENARIO" 2>&1)"
RC=$?

if [ -L "$SCENARIO/skills" ] && [ ! -e "$SCENARIO/skills" ] &&
  echo "$OUT" | grep -q "dangling symlink" &&
  [ "$RC" -eq 0 ]; then
  pass "skips_dangling_skills_symlink"
else
  fail "skips_dangling_skills_symlink" "dangling symlink が mkdir -p で壊れた、または 'dangling symlink' メッセージが出力されない、または exit != 0 (rc=$RC, out=$OUT)"
fi

# ---------------------------------------------------------------------------
# 静的検査: no_plugin_dir_placement
# ---------------------------------------------------------------------------
case "$BLOCK" in
*plugins/playpark-skills*)
  fail "no_plugin_dir_placement" "抽出ブロックに plugins/playpark-skills への参照が残っている (link mode の escape 検査に抵触する)"
  ;;
*)
  pass "no_plugin_dir_placement"
  ;;
esac

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

echo "PASS: hunk-review-symlink"
