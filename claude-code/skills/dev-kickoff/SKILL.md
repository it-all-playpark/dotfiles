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

## State Persistence

State is persisted in `$WORKTREE/.claude/kickoff.json` for recovery after auto-compact.

### Initialize State

After Phase 1 (worktree creation), run:
```bash
~/.claude/skills/dev-kickoff/scripts/init-kickoff.sh $ISSUE $BRANCH $WORKTREE_PATH \
  --base $BASE --strategy $STRATEGY --depth $DEPTH --lang $LANG --env-mode $ENV_MODE
```

### Update Phase Status

Before starting a phase:
```bash
~/.claude/skills/dev-kickoff/scripts/update-phase.sh <phase> in_progress --worktree $PATH
```

After completing a phase:
```bash
~/.claude/skills/dev-kickoff/scripts/update-phase.sh <phase> done --result "Summary" --worktree $PATH
```

After PR creation (phase 6_pr), record PR info for pr-iterate handoff:
```bash
~/.claude/skills/dev-kickoff/scripts/update-phase.sh 6_pr done \
  --result "PR created" \
  --pr-number 123 \
  --pr-url "https://github.com/org/repo/pull/123" \
  --worktree $PATH
```

On failure:
```bash
~/.claude/skills/dev-kickoff/scripts/update-phase.sh <phase> failed --error "Error message" --worktree $PATH
```

### Resume After Compact

1. Read `$WORKTREE/.claude/kickoff.json`
2. Check `current_phase` and `next_actions`
3. Resume from the pending phase

## Workflow

```
git-prepare.sh → init-kickoff.sh → dev-issue-analyze → dev-implement → dev-validate → git-commit → git-pr → pr-iterate
```

After PR creation, kickoff.json is updated with PR info and `next_action: "pr-iterate"`. The pr-iterate skill automatically detects the worktree from kickoff.json.

## Phase Execution

| Phase | Command | Subagent |
|-------|---------|----------|
| 1. Worktree | `~/.claude/skills/git-prepare/scripts/git-prepare.sh $ISSUE --base $BASE --env-mode $ENV_MODE` | - |
| 1b. Init State | `~/.claude/skills/dev-kickoff/scripts/init-kickoff.sh ...` | - |
| 2. Analyze | Skill: `dev-issue-analyze $ISSUE --depth $DEPTH` | Task(Explore) |
| 3. Implement | Skill: `dev-implement --strategy $STRATEGY --worktree $PATH` | - |
| 4. Validate | Skill: `dev-validate --fix --worktree $PATH` | Task(quality-engineer) |
| 5. Commit | Skill: `git-commit --all --worktree $PATH` | - |
| 6. Create PR | Skill: `git-pr $ISSUE --base $BASE --lang $LANG --worktree $PATH` | - |

⚠️ **Phase 1 は必ずスクリプトを実行。`git worktree add` 直接実行禁止。**

## Subagent Delegation

| Phase | Subagent | Reason |
|-------|----------|--------|
| 2. Analyze | Task(Explore) | Large file reads, codebase exploration |
| 4. Validate | Task(quality-engineer) | Test execution, log analysis |

After subagent completes, update state with results:
```bash
# Example: record analyze results
~/.claude/skills/dev-kickoff/scripts/update-phase.sh 2_analyze done \
  --result "Identified 5 files to modify" \
  --next "Create implementation tasks,Start with schema file" \
  --worktree $PATH
```

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
| Worktree/Analyze | Abort, update state with error |
| Implement | Pause for intervention, save progress |
| Validate | Retry with --fix, then pause |
| Commit/PR | Report manual command, save state |

## State File Location

```
$WORKTREE/
├── .claude/
│   ├── kickoff.json    # Machine-readable state
│   └── iterate.json    # pr-iterate state (created after PR)
└── docs/
    └── STATE.md        # Human-readable summary (optional)
```

## kickoff.json Schema (with PR info)

```json
{
  "issue": 123,
  "worktree": "/path/to/worktree",
  "pr": {
    "number": 456,
    "url": "https://github.com/org/repo/pull/456",
    "created_at": "2026-01-28T10:00:00Z"
  },
  "next_action": "pr-iterate"
}
```
