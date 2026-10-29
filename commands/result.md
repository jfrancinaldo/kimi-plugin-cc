---
description: Show the final answer of a finished Kimi job
argument-hint: '[job-id|--last]'
allowed-tools: Bash(bash:*)
---

Raw arguments: `$ARGUMENTS`

Accept only these argument forms and refuse anything else without running a command:
- empty, `--last`
- a job id matching `^kimi-[0-9]{8}-[0-9]{6}-[0-9]+$`

Then run exactly one Bash call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" result <validated arguments>
```

Present the output verbatim. If the job is still running, say so and suggest `/kimi
