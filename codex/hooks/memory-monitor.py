#!/usr/bin/env python3
"""No-op Codex PostToolUse hook.

Kept to satisfy existing ~/.codex/hooks.json installations that reference this
file. Runtime memory monitoring behavior is not defined for Codex here.
"""

import sys

sys.stdin.read()
sys.exit(0)
