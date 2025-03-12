#!/usr/bin/env bash

# Nixがインストールされているか確認
if ! command -v nix &>/dev/null; then
  echo "Nixがインストールされていません。インストールを開始します。"
  # Nixのインストールコマンド
  sh <(curl -L https://nixos.org/nix/install) --daemon
  # シェルの再読み込み
  . /etc/zshrc
fi

# flakeを有効化
if ! grep -q "experimental-features" ~/.config/nix/nix.conf 2>/dev/null; then
  echo "flakeを有効化しています..."
  mkdir -p ~/.config/nix
  echo "experimental-features = nix-command flakes" >>~/.config/nix/nix.conf
fi

# 環境のセットアップ
echo "環境をセットアップしています..."
nix run .#update
