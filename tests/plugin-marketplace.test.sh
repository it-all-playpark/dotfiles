#!/usr/bin/env bash
# tests/plugin-marketplace.test.sh
# Unit test for claude-code/settings.json's extraKnownMarketplaces /
# enabledPlugins entries for the 3 playpark plugins
# (playpark-core / dev-flow / playpark-skills). They are installed from the
# GitHub marketplace "playpark" (it-all-playpark/skills) on every host, so
# hosts without a local skills checkout track main too (the plugins carry no
# version, so every commit on main is a new version - skills#722).
# Run from the repo root: bash tests/plugin-marketplace.test.sh
# Requires: jq

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
# marketplace_is_github_source
# ---------------------------------------------------------------------------
echo "- marketplace_is_github_source"
if jq -e '
    .extraKnownMarketplaces["playpark"].source
      == {"source": "github", "repo": "it-all-playpark/skills"}
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "marketplace_is_github_source"
else
  fail "marketplace_is_github_source" "extraKnownMarketplaces.playpark.source is not {source: github, repo: it-all-playpark/skills}"
fi

# ---------------------------------------------------------------------------
# no_playpark_local_marketplace
# ---------------------------------------------------------------------------
# The link-mode inline marketplace and the GitHub marketplace ship plugins
# with the same names; enabling both would collide on the dev-flow:
# namespace, so playpark-local must be gone entirely.
echo "- no_playpark_local_marketplace"
if jq -e '
    (.extraKnownMarketplaces | has("playpark-local") | not)
    and ([.enabledPlugins | keys[] | select(endswith("@playpark-local"))] | length == 0)
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "no_playpark_local_marketplace"
else
  fail "no_playpark_local_marketplace" "playpark-local marketplace or an @playpark-local enabledPlugins entry remains"
fi

# ---------------------------------------------------------------------------
# enabled_plugins_registered
# ---------------------------------------------------------------------------
echo "- enabled_plugins_registered"
if jq -e '
    .enabledPlugins["playpark-core@playpark"] == true
    and .enabledPlugins["dev-flow@playpark"] == true
    and .enabledPlugins["playpark-skills@playpark"] == true
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "enabled_plugins_registered"
else
  fail "enabled_plugins_registered" "One or more of playpark-core@playpark / dev-flow@playpark / playpark-skills@playpark is not true"
fi

# ---------------------------------------------------------------------------
# plugin_autoupdate_forced
# ---------------------------------------------------------------------------
# DISABLE_AUTOUPDATER=1 also stops plugin auto-updates; FORCE_AUTOUPDATE_PLUGINS=1
# keeps plugin updates on while Claude Code itself stays pinned (mise).
echo "- plugin_autoupdate_forced"
if jq -e '
    (.env.DISABLE_AUTOUPDATER != "1") or (.env.FORCE_AUTOUPDATE_PLUGINS == "1")
  ' "${SETTINGS}" >/dev/null 2>&1; then
  pass "plugin_autoupdate_forced"
else
  fail "plugin_autoupdate_forced" "DISABLE_AUTOUPDATER=1 without FORCE_AUTOUPDATE_PLUGINS=1 stops plugin auto-updates"
fi

# ---------------------------------------------------------------------------
# excluded_commands_cover_plugin_cache
# ---------------------------------------------------------------------------
# Copy-mode plugins run from ~/.claude/plugins/cache/playpark/<plugin>/<version>/;
# skill scripts that call gh internally need the same 3 launch forms as the
# skills checkout paths.
echo "- excluded_commands_cover_plugin_cache"
missing=()
for form in \
  "/Users/naramotoyuuji/.claude/plugins/cache/playpark/*" \
  "bash /Users/naramotoyuuji/.claude/plugins/cache/playpark/*" \
  "python3 /Users/naramotoyuuji/.claude/plugins/cache/playpark/*" \
  'bash $HOME/.claude/plugins/cache/playpark/*' \
  'python3 $HOME/.claude/plugins/cache/playpark/*'; do
  if ! jq -e --arg f "${form}" '.sandbox.excludedCommands | index($f) != null' "${SETTINGS}" >/dev/null 2>&1; then
    missing+=("${form}")
  fi
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "excluded_commands_cover_plugin_cache"
else
  fail "excluded_commands_cover_plugin_cache" "Missing: ${missing[*]}"
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
# hooks_no_dot_claude_skills
# ---------------------------------------------------------------------------
echo "- hooks_no_dot_claude_skills"
count_hooks="$(jq '
    .hooks | [.. | strings | select(contains(".claude/skills"))] | length
  ' "${SETTINGS}")"
if [ "${count_hooks}" -eq 0 ]; then
  pass "hooks_no_dot_claude_skills"
else
  fail "hooks_no_dot_claude_skills" "Expected 0 occurrences in hooks (migrated to plugin hooks.json in skills#572), got ${count_hooks}"
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
