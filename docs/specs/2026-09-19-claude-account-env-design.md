# Claude Code セッション単位の gh / gcloud アカウント固定 設計

- 状態: 設計承認済み（2026-09-19）、未実装
- 対象リポジトリ: `dotfiles`（`claude-code/hooks`, `claude-code/settings.json`, `home-manager/home/default.nix`）
- 関連: `claude-code/README.md` の hooks 表

## 1. 目的 / 解決する痛み

gh と gcloud をそれぞれ複数アカウントで使い分けている。Claude Code のセッションが
別 org の repo で `gh` / `gcloud` を叩くと「アクセスできない」系の失敗が頻発する。
原因は 3 つ重なっている。

1. **グローバル切替の取り合い**: `gh auth switch` は `~/.config/gh/hosts.yml` の
   active account を、`gcloud config configurations activate` は
   `~/.config/gcloud/active_config` を書き換える。並列セッション・bg job・hermes 由来の
   job が別 org で動くと、どれか 1 つの切替が他全部を壊す
2. **失効 token を掴んだまま切り替える**: 2026-09-19 時点で `gh auth status` は
   `th-it-dev` の token を invalid と報告している。switch しても必ず失敗する
3. **sandbox が gcloud の書込みを塞ぐ**: `gcloud` は `sandbox.excludedCommands` に
   入っておらず、sandbox 内では `~/.config/gcloud/credentials.db` と `logs/` に
   書けない。`gcloud auth list` すら `Operation not permitted` で落ち、token refresh も
   同じ経路で失敗する。アカウント切替と無関係な失敗がここに混ざっている

目標: **グローバル状態を一切切り替えずに**、セッションごとに正しいアカウントが
使われる状態にする。加えて 3 の sandbox 起因の失敗を除く。

## 2. スコープ

### 入れるもの

- SessionStart hook `claude-code/hooks/session-start-account-env.sh`: 起動 cwd の
  org から gh / gcloud のアカウントを決め、セッション env に固定する
- マップ `claude-code/account-map.json`（org → gh config dir / gcloud 構成名）
- `claude-code/settings.json`: hook 登録、`sandbox.filesystem.allowWrite` に
  `~/.config/gcloud`、`denyRead` に `~/.config/gh-*/**`
- `home-manager/home/default.nix` の `setupClaudeCode`: マップを `~/.claude/account-map.json` へ symlink
- hook のテスト `claude-code/hooks/session-start-account-env.test.sh`
- `claude-code/README.md` hooks 表への追記と、初回セットアップ手順

### 入れないもの

- セッション途中の `cd` / `--add-dir` への追従（起動 cwd で固定する。同一セッションで
  別 org を触る運用は現状ない）
- 対話シェル側の切替（direnv 等）。ハーネスの問題だけを解く
- gcloud ADC（`application_default_credentials.json`）の分離。ADC は構成をまたいで
  グローバルであり、クライアントライブラリ経由のアクセスは本設計の対象外。必要に
  なったら `CLOUDSDK_CONFIG` で dir ごと分離する拡張で対応する
- `gcloud` の sandbox 除外。network allowlist の `*.googleapis.com` で足りており、
  隔離を保ったまま動かせる

## 3. 方式の選定

| 案 | 内容 | 判定 |
|---|---|---|
| **A. SessionStart hook で env 固定** | cwd の org をマップで引き `$CLAUDE_ENV_FILE` に export | **採用**。グローバル状態を触らない。既存 hook と同じ構造 |
| B. PreToolUse で gh/gcloud コマンドに env を前置 | `updatedInput` でコマンド文字列を書き換え | 不採用。パイプ・サブシェル・`&&` で壊れ、既存 guard 群と干渉する。利点は途中 `cd` への追従だけ |
| C. direnv `.envrc` | org dir に `.envrc` | 不採用（単体では）。Claude Code の Bash は direnv hook を通らない。A の補完として後で足すのは可 |

gh 側を `GH_TOKEN` の export ではなく `GH_CONFIG_DIR` にした理由:
token をセッション env に出さない（keyring のまま）。既存の credential guard や
hermes の blast radius 方針と整合する。代償は分離 dir への初回 `gh auth login` 1 回
だが、th-it-dev はどのみち再ログイン必須なので実質コストは無い。

## 4. 構成要素とデータフロー

```
claude start (cwd=~/ghq/github.com/<org>/…)
  └─ SessionStart(startup|resume|compact)
       └─ hooks/session-start-account-env.sh
            ├─ stdin JSON .cwd → ~/ghq/github.com/<org>/ の <org> を抽出
            ├─ ~/.claude/account-map.json で <org> を引く
            ├─ $CLAUDE_ENV_FILE に export を追記
            │     GH_CONFIG_DIR=<path>
            │     CLOUDSDK_ACTIVE_CONFIG_NAME=<name>
            └─ stdout に 1 行 (additionalContext):
                  "account-env: org=<org> gh=<path> gcloud=<name>"
  └─ 以降の Bash ツール全部がこの env を継承
       gh     (sandbox 除外) → GH_CONFIG_DIR の hosts.yml で認証
       git    (sandbox 除外) → credential helper `gh auth git-credential` も同じ dir を見る
       gcloud (sandbox 内)   → CLOUDSDK_ACTIVE_CONFIG_NAME の構成を使用
```

`GH_CONFIG_DIR` / `CLOUDSDK_ACTIVE_CONFIG_NAME` はどちらもプロセス単位で効く公式の
環境変数で、ファイルを書き換えない。`git push`（https）も credential helper が gh を
呼ぶので同じ dir で解決される。

## 5. マップ形式 (`claude-code/account-map.json`)

```json
{
  "orgs": {
    "it-all-playpark":   { "gh_config_dir": "~/.config/gh",           "gcloud_config": "default" },
    "playpark-llc":      { "gh_config_dir": "~/.config/gh",           "gcloud_config": "default" },
    "Cistree-dev":       { "gh_config_dir": "~/.config/gh",           "gcloud_config": "default" },
    "YujiNaramoto":      { "gh_config_dir": "~/.config/gh",           "gcloud_config": "default" },
    "BusinessProcessDX": { "gh_config_dir": "~/.config/gh-th-it-dev", "gcloud_config": "th-it-all" }
  }
}
```

- 既存の `~/.config/gh` は `it-all-playpark` 専用に戻す（`th-it-dev` の失効エントリは
  logout する）。`th-it-dev` は `~/.config/gh-th-it-dev` に分離する
- `gh_config_dir` / `gcloud_config` は両方 optional。無いキーは export しない
  （gcloud を使わない org は `gcloud_config` を省略する）
- 値の先頭 `~` は hook が `$HOME` に展開する。それ以外の展開はしない
- gcloud 構成名は `gcloud config configurations list` に既に存在する
  `default` / `th-it-all` をそのまま使う

## 6. hook の仕様

入力: Claude Code SessionStart hook の stdin JSON（`session-start-replay.sh` と同じ）。
`.cwd` を使う。stdin が空なら `$PWD`。

環境変数:
- `CLAUDE_ENV_FILE`: Claude Code が渡す。ここに `export KEY=VALUE` を追記する
- `CLAUDE_ACCOUNT_MAP`: マップの場所を差し替える（テスト用）。既定は
  `$HOME/.claude/account-map.json`

処理:
1. cwd が `$HOME/ghq/github.com/<org>/` に一致しなければ exit 0（無出力）
2. マップを `jq` で引く。`.orgs[<org>]` が無ければ exit 0（無出力）
3. `gh_config_dir` があれば `~` を展開して `export GH_CONFIG_DIR='<path>'` を追記
4. `gcloud_config` があれば `export CLOUDSDK_ACTIVE_CONFIG_NAME='<name>'` を追記
5. 追記した内容を stdout に 1 行で要約する（additionalContext としてモデルに見える）

fail 方針は **fail-open**。次は全て「何もしない + stderr に 1 行 + exit 0」:
- マップ不在、JSON 不正、`jq` 不在
- `CLAUDE_ENV_FILE` 未設定
- `.orgs[<org>]` の値がオブジェクトでない

やらないこと:
- `GH_CONFIG_DIR` のディレクトリ存在チェック。無くても export する。gh が「未ログイン」と
  正しく言うので、hook が黙って fallback するより原因が見える
- 値のバリデーション（構成名が gcloud に存在するか等）。同上

タイムアウト 5 秒。`set -euo pipefail`。`jq` 必須（既存 hook と同じ前提）。
export の値は single quote で囲む（パスに空白があっても壊れない。値に single quote は
含まない前提とし、含む場合は stderr 警告で skip）。

## 7. settings.json の変更

```jsonc
// hooks.SessionStart: startup / resume / compact の 3 matcher それぞれに追加
{
  "command": "bash \"$HOME/.claude/hooks/session-start-account-env.sh\"",
  "statusMessage": "gh/gcloud アカウント env 設定中...",
  "timeout": 5,
  "type": "command"
}

// sandbox.filesystem
"allowWrite": [ /* 既存 */ "~/.config/gcloud" ],
"denyRead":   [ /* 既存 */ "~/.config/gh-*/**" ]
```

`~/.config/gcloud` を allowWrite にするのは §1-3 の修正。credentials.db / logs / 
access token cache がここに書かれる。

`~/.config/gh-*/**` の denyRead は、分離した gh config dir を既存の `~/.config/gh/**`
と同じ扱いにするため。gh 自体は sandbox 除外なので影響を受けない。

注意: `claude-code/settings.json` は agent セッションの sandbox で write deny
（自己改変ガード）。実装時は diff を提示して人間が適用するか、`update-config` skill
経由で行う。

## 8. home-manager の変更

`setupClaudeCode` activation に、`CLAUDE.md` 等と同列で
`account-map.json` の symlink を 1 行足す:

```
ln -sf "$DOTFILES_CLAUDE/account-map.json" "$CLAUDE_DIR/account-map.json"
```

hook 本体は既存の `hooks/*.sh` ループで自動的に `~/.claude/hooks/` に symlink される
（`*.test.sh` は除外される既存ルール）。

## 9. テスト

`claude-code/hooks/session-start-account-env.test.sh`。既存 `*.test.sh` と同じ自前
PASS/FAIL 形式。`CLAUDE_ENV_FILE` と `CLAUDE_ACCOUNT_MAP` を `$TMPDIR` 配下の一時
ファイルに向け、`HOME` も一時 dir に差し替えて cwd を組み立てる。

| # | 入力 | 期待 |
|---|---|---|
| 1 | mapped org の repo 直下 | `GH_CONFIG_DIR` と `CLOUDSDK_ACTIVE_CONFIG_NAME` の export 2 行、`~` が `$HOME` に展開済み |
| 2 | worktree パス `…/<org>/repo/.claude/worktrees/x` | 1 と同じ |
| 3 | `gcloud_config` を省略した org | `GH_CONFIG_DIR` の 1 行だけ |
| 4 | 未登録 org | env file 空、stdout 空、exit 0 |
| 5 | ghq 外の cwd | 4 と同じ |
| 6 | マップ不在 | env file 空、exit 0、stderr に警告 |
| 7 | マップが JSON 不正 | 6 と同じ |
| 8 | `CLAUDE_ENV_FILE` 未設定 | exit 0、stderr に警告 |
| 9 | stdout の 1 行要約に org / gh / gcloud が含まれる | 目視ではなく grep で確認 |

加えて `nix fmt -- --no-cache` と `nix flake check` が通ること（shellcheck 含む）。

## 10. 初回セットアップ（人間の作業、README に記載）

```bash
gh auth logout -h github.com -u th-it-dev            # ~/.config/gh から失効エントリを除去
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login    # 分離 dir に th-it-dev を再ログイン
nix run .#update                                      # symlink と settings を反映
```

確認:

```bash
cd ~/ghq/github.com/BusinessProcessDX/<repo> && claude
# セッション内で: gh auth status → th-it-dev / gcloud config list → th-it-all
```

## 11. 受け入れ基準

1. `BusinessProcessDX` 配下で起動したセッションの `gh auth status` が `th-it-dev`、
   `gcloud config list` の account が `th.it.dev@…` になる。`~/.config/gh/hosts.yml`
   と `~/.config/gcloud/active_config` は変化しない
2. `it-all-playpark` / `playpark-llc` 配下で起動したセッションが同時に動いていても
   互いに影響しない
3. sandbox 内で `gcloud auth list` が `Operation not permitted` で落ちない
4. §9 のテスト 9 件が通り、`nix flake check` が通る

## 12. 既知の限界

- 起動 cwd で固定。途中で別 org に `cd` しても切り替わらない（§2）
- gcloud ADC は対象外（§2）
- `GH_CONFIG_DIR` を分けると `config.yml`（alias, editor 等）も dir ごとに独立する。
  th-it-dev 側は初回 login 時の既定値になる。共有したくなったら config.yml だけ
  symlink する
