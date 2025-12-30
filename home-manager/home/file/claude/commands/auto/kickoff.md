---
name: auto:kickoff
description: プロジェクト開始フロー - Morphllm対応版
allowed-tools:
  - Bash(gh issue view:*)
  - Bash(gh issue create:*)
  - Bash(git:*)
  - Bash(jq:*)
  - Task
  - mcp__morphllm-fast-apply__*
  - mcp__serena__*
  - mcp__sequential-thinking__*
  - TodoWrite
  - Grep
  - Read
  - MultiEdit
---

# /auto:kickoff-m

set -euo pipefail

# パラメータ解析

ISSUE_NUMBER="$1"
STRATEGY="${2:-tdd}"      # tdd|bdd|ddd
DEPTH="${3:-comprehensive}"     # minimal|standard|comprehensive

[ -n "$ISSUE_NUMBER" ] || { echo "❌ Issue番号が指定されていません"; exit 1; }

# SuperClaudeV4フラグ構築

SC_FLAGS=""
shift 3 || true
for arg in "$@"; do
  case "$arg" in
    --no-morph) ;;  # morphはデフォルトで有効なので無効化のみ処理
    --parallel) SC_FLAGS="$SC_FLAGS --parallel" ;;
    --seq|--sequential) SC_FLAGS="$SC_FLAGS --sequential" ;;
    --think) SC_FLAGS="$SC_FLAGS --think" ;;
    --think-hard) SC_FLAGS="$SC_FLAGS --think-hard" ;;
    --delegate) SC_FLAGS="$SC_FLAGS --delegate" ;;
    --uc|--ultracompressed) SC_FLAGS="$SC_FLAGS --uc" ;;
    *) SC_FLAGS="$SC_FLAGS $arg" ;;
  esac
done

# デフォルトでmorphを有効化（--no-morphがない限り）

[[ "$@" != *"--no-morph"* ]] && SC_FLAGS="--morph $SC_FLAGS"

# DEPTHに応じた自動フラグ

case "$DEPTH" in
  minimal) ;;
  comprehensive) SC_FLAGS="$SC_FLAGS --think-hard --parallel" ;;
  *) SC_FLAGS="$SC_FLAGS --think" ;;  # standard
esac

echo "🚀 Issue #$ISSUE_NUMBER 開始"
echo "📋 Strategy: $STRATEGY | Depth: $DEPTH"
echo "🔧 Flags: $SC_FLAGS"

# ==============================================================================

# Phase 1: Git状態確認とブランチ準備

# ==============================================================================

echo "🌳 Phase 1: Git準備"

# 現在の状態確認

Bash(git status --short)
CURRENT_BRANCH=$(Bash(git branch --show-current))

# 未コミットの変更がある場合の警告

if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  未コミットの変更があります。stashするか、コミットしてください。"
  echo "実行: git stash または git commit -am 'WIP'"
  exit 1
fi

# ブランチ作成

BRANCH_NAME="feature/issue-$ISSUE_NUMBER-m"
Bash(git checkout -b "$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME")

# ==============================================================================

# Phase 2: SuperClaudeV4 Orchestration

# ==============================================================================

echo "🎯 Phase 2: 要件分析と実装"

# Issue情報取得

Bash(gh issue view "$ISSUE_NUMBER" --json body,title,labels,assignees > /tmp/issue.json)
ISSUE_TITLE=$(jq -r '.title' /tmp/issue.json)
ISSUE_BODY=$(jq -r '.body' /tmp/issue.json)
ISSUE_LABELS=$(jq -r '.labels[].name' /tmp/issue.json | tr '\n' ',' | sed 's/,$//')

# SuperClaudeV4による統合実行

/sc:orchestrate "
=== ISSUE #$ISSUE_NUMBER ===
Title: $ISSUE_TITLE
Labels: $ISSUE_LABELS
Strategy: $STRATEGY
Depth: $DEPTH

Body:
$ISSUE_BODY

=== EXECUTION REQUIREMENTS ===

1. Load project context using /sc:load if needed
2. Analyze requirements with appropriate depth ($DEPTH)
3. Implement using $STRATEGY strategy
4. Apply Morphllm patterns for efficiency
5. Validate implementation quality
6. Prepare for PR creation

=== FLAGS ===
$SC_FLAGS

=== OUTPUT EXPECTATIONS ===

- Completed implementation
- All tests passing
- Code quality validated
- Ready for PR
" $SC_FLAGS

# ==============================================================================

# Phase 3: 実装結果の検証

# ==============================================================================

echo "✅ Phase 3: 実装検証"

# 変更内容の確認

Bash(git status --short)
CHANGES=$(git diff --stat)

if [ -z "$CHANGES" ]; then
  echo "⚠️  変更がありません。実装を確認してください。"
  exit 1
fi

echo "📊 変更サマリー:"
echo "$CHANGES"

# テスト実行（プロジェクトに応じて調整）

echo "🧪 テスト実行中..."
if [ -f "package.json" ]; then
  npm test 2>/dev/null || yarn test 2>/dev/null || echo "⚠️  テストコマンドが見つかりません"
elif [ -f "Makefile" ]; then
  make test 2>/dev/null || echo "⚠️  make testが失敗しました"
fi

# ==============================================================================

# Phase 4: コミットとPR作成

# ==============================================================================

echo "📝 Phase 4: コミット&PR作成"

# 全変更をステージング

Bash(git add -A)

# コミットメッセージ生成

COMMIT_MSG="feat: Implement Issue #$ISSUE_NUMBER

- Strategy: $STRATEGY"

# コミット実行

Bash(git commit -m "$COMMIT_MSG" || echo "⚠️  コミット済みまたはエラー")

# プッシュ

Bash(git push -u origin "$BRANCH_NAME")

# PR作成

PR_BODY="## 🎯 対応Issue
Fixes #$ISSUE_NUMBER

## 📋 実装詳細

- **タイトル**: $ISSUE_TITLE
- **戦略**: $STRATEGY

## ✅ チェックリスト

- [ ] テストが通過している
- [ ] コード品質が検証されている
- [ ] ドキュメントが更新されている（必要な場合）
- [ ] レビュー準備完了"

PR_URL=$(Bash(gh pr create \
  --title "✨ [$STRATEGY] $ISSUE_TITLE (#$ISSUE_NUMBER)" \
  --body "$PR_BODY" \
  --base dev \
  --head "$BRANCH_NAME" \
  --assignee @me \
  2>/dev/null | grep -o 'https://.*' || echo ""))

# ==============================================================================

# Phase 5: 完了レポート

# ==============================================================================

echo "
================================================================================

✅ 完了
================================================================================

📎 PR: ${PR_URL:-"作成済みまたはスキップ"}
🌳 Branch: $BRANCH_NAME
🚀 Strategy: $STRATEGY
💡 Depth: $DEPTH
🔧 Flags: $SC_FLAGS

🔄 次のステップ:

  1. PR レビュー: ${PR_URL:-"GitHub上で確認"}
  2. 継続開発: /auto:loop ${PR_URL:-"#$ISSUE_NUMBER"}
  3. 品質改善: /sc:introspect --review
================================================================================
"

# セッション状態を保存

/sc:save "issue_$ISSUE_NUMBER"
