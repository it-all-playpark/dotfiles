---
name: pr-iterate
description: |
  Continuous improvement loop - iterate on PR until LGTM.
  Use when: (1) PR needs multiple rounds of fixes, (2) automated improvement cycle,
  (3) keywords: iterate, improve loop, continuous fix, until LGTM
  Accepts args: <pr-number-or-url> [--max-iterations N]
allowed-tools:
  - Skill
  - Bash
---

# PR Iterate

## Usage

```
/pr-iterate <pr> [--max-iterations N]
```

| Arg | Default |
|-----|---------|
| `--max-iterations` | `10` |

## Workflow

1. Run: `~/.claude/skills/pr-iterate/scripts/pr-iterate-setup.sh $PR`
2. Loop (max N iterations):
   - Skill: `pr-review $PR`
   - If LGTM → exit
   - Skill: `pr-fix $PR`
