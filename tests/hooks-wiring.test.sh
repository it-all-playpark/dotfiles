#!/usr/bin/env bash
# tests/hooks-wiring.test.sh
# Unit test for claude-code/settings.json and claude-code/container.settings.json
# hook wiring integrity after issue #185's plugin-migrated hook removal
# (stop-devflow-telemetry / pretool-inline-edit-guard /
# pretool-bash-inline-commit-gate / pretool-context-guard /
# posttool-secret-mask / validate-skill-frontmatter moved to
# skills repo's plugins/{dev-flow,playpark-core}/hooks/).
# Run from the repo root: bash tests/hooks-wiring.test.sh
# Requires: jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
CONTAINER_SETTINGS="${REPO_ROOT}/claude-code/container.settings.json"
HOOKS_DIR="${REPO_ROOT}/claude-code/hooks"

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

echo "=== settings.json / container.settings.json hook wiring unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# settings_hook_files_exist
# ---------------------------------------------------------------------------
echo "- settings_hook_files_exist"
missing=()
# shellcheck disable=SC2016 # 意図的なリテラル: settings.json 内の $HOME を文字どおりに照合する
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  target="${HOOKS_DIR}/${name}"
  if [ ! -x "${target}" ]; then
    missing+=("${name}")
  fi
done < <(jq -r '
    .hooks | .. | strings
      | select(startswith("bash \"$HOME/.claude/hooks/") or startswith("python3 \"$HOME/.claude/hooks/"))
  ' "${SETTINGS}" | sed -E 's|.*\$HOME/\.claude/hooks/([^"]+)".*|\1|')
if [ "${#missing[@]}" -eq 0 ]; then
  pass "settings_hook_files_exist"
else
  fail "settings_hook_files_exist" "Missing/non-executable in claude-code/hooks: ${missing[*]}"
fi

# ---------------------------------------------------------------------------
# container_hook_files_exist
# ---------------------------------------------------------------------------
echo "- container_hook_files_exist"
missing=()
# shellcheck disable=SC2016 # 意図的なリテラル: settings.json 内の $HOME を文字どおりに照合する
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  target="${HOOKS_DIR}/${name}"
  if [ ! -x "${target}" ]; then
    missing+=("${name}")
  fi
done < <(jq -r '
    .hooks | .. | strings
      | select(startswith("bash \"$HOME/.claude/hooks/") or startswith("python3 \"$HOME/.claude/hooks/"))
  ' "${CONTAINER_SETTINGS}" | sed -E 's|.*\$HOME/\.claude/hooks/([^"]+)".*|\1|')
if [ "${#missing[@]}" -eq 0 ]; then
  pass "container_hook_files_exist"
else
  fail "container_hook_files_exist" "Missing/non-executable in claude-code/hooks: ${missing[*]}"
fi

# ---------------------------------------------------------------------------
# settings_no_migrated_hooks
# ---------------------------------------------------------------------------
echo "- settings_no_migrated_hooks"
count="$(jq '
    [.hooks | .. | strings
      | select(test("stop-devflow-telemetry|pretool-inline-edit-guard|pretool-bash-inline-commit-gate|pretool-context-guard|posttool-secret-mask|validate-skill-frontmatter|journal/scripts/journal\\.sh|zombie-kill|claude-skill-ctx"))
    ] | length
  ' "${SETTINGS}")"
if [ "${count}" -eq 0 ]; then
  pass "settings_no_migrated_hooks"
else
  fail "settings_no_migrated_hooks" "Expected 0 references to migrated hooks in settings.json, got ${count}"
fi

# ---------------------------------------------------------------------------
# container_no_migrated_hooks
# ---------------------------------------------------------------------------
echo "- container_no_migrated_hooks"
count="$(jq '
    [.hooks | .. | strings
      | select(test("posttool-secret-mask|validate-skill-frontmatter|claude-skill-ctx"))
    ] | length
  ' "${CONTAINER_SETTINGS}")"
if [ "${count}" -eq 0 ]; then
  pass "container_no_migrated_hooks"
else
  fail "container_no_migrated_hooks" "Expected 0 references to migrated hooks in container.settings.json, got ${count}"
fi

# ---------------------------------------------------------------------------
# migrated_hook_files_removed
# ---------------------------------------------------------------------------
echo "- migrated_hook_files_removed"
still_present=()
for f in \
  stop-devflow-telemetry.sh \
  stop-devflow-telemetry.test.sh \
  pretool-inline-edit-guard.sh \
  pretool-inline-edit-guard.test.sh \
  pretool-bash-inline-commit-gate.sh \
  pretool-bash-inline-commit-gate.test.sh \
  pretool-context-guard.sh \
  pretool-context-guard.test.sh \
  posttool-secret-mask.sh \
  posttool-secret-mask.test.sh \
  validate-skill-frontmatter.sh; do
  if [ -e "${HOOKS_DIR}/${f}" ]; then
    still_present+=("${f}")
  fi
done
if [ "${#still_present[@]}" -eq 0 ]; then
  pass "migrated_hook_files_removed"
else
  fail "migrated_hook_files_removed" "Still present in claude-code/hooks: ${still_present[*]}"
fi

# ---------------------------------------------------------------------------
# machine_specific_hooks_present
# ---------------------------------------------------------------------------
echo "- machine_specific_hooks_present"
missing=()
for f in \
  allow-feature-push.sh \
  allow-pr-merge.sh \
  generate-worktreeinclude.sh \
  memory-monitor.py \
  permission-journal.sh \
  pre-compact-dump.sh \
  pretool-bash-credential-guard.sh \
  pretool-gh-pr-self-approve-guard.sh \
  pretool-npx-guard.sh \
  pretool-ps-guard.sh \
  session-start-replay.sh \
  stop-unfinished-guard.sh \
  permission-summary.sh; do
  if [ ! -e "${HOOKS_DIR}/${f}" ]; then
    missing+=("${f}")
  fi
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "machine_specific_hooks_present"
else
  fail "machine_specific_hooks_present" "Missing from claude-code/hooks: ${missing[*]}"
fi

# ---------------------------------------------------------------------------
# settings_pretool_ps_guard_wired
#
# ps / pgrep / lsof / top の書き方ガードは全 Bash コマンドで走らせる（`if` で
# 絞ると `cd x && ps` のような複合形を見逃す）。
# ---------------------------------------------------------------------------
echo "- settings_pretool_ps_guard_wired"
count="$(jq '
    [.hooks.PreToolUse // [] | .[]
      | select(.matcher == "Bash")
      | .hooks[]
      | select(.command == "bash \"$HOME/.claude/hooks/pretool-ps-guard.sh\"" and (has("if") | not))
    ] | length
  ' "${SETTINGS}")"
if [ "${count}" -eq 1 ]; then
  pass "settings_pretool_ps_guard_wired"
else
  fail "settings_pretool_ps_guard_wired" "Expected 1 unconditional PreToolUse(Bash) entry for pretool-ps-guard.sh, got ${count}"
fi

# ---------------------------------------------------------------------------
# settings_pretool_codex_guard_wired
#
# 素の codex（excludedCommands の codex:* で sandbox 外）の呼び出しガードも全 Bash
# コマンドで走らせる（`if` で絞ると `cd x && codex …` を見逃す）。新規の hook ファイルは
# 次の activation までリンクされないので、無いときだけ exit 0 で抜ける形にする
# （`|| true` で hook の失敗まで握り潰さない）。
# ---------------------------------------------------------------------------
echo "- settings_pretool_codex_guard_wired"
count="$(jq '
    [.hooks.PreToolUse // [] | .[]
      | select(.matcher == "Bash")
      | .hooks[]
      | select(.command == "[ ! -f \"$HOME/.claude/hooks/pretool-codex-guard.sh\" ] || bash \"$HOME/.claude/hooks/pretool-codex-guard.sh\"" and (has("if") | not))
    ] | length
  ' "${SETTINGS}")"
if [ "${count}" -eq 1 ] && [ -x "${HOOKS_DIR}/pretool-codex-guard.sh" ]; then
  pass "settings_pretool_codex_guard_wired"
else
  fail "settings_pretool_codex_guard_wired" "Expected 1 unconditional PreToolUse(Bash) entry for an executable pretool-codex-guard.sh, got ${count}"
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
