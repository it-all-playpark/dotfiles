---
name: auto:review
description: PR をレビューし approve / request-changes を投稿。LGTM→exit0、要修正→exit1。
allowed-tools:
  - sc:review              # LLM-based review
  - Bash:(grep:*)          # grep
  - Bash:(gh pr review:*)  # gh
---

sc:review --pr $ARGUMENTS \
          --with-ci --decision --uc --language ja \
          --c7 --seq --think --verbose --cite \
          > /tmp/review.md && \

if grep -qi "LGTM" /tmp/review.md; then
  EVENT=approve
else
  EVENT=request-changes
fi && \

Bash(gh pr review $ARGUMENTS --${EVENT} --body-file /tmp/review.md) && \
[ "$EVENT" = approve ]
