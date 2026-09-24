# claude-code

[Claude Code](https://docs.claude.com/en/docs/claude-code) の設定を dotfiles で管理する。
home-manager の `activation.setupClaudeCode` が `~/.claude/` 配下に symlink を張る。

`claude-code` バイナリ自体は mise で管理（`home-manager/home/file/mise/config.toml` の
`"npm:@anthropic-ai/claude-code"`）。本ディレクトリは設定のみを扱う。

## ファイル構成

```
claude-code/
├── README.md             # このファイル
├── CLAUDE.md             # global Claude Code instructions（PRINCIPLES.md / RULES.md を import）
├── PRINCIPLES.md         # ソフトウェアエンジニアリングの原則
├── RULES.md              # 振る舞いのルール（priority / workflow / safety / git 等）
├── settings.json         # permissions（allow/deny）+ hooks 設定 + env
├── skill-config.json     # it-all-playpark/skills の per-skill デフォルト値
├── account-map.json      # gh / gcloud / tofu の org → アカウントマップ（bin/account-exec が読む）
├── bin/                  # gh / gcloud / tofu の cwd 連動アカウント shim（account-exec + symlink の gh / gcloud / tofu）
└── hooks/                # SessionStart / PreCompact / Pre|PostToolUse スクリプト
```

`PRINCIPLES.md` / `RULES.md` はかつて SuperClaude framework の一部として導入したが、
framework 自体は使っていない。今は普遍的なガードレールとしてのテキストのみを残し、
`CLAUDE.md` から `@PRINCIPLES.md` / `@RULES.md` で import している。

## activation

`home-manager/home/default.nix` の `activation.setupClaudeCode` が以下を実施する:

1. `~/.claude/` ディレクトリ作成（無ければ）
2. `settings.json` を symlink
3. `CLAUDE.md` / `PRINCIPLES.md` / `RULES.md` / `FLAGS.md` / `README.md` を symlink（存在するもののみ）
4. `MCP_*.md` / `MODE_*.md` ファイルがあれば symlink
5. `hooks/*.{py,sh}` を `~/.claude/hooks/` に symlink（`*.test.sh` は除外）
6. `bin/*` を `~/.claude/bin/` に symlink（`*.test.sh` は除外。`bin/gh` / `bin/gcloud` / `bin/tofu` は repo 内で
   `account-exec` への symlink なので `~/.claude/bin/gh` → `bin/gh` → `account-exec` の 2 段になる）
7. `account-map.json` を `~/.claude/account-map.json` に symlink

`skills/` は `scripts/setup-skills.sh` で別管理（`setup.sh` から呼び出される）。
activation 側では触らないので、既存の symlink を壊さない。

```bash
nix run .#update
```

## gh / gcloud / tofu アカウント shim

設計: `docs/specs/2026-09-19-claude-account-env-design.md`

gh と gcloud を複数アカウントで使い分けるとき、`gh auth switch` / `gcloud config configurations activate` /
`gcloud auth application-default login` はグローバル状態（`~/.config/gh/hosts.yml` /
`~/.config/gcloud/active_config` / `~/.config/gcloud/application_default_credentials.json`）を書き換えるため、
並列セッションや dev-flow の subagent が別 org で動くと互いに壊し合う。`bin/account-exec` は
**グローバル状態を一切切り替えず**、コマンドを実行した cwd から使うアカウントを決める PATH shim。

### 仕組み

```
Bash: gh pr create …  (cwd=~/ghq/github.com/BusinessProcessDX/repo/.claude/worktrees/x)
  └─ ~/.claude/bin/gh → claude-code/bin/gh → account-exec
       ├─ $PWD（不一致なら pwd -P）から org=BusinessProcessDX を取る
       ├─ ~/.claude/account-map.json の .orgs[org] を jq で引く
       ├─ GH_CONFIG_DIR=~/.config/gh-th-it-dev を export
       └─ exec ~/.nix-profile/bin/gh pr create …
            （PATH から shim dir を除いて解決した実体。exec 先の PATH は元のまま）
```

ツールごとに付ける env:

| ツール | env | マップのキー |
|---|---|---|
| `gh` | `GH_CONFIG_DIR=<dir>` | `gh_config_dir` |
| `gcloud` | `CLOUDSDK_CONFIG=<dir>` | `gcloud_config_dir` |
| `tofu`（`terraform` 名も可） | `GOOGLE_APPLICATION_CREDENTIALS=<dir>/application_default_credentials.json` | `gcloud_config_dir` |

gcloud は構成名（`CLOUDSDK_ACTIVE_CONFIG_NAME`）ではなく **config dir ごと**分離する。ADC
（`application_default_credentials.json`）は構成をまたいでグローバルなので、dir を分けないと
`gcloud auth application-default login` が他 org の ADC を上書きし、tofu / クライアントライブラリが
別アカウントで GCS 等を叩いて 403 になる。tofu（Go の `x/oauth2`）は `CLOUDSDK_CONFIG` を見ず
`~/.config/gcloud/` 固定で ADC を探すため、`GOOGLE_APPLICATION_CREDENTIALS` でファイルを明示する。

- `~/.claude/bin` は home-manager が zsh（`envExtra`）/ fish（`shellInit`）の PATH 先頭に載せる。
  `which gh` / `which gcloud` / `which tofu` は `~/.claude/bin/…` を指すようになる。Claude Code セッション内では加えて
  SessionStart hook `session-start-account-path.sh` が `$CLAUDE_ENV_FILE` に同じ export を書き、
  起動元の PATH に依存せず shim が効くようにする
- 同じスクリプト内で `cd org1 && gh …; cd org2 && gh …` としても各呼び出しが独立に解決される。
  `git push`（https）の credential helper `gh auth git-credential` も git が chdir 済みなので同じ dir で解決される。
  `pnpm tf:init:stg` のような `cd infrastructure/terraform && tofu init …` も repo 内に留まるので同じ org で解決される
- **明示指定は素通し**: `GH_CONFIG_DIR=… gh …` / `CLOUDSDK_CONFIG=… gcloud …` /
  `GOOGLE_APPLICATION_CREDENTIALS=… tofu …` のように対象 env が既に set なら判定しない
  （サービスアカウント鍵の明示指定もこれで通る）。実体を直接叩きたいときはこれか `~/.nix-profile/bin/gh`
- **fail-open**: マップ不在 / JSON 不正 / `jq` 不在 / 値に `'` や改行 を含む場合は env を付けずに実体へ
  passthrough し、stderr に `account-exec: …` を 1 行出す。ghq 外（`~/ghq/github.com/<org>/` にも
  `~/ghq/github.com-<alias>/<org>/` にも無い cwd）や未登録 org は無言で passthrough（既定のグローバル状態のまま）
- 実体が PATH に無い、または解決先が shim 自身なら exit 127（無限再帰しない）
- `ACCOUNT_EXEC_DEBUG=1 gh …` で判定結果（org / 付けた env / exec 先）を stderr に 1 行出す

### マップの編集（`account-map.json`）

```json
{
  "orgs": {
    "BusinessProcessDX": { "gcloud_config_dir": "~/.config/gcloud-th-it-dev", "gh_config_dir": "~/.config/gh-th-it-dev" },
    "it-all-playpark":   { "gcloud_config_dir": "~/.config/gcloud",           "gh_config_dir": "~/.config/gh" }
  }
}
```

- キーは `~/ghq/github.com/<org>/` の `<org>`。SSH host alias（`~/.ssh/config` の `Host github.com-<alias>`）
  経由で `ghq get` した `~/ghq/github.com-<alias>/<org>/` も同じ `<org>` で引く。
  `gh_config_dir` / `gcloud_config_dir` は両方 optional で、
  無いキーは env を付けない（gcloud を使わない org は `gcloud_config_dir` を省略する）
- 値の先頭 `~` だけ `$HOME` に展開する。それ以外の展開はしない
- `gcloud_config_dir` は gcloud の config dir（既定 `~/.config/gcloud` に相当）。tofu はこの dir 直下の
  `application_default_credentials.json` を使う
- dir の存在や妥当性は shim では検証しない（gh / gcloud が「未ログイン」、tofu が「ファイルが無い」を正しく言う）
- 編集後は `nix run .#update` 不要（`~/.claude/account-map.json` は symlink）。`nix fmt` がキーをソートする

### 初回セットアップ（人間の作業）

```bash
gh auth logout -h github.com -u th-it-dev            # ~/.config/gh から失効エントリを除去
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login    # 分離 dir に th-it-dev を再ログイン
nix run .#update                                      # symlink / PATH / settings を反映
exec $SHELL -l                                        # PATH を取り直す

# gcloud: 分離 dir にログイン（shim が cwd から CLOUDSDK_CONFIG を付けるので cd してから）
cd ~/ghq/github.com/BusinessProcessDX/<repo>
gcloud auth login                                     # → ~/.config/gcloud-th-it-dev/
gcloud config set project th-all
gcloud auth application-default login                 # → ~/.config/gcloud-th-it-dev/application_default_credentials.json
cd ~/ghq/github.com/playpark-llc/<repo>
gcloud auth application-default login                 # ~/.config/gcloud/ の ADC が別アカウントで上書きされていたら戻す
gcloud config configurations delete th-it-all         # 旧構成（~/.config/gcloud 内）は不要になったので消す（任意）
```

確認:

```bash
cd ~/ghq/github.com/BusinessProcessDX/<repo>   # SSH alias 運用なら ~/ghq/github.com-<alias>/BusinessProcessDX/<repo>
which gh                      # → ~/.claude/bin/gh
gh auth status                # → th-it-dev
gcloud config list            # → account th.it.dev@…（~/.config/gcloud-th-it-dev/）
ACCOUNT_EXEC_DEBUG=1 tofu version   # stderr: GOOGLE_APPLICATION_CREDENTIALS=…/gcloud-th-it-dev/application_default_credentials.json
cd ~/ghq/github.com/it-all-playpark/dotfiles
gh auth status                # → it-all-playpark
gcloud config list            # → account yuji.naramoto@…（~/.config/gcloud/）
```

### 既知の限界

- `GH_CONFIG_DIR` / `CLOUDSDK_CONFIG` を分けると `config.yml` / `configurations/`（alias, editor, project 等）も
  dir ごとに独立する。共有したくなったら該当ファイルだけ symlink する
- shim が env を付けるのは `gh` / `gcloud` / `tofu`（と `terraform` 名）だけ。他のクライアント
  （gsutil、各言語の SDK を直接使うスクリプト等）は env が付かないので既定の `~/.config/gcloud/` を探す。
  必要になったら `bin/<tool>` symlink と `case` を足す
- shim は毎回 `jq` を起動する（数 ms、gh / gcloud 自体の起動時間に埋もれる）
- ghq 外に clone した repo では判定できず既定のまま

テスト: `bash claude-code/bin/account-exec.test.sh`（shim、16 ケース / 20 assertion）、
`bash tests/claude-bin-symlink.test.sh`（activation の symlink ロジック）。
`bin/account-exec` は拡張子が無いため pre-commit の shellcheck 対象外。変更時は
`nix develop -c shellcheck claude-code/bin/account-exec` を手で回す。

## hooks

`settings.json` の `hooks` セクションで wire し、`~/.claude/hooks/` にある実体スクリプトを呼ぶ。

dev-flow / skills 共通の hook（inline 生成区間ガード、inline 同期チェック、dev-flow telemetry、
コンテキスト浪費ガード、secret マスク、SKILL.md frontmatter 検証、skill 使用ログ、zombie-kill）は
it-all-playpark/skills#572 で plugin（`dev-flow` / `playpark-core` / `playpark-skills`）の
`hooks/hooks.json` へ移植済みで、`${CLAUDE_PLUGIN_ROOT}` 経由で発火する。ここに残るのは
マシン固有の hook に加え、`UserPromptSubmit`（plugin 側に移植先が無いため維持。下記参照）。

| イベント | スクリプト | 役割 |
|---------|----------|------|
| `SessionStart` (startup / resume / compact) | `session-start-replay.sh` | 直近の作業状態を再表示 |
| `SessionStart` (*) | `session-start-account-path.sh` | `~/.claude/bin`（gh / gcloud shim）を `$CLAUDE_ENV_FILE` 経由でセッション PATH 先頭に追加。Claude Code の Bash は起動プロセスの PATH snapshot を使い rc を読み直さないため、rc 側の PATH 追加だけでは desktop app / bg job 起動で欠けることがある |
| `PreCompact` | `pre-compact-dump.sh` | compact 前に session 状態を `claudedocs/session-*.md` へ退避 |
| `PreToolUse` Bash (`git push*`) | `allow-feature-push.sh` | protected branch への push を抑止 |
| `PreToolUse` Bash | `pretool-bash-credential-guard.sh` | prod credential を含むコマンドを `ask`。1 段目は正規表現（`$PROD_*` / `.env.prod*` / `aws --profile *prod*`）、2 段目は字面で候補（cloud CLI / DB クライアント / `--context` 等 / prod・live・deploy 語）に絞った上で Jev に「本番に触るか」を判定させ p ≥ 0.7 で `ask`。判定は `~/.claude/logs/credential-guard.jsonl` に記録 |
| `PreToolUse` Bash | `pretool-gh-pr-self-approve-guard.sh` | `gh pr review --approve` による PR self-approve を deny（merge/approve は常に人間） |
| `PreToolUse` Bash | `pretool-gh-compound-guard.py` | gh / git の通信系（push・pull・fetch・clone・ls-remote）を含む複合コマンドのうち、harness が sandbox 内に戻す形（除外対象外のコマンドとの連結、`cd X &&`、`VAR=x` 前置、ファイルへのリダイレクト、`$(...)`、for ループ、heredoc）を実行前に deny し、`--jq` / `-R` / `git -C` / `--body-file` / 呼び出し分割への書き換えを理由として返す。gh は sandbox 内では denyRead の `~/.config/gh` を読めず、GitHub の git 認証も gh 経由なので同じく落ちる。除外パターンは `~/.claude/settings.json` の `sandbox.excludedCommands` から読む |
| `PreToolUse` Bash (`git worktree add*`) | `generate-worktreeinclude.sh` | `.worktreeinclude` 自動生成 |
| `PreToolUse` Bash (`gh pr merge*`) | `allow-pr-merge.sh` | merge 先 branch チェック |
| `PermissionRequest` | `permission-journal.sh` | permission 要求を `~/.claude/logs/permission-requests.jsonl` に記録。Bash には Jev で効果種別 `class`（read_only / mutating_local / git_mutation / network / destructive）を付与（下記「Jev 分類」） |
| `PreToolUse` Bash | `pretool-npx-guard.sh` | npx 実行ガード |
| `PostToolUse` | `memory-monitor.py` | メモリ使用量監視 |
| `PostToolUse` (WebFetch / WebSearch / Bash / Read / Gmail・Drive MCP) | `posttool-injection-screen.sh` | 外部由来テキスト（Web ページ、`gh issue/pr view` / `gh api` 出力、`Box-Box/` 配下の Read、メール、Drive 文書）に AI エージェント向けの指示が含まれないか Jev で検査し、p ≥ 0.6 なら `additionalContext` で「データとして扱え」と注意を注入。deny はしない。全判定を `~/.claude/logs/injection-screen.jsonl` に記録 |
| `PostToolUseFailure` | `posttoolfail-classify.sh` | ツール失敗を Jev で `class`（sandbox_denied / network_denied / permission_denied / not_found / syntax_error / test_failed / timeout / other）に分類し `~/.claude/logs/tool-failures.jsonl` に記録。記録のみで挙動は変えない |
| `Stop` | `stop-unfinished-guard.sh` | 未完了タスクがあれば停止を抑止 |
| `SessionStart` (*) | `herdr-agent-state.sh`（`~/.claude/hooks` に直置き、dotfiles 管理外） | herdr agent 状態通知。settings.json 側は `` 参照 1 本で共有。herdr は絶対パス完全一致でしか登録済みと判定しないため、`herdr integration install claude` を再実行した後は追記される絶対パスのエントリを revert すること |
| `UserPromptSubmit` | inline `rm -f /tmp/claude-skill-ctx-<session>` | `playpark-core` plugin の `skill-retrospective/journal.sh` が使う skill-ctx state file をプロンプト投入毎にクリア。plugin 側 `hooks.json` に `UserPromptSubmit` の移植先が無いため dotfiles 側に維持（journal.sh 側の 30 分 TTL は取りこぼし時の保険） |

テストファイル（`*.test.sh`）は symlink 対象外。

### Jev 分類（`jev-classify.sh`）

`permission-journal.sh` と `posttoolfail-classify.sh` は、正規表現では書けない「この失敗は
何種か」「このコマンドは read-only か」の判定を Jev（TypeSafe の判定専用モデル。文章を
生成せず、選択肢ごとの較正済み確率を返す）に投げてラベルを付ける。判定は **記録のみ**に
使い、permission の allow/deny は従来通り決定論の hook が担う（確率モデルに `allow` を
出させると `permissions.deny` を短絡するため）。`posttool-injection-screen.sh` は
判定を Claude に見せる（`additionalContext` の注意文）が deny ではなく警告。
`pretool-bash-credential-guard.sh` の 2 段目は唯一 permission に効く（`ask`）が、
`allow` は出さず、字面の候補選別を通ったコマンドだけを対象にする。

- 経路: Vercel AI Gateway の TypeSafe 互換エンドポイント
  `https://ai-gateway.vercel.sh/typesafe/v1/systemone` を `curl` で直叩き。jevctl / Node 不要。
  課金は AI Gateway（list price そのまま、markup 0、入力 $0.042/M tokens、出力無料。
  1 判定 ≈ 300〜1500 tokens）
- 鍵: macOS Keychain から読む（Claude の Bash 環境に env で露出させない）
  ```bash
  security add-generic-password -s vercel-ai-gateway -a claude-hooks -w 'vck_…'
  ```
  `AI_GATEWAY_API_KEY` env があればそちらを優先（テスト・一時上書き用）
- fail-open: 鍵なし・timeout（既定 2 秒）・API エラー時は `class` を付けずに記録する。
  `JEV_DISABLE=1` で完全停止。`JEV_DEBUG=1` で失敗理由を stderr に出す
- `--redact` で送信前に token / password / api-key 系の値（`KEY=v` / `key: v` / `--password v` /
  `Bearer v`）と既知の鍵プレフィックス（`vck_` `ghp_` `sk-` 等）を伏せる。散文は触らない。
  AI Gateway はプロンプトを保持しないが、上流の扱いが気になるなら Gateway 側で ZDR を有効にする
- `permission-summary.sh --suggest` は Bash について `class == read_only` のものだけを allow 候補にする
- injection 検査の閾値は `INJECTION_SCREEN_THRESHOLD`（既定 0.6）、Read の対象パスは
  `INJECTION_SCREEN_READ_PATHS`（`:` 区切り、既定 `~/Library/CloudStorage/Box-Box`）
- credential guard 2 段目は `CREDENTIAL_GUARD_JEV=0` で無効化、閾値は
  `CREDENTIAL_GUARD_JEV_THRESHOLD`（既定 0.7）

テスト: `bash claude-code/hooks/jev-classify.test.sh` / `permission-journal.test.sh` /
`permission-summary.test.sh` / `posttoolfail-classify.test.sh` / `posttool-injection-screen.test.sh` /
`pretool-bash-credential-guard.test.sh`（PATH 先頭の偽 `curl` で応答を差し替え、ネットワークには出ない）。

## settings.json の方針

- `permissions.allow`: 標準ツール（Read/Write/Edit/Bash/Task* など）と MCP ツールを明示的に許可
- `permissions.deny`: protected branch への push、危険な `gh api` / `git reset --hard` / `rm -rf` 等を遮断
- `permissions.additionalDirectories`: ghq の主要 workspace を予め通す
- `hooks`: 上記表の通り

permission を追加するときは、まず deny ルールに引っかからないか確認すること
（deny は allow より優先される）。

## skill-config.json

`it-all-playpark/skills` リポジトリの skill が読み込む per-skill デフォルト値。
ブログ系（`blog-fact-check` / `blog-seo-improve` / `blog-internal-links` 等）の閾値や、
`sales` skill のテンプレート文面などを集約している。

機密情報は **入れない**（このファイルは public repo にコミットされる）。
シークレットは各 skill が `~/.config/<skill>/` 等から個別に読む方式にする。

## skills のセットアップ

skills 本体は別 repo（[it-all-playpark/skills](https://github.com/it-all-playpark/skills)）で管理される。
skills#571 以降は `plugins/{playpark-core,dev-flow,playpark-skills}` の 3 plugin 構成。

全ホスト共通で `settings.json` の `extraKnownMarketplaces.playpark`（GitHub source
`it-all-playpark/skills`、既定ブランチ main）から 3 plugin を copy mode で入れ、`enabledPlugins` で
`playpark-core@playpark` / `dev-flow@playpark` / `playpark-skills@playpark` を有効化している。
skills の plugin は `version` を持たない（skills#722）ので git commit SHA が version になり、
main への commit がそのまま更新として配布される。skills repo を checkout できないホストでも
main に追随できるよう、旧 link mode の inline marketplace `playpark-local` は廃止した
（同名 plugin を両方有効化すると `dev-flow:` 名前空間が衝突するため併用しない）。
ローカル checkout の未 merge の変更は plugin には反映されない（merge 後に auto-update で届く）。

自動追随のための設定と前提:

- `env.FORCE_AUTOUPDATE_PLUGINS=1`: `DISABLE_AUTOUPDATER=1`（本体は mise で固定）は plugin の
  auto-update も止めるため、plugin だけ更新を有効に戻す
- `autoUpdate: true` は managed settings でしか効かないため、user settings には書けない。
  各マシンで一度 `/plugin` → Marketplaces → `playpark` の auto-update を有効化する
- GitHub 由来の plugin は起動時に自動 install されない。各マシンで一度 install する（下記導入手順）
- auto-update は起動後 0〜10 分の遅延で走り、`/reload-plugins` か次回起動で反映される

`bin/` の bare 名（`journal` / `secfloor-classify` 等）は Claude Code が plugin の `bin/` を
PATH に載せることで解決する。`sandbox.excludedCommands` には bare 名を登録し、
`~/.claude/skills/*` 系 glob は撤去済み（issue #179）。gh を内部で呼ぶ skill スクリプトを
パス指定で起動する形は、plugin cache（`~/.claude/plugins/cache/playpark/*`）と skills の
checkout / `skills-wt/` の両方を bare / `bash` / `python3` の 3 形で登録している。

hooks の `journal.sh` / `zombie-kill.sh` 参照 3 箇所は skills#572 で plugin の hooks.json へ
移植済み。dotfiles 側の重複 entry と `claude-code/hooks/` の移植済みスクリプトは issue #185 で削除した。
ただし `UserPromptSubmit` の skill-ctx クリアは plugin 側 `hooks.json` 3 種いずれにも移植先が無いため、
`claude-code/settings.json` に残している（上記 hooks 表参照）。

hermes コンテナ（`container.settings.json` を `/root/.claude/settings.json` として mount、
`enabledPlugins` は空）では plugin が動かないため、#185 以降 PostToolUse の secret マスクと
SKILL.md frontmatter 検証はコンテナ内では発火しない（gateway 側 `security.redact_secrets` は
継続）。必要なら hermes 側で `playpark-core` plugin を有効化する。

### 導入手順（各マシンで一度）

1. `nix run .#update` を実行
2. `~/.claude/skills` / `~/.claude/workflows` / `~/.claude/agents` の repo symlink が残っていれば
   skills 側の手順で撤去
3. 旧 `playpark-local` の install が残っていれば除去する:
   `claude plugin uninstall dev-flow@playpark-local`（`playpark-core` / `playpark-skills` も同様）
4. 3 plugin を install する:
   `claude plugin install playpark-core@playpark` / `dev-flow@playpark` / `playpark-skills@playpark`
   （private repo として扱われる環境では git の認証（`gh auth setup-git` 等）が必要）
5. `/plugin` → Marketplaces → `playpark` で auto-update を有効化
6. `/dev-flow` が出ることを確認
7. セッション内で `command -v journal` と `command -v secfloor-classify` が
   `~/.claude/plugins/cache/playpark/...` 配下を返すことを確認

## Rollback

```bash
git revert <commit>
nix run .#update
# 必要なら symlink を手動で剥がす
rm ~/.claude/settings.json
rm ~/.claude/hooks/<name>.sh
rm ~/.claude/bin/gh ~/.claude/bin/gcloud ~/.claude/bin/tofu ~/.claude/bin/account-exec ~/.claude/account-map.json
```
