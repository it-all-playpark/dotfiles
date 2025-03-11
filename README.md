# dotconfig – Nix Managed Dotfiles for macOS

このリポジトリは、macOS向けの開発環境を構築するためのdotfilesを**Nix (Flakes)** を利用した管理方式へ移行したものです。  
nix-darwin（システム設定）とhome-manager（ユーザー設定）をFlake経由で一元管理することで、再現性のある環境構築を実現します。

## 特徴

- **Nix/Flakes管理**  
  `flake.nix`および`flake.lock`でnix-darwinとhome-managerの設定を統合。  
  システム全体とユーザー環境の構成をコードとして管理できます。

- **macOS専用最適化**  
  macOS向けに、Homebrewやシェルの設定など、必要なコンポーネントを含んでいます。  
  ※ Vimのキーバインドは「大西配列」向けに設定されています（必要に応じて変更してください）。

- **再現性のあるセットアップ**  
  Nixの仕組みを利用することで、常に最新かつ安定した環境を提供します。

## 前提条件

- **macOS**  
  本リポジトリはmacOS上での利用を前提としています。

- **Nixのインストール**  
  まだNixがインストールされていない場合、`setup.sh`実行時に自動インストールが試みられます。  
  または、[Nix公式サイト](https://nixos.org/download.html)のガイドを参照してください。

## ディレクトリ構成

```text
dotconfig/
├── README.md
├── flake.nix         # nix-darwin / home-manager設定を統合したFlake定義
├── flake.lock        # Flake依存関係のロックファイル
├── darwin/
│   └── default.nix   # nix-darwin（システム設定）の定義
├── home-manager/
│   ├── default.nix   # home-manager全体の設定
│   ├── home/         # ユーザー固有のdotfiles設定（nvim, tmux, gitなど）
│   └── programs/     # 各プログラム（fish, zsh, git, neovimなど）の設定
└── setup.sh          # 環境セットアップ用スクリプト（Nixインストール＆更新）
```

## セットアップ手順

1. **ローカル設定ファイルの準備**

   環境依存の設定は、テンプレートファイルをコピーして編集してください。  
   例：Gitのローカル設定

  ```bash
  cp home-manager/home/file/git/config.local.template home-manager/home/file/git/config.local
  ```

  同様に、Fish用の設定もコピーします。

  ```bash
  cp home-manager/home/file/fish/config.fish.local.template home-manager/home/file/fish/config.fish.local
  ```

2. **初回セットアップ**

  リポジトリのルートディレクトリに移動し、以下のコマンドを実行してください。

  ```bash
  ./setup.sh
  ```

  このスクリプトは以下を実施します：

- Nixが未インストールの場合、自動でインストール
- `nix run .#update` コマンドでFlake定義に基づく最新の環境（nix-darwinおよびhome-manager）の適用

3. **環境の更新**

dotfilesや設定に変更を加えた場合、以下のコマンドで一括更新が可能です。

```bash
nix run .#update
```

flake.nix内のアップデートスクリプトが、home-managerとnix-darwinの両方の設定を切り替えます。

## 注意事項

- バックアップの推奨
既存の設定ファイルが上書き・削除される可能性があるため、事前にバックアップを取ることをおすすめします。
- カスタマイズ
各種設定（シェル、Git、Neovimなど）は、home-manager内のテンプレートファイルを編集することで柔軟にカスタマイズ可能です。
- Nix Flakesの利用
本リポジトリはNix Flakesを前提としています。詳細な使い方やトラブルシューティングについては、Nix公式ドキュメントを参照してください。

## ライセンス

このリポジトリは MIT License の下で公開されています。詳細はLICENSEファイルをご確認ください。
