#!/usr/bin/env bash
# tests/sandbox-excluded-commands.test.sh
# Unit test for claude-code/settings.json's sandbox.excludedCommands array.
# Run from the repo root: bash tests/sandbox-excluded-commands.test.sh
# Requires: jq
#
# Verifies that the bin/ bare command names (18 names, resolved via PATH
# once skills#582's bin/ wrappers are installed) are registered in both
# their argument-less form (`<name>`) and argument-taking form
# (`<name> *`), and that the pre-existing entries (path globs, gh:*,
# git:*, etc.) are preserved unchanged. The .claude/skills 系 9 件は
# issue #179 で削除済み（skills#584 の 3 plugin 化に追従）。

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
  "ui-verify-server"
  "veridelta-archive"
  "worktree-diff-hash"
  "worktree-teardown"
  "journal"
  "check-ci"
  "analyze-issue"
  "hypothesis-check"
  "analyze-dev-flow-telemetry"
  "detect-stack"
  "ac-lint"
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
# other_existing_entries_preserved
# ---------------------------------------------------------------------------
echo "- other_existing_entries_preserved"
OTHER_ENTRIES=(
  "gh:*"
  "git:*"
  "codex:*"
  "zernio:*"
  "bash tests/run-all-bats.sh"
  "bats:*"
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
if [ "${total_len}" -eq 47 ]; then
  pass "total_entry_count"
else
  fail "total_entry_count" "Expected 47 entries, got ${total_len}"
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
