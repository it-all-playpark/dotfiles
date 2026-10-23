#!/usr/bin/env bash
# scripts/flake-lock-pr.sh: `nix run .#update` が更新した flake.lock を PR にして main に入れる
#
# update / update-all が switch まで通ったあとに repo の root で呼ぶ。dotfiles-apply は origin/main の flake.lock で
# 反映するので、更新した lock を未 commit のまま残すと、次の apply で入力が古い rev に戻る。
#
# 作業ツリーと HEAD には触らず、origin/main の tree の flake.lock だけを差し替えた commit を作って
# chore/flake-lock-<日時> に push し、PR を作って auto-merge（CI が通ったら squash merge）を予約する。
# main へは直接 push しない（保護ブランチ）。push する commit は作業ツリーと中身が違うので pre-push の検査は
# 走らせず（--no-verify）、PR の CI を merge の関門にする。
# PR を作れたら作業ツリーの flake.lock を HEAD に戻す。新しい入力は PR が main に運び、残すと dotfiles-sync が
# 取り込みと重なったファイルとして止まる。
#
# 終了コード: 0 = PR を作った / lock が変わっていない。1 = PR を作れなかった（作業ツリーの flake.lock は残す）
#   - flake.nix か更新前の flake.lock が origin/main と違う（main と別の入力で作った lock は main に入れない）
#   - fetch / push / PR 作成に失敗した
# auto-merge を予約できなかったとき（repo で auto-merge が無効等）は警告だけ出して 0 で終わる。
set -uo pipefail

if git diff --quiet HEAD -- flake.lock; then
  echo "flake-lock-pr: flake.lock は変わっていない。PR は作らない"
  exit 0
fi

if ! git fetch --quiet origin main; then
  echo "flake-lock-pr: origin/main を fetch できない。flake.lock は作業ツリーに残した" >&2
  exit 1
fi
base="$(git rev-parse --verify refs/remotes/origin/main)" || exit 1

if ! git diff --quiet HEAD "$base" -- flake.nix flake.lock; then
  echo "flake-lock-pr: flake.nix か更新前の flake.lock が origin/main と違うので PR にしない。flake.lock は作業ツリーに残した" >&2
  echo "  main を取り込んでから nix run .#update をやり直すか、flake.lock を手で PR にする" >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/flake-lock-pr.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

blob="$(git hash-object -w flake.lock)" || exit 1
GIT_INDEX_FILE="$tmp/index" git read-tree "$base" || exit 1
GIT_INDEX_FILE="$tmp/index" git update-index --cacheinfo "100644,$blob,flake.lock" || exit 1
tree="$(GIT_INDEX_FILE="$tmp/index" git write-tree)" || exit 1

stamp="$(date +%Y%m%d-%H%M%S)"
branch="chore/flake-lock-$stamp"
title="chore(flake): flake.lock の入力を更新する ($stamp)"
commit="$(git commit-tree "$tree" -p "$base" -m "$title")" || exit 1

if ! git push --no-verify --quiet origin "$commit:refs/heads/$branch"; then
  echo "flake-lock-pr: $branch を push できない。flake.lock は作業ツリーに残した" >&2
  exit 1
fi

body="\`nix run .#update\` が更新し、ビルドと switch が通った flake.lock。CI が通ったら auto-merge する。"
if ! url="$(gh pr create --base main --head "$branch" --title "$title" --body "$body")"; then
  echo "flake-lock-pr: PR を作れない（$branch は push 済み）。flake.lock は作業ツリーに残した" >&2
  exit 1
fi
echo "flake-lock-pr: $url"

if ! gh pr merge "$url" --auto --squash --delete-branch; then
  echo "flake-lock-pr: WARNING: auto-merge を予約できない。$url は手で merge する" >&2
fi

git checkout --quiet HEAD -- flake.lock
