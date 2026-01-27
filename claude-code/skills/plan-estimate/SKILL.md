---
name: plan-estimate
description: |
  Provide development estimates for tasks with intelligent analysis.
  Use when: (1) planning development, (2) scoping features, (3) resource allocation,
  (4) keywords: estimate, how long, effort, complexity, scope
  Accepts args: [target] [--type time|effort|complexity] [--unit hours|days] [--breakdown]
---

# plan-estimate

Development estimation with analysis.

## Usage

```
/sc:estimate [target] [--type time|effort|complexity] [--unit hours|days] [--breakdown]
```

| Arg | Description |
|-----|-------------|
| target | Task/feature to estimate |
| --type | Estimate type |
| --unit | Time unit for output |
| --breakdown | Show subtask breakdown |

## Estimation Types

| Type | Output |
|------|--------|
| time | Calendar time estimate |
| effort | Person-hours/days |
| complexity | Low/Medium/High with factors |

## Workflow

1. **Analyze** → Scope, dependencies, unknowns
2. **Decompose** → Break into subtasks
3. **Score** → Apply complexity factors
4. **Calculate** → Generate estimates with ranges
5. **Present** → Confidence intervals

## Complexity Factors

| Factor | Impact |
|--------|--------|
| New technology | +30-50% |
| Integration | +20-40% |
| Unclear requirements | +40-60% |
| Team familiarity | -10-20% |

## Output

```markdown
## 📊 Estimate: [target]

### Summary
| Metric | Optimistic | Likely | Pessimistic |
|--------|------------|--------|-------------|
| Time | X | Y | Z |
| Effort | X | Y | Z |

### Breakdown (if --breakdown)
| Task | Estimate | Risk |
|------|----------|------|
| ... | ... | ... |

### Assumptions
- [List assumptions]

### Risks
- [Identified risks]
```

## Examples

```bash
/sc:estimate "authentication system" --breakdown
/sc:estimate "API migration" --type effort --unit days
/sc:estimate "UI redesign" --type complexity
```
