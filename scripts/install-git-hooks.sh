#!/usr/bin/env bash
# .githooks/ の hook を、git が実際に見る hooks ディレクトリから呼べるようにする。
# nix run .#update / nix develop から呼ばれる。何度実行してもよい。
#
# core.hooksPath は <repo>/.git/hooks の絶対パスに書き換えられていることがある（設定元は未特定）ので
# hooksPath 自体は触らず、git が見る場所に .githooks/<name> へ委譲する shim を置く。
# shim は実行時の作業ツリー（worktree を含む）の .githooks を呼ぶので、ブランチごとの hook が効く。
#
# Claude のセッションでも hook は動く。issue #249 以降 Claude Code の git は sandbox 内で動き、
# hook もその子プロセスとして sandbox 内で走るので、作業ツリーのスクリプトを実行しても脱出口にならない。
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
  # shim の中身は展開せずにそのまま書き出す
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    "$MARKER" \
    "hook=\"\$(git rev-parse --show-toplevel)/.githooks/$name\"" \
    '[ -x "$hook" ] || exit 0' \
    'exec "$hook" "$@"' >"$dst"
  chmod +x "$dst"
done
