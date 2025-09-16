---
name: auto:fix
description: 自動修正フロー - 問題の体系的な発見と修正、安全な改善の適用、自動検証による品質保証
allowed-tools:
  - Bash(gh pr checkout:*)
  - Bash(gh repo view:*)
  - Bash(git:*)
  - Bash(grep:*)
---

# /auto:fix - 自動修正フロー
# 問題の体系的な発見→修正→検証→コミットの完全自動化

set -euo pipefail

# PRブランチへチェックアウト
Bash(gh pr checkout $ARGUMENTS)

# 1. 現状分析 - 問題の体系的な発見
/sc:analyze --focus quality --depth deep

# 2. 問題診断 - 詳細なトレース情報取得
/sc:troubleshoot --type bug --trace

# 3. 修正コスト見積もり
/sc:estimate --type effort --unit hours

# 4. レビュー本文を取得して修正指示を抽出
/sc:review \
  --pr $ARGUMENTS \
  --with-ci \
  --decision \
  --language ja \
  > /tmp/review.md

# 5. 改善適用 - 安全な修正の実行
FIX_PROMPT=$(printf '%s' "
[ROLE] Apply requested changes to the current PR based on the following review (Japanese).

=== REVIEW ===
$(cat /tmp/review.md)
")

/sc:improve --type quality --safe
/sc:implement --language ja "$FIX_PROMPT"

# 6. テスト実行 - 修正の検証
/sc:test --coverage

# 7. タスクの振り返りと検証
/sc:reflect --type task --validate

# 8. スマートコミット - 変更内容を分析して適切なコミットメッセージ生成
/sc:git commit --smart-commit

# 9. 安全なプッシュ
Bash(git push --force-with-lease)
