---
name: auto:split
description: タスク分割と並列実行 - 効率的な並列処理、リソース最適化
allowed-tools:
  - Bash(gh issue view:*)
  - Bash(gh issue create:*)
  - Bash(gh issue comment:*)
  - Bash(jq:*)
  - Bash(grep:*)
---

# /auto:split - タスク分割と並列実行
# 複雑なタスクの効率的な分解と並列処理

set -euo pipefail

# フェーズ 0: 親 Issue 本文を取得
Bash(gh issue view $ARGUMENTS --json body,title --jq '.body' > /tmp/parent_body.md)

# フェーズ 1: 依存関係マッピング（事前分析）
/sc:workflow "$(cat /tmp/parent_body.md)" --depth normal

# フェーズ 2: 最適ツール選択
/sc:select-tool "task splitting and parallel execution" --analyze

# フェーズ 3: タスク分解と並列実行戦略
/sc:spawn --strategy adaptive

# フェーズ 4: 並列タスク実行
/sc:task --parallel --delegate

# フェーズ 5: 衝突フリー & 実装順付きタスク分割
/sc:analyze \
  --input-file /tmp/parent_body.md \
  --task-breakdown conflict-free \
  --ordered \
  --max-subtasks 8 \
  --language ja \
  > /tmp/tasks.json

# フェーズ 6: サブ Issue 作成（並列実行情報付き）

Bash(jq -c '.[]' /tmp/tasks.json | while read -r TASK; do
  TITLE=$(jq -r '.title' <<< "$TASK")
  BODY=$( jq -r '.body'  <<< "$TASK"; echo; echo "Parent: #$ARGUMENTS" )
  ORDER=$(jq -r '.order' <<< "$TASK")
  PADDED=$(printf "%02d" "$ORDER")
  LABELS="sub-task,order-$PADDED"

  NUM=$(Bash(gh issue create \
              --title "$TITLE" \
              --body  "$BODY" \
              --label "$LABELS" \
              --json number --jq .number))

  jq --null-input --argjson t "$TASK" --arg n "$NUM" \
     '$t + {number:($n|tonumber)}'
done > /tmp/tasks_numbered.json)

# フェーズ 7: 並列実行の最終結果統合
/sc:reflect --type completion

# フェーズ 8: ビルド検証
/sc:build --type prod

# フェーズ 9: 親 Issue へ実装計画コメントを投稿（並列実行情報含む）
PLAN=$(jq -r 'sort_by(.order)[] | "- [ ] #\(.number) \(.title) [並列可能: \(.parallel // false)]"' /tmp/tasks_numbered.json \
       | sed '1s/^/### 📝 実装計画 (自動生成・並列実行最適化済み)\n/')
Bash(gh issue comment $ARGUMENTS --body "$PLAN")
