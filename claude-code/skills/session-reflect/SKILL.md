---
name: session-reflect
description: |
  Task reflection and validation - assess completion and quality.
  Use when: (1) task completion check, (2) quality assessment, (3) session review,
  (4) keywords: reflect, review, validate, check, assess, done
  Accepts args: [--type task|session|completion] [--analyze] [--validate]
---

# session-reflect

Task reflection and validation.

## Usage

```
/sc:reflect [--type task|session|completion] [--analyze] [--validate]
```

| Arg | Description |
|-----|-------------|
| --type | Reflection scope |
| --analyze | Deep analysis |
| --validate | Strict validation |

## Reflection Types

| Type | Focus |
|------|-------|
| task | Current task progress |
| session | Overall session work |
| completion | Final completion check |

## Workflow

1. **Gather** → Collect task/session state
2. **Analyze** → Assess progress and quality
3. **Validate** → Check against requirements
4. **Document** → Record insights
5. **Recommend** → Suggest next steps

## Validation Checks

- [ ] All todos completed
- [ ] No partial implementations
- [ ] Tests pass
- [ ] Requirements met
- [ ] No TODO comments left

## Output

```markdown
## 🔍 Reflect: [type]

### Progress
| Task | Status | Quality |
|------|--------|---------|
| ... | ✅/❌ | Good/Needs work |

### Assessment
[Overall assessment]

### Insights
- [What went well]
- [What could improve]

### Next Steps
- [Recommended actions]
```

## Examples

```bash
/sc:reflect --type task
/sc:reflect --type session --analyze
/sc:reflect --type completion --validate
```
