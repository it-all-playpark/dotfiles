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

# hook の cwd（project config の有無を見る起点）。exec / review は $HOME/ghq/ の下でだけ通るので、
# HOME を一時 dir に向け、既定の cwd は その ghq/ の下の project config の無い dir にする
TMPROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codex-guard-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_HOME="$TMPROOT/home"
GHQ="$FAKE_HOME/ghq"
mkdir -p "$GHQ/plain" "$GHQ/proj/.codex" "$GHQ/proj/sub" "$GHQ/rules/.codex/rules" "$GHQ/rules/sub" "$TMPROOT/outside"
touch "$GHQ/proj/.codex/config.toml" "$GHQ/rules/.codex/rules/default.rules"

run_hook() {
  jq -n --arg cmd "$1" --arg cwd "${2:-$GHQ/plain}" '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}' | HOME="$FAKE_HOME" bash "$HOOK" 2>&1 || true
}

# run_case <name> <command> <expected: deny|pass> [<cwd>]
# pass は「stdout が空」（allow も含め何も返さない）
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  local output
  output=$(run_hook "$cmd" "${4:-}")

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

# --- 許可形（情報表示と、claude-readonly profile と read-only を明示した exec / review）→ 素通し ---
echo "[Allowed codex forms — should pass through]"
run_case "codex --version" 'codex --version' "pass"
run_case "codex --help" 'codex --help' "pass"
run_case "codex features list" 'codex features list' "pass"
run_case "codex login status" 'codex login status' "pass"
run_case "absolute path codex --version" '/opt/homebrew/bin/codex --version' "pass"
run_case "quoted --version word" "codex '--version'" "pass"
run_case "exec profile + read-only" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "review the diff"' "pass"
run_case "exec alias e profile + read-only" 'codex e -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "pass"
run_case "exec read-only before profile" 'codex exec -c sandbox_mode=read-only -c default_permissions=claude-readonly "x"' "pass"
run_case "exec --config= profile + TOML strings" "codex exec --config='default_permissions=\"claude-readonly\"' --config='sandbox_mode=\"read-only\"' \"x\"" "pass"
run_case "review profile + read-only" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted' "pass"
run_case "absolute path review profile + read-only" '/opt/homebrew/bin/codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted' "pass"
run_case "exec profile with allowed exec options" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --skip-git-repo-check --json --ephemeral --color never -m gpt-5 "x"' "pass"
run_case "exec profile with --model= and model -c keys" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --model=gpt-5 -c model_reasoning_effort=high -c model_reasoning_summary=auto --config=model_verbosity=low --color=never "x"' "pass"
run_case "review profile with -c model" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c model="gpt-5" --base main --title "t"' "pass"
run_case "review profile --commit" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --commit abc123' "pass"
run_case "review profile with prompt" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted "focus on tests"' "pass"
run_case "exec profile prompt word resume" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x" resume' "pass"
run_case "exec profile single-quoted prompt with double quote" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only 'say \"hi\"'" "pass"

# --- AC-2: profile と read-only の両方を exec / review の後ろに明示しないもの・別の値のもの → deny ---
echo "[exec / review without the claude-readonly profile and read-only — should deny]"
run_case "exec read-only without profile" 'codex exec -c sandbox_mode=read-only "x"' "deny"
run_case "exec profile without read-only" 'codex exec -c default_permissions="claude-readonly" "x"' "deny"
run_case "review read-only without profile" 'codex review -c sandbox_mode=read-only --uncommitted' "deny"
run_case "review profile without read-only" 'codex review -c default_permissions="claude-readonly" --uncommitted' "deny"
run_case "exec other profile" 'codex exec -c default_permissions="probe" -c sandbox_mode=read-only "x"' "deny"
run_case "exec built-in profile" 'codex exec -c default_permissions=":workspace" -c sandbox_mode=read-only "x"' "deny"
run_case "exec profile name with suffix" 'codex exec -c default_permissions="claude-readonly-x" -c sandbox_mode=read-only "x"' "deny"
run_case "review other profile" 'codex review -c default_permissions=other -c sandbox_mode=read-only --uncommitted' "deny"
run_case "exec profile then other profile" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c default_permissions=other "x"' "deny"
run_case "exec profile + workspace-write" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=workspace-write "x"' "deny"
run_case "review profile + danger-full-access" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=danger-full-access --uncommitted' "deny"
run_case "profile before exec (root -c)" 'codex -c default_permissions="claude-readonly" -c sandbox_mode=read-only exec "x"' "deny"
run_case "profile before review (root -c)" 'codex -c default_permissions="claude-readonly" -c sandbox_mode=read-only review --uncommitted' "deny"
run_case "exec profile overridden by permissions.* -c" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c permissions.claude-readonly.filesystem.:root=write "x"' "deny"
run_case "exec profile with permission_profile -c" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c permission_profile=x "x"' "deny"
# exec の -s / --sandbox は profile を外すので値を問わず deny
run_case "exec profile + -s read-only" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -s read-only "x"' "deny"
run_case "exec profile + --sandbox read-only" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --sandbox read-only "x"' "deny"
run_case "exec profile + --sandbox=read-only" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --sandbox=read-only "x"' "deny"
run_case "exec profile + -sread-only attached" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -sread-only "x"' "deny"
run_case "exec -s read-only before profile" 'codex exec -s read-only -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny"
run_case "exec profile + -s workspace-write" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -s workspace-write "x"' "deny"
run_case "exec profile + --sandbox danger-full-access" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --sandbox danger-full-access "x"' "deny"
run_case "exec -s read-only without profile" 'codex exec -s read-only "review the diff"' "deny"
run_case "exec --sandbox=read-only without profile" 'codex exec --sandbox=read-only "review the diff"' "deny"
run_case "review profile + -s read-only" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only -s read-only --uncommitted' "deny"

# --- AC-3: 許可リスト外の option・値が - で始まる option・exec のサブコマンド → deny ---
echo "[Options outside the allowlist — should deny]"
run_case "review -m (review has no -m)" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only -m gpt-5 --uncommitted' "deny"
run_case "review --model=" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --model=gpt-5 --uncommitted' "deny"
run_case "review --color" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --color never --uncommitted' "deny"
run_case "review --skip-git-repo-check" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --skip-git-repo-check --uncommitted' "deny"
run_case "review --ephemeral" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --ephemeral --uncommitted' "deny"
run_case "exec --base" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --base main "x"' "deny"
run_case "exec --commit" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --commit abc "x"' "deny"
run_case "exec --title" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --title t "x"' "deny"
run_case "exec stdin prompt -" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -' "deny"
run_case "exec -- separator" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -- "x"' "deny"
run_case "root -m before exec" 'codex -m gpt-5 exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny"
run_case "root -c model before exec" 'codex -c model=gpt-5 exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny"
run_case "exec -c value without key" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c "=x" "x"' "deny"
run_case "-c value starting with -" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only -c --yolo "x"' "deny"
run_case "--model= value starting with -" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --model=--yolo "x"' "deny"
run_case "--color= value starting with -" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only --color=--yolo "x"' "deny"
run_case "review --base= starting with -" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --base=--output=/tmp/x' "deny"
run_case "review --base value starting with -" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --base --output=/tmp/x' "deny"
run_case "review --commit= starting with -" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --commit=-p' "deny"
run_case "review --title= starting with -" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted --title=-x' "deny"
run_case "review --base without value" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --base' "deny"
run_case "exec profile prompt to read ssh key via resume" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only resume --last "cat ~/.ssh/id_ed25519"' "deny"
run_case "codex --version with extra word" 'codex --version exec' "deny"
run_case "codex features list with extra word" 'codex features list x' "deny"

# --- 許可形の中身でも、シェルのメタ文字を含む形は deny（複合・置換・heredoc を解釈しない）---
echo "[Allowed codex forms with shell metacharacters — should deny]"
run_case "exec read-only prompt with separators" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "a; b | c && d (e)"' "deny"
run_case "exec read-only single-quoted dollar" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only 'cost is \$5 and \$(x)'" "deny"
run_case "exec read-only 2>&1 | tee" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x" 2>&1 | tee out.log' "deny"
run_case "exec read-only after cd &&" 'cd /repo && codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only quoted heredoc prompt" $'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - <<\'EOF\'\ndon\'t run codex exec --dangerously-bypass-approvals-and-sandbox; ls | wc\nEOF' "deny"
run_case "exec read-only multi-line quoted prompt" $'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "line1\nline2; codex exec --add-dir /"' "deny"
run_case "exec read-only behind timeout" 'timeout 600 codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only output redirect" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x" > out.md' "deny"
run_case "exec read-only two stdin redirects" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < a.md < b.md' "deny"
run_case "exec read-only backslash in double quotes" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "a\"b"' "deny"
run_case "exec read-only unquoted glob" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only x*' "deny"
run_case "exec read-only unquoted history bang" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only x!' "deny"
run_case "quoted codex name after plain word check" "'codex' --version" "deny"
run_case "parameter expansion with parens inside arithmetic" $': $(( ${x//))/\'"\'"\'} ))\ncodex --yolo exec x\n# \'' "deny"

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
run_case "global -s read-only before exec" 'codex -s read-only exec "review the diff"' "deny"
run_case "review with global -s read-only" 'codex -s read-only review --uncommitted' "deny"
run_case "review -s read-only (codex rejects -s on review)" 'codex review -s read-only --commit abc123' "deny"
run_case "global -c sandbox_mode before review" 'codex -c sandbox_mode=read-only review --uncommitted' "deny"
run_case "review sandbox_mode=read-only then workspace-write" 'codex review -c default_permissions=claude-readonly -c sandbox_mode=read-only -c sandbox_mode=workspace-write' "deny"
run_case "read-only before sandbox subcommand" 'codex -s read-only sandbox macos -- ls' "deny"
run_case "read-only after -- is a prompt" 'codex -- exec -c default_permissions=claude-readonly -c sandbox_mode=read-only' "deny"
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
run_case "--yolo behind env" 'env codex --yolo exec x' "deny"
run_case "exec behind env -u" 'env -u FOO codex exec "x"' "deny"
run_case "exec behind env -i" 'env -i codex exec "x"' "deny"
run_case "exec behind /usr/bin/env -C" '/usr/bin/env -C /tmp codex exec "x"' "deny"
run_case "CODEX_HOME after env on read-only exec" 'env CODEX_HOME=/private/tmp/claude/x codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "dynamic word after env on read-only exec" 'env "$V" codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "env -S hides codex arguments" "env -S 'codex --yolo exec x'" "deny"
run_case "env --split-string= hides codex arguments" "env --split-string='codex --yolo exec x'" "deny"

# --- AC-2: sandbox を外す・広げる指定 → read-only を明示しても deny ---
echo "[Sandbox-escaping flags — should deny]"
run_case "bypass approvals and sandbox" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --dangerously-bypass-approvals-and-sandbox "x"' "deny"
run_case "bypass hook trust" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --dangerously-bypass-hook-trust "x"' "deny"
run_case "global bypass before exec" 'codex --dangerously-bypass-approvals-and-sandbox exec "x"' "deny"
run_case "exec read-only with --yolo" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --yolo "x"' "deny"
run_case "global --yolo before exec" 'codex --yolo exec "x"' "deny"
run_case "CODEX_HOME prefix on read-only exec" 'CODEX_HOME=/private/tmp/claude/x codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "env prefix on read-only exec" 'FOO=1 codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "review with bypass" 'codex review -c default_permissions=claude-readonly -c sandbox_mode=read-only --dangerously-bypass-approvals-and-sandbox' "deny"
run_case "-s workspace-write" 'codex exec -s workspace-write "x"' "deny"
run_case "-s danger-full-access" 'codex exec -s danger-full-access "x"' "deny"
run_case "--sandbox workspace-write" 'codex exec --sandbox workspace-write "x"' "deny"
run_case "--sandbox=danger-full-access" 'codex exec --sandbox=danger-full-access "x"' "deny"
run_case "-sworkspace-write attached" 'codex exec -sworkspace-write "x"' "deny"
run_case "review with -s danger-full-access" 'codex -s danger-full-access review' "deny"
run_case "--add-dir" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --add-dir /tmp "x"' "deny"
run_case "--add-dir=" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --add-dir=/tmp "x"' "deny"
run_case "--approve-for-me" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --approve-for-me "x"' "deny"
run_case "exec read-only -o" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -o /tmp/out.md "x"' "deny"
run_case "exec read-only -o attached" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -o/tmp/out.md "x"' "deny"
run_case "exec read-only --output-last-message" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --output-last-message /tmp/out.md "x"' "deny"
run_case "exec read-only --output-last-message=" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --output-last-message=/tmp/out.md "x"' "deny"
run_case "-c notify" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c 'notify=[\"bash\",\"-c\",\"touch /tmp/x\"]' \"x\"" "deny"
run_case "-c sandbox_mode" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c sandbox_mode="danger-full-access" "x"' "deny"
run_case "-c sandbox_mode=read-only" 'codex exec -c sandbox_mode="read-only" "x"' "deny"
run_case "-c sandbox_workspace_write.*" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c sandbox_workspace_write.network_access=true "x"' "deny"
run_case "--config approval_policy" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --config approval_policy=never "x"' "deny"
run_case "-c sandbox_permissions" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c 'sandbox_permissions=[\"disk-full-read-access\"]' \"x\"" "deny"
run_case "-c shell_environment_policy.*" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c shell_environment_policy.inherit=all "x"' "deny"
run_case "--config=mcp_servers.*" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --config=mcp_servers.x.command=sh "x"' "deny"
run_case "-c attached key" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -csandbox_mode=danger-full-access "x"' "deny"
run_case "-c key with spaces" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c " sandbox_mode = \"danger-full-access\"" "x"' "deny"
run_case "-c profile-scoped sandbox_mode" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c profiles.p.sandbox_mode=danger-full-access "x"' "deny"
run_case "review -c sandbox_mode" 'codex review -c sandbox_mode=workspace-write' "deny"
run_case "exec read-only --full-auto" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --full-auto "x"' "deny"
run_case "global --full-auto before exec" 'codex --full-auto exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only -C" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -C /Users/someone "x"' "deny"
run_case "exec read-only -C attached" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -C/Users/someone "x"' "deny"
run_case "exec read-only --cd=" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --cd=/Users/someone "x"' "deny"
run_case "exec read-only --remote" 'codex --remote ws://evil.example exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only --remote-auth-token-env" 'codex --remote-auth-token-env TOKEN exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only -p" 'codex -p evil exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only --profile=" 'codex --profile=evil exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec read-only --enable" 'codex --enable foo exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "-c model_provider" 'codex -c model_provider=x -c model_providers.x.base_url=https://evil.example exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -' "deny"
run_case "-c otel" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c otel.exporter=x "x"' "deny"
run_case "unlisted option -i" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -i shot.png "x"' "deny"
run_case "unlisted option --output-schema" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --output-schema s.json "x"' "deny"
run_case "unlisted option --oss" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --oss "x"' "deny"
run_case "unlisted global option -a" 'codex -a never exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x"' "deny"
run_case "exec option on review" 'codex review -c default_permissions=claude-readonly -c sandbox_mode=read-only --json' "deny"
run_case "review option on exec" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --uncommitted "x"' "deny"
run_case "-c without =" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -c model "x"' "deny"
run_case "-s without value" 'codex exec -s' "deny"
run_case "flag in value position" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only -m --yolo "x"' "deny"
run_case "exec resume subcommand" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only resume --last' "deny"
run_case "exec help subcommand" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only help' "deny"
run_case "exec fork subcommand" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only fork x' "deny"
run_case "exec review subcommand" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only review' "deny"
run_case "zsh precommand modifier -" '- codex --yolo exec x' "deny"
run_case "command builtin" 'command codex --yolo exec x' "deny"
run_case "zsh noglob" 'noglob codex --yolo exec x' "deny"
run_case "exec builtin" 'exec codex --yolo exec x' "deny"
run_case "zsh =codex expansion" '=codex --yolo exec x' "deny"
run_case "backslash-quoted codex name" '\codex --yolo exec x' "deny"
run_case "arithmetic shift is not a heredoc" $': $((1<<2))\ncodex --yolo exec x\n2' "deny"
run_case "arithmetic command shift is not a heredoc" $'((a<<1))\ncodex --yolo exec x\n1' "deny"
run_case "codex inside arithmetic expansion" 'echo $(( $(codex --yolo exec x) ))' "deny"
run_case "quoted paren inside arithmetic command" $'(( x[")) \'"] ))\ncodex --yolo exec x\n# \'' "deny"
run_case "quoted paren inside arithmetic expansion" $': $(( x[")) \'"] ))\ncodex --yolo exec x\n# \'' "deny"
run_case "command substitution in unquoted heredoc body" $'cat <<EOF\n$(codex --yolo exec x)\nEOF' "deny"
run_case "backticks in unquoted heredoc body" $'cat <<EOF\n`codex --yolo exec x`\nEOF' "deny"
run_case "plain unquoted heredoc body" $'gh pr create --body-file - <<EOF\ncodex exec is denied\nEOF' "deny"
run_case "nested backticks" 'echo `echo \`codex --yolo exec x\``' "deny"
run_case "case inside command substitution" 'echo $(case x in x) codex --yolo exec x;; esac)' "deny"
run_case "flag after redirect" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "x" 2>&1 --add-dir /' "deny"
run_case "flag after command substitution arg" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "$(echo hi)" --add-dir /' "deny"
run_case "dynamic arg: command substitution" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "$(cat prompt.md)"' "deny"
run_case "dynamic arg: variable" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only $FLAGS "x"' "deny"
run_case "dynamic arg: quoted variable" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only "$FLAGS"' "deny"
run_case "dynamic arg: backticks" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only `cat flags`' "deny"
run_case "dynamic arg: ANSI-C quoting" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only \$'--add-dir' /" "deny"
run_case "ANSI-C escaped quote hides a second codex" "codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - <<<\$'\\'' ; codex --yolo exec x # '" "deny"
run_case "dynamic here-string" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - <<<"$PROMPT"' "deny"
run_case "dynamic arg: glob" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --add* /' "deny"
run_case "dynamic arg: brace expansion" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --{add-dir,x} /' "deny"
run_case "dynamic arg: process substitution" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only <(cat flags)' "deny"
run_no_echo_case "deny reason does not echo the command" 'codex exec "SECRET_MARKER_409"' 'SECRET_MARKER_409'
run_no_echo_case "danger reason does not echo the command" 'codex exec --dangerously-bypass-approvals-and-sandbox "SECRET_MARKER_409"' 'SECRET_MARKER_409'

# --- AC-3: 先頭トークンが codex でないコマンド → 無出力で素通し ---
echo "[Non-codex commands — should pass through silently]"
run_case "generate-thumbnail" 'generate-thumbnail --input a.png --output b.png' "pass"
run_case "grep codex" 'grep -rn codex claude-code/' "pass"
run_case "rg dangerous flag as pattern" "rg -n 'codex exec --dangerously-bypass-approvals-and-sandbox' docs" "pass"
run_case "git commit message" 'git commit -m "feat: deny codex exec -s danger-full-access"' "pass"
run_case "echo codex" 'echo codex' "pass"
run_case "ls ~/.codex" 'ls ~/.codex' "pass"
run_case "cat codex config" 'cat codex/config.base.toml' "pass"
run_case "jq codex key" "jq '.codex' file.json" "pass"
run_case "word containing codex" 'mycodex exec "x"' "pass"
run_case "path not ending in codex" './codex-helper exec "x"' "pass"
run_case "codex in comment" '# codex exec "x"' "pass"
run_case "codex in double-quoted arg with glob" 'git log --grep "codex*"' "pass"
run_case "codex word in an unknown wrapper's args" 'nohup grep codex f' "deny"
run_case "VAR= prefix before plain command" 'FOO=1 grep codex f' "deny"
# メタ文字を含む非 codex コマンドも、codex を起動しうる形として deny に倒す（fail-closed）
run_case "codex in quoted heredoc body" $'gh pr create --body-file - <<\'EOF\'\ncodex exec --dangerously-bypass-approvals-and-sandbox\nEOF' "deny"
run_case "grep codex piped" 'grep -rn codex docs | head' "deny"
# 印字可能な ASCII と空白以外のバイトを含むものは素通しせず、許可形の判定に回す
run_case "non-ASCII git commit message" 'git commit -m "feat: codex exec -s danger-full-access を deny する"' "deny"
run_case "non-ASCII bytes before ; codex" $'grep \xe3\x81 f ; codex --yolo exec x' "deny"
# 4096 バイトを超えるものは字句分割の前に deny
long_arg=$(printf 'a%.0s' {1..4100})
run_case "codex word in an over-long command" "grep codex ${long_arg}" "deny"

# --- cwd の上に codex の project 層（.codex dir）があれば exec / review は deny（symlink 越しの物理パスも見る）---
echo "[Project config above cwd — should deny]"
run_case "exec profile under project config" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$GHQ/proj/sub"
run_case "review profile under project config" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted' "deny" "$GHQ/proj/sub"
run_case "exec profile under project .codex/rules only" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$GHQ/rules/sub"
run_case "codex --version under project config" 'codex --version' "pass" "$GHQ/proj/sub"
ln -s "$GHQ/proj/sub" "$GHQ/plain/sublink"
run_case "exec profile with symlinked cwd into project" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$GHQ/plain/sublink"
run_case "exec profile with missing cwd" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$GHQ/missing"

# --- exec / review は cwd の物理パスが $HOME/ghq/ の下のときだけ通す（外では .codex を後から作れる）---
echo "[exec / review outside ~/ghq — should deny]"
ln -s "$TMPROOT/outside" "$GHQ/outlink"
run_case "exec profile outside ghq" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$TMPROOT/outside"
run_case "review profile outside ghq" 'codex review -c default_permissions="claude-readonly" -c sandbox_mode=read-only --uncommitted' "deny" "$TMPROOT/outside"
run_case "exec profile via symlink from ghq to outside" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$GHQ/outlink"
run_case "exec profile at HOME (not under ghq)" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$FAKE_HOME"
run_case "exec profile above HOME" 'codex exec -c default_permissions="claude-readonly" -c sandbox_mode=read-only "x"' "deny" "$TMPROOT"
run_case "codex --version outside ghq" 'codex --version' "pass" "$TMPROOT/outside"

# --- < file は受けない（sandbox の外の shell が開くので、作業ツリーに置いた symlink 越しに外を読める）---
echo "[Stdin redirect — should deny]"
run_case "stdin from relative file" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < prompt.md' "deny"
run_case "stdin from relative file without space" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - <prompt.md' "deny"
run_case "stdin from relative symlink" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < k' "deny"
run_case "stdin from home ssh key" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only --skip-git-repo-check - < ~/.ssh/id_ed25519' "deny"
run_case "stdin from absolute path" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < /etc/passwd' "deny"
run_case "stdin from parent dir" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < ../secret' "deny"
run_case "stdin with .. inside" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < a/../../secret' "deny"
run_case "stdin from zsh =cmd expansion" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < =ls' "deny"
run_case "stdin from ~user" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - <~root/x' "deny"
run_case "stdin from nested relative path" 'codex exec -c default_permissions=claude-readonly -c sandbox_mode=read-only - < docs/prompt.md' "deny"

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
