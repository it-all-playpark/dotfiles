---
name: meta-task
description: |
  Hierarchical task management with memory persistence.
  Use when: (1) multi-step operations (>3 steps), (2) complex scope,
  (3) keywords: plan, organize, track, manage, phases, breakdown
  Accepts args: [goal] [--phases] [--checkpoint] [--resume]
---

# meta-task

Hierarchical task organization with persistent memory for complex operations.

## Usage

```
/sc:task [goal] [--phases] [--checkpoint] [--resume]
```

| Arg | Description |
|-----|-------------|
| goal | Overall task objective |
| --phases | Break into explicit phases |
| --checkpoint | Create checkpoint for resumption |
| --resume | Resume from previous checkpoint |

## Task Hierarchy

```
📋 Plan (goal)
└── 🎯 Phase (milestone)
    └── 📦 Task (deliverable)
        └── ✓ Todo (action)
```

## Workflow

### Session Start
1. Check existing state (list todos)
2. Resume context if available
3. Plan or continue execution

### During Execution
1. Update todo status in real-time
2. Mark complete IMMEDIATELY after finishing
3. Only ONE task `in_progress` at a time
4. Create checkpoints for complex operations

### Session End
1. Assess completion status
2. Document outcomes
3. Clean up temporary state

## TodoWrite Integration

**ALWAYS use TodoWrite when:**
- Task has >3 steps
- Spans >2 directories OR >3 files
- User requests tracking
- Complex dependencies exist

**Status Flow:**
```
pending → in_progress → completed
           ↓
    (if blocked) → create new task for blocker
```

## Output Format

```markdown
## 📋 Task Plan: [Goal]

### Phase 1: [Milestone]
- [ ] Task 1.1: [Deliverable]
- [ ] Task 1.2: [Deliverable]

### Phase 2: [Milestone]
- [ ] Task 2.1: [Deliverable]

## 📊 Progress
- Total: X tasks
- Completed: Y
- In Progress: Z
```

## Checkpoint Format

```markdown
## 🔖 Checkpoint: [timestamp]
- **Goal**: [original goal]
- **Phase**: [current phase]
- **Completed**: [list]
- **Next**: [next task]
- **Blockers**: [if any]
```

## Rules

| Rule | Description |
|------|-------------|
| Atomic updates | Mark tasks complete immediately |
| Single focus | Only one `in_progress` at a time |
| No batching | Don't batch completions |
| Real-time | Update status as you work |
| Honest status | Never mark incomplete as complete |

## Examples

```
/sc:task "Implement authentication system" --phases
→ Creates phased plan: Design → Implement → Test → Document

/sc:task --checkpoint
→ Saves current progress for later resumption

/sc:task --resume
→ Loads previous checkpoint and continues
```

## Tool Selection by Task Type

| Task Type | Primary Tool |
|-----------|-------------|
| Analysis | Sequential MCP |
| Implementation | MultiEdit/Morphllm |
| UI Components | Magic MCP |
| Testing | Playwright MCP |
| Documentation | Context7 MCP |
