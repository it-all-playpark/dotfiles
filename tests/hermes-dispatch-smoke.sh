#!/usr/bin/env bash
# tests/hermes-dispatch-smoke.sh
# Real (docker + git) end-to-end smoke test for claude_runner dispatch_job
# (S2, AC-1): "Slack の bind 済みチャンネルへの依頼で、origin 基準 clone ->
# `claude --bg` 起動 -> manifest への job-id reconcile が実機で成功する
# (フェーズA)".
#
# This is a MANUAL smoke test, NOT part of `nix flake check` / CI: it needs
# a running Docker daemon, the hermes-tools:latest image, network access to
# clone a real repo, and a valid CLAUDE_CODE_OAUTH_TOKEN in ~/.hermes/.env.
# It exercises dispatch.dispatch_job() directly (not the gateway/Slack
# transport layer) against a scratch (platform, channel) -> repo binding, so
# no real Slack message needs to be sent.
#
# Usage:
#   bash tests/hermes-dispatch-smoke.sh [owner/repo]
#
# Defaults to binding a throwaway channel to `it-all-playpark/dotfiles`
# (read-only clone via origin; no push happens in this smoke test).
#
# Requires: docker, git, jq, the hermes-agent venv (~/.hermes/hermes-agent/venv)
#
# NOTE: This test file is intentionally NOT added to `nix flake check` — see
# tests/hermes-image-smoke.sh for the same convention.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_AGENT_ROOT="${HERMES_AGENT_ROOT:-${HOME}/.hermes/hermes-agent}"
VENV_PYTHON="${HERMES_AGENT_ROOT}/venv/bin/python"
TARGET_REPO="${1:-it-all-playpark/dotfiles}"

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

echo "=== hermes-dispatch smoke test (AC-1, フェーズA) ==="
echo "  REPO_ROOT: ${REPO_ROOT}"
echo "  HERMES_AGENT_ROOT: ${HERMES_AGENT_ROOT}"
echo "  TARGET_REPO: ${TARGET_REPO}"
echo ""

if [ ! -x "${VENV_PYTHON}" ]; then
  echo "SKIP: ${VENV_PYTHON} not found (hermes-agent not installed locally)" >&2
  exit 0
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not reachable" >&2
  exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermes-dispatch-smoke.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

HERMES_HOME="${WORK_DIR}/hermes-home"
mkdir -p "${HERMES_HOME}"

BINDINGS_FILE="${WORK_DIR}/repo_bindings.yaml"
cat >"${BINDINGS_FILE}" <<EOF
platforms:
  slack:
    channels:
      C_SMOKE_TEST:
        repos:
          - ${TARGET_REPO}
EOF

echo "- dispatch_job_real_clone_and_claude_bg"
DISPATCH_RESULT="${WORK_DIR}/dispatch_result.json"
if HERMES_AGENT_ROOT="${HERMES_AGENT_ROOT}" \
  HERMES_REPO_BINDINGS_PATH="${BINDINGS_FILE}" \
  HERMES_HOME="${HERMES_HOME}" \
  "${VENV_PYTHON}" - "${REPO_ROOT}" "${TARGET_REPO}" >"${DISPATCH_RESULT}" 2>"${WORK_DIR}/dispatch.err" <<'PYEOF'
import json
import sys

repo_root, target_repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, f"{repo_root}/hermes/plugins")

from claude_runner import dispatch  # noqa: E402

result = dispatch.dispatch_job(
    {
        "platform": "slack",
        "channel": "C_SMOKE_TEST",
        "prompt": "echo hermes-dispatch-smoke ping",
    }
)
print(result)
PYEOF
then
  pass "dispatch_job_real_clone_and_claude_bg (invocation succeeded)"
else
  fail "dispatch_job_real_clone_and_claude_bg" \
    "dispatch_job raised; see ${WORK_DIR}/dispatch.err"
  cat "${WORK_DIR}/dispatch.err" >&2 || true
fi

echo "- dispatch_result_has_running_job_with_bg_job_id"
if [ -f "${DISPATCH_RESULT}" ] && jq -e '.jobs[0].bg_job_id != null and .jobs[0].status == "running"' \
  "${DISPATCH_RESULT}" >/dev/null 2>&1; then
  pass "dispatch_result_has_running_job_with_bg_job_id"
  JOB_ID="$(jq -r '.jobs[0].job_id' "${DISPATCH_RESULT}")"
else
  fail "dispatch_result_has_running_job_with_bg_job_id" \
    "expected .jobs[0].bg_job_id + status=running, got: $(cat "${DISPATCH_RESULT}" 2>/dev/null || echo '<no output>')"
  JOB_ID=""
fi

echo "- manifest_reconciled_to_running"
if [ -n "${JOB_ID}" ] && [ -f "${HERMES_HOME}/jobs/${JOB_ID}.json" ] \
  && jq -e '.status == "running" and .bg_job_id != null' "${HERMES_HOME}/jobs/${JOB_ID}.json" >/dev/null 2>&1; then
  pass "manifest_reconciled_to_running"
else
  fail "manifest_reconciled_to_running" \
    "expected ${HERMES_HOME}/jobs/${JOB_ID}.json status=running with bg_job_id set"
fi

echo "- workspace_cloned_from_origin"
if [ -n "${JOB_ID}" ] && [ -d "${HERMES_HOME}/workspaces/${JOB_ID}/.git" ]; then
  pass "workspace_cloned_from_origin"
else
  fail "workspace_cloned_from_origin" \
    "expected ${HERMES_HOME}/workspaces/${JOB_ID}/.git to exist after origin clone"
fi

# Best-effort cleanup of the container this smoke test spun up.
if [ -n "${JOB_ID:-}" ]; then
  docker rm -f "hermes-claude-${JOB_ID}" >/dev/null 2>&1 || true
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
