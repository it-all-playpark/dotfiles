---
name: meta-spawn
description: |
  Meta-system task orchestration with intelligent breakdown and delegation.
  Use when: (1) complex multi-domain tasks, (2) parallel coordination needed,
  (3) keywords: spawn, orchestrate, coordinate, parallel, delegate
  Accepts args: [task] [--strategy sequential|parallel|adaptive] [--depth normal|deep]
---

# meta-spawn

Task orchestration and delegation.

## Usage

```
/sc:spawn [task] [--strategy sequential|parallel|adaptive] [--depth normal|deep]
```

| Arg | Description |
|-----|-------------|
| task | Complex task to orchestrate |
| --strategy | Execution strategy |
| --depth | Analysis depth |

## Strategies

| Strategy | When to Use |
|----------|-------------|
| sequential | Dependencies between subtasks |
| parallel | Independent subtasks |
| adaptive | Mixed dependencies |

## Workflow

1. **Analyze** → Parse task requirements
2. **Decompose** → Break into subtasks
3. **Plan** → Determine execution order
4. **Delegate** → Assign to appropriate skills/agents
5. **Monitor** → Track progress
6. **Integrate** → Aggregate results

## Task Delegation

| Subtask Type | Delegate To |
|--------------|-------------|
| Analysis | sc:analyze, sc:think |
| Implementation | implement |
| Testing | sc:test |
| Documentation | sc:document |

## Output

```markdown
## 🚀 Spawn: [task]

### Subtasks
| # | Task | Strategy | Status |
|---|------|----------|--------|
| 1 | ... | parallel | ✅ |
| 2 | ... | sequential | 🔄 |

### Progress
[Progress bar or percentage]

### Results
[Aggregated results]
```

## Examples

```bash
/sc:spawn "implement auth with tests and docs" --strategy adaptive
/sc:spawn "refactor entire module" --strategy parallel
/sc:spawn "migrate database" --strategy sequential --depth deep
```
