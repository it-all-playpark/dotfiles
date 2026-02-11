#!/usr/bin/env python3
"""PreToolUse hook: Protect branches from dangerous git/gh operations.

Blocks:
1. gh pr merge into protected branches (main, master, dev, develop, development)
2. git push from protected branches
3. git push to protected branches via refspec
"""
import json
import re
import subprocess
import sys

raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)

try:
    inp = json.loads(raw)
    cmd = ((inp.get("tool_input") or {}).get("command") or "").strip()
except Exception:
    sys.exit(0)

if not cmd:
    sys.exit(0)

norm = " ".join(cmd.split())
PROTECTED = {"main", "master", "dev", "develop", "development"}


def deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


# --- 1. gh pr merge check ---
if re.match(r"^(?:env\s+\S+=\S+\s+)*gh\s+pr\s+merge\b", norm):
    try:
        result = subprocess.run(
            ["gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        base = result.stdout.strip()
    except Exception:
        base = ""
    if base in PROTECTED:
        deny(f"Blocked: merging into protected branch {base}")
    sys.exit(0)

# --- 2 & 3. git push checks ---
if not re.match(r"^(?:env\s+\S+=\S+\s+)*git\s+push\b", norm):
    sys.exit(0)

# 2. Block push from protected branch
try:
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    br = result.stdout.strip()
except Exception:
    br = ""

if br in PROTECTED:
    deny(f"Blocked: pushing from protected branch {br}")

# 3. Block push to protected branch via refspec
parts = norm.split()
try:
    i = max(j for j, p in enumerate(parts) if p == "push")
except ValueError:
    sys.exit(0)

# Skip push options until remote
j = i + 1
while j < len(parts) and parts[j].startswith("-"):
    j += 1
if j >= len(parts):
    sys.exit(0)

# Skip remote, collect refspecs
j += 1
refspecs = []
while j < len(parts):
    if parts[j].startswith("-"):
        j += 1
        continue
    refspecs.append(parts[j])
    j += 1

for rs in refspecs:
    rs = rs.lstrip("+")
    if ":" in rs:
        _, dst = rs.split(":", 1)
    else:
        dst = rs
    if dst.startswith("refs/heads/"):
        dst = dst.rsplit("/", 1)[-1]
    if dst in PROTECTED:
        deny(f"Blocked: pushing to protected branch {dst}")

sys.exit(0)
