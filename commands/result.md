---
description: Show the final answer of a finished Kimi job
argument-hint: '[job-id|--last]'
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" result $ARGUMENTS`

Present the output verbatim. If the job is still running, say so and suggest `/kimi:status <job-id>`.
