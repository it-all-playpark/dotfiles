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

## Organization
- Follow existing project conventions for naming and directory structure
- Reports/analyses → `claudedocs/`、Tests → `tests/`、Scripts → `scripts/`

## Workspace Hygiene
- Clean temporary files and build artifacts after use

## Sandbox Hygiene
🟡 sandbox 有効時（bg/remote 含む）に多発する失敗をコマンド側で回避する:
- **一時ファイルは `/tmp` 直書き禁止**。`$TMPDIR`（bg では `$CLAUDE_JOB_DIR/tmp`）を使う。素の `/tmp/foo` は書込み不許可で `Operation not permitted`
- **process substitution `<(…)` を避ける**。`diff <(a) <(b)` 等は sandbox が `/dev/fd/*` を塞ぐため失敗する。一旦 tempfile に落として `diff f1 f2` にする
- **network は `sandbox.network.allowedDomains` のホストのみ**到達可能。未許可ホストは即失敗 → 必要なら settings.json に追加してから実行（推測で叩かない）
- sandbox で塞がれても `dangerouslyDisableSandbox` は policy で無効。回避不能なら失敗を報告し、settings 調整を提案する（勝手に緩めない）

## Failure Investigation
🔴 Root cause analysis always. Never skip/disable tests or validation.

## Safety
- **Deletion**: `rip` を使用（復元可能）

## Git
- Feature branch で作業。`dev` branch は直接 push 可
- Incremental commits with descriptive messages

## Temporal Awareness
🔴 日付は env コンテキストから確認。knowledge cutoff を前提にしない
