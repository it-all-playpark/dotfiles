#!/usr/bin/env bash
# tests/hermes-phaseB-gate.sh
# Real (docker + git + claude CLI) go/no-go GATE for the フェーズB execution
# model decision (S4, AC-2, AC-3):
#
#   AC-2: per-job コンテナを明示 kill した後、watchdog がコンテナ死を検知して
#          ジョブを status=failed へ reconcile し、既存 notify 経路で通知する
#          ことを実機確認する (自動再試行はしない設計決定、issue #122)
#   AC-3: "per-job `CLAUDE_CONFIG_DIR` を host 非root から `claude agents` で
#          読み取れることを実機確認できる (フェーズB)"
#
# This is a MANUAL smoke/gate test, NOT part of `nix flake check` / CI (same
# convention as tests/hermes-dispatch-smoke.sh and tests/hermes-image-smoke.sh):
# it needs a running Docker daemon reachable from the *host* (not from inside
# an agent sandbox — `docker kill` against a real per-job container and a
# real `gh`-authenticated push both require host-level privileges the
# implementer's own sandboxed Bash tool does not have), the hermes-tools:latest
# image, network access, and a valid CLAUDE_CODE_OAUTH_TOKEN in ~/.hermes/.env.
#
# Every PASS/FAIL/SKIP line below is intended to be copy-pasted verbatim into
# claudedocs/hermes-phaseB-execution-model-decision.md by whoever runs this
# for real, so the decision-log stays evidence-backed.
#
# Usage:
#   bash tests/hermes-phaseB-gate.sh [owner/repo]
#
# Requires: docker, git, jq, gh, the hermes-agent venv (~/.hermes/hermes-agent/venv),
#           the `claude` CLI on PATH (for AC-3; does not need docker)
#
# NOTE: This test file is intentionally NOT added to `nix flake check` — see
# tests/hermes-dispatch-smoke.sh for the same convention.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_AGENT_ROOT="${HERMES_AGENT_ROOT:-${HOME}/.hermes/hermes-agent}"
VENV_PYTHON="${HERMES_AGENT_ROOT}/venv/bin/python"
TARGET_REPO="${1:-it-all-playpark/dotfiles}"
KILL_DELAY_SECONDS="${KILL_DELAY_SECONDS:-5}"

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

skip() {
  echo "  SKIP: $1 (${2})"
}

echo "=== hermes-phaseB go/no-go gate (AC-2, AC-3, フェーズB) ==="
echo "  REPO_ROOT: ${REPO_ROOT}"
echo "  HERMES_AGENT_ROOT: ${HERMES_AGENT_ROOT}"
echo "  TARGET_REPO: ${TARGET_REPO}"
echo ""

if [ ! -x "${VENV_PYTHON}" ]; then
  echo "SKIP: ${VENV_PYTHON} not found (hermes-agent not installed locally)" >&2
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not on PATH (needed for AC-3)" >&2
  exit 0
fi

DOCKER_AVAILABLE=true
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  DOCKER_AVAILABLE=false
  echo "NOTE: docker daemon not reachable from this shell -- AC-2 section will" >&2
  echo "      be SKIPped. Re-run this script from a shell with real docker" >&2
  echo "      socket access (outside any agent sandbox) to get an AC-2 verdict." >&2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermes-phaseB-gate.XXXXXX")"
_cleanup_work_dir() {
  # Debug aid (issue #122 follow-up): on failure, keep WORK_DIR (watchdog.err,
  # container_diag.txt, dispatch.err, etc.) around instead of silently
  # deleting the only evidence of what actually happened.
  if [ "${FAIL:-0}" -gt 0 ]; then
    echo "" >&2
    echo "NOTE: FAIL>0 -- preserving WORK_DIR for debugging: ${WORK_DIR}" >&2
    if [ -f "${WORK_DIR}/watchdog.err" ]; then
      echo "--- ${WORK_DIR}/watchdog.err (full contents) ---" >&2
      cat "${WORK_DIR}/watchdog.err" >&2
    fi
  else
    rm -rf "${WORK_DIR}"
  fi
}
trap _cleanup_work_dir EXIT

HERMES_HOME="${WORK_DIR}/hermes-home"
mkdir -p "${HERMES_HOME}"

BINDINGS_FILE="${WORK_DIR}/repo_bindings.yaml"
cat >"${BINDINGS_FILE}" <<EOF
platforms:
  slack:
    channels:
      C_PHASEB_GATE:
        repos:
          - ${TARGET_REPO}
EOF

# ---------------------------------------------------------------------------
# AC-2: per-job container を明示 kill -> watchdog が failed へ reconcile し
#       通知経路を実行するか観測 (issue #122)
# ---------------------------------------------------------------------------
JOB_ID=""
WORKSPACE_HOST_DIR=""
CLAUDE_CONFIG_HOST_DIR=""

if [ "${DOCKER_AVAILABLE}" = "true" ]; then
  echo "- ac2_dispatch_job_and_capture_manifest"
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
        "channel": "C_PHASEB_GATE",
        "prompt": (
            "This is a hermes-phaseB-gate AC-2 experiment. Wait, then create a "
            "trivial docs-only PR (e.g. append a comment to README) so the "
            "gate script can observe whether the job progressed after its "
            "dispatch container was killed."
        ),
    }
)
print(result)
PYEOF
  then
    pass "ac2_dispatch_job_and_capture_manifest (invocation succeeded)"
  else
    fail "ac2_dispatch_job_and_capture_manifest" \
      "dispatch_job raised; see ${WORK_DIR}/dispatch.err"
    cat "${WORK_DIR}/dispatch.err" >&2 || true
  fi

  if [ -f "${DISPATCH_RESULT}" ] && jq -e '.jobs[0].job_id != null' "${DISPATCH_RESULT}" >/dev/null 2>&1; then
    JOB_ID="$(jq -r '.jobs[0].job_id' "${DISPATCH_RESULT}")"
    WORKSPACE_HOST_DIR="${HERMES_HOME}/workspaces/${JOB_ID}"
    CLAUDE_CONFIG_HOST_DIR="${HERMES_HOME}/claude-state/${JOB_ID}"
  else
    fail "ac2_dispatch_job_and_capture_manifest" \
      "no job_id in dispatch result: $(cat "${DISPATCH_RESULT}" 2>/dev/null || echo '<no output>')"
  fi

  if [ -n "${JOB_ID}" ]; then
    CONTAINER_NAME="hermes-claude-${JOB_ID}"
    MANIFEST_FILE="${HERMES_HOME}/jobs/${JOB_ID}.json"

    echo "- ac2_dispatch_container_running_before_kill"
    if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q true; then
      pass "ac2_dispatch_container_running_before_kill"
    else
      fail "ac2_dispatch_container_running_before_kill" \
        "expected container ${CONTAINER_NAME} to be running pre-kill"
    fi

    sleep "${KILL_DELAY_SECONDS}"

    echo "- ac2_explicit_kill_of_dispatch_container"
    if docker kill "${CONTAINER_NAME}" >/dev/null 2>&1; then
      pass "ac2_explicit_kill_of_dispatch_container"
    else
      # Debug aid (issue #122 follow-up): the container can only fail this
      # kill by having already exited on its own between the running-check
      # above and here, which means the underlying claude bg session died/
      # completed for some reason unrelated to this gate's explicit kill.
      # Capture its exit state and last output so that reason is diagnosable
      # instead of silently discarded when WORK_DIR is removed on exit.
      DIAG_FILE="${WORK_DIR}/container_diag.txt"
      {
        echo "--- docker inspect state ---"
        docker inspect -f 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}} OOMKilled={{.State.OOMKilled}}' \
          "${CONTAINER_NAME}" 2>&1 || echo "(inspect failed — container may already be --rm'd)"
        echo "--- docker logs (last 100 lines) ---"
        docker logs --tail 100 "${CONTAINER_NAME}" 2>&1 || echo "(logs unavailable)"
        echo "--- claude agents --json --all (bg session's own reported status) ---"
        if [ -f "${MANIFEST_FILE}" ]; then
          BG_JOB_ID="$(jq -r '.bg_job_id // empty' "${MANIFEST_FILE}" 2>/dev/null || true)"
          CFG_DIR="$(jq -r '.claude_config_host_dir // empty' "${MANIFEST_FILE}" 2>/dev/null || true)"
          WS_DIR="$(jq -r '.workspace_host_dir // empty' "${MANIFEST_FILE}" 2>/dev/null || true)"
          if [ -n "${CFG_DIR}" ] && [ -n "${WS_DIR}" ]; then
            RAW_JSON="$(CLAUDE_CONFIG_DIR="${CFG_DIR}" claude agents --json --all --cwd "${WS_DIR}" 2>&1 || echo '(claude agents invocation failed)')"
            echo "bg_job_id=${BG_JOB_ID}"
            echo "matching entry: $(printf '%s' "${RAW_JSON}" | jq -c --arg id "${BG_JOB_ID}" '[.[] | select((.id // .sessionId // .taskId // .job_id) == $id)] | .[0]' 2>/dev/null || echo '(jq parse failed)')"
            echo "full listing: ${RAW_JSON}"
          else
            echo "(manifest missing claude_config_host_dir/workspace_host_dir)"
          fi
        else
          echo "(manifest ${MANIFEST_FILE} not found yet)"
        fi
      } >"${DIAG_FILE}" 2>&1
      fail "ac2_explicit_kill_of_dispatch_container" \
        "docker kill ${CONTAINER_NAME} failed (container may have already exited); diagnostics: ${DIAG_FILE}"
      echo "  --- container diagnostics (${DIAG_FILE}) ---"
      cat "${DIAG_FILE}" | sed 's/^/    /'
    fi

    echo "- ac2b_watchdog_reconciles_killed_container_to_failed (up to 6 watchdog passes)"
    RECONCILED=false
    for _ in 1 2; do
      HERMES_HOME="${HERMES_HOME}" HERMES_WATCHDOG_SKIP_LOCK=1 \
        bash "${REPO_ROOT}/hermes/watchdog.sh" 2>>"${WORK_DIR}/watchdog.err" || true
    done
    if [ -f "${MANIFEST_FILE}" ] && jq -e '.status == "failed"' "${MANIFEST_FILE}" >/dev/null 2>&1; then
      RECONCILED=true
    else
      # HERMES_WATCHDOG_CONTAINER_DEAD_CONFIRM_COUNT default is 2, but real
      # environments may have claude agents session-state lag or race with
      # the bg_absent_streak path, so allow up to 6 total passes before
      # judging.
      for _ in 3 4 5 6; do
        sleep 2
        HERMES_HOME="${HERMES_HOME}" HERMES_WATCHDOG_SKIP_LOCK=1 \
          bash "${REPO_ROOT}/hermes/watchdog.sh" 2>>"${WORK_DIR}/watchdog.err" || true
        if [ -f "${MANIFEST_FILE}" ] && jq -e '.status == "failed"' "${MANIFEST_FILE}" >/dev/null 2>&1; then
          RECONCILED=true
          break
        fi
      done
    fi

    if [ "${RECONCILED}" = "true" ]; then
      pass "ac2b_watchdog_reconciles_killed_container_to_failed"
    else
      fail "ac2b_watchdog_reconciles_killed_container_to_failed" \
        "manifest ${MANIFEST_FILE} did not reach status=failed after up to 6 watchdog.sh passes; see ${WORK_DIR}/watchdog.err"
    fi

    echo "- ac2b_notify_path_exercised"
    if grep -q 'reconciling status to failed (issue #122)' "${WORK_DIR}/watchdog.err" &&
      grep -q -e 'skipping notify for channel' -e 'notified (status=failed' "${WORK_DIR}/watchdog.err"; then
      pass "ac2b_notify_path_exercised"
    else
      fail "ac2b_notify_path_exercised" \
        "expected watchdog.err to contain both the 'reconciling status to failed (issue #122)' reconcile line and either a 'skipping notify for channel' or 'notified (status=failed' notify line; see ${WORK_DIR}/watchdog.err"
    fi

    if [ "${RECONCILED}" = "true" ] && grep -q -e 'skipping notify for channel' -e 'notified (status=failed' "${WORK_DIR}/watchdog.err"; then
      echo "  AC-2 RESULT: RECONCILED -- per-job container killed -> watchdog"
      echo "               reconciled job to failed and notify path was"
      echo "               exercised (no auto-retry by design, issue #122)."
    else
      echo "  AC-2 RESULT: FAIL -- watchdog did not reconcile the killed"
      echo "               container's job to failed and/or the notify path"
      echo "               was not exercised within the poll window."
      echo "               -> record in the decision-log."
    fi

    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
else
  skip "ac2_dispatch_container_kill_and_progress" "docker daemon not reachable from this shell"
fi

# ---------------------------------------------------------------------------
# AC-3: per-job CLAUDE_CONFIG_DIR を host 非root から `claude agents` で読める
# ---------------------------------------------------------------------------
echo "- ac3_claude_agents_reads_per_job_config_dir"
if [ "$(id -u)" -eq 0 ]; then
  fail "ac3_claude_agents_reads_per_job_config_dir" \
    "this check must run as a non-root host user (AC-3 requires host非root); currently uid=0"
else
  AC3_CFG_DIR="${CLAUDE_CONFIG_HOST_DIR:-${WORK_DIR}/claude-state/scratch-job}"
  AC3_WS_DIR="${WORKSPACE_HOST_DIR:-${WORK_DIR}/workspace/scratch-job}"
  mkdir -p "${AC3_CFG_DIR}" "${AC3_WS_DIR}"

  AC3_OUT="${WORK_DIR}/ac3_agents.json"
  if CLAUDE_CONFIG_DIR="${AC3_CFG_DIR}" claude agents --json --cwd "${AC3_WS_DIR}" >"${AC3_OUT}" 2>"${WORK_DIR}/ac3.err"; then
    if jq -e 'type == "array"' "${AC3_OUT}" >/dev/null 2>&1; then
      pass "ac3_claude_agents_reads_per_job_config_dir (uid=$(id -u), exit 0, JSON array returned)"
      echo "  AC-3 RESULT: GO -- non-root host user (uid=$(id -u)) read"
      echo "               CLAUDE_CONFIG_DIR=${AC3_CFG_DIR} via \`claude agents\`"
      echo "               successfully. Record as confirmed in the decision-log."
    else
      fail "ac3_claude_agents_reads_per_job_config_dir" \
        "claude agents --json exited 0 but did not print a JSON array: $(cat "${AC3_OUT}")"
    fi
  else
    fail "ac3_claude_agents_reads_per_job_config_dir" \
      "claude agents --json --cwd ${AC3_WS_DIR} (CLAUDE_CONFIG_DIR=${AC3_CFG_DIR}) failed; see ${WORK_DIR}/ac3.err"
    cat "${WORK_DIR}/ac3.err" >&2 || true
  fi
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
