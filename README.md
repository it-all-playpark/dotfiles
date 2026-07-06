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
├── treefmt.nix       # treefmt-nix フォーマッター設定
├── darwin/
│   └── default.nix   # nix-darwin（システム設定）の定義
├── home-manager/
│   ├── default.nix   # home-manager全体の設定
│   ├── home/         # ユーザー固有のdotfiles設定（nvim, zellij, gitなど）
│   └── programs/     # 各プログラム（fish, zsh, git, neovimなど）の設定
├── scripts/
│   └── setup-skills.sh  # Agent Skills セットアップスクリプト
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
- Agent Skills（AIエージェントツール用スキル）のセットアップ

3. **環境の更新**

dotfilesや設定に変更を加えた場合、以下のコマンドで一括更新が可能です。

```bash
nix run .#update
```

flake.nix内のアップデートスクリプトが、home-managerとnix-darwinの両方の設定を切り替えます。

## 1Password Service Account による GH_TOKEN 注入（bg claude agents 向け）

`bg` で spawn される claude agents の sandbox からは credential dir（`~/.config/gh` 等）が deny されるため `gh` 認証が失敗します。これを回避するため、1Password Service Account (SA) を使い env 経由で `GH_TOKEN` を注入します。

### 1. Service Account の作成

1Password で対象 vault への read 権限を持つ Service Account を作成し、SA トークン（`ops_...` 形式）を発行します。

- [1Password Service Accounts](https://developer.1password.com/docs/service-accounts/) のドキュメントに従い作成
- 対象 vault に対して read 権限を付与
- 発行された SA トークンを控える（この後 Keychain に格納するので画面には残さない）

### 2. Keychain への格納

SA トークンは macOS Keychain の `claude-op-sa` という service 名で保存します。

```bash
security add-generic-password -s claude-op-sa -a "$USER" -w
```

**128 文字切れの罠**: `security add-generic-password -w` はプロンプト（GUI ダイアログや一部の入力経路）経由で値を渡すと 128 文字で切れることがあります。SA トークンは 128 文字を超えることが多いため、必ず以下のいずれかの方法で値を直接渡してください。

```bash
# pbpaste でクリップボードの値を shell 側から直接渡す（プロンプトへの貼り付けは避ける）
security add-generic-password -s claude-op-sa -a "$USER" -w "$(pbpaste)"
```

既に短く切れた値で登録してしまった場合は、一度削除してから入れ直してください。

```bash
security delete-generic-password -s claude-op-sa
security add-generic-password -s claude-op-sa -a "$USER" -w "$(pbpaste)"
```

### 3. env-file の作成

テンプレートをコピーし、`op://` 参照の vault/item 名を実際のものに置き換えます。

```bash
cp ~/.config/op/claude.env.example ~/.config/op/claude.env
```

```
GH_TOKEN=op://<vault>/<item>/token
```

の `<vault>` と `<item>` を、作成した実 vault/item 名に置換してください。

リポジトリ単位で値を上書きしたい場合は、リポジトリ直下に `.op.env`（`.gitignore` 済み）を配置します。同名キーは repo 側が global (`~/.config/op/claude.env`) を後勝ちで上書きします。

### 4. 疎通確認

SA トークンが有効か確認します（token 平文が端末に表示されるため、確認時のみ実行し、シェル履歴への残留に注意してください）。

```bash
OP_SERVICE_ACCOUNT_TOKEN=$(security find-generic-password -s claude-op-sa -a "$USER" -w) op vault list
```

env-file が意図通り解決できるか確認します（同様に平文が出力されるため取り扱い注意）。

```bash
op run --env-file ~/.config/op/claude.env -- printenv GH_TOKEN
```

### 仕組み

fish の `claude` 関数が `op run` で `op://` 参照を解決した env を組み立て、`env -u OP_SERVICE_ACCOUNT_TOKEN` で SA トークン自体を除去してから `claude` を起動します。credential dir に対する sandbox の deny 設定はそのまま維持され、env チャネルのみで最小限の secret（`GH_TOKEN` 等）が渡されます。

## Agent Skills

本リポジトリは [Agent Skills](https://agentskills.io) をサポートしており、複数のAIエージェントツール間でスキルを共有できます。

### サポートされるエージェント

| ツール | Symlink パス |
|--------|-------------|
| Claude Code | `~/.claude/skills` |
| Codex | `~/.codex/skills` |
| Antigravity | `~/.gemini/antigravity/skills` |

### セットアップ

`setup.sh` 実行時に自動でセットアップされます。手動でセットアップする場合：

```bash
./scripts/setup-skills.sh
```

カスタムパスを指定する場合：

```bash
./scripts/setup-skills.sh --skills-repo /path/to/your/skills
```

Skills の詳細は [it-all-playpark/skills](https://github.com/it-all-playpark/skills) を参照してください。

## Codex 設定管理

Codex の設定は `codex/` ディレクトリで管理します。

- `codex/config.base.toml`: 全ユーザー共通の設定
- `codex/config.local.toml.template`: ローカル専用設定のテンプレート
- `codex/prompts/`, `codex/policy/`: 静的アセット
- `codex/rules/default.rules`: 初期テンプレート（`~/.codex/rules/default.rules` へ初回コピー）

`nix run .#update <username>` 実行時に Home Manager activation が以下を実施します。

- `codex/prompts`, `codex/policy` を `~/.codex/` にシンボリックリンク
- `codex/rules/default.rules` を `~/.codex/rules/default.rules` に初回コピー（以後はローカル運用）
- `~/.codex/config.local.toml` がなければ既存 `config.toml` の `projects` / `mcp_servers` セクションを移行（バックアップ作成）またはテンプレートから生成
- `~/.codex/config.toml` を `config.base.toml + config.local.toml` で再生成

機密情報（MCPキー等）は `~/.codex/config.local.toml` にのみ記載してください。

## コード品質（Format / Lint）

[treefmt-nix](https://github.com/numtide/treefmt-nix) を利用したフォーマット・リント基盤を導入しています。

### 対応ツール

| 言語 | フォーマッター | リンター |
|------|--------------|---------|
| Nix | nixfmt | - |
| Python | ruff format | ruff check |
| Lua | stylua | - |
| Shell | shfmt | shellcheck |

### 使い方

```bash
# 全ファイルをフォーマット
nix fmt

# フォーマット違反がないかチェック（CI向け）
nix flake check

# devShell に入る（shellcheck 等のリンターが使える）
nix develop
```

### Pre-commit Hook

`nix develop` で devShell に入ると、`.git/hooks/pre-commit` が自動設置されます。
以降のコミット時に treefmt + shellcheck が自動実行され、フォーマット済みのコードのみがコミットされます。

devShell 外からのコミットではフォーマットはスキップされます（警告メッセージを表示）。

## 注意事項

- バックアップの推奨
既存の設定ファイルが上書き・削除される可能性があるため、事前にバックアップを取ることをおすすめします。
- カスタマイズ
各種設定（シェル、Git、Neovimなど）は、home-manager内のテンプレートファイルを編集することで柔軟にカスタマイズ可能です。
- Nix Flakesの利用
本リポジトリはNix Flakesを前提としています。詳細な使い方やトラブルシューティングについては、Nix公式ドキュメントを参照してください。

## ライセンス

このリポジトリは MIT License の下で公開されています。詳細はLICENSEファイルをご確認ください。
