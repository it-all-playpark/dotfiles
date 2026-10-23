#!/usr/bin/env bash
# .githooks/ の hook を、git が実際に見る hooks ディレクトリから呼べるようにする。
# nix run .#update / nix develop から呼ばれる。何度実行してもよい。
#
# core.hooksPath は <repo>/.git/hooks の絶対パスに書き換えられていることがある（設定元は未特定）ので
# hooksPath 自体は触らず、git が見る場所に .githooks/<name> へ委譲する shim を置く。
# shim は実行時の作業ツリー（worktree を含む）の .githooks を呼ぶので、ブランチごとの hook が効く。
# wt-add の worktree は .githooks を sandbox から書けないので取り出さない（skip-worktree）。その hook は
# HEAD の中身を一時ファイルに取り出して走らせる（作業ツリーに無いのを理由に黙って飛ばさない）。
#
# Claude のセッション（CLAUDECODE=1）では、sandbox 内で呼ばれたときだけ hook を動かす。
# issue #249 以降 Claude Code の git は sandbox 内で動き、hook も sandbox 内で走るので脱出口にならない。
# ただし excludedCommands 経由（plugin cache の pr-push をフルパスで呼ぶ等）の git は sandbox 外で動き、
# そこで作業ツリーの .githooks / tests / flake.nix を実行すると脱出口になる。
# sandbox 内からは .git/hooks に書けないので、shim の置き場に書けるかどうかで sandbox 外を見分けて抜ける。
# 判定は sandbox から書けない shim 側に置く（.githooks 側に置いても作業ツリーから外せる）。
set -euo pipefail

MARKER="# dotfiles: .githooks dispatcher"

top="$(git rev-parse --show-toplevel)"
hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"

# hooksPath が直接 .githooks を指していれば shim は要らない。
# ただしその構成では shim を通らないので、上の sandbox 外判定が効かない（dotfiles は .git/hooks を使う）
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
    'if [ -n "${CLAUDECODE:-}" ]; then' \
    '  probe="$(dirname "$0")/.sandbox-probe.$$"' \
    '  if (: >"$probe") 2>/dev/null; then rm -f "$probe"; exit 0; fi' \
    'fi' \
    "hook=\"\$(git rev-parse --show-toplevel)/.githooks/$name\"" \
    'if [ ! -e "$hook" ]; then' \
    "  case \"\$(git ls-files -v -- .githooks/$name)\" in S\\ *) ;; *) exit 0 ;; esac" \
    "  tmp=\"\$(mktemp \"\${TMPDIR:-/tmp}/githook-$name.XXXXXX\")\" || exit 1" \
    '  trap '"'"'rm -f "$tmp"'"'"' EXIT' \
    "  git show \"HEAD:.githooks/$name\" >\"\$tmp\" && chmod +x \"\$tmp\" || exit 1" \
    '  "$tmp" "$@"' \
    '  exit $?' \
    'fi' \
    '[ -x "$hook" ] || exit 0' \
    'exec "$hook" "$@"' >"$dst"
  chmod +x "$dst"
done
