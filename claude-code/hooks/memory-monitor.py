#!/usr/bin/env python3
"""PostToolUse hook: Monitor Claude Code memory usage and warn if high.

Checks total RSS of all claude processes. Warns via systemMessage
when usage exceeds thresholds. Throttled to check at most once per
30 seconds to avoid overhead on every tool call.

Thresholds (tuned for 18GB RAM):
  - WARNING:  4 GB total claude RSS
  - CRITICAL: 8 GB total claude RSS
"""

import json
import os
import subprocess
import sys
import time

# --- Config ---
WARN_MB = 4096
CRIT_MB = 8192
THROTTLE_SEC = 30
STATE_FILE = os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-memmon-last")


def should_check():
    """Throttle: only check once per THROTTLE_SEC."""
    try:
        mtime = os.path.getmtime(STATE_FILE)
        if time.time() - mtime < THROTTLE_SEC:
            return False
    except OSError:
        pass
    # Touch state file
    with open(STATE_FILE, "w") as f:
        f.write(str(time.time()))
    return True


def get_claude_rss_mb():
    """Get total RSS (MB) and per-process breakdown for claude processes."""
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,rss,comm"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return 0, []

    procs = []
    for line in result.stdout.splitlines()[1:]:  # skip header
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid_s, rss_s, comm = parts
        # Match claude binary (Nix-wrapped or direct)
        if "/claude" not in comm and comm != "claude":
            continue
        try:
            rss_mb = int(rss_s) / 1024
            procs.append((int(pid_s), rss_mb))
        except ValueError:
            continue

    total = sum(rss for _, rss in procs)
    return total, procs


def main():
    # Consume stdin (required by hook protocol)
    sys.stdin.read()

    if not should_check():
        sys.exit(0)

    total_mb, procs = get_claude_rss_mb()

    if total_mb < WARN_MB:
        sys.exit(0)

    # Build warning message
    if total_mb >= CRIT_MB:
        icon = "CRITICAL"
    else:
        icon = "WARNING"

    top = sorted(procs, key=lambda x: -x[1])[:3]
    top_str = ", ".join(f"PID {p}={m:.0f}MB" for p, m in top)

    msg = (
        f"[Memory {icon}] Claude Code total: {total_mb:.0f} MB "
        f"({len(procs)} processes). Top: {top_str}. "
        f"Consider closing unused sessions or restarting Claude Code."
    )

    print(json.dumps({"systemMessage": msg}))
    sys.exit(0)


if __name__ == "__main__":
    main()
