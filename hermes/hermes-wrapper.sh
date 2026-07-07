#!/bin/sh
# hermes wrapper — ~/.hermes/.env を環境変数として load してから real hermes binary を exec する。
# launchd agent (com.playpark.hermes-gateway) からも host shell からも同じ経路で起動できるよう、
# `hermes gateway` 等のサブコマンドに依存せず汎用的に動く。
#
# 配置: dotfiles/hermes/hermes-wrapper.sh → ~/.hermes/hermes-wrapper.sh (symlink, activation で配置)
# real binary: ~/.local/bin/hermes (pip/uv 等が install したもの)
set -eu

HERMES_ENV="${HOME}/.hermes/.env"
HERMES_BIN="${HOME}/.local/bin/hermes"

if [ -f "$HERMES_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$HERMES_ENV"
  set +a
fi

if [ ! -x "$HERMES_BIN" ]; then
  echo "hermes-wrapper: $HERMES_BIN not found or not executable" >&2
  exit 127
fi

exec "$HERMES_BIN" "$@"
