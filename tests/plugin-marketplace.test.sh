#!/usr/bin/env bash
# tests/plugin-marketplace.test.sh
# Unit test for claude-code/settings.json's extraKnownMarketplaces /
# enabledPlugins entries introduced for skills#584's 3 plugin split
# (playpark-core / dev-flow / playpark-skills, marketplace playpark-local,
# link mode via source: command).
# Run from the repo root: bash tests/plugin-marketplace.test.sh
# Requires: jq
#
# String checks are done with jq's test() rather than grep: the grep
# resolved in this environment is macOS BSD grep, which does not
# interpret bracket-expression escapes like \x20, so ASCII/whitespace
# assertions are expressed with jq (Oniguruma) instead.

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

echo "=== extraKnownMarketplaces / enabledPlugins unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# settings_is_valid_json
# ---------------------------------------------------------------------------
echo "- settings_is_valid_json"
if jq empty "${SETTINGS}" >/dev/null 2>&1; then
  pass "settings_is_valid_json"
else
  fail "settings_is_valid_json" "${SETTINGS} is not valid JSON"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# marketplace_is_inline_settings_source
# ---------------------------------------------------------------------------
echo "- marketplace_is_inline_settings_source"
if jq -e '
    .extraKnownMarketplaces["playpark-local"].source.source == "settings"
    and .extraKnownMarketplaces["playpark-local"].source.name == "playpark-local"
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "marketplace_is_inline_settings_source"
else
  fail "marketplace_is_inline_settings_source" "extraKnownMarketplaces.playpark-local.source is not an inline settings-source manifest with matching name"
fi

# ---------------------------------------------------------------------------
# marketplace_plugins_are_the_three
# ---------------------------------------------------------------------------
echo "- marketplace_plugins_are_the_three"
if jq -e '
    (.extraKnownMarketplaces["playpark-local"].source.plugins | map(.name))
      == ["playpark-core", "dev-flow", "playpark-skills"]
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "marketplace_plugins_are_the_three"
else
  fail "marketplace_plugins_are_the_three" "plugins[] names/order != [playpark-core, dev-flow, playpark-skills]"
fi

# ---------------------------------------------------------------------------
# plugin_sources_are_command_link
# ---------------------------------------------------------------------------
echo "- plugin_sources_are_command_link"
if jq -e '
    [.extraKnownMarketplaces["playpark-local"].source.plugins[]
      | (.source.source == "command" and .source.mode == "link")]
      | all
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "plugin_sources_are_command_link"
else
  fail "plugin_sources_are_command_link" "Not all 3 plugins have source.source==command and source.mode==link"
fi

# ---------------------------------------------------------------------------
# command_points_to_plugin_dir
# ---------------------------------------------------------------------------
echo "- command_points_to_plugin_dir"
mismatched=()
for name in playpark-core dev-flow playpark-skills; do
  expected="echo \"\$HOME/ghq/github.com/it-all-playpark/skills/plugins/${name}\""
  actual="$(jq -r --arg n "${name}" '
      .extraKnownMarketplaces["playpark-local"].source.plugins[]
        | select(.name == $n) | .source.command
    ' "${SETTINGS}")"
  [ "${actual}" = "${expected}" ] || mismatched+=("${name}: got [${actual}]")
done
if [ "${#mismatched[@]}" -eq 0 ]; then
  pass "command_points_to_plugin_dir"
else
  fail "command_points_to_plugin_dir" "Mismatches: ${mismatched[*]}"
fi

# ---------------------------------------------------------------------------
# command_is_printable_ascii
# ---------------------------------------------------------------------------
echo "- command_is_printable_ascii"
bad=()
for name in playpark-core dev-flow playpark-skills; do
  ok="$(jq -r --arg n "${name}" '
      (.extraKnownMarketplaces["playpark-local"].source.plugins[]
        | select(.name == $n) | .source.command) as $c
      | (($c | test("^[ -~]+$")) and (($c | test("    ")) | not) and ($c | length) <= 500)
    ' "${SETTINGS}")"
  [ "${ok}" = "true" ] || bad+=("${name}")
done
if [ "${#bad[@]}" -eq 0 ]; then
  pass "command_is_printable_ascii"
else
  fail "command_is_printable_ascii" "Failed ASCII/whitespace/length check: ${bad[*]}"
fi

# ---------------------------------------------------------------------------
# command_prints_absolute_plugin_path
# ---------------------------------------------------------------------------
echo "- command_prints_absolute_plugin_path"
FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/pm-test.XXXXXX")"
trap 'rm -rf "${FAKE_HOME}"' EXIT

exec_mismatch=()
for name in playpark-core dev-flow playpark-skills; do
  cmd="$(jq -r --arg n "${name}" '
      .extraKnownMarketplaces["playpark-local"].source.plugins[]
        | select(.name == $n) | .source.command
    ' "${SETTINGS}")"
  out="$(HOME="${FAKE_HOME}" sh -c "${cmd}")" || {
    exec_mismatch+=("${name}: command exited non-zero")
    continue
  }
  expected_out="${FAKE_HOME}/ghq/github.com/it-all-playpark/skills/plugins/${name}"
  [ "${out}" = "${expected_out}" ] || exec_mismatch+=("${name}: got [${out}] want [${expected_out}]")
done
if [ "${#exec_mismatch[@]}" -eq 0 ]; then
  pass "command_prints_absolute_plugin_path"
else
  fail "command_prints_absolute_plugin_path" "Mismatches: ${exec_mismatch[*]}"
fi

# ---------------------------------------------------------------------------
# enabled_plugins_registered
# ---------------------------------------------------------------------------
echo "- enabled_plugins_registered"
if jq -e '
    .enabledPlugins["playpark-core@playpark-local"] == true
    and .enabledPlugins["dev-flow@playpark-local"] == true
    and .enabledPlugins["playpark-skills@playpark-local"] == true
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "enabled_plugins_registered"
else
  fail "enabled_plugins_registered" "One or more of playpark-core@playpark-local / dev-flow@playpark-local / playpark-skills@playpark-local is not true"
fi

# ---------------------------------------------------------------------------
# legacy_playpark_plugin_still_enabled
# ---------------------------------------------------------------------------
# NOTE: it-all-playpark/skills#584 (plugin bin/ 化) がまだ未 merge のため、
# playpark-local 側だけを有効化すると journal / secfloor-classify 等の
# bare command が PATH から消え、playpark-local の install も失敗しうる。
# 584 merge 後の別 PR で false に倒すまでは true のまま残す。
echo "- legacy_playpark_plugin_still_enabled"
if jq -e '.enabledPlugins["playpark-skills@playpark"] == true' "${SETTINGS}" >/dev/null 2>&1; then
  pass "legacy_playpark_plugin_still_enabled"
else
  fail "legacy_playpark_plugin_still_enabled" "enabledPlugins[playpark-skills@playpark] must stay true until skills#584 merges"
fi

# ---------------------------------------------------------------------------
# no_dot_claude_skills_outside_hooks (AC1)
# ---------------------------------------------------------------------------
echo "- no_dot_claude_skills_outside_hooks"
count_outside="$(jq '
    del(.hooks) | [.. | strings | select(contains(".claude/skills"))] | length
  ' "${SETTINGS}")"
if [ "${count_outside}" -eq 0 ]; then
  pass "no_dot_claude_skills_outside_hooks"
else
  fail "no_dot_claude_skills_outside_hooks" "Expected 0 occurrences outside hooks, got ${count_outside}"
fi

# ---------------------------------------------------------------------------
# hooks_dot_claude_skills_unchanged
# ---------------------------------------------------------------------------
echo "- hooks_dot_claude_skills_unchanged"
count_hooks="$(jq '
    .hooks | [.. | strings | select(contains(".claude/skills"))] | length
  ' "${SETTINGS}")"
if [ "${count_hooks}" -eq 3 ]; then
  pass "hooks_dot_claude_skills_unchanged"
else
  fail "hooks_dot_claude_skills_unchanged" "Expected 3 occurrences in hooks, got ${count_hooks}"
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
