#!/usr/bin/env bash
# extract-info.sh - Extract key information from repo export markdown
# Usage: extract-info.sh <file-path>
#
# Output: JSON with project info, sections found, keywords

set -euo pipefail

FILE_PATH="${1:-}"

if [[ -z "$FILE_PATH" ]] || [[ ! -f "$FILE_PATH" ]]; then
    echo '{"error":"file_not_found"}'
    exit 1
fi

# Get file size and line count
FILE_SIZE=$(wc -c < "$FILE_PATH" | tr -d ' ')
LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')

# Extract project name from first header or filename
PROJECT_NAME=$(head -20 "$FILE_PATH" | grep -E '^# ' | head -1 | sed 's/^# //' || basename "$FILE_PATH" .md)

# Find README sections with line numbers
README_LINES=$(grep -n -E '^## .*README' "$FILE_PATH" 2>/dev/null | head -5 || echo "")

# Search for key sections
SECTIONS=$(grep -n -E '^## ' "$FILE_PATH" 2>/dev/null | head -20 | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")

# Search for keywords
KEYWORDS_JA=$(grep -c -E '機能|Features|概要|Overview|課題|効果|削減|自動化' "$FILE_PATH" 2>/dev/null || echo "0")
KEYWORDS_METRICS=$(grep -oE '[0-9]+%|[0-9]+時間|[0-9]+分' "$FILE_PATH" 2>/dev/null | sort -u | head -5 | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")

# Check for common doc patterns
HAS_README=$(grep -c -E '^## .*README' "$FILE_PATH" 2>/dev/null || echo "0")
HAS_FEATURES=$(grep -c -iE 'features|機能' "$FILE_PATH" 2>/dev/null || echo "0")
HAS_TECH_STACK=$(grep -c -iE 'tech|stack|技術|依存' "$FILE_PATH" 2>/dev/null || echo "0")

# Output JSON
cat <<EOF
{
  "file": "$FILE_PATH",
  "size_bytes": $FILE_SIZE,
  "lines": $LINE_COUNT,
  "project_name": $(echo "$PROJECT_NAME" | jq -R .),
  "sections": $SECTIONS,
  "has_readme": $([[ "$HAS_README" -gt 0 ]] && echo "true" || echo "false"),
  "has_features": $([[ "$HAS_FEATURES" -gt 0 ]] && echo "true" || echo "false"),
  "has_tech_stack": $([[ "$HAS_TECH_STACK" -gt 0 ]] && echo "true" || echo "false"),
  "keyword_count": $KEYWORDS_JA,
  "metrics_found": $KEYWORDS_METRICS
}
EOF
