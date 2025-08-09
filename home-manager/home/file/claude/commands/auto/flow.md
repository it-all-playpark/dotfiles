---
name: auto:flow
description: Issue番号だけで Kickoff→PR→Review&Fix ループを完全自動実行
allowed-tools:
  - sc:spawn
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh repo view:*)
  - Bash(gh search prs:*)
---

: "${FLOW_FLAGS:=}"        # /auto:kickoff へ渡す任意フラグ
: "${FLOW_POLL_MAX_A:=24}" # タイトル検索の試行回数 (24×5s=120s)
: "${FLOW_POLL_MAX_B:=12}" # Fixes検索の試行回数 (12×5s=60s)
: "${FLOW_POLL_SLEEP:=5}"  # ポーリング間隔(秒)

sc:spawn --seq --ultrathink --verbose --cite "
  set -euo pipefail

# 0) 前提チェック

  command -v gh >/dev/null || { echo '❌ gh (GitHub CLI) が見つかりません'; exit 1; }

  ############################################################

# 1) Kickoff (branch→実装→PR)

  ############################################################
  sc:spawn \"/auto:kickoff $ARGUMENTS ${FLOW_FLAGS}\" || exit 1

  ############################################################

# 2) PR URL 取得（優先: 現在ブランチのPR → フォールバック検索）

  ############################################################

# repo を明示しておくと誤ヒットを避けられる

  REPO=\$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  REPO_FLAG=\"\"
  [ -n \"\$REPO\" ] && REPO_FLAG=\"--repo \$REPO\"

  echo '🔎 PR URL を取得中… (branch-bound PR を優先)'
  PR_URL=\$(gh pr view \$REPO_FLAG --json url --jq .url 2>/dev/null || true)

  if [ -z \"\$PR_URL\" ]; then
    echo '🔎 fallback A: タイトル末尾の "(#番号)" で検索…'
    i=0
    while [ \$i -lt ${FLOW_POLL_MAX_A} ]; do
      PR_URL=\$(gh pr list \$REPO_FLAG \
        --state open \
        --search \"in:title \\\"(#$ARGUMENTS)\\\"\" \
        --json url --jq '.[0].url' 2>/dev/null || true)
      [ -n \"\$PR_URL\" ] && break
      sleep ${FLOW_POLL_SLEEP}; i=\$((i+1))
    done
  fi

  if [ -z \"\$PR_URL\" ]; then
    echo '🔎 fallback B: \"Fixes #番号\" を本文/タイトルで検索…'
    i=0
    while [ \$i -lt ${FLOW_POLL_MAX_B} ]; do
      PR_URL=\$(gh pr list \$REPO_FLAG \
        --state open \
        --search \"\\\"Fixes #$ARGUMENTS\\\" in:title,body\" \
        --json url --jq '.[0].url' 2>/dev/null || true)
      [ -n \"\$PR_URL\" ] && break
      sleep ${FLOW_POLL_SLEEP}; i=\$((i+1))
    done
  fi

  if [ -z \"\$PR_URL\" ]; then
    echo '🔎 fallback C: gh search prs …'
    if [ -n \"\$REPO\" ]; then
      PR_URL=\$(gh search prs \"repo:\$REPO state:open in:title \\\"(#$ARGUMENTS)\\\"\" \\
                 --json url --jq '.[0].url' 2>/dev/null || true)
    else
      PR_URL=\$(gh search prs \"state:open in:title \\\"(#$ARGUMENTS)\\\"\" \\
                 --json url --jq '.[0].url' 2>/dev/null || true)
    fi
  fi

  [ -z \"\$PR_URL\" ] && { echo '❌ PR URL 取得失敗'; exit 1; }
  echo \"🟢 PR URL = \$PR_URL\"

  ############################################################

# 3) Review ↔ Fix ループ（LGTM まで）

  ############################################################
  sc:spawn \"/auto:loop \$PR_URL --seq --ultrathink --verbose --cite\"
"
