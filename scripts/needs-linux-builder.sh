#!/usr/bin/env bash
# 引数の installable を build するのに、Linux 向けの derivation の build が要るかを判定する。
# 要る（または判定できない）なら 0、要らなければ 1 を返す。
# nix run .#update の build 検証で、linux-builder VM（scripts/with-linux-builder.sh）を起動するかを決める。
# flake.lock が変わらなくても、merge 済みで未反映の lock を初めて build するときは
# linux-builder VM 自体の aarch64-linux derivation を作り直す必要があるので、lock の差分ではなく
# 実際に build される derivation の system で判定する。
# usage: needs-linux-builder.sh <installable>...

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: needs-linux-builder.sh <installable>..." >&2
  exit 2
fi

# 評価に失敗したときは判定できないので、VM を起動する側に倒す
if ! out="$(nix build --no-link --dry-run "$@" 2>&1)"; then
  exit 0
fi

# dry-run は build する derivation を「  /nix/store/<hash>-<name>.drv」の行で出す（fetch する path は .drv ではない）
drvs=()
while IFS= read -r line; do
  drvs+=("$line")
done <<<"$(printf '%s\n' "$out" | sed -n 's|^[[:space:]]*\(/nix/store/[^[:space:]]*\.drv\)$|\1|p')"

if [ -z "${drvs[0]:-}" ]; then
  exit 1
fi

nix derivation show "${drvs[@]}" | grep -q '"system":"[^"]*-linux"'
