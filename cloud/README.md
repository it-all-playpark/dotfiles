# cloud/

Claude Code のクラウドセッション（claude.ai/code）を、Mac と同じく playpark の plugin・安全用の hook・dev-flow が使うツールが揃った状態で始めるための setup。クラウドのコンテナは毎回まっさらなので、環境の setup スクリプトから dotfiles を clone して `cloud/setup.sh` を呼ぶ。

## クラウド環境の setup スクリプトに書く内容

```bash
git clone --depth 1 https://github.com/it-all-playpark/dotfiles.git "$HOME/dotfiles"
bash "$HOME/dotfiles/cloud/setup.sh"
```

clone 先はどこでもよい（`setup.sh` は自分の場所から checkout のパスを決める）。

## 許可が要るホスト

環境の network 設定で、既定の許可に加えて次のホストを許可する。

| ホスト | 使うもの |
|---|---|
| `ai-gateway.vercel.sh` | `claude-code/bin/jev-classify`（hook のログ分類） |

## 鍵の置き方

クラウドには OS の sandbox が無く、エージェントの操作を止めるのは permissions の deny と hook だけになる。hook はコマンドの文字列で判定するので、エージェントが読み込んだ文書に誘導された場合に鍵の読み出しを止め切れるとは限らない。

そのため、クラウドに置くのは漏れても被害の小さい鍵に限る:

- AI Gateway の鍵は、クラウド専用に使用額の上限を付けたものにする
- 上限を付けられない鍵（ChatGPT アカウントのログイン token 等）は置かない。codex CLI はクラウドでは使わず、dev-flow の security review は claude で回す（`security_reviewer` を指定しなければ claude になる）
- GitHub の認証は環境の egress proxy が付けるので、token をコンテナに置かない

## 何が入るか

| ファイル | 役割 |
|---|---|
| `setup.sh` | bats・jq（apt-get）を入れ、`claude-code/hooks/` の hook を `~/.claude/hooks/` に、`claude-code/bin/` のコマンドを `~/.claude/bin/` に symlink し、`settings.jq` の出力を `~/.claude/settings.json` に書く。既にある settings は `settings.json.bak` に退避する。再実行しても同じ結果になる |
| `settings.jq` | `claude-code/settings.json`（Mac 版）からクラウド用の settings を作る変換定義。手で写した settings JSON は repo に置かない |
| `hooks/session-start.sh` | SessionStart hook。`CLAUDE_CODE_REMOTE=true` のときだけ、`/var/run/docker.sock` が無ければ `dockerd` を起動して最大 30 秒待つ |
| `bin/pg-broker` | `pg-broker create [--version <major>]` / `pg-broker delete <id>`。Mac 版と同じ引数と出力で、docker の `postgres:<major>` を `127.0.0.1` の 5500〜5599 に起動する |

## Mac 版の settings との違い

- **`sandbox` を外す。** クラウドのコンテナ自体が使い捨ての隔離環境で、外向き通信は環境の egress proxy が許可ホストに絞っている。Mac 版の sandbox 設定（Seatbelt・docker-vm・agent-vault 前提）はクラウドでは成り立たない。`permissions` の deny と安全用の hook は外さない
- **hook は `claude-code/hooks/` に実体があるものだけ残す。** macOS の通知（osascript）や moshi-hook のように、クラウドに実体が無い hook は落とす
- **`env.PATH` で `cloud/bin`・`claude-code/bin` の順に先頭へ足す。** settings の `env` は `$PATH` を展開しないので、後ろには `setup.sh` を実行したときの `PATH` をそのまま書く
- **`env.DOCKER_HOST` を `/var/run/docker.sock` に向ける。** `claude-code/bin/docker`（Mac の sandbox 用 shim）は繋ぎ先が明示されていれば実体の docker に素通しする
- macOS 専用の値（`~/Library/` 配下のディレクトリ等）は除き、`/private/tmp/` は `/tmp/` に読み替える

## まだ決めていないこと

- jev-classify の鍵（`AI_GATEWAY_API_KEY` を環境変数に置くか、Network secrets のヘッダ注入で足りるか）は未確認（jev-classify は鍵が無いと送信しない）
- gh の shim（`cloud/bin/gh`）は別 issue
