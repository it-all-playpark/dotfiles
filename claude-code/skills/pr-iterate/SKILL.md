---
name: pr-iterate
description: |
  Continuous improvement loop - iterate on PR until LGTM.
  Use when: (1) PR needs multiple rounds of fixes, (2) automated improvement cycle,
  (3) keywords: iterate, improve loop, continuous fix, until LGTM
  Accepts args: <pr-number-or-url> [--max-iterations N]
allowed-tools:
  - Skill
  - Bash
---

# PR Iterate

## Usage

```
/pr-iterate <pr> [--max-iterations N]
```

| Arg | Default |
|-----|---------|
| `--max-iterations` | `10` |

## State Persistence

State is persisted in `.claude/iterate.json` for recovery after auto-compact.

### Initialize State

```bash
~/.claude/skills/pr-iterate/scripts/init-iterate.sh $PR [--max-iterations N]
```

### Record Results

```bash
# Record review decision
~/.claude/skills/pr-iterate/scripts/record-iteration.sh review \
  --decision <approved|request-changes|comment> \
  [--issues "issue1,issue2"] \
  [--summary "Review summary"]

# Record CI status
~/.claude/skills/pr-iterate/scripts/record-iteration.sh ci --status <passed|failed|pending>

# Record fixes applied
~/.claude/skills/pr-iterate/scripts/record-iteration.sh fix --applied "fix1,fix2"

# Start next iteration
~/.claude/skills/pr-iterate/scripts/record-iteration.sh next

# Complete iteration loop
~/.claude/skills/pr-iterate/scripts/record-iteration.sh complete --status <lgtm|failed|max_reached>
```

### Resume After Compact

1. Read `.claude/iterate.json`
2. Check `current_iteration`, `status`, and `next_actions`
3. Resume from where you left off

## Workflow

1. Initialize: `init-iterate.sh $PR`
2. Loop (max N iterations):
   - Skill: `pr-review $PR`
   - Record: `record-iteration.sh review --decision ... --issues ...`
   - If LGTM → `record-iteration.sh complete --status lgtm` → exit
   - Skill: `pr-fix $PR`
   - Record: `record-iteration.sh fix --applied ...`
   - Record: `record-iteration.sh next`

## Subagent Delegation

| Step | Subagent | Reason |
|------|----------|--------|
| pr-review | Task(Plan) | Sequential thinking for complex review analysis |

## State File Location

```
$REPO/
├── .claude/
│   └── iterate.json    # Machine-readable state
└── docs/
    └── STATE.md        # Human-readable summary (auto-generated)
```

## Error Handling

| Scenario | Action |
|----------|--------|
| Review decision unclear | Ask for clarification, record decision |
| CI persistently failing | Record failures, pause after 3 consecutive |
| Max iterations reached | Set status `max_reached`, report manual intervention needed |
| Network/API errors | Retry once, then record error and pause |
