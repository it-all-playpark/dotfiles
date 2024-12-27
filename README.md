# dotconfig

macOS 環境での開発を想定した dotfiles リポジトリです。  
Git のローカル設定や Homebrew・Vim などの設定ファイルが含まれます。

## 前提

- macOS 上での開発を想定しています。
- Vim のキーバインドは「大西配列」を前提としているため、通常のキーバインドとは異なる可能性があります。  
  キーバインドのカスタマイズを行う場合は、各自の環境に合わせて設定を変更してください。

## セットアップ手順

1. **`.gitconfig.local.template` のコピー**  
   Git のローカル設定用ファイル（ユーザー情報等）をテンプレートからコピーし、自分の環境に合わせて編集します。

   ```bash
   cp .gitconfig.local.template .gitconfig.local
   ```

   > **注意**: `.gitconfig.local` はコミットされないように `.gitignore` などで管理してください。

2. **Homebrew インストールスクリプトの実行**  
   Homebrew を使って必要なパッケージやアプリケーションをインストールするスクリプトです。

   ```bash
   ./install_brew.sh
   ```

   > macOS に Homebrew がインストールされている前提です。未インストールの場合は以下のコマンドで導入してください。
   >
   > ```bash
   > /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   > ```

3. **インストールスクリプトの実行**  
   dotfiles をホームディレクトリにシンボリックリンクとして配置し、各種設定を適用します。
   ```bash
   ./install.sh
   ```
   > ファイルに実行権限がない場合は、事前に `chmod +x install.sh` などで権限を付与してください。

## 注意点

- すでに同名の設定ファイルやディレクトリが存在する場合、上書きまたは削除が行われる可能性があります。  
  バックアップを取るなど注意して実行してください。
- Vim のキーバインドは「大西配列」に合わせたものが含まれているため、慣れていない場合はカスタマイズをおすすめします。

## ディレクトリ構成例

```
dotconfig/
├── .gitconfig
├── .gitconfig.local.template
├── .zshrc
├── install.sh
├── install_brew.sh
└── ...
```

- **`.gitconfig`**  
  共通で使用する Git の設定を管理します。
- **`.gitconfig.local.template`**  
  ユーザー名やメールアドレスなど、環境依存の設定を管理するためのテンプレートファイルです。コピーして `.gitconfig.local` として使用します。
- **`install_brew.sh`**  
  必要なパッケージを Homebrew で一括インストールするためのスクリプトです。
- **`install.sh`**  
  各種 dotfiles をシンボリックリンクとしてホームディレクトリに配置するスクリプトです。

## ライセンス

このリポジトリは [MIT ライセンス](https://opensource.org/license/mit) の下で公開されています。詳細は [LICENSE](https://opensource.org/license/mit) ファイルをご確認ください。

---
