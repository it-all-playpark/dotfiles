#!/usr/bin/env bash
# Test suite for permission-summary.sh
#
# Usage: bash permission-summary.test.sh
#
# 固定の JSONL を PERMISSION_JOURNAL_FILE に与え、--suggest が read_only の
# Bash だけを候補にすること、summary / --json に class 集計が出ることを検証する。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/permission-summary.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/permission-summary-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export PERMISSION_JOURNAL_FILE="$WORK/log.jsonl"
cat >"$PERMISSION_JOURNAL_FILE" <<'EOF'
{"ts":"2026-09-20T00:00:00Z","tool":"Bash","detail":"grep -n foo a","project":"p","session":"s","class":"read_only","class_p":0.9}
{"ts":"2026-09-20T00:00:01Z","tool":"Bash","detail":"grep -n foo b","project":"p","session":"s","class":"read_only","class_p":0.9}
{"ts":"2026-09-20T00:00:02Z","tool":"Bash","detail":"grep -n foo c","project":"p","session":"s","class":"read_only","class_p":0.9}
{"ts":"2026-09-20T00:00:03Z","tool":"Bash","detail":"gh pr merge 1","project":"p","session":"s","class":"network","class_p":0.8}
{"ts":"2026-09-20T00:00:04Z","tool":"Bash","detail":"gh pr merge 2","project":"p","session":"s","class":"network","class_p":0.8}
{"ts":"2026-09-20T00:00:05Z","tool":"Bash","detail":"gh pr merge 3","project":"p","session":"s","class":"network","class_p":0.8}
{"ts":"2026-09-20T00:00:06Z","tool":"Bash","detail":"rm -f x","project":"p","session":"s"}
{"ts":"2026-09-20T00:00:07Z","tool":"Bash","detail":"rm -f y","project":"p","session":"s"}
{"ts":"2026-09-20T00:00:08Z","tool":"Bash","detail":"rm -f z","project":"p","session":"s"}
{"ts":"2026-09-20T00:00:09Z","tool":"WebFetch","detail":"https://example.com/a","project":"p","session":"s"}
{"ts":"2026-09-20T00:00:10Z","tool":"WebFetch","detail":"https://example.com/b","project":"p","session":"s"}
{"ts":"2026-09-20T00:00:11Z","tool":"WebFetch","detail":"https://example.com/c","project":"p","session":"s"}
EOF

PASS=0
FAIL=0
FAILURES=()

ok() {
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m %s\n" "$1"
}
ng() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
  printf "  \033[31mFAIL\033[0m %s — %s\n" "$1" "$2"
}

echo "=== permission-summary.sh ==="

# 1. --suggest: read_only の Bash と WebFetch は候補、network / 未分類 Bash は出ない
out=$(bash "$SCRIPT" --suggest)
if echo "$out" | grep -q 'Bash(grep -n:\*)'; then
  ok "suggest: read_only bash is a candidate"
else
  ng "suggest: read_only bash is a candidate" "$out"
fi
if ! echo "$out" | grep -q 'Bash(gh pr:\*)'; then
  ok "suggest: network bash is excluded"
else
  ng "suggest: network bash is excluded" "$out"
fi
if ! echo "$out" | grep -q 'Bash(rm -f:\*)'; then
  ok "suggest: unclassified bash is excluded"
else
  ng "suggest: unclassified bash is excluded" "$out"
fi
if echo "$out" | grep -q 'WebFetch(domain:example.com)'; then
  ok "suggest: non-bash tools unaffected"
else
  ng "suggest: non-bash tools unaffected" "$out"
fi
if echo "$out" | grep -q '全 9 件中、未分類 3 件・副作用あり 3 件を除外'; then
  ok "suggest: exclusion counts shown"
else
  ng "suggest: exclusion counts shown" "$out"
fi

# 2. summary: By Class
out=$(bash "$SCRIPT")
if echo "$out" | grep -q 'By Class (Bash, Jev)' &&
  echo "$out" | grep -qE '3 read_only' &&
  echo "$out" | grep -qE '3 network' &&
  echo "$out" | grep -qE '3 unclassified'; then
  ok "summary: class breakdown"
else
  ng "summary: class breakdown" "$out"
fi

# 3. --json: classes 配列
out=$(bash "$SCRIPT" --json)
if [[ $(echo "$out" | jq -r '.[] | select(.tool == "Bash") | .classes | map("\(.class)=\(.count)") | sort | join(",")') == "network=3,read_only=3,unclassified=3" ]]; then
  ok "json: classes breakdown"
else
  ng "json: classes breakdown" "$out"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
