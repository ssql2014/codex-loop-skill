#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${CODEX_LOOP_HOME:-$HOME/codex-loop}"
JOBS_DIR="$BASE_DIR/jobs"
SEND_CURRENT_BIN_DEFAULT="$SCRIPT_DIR/codex-send-current.sh"
SEND_CURRENT_BIN="${CODEX_LOOP_SEND_CURRENT_BIN:-$SEND_CURRENT_BIN_DEFAULT}"
DEFAULT_MODE="terminal"
TERMINAL_IDLE_TIMEOUT="${CODEX_LOOP_TERMINAL_IDLE_TIMEOUT:-0}"
TERMINAL_AFTER_SEND_DELAY="${CODEX_LOOP_TERMINAL_AFTER_SEND_DELAY:-2}"
TERMINAL_ASAP_TURN_TIMEOUT="${CODEX_LOOP_TERMINAL_ASAP_TURN_TIMEOUT:-0}"
TERMINAL_TURN_TIMEOUT="${CODEX_LOOP_TERMINAL_TURN_TIMEOUT:-900}"
TERMINAL_REQUIRE_END_TAG_DEFAULT="${CODEX_LOOP_TERMINAL_REQUIRE_END_TAG:-0}"
DEFAULT_PROMPT_SENTINEL="__CODEX_LOOP_DEFAULT_PROMPT__"
FIELD_SEP=$'\034'
DYNAMIC_INITIAL_SECONDS=600
DYNAMIC_MIN_SECONDS=60
DYNAMIC_MAX_SECONDS=3600
REFLECTION_ENABLED="${CODEX_LOOP_REFLECTION:-1}"

usage() {
  cat <<'EOF'
Usage:
  codex-loop [--cwd PATH] [--start-now] [--count N] [--mode terminal] [--require-end-tag] [--supervise] [--supervisor-file PATH] [--window-id ID|--title-pattern TEXT|--tty TTY|--tmux-pane PANE] -- "<loop prompt>"
  codex-loop 5m check the deploy and summarize status
  codex-loop check the deploy every 20m
  codex-loop check the deploy
  codex-loop asap check the deploy and immediately continue after each run
  codex-loop
  codex-loop ensure --name JOB_NAME [--cwd PATH] [--start-now] [--count N] [--mode terminal] [--require-end-tag] [--supervise] [--supervisor-file PATH] [--window-id ID|--title-pattern TEXT|--tty TTY|--tmux-pane PANE] -- "<loop prompt>"
  codex-loop list
  codex-loop show JOB_ID
  codex-loop run-now JOB_ID
  codex-loop restart JOB_ID
  codex-loop cancel JOB_ID
  codex-loop parse "<loop prompt>"

Examples:
  codex-loop --cwd "$PWD" -- "5m check the deploy and summarize status"
  codex-loop "check pane 35 every 10 minutes"
  codex-loop "check whether CI passed and address review comments"
  codex-loop "asap keep improving this issue until blocked"
  codex-loop --count 5 -- "asap continue"
  codex-loop "15m"
  codex-loop
  codex-loop ensure --name deploy-watch --cwd "$PWD" -- "5m check the deploy"
  codex-loop ensure --name current-audit --mode terminal --window-id 40000 -- "10m audit the live evas session"
  codex-loop ensure --name guarded-fix --supervise --supervisor-file .codex/loop-supervisor.md -- "asap continue until the issue is fixed"
  codex-loop list
  codex-loop show ab12cd34
  codex-loop run-now ab12cd34
  codex-loop cancel ab12cd34
EOF
}

die() {
  echo "codex-loop: $*" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p "$JOBS_DIR"
}

trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

escape_squotes() {
  printf '%s' "${1-}" | sed "s/'/'\\\\''/g"
}

now_epoch() {
  date +%s
}

now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

epoch_to_local() {
  local epoch="$1"
  if date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z' >/dev/null 2>&1; then
    date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z'
  else
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z'
  fi
}

generate_job_id() {
  uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-8
}

pid_alive() {
  local pid="${1-}"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

job_dir() {
  printf '%s' "$JOBS_DIR/$1"
}

find_job_dirs_by_name() {
  local name="$1"
  ensure_dirs

  shopt -s nullglob
  local -a metas=()
  metas=("$JOBS_DIR"/*/meta.env)
  shopt -u nullglob

  local meta jobdir
  for meta in "${metas[@]}"; do
    jobdir="$(dirname "$meta")"
    load_job "$jobdir"
    if [[ "${JOB_NAME:-}" == "$name" ]]; then
      printf '%s\n' "$jobdir"
    fi
  done
}

resolve_jobdir() {
  local ref="$1"
  local exact
  exact="$(job_dir "$ref")"
  if [[ -d "$exact" ]]; then
    printf '%s' "$exact"
    return 0
  fi

  local matches=()
  local match
  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    matches+=("$match")
  done < <(find_job_dirs_by_name "$ref")

  (( ${#matches[@]} > 0 )) || die "unknown job id or name: $ref"

  local jobdir best="" best_updated="" best_priority=-1 status priority
  for jobdir in "${matches[@]}"; do
    load_job "$jobdir"
    status="$(job_display_status "$jobdir")"
    case "$status" in
      running) priority=2 ;;
      scheduled) priority=1 ;;
      *) priority=0 ;;
    esac

    if (( priority > best_priority )); then
      best="$jobdir"
      best_updated="${UPDATED_AT:-}"
      best_priority="$priority"
      continue
    fi

    if (( priority == best_priority )) && [[ "${UPDATED_AT:-}" > "$best_updated" ]]; then
      best="$jobdir"
      best_updated="${UPDATED_AT:-}"
    fi
  done

  printf '%s' "$best"
}

load_job() {
  local jobdir="$1"
  [[ -f "$jobdir/meta.env" ]] || die "missing job metadata: $jobdir/meta.env"
  MODE="terminal"
  TARGET_WINDOW_ID=""
  TARGET_TITLE_PATTERN=""
  TARGET_TTY=""
  SEND_DELAY="0"
  SCHEDULE_MODE="fixed"
  PROMPT_SOURCE="inline"
  MAX_RUNS="0"
  REQUIRE_END_TAG="$TERMINAL_REQUIRE_END_TAG_DEFAULT"
  SUPERVISE="0"
  SUPERVISOR_FILE=""
  REFLECTION="$REFLECTION_ENABLED"
  # shellcheck disable=SC1090
  source "$jobdir/meta.env"
  MODE="${MODE:-terminal}"
  TARGET_WINDOW_ID="${TARGET_WINDOW_ID:-}"
  TARGET_TITLE_PATTERN="${TARGET_TITLE_PATTERN:-}"
  TARGET_TTY="${TARGET_TTY:-}"
  TARGET_TMUX_PANE="${TARGET_TMUX_PANE:-}"
  SEND_DELAY="${SEND_DELAY:-0}"
  SCHEDULE_MODE="${SCHEDULE_MODE:-fixed}"
  PROMPT_SOURCE="${PROMPT_SOURCE:-inline}"
  MAX_RUNS="${MAX_RUNS:-0}"
  REQUIRE_END_TAG="${REQUIRE_END_TAG:-$TERMINAL_REQUIRE_END_TAG_DEFAULT}"
  SUPERVISE="${SUPERVISE:-0}"
  SUPERVISOR_FILE="${SUPERVISOR_FILE:-}"
  REFLECTION="${REFLECTION:-$REFLECTION_ENABLED}"
  validate_bool_flag "$REQUIRE_END_TAG" "REQUIRE_END_TAG"
  validate_bool_flag "$SUPERVISE" "SUPERVISE"
  validate_bool_flag "$REFLECTION" "REFLECTION"
}

save_job() {
  local jobdir="$1"
  local tmp="$jobdir/meta.env.tmp.$$.$RANDOM"
  cat >"$tmp" <<EOF
JOB_ID='$(escape_squotes "${JOB_ID:-}")'
JOB_NAME='$(escape_squotes "${JOB_NAME:-}")'
STATUS='$(escape_squotes "${STATUS:-active}")'
CWD='$(escape_squotes "${CWD:-}")'
INTERVAL_INPUT='$(escape_squotes "${INTERVAL_INPUT:-}")'
INTERVAL_SECONDS='$(escape_squotes "${INTERVAL_SECONDS:-0}")'
INTERVAL_LABEL='$(escape_squotes "${INTERVAL_LABEL:-}")'
CREATED_AT='$(escape_squotes "${CREATED_AT:-}")'
NEXT_RUN_EPOCH='$(escape_squotes "${NEXT_RUN_EPOCH:-0}")'
NEXT_RUN_AT='$(escape_squotes "${NEXT_RUN_AT:-}")'
SESSION_ID='$(escape_squotes "${SESSION_ID:-}")'
RUN_COUNT='$(escape_squotes "${RUN_COUNT:-0}")'
LAST_RUN_STARTED_AT='$(escape_squotes "${LAST_RUN_STARTED_AT:-}")'
LAST_RUN_FINISHED_AT='$(escape_squotes "${LAST_RUN_FINISHED_AT:-}")'
LAST_EXIT_CODE='$(escape_squotes "${LAST_EXIT_CODE:-}")'
PID='$(escape_squotes "${PID:-}")'
CURRENT_CHILD_PID='$(escape_squotes "${CURRENT_CHILD_PID:-}")'
MODE='$(escape_squotes "${MODE:-terminal}")'
TARGET_WINDOW_ID='$(escape_squotes "${TARGET_WINDOW_ID:-}")'
TARGET_TITLE_PATTERN='$(escape_squotes "${TARGET_TITLE_PATTERN:-}")'
TARGET_TTY='$(escape_squotes "${TARGET_TTY:-}")'
TARGET_TMUX_PANE='$(escape_squotes "${TARGET_TMUX_PANE:-}")'
SEND_DELAY='$(escape_squotes "${SEND_DELAY:-0}")'
REQUIRE_END_TAG='$(escape_squotes "${REQUIRE_END_TAG:-$TERMINAL_REQUIRE_END_TAG_DEFAULT}")'
SUPERVISE='$(escape_squotes "${SUPERVISE:-0}")'
SUPERVISOR_FILE='$(escape_squotes "${SUPERVISOR_FILE:-}")'
REFLECTION='$(escape_squotes "${REFLECTION:-$REFLECTION_ENABLED}")'
SCHEDULE_MODE='$(escape_squotes "${SCHEDULE_MODE:-fixed}")'
PROMPT_SOURCE='$(escape_squotes "${PROMPT_SOURCE:-inline}")'
MAX_RUNS='$(escape_squotes "${MAX_RUNS:-0}")'
LAST_NOTE='$(escape_squotes "${LAST_NOTE:-}")'
UPDATED_AT='$(escape_squotes "$(now_iso)")'
EOF
  mv "$tmp" "$jobdir/meta.env"
}

normalize_job_name() {
  local name
  name="$(trim "${1-}")"
  [[ -n "$name" ]] || die "job name cannot be empty"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "job name must match [A-Za-z0-9._-]+"
  printf '%s' "$name"
}

validate_mode() {
  local mode="$1"
  case "$mode" in
    terminal) ;;
    exec) die "exec mode is disabled; codex-loop only runs in the current Terminal session" ;;
    *) die "mode must be terminal: $mode" ;;
  esac
}

validate_non_negative_number() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$label must be a non-negative number: $value"
}

bool_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_bool_flag() {
  local value="${1:-0}"
  local label="$2"
  case "$value" in
    0|1|true|TRUE|false|FALSE|yes|YES|no|NO|on|ON|off|OFF) ;;
    *) die "$label must be boolean-like (0/1/true/false/on/off): $value" ;;
  esac
}

last_message_has_end_tag() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  awk '
    {
      line = tolower($0)
      while (match(line, /\[(start|end)[[:space:]][^][]+\]/)) {
        last = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END {
      exit (last ~ /^\[end[[:space:]]/) ? 0 : 1
    }
  ' "$file"
}

schedule_end_tag_retry() {
  local jobdir="$1"
  local note="$2"
  local seconds="${INTERVAL_SECONDS:-60}"
  if ! [[ "$seconds" =~ ^[0-9]+$ ]] || (( seconds < 60 )); then
    seconds=60
  fi
  NEXT_RUN_EPOCH=$(( $(now_epoch) + seconds ))
  NEXT_RUN_AT="$(epoch_to_local "$NEXT_RUN_EPOCH")"
  LAST_NOTE="$note; retry after ${seconds}s"
  save_job "$jobdir"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer: $value"
}

current_tty() {
  local tty_value
  tty_value="$(tty 2>/dev/null || true)"
  [[ "$tty_value" == /dev/ttys* || "$tty_value" == /dev/pts/* ]] || return 1
  printf '%s' "$tty_value"
}

current_tmux_pane() {
  local pane="${TMUX_PANE:-}"
  [[ -n "$pane" ]] || return 1
  tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || return 1
}

resolve_terminal_target() {
  local mode="$1"
  local window_id="$2"
  local title_pattern="$3"
  local target_tty="$4"
  local target_tmux_pane="$5"

  [[ "$mode" == "terminal" ]] || return 0
  local target_count=0
  [[ -z "$window_id" ]] || target_count=$((target_count + 1))
  [[ -z "$title_pattern" ]] || target_count=$((target_count + 1))
  [[ -z "$target_tty" ]] || target_count=$((target_count + 1))
  [[ -z "$target_tmux_pane" ]] || target_count=$((target_count + 1))
  (( target_count <= 1 )) || die "--window-id, --title-pattern, --tty, and --tmux-pane are mutually exclusive"
  [[ -x "$SEND_CURRENT_BIN" ]] || die "terminal mode requires sender: $SEND_CURRENT_BIN"

  if [[ -n "$target_tmux_pane" ]]; then
    tmux display-message -p -t "$target_tmux_pane" '#{pane_id}' >/dev/null || die "tmux pane not found: $target_tmux_pane"
  elif [[ -n "$target_tty" ]]; then
    "$SEND_CURRENT_BIN" --tty "$target_tty" --print-window-id placeholder
  elif [[ -z "$window_id" && -z "$title_pattern" ]]; then
    die "terminal loop defaults to the current session only; run codex-loop from the target tmux pane or live terminal tab, or pass an explicit override target"
  fi
}

plural_label() {
  local count="$1"
  local noun="$2"
  if [[ "$count" == "1" ]]; then
    printf 'every 1 %s' "$noun"
  else
    printf 'every %s %ss' "$count" "$noun"
  fi
}

format_interval_label() {
  local seconds="$1"
  if (( seconds % 86400 == 0 )); then
    plural_label "$((seconds / 86400))" "day"
  elif (( seconds % 3600 == 0 )); then
    plural_label "$((seconds / 3600))" "hour"
  else
    plural_label "$((seconds / 60))" "minute"
  fi
}

format_schedule_label() {
  local mode="$1"
  local seconds="$2"
  local base
  if [[ "$mode" == "asap" ]]; then
    printf 'asap; next immediately'
    return 0
  fi
  base="$(format_interval_label "$seconds")"
  if [[ "$mode" == "dynamic" ]]; then
    printf 'dynamic; next %s' "$base"
  else
    printf '%s' "$base"
  fi
}

read_loop_prompt_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    head -c 65536 "$file"
    return 0
  fi
  return 1
}

default_maintenance_prompt() {
  cat <<'EOF'
Review the current session and choose the best next maintenance action. Continue useful unfinished work, check for obvious blockers, keep changes durable, and stop before taking risky or destructive actions that need user approval.
EOF
}

resolve_default_prompt() {
  local cwd="${1:-$PWD}"
  if read_loop_prompt_file "$cwd/.claude/loop.md"; then
    return 0
  fi
  if read_loop_prompt_file "$HOME/.claude/loop.md"; then
    return 0
  fi
  default_maintenance_prompt
}

resolve_supervisor_file() {
  local cwd="${1:-$PWD}"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    if [[ "$explicit" != /* ]]; then
      explicit="$cwd/$explicit"
    fi
    [[ -f "$explicit" ]] || die "supervisor file not found: $explicit"
    printf '%s' "$explicit"
    return 0
  fi

  local candidate
  for candidate in \
    "$cwd/.codex/loop-supervisor.md" \
    "$cwd/.claude/SUPERVISOR.md" \
    "$cwd/SUPERVISOR.md" \
    "$HOME/.codex/loop-supervisor.md" \
    "$HOME/.claude/SUPERVISOR.md"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

append_supervisor_instruction() {
  local criteria_file="${SUPERVISOR_FILE:-}"

  cat <<'EOF'

Codex-loop supervised-run instruction:
This loop is running with CCC-inspired inline supervision. Treat the end of this turn like a stop-hook checkpoint: before your final answer, audit the work you just did against the loop objective, the user's latest request, repo instructions, and any supervisor criteria below.

Safety rules:
- Do not create, restart, cancel, or modify loop jobs from this supervised instruction unless the user explicitly asked for loop management.
- Do not recursively invoke `/loop`, `/audit`, `codex-loop`, or another supervisor from this instruction.
- Do not edit the loop skill, supervisor criteria, workflow docs, or other skills unless that is directly required by the loop objective and the change is narrow, verified, and reported.
- If the turn is blocked, unsafe, or incomplete, say so and choose the smallest concrete next action rather than claiming completion.

At the end of your final response, include these machine-readable lines:
LOOP_AUDIT_VERDICT=<PASS|FAIL|HOLD>
LOOP_AUDIT_REASON=<one short reason tied to evidence>
LOOP_AUDIT_NEXT=<the smallest useful next action or verification>
EOF

  if [[ -n "$criteria_file" && -f "$criteria_file" ]]; then
    cat <<EOF

Supervisor criteria from: $criteria_file
--- BEGIN SUPERVISOR CRITERIA ---
$(head -c 65536 "$criteria_file")
--- END SUPERVISOR CRITERIA ---
EOF
  else
    cat <<'EOF'

Default supervisor criteria:
- The requested work is actually completed or the blocker is explicit.
- Claims are backed by files, command results, tests, or concrete observations.
- No unrelated edits, destructive commands, or hidden background work were introduced.
- Any follow-up is specific and immediately actionable.
EOF
  fi
}

base_prompt_for_job() {
  local jobdir="$1"
  load_job "$jobdir"
  if [[ "${PROMPT_SOURCE:-inline}" == "default" ]]; then
    resolve_default_prompt "${CWD:-$PWD}"
  else
    cat "$jobdir/prompt.txt"
  fi
}

build_effective_prompt() {
  local jobdir="$1"
  local base
  base="$(base_prompt_for_job "$jobdir")"
  printf '%s\n' "$base"

  load_job "$jobdir"
  if [[ "${SCHEDULE_MODE:-fixed}" == "dynamic" ]]; then
    cat <<EOF

Codex-loop scheduling instruction:
At the end of your final response, include these two machine-readable lines:
CODEX_LOOP_NEXT_DELAY=<duration from 1m to 1h, for example 3m, 20m, or 1h>
CODEX_LOOP_NEXT_REASON=<one short reason for the chosen delay>
Choose the delay based on urgency, expected external latency, and how soon useful new work can be done.
EOF
  fi

  if [[ "${REFLECTION:-$REFLECTION_ENABLED}" != "0" ]]; then
    cat <<'EOF'

Codex-loop reflection instruction:
At the end of your final response, include this compact reflection section:
LOOP_REFLECTION_OBJECTIVE=<on-track or deviating; compare against the original loop objective and explain any drift in one short phrase>
LOOP_REFLECTION_TARGET=<what changed about the loop target or its state>
LOOP_REFLECTION_SELF=<one improvement or risk for this loop, target project, active skills, prompts, workflow docs, or repo instructions; write none if none>
LOOP_REFLECTION_PROMPT=<one concrete adjustment to a relevant prompt, skill, workflow doc, repo instruction, or this loop; write none if none>
LOOP_REFLECTION_NEXT=<the smallest useful next action or verification>
Self-improvement edits are allowed when the reflection identifies a concrete defect or high-confidence improvement in any relevant user/project skill, prompt, workflow doc, repo instruction, or this loop. Keep edits narrow and scope-relevant, avoid unrelated rewrites, verify the result, and commit changes when the target is a git repo.
EOF
  fi

  if bool_enabled "${SUPERVISE:-0}"; then
    append_supervisor_instruction
  fi
}

extract_keyed_line() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  awk -v key="$key" -F= '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      found=value
    }
    END {
      if (found != "") print found
    }
  ' "$file"
}

update_loop_state() {
  local jobdir="$1"
  local objective="$2"
  local target="$3"
  local self="$4"
  local prompt="$5"
  local next="$6"
  local tmp="$jobdir/state.md.tmp.$$.$RANDOM"
  local recent=""
  local recent_audit=""
  local reflection_enabled=1
  local key_decisions=""
  local relevant_files=""
  local recent_notes=""

  load_job "$jobdir"
  if [[ "${REFLECTION:-$REFLECTION_ENABLED}" == "0" ]]; then
    reflection_enabled=0
  fi

  if (( reflection_enabled )); then
    recent="$(tail -n 80 "$jobdir/reflection.log" 2>/dev/null || true)"
    key_decisions=$'- Runtime prompts include compact LOOP_REFLECTION_* lines.\n- This state file is regenerated from the latest reflection plus a short reflection log tail.'
    relevant_files=$'- prompt.txt\n- runtime_prompt.txt\n- audit.log\n- reflection.log\n- state.md\n- last_message.txt\n- run.log'
  fi
  recent_audit="$(tail -n 40 "$jobdir/audit.log" 2>/dev/null || true)"
  if (( ! reflection_enabled )); then
    key_decisions=$'- Reflection is disabled for this job.\n- This state file is regenerated from audit output and current job metadata only.'
    relevant_files=$'- prompt.txt\n- runtime_prompt.txt\n- audit.log\n- state.md\n- last_message.txt\n- run.log'
  fi
  if [[ -n "$recent" ]]; then
    recent_notes="$recent"
  elif (( ! reflection_enabled )) && [[ -n "$recent_audit" ]]; then
    recent_notes="$recent_audit"
  else
    recent_notes='none'
  fi

  {
    cat <<EOF
# Codex Loop State

Generated: $(now_iso)

## Goal
$(job_prompt_preview "$jobdir")

## Objective Drift Check
${objective:-not reported}

## Constraints & Preferences
- Job: ${JOB_ID:-}${JOB_NAME:+ (${JOB_NAME})}
- Working directory: ${CWD:-}
- Schedule: ${SCHEDULE_MODE:-fixed} / ${INTERVAL_INPUT:-}
- Mode: ${MODE:-terminal}
- Reflection: $([[ "$reflection_enabled" == "1" ]] && printf 'enabled' || printf 'disabled')

## Progress
### Latest Target State
${target:-none}

### Loop/Prompt Notes
${self:-none}

### Prompt Adjustment Candidate
${prompt:-none}

## Supervision
${recent_audit:-not enabled or not reported}

## Key Decisions
${key_decisions}

## Relevant Files
${relevant_files}

## Next Steps
${next:-none}

## Critical Context
- Run count: $(run_count_label)
- Last started: ${LAST_RUN_STARTED_AT:-}
- Last finished: ${LAST_RUN_FINISHED_AT:-}
- Last exit code: ${LAST_EXIT_CODE:-}
- Last note: ${LAST_NOTE:-}

## Recent Notes
EOF
    printf '%s\n' "$recent_notes"
  } >"$tmp"

  mv "$tmp" "$jobdir/state.md"
}

record_loop_audit() {
  local jobdir="$1"
  local message_file="$jobdir/last_message.txt"
  local verdict reason next
  bool_enabled "${SUPERVISE:-0}" || return 0
  verdict="$(extract_keyed_line "$message_file" "LOOP_AUDIT_VERDICT" || true)"
  reason="$(extract_keyed_line "$message_file" "LOOP_AUDIT_REASON" || true)"
  next="$(extract_keyed_line "$message_file" "LOOP_AUDIT_NEXT" || true)"
  [[ -n "$verdict$reason$next" ]] || return 0

  {
    printf '[%s] job=%s run=%s\n' "$(now_iso)" "${JOB_ID:-}" "${RUN_COUNT:-}"
    printf 'verdict=%s\n' "$verdict"
    printf 'reason=%s\n' "$reason"
    printf 'next=%s\n\n' "$next"
  } >>"$jobdir/audit.log"

  update_loop_state "$jobdir" "" "" "" "" "$next"
}

record_loop_reflection() {
  local jobdir="$1"
  local message_file="$jobdir/last_message.txt"
  local objective target self prompt next
  if [[ "${REFLECTION:-$REFLECTION_ENABLED}" == "0" ]]; then
    return 0
  fi
  objective="$(extract_keyed_line "$message_file" "LOOP_REFLECTION_OBJECTIVE" || true)"
  target="$(extract_keyed_line "$message_file" "LOOP_REFLECTION_TARGET" || true)"
  self="$(extract_keyed_line "$message_file" "LOOP_REFLECTION_SELF" || true)"
  prompt="$(extract_keyed_line "$message_file" "LOOP_REFLECTION_PROMPT" || true)"
  next="$(extract_keyed_line "$message_file" "LOOP_REFLECTION_NEXT" || true)"
  [[ -n "$objective$target$self$prompt$next" ]] || return 0

  {
    printf '[%s] job=%s run=%s\n' "$(now_iso)" "${JOB_ID:-}" "${RUN_COUNT:-}"
    printf 'objective=%s\n' "$objective"
    printf 'target=%s\n' "$target"
    printf 'self=%s\n' "$self"
    printf 'prompt=%s\n' "$prompt"
    printf 'next=%s\n\n' "$next"
  } >>"$jobdir/reflection.log"

  update_loop_state "$jobdir" "$objective" "$target" "$self" "$prompt" "$next"
}

parse_duration_to_seconds() {
  local spec
  spec="$(trim "${1-}")"
  local value unit
  local restore_nocasematch
  restore_nocasematch="$(shopt -p nocasematch || true)"
  shopt -s nocasematch
  if [[ "$spec" =~ ^([0-9]+)[[:space:]]*(s|sec|secs|second|seconds)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="s"
  elif [[ "$spec" =~ ^([0-9]+)[[:space:]]*(m|min|mins|minute|minutes)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="m"
  elif [[ "$spec" =~ ^([0-9]+)[[:space:]]*(h|hr|hrs|hour|hours)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="h"
  else
    eval "$restore_nocasematch" 2>/dev/null || shopt -u nocasematch
    return 1
  fi
  eval "$restore_nocasematch" 2>/dev/null || shopt -u nocasematch

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  case "$unit" in
    s) printf '%s' "$value" ;;
    m) printf '%s' "$((value * 60))" ;;
    h) printf '%s' "$((value * 3600))" ;;
    *) return 1 ;;
  esac
}

extract_dynamic_delay() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -F= '
    /^[[:space:]]*CODEX_LOOP_NEXT_DELAY[[:space:]]*=/ {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      found=value
    }
    END {
      if (found != "") print found
    }
  ' "$file"
}

extract_dynamic_reason() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -F= '
    /^[[:space:]]*CODEX_LOOP_NEXT_REASON[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      found=value
    }
    END {
      if (found != "") print found
    }
  ' "$file"
}

schedule_next_run() {
  local jobdir="$1"
  local rc="${2:-0}"
  local exit_note="${3:-}"

  # Caller owns the latest in-memory run fields; do not reload and discard them.
  [[ "${STATUS:-active}" == "active" ]] || return 0

  local seconds="${INTERVAL_SECONDS:-$DYNAMIC_INITIAL_SECONDS}"
  local note=""

  if [[ "${SCHEDULE_MODE:-fixed}" == "asap" ]]; then
    seconds=0
    note="asap schedule; next run immediately"
    INTERVAL_INPUT="asap"
    INTERVAL_SECONDS="0"
    INTERVAL_LABEL="$(format_schedule_label asap 0)"
  elif [[ "${SCHEDULE_MODE:-fixed}" == "dynamic" ]]; then
    local delay_spec delay_seconds reason
    delay_spec="$(extract_dynamic_delay "$jobdir/last_message.txt" || true)"
    delay_seconds="$(parse_duration_to_seconds "$delay_spec" 2>/dev/null || true)"
    if [[ -n "$delay_seconds" ]]; then
      if (( delay_seconds < DYNAMIC_MIN_SECONDS )); then
        delay_seconds="$DYNAMIC_MIN_SECONDS"
        note="dynamic delay '$delay_spec' clamped to 1m"
      elif (( delay_seconds > DYNAMIC_MAX_SECONDS )); then
        delay_seconds="$DYNAMIC_MAX_SECONDS"
        note="dynamic delay '$delay_spec' clamped to 1h"
      else
        note="dynamic delay selected: $delay_spec"
      fi
      seconds="$delay_seconds"
      reason="$(extract_dynamic_reason "$jobdir/last_message.txt" || true)"
      if [[ -n "$reason" ]]; then
        note="$note; reason: $(printf '%s' "$reason" | cut -c1-160)"
      fi
    else
      seconds="$DYNAMIC_INITIAL_SECONDS"
      note="dynamic delay missing or invalid; fallback to 10m"
    fi
    INTERVAL_INPUT="dynamic"
    INTERVAL_SECONDS="$seconds"
    INTERVAL_LABEL="$(format_schedule_label dynamic "$seconds")"
  fi

  NEXT_RUN_EPOCH=$(( $(now_epoch) + seconds ))
  NEXT_RUN_AT="$(epoch_to_local "$NEXT_RUN_EPOCH")"
  LAST_NOTE="$note"
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$LAST_NOTE" ]]; then
      LAST_NOTE="$LAST_NOTE; $exit_note"
    else
      LAST_NOTE="$exit_note"
    fi
  fi
  save_job "$jobdir"
}

parse_interval_spec() {
  local value="$1"
  local unit="$2"
  local normalized="${value}${unit}"
  local seconds=""
  local note=""

  [[ "$value" =~ ^[0-9]+$ ]] || die "invalid interval value: $value"
  (( value >= 1 )) || die "interval must be positive"

  case "$unit" in
    s)
      local minutes=$(((value + 59) / 60))
      (( minutes >= 1 )) || minutes=1
      normalized="${minutes}m"
      seconds=$((minutes * 60))
      if (( value != minutes * 60 )); then
        note="rounded ${value}s up to ${minutes}m"
      fi
      ;;
    m)
      seconds=$((value * 60))
      ;;
    h)
      seconds=$((value * 3600))
      ;;
    d)
      seconds=$((value * 86400))
      ;;
    *)
      die "unsupported interval unit: $unit"
      ;;
  esac

  printf '%s\t%s\t%s\t%s\n' "$normalized" "$seconds" "$(format_interval_label "$seconds")" "$note"
}

parse_loop_input() {
  local raw
  raw="$(trim "${1-}")"

  local value=""
  local unit=""
  local prompt=""
  local note=""
  local schedule_mode="fixed"
  local prompt_source="inline"
  local restore_nocasematch=""
  local word=""

  restore_nocasematch="$(shopt -p nocasematch || true)"
  shopt -s nocasematch
  if [[ -z "$raw" ]]; then
    value="10"
    unit="m"
    prompt="$DEFAULT_PROMPT_SENTINEL"
    schedule_mode="dynamic"
    prompt_source="default"
    note="using default maintenance prompt; dynamic interval starts at 10m"
  elif [[ "$raw" =~ ^(asap|immediately|立即|马上)$ ]]; then
    prompt="$DEFAULT_PROMPT_SENTINEL"
    schedule_mode="asap"
    prompt_source="default"
    note="using default maintenance prompt; asap schedule"
  elif [[ "$raw" =~ ^(asap|immediately)[[:space:]]+(.+)$ ]]; then
    prompt="${BASH_REMATCH[2]}"
    schedule_mode="asap"
    note="asap schedule"
  elif [[ "$raw" =~ ^(立即|马上)[[:space:]]*(.+)$ ]]; then
    prompt="${BASH_REMATCH[2]}"
    schedule_mode="asap"
    note="asap schedule"
  elif [[ "$raw" =~ ^(.+)[[:space:]]+(asap|immediately|立即|马上)$ ]]; then
    prompt="${BASH_REMATCH[1]}"
    schedule_mode="asap"
    note="asap schedule"
  elif [[ "$raw" =~ ^([0-9]+)([smhd])$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    prompt="$DEFAULT_PROMPT_SENTINEL"
    prompt_source="default"
    note="using default maintenance prompt"
  elif [[ "$raw" =~ ^([0-9]+)([smhd])[[:space:]]+(.+)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    prompt="${BASH_REMATCH[3]}"
  elif [[ "$raw" =~ ^每[[:space:]]*([0-9]+)[[:space:]]*(秒|分钟|小时|天)$ ]]; then
    value="${BASH_REMATCH[1]}"
    word="${BASH_REMATCH[2]}"
    prompt="$DEFAULT_PROMPT_SENTINEL"
    prompt_source="default"
    note="using default maintenance prompt"
    case "$word" in
      秒) unit="s" ;;
      分钟) unit="m" ;;
      小时) unit="h" ;;
      天) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  elif [[ "$raw" =~ ^每[[:space:]]*([0-9]+)[[:space:]]*(秒|分钟|小时|天)[[:space:]]*(.+)$ ]]; then
    value="${BASH_REMATCH[1]}"
    word="${BASH_REMATCH[2]}"
    prompt="${BASH_REMATCH[3]}"
    case "$word" in
      秒) unit="s" ;;
      分钟) unit="m" ;;
      小时) unit="h" ;;
      天) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  elif [[ "$raw" =~ ^每[[:space:]]*(秒|分钟|小时|天)$ ]]; then
    value="1"
    word="${BASH_REMATCH[1]}"
    prompt="$DEFAULT_PROMPT_SENTINEL"
    prompt_source="default"
    note="using default maintenance prompt"
    case "$word" in
      秒) unit="s" ;;
      分钟) unit="m" ;;
      小时) unit="h" ;;
      天) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  elif [[ "$raw" =~ ^每[[:space:]]*(秒|分钟|小时|天)[[:space:]]*(.+)$ ]]; then
    value="1"
    word="${BASH_REMATCH[1]}"
    prompt="${BASH_REMATCH[2]}"
    case "$word" in
      秒) unit="s" ;;
      分钟) unit="m" ;;
      小时) unit="h" ;;
      天) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  elif [[ "$raw" =~ ^every[[:space:]]+([0-9]+)[[:space:]]*([smhd])$ ]]; then
    prompt="$DEFAULT_PROMPT_SENTINEL"
    prompt_source="default"
    note="using default maintenance prompt"
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
  elif [[ "$raw" =~ ^every[[:space:]]+([0-9]+)[[:space:]]+(second|seconds|minute|minutes|hour|hours|day|days)$ ]]; then
    prompt="$DEFAULT_PROMPT_SENTINEL"
    prompt_source="default"
    note="using default maintenance prompt"
    value="${BASH_REMATCH[1]}"
    word="${BASH_REMATCH[2],,}"
    case "$word" in
      second|seconds) unit="s" ;;
      minute|minutes) unit="m" ;;
      hour|hours) unit="h" ;;
      day|days) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  elif [[ "$raw" =~ ^(.+)[[:space:]]+every[[:space:]]+([0-9]+)[[:space:]]*([smhd])$ ]]; then
    prompt="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    unit="${BASH_REMATCH[3],,}"
  elif [[ "$raw" =~ ^(.+)[[:space:]]+every[[:space:]]+([0-9]+)[[:space:]]+(second|seconds|minute|minutes|hour|hours|day|days)$ ]]; then
    prompt="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    word="${BASH_REMATCH[3],,}"
    case "$word" in
      second|seconds) unit="s" ;;
      minute|minutes) unit="m" ;;
      hour|hours) unit="h" ;;
      day|days) unit="d" ;;
      *) die "unsupported interval word: $word" ;;
    esac
  else
    value="10"
    unit="m"
    prompt="$raw"
    schedule_mode="dynamic"
    note="dynamic interval starts at 10m"
  fi
  eval "$restore_nocasematch" 2>/dev/null || shopt -u nocasematch

  prompt="$(trim "$prompt")"
  [[ -n "$prompt" ]] || die "usage: /loop [interval] <prompt>"

  local parsed interval_input interval_seconds interval_label interval_note
  if [[ "$schedule_mode" == "asap" ]]; then
    interval_input="asap"
    interval_seconds="0"
    interval_label="$(format_schedule_label asap 0)"
    interval_note=""
  else
    parsed="$(parse_interval_spec "$value" "$unit")"
    IFS=$'\t' read -r interval_input interval_seconds interval_label interval_note <<<"$parsed"
  fi
  if [[ "$schedule_mode" == "dynamic" ]]; then
    interval_input="dynamic"
    interval_seconds="$DYNAMIC_INITIAL_SECONDS"
    interval_label="$(format_schedule_label dynamic "$interval_seconds")"
  fi

  if [[ -n "$note" && -n "$interval_note" ]]; then
    note="$note; $interval_note"
  elif [[ -z "$note" ]]; then
    note="$interval_note"
  fi

  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$interval_input" \
    "$FIELD_SEP" \
    "$interval_seconds" \
    "$FIELD_SEP" \
    "$interval_label" \
    "$FIELD_SEP" \
    "$prompt" \
    "$FIELD_SEP" \
    "$note" \
    "$FIELD_SEP" \
    "$schedule_mode" \
    "$FIELD_SEP" \
    "$prompt_source"
}

job_prompt_preview() {
  local jobdir="$1"
  [[ -f "$jobdir/prompt.txt" ]] || return 0
  base_prompt_for_job "$jobdir" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-120
}

last_message_preview() {
  local file="$1"
  if [[ -f "$file" ]]; then
    tr '\n' ' ' <"$file" | sed 's/[[:space:]]\+/ /g' | cut -c1-160
  fi
}

run_count_label() {
  if [[ "${MAX_RUNS:-0}" != "0" ]]; then
    printf '%s/%s' "${RUN_COUNT:-0}" "${MAX_RUNS:-0}"
  else
    printf '%s' "${RUN_COUNT:-0}"
  fi
}

job_display_status() {
  local jobdir="$1"
  load_job "$jobdir"
  if [[ "${STATUS:-}" == "active" ]]; then
    if pid_alive "${CURRENT_CHILD_PID:-}"; then
      printf 'running'
    elif pid_alive "${PID:-}"; then
      printf 'scheduled'
    else
      printf 'stopped'
    fi
  else
    printf '%s' "${STATUS:-unknown}"
  fi
}

assert_job_exists() {
  local id="$1"
  local jobdir
  jobdir="$(resolve_jobdir "$id")"
  printf '%s' "$jobdir"
}

acquire_run_lock() {
  local jobdir="$1"
  local lockdir="$jobdir/run.lock"
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lockdir/pid"
    return 0
  fi

  local holder=""
  if [[ -f "$lockdir/pid" ]]; then
    holder="$(cat "$lockdir/pid" 2>/dev/null || true)"
  fi

  if ! pid_alive "$holder"; then
    rm -rf "$lockdir"
    mkdir "$lockdir"
    printf '%s\n' "$$" >"$lockdir/pid"
    return 0
  fi

  return 1
}

release_run_lock() {
  local jobdir="$1"
  rm -rf "$jobdir/run.lock" 2>/dev/null || true
}

start_worker() {
  local jobdir="$1"
  load_job "$jobdir"
  local worker_log="$jobdir/worker.log"
  local worker_pid=""

  if pid_alive "${PID:-}"; then
    printf '%s\n' "$PID"
    return 0
  fi

  STATUS="active"
  save_job "$jobdir"

  if command -v python3 >/dev/null 2>&1; then
    worker_pid="$(
      python3 - "$0" "$JOB_ID" "$worker_log" <<'PY'
import subprocess
import sys

script_path, job_id, worker_log = sys.argv[1:]
with open(worker_log, "ab", buffering=0) as log:
    proc = subprocess.Popen(
        [script_path, "worker", job_id],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
print(proc.pid)
PY
    )"
  else
    nohup "$0" worker "$JOB_ID" >>"$worker_log" 2>&1 </dev/null &
    worker_pid="$!"
  fi

  PID="$worker_pid"
  CURRENT_CHILD_PID=""
  save_job "$jobdir"

  printf '%s\n' "$PID"
}

wait_until_due() {
  local jobdir="$1"
  while true; do
    load_job "$jobdir"
    [[ "${STATUS:-}" == "active" ]] || return 1

    local now
    now="$(now_epoch)"
    if (( NEXT_RUN_EPOCH <= now )); then
      return 0
    fi

    local sleep_for=$((NEXT_RUN_EPOCH - now))
    if (( sleep_for > 60 )); then
      sleep_for=60
    elif (( sleep_for < 1 )); then
      sleep_for=1
    fi

    sleep "$sleep_for"
  done
}

run_job_once() {
  local jobdir="$1"
  acquire_run_lock "$jobdir" || return 0
  trap "release_run_lock '$jobdir'; trap - RETURN" RETURN

  load_job "$jobdir"

  local prompt_file="$jobdir/runtime_prompt.txt"
  local json_file="$jobdir/last_run.jsonl"
  local last_message_file="$jobdir/last_message.txt"
  local stderr_file="$jobdir/stderr.log"
  local started_at prompt_preview child_pid rc
  local mode="${MODE:-terminal}"
  build_effective_prompt "$jobdir" >"$prompt_file"

  if [[ "$mode" == "terminal" ]]; then
    local -a target_cmd=("$SEND_CURRENT_BIN" --idle-timeout "$TERMINAL_IDLE_TIMEOUT")
    local -a send_cmd=()
    local capture_terminal_output=0

    [[ -x "$SEND_CURRENT_BIN" ]] || die "terminal mode requires sender: $SEND_CURRENT_BIN"

    if [[ -n "${TARGET_TMUX_PANE:-}" ]]; then
      target_cmd+=(--tmux-pane "$TARGET_TMUX_PANE")
    elif [[ -n "${TARGET_WINDOW_ID:-}" ]]; then
      target_cmd+=(--window-id "$TARGET_WINDOW_ID")
    elif [[ -n "${TARGET_TITLE_PATTERN:-}" ]]; then
      target_cmd+=(--title-pattern "$TARGET_TITLE_PATTERN")
    fi
    if [[ -n "${TARGET_TTY:-}" ]]; then
      target_cmd+=(--tty "$TARGET_TTY")
    fi
    send_cmd=("${target_cmd[@]}" --delay "${SEND_DELAY:-0}" --stdin)
    if [[ "${SCHEDULE_MODE:-fixed}" == "dynamic" ]]; then
      send_cmd+=(--wait-for-idle)
      capture_terminal_output=1
    elif [[ "${SCHEDULE_MODE:-fixed}" == "asap" ]]; then
      # ASAP means "send as soon as the current Codex turn is idle", not
      # "append to whatever is currently being typed or processed".
      send_cmd+=(--wait-for-idle)
      capture_terminal_output=1
    elif [[ "${REFLECTION:-$REFLECTION_ENABLED}" != "0" ]]; then
      capture_terminal_output=1
    fi
    if bool_enabled "${REQUIRE_END_TAG:-0}"; then
      capture_terminal_output=1
    fi
    if (( capture_terminal_output )) && [[ "${SCHEDULE_MODE:-fixed}" == "fixed" ]]; then
      # Fixed terminal loops with reflection still need the same pre-send idle
      # gate as dynamic/asap loops. Without this, the prompt can be pasted into
      # an active TUI turn, and post-send detection becomes unreliable.
      send_cmd+=(--wait-for-idle)
    fi

    started_at="$(now_iso)"
    LAST_RUN_STARTED_AT="$started_at"
    LAST_RUN_FINISHED_AT=""
    LAST_EXIT_CODE=""
    CURRENT_CHILD_PID=""
    save_job "$jobdir"

    prompt_preview="$(job_prompt_preview "$jobdir")"
    echo "[$started_at] start mode=terminal interval=$INTERVAL_INPUT target_tmux_pane=${TARGET_TMUX_PANE:-} target_window=${TARGET_WINDOW_ID:-} target_title=${TARGET_TITLE_PATTERN:-} target_tty=${TARGET_TTY:-} prompt=$prompt_preview" >>"$jobdir/run.log"

    if bool_enabled "${REQUIRE_END_TAG:-0}" && [[ "${RUN_COUNT:-0}" != "0" ]]; then
      local gate_rc gate_note
      set +e
      "${target_cmd[@]}" --idle-timeout "$TERMINAL_IDLE_TIMEOUT" --wait-idle-only --print-contents >"$last_message_file" 2>>"$stderr_file"
      gate_rc="$?"
      set -e
      if [[ "$gate_rc" -ne 0 ]]; then
        rc="$gate_rc"
        LAST_RUN_FINISHED_AT="$(now_iso)"
        LAST_EXIT_CODE="$rc"
        gate_note="waiting for target idle before [end xxx] gate"
        schedule_end_tag_retry "$jobdir" "$gate_note"
        echo "[$LAST_RUN_FINISHED_AT] skip rc=$rc next=$NEXT_RUN_AT message=$gate_note" >>"$jobdir/run.log"
        return 0
      fi
      if ! last_message_has_end_tag "$last_message_file"; then
        rc="75"
        LAST_RUN_FINISHED_AT="$(now_iso)"
        LAST_EXIT_CODE="$rc"
        gate_note="waiting for latest session [end xxx] tag before sending next loop cycle"
        schedule_end_tag_retry "$jobdir" "$gate_note"
        echo "[$LAST_RUN_FINISHED_AT] skip rc=$rc next=$NEXT_RUN_AT message=$gate_note" >>"$jobdir/run.log"
        return 0
      fi
    fi

    : >"$json_file"
    : >"$last_message_file"

    set +e
    (
      cd "$CWD" &&
      "${send_cmd[@]}" <"$prompt_file"
    ) >"$json_file" 2>>"$stderr_file" &
    child_pid="$!"
    CURRENT_CHILD_PID="$child_pid"
    save_job "$jobdir"

    wait "$child_pid"
    rc="$?"
    set -e

    load_job "$jobdir"
    CURRENT_CHILD_PID=""
    RUN_COUNT=$((RUN_COUNT + 1))
    LAST_RUN_FINISHED_AT="$(now_iso)"
    LAST_EXIT_CODE="$rc"

    if [[ "$rc" -eq 0 ]]; then
      if [[ "${SCHEDULE_MODE:-fixed}" == "asap" ]]; then
        sleep "$TERMINAL_AFTER_SEND_DELAY"
        set +e
        "${target_cmd[@]}" --idle-timeout "$TERMINAL_ASAP_TURN_TIMEOUT" --wait-idle-only --require-busy-first --print-contents >"$last_message_file" 2>>"$stderr_file"
        rc="$?"
        set -e
        LAST_EXIT_CODE="$rc"
        LAST_RUN_FINISHED_AT="$(now_iso)"
        if [[ "$rc" -ne 0 ]]; then
          printf 'terminal wait-for-idle after asap send failed rc=%s\n' "$rc" >"$last_message_file"
        fi
      elif (( capture_terminal_output )); then
        sleep "$TERMINAL_AFTER_SEND_DELAY"
        set +e
        "${target_cmd[@]}" --idle-timeout "$TERMINAL_TURN_TIMEOUT" --wait-idle-only --print-contents >"$last_message_file" 2>>"$stderr_file"
        rc="$?"
        set -e
        LAST_EXIT_CODE="$rc"
        LAST_RUN_FINISHED_AT="$(now_iso)"
        if [[ "$rc" -ne 0 ]]; then
          printf 'terminal wait-for-idle failed rc=%s\n' "$rc" >"$last_message_file"
        fi
      else
        printf 'sent prompt to terminal target window=%s title=%s tty=%s\n' "${TARGET_WINDOW_ID:-}" "${TARGET_TITLE_PATTERN:-}" "${TARGET_TTY:-}" >"$last_message_file"
      fi
    else
      printf 'terminal send failed rc=%s\n' "$rc" >"$last_message_file"
    fi

    record_loop_audit "$jobdir"
    record_loop_reflection "$jobdir"

    if [[ "${STATUS:-active}" == "active" && "${MAX_RUNS:-0}" != "0" && "${RUN_COUNT:-0}" -ge "${MAX_RUNS:-0}" ]]; then
      STATUS="completed"
      NEXT_RUN_EPOCH="0"
      NEXT_RUN_AT=""
      LAST_NOTE="completed after $(run_count_label) runs"
      save_job "$jobdir"
    elif [[ "${STATUS:-active}" == "active" && "$rc" -ne 0 && ( "${SCHEDULE_MODE:-fixed}" == "dynamic" || "${SCHEDULE_MODE:-fixed}" == "asap" ) ]]; then
      STATUS="paused"
      NEXT_RUN_EPOCH="0"
      NEXT_RUN_AT=""
      LAST_NOTE="paused after terminal send because Codex idle/turn completion was not observed"
      save_job "$jobdir"
    elif [[ "${STATUS:-active}" == "active" ]]; then
      schedule_next_run "$jobdir" "$rc" "terminal loop exited with status $rc"
    elif [[ -z "${LAST_NOTE:-}" && "$rc" -ne 0 ]]; then
      LAST_NOTE="terminal loop exited with status $rc"
    fi

    load_job "$jobdir"
    echo "[$LAST_RUN_FINISHED_AT] finish rc=$rc next=$NEXT_RUN_AT message=$(last_message_preview "$last_message_file")" >>"$jobdir/run.log"
    return 0
  fi

  started_at="$(now_iso)"
  LAST_RUN_STARTED_AT="$started_at"
  LAST_RUN_FINISHED_AT="$(now_iso)"
  LAST_EXIT_CODE="2"
  CURRENT_CHILD_PID=""
  STATUS="canceled"
  NEXT_RUN_EPOCH="0"
  NEXT_RUN_AT=""
  LAST_NOTE="unsupported mode '$mode'; loop only runs in the current Terminal session"
  printf "unsupported mode '%s'; loop only runs in the current Terminal session\n" "$mode" >"$last_message_file"
  echo "[$started_at] blocked mode=$mode prompt=$(job_prompt_preview "$jobdir")" >>"$jobdir/run.log"
  save_job "$jobdir"
  return 0
}

worker_cleanup() {
  local jobdir="$1"
  if [[ -f "$jobdir/meta.env" ]]; then
    load_job "$jobdir" || return 0
    if [[ "${PID:-}" == "$$" ]]; then
      PID=""
      CURRENT_CHILD_PID=""
      save_job "$jobdir"
    fi
  fi
}

worker_loop() {
  local id="$1"
  local jobdir
  jobdir="$(assert_job_exists "$id")"

  load_job "$jobdir"
  PID="$$"
  save_job "$jobdir"

  trap 'worker_cleanup "$jobdir"' EXIT
  trap 'worker_cleanup "$jobdir"; exit 0' INT TERM

  while true; do
    wait_until_due "$jobdir" || exit 0
    run_job_once "$jobdir"
  done
}

create_job() {
  ensure_dirs

  local cwd="$PWD"
  local start_now=0
  local job_name=""
  local mode="$DEFAULT_MODE"
  local target_window_id=""
  local target_title_pattern=""
  local target_tty=""
  local target_tmux_pane=""
  local send_delay="0"
  local max_runs="0"
  local require_end_tag="$TERMINAL_REQUIRE_END_TAG_DEFAULT"
  local supervise="0"
  local supervisor_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        job_name="$(normalize_job_name "$2")"
        shift 2
        ;;
      --cwd)
        [[ $# -ge 2 ]] || die "--cwd requires a path"
        cwd="$2"
        shift 2
        ;;
      --start-now)
        start_now=1
        shift
        ;;
      --count|--max-runs)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        validate_positive_integer "$2" "$1"
        max_runs="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        mode="$2"
        validate_mode "$mode"
        shift 2
        ;;
      --terminal|--current-terminal)
        mode="terminal"
        shift
        ;;
      --window-id)
        [[ $# -ge 2 ]] || die "--window-id requires a value"
        mode="terminal"
        target_window_id="$2"
        shift 2
        ;;
      --title-pattern)
        [[ $# -ge 2 ]] || die "--title-pattern requires a value"
        mode="terminal"
        target_title_pattern="$2"
        shift 2
        ;;
      --tty)
        [[ $# -ge 2 ]] || die "--tty requires a value"
        mode="terminal"
        target_tty="$2"
        shift 2
        ;;
      --tmux-pane)
        [[ $# -ge 2 ]] || die "--tmux-pane requires a value"
        mode="terminal"
        target_tmux_pane="$2"
        shift 2
        ;;
      --send-delay)
        [[ $# -ge 2 ]] || die "--send-delay requires a value"
        send_delay="$2"
        validate_non_negative_number "$send_delay" "--send-delay"
        shift 2
        ;;
      --require-end-tag)
        require_end_tag="1"
        shift
        ;;
      --no-require-end-tag)
        require_end_tag="0"
        shift
        ;;
      --supervise|--audit|--self-audit)
        supervise="1"
        shift
        ;;
      --no-supervise|--no-audit)
        supervise="0"
        shift
        ;;
      --supervisor-file)
        [[ $# -ge 2 ]] || die "--supervisor-file requires a value"
        supervise="1"
        supervisor_file="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  local raw_input="$*"
  [[ -d "$cwd" ]] || die "working directory not found: $cwd"
  validate_mode "$mode"
  validate_non_negative_number "$send_delay" "--send-delay"
  validate_bool_flag "$require_end_tag" "--require-end-tag"
  validate_bool_flag "$supervise" "--supervise"
  if [[ "$mode" == "terminal" && -z "$target_window_id" && -z "$target_title_pattern" && -z "$target_tty" && -z "$target_tmux_pane" ]]; then
    target_tmux_pane="$(current_tmux_pane || true)"
    if [[ -z "$target_tmux_pane" ]]; then
      target_tty="$(current_tty)" || die "terminal loop defaults to the current session only; run codex-loop from the target tmux pane or live terminal tab, or pass --tmux-pane/--tty/--window-id/--title-pattern explicitly. Chat/API calls have no implicit current terminal."
    fi
  fi
  target_window_id="${target_window_id:-$(resolve_terminal_target "$mode" "$target_window_id" "$target_title_pattern" "$target_tty" "$target_tmux_pane")}"
  if bool_enabled "$supervise"; then
    if [[ -n "$supervisor_file" ]]; then
      supervisor_file="$(resolve_supervisor_file "$(cd "$cwd" && pwd)" "$supervisor_file")"
    else
      supervisor_file="$(resolve_supervisor_file "$(cd "$cwd" && pwd)" "" 2>/dev/null || true)"
    fi
  else
    supervisor_file=""
  fi

  local parsed interval_input interval_seconds interval_label prompt note schedule_mode prompt_source
  parsed="$(parse_loop_input "$raw_input")"
  IFS="$FIELD_SEP" read -r interval_input interval_seconds interval_label prompt note schedule_mode prompt_source <<<"$parsed"

  local job_id jobdir
  while true; do
    job_id="$(generate_job_id)"
    jobdir="$(job_dir "$job_id")"
    [[ ! -e "$jobdir" ]] && break
  done

  mkdir -p "$jobdir"
  printf '%s\n' "$prompt" >"$jobdir/prompt.txt"
  : >"$jobdir/run.log"
  : >"$jobdir/stderr.log"
  : >"$jobdir/last_message.txt"
  : >"$jobdir/last_run.jsonl"
  : >"$jobdir/runtime_prompt.txt"
  : >"$jobdir/audit.log"
  : >"$jobdir/reflection.log"
  : >"$jobdir/state.md"
  : >"$jobdir/worker.log"

  JOB_ID="$job_id"
  JOB_NAME="$job_name"
  STATUS="active"
  CWD="$(cd "$cwd" && pwd)"
  INTERVAL_INPUT="$interval_input"
  INTERVAL_SECONDS="$interval_seconds"
  INTERVAL_LABEL="$interval_label"
  CREATED_AT="$(now_iso)"
  NEXT_RUN_EPOCH=$(( $(now_epoch) + INTERVAL_SECONDS ))
  if (( start_now )); then
    NEXT_RUN_EPOCH="$(now_epoch)"
  fi
  NEXT_RUN_AT="$(epoch_to_local "$NEXT_RUN_EPOCH")"
  SESSION_ID=""
  RUN_COUNT="0"
  MAX_RUNS="$max_runs"
  LAST_RUN_STARTED_AT=""
  LAST_RUN_FINISHED_AT=""
  LAST_EXIT_CODE=""
  PID=""
  CURRENT_CHILD_PID=""
  MODE="$mode"
  TARGET_WINDOW_ID="$target_window_id"
  TARGET_TITLE_PATTERN="$target_title_pattern"
  TARGET_TTY="$target_tty"
  TARGET_TMUX_PANE="$target_tmux_pane"
  SEND_DELAY="$send_delay"
  REQUIRE_END_TAG="$require_end_tag"
  SUPERVISE="$supervise"
  SUPERVISOR_FILE="$supervisor_file"
  REFLECTION="$REFLECTION_ENABLED"
  SCHEDULE_MODE="$schedule_mode"
  PROMPT_SOURCE="$prompt_source"
  LAST_NOTE="$note"
  save_job "$jobdir"

  start_worker "$jobdir" >/dev/null
  load_job "$jobdir"

  cat <<EOF
Created loop job $JOB_ID
Name: ${JOB_NAME:-}
Status: $(job_display_status "$jobdir")
Interval: $INTERVAL_LABEL ($INTERVAL_INPUT)
Schedule mode: ${SCHEDULE_MODE:-fixed}
Prompt source: ${PROMPT_SOURCE:-inline}
Run limit: ${MAX_RUNS:-0}
Next run: $NEXT_RUN_AT
Working directory: $CWD
Mode: ${MODE:-terminal}
Terminal target: tmux_pane=${TARGET_TMUX_PANE:-} window=${TARGET_WINDOW_ID:-} title=${TARGET_TITLE_PATTERN:-} tty=${TARGET_TTY:-}
Require end tag: ${REQUIRE_END_TAG:-0}
Supervise: ${SUPERVISE:-0}${SUPERVISOR_FILE:+ ($SUPERVISOR_FILE)}
Session id: ${SESSION_ID:-pending}
Prompt: $(job_prompt_preview "$jobdir")
EOF
  if [[ -n "$note" ]]; then
    echo "Note: $note"
  fi
  echo "Use: codex-loop list | codex-loop show $JOB_ID | codex-loop cancel $JOB_ID"
}

ensure_job() {
  ensure_dirs

  local cwd="$PWD"
  local start_now=0
  local job_name=""
  local mode="$DEFAULT_MODE"
  local target_window_id=""
  local target_title_pattern=""
  local target_tty=""
  local target_tmux_pane=""
  local send_delay="0"
  local max_runs="0"
  local require_end_tag="$TERMINAL_REQUIRE_END_TAG_DEFAULT"
  local supervise="0"
  local supervisor_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        job_name="$(normalize_job_name "$2")"
        shift 2
        ;;
      --cwd)
        [[ $# -ge 2 ]] || die "--cwd requires a path"
        cwd="$2"
        shift 2
        ;;
      --start-now)
        start_now=1
        shift
        ;;
      --count|--max-runs)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        validate_positive_integer "$2" "$1"
        max_runs="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        mode="$2"
        validate_mode "$mode"
        shift 2
        ;;
      --terminal|--current-terminal)
        mode="terminal"
        shift
        ;;
      --window-id)
        [[ $# -ge 2 ]] || die "--window-id requires a value"
        mode="terminal"
        target_window_id="$2"
        shift 2
        ;;
      --title-pattern)
        [[ $# -ge 2 ]] || die "--title-pattern requires a value"
        mode="terminal"
        target_title_pattern="$2"
        shift 2
        ;;
      --tty)
        [[ $# -ge 2 ]] || die "--tty requires a value"
        mode="terminal"
        target_tty="$2"
        shift 2
        ;;
      --tmux-pane)
        [[ $# -ge 2 ]] || die "--tmux-pane requires a value"
        mode="terminal"
        target_tmux_pane="$2"
        shift 2
        ;;
      --send-delay)
        [[ $# -ge 2 ]] || die "--send-delay requires a value"
        send_delay="$2"
        validate_non_negative_number "$send_delay" "--send-delay"
        shift 2
        ;;
      --require-end-tag)
        require_end_tag="1"
        shift
        ;;
      --no-require-end-tag)
        require_end_tag="0"
        shift
        ;;
      --supervise|--audit|--self-audit)
        supervise="1"
        shift
        ;;
      --no-supervise|--no-audit)
        supervise="0"
        shift
        ;;
      --supervisor-file)
        [[ $# -ge 2 ]] || die "--supervisor-file requires a value"
        supervise="1"
        supervisor_file="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  [[ -n "$job_name" ]] || die "usage: codex-loop ensure --name JOB_NAME [--cwd PATH] [--start-now] [--mode terminal] -- \"<loop prompt>\""

  local raw_input="$*"
  [[ -d "$cwd" ]] || die "working directory not found: $cwd"
  cwd="$(cd "$cwd" && pwd)"
  validate_mode "$mode"
  validate_non_negative_number "$send_delay" "--send-delay"
  validate_bool_flag "$require_end_tag" "--require-end-tag"
  validate_bool_flag "$supervise" "--supervise"
  if [[ "$mode" == "terminal" && -z "$target_window_id" && -z "$target_title_pattern" && -z "$target_tty" && -z "$target_tmux_pane" ]]; then
    target_tmux_pane="$(current_tmux_pane || true)"
    if [[ -z "$target_tmux_pane" ]]; then
      target_tty="$(current_tty)" || die "terminal loop defaults to the current session only; run codex-loop from the target tmux pane or live terminal tab, or pass --tmux-pane/--tty/--window-id/--title-pattern explicitly. Chat/API calls have no implicit current terminal."
    fi
  fi
  target_window_id="${target_window_id:-$(resolve_terminal_target "$mode" "$target_window_id" "$target_title_pattern" "$target_tty" "$target_tmux_pane")}"
  if bool_enabled "$supervise"; then
    if [[ -n "$supervisor_file" ]]; then
      supervisor_file="$(resolve_supervisor_file "$cwd" "$supervisor_file")"
    else
      supervisor_file="$(resolve_supervisor_file "$cwd" "" 2>/dev/null || true)"
    fi
  else
    supervisor_file=""
  fi

  local parsed interval_input interval_seconds interval_label prompt note schedule_mode prompt_source
  parsed="$(parse_loop_input "$raw_input")"
  IFS="$FIELD_SEP" read -r interval_input interval_seconds interval_label prompt note schedule_mode prompt_source <<<"$parsed"

  local selected=""
  local selected_prompt=""
  local spec_changed=0

  if selected="$(resolve_jobdir "$job_name" 2>/dev/null)"; then
    load_job "$selected"
    selected_prompt="$(cat "$selected/prompt.txt" 2>/dev/null || true)"
    if [[ "$CWD" != "$cwd" || "$INTERVAL_INPUT" != "$interval_input" || "$selected_prompt" != "$prompt" || "${SCHEDULE_MODE:-fixed}" != "$schedule_mode" || "${PROMPT_SOURCE:-inline}" != "$prompt_source" || "${MODE:-terminal}" != "$mode" || "${TARGET_WINDOW_ID:-}" != "$target_window_id" || "${TARGET_TITLE_PATTERN:-}" != "$target_title_pattern" || "${TARGET_TTY:-}" != "$target_tty" || "${TARGET_TMUX_PANE:-}" != "$target_tmux_pane" || "${SEND_DELAY:-0}" != "$send_delay" || "${REQUIRE_END_TAG:-$TERMINAL_REQUIRE_END_TAG_DEFAULT}" != "$require_end_tag" || "${SUPERVISE:-0}" != "$supervise" || "${SUPERVISOR_FILE:-}" != "$supervisor_file" || "${MAX_RUNS:-0}" != "$max_runs" ]]; then
      spec_changed=1
    fi

    JOB_NAME="$job_name"
    CWD="$cwd"
    INTERVAL_INPUT="$interval_input"
    INTERVAL_SECONDS="$interval_seconds"
    INTERVAL_LABEL="$interval_label"
    MODE="$mode"
    TARGET_WINDOW_ID="$target_window_id"
    TARGET_TITLE_PATTERN="$target_title_pattern"
    TARGET_TTY="$target_tty"
    TARGET_TMUX_PANE="$target_tmux_pane"
    SEND_DELAY="$send_delay"
    REQUIRE_END_TAG="$require_end_tag"
    SUPERVISE="$supervise"
    SUPERVISOR_FILE="$supervisor_file"
    MAX_RUNS="$max_runs"
    SCHEDULE_MODE="$schedule_mode"
    PROMPT_SOURCE="$prompt_source"
    STATUS="active"
    if (( start_now || spec_changed )); then
      NEXT_RUN_EPOCH="$(now_epoch)"
      if (( ! start_now )); then
        NEXT_RUN_EPOCH=$(( NEXT_RUN_EPOCH + INTERVAL_SECONDS ))
      fi
    elif [[ -z "${NEXT_RUN_EPOCH:-}" || "$NEXT_RUN_EPOCH" == "0" ]]; then
      NEXT_RUN_EPOCH=$(( $(now_epoch) + INTERVAL_SECONDS ))
    fi
    NEXT_RUN_AT="$(epoch_to_local "$NEXT_RUN_EPOCH")"

    if (( spec_changed )); then
      printf '%s\n' "$prompt" >"$selected/prompt.txt"
      SESSION_ID=""
      RUN_COUNT="0"
      LAST_RUN_STARTED_AT=""
      LAST_RUN_FINISHED_AT=""
      LAST_EXIT_CODE=""
      : >"$selected/run.log"
      : >"$selected/stderr.log"
      : >"$selected/last_message.txt"
      : >"$selected/last_run.jsonl"
      : >"$selected/runtime_prompt.txt"
      : >"$selected/audit.log"
      : >"$selected/reflection.log"
      : >"$selected/state.md"
      LAST_NOTE="spec updated; session reset"
    elif [[ -n "$note" ]]; then
      LAST_NOTE="$note"
    fi

    save_job "$selected"
    start_worker "$selected" >/dev/null
    load_job "$selected"

    cat <<EOF
Ensured loop job $JOB_ID
Name: ${JOB_NAME:-}
Status: $(job_display_status "$selected")
Interval: $INTERVAL_LABEL ($INTERVAL_INPUT)
Schedule mode: ${SCHEDULE_MODE:-fixed}
Prompt source: ${PROMPT_SOURCE:-inline}
Run limit: ${MAX_RUNS:-0}
Next run: $NEXT_RUN_AT
Working directory: $CWD
Mode: ${MODE:-terminal}
Terminal target: tmux_pane=${TARGET_TMUX_PANE:-} window=${TARGET_WINDOW_ID:-} title=${TARGET_TITLE_PATTERN:-} tty=${TARGET_TTY:-}
Require end tag: ${REQUIRE_END_TAG:-0}
Supervise: ${SUPERVISE:-0}${SUPERVISOR_FILE:+ ($SUPERVISOR_FILE)}
Session id: ${SESSION_ID:-pending}
Prompt: $(job_prompt_preview "$selected")
EOF
    return 0
  fi

  local -a create_args=(--name "$job_name" --cwd "$cwd" --mode "$mode" --send-delay "$send_delay")
  if bool_enabled "$supervise"; then
    create_args+=(--supervise)
    if [[ -n "$supervisor_file" ]]; then
      create_args+=(--supervisor-file "$supervisor_file")
    fi
  else
    create_args+=(--no-supervise)
  fi
  if bool_enabled "$require_end_tag"; then
    create_args+=(--require-end-tag)
  else
    create_args+=(--no-require-end-tag)
  fi
  if (( start_now )); then
    create_args+=(--start-now)
  fi
  if [[ "$max_runs" != "0" ]]; then
    create_args+=(--count "$max_runs")
  fi
  if [[ -n "$target_tty" ]]; then
    create_args+=(--tty "$target_tty")
  elif [[ -n "$target_tmux_pane" ]]; then
    create_args+=(--tmux-pane "$target_tmux_pane")
  elif [[ -n "$target_window_id" ]]; then
    create_args+=(--window-id "$target_window_id")
  elif [[ -n "$target_title_pattern" ]]; then
    create_args+=(--title-pattern "$target_title_pattern")
  fi
  create_job "${create_args[@]}" -- "$raw_input"
}

list_jobs() {
  ensure_dirs

  shopt -s nullglob
  local -a metas=()
  metas=("$JOBS_DIR"/*/meta.env)
  shopt -u nullglob

  if (( ${#metas[@]} == 0 )); then
    echo "No loop jobs."
    return 0
  fi

  printf '%-8s  %-18s  %-10s  %-9s  %-8s  %-18s  %-20s  %-5s  %s\n' "JOB_ID" "NAME" "STATUS" "MODE" "SCHED" "INTERVAL" "NEXT_RUN" "RUNS" "PROMPT"
  local meta jobdir status prompt_preview
  for meta in "${metas[@]}"; do
    jobdir="$(dirname "$meta")"
    load_job "$jobdir"
    status="$(job_display_status "$jobdir")"
    prompt_preview="$(job_prompt_preview "$jobdir")"
    printf '%-8s  %-18s  %-10s  %-9s  %-8s  %-18s  %-20s  %-5s  %s\n' \
      "$JOB_ID" \
      "${JOB_NAME:--}" \
      "$status" \
      "${MODE:-terminal}" \
      "${SCHEDULE_MODE:-fixed}" \
      "$INTERVAL_INPUT" \
      "${NEXT_RUN_AT:-n/a}" \
      "$(run_count_label)" \
      "$prompt_preview"
  done
}

show_job() {
  local jobdir
  jobdir="$(assert_job_exists "$1")"
  load_job "$jobdir"

  cat <<EOF
Job ID: $JOB_ID
Name: ${JOB_NAME:-}
Status: $(job_display_status "$jobdir")
Created: ${CREATED_AT:-}
Working directory: ${CWD:-}
Interval: ${INTERVAL_LABEL:-} (${INTERVAL_INPUT:-})
Schedule mode: ${SCHEDULE_MODE:-fixed}
Prompt source: ${PROMPT_SOURCE:-inline}
Run limit: ${MAX_RUNS:-0}
Next run: ${NEXT_RUN_AT:-}
Mode: ${MODE:-terminal}
Terminal target: tmux_pane=${TARGET_TMUX_PANE:-} window=${TARGET_WINDOW_ID:-} title=${TARGET_TITLE_PATTERN:-} tty=${TARGET_TTY:-}
Send delay: ${SEND_DELAY:-0}
Require end tag: ${REQUIRE_END_TAG:-0}
Supervise: ${SUPERVISE:-0}
Supervisor file: ${SUPERVISOR_FILE:-}
Reflection: ${REFLECTION:-$REFLECTION_ENABLED}
Session id: ${SESSION_ID:-}
Worker pid: ${PID:-}
Child pid: ${CURRENT_CHILD_PID:-}
Run count: $(run_count_label)
Last started: ${LAST_RUN_STARTED_AT:-}
Last finished: ${LAST_RUN_FINISHED_AT:-}
Last exit code: ${LAST_EXIT_CODE:-}
Last note: ${LAST_NOTE:-}
Prompt:
$(base_prompt_for_job "$jobdir")

Artifacts:
  $jobdir/prompt.txt
  $jobdir/runtime_prompt.txt
  $jobdir/audit.log
  $jobdir/reflection.log
  $jobdir/state.md
  $jobdir/run.log
  $jobdir/stderr.log
  $jobdir/last_message.txt
  $jobdir/last_run.jsonl
EOF
}

cancel_job() {
  local jobdir
  jobdir="$(assert_job_exists "$1")"
  load_job "$jobdir"

  local worker_pid="${PID:-}"
  local child_pid="${CURRENT_CHILD_PID:-}"

  STATUS="canceled"
  NEXT_RUN_EPOCH="0"
  NEXT_RUN_AT=""
  PID=""
  CURRENT_CHILD_PID=""
  LAST_NOTE="canceled"
  save_job "$jobdir"

  if pid_alive "$child_pid"; then
    kill "$child_pid" 2>/dev/null || true
  fi
  if pid_alive "$worker_pid"; then
    kill -TERM -- "-$worker_pid" 2>/dev/null || kill "$worker_pid" 2>/dev/null || true
  fi

  echo "Canceled loop job $JOB_ID"
}

restart_job() {
  local jobdir
  jobdir="$(assert_job_exists "$1")"
  load_job "$jobdir"

  STATUS="active"
  if [[ "${MAX_RUNS:-0}" != "0" && "${RUN_COUNT:-0}" -ge "${MAX_RUNS:-0}" ]]; then
    RUN_COUNT="0"
  fi
  if [[ -z "${NEXT_RUN_EPOCH:-}" || "$NEXT_RUN_EPOCH" == "0" ]]; then
    NEXT_RUN_EPOCH=$(( $(now_epoch) + INTERVAL_SECONDS ))
    NEXT_RUN_AT="$(epoch_to_local "$NEXT_RUN_EPOCH")"
  fi
  LAST_NOTE="restarted"
  save_job "$jobdir"
  start_worker "$jobdir" >/dev/null
  echo "Restarted loop job $JOB_ID"
  echo "Next run: $NEXT_RUN_AT"
}

run_now_job() {
  local jobdir
  jobdir="$(assert_job_exists "$1")"
  load_job "$jobdir"

  if [[ "${STATUS:-}" != "active" ]]; then
    STATUS="active"
    if [[ "${MAX_RUNS:-0}" != "0" && "${RUN_COUNT:-0}" -ge "${MAX_RUNS:-0}" ]]; then
      RUN_COUNT="0"
    fi
    save_job "$jobdir"
  fi

  run_job_once "$jobdir"
  echo "Triggered loop job $JOB_ID"
  echo "Session id: ${SESSION_ID:-}"
  echo "Last exit code: ${LAST_EXIT_CODE:-}"
  echo "Next run: ${NEXT_RUN_AT:-}"
  echo "Last message: $(last_message_preview "$jobdir/last_message.txt")"
}

parse_only() {
  local parsed interval_input interval_seconds interval_label prompt note schedule_mode prompt_source
  parsed="$(parse_loop_input "$*")"
  IFS="$FIELD_SEP" read -r interval_input interval_seconds interval_label prompt note schedule_mode prompt_source <<<"$parsed"
  cat <<EOF
Interval input: $interval_input
Interval seconds: $interval_seconds
Interval label: $interval_label
Schedule mode: $schedule_mode
Prompt source: $prompt_source
Prompt: $prompt
Note: ${note:-}
EOF
}

main() {
  local cmd="${1-}"
  if [[ -z "$cmd" ]]; then
    create_job
    exit 0
  fi
  shift || true

  case "$cmd" in
    create)
      create_job "$@"
      ;;
    ensure)
      ensure_job "$@"
      ;;
    list)
      list_jobs
      ;;
    show)
      [[ $# -eq 1 ]] || die "usage: codex-loop show JOB_ID"
      show_job "$1"
      ;;
    run-now)
      [[ $# -eq 1 ]] || die "usage: codex-loop run-now JOB_ID"
      run_now_job "$1"
      ;;
    restart)
      [[ $# -eq 1 ]] || die "usage: codex-loop restart JOB_ID"
      restart_job "$1"
      ;;
    cancel)
      [[ $# -eq 1 ]] || die "usage: codex-loop cancel JOB_ID"
      cancel_job "$1"
      ;;
    parse)
      parse_only "$@"
      ;;
    worker)
      [[ $# -eq 1 ]] || die "usage: codex-loop worker JOB_ID"
      worker_loop "$1"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      create_job "$cmd" "$@"
      ;;
  esac
}

main "$@"
