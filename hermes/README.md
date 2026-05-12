# hermes

dotfiles-managed configuration for [hermes-agent](https://hermes-agent.nousresearch.com/).
home-manager の activation により `~/.hermes/` 配下に symlink される (Plan A)。

## ファイル構成

```
hermes/
├── README.md              # このファイル
├── config.yaml            # symlink → ~/.hermes/config.yaml
├── .env.template          # 初回 copy → ~/.hermes/.env (chmod 600)
└── plugins/
    └── path_guard/        # symlink → ~/.hermes/plugins/path_guard
        ├── plugin.yaml
        └── __init__.py
```

`hermes/.env` は **.gitignore で除外**。tokens を含む実体ファイルは絶対に commit しない。

## activation

`home-manager/home/default.nix` の `activation.setupHermes` が以下を実施する:

1. `~/.hermes/` ディレクトリ作成
2. `config.yaml` を symlink (既存実体ファイルは事前削除)
3. `plugins/*/` を per-plugin で symlink
4. `~/.hermes/.env` が **未存在** の場合のみ `.env.template` から copy + chmod 600
   - 既存の `.env` は tokens 喪失防止のため触らない

適用は通常通り:

```bash
nix run .#update
```

## 運用メモ

### tokens 投入 (初回のみ)

`nix run .#update` 後に `~/.hermes/.env` が作成される (template 由来)。
以下を手動入力:

| 変数 | 取得元 |
|------|--------|
| `OPENROUTER_API_KEY` | https://openrouter.ai/keys |
| `SLACK_BOT_TOKEN` (xoxb-) | Slack App → OAuth & Permissions |
| `SLACK_APP_TOKEN` (xapp-) | Slack App → Basic Information → App-Level Tokens (`connections:write`) |
| `SLACK_ALLOWED_USERS` | Slack profile → Copy member ID |
| `SLACK_HOME_CHANNEL` | 専用 channel ID |

`chmod 600 ~/.hermes/.env` は activation で実施済み。

### model 切替

```bash
hermes model
# Provider: OpenRouter
# Model: moonshotai/kimi-k2.6 など
```

### Slack manifest 生成

```bash
hermes slack manifest --write
# ~/.hermes/slack-manifest.json が生成される
# → Slack App 管理画面で "From a manifest" → import
```

### 起動

```bash
hermes gateway   # foreground
```

## path_guard plugin

hermes built-in approvals が見落とす deny を補強する。

- **sensitive path**: `.env` / `.ssh/` / `.gnupg/` / `.aws/` / `Library/Keychains/` 等
- **interpreter/runner**: `npx` / `uvx` / `bunx` / `deno run|eval` / `eval ` / `fish|dash -c`

`pre_tool_call` フックで `tool_name` / `args.command|path|file_path|paths` を走査し、
マッチしたら `{"action": "block", ...}` を返す。

## Rollback

```bash
git revert <commit>
nix run .#update
# 必要なら
rm -rf ~/.hermes/{config.yaml,plugins/path_guard}
```

## 参考

- [hermes-agent docs](https://hermes-agent.nousresearch.com/docs/)
- [Slack gateway](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack)
- [Security guide](https://hermes-agent.nousresearch.com/docs/user-guide/security)
- 前段 issue: [#55](https://github.com/it-all-playpark/dotfiles/issues/55) — hermes-tools docker image
- 親 issue: [#57](https://github.com/it-all-playpark/dotfiles/issues/57)
