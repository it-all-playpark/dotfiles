---
name: meta-orchestrate
description: |
  Intelligent tool selection and parallel execution optimization.
  Use when: (1) multi-tool operations, (2) performance optimization needed,
  (3) keywords: optimize, parallel, efficient, batch, coordinate
  Accepts args: [--analyze] [--parallel] [--delegate auto|files|folders]
---

# meta-orchestrate

Optimize tool selection and execution strategy for maximum efficiency.

## Usage

```
/sc:orchestrate [--analyze] [--parallel] [--delegate auto|files|folders]
```

| Arg | Description |
|-----|-------------|
| --analyze | Analyze current task for optimization opportunities |
| --parallel | Force parallel execution strategy |
| --delegate | Enable sub-agent delegation mode |

## Tool Selection Matrix

| Task Type | Best Tool | Alternative |
|-----------|-----------|-------------|
| UI components | Magic MCP | Manual coding |
| Deep analysis | Sequential MCP | Native reasoning |
| Symbol operations | Serena MCP | Manual search |
| Pattern edits | Morphllm MCP | Individual edits |
| Documentation | Context7 MCP | Web search |
| Browser testing | Playwright MCP | Unit tests |
| Multi-file edits | MultiEdit | Sequential Edits |
| Code search | Grep | bash grep |
| File patterns | Glob | bash find |

## Parallel Execution Rules

**ALWAYS parallel when:**
- 3+ independent file reads
- Multiple independent edits
- Concurrent searches across different paths
- Independent tool calls with no data dependencies

**NEVER parallel when:**
- Results depend on previous calls
- Sequential file modifications
- Operations that may conflict

## Resource Zones

| Zone | Context | Action |
|------|---------|--------|
| 🟢 Green | 0-75% | Full capabilities |
| 🟡 Yellow | 75-85% | Reduce verbosity |
| 🔴 Red | 85%+ | Essential only |

## Delegation Triggers

| Condition | Delegate |
|-----------|----------|
| >7 directories | Yes |
| >50 files | Yes |
| Complexity >0.8 | Yes |
| Independent subtasks | Consider |

## Workflow

1. **Assess** → Analyze task complexity and tool requirements
2. **Plan** → Identify parallel vs sequential operations
3. **Route** → Select optimal tools for each subtask
4. **Execute** → Run with maximum parallelization
5. **Validate** → Verify results and efficiency

## Output Format

```markdown
## 🔧 Tool Selection
| Task | Tool | Reason |
|------|------|--------|
| ... | ... | ... |

## ⚡ Execution Strategy
- Parallel: [list operations]
- Sequential: [list operations]

## 📊 Efficiency Analysis
- Estimated parallelization gain: X%
- Resource usage: [zone]
```

## Examples

```
/sc:orchestrate --analyze
→ Analyzes current context and suggests optimizations

/sc:orchestrate --parallel
→ Restructures upcoming operations for parallel execution

/sc:orchestrate --delegate auto
→ Enables automatic sub-agent delegation for complex tasks
```
