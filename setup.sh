#!/usr/bin/env bash

# Nixがインストールされているか確認
if ! command -v nix &>/dev/null; then
  echo "Nixがインストールされていません。インストールを開始します。"
  sh <(curl -L https://nixos.org/nix/install) --daemon
  if [ "$(uname)" = "Darwin" ]; then
    . /etc/zshrc
  fi
fi

# flakeを有効化
if ! grep -q "experimental-features" ~/.config/nix/nix.conf 2>/dev/null; then
  echo "flakeを有効化しています..."
  mkdir -p ~/.config/nix
  echo "experimental-features = nix-command flakes" >>~/.config/nix/nix.conf
fi

# 環境のセットアップ
echo "環境をセットアップしています..."

# コマンドライン引数を確認
if [ -z "$1" ]; then
  echo "使用法: ./setup.sh <ユーザー名>"
  echo "例: ./setup.sh naramotoyuuji"
  exit 1
fi

# 引数をnix runコマンドに渡す
nix run .#update "$1"
