---
name: dev-improve
description: |
  Apply systematic improvements to code quality, performance, maintainability.
  Use when: (1) code quality enhancement, (2) performance optimization,
  (3) keywords: improve, optimize, refactor, enhance, better, clean up
  Accepts args: [target] [--type quality|performance|maintainability] [--safe]
---

# dev-improve

Systematic code improvement.

## Usage

```
/sc:improve [target] [--type quality|performance|maintainability] [--safe]
```

| Arg | Description |
|-----|-------------|
| target | Code to improve |
| --type | Improvement focus |
| --safe | Conservative changes only |

## Improvement Types

| Type | Focus |
|------|-------|
| quality | Readability, patterns, SOLID |
| performance | Speed, memory, efficiency |
| maintainability | Structure, modularity, tests |

## Workflow

1. **Analyze** → Identify improvement opportunities
2. **Prioritize** → Rank by impact/risk
3. **Plan** → Group related changes
4. **Execute** → Apply improvements
5. **Verify** → Ensure no regressions

## Quality Improvements

- Extract functions/methods
- Improve naming
- Reduce complexity
- Apply design patterns

## Performance Improvements

- Optimize algorithms
- Reduce allocations
- Cache expensive operations
- Lazy evaluation

## Output

```markdown
## ✨ Improve: [target]

### Changes Applied
| Change | Impact | Risk |
|--------|--------|------|
| ... | High/Med/Low | Low/Med |

### Before/After
[Code comparison if significant]

### Verification
- [ ] Tests pass
- [ ] No performance regression
```

## Examples

```bash
/sc:improve src/api/ --type performance
/sc:improve lib/utils.ts --type quality --safe
/sc:improve --type maintainability
```
