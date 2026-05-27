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
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` で発行 (下記参照) |

`chmod 600 ~/.hermes/.env` は activation で実施済み。

> **既存 `~/.hermes/.env` を持つユーザ向け追記手順** (activation は既存 `.env` を上書きしない):
>
> ```bash
> echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-...' >> ~/.hermes/.env
> ```

### model 切替

```bash
hermes model
# Provider: OpenRouter
# Model: moonshotai/kimi-k2.6 など
```

### gws (Google Workspace CLI) 認証 (初回のみ)

hermes は docker container 内で `gws` を実行するが、container では macOS Keychain が
使えないため、host の keyring で復号した credentials を JSON ファイルに export して
mount 経由で共有する。

```bash
# host 側で 1 回実行 (gws auth login が未実行ならまずそちらを先に)
mkdir -p ~/.config/gws
gws auth export --unmasked > ~/.config/gws/token.json
chmod 600 ~/.config/gws/token.json
```

- `--unmasked` を忘れると値が `...` で省略保存され、container 側で `invalid_client` (401)
- `~/.config/gws/` は `hermes/config.yaml` の `docker_volumes` で `/root/.config/gws:rw` に mount 済み
- container 側 image (`hermes-tools:latest`) には以下の env が焼き込まれており、
  上記 token.json を file backend 経由で自動参照する:
  - `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`
  - `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/root/.config/gws/token.json`
- refresh_token は long-lived だが、Google 側 revoke / 90 日無使用で失効する。
  失効時は host で `gws auth login` → 上記 export を再実行

### Slack manifest 生成

```bash
hermes slack manifest --write
# ~/.hermes/slack-manifest.json が生成される
# → Slack App 管理画面で "From a manifest" → import
```

### 起動

ログイン時に **launchd agent (`com.playpark.hermes-gateway`)** が `hermes gateway`
を background 起動する。`nix run .#update` で plist が `~/Library/LaunchAgents/`
に展開され、即座に load される。

ただし **opt-in marker `~/.hermes/.gateway-primary` が存在する host でのみ実起動** する。
marker 不在なら agent は exit 0 で即終了し restart しない。同一 user account を
複数 Mac で運用する場合の二重起動 (Slack に同一 App Token で multi-connect → 二重応答)
を防ぐため。

```bash
# primary 機で opt-in
touch ~/.hermes/.gateway-primary
launchctl kickstart -k gui/$(id -u)/com.playpark.hermes-gateway

# primary を別 Mac に移すとき
rm ~/.hermes/.gateway-primary    # 旧機
# 旧機の gateway を停止
launchctl kickstart -k gui/$(id -u)/com.playpark.hermes-gateway
# 新機で touch + kickstart
```

```bash
# 状態確認
launchctl list | grep hermes-gateway

# 停止/再開
launchctl unload ~/Library/LaunchAgents/com.playpark.hermes-gateway.plist
launchctl load   ~/Library/LaunchAgents/com.playpark.hermes-gateway.plist

# ログ
tail -f ~/.hermes/logs/gateway.{out,err}.log
```

KeepAlive (Crashed + 非0 exit) + `ThrottleInterval=30` を設定済みなので、
Docker Desktop が遅れて起動するケースや一時的な network 断は自動で復旧する。

foreground で debug したい場合は agent を unload してから:

```bash
hermes gateway   # foreground
```

## path_guard plugin

hermes built-in approvals が見落とす deny を補強する。

- **sensitive path**: `.env` / `.ssh/` / `.gnupg/` / `.aws/` / `Library/Keychains/` 等
- **interpreter/runner**: `npx` / `uvx` / `bunx` / `deno run|eval` / `eval ` / `fish|dash -c`

`pre_tool_call` フックで `tool_name` / `args.command|path|file_path|paths` を走査し、
マッチしたら `{"action": "block", ...}` を返す。

## Claude Code in container (subscription)

### 概要

`hermes-tools:latest` image に Node.js v24 + `@anthropic-ai/claude-code` が同梱されている (#61)。
`CLAUDE_CODE_OAUTH_TOKEN` env を container に forward することで、**Claude Pro/Max subscription 枠**
内で `claude --bg` + `claude agents` 経路を使い、ghq 配下 repo の project skill を実行できる。

> **subscription 経路について**: `claude --bg` + `claude agents` は 2026-06-15 以降も subscription 内。
> API billing になるのは Agent SDK (TypeScript/Python library) と `claude -p` のみ。

### container 専用 OAuth token の発行 (初回のみ)

host の `~/.claude/.credentials.json` を bind mount する方法は rotation 競合リスクがあるため非推奨。
`claude setup-token` で **container 専用の長寿命 OAuth token** を別途発行すること。

```bash
# host 上で実行
claude setup-token
# → ブラウザが開き OAuth flow → token (sk-ant-oat-...) が表示される
# → ~/.hermes/.env の CLAUDE_CODE_OAUTH_TOKEN= に貼り付け
```

### image の build と動作確認

```bash
# image build (darwin host では nix.linux-builder 経由で aarch64-linux image を build)
nix run .#hermes-image-load

# 動作確認
docker run --rm hermes-tools:latest claude --version
docker run --rm hermes-tools:latest node --version  # v24.x が返ること

# token 認証確認
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}" \
  hermes-tools:latest \
  claude --version
```

### smoke test の実行

```bash
# docker/build が必要なためローカル手動実行のみ (CI 対象外)
bash tests/hermes-image-smoke.sh            # すべてのテスト
bash tests/hermes-image-smoke.sh --skip-build   # nix build をスキップ
bash tests/hermes-image-smoke.sh --skip-docker  # docker run をスキップ
```

### Troubleshooting

| 症状 | 原因 | 対策 |
|------|------|------|
| `claude: not authenticated` | `CLAUDE_CODE_OAUTH_TOKEN` が空または未設定 | `.env` に token を投入し hermes を再起動 |
| `nix build: 'aarch64-linux' required` | darwin host で linux-builder 未設定 | [README #55 の手順](../README.md) を参照 |
| `claude --version` が失敗 | image が古い (`claude-code` 未同梱) | `nix run .#hermes-image-load` で再 build |

> **follow-up**: Phase 3 (workspace/worktree 構成)・Phase 4 (`claude --bg` container 跨ぎ検証)・
> Phase 5 (hermes plugin 化) は別 issue に切り出し予定。

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
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
