#!/usr/bin/env bash
# PreToolUse(Bash) hook for Codex: detect production credential exposure.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

INPUT=$(cat || true)
[[ -n $INPUT ]] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)
if [[ $TOOL != "Bash" ]]; then
  exit 0
fi

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .input.command // empty' 2>/dev/null || true)
[[ -n $CMD ]] || exit 0

emit_ask() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# $PROD_XXX / ${PRODUCTION_XXX} / $LIVE_XXX.
if printf '%s' "$CMD" | grep -qE '\$\{?(PROD|PRODUCTION|LIVE)_[A-Z0-9_]+'; then
  MATCH=$(printf '%s' "$CMD" | grep -oE '\$\{?(PROD|PRODUCTION|LIVE)_[A-Z0-9_]+' | head -1)
  emit_ask "prod credential env var を検知: ${MATCH}"
fi

# .env.production / .env.prod references.
if printf '%s' "$CMD" | grep -qE '(^|[[:space:]/"'"'"'=])\.env\.(production|prod)([[:space:]"'"'"';|&<>]|$)'; then
  MATCH=$(printf '%s' "$CMD" | grep -oE '\.env\.(production|prod)' | head -1)
  emit_ask "prod env ファイル参照を検知: ${MATCH}"
fi

# aws --profile values containing prod.
if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])aws([[:space:]]|$)'; then
  if printf '%s' "$CMD" | grep -qE -- '--profile[= ]'; then
    PROFILE=$(printf '%s' "$CMD" | grep -oE -- '--profile[= ][^[:space:]]+' | head -1 | sed -E 's/^--profile[= ]//')
    if [[ -n $PROFILE ]] && printf '%s' "$PROFILE" | grep -qiE 'prod'; then
      emit_ask "aws prod profile を検知: --profile ${PROFILE}"
    fi
  fi
fi

exit 0
