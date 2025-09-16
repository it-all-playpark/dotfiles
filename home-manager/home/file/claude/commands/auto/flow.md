---
name: auto:flow
description: 開発フロー自動化 - エンドツーエンドの開発プロセス、セッション管理の統合
allowed-tools:
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh repo view:*)
  - Bash(gh search prs:*)
  - Bash(git:*)
  - Bash(grep:*)
---

# /auto:flow - 開発フロー自動化
# エンドツーエンドの開発プロセスとセッション管理の統合

: "${FLOW_FLAGS:=}"        # /auto:kickoff へ渡す任意フラグ
: "${FLOW_POLL_MAX_A:=24}" # タイトル検索の試行回数 (24×5s=120s)
: "${FLOW_POLL_MAX_B:=12}" # Fixes検索の試行回数 (12×5s=60s)
: "${FLOW_POLL_SLEEP:=5}"  # ポーリング間隔(秒)

set -euo pipefail
command -v gh >/dev/null || { echo '❌ gh (GitHub CLI) が見つかりません'; exit 1; }

########################################
# 0) セッションロード
########################################
/sc:load

########################################
# 1) 要件探索と実装計画
########################################
/sc:brainstorm --depth normal "Issue #$ARGUMENTS の実装"
/sc:workflow --strategy agile

########################################
# 2) Kickoff（branch→実装→PR）
########################################
/auto:kickoff $ARGUMENTS ${FLOW_FLAGS} || exit 1

########################################
# 3) タスク並列実行と実装
########################################
/sc:task --parallel --delegate
/sc:implement --with-tests

########################################
# 4) 工数見積もり（進捗把握）
########################################
/sc:estimate --breakdown

########################################
# 5) PR URL 取得（branch-bound→検索）
########################################
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
REPO_FLAG=""; [ -n "$REPO" ] && REPO_FLAG="--repo $REPO"

echo '🔎 PR URL を取得中… (branch-bound PR を優先)'
PR_URL=$(gh pr view $REPO_FLAG --json url --jq .url 2>/dev/null || true)

if [ -z "$PR_URL" ]; then
  echo '🔎 fallback A: タイトル末尾 "(#番号)" 検索…'
  i=0; while [ $i -lt ${FLOW_POLL_MAX_A} ]; do
    PR_URL=$(gh pr list $REPO_FLAG --state open \
      --search "in:title \"(#$ARGUMENTS)\"" \
      --json url --jq '.[0].url' 2>/dev/null || true)
    [ -n "$PR_URL" ] && break
    sleep ${FLOW_POLL_SLEEP}; i=$((i+1))
  done
fi

if [ -z "$PR_URL" ]; then
  echo '🔎 fallback B: "Fixes #番号" 検索…'
  i=0; while [ $i -lt ${FLOW_POLL_MAX_B} ]; do
    PR_URL=$(gh pr list $REPO_FLAG --state open \
      --search "\"Fixes #$ARGUMENTS\" in:title,body" \
      --json url --jq '.[0].url' 2>/dev/null || true)
    [ -n "$PR_URL" ] && break
    sleep ${FLOW_POLL_SLEEP}; i=$((i+1))
  done
fi

if [ -z "$PR_URL" ] && [ -n "$REPO" ]; then
  echo '🔎 fallback C: gh search prs …'
  PR_URL=$(gh search prs "repo:$REPO state:open in:title \"(#$ARGUMENTS)\"" \
               --json url --jq '.[0].url' 2>/dev/null || true)
fi

[ -z "$PR_URL" ] && { echo '❌ PR URL 取得失敗'; exit 2; }
echo "🟢 PR URL = $PR_URL"

########################################
# 6) ドキュメント生成
########################################
/sc:document --type api --style detailed

########################################
# 7) セッション保存とチェックポイント
########################################
/sc:save --checkpoint

########################################
# 8) ループは /auto:loop に委譲（終了コードを伝播）
########################################
/auto:loop "$PR_URL"
LOOP_STATUS=$?

########################################
# 9) 最終セッション保存
########################################
/sc:save --type all --summarize

exit $LOOP_STATUS
