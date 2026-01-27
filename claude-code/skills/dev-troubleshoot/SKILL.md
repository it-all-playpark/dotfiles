---
name: dev-troubleshoot
description: |
  Diagnose and resolve issues in code, builds, and system behavior.
  Use when: (1) debugging errors, (2) build failures, (3) performance issues,
  (4) keywords: troubleshoot, debug, fix, error, issue, problem, broken
  Accepts args: [issue] [--type bug|build|performance|deployment] [--trace] [--fix]
---

# dev-troubleshoot

Issue diagnosis and resolution.

## Usage

```
/sc:troubleshoot [issue] [--type bug|build|performance|deployment] [--trace] [--fix]
```

| Arg | Description |
|-----|-------------|
| issue | Issue description or error |
| --type | Issue category |
| --trace | Show detailed trace |
| --fix | Attempt automatic fix |

## Issue Types

| Type | Focus |
|------|-------|
| bug | Code defects, runtime errors |
| build | Compilation, bundling failures |
| performance | Slow code, memory issues |
| deployment | Environment, config issues |

## Workflow

1. **Analyze** → Parse error/issue
2. **Investigate** → Find root cause
3. **Diagnose** → Identify fix options
4. **Propose** → Rank solutions
5. **Fix** → Apply fix (if --fix)

## Diagnostic Steps

| Step | Action |
|------|--------|
| 1 | Read error message |
| 2 | Check recent changes |
| 3 | Examine related code |
| 4 | Test hypothesis |
| 5 | Verify fix |

## Output

```markdown
## 🔧 Troubleshoot: [issue]

### Diagnosis
**Root Cause**: [identified cause]
**Confidence**: High/Medium/Low

### Evidence
- [What points to this cause]

### Solution
1. [Primary fix]
2. [Alternative fix]

### Applied Fix (if --fix)
[What was changed]

### Verification
- [ ] Issue resolved
- [ ] No regressions
```

## Examples

```bash
/sc:troubleshoot "TypeError: undefined is not a function"
/sc:troubleshoot --type build --trace
/sc:troubleshoot "slow API response" --type performance --fix
```
