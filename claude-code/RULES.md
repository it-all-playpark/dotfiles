# Rules

<!--
保守メモ: この節以下は毎セッション context に載る。1 行ごとに「消したら Claude がミスるか」で判断し、
ミスらないもの（モデルの既定動作、harness の system prompt が既に言っていること、hook が強制していること）は書かない。
経緯・根拠は block-level の HTML コメントに書く（注入前に剥がされるので token を食わない）。
強調（IMPORTANT / MUST / 絵文字の優先度）は Opus 4.5 以降で過剰発火するので使わない。
-->

## Engineering
- 失敗は根本原因を直す。テストや検証を skip / 無効化 / 期待値の緩和で通さない
- テストは実装を外せば落ちる形で書く。同じ事実を検証する既存テスト・helper があればそこに足し、重複させない。撤去したものが「無い」ことだけを確かめるテストは書かない
- スコープは頼まれた範囲まで。隣接リファクタ・投機的な一般化・不要な抽象化 / fallback / validation を足さない
- issue は実測できる事実を実測してから立てる（再現・数値・どの経路を通るか）。測れなかった部分は「未検証の仮説」と明記して事実と分ける
- レポート・分析の成果物は `claudedocs/` に置く
- 削除は `rip`（復元できる）

<!--
テスト・スコープの 2 行は dev-flow の dev-implementer（skills repo plugins/dev-flow/agents/dev-implementer.md）の
「守ること」から汎用部分だけを写したもの。plugin は RULES.md 無しでも動く必要があるので、向こうからは消さない（重複は意図的）。
「触ったテストだけ走らせる」「曖昧さは聞かずに codebase で決める」「削除は git rm」はパイプライン前提で対話作業と逆になるので写さない。
-->

## Subagents / Workflow
- 各ステージは作業の重さでモデルを選ぶ。検索・grep 集約・機械的編集は haiku、判断（verify / judge / synthesize）だけ opus
- 指定しないとセッションのモデルと effort を継承するので、軽いステージほど明示する。effort は agent 定義の frontmatter でしか効かない（`agent()` の opts は無視される）
- 単発で済む作業は Workflow にせず直接ツールを叩く（ultracode でも同じ）

## Tool routing
20KB 超の構造化ファイルや 100KB 超の全読みは `playpark-core` の hook が止めて代替を示す。以下は hook が検知できないので自分で選ぶ:
- コードベースの概観 → `tokei`
- 同じパターンを 3 箇所以上書き換える（rename・API 移行）/ grep に偽陽性が混ざる → `ast-grep`
- 機械的な文字列置換 → `sd`
- フォーマッタ適用前後で挙動が変わらないことの確認 → `difft --exit-code old new`
- 速い / 遅いの主張 → `hyperfine` で測る
- `python3 -c` / `node -e` / `curl` / `rm -rf` は permissions.deny で止まるので最初から使わない → コードは Write で `$TMPDIR` に書いて `python3 "$TMPDIR/x.py"`、HTTP の確認は WebFetch、削除は `rip`

## Git
- 保護ブランチ（main / dev / production 等）には push せず、feature branch から PR を出す。`保護/デプロイブランチ (...) への push は禁止` で止まったら sandbox ではなく `allow-feature-push.sh` hook
- PR / issue コメントの編集は `gh api -X PATCH` ではなく `gh pr comment <N> --edit-last --body-file <file>` / `gh issue comment <N> --edit-last --body-file <file>` を使う（`gh api -X PATCH` は permissions.deny で止まる）
- dotfiles の PR を merge したあとメイン checkout に取り込むときは、host-exec で `dotfiles-sync` だけを実行する。止まったら人間に判断を渡す

<!--
保護ブランチ判定は allow-feature-push.sh（PreToolUse）が唯一の強制点。9 ブランチ（main / master / dev / develop /
development / production / staging / release / nightly）を、git -C / :main / --delete / --mirror まで含めて判定する。
permissions.deny 側の規則は 2026-08-16 に撤去: `Bash(git push *:main)` のような引数を glob で絞る規則は実測で一致せず、
公式も「引数を制約する Bash permission パターンは fragile。PreToolUse hook を使え」としているため。
-->

## Sandbox
コマンド側で避ける:
- bg セッションでも一時ファイルは `$TMPDIR`。`$CLAUDE_JOB_DIR/tmp` は system prompt が案内しても書けない（`~/.claude/jobs` は組み込みガードで write deny）
- process substitution `<(…)` は使わない（`/dev/fd/*` が塞がれる）。tempfile に落としてから渡す
- `~/.claude/skills` を repo への symlink にしない（skill は playpark marketplace の plugin で読み込む）。Claude Code の組み込み保護は `~/.claude/skills` の symlink 先にも掛かり、repo ルートを指すと `.git` ごと書けなくなって commit・worktree が sandbox 内で動かない
- Bash から書けない場所。編集は Edit / Write ツールで行う:
  - sandbox 外で実行されるので書き換えが脱出口になる: dotfiles メインチェックアウトの `claude-code/bin` / `claude-code/hooks`、全 repo の `.husky`・`.githooks`（dotfiles の 2 つは worktree 側なら Bash でも書ける）
  - Claude Code が読み込む指示なので、書き換えると次の session（無人の定期タスクを含む）の振る舞いが変わる: 全 repo の `.claude/skills`。作業中の repo とその上位の `.claude/skills`・`.claude/hooks`・`.claude/agents`・`.claude/commands` は Claude Code の組み込み保護で、設定では外せない（worktree でも同じ）。denyWrite の `~/ghq/*/*/*/.claude/skills` は作業中でない repo のメイン checkout まで同じ保護を広げる（`<repo>/.claude/worktrees/*` は含めない）
- `~/ghq` 深さ 3 の全 repo（`~/ghq/<host>/<org>/<repo>`）の `.git/config`（worktree も共有）・`.git/hooks`・`.claude/settings*.json`・`.claude/hooks` は書けない（起動元 repo は Claude Code の組み込み保護で設定で外せず、他の repo は settings.json の denyWrite）。`~/ghq/<host>/<org>/` への新規 clone は host-exec の `ghq get` か人間が行い、pull / switch で `unable to unlink old .claude/settings*.json` が出たら、その repo を起動元にするか host-exec でやり直して `git status` を確かめる。push は `-u` を付けず素の `git push`（wrapper が `push.default=current` / `branch.autoSetupMerge=false` を入れている）、PR の branch は `gh pr checkout` ではなく `git fetch origin <branch>` → `git switch <branch>`。`git config --local`・remote の変更は人間に頼む
- `.githooks` / `.husky`（denyWrite）や組み込み保護の対象ファイル（`.ripgreprc` 等）を追跡する repo の worktree は、`git worktree add` ではなく `wt-add <repo> <path> <branch> [<start>]`（`~/.claude/bin`）で作る。取り出せないパスに skip-worktree を付け、付けたパスを stdout に出す。既存の worktree でブランチを切り替えて取り出せないパスが増えるときも、`git switch` ではなく新しく wt-add で作る
- `nix fmt` は `nix fmt -- --no-cache`（treefmt のキャッシュ書き込みが落ちる）
- `neonctl` は `--no-analytics` を付ける（テレメトリ先が未許可で終了時に待たされる）。`neonctl auth` は通常ターミナルで人間が行う
- `&` で起動したプロセスは名前で止められない（`pkill` / `killall` はプロセス一覧が塞がれて落ちる）。CPU 負荷などの道具は `timeout 60 yes > /dev/null &` のように寿命を付けるか、`$!` を控えて同じ呼び出しの中で `kill` → `wait` する。取り残したら `/usr/bin/pgrep -l <名前>` で PID を確かめ、`! kill <PID>` を示して人間に止めてもらう（下の「プロセス調査」）

worktree 隔離中（bg job・dev-flow の `df-*`）は、組み込みガードが「git に届かないと証明できない」コマンドを拒否する（設定では外せない）。拒否されない形で書く:
- cwd はもう自分の worktree。`cd <worktree> &&` や `git -C` を付けず相対パスで叩く。git は素の形で 1 呼び出し 1 コマンド（`&&` 連結・`$(git …)` も拒否）
- ファイル作成は heredoc（`cat > f <<'EOF'`）ではなく Write ツール
- 変数は必ずダブルクォート（`"$TMPDIR/x"`）。`$(…)` の結果を変数に入れて渡す形、`HOME=` 前置、`source` / `eval` を含む形も拒否される。`nix eval` も名前だけで拒否されるので、隔離中は `nix flake check` / `nix build` で確かめる

使えるもの:
- nix（daemon socket 許可済み）: nix を書いたら apply 前に `nix build` / `nix flake check` で自分で確かめる。ただし daemon は sandbox 外なので、nix 経由の取得は `allowedDomains` の制限を受けない。未知の flake や URL は通常の外部アクセスと同じ慎重さで扱う
- Jev: `~/.local/state/jev-broker/jev.sock` 経由。sandbox 内では Keychain が exit 36 で読めないのが正常なので、ロック解除を試さない
- docker-vm: sandbox 内から書き込み系も含めて使う docker。sandbox-docker VM の rootless docker に繋がる。VM に mount しているのは `/private/tmp/claude` だけなので、repo のファイルは build context か `docker cp` で渡す。Docker Hub のイメージは `docker-vm build` がそのまま取れるが、それ以外のレジストリ（ghcr.io 等）のイメージは build の前に `docker-vm pull` しておく（sandbox はそのレジストリのトークン発行先を許可していない）。VM の外向き通信は許可リスト（settings.json の `allowedDomains` と VM 専用の追加分 `home-manager/home/file/vm-egress-proxy/vm-domains.txt` の和）に一致するホストにだけ、ホスト側のプロキシ（VM からは `http://192.168.5.2:3128`）を通して出られ、VM の DNS は外の名前を引かない。VM の dockerd・apt と、`docker-vm run` / `docker-vm build` のコンテナ（build の RUN を含む）には `HTTPS_PROXY` / `HTTP_PROXY` が自動で入る（CONNECT を使わない busybox の `wget` は HTTPS が 400 になるので curl 等を使う）。取れないホストは `~/.local/state/vm-egress-proxy.err.log` の `denied` の行で確かめ、sandbox にも要るものは settings.json の `allowedDomains` に、VM だけに要るものは `vm-domains.txt` に足す
- docker-sb: OrbStack（ホストの docker）の状態を読む読み取り専用の docker。素の `docker` は sandbox に拒否されるので、host-exec や人間に回さず最初から `docker-sb` を使う。`docker-sb ps` / `images` / `inspect` / `stats --no-stream` / `logs` / `top` / `info` / `system df` が sandbox 内で動く（docker-proxy が読み取りの GET だけを OrbStack に中継する）。`logs -f` と `--no-stream` なしの `stats` は通らず、inspect の応答からは `Config.Env` が取り除かれる。書き込み系（`run` / `stop` / `rm` / `rmi` / `prune` / `build` / `exec` 等）は proxy が 403 を返すので docker-sb では通らない。コンテナを動かす作業は `docker-vm` で行い、ホスト（OrbStack）のコンテナの停止・削除は人間に頼む
- Postgres: sandbox 内で `initdb` は使わず、`pg-broker` に頼む。sandbox-docker VM（`docker-vm`）に digest 固定の postgres コンテナを起動する。`pg-broker create` が返す `database_url`（`127.0.0.1:5500〜5599`。`app` は superuser だが動くのは VM の中だけ、TTL 90 分・同時 4 つまで）に繋ぎ、終わったら `pg-broker delete <id>`
- プロセス調査: 絶対パスで単独に叩くと sandbox 外で動く（`/usr/bin/top` `/usr/bin/pgrep` `/usr/sbin/lsof`）。`ps` は使わない（環境変数を出せるので hook が deny する）。一覧・CPU・メモリは `/usr/bin/top -l 1 -o mem -n 15 -stats pid,ppid,command,cpu,mem,time`、引数まで含むコマンドラインは `/usr/bin/pgrep -lf <pattern>`。見るだけで、止めるのは人間（PID を特定して `! kill <PID>` を示す）。bare 名・`| head` などのパイプ・リダイレクトを付けると sandbox 内に戻って EPERM になるので、件数は引数で絞る。メモリ総量は sandbox 内でも `memory_pressure -Q` / `vm_stat` で見える
- pnpm と dev サーバー（localhost listen）は sandbox 内で動く。pnpm や docker を `excludedCommands` で sandbox 外に出さない（postinstall が `~/.ssh` や gh の資格情報を読める / docker socket はホスト権限相当）
- Postgres を使う E2E（Playwright 等）も sandbox 内で回す。人間や CI に回さない。DB は自分で docker compose や initdb で立てず、`pg-broker create` の `database_url` を、その repo が外部 DB を受け取る口（環境変数等。repo のテスト手順書で確かめる）に渡す。終わったら `pg-broker delete <id>`
- 依存の install が postinstall / prepare の書き込みで EPERM になったら（`.husky` 等の denyWrite・`~/.cache/<tool>` 等の書けない場所）、その tool の無効化用の環境変数（husky は `HUSKY=0`）を付けるか、キャッシュを `XDG_CACHE_HOME="$TMPDIR/<一意名>"` に向けて入れ直す

sandbox に塞がれたら:
- その場で回避せず、原因を特定して settings.json を直す。「編集できない」「手で足してください」とは返さない。dotfiles に worktree を切れば `claude-code/settings.json` は Edit ツールで編集できる（`denyWithinAllow` は Bash にしか効かない）。commit message と PR 本文まで用意し、許可を広げる変更は差分と理由を PR 本文に書いて merge 判断で確認を取る
- `excludedCommands` に足してよいのは、sandbox 内から書けない場所にある実体だけ（mise / nix / plugin の `bin/` の CLI）。書ける場所（repo の作業ツリー・worktree・`$TMPDIR`）のスクリプトや、任意のファイルを実行するランナー（`bats`、`bash <相対パス>`）を足すと、書き換えて sandbox 外で実行できる脱出口になる。そうしないと動かない作業は、sandbox 内で動くように作業場所か手順を変える
- uv を使うものを `excludedCommands` に足すときは、その起動で `UV_CACHE_DIR` を外す（settings.json の `env` は sandbox 外の起動にも渡り、sandbox 内から書けるキャッシュ `/private/tmp/claude/uv-cache` を sandbox 外で読ませることになる）
- plugin のスクリプトは bare 名（plugin の `bin/` 経由）か絶対パスの 1 本だけで足す。`<dir>/*` のようなパスの glob は `*` が `..` にも一致し、`<dir>/../../<書ける場所>/x.sh` で任意のスクリプトが sandbox 外で走る
- sandbox を広げる変更（`allowMachLookup`・`allowUnixSockets`・`allowedDomains`・`excludedCommands` 等）は、広げた口の悪用を防ぐ手当てまで dotfiles（`nix run .#update`）で完結するものだけにする。手当てに dotfiles の外（システム拡張・GUI での許可・MDM）が要るものは入れず、repo 側か手順で直す。設定が分散すると、片方だけ外れても気付けない
- auto mode classifier が settings / RULES の commit を Self-Modification として止めたら回避しない。worktree パスと実行コマンド（commit → push → PR）を渡して止まる
- Unix ソケットへの接続は `filesystem.allowWrite` では開かない。`sandbox.network.allowUnixSockets` にパスを足す（`allowAllUnixSockets` は使わない）

<!--
経緯メモ（context には載らない）:
- nix daemon socket: 2026-08-21 許可。CLAUDE.md の「agent の検証範囲は nix fmt / nix flake check / nix eval」を実際に機能させるため。
  fixed-output derivation のビルダーは設計上ネットワーク自由なので egress の抜け道になる。
- Jev: 2026-09-26。API 鍵は login keychain にあるが、Keychain の解除は監査セッション単位なので sandbox 内の Bash と
  bg job からは解除済みでも `security` が exit 36。gui ドメインの LaunchAgent（home-manager/programs/jev-broker.nix）が
  鍵をメモリに持って中継する。代償: ソケットに届くプロセスは Jev を課金付きで呼べる（鍵と他モデルには届かない）。
- pg-broker: 2026-10-07（issue #243）。sandbox 内では initdb の shmget が EPERM。LaunchAgent（home-manager/programs/pg-broker.nix）が
  sandbox 外で cluster を起動し、非 superuser の app だけを pg_hba で通す（superuser は COPY TO PROGRAM で sandbox 外を実行できる）。
  allowUnixSockets のディレクトリ指定は配下（3 階層下まで確認）のソケットにも効く（実測。リストに無いパスは bind / connect とも EPERM）ので
  `~/.local/state/pg-broker/sock` を 1 行で足した。代償: ソケットに届くプロセスは使い捨て DB を 4 つまで作れる。
  依頼口は専用コマンド `pg-broker`（pg_broker_client.py、nix store に置く）。permissions.deny の `Bash(curl *)` は allow より強く、
  broker.sock 宛てだけを許す書き方が無いため。curl の deny は外さない。
  2026-10-17（issue #338）: sandbox-docker VM（#336）の postgres コンテナに置き換え、LaunchAgent と allowUnixSockets の
  pg-broker の 2 行を撤去。superuser の COPY TO PROGRAM も VM の中で実行される（実測）。コマンドと create / delete の契約は同じ。
- pnpm: pnpm 12 は store の operation lock を TMPDIR を無視して /tmp/pnpm-store-operation-locks-<uid>/ に作る。
  allowWrite に `/private/tmp/pnpm-store-operation-locks-*` と `…-*/*` の両方が要る。glob を含むエントリはそのパス自体にしか
  一致せず、`-*` だけだと既存の all-stores.lock を開き直す 2 回目以降が落ちる。`-*/**` は末尾 `/**` が剥がされて `-*` と同じ。
  エラー文は相対名 "pnpm-store-operation-locks" しか出さず ERR_PNPM_STORE_DIR_OPEN_OPERATION_LOCK になる。
  /tmp 全体は hook が読む claude-skill-ctx-* や bridge のソケットと共有する領域なので開けない。
- dev サーバー: 2026-09-25 `network.allowLocalBinding: true`。外向き通信の制限は変わらない。
- neonctl: 2026-09-29 console.neon.tech / oauth2.neon.tech と ~/.config/neon を許可（API とトークン更新の書き戻し分だけ）。
  track.neon.tech は未許可なので --no-analytics がないと closeAndFlush が拒否された送信を待つ。
  代償: sandbox 内のプロセスが Neon の API を持ち主の権限で叩ける（branch / DB の削除も可能）。
- nix fmt: treefmt が ~/Library/Caches/treefmt にキャッシュ DB を書こうとして落ちる。allowWrite に足せば通るが、キャッシュなので --no-cache で足りる。
- uv: 2026-10-15（issue #317）sandbox 内の uv run は ~/.cache/uv を初期化できず exit 2。env の UV_CACHE_DIR を /private/tmp/claude/uv-cache に
  向けた。~/.cache/uv を allowWrite に足すと sandbox 外の uv が使うキャッシュを sandbox 内から書き換えられるので足さない。
  /private/tmp/claude は Claude Code の組み込みで書けるが、settings.json の allowWrite にも明示した（組み込みが変わっても cache が書ける）。
- ホーム基点の excludedCommands は `~/` で書く（絶対パスへの展開は agent-vault-managed-env が
  managed-settings.d/60-home-paths.json に書く。`/Users/<name>` の直書きはテストで落ちる）。
- 2026-10-14 plugin cache の glob（`~/.claude/plugins/cache/playpark/*` の bare / bash / python3 形）を撤去: `*` が `..` に一致し、
  `bash ~/.claude/plugins/cache/playpark/../../../../../../private/tmp/claude-501/x.sh` で $TMPDIR のスクリプトが sandbox 外で
  走ることを実測した。cache 内にも local-verify / run-tests / pr-push など作業ツリーのコードを実行する bin があり、bare 名では
  UNREGISTERED_BINS にしているのにフルパスで素通りしていた。30 日の transcript でフルパス実行は 3,481 回中 1 回（mem-triage）。
  sandbox 外が要る mem-triage（/bin/ps）と generate-thumbnail（codex）は plugin の bin/ に足して bare 名で登録した。
  同日、corporate-site の daily-blog-factory/scripts/*（bare / bash / bash $HOME、worktrees/** 版の 6 行）も同じ形なので撤去し、
  SKILL.md が sandbox 外を要すると挙げる preflight / harvest_topics / seed_harvest / format_gate / premise_gate の 5 本だけを
  `bash ~/…/scripts/<name>.sh` の絶対パスで登録した（.claude/skills は Bash から書けない）。worktree 版は glob なしでは書けないので外し、
  worktree からの実行は sandbox 内に落ちる。
- 2026-10-15 corporate-site の daily-blog-factory 5 本（10 行）も撤去: 外に出していた理由（gh / git fetch の資格情報、Jev の Keychain の鍵）は
  agent-vault と jev-broker で sandbox 内で解決済みと実測（gh auth status・git fetch・Jev classifier=jev）。repo 側の
  jev-classify 参照の追随と、需要センサーの allowedDomains は corporate-site のプロジェクト settings で持つ。
  これで denyWrite の `~/ghq/**/.claude/skills` は脱出口を塞ぐ役を失ったが、Claude Code が読み込む指示を守る役で残す
  （組み込み保護は作業中の repo とその上位にしか掛からない）。
- 2026-10-16 qiita-publish / zenn-publish の除外（4 行）を撤去: corporate-site の .claude/skills へ移って plugin の bin/ から消え、
  PATH 上に実体が無かった。実体の無い bare 名の除外は、PATH に同名を置ければ sandbox 外で走る口になる。
- 2026-10-21（PR #373）dep-guardian-{discover-prs,test-pr,merge-prs} の除外（6 行）を撤去: dep-guardian skill の撤去で plugin の bin/ から消え、
  PATH 上に実体が無かった。理由は qiita-publish / zenn-publish と同じ。
- 2026-10-16 denyWrite の `~/ghq/**/.claude/skills` を `~/ghq/*/*/*/.claude/skills` に絞る: `**` が
  `<repo>/.claude/worktrees/<name>/.claude/skills` にも一致し、wt-add が取り出せず corporate-site の worktree から push すると
  pre-push のテストが毎回落ちていた。denyWrite の glob は配下にも効く（作業中でない repo の既存 .claude/skills へのファイル作成が
  EPERM になるのを実測）。worktree は作業中なら組み込み保護が掛かる。
- 2026-10-21（issue #366）denyWrite に `~/ghq/*/*/*/` の `.git/hooks`・`.git/config`・`.claude/settings{,.local}.json`・`.claude/hooks` を追加:
  組み込み保護は起動元 repo しか塞がず、他 repo のこれらへの `: >>` が sandbox 内で通った（下の 2026-09-30 の「既に塞いでいる」は起動元だけの話）。
  `**` にしないのは skills と同じ理由。permissions.deny の `Write(path)` は参照されないので `Edit(path)` で書く。
- 2026-10-08 ~/.claude/skills の symlink 撤去: plugin 化後も ~/.claude/skills → skills repo ルートの symlink が残り、組み込み保護が
  skills/.git まで及んで dev-flow の commit が index.lock EPERM で止まっていた（skills#871）。symlink は skill を 1 つも提供して
  いなかった。撤去で skills checkout が書けるようになるので、checkout 配下の excludedCommands 5 件と live checkout 用の git guard hook も外した。
- 2026-09-30 脱出口の封鎖: skills-wt/*・`bats:*`・`bash tests/run-all-bats.sh` の除外を撤去。skills-wt の worktree は git メタデータが
  保護された skills/.git にあり sandbox 内で git すら動かないため、作業全体を除外で逃がしていた（30 日で 1,000 回超、エージェント自作の
  使い捨てスクリプトも sandbox 外で走っていた）。通常 clone（skills-dev）なら vitest 2573 件・bats 47 ファイル・sync-inlines・
  worktree / commit が全部 sandbox 内で通ることを実測して移行。あわせて dotfiles の claude-code/bin・hooks（hook と gh shim の実体）、
  **/.claude/skills（daily-blog-factory の除外先）、**/.husky（hooksPath が作業ツリー内。素の git commit で sandbox 外実行されることを実測）を
  denyWrite。husky の install は sandbox 内だと git config が先に拒否されて何も書かずに返るので影響しない。
  Claude Code 側が既に塞いでいるもの（実測）: ~/ghq 配下の .git/hooks・.git/config への書き込み、git config / git worktree / git init --template
  の sandbox 実行、PATH 上のディレクトリへの書き込み。
- 2026-10-05 dotfiles の .githooks（pre-commit: 整形、pre-push: flake check + tests/run-all.sh）: .git/hooks の shim が作業ツリーの
  .githooks を呼ぶ。Claude の git は sandbox 外なので、shim は CLAUDECODE=1 なら何も呼ばない（Claude の push は CI が検査）。
  shim は sandbox から書けない .git/hooks にあるのでこの判定は外せない。.githooks 自体も **/.githooks として denyWrite。
- 2026-10-14 dotfiles の .githooks を Claude でも動かす（#307）: #249 以降 git は sandbox 内なので、shim は CLAUDECODE=1 でも
  .git/hooks に probe を書けなければ（= sandbox 内）hook を実行し、書ければ（= excludedCommands 経由の sandbox 外）何もしない。
  あわせて uid 501 の sandbox TMPDIR に socket 専用の /private/tmp/claude-501/sock を allowUnixSockets に足した（pg-broker のテスト用）。
- dangerouslyDisableSandbox は policy で無効。
- 2026-10-08 git / gh を excludedCommands から撤去（issue #249）: agent-vault（dotfiles#248）で sandbox 内のまま GitHub に
  認証できるようになったため。起動形（cd X && / VAR=x 前置 / リダイレクト / git -C）で一致が外れて EPERM になる問題と、
  一致すると git の hooks が sandbox 外で走る問題が両方なくなった。「gh を呼ぶ skill スクリプトは bare 形で」のルールと
  pretool-gh-compound-guard.py を削除。worktree 隔離ガードの書き方（上の節）は Claude Code 組み込みの別物なので残す。
- 2026-10-08 プロセス系を excludedCommands に追加: sandbox 内では ps / top が setuid の exec で EPERM、pgrep / pkill が
  "sysmond service not found"、lsof は自プロセスのみ、kill は sandbox 外のプロセスに EPERM（実測）。メモリ逼迫時に原因プロセスを
  特定・停止できなかった。どれも SIP 保護下で書き換え不可。PATH 解決で別物に化けないよう絶対パスだけで登録する。
  見るだけに留め、kill / pkill は登録しない: sandbox 外の kill は持ち主の任意プロセスに signal を送れ（`kill -9 -1` で全プロセス、
  `pkill -f node` で Claude 本体・他セッション）、歯止めが auto mode の判定だけになる。取り残し対策は寿命ルール（#268）で先回りする。
  寿命ルールのきっかけ: 2026-10-08 に負荷用の `yes` 16 本が 8 時間残り、Mac が詰まった。
- 2026-10-09 /bin/ps を excludedCommands から撤去（issue #274）: macOS の ps は `e` / `-E` で他プロセスの環境変数を出し、sandbox 外で
  wrapper が Claude 本体に渡す HTTPS_PROXY（agent-vault の proxy token）が読めた。excludedCommands は前方一致の glob なので option を
  絞っても後ろに -E を足せ、permissions.deny で BSD 形式の組み合わせを網羅するのも fragile なので除外そのものを外した。
  top（-stats の key に環境変数が無い）/ pgrep -lf（引数まで）で用途は足りる。pretool-ps-guard.sh は ps をどの形でも deny する。
- 2026-10-13 `com.apple.trustd.agent`（`allowMachLookup` / `enableWeakerNetworkIsolation`）は入れない（#302 で close）: OS の trust store で
  TLS を検証するツール（Turbopack の rustls-platform-verifier、Swift 等）は sandbox 内だと trust 評価自体が走らず失敗し、これを開ければ
  直る。ただし AIA / OCSP の URL を細工した証明書を検証させると、trustd がプロキシを通さずその URL へ GET する（sandbox から直接は
  deny される LAN 側 IP 宛てで実測）。trustd の取得を止める defaults キーは無く、agent はログインユーザーで動くので pf でも絞れない。
  該当ツールは repo 側で直す（corporate-site は next/font/google をやめてフォントを同梱）。
-->
