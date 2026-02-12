#!/usr/bin/env python3
"""PreToolUse hook: Auto-approve safe git command sequences.

Auto-approves:
- git add, commit, status, restore --staged (and chained combinations)
- git commit with -m / -F flags (with optional env/config prefixes)
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

cmd = (inp.get("tool_input", {}) or {}).get("command", "") or ""
norm = " ".join(cmd.split())


def allow(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


# Split on && || ;
parts = re.split(r"\s*(?:&&|\|\||;)\s*", norm)
SAFE_SUB = re.compile(
    r"^git\s+(?:add\b.*|commit\b.*|status\b.*|restore\s+--staged\b.*)$"
)

# Chained safe git commands
if parts and all(SAFE_SUB.match(p) for p in parts if p):
    allow("auto-approve safe git sequence")

# Single git commit with -m / -F (with optional env/config prefixes)
if re.search(
    r"(^|\s)(env\s+\S+=\S+\s+)*git(\s+-c\s+\S+=\S+)*\s+commit(\s+(-m|-F)\b|\b)",
    norm,
):
    allow("auto-approve git commit")
