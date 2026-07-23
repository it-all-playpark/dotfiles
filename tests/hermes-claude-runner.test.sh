#!/usr/bin/env bash
# tests/hermes-claude-runner.test.sh
# Runs the claude_runner plugin's full pytest suite (hermes/plugins/claude_runner/tests)
# using the installed hermes-agent venv Python. `tools.registry`, `hermes_cli.plugins`,
# etc. are only importable from that venv/checkout — this repo does not vendor a
# second hermes-agent dependency set. Every test file in that directory self-guards
# via `pytest.importorskip("tools.registry", ...)` when the venv/checkout is absent,
# and mocks out docker/git/network via subprocess.run monkeypatching, so running the
# whole directory is safe even without a full hermes-agent environment.
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
exec "${VENV_PYTHON}" -m pytest hermes/plugins/claude_runner/tests -v
