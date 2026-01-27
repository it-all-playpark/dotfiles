---
name: meta-select-tool
description: |
  Intelligent MCP tool selection based on complexity and operation analysis.
  Use when: (1) choosing between tools, (2) optimizing tool usage,
  (3) keywords: which tool, best tool, select tool, optimize tools
  Accepts args: [operation] [--analyze] [--explain]
---

# meta-select-tool

Intelligent tool selection for operations.

## Usage

```
/sc:select-tool [operation] [--analyze] [--explain]
```

| Arg | Description |
|-----|-------------|
| operation | Operation to analyze |
| --analyze | Show scoring details |
| --explain | Explain selection rationale |

## Tool Selection Matrix

| Task Type | Best Tool | Alternative |
|-----------|-----------|-------------|
| UI components | Magic MCP | Manual |
| Deep analysis | Sequential MCP | Native |
| Symbol operations | Serena MCP | Grep |
| Pattern edits | morphllm MCP | Edit |
| Documentation | Context7 MCP | WebSearch |
| Browser testing | Playwright MCP | Unit tests |
| Multi-file edits | MultiEdit | Edit |

## Scoring Factors

| Factor | Weight |
|--------|--------|
| File count | High |
| Complexity | High |
| Pattern consistency | Medium |
| Semantic needs | Medium |

## Output

```markdown
## 🔧 Tool Selection: [operation]

### Recommendation
**Best Tool**: [tool name]
**Confidence**: High/Medium/Low

### Analysis (if --analyze)
| Factor | Score | Reason |
|--------|-------|--------|
| ... | ... | ... |

### Alternative
If [tool] unavailable, use [alternative]
```

## Examples

```bash
/sc:select-tool "rename function across project"
/sc:select-tool "update 50 files" --analyze
/sc:select-tool "debug performance" --explain
```
