#!/usr/bin/env bash
# kimi-companion — delegate tasks from Claude Code to Kimi (Moonshot AI) and keep every run as a tracked job.
#
# Kimi runs headless through the Kimi Code CLI (`kimi -p`, stream-json output). Read-only runs use a restricted
# agent profile (profiles/read-only.md) because the CLI's prompt mode otherwise runs every tool without asking.
#
#   kimi-companion.sh task [--cwd DIR] [--add-dir DIR]... [--write | --read-only]
#                          [--model MODEL] [--background] [--swarm] [--resume-last | --resume JOB]
#                         [--label TEXT] [--prompt-file FILE | -- PROMPT... | -]
#   kimi-companion.sh review [--base REF] [--model MODEL] [--background] [FOCUS...]
#   kimi-companion.sh adversarial-review [--base REF] [--model MODEL] [--background] [FOCUS...]
#   kimi-companion.sh status [JOB] [--all]
#   kimi-companion.sh result [JOB | --last]
#   kimi-companion.sh cancel JOB
#   kimi-companion.sh setup
#
# Environment: KIMI_BIN (path to the kimi CLI), KIMI_MODEL (model alias; default = the CLI's default_model),
# KIMI_COMPANION_HOME, KIMI_COMPANION_RULES (extra rules file prepended to every task).
set -u

VERSION="0.1.0"
HOME_DIR="${KIMI_COMPANION_HOME:-$HOME/.kimi-companion}"
JOBS="$HOME_DIR/jobs"
DEFAULT_MODEL="${KIMI_MODEL:-}"
RULES_FILE="${KIMI_COMPANION_RULES:-$HOME/.config/kimi-companion/rules.md}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PROFILE_RO="$(dirname "$SELF")/../profiles/read-only.md"
PROFILE_RO_SWARM="$(dirname "$SELF")/../profiles/read-only-swarm.md"

kimi_bin() {
  if [ -n "${KIMI_BIN:-}" ]; then echo "$KIMI_BIN"; return; fi
  command -v kimi 2>/dev/null && return
  [ -x "$HOME/.kimi-code/bin/kimi" ] && echo "$HOME/.kimi-code/bin/kimi"
}
mkdir -p "$JOBS" && chmod 700 "$HOME_DIR" 2>/dev/null

BASE_RULES='You are Kimi, running a task delegated by Claude Code through kimi-companion. Rules: never print secrets
(API keys, tokens, passwords, private keys, .env contents) or personal data; do not push, deploy, publish, or change
remote systems unless the task explicitly says so; never invent results — if you could not verify something, say so.
Answer in the language of the task. Finish with a "## Result" section: what you did, files changed (full paths),
evidence (command + short output), and open questions.'

SWARM_RULES='Swarm mode is on: split the work into independent parts and run them in parallel with your subagent
tools (one subagent per part, each with a precise brief), then verify and merge their findings yourself. Do not
spawn agents for trivial steps; keep the final answer a single, deduplicated report.'



die() { echo "kimi-companion: $*" >&2; exit 1; }

jget() {  # jget FILE KEY — print a top-level field of a JSON file (empty if missing)
  python3 -I -c 'import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v)' "$1" "$2"
}

state() {  # current state of a job; a "running" job whose process died becomes "failed"
  local d="$JOBS/$1" s pid
  s=$(cat "$d/state" 2>/dev/null || echo unknown)
  if [ "$s" = running ]; then
    pid=$(cat "$d/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then s=failed; echo failed > "$d/state"; fi
  fi
  echo "$s"
}

last_job() {  # last_job [CWD] — newest job id, optionally only for one working directory
  local j
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [ -f "$JOBS/$j/meta.sh" ] || continue
    if [ -z "${1:-}" ] || [ "$(. "$JOBS/$j/meta.sh"; echo "$CWD")" = "$1" ]; then echo "$j"; return; fi
  done
}

run_job() {  # run_job JOB_DIR — runs Kimi and records output, answer, session and final state
  local d="$1" rc=0 rules="$BASE_RULES" a
  # shellcheck disable=SC1091
  . "$d/meta.sh"
  SWARM=0; . "$d/meta.sh"
  [ "$SWARM" = 1 ] && rules="$rules

$SWARM_RULES"
  [ -s "$RULES_FILE" ] && rules="$rules

$(cat "$RULES_FILE")"
  local text
  text="<rules>
$rules
</rules>

<task>
$(cat "$d/prompt.md")
</task>"
  local args=(-p "$text" --output-format stream-json)
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  for a in $ADD_DIRS; do args+=(--add-dir "$a"); done
  if [ -n "$RESUME_SESSION" ]; then
    args+=(-S "$RESUME_SESSION")          # the resumed session keeps the profile it was created with
  elif [ "$MODE" = read-only ] && [ "$SWARM" = 1 ]; then
    args+=(--agent-file "$PROFILE_RO_SWARM")
  elif [ "$MODE" = read-only ]; then
    args+=(--agent-file "$PROFILE_RO")
  fi
  date +%s > "$d/started"
  ( cd "$CWD" && "$(kimi_bin)" "${args[@]}" < /dev/null > "$d/output.jsonl" 2> "$d/stderr.log" ) || rc=$?
  date +%s > "$d/finished"
  python3 -I - "$d" <<'PY2'
import json, sys, os
d = sys.argv[1]
answer, session, errors = "", "", []
for line in open(os.path.join(d, "output.jsonl"), errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        m = json.loads(line)
    except ValueError:
        errors.append(line)
        continue
    if m.get("role") == "assistant" and isinstance(m.get("content"), str) and m["content"].strip():
        answer = m["content"]
    if m.get("type") == "session.resume_hint":
        session = m.get("session_id", "")
open(os.path.join(d, "answer.md"), "w").write(answer)
open(os.path.join(d, "session"), "w").write(session)
if errors:
    with open(os.path.join(d, "stderr.log"), "a") as f:
        f.write("\n".join(errors) + "\n")
PY2
  if [ "$rc" = 0 ] && [ -s "$d/answer.md" ]; then echo completed > "$d/state"; else echo failed > "$d/state"; fi
}

cmd_task() {
  local CWD="$PWD" ADD_DIRS="" MODE=read-only MODEL="$DEFAULT_MODEL" MAX_TURNS=0 BG=0 RESUME="" RESUME_LAST=0 SWARM=0
  local LABEL="" PROMPT_FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) CWD="$2"; shift 2 ;;
      --add-dir) ADD_DIRS="$ADD_DIRS $2"; shift 2 ;;
      --write) MODE=write; shift ;;
      --read-only) MODE=read-only; shift ;;
      --model) MODEL="$2"; shift 2 ;;
      --max-turns) shift 2 ;;   # not supported by the kimi CLI; accepted and ignored
      --background) BG=1; shift ;;
      --swarm) SWARM=1; shift ;;
      --wait) BG=0; shift ;;
      --resume) RESUME="$2"; shift 2 ;;
      --resume-last) RESUME_LAST=1; shift ;;
      --fresh) RESUME_LAST=0; RESUME=""; shift ;;
      --label) LABEL="$2"; shift 2 ;;
      --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
      --) shift; break ;;
      -) break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  [ -n "$(kimi_bin)" ] || die "kimi CLI not found: install Kimi Code CLI or set KIMI_BIN (run: kimi-companion.sh setup)"
  [ -d "$CWD" ] || die "working directory does not exist: $CWD"
  CWD="$(cd "$CWD" && pwd)"

  local id d session=""
  id="kimi-$(date +%Y%m%d-%H%M%S)-$$"
  d="$JOBS/$id"; mkdir -p "$d"; chmod 700 "$d"
  if [ -n "$PROMPT_FILE" ]; then cat "$PROMPT_FILE" > "$d/prompt.md" || die "cannot read $PROMPT_FILE"
  elif [ "${1:-}" = - ] || [ $# -eq 0 ]; then cat > "$d/prompt.md"
  else printf '%s\n' "$*" > "$d/prompt.md"; fi
  [ -s "$d/prompt.md" ] || { rm -f "$d"/*; rmdir "$d"; die "empty prompt"; }

  [ "$RESUME_LAST" = 1 ] && RESUME="$(last_job "$CWD")"
  if [ -n "$RESUME" ]; then
    session=$(cat "$JOBS/$RESUME/session" 2>/dev/null || true)
    [ -n "$session" ] || die "job $RESUME has no session to resume"
    local prev_mode; prev_mode="$(. "$JOBS/$RESUME/meta.sh"; echo "$MODE")"
    if [ "$prev_mode" != "$MODE" ]; then
      echo "kimi-companion: a resumed Kimi session keeps its original tools — running as $prev_mode" >&2
      MODE="$prev_mode"
    fi
  fi
  printf 'CWD=%q\nADD_DIRS=%q\nMODE=%q\nMODEL=%q\nMAX_TURNS=%q\nRESUME_SESSION=%q\nLABEL=%q\nSWARM=%q\n' \
    "$CWD" "$ADD_DIRS" "$MODE" "$MODEL" "$MAX_TURNS" "$session" "$LABEL" "$SWARM" > "$d/meta.sh"
  echo running > "$d/state"
  [ "$MODE" = write ] && echo "kimi-companion: note — write mode runs every Kimi tool (edits and shell) without asking" >&2

  if [ "$BG" = 1 ]; then
    nohup bash "$SELF" __run "$id" > /dev/null 2>&1 &
    echo $! > "$d/pid"
    echo "Kimi job started in the background: $id"
    echo "Check it with: /kimi:status $id   ·   answer: /kimi:result $id   ·   stop: /kimi:cancel $id"
  else
    echo $$ > "$d/pid"
    run_job "$d"
    cmd_result "$id"
  fi
}

cmd_status() {
  local all=0 j
  if [ "${1:-}" = --all ]; then all=1; shift; fi
  if [ -n "${1:-}" ]; then
    local d="$JOBS/$1" s t0 t1
    [ -d "$d" ] || die "no such job: $1"
    s=$(state "$1"); LABEL=""; SWARM=0; . "$d/meta.sh"
    t0=$(cat "$d/started" 2>/dev/null || date +%s); t1=$(cat "$d/finished" 2>/dev/null || date +%s)
    echo "job:      $1${LABEL:+  ($LABEL)}"
    echo "state:    $s$([ "${SWARM:-0}" = 1 ] && echo "  ·  swarm")  ·  $(( (t1 - t0) / 60 ))m$(( (t1 - t0) % 60 ))s  ·  mode $MODE  ·  model ${MODEL:-default}"
    echo "cwd:      $CWD"
    echo "prompt:   $(head -c 200 "$d/prompt.md" | tr '\n' ' ')"
    if [ "$s" = failed ] && [ -s "$d/stderr.log" ]; then echo "stderr (tail):"; tail -5 "$d/stderr.log"; fi
    return 0
  fi
  printf '%-30s %-10s %-12s %-8s %s\n' JOB STATE MODE AGE "LABEL / PROMPT"
  local n=0 now; now=$(date +%s)
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [ -f "$JOBS/$j/meta.sh" ] || continue
    LABEL=""; . "$JOBS/$j/meta.sh"
    [ "$all" = 1 ] || [ "$CWD" = "$PWD" ] || continue
    printf '%-30s %-10s %-12s %-8s %s\n' "$j" "$(state "$j")" "$MODE" \
      "$(( (now - $(cat "$JOBS/$j/started" 2>/dev/null || echo "$now")) / 60 ))m" \
      "${LABEL:-$(head -c 70 "$JOBS/$j/prompt.md" | tr '\n' ' ')}"
    n=$((n + 1)); [ "$n" -ge 20 ] && break
  done
  [ "$n" = 0 ] && echo "(no Kimi jobs for $PWD — use --all to list every directory)"
  return 0
}

cmd_result() {
  local id="${1:-}"
  [ -z "$id" ] || [ "$id" = --last ] && id="$(last_job)"
  [ -n "$id" ] && [ -d "$JOBS/$id" ] || die "no such job: ${1:-<none>}"
  local d="$JOBS/$id" s
  s=$(state "$id")
  case "$s" in
    running) echo "Kimi job $id is still running. Check later with /kimi:status $id."; return 2 ;;
    completed) cat "$d/answer.md"; echo; echo "[kimi-companion] job $id · session $(cat "$d/session")" ;;
    *) echo "Kimi job $id ended as: $s"
       [ -s "$d/answer.md" ] && cat "$d/answer.md"
       [ -s "$d/stderr.log" ] && { echo "--- stderr (tail)"; tail -15 "$d/stderr.log"; }
       return 1 ;;
  esac
}

cmd_cancel() {
  local d="$JOBS/${1:?missing job id}" pid
  [ -d "$d" ] || die "no such job: $1"
  pid=$(cat "$d/pid" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then echo "job $1 is not running ($(state "$1"))"; return 0; fi
  pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
  echo cancelled > "$d/state"; echo "cancelled: $1"
}

cmd_setup() {
  local ok=1 kb
  echo "kimi-companion $VERSION"
  kb="$(kimi_bin)"
  if [ -n "$kb" ]; then echo "✓ kimi CLI: $kb ($("$kb" --version 2>/dev/null | head -1))"; else
    echo "✗ kimi CLI not found — install Kimi Code CLI (https://www.kimi.com/code) or set KIMI_BIN"; ok=0; fi
  command -v python3 >/dev/null && echo "✓ python3" || { echo "✗ python3 not found (used to read JSON)"; ok=0; }
  echo "· model ${DEFAULT_MODEL:-CLI default} · read-only profile $PROFILE_RO"
  echo "· extra rules: $([ -s "$RULES_FILE" ] && echo "$RULES_FILE" || echo "none ($RULES_FILE)")"
  [ "$ok" = 1 ] || return 1
  echo "· live test…"
  if (cd "${TMPDIR:-/tmp}" && cmd_task --label setup -- "Reply with exactly: KIMI OK") | grep -q "KIMI OK"; then
    echo "✓ Kimi answered"
  else
    echo "✗ Kimi did not answer — if you are not logged in, run: kimi login"; return 1
  fi
}

cmd_review() {  # cmd_review review|adversarial-review [--base REF] [--cwd DIR] [--model M] [--background] [FOCUS...]
  local kind="$1"; shift
  local base="" cwd="$PWD" pass=() focus
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --cwd) cwd="$2"; shift 2 ;;
      --scope) [ "$2" = working-tree ] && base=""; shift 2 ;;
      --model) pass+=(--model "$2"); shift 2 ;;
      --background|--wait|--swarm) pass+=("$1"); shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  focus="${*:-none given}"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repository: $cwd"
  cwd="$(git -C "$cwd" rev-parse --show-toplevel)"
  local ctx target max=180000
  ctx="$(mktemp "${TMPDIR:-/tmp}/kimi-review.XXXXXX")"
  if [ -n "$base" ]; then
    target="branch diff $base...HEAD"
    { echo "### git log $base..HEAD"; git -C "$cwd" log --oneline "$base..HEAD" | head -50
      echo; echo "### git diff --stat $base...HEAD"; git -C "$cwd" diff --stat "$base...HEAD"
      echo; echo "### git diff $base...HEAD"; git -C "$cwd" diff "$base...HEAD"; } > "$ctx" 2>&1
  else
    target="working tree (staged + unstaged + untracked) against HEAD"
    { echo "### git status --short"; git -C "$cwd" status --short --untracked-files=all
      echo; echo "### git diff --stat HEAD"; git -C "$cwd" diff --stat HEAD 2>/dev/null || git -C "$cwd" diff --stat
      echo; echo "### git diff HEAD"; git -C "$cwd" diff HEAD 2>/dev/null || git -C "$cwd" diff
      echo; echo "### untracked files (read them with the Read tool)"
      git -C "$cwd" ls-files --others --exclude-standard | head -200; } > "$ctx" 2>&1
  fi
  if ! grep -qE '^[-+ ]|^\?\?| [MADRCU?]{1,2} ' "$ctx"; then rm -f "$ctx"; echo "Nothing to review for $target."; return 0; fi
  if [ "$(wc -c < "$ctx")" -gt "$max" ]; then
    head -c "$max" "$ctx" > "$ctx.cut"; mv "$ctx.cut" "$ctx"
    printf '\n\n[diff truncated at %s bytes — run `git diff` yourself for the rest]\n' "$max" >> "$ctx"
  fi
  local prompt; prompt="$(mktemp "${TMPDIR:-/tmp}/kimi-review-prompt.XXXXXX")"
  python3 -I - "$(dirname "$SELF")/../prompts/$kind.md" "$ctx" "$target" "$focus" > "$prompt" <<'PY'
import sys
tpl, ctx, target, focus = sys.argv[1:5]
text = open(tpl).read()
print(text.replace("{{TARGET}}", target).replace("{{FOCUS}}", focus).replace("{{CONTEXT}}", open(ctx, errors="replace").read()))
PY
  rm -f "$ctx"
  cmd_task --read-only --cwd "$cwd" --label "$kind: ${focus:0:50}" --prompt-file "$prompt" ${pass[@]+"${pass[@]}"}
  local rc=$?; rm -f "$prompt"; return $rc
}

case "${1:-}" in
  task) shift; cmd_task "$@" ;;
  review|adversarial-review) cmd_review "$@" ;;
  status) shift; cmd_status "$@" ;;
  result) shift; cmd_result "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  setup) cmd_setup ;;
  __run) run_job "$JOBS/$2" ;;
  --version) echo "$VERSION" ;;
  *) sed -n '2,19p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
