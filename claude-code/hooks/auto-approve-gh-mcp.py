#!/usr/bin/env python3
"""PreToolUse hook: Auto-approve safe gh MCP tools.

Safe gh MCP tools (read-only operations) are auto-approved.
Tools containing destructive keywords are left for manual approval.
"""
import json
import re
import sys

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)

try:
    inp = json.loads(raw)
except Exception:
    sys.exit(0)

name = inp.get("tool_name", "")
DANGEROUS = re.compile(r"(merge|delete|transfer|archive|secret|token|ref|workflow)")

if name.startswith("mcp__gh__") and not DANGEROUS.search(name):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "auto-approve safe gh MCP tool",
                }
            }
        )
    )
