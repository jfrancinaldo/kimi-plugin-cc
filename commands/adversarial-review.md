---
description: Run a read-only Kimi (Moonshot AI) adversarial review that looks for reasons the change should not ship
argument-hint: '[--wait|--background] [--base <ref>] [focus text, e.g. "auth and retries"]'
allowed-tools: Bash(bash:*), Bash(git:*), AskUserQuestion
---

Run a Kimi adversarial review of the current repository. Review-only: do not fix anything yourself.

Raw arguments: `$ARGUMENTS`

1. Estimate the size with `git status --short --untracked-files=all` and `git diff --shortstat HEAD` (or the
   `--base` diff). Nothing to review → say so and stop.
2. Without `--wait`/`--background`, ask once with `AskUserQuestion` (`Wait for results` / `Run in background`).
3. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" adversarial-review $ARGUMENTS
```

4. Return Kimi's output verbatim.
