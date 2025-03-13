#!/usr/bin/env bash

# Nixがインストールされているか確認
if ! command -v nix &>/dev/null; then
  echo "Nixがインストールされていません。インストールを開始します。"
  sh <(curl -L https://nixos.org/nix/install) --daemon
  if [ "$(uname)" = "Darwin" ]; then
    . /etc/zshrc
  fi
fi

# 環境のセットアップ
echo "環境をセットアップしています..."
nix run .#update
