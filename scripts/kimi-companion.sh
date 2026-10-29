#!/usr/bin/env bash
# kimi-companion — delegate tasks from Claude Code to Kimi (Moonshot AI) and keep every run as a tracked job.
#
# Kimi runs headless through the Kimi Code CLI (`kimi -p`, stream-json output). Read-only runs use a restricted
# agent profile (profiles/read-only.md) because the CLI's prompt mode otherwise runs every tool without asking.
#
#   kimi-companion.sh task [--cwd DIR] [--add-dir DIR]... [--write | --read-only] [--model MODEL] [--background]
#                          [--swarm] [--resume-last | --resume JOB] [--label TEXT]
#                          [--prompt-file FILE [--delete-prompt-file] | -- PROMPT... | -]
#   kimi-companion.sh review [--base REF] [--model MODEL] [--background] [--focus-file FILE | FOCUS...]
#   kimi-companion.sh adversarial-review [same options as review]
#   kimi-companion.sh status [JOB] [--all]
#   kimi-companion.sh result [JOB | --last]
#   kimi-companion.sh cancel JOB
#   kimi-companion.sh setup
#
# Environment: KIMI_BIN (path to the kimi CLI), KIMI_MODEL (model alias; default = the CLI's default_model),
# KIMI_COMPANION_HOME, KIMI_COMPANION_RULES (extra rules file prepended to every task).
set -u
umask 077

VERSION="0.2.0"
HOME_DIR="${KIMI_COMPANION_HOME:-$HOME/.kimi-companion}"
JOBS="$HOME_DIR/jobs"
DEFAULT_MODEL="${KIMI_MODEL:-}"
RULES_FILE="${KIMI_COMPANION_RULES:-$HOME/.config/kimi-companion/rules.md}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PROFILE_RO="$(dirname "$SELF")/../profiles/read-only.md"
ID_RE='^kimi-[0-9]{8}-[0-9]{6}-[0-9]+$'

BASE_RULES='You are Kimi, running a task delegated by Claude Code through kimi-companion. Rules: never print secrets
(API keys, tokens, passwords, private keys, .env contents) or personal data; do not push, deploy, publish, or change
remote systems unless the task explicitly says so; never invent results — if you could not verify something, say so.
Answer in the language of the task. Finish with a "## Result" section: what you did, files changed (full paths),
evidence (command + short output), and open questions.'

SWARM_RULES='Swarm mode is on: split the work into independent parts and run them in parallel with your subagent
tools (one subagent per part, each with a precise brief), then verify and merge their findings yourself. Do not
spawn agents for trivial steps; keep the final answer a single, deduplicated report.'

die() { echo "kimi-companion: $*" >&2; exit 1; }

kimi_bin() {
  if [ -n "${KIMI_BIN:-}" ]; then echo "$KIMI_BIN"; return; fi
  command -v kimi 2>/dev/null && return
  [ -x "$HOME/.kimi-code/bin/kimi" ] && echo "$HOME/.kimi-code/bin/kimi"
}

secure_home() {  # job store: private, owned by us, never a symlink
  local p
  for p in "$HOME_DIR" "$JOBS"; do
    [ -L "$p" ] && die "refusing to use a symlink as job store: $p"
    mkdir -p "$p" || die "cannot create $p"
    [ -O "$p" ] || die "$p is not owned by you"
    chmod 700 "$p" || die "cannot make $p private"
  done
}

valid_id() { [[ "$1" =~ $ID_RE ]] || die "invalid job id: $1"; [ -d "$JOBS/$1" ] || die "no such job: $1"; }

need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

started_at() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

alive() {  # alive JOB_DIR — the recorded process still exists and is the same process (not a reused PID)
  local d="$1" pid
  pid=$(cat "$d/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(started_at "$pid")" = "$(cat "$d/pid_start" 2>/dev/null)" ]
}

state() {  # current state; a "running" job whose process is gone becomes "failed"
  local d="$JOBS/$1" s
  s=$(cat "$d/state" 2>/dev/null || echo unknown)
  if [ "$s" = running ] && [ -f "$d/pid" ] && ! alive "$d"; then s=failed; echo failed > "$d/state"; fi
  echo "$s"
}

meta() { (LABEL=""; SWARM=0; . "$JOBS/$1/meta.sh"; eval "echo \"\${$2}\""); }  # meta JOB VAR

last_job() {  # last_job [CWD] [resumable] — newest job, optionally for one directory / with a resumable session
  local j
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [[ "$j" =~ $ID_RE ]] && [ -f "$JOBS/$j/meta.sh" ] || continue
    [ -z "${1:-}" ] || [ "$(meta "$j" CWD)" = "$1" ] || continue
    if [ "${2:-}" = resumable ]; then
      [ -s "$JOBS/$j/session" ] && [ "$(state "$j")" != running ] || continue
    fi
    echo "$j"; return
  done
}

run_job() {  # run_job JOB_DIR — runs Kimi and records output, answer, session and final state
  local d="$1" rc=0 rules="$BASE_RULES" a
  local CWD MODE MODEL RESUME_SESSION LABEL SWARM=0
  # shellcheck disable=SC1091
  . "$d/meta.sh"
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
  while IFS= read -r a; do [ -n "$a" ] && args+=(--add-dir "$a"); done < "$d/add_dirs"
  if [ -n "$RESUME_SESSION" ]; then
    args+=(-S "$RESUME_SESSION")          # the resumed session keeps the profile it was created with
  elif [ "$MODE" = read-only ]; then
    args+=(--agent-file "$PROFILE_RO")
  fi
  date +%s > "$d/started"
  ( cd "$CWD" && exec "$(kimi_bin)" "${args[@]}" < /dev/null > "$d/output.jsonl" 2> "$d/stderr.log" ) || rc=$?
  date +%s > "$d/finished"
  python3 -I - "$d" <<'PY'
import json, os, sys
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
PY
  if [ "$rc" = 0 ] && [ -s "$d/answer.md" ]; then echo completed > "$d/state"; else echo failed > "$d/state"; fi
}

cmd_task() {
  local CWD="$PWD" MODE=read-only MODE_SET=0 MODEL="$DEFAULT_MODEL" BG=0 RESUME="" RESUME_LAST=0 SWARM=0
  local LABEL="" PROMPT_FILE="" DELETE_PROMPT=0 ADD_DIRS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) need_value $# "$1"; CWD="$2"; shift 2 ;;
      --add-dir) need_value $# "$1"; ADD_DIRS+=("$2"); shift 2 ;;
      --write) MODE=write; MODE_SET=1; shift ;;
      --read-only) MODE=read-only; MODE_SET=1; shift ;;
      --unrestricted) die "--unrestricted is GLM-only; for Kimi use --write (which already runs every tool)" ;;
      --model) need_value $# "$1"; MODEL="$2"; shift 2 ;;
      --max-turns) die "--max-turns is not supported by the kimi CLI" ;;
      --background) BG=1; shift ;;
      --wait) BG=0; shift ;;
      --swarm) SWARM=1; shift ;;
      --resume) need_value $# "$1"; RESUME="$2"; shift 2 ;;
      --resume-last) RESUME_LAST=1; shift ;;
      --fresh) RESUME_LAST=0; RESUME=""; shift ;;
      --label) need_value $# "$1"; LABEL="$2"; shift 2 ;;
      --prompt-file) need_value $# "$1"; PROMPT_FILE="$2"; shift 2 ;;
      --delete-prompt-file) DELETE_PROMPT=1; shift ;;
      --) shift; break ;;
      -) break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  [ -n "$(kimi_bin)" ] || die "kimi CLI not found: install Kimi Code CLI or set KIMI_BIN (run: kimi-companion.sh setup)"
  [ -d "$CWD" ] || die "working directory does not exist: $CWD"
  CWD="$(cd "$CWD" && pwd)"
  local a; for a in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do [ -d "$a" ] || die "--add-dir does not exist: $a"; done

  local session=""
  [ "$RESUME_LAST" = 1 ] && [ -z "$RESUME" ] && { RESUME="$(last_job "$CWD" resumable)"; [ -n "$RESUME" ] || die "no resumable Kimi job for $CWD"; }
  if [ -n "$RESUME" ]; then
    valid_id "$RESUME"
    session=$(cat "$JOBS/$RESUME/session" 2>/dev/null || true)
    [ -n "$session" ] || die "job $RESUME has no session to resume"
    # a resumed Kimi session keeps the tools it was created with: never silently upgrade or downgrade the mode
    local prev_mode; prev_mode="$(meta "$RESUME" MODE)"
    if [ "$MODE_SET" = 1 ] && [ "$MODE" != "$prev_mode" ]; then
      die "job $RESUME ran as $prev_mode; a resumed Kimi session keeps its tools, so it cannot continue as $MODE — start a new job instead"
    fi
    MODE="$prev_mode"
  fi
  # Kimi's built-in subagents (explore, plan, coder) carry their own tools, shell included, so a read-only parent
  # cannot keep them read-only. Swarm is therefore only offered together with --write.
  [ "$SWARM" = 1 ] && [ "$MODE" = read-only ] && \
    die "--swarm needs --write: Kimi's subagents have shell access, so a read-only swarm would not stay read-only"

  local id d
  id="kimi-$(date +%Y%m%d-%H%M%S)-$$"
  d="$JOBS/$id"; mkdir "$d" || die "cannot create job directory"
  if [ -n "$PROMPT_FILE" ]; then
    cat -- "$PROMPT_FILE" > "$d/prompt.md" || die "cannot read $PROMPT_FILE"
    [ "$DELETE_PROMPT" = 1 ] && rm -f -- "$PROMPT_FILE"
  elif [ "${1:-}" = - ] || [ $# -eq 0 ]; then cat > "$d/prompt.md"
  else printf '%s\n' "$*" > "$d/prompt.md"; fi
  [ -s "$d/prompt.md" ] || { rm -f "$d"/*; rmdir "$d"; die "empty prompt"; }
  : > "$d/add_dirs"; for a in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do (cd "$a" && pwd) >> "$d/add_dirs"; done
  printf 'CWD=%q\nMODE=%q\nMODEL=%q\nRESUME_SESSION=%q\nLABEL=%q\nSWARM=%q\n' \
    "$CWD" "$MODE" "$MODEL" "$session" "$LABEL" "$SWARM" > "$d/meta.sh"
  echo running > "$d/state"
  [ "$MODE" = write ] && echo "kimi-companion: note — write mode runs every Kimi tool (edits and shell) without asking" >&2

  if [ "$BG" = 1 ]; then
    set -m   # own process group, so cancel can stop Kimi and everything it started
    nohup bash "$SELF" __run "$id" < /dev/null > /dev/null 2>&1 &
    local pid=$!
    set +m
    echo "$pid" > "$d/pid"; echo "$pid" > "$d/pgid"; started_at "$pid" > "$d/pid_start"
    echo "Kimi job started in the background: $id"
    echo "Check it with: /kimi:status $id   ·   answer: /kimi:result $id   ·   stop: /kimi:cancel $id"
  else
    echo $$ > "$d/pid"; started_at $$ > "$d/pid_start"
    run_job "$d"
    cmd_result "$id"
  fi
}

cmd_status() {
  local all=0 j
  [ "${1:-}" = --all ] && { all=1; shift; }
  if [ -n "${1:-}" ]; then
    valid_id "$1"
    local d="$JOBS/$1" s t0 t1 CWD MODE MODEL LABEL="" SWARM=0
    s=$(state "$1"); . "$d/meta.sh"
    t0=$(cat "$d/started" 2>/dev/null || date +%s); t1=$(cat "$d/finished" 2>/dev/null || date +%s)
    echo "job:      $1${LABEL:+  ($LABEL)}"
    echo "state:    $s$([ "$SWARM" = 1 ] && echo "  ·  swarm")  ·  ran $(( (t1 - t0) / 60 ))m$(( (t1 - t0) % 60 ))s  ·  mode $MODE  ·  model ${MODEL:-default}"
    echo "cwd:      $CWD"
    echo "prompt:   $(head -c 200 "$d/prompt.md" | tr '\n' ' ')"
    if [ "$s" = failed ] && [ -s "$d/stderr.log" ]; then echo "stderr (tail):"; tail -5 "$d/stderr.log"; fi
    return 0
  fi
  printf '%-29s %-10s %-10s %-9s %s\n' JOB STATE MODE STARTED "LABEL / PROMPT"
  local n=0 now t; now=$(date +%s)
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [[ "$j" =~ $ID_RE ]] && [ -f "$JOBS/$j/meta.sh" ] || continue
    [ "$all" = 1 ] || [ "$(meta "$j" CWD)" = "$PWD" ] || continue
    t=$(cat "$JOBS/$j/started" 2>/dev/null || echo "$now")
    printf '%-29s %-10s %-10s %-9s %s\n' "$j" "$(state "$j")" "$(meta "$j" MODE)" "$(( (now - t) / 60 ))m ago" \
      "$(l=$(meta "$j" LABEL); echo "${l:-$(head -c 70 "$JOBS/$j/prompt.md" | tr '\n' ' ')}")"
    n=$((n + 1)); [ "$n" -ge 20 ] && break
  done
  [ "$n" = 0 ] && echo "(no Kimi jobs for $PWD — use --all to list every directory)"
  return 0
}

cmd_result() {
  local id="${1:-}"
  if [ -z "$id" ] || [ "$id" = --last ]; then id="$(last_job)"; [ -n "$id" ] || die "no Kimi jobs yet"; fi
  valid_id "$id"
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
  [ -n "${1:-}" ] || die "missing job id"
  valid_id "$1"
  local d="$JOBS/$1" pid pgid i
  [ "$(state "$1")" = running ] || { echo "job $1 is not running ($(state "$1"))"; return 0; }
  alive "$d" || { echo "job $1 is not running"; return 0; }
  pid=$(cat "$d/pid"); pgid=$(cat "$d/pgid" 2>/dev/null || true)
  if [ -n "$pgid" ]; then kill -TERM -- "-$pgid" 2>/dev/null; else pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do alive "$d" || break; sleep 0.5; done
  if alive "$d"; then
    if [ -n "$pgid" ]; then kill -KILL -- "-$pgid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
    sleep 0.5
  fi
  if alive "$d"; then echo "could not stop job $1 (pid $pid)"; return 1; fi
  echo cancelled > "$d/state"; echo "cancelled: $1"
}

cmd_review() {  # cmd_review review|adversarial-review [--base REF] [--cwd DIR] [--model M] [--background] [--focus-file F | FOCUS...]
  local kind="$1"; shift
  local base="" cwd="$PWD" pass=() focus="" focus_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) need_value $# "$1"; base="$2"; shift 2 ;;
      --cwd) need_value $# "$1"; cwd="$2"; shift 2 ;;
      --scope) need_value $# "$1"; [ "$2" = working-tree ] && base=""; shift 2 ;;
      --model) need_value $# "$1"; pass+=(--model "$2"); shift 2 ;;
      --background|--wait) pass+=("$1"); shift ;;
      --swarm) die "reviews are read-only and Kimi swarms need --write; use /kimi:task --write --swarm for a swarm audit" ;;
      --focus-file) need_value $# "$1"; focus_file="$2"; shift 2 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$focus_file" ]; then focus="$(cat -- "$focus_file")" || die "cannot read $focus_file"; rm -f -- "$focus_file"
  else focus="${*:-}"; fi
  [ -n "$focus" ] || focus="none given"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repository: $cwd"
  cwd="$(git -C "$cwd" rev-parse --show-toplevel)"
  local ctx target max=180000 rc
  ctx="$(mktemp "${TMPDIR:-/tmp}/kimi-review.XXXXXX")" || die "mktemp failed"
  if [ -n "$base" ]; then
    git -C "$cwd" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { rm -f "$ctx"; die "unknown git ref: $base"; }
    git -C "$cwd" diff --quiet "$base...HEAD"; rc=$?
    [ "$rc" -gt 1 ] && { rm -f "$ctx"; die "git diff failed for $base...HEAD"; }
    [ "$rc" = 0 ] && { rm -f "$ctx"; echo "Nothing to review: no changes in $base...HEAD."; return 0; }
    target="branch diff $base...HEAD"
    { echo "### git log $base..HEAD"; git -C "$cwd" log --oneline "$base..HEAD" | head -50
      echo; echo "### git diff --stat $base...HEAD"; git -C "$cwd" diff --stat "$base...HEAD"
      echo; echo "### git diff $base...HEAD"; git -C "$cwd" diff "$base...HEAD"; } > "$ctx" 2>&1
  else
    local st; st="$(git -C "$cwd" status --porcelain --untracked-files=all)" || { rm -f "$ctx"; die "git status failed"; }
    [ -n "$st" ] || { rm -f "$ctx"; echo "Nothing to review: the working tree is clean."; return 0; }
    target="working tree (staged + unstaged + untracked)"
    { echo "### git status --short"; echo "$st"
      if git -C "$cwd" rev-parse --verify --quiet HEAD >/dev/null; then
        echo; echo "### git diff --stat HEAD"; git -C "$cwd" diff --stat HEAD
        echo; echo "### git diff HEAD"; git -C "$cwd" diff HEAD
      else
        echo; echo "### git diff --cached (no commits yet)"; git -C "$cwd" diff --cached
        echo; echo "### git diff (unstaged)"; git -C "$cwd" diff
      fi
      echo; echo "### untracked files (read them with the Read tool)"
      git -C "$cwd" ls-files --others --exclude-standard | head -200; } > "$ctx" 2>&1
  fi
  if [ "$(wc -c < "$ctx")" -gt "$max" ]; then
    head -c "$max" "$ctx" > "$ctx.cut" && mv "$ctx.cut" "$ctx"
    printf '\n\n[diff truncated at %s bytes — read the changed files for the rest]\n' "$max" >> "$ctx"
  fi
  local prompt; prompt="$(mktemp "${TMPDIR:-/tmp}/kimi-review-prompt.XXXXXX")" || die "mktemp failed"
  python3 -I - "$(dirname "$SELF")/../prompts/$kind.md" "$ctx" "$target" "$focus" > "$prompt" <<'PY'
import sys
tpl, ctx, target, focus = sys.argv[1:5]
text = open(tpl).read()
print(text.replace("{{TARGET}}", target).replace("{{FOCUS}}", focus).replace("{{CONTEXT}}", open(ctx, errors="replace").read()))
PY
  rm -f "$ctx"
  cmd_task --read-only --cwd "$cwd" --label "$kind: ${focus:0:50}" --prompt-file "$prompt" --delete-prompt-file \
    ${pass[@]+"${pass[@]}"}
}

cmd_setup() {
  local ok=1 kb
  echo "kimi-companion $VERSION"
  kb="$(kimi_bin)"
  if [ -n "$kb" ]; then echo "✓ kimi CLI: $kb ($("$kb" --version 2>/dev/null | head -1))"; else
    echo "✗ kimi CLI not found — install Kimi Code CLI (https://www.kimi.com/code) or set KIMI_BIN"; ok=0; fi
  command -v python3 >/dev/null && echo "✓ python3" || { echo "✗ python3 not found (used to read JSON)"; ok=0; }
  echo "· model ${DEFAULT_MODEL:-CLI default} · read-only profile $PROFILE_RO"
  echo "· extra rules: $([ -s "$RULES_FILE" ] && echo "$RULES_FILE (sent to Kimi with every task)" || echo "none ($RULES_FILE)")"
  [ "$ok" = 1 ] || return 1
  echo "· live test…"
  if (cd "${TMPDIR:-/tmp}" && cmd_task --label setup -- "Reply with exactly: KIMI OK") | grep -q "KIMI OK"; then
    echo "✓ Kimi answered"
  else
    echo "✗ Kimi did not answer — if you are not logged in, run: kimi login"; return 1
  fi
}

secure_home
case "${1:-}" in
  task) shift; cmd_task "$@" ;;
  review|adversarial-review) cmd_review "$@" ;;
  status) shift; cmd_status "$@" ;;
  result) shift; cmd_result "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  setup) cmd_setup ;;
  __run) [[ "${2:-}" =~ $ID_RE ]] || die "invalid job id"; run_job "$JOBS/$2" ;;
  --version) echo "$VERSION" ;;
  *) sed -n '2,19p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
