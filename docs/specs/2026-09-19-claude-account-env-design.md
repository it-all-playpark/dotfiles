# gh / gcloud / tofu の cwd 連動アカウント固定（PATH shim） 設計

- 状態: 実装済み（2026-09-19、shim 方式へ改訂のうえ実装。`nix run .#update` と初回ログインは §10 参照）
- 改訂 2026-09-21: gcloud を構成名（`CLOUDSDK_ACTIVE_CONFIG_NAME`）から config dir
  （`CLOUDSDK_CONFIG`）の分離に変更し、ADC を org 単位に分けた。`tofu` を shim 対象に追加し
  `GOOGLE_APPLICATION_CREDENTIALS` で ADC ファイルを明示する（§2 / §5 / §6 / §10 / §12）。
  きっかけ: BusinessProcessDX 側で `gcloud auth application-default login` した結果、
  グローバルな ADC が別アカウントになり、playpark-llc/shift-bud の `tofu init`（GCS backend）が
  403 になった
- 対象リポジトリ: `dotfiles`（`claude-code/bin`, `claude-code/settings.json`,
  `home-manager/home/default.nix`, `home-manager/programs/{zsh,fish}.nix`）
- 関連: `claude-code/README.md`

## 1. 目的 / 解決する痛み

gh と gcloud をそれぞれ複数アカウントで使い分けている。Claude Code のセッションが
別 org の repo で `gh` / `gcloud` を叩くと「アクセスできない」系の失敗が頻発する。
原因は 3 つ重なっている。

1. **グローバル切替の取り合い**: `gh auth switch` は `~/.config/gh/hosts.yml` の
   active account を、`gcloud config configurations activate` は
   `~/.config/gcloud/active_config` を書き換える。並列セッション・bg job・dev-flow の
   subagent が別 org で動くと、どれか 1 つの切替が他全部を壊す
2. **失効 token を掴んだまま切り替える**: 2026-09-19 時点で `gh auth status` は
   `th-it-dev` の token を invalid と報告している。switch しても必ず失敗する
3. **sandbox が gcloud の書込みを塞ぐ**: `gcloud` は `sandbox.excludedCommands` に
   入っておらず、sandbox 内では `~/.config/gcloud/credentials.db` と `logs/` に
   書けない。`gcloud auth list` すら `Operation not permitted` で落ち、token refresh も
   同じ経路で失敗する。アカウント切替と無関係な失敗がここに混ざっている

目標: **グローバル状態を一切切り替えずに**、コマンドを実行した cwd に応じて正しい
アカウントが使われる状態にする。加えて 3 の sandbox 起因の失敗を除く。

## 2. スコープ

### 入れるもの

- PATH shim `claude-code/bin/account-exec` と、それへの symlink `bin/gh` / `bin/gcloud` /
  `bin/tofu`。実行時の `$PWD` から org を判定し、`GH_CONFIG_DIR` / `CLOUDSDK_CONFIG` /
  `GOOGLE_APPLICATION_CREDENTIALS` を付けて実体を `exec` する
- マップ `claude-code/account-map.json`（org → gh config dir / gcloud config dir）
- gcloud ADC（`application_default_credentials.json`）の分離（2026-09-21 改訂で追加）。
  gcloud config dir を org ごとに分けることで ADC も dir に閉じ、`tofu` には
  `GOOGLE_APPLICATION_CREDENTIALS` でその dir の ADC ファイルを渡す
- `home-manager/home/default.nix` の `setupClaudeCode`: `bin/*` と `account-map.json` を
  `~/.claude/` へ symlink
- `home-manager/programs/zsh.nix` / `fish.nix`: `~/.claude/bin` を PATH 先頭に追加
- `claude-code/settings.json`: `sandbox.filesystem.allowWrite` に `~/.config/gcloud`、
  `denyRead` に `~/.config/gh-*/**`
- shim のテスト `claude-code/bin/account-exec.test.sh`
- `claude-code/README.md` への追記と、初回セットアップ手順

### 入れないもの

- `tofu` 以外のクライアントライブラリ利用者（gsutil、各言語 SDK を直接使うスクリプト等）
  への ADC 受け渡し。必要になったら `bin/<tool>` symlink と `case` を足す
- `gcloud` の sandbox 除外。network allowlist の `*.googleapis.com` で足りており、
  隔離を保ったまま動かせる
- org より細かい粒度（repo 単位・gcloud project 単位）のマップ。必要になったら
  マップに `repos` を足す
- launchd job（hermes watchdog 等）の PATH。既定アカウントで足りている

## 3. 方式の選定

| 案 | 内容 | 判定 |
|---|---|---|
| **A'. PATH shim** | `gh` / `gcloud` のラッパーを PATH 先頭に置き、実行時 `$PWD` で判定 | **採用**。コマンド単位で正しく、subagent / worktree / `cd X && gh` / `git -C` 全部に効く |
| A. SessionStart hook で env 固定 | 起動 cwd で `$CLAUDE_ENV_FILE` に export | 不採用。1 セッション = 1 org の前提が dev-flow（複数 repo を並列で回す）で崩れる |
| B. PreToolUse で gh/gcloud コマンドに env を前置 | `updatedInput` でコマンド文字列を書き換え | 不採用。パイプ・サブシェル・`&&` で壊れ、既存 guard 群と干渉する |
| C. direnv `.envrc` | org dir に `.envrc` | 不採用。Claude Code の Bash は direnv hook を通らない |

shim dir を PATH に入れる場所は、Claude Code 限定（SessionStart で `CLAUDE_ENV_FILE`）
ではなく **home-manager で全シェルの PATH** にする。Claude Code の Bash はログイン
シェルの env snapshot を使うのでそれで効き、対話シェル・bg job・cca セッションも同じ
挙動になる。`gh auth switch` を手で打つ運用自体が消える。

gh 側を `GH_TOKEN` ではなく `GH_CONFIG_DIR` にした理由: token を env に出さない
（keyring のまま）。既存の credential guard や hermes の blast radius 方針と整合する。
代償は分離 dir への初回 `gh auth login` 1 回だが、th-it-dev はどのみち再ログイン必須
なので実質コストは無い。

## 4. 構成要素とデータフロー

```
subagent (cwd=~/ghq/github.com/BusinessProcessDX/repo/.claude/worktrees/x)
  └─ Bash: gh pr create …
       └─ ~/.claude/bin/gh  → account-exec   (shim)
            ├─ $PWD → org=BusinessProcessDX
            ├─ ~/.claude/account-map.json を引く
            ├─ GH_CONFIG_DIR=~/.config/gh-th-it-dev を env に付ける
            └─ exec ~/.nix-profile/bin/gh pr create …
                 (PATH から shim dir を除いて解決した実体。exec 先の PATH は元のまま)

git push (https) → credential helper `gh auth git-credential`
  └─ git は -C / cwd に chdir 済みなので、この gh 呼び出しも shim を通り同じ dir で解決
```

`GH_CONFIG_DIR` / `CLOUDSDK_CONFIG` / `GOOGLE_APPLICATION_CREDENTIALS` はいずれもプロセス
単位で効く公式の環境変数で、ファイルを書き換えない。shim は自分の子プロセスにだけ env を
付けるので、同じ bash スクリプト内で `cd org1 && gh …; cd org2 && gh …` としても各呼び出しが
独立に解決される。

ツールと env の対応:

| ツール | env | マップのキー |
|---|---|---|
| `gh` | `GH_CONFIG_DIR=<dir>` | `gh_config_dir` |
| `gcloud` | `CLOUDSDK_CONFIG=<dir>` | `gcloud_config_dir` |
| `tofu` / `terraform` | `GOOGLE_APPLICATION_CREDENTIALS=<dir>/application_default_credentials.json` | `gcloud_config_dir` |

gcloud を構成名（`CLOUDSDK_ACTIVE_CONFIG_NAME`）ではなく dir（`CLOUDSDK_CONFIG`）で分ける
理由: ADC（`application_default_credentials.json`）は構成をまたいで config dir 直下に 1 つ
しか無く、`gcloud auth application-default login` は無条件にそれを上書きする。構成名だけ
分けても org B でログインした瞬間に org A の ADC が消える。dir を分ければ
`gcloud auth application-default login` の書き先も dir に閉じる。

tofu に `CLOUDSDK_CONFIG` ではなく `GOOGLE_APPLICATION_CREDENTIALS` を渡す理由: Go の
`golang.org/x/oauth2/google` は ADC の well-known path を `~/.config/gcloud/` 固定で
組み立て、`CLOUDSDK_CONFIG` を参照しない（`default.go` の `wellKnownFile()`）。
`GOOGLE_APPLICATION_CREDENTIALS` は全クライアントライブラリが最優先で見る公式の env で、
`authorized_user` 型（ユーザー ADC）のファイルもそのまま受け付ける。

## 5. マップ形式 (`claude-code/account-map.json`)

```json
{
  "orgs": {
    "it-all-playpark":   { "gh_config_dir": "~/.config/gh",           "gcloud_config_dir": "~/.config/gcloud" },
    "playpark-llc":      { "gh_config_dir": "~/.config/gh",           "gcloud_config_dir": "~/.config/gcloud" },
    "Cistree-dev":       { "gh_config_dir": "~/.config/gh",           "gcloud_config_dir": "~/.config/gcloud" },
    "YujiNaramoto":      { "gh_config_dir": "~/.config/gh",           "gcloud_config_dir": "~/.config/gcloud" },
    "BusinessProcessDX": { "gh_config_dir": "~/.config/gh-th-it-dev", "gcloud_config_dir": "~/.config/gcloud-th-it-dev" }
  }
}
```

- 既存の `~/.config/gh` は `it-all-playpark` 専用に戻す（`th-it-dev` の失効エントリは
  logout する）。`th-it-dev` は `~/.config/gh-th-it-dev` に分離する
- 同様に既存の `~/.config/gcloud` は playpark 系専用に戻し、`th.it.dev` は
  `~/.config/gcloud-th-it-dev` に分離する（旧 `th-it-all` 構成は不要になる）
- `gh_config_dir` / `gcloud_config_dir` は両方 optional。無いキーは env を付けない
  （gcloud を使わない org は `gcloud_config_dir` を省略する）
- 値の先頭 `~` は shim が `$HOME` に展開する。それ以外の展開はしない
- 旧キー `gcloud_config`（構成名）は 2026-09-21 改訂で廃止。残っていても shim は無視する
  （`gcloud_config_dir` が無い扱いになり env を付けない）

## 6. shim の仕様 (`claude-code/bin/account-exec`)

`bin/gh` / `bin/gcloud` / `bin/tofu` は `account-exec` への symlink。shim は `$0` の
basename で自分がどのツールか判定する（`gh` → `GH_CONFIG_DIR`、`gcloud` →
`CLOUDSDK_CONFIG`、`tofu` / `terraform` → `GOOGLE_APPLICATION_CREDENTIALS`。
それ以外の名前は stderr にエラーを出して exit 2）。`terraform` は symlink を置いて
いない（このマシンでは shell function で `tofu` に向けている）が、名前だけは受け付ける。

環境変数:
- `ACCOUNT_MAP`: マップの場所を差し替える（テスト用）。既定は
  `$HOME/.claude/account-map.json`
- `ACCOUNT_EXEC_DEBUG=1`: 判定結果（org / 付けた env / exec 先）を stderr に 1 行出す

処理:
1. **明示指定があれば何もしない**: そのツールの対象 env（`GH_CONFIG_DIR` /
   `CLOUDSDK_CONFIG` / `GOOGLE_APPLICATION_CREDENTIALS`）が既に set なら、判定を飛ばして手順 5 へ。
   初回 login の `GH_CONFIG_DIR=… gh auth login` がそのまま使え、shim が付けた env を
   継承した孫プロセス（gh → git → gh）も二重判定しない
2. `$PWD` が `$HOME/ghq/github.com/<org>/` または `$HOME/ghq/github.com-<alias>/<org>/`
   （SSH host alias 経由で `ghq get` した置き場）に一致すれば `<org>` を取る。一致しなければ
   `pwd -P`（symlink 解決後）でもう一度試す。どちらも不一致なら判定なしで手順 5 へ。
   `github.com` 以外のホスト（`gitlab.com` 等）は対象外
3. マップを `jq` で引く。`.orgs[<org>]` が無ければ判定なしで手順 5 へ
4. 対象キーがあれば `~` を展開して env に set する（`tofu` は dir の後ろに
   `/application_default_credentials.json` を付けてファイルパスにする）
5. 実体を解決して `exec`。解決は **PATH から shim dir を除いた PATH** で
   `command -v <tool>` する。shim dir は `$HOME/.claude/bin` と、`$0` の物理パスの
   ディレクトリ（dotfiles 側 `claude-code/bin`）の両方。exec 先の PATH は元のまま
   （git → gh の credential helper 呼び出しが shim を通り続けるため）
6. 解決先が無い、または解決先が shim 自身（同一 inode）なら stderr にエラーを出して
   exit 127。無限再帰にはしない

fail 方針は **fail-open で passthrough**。次は全て「env を付けずに実体を exec +
stderr に 1 行」:
- マップ不在、JSON 不正、`jq` 不在
- `.orgs[<org>]` の値がオブジェクトでない
- 値に single quote や改行が含まれる（env に安全に載せられない）

やらないこと:
- `GH_CONFIG_DIR` のディレクトリ存在チェック。無くても set する。gh が「未ログイン」と
  正しく言うので、shim が黙って fallback するより原因が見える
- 値のバリデーション（ADC ファイルの存在等）。同上。`GOOGLE_APPLICATION_CREDENTIALS` が
  無いファイルを指せば tofu が `open …: no such file` と言う

引数は `"$@"` でそのまま渡す。stdin / stdout / stderr / exit code は実体のもの
（`exec` するので shim のプロセスは残らない）。`set -euo pipefail`。`jq` 必須。

## 7. PATH と symlink（home-manager）

`setupClaudeCode` activation:
- `hooks/*.sh` と同じループで `claude-code/bin/*` を `~/.claude/bin/` へ symlink
  （`*.test.sh` は除外。`bin/gh` / `bin/gcloud` は repo 内 symlink なので、
  `~/.claude/bin/gh` → `claude-code/bin/gh` → `account-exec` の 2 段になる）
- `account-map.json` を `CLAUDE.md` 等と同列で `~/.claude/account-map.json` へ symlink

PATH:
- `zsh.nix` `envExtra`: 既存の nix-profile 行の後に
  `export PATH="$HOME/.claude/bin:$PATH"`
- `fish.nix` `shellInit`: `fish_add_path $HOME/.nix-profile/bin` の後に
  `fish_add_path $HOME/.claude/bin`。fish の PATH 合成順は実装時に
  `fish -lc 'which gh'` で shim が先に来ることを確認する
- `gh` / `gcloud` は `~/.nix-profile/bin` にしか無く mise 管理外なので、shim dir が
  nix-profile より前にあれば足りる
- Claude Code の Bash ツールは rc を読み直さず起動プロセスの PATH snapshot を使うため、
  SessionStart hook `hooks/session-start-account-path.sh` が `$CLAUDE_ENV_FILE` に
  `export PATH="$HOME/.claude/bin:$PATH"` を追記する（cwd 非依存。§3-A で却下したのは
  「起動 cwd で org を固定する」ことであり、PATH の追加は影響しない）

`which gh` が shim を指すようになる。実体を直接叩きたいときは
`GH_CONFIG_DIR=… gh` の明示指定（§6-1）か `~/.nix-profile/bin/gh`。

## 8. settings.json の変更

```jsonc
// sandbox.filesystem
"allowWrite": [ /* 既存 */ "~/.config/gcloud", "~/.config/gcloud-*" ],
"denyRead":   [ /* 既存 */ "~/.config/gh-*/**" ]
```

`~/.config/gcloud` を allowWrite にするのは §1-3 の修正。credentials.db / logs /
access token cache がここに書かれる。`~/.config/gcloud-*` は 2026-09-21 改訂で分離した
org 別 config dir（`~/.config/gcloud-th-it-dev` 等）に同じ扱いをするため。

`~/.config/gh-*/**` の denyRead は、分離した gh config dir を既存の `~/.config/gh/**`
と同じ扱いにするため。gh 自体は `gh:*` で sandbox 除外なので影響を受けない。
`excludedCommands` の `gh:*` と permission の `Bash(gh …)` はコマンド名一致なので、
shim 経由でもそのまま効く。

hooks の追加は無い。

注意: `claude-code/settings.json` は agent セッションの sandbox で write deny
（自己改変ガード）。実装時は diff を提示して人間が適用するか、`update-config` skill
経由で行う。

## 9. テスト

`claude-code/bin/account-exec.test.sh`。既存 `hooks/*.test.sh` と同じ自前 PASS/FAIL
形式。`$TMPDIR` 配下に一時 `HOME` を作り、その中に
`ghq/github.com/<org>/repo/.claude/worktrees/x` と `ghq/github.com-<alias>/<org>/repo` を掘る。
fake の `gh` / `gcloud` / `tofu`
（受け取った `GH_CONFIG_DIR` / `CLOUDSDK_CONFIG` / `GOOGLE_APPLICATION_CREDENTIALS` と `argv` を 1 行ずつ
出力するだけ）を一時 dir に置き、`PATH=<shim dir>:<fake dir>` で shim を呼ぶ。
`ACCOUNT_MAP` は一時ファイル。

| # | 入力 | 期待 |
|---|---|---|
| 1 | mapped org の repo 直下で `gh` | fake が `GH_CONFIG_DIR=<HOME>/.config/gh-…` を受け取る（`~` 展開済み） |
| 2 | worktree パス `…/<org>/repo/.claude/worktrees/x` で `gh` | 1 と同じ |
| 3 | mapped org で `gcloud` | fake が `CLOUDSDK_CONFIG=<HOME>/.config/gcloud-…` を受け取る（`~` 展開済み） |
| 4 | `gcloud_config_dir` を省略した org で `gcloud` | env 未設定のまま実体へ |
| 5 | 未登録 org / ghq 外の cwd | env 未設定、stderr 空、argv そのまま |
| 6 | マップ不在 / JSON 不正 | env 未設定で実体へ、stderr に警告 1 行 |
| 7 | `GH_CONFIG_DIR` を事前に set して mapped org で `gh` | 事前の値がそのまま（上書きしない） |
| 8 | 空白・引用符・`--flag=value` を含む引数 | argv が 1 要素も欠けず・壊れずに届く |
| 9 | 実体が PATH に無い | exit 127、stderr にツール名を含むエラー |
| 10 | PATH に shim dir しか無い | exit 127（無限再帰しない、1 秒以内に終わる） |
| 11 | `ACCOUNT_EXEC_DEBUG=1` | stderr に org / env / exec 先が出る |
| 12 | 実体の exit code が非 0 | shim の exit code も同じ値 |
| 13 | SSH host alias 置き場 `…/ghq/github.com-<alias>/<org>/repo` で `gh` / `gitlab.com` 配下で `gh` | 前者は 1 と同じ / 後者は env 未設定・stderr 空 |
| 14 | mapped org で `tofu` | fake が `GOOGLE_APPLICATION_CREDENTIALS=<HOME>/.config/gcloud-…/application_default_credentials.json` を受け取る。`CLOUDSDK_CONFIG` は付かない |
| 15 | `gcloud_config_dir` を省略した org / 未登録 org で `tofu` | env 未設定のまま実体へ |
| 16 | `GOOGLE_APPLICATION_CREDENTIALS` を事前に set して mapped org で `tofu` | 事前の値がそのまま（SA 鍵の明示指定を尊重） |

加えて `nix fmt -- --no-cache` と `nix flake check` が通ること（shellcheck 含む）。

## 10. 初回セットアップ（人間の作業、README に記載）

```bash
gh auth logout -h github.com -u th-it-dev            # ~/.config/gh から失効エントリを除去
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login    # 分離 dir に th-it-dev を再ログイン
nix run .#update                                      # symlink / PATH / settings を反映
exec $SHELL -l                                        # PATH を取り直す

# gcloud（2026-09-21 改訂）: 分離 dir にログイン。shim が cwd から CLOUDSDK_CONFIG を付けるので cd してから
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

## 11. 受け入れ基準

1. `BusinessProcessDX` 配下の cwd で `gh auth status` が `th-it-dev`、
   `gcloud config list` の account が `th.it.dev@…` になる。`~/.config/gh/hosts.yml`
   と `~/.config/gcloud/active_config` は変化しない
2. 1 つの Claude Code セッション内で、`it-all-playpark` と `BusinessProcessDX` の
   worktree をそれぞれ cwd にした subagent が同時に `gh` を叩いても互いに影響しない
3. sandbox 内で `gcloud auth list` が `Operation not permitted` で落ちない
4. §9 のテスト 16 件が通り、`nix flake check` が通る
5. `playpark-llc/shift-bud` で `pnpm tf:init:stg` が playpark の ADC で通り、
   `BusinessProcessDX` 配下で `gcloud auth application-default login` しても
   `~/.config/gcloud/application_default_credentials.json` が変化しない

## 12. 既知の限界

- shim が env を付けるのは `gh` / `gcloud` / `tofu` だけ。gsutil や各言語 SDK を直接使う
  スクリプトには env が付かず既定の `~/.config/gcloud/` を探す（§2）
- `GH_CONFIG_DIR` / `CLOUDSDK_CONFIG` を分けると `config.yml` / `configurations/`（alias, editor,
  project 等）も dir ごとに独立する。
  th-it-dev 側は初回 login 時の既定値になる。共有したくなったら config.yml だけ
  symlink する
- shim は `jq` を毎回起動する（数 ms）。gh / gcloud 自体の起動時間に埋もれる
- ghq 外に clone した repo では判定できず、既定（グローバル状態）のまま
- shim は論理 `$PWD` を優先するため、org A の repo 内から org B の repo への symlink 経由で
  入った cwd は A のアカウントになる
