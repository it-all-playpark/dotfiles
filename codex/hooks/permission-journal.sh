#!/usr/bin/env bash
# PermissionRequest hook for Codex: log classifier prompts to ~/.codex/log.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

INPUT=$(cat || true)
[[ -n $INPUT ]] || exit 0

CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
LOG_DIR="$CODEX_DIR/log"
LOG_FILE="$LOG_DIR/permission-requests.jsonl"
mkdir -p "$LOG_DIR"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // "unknown"' 2>/dev/null || echo "unknown")

case "$TOOL" in
Bash)
  DETAIL=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .input.command // empty' 2>/dev/null | head -c 500)
  ;;
Read | Write | Edit | MultiEdit)
  DETAIL=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .input.file_path // empty' 2>/dev/null | head -c 500)
  ;;
WebFetch)
  DETAIL=$(printf '%s' "$INPUT" | jq -r '.tool_input.url // .input.url // empty' 2>/dev/null | head -c 500)
  ;;
*)
  DETAIL=$(printf '%s' "$INPUT" | jq -c '.tool_input // .input // {}' 2>/dev/null | head -c 500)
  ;;
esac

PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg detail "$DETAIL" \
  --arg project "$PROJECT" \
  --arg session "$SESSION" \
  '{ts: $ts, tool: $tool, detail: $detail, project: $project, session: $session}' \
  >>"$LOG_FILE"
