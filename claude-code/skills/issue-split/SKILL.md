---
name: issue-split
description: |
  Split complex issue into parallel-executable sub-issues.
  Use when: (1) large issue needs breakdown, (2) parallel development planning,
  (3) keywords: split issue, break down, sub-tasks, parallel tasks
  Accepts args: <issue-number> [--max-subtasks N] [--language ja|en]
allowed-tools:
  - Skill
  - Bash
  - TodoWrite
  - Write
---

# Issue Split

Orchestrates issue splitting into conflict-free, parallel-executable sub-issues.

## Usage

```
/issue-split <issue-number> [--max-subtasks N] [--language ja|en]
```

| Arg | Default | Description |
|-----|---------|-------------|
| `<issue>` | required | Parent issue number |
| `--max-subtasks` | `8` | Maximum sub-issues |
| `--language` | `ja` | Output language |

## Workflow

```
Task Progress:
- [ ] Step 1: Fetch parent issue
- [ ] Step 2: Analyze dependencies (plan-workflow)
- [ ] Step 3: Plan splitting (meta-spawn, meta-task)
- [ ] Step 4: Generate task breakdown (think-analyze)
- [ ] Step 5: Create sub-issues
- [ ] Step 6: Validate (session-reflect)
- [ ] Step 7: Verify build (dev-build)
- [ ] Step 8: Post plan to parent
```

See [references/splitting-guide.md](references/splitting-guide.md) for splitting criteria.

### Step 1: Fetch Parent Issue

```bash
gh issue view $ISSUE --json body,title --jq '.body' > /tmp/parent.md
```

### Step 2-4: Analysis Phase

```
Skill: plan-workflow "$(cat /tmp/parent.md)" --depth normal
Skill: meta-select-tool "task splitting" --analyze
Skill: meta-spawn --strategy adaptive
Skill: meta-task --parallel
Skill: think-analyze (conflict-free breakdown)
```

Output: `/tmp/tasks.json` with task breakdown

### Step 5: Create Sub-Issues

For each task in breakdown:

```bash
~/.claude/skills/issue-split/scripts/create-sub-issue.sh \
    "$TITLE" /tmp/task-body.md $ORDER $PARENT_ISSUE
```

### Step 6-7: Verification

```
Skill: session-reflect --type completion
Skill: dev-build --type prod
```

### Step 8: Post Plan

Generate plan markdown, then:

```bash
~/.claude/skills/issue-split/scripts/post-plan-comment.sh $ISSUE /tmp/plan.md
```

## Output

```
================================================================================
Issue Split Complete: #XXX
================================================================================
Sub-issues: [count]
Groups:     [parallel groups count]

| Order | Issue | Title | Parallel |
|-------|-------|-------|----------|
| 01 | #101 | Domain | Yes |
| 01 | #102 | Types | Yes |
| 02 | #103 | Tests | No |

Plan posted to parent issue.
================================================================================
```

## Examples

```bash
/issue-split 123
/issue-split 123 --max-subtasks 5
/issue-split 456 --language en
```
