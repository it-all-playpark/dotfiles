#!/usr/bin/env bash

# Nixがインストールされているか確認
if ! command -v nix &>/dev/null; then
  echo "Nixがインストールされていません。インストールを開始します。"
  # Nixのインストールコマンド
  sh <(curl -L https://nixos.org/nix/install) --daemon
  # シェルの再読み込み
  . /etc/profile.d/nix.sh
fi

# 環境のセットアップ
echo "環境をセットアップしています..."
nix run .#update
