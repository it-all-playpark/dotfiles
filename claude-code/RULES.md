# Rules

<!--
保守メモ: この節以下は毎セッション context に載る。1 行ごとに「消したら Claude がミスるか」で判断し、
ミスらないもの（モデルの既定動作、harness の system prompt が既に言っていること、hook が強制していること）は書かない。
経緯・根拠は block-level の HTML コメントに書く（注入前に剥がされるので token を食わない）。
強調（IMPORTANT / MUST / 絵文字の優先度）は Opus 4.5 以降で過剰発火するので使わない。
-->

## Engineering
- 失敗は根本原因を直す。テストや検証を skip / 無効化して通さない
- レポート・分析の成果物は `claudedocs/` に置く
- 削除は `rip`（復元できる）

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
- リポジトリ全体をコンテキスト化 → `/repo-export`

## Git
- 保護ブランチ（main / dev / production 等）には push せず、feature branch から PR を出す。`保護/デプロイブランチ (...) への push は禁止` で止まったら sandbox ではなく `allow-feature-push.sh` hook

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
- `it-all-playpark/skills` repo（`~/.claude/skills` / `agents` の実体）は repo 内の worktree も含めて書けない。編集用の worktree は `~/.claude/bin/skills-worktree-add <branch>`（絶対パスで呼ぶ）で repo 外の `skills-wt/<branch>` に origin/main から作る。`git worktree add` は `git *` に一致しても sandbox 内で走り、skills では必ず EPERM になる。作った worktree の中では素の git で commit / push できる
- gh を内部で呼ぶ skill スクリプトは、スクリプトパスが先頭の bare 形か `bash <path>` / `python3 <path>` で呼ぶ。`cd X &&` や `VAR=x` 前置の形は `excludedCommands` に一致せず、sandbox 内で gh の資格情報が読めずに落ちる
- `nix fmt` は `nix fmt -- --no-cache`（treefmt のキャッシュ書き込みが落ちる）
- `neonctl` は `--no-analytics` を付ける（テレメトリ先が未許可で終了時に待たされる）。`neonctl auth` は通常ターミナルで人間が行う

worktree 隔離中（bg job・dev-flow の `df-*`）は、組み込みガードが「git に届かないと証明できない」コマンドを拒否する（設定では外せない）。拒否されない形で書く:
- cwd はもう自分の worktree。`cd <worktree> &&` や `git -C` を付けず相対パスで叩く。git は素の形で 1 呼び出し 1 コマンド（`&&` 連結・`$(git …)` も拒否）。skills-wt では `git -C` が sandbox 行きになり `skills/.git/worktrees/*/index.lock` が書けずに落ちる
- ファイル作成は heredoc（`cat > f <<'EOF'`）ではなく Write ツール
- 変数は必ずダブルクォート（`"$TMPDIR/x"`）。`$(…)` の結果を変数に入れて渡す形、`HOME=` 前置、`source` / `eval` を含む形も拒否される。`nix eval` も名前だけで拒否されるので、隔離中は `nix flake check` / `nix build` で確かめる

使えるもの:
- nix（daemon socket 許可済み）: nix を書いたら apply 前に `nix build` / `nix flake check` で自分で確かめる。ただし daemon は sandbox 外なので、nix 経由の取得は `allowedDomains` の制限を受けない。未知の flake や URL は通常の外部アクセスと同じ慎重さで扱う
- Jev: `~/.local/state/jev-broker/jev.sock` 経由。sandbox 内では Keychain が exit 36 で読めないのが正常なので、ロック解除を試さない
- pnpm と dev サーバー（localhost listen）は sandbox 内で動く。pnpm や docker を `excludedCommands` で sandbox 外に出さない（postinstall が `~/.ssh` や gh の資格情報を読める / docker socket はホスト権限相当）。E2E（Playwright + DB コンテナ）は人間か CI が回す

sandbox に塞がれたら:
- その場で回避せず、原因を特定して settings.json を直す。「編集できない」「手で足してください」とは返さない。dotfiles に worktree を切れば `claude-code/settings.json` は Edit ツールで編集できる（`denyWithinAllow` は Bash にしか効かない）。commit message と PR 本文まで用意し、許可を広げる変更は差分と理由を PR 本文に書いて merge 判断で確認を取る
- auto mode classifier が settings / RULES の commit を Self-Modification として止めたら回避しない。worktree パスと実行コマンド（commit → push → PR）を渡して止まる
- Unix ソケットへの接続は `filesystem.allowWrite` では開かない。`sandbox.network.allowUnixSockets` にパスを足す（`allowAllUnixSockets` は使わない）

<!--
経緯メモ（context には載らない）:
- nix daemon socket: 2026-08-21 許可。CLAUDE.md の「agent の検証範囲は nix fmt / nix flake check / nix eval」を実際に機能させるため。
  fixed-output derivation のビルダーは設計上ネットワーク自由なので egress の抜け道になる。
- Jev: 2026-09-26。API 鍵は login keychain にあるが、Keychain の解除は監査セッション単位なので sandbox 内の Bash と
  bg job からは解除済みでも `security` が exit 36。gui ドメインの LaunchAgent（home-manager/programs/jev-broker.nix）が
  鍵をメモリに持って中継する。代償: ソケットに届くプロセスは Jev を課金付きで呼べる（鍵と他モデルには届かない）。
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
- skill スクリプトの excludedCommands 登録: plugin cache ~/.claude/plugins/cache/playpark/、~/ghq/github.com/it-all-playpark/skills/、
  skills-wt/ 配下を bare / bash / python3 の 3 形で登録。前置形は先頭トークンマッチの仕組み上パターンで表現できない。
- dangerouslyDisableSandbox は policy で無効。
-->
