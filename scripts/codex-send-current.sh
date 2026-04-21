#!/usr/bin/env bash

set -euo pipefail

TMI_BIN="${TMI_BIN:-$HOME/.local/bin/tmi}"
CODEX_SEND_CHECKED_BIN="${CODEX_SEND_CHECKED_BIN:-$HOME/bin/codex_send_checked.sh}"
CLAUDE_SEND_CHECKED_BIN="${CLAUDE_SEND_CHECKED_BIN:-$HOME/bin/claude_send_checked.sh}"

WINDOW_ID=""
TITLE_PATTERN=""
TARGET_TTY=""
TARGET_TMUX_PANE=""
TEXT=""
PRESS_ENTER=1
DELAY_SEC="0"
BACKGROUND=0
DRY_RUN=0
READ_STDIN=0
PRINT_WINDOW_ID=0
PRINT_CONTENTS=0
WAIT_FOR_IDLE=0
WAIT_IDLE_ONLY=0
WAIT_BUSY_ONLY=0
REQUIRE_BUSY_FIRST=0
IDLE_TIMEOUT_SEC="0"
QUIET=0
LOG_FILE="${CODEX_SEND_CURRENT_LOG:-$HOME/codex-send-current.log}"

usage() {
  cat <<'EOF'
Usage:
  codex-send-current.sh [options] <text>

Options:
  --window-id ID   Target Terminal.app window id. Default: current front window.
  --title-pattern T Resolve the target Terminal.app window by matching its title.
  --tty TTY        Resolve and target the live terminal session with this tty, e.g. /dev/ttys020. Supports Terminal.app and iTerm.
  --tmux-pane PANE Target a tmux pane directly, e.g. %18. Preferred when the Codex session runs inside tmux.
  --delay SEC      Wait this many seconds before sending. Default: 0
  --background     Spawn a delayed one-shot sender and return immediately.
  --dry-run        Print the resolved action without sending anything.
  --stdin          Read text from stdin instead of argv.
  --print-window-id Print the resolved Terminal window id and exit.
  --print-contents Print the resolved Terminal tab contents and exit.
  --wait-for-idle Wait until the target Codex Terminal appears idle before acting.
  --wait-idle-only Wait for idle, optionally print contents, and do not send text.
  --wait-busy-only Wait for a busy/working state, optionally print contents, and do not send text.
  --require-busy-first With --wait-for-idle, require a busy/working state before accepting idle.
  --idle-timeout SEC Timeout for --wait-for-idle. 0 means no timeout.
  --quiet          Suppress the background scheduling line.
  --no-enter       Paste text without pressing Return.
  -h, --help       Show this help.
EOF
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

front_window_id() {
  osascript <<'APPLESCRIPT'
tell application "Terminal"
  return (id of front window) as text
end tell
APPLESCRIPT
}

iterm_session_id_by_tty() {
  local target_tty="$1"
  osascript - "$target_tty" <<'APPLESCRIPT'
on run argv
  set targetTty to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            if (tty of s as text) is targetTty then
              return "iterm:" & (id of s as text)
            end if
          end try
        end repeat
      end repeat
    end repeat
  end tell
  error "No iTerm session matches tty: " & targetTty
end run
APPLESCRIPT
}

window_id_by_title() {
  local pattern="$1"
  osascript - "$pattern" <<'APPLESCRIPT'
on run argv
  set patternText to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      try
        set nameText to name of w as text
      on error
        set nameText to ""
      end try
      try
        set titleText to custom title of w as text
      on error
        set titleText to ""
      end try
      if nameText contains patternText or titleText contains patternText then
        return (id of w) as text
      end if
    end repeat
  end tell
  error "No Terminal window matches: " & patternText
end run
APPLESCRIPT
}

window_id_by_tty() {
  local target_tty="$1"
  osascript - "$target_tty" <<'APPLESCRIPT'
on run argv
  set targetTty to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t as text) is targetTty then
            return (id of w) as text
          end if
        end try
      end repeat
    end repeat
  end tell
  error "No Terminal tab matches tty: " & targetTty
end run
APPLESCRIPT
}

resolve_window_id() {
  if [[ -n "$WINDOW_ID" ]]; then
    printf '%s\n' "$WINDOW_ID"
  elif [[ -n "$TITLE_PATTERN" ]]; then
    window_id_by_title "$TITLE_PATTERN"
  elif [[ -n "$TARGET_TTY" ]]; then
    if window_id_by_tty "$TARGET_TTY" 2>/dev/null; then
      return 0
    fi
    iterm_session_id_by_tty "$TARGET_TTY"
  else
    front_window_id
  fi
}

terminal_content() {
  local wid="$1"
  local target_tty="${2:-}"
  if [[ -n "$TARGET_TMUX_PANE" ]]; then
    tmux capture-pane -p -J -S -400 -t "$TARGET_TMUX_PANE"
    return 0
  fi
  if [[ "$wid" == iterm:* ]]; then
    local session_id="${wid#iterm:}"
    osascript - "$session_id" <<'APPLESCRIPT'
on run argv
  set targetSessionId to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as text) is targetSessionId then
            return (contents of s) as text
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "No iTerm session matches id: " & targetSessionId
end run
APPLESCRIPT
    return 0
  fi
  osascript - "$wid" "$target_tty" <<'APPLESCRIPT'
on run argv
  set wid to (item 1 of argv) as integer
  set targetTty to item 2 of argv
  tell application "Terminal"
    if targetTty is not "" then
      repeat with w in windows
        repeat with t in tabs of w
          try
            set tabTty to tty of t as text
          on error
            set tabTty to ""
          end try
          if tabTty is targetTty then
            set selected tab of w to t
            return (contents of selected tab of w) as text
          end if
        end repeat
      end repeat
      error "No Terminal tab matches tty: " & targetTty
    end if
    set targetWindow to first window whose id is wid
    return (contents of selected tab of targetWindow) as text
  end tell
end run
APPLESCRIPT
}

is_codex_idle_text() {
  local text="$1"
  local tail_text
  local prompt_line busy_line
  tail_text="$(printf '%s' "$text" | tail -40)"
  prompt_line="$(
    printf '%s\n' "$tail_text" | awk '/› / { n = NR } END { print n + 0 }'
  )"
  busy_line="$(
    printf '%s\n' "$tail_text" | awk '/esc to interrupt|Working \(|Thinking/ { n = NR } END { print n + 0 }'
  )"
  (( prompt_line > 0 )) || return 1
  (( prompt_line > busy_line )) || return 1
  return 0
}

is_codex_busy_text() {
  local text="$1"
  local tail_text
  local prompt_line busy_line
  tail_text="$(printf '%s' "$text" | tail -40)"
  prompt_line="$(
    printf '%s\n' "$tail_text" | awk '/› / { n = NR } END { print n + 0 }'
  )"
  busy_line="$(
    printf '%s\n' "$tail_text" | awk '/esc to interrupt|Working \(|Thinking/ { n = NR } END { print n + 0 }'
  )"
  (( busy_line > 0 )) || return 1
  (( prompt_line == 0 || busy_line >= prompt_line )) || return 1
  return 0
}

wait_for_idle() {
  local wid="$1"
  local timeout="$2"
  local start now content
  start="$(date +%s)"
  while true; do
    content="$(terminal_content "$wid" "$TARGET_TTY" 2>/dev/null || true)"
    if is_codex_idle_text "$content"; then
      return 0
    fi

    if [[ "$timeout" != "0" ]]; then
      now="$(date +%s)"
      if (( now - start >= timeout )); then
        echo "timeout waiting for Codex idle in Terminal window $wid" >&2
        return 1
      fi
    fi
    sleep 2
  done
}

wait_for_busy_then_idle() {
  local wid="$1"
  local timeout="$2"
  local start now content
  start="$(date +%s)"
  while true; do
    content="$(terminal_content "$wid" "$TARGET_TTY" 2>/dev/null || true)"
    if is_codex_busy_text "$content"; then
      wait_for_idle "$wid" "$timeout"
      return $?
    fi

    if [[ "$timeout" != "0" ]]; then
      now="$(date +%s)"
      if (( now - start >= timeout )); then
        echo "timeout waiting for Codex turn to start in Terminal window $wid" >&2
        return 1
      fi
    fi
    sleep 1
  done
}

wait_for_busy() {
  local wid="$1"
  local timeout="$2"
  local start now content
  start="$(date +%s)"
  while true; do
    content="$(terminal_content "$wid" "$TARGET_TTY" 2>/dev/null || true)"
    if is_codex_busy_text "$content"; then
      return 0
    fi

    if [[ "$timeout" != "0" ]]; then
      now="$(date +%s)"
      if (( now - start >= timeout )); then
        echo "timeout waiting for Codex busy state in Terminal window $wid" >&2
        return 1
      fi
    fi
    sleep 1
  done
}

validate_non_negative_number() {
  local value="$1"
  local label="$2"
  if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "$label must be a non-negative number: $value" >&2
    exit 1
  fi
}

send_tmux_payload() {
  local pane="$1"
  local payload="$2"
  local press_enter="$3"
  local buffer_name="codex-loop-send-$$-$RANDOM"
  local pane_state pane_cmd pane_title runtime

  tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null
  pane_state="$("$TMI_BIN" state "$pane" 2>/dev/null || true)"
  pane_cmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
  pane_title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
  runtime="shell"

  if [[ "$pane_state" == *"app=codex"* ]] || [[ "$pane_cmd" == "node" ]] || [[ "$pane_title" =~ [Cc]odex ]]; then
    runtime="codex"
  elif [[ "$pane_state" == *"app=claude"* ]] || [[ "$pane_cmd" =~ ^[0-9]+\.[0-9]+ ]] || [[ "$pane_title" =~ (Opus|Sonnet|Haiku|claude|Claude) ]]; then
    runtime="claude"
  elif [[ "$pane_state" == *"app=gemini"* ]] || [[ "$pane_title" =~ [Gg]emini ]]; then
    runtime="gemini"
  fi

  if [[ "$press_enter" -eq 1 ]]; then
    case "$runtime" in
      codex)
        "$CODEX_SEND_CHECKED_BIN" "$pane" "$payload"
        return
        ;;
      claude)
        "$CLAUDE_SEND_CHECKED_BIN" --agent claude "$pane" "$payload"
        return
        ;;
      gemini)
        "$CLAUDE_SEND_CHECKED_BIN" --agent gemini "$pane" "$payload"
        return
        ;;
    esac
  fi

  printf '%s' "$payload" | tmux load-buffer -b "$buffer_name" -
  tmux paste-buffer -p -d -b "$buffer_name" -t "$pane"
  if [[ "$press_enter" -eq 1 ]]; then
    tmux send-keys -t "$pane" Enter
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-id)
      WINDOW_ID="${2:-}"
      shift 2
      ;;
    --title-pattern)
      TITLE_PATTERN="${2:-}"
      shift 2
      ;;
    --tty)
      TARGET_TTY="${2:-}"
      shift 2
      ;;
    --tmux-pane)
      TARGET_TMUX_PANE="${2:-}"
      shift 2
      ;;
    --delay)
      DELAY_SEC="${2:-}"
      shift 2
      ;;
    --background)
      BACKGROUND=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --stdin)
      READ_STDIN=1
      shift
      ;;
    --print-window-id)
      PRINT_WINDOW_ID=1
      shift
      ;;
    --print-contents)
      PRINT_CONTENTS=1
      shift
      ;;
    --wait-for-idle)
      WAIT_FOR_IDLE=1
      shift
      ;;
    --wait-idle-only)
      WAIT_FOR_IDLE=1
      WAIT_IDLE_ONLY=1
      shift
      ;;
    --wait-busy-only)
      WAIT_BUSY_ONLY=1
      shift
      ;;
    --require-busy-first)
      REQUIRE_BUSY_FIRST=1
      shift
      ;;
    --idle-timeout)
      IDLE_TIMEOUT_SEC="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --no-enter)
      PRESS_ENTER=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

validate_non_negative_number "$DELAY_SEC" "delay"
validate_non_negative_number "$IDLE_TIMEOUT_SEC" "idle-timeout"

if [[ -n "$TARGET_TMUX_PANE" && ( -n "$WINDOW_ID" || -n "$TITLE_PATTERN" || -n "$TARGET_TTY" ) ]]; then
  echo "--tmux-pane is mutually exclusive with --window-id, --title-pattern, and --tty" >&2
  exit 1
fi

if [[ "$WAIT_IDLE_ONLY" -eq 1 || "$WAIT_BUSY_ONLY" -eq 1 ]]; then
  TEXT=""
elif [[ "$READ_STDIN" -eq 1 ]]; then
  TEXT="$(cat)"
elif [[ $# -lt 1 ]]; then
  echo "missing text" >&2
  usage >&2
  exit 1
else
  TEXT="$*"
fi

if [[ -n "$TARGET_TMUX_PANE" ]]; then
  tmux display-message -p -t "$TARGET_TMUX_PANE" '#{pane_id}' >/dev/null
  WINDOW_ID="tmux:$TARGET_TMUX_PANE"
else
  WINDOW_ID="$(resolve_window_id)"
fi
if [[ "$PRINT_WINDOW_ID" -eq 1 ]]; then
  printf '%s\n' "$WINDOW_ID"
  exit 0
fi

if [[ "$BACKGROUND" -eq 1 ]]; then
  if [[ -n "$TARGET_TMUX_PANE" ]]; then
    cmd=( "$0" --tmux-pane "$TARGET_TMUX_PANE" --delay "$DELAY_SEC" )
  else
    cmd=( "$0" --window-id "$WINDOW_ID" --delay "$DELAY_SEC" )
  fi
  if [[ -n "$TARGET_TTY" ]]; then
    cmd+=( --tty "$TARGET_TTY" )
  fi
  if [[ "$WAIT_FOR_IDLE" -eq 1 ]]; then
    cmd+=( --wait-for-idle --idle-timeout "$IDLE_TIMEOUT_SEC" )
  fi
  if [[ "$REQUIRE_BUSY_FIRST" -eq 1 ]]; then
    cmd+=( --require-busy-first )
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd+=( --dry-run )
  fi
  if [[ "$READ_STDIN" -eq 1 ]]; then
    cmd+=( --stdin )
  fi
  if [[ "$QUIET" -eq 1 ]]; then
    cmd+=( --quiet )
  fi
  if [[ "$PRESS_ENTER" -eq 0 ]]; then
    cmd+=( --no-enter )
  fi
  cmd+=( -- "$TEXT" )
  nohup "${cmd[@]}" >/dev/null 2>&1 &
  log "scheduled pid=$! window_id=$WINDOW_ID delay=$DELAY_SEC enter=$PRESS_ENTER text=$TEXT"
  if [[ "$QUIET" -eq 0 ]]; then
    printf 'started pid=%s window_id=%s delay=%s text=%s\n' "$!" "$WINDOW_ID" "$DELAY_SEC" "$TEXT"
  fi
  exit 0
fi

if [[ "$WAIT_BUSY_ONLY" -eq 1 ]]; then
  wait_for_busy "$WINDOW_ID" "$IDLE_TIMEOUT_SEC"
  if [[ "$PRINT_CONTENTS" -eq 1 ]]; then
    terminal_content "$WINDOW_ID" "$TARGET_TTY"
  fi
  exit 0
fi

if [[ "$WAIT_FOR_IDLE" -eq 1 ]]; then
  if [[ "$REQUIRE_BUSY_FIRST" -eq 1 ]]; then
    wait_for_busy_then_idle "$WINDOW_ID" "$IDLE_TIMEOUT_SEC"
  else
    wait_for_idle "$WINDOW_ID" "$IDLE_TIMEOUT_SEC"
  fi
fi

if [[ "$WAIT_IDLE_ONLY" -eq 1 ]]; then
  if [[ "$PRINT_CONTENTS" -eq 1 ]]; then
    terminal_content "$WINDOW_ID" "$TARGET_TTY"
  fi
  exit 0
fi

if [[ "$PRINT_CONTENTS" -eq 1 ]]; then
  terminal_content "$WINDOW_ID" "$TARGET_TTY"
  exit 0
fi

sleep "$DELAY_SEC"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run window_id=%s tmux_pane=%s delay=%s enter=%s text=%s\n' "$WINDOW_ID" "$TARGET_TMUX_PANE" "$DELAY_SEC" "$PRESS_ENTER" "$TEXT"
  exit 0
fi

if [[ -n "$TARGET_TMUX_PANE" ]]; then
  send_tmux_payload "$TARGET_TMUX_PANE" "$TEXT" "$PRESS_ENTER"
  log "sent tmux_pane=$TARGET_TMUX_PANE delay=$DELAY_SEC enter=$PRESS_ENTER text=$TEXT"
  exit 0
fi

if [[ "$WINDOW_ID" == iterm:* ]]; then
  osascript - "${WINDOW_ID#iterm:}" "$TEXT" "$PRESS_ENTER" <<'APPLESCRIPT'
on run argv
  set targetSessionId to item 1 of argv
  set payload to item 2 of argv
  set pressEnter to ((item 3 of argv) as integer)

  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as text) is targetSessionId then
            if pressEnter is 1 then
              tell s to write text payload
            else
              tell s to write text payload newline NO
            end if
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "No iTerm session matches id: " & targetSessionId
end run
APPLESCRIPT
  log "sent iterm_session=${WINDOW_ID#iterm:} delay=$DELAY_SEC enter=$PRESS_ENTER text=$TEXT"
  exit 0
fi

osascript - "$WINDOW_ID" "$TARGET_TTY" "$TEXT" "$PRESS_ENTER" <<'APPLESCRIPT'
on run argv
  set wid to (item 1 of argv) as integer
  set targetTty to item 2 of argv
  set payload to item 3 of argv
  set pressEnter to ((item 4 of argv) as integer)

  set hadClipboard to true
  set oldClipboard to ""
  try
    set oldClipboard to the clipboard
  on error
    set hadClipboard to false
  end try

  tell application "Terminal"
    if targetTty is not "" then
      set foundTarget to false
      repeat with w in windows
        repeat with t in tabs of w
          try
            set tabTty to tty of t as text
          on error
            set tabTty to ""
          end try
          if tabTty is targetTty then
            set targetWindow to w
            set selected tab of w to t
            set foundTarget to true
            exit repeat
          end if
        end repeat
        if foundTarget then
          exit repeat
        end if
      end repeat
      if not foundTarget then
        error "No Terminal tab matches tty: " & targetTty
      end if
    else
      set targetWindow to first window whose id is wid
    end if
    activate
    set index of targetWindow to 1
  end tell

  delay 0.2
  set the clipboard to payload
  delay 0.05

  tell application "System Events"
    keystroke "v" using command down
  end tell

  if pressEnter is 1 then
    delay 0.15
    tell application "System Events"
      key code 36
    end tell
  end if

  if hadClipboard then
    delay 0.05
    set the clipboard to oldClipboard
  end if
end run
APPLESCRIPT

log "sent window_id=$WINDOW_ID delay=$DELAY_SEC enter=$PRESS_ENTER text=$TEXT"
