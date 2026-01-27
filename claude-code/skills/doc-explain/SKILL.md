---
name: doc-explain
description: |
  Provide clear explanations of code, concepts, and system behavior.
  Use when: (1) understanding code, (2) learning concepts, (3) knowledge transfer,
  (4) keywords: explain, how does, what is, why, understand
  Accepts args: [target] [--level basic|intermediate|advanced] [--format text|examples]
---

# doc-explain

Code and concept explanation with educational clarity.

## Usage

```
/sc:explain [target] [--level basic|intermediate|advanced] [--format text|examples]
```

| Arg | Description |
|-----|-------------|
| target | Code/concept to explain |
| --level | Audience level |
| --format | Explanation format |

## Explanation Levels

| Level | Approach |
|-------|----------|
| basic | Simple terms, analogies |
| intermediate | Technical details |
| advanced | Deep dive, edge cases |

## Workflow

1. **Analyze** → Understand target thoroughly
2. **Assess** → Determine appropriate depth
3. **Structure** → Plan explanation flow
4. **Generate** → Create clear explanation
5. **Validate** → Ensure accuracy

## Output

```markdown
## 📚 Explanation: [target]

### Overview
[Simple summary]

### How It Works
[Step-by-step explanation]

### Key Concepts
| Concept | Description |
|---------|-------------|
| ... | ... |

### Examples (if --format examples)
```code
// Example with comments
```

### Related Topics
- [Links to related concepts]
```

## Examples

```bash
/sc:explain src/auth/jwt.ts --level intermediate
/sc:explain "React hooks" --format examples
/sc:explain "dependency injection" --level basic
```
