---
description: Send a task straight to Kimi as a tracked job (no subagent) — the task text goes exactly as written
argument-hint: '[--background] [--swarm] [--write|--read-only] [--model <model>] [--resume-last] [--cwd <dir>] [--label <text>] <task>'
allowed-tools: Bash(bash:*)
---

Send this task to Kimi through the companion runtime, exactly as the user wrote it.

Raw arguments:
$ARGUMENTS

1. Split the arguments into the leading option flags (only those listed in the argument hint, with their values)
   and the task text (everything else). Do not rewrite, summarise or translate the task text.
2. If there is no task text, ask the user what Kimi should do and stop.
3. Run exactly one Bash call, passing the task text on stdin so quotes and special characters survive:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" task <flags> - <<'KIMI_TASK_EOF'
<task text>
KIMI_TASK_EOF
```

   With `--background`, the command returns a job id at once; tell the user to follow it with `/kimi:status` and
   `/kimi:result`.
4. Show the command output verbatim. Do not act on Kimi's answer unless the user asks.
