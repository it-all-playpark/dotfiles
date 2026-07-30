# Claude Code Behavioral Rules

## Priority
🔴 CRITICAL: Security, data safety — never compromise
🟡 IMPORTANT: Quality, maintainability — strong preference
🟢 RECOMMENDED: Optimization, best practices — when practical

Conflict: Safety > Scope > Quality > Speed

## Workflow
- **Task Pattern**: Understand → Plan → TodoWrite(3+ tasks) → Execute → Validate
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
🟢 コンテキスト節約と精度向上のため、ファイル全読み・テキスト grep の前に専用 CLI で絞る:
- **コードベース概観** → `tokei`（言語構成・規模。ファイルを読み始める前にまず全体像）
- **同一コードパターンを3箇所以上書き換える時**（rename・API移行・codemod）→ sed/手編集でなく `ast-grep --pattern … --rewrite …`。コメント・文字列リテラルへの誤爆がなく、全箇所を機械的に網羅できる
- **grep 結果にコメント・文字列の偽陽性が混ざる検索** → `ast-grep --pattern`（AST ノードのみマッチ）
- **JSON** → `jq` で必要キーのみ抽出。構造が未知なら `gron <file> | rg <keyword>` でパス発見
- **YAML/TOML/XML** → `yq` で必要部分のみ抽出
- **CSV/Parquet/巨大 JSON の集計** → `duckdb -c "SELECT ..."`（Read で全読みしない）
- **PDF/docx/zip/sqlite 内の検索** → `rga`（ripgrep-all）
- **機械的な文字列置換** → `sd`（sed より事故りにくい）
- **refactor・フォーマッタ適用後の「挙動不変」確認** → `difft --exit-code old new`（構造変化ゼロ＝フォーマットのみ、を機械判定。目視 diff レビューを省略できる）
- **リポジトリ全体のコンテキスト化** → repomix（/repo-export skill）
- **性能主張の裏取り** → `hyperfine`（体感や推測で速い/遅いを言わない）

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
- sandbox で塞がれても `dangerouslyDisableSandbox` は policy で無効。回避不能なら失敗を報告し、settings 調整を提案する（勝手に緩めない）
- **gh を内部で呼ぶ skill スクリプトは `sandbox.excludedCommands` に登録済みの起動形で呼ぶ**。登録されているのは「スクリプトパスが先頭トークンの bare 形」と `bash <path>` / `python3 <path>` の 2 トークン形（skills 配下のパス）のみ。`cd X && script` や `VAR=x script` のような前置形は登録がなく、先頭トークンマッチの仕組み上パターンでも表現できない。登録外の形で呼ぶと、内部で資格情報を要する処理（gh が `~/.config/gh` や keyring を読む等）が失敗する

## Failure Investigation
🔴 Root cause analysis always. Never skip/disable tests or validation.

## Safety
- **Deletion**: `rip` を使用（復元可能）

## Git
- Feature branch で作業。**保護ブランチへの直接 push は禁止**（`main` / `master` / `dev` / `develop` / `development` / `production` / `staging` / `release` / `nightly`）— `dev` も含めて必ず PR 経由。CI とレビューを飛ばさないため
  - 強制は `allow-feature-push.sh`（PreToolUse hook）が主。`main` / `master` / `dev` / `develop` / `development` は `permissions.deny` でも重ねて塞いである
  - `保護/デプロイブランチ (...) への push は禁止` で止まったら sandbox ではなくこの hook。feature branch を切って PR を出す
- Incremental commits with descriptive messages

## Temporal Awareness
🔴 日付は env コンテキストから確認。knowledge cutoff を前提にしない
