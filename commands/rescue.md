---
description: Delegate an investigation, a fix or follow-up work to Kimi (Moonshot AI) through the kimi-rescue subagent
argument-hint: "[--background|--wait] [--resume|--fresh] [--write|--read-only] [--swarm] [--model <model>] [what Kimi should investigate, solve or continue]"
allowed-tools: Bash(bash:*), Agent
---

Invoke the `kimi:kimi-rescue` subagent via the `Agent` tool (`subagent_type: "kimi:kimi-rescue"`), forwarding the raw
user request as the prompt. `kimi:kimi-rescue` is a subagent, not a skill — do not call `Skill(kimi:rescue)` (that
re-enters this command).

Raw user request:
$ARGUMENTS

Rules:

- `--background` → run the subagent in the background; `--wait` or neither → foreground.
- Keep `--resume`, `--fresh`, `--write`, `--read-only`, `--swarm` and `--model` in the forwarded request; the subagent turns
  them into companion options.
- The final user-visible response is Kimi's output verbatim — do not paraphrase or add commentary.
- If the companion reports a missing API key or CLI, tell the user to run `/kimi:setup`.
- If the user gave no request, ask what Kimi should investigate or fix.
