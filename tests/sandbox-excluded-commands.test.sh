#!/usr/bin/env bash
# tests/sandbox-excluded-commands.test.sh
# Unit test for claude-code/settings.json's sandbox.excludedCommands array.
# Run from the repo root: bash tests/sandbox-excluded-commands.test.sh
# Requires: jq
#
# Verifies that the bin/ bare command names (30 names, resolved via PATH
# once skills#582 (dev-flow/playpark-core) and skills#585 (playpark-skills)'s
# bin/ wrappers are installed) are registered in both their argument-less
# form (`<name>`) and argument-taking form (`<name> *`), that every bin in
# the skills checkout's plugins/*/bin/ is registered or listed in
# UNREGISTERED_BINS with a reason (issue #238), and that the
# pre-existing entries (path globs, gh / git, etc.) are preserved
# unchanged. The .claude/skills 系 9 件は issue #179 で削除済み
# （skills#584 の 3 plugin 化に追従）。
# skills-wt/* と bats 系ランナーは脱出口になるので 05fe69a で削除済み（無いことを確かめる）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== sandbox.excludedCommands unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# settings_is_valid_json
# ---------------------------------------------------------------------------
echo "- settings_is_valid_json"
if jq empty "${SETTINGS}" >/dev/null 2>&1; then
  pass "settings_is_valid_json"
else
  fail "settings_is_valid_json" "${SETTINGS} is not valid JSON"
fi

EXCLUDED_JSON="$(jq -c '.sandbox.excludedCommands' "${SETTINGS}")"

has_entry() {
  jq -e --arg e "$1" 'index($e) != null' <<<"${EXCLUDED_JSON}" >/dev/null
}

count_entry() {
  jq --arg e "$1" 'map(select(. == $e)) | length' <<<"${EXCLUDED_JSON}"
}

BARE_NAMES=(
  "cross-repo-artifacts"
  "detect-and-install"
  "diff-risk-classify"
  "ensure-worktree-deps"
  "redgreen-verify"
  "secfloor-classify"
  "structural-classify"
  "veridelta-archive"
  "worktree-diff-hash"
  "worktree-teardown"
  "merge-tier-facts"
  "dev-flow-ready-set"
  "journal"
  "check-ci"
  "analyze-issue"
  "hypothesis-check"
  "analyze-dev-flow-telemetry"
  "detect-stack"
  "ac-lint"
  "dep-guardian-discover-prs"
  "dep-guardian-test-pr"
  "dep-guardian-merge-prs"
  "repo-commit"
  "repo-export"
  "repo-issue"
  "repo-pr"
  "qiita-publish"
  "zenn-publish"
)

# ---------------------------------------------------------------------------
# bare_name_entries_present
# ---------------------------------------------------------------------------
echo "- bare_name_entries_present"
missing=()
for n in "${BARE_NAMES[@]}"; do
  has_entry "${n}" || missing+=("${n}")
  has_entry "${n} *" || missing+=("${n} *")
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "bare_name_entries_present"
else
  fail "bare_name_entries_present" "Missing entries: ${missing[*]}"
fi

# ---------------------------------------------------------------------------
# bare_name_entries_not_duplicated
# ---------------------------------------------------------------------------
echo "- bare_name_entries_not_duplicated"
dupes=()
for n in "${BARE_NAMES[@]}"; do
  c1="$(count_entry "${n}")"
  c2="$(count_entry "${n} *")"
  [ "${c1}" -eq 1 ] || dupes+=("${n} (count=${c1})")
  [ "${c2}" -eq 1 ] || dupes+=("${n} * (count=${c2})")
done
if [ "${#dupes[@]}" -eq 0 ]; then
  pass "bare_name_entries_not_duplicated"
else
  fail "bare_name_entries_not_duplicated" "Unexpected counts: ${dupes[*]}"
fi

# ---------------------------------------------------------------------------
# skills_bins_registered / skills_bins_check_detects_unregistered
# skills の plugins/*/bin/ にある bare 名は、sandbox 外で動かす必要がある
# （gh を呼ぶ・git object を書く）ので excludedCommands に登録する。
# 登録し忘れると sandbox 内で落ちる（merge-tier-facts / dev-flow-ready-set, issue #238）。
# 意図的に登録しない bin は理由つきでここに書く（"<name>|<reason>"）。
# ---------------------------------------------------------------------------
UNREGISTERED_BINS=(
  "ui-verify-stack|repo の dev コマンドを実行する。sandbox 外に出すと脱出口になる（skills #766）"
  "workspace-prebuild|repo の pnpm build を実行する。sandbox 外に出すと脱出口になる"
  "ci-wait|gh も git 書き込みも呼ばない"
  "gmail-cleanup|gws の資格情報（~/.config/gws）は sandbox 内で読める"
  "gmail-receipts|gws の資格情報（~/.config/gws）は sandbox 内で読める"
  "blog-cross-post-resolve-source|gh も git 書き込みも呼ばない"
  "dep-guardian-classify-pr|gh も git 書き込みも呼ばない"
  "skill-creator-init|gh も git 書き込みも呼ばない"
  "sns-announce-check-length|gh も git 書き込みも呼ばない"
  "sns-announce-extract-metadata|gh も git 書き込みも呼ばない"
  "sns-announce-get-posting-time|gh も git 書き込みも呼ばない"
  "sns-announce-load-config|gh も git 書き込みも呼ばない"
)
SKILLS_PLUGINS_DIR="${SKILLS_PLUGINS_DIR:-${HOME}/ghq/github.com/it-all-playpark/skills/plugins}"

is_intentionally_unregistered() {
  local entry
  for entry in "${UNREGISTERED_BINS[@]}"; do
    [ "${entry%%|*}" = "$1" ] && return 0
  done
  return 1
}

# plugins dir の bin のうち、bare 形・` *` 形のどちらかが未登録で、許可リストにも無いものを出す
unregistered_skills_bins() {
  local bin name
  for bin in "$1"/*/bin/*; do
    [ -f "${bin}" ] || continue
    name="$(basename "${bin}")"
    is_intentionally_unregistered "${name}" && continue
    if ! has_entry "${name}" || ! has_entry "${name} *"; then
      echo "${name}"
    fi
  done
}

echo "- skills_bins_registered"
if [ -d "${SKILLS_PLUGINS_DIR}" ]; then
  unregistered="$(unregistered_skills_bins "${SKILLS_PLUGINS_DIR}" | tr '\n' ' ')"
  if [ -z "${unregistered}" ]; then
    pass "skills_bins_registered"
  else
    fail "skills_bins_registered" "Not in excludedCommands nor UNREGISTERED_BINS: ${unregistered}"
  fi
else
  echo "  SKIP: skills_bins_registered (${SKILLS_PLUGINS_DIR} not found)"
fi

# 突き合わせ自体が未登録の bin を検出できることを fixture で確かめる（checkout 無しでも走る）
echo "- skills_bins_check_detects_unregistered"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-excluded-fixture.XXXXXX")"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
mkdir -p "${FIXTURE_DIR}/dev-flow/bin" "${FIXTURE_DIR}/playpark-core/bin"
touch "${FIXTURE_DIR}/dev-flow/bin/merge-tier-facts" \
  "${FIXTURE_DIR}/dev-flow/bin/ci-wait" \
  "${FIXTURE_DIR}/dev-flow/bin/unregistered-fixture-bin" \
  "${FIXTURE_DIR}/playpark-core/bin/journal"
detected="$(unregistered_skills_bins "${FIXTURE_DIR}")"
if [ "${detected}" = "unregistered-fixture-bin" ]; then
  pass "skills_bins_check_detects_unregistered"
else
  fail "skills_bins_check_detects_unregistered" "Expected only unregistered-fixture-bin, got: ${detected:-<none>}"
fi

# ---------------------------------------------------------------------------
# legacy_path_globs_preserved
# ---------------------------------------------------------------------------
echo "- legacy_path_globs_preserved"
# shellcheck disable=SC2016 # 意図的に非展開: settings.json に格納された literal string と照合する
LEGACY_GLOBS=(
  '/Users/naramotoyuuji/ghq/github.com/it-all-playpark/skills/*'
  'bash /Users/naramotoyuuji/ghq/github.com/it-all-playpark/skills/*'
  'python3 /Users/naramotoyuuji/ghq/github.com/it-all-playpark/skills/*'
  'bash $HOME/ghq/github.com/it-all-playpark/skills/*'
  'python3 $HOME/ghq/github.com/it-all-playpark/skills/*'
)
missing_legacy=()
for g in "${LEGACY_GLOBS[@]}"; do
  has_entry "${g}" || missing_legacy+=("${g}")
done
if [ "${#missing_legacy[@]}" -eq 0 ]; then
  pass "legacy_path_globs_preserved"
else
  fail "legacy_path_globs_preserved" "Missing legacy globs: ${missing_legacy[*]}"
fi

# ---------------------------------------------------------------------------
# skills_wt_globs_removed
# skills-wt は sandbox から書ける場所なので、そこのスクリプトを sandbox 外で
# 実行させると脱出口になる。skills の開発は通常 clone（skills-dev）に移した（05fe69a）。
# ---------------------------------------------------------------------------
echo "- skills_wt_globs_removed"
skills_wt_left="$(jq -r '[.[] | select(contains("skills-wt"))] | join(", ")' <<<"${EXCLUDED_JSON}")"
if [ -z "${skills_wt_left}" ]; then
  pass "skills_wt_globs_removed"
else
  fail "skills_wt_globs_removed" "Should be removed but present: ${skills_wt_left}"
fi

# ---------------------------------------------------------------------------
# test_runners_not_excluded
# bats や `bash tests/...` は任意のファイルを実行するランナーなので、sandbox 外に
# 出すと書き換えて脱出できる（05fe69a で削除）。
# ---------------------------------------------------------------------------
echo "- test_runners_not_excluded"
runners_left="$(jq -r '[.[] | select(test("^(bats|bash tests/)"))] | join(", ")' <<<"${EXCLUDED_JSON}")"
if [ -z "${runners_left}" ]; then
  pass "test_runners_not_excluded"
else
  fail "test_runners_not_excluded" "Should be removed but present: ${runners_left}"
fi

# ---------------------------------------------------------------------------
# dot_claude_skills_globs_removed
# ---------------------------------------------------------------------------
echo "- dot_claude_skills_globs_removed"
# shellcheck disable=SC2016,SC2088 # 意図的に非展開: settings.json に格納された literal string と照合する
REMOVED_GLOBS=(
  '~/.claude/skills/*'
  'bash ~/.claude/skills/*'
  'node ~/.claude/skills/*'
  'python3 ~/.claude/skills/*'
  '/Users/naramotoyuuji/.claude/skills/*'
  'bash /Users/naramotoyuuji/.claude/skills/*'
  'python3 /Users/naramotoyuuji/.claude/skills/*'
  'bash $HOME/.claude/skills/*'
  'python3 $HOME/.claude/skills/*'
)
still_present=()
for g in "${REMOVED_GLOBS[@]}"; do
  has_entry "${g}" && still_present+=("${g}")
done
if [ "${#still_present[@]}" -eq 0 ]; then
  pass "dot_claude_skills_globs_removed"
else
  fail "dot_claude_skills_globs_removed" "Should be removed but present: ${still_present[*]}"
fi

# ---------------------------------------------------------------------------
# ui_verify_server_removed
# ui-verify-server は repo が宣言した dev コマンド（repo の任意コード）を実行するので、
# sandbox 外に出すと脱出口になる。dev-flow の ui_verify は sandbox 内で回す（skills #766）。
# ---------------------------------------------------------------------------
echo "- ui_verify_server_removed"
if has_entry "ui-verify-server" || has_entry "ui-verify-server *"; then
  fail "ui_verify_server_removed" "ui-verify-server must not be in excludedCommands"
else
  pass "ui_verify_server_removed"
fi

# ---------------------------------------------------------------------------
# other_existing_entries_preserved
# ---------------------------------------------------------------------------
echo "- other_existing_entries_preserved"
OTHER_ENTRIES=(
  "gh"
  "gh *"
  "git"
  "git *"
  "codex:*"
  "zernio:*"
)
missing_other=()
for e in "${OTHER_ENTRIES[@]}"; do
  has_entry "${e}" || missing_other+=("${e}")
done
if [ "${#missing_other[@]}" -eq 0 ]; then
  pass "other_existing_entries_preserved"
else
  fail "other_existing_entries_preserved" "Missing entries: ${missing_other[*]}"
fi

# ---------------------------------------------------------------------------
# no_duplicate_entries
# ---------------------------------------------------------------------------
echo "- no_duplicate_entries"
total_len="$(jq 'length' <<<"${EXCLUDED_JSON}")"
unique_len="$(jq 'unique | length' <<<"${EXCLUDED_JSON}")"
if [ "${total_len}" -eq "${unique_len}" ]; then
  pass "no_duplicate_entries"
else
  fail "no_duplicate_entries" "length=${total_len} unique=${unique_len}"
fi

# ---------------------------------------------------------------------------
# total_entry_count
# ---------------------------------------------------------------------------
echo "- total_entry_count"
if [ "${total_len}" -eq 80 ]; then
  pass "total_entry_count"
else
  fail "total_entry_count" "Expected 80 entries, got ${total_len}"
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
