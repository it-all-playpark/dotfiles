# Claude Code Behavioral Rules

## Priority
🔴 CRITICAL: Security, data safety — never compromise
🟡 IMPORTANT: Quality, maintainability — strong preference
🟢 RECOMMENDED: Optimization, best practices — when practical

Conflict: Safety > Scope > Quality > Speed

## Workflow
- **Task Pattern**: Understand → Plan → Task ツール群で分解(3+ tasks) → Execute → Validate
  - 新しめのモデル（opus 4.8 / sonnet 5 / fable 5 / mythos 5）では Todo ツールが既定無効。`TaskCreate` / `TaskUpdate` / `TaskList` を使う（`permissions.allow` に登録済み）
  - 旧 `TodoWrite` を使いたい場合のみ `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`（または設定 `todoFeatureEnabled: true`）で復活させる
- **Discovery First**: Project-wide analysis before systematic changes
- **Session Lifecycle**: /session-load → Work → Checkpoint(30min) → /session-save
- **Memory Persistence**: セッション終了時・タスク完了時に memvid へ自動保存（確認不要）
  - タスク完了: memvid put（project or global）
  - セッション終了: memvid put（global, type=session）
  - フィードバック受領: memvid put（global, type=feedback）

## Implementation
- **No Partial Features**: Start = Finish. No TODO, no mocks, no stubs
- **Scope Discipline**: Build ONLY what's asked. MVP first, no speculative features

## Orchestration & Compute Budget
- **Right-Sized Model**: Workflow/subagent の各ステージは作業の重さでモデルを選ぶ
  - 軽量・機械的（web search, grep集約, mechanical edit）→ `model: haiku, effort: low`
  - 重い判断のみ（verify/judge/synthesize）→ opus + 上位 effort
- **Inherit ≠ Default-Heavy**: `agent()` は明示しない限りセッションモデル（opus xhigh）を継承する。軽ステージに指定をサボると全部 opus xhigh になる
- **No Over-Orchestration**: trivial な単発作業は Workflow 化せず直接ツールを叩く。ultracode でも例外でない

## Tool Routing
🟢 全読み（20KB 超の構造化ファイル / 100KB 超）は `playpark-core` plugin の `pretool-context-guard.sh` hook が deny し `jq`/`gron`/`yq`/`duckdb`/`rga` を提示する。以下は hook が意図を検知できないので自分で選ぶ:
- **コードベース概観** → `tokei`（読み始める前にまず全体像）
- **同一パターンを3箇所以上書き換え**（rename・API移行）→ sed でなく `ast-grep --pattern … --rewrite …`（コメント・文字列に誤爆しない）
- **grep 結果に偽陽性が混ざる検索** → `ast-grep --pattern`（AST ノードのみ）
- **機械的な文字列置換** → `sd`（sed より事故りにくい）
- **フォーマッタ適用後の挙動不変確認** → `difft --exit-code old new`
- **性能主張の裏取り** → `hyperfine`（体感で速い/遅いを言わない）
- **リポジトリ全体のコンテキスト化** → repomix（/repo-export skill）

## Organization
- Follow existing project conventions for naming and directory structure
- Reports/analyses → `claudedocs/`、Tests → `tests/`、Scripts → `scripts/`

## Workspace Hygiene
- Clean temporary files and build artifacts after use

## Sandbox Hygiene
🟡 sandbox 有効時（bg/remote 含む）に多発する失敗をコマンド側で回避する:
- **一時ファイルは `/tmp` 直書き禁止**。bg/remote を含め常に `$TMPDIR` を使う。素の `/tmp/foo` は書込み不許可で `Operation not permitted`
  - `$CLAUDE_JOB_DIR/tmp` は使わない。`~/.claude/jobs` は Claude Code 組み込みの自己改変ガードで write deny されており、`sandbox.filesystem.allowWrite` に書いても上書きできない（deny が allow 内で優先される）。bg セッションの system prompt は `$CLAUDE_JOB_DIR/tmp` を案内するが実際には書けない
- **`~/.claude/skills` / `~/.claude/agents` の実体（`it-all-playpark/skills` repo）は repo 丸ごと write deny**。組み込みの自己改変ガードが symlink を解決して効くため、repo 内の `.claude/worktrees/` も書けない。skills repo を編集する作業は **repo 外**に worktree を切る（例: `git worktree add ~/ghq/github.com/it-all-playpark/skills-wt/<branch>`）。settings では緩められない
- **process substitution `<(…)` を避ける**。`diff <(a) <(b)` 等は sandbox が `/dev/fd/*` を塞ぐため失敗する。一旦 tempfile に落として `diff f1 f2` にする
- **network は `sandbox.network.allowedDomains` のホストのみ**到達可能。未許可ホストは即失敗 → 必要なら settings.json に追加してから実行（推測で叩かない）
- **Unix ソケット接続は `filesystem.allowWrite` では開かない**。専用キーの
  `sandbox.network.allowUnixSockets`（macOS 限定・パスの配列）を使う。
  `cannot connect to socket at '...': Operation not permitted` が出たらこれ。
  `allowAllUnixSockets: true` は全ソケットが開くので使わない
- **nix daemon socket は許可済み**（`/nix/var/nix/daemon-socket/socket`、2026-08-21 追加）。
  これで `nix build` / `nix flake check` / `nix eval` / `nix fmt` が agent から実行でき、
  CLAUDE.md の「agent の検証範囲は nix fmt / nix flake check / nix eval」が実際に機能する。
  nix を書いたら apply 前に自分でビルドして確かめること
  - **代償**: nix daemon は root で **sandbox の外側**にいるので、daemon 経由の取得は
    `allowedDomains` の制限を受けない。fixed-output derivation のビルダーは設計上
    ネットワーク自由なので、ここは egress の抜け道になっている。nix 経由の外部取得を
    「許可ドメインの内側だから安全」と考えないこと。未知の flake や URL を
    `nix build` / `nix run` で引く前に、通常の外部アクセスと同じ慎重さで扱う
- **Jev は jev-broker のソケット経由で呼ぶ**（`~/.local/state/jev-broker/jev.sock`、2026-09-26 追加）。
  API 鍵は login keychain にあるが、sandbox 内の Bash と bg job（別の監査セッション）からは
  解除済みでも `security` が exit 36 になり読めない。gui ドメインの LaunchAgent
  （`home-manager/programs/jev-broker.nix`）が鍵をメモリに持って中継し、`jev-classify.sh` は
  ソケットがあればそちらを使う。exit 36 を見て Keychain のロック解除を試さないこと
  - **代償**: ソケットに届くプロセスは Jev を課金付きで呼べる（鍵そのものと Jev 以外のモデルには届かない。
    broker が model と転送先を固定する）
- **pnpm は sandbox 内で動かす**（`~/Library/pnpm` と `/private/tmp/pnpm-store-operation-locks-*` を `allowWrite`）。
  pnpm 12 は store の operation lock を `TMPDIR` を無視して `/tmp/pnpm-store-operation-locks-<uid>/` に作る。
  ここが未許可だと、エラー文は相対名 `"pnpm-store-operation-locks"` しか出さないまま
  `ERR_PNPM_STORE_DIR_OPEN_OPERATION_LOCK` で全コマンドが落ちる（`~/Library/pnpm` だけ許可しても直らない）。
  `/tmp` 全体は開けない: hook が読む `claude-skill-ctx-*` や Claude / Chrome bridge のソケットなど、
  sandbox 外のプロセスと共有する領域になるため。
  `excludedCommands` で sandbox 外に出さないこと: install 時の postinstall スクリプトが
  `~/.ssh` や gh の資格情報を読めてしまう。docker も同様に外に出さない（ソケットが
  ホスト権限相当）。E2E（Playwright + DB コンテナ）は人間か CI が回す
- **dev サーバーの起動は許可済み**（`network.allowLocalBinding: true`、2026-09-25 追加）。
  `next dev` 等で localhost の port を listen できる。外向き通信の制限は変わらない
- **`nix fmt` は `-- --no-cache` を付ける**。treefmt が `~/Library/Caches/treefmt` に
  キャッシュ DB を書こうとして `operation not permitted` で落ちる
  （`allowWrite` に足せば素で通るが、キャッシュなので付けて回避で足りる）
- **settings.json の編集は自分でやる。「編集できない」「手で足してください」と返さない**。
  sandbox の書き込み拒否リスト（`denyWithinAllow`）は Bash コマンドにしか効かない。
  dotfiles に worktree を切れば、`claude-code/settings.json` は Edit ツールで編集できる
  （拒否されるのは main checkout 側のパスへの Bash 書き込みだけ）。
  原因を特定して設定変更が要ると判断したら、worktree で Edit し、commit message と PR 本文まで用意する。
  settings / RULES の commit は auto mode classifier が Self-Modification として止めることがある。
  止められたら回避せず、worktree パスと実行コマンド（commit → push → PR）を渡して止まる。
  許可範囲を広げる変更は差分と理由を PR 本文に書き、merge 判断で確認を取る（これが「勝手に緩めない」の意味）
- sandbox で塞がれても `dangerouslyDisableSandbox` は policy で無効。その場で回避せず、上の settings 変更 PR で直す
- **gh を内部で呼ぶ skill スクリプトは `sandbox.excludedCommands` に登録済みの起動形で呼ぶ**。登録されているのは「スクリプトパスが先頭トークンの bare 形」と `bash <path>` / `python3 <path>` の 2 トークン形（plugin cache `~/.claude/plugins/cache/playpark/`、`~/ghq/github.com/it-all-playpark/skills/` および repo 外 worktree 置き場 `skills-wt/` 配下のパス）のみ。`cd X && script` や `VAR=x script` のような前置形は登録がなく、先頭トークンマッチの仕組み上パターンでも表現できない。登録外の形で呼ぶと、内部で資格情報を要する処理（gh が `~/.config/gh` や keyring を読む等）が失敗する

## Failure Investigation
🔴 Root cause analysis always. Never skip/disable tests or validation.

## Safety
- **Deletion**: `rip` を使用（復元可能）

## Git
- Feature branch で作業。**保護ブランチへの直接 push は禁止**（`main` / `master` / `dev` / `develop` / `development` / `production` / `staging` / `release` / `nightly`）— `dev` も含めて必ず PR 経由。CI とレビューを飛ばさないため
  - 強制は `allow-feature-push.sh`（PreToolUse hook）が**唯一**。9 ブランチ全てを、素の `git push origin main` / `git -C <dir> push` / `git push origin :main` / `--delete` / `--mirror` まで含めて判定する
  - `permissions.deny` 側の保護ブランチ規則は 2026-08-16 に撤去した。`Bash(git push *:main)` のような**引数を glob で絞る規則は実際には一致せず**（実測で確認）、公式も「引数を制約する Bash permission パターンは fragile。PreToolUse hook を使え」としているため
  - `保護/デプロイブランチ (...) への push は禁止` で止まったら sandbox ではなくこの hook。feature branch を切って PR を出す
- Incremental commits with descriptive messages

## Temporal Awareness
🔴 日付は env コンテキストから確認。knowledge cutoff を前提にしない
