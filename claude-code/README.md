# claude-code

[Claude Code](https://docs.claude.com/en/docs/claude-code) の設定を dotfiles で管理する。
home-manager の `activation.setupClaudeCode` が `~/.claude/` 配下に symlink を張る。

`claude-code` バイナリ自体は mise で管理（`home-manager/home/file/mise/config.toml` の
`"npm:@anthropic-ai/claude-code"`）。本ディレクトリは設定のみを扱う。

## ファイル構成

```
claude-code/
├── README.md             # このファイル
├── CLAUDE.md             # global Claude Code instructions（RULES.md を import）
├── RULES.md              # 振る舞いのルール（engineering / subagent / tool routing / git / sandbox）
├── settings.json         # permissions（allow/deny）+ hooks 設定 + env
├── skill-config.json     # it-all-playpark/skills の per-skill デフォルト値
├── account-map.json      # gh / gcloud / tofu の org → アカウントマップ（bin/account-exec が読む）
├── bin/                  # gh / gcloud / tofu の cwd 連動アカウント shim（account-exec + symlink の gh / gcloud / tofu）
│                         # と、本体の上流 proxy を agent-vault に向ける claude wrapper
└── hooks/                # SessionStart / PreCompact / Pre|PostToolUse スクリプト
```

`RULES.md` はかつて SuperClaude framework の一部として `PRINCIPLES.md` と共に導入したが、
Opus 5.5 / Sonnet 5.5 向けに公式 best practice に沿って削った（2026-09-30）。方針は
「消したら Claude がミスる行だけ残す」: モデルの既定動作、harness が既に指示していること、
hook が強制していることは書かない。強調（IMPORTANT / 絵文字の優先度）は過剰発火するので使わない。
経緯・根拠は HTML コメント（context 注入前に剥がされる）に残す。`CLAUDE.md` から `@RULES.md` で import している。

## activation

`home-manager/home/default.nix` の `activation.setupClaudeCode` が以下を実施する:

1. `~/.claude/` ディレクトリ作成（無ければ）
2. `settings.json` を symlink
3. `CLAUDE.md` / `RULES.md` / `FLAGS.md` / `README.md` を symlink（存在するもののみ）
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

- `~/.claude/bin` は home-manager が zsh / fish の PATH 先頭に載せる。mise より後に足すことが要る:
  fish は `mise activate` の後に `fish_add_path --path --move`（mise は activate の後に PATH へ足したものを
  自分のツールより前に保つ。`activate_aggressive` が既定の `false` のとき。`--path` が無いと `fish_user_paths`
  経由になり、mise の hook-env がツールを前に戻す）、zsh は `initContent` で mise の shims を入れた後に
  先頭へ移し直す（`.zshenv` の `envExtra` でも入れるが、非対話の zsh 向け）。mise より前に足すと、mise で入れた
  `claude` が `bin/claude`（agent-vault の wrapper）より先に見つかる。
  `which claude` / `which gh` / `which gcloud` / `which tofu` は `~/.claude/bin/…` を指すようになる。Claude Code セッション内では加えて
  SessionStart hook `session-start-account-path.sh` が `$CLAUDE_ENV_FILE` に同じ export を書き、
  起動元の PATH に依存せず shim が効くようにする
- 同じスクリプト内で `cd org1 && gh …; cd org2 && gh …` としても各呼び出しが独立に解決される。
  `pnpm tf:init:stg` のような `cd infrastructure/terraform && tofu init …` も repo 内に留まるので同じ org で解決される
- `git push`（https）の credential helper は `~/.config/git/config.local` に `gh auth git-credential` を
  **絶対パス**で書いている（`gh auth setup-git` の形）ので shim を通らず、常に `~/.config/gh` のアカウントになる。
  agent-vault 経由のセッションでは `bin/claude` が helper を空にし、agent-vault が owner ごとに Basic 認証を付ける（下記）
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
- `gh_vault_config_dir` は agent-vault 経由のセッション（`CLAUDE_GH_VAULT=1`）で gh が使う config dir
  （下記「agent-vault」）。org に無ければトップレベルの `default.gh_vault_config_dir` を使い、未登録 org・ghq 外
  （お客さんの repo 等）も `default` になる。main 以外のアカウントを使う org だけ書き、同じ org を
  `home-manager/home/file/agent-vault/services.yaml` の git の振り分けにも書く（`tests/agent-vault.test.sh` が一致を確かめる）
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

## agent-vault（sandbox 内の git / gh の認証）

sandbox 内の git / gh に資格情報を持たせずに GitHub へ認証する。経路は
sandbox 内の git / gh → Claude Code の proxy（`allowedDomains` で通信先を確認）→
agent-vault（`127.0.0.1:14322`、認証を付与）→ GitHub。検証の経緯は dotfiles#247。
vault に入れる token は、人間の端末で `gh auth login` 済みの gh の OAuth token そのもの
（`repo` / `read:org` / `workflow` / `gist`）。新しい PAT は発行しない。届く範囲は今の gh と同じで、
お客さんの repo（outside collaborator を含む）も GraphQL を含めて動く。

| 部品 | 場所 |
|------|------|
| binary（v0.40.0 固定。更新手順は冒頭コメント） | `lib/agent-vault/default.nix` |
| LaunchAgent `com.playpark.agent-vault` | `home-manager/programs/agent-vault.nix` |
| 起動（Keychain のマスターパスワードを `--password-stdin` で渡し、CA bundle を書く） | `home-manager/home/file/agent-vault/agent-vault-server.sh` |
| services（api.github.com の placeholder 置換、git の owner 振り分け） | `home-manager/home/file/agent-vault/services.yaml` |
| gh 用の config dir（アカウントごとの `hosts.yml`。token は placeholder） | `home-manager/home/file/agent-vault-gh/<account>/` → `~/.config/agent-vault-gh/<account>/` |
| どの repo でどのアカウントか（`gh_vault_config_dir`、未登録は `default`） | `account-map.json` |
| Claude Code 本体に `HTTPS_PROXY` と CA を付ける wrapper | `bin/claude` |
| gh の token を vault に写す（人間の端末で実行） | `bin/agent-vault-sync-gh` |

`bin/claude` は `~/.claude/bin`（PATH 先頭）から実体の claude を exec する前に、
`~/.agent-vault/proxy-token` を読んで `HTTPS_PROXY` / `HTTP_PROXY` を
`http://<proxy token>:default@127.0.0.1:14322` にし、`~/.local/state/agent-vault/ca-bundle.pem`
（システムの CA + agent-vault の CA）を `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` / `GIT_SSL_CAINFO` に、
目印の `CLAUDE_GH_VAULT=1` を付ける。git の credential helper は `GIT_CONFIG_COUNT=1` /
`GIT_CONFIG_KEY_0=credential.helper` / `GIT_CONFIG_VALUE_0=`（空）で外す（空の helper は、それより前に読んだ
`config.local` の `gh auth git-credential` を一覧から消す。この helper は `~/.config/gh` を読むので sandbox 内では動かない）。
bg job を動かす daemon は claude から on-demand で起動されるので、この env を継承する。
sandbox 内のコマンドの `HTTPS_PROXY` は Claude Code 自身の proxy に置き換わるので token は見えない。
`~/.agent-vault`（DB・CA 鍵・セッション・proxy token）は `settings.json` の `denyRead` で sandbox から読めない。
token ファイルが無い・agent-vault が落ちているときは env を付けずに起動する（後者は 1 行警告）。

アカウントの選び方:

```
gh pr create（cwd = ~/ghq/github.com/<org>/repo、sandbox 内でも bg job でも）
 └─ ~/.claude/bin/gh → account-exec（CLAUDE_GH_VAULT=1）
      ├─ account-map.json の orgs[<org>].gh_vault_config_dir、無ければ default.gh_vault_config_dir
      └─ GH_CONFIG_DIR=~/.config/agent-vault-gh/<account> で gh を exec
           └─ Authorization: token __gh_<account>__ → agent-vault が vault の GH_TOKEN_<ACCOUNT> に置き換え
git push / fetch（https。sandbox 内でも bg job でも）
 └─ agent-vault が URL の owner で Basic 認証を付ける（github.com/BusinessProcessDX/* は th-it-dev、
    それ以外は main）。credential helper は bin/claude が空にしているので呼ばれない
```

- GraphQL（`gh pr` / `gh issue` の大半が最初に叩く `/graphql`）は URL に owner が出ないので、vault 側の
  path では振り分けられない。アカウントは送る側（cwd を見る account-exec）が placeholder で選ぶ
- `~/.config/gh*` は sandbox から読めず（denyRead）、gh は config dir を読めないと起動もしないので、
  placeholder の dir は `gh-` で始めない名前にしている
- placeholder を送らない client（curl・octokit 等）は api.github.com に認証なしで届く。
  placeholder を GitHub 以外のホストに送っても、置換は api.github.com の service にしか無いので置き換わらない

### 初回セットアップ（人間の作業）

`nix run .#update` の後、通常のターミナル（Aqua セッション）で行う。`bin/claude` と `bin/agent-vault-sync-gh` は
新規ファイルなので activation で `~/.claude/bin/` に張られる。

```bash
# 0. 手で起動した agent-vault（/usr/local/bin の install script 版。#247 の PoC）があれば、
#    CLI セッションを revoke し（denyRead が入る前の sandbox から使えた）、server を止めて binary と DB を捨てる。
#    PoC の DB はパスワードなしモードで作られていることがあり、そのままでは launchd 版（--password-stdin）で開けない
agent-vault auth sessions list                 # → 該当セッションを revoke
/usr/local/bin/agent-vault server stop
lsof -nP -iTCP:14321 -iTCP:14322 -sTCP:LISTEN  # 何も出なければ止まっている
sudo rip /usr/local/bin/agent-vault            # /usr/local/bin は root 所有なので sudo
rip ~/.agent-vault                             # PoC の DB・CA（新しく作り直す）
# 1. マスターパスワード（DB の暗号鍵を守る。launchd の起動スクリプトが使う）を 1Password で生成・保存し、
#    同じ値を login keychain に置く。launchd が起動すると、このパスワードで新しい DB が作られる
security add-generic-password -s agent-vault -a master-password -w
launchctl kickstart -k gui/$(id -u)/com.playpark.agent-vault
tail -n 2 ~/.local/state/agent-vault.err.log   # "wrote CA bundle: …" が出れば起動している
#    owner アカウント（CLI・Web UI のログイン用。マスターパスワードとは別の値にして 1Password に保存）を作り、
#    以後の自己登録を閉じる（管理 API の 127.0.0.1:14321 は sandbox からも届くので、開けたままにしない）
agent-vault auth register
agent-vault owner config set --invite-only
agent-vault owner config get                   # invite_only: enabled
# 2. credential: gh にログイン済みの token（main と th-it-dev）を写す
agent-vault-sync-gh
# 3. services
agent-vault vault service set -f ~/ghq/github.com/it-all-playpark/dotfiles/home-manager/home/file/agent-vault/services.yaml
# 4. Claude Code 用の agent と proxy token
agent-vault agent create claude-code --vault default:proxy --token-only > ~/.agent-vault/proxy-token
chmod 600 ~/.agent-vault/proxy-token
# 5. 起動中の claude と daemon を止めて、wrapper（~/.claude/bin/claude）経由で起動し直す（下記）
```

#### claude と daemon の起動し直し

bg job は daemon の env を受け継ぎ、daemon は最初に `claude agents` / `claude --bg` を実行した claude の env で
立ち上がる。`claude agents` は動いている daemon があればそれに接続するだけなので、claude を抜けて入り直しても
daemon は古い env（`HTTPS_PROXY` も `CLAUDE_GH_VAULT` も無い）のまま残る。daemon が事前に起動しておく
予備のプロセス（`claude bg-pty-host` / `claude bg-spare`）も同じ env で、親の daemon が終わっても PID 1 の下に残る。
これらを止めてから起動し直す。daemon を止めるコマンドは `claude` に無いので、プロセスを止める
（動いている bg job はすべて終了する）:

```bash
pkill -f 'claude daemon run'
pkill -f 'claude bg-pty-host'
pkill -f 'claude bg-spare'
ps -axo pid,command | grep -E '[c]laude (daemon|bg-)'   # 何も出なければ止まっている

# 新しいタブで（既存の zsh は claude の場所を覚えていることがあるので、使うなら rehash してから）
which claude                      # ~/.claude/bin/claude（~/.zshenv / fish の設定が PATH の先頭に置く）
claude agents --cwd "$(pwd)"      # wrapper の env を持った daemon が新しく起動する
ps eww -p "$(pgrep -f 'claude daemon run')" | tr ' ' '\n' | grep -cE '^(CLAUDE_GH_VAULT|HTTPS_PROXY)='   # 2
```

状態は `launchctl print gui/$(id -u)/com.playpark.agent-vault` と `~/.local/state/agent-vault.err.log` で見る。

- `gh auth login` / `gh auth refresh` / token の revoke の後は `agent-vault-sync-gh` をもう一度実行する
  （vault の写しが古いと gh・git が 401 になる）
- proxy token を替えるときは `agent-vault agent rotate claude-code` の出力で `proxy-token` を書き換え、
  上の「claude と daemon の起動し直し」をする（daemon と予備のプロセスを止めないと、bg job は古い token のまま 407 になる）

### 実機での確認（初回セットアップ後）

通常のターミナルで、wrapper を通さずに agent-vault の経路だけを確かめる:

```bash
tok=$(tr -d '[:space:]' < ~/.agent-vault/proxy-token)
p="http://$tok:default@127.0.0.1:14322"
# gh: placeholder が置き換わり main / th-it-dev が返る
HTTPS_PROXY=$p SSL_CERT_FILE=~/.local/state/agent-vault/ca-bundle.pem GH_CONFIG_DIR=~/.config/agent-vault-gh/main gh api user --jq .login
HTTPS_PROXY=$p SSL_CERT_FILE=~/.local/state/agent-vault/ca-bundle.pem GH_CONFIG_DIR=~/.config/agent-vault-gh/th-it-dev gh api user --jq .login
# git: owner ごとの Basic 認証（BusinessProcessDX の private repo で th-it-dev、それ以外で main）。
# credential helper を外して、vault の認証だけで通ることを見る
HTTPS_PROXY=$p GIT_SSL_CAINFO=~/.local/state/agent-vault/ca-bundle.pem GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= ls-remote https://github.com/BusinessProcessDX/<private-repo> HEAD
HTTPS_PROXY=$p GIT_SSL_CAINFO=~/.local/state/agent-vault/ca-bundle.pem GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= ls-remote https://github.com/playpark-llc/<private-repo> HEAD
unset tok p
```

gh 2.102（Go）は macOS でも `SSL_CERT_FILE` の bundle で agent-vault の CA を信頼した（2026-10-08 に確認。
login keychain に CA を信頼させる必要は無かった）。将来 `x509: certificate signed by unknown authority` で
落ちるようになったら、`security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db
~/.agent-vault/ca/ca.crt.pem` で信頼させる（ユーザーのすべての TLS 通信でこの CA が信頼されるようになる）。

Claude Code のセッション内（wrapper 経由で起動）で:

```bash
ls ~/.agent-vault                 # Operation not permitted になる
agent-vault vault credential list # 失敗する（管理 API に sandbox から認証できない）
ps eww -p $PPID                   # 失敗するか、HTTPS_PROXY（proxy token 入り）が見えない
                                  # （見えると 14322 経由で allowedDomains を迂回できる）
echo "$CLAUDE_GH_VAULT"           # 1
gh api user --jq .login           # cwd のアカウント（BusinessProcessDX の repo では th-it-dev）
gh pr list --limit 1              # GraphQL が通る（playpark-llc・お客さんの repo でも）
git config --get-all credential.helper; echo "rc=$?"   # 何も出ず rc=1（helper が空）
git fetch --dry-run               # sandbox 内で通る（git / gh は excludedCommands に無い）
git -C . ls-remote origin HEAD > "$TMPDIR/ls"; cat "$TMPDIR/ls"   # 複文・-C・リダイレクトでも同じ
GIT_TERMINAL_PROMPT=0 git fetch --dry-run && gh api user --jq .login                  # VAR=x 前置・連結でも同じ
# 書き込みを伴う git（feature branch で確かめる。.git・~/ghq への書き込みが sandbox の allowWrite で通ること）
git config --get-all branch.autoSetupMerge; git config --get push.default   # false / current（wrapper の env）
git push origin                   # vault の Basic 認証で通る。upstream が無くても同名 branch へ（-u は付けない）
git worktree add -b wt-check "$TMPDIR/wt-check" origin/main && git worktree remove "$TMPDIR/wt-check" && git branch -D wt-check   # upstream を書かずに通る
git clone https://github.com/it-all-playpark/dotfiles.git ~/ghq/github.com/it-all-playpark/clone-check   # ~/ghq 配下への clone が通る（確認後に rip で消す）
```

上の push / worktree / clone のどれかが sandbox に塞がれたら、RULES.md の Sandbox 節に代わりの手順を書くか、
その操作だけ扱いを分ける（excludedCommands に戻さない。git を sandbox 外に出すと hook・設定経由の脱出口になる）。

**起動元 repo の `.git/config` は sandbox 内から書けない**（2026-10-08、Claude Code 2.1.293 で実測）。Claude Code に
組み込まれた sandbox-runtime が、起動ディレクトリの `.git` が実ディレクトリなら `<cwd>/.git/config` と
`<cwd>/.git/hooks` を mandatory deny にする（sandbox 外で走る git に `core.fsmonitor` 等を仕込ませないため）。
runtime には `allowGitConfig` があるが settings.json のスキーマに無く、外せない。worktree は起動元の
`.git/config` を共有するので同じく書けない。別 repo（clone 先・skills-dev 等）の `.git/config` は書ける。

| 操作 | sandbox 内の結果（対処前） | 対処 |
|------|------|------|
| `git worktree add -b X <path> origin/main`・`git switch -c X origin/main`・`git switch X`（origin/X から自動作成） | upstream を書けず中断（rc 255）/ branch だけ残って rc 1 | wrapper が `branch.autoSetupMerge=false` を入れる |
| `git push -u` | push は通るが upstream を書けずにエラー表示 | `-u` を付けない。wrapper の `push.default=current` で素の `git push` が同名 branch へ |
| `gh pr checkout`（未実測。branch の upstream を `git config` で書く） | 失敗する見込み | `git fetch origin <branch>` → `git switch <branch>` |
| `git config --local` / `git remote add/set-url` | 書けない（rc 255） | 人間が通常ターミナルで行う |

bg job でも `echo "$CLAUDE_GH_VAULT"` と `gh api user --jq .login`、上の git の行（push・worktree・clone を含む）を確かめる。
あわせて git / gh を使う skill（dep-guardian・zenn-publish・qiita-publish）を 1 回ずつ流し、結果を PR に記録してからマージする。

### 決めたこと

- **token は gh の OAuth token をそのまま使う（owner ごとの fine-grained PAT にしない）**。issue #248 は owner ごとの
  fine-grained PAT（Contents / Pull requests の write）を想定していたが、fine-grained PAT は resource owner が
  1 つに限られ、outside collaborator として入っているお客さんの repo には届かない。GitHub App もお客さんの org への
  install が要る。作業する repo を選ばないことを優先し、今の gh と同じ範囲（`repo` scope）を受け入れる
- **アカウントは送る側（account-exec）が選ぶ**。agent-vault の service は host と path でしか一致せず、
  GraphQL は path に owner が出ない。session ごとに vault を分ける案は、bg job が daemon の予備プロセス
  （cwd が決まる前に起動済み）で動くので効かない。account-exec は gh のたびに cwd を見るので bg job でも効く
- **sandbox 内のプロセスは、本人の token の権限で GitHub を操作できる**。permissions.deny の gh / git のパターンは
  コマンド文字列の一致なので、スクリプト経由の API 呼び出しは止められない。api.github.com は placeholder を
  送ったリクエストにだけ token を付ける（passthrough + 置換）ので、placeholder を知らない client が偶然
  認証付きで書き込むことはない。一方 placeholder は秘密ではない（このリポジトリにある）ので、意図して使う
  コードは止められない。sandbox 内の任意のプロセスが別アカウントの placeholder を選べるのも同じで、
  どちらも本人のアカウントなので受け入れる
- **github.com の既定 service は、github.com へのすべてのリクエスト（public repo の clone を含む）に main の
  Basic 認証を付ける**。remote は `https://github.com/<Owner>/…` の正規表記を前提にする（path の一致は大文字小文字を
  区別する可能性がある）。ssh remote は sandbox から `~/.ssh` を読めないので使えない
- **wrapper を通らない起動では vault が効かない**: desktop app / IDE から起動した claude と、wrapper を通らずに
  立った daemon には `HTTPS_PROXY` も `CLAUDE_GH_VAULT` も付かない。account-exec は目印が無ければ従来の
  `gh_config_dir` を使う（人間の端末と同じ）
- **本体の env に `AGENT_VAULT_TOKEN` を出さない**。agent-vault の CLI はこれで管理 API（`127.0.0.1:14321`。
  sandbox から到達できる）に認証するので、出すと sandbox 内から credential を読めてしまう。
  sandbox からの防壁は `~/.agent-vault` の denyRead（CLI のセッション `session.json` を含む）だけ
- 未登録 host は既定の passthrough のまま（`unmatched_host_policy=deny` にしない）。sandbox 内の通信先は
  Claude Code の `allowedDomains`（`strictAllowlist`）が前段で絞っている。deny にすると、同じ proxy を通る
  Claude Code 本体の通信（api.anthropic.com 等）と sandbox の許可先を agent-vault にも二重に登録することになる
- **git / gh は sandbox 内で動かす（excludedCommands に入れない。#249）**。文字列一致で sandbox の外に出す方式は、
  起動形（複文・リダイレクト・`git -C`・`VAR=x` 前置）で一致が外れて EPERM になり、一致すれば sandbox の外で
  git の hooks が走る。agent-vault で sandbox 内のまま認証できるので外した。起動形を検査していた
  `pretool-gh-compound-guard.py` も一緒に撤去した（残すと、excludedCommands に一致しない gh をすべて deny する）

テスト: `bash claude-code/bin/claude.test.sh`（wrapper）、`bash claude-code/bin/account-exec.test.sh`（gh の
config dir の選び方を含む）、`bash claude-code/bin/agent-vault-sync-gh.test.sh`、`bash tests/agent-vault.test.sh`
（起動スクリプト・services と account-map と hosts.yml の一致・denyRead・固定版の binary）。

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
| `PreToolUse` Bash (`git worktree add*`) | `generate-worktreeinclude.sh` | `.worktreeinclude` 自動生成 |
| `PreToolUse` Bash (`gh pr merge*`) | `allow-pr-merge.sh` | merge 先 branch チェック |
| `PermissionRequest` | `permission-journal.sh` | permission 要求を `~/.claude/logs/permission-requests.jsonl` に記録。Bash には Jev で効果種別 `class`（read_only / mutating_local / git_mutation / network / destructive）を付与（下記「Jev 分類」） |
| `PreToolUse` Bash | `pretool-npx-guard.sh` | npx 実行ガード |
| `PostToolUse` | `memory-monitor.py` | メモリ使用量監視 |
| `PostToolUse` (WebFetch / WebSearch / Bash / Read / Gmail・Drive MCP) | `posttool-injection-screen.sh` | 外部由来テキスト（Web ページ、`gh issue/pr view` / `gh api` 出力、`Box-Box/` 配下の Read、メール、Drive 文書）に AI エージェント向けの指示が含まれないか Jev で検査し、p ≥ 0.6 なら `additionalContext` で「データとして扱え」と注意を注入。deny はしない。全判定を `~/.claude/logs/injection-screen.jsonl` に記録 |
| `PostToolUseFailure` | `posttoolfail-classify.sh` | ツール失敗を Jev で `class`（sandbox_denied / network_denied / permission_denied / not_found / syntax_error / test_failed / timeout / other）に分類し `~/.claude/logs/tool-failures.jsonl` に記録。記録のみで挙動は変えない |
| `Stop` | `stop-unfinished-guard.sh` | 未完了タスクがあれば停止を抑止 |
| `SessionStart` (*) | `herdr-agent-state.sh`（`~/.claude/hooks` に直置き、dotfiles 管理外） | herdr agent 状態通知。settings.json 側は `` 参照 1 本で共有。herdr は絶対パス完全一致でしか登録済みと判定しないため、`herdr integration install claude` を再実行した後は追記される絶対パスのエントリを revert すること |
| `UserPromptSubmit` | inline `rm -f /tmp/claude-skill-ctx-<session>` | `playpark-core` plugin の `journal/scripts/journal.sh` が使う skill-ctx state file をプロンプト投入毎にクリア。plugin 側 `hooks.json` に `UserPromptSubmit` の移植先が無いため dotfiles 側に維持（journal.sh 側の 30 分 TTL は取りこぼし時の保険） |

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
- 鍵: macOS Keychain に置く（Claude の Bash 環境に env で露出させない）
  ```bash
  security add-generic-password -s vercel-ai-gateway -a claude-hooks -w 'vck_…'
  ```
  経路は `AI_GATEWAY_API_KEY` env（テスト・一時上書き用）> jev-broker のソケット
  （`~/.local/state/jev-broker/jev.sock`）> Keychain の直接読み出し、の順。Keychain の解除は
  監査セッションごとに効くので、sandbox 内の Bash と bg job からは解除済みでも `security` が
  exit 36 になる。gui ドメインの LaunchAgent `com.playpark.jev-broker`
  （`home-manager/programs/jev-broker.nix`）が鍵をメモリに持って中継するのはこのため。
  broker の状態は `launchctl print gui/$(id -u)/com.playpark.jev-broker` と
  `~/.local/state/jev-broker.err.log` で見る
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
