# Hermes 経由の Google Chat / Discord → Claude Code マルチリポジトリ ChatOps 設計

- Status: Draft (brainstorming 承認済み、実装計画は未着手)
- Date: 2026-07-21
- 関連: [dotfiles#57](https://github.com/it-all-playpark/dotfiles/issues/57)(hermes 初期構築)、[dotfiles#61](https://github.com/it-all-playpark/dotfiles/issues/61)(Claude Code container 化。本設計は #61 の Phase 3〜5 を具体化・修正するもの)

## 1. ゴール

複数の GitHub リポジトリ(playpark-llc / it-all-playpark 配下)にまたがるプロジェクトで、Google Chat または Discord から自然言語で依頼を送るだけで、Claude Code が該当リポジトリに対してコード変更を行い PR を作成するところまでを完結させる。マージは常に人間が GitHub 上で行う。

## 2. 前提として採用しない案

検討の過程で「Vercel 上に新規 Bot を建て、claude.ai の RemoteTrigger API(routine)経由でクラウド実行環境にディスパッチする」案を比較したが、以下の理由で不採用とした:

- RemoteTrigger tool は「OAuth トークンをプロセス内で自動注入し、外部に露出しない」設計であり、Vercel Function のような外部プロセスが正当にこの API を呼べる経路がない。
- `action=run` の body 上書きスキーマが未規定(フリーフォーム)で、既存 trigger の再利用パターンに実運用実績がない。
- 通知の outbound 到達性(Discord/Google Chat webhook への到達可否)が未検証。

これらの問題は、**ローカルで常時稼働している hermes-agent という既存資産を使えばそもそも発生しない**(トークンはコンテナに直接 forward 済み、通知は hermes 自身がチャットに返信するだけで済む)ため、本設計は hermes-agent の拡張として構成する。

## 3. 既存資産(現状確認済みの事実)

- `dotfiles/hermes/` に hermes-agent(Nous Research 製、OSS/SaaS の汎用チャットゲートウェイ)の設定一式があり、`com.playpark.hermes-gateway` という launchd agent として常時稼働中(Slack のみ接続済み)。
- hermes は Docker(`hermes-tools:latest`)をターミナルバックエンドとして持ち、`CLAUDE_CODE_OAUTH_TOKEN` / `GH_TOKEN` / `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` をコンテナに forward 済み。`claude --bg` + `claude agents` 経路は Claude Pro/Max のサブスクリプション枠内で動作し、API 課金にならない(`-p` は使わない方針)。
- `~/ghq`(全リポジトリ)がコンテナに `:ro` で mount 済み。書き込み可能な mount は `~/Documents/hermes-out:/workspace/out:rw` のみ現状存在する。
- hermes-agent は Discord・Google Chat を含む多数のメッセージングプラットフォームにネイティブ対応しており、`config.yaml` の `platforms.*` セクションと `.env` へのトークン投入だけで追加接続できる(具体的なキーは §5.1 参照)。新規 Bot サーバーの自作は不要。
- 承認済みブレストの結果、dotfiles issue #61 で「Phase 3: worktree 実行」「Phase 4: container 永続化検証」「Phase 5: hermes plugin 化」が計画されていたが未実装。ただし Phase 3 の `git worktree add` は `/workspace/repos` が `:ro` mount のため**失敗する**(worktree 登録は主リポジトリの `.git/worktrees/` への書き込みを要する)。本設計はこれを `git clone` 方式に修正する。

## 4. 要件(ヒアリング済み)

- Google Chat と Discord の両方に、同時に対応する。
- どのリポジトリ向けの依頼かは、チャンネル/スレッド単位の固定紐付けで判定する(メッセージ本文への毎回明記や LLM 推定は不採用)。
- 作業完了(PR 作成 or 失敗)は自動でチャットに通知する。マージ等の破壊的操作は常に人間が GitHub 上で行う。
- バックグラウンドで動かした Claude Code のジョブは、普段の手元ワークフロー(`cd <repo> && claude agents --cwd $(pwd)` で done/pending を確認する)と同様に、コンテナのライフサイクルに関わらず継続して状態を追跡・確認できること。また作業用の一時ディレクトリは確実に削除されること。

## 5. アーキテクチャ

```
Discord / Google Chat (メッセージ、@mention or 明示コマンド)
        │  hermes-gateway が platforms.discord / platforms.google_chat で受信
        ▼
  claude_runner plugin (新設, hermes/plugins/claude_runner/)
        │  channel_id/space_id → repo のマッピングを解決 (repo_bindings.yaml)
        ▼
  [dispatch] (ephemeral docker container 内、数秒〜数十秒で完了する短いツール呼び出し)
    1. git clone /workspace/repos/<repo> /workspace/jobs/<job-id>  (ローカル clone、書き込み可)
    2. CLAUDE_CONFIG_DIR=/root/.claude-hermes claude --bg "<ユーザー指示 + PR作成までで停止する指示>"
       --cwd /workspace/jobs/<job-id>
    3. job manifest を host 側に記録: ~/.hermes/jobs/<claude-job-id>.json
       { platform, channel_id/space_id, thread_id, repo, workspace_dir: /workspace/jobs/<job-id>, started_at }
    4. hermes がチャットに「受付けました」を即時返信 (Claude Codeの応答を待たない)
        │  ここでコンテナは終了してよい (lifetime_seconds: 1800 に縛られない)
        ▼
  [watchdog] (host 常駐, launchd agent, 数分おきに実行。docker コンテナの外)
    1. ~/.hermes/jobs/*.json を走査
    2. CLAUDE_CONFIG_DIR=~/.hermes/claude-state claude agents --json --all --cwd <workspace_dir>
       で対象ジョブの状態(done/failed/needs-input)を確認
    3. done/failed になったジョブのみ:
       - claude agents <id> logs で結果(PR URL 等)を取得
       - Discord/Google Chat の該当 channel/thread に完了(または失敗)通知を直接 POST
         (host プロセスなので docker sandbox のネットワーク制限を受けない)
       - /workspace/jobs/<job-id> の clone を削除
       - job manifest (~/.hermes/jobs/<id>.json) を削除
    4. 一定時間(例: 90分)経過しても状態不明な job は「タイムアウト」としてチャットに警告
        ▼
  human が GitHub 上で PR を確認・マージ (自動マージなし)
```

### 5.1 メッセージング層 (Discord / Google Chat 追加)

`hermes gateway setup` の対話ウィザードを使うか、以下を手動設定する。

**Discord**(Developer Portal で bot 作成、`bot` + `applications.commands` スコープ、Message Content Intent 有効化):

- `.env`: `DISCORD_BOT_TOKEN`(必須)、`DISCORD_ALLOWED_USERS`(allowlist、必須運用)、`DISCORD_REQUIRE_MENTION=true`(誤爆防止)
- `config.yaml` の `platforms.discord`: `require_mention: true`、`auto_thread: true`、`ignored_channels` で対象外チャンネルを明示

**Google Chat**(GCP プロジェクトで Chat API + Pub/Sub API 有効化、サービスアカウント作成、Pub/Sub topic `hermes-chat-events` / subscription `hermes-chat-events-sub` を作成し IAM 権限を設定):

- `.env`: `GOOGLE_CHAT_PROJECT_ID`、`GOOGLE_CHAT_SUBSCRIPTION_NAME`、`GOOGLE_CHAT_SERVICE_ACCOUNT_JSON`(ファイルパス、`chmod 600`)、`GOOGLE_CHAT_ALLOWED_USERS`(allowlist)
- `config.yaml` の `platforms.google_chat`: `typing_indicator` 等の表示設定のみ(認可は allowlist で行う)

いずれも `chmod 600` した `.env` の追記のみで、`~/.hermes/.env` は activation で上書きされない(dotfiles 既存の運用方針どおり)。

### 5.2 repo binding (`claude_runner` plugin)

`hermes/plugins/claude_runner/`(`path_guard` plugin と同様の構成: `plugin.yaml` + 実装)を新設する。

- `repo_bindings.yaml`: `{platform, channel_id または space_id}` → `{repo: "<org>/<name>", allowed_tools: [...]}` のマッピングを保持。plugin はツール呼び出し時にこのファイルを都度読み込む(hermes 本体の `config.yaml` と異なり daemon 起動時 load 固定ではないため、bind の追加/変更に daemon 再起動は不要)。
- 未 bind のチャンネルからの依頼は実行せず、「このチャンネルはどのリポジトリにも紐付いていません」と返す。

### 5.3 dispatch (worktree ではなく clone)

- `/workspace/repos` は `:ro` のため、当該パスへの `git worktree add` は主リポジトリの `.git/worktrees/` への書き込みが必要で失敗する。**`git clone` に変更する。**
- clone 先は新設の rw docker volume `~/.hermes/workspaces`(host)→ `/workspace/jobs`(container)。既存の `/workspace/out`(hermes-out、成果物置き場として別用途)とは分離する。
- `claude --bg` の指示文には必ず「PR 作成(または `gh pr create --draft`)までで停止し、マージ・force push・main への直接 push は行わない」旨を明記する(既存の `dev-flow` 系運用と同じ不変条件)。

### 5.4 Claude Code セッション状態の永続化

- `claude --bg` のセッション状態は `~/.claude/daemon/` と `~/.claude/jobs/<id>/` にディスク永続化される(supervisor 経由、プロセス終了・sleep・再起動を跨いで保持される)。
- コンテナ内では `CLAUDE_CONFIG_DIR=/root/.claude-hermes` を指定し、これを新設の rw docker volume `~/.hermes/claude-state`(host)→ `/root/.claude-hermes`(container)にマウントする。
  - **ユーザー本人の `~/.claude`(個人利用)とは意図的に分離する**。container は root 実行のため、個人の `~/.claude/daemon/roster.json` を直接共有すると uid 不一致によるパーミッション問題や、同一ファイルへの並行書き込みによる lock 競合のリスクがある。分離しておけば、どちらのプロセスも自分専用の roster/jobs ファイルだけを扱う。
  - host 側から hermes 経由のジョブを直接確認したい場合は `CLAUDE_CONFIG_DIR=~/.hermes/claude-state claude agents --all` を叩けば、普段の `claude agents --cwd $(pwd)` と同じ CLI・同じ表示形式で確認できる。
- これにより、dispatch を行ったコンテナが `lifetime_seconds: 1800` で終了しても、セッション状態は host 上に残り続け、supervisor が再開時に引き継ぐ(公式ドキュメントの「sleep/restart を跨いで永続化」という性質に依拠)。

### 5.5 watchdog

- 新設の launchd agent(`com.playpark.hermes-claude-watchdog` 案)として host に常駐。`hermes-gateway` とは独立したプロセスとし、docker コンテナには依存しない(直接 host 上で `claude` CLI と各プラットフォームの通知 API を呼ぶ)。
- 実行間隔: 3〜5分ごと(初期値、運用しながら調整)。
- 責務: ジョブ状態の確認、完了/失敗通知の送信、clone ディレクトリと job manifest の削除、長時間応答なしジョブのタイムアウト警告。
- 通知送信は Discord Bot Token / Google Chat service account を `.env` から読み、host から直接プラットフォーム API を呼ぶ(docker sandbox のネットワーク制限を経由しないため、§2 で挙げた到達性の懸念はこの経路では発生しない)。

## 6. 安全策

- **マージ権限は一切付与しない**。`claude --bg` への指示に明記し、`gh pr merge` 系コマンドを許可ツールから除外することも検討する。
- **発火制御**: Discord は `require_mention: true`、Google Chat は allowlist されたメールアドレスのみ。誤爆・雑談による意図しない実行やコスト発生を防ぐ。
- **投稿可否の allowlist**: `DISCORD_ALLOWED_USERS` / `GOOGLE_CHAT_ALLOWED_USERS` を必須運用とする。
- **重複配送への対応**: hermes-agent 本体がプラットフォームからの webhook 重複配送を吸収する前提(実装詳細は hermes 本体に委ねる。挙動が不十分と判明した場合は claude_runner plugin 側で job manifest のファイル存在チェックによる冪等化を追加する)。
- **path_guard plugin との整合**: コンテナ内で Claude Code 自身が呼ぶツール(Bash 等)が `path_guard` の `pre_tool_call` 監視対象になっているかは、issue #61 の未確定事項として残っている。claude_runner plugin 実装時に確認する。

## 7. エラーハンドリング

- **未 bind チャンネルからの依頼**: 実行せず、bind 方法を案内する返信のみ。
- **clone/dispatch 失敗**: hermes がその場でチャットにエラーを返信。job manifest は書き込まない(watchdog の対象にならない)。
- **`claude --bg` セッションが `failed` になった場合**: watchdog が失敗内容(ログの要約)をチャットに通知し、clone と manifest を削除する。
- **watchdog 自体が見つけられない/タイムアウトしたジョブ**: 一定時間(初期値90分)応答のない job manifest は「応答なし」警告をチャットに出し、人手での `claude agents --json --all`(`CLAUDE_CONFIG_DIR=~/.hermes/claude-state`)による調査を促す。自動削除はしない(調査のため残す)。
- **複数リポジトリにまたがる1依頼**(例:「A と B の両方に同じ変更を」): 1 依頼 = 1 repo = 1 job に正規化する。claude_runner plugin が該当チャンネルに複数 repo が bind されている場合は、依頼ごとに job を複数ファンアウトし、それぞれ独立して通知・cleanup する。

## 8. ロールアウト計画

1. **Phase A(dispatch の実装)**: `claude_runner` plugin の最小版(単一リポジトリ、clone → `claude --bg` → job manifest 書き込みまで)を実装し、既存の Slack 接続で動作確認する。worktree ではなく clone 方式が実際に動くことをまず確認する。
2. **Phase B(状態永続化の検証)**: `CLAUDE_CONFIG_DIR` の分離 mount が機能するか、コンテナ終了後も `claude agents`(host 側、分離 CONFIG_DIR)でジョブが見え続けるかを実機検証する。
3. **Phase C(watchdog の実装)**: launchd agent として実装し、完了検知・通知・cleanup・タイムアウト警告を通す。Slack のみでエンドツーエンド(依頼→受付→完了通知→cleanup)を通す。
4. **Phase D(repo binding の複数化)**: `repo_bindings.yaml` を複数リポジトリ対応にし、ファンアウトを実装する。
5. **Phase E(Discord / Google Chat 追加)**: §5.1 の手順でプラットフォームを追加し、allowlist・mention 制御を有効化してから展開する。

## 9. 未検証事項(実装前に確認すべきもの)

| # | 項目 | 検証方法 |
|---|---|---|
| 1 | `git clone`(ローカルパスから)がコンテナの `:ro` mount 越しでも問題なく行えるか、hardlink 由来の権限エラーが出ないか | `docker run` で実際に `git clone /workspace/repos/<repo> /tmp/test` を試す |
| 2 | `CLAUDE_CONFIG_DIR` を分離した場合でも `claude --bg` が正常に動作するか(env var 一つで完結するか、他の前提ファイルが `~/.claude` 直下に必要ないか) | 分離 CONFIG_DIR で `claude --bg "echo test"` を実行し `claude agents` に表示されるか確認 |
| 3 | root(container)が書き込んだ `~/.hermes/claude-state` 配下のファイルを、host 側の非 root ユーザーから `claude agents` で問題なく読めるか(パーミッション) | 実際に mount して host 側から読み取りテスト |
| 4 | hermes-agent 本体が webhook の重複配送をどこまで吸収するか(dedupe の実装有無) | hermes-agent 公式ドキュメント/ソースの確認、または同一メッセージを意図的に再送して挙動確認 |
| 5 | path_guard plugin が container 内 Claude Code の tool 呼び出しも監視できるか | 実機での pre_tool_call フック発火確認 |
| 6 | Google Chat の Pub/Sub 経路のレイテンシ(メッセージ受信までの遅延) | 実機での実測 |

## 10. 非対象(Out of scope)

- 自動マージ、force push、main への直接 push の自動化。
- チャット上でのリアルタイムなストリーミング進捗表示(「受付」「完了」の2点通知に割り切る)。
- Slack 以外のプラットフォームでの hermes 初回導入作業そのもの(既に導入済みの Slack 実装を土台とする)。
