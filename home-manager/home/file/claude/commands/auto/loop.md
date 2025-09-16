---
name: auto:loop
description: 継続的改善ループ - 自動的な品質向上サイクル、段階的な最適化
allowed-tools:
  - Bash(gh pr checkout:*)
  - Bash(git:*)
  - Bash(grep:*)
---

# /auto:loop - 継続的改善ループ
# 品質向上サイクルと段階的最適化の自動化

set -euo pipefail

PR_REF="$ARGUMENTS"
[ -n "$PR_REF" ] || { echo "❌ PRが指定されていません"; exit 1; }

# PRブランチへチェックアウト
Bash(gh pr checkout "$PR_REF")

# セッションチェックポイント作成
/sc:save --checkpoint

MAX=15
i=1
while [ $i -le $MAX ]; do

  # 1. テスト実行とカバレッジ分析
  /sc:test --coverage

  # 2. パフォーマンス分析
  /sc:analyze --focus performance

  # 3. 最適ツール選択
  /sc:select-tool "improvement optimization" --analyze

  # 4. レビュー実行
  /sc:review \
    --pr "$PR_REF" \
    --with-ci \
    --decision \
    --language ja \
    > /tmp/review.md

  if Bash(grep -qi "\bLGTM\b" /tmp/review.md); then
    echo '✅ LGTM – ループ終了'
    break
  fi

  # 5. パフォーマンス改善
  /sc:improve --type performance

  # 6. コードクリーンアップ（安全モード）
  /sc:cleanup --safe

  # 7. 修正適用（レビュー本文を参照）
  FIX_PROMPT=$(printf '%s' "
[ROLE] Apply requested changes to the current PR.
Use the following review as the single source of truth (Japanese).

=== REVIEW ===
$(cat /tmp/review.md)
")
  /sc:implement --language ja "$FIX_PROMPT"

  # 8. セッションリフレクション
  /sc:reflect --type session

  # 9. ループごとにチェックポイント保存
  /sc:save --checkpoint

  # 10. 安全なプッシュ
  Bash(git add -A || true)
  Bash(git commit -m "Apply review fixes and improvements - Iteration $i" || true)
  Bash(git push --force-with-lease)

  sleep 2
  i=$((i+1))
done

if [ $i -gt $MAX ]; then
  echo "⚠️ 上限($MAX回)に達しました。手動確認をお願いします。"
  exit 3
fi
