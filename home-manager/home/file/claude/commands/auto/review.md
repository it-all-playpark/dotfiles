---
name: auto:review
description: コードレビュー自動化 - 多角的なコード評価、改善提案の自動生成
allowed-tools:
  - Bash(grep:*)
  - Bash(gh pr review:*)
---

# /auto:review - コードレビュー自動化
# 包括的な品質評価と改善提案の生成

set -euo pipefail

# 1. Git状態確認
/sc:git status

# 2. 多角的コード分析（全ドメイン）
/sc:analyze --focus all --depth deep

# 3. 高度な説明生成
/sc:explain --level advanced

# 4. 潜在的問題の検出
/sc:troubleshoot --type potential

# 5. 改善コスト見積もり
/sc:estimate --type effort --unit hours

# 6. レビュー実行（既存の処理を維持）
/sc:review \
  --pr $ARGUMENTS \
  --with-ci \
  --decision \
  --language ja \
  > /tmp/review.md

# 7. テスト影響確認
/sc:test --coverage > /tmp/test_impact.md

# 8. 改善提案（インタラクティブ）
/sc:improve --safe --interactive > /tmp/improvements.md

# 9. インラインドキュメント生成
/sc:document --type inline > /tmp/docs.md

# 10. 統合レビュー作成
cat <<EOF > /tmp/final_review.md
$(cat /tmp/review.md)

## 📊 テスト影響分析
$(cat /tmp/test_impact.md)

## 💡 改善提案
$(cat /tmp/improvements.md)

## 📝 ドキュメント推奨
$(cat /tmp/docs.md)
EOF

if Bash(grep -qi "LGTM" /tmp/final_review.md); then
  EVENT=approve
else
  EVENT=request-changes
fi

Bash(gh pr review $ARGUMENTS --${EVENT} --body-file /tmp/final_review.md)

# LGTM の場合のみ 0、要修正は 1 を返す
[ "$EVENT" = approve ]
