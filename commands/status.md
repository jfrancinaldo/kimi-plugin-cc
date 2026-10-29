---
description: Show active and recent Kimi jobs for this directory (or one job in detail)
argument-hint: '[job-id] [--all]'
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" status $ARGUMENTS`

Without a job id: render the output as one compact Markdown table. With a job id: show the full output as-is.
