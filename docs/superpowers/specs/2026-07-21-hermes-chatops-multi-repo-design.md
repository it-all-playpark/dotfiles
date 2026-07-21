# Hermes 経由の Google Chat / Discord → Claude Code マルチリポジトリ ChatOps 設計

- Status: Draft (brainstorming 承認済み、実装計画は未着手)
- Date: 2026-07-21
- 関連: [dotfiles#57](https://github.com/it-all-playpark/dotfiles/issues/57)(hermes 初期構築)、[dotfiles#61](https://github.com/it-all-playpark/dotfiles/issues/61)(Claude Code container 化。本設計は #61 の Phase 3〜5 を具体化・修正するもの)
- Addendum (2026-07-21): 本設計は悪魔の代弁者/擁護側レビュー(懸念 C1–C16)を経て改訂済み。resolved となった懸念の修正は本文各節へ統合し、未解決のまま残った **C7(資格情報の blast radius / exfil)は §11「未解決の懸念」に既知の残課題として明記**した。なお本レビューの対象アーティファクトは `worktree-hermes-chatops-design@83d6643` の本 Draft + 付随実装ファイル(`hermes/config.yaml` / `claude-code/container.settings.json` / `hooks/allow-pr-merge.sh` / `hooks/allow-feature-push.sh` / `plugins/path_guard/`)であり、当初この spec 本文がレビュープロンプトへ `undefined` として渡った注入不具合はオーケストレーション側で別途修正する(C15。spec 本文の欠陥ではなくトレーサビリティの process fix)。

## 1. ゴール

複数の GitHub リポジトリ(playpark-llc / it-all-playpark 配下)にまたがるプロジェクトで、Google Chat または Discord から自然言語で依頼を送るだけで、Claude Code が該当リポジトリに対してコード変更を行い PR を作成するところまでを完結させる。**マージは常に人間が GitHub 上で行う**。この不変条件は「指示文への明記」だけでは担保されず、**権威ある防御線は bind 対象 repo の base ブランチに設定した required review 付き branch protection である**(§6 参照)。コンテナ側のツール許可(denylist)や token scope はあくまで defense-in-depth と位置づける。

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
- バックグラウンドで動かした Claude Code のジョブは、普段の手元ワークフロー(`cd <repo> && claude agents --cwd $(pwd)` で done/pending を確認する)と同様に、状態を追跡・確認できること。ただし「コンテナのライフサイクルに関わらず継続」という当初の期待は、実行オーナーモデルの見直し(§5.4、C1)により「ジョブ専用の長寿命コンテナがジョブ完了まで実行を担う」形で満たす。また作業用の一時ディレクトリは確実に削除されること(§5.5 の reaper 含む)。

## 5. アーキテクチャ

```
Discord / Google Chat (メッセージ、@mention or 明示コマンド)
        │  hermes-gateway が platforms.discord / platforms.google_chat で受信
        │  ★ inbound 冪等化 (C4): プラットフォーム event/message id
        │     (Pub/Sub message_id / Chat event id / Discord message id) を
        │     永続・有界(TTL/上限)な seen-set で dedupe してから dispatch する。
        │     claude-job-id は inbound 時点で未確定なので冪等鍵に使わない。
        │     ※ seen-set は per-machine。複数 Mac 間の重複は弾けない(C11, §5.5)。
        ▼
  claude_runner plugin (新設, hermes/plugins/claude_runner/)
        │  channel_id/space_id → repo を解決 (repo_bindings.yaml, schema 検証, 失敗時 fail-closed)
        │  ★ backpressure (C6): グローバル同時ジョブ数上限を manifest 数で計数し、
        │     超過なら「混雑中」を返信して拒否(無界キューは作らない)。
        │     clone 前にディスク空き容量ガード(閾値未満は拒否+通知)。
        ▼
  [dispatch] (per-job docker container。★ ジョブ完了までコンテナは生存する — C1)
    1. ★ manifest-first (C5): plugin 生成の相関 id で job manifest を「先に」書く:
       ~/.hermes/jobs/<correlation-id>.json
       { schema_version, status:"starting", platform, channel_id/space_id, thread_id,
         repo, workspace_dir, correlation_id, claude_job_id:null,
         inbound_event_id, started_at, notified_at:null }
    2. ★ clone は origin(GitHub)基準にする (C10):
       (推奨) GH_TOKEN で https://github.com/<repo> を直接 clone、または
       ローカル clone 後に origin を GitHub URL へ張替え → git fetch origin →
       git checkout -b <work> origin/<default>
       (default ブランチ名は動的取得、hardlink 回避が要るなら --no-hardlinks)
    3. CLAUDE_CONFIG_DIR=/root/.claude-hermes/<correlation-id>  (★ per-job — C8)
       claude --bg "<ユーザー指示 + PR作成までで停止する指示>" --cwd <workspace_dir>
    4. 返却された claude-job-id を manifest に reconcile (status:"running")
    5. hermes がチャットに「受付けました」を即時返信
        │  ★ dispatch コンテナはジョブ完了まで生存する。
        │    「起動したら即終了してよい / supervisor が再開時に引き継ぐ」という
        │    fire-and-forget 前提は撤回した(C1。状態の永続化 ≠ 実行の継続)。
        ▼
  [watchdog] (host 常駐, launchd agent, ★ gateway と同一 Mac・.gateway-primary でゲート — C11)
    0. ★ flock で多重 run を排除 (C4)
    1. ~/.hermes/jobs/*.json を走査(in-flight 計数にも使う)
    2. ★ 各ジョブを per-job CONFIG_DIR / workspace_dir で個別照会 (C8):
       CLAUDE_CONFIG_DIR=~/.hermes/claude-state/<correlation-id> \
         claude agents --json --cwd <workspace_dir>
    3. done/failed かつ notified_at が空のジョブのみ:
       - claude agents <id> logs で結果(PR URL 等)を取得
       - 該当 channel/thread に完了/失敗を直接 POST(host プロセスなので sandbox 制限外)
       - POST 成功後に notified_at を記録 (status:"notified")
       - clone / manifest の削除は retry-safe な後追い遷移(manifest は最後に削除)
    4. ★ reaper (C5): workspaces を走査し対応 manifest の無い clone を回収。
       claude_job_id 未 reconcile / agents に不在の manifest は grace period 経過で
       failed 扱いにして reap(orphan clone 回収だけでは manifest-あり/job-未起動を掃除できない)
    5. 一定時間(初期値90分)応答なしジョブはタイムアウト警告(自動削除はしない)
        ▼
  human が GitHub 上で PR を確認・マージ
    (自動マージなし。base の branch protection + required review が権威 — C2)
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

> 注(C4): Google Chat の Pub/Sub は at-least-once 配送であり、ack deadline(既定 10s)に対し dispatch は数秒〜数十秒かかりうる。**hermes は受信直後に ack し、dispatch は非同期で処理する(ack-after-process にしない)**。加えて正常時でも再配送が起きうるため、冪等化は §5 冒頭の event/message id ベース seen-set を **必須**とする(「hermes 本体が吸収する前提」に依存しない)。

### 5.2 repo binding (`claude_runner` plugin)

`hermes/plugins/claude_runner/`(`path_guard` plugin と同様の構成: `plugin.yaml` + 実装)を新設する。

- `repo_bindings.yaml`: `{platform, channel_id または space_id}` → `{repo: "<org>/<name>", allowed_tools: [...]}` のマッピングを保持。plugin はツール呼び出し時にこのファイルを都度読み込む(bind の追加/変更に daemon 再起動不要)。
- **schema 検証と fail-mode(C14)**: `repo_bindings.yaml` の schema を定義し、読込ごとに検証する。parse 失敗・schema 不一致は **fail-closed**(該当 bind の dispatch を拒否し、オペレータ/チャンネルへ通知)とし、**fail-open で誤った default repo に流さない**。repo フィールドの取り違えは「あるチャンネルの依頼が別 repo に PR」という実害に直結するため、緩い fallback を持たない。
- **bind ファイルの隔離(C14)**: `repo_bindings.yaml`(および plugin config)は host 側の claude_runner plugin が読む(hermes は host 稼働: `hermes-wrapper.sh` → `~/.local/bin/hermes`)。**いかなる container mount の外**に置き、`docker_volumes`(`~/ghq:ro`、`hermes-out:rw`、`~/.hermes/claude-state`、`~/.hermes/workspaces` 等)配下に含めない。injection されたエージェントが channel→repo バインドを書き換えて権限昇格するのを防ぐため、container から不可視・不可書とする。
- **per-binding `allowed_tools` の扱い(C14)**: MVP では固定単一の `container.settings.json` に統一し、per-binding `allowed_tools` は仕様から外す。将来 per-binding を有効化する場合は「per-job で `settings.json` を生成し、ジョブコンテナへ `:ro` mount して反映する」機構として明記する(固定単一 mount の現状に暗黙接続しない)。どちらを採るかは実装時に確定する。
- 未 bind のチャンネルからの依頼は実行せず、「このチャンネルはどのリポジトリにも紐付いていません」と返す。

### 5.3 dispatch (worktree ではなく clone、かつ origin 基準)

- `/workspace/repos` は `:ro` のため、当該パスへの `git worktree add` は主リポジトリの `.git/worktrees/` への書き込みが必要で失敗する。**`git clone` に変更する。**
- **clone は base-of-truth を origin(GitHub)に置く(C10)**。host の `~/ghq` ローカルチェックアウトは日常的に origin/main より遅れており(pull 忘れ・別 Mac 作業)、そこから直接 clone すると古い main から分岐して (a) origin で revert 済みコードの復活、(b) 大量 conflict、(c) 古い依存前提の誤修正を生む。対処は次のいずれか:
  - **案 A(推奨: staleness と hardlink を同時解決)**: `GH_TOKEN` による HTTPS で origin(`https://github.com/<repo>`)から直接 clone する。`gh pr create` が動く=コンテナから github.com へ到達可能なはずなので HTTPS clone/fetch も通る想定(§9 #1 で疎通確認)。
  - **案 B(オフライン/速度優先)**: ローカル clone をオブジェクトキャッシュとして使い、直後に `origin` remote を GitHub URL へ張替え → `git fetch origin` → `git checkout -b <work> origin/<default>` で作業ブランチを origin の最新から作る。
  - いずれも「ローカル clone は base-of-truth ではなくキャッシュ最適化」と位置づける。hardlink 由来の権限エラーが懸念される場合は `git clone --no-hardlinks`。default ブランチ名は動的取得する。
- clone 先は新設の rw docker volume `~/.hermes/workspaces`(host)→ `/workspace/jobs`(container)。既存の `/workspace/out`(hermes-out、成果物置き場)とは分離する。
- **manifest-first(C5)**: §5 冒頭の順序に従い、`claude --bg` 起動より **前に** plugin 生成の相関 id で job manifest を書き、起動後に返却 job-id を manifest へ reconcile する。これにより manifest が常に先行し、dispatch 途中 crash 時も watchdog/reaper が回収できる。
- `claude --bg` の指示文には必ず「PR 作成(または `gh pr create --draft`)までで停止し、マージ・force push・保護ブランチへの直接 push は行わない」旨を明記する(既存の `dev-flow` 系運用と同じ不変条件)。ただし指示文は最終防御線ではない(§6 を参照)。

### 5.4 Claude Code セッション状態の永続化と実行オーナーモデル

**実行オーナーモデル(C1 — 撤回・確定)**

- 初版は「dispatch コンテナは `claude --bg` を起動したら即終了してよく、状態はディスク永続化され supervisor が再開時に引き継ぐ」という fire-and-forget を前提にしていた。これは **撤回する**。**状態の永続化(roster/jobs のディスク保存)と実行の継続(LLM ターンを回して clone→edit→test→`gh pr create` を進める live daemon)は別物**であり、`container_persistent: false` でコンテナが teardown されれば daemon は PID ツリーごと kill され、watchdog の `claude agents --json --all` は read-only の状態照会に過ぎず pending turn を実行しない。ディスク上の roster.json は「次に誰かが supervisor を起動したときの再開材料」でしかなく、それ自体はコードを書かない。
- **確定モデル(案 A: 長寿命 per-job コンテナ)**: dispatch コンテナはそのジョブが完了(PR 作成 or failed)するまで生存する。`lifetime_seconds` はジョブ規模に合わせて設定し、watchdog が per-job コンテナを所有・監視して必要なら再起動する。**案 B(watchdog が state を resume して LLM ターンを能動的に駆動する)は採用しない**: 現 watchdog は read-only の `claude agents` 照会しか持たず、state を resume してターンを前進させる機構が未定義=結局 live executor が必要で案 A に帰着する。具体的な resume 機構を設計しない限り B を primary にしない。
- この変更は **4GB コンテナがジョブ全期間(数分〜30分超)常駐する**ことを意味し、メモリ圧が上がる。上限値は「起動即終了」前提より厳しくする必要があるため、§5.6 の同時実行数上限と **必ず同時に設計する**。

**CONFIG_DIR トポロジ(C8)**

- ユーザー本人の `~/.claude`(個人利用)とは **引き続き分離する**。container は root 実行のため、個人の `~/.claude/daemon/roster.json` を直接共有すると uid 不一致や lock 競合、秘匿の問題が生じる。この分離自体は独立に正当なので維持する。
- ただし初版の「**単一 `~/.hermes/claude-state` を全 dispatch コンテナが共有**」は **棄却する**。複数の container-root が同一 roster.json に並行書き込みするのは、分離で避けたはずの多 writer lock 競合・状態破損を高並列で再生産する(C6 の同時実行と重なると悪化)。
- **per-job CONFIG_DIR** を採用: `CLAUDE_CONFIG_DIR=/root/.claude-hermes/<correlation-id>`(host 側 `~/.hermes/claude-state/<correlation-id>`)。roster への同時 writer をジョブごとに 1 に限定する。
- watchdog は単一の `claude agents --all` に依存せず、manifest を走査して各ジョブの CONFIG_DIR / workspace_dir を **個別照会する集約方式**にする(§5.5)。§4 の「`claude agents --cwd $(pwd)` と同じ CLI で確認」は per-job の `CLAUDE_CONFIG_DIR=~/.hermes/claude-state/<id> claude agents --cwd <workspace_dir>` で成立する。
- 残ゲート(§9 #3): container root が書いた `~/.hermes/claude-state/<id>` を host 非 root が `claude agents` で読めるか(bind-mount 越しの uid/権限)は topology では解決しないため実測が必要。macOS Docker Desktop の gRPC-FUSE は uid 変換で host user 所有に見え通る公算が高いが、要確認。

### 5.5 watchdog

- 新設の launchd agent(`com.playpark.hermes-claude-watchdog` 案)として host に常駐。`hermes-gateway` とは独立したプロセスとし、docker コンテナには依存しない(直接 host 上で `claude` CLI と各プラットフォームの通知 API を呼ぶ)。
- **gateway と同一 Mac 常駐 + primary ゲート(C11)**: `~/.hermes/jobs` は gateway 機で生成され、機械間で同期されない。したがって **watchdog は gateway と同一 Mac に常駐することが必須**であり、gateway と同じ `.gateway-primary` marker(または共通の primary 概念)でゲートして、primary 機のみが gateway と watchdog の両方を起動する。これにより複数 Mac で watchdog が走って「自機の `~/.hermes/jobs` を見る前提」が崩れるのを防ぐ。
- **多重 run の排除(C4)**: watchdog は `flock` ベースのロックファイルを取得してから走る。launchd `KeepAlive` + 手動 `kickstart` や、gh/network 遅延で run が実行間隔を超えた場合の多重 run を排除する。
- **冪等な通知(C4)**: manifest スキーマに `status` と `notified_at` を持たせ(§5 の manifest 定義)、`notified_at` が空のジョブのみ POST する。POST 成功後に `notified_at` を記録し `status:"notified"` へ遷移。clone / manifest の削除は **retry-safe な後追い遷移**で行い(`notified` 終端へ遷移してから削除、manifest は最後に削除)、冪等性を delete-after-notify の非原子操作に依存させない。
- **reaper(C5)**: `~/.hermes/workspaces` を走査し、対応 manifest の無い clone を回収する。さらに `claude_job_id` 未 reconcile または `claude agents` に不在の manifest は grace period 経過で `failed` 扱いにして reap する(manifest 書込み後・`claude --bg` 成功前に crash した「manifest あり・job 未起動」の永久 stuck を回収するため。orphan clone 回収だけでは不足)。
- 実行間隔: 3〜5分ごと(初期値、運用しながら調整)。
- 責務: ジョブ状態の確認、完了/失敗通知の送信、clone ディレクトリと job manifest の削除、長時間応答なしジョブのタイムアウト警告。
- 通知送信は Discord Bot Token / Google Chat service account を `.env` から読み、host から直接プラットフォーム API を呼ぶ(docker sandbox のネットワーク制限を経由しないため、§2 で挙げた到達性の懸念はこの経路では発生しない)。
- **承認機構との関係(C13)**: watchdog は hermes の approvals 機構を経由しない独立した host プロセス(launchd)であり、`approvals.mode` の対象外である。

### 5.6 リソース制御と同時実行数(backpressure) (C6)

allowlist + `require_mention` は「誰が」実行できるかを絞るが「どれだけ」は絞らない。1 依頼 = 1 clone + 1 bg ジョブで、重複配送(C4)や 1 依頼→N repo ファンアウト(§7)により並列ジョブが増幅しうる。さらに §5.4 の長寿命 per-job コンテナ化で 4GB×N がジョブ全期間常駐するため、無制限並列は disk(フル clone×N)・memory(Docker Desktop VM/host の OOM)・サブスクリプション枠を同時に枯渇させる。MVP で以下を **必須**とする:

- **グローバル最大同時ジョブ数上限**: in-flight を manifest 数で計数(manifest-first が前提、§5.3)し、超過分は「混雑中」を返信して拒否するか、**有界**キューに入れる(無界キューは作らない)。上限値は長寿命コンテナのメモリ常駐を踏まえ、エフェメラル前提より厳しく設定する(§5.4 と連動)。
- **clone 前ディスク空き容量ガード**: 閾値未満なら clone せず拒否+通知する。§9 #1 のローカル clone hardlink 有無(および HTTPS clone のフルコピー量)の結論をディスク見積りに反映する。

per-user / per-channel のトークンバケット型レート制限は、allowlist が既に actor を有界化している運用実態を踏まえ **MVP 必須にはせず**、濫用が観測された場合の follow-up とする(§10 参照)。

## 6. 安全策

### 6.1 マージ不変条件(「マージは常に人間」)の担保 (C2, C9)

見出しの約束を構成で担保する。初版の「`gh pr merge` 系を許可ツールから除外することも検討する」という曖昧な表現を確定要件に格上げする:

- **サーバ側 branch protection が権威(load-bearing)**: bind 対象 repo の base ブランチに required review 付き branch protection を設定することを **前提条件**とする。push も merge も base への `contents:write` を要するため、feature push を許す PAT は原理的に PR merge も可能で、**token scope 単独ではマージ不変条件を担保できない**。token 最小化は defense-in-depth に留める。可能なら merge 権限を持たない fine-grained PAT / GitHub App installation token(できれば per-job)を割り当てる。
- **denylist の追加**: `container.settings.json` の deny に `Bash(gh pr merge:*)`、`Bash(gh pr review --approve:*)` を追加する。加えて `gh api` 経由の変異防止を等号形/連結形へ拡張する(`gh api --method=POST`、`-XPOST` 等。現状は `--method POST:*` / `-X POST:*` の空白区切りのみで等号形が素通り)。
- **nightly 自動マージの無効化**: 既存 `hooks/allow-pr-merge.sh` は base が `nightly/*` の PR を `permissionDecision:allow` で無人自動マージする。ChatOps コンテナでは専用 hook または env フラグで **この nightly 自動 allow を deny/ask 固定に無害化する**。deny リスト追加だけでは PreToolUse hook の allow と競合して優先順位が版依存になるため、hook 側も必ず無害化する。
- **denylist は best-effort(C9)**: CLI(gh/cobra/pflag)は等号形・field 指定など複数の表記を受理し、`gh api /repos/.../merges -f ...` のように `--method`/`-X` を書かず暗黙 POST になる呼びは列挙型 deny を素通りする。したがって **変異/merge 防止の load-bearing は denylist ではなくサーバ側 branch protection と token 権限**であることを明記し、denylist は hygiene(defense-in-depth)と位置づける。

### 6.2 push 宛先の保護 (C3)

既存 `hooks/allow-feature-push.sh` は `git rev-parse --abbrev-ref HEAD`(=カレント feature ブランチ)で判定しており、push **宛先** refspec を parse していない。エージェントは常に feature ブランチ上で作業するため実質常時 allow になり、`git push origin HEAD:refs/heads/production` 等の保護/デプロイブランチへの直 push が hook auto-allow かつ deny 未該当で通る。

- **hook を宛先 refspec ベースに作り直す**: コマンド中の全 refspec を parse し、宛先が保護対象なら deny、判定不能は ask、それ以外を allow。明示形(`HEAD:refs/heads/x`、`src:dst`、`+force`、`--delete`、`--set-upstream`)だけでなく **暗黙形も網羅する**(`git push origin <branch>`、refspec 無しの `git push`/`git push origin` の `push.default`/`remote.pushDefault` 依存、tag push)。
- 保護対象は設定可能な宛先 denylist とし、`main`/`master`/`dev`/`develop`/`development` に加え `production`/`staging`/`release`/`gh-pages`/`nightly/*` を含める。
- config 駆動 push(`push.default=matching` 等)まで hook で完全網羅するのは困難なため、**push 宛先保護の権威も GitHub branch protection**(hook は defense-in-depth)とし、deploy ブランチにも branch protection を要求する。

### 6.3 発火制御・allowlist

- **発火制御**: Discord は `require_mention: true`、Google Chat は allowlist されたメールアドレスのみ。誤爆・雑談による意図しない実行やコスト発生を防ぐ。
- **投稿可否の allowlist**: `DISCORD_ALLOWED_USERS` / `GOOGLE_CHAT_ALLOWED_USERS` を必須運用とする。

### 6.4 重複配送・冪等化

- **inbound 冪等化(C4)**: 冪等鍵はプラットフォーム event/message id(Pub/Sub message_id / Chat event id / Discord message id)とし、claude_runner plugin が job-id とは独立の **永続・有界(TTL/上限)な seen-set** で dedupe する。「hermes 本体が webhook 重複を吸収する前提」は Pub/Sub の at-least-once 保証と衝突するため **撤回**する。seen-set は per-machine のため、複数 Mac 間の重複は §5.5 の primary ゲート(手動 marker)で防ぐ(cross-Mac の唯一の dedupe。最悪でも重複 PR で人間 merge のため許容、C11)。
- **完了通知の冪等化(C4)**: §5.5 の `notified_at`/`status` + flock による(前述)。

### 6.5 path_guard の適用範囲 (C9)

- `path_guard` plugin は **hermes 自身のツール呼び出し(`terminal` 等)のみ**を `pre_tool_call` で監視する。hermes が `claude --bg` を起動すると、実作業の Bash は `claude` プロセスの子として別プロセスツリーで spawn され、hermes のツール呼び出しではないため、**path_guard は dispatch された inner Claude のコマンドをほぼ確実に監視しない**。よって path_guard を「inner Claude(dispatch 作業)の防御層」として数えるのをやめる。
- inner Claude の実ガードは `/root/.claude/settings.json` にマウントされる `container.settings.json` の denylist + PreToolUse hooks のみである。inner への追加ガードが要る場合は、既に mount 済みの inner 用 PreToolUse hook に投資する。

### 6.6 監査と attribution (C12)

- 現状 `container.settings.json` の `attribution.commit`/`attribution.pr` は空で、`config.yaml` は `GIT_AUTHOR_NAME`/`EMAIL` に人間本人の値を forward する。このままでは bot 生成の commit/PR が本人名義になり、「人間がマージする」設計なのにレビュアーが bot 自律生成か判別できず、インシデント時のフォレンジックも本人操作と切り分けられない。
- ChatOps コンテナ向けに:
  1. attribution を **bot マーカー付き**にする(`Co-Authored-By` に machine identity、または「Generated via hermes ChatOps」の PR trailer を有効化)。
  2. `gh pr create` 時に識別ラベル(例: `chatops-bot`)を付与する。
  3. watchdog/plugin に **監査ログ**を追加し `{chat message id, requester, job-id, repo, PR URL, timestamp}` を永続記録する。
  4. bot commit の author/committer を人間本人ではなく **専用 machine identity** にする(`GIT_AUTHOR_*` を bot identity へ)。

### 6.7 dispatch の承認フロー・タイムアウト (C13)

- **dispatch ツールの承認**: `claude_runner` の dispatch(`terminal` 経由の clone / `claude --bg` 起動)は、hermes 承認上 **明示的に auto-approve / allow-list** と規定する(ゲートは allowlist + `require_mention` で上流に、inner は自前ガードで担保)。`approvals.mode:smart` / `timeout:60` の下で、非同期 ChatOps(ユーザー非在席)の 60s 無応答時に dispatch がハング/自動 deny しないことを明記する。
- **時間制約**: dispatch(clone + `claude --bg` 初期化)が `terminal.timeout:600` 内に収まることを要件化する。大 monorepo で超過しうる場合は clone を独立ステップに分割するか当該ツールの上限を引き上げ、超過時も §5.3 の manifest-先行順序で orphan 化(C5)を防ぐ。
- **cron**: 本設計に cron トリガ経路は無いため、`cron_mode:deny` との相互作用は **N/A**(対応不要)。

### 6.8 bypass permissions mode の確認 (C16)

- `container.settings.json` の `disableBypassPermissionsMode: "disable"` は Claude Code の **正規の設定値**であり(個人 `claude-code/settings.json` と container 双方で同一に使われる確立パターン)、意味は「bypass permissions mode を無効化する(=`--dangerously-skip-permissions` を封じる)」である。二重否定でも危険設定でもなく、値は変更しない。誤読を避けるため近傍または README に「`disableBypassPermissionsMode:"disable"` は bypass mode を封じる正しい値」の一文コメントを付す。
- 保険として、`tests/hermes-image-smoke.sh` に「コンテナ内で `--dangerously-skip-permissions` が拒否される / denylist が honored される」アサーションを追加し、意図を回帰テストで固定する(§9 #7)。

## 7. エラーハンドリング

- **未 bind チャンネルからの依頼**: 実行せず、bind 方法を案内する返信のみ。schema/parse 失敗の bind は §5.2 の fail-closed に従い拒否+通知する。
- **clone/dispatch 失敗**: hermes がその場でチャットにエラーを返信。ただし manifest-first(§5.3)により manifest は先に存在するため、失敗時は `status` を `failed` に落として watchdog/reaper が回収・通知・cleanup できるようにする(「manifest を書かない」設計は orphan と不可視化を招くため撤回)。
- **`claude --bg` セッションが `failed` になった場合**: watchdog が失敗内容(ログの要約)をチャットに通知し、clone と manifest を(retry-safe な後追い削除で)cleanup する。
- **orphan / stuck ジョブ**: §5.5 の reaper が回収する(対応 manifest の無い clone、`claude_job_id` 未 reconcile / `agents` に不在の manifest の grace-period 経過 failed 化)。
- **watchdog が見つけられない/タイムアウトしたジョブ**: 一定時間(初期値90分)応答のない job manifest は「応答なし」警告をチャットに出し、人手での `claude agents --json --cwd <workspace_dir>`(per-job `CLAUDE_CONFIG_DIR`)による調査を促す。自動削除はしない(調査のため残す)。
- **複数リポジトリにまたがる1依頼**: 1 依頼 = 1 repo = 1 job に正規化する。該当チャンネルに複数 repo が bind されている場合は依頼ごとに job を複数ファンアウトし、それぞれ独立して通知・cleanup する。**ただしファンアウトは §5.6 の同時実行上限の対象に含める**(単一メッセージで並列ジョブを無制限に増幅させない)。

## 8. ロールアウト計画

1. **Phase A(dispatch の実装)**: `claude_runner` plugin の最小版(単一リポジトリ、manifest-first → origin 基準 clone → `claude --bg` → job-id reconcile)を実装し、既存の Slack 接続で動作確認する。worktree ではなく clone 方式が実際に動くことをまず確認する。
2. **Phase B(実行モデルの go/no-go ゲート)**: §9 #2 を検証する。すなわち「**dispatch を起動したコンテナを kill した後にジョブが前進し PR が生成されるか**」を実機で確認する。ここは単なる「見えるか」の確認ではなく **go/no-go ゲート**であり、否定結果(コンテナ kill でジョブが凍結する)は「実装可能な調整」ではなく **設計ブロッカー**として扱い、§5.4 の長寿命 per-job コンテナモデル(案 A)が必須であることを確定する。あわせて分離 per-job `CLAUDE_CONFIG_DIR` mount が機能するかを確認する。
3. **Phase C(watchdog の実装)**: launchd agent として実装し、flock・完了検知・冪等通知(`notified_at`)・cleanup・reaper・タイムアウト警告を通す。Slack のみでエンドツーエンド(依頼→受付→完了通知→cleanup)を通す。primary ゲート(gateway 同一 Mac)も組み込む。
4. **Phase D(repo binding の複数化)**: `repo_bindings.yaml` を複数リポジトリ対応(schema 検証 + fail-closed)にし、ファンアウトを実装する。同時実行上限・ディスクガード(§5.6)を有効化する。
5. **Phase E(Discord / Google Chat 追加)**: §5.1 の手順でプラットフォームを追加し、allowlist・mention 制御・inbound 冪等化(seen-set)を有効化してから展開する。

## 9. 未検証事項(実装前に確認すべきもの)

| # | 項目 | 検証方法 |
|---|---|---|
| 1 | origin(GitHub)からの clone/fetch がコンテナから疎通するか(`gh pr create` が通るなら HTTPS clone も通る想定)。ローカル clone を使う場合の hardlink 由来権限エラー・フルコピー時のディスク量。結論は §5.3/§5.6 のディスク見積りに反映する (C10, C6) | `docker run` で `git clone https://github.com/<repo>` を試し、案 B の場合はローカル clone→fetch→checkout を実行。`--no-hardlinks` 要否も確認 |
| 2 | **(go/no-go ゲート)** dispatch を起動したコンテナを kill した後に、ジョブが前進し PR が生成されるか (C1) | dispatch 起動後にコンテナを明示 kill し、clone→edit→test→`gh pr create` が完走するか実機確認。否定結果は設計ブロッカー(§8 Phase B)として扱い、長寿命 per-job コンテナ案 A を必須化 |
| 3 | 同時ジョブ下で、container root が書いた `~/.hermes/claude-state/<id>` を host 非 root が per-job `claude agents` で読めるか(bind-mount 越しの uid/権限・整合性) (C8) | per-job CONFIG_DIR を mount し、複数ジョブ並行下で host 側から読み取り/照会テスト |
| 4 | hermes-agent の **ack 戦略**(ack-after-process か即時 ack か)と dedupe 実装有無。ack-after-process なら dispatch を即時 ack/非同期化する (C4) | hermes-agent のソース/ドキュメント確認、および同一 message id を再送して二重 dispatch が起きないか実機確認 |
| 5 | path_guard が container 内 inner Claude の tool 呼び出しを監視するか(**しない前提**でガード配置を設計する) (C9) | 実機で inner Claude の Bash に対し pre_tool_call が発火しないことを確認 |
| 6 | Google Chat の Pub/Sub 経路のレイテンシ(受信までの遅延) | 実機での実測 |
| 7 | headless(`skipAutoPermissionPrompt:true` / `defaultMode:auto` / 応答 TTY 無し)で PreToolUse hook の `ask` がハング/自動 proceed/自動 deny のどれに倒れるか。proceed/ハングは設計ブロッカー扱い (C2)。あわせてコンテナ内で `--dangerously-skip-permissions` が拒否され denylist が honored されることを smoke test で固定 (C16) | `claude --bg` headless で `ask` を返す操作を実行し解決先を実測。`tests/hermes-image-smoke.sh` に回帰アサーション追加 |
| 8 | `claude --bg` が返す job-id と `claude agents --all` が列挙する id の表記が一致するか(manifest reconcile / 状態相関の前提) (C5) | `claude --bg` の返却値と `claude agents --all` の列挙 id を突き合わせ |
| 9 | Discord / Google Chat で同一 token/subscription を 2 接続した際の受信挙動(Google Chat Pub/Sub は competing-consumer で分割/取り合い=取りこぼしになりうる、Discord は複数 gateway session が両方受信=真の二重 dispatch) (C11) | 2 接続を実際に張り、受信の重複/欠落を観測 |

## 10. 非対象(Out of scope)

- 自動マージ、force push、保護ブランチへの直接 push の自動化。
- チャット上でのリアルタイムなストリーミング進捗表示(「受付」「完了」の2点通知に割り切る)。
- Slack 以外のプラットフォームでの hermes 初回導入作業そのもの(既に導入済みの Slack 実装を土台とする)。
- **自動 leader election / 自動 failover**(C11): gateway/watchdog の二重起動防止は手動 `.gateway-primary` marker + co-location ゲートで担保し、leader election は作らない。
- **per-user / per-channel レート制限**(C6): allowlist が actor を有界化している運用実態を踏まえ MVP 非対象。**濫用が観測された場合の follow-up** としてトークンバケット型を追加する(グローバル同時ジョブ数上限とディスクガードは §5.6 で MVP 必須)。

## 11. 未解決の懸念(実装前に解決すべき既知の残課題)

以下はレビューで **resolved に至らなかった**懸念であり、擁護側の proposed_fix を実装しても load-bearing な穴が残ると判定された。**実装前に本節を解決すること**を必須とする。

### C7. 資格情報の blast radius と exfil(未解決 / critical)

chat 由来の自然言語がそのまま `claude --bg` に渡り root コンテナで実行される設計上、cloneした repo 内容(README/issue/コード内の指示文)による **prompt injection を前提**に置く必要がある。この前提の下で、当初の修正案(path_guard に `.config/gws/` 追加 + telegram reply 削除 + token 最小化)では次の穴が残る:

1. **gws 資格情報の保護が実質無効**: `path_guard` は inner Claude のツールを監視しない(C9/§6.5 で確定)ため「path_guard に `.config/gws/` を追加」は実脅威に効かない。かつ `container.settings.json` の `Read(./.config/gws/**)` は cwd(`/workspace/jobs/<id>`)相対で、実マウント `/root/.config/gws` に一致しない(既存 `Read(./.config/gh/**)` も同理由で既に無効の疑い)。さらに `Read` deny は `Bash(cat/head/od /root/.config/gws/token.json)` を塞がない(`cat` 等は deny 外、gws は `:rw` マウント)。→ **唯一有効な対策は、Google Workspace 資格情報を必要としない inner ジョブに対し `~/.config/gws:/root/.config/gws:rw` を `docker_volumes` から削除し、そもそも mount しないこと。**
2. **WebSearch が exfil 経路として allow に残存**: `curl`/`wget`/`nc`/`ssh` を deny しても、`container.settings.json` の allow に残る `WebSearch`(および `mcp` reply 系)は許可された egress であり、injection 前提では読み取った秘密をクエリに載せて持ち出せる。denylist では原理的に塞げない。→ **WebSearch を allow から削除するか、明示的に脅威として受容し監視する(どちらかを決める)。**
3. **push 経路の exfil**: `GH_TOKEN` を repo scope に絞っても、mount された他の秘密(gws token / OAuth token)を commit → bind repo に push すれば流出する。push 可能な token は必然的に流出経路になるため、対策は token scoping ではなく「**in-container で読める秘密を最小化する**」ことである。
4. **前提の明文化**: `env`/`echo $GH_TOKEN` はシェル展開で deny 列挙を素通りし、`posttool-secret-mask` は既知パターンのみで base64/novel format を取りこぼす。したがって「**in-container で読める秘密はすべて exfil されうる**」を前提とした資格情報最小化と egress 最小化が制御の主軸であり、denylist は補助に過ぎない。`GH_TOKEN` の 3 org 横断(playpark-llc / it-all-playpark / Cistree-dev)や `additionalDirectories` による 3 org 全 ro ツリー可視化は、bind repo を超えた blast radius を生むため、per-repo credential scoping と read scope の限定(そのジョブの clone + 明示的依存のみ)を要する。

**要決定事項(実装前)**: (a) gws mount の削除、(b) WebSearch の削除 or 明示受容、(c) fine-grained PAT / GitHub App installation token(可能なら per-job)への移行と `additionalDirectories` の廃止/限定、(d) `container.settings.json` に脅威モデル節を設け「denylist は best-effort、制御の主軸は資格情報最小化 + egress 制限、prompt injection を前提とする」と明記すること。これらが揃うまで Discord/Google Chat への一般展開(§8 Phase E)は行わない。
