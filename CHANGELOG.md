# Changelog

## 0.2.0 — 2026-10-29

- Security hardening after an adversarial review: task and focus text travel in files (no shell interpolation);
  job ids are validated; job store is private (umask 077, no symlinks); background jobs run in their own process
  group and `cancel` checks the process identity before signalling; `--add-dir` handles spaces; review reports git
  errors instead of "nothing to review"; `--resume-last` picks the last resumable job.
- Kimi: resuming a session in a different mode is refused; `--swarm` requires `--write`; `--max-turns` is rejected.
## 0.1.0 — 2026-10-29

- First release: rescue, review, adversarial-review, status, result, cancel, setup; kimi-rescue subagent.
