#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_BIN="$SCRIPT_DIR/codex-loop.sh"
SEND_BIN="$SCRIPT_DIR/codex-send-current.sh"

SESSION="codex_loop_asap_smoke_$$"
PANE_ID=""
JOB_IDLE=""
JOB_BUSY=""
FAIL_JOB=""
MOCK_TMI=""
IDLE_MARK="LOOP_ASAP_IDLE_$RANDOM"
BUSY_MARK="LOOP_ASAP_BUSY_$RANDOM"

cleanup() {
  if [[ -n "$JOB_IDLE" ]]; then
    "$LOOP_BIN" cancel "$JOB_IDLE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$JOB_BUSY" ]]; then
    "$LOOP_BIN" cancel "$JOB_BUSY" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAIL_JOB" ]]; then
    "$LOOP_BIN" cancel "$FAIL_JOB" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOCK_TMI" ]]; then
    rm -f "$MOCK_TMI"
  fi
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

extract_job_id() {
  awk '/^Created loop job / { print $4; exit }'
}

wait_for_job_state() {
  local job_id="$1"
  local want="$2"
  local timeout="${3:-15}"
  local start now
  start="$(date +%s)"
  while true; do
    if "$LOOP_BIN" show "$job_id" 2>/dev/null | grep -q "^Status: $want$"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo "timeout waiting for job $job_id to reach state '$want'" >&2
      return 1
    fi
    sleep 1
  done
}

capture_pane() {
  tmux capture-pane -pt "$PANE_ID"
}

count_output_lines() {
  local marker="$1"
  capture_pane | grep -xc "$marker" || true
}

tmux new-session -d -s "$SESSION" 'bash'
PANE_ID="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | head -n1)"
[[ -n "$PANE_ID" ]] || {
  echo "failed to create tmux test pane" >&2
  exit 1
}

echo "[1/6] idle-pane asap smoke"
JOB_IDLE="$("$LOOP_BIN" --cwd "$PWD" --target "$PANE_ID" --count 2 -- "asap echo $IDLE_MARK" | extract_job_id)"
[[ -n "$JOB_IDLE" ]] || {
  echo "failed to create idle asap test job" >&2
  exit 1
}
wait_for_job_state "$JOB_IDLE" "completed" 15
IDLE_COUNT="$(count_output_lines "$IDLE_MARK")"
if [[ "$IDLE_COUNT" != "2" ]]; then
  echo "idle asap test failed: expected 2 occurrences of $IDLE_MARK, saw $IDLE_COUNT" >&2
  exit 1
fi

echo "[2/6] busy-pane asap smoke"
tmux send-keys -t "$PANE_ID" 'sleep 4' C-m
JOB_BUSY="$("$LOOP_BIN" --cwd "$PWD" --target "$PANE_ID" --count 1 -- "asap echo $BUSY_MARK" | extract_job_id)"
[[ -n "$JOB_BUSY" ]] || {
  echo "failed to create busy asap test job" >&2
  exit 1
}
sleep 1
MID_CAPTURE="$(capture_pane)"
if grep -q "$BUSY_MARK" <<<"$MID_CAPTURE"; then
  echo "busy asap test failed: prompt was injected before pane became idle" >&2
  exit 1
fi
wait_for_job_state "$JOB_BUSY" "completed" 15
FINAL_COUNT="$(count_output_lines "$BUSY_MARK")"
if [[ "$FINAL_COUNT" != "1" ]]; then
  echo "busy asap test failed: expected 1 occurrence of $BUSY_MARK, saw $FINAL_COUNT" >&2
  exit 1
fi

echo "[3/6] interrupted pane idle gate"
MOCK_TMI="$(mktemp "${TMPDIR:-/tmp}/codex-loop-tmi-mock.XXXXXX")"
cat >"$MOCK_TMI" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  state)
    echo "app=codex idle=true busy=false cursor=20,3"
    ;;
  send)
    exit 0
    ;;
  *)
    echo "unsupported mock tmi command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_TMI"

tmux send-keys -t "$PANE_ID" "printf 'Model interrupted to submit steer instructions.\\n\\n› continue\\n'" C-m
sleep 1
if TMI_BIN="$MOCK_TMI" "$SEND_BIN" --tmux-pane "$PANE_ID" --wait-idle-only --idle-timeout 2 >/dev/null 2>&1; then
  echo "interrupted idle-gate test failed: interrupted pane was treated as idle" >&2
  exit 1
fi

echo "[4/6] history prompt must not block idle"
tmux send-keys -t "$PANE_ID" "printf '› old prompt from history\\nline 1\\nline 2\\nline 3\\nline 4\\nline 5\\ngpt-5.4 xhigh · ~\\n'" C-m
sleep 1
if ! TMI_BIN="$MOCK_TMI" "$SEND_BIN" --tmux-pane "$PANE_ID" --wait-idle-only --idle-timeout 2 >/dev/null 2>&1; then
  echo "history prompt idle-gate test failed: historical prompt was treated as active draft" >&2
  exit 1
fi

echo "[5/6] idle suggestion placeholder must not block idle"
tmux send-keys -t "$PANE_ID" "printf '\\n› Implement {feature}\\n\\n  gpt-5.4 high · ~/evas-autoresearch\\n'" C-m
sleep 1
if ! TMI_BIN="$MOCK_TMI" "$SEND_BIN" --tmux-pane "$PANE_ID" --wait-idle-only --idle-timeout 2 >/dev/null 2>&1; then
  echo "placeholder idle-gate test failed: idle suggestion was treated as a real draft" >&2
  exit 1
fi

echo "[6/6] failed first send must not dirty run count"
tmux send-keys -t "$PANE_ID" "printf 'Model interrupted to submit steer instructions.\\n\\n› continue\\n'" C-m
sleep 1
FAIL_JOB="$(
  TMI_BIN="$MOCK_TMI" CODEX_LOOP_TERMINAL_PRE_SEND_IDLE_TIMEOUT=2 "$LOOP_BIN" \
    --cwd "$PWD" --target "$PANE_ID" --count 1 --require-end-tag -- "10m echo LOOP_FAIL_GUARD" | extract_job_id
)"
[[ -n "$FAIL_JOB" ]] || {
  echo "failed to create first-send guard job" >&2
  exit 1
}
TMI_BIN="$MOCK_TMI" CODEX_LOOP_TERMINAL_PRE_SEND_IDLE_TIMEOUT=2 "$LOOP_BIN" run-now "$FAIL_JOB" >/dev/null
if ! "$LOOP_BIN" show "$FAIL_JOB" | grep -q '^Run count: 0/1$'; then
  echo "first-send guard test failed: unsuccessful send dirtied run count" >&2
  exit 1
fi

echo "loop asap smoke test passed"
