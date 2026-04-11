#!/bin/bash
# PermissionRequest hook: classifier に止められた操作を JSONL に記録
# 用途: 頻出パターンを特定し allow リストの候補を抽出する
#
# stdin JSON 例:
# {
#   "session_id": "...",
#   "tool_name": "Bash",
#   "tool_input": { "command": "docker ps" }
# }

set -euo pipefail

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/permission-requests.jsonl"
mkdir -p "$LOG_DIR"

INPUT=$(cat)

# ツール名取得
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')

# ツール入力からキー情報を抽出
case "$TOOL" in
Bash)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // empty' | head -c 500)
  ;;
Read | Write | Edit | MultiEdit)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  ;;
WebFetch)
  DETAIL=$(echo "$INPUT" | jq -r '.tool_input.url // empty')
  ;;
mcp__*)
  DETAIL=$(echo "$INPUT" | jq -c '.tool_input // {}' | head -c 500)
  ;;
*)
  DETAIL=$(echo "$INPUT" | jq -c '.tool_input // {}' | head -c 500)
  ;;
esac

# プロジェクト（カレントディレクトリ）
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# JSONL に追記
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg detail "$DETAIL" \
  --arg project "$PROJECT" \
  --arg session "$(echo "$INPUT" | jq -r '.session_id // "unknown"')" \
  '{ts: $ts, tool: $tool, detail: $detail, project: $project, session: $session}' \
  >>"$LOG_FILE"

# 7日以上古いログをローテーション（日次でチェック）
ROTATE_MARKER="$LOG_DIR/.permission-rotate-marker"
if [ ! -f "$ROTATE_MARKER" ] || [ "$(find "$ROTATE_MARKER" -mtime +1 2>/dev/null)" ]; then
  touch "$ROTATE_MARKER"
  # 30日分保持、古いエントリを削除
  if [ -f "$LOG_FILE" ] && [ "$(wc -l <"$LOG_FILE")" -gt 10000 ]; then
    CUTOFF=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    if [ -n "$CUTOFF" ]; then
      TMP=$(mktemp)
      jq -c "select(.ts >= \"$CUTOFF\")" "$LOG_FILE" >"$TMP" 2>/dev/null && mv "$TMP" "$LOG_FILE"
    fi
  fi
fi
