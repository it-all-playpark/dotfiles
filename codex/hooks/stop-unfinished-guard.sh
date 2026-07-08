#!/usr/bin/env bash
# Codex Stop hook placeholder.
#
# The old runtime hooks.json may reference this path. Keep it present and
# successful, but avoid Claude-specific stop blocking behavior.

set -euo pipefail

cat >/dev/null 2>&1 || true
exit 0
