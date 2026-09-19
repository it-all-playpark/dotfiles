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
├── account-map.json      # gh / gcloud の org → アカウントマップ（bin/account-exec が読む）
├── bin/                  # gh / gcloud の cwd 連動アカウント shim（account-exec + symlink の gh / gcloud）
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
6. `bin/*` を `~/.claude/bin/` に symlink（`*.test.sh` は除外。`bin/gh` / `bin/gcloud` は repo 内で
   `account-exec` への symlink なので `~/.claude/bin/gh` → `bin/gh` → `account-exec` の 2 段になる）
7. `account-map.json` を `~/.claude/account-map.json` に symlink

`skills/` は `scripts/setup-skills.sh` で別管理（`setup.sh` から呼び出される）。
activation 側では触らないので、既存の symlink を壊さない。

```bash
nix run .#update
```

## gh / gcloud アカウント shim

設計: `docs/specs/2026-09-19-claude-account-env-design.md`

gh と gcloud を複数アカウントで使い分けるとき、`gh auth switch` / `gcloud config configurations activate`
はグローバル状態（`~/.config/gh/hosts.yml` / `~/.config/gcloud/active_config`）を書き換えるため、
並列セッションや dev-flow の subagent が別 org で動くと互いに壊し合う。`bin/account-exec` は
**グローバル状態を一切切り替えず**、コマンドを実行した cwd から使うアカウントを決める PATH shim。

### 仕組み

```
Bash: gh pr create …  (cwd=~/ghq/github.com/BusinessProcessDX/repo/.claude/worktrees/x)
  └─ ~/.claude/bin/gh → claude-code/bin/gh → account-exec
       ├─ $PWD（不一致なら pwd -P）から org=BusinessProcessDX を取る
       ├─ ~/.claude/account-map.json の .orgs[org] を jq で引く
       ├─ GH_CONFIG_DIR=~/.config/gh-th-it-dev を export（gcloud なら CLOUDSDK_ACTIVE_CONFIG_NAME）
       └─ exec ~/.nix-profile/bin/gh pr create …
            （PATH から shim dir を除いて解決した実体。exec 先の PATH は元のまま）
```

- `~/.claude/bin` は home-manager が zsh（`envExtra`）/ fish（`shellInit`）の PATH 先頭に載せる。
  `which gh` / `which gcloud` は `~/.claude/bin/…` を指すようになる。Claude Code セッション内では加えて
  SessionStart hook `session-start-account-path.sh` が `$CLAUDE_ENV_FILE` に同じ export を書き、
  起動元の PATH に依存せず shim が効くようにする
- 同じスクリプト内で `cd org1 && gh …; cd org2 && gh …` としても各呼び出しが独立に解決される。
  `git push`（https）の credential helper `gh auth git-credential` も git が chdir 済みなので同じ dir で解決される
- **明示指定は素通し**: `GH_CONFIG_DIR=… gh …` / `CLOUDSDK_ACTIVE_CONFIG_NAME=… gcloud …` のように対象 env が
  既に set なら判定しない。実体を直接叩きたいときはこれか `~/.nix-profile/bin/gh`
- **fail-open**: マップ不在 / JSON 不正 / `jq` 不在 / 値に `'` や改行 を含む場合は env を付けずに実体へ
  passthrough し、stderr に `account-exec: …` を 1 行出す。ghq 外（`~/ghq/github.com/<org>/` に無い cwd）や
  未登録 org は無言で passthrough（既定のグローバル状態のまま）
- 実体が PATH に無い、または解決先が shim 自身なら exit 127（無限再帰しない）
- `ACCOUNT_EXEC_DEBUG=1 gh …` で判定結果（org / 付けた env / exec 先）を stderr に 1 行出す

### マップの編集（`account-map.json`）

```json
{
  "orgs": {
    "BusinessProcessDX": { "gcloud_config": "th-it-all", "gh_config_dir": "~/.config/gh-th-it-dev" },
    "it-all-playpark":   { "gcloud_config": "default",   "gh_config_dir": "~/.config/gh" }
  }
}
```

- キーは `~/ghq/github.com/<org>/` の `<org>`。`gh_config_dir` / `gcloud_config` は両方 optional で、
  無いキーは env を付けない（gcloud を使わない org は `gcloud_config` を省略する）
- 値の先頭 `~` だけ `$HOME` に展開する。それ以外の展開はしない
- `gcloud_config` は `gcloud config configurations list` に存在する構成名をそのまま書く
- dir の存在や構成名の妥当性は shim では検証しない（gh / gcloud が「未ログイン」等を正しく言う）
- 編集後は `nix run .#update` 不要（`~/.claude/account-map.json` は symlink）。`nix fmt` がキーをソートする

### 初回セットアップ（人間の作業）

```bash
gh auth logout -h github.com -u th-it-dev            # ~/.config/gh から失効エントリを除去
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login    # 分離 dir に th-it-dev を再ログイン
nix run .#update                                      # symlink / PATH / settings を反映
exec $SHELL -l                                        # PATH を取り直す
```

確認:

```bash
cd ~/ghq/github.com/BusinessProcessDX/<repo>
which gh                      # → ~/.claude/bin/gh
gh auth status                # → th-it-dev
gcloud config list            # → th-it-all (account th.it.dev@…)
cd ~/ghq/github.com/it-all-playpark/dotfiles
gh auth status                # → it-all-playpark
```

### 既知の限界

- gcloud ADC（`application_default_credentials.json`）は構成をまたいでグローバルなので対象外
- `GH_CONFIG_DIR` を分けると `config.yml`（alias, editor 等）も dir ごとに独立する。共有したくなったら
  `config.yml` だけ symlink する
- shim は毎回 `jq` を起動する（数 ms、gh / gcloud 自体の起動時間に埋もれる）
- ghq 外に clone した repo では判定できず既定のまま

テスト: `bash claude-code/bin/account-exec.test.sh`（shim、12 ケース / 14 assertion）、
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
| `PreToolUse` Bash | `pretool-bash-credential-guard.sh` | prod credential を含むコマンドを抑止 |
| `PreToolUse` Bash | `pretool-gh-pr-self-approve-guard.sh` | `gh pr review --approve` による PR self-approve を deny（merge/approve は常に人間） |
| `PreToolUse` Bash (`git worktree add*`) | `generate-worktreeinclude.sh` | `.worktreeinclude` 自動生成 |
| `PreToolUse` Bash (`gh pr merge*`) | `allow-pr-merge.sh` | merge 先 branch チェック |
| `PermissionRequest` | `permission-journal.sh` | permission 要求を journal に記録 |
| `PreToolUse` Bash | `pretool-npx-guard.sh` | npx 実行ガード |
| `PostToolUse` | `memory-monitor.py` | メモリ使用量監視 |
| `Stop` | `stop-unfinished-guard.sh` | 未完了タスクがあれば停止を抑止 |
| `SessionStart` (*) | `herdr-agent-state.sh`（`~/.claude/hooks` に直置き、dotfiles 管理外） | herdr agent 状態通知。settings.json 側は `` 参照 1 本で共有。herdr は絶対パス完全一致でしか登録済みと判定しないため、`herdr integration install claude` を再実行した後は追記される絶対パスのエントリを revert すること |
| `UserPromptSubmit` | inline `rm -f /tmp/claude-skill-ctx-<session>` | `playpark-core` plugin の `skill-retrospective/journal.sh` が使う skill-ctx state file をプロンプト投入毎にクリア。plugin 側 `hooks.json` に `UserPromptSubmit` の移植先が無いため dotfiles 側に維持（journal.sh 側の 30 分 TTL は取りこぼし時の保険） |

テストファイル（`*.test.sh`）は symlink 対象外。

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

自分用は `settings.json` の `extraKnownMarketplaces.playpark-local`（`source: "settings"` の
inline marketplace）に 3 plugin を `source: "command"` + `mode: "link"` で登録し、
`enabledPlugins` で `playpark-core@playpark-local` / `dev-flow@playpark-local` /
`playpark-skills@playpark-local` を有効化している。command は
`echo "$HOME/ghq/github.com/it-all-playpark/skills/plugins/<plugin>"` で、link mode は
plugin cache から checkout への symlink を張るので repo の編集が再 install なしで反映される。

`bin/` の bare 名（`journal` / `secfloor-classify` 等）は Claude Code が plugin の `bin/` を
PATH に載せることで解決する。`sandbox.excludedCommands` には bare 名のみ登録し、
`~/.claude/skills/*` 系 glob は撤去済み（issue #179）。

旧 copy mode の `playpark-skills@playpark`（github marketplace `playpark`）は、
[it-all-playpark/skills#584](https://github.com/it-all-playpark/skills/issues/584)
（plugin `bin/` 化）が未 merge の間は `enabledPlugins` で `true` のまま残す。
584 merge 前に `false` にすると `journal` / `secfloor-classify` 等の bare command が
PATH から消え、`playpark-local` 側の install も失敗しうるため。584 merge 後に別 PR で
`false` へ倒し、マシン上に残っていれば `claude plugin uninstall playpark-skills@playpark`
で除去する。

hooks の `journal.sh` / `zombie-kill.sh` 参照 3 箇所は skills#572 で plugin の hooks.json へ
移植済み。dotfiles 側の重複 entry と `claude-code/hooks/` の移植済みスクリプトは issue #185 で削除した。
ただし `UserPromptSubmit` の skill-ctx クリアは plugin 側 `hooks.json` 3 種いずれにも移植先が無いため、
`claude-code/settings.json` に残している（上記 hooks 表参照）。

hermes コンテナ（`container.settings.json` を `/root/.claude/settings.json` として mount、
`enabledPlugins` は空）では plugin が動かないため、#185 以降 PostToolUse の secret マスクと
SKILL.md frontmatter 検証はコンテナ内では発火しない（gateway 側 `security.redact_secrets` は
継続）。必要なら hermes 側で `playpark-core` plugin を有効化する。

### 導入手順（skills#571 merge 後）

1. `nix run .#update` を実行
2. `~/.claude/skills` / `~/.claude/workflows` / `~/.claude/agents` の repo symlink が残っていれば
   skills 側の手順で撤去
3. 素の `claude` を起動すると `playpark-local` の 3 plugin が install される
4. `/dev-flow` が出ることを確認
5. セッション内で `command -v journal` と `command -v secfloor-classify` が
   `~/.claude/plugins/cache/playpark-local/...` 配下を返すことを確認

## Rollback

```bash
git revert <commit>
nix run .#update
# 必要なら symlink を手動で剥がす
rm ~/.claude/settings.json
rm ~/.claude/hooks/<name>.sh
rm ~/.claude/bin/gh ~/.claude/bin/gcloud ~/.claude/bin/account-exec ~/.claude/account-map.json
```
