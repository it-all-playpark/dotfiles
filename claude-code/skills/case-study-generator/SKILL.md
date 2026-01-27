---
name: case-study-generator
description: |
  Generate compelling case study documents from repository export files for sales and marketing purposes.
  Use when: (1) user wants to create a case study or introduction case (導入事例) from code/project,
  (2) user has a repository export markdown file to analyze, (3) keywords like "case study", "導入事例",
  "事例作成", "sales material from repo", (4) user needs business-focused documentation from technical projects.
  Supports multiple target audiences (decision-makers, technical staff, general prospects) and emphasis points
  (business outcomes, technical solutions, ease of adoption).
---

# Case Study Generator

Generate professional case study documents from repository export files.

## Workflow

```
1. Gather requirements → 2. Extract info → 3. Analyze → 4. Generate document
```

## Step 1: Gather Requirements

Ask user for:
- Source file path (repository export md)
- Target audience: `decision-makers` | `technical` | `general`
- Emphasis: `business-outcomes` | `technical-solution` | `adoption-ease`

## Step 2: Extract Info

```bash
~/.claude/skills/case-study-generator/scripts/extract-info.sh <file-path>
```

**Output**: JSON with project_name, sections, has_readme, metrics_found

## Step 3: Analyze Source

Read relevant sections based on extract-info output:
- README sections
- Feature descriptions
- Technical stack (simplified for audience)

## Step 4: Generate Document

Apply format from `references/format-guide.md`:

| Audience | Emphasis | Focus |
|----------|----------|-------|
| Decision-makers | Business outcomes | Metrics, ROI |
| Technical | Technical solution | Architecture, integration |
| General | Adoption ease | Simple language, quick wins |

## Output Quality Checklist

- [ ] No technical jargon for non-technical audiences
- [ ] Quantified benefits (time %, cost reduction)
- [ ] Before/After comparison table
- [ ] Clear call-to-action
- [ ] A4 1-2 pages equivalent

## Output Location

`docs/case-study-{project-name}.md`
