---
name: dev-flow
description: |
  End-to-end development flow automation - from issue to merged PR.
  Use when: (1) complete development cycle needed, (2) issue to PR automation,
  (3) keywords: full flow, development cycle, issue to PR
  Accepts args: <issue-number> [--strategy tdd|bdd|ddd] [--depth minimal|standard|comprehensive] [--base <branch>] [--max-iterations N]
allowed-tools:
  - Skill
  - Bash
---

# Dev Flow

## Usage

```
/dev-flow <issue> [--strategy tdd] [--depth comprehensive] [--base dev] [--max-iterations 10]
```

## Workflow

1. Skill: `dev-kickoff $ISSUE --strategy $STRATEGY --depth $DEPTH --base $BASE`
2. Get PR URL: `gh pr view --json url --jq .url`
3. Skill: `pr-iterate $PR --max-iterations $MAX`
