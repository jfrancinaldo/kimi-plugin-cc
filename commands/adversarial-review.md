---
description: Run a read-only Kimi adversarial review that looks for reasons the change should not ship
argument-hint: '[--wait|--background] [--base <ref>] [focus text, e.g. "auth and retries"]'
allowed-tools: Bash(bash:*), Bash(git status:*), Bash(git diff:*), Write, AskUserQuestion
---

Run a Kimi adversarial review of the current repository. Review-only: do not fix anything yourself.

Raw arguments: `$ARGUMENTS`

1. Split the arguments into flags (`--wait`, `--background`, `--base <ref>`) and the focus text (the rest).
2. Estimate the size: `git status --short --untracked-files=all` and `git diff --shortstat HEAD` (or
   `git diff --shortstat <base>...HEAD` with `--base`). Nothing to review → say so and stop.
3. Without `--wait`/`--background`, ask once with `AskUserQuestion`: `Wait for results` or `Run in background`
   (recommend waiting only for a tiny change of 1–2 files).
4. If there is focus text, write it unchanged to `/tmp/kimi-focus-<8 random hex characters>.md` with the **Write tool**.
5. Run exactly one Bash call, wrapping the `--base` value in single quotes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" adversarial-review <flags> [--focus-file '<file from step 4>']
```

6. Return Kimi's output verbatim. Apply fixes only if the user asks afterwards.
