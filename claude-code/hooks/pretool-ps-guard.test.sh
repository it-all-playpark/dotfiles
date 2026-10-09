#!/usr/bin/env bash
# Test suite for pretool-ps-guard.sh
#
# Usage: bash pretool-ps-guard.test.sh
#
# Exit 0 on all pass, non-zero otherwise.
#
# shellcheck disable=SC2016
# 単一引用符内の `$(…)` / `$VAR` / backtick は意図的なリテラル（hook に生文字列として渡す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-ps-guard.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

run_hook() {
  jq -n --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}' | bash "$HOOK" 2>&1 || true
}

# run_reason_case <name> <command> <substring expected in permissionDecisionReason>
run_reason_case() {
  local name="$1"
  local cmd="$2"
  local want="$3"

  local reason
  reason=$(run_hook "$cmd" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)

  if [[ $reason == *"$want"* ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: reason does not contain '$want' (got: $reason) cmd=$cmd")
    printf "  \033[31mFAIL\033[0m %s (reason missing: %s)\n" "$name" "$want"
  fi
}

# run_case <name> <command> <expected: deny|pass>
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  local output
  output=$(run_hook "$cmd")

  local decision="pass"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || echo "pass")
  fi

  if [[ $decision == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected=$expected got=$decision cmd=$cmd")
    printf "  \033[31mFAIL\033[0m %s (expected=%s, got=%s)\n" "$name" "$expected" "$decision"
  fi
}

echo "=== pretool-ps-guard tests ==="

# --- bare 名・複合形: excludedCommands に一致せず sandbox 内で EPERM になる → deny ---
echo "[Positive cases — should deny]"
run_case "bare ps" 'ps aux' "deny"
run_case "bare top" 'top -l 1' "deny"
run_case "bare pgrep" 'pgrep -l claude' "deny"
run_case "bare lsof" 'lsof -i :3000' "deny"
run_case "absolute ps piped" '/bin/ps aux | head' "deny"
run_case "pgrep in command substitution" 'ps eww -p $(pgrep foo)' "deny"
run_case "absolute ps after ;" 'foo; /bin/ps' "deny"
run_case "absolute pgrep with redirect" '/usr/bin/pgrep -l x > out' "deny"
run_case "absolute top with 2>&1" '/usr/bin/top -l 1 2>&1' "deny"
run_case "absolute ps after &&" 'cd /tmp && /bin/ps aux' "deny"
run_case "absolute lsof || fallback" '/usr/sbin/lsof -i :3000 || true' "deny"
run_case "absolute ps in background" '/bin/ps aux &' "deny"
run_case "pgrep in backticks" 'kill `pgrep foo`' "deny"
run_case "ps in subshell" '(ps aux)' "deny"
run_case "ps with env prefix" 'LC_ALL=C ps aux' "deny"
run_case "ps on second line" $'echo start\n/bin/ps aux' "deny"
run_case "non-allowed absolute path" '/usr/bin/ps aux' "deny"
run_case "ps inside double quotes is expanded" 'echo "$(ps aux)"' "deny"

# --- ps は環境変数（e / -E）を出せるので excludedCommands に無い。単独・絶対パス形でも deny ---
echo "[ps in any form — should deny]"
run_case "absolute ps" '/bin/ps aux' "deny"
run_case 'absolute ps with $VAR' '/bin/ps eww -p $PPID' "deny"
run_case "absolute ps with -E" '/bin/ps -E -ww -o command -p 1' "deny"
run_reason_case "ps reason suggests top" '/bin/ps aux' '/usr/bin/top -l 1 -o mem -n 15 -stats pid,ppid,command,cpu,mem,time'
run_reason_case "ps reason suggests pgrep -lf" 'ps aux' '/usr/bin/pgrep -lf <pattern>'

# --- 単独・絶対パス形（excludedCommands に一致して sandbox 外で動く）→ 素通し ---
echo "[Single absolute form — should pass through]"
run_case "absolute pgrep" '/usr/bin/pgrep -l claude' "pass"
run_case "absolute top narrowed by args" '/usr/bin/top -l 1 -o mem -n 15 -stats pid,ppid,command,cpu,mem,time' "pass"
run_case "absolute lsof" '/usr/sbin/lsof -nP -iTCP:3000 -sTCP:LISTEN' "pass"
run_case "absolute pgrep with quoted pattern" "/usr/bin/pgrep -lf 'node|vite'" "pass"

# --- ps 系を含まないコマンド（引数・語の一部・別ツールのサブコマンド）→ 素通し ---
echo "[No ps-family command — should pass through]"
run_case "echo ps" 'echo ps' "pass"
run_case "git log --grep=ps" 'git log --grep=ps' "pass"
run_case "docker ps" 'docker ps' "pass"
run_case "pnpm ps" 'pnpm ps' "pass"
run_case "grep ps" 'grep ps file.txt' "pass"
run_case "gh pr list" 'gh pr list' "pass"
run_case "topgrade (prefix word)" 'topgrade' "pass"
run_case "path containing top" 'cat ~/notes/top' "pass"
run_case "docker ps piped" 'docker ps | grep web' "pass"
run_case "ps inside single quotes" "git commit -m 'fix: use /bin/ps aux | head'" "pass"
run_case "ps in quoted heredoc body" $'gh pr create --body-file - <<\'EOF\'\nps aux | head は deny される\n`ps aux`\nEOF' "pass"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if ((FAIL > 0)); then
  printf '\n'
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
