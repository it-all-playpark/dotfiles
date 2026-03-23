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

## Organization
- Follow existing project conventions for naming and directory structure
- Reports/analyses → `claudedocs/`、Tests → `tests/`、Scripts → `scripts/`

## Workspace Hygiene
- Clean temporary files and build artifacts after use

## Failure Investigation
🔴 Root cause analysis always. Never skip/disable tests or validation.

## Safety
- **Deletion**: `rip` を使用（復元可能）

## Git
- Feature branch で作業。`dev` branch は直接 push 可
- Incremental commits with descriptive messages

## Temporal Awareness
🔴 日付は env コンテキストから確認。knowledge cutoff を前提にしない
