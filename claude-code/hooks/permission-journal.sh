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
#
# Bash の要求には Jev（jev-classify.sh）で効果種別のラベルを付ける:
#   class:   read_only | mutating_local | git_mutation | network | destructive
#   class_p: その選択肢の確率
# 実測では止められた Bash の大半が `cd X; grep …; echo "=== … ==="` のような
# 複合 read-only コマンド（classifier が構文的に判定できない）で、ラベルが
# あれば permission-summary.sh --suggest が read_only の頻出形だけを allow 候補に
# 絞れる。判定は記録のみで permission の決定は変えない。Jev が使えない
# （鍵なし・timeout・JEV_DISABLE=1）ときは class を付けずに記録する。
#
# 環境変数:
#   PERMISSION_JOURNAL_FILE  記録先（既定 ~/.claude/logs/permission-requests.jsonl、テスト用）
#   JEV_*                    jev-classify.sh を参照

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${PERMISSION_JOURNAL_FILE:-$HOME/.claude/logs/permission-requests.jsonl}"
LOG_DIR="$(dirname "$LOG_FILE")"
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

# --- Bash の効果種別を Jev で分類 ---
# 質問は英語（Jev の主言語）。複数該当時は「最も影響の大きいもの」を選ばせる。
# shellcheck disable=SC2016 # criteria 内の $TMPDIR は Jev に見せる文字列であり展開しない
BASH_KIND_QUESTIONS='{
  "kind": {
    "type": "choice",
    "instructions": "The state is a shell command an AI coding agent wants to run. Classify it by its most consequential effect. If several apply, pick the most severe in this order: destructive > network > git_mutation > mutating_local > read_only.",
    "criteria": {
      "read_only": "Only reads files or prints information: ls, cat, grep, find, jq, echo, git status/log/diff/show, running tests or linters without side effects. Writing only to temp dirs such as $TMPDIR still counts as read_only.",
      "mutating_local": "Creates, edits, moves or deletes files in the working tree or home directory, or installs into a project: mkdir, cp, mv, sed -i, touch, npm install, plain rm of specific files.",
      "git_mutation": "Changes local or feature-branch git state: git add/commit, push to a feature branch, merge, rebase, reset, checkout/switch, stash, branch or tag create/delete, worktree add/remove.",
      "network": "Mutates or reads a remote service beyond a plain git push: curl/wget, gh api/pr/issue mutations (comment, merge, edit, create), package publish, ssh/scp, deploys, docker pull, cloud CLIs.",
      "destructive": "Irreversible or wide blast radius: rm -rf on non-temp paths, force push, history rewrite on a shared branch, dropping or migrating databases, killing processes, chmod/chown -R, disk, keychain or system settings."
    }
  }
}'

# 送信前の redaction: token/secret/password/api-key 系の値と既知の鍵プレフィックスを伏せる。
# 記録側の detail は従来通り（500 文字切り詰めのみ）。
# BSD sed は大文字小文字無視 (I) を持たないので perl（macOS 標準）を使う。
redact() {
  perl -pe '
    s/((?:token|secret|passw(?:or)?d|api[_-]?key|authorization|bearer)\w*[=: ]+)[^\s"\x27]+/$1<redacted>/gi;
    s/\b(?:vck|ghp|gho|ghu|ghs|ghr|sk|xox[abp]|AKIA)[-_][A-Za-z0-9_-]{8,}/<redacted>/g;
  '
}

CLASS=""
CLASS_P=""
if [[ $TOOL == "Bash" ]]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  if [[ -n $CMD ]]; then
    CLASS_JSON=$(printf '%s' "$CMD" | redact | bash "$SCRIPT_DIR/jev-classify.sh" --questions "$BASH_KIND_QUESTIONS" 2>/dev/null || true)
    if [[ -n $CLASS_JSON ]]; then
      CLASS=$(echo "$CLASS_JSON" | jq -r '.answers.kind.choice // empty' 2>/dev/null || true)
      CLASS_P=$(echo "$CLASS_JSON" | jq -r '.answers.kind as $k | $k.probabilities[$k.choice] // empty' 2>/dev/null || true)
    fi
  fi
fi

# プロジェクト（カレントディレクトリ）
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# JSONL に追記（class は分類できたときだけ付ける）
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg detail "$DETAIL" \
  --arg project "$PROJECT" \
  --arg session "$(echo "$INPUT" | jq -r '.session_id // "unknown"')" \
  --arg class "$CLASS" \
  --arg class_p "$CLASS_P" \
  '{ts: $ts, tool: $tool, detail: $detail, project: $project, session: $session}
   + (if $class != "" then {class: $class} else {} end)
   + (if $class_p != "" then {class_p: ($class_p | tonumber)} else {} end)' \
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
