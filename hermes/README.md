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

ログイン時に **launchd agent (`com.playpark.hermes-gateway`)** が
`~/.hermes/hermes-wrapper.sh gateway` を background 起動する。
wrapper は `~/.hermes/.env` を `set -a` で export してから real binary
(`~/.local/bin/hermes`) を `exec` する薄いシェル。これにより launchd 経路でも
`.env` の tokens (`CLAUDE_CODE_OAUTH_TOKEN` 等) が確実に注入される。

`nix run .#update` で plist が `~/Library/LaunchAgents/` に展開され、即座に
load される。wrapper 自体は `activation.setupHermes` が `dotfiles/hermes/`
から `~/.hermes/` に symlink を張る。

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

### config.yaml 変更時の reload

hermes daemon は `~/.hermes/config.yaml` を **起動時のみ load** する
(セッションごとに reload しない)。`docker_volumes` / `docker_forward_env` 等を
変更したら kickstart で再起動が必要:

```bash
launchctl kickstart -k "gui/$(id -u)/com.playpark.hermes-gateway"
```

config が反映されているかは、hermes が起動した container を直接覗くのが確実:

```bash
# 起動中 container の mount 一覧
CID=$(docker ps -q --filter ancestor=hermes-tools:latest | head -1)
docker inspect "$CID" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{println}}{{end}}'
```

restart 忘れの典型症状は「config.yaml に書いた mount が container 内に
見当たらない」「新しい env var が container に渡らない」など。

foreground で debug したい場合は agent を unload してから:

```bash
~/.hermes/hermes-wrapper.sh gateway   # foreground (.env 経由)
```

> 直接 `hermes gateway` を叩くと `~/.hermes/.env` は **load されない**。
> debug 時も wrapper 経由で起動すること。

## watchdog (S5, AC-4/AC-5)

`~/.hermes/jobs/*.json` (claude_runner が dispatch_job で書く manifest) を定期 reconcile し、
完了したジョブを `manifest.platform` に応じた経路で通知した上で clone/manifest を後片付けする
常駐タスク。

- **多重run排除**: 起動直後に `flock -xn` で `~/.hermes/watchdog.lock` を排他取得する。
  取得できなければ即 `exit 0`(他 run が処理中)。macOS には GNU flock(1) が同梱されないため
  `pkgs.flock`(discoteq/flock, cross-platform 実装) を home-manager package として追加済み。
- **通知は platform 別に分岐 (`notify_dispatch`)**: `slack` は `chat.postMessage`
  (`SLACK_BOT_TOKEN`)、`discord` は Discord bot REST API
  (`POST /channels/<id>/messages`, `DISCORD_BOT_TOKEN`) — native gateway adapter
  (`gateway/platforms/discord.py`) と同じ credential を使う。それ以外(例: `google_chat` —
  現状は inbound webhook 経路のみで送信用 credential が無い)は adapter 未実装として
  `notified=false` のまま次パスへ retry する。**非 Slack channel を `notify_slack` に丸投げしない**
  ——Slack API は未知 channel でも HTTP 200 + `{"ok":false,"error":"channel_not_found"}` を返すため、
  `notify_slack` は `curl` の終了コードだけでなくレスポンス body の `.ok` も検査する。
- **通知の二重送信防止**: ジョブが `done`/`failed` に達した最初のパスで通知 → 通知成功後に
  `manifest.notified` を atomic に `true` へ更新する。cleanup はこのパスでは行わず、
  **次のパスで `notified=true` を確認してから** `workspace_host_dir` の clone と manifest を削除する。
  通知と cleanup を別パスに分離しているため、cleanup が途中で失敗しても再送信は起きない。
- **bg session の reconcile**: `status` がまだ `pending`/`running` のジョブは、
  `CLAUDE_CONFIG_DIR=<claude_config_host_dir> claude agents --json --all --cwd <workspace_host_dir>`
  で `bg_job_id` を照合する(host 非root からの `CLAUDE_CONFIG_DIR` 読み取りは
  `claudedocs/hermes-phaseB-execution-model-decision.md` の AC-3 実機確認と同じ経路)。
  `bg_job_id` が一覧に無い場合は即 `done` 扱いにはせず、`manifest.created_at` からの猶予
  (`HERMES_WATCHDOG_ABSENT_GRACE_SECONDS`、既定60秒)を過ぎてから、かつ連続
  `HERMES_WATCHDOG_ABSENT_CONFIRM_COUNT` 回(既定3回、manifest の `bg_absent_streak` に永続化)
  不在が続いて初めて `done` と判定する — dispatch 直後の登録遅延や一時的な空応答一発で、
  稼働中ジョブの bind-mount された `workspace_host_dir` が誤って `cleanup_job` に `rm -rf`
  されるのを防ぐため。
- **reaper / timeout 警告** (`HERMES_WATCHDOG_REAP_TIMEOUT_SECONDS`、既定 5400 秒 = 90 分):
  `manifest.created_at` からの経過時間がこの閾値を超えた `pending`/`running` ジョブを
  回収する。放置すると永久に詰まる2ケースに対応:
  - `bg_job_id` が一度も書かれないまま(dispatch が `reserve` 直後に中断された等)閾値超過 →
    `status` を `failed` に強制し、通常の notify+cleanup パスへ流す(それまでは毎パス
    `has no bg_job_id yet — skipping` で永久 skip し `max_concurrent_jobs` の枠を占有し続けた)。
  - `bg_job_id` があり実行中と判定され続ける場合は強制終了せず、閾値超過を毎パス
    warning ログするのみ(`poll_bg_status` による通常の reconcile は継続)。
  - 別枠として、outbound notify adapter が無い platform(例: `google_chat` — inbound webhook
    のみで送信 credential が無い)の terminal ジョブが `notified=false` のまま閾値を超えた場合、
    通知なしで `cleanup_job` する — この platform では notify が原理的に成功し得ないため、
    reap しない限り `workspace_host_dir`/manifest が恒久的にリークする。

### 起動 (launchd)

`com.playpark.hermes-watchdog` が **StartInterval 120秒**で `~/.hermes/watchdog.sh` を起動する。
hermes-gateway と同じ opt-in marker `~/.hermes/.gateway-primary` を再利用するため、
gateway を稼働させている primary 機でのみ watchdog も動く(marker 不在なら即 exit)。

```bash
# 状態確認
launchctl list | grep hermes-watchdog

# 停止/再開
launchctl unload ~/Library/LaunchAgents/com.playpark.hermes-watchdog.plist
launchctl load   ~/Library/LaunchAgents/com.playpark.hermes-watchdog.plist

# 手動で1回だけ実行 (デバッグ用)
~/.hermes/watchdog.sh

# ログ
tail -f ~/.hermes/logs/watchdog.{out,err}.log
```

### 多重run排除の手動確認 (AC-5)

```bash
# 2並列起動 — 片方は lock 取得に失敗し即 exit するはず
~/.hermes/watchdog.sh & ~/.hermes/watchdog.sh; wait
tail ~/.hermes/logs/watchdog.err.log   # "another watchdog run holds ... — exiting immediately (AC-5)" が出る
```

### env overrides (テスト/代替配置用)

`manifest.py` と同じ規約で `HERMES_HOME` が jobs/workspaces/claude-state の基点になる。
`HERMES_WATCHDOG_SKIP_LOCK=1` は **テスト専用**の flock 迂回フラグ(本番 launchd agent では絶対に設定しない)。

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

## フェーズE (Phase E): Discord / Google Chat (S7/E2/E3/E4, AC-12/AC-13)

ChatOps dispatch を Slack 以外の platform に拡張するフェーズ。**着手前に precondition gate を
必ず通すこと**。

### 着手前提条件 (AC-14)

未解決事項 C7 (blast-radius review) の要決定事項 4 項目がすべて decision-logged されている
ことを、以下の自動アサーション test で確認してから着手する:

```bash
bash tests/hermes-phaseE-precondition.test.sh
# → "Results: 3 passed, 0 failed" / exit 0 であること
```

このテストは決定ログ成果物
[`claudedocs/hermes-c7-blast-radius-decisions.md`](../claudedocs/hermes-c7-blast-radius-decisions.md)
に `## 1.`〜`## 4.` の4見出しと4件以上の `決定:` マーカーが存在するかを grep 検証するだけの
filesystem アサーションで、docker/network 不要・CI/sandbox で安全に実行できる。fail した場合は
C7 の当該項目を decision-log してから再実行すること。

### Discord native adapter の有効化

hermes 内蔵の native adapter (`gateway/platforms/discord.py`, 本リポジトリ管理外の editable
install 側) を config で有効化する。

1. Discord Developer Portal で bot を作成し `DISCORD_BOT_TOKEN` を発行、対象サーバーに招待する
2. `~/.hermes/.env` (テンプレートは `hermes/.env.template`) に投入する:

   | 変数 | 内容 |
   |------|------|
   | `DISCORD_BOT_TOKEN` | Discord bot token |
   | `DISCORD_ALLOWED_USERS` | 許可する Discord user ID (カンマ区切り) |
   | `DISCORD_ALLOWED_ROLES` | 許可する Discord role ID (カンマ区切り、任意) |

   > **重要 (allowlist / fail-open 警告)**: `discord.py` の `_is_allowed_user` は
   > `DISCORD_ALLOWED_USERS` と `DISCORD_ALLOWED_ROLES` が **両方空だと全員許可 (fail-open)**
   > になる仕様。fail-closed にするため、どちらか (通常は両方) を必ず設定すること。未設定の
   > ままではこの機能は allowlist を強制しない。

3. `hermes/config.yaml` の `platforms.discord.extra.require_mention: true` で mention なし
   メッセージの dispatch を防ぐ (strict_mention 相当)。`platforms.discord.dm_role_auth_guild`
   は意図的に未設定のまま運用する — 設定すると DM でのロール認証が有効になり、共有 guild
   経由の cross-guild 権限昇格リスクがあるため
4. `hermes/repo_bindings.yaml` の `platforms.discord.channels.<channel_id>.repos` で
   bind 対象 channel と repo を明示する (未 bind の channel は fail-closed で dispatch 不可)
5. config.yaml は起動時のみ load されるため、変更後は `launchctl kickstart -k
   gui/$(id -u)/com.playpark.hermes-gateway` で再起動する

### Google Chat (generic webhook 経路)

Google Chat 用の native adapter は存在しない (`gateway/platforms/` に `google_chat.py` は
無い) ため、generic webhook 経路 (`gateway/platforms/webhook.py`, token/secret 認証) で
受ける。

1. `~/.hermes/.env` に投入する:

   | 変数 | 内容 |
   |------|------|
   | `WEBHOOK_ENABLED` | `true` (Google Chat webhook route を使う場合) |
   | `GOOGLE_CHAT_WEBHOOK_SECRET` | Google Chat 側からの POST を検証する共有 secret |

2. `hermes/config.yaml` の `platforms.webhook.extra.routes.google-chat.secret` は
   `"${GOOGLE_CHAT_WEBHOOK_SECRET}"` として `.env` の値を参照する
   (`hermes_cli/config.py` の `_expand_env_vars` が load 時に展開)
3. `hermes/repo_bindings.yaml` の `platforms.google_chat.channels.<space_id>.repos` で
   bind 対象 space (`spaces/AAAAxxxxxxx` 形式) と repo を明示する。shared secret を
   知らない送信元 (または誤った secret) からの POST は `webhook.py` 側の signature 検証で
   拒否され、この binding には到達しない (fail-closed)

   > **重要 (per-user AC-12 は未充足): route/space 境界であって allowlist ではない**。
   > `GOOGLE_CHAT_WEBHOOK_SECRET` は Google Chat 側サーバーが space にひも付けて保持するため、
   > **bound space の全メンバーのメッセージが正しい secret を伴って到達する**。この secret
   > 検証は「正しい secret を伴った POST か (= route/space 境界の未認証源の遮断)」を保証する
   > のであって、「どの個人が送信したか」を検証する per-user allowlist でも、Discord の
   > `require_mention` に相当する mention gating でもない。`guard.py`/`dispatch_job` の検証も
   > `platform` + `channel` (space) → repo scope の判定のみで user scope を持たない。
   > enforcement 層 (`gateway/platforms/webhook.py`) は editable install 側で本リポジトリ
   > 管理外のため、`hermes/config.yaml`/`hermes/repo_bindings.yaml` の config 変更だけでは
   > per-user gating を追加できない。したがって **Google Chat は AC-12 (allowlist 外ユーザー/
   > mention なしの dispatch 拒否) を per-user 粒度では config だけで満たさない**。
   > 受容可否は人間判断への escalate 事項として
   > [`claudedocs/hermes-phaseE-googlechat-user-gating-decision.md`](../claudedocs/hermes-phaseE-googlechat-user-gating-decision.md)
   > (要決定・決定保留) に記録している。決定前に Google Chat を production bind する場合は
   > このリスクを踏まえた上で行うこと。

### 重複配送 (dedupe) は platform adapter 層の責務 (AC-13)

同一 event/message id の重複配送に対する二重 dispatch (二重 clone・二重 PR) 防止は
**plugin 層 (`hermes/plugins/claude_runner/`) では実装しない**。inbound メッセージフック
(invoke_hook 対象イベント) には該当フックが存在しないため、これは正しい統合点ではない。

dedupe は各 platform adapter 層に委譲される:

- **Slack / Discord**: hermes 内蔵 adapter が dedupe 済み
- **Google Chat**: generic webhook 経路 (`gateway/platforms/webhook.py`) 側の dedupe に依存
- 実装パターンの参照: `~/.hermes/hermes-agent/gateway/platforms/wecom_callback.py` の
  `_seen_messages` + TTL による重複配送防止パターン (本リポジトリ管理外、editable install
  側のソース参照用)

plugin 層はこの dedupe を前提として、adapter を通過したメッセージのみを受け取る。

### AC-12/AC-13 手動実機検証チェックリスト

Discord / Google Chat は保証レベルが異なる (per-user allowlist vs route/space 境界のみ) ため、
チェックリストを分離して記載する。実機で手動検証すること (自動テストではない):

#### [Discord・per-user 粒度] AC-12

- [ ] **allowlist 外ユーザからの依頼が dispatch されないこと**
  - `DISCORD_ALLOWED_USERS`/`DISCORD_ALLOWED_ROLES` に含まれない user で bind 済み channel に
    メンション付き依頼を送り、`~/.hermes/jobs/*.json` に新規 manifest が生成されないことを
    確認する (env allowlist、`discord.py` の `_is_allowed_user`)
- [ ] **mention なしメッセージが dispatch されないこと**
  - `require_mention: true` の bind channel に bot を mention せず通常メッセージを送り、
    dispatch_job が呼ばれないことを確認する

#### [Google Chat・route/space 境界のみ] AC-12

> per-user 粒度の allowlist・mention gating は存在しない。以下は「未認証源 (誤った secret)
> の遮断」の確認であり、「allowlist 外の個人・mention なしの拒否」ではない。受容可否は
> [`claudedocs/hermes-phaseE-googlechat-user-gating-decision.md`](../claudedocs/hermes-phaseE-googlechat-user-gating-decision.md)
> の決定 (要決定・決定保留) に依存する。

- [ ] **誤った/未知の secret を伴う POST が拒否されること (route/space 境界の確認、per-user
      allowlist の確認ではない)**
  - `GOOGLE_CHAT_WEBHOOK_SECRET` を知らない送信元、または誤った secret で webhook route に
    POST し、`webhook.py` の signature 検証で拒否され dispatch されないことを確認する
  - **per-user 制御の確認ではない**: bound space に在籍する正規メンバーが secret を伴って
    送信した場合の per-user 絞り込み・mention gating は E3 決定 (上記リンク) が案A/案B の
    どちらかに定まるまで検証対象外

#### [dedupe・AC-13] 全 platform 共通

- [ ] **同一 event/message id の重複配送で dispatch が1回のみであること**
  - allowlist 済みユーザ (Discord) または route secret を伴う正規送信元 (Google Chat) から
    mention 付き/正規経路で1件依頼を送った後、同一 message id / event id を platform 側
    (または adapter の再送機構) から再送させ、`~/.hermes/jobs/*.json` の manifest が1件のみ
    (clone・PR とも1回のみ) であることを確認する。Slack/Discord は内蔵 adapter の dedupe、
    Google Chat は webhook 経路の dedupe に依存する
    (`gateway/platforms/wecom_callback.py` の `_seen_messages` + TTL パターン参照)

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
