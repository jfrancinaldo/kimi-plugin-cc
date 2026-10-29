---
description: Run a read-only Kimi (Moonshot AI) code review of the local git changes
argument-hint: '[--wait|--background] [--base <ref>] [focus text]'
allowed-tools: Bash(bash:*), Bash(git:*), AskUserQuestion
---

Run a Kimi review of the current repository. This command is review-only: do not fix anything yourself.

Raw arguments: `$ARGUMENTS`

1. Estimate the size: `git status --short --untracked-files=all` and `git diff --shortstat HEAD` (or
   `git diff --shortstat <base>...HEAD` when `--base` is given). If there is nothing to review, say so and stop.
2. If neither `--wait` nor `--background` was given, ask once with `AskUserQuestion`: `Wait for results` or
   `Run in background`, recommending wait only for a tiny change (1–2 files).
3. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" review $ARGUMENTS
```

   For background, add `--background` and tell the user to check `/kimi:status` and `/kimi:result`.
4. Return Kimi's output verbatim. Do not apply fixes unless the user asks afterwards.
