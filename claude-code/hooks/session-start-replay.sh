#!/usr/bin/env bash
# SessionStart hook: 前 session の pre-compact dump を stdout に流して context に載せる
#
# 仕組み:
#   pre-compact-dump.sh が <project-root>/claudedocs/session-YYYYMMDD-HHMMSS.md を出力する。
#   本スクリプトは現在の cwd から project root を解決し、最新の session-*.md を cat する。
#   Claude Code の SessionStart hook は stdout の additionalContext を context に注入する
#   (startup / resume / compact のいずれでも動作)。
#
# stdin JSON (Claude Code SessionStart hook):
#   {
#     "session_id": "...",
#     "cwd": "/absolute/path",
#     "hook_event_name": "SessionStart",
#     "source": "startup" | "resume" | "compact"
#   }

set -euo pipefail

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat || true)
fi

CWD="$PWD"
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  V=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  [ -n "$V" ] && CWD="$V"
fi

cd "$CWD" 2>/dev/null || cd "$PWD"

if git rev-parse --show-toplevel >/dev/null 2>&1; then
  PROJECT_ROOT=$(git rev-parse --show-toplevel)
else
  PROJECT_ROOT="$PWD"
fi

CLAUDEDOCS_DIR="$PROJECT_ROOT/claudedocs"
[ -d "$CLAUDEDOCS_DIR" ] || exit 0

# 最新の session-*.md を検索
# ファイル名が `session-YYYYMMDD-HHMMSS.md` なので lexicographic sort = 時刻降順。
# ls -t (mtime) に依存しないので treefmt drift 等で touch された古いファイルを
# 最新扱いしてしまうリスクを避けられる。
LATEST=""
shopt -s nullglob
candidates=("$CLAUDEDOCS_DIR"/session-*.md)
shopt -u nullglob
if ((${#candidates[@]} > 0)); then
  LATEST=$(printf '%s\n' "${candidates[@]}" | sort -r | head -n 1)
fi

if [ -z "$LATEST" ] || [ ! -f "$LATEST" ]; then
  exit 0
fi

# 14 日以上古い dump は無視 (rotation は pre-compact 側で行うがフェイルセーフ)
if find "$LATEST" -mtime +14 -print 2>/dev/null | grep -q .; then
  exit 0
fi

echo "## 前 session の pre-compact dump (自動読み込み)"
echo ""
echo "Source: \`${LATEST#"$PROJECT_ROOT"/}\`"
echo ""
cat "$LATEST"
exit 0
