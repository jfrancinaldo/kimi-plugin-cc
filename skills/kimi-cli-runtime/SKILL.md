---
name: kimi-cli-runtime
description: Contract for calling the kimi-companion runtime from Claude Code (task, review, status, result, cancel) — how to delegate work to Kimi (Moonshot AI) and read its answer
user-invocable: false
---

# kimi-companion runtime

`kimi-companion.sh` runs Kimi headless through the Kimi Code CLI (`kimi -p`, stream-json). Every run is a job in
`~/.kimi-companion/jobs/<id>/` (prompt, raw output, answer, session id, state).

Call it as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/kimi-companion.sh" <command> ...`.

| Command | What it does |
|---|---|
| `task [opts] -- <prompt>` | Run a delegated task. Prompt can also come from `--prompt-file F` or stdin (`-`). |
| `review [--base REF] [--focus-file F [--delete-focus-file]] [focus]` | Read-only code review of the working tree (or `REF...HEAD`). |
| `adversarial-review [--base REF] [focus]` | Read-only review that tries to find reasons not to ship. |
| `status [JOB] [--all]` | Jobs for the current directory (or one job in detail). |
| `result [JOB\|--last]` | Final answer of a finished job. Exit 2 while still running. |
| `cancel JOB` | Stop a background job. |
| `setup` | Check the CLI and do a live test. |

Task options: `--read-only` (default: a restricted agent profile with only Read, Grep, Glob, FetchURL, WebSearch,
TodoList), `--write` (every Kimi tool, including shell, runs without asking — the CLI has no finer mode in prompt
mode), `--cwd DIR`, `--add-dir DIR`, `--model ALIAS`, `--background`, `--resume-last` / `--resume JOB` (a resumed
session keeps the tools it was created with), `--label TEXT`, `--swarm` (let Kimi fan the task out to its own parallel subagents; requires `--write`, because Kimi's subagents have shell access).

## Writing a good Kimi prompt

Kimi starts with no context from this conversation. State the goal, the relevant absolute paths, what is already
known or ruled out, the constraints, and the shape of the final report. Kimi always ends with a `## Result` section.

## Handling the answer

- Treat Kimi's output as a second opinion: verify any claim you act on before reporting it as confirmed.
- If Kimi changed files (`--write`), review the diff before calling the work done.
- Never paste secrets or personal data into a prompt. House rules go in `~/.config/kimi-companion/rules.md` (or
  `KIMI_COMPANION_RULES`) and are prepended to every task.
