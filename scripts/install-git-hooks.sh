#!/usr/bin/env bash
# .githooks/ の hook を、git が実際に見る hooks ディレクトリから呼べるようにする。
# nix run .#update / nix develop から呼ばれる。何度実行してもよい。
#
# core.hooksPath は <repo>/.git/hooks の絶対パスに書き換えられていることがある（設定元は未特定）ので
# hooksPath 自体は触らず、git が見る場所に .githooks/<name> へ委譲する shim を置く。
# shim は実行時の作業ツリー（worktree を含む）の .githooks を呼ぶので、ブランチごとの hook が効く。
#
# Claude Code の git は sandbox 外で動く。作業ツリーの .githooks / tests / flake.nix は sandbox から
# 書けるので、Claude のセッション（CLAUDECODE=1）では shim が何も呼ばずに抜ける。shim の置き場
# （.git/hooks）は sandbox から書けないので、この判定は Claude から外せない。
set -euo pipefail

MARKER="# dotfiles: .githooks dispatcher"

top="$(git rev-parse --show-toplevel)"
hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"

# hooksPath が直接 .githooks を指していれば shim は要らない
[ "$hooks_dir" = "$top/.githooks" ] && exit 0

mkdir -p "$hooks_dir"
for src in "$top"/.githooks/*; do
  name="$(basename "$src")"
  dst="$hooks_dir/$name"
  if [ -e "$dst" ] && ! grep -qF "$MARKER" "$dst"; then
    echo "install-git-hooks: $dst は別の hook なので上書きしない" >&2
    continue
  fi
  printf '%s\n' \
    '#!/bin/sh' \
    "$MARKER" \
    '[ -n "${CLAUDECODE:-}" ] && exit 0' \
    "hook=\"\$(git rev-parse --show-toplevel)/.githooks/$name\"" \
    '[ -x "$hook" ] || exit 0' \
    'exec "$hook" "$@"' >"$dst"
  chmod +x "$dst"
done
