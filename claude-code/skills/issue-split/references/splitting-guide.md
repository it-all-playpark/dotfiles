# Issue Splitting Guide

## Splitting Criteria

### Conflict-Free Decomposition

Tasks should be split to avoid file conflicts:

| Good Split | Bad Split |
|------------|-----------|
| Domain layer / Infra layer | Feature A / Feature B (same files) |
| API / UI / Tests | Mixed concerns per task |
| Module A / Module B | Cross-cutting changes |

### Dependency Order

```
Order 1 (parallel): Domain, Types, Interfaces
Order 2 (parallel): Infrastructure, Services
Order 3 (depends on 1-2): Integration
Order 4 (depends on 1-3): Tests
Order 5 (depends on all): Documentation
```

### Task Size Guidelines

| Size | Lines | Duration |
|------|-------|----------|
| Small | <100 | 30min |
| Medium | 100-300 | 1-2h |
| Large | 300+ | Split further |

## Task Structure

Each sub-task should include:

```json
{
  "title": "Clear, action-oriented title",
  "body": "Detailed implementation instructions",
  "target_files": ["src/domain/**/*.ts"],
  "order": 1,
  "parallel": true,
  "depends_on": []
}
```

## Implementation Plan Format

```markdown
### Implementation Plan (Auto-generated)

| Order | Issue | Title | Parallel |
|-------|-------|-------|----------|
| 01 | #101 | Domain layer | Yes |
| 01 | #102 | Type definitions | Yes |
| 02 | #103 | Service layer | No |
| 03 | #104 | Tests | No |

**Execution Strategy:**
- Order 01 tasks can run in parallel
- Order 02+ tasks depend on previous orders
```

## Labels

| Label | Purpose |
|-------|---------|
| `sub-task` | Identifies as sub-issue |
| `order-NN` | Execution order (01-99) |
| `parallel` | Can run with same-order tasks |
| `blocked` | Waiting on dependency |

## Analysis Output

The analysis phase should produce:

1. Task breakdown with conflict analysis
2. Dependency graph
3. Parallel execution groups
4. Estimated total effort
