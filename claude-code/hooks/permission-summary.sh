#!/bin/bash
# permission-requests.jsonl の集計・allow 候補抽出
#
# Usage:
#   permission-summary.sh              # 全期間の集計
#   permission-summary.sh --days 7     # 直近7日
#   permission-summary.sh --suggest    # allow ルール候補を出力
#   permission-summary.sh --json       # JSON 形式で出力

set -euo pipefail

LOG_FILE="$HOME/.claude/logs/permission-requests.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "ログファイルが存在しません: $LOG_FILE"
  echo "PermissionRequest hook が発火するまで待ってください。"
  exit 0
fi

DAYS=""
SUGGEST=false
JSON_OUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)   DAYS="$2"; shift 2 ;;
    --suggest) SUGGEST=true; shift ;;
    --json)   JSON_OUT=true; shift ;;
    *)        echo "Unknown option: $1"; exit 1 ;;
  esac
done

# 日数フィルタ
if [ -n "$DAYS" ]; then
  CUTOFF=$(date -u -v-"${DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  DATA=$(jq -c "select(.ts >= \"$CUTOFF\")" "$LOG_FILE")
else
  DATA=$(cat "$LOG_FILE")
fi

TOTAL=$(echo "$DATA" | wc -l | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
  echo "該当期間のログがありません。"
  exit 0
fi

if [ "$JSON_OUT" = true ]; then
  # JSON 集計出力
  echo "$DATA" | jq -s '
    group_by(.tool) |
    map({
      tool: .[0].tool,
      count: length,
      details: (group_by(.detail) | map({detail: .[0].detail, count: length}) | sort_by(-.count) | .[0:10]),
      projects: ([.[].project] | unique)
    }) |
    sort_by(-.count)
  '
  exit 0
fi

if [ "$SUGGEST" = true ]; then
  # allow ルール候補を生成
  echo "# allow ルール候補（頻度順）"
  echo "# 3回以上出現したパターンを抽出"
  echo ""

  echo "$DATA" | jq -r '
    if .tool == "Bash" then
      # コマンドの先頭2語をパターン化
      .detail | split(" ") | .[0:2] | join(" ") | "Bash(" + . + ":*)"
    elif .tool == "WebFetch" then
      # ドメイン抽出
      .detail | capture("https?://(?<domain>[^/]+)") | "WebFetch(domain:" + .domain + ")"
    elif (.tool | startswith("mcp__")) then
      .tool
    else
      .tool + "(" + .detail + ")"
    end
  ' | sort | uniq -c | sort -rn | while read -r count pattern; do
    if [ "$count" -ge 3 ]; then
      printf '  %-4s %s\n' "${count}x" "$pattern"
    fi
  done

  echo ""
  echo "# settings.json に追加する場合:"
  echo '# "permissions": { "allow": [ "パターン" ] }'
  exit 0
fi

# デフォルト: サマリー表示
echo "=== Permission Request Summary ==="
echo "Total: $TOTAL requests"
if [ -n "$DAYS" ]; then
  echo "Period: last $DAYS days"
fi
echo ""

echo "--- By Tool ---"
echo "$DATA" | jq -r '.tool' | sort | uniq -c | sort -rn | head -20

echo ""
echo "--- Top Commands (Bash) ---"
echo "$DATA" | jq -r 'select(.tool == "Bash") | .detail' | \
  awk '{print $1, $2}' | sort | uniq -c | sort -rn | head -15

echo ""
echo "--- Top Files (Read/Write/Edit) ---"
echo "$DATA" | jq -r 'select(.tool == "Read" or .tool == "Write" or .tool == "Edit") | .detail' | \
  sort | uniq -c | sort -rn | head -15

echo ""
echo "--- Top Domains (WebFetch) ---"
echo "$DATA" | jq -r 'select(.tool == "WebFetch") | .detail' | \
  grep -oE 'https?://[^/]+' | sort | uniq -c | sort -rn | head -10

echo ""
echo "--- By Project ---"
echo "$DATA" | jq -r '.project' | sort | uniq -c | sort -rn

echo ""
echo "Tip: --suggest で allow ルール候補を表示"
