---
name: plan-design
description: |
  Design system architecture, APIs, and component interfaces.
  Use when: (1) architecture planning, (2) API design, (3) component design,
  (4) keywords: design, architect, plan, spec, schema, interface
  Accepts args: [target] [--type architecture|api|component|database] [--format diagram|spec|code]
---

# plan-design

System and component design with specifications.

## Usage

```
/sc:design [target] [--type architecture|api|component|database] [--format diagram|spec|code]
```

| Arg | Description |
|-----|-------------|
| target | What to design |
| --type | Design type |
| --format | Output format |

## Design Types

| Type | Output |
|------|--------|
| architecture | System diagrams, component relationships |
| api | Endpoint specs, request/response schemas |
| component | Interface definitions, prop types |
| database | Schema design, relationships, indexes |

## Workflow

1. **Analyze** → Requirements, constraints
2. **Design** → Create specifications
3. **Validate** → Check consistency
4. **Document** → Generate artifacts

## Output Formats

| Format | Description |
|--------|-------------|
| diagram | ASCII/mermaid diagrams |
| spec | Detailed specification doc |
| code | TypeScript interfaces, schemas |

## Output

```markdown
## 📐 Design: [target]

### Overview
[High-level description]

### Components
| Component | Responsibility |
|-----------|---------------|
| ... | ... |

### Interfaces
[TypeScript/schema definitions]

### Considerations
- [Trade-offs]
- [Alternatives considered]
```

## Examples

```bash
/sc:design "user service" --type api --format spec
/sc:design "payment flow" --type architecture
/sc:design "User model" --type database --format code
```
