#!/usr/bin/env bash
# Test suite for pretool-codex-guard.sh
#
# Usage: bash pretool-codex-guard.test.sh
#
# Exit 0 on all pass, non-zero otherwise.
#
# shellcheck disable=SC2016
# 単一引用符内の `$(…)` / `$VAR` / backtick は意図的なリテラル（hook に生文字列として渡す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-codex-guard.sh"

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

# run_case <name> <command> <expected: deny|pass>
# pass は「stdout が空」（allow も含め何も返さない）
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  local output
  output=$(run_hook "$cmd")

  local decision="pass"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "unexpected-output"' 2>/dev/null || echo "unexpected-output")
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

# run_no_echo_case <name> <command> <marker>: deny の理由に command の文字列が入らない
run_no_echo_case() {
  local name="$1"
  local cmd="$2"
  local marker="$3"

  local output
  output=$(run_hook "$cmd")

  if [[ -n $output && $output != *"$marker"* ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: output empty or echoes the command (got: $output)")
    printf "  \033[31mFAIL\033[0m %s\n" "$name"
  fi
}

echo "=== pretool-codex-guard tests ==="

# --- AC-1: 許可形（情報表示と read-only を明示した exec / review）→ 素通し ---
echo "[Allowed codex forms — should pass through]"
run_case "codex --version" 'codex --version' "pass"
run_case "codex --help" 'codex --help' "pass"
run_case "codex features list" 'codex features list' "pass"
run_case "codex login status" 'codex login status' "pass"
run_case "absolute path codex --version" '/opt/homebrew/bin/codex --version' "pass"
run_case "exec -s read-only" 'codex exec -s read-only "review the diff"' "pass"
run_case "exec --sandbox read-only" 'codex exec --sandbox read-only "review the diff"' "pass"
run_case "exec --sandbox=read-only" 'codex exec --sandbox=read-only "review the diff"' "pass"
run_case "global -s read-only before exec" 'codex -s read-only exec "review the diff"' "pass"
run_case "review with global -s read-only" 'codex -s read-only review --uncommitted' "pass"
run_case "exec read-only with model override" 'codex exec -s read-only -c model="o3" -m gpt-5 "x"' "pass"
run_case "exec read-only prompt from stdin file" 'codex exec -s read-only - < prompt.md' "pass"
run_case "exec read-only prompt with separators" 'codex exec -s read-only "a; b | c && d (e)"' "pass"
run_case "exec read-only single-quoted dollar" "codex exec -s read-only 'cost is \$5 and \$(x)'" "pass"
run_case "exec read-only 2>&1 | tee" 'codex exec -s read-only "x" 2>&1 | tee out.log' "pass"
run_case "exec read-only after cd &&" 'cd /repo && codex exec -s read-only "x"' "pass"
run_case "exec read-only quoted heredoc prompt" $'codex exec -s read-only - <<\'EOF\'\ndon\'t run codex exec --dangerously-bypass-approvals-and-sandbox; ls | wc\nEOF' "pass"
run_case "exec read-only multi-line quoted prompt" $'codex exec -s read-only "line1\nline2; codex exec --add-dir /"' "pass"

# --- AC-1: 許可形以外の codex 呼び出し → deny ---
echo "[Other codex forms — should deny]"
run_case "interactive TUI" 'codex' "deny"
run_case "interactive TUI with prompt" 'codex "fix the bug"' "deny"
run_case "codex sandbox" 'codex sandbox macos -- ls' "deny"
run_case "codex apply" 'codex apply' "deny"
run_case "codex mcp" 'codex mcp list' "deny"
run_case "codex login (not status)" 'codex login' "deny"
run_case "codex features enable" 'codex features enable foo' "deny"
run_case "exec without sandbox" 'codex exec "review the diff"' "deny"
run_case "exec alias e without sandbox" 'codex e "x"' "deny"
run_case "review without sandbox" 'codex review --uncommitted' "deny"
run_case "read-only before sandbox subcommand" 'codex -s read-only sandbox macos -- ls' "deny"
run_case "read-only after -- is a prompt" 'codex -- exec -s read-only' "deny"
run_case "exec after cd &&" 'cd /repo && codex exec "x"' "deny"
run_case "exec after allowed codex" 'codex --version && codex exec "x"' "deny"
run_case "exec with env prefix" 'FOO=1 codex exec "x"' "deny"
run_case "exec in subshell" '(codex exec "x")' "deny"
run_case "exec in brace group" '{ codex exec "x"; }' "deny"
run_case "exec in command substitution" 'echo "$(codex exec "x")"' "deny"
run_case "exec in backticks" 'echo `codex exec x`' "deny"
run_case "exec piped" 'codex exec "x" | tee out.log' "deny"
run_case "exec on second line" $'echo start\ncodex exec "x"' "deny"
run_case "exec after comment with apostrophe" $'# don\'t\ncodex exec "x"' "deny"
run_case "exec after quoted heredoc" $'cat <<\'EOF\'\nit\'s\nEOF\ncodex exec "x"' "deny"
run_case "exec quoted command name" '"codex" exec "x"' "deny"
run_case "bypass behind timeout" 'timeout 5 codex exec --dangerously-bypass-approvals-and-sandbox x' "deny"
run_case "exec behind timeout with options" 'timeout -k 5 -s TERM 30s codex exec "x"' "deny"
run_case "exec behind nice -n" 'nice -n 10 codex exec "x"' "deny"
run_case "exec behind nohup" 'nohup codex exec "x"' "deny"
run_case "exec behind stdbuf" 'stdbuf -oL codex exec "x"' "deny"
run_case "exec behind time -p" 'time -p codex exec "x"' "deny"
run_case "exec behind nested wrappers" 'nice timeout 5 /opt/homebrew/bin/codex exec "x"' "deny"
run_case "exec behind timeout with dynamic duration" 'timeout "$T" codex exec "x"' "deny"

# --- AC-2: sandbox を外す・広げる指定 → read-only を明示しても deny ---
echo "[Sandbox-escaping flags — should deny]"
run_case "bypass approvals and sandbox" 'codex exec -s read-only --dangerously-bypass-approvals-and-sandbox "x"' "deny"
run_case "bypass hook trust" 'codex exec -s read-only --dangerously-bypass-hook-trust "x"' "deny"
run_case "global bypass before exec" 'codex --dangerously-bypass-approvals-and-sandbox exec "x"' "deny"
run_case "exec read-only with --yolo" 'codex exec -s read-only --yolo "x"' "deny"
run_case "global --yolo before exec" 'codex --yolo exec "x"' "deny"
run_case "CODEX_HOME prefix on read-only exec" 'CODEX_HOME=/private/tmp/claude/x codex exec -s read-only "x"' "deny"
run_case "env prefix on read-only exec" 'FOO=1 codex exec -s read-only "x"' "deny"
run_case "review with bypass" 'codex -s read-only review --dangerously-bypass-approvals-and-sandbox' "deny"
run_case "-s workspace-write" 'codex exec -s workspace-write "x"' "deny"
run_case "-s danger-full-access" 'codex exec -s danger-full-access "x"' "deny"
run_case "--sandbox workspace-write" 'codex exec --sandbox workspace-write "x"' "deny"
run_case "--sandbox=danger-full-access" 'codex exec --sandbox=danger-full-access "x"' "deny"
run_case "-sworkspace-write attached" 'codex exec -sworkspace-write "x"' "deny"
run_case "review with -s danger-full-access" 'codex -s danger-full-access review' "deny"
run_case "--add-dir" 'codex exec -s read-only --add-dir /tmp "x"' "deny"
run_case "--add-dir=" 'codex exec -s read-only --add-dir=/tmp "x"' "deny"
run_case "--approve-for-me" 'codex exec -s read-only --approve-for-me "x"' "deny"
run_case "exec read-only -o" 'codex exec -s read-only -o /tmp/out.md "x"' "deny"
run_case "exec read-only -o attached" 'codex exec -s read-only -o/tmp/out.md "x"' "deny"
run_case "exec read-only --output-last-message" 'codex exec -s read-only --output-last-message /tmp/out.md "x"' "deny"
run_case "exec read-only --output-last-message=" 'codex exec -s read-only --output-last-message=/tmp/out.md "x"' "deny"
run_case "-c notify" "codex exec -s read-only -c 'notify=[\"bash\",\"-c\",\"touch /tmp/x\"]' \"x\"" "deny"
run_case "-c sandbox_mode" 'codex exec -s read-only -c sandbox_mode="danger-full-access" "x"' "deny"
run_case "-c sandbox_mode=read-only" 'codex exec -c sandbox_mode="read-only" "x"' "deny"
run_case "-c sandbox_workspace_write.*" 'codex exec -s read-only -c sandbox_workspace_write.network_access=true "x"' "deny"
run_case "--config approval_policy" 'codex exec -s read-only --config approval_policy=never "x"' "deny"
run_case "-c sandbox_permissions" "codex exec -s read-only -c 'sandbox_permissions=[\"disk-full-read-access\"]' \"x\"" "deny"
run_case "-c shell_environment_policy.*" 'codex exec -s read-only -c shell_environment_policy.inherit=all "x"' "deny"
run_case "--config=mcp_servers.*" 'codex exec -s read-only --config=mcp_servers.x.command=sh "x"' "deny"
run_case "-c attached key" 'codex exec -s read-only -csandbox_mode=danger-full-access "x"' "deny"
run_case "-c key with spaces" 'codex exec -s read-only -c " sandbox_mode = \"danger-full-access\"" "x"' "deny"
run_case "-c profile-scoped sandbox_mode" 'codex exec -s read-only -c profiles.p.sandbox_mode=danger-full-access "x"' "deny"
run_case "review -c sandbox_mode" 'codex -s read-only review -c sandbox_mode=workspace-write' "deny"
run_case "flag after redirect" 'codex exec -s read-only "x" 2>&1 --add-dir /' "deny"
run_case "flag after command substitution arg" 'codex exec -s read-only "$(echo hi)" --add-dir /' "deny"
run_case "dynamic arg: command substitution" 'codex exec -s read-only "$(cat prompt.md)"' "deny"
run_case "dynamic arg: variable" 'codex exec -s read-only $FLAGS "x"' "deny"
run_case "dynamic arg: quoted variable" 'codex exec -s read-only "$FLAGS"' "deny"
run_case "dynamic arg: backticks" 'codex exec -s read-only `cat flags`' "deny"
run_case "dynamic arg: ANSI-C quoting" "codex exec -s read-only \$'--add-dir' /" "deny"
run_case "ANSI-C escaped quote hides a second codex" "codex exec -s read-only - <<<\$'\\'' ; codex --yolo exec x # '" "deny"
run_case "dynamic here-string" 'codex exec -s read-only - <<<"$PROMPT"' "deny"
run_case "dynamic arg: glob" 'codex exec -s read-only --add* /' "deny"
run_case "dynamic arg: brace expansion" 'codex exec -s read-only --{add-dir,x} /' "deny"
run_case "dynamic arg: process substitution" 'codex exec -s read-only <(cat flags)' "deny"
run_no_echo_case "deny reason does not echo the command" 'codex exec "SECRET_MARKER_409"' 'SECRET_MARKER_409'
run_no_echo_case "danger reason does not echo the command" 'codex exec --dangerously-bypass-approvals-and-sandbox "SECRET_MARKER_409"' 'SECRET_MARKER_409'

# --- AC-3: 先頭トークンが codex でないコマンド → 無出力で素通し ---
echo "[Non-codex commands — should pass through silently]"
run_case "generate-thumbnail" 'generate-thumbnail --input a.png --output b.png' "pass"
run_case "grep codex" 'grep -rn codex claude-code/' "pass"
run_case "rg dangerous flag as pattern" "rg -n 'codex exec --dangerously-bypass-approvals-and-sandbox' docs" "pass"
run_case "git commit message" 'git commit -m "feat: codex exec -s danger-full-access を deny する"' "pass"
run_case "echo codex" 'echo codex' "pass"
run_case "ls ~/.codex" 'ls ~/.codex' "pass"
run_case "cat codex config" 'cat codex/config.base.toml' "pass"
run_case "jq codex key" "jq '.codex' file.json" "pass"
run_case "word containing codex" 'mycodex exec "x"' "pass"
run_case "path not ending in codex" './codex-helper exec "x"' "pass"
run_case "codex in quoted heredoc body" $'gh pr create --body-file - <<\'EOF\'\ncodex exec --dangerously-bypass-approvals-and-sandbox\nEOF' "pass"
run_case "codex in comment" '# codex exec "x"' "pass"

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
