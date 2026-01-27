---
name: dev-kickoff
description: |
  End-to-end feature development orchestrator using git worktree. Coordinates git-prepare, issue-analyze, implement, validate, commit, and create-pr skills.
  Use when: starting new feature development from GitHub issue, full development cycle automation with isolated worktree.
  Accepts args: <issue-number> [--strategy tdd|bdd|ddd] [--depth minimal|standard|comprehensive] [--base <branch>] [--lang ja|en] [--env-mode hardlink|symlink|copy|none] [--skip-pr]
allowed-tools:
  - Bash
  - TodoWrite
---

# Kickoff

Orchestrate complete feature development cycle from issue to PR.

## Workflow

```
git-prepare.sh → dev-issue-analyze → dev-implement → dev-validate → git-commit → git-pr
```

## Phase Execution

| Phase | Command |
|-------|---------|
| 1. Worktree | `~/.claude/skills/git-prepare/scripts/git-prepare.sh $ISSUE --base $BASE --env-mode $ENV_MODE` |
| 2. Analyze | Skill: `dev-issue-analyze $ISSUE --depth $DEPTH` |
| 3. Implement | Skill: `dev-implement --strategy $STRATEGY --worktree $PATH` |
| 4. Validate | Skill: `dev-validate --fix --worktree $PATH` |
| 5. Commit | Skill: `git-commit --all --worktree $PATH` |
| 6. Create PR | Skill: `git-pr $ISSUE --base $BASE --lang $LANG --worktree $PATH` |

⚠️ **Phase 1 は必ずスクリプトを実行。`git worktree add` 直接実行禁止。**

## Phase 1 Verification

```bash
ls $WORKTREE_PATH/.env || echo "ERROR: .env not linked - script was not used"
```

.env が存在しない場合はエラー報告し続行しない。

## Args

| Arg | Default | Description |
|-----|---------|-------------|
| `<issue-number>` | required | GitHub issue number |
| `--strategy` | `tdd` | Implementation strategy |
| `--depth` | `standard` | Analysis depth |
| `--base` | `dev` | PR base branch |
| `--lang` | `ja` | PR language |
| `--env-mode` | `hardlink` | Env file handling |
| `--skip-pr` | false | Skip PR creation |

## Error Handling

| Phase | On Failure |
|-------|------------|
| Worktree/Analyze | Abort |
| Implement | Pause for intervention |
| Validate | Retry with --fix |
| Commit/PR | Report manual command |
