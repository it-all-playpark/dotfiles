#!/usr/bin/env bash
# magic-switch の activation が「起動中のアプリバンドルを消さない」ことを検証する。
#
# 2026-08-22 の apply で、起動中の Magic Switch のバンドルを activation が
# `rm -rf` で消した。実体を失ったプロセスは終了要求にまともに応答できず、
# シャットダウンが停止 (shutdown stall) して強制再起動になり、BLE の bond が
# 巻き添えで壊れた。
#
# よって以下を不変条件とする。
#   1. `$dest` を消す前に、起動中かどうかの guard を通ること
#   2. その guard は差し替えを行わずに抜けること (exit)
#   3. `$dest` を消す前に staging へのコピーが済んでいること
#      (途中で失敗したときに壊れたバンドルを dest に残さない)
#   4. stamp を書くのは入れ替えが終わったあとであること
#      (失敗した回に stamp を書くと、次回が「適用済み」と誤認して skip する)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX_FILE="$REPO_ROOT/home-manager/programs/magic-switch.nix"

PASS=0
FAIL=0

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

ng() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

if [ ! -f "$NIX_FILE" ]; then
  echo "FAIL: $NIX_FILE が無い" >&2
  exit 1
fi

# activation ブロックの本体だけを取り出す。
BODY="$(awk '
  /home\.activation\.magicSwitchApp = / { inblock = 1; next }
  inblock && /^  ..;$/                  { inblock = 0; next }
  inblock                                { print }
' "$NIX_FILE")"

if [ -z "$BODY" ]; then
  echo "FAIL: magicSwitchApp の activation ブロックを取り出せなかった (検査が空振りしている)" >&2
  exit 1
fi

line_of() {
  # $1 にマッチする最初の行番号。無ければ空文字。
  # grep の不一致は失敗ではないので握り潰す。`set -e` 下で握り潰さないと、
  # 「見つからない = 検証したい失敗ケース」で何も出さずに落ちる。
  local hit
  hit="$(echo "$BODY" | grep -n -- "$1" || true)"
  [ -n "$hit" ] || return 0
  echo "$hit" | head -n 1 | cut -d: -f1
}

# 探すのは activation スクリプト側の変数名そのもの。ここで展開されては困るので
# シングルクォートのままにする。
# shellcheck disable=SC2016
{
  GUARD_LINE="$(line_of 'pgrep')"
  RM_DEST_LINE="$(line_of 'rm -rf "\$dest"')"
  CP_STAGING_LINE="$(line_of 'cp -R "\$src" "\$staging"')"
  MV_LINE="$(line_of 'mv "\$staging" "\$dest"')"
  STAMP_LINE="$(line_of 'ln -sfn')"
}

# 1. dest を消す前に起動中 guard を通る
if [ -z "$RM_DEST_LINE" ]; then
  ok "dest を消していない (guard の要否なし)"
elif [ -z "$GUARD_LINE" ]; then
  ng "dest を rm -rf しているのに、起動中かどうかの guard (pgrep) が無い"
elif [ "$GUARD_LINE" -lt "$RM_DEST_LINE" ]; then
  ok "起動中 guard が dest の削除より前にある"
else
  ng "起動中 guard が dest の削除より後ろにある"
fi

# 2. guard は差し替えせずに抜ける
if [ -n "$GUARD_LINE" ]; then
  GUARD_BLOCK="$(echo "$BODY" | sed -n "${GUARD_LINE},$((GUARD_LINE + 4))p")"
  if echo "$GUARD_BLOCK" | grep -q 'exit 0'; then
    ok "起動中 guard は exit 0 で抜ける"
  else
    ng "起動中 guard に exit 0 が無い (検出しても差し替えを続行してしまう)"
  fi
fi

# 3. dest を消す前に staging へのコピーが済んでいる
if [ -z "$RM_DEST_LINE" ]; then
  :
elif [ -z "$CP_STAGING_LINE" ] || [ -z "$MV_LINE" ]; then
  ng "staging へコピーしてから mv で入れ替える形になっていない"
elif [ "$CP_STAGING_LINE" -lt "$RM_DEST_LINE" ] && [ "$RM_DEST_LINE" -lt "$MV_LINE" ]; then
  ok "staging へコピー → dest 削除 → mv の順になっている"
else
  ng "cp(staging) → rm(dest) → mv の順序が崩れている"
fi

# 4. stamp は入れ替えのあとに書く
if [ -z "$STAMP_LINE" ]; then
  ng "stamp を書く ln -sfn が無い"
elif [ -z "$MV_LINE" ]; then
  :
elif [ "$MV_LINE" -lt "$STAMP_LINE" ]; then
  ok "stamp は入れ替えが終わってから書いている"
else
  ng "入れ替えより前に stamp を書いている (失敗した回を適用済みと誤認する)"
fi

echo
echo "passed: $PASS / failed: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: magic-switch-replace" >&2
  exit 1
fi

echo "PASS: magic-switch-replace"
