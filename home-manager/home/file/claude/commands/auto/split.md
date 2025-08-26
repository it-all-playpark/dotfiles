---
name: auto:split
description: 親 Issue を衝突しない粒度で分割し、順序付きサブ Issue 作成＋実装計画を追記
allowed-tools:
  - sc:spawn
  - sc:load
  - sc:analyze
  - Bash(gh issue view:*)
  - Bash(gh issue create:*)
  - Bash(gh issue comment:*)
  - Bash(jq:*)
---

sc:spawn --c7 --seq --think --verbose --cite "
  set -euo pipefail

  #######################################################################

# フェーズ 0 : 親 Issue 本文を取得

  #######################################################################
  sc:load --summary --uc &&
  Bash(gh issue view $ARGUMENTS --json body,title --jq '.body' > /tmp/parent_body.md)

  #######################################################################

# フェーズ 1 : 衝突フリー & 実装順付きタスク分割

  #######################################################################
  sc:analyze \
      --input-file /tmp/parent_body.md \
      --task-breakdown conflict-free \
      --ordered \
      --max-subtasks 8 \
      --language ja \
      --persona architect \
      --uc \
      --output /tmp/tasks.json

  #######################################################################

# フェーズ 2 : サブ Issue 作成

  #######################################################################
  Bash(jq -c '.[]' /tmp/tasks.json | while read -r TASK; do
    TITLE=$(jq -r '.title' <<< \"$TASK\")
    BODY=$( jq -r '.body' <<< \"$TASK\"; echo; echo \"Parent: #$ARGUMENTS\" )
    ORDER=$(jq -r '.order' <<< \"$TASK\")
    PADDED=$(printf \"%02d\" \"$ORDER\")
    LABELS=\"sub-task,order-$PADDED\"

    NUM=$(Bash(gh issue create \
                --title \"$TITLE\" \
                --body  \"$BODY\" \
                --label \"$LABELS\" \
                --json number --jq .number))

    jq --null-input --argjson t \"$TASK\" --arg n \"$NUM\" \
       '$t + {number:(\$n|tonumber)}'
  done > /tmp/tasks_numbered.json)

  #######################################################################

# フェーズ 3 : 親 Issue へ実装計画コメントを投稿

  #######################################################################
  PLAN=$(jq -r 'sort_by(.order)[] | "- [ ] #\(.number) \(.title)"' \
             /tmp/tasks_numbered.json | \
         sed '1s/^/### 📝 実装計画 (自動生成)\\n/')

  Bash(gh issue comment $ARGUMENTS --body \"$PLAN\")
"
