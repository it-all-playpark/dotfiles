---
name: auto:fix
description: 最新レビュー指摘を取り込み再実装→push
allowed-tools:
  - sc:spawn
  - sc:git
  - sc:implement
  - sc:load
  - Bash(gh pr checkout:*)
  - Bash(gh pr view:*)
---

Bash(gh pr checkout $ARGUMENTS) && \

# ──────────────────────────────────────────────────────────

# ここから SuperClaude のシーケンス

# ──────────────────────────────────────────────────────────

sc:spawn --seq --ultrathink --verbose --cite "
  set -euo pipefail

  ##################################################################

# 1. 最新レビューコメントをコンテキストにロード

  ##################################################################

# --pr:   PR 番号

# --include: reviews,reviewComments など環境に合わせて

  sc:load --pr $ARGUMENTS --include reviewComments --format markdown --ctx review &&

  ##################################################################

# 2. upstream の最新を取り込み（コンフリクト早期検知）

  ##################################################################

# PR ブランチなら tracking が付いている前提で fast-forward rebase

  sc:git fetch origin &&
  UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
  if [ -z \"$UPSTREAM\" ]; then
    # upstream 未設定ならデフォルトブランチへ
    DEF=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)
    UPSTREAM=\"origin/$DEF\"
  fi
  sc:git rebase \"$UPSTREAM\" &&

  ##################################################################

# 3. レビュー指摘を自動修正

  sc:implement --fix-issues --quality &&

  ##################################################################

# 4. 変更を push（force-with-lease で安全）

  ##################################################################
  sc:git --smart-commit \"Apply review fixes\" --push --force-with-lease
"
