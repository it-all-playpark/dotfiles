#!/usr/bin/env bash
# tests/hermes-phaseE-precondition.test.sh
# Deterministic gate for the フェーズE (Discord/Google Chat) precondition
# (AC-14, E1):
#
#   AC-14: "フェーズE着手前に、未解決事項C7の要決定事項(4項目)がすべて
#          decision-logged されていることを確認できる（フェーズE前提条件）"
#
# This replaces the previous subjective "was P-C7 completed in the same
# run?" gate (which caused a prior BLOCKED status because an implementer
# could not observe another task's in-run completion) with a machine
# assertion over the C7 decision-log artifact
# claudedocs/hermes-c7-blast-radius-decisions.md: it must contain all 4
# `## 1.`..`## 4.` section headings (gws mount 削除可否 / WebSearch 削除or
# 受容 / fine-grained token 移行可否 / 脅威モデル節) and at least 4
# `決定:` markers (one decision-or-explicit-hold per item).
#
# This test is the sole gate for フェーズE (E1); E2/E3 treat `exit 0` from
# this test as their entry precondition.
#
# Usage:
#   bash tests/hermes-phaseE-precondition.test.sh
#
# Env:
#   HERMES_C7_DECISIONS_PATH  override the path to the C7 decision-log
#                             artifact (default: REPO_ROOT/claudedocs/
#                             hermes-c7-blast-radius-decisions.md, resolved
#                             relative to this script's BASH_SOURCE so it
#                             works with a bare `bash tests/....test.sh`
#                             invocation without any cd/env prefix, same
#                             convention as tests/verify-branch-protection.test.sh)
#
# Requires: grep (no yq/jq/gh/docker/network needed) -- this is a pure
#           filesystem/text assertion and is safe to run in CI / sandboxes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECISIONS_PATH="${HERMES_C7_DECISIONS_PATH:-${REPO_ROOT}/claudedocs/hermes-c7-blast-radius-decisions.md}"

REQUIRED_HEADINGS=4
REQUIRED_DECISIONS=4

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

echo "=== hermes-phaseE precondition gate (AC-14, E1) ==="
echo "  DECISIONS_PATH: ${DECISIONS_PATH}"
echo ""

echo "- c7_decisions_file_exists"
if [ -f "${DECISIONS_PATH}" ]; then
  pass "c7_decisions_file_exists"
else
  fail "c7_decisions_file_exists" "${DECISIONS_PATH} not found"
fi

if [ -f "${DECISIONS_PATH}" ]; then
  echo "- c7_decisions_has_all_4_section_headings"
  HEADING_COUNT="$(grep -cE '^## [1-4]\. ' "${DECISIONS_PATH}" || true)"
  if [ "${HEADING_COUNT}" -eq "${REQUIRED_HEADINGS}" ]; then
    pass "c7_decisions_has_all_4_section_headings (found ${HEADING_COUNT})"
  else
    fail "c7_decisions_has_all_4_section_headings" \
      "expected exactly ${REQUIRED_HEADINGS} '## 1.'..'## 4.' headings, found ${HEADING_COUNT}"
  fi

  echo "- c7_decisions_has_4_or_more_decision_markers"
  DECISION_COUNT="$(grep -cE '決定:' "${DECISIONS_PATH}" || true)"
  if [ "${DECISION_COUNT}" -ge "${REQUIRED_DECISIONS}" ]; then
    pass "c7_decisions_has_4_or_more_decision_markers (found ${DECISION_COUNT})"
  else
    fail "c7_decisions_has_4_or_more_decision_markers" \
      "expected at least ${REQUIRED_DECISIONS} '決定:' markers, found ${DECISION_COUNT}"
  fi
else
  fail "c7_decisions_has_all_4_section_headings" "skipped: decisions file missing"
  fail "c7_decisions_has_4_or_more_decision_markers" "skipped: decisions file missing"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  echo ""
  echo "フェーズE (E2/E3) 着手不可: C7 決定ログが4項目 decision-logged 済で" >&2
  echo "ないため fail-close します。${DECISIONS_PATH} を確認してください。" >&2
  exit 1
fi

exit 0
