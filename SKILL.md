---
name: loop
description: Schedule recurring Codex prompts with Claude-style /loop syntax. Use when the user asks to create, list, inspect, restart, or cancel periodic prompt jobs, recurring reminders, polling loops, asap loops, dynamic loops, or a generic replacement for one-off cron watchers. Accepts inputs like `5m check deploy`, `check deploy every 2 hours`, `asap keep going`, or no interval for the default maintenance loop.
user-invocable: true
---

# Loop

Use this skill when the user wants Claude Code style `/loop` behavior in Codex.

## Workflow

1. Decide whether the user wants to create a loop, inspect existing loops, run one immediately, restart a stopped loop, or cancel a loop.
2. Use the bundled `codex-loop` wrapper instead of re-implementing parsing by hand.
3. Prefer the current working directory as the loop's `--cwd` unless the user explicitly points at another project.
4. New loop jobs must target the current visible Codex session by default. Prefer tmux pane targets via `--target self`, `--target %12`, or `--target pane:%14`. Do not use detached `exec` mode; the goal is to mimic Claude `/loop` by queuing work back into the visible session.
5. New loop jobs should execute one first cycle immediately after creation or spec update, then follow their fixed/dynamic/asap schedule after that.
6. Treat tmux panes as the primary target type. Use `--target self` when running from inside the target pane, or pass `--target %NN` / `--target pane:%NN` explicitly. Plain terminal tab targeting by `--tty`, `--window-id`, or `--title-pattern` remains available only as a compatibility fallback when the target is not inside tmux.
7. The background worker only schedules and queues terminal input. The actual reasoning and tool work happen in the current visible Codex session.
8. A chat/API call does not itself have a builtin terminal handle. If `/loop` is invoked from chat rather than from inside a live terminal, resolve the target session first by tty/pane: prefer current/frontmost terminal tty, map it to tmux when possible, and only then fall back to hint-based live session discovery. Do not reuse stale hard-coded pane ids as an implicit default.

## Pre-Send Idle Gate

Before sending a loop prompt into a Terminal/tmux Codex target, treat idle detection as a hard gate:

- Only send after the previous turn has produced a final assistant response or the target pane/tab has returned to a prompt-ready idle state.
- If the target is still running a tool, streaming output, waiting on SSH/test results, or has not emitted a final response, do not paste or press Return; wait and re-check.
- If idle detection is ambiguous, skip that fire rather than risk appending a prompt into an active turn. Record the skip in the job log.
- Prefer a terminal-orchestrator/tmux `read/check` style status check for tmux targets, or the loop runner's bound TTY/session idle detector for plain terminal tabs. Do not use fixed wall-clock cadence alone as proof of readiness.
- For fragile long-running jobs, use a per-job lock or state file around prompt injection: create it when a turn is sent, clear it only after the turn is observed idle/final, and skip sends while it exists.
- For session-loop workflows that tag complete conversations with `[start xxx]` and `[end xxx]`, pass `--require-end-tag`. The first cycle may send normally; later cycles must capture the target output and require the latest `[start ...]`/`[end ...]` tag to be an `[end xxx]` tag before sending the next prompt. If the latest tag is a `[start xxx]` or no end tag is visible, skip and retry instead of pasting or pressing Return.

## Commands

- Create a loop in the current tmux pane:
  `codex-loop --cwd "$PWD" --target self -- "<raw loop input>"`
- Create a loop for another tmux pane:
  `codex-loop --cwd "$PWD" --target %12 -- "<raw loop input>"`
- Ensure one named loop exists and stays reusable:
  `codex-loop ensure --name JOB_NAME --cwd "$PWD" --target self -- "<raw loop input>"`
- Limit a loop to N runs:
  `codex-loop --count 5 -- "asap continue"`
- Create or ensure a loop that sends the prompt back into a tmux Codex session:
  `codex-loop ensure --name JOB_NAME --mode terminal --target %NN --cwd "$PWD" -- "<raw loop input>"`
  Use `--target self` for the current tmux pane. Use `--target %NN` or `--target pane:%NN` for another tmux pane. Only use `--tty /dev/ttysNNN`, `--title-pattern TEXT`, or `--window-id WINDOW_ID` when the target is a plain terminal tab outside tmux.
- Create or ensure a session-tag gated loop:
  `codex-loop ensure --name JOB_NAME --mode terminal --target %NN --require-end-tag --cwd "$PWD" -- "<raw loop input>"`
  Use this for recurring Codex sessions that emit `[start xxx]` at the beginning of a full session and `[end xxx]` only after the final response is complete.
- Create or ensure a CCC-inspired supervised loop:
  `codex-loop ensure --name JOB_NAME --supervise --supervisor-file .codex/loop-supervisor.md --cwd "$PWD" -- "<raw loop input>"`
  This appends an inline stop-check to every loop prompt and records `LOOP_AUDIT_*` lines in `audit.log` and `state.md`. It is intentionally not a separate model fork.
- Create a companion audit loop when independent review matters:
  `codex-loop ensure --name JOB_NAME-audit --mode terminal --target %AUDITOR --cwd "$PWD" -- "5m /audit %TARGET <criteria>"`
  Prefer a separate auditor pane/session for this pattern. Do not point an audit loop at the same busy target unless the prompt is purely read-only and idle-gated.
- List loops:
  `codex-loop list`
- Show details for one loop:
  `codex-loop show JOB_ID`
  or `codex-loop show JOB_NAME`
- Trigger one loop immediately:
  `codex-loop run-now JOB_ID`
  or `codex-loop run-now JOB_NAME`
- Restart a stopped loop:
  `codex-loop restart JOB_ID`
  or `codex-loop restart JOB_NAME`
- Cancel a loop:
  `codex-loop cancel JOB_ID`
  or `codex-loop cancel JOB_NAME`

## Input Syntax

Mirror Claude's `/loop` surface syntax:

- `5m check the deploy`
- `check the deploy every 20m`
- `check the deploy every 2 hours`
- `每分钟检查 pane 35`
- `每 5 分钟检查部署`
- `check the deploy`
- `asap check the deploy`
- `check the deploy asap`
- `15m`
- empty input

Prompt-only input uses Claude-style dynamic scheduling: the loop executes one first cycle immediately, then the next delay starts at 10 minutes unless a run chooses a different next delay from 1 minute to 1 hour by writing `CODEX_LOOP_NEXT_DELAY=<duration>` in its final message.

`asap` mode schedules the next iteration immediately, but terminal mode still waits until the bound target appears idle before injecting the prompt. If `--require-end-tag` is enabled, terminal mode also waits until the latest session tag is `[end xxx]`. This avoids appending a new prompt into an active Codex turn. After sending, ASAP waits for the turn to go busy and then idle again before scheduling the next immediate fire. The turn wait defaults to no timeout and can be bounded with `CODEX_LOOP_TERMINAL_ASAP_TURN_TIMEOUT`.

If the user gives only an interval and no prompt, use the default maintenance prompt. Resolve it from `.claude/loop.md` in the loop working directory, then `~/.claude/loop.md`, then the built-in maintenance prompt.

When the user invokes the skill as `/loop ...`, pass the raw argument string through unchanged. Do not force an extra `create` verb.

## Behavior

- Default `terminal` mode: each loop fire pastes the parsed prompt into the bound target and presses Return via `codex-send-current.sh`. The preferred target is a tmux pane selected by `--target self|current|%NN|pane:%NN`. For tmux targets, `codex-send-current.sh` delegates submit/verification to the checked sender stack from `terminal-orchestrator` (`tmi`, `codex_send_checked.sh`, `claude_send_checked.sh`) instead of maintaining a second tmux submit path. Plain terminal tabs remain a fallback through `--tty`, `--window-id`, or `--title-pattern`.
- Schedule modes:
  - `fixed`: explicit intervals such as `5m check deploy` or `check deploy every 2 hours`.
  - `dynamic`: prompt-only input such as `check deploy`; Codex chooses the next 1m-1h delay after each run, falling back to 10m if no valid delay is emitted.
  - `asap`: explicit `asap` input such as `asap keep going`; the next run is scheduled immediately, but each terminal send waits for the target to be idle first, then waits for that turn to complete before scheduling the next immediate run. With `--require-end-tag`, it also requires the latest observed session tag to be `[end xxx]` before sending the next cycle. This preserves "never stop" without interrupting the active turn.
- Creation/update behavior:
  - new jobs run one first cycle immediately
  - `ensure` with a changed spec also runs one first cycle immediately
  - after that first cycle, the configured fixed/dynamic/asap schedule takes over
- Jobs live under `$CODEX_LOOP_HOME/jobs/<job_id>/`, defaulting to `~/codex-loop/jobs/<job_id>/`.
- Named jobs are supported through `--name` plus `ensure`. This is the preferred way to keep one reusable monitor, reminder, or polling loop without spawning duplicates.
- This Codex implementation is still a local background runner, not a native session hook. In `terminal` mode the background runner queues terminal injection and uses TTY-bound session contents for post-send idle detection.
- Detached `exec` mode is disabled. Historical jobs with `MODE=exec` are blocked at runtime instead of launching detached Codex.
- No overlap per job. A loop never spawns multiple concurrent Codex runs for the same job.
- Reflection is off by default. Set `CODEX_LOOP_REFLECTION=1` when you intentionally want compact `LOOP_REFLECTION_*` lines, `reflection.log`, and reflection-derived `state.md` updates for a job.
- `state.md` is regenerated from audit output and current job metadata when reflection is off, or from the latest reflection plus a short `reflection.log` tail when reflection is on.
- Reflection-capable jobs may improve relevant user/project skills, prompts, workflow docs, repo instructions, or the loop itself when they find a concrete defect or high-confidence improvement. Keep such edits scope-relevant and narrow, avoid unrelated rewrites, verify the result, and commit changes when the target is a git repo.
- Seconds are rounded up to one minute for fixed intervals. `asap` is the exception and intentionally uses a 0-second delay.
- Debug with the per-job artifacts:
  `prompt.txt`, `runtime_prompt.txt`, `audit.log`, `reflection.log`, `state.md`, `run.log`, `stderr.log`, `last_message.txt`, `last_run.jsonl`
- The Terminal sender is vendored inside this skill at `scripts/codex-send-current.sh`. It keeps the plain Terminal/iTerm fallback locally, but the tmux send path should reuse `terminal-orchestrator`'s checked sender stack whenever those tools are available. `loop` no longer depends on the separate `auto-continue` skill.

## CCC-Style Supervision

Use `--supervise` when the loop is likely to keep iterating on a task and needs a lightweight stop-check after each turn. This borrows the useful part of `ccc` supervisor behavior, but keeps the loop architecture simple:

- The Codex equivalent of a `stop` hook is the existing post-send idle/final capture. `codex-loop` waits for the target turn to complete, captures the terminal output, then extracts audit lines and, when enabled, reflection lines.
- `--supervise` adds an inline audit contract to the loop prompt. The target must emit `LOOP_AUDIT_VERDICT=PASS|FAIL|HOLD`, `LOOP_AUDIT_REASON=...`, and `LOOP_AUDIT_NEXT=...`.
- Criteria are loaded from `--supervisor-file`, or automatically from `.codex/loop-supervisor.md`, `.claude/SUPERVISOR.md`, `SUPERVISOR.md`, `~/.codex/loop-supervisor.md`, or `~/.claude/SUPERVISOR.md` when present.
- Audit results append to `audit.log` and are folded into `state.md`, so future cycles and recovery can see whether the previous turn really passed.
- Guardrails are prompt-level and runner-level: no recursive `/loop` or `/audit`, no loop job mutation unless explicitly requested, no unrelated skill/doc edits, plus the existing run lock, `--count`, idle gate, and optional `--require-end-tag`.

Do not over-apply this. If you need ccc's strongest property, independent review, run a separate auditor session and schedule a companion audit loop against that auditor. Keep provider switching and SDK-fork logic outside this skill unless the user explicitly asks for that architecture.

## Response Pattern

When you create a loop, report:

- Job ID
- Parsed interval
- Next run time
- Working directory
- Any parse note, such as defaulting to `10m` or rounding seconds up

When you cancel or restart a loop, confirm the job ID and resulting state.
