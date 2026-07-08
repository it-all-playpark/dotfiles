#!/usr/bin/env bash
# PostToolUse hook for Codex: redact secrets from Bash stdout/stderr.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

INPUT=$(cat || true)
[[ -n $INPUT ]] || exit 0

if [[ ${CODEX_HOOK_DEBUG:-0} == 1 ]]; then
  {
    printf '=== %s tool=%s ===\n' "$(date -Iseconds 2>/dev/null || date)" "$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // "?"')"
    printf 'INPUT_FULL: %s\n\n' "$INPUT"
  } >>"${TMPDIR:-/tmp}/codex-secret-mask-debug.log"
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)

mask_text() {
  perl -0777 -pe '
    s/-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/[REDACTED:PRIVATE_KEY_BLOCK]/g;
    s/\bAKIA[0-9A-Z]{16}\b/[REDACTED:AWS_ACCESS_KEY_ID]/g;
    s/\bgithub_pat_[A-Za-z0-9_]{82,}/[REDACTED:GITHUB_PAT]/g;
    s/\bgh[pousr]_[A-Za-z0-9]{36,255}\b/[REDACTED:GITHUB_TOKEN]/g;
    s/\bsk-ant-[A-Za-z0-9_-]{20,}/[REDACTED:ANTHROPIC_KEY]/g;
    s/\bsk_(?:live|test)_[A-Za-z0-9]{24,}/[REDACTED:STRIPE_KEY]/g;
    s/\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}/[REDACTED:SK_API_KEY]/g;
    s/\bAIza[0-9A-Za-z_-]{30,}/[REDACTED:GOOGLE_API_KEY]/g;
    s/\bxox[baprs]-[A-Za-z0-9-]{20,}/[REDACTED:SLACK_TOKEN]/g;
    s/\bxapp-\d+-[A-Z0-9]+-\d+-[A-Za-z0-9]{20,}/[REDACTED:SLACK_APP_TOKEN]/g;
    s/\bvck_[A-Za-z0-9]{24,}/[REDACTED:VERCEL_TOKEN]/g;
    s/\bnapi_[A-Za-z0-9_-]{32,}/[REDACTED:NEON_API_KEY]/g;
    s/\bhf_[A-Za-z0-9]{30,}/[REDACTED:HUGGINGFACE_TOKEN]/g;
    s/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[REDACTED:JWT]/g;
    s{\b([a-zA-Z][a-zA-Z0-9+.\-]*://)([^:/@\s]*):([^@/\s]+)@}{${1}${2}:[REDACTED:URL_CRED]\@}g;
    s/(^|[\s])([A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD|PASSPHRASE|CREDENTIAL|BEARER|SALT)[A-Z0-9_]*)=(?!\[REDACTED:)([^\s\r\n]{16,})($|[\s])/$1$2=[REDACTED:ENV_SECRET]$4/gm;
    s/(^|[\s])([A-Za-z0-9_]*(?i:token|key|secret|password|passphrase|credential|bearer|salt)[A-Za-z0-9_]*)=(?!\[REDACTED:)([^\s\r\n]{16,})($|[\s])/$1$2=[REDACTED:ENV_SECRET]$4/gm;
    s/("(?:[A-Za-z0-9_]*(?i:token|key|secret|password|credential|bearer|salt)[A-Za-z0-9_]*)"\s*:\s*")(?!\[REDACTED:)[^"\r\n]{12,}"/${1}[REDACTED:JSON_SECRET]"/g;
  '
}

if [[ $TOOL_NAME == Bash ]]; then
  STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // .response.stdout // ""' 2>/dev/null || true)
  STDERR=$(printf '%s' "$INPUT" | jq -r '.tool_response.stderr // .response.stderr // ""' 2>/dev/null || true)

  if [[ -z $STDOUT && -z $STDERR ]]; then
    exit 0
  fi

  MASKED_STDOUT=$(printf '%s' "$STDOUT" | mask_text)
  MASKED_STDERR=$(printf '%s' "$STDERR" | mask_text)

  if [[ $MASKED_STDOUT == "$STDOUT" && $MASKED_STDERR == "$STDERR" ]]; then
    exit 0
  fi

  printf '%s' "$INPUT" | jq \
    --arg stdout "$MASKED_STDOUT" \
    --arg stderr "$MASKED_STDERR" '
      {
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          updatedToolOutput: ((.tool_response // .response // {}) + {stdout: $stdout, stderr: $stderr})
        }
      }
    '
  exit 0
fi

exit 0
