#!/usr/bin/env bash
# tests/hermes-claude-runner.test.sh
# Runs the claude_runner plugin scaffold's pytest suite using the installed
# hermes-agent venv Python. `tools.registry`, `hermes_cli.plugins`, etc. are
# only importable from that venv/checkout — this repo does not vendor a
# second hermes-agent dependency set.
#
# Usage:
#   bash tests/hermes-claude-runner.test.sh
#
# Env:
#   HERMES_AGENT_ROOT - override the hermes-agent checkout (default: ~/.hermes/hermes-agent)
#
# Requires: ~/.hermes/hermes-agent/venv (installed via hermes/hermes-wrapper.sh / setup-hermes.sh)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_AGENT_ROOT="${HERMES_AGENT_ROOT:-${HOME}/.hermes/hermes-agent}"
VENV_PYTHON="${HERMES_AGENT_ROOT}/venv/bin/python"

echo "=== hermes-claude-runner scaffold tests ==="
echo "  REPO_ROOT: ${REPO_ROOT}"
echo "  HERMES_AGENT_ROOT: ${HERMES_AGENT_ROOT}"
echo ""

if [ ! -x "${VENV_PYTHON}" ]; then
  echo "SKIP: ${VENV_PYTHON} not found (hermes-agent not installed locally)" >&2
  exit 0
fi

export HERMES_AGENT_ROOT
cd "${REPO_ROOT}"
exec "${VENV_PYTHON}" -m pytest hermes/plugins/claude_runner/tests/test_registration.py -v
