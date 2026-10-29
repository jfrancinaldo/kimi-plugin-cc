# Kimi plugin for Claude Code

Use **Kimi (Moonshot AI)** from inside Claude Code to **review code or delegate tasks** — a second engineer that
works in the background while Claude keeps going. Same workflow as OpenAI's
[codex-plugin-cc](https://github.com/openai/codex-plugin-cc), for Kimi.

Kimi runs headless through the official **Kimi Code CLI** (`kimi -p`, stream-json output). Every run is a tracked
job you can check, read or cancel later.

## What you get

| | |
|---|---|
| `/kimi:rescue <task>` | Hand a debugging, research or implementation task to Kimi (`--write` lets it edit files; `--swarm` lets it run a team of its own subagents in parallel; `--background`; `--resume`) |
| `/kimi:task <task>` | Send a task straight to Kimi exactly as written (same flags; no subagent in between) |
| `/kimi:review [--base main] [focus]` | Read-only code review of your working tree or branch |
| `/kimi:adversarial-review [focus]` | Read-only review that tries to find reasons the change should **not** ship |
| `/kimi:status [job]` · `/kimi:result [job]` · `/kimi:cancel <job>` | Follow background jobs |
| `/kimi:setup` | Check the CLI and do a live test |
| `kimi:kimi-rescue` subagent | Claude can delegate to Kimi on its own when a task is large |

## Install

```text
/plugin marketplace add jfrancinaldo/kimi-plugin-cc
/plugin install kimi@kimi-plugin-cc
/kimi:setup
```

Requirements: Claude Code, `python3`, `bash`, and the Kimi Code CLI logged in (`kimi login`). If `kimi` is not on
your `PATH`, set `KIMI_BIN` (the installer puts it in `~/.kimi-code/bin/kimi`, which is found automatically).

## Permission modes

| Mode | Flag | Kimi can |
|---|---|---|
| read-only (default) | `--read-only` | read and search files and the web — runs with a restricted agent profile ([profiles/read-only.md](profiles/read-only.md)) that has no Write, Edit or shell |
| write | `--write` | every Kimi tool, including shell commands, **without asking** — the CLI has no finer mode in prompt mode |

A resumed session (`--resume`) keeps the tools it was created with. Kimi never pushes, deploys or publishes unless
the task explicitly says so, and always ends with a `## Result` section.

## Swarm mode (`--swarm`)

Kimi can spawn its own subagents. With `--swarm` it splits a large task into independent parts, runs them in
parallel and merges the results into one report — useful for audits across many files, multi-module refactors or
research with several sources. In read-only mode only the read-only `explore` and `plan` subagents are allowed ([profiles/read-only-swarm.md](profiles/read-only-swarm.md)).
Swarms finish faster on wide tasks but use more tokens.

```text
/kimi:rescue --swarm --background audit every route in src/routes for missing auth checks
/kimi:adversarial-review --swarm --base main
```

## Configuration

| Variable | Default |
|---|---|
| `KIMI_BIN` | `kimi` on `PATH`, then `~/.kimi-code/bin/kimi` |
| `KIMI_MODEL` | the CLI's `default_model` |
| `KIMI_COMPANION_HOME` | `~/.kimi-companion` (jobs) |
| `KIMI_COMPANION_RULES` | `~/.config/kimi-companion/rules.md` — your own rules, prepended to every task |

## Using the runtime directly

```bash
bash scripts/kimi-companion.sh task --background -- "Explain how auth works in src/; cite file:line."
bash scripts/kimi-companion.sh status
bash scripts/kimi-companion.sh result --last
```

## Em português

Plugin para usar o **Kimi (Moonshot AI)** dentro do Claude Code: revisar código ou receber tarefas pesadas em
segundo plano, como o plugin do Codex. Precisa do Kimi Code CLI com login (`kimi login`). Regras da sua equipe vão
em `~/.config/kimi-companion/rules.md` (ficam só na sua máquina).

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Moonshot AI or Anthropic.
