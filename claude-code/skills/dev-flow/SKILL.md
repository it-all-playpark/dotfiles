---
name: dev-flow
description: |
  End-to-end development flow automation - from issue to merged PR.
  Use when: (1) complete development cycle needed, (2) issue to PR automation,
  (3) keywords: full flow, development cycle, issue to PR
  Accepts args: <issue-number> [--strategy tdd|bdd|ddd] [--depth minimal|standard|comprehensive] [--base <branch>] [--max-iterations N]
allowed-tools:
  - Skill
  - Bash
---

# Dev Flow

End-to-end development automation from issue to merged PR.

## ⚠️ CRITICAL: Complete All Phases

**This workflow has 3 steps. DO NOT EXIT until pr-iterate completes.**

| Step | Action | Complete When |
|------|--------|---------------|
| 1 | `Skill: dev-kickoff` | PR URL available |
| 2 | `gh pr view --json url` | URL captured |
| 3 | `Skill: pr-iterate` | PR merged or max iterations |

## Usage

```
/dev-flow <issue> [--strategy tdd] [--depth comprehensive] [--base main] [--max-iterations 10]
```

## Workflow Checklist

Execute in order. Mark each complete before proceeding:

```
[ ] Step 1: Skill: dev-kickoff $ISSUE --strategy $STRATEGY --depth $DEPTH --base $BASE
[ ] Step 2: PR_URL=$(gh pr view --json url --jq .url)
[ ] Step 3: Skill: pr-iterate $PR_URL --max-iterations $MAX
```

## Completion Conditions

| Condition | Action |
|-----------|--------|
| pr-iterate completes | ✅ Workflow complete |
| PR merged | ✅ Workflow complete |
| Max iterations reached | ⚠️ Report status, user decides |
| Any step fails | ❌ Report error, do not proceed |

## State Recovery

After auto-compact, check worktree state:

```bash
~/.claude/skills/dev-flow/scripts/flow-status.sh --worktree $WORKTREE
```

Output tells you the next action.

## References

- [Workflow Details](references/workflow-detail.md) - Full phase descriptions
- [dev-kickoff](../dev-kickoff/SKILL.md) - Orchestrator skill
- [pr-iterate](../pr-iterate/SKILL.md) - PR iteration skill
