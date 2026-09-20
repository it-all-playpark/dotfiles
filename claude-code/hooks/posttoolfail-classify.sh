#!/usr/bin/env bash
# PostToolUseFailure hook: ツール失敗を Jev で分類して JSONL に記録
#
# 目的:
#   skill-retrospective が失敗の再発パターンを見つけるとき、エラー文字列の
#   sed 正規化に頼らず固定ラベルで集計できるようにする。RULES.md の
#   Sandbox Hygiene に並ぶ項目（/tmp 直書き・process substitution・未許可
#   ホスト等）は、どれも「同じ種類の失敗が何度も起きた」ことから書かれた。
#   種別ごとの件数が見えれば、次に hook 化すべき失敗が数で決まる。
#
# 記録のみで挙動は変えない（additionalContext も出さない）。
#
# ラベル:
#   sandbox_denied | network_denied | permission_denied | not_found |
#   syntax_error | test_failed | timeout | other
#
# 記録先: ~/.claude/logs/tool-failures.jsonl（TOOL_FAILURES_LOG で上書き）
#   {ts, tool, class, class_p, error, detail, project, session}
#   Jev が使えないときは class を付けずに記録する。
#
# stdin: PostToolUseFailure の payload
#   {tool_name, tool_input, error, tool_response, cwd, session_id, ...}
#
# 備考:
#   playpark-core plugin の journal.sh hook-capture も同じイベントで生記録を
#   残している。ラベルをそちらへ統合するのは skills repo 側の変更になるため、
#   まずは dotfiles 側で独立したログとして計測する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${TOOL_FAILURES_LOG:-$HOME/.claude/logs/tool-failures.jsonl}"
mkdir -p "$(dirname "$LOG_FILE")"

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
ERROR=$(echo "$INPUT" | jq -r '.error // empty')
# tool_response は文字列とは限らない（オブジェクトで来る tool もある）
RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty | if type == "string" then . else tojson end')

if [[ -z $ERROR && -z $RESPONSE ]]; then
  exit 0
fi

case "$TOOL" in
Bash)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  ;;
Read | Write | Edit | MultiEdit)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  ;;
WebFetch)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.url // empty')
  ;;
*)
  DETAIL=$(echo "$INPUT" | jq -c '.tool_input // {}')
  ;;
esac

FAILURE_KIND_QUESTIONS='{
  "kind": {
    "type": "choice",
    "instructions": "The state describes a tool call made by an AI coding agent that failed, with the tool name, its input, and the error output. Classify the primary cause of the failure.",
    "criteria": {
      "sandbox_denied": "Blocked by the OS sandbox or filesystem policy: Operation not permitted, read-only file system, EPERM/EACCES on a path, seatbelt or sandbox violation, cannot write to /tmp or a home directory path.",
      "network_denied": "Network egress blocked or unreachable: proxy refused the host, connection refused or timed out to a remote host, DNS resolution failed, 403 from a filtering proxy, host not in an allowlist.",
      "permission_denied": "Blocked by the coding agent'"'"'s permission system or a hook: permission rule denied, user declined the request, a hook returned deny or ask, protected branch push refused.",
      "not_found": "A command, file, directory, module or package does not exist: command not found, No such file or directory, ENOENT, module not found, HTTP 404.",
      "syntax_error": "The command or edit itself was malformed: shell syntax error, unknown option or bad argument, JSON/YAML parse error, old_string not found or not unique for an edit.",
      "test_failed": "The program ran to completion but reported failure: failing tests, lint or type errors, compile or build errors, assertion failures, non-zero exit from the program under test.",
      "timeout": "The command exceeded its time limit or was interrupted or killed before finishing.",
      "other": "None of the above, or the cause cannot be determined from the output."
    }
  }
}'

# 送信前 redaction（permission-journal.sh と同じ規則。BSD sed に I が無いので perl）
redact() {
  perl -pe '
    s/((?:token|secret|passw(?:or)?d|api[_-]?key|authorization|bearer)\w*[=: ]+)[^\s"\x27]+/$1<redacted>/gi;
    s/\b(?:vck|ghp|gho|ghu|ghs|ghr|sk|xox[abp]|AKIA)[-_][A-Za-z0-9_-]{8,}/<redacted>/g;
  '
}

CLASS=""
CLASS_P=""
STATE=$(printf 'tool: %s\ninput: %s\nerror: %s\noutput:\n%s\n' \
  "$TOOL" "$(printf '%s' "$DETAIL" | head -c 2000)" "$(printf '%s' "$ERROR" | head -c 2000)" "$(printf '%s' "$RESPONSE" | head -c 6000)")
CLASS_JSON=$(printf '%s' "$STATE" | redact | bash "$SCRIPT_DIR/jev-classify.sh" --questions "$FAILURE_KIND_QUESTIONS" 2>/dev/null || true)
if [[ -n $CLASS_JSON ]]; then
  CLASS=$(echo "$CLASS_JSON" | jq -r '.answers.kind.choice // empty' 2>/dev/null || true)
  CLASS_P=$(echo "$CLASS_JSON" | jq -r '.answers.kind as $k | $k.probabilities[$k.choice] // empty' 2>/dev/null || true)
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$(git -C "${CWD:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${CWD:-$(pwd)}")")

jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg error "$(printf '%s' "$ERROR" | head -c 300)" \
  --arg detail "$(printf '%s' "$DETAIL" | head -c 300)" \
  --arg project "$PROJECT" \
  --arg session "$(echo "$INPUT" | jq -r '.session_id // "unknown"')" \
  --arg class "$CLASS" \
  --arg class_p "$CLASS_P" \
  '{ts: $ts, tool: $tool, error: $error, detail: $detail, project: $project, session: $session}
   + (if $class != "" then {class: $class} else {} end)
   + (if $class_p != "" then {class_p: ($class_p | tonumber)} else {} end)' \
  >>"$LOG_FILE"

# 肥大化防止: 12000 行を超えたら直近 10000 行に切り詰める
if [[ $(wc -l <"$LOG_FILE") -gt 12000 ]]; then
  TMP=$(mktemp)
  tail -n 10000 "$LOG_FILE" >"$TMP" && mv "$TMP" "$LOG_FILE"
fi

exit 0
