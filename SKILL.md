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
4. New loop jobs must target the current Terminal Codex session. Do not use detached `exec` mode; the goal is to mimic Claude `/loop` by queuing work back into the visible session.
5. Target binding must be reliable. If the target Codex session is inside tmux, prefer `--tmux-pane %NN` or create the loop from inside that pane so `codex-loop` can bind `TMUX_PANE`. If the target is a plain Terminal tab, use `--tty /dev/ttysNNN`, `--window-id ID`, or `--title-pattern TEXT`; do not rely on front-window guessing.
6. The background worker only schedules and queues Terminal input. The actual reasoning and tool work happen in the current Terminal Codex session.

## Pre-Send Idle Gate

Before sending a loop prompt into a Terminal/tmux Codex target, treat idle detection as a hard gate:

- Only send after the previous turn has produced a final assistant response or the target pane/tab has returned to a prompt-ready idle state.
- If the target is still running a tool, streaming output, waiting on SSH/test results, or has not emitted a final response, do not paste or press Return; wait and re-check.
- If idle detection is ambiguous, skip that fire rather than risk appending a prompt into an active turn. Record the skip in the job log.
- Prefer a terminal-orchestrator/tmux `read/check` style status check for tmux targets, or the loop runner's bound TTY/window idle detector for Terminal tabs. Do not use fixed wall-clock cadence alone as proof of readiness.
- For fragile long-running jobs, use a per-job lock or state file around prompt injection: create it when a turn is sent, clear it only after the turn is observed idle/final, and skip sends while it exists.
- For session-loop workflows that tag complete conversations with `[start xxx]` and `[end xxx]`, pass `--require-end-tag`. The first cycle may send normally; later cycles must capture the target output and require the latest `[start ...]`/`[end ...]` tag to be an `[end xxx]` tag before sending the next prompt. If the latest tag is a `[start xxx]` or no end tag is visible, skip and retry instead of pasting or pressing Return.

## Commands

- Create a loop:
  `codex-loop --cwd "$PWD" -- "<raw loop input>"`
- Ensure one named loop exists and stays reusable:
  `codex-loop ensure --name JOB_NAME --cwd "$PWD" -- "<raw loop input>"`
- Limit a loop to N runs:
  `codex-loop --count 5 -- "asap continue"`
- Create or ensure a loop that sends the prompt back into a Terminal Codex session:
  `codex-loop ensure --name JOB_NAME --mode terminal --window-id WINDOW_ID --cwd "$PWD" -- "<raw loop input>"`
  Use `--tmux-pane %NN` when the target Codex session is inside tmux; this is preferred over Terminal focus. Use `--tty /dev/ttysNNN` for a Terminal tab outside tmux, or `--title-pattern TEXT` when the Terminal title is stable.
- Create or ensure a session-tag gated loop:
  `codex-loop ensure --name JOB_NAME --mode terminal --tmux-pane %NN --require-end-tag --cwd "$PWD" -- "<raw loop input>"`
  Use this for recurring Codex sessions that emit `[start xxx]` at the beginning of a full session and `[end xxx]` only after the final response is complete.
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

Prompt-only input uses Claude-style dynamic scheduling: the first delay starts at 10 minutes, then each run may choose the next delay from 1 minute to 1 hour by writing `CODEX_LOOP_NEXT_DELAY=<duration>` in its final message.

`asap` mode schedules the next iteration immediately, but terminal mode still waits until the bound target appears idle before injecting the prompt. If `--require-end-tag` is enabled, terminal mode also waits until the latest session tag is `[end xxx]`. This avoids appending a new prompt into an active Codex turn. After sending, ASAP waits for the turn to go busy and then idle again before scheduling the next immediate fire. The turn wait defaults to no timeout and can be bounded with `CODEX_LOOP_TERMINAL_ASAP_TURN_TIMEOUT`.

If the user gives only an interval and no prompt, use the default maintenance prompt. Resolve it from `.claude/loop.md` in the loop working directory, then `~/.claude/loop.md`, then the built-in maintenance prompt.

When the user invokes the skill as `/loop ...`, pass the raw argument string through unchanged. Do not force an extra `create` verb.

## Behavior

- Default `terminal` mode: each loop fire pastes the parsed prompt into the bound target and presses Return via `codex-send-current.sh`. If the target session is inside tmux, bind and send by `--tmux-pane`/`tmux send-keys` instead of relying on mouse focus or AppleScript. Otherwise fall back to TTY/window/title binding. This is the closest local approximation of Claude's native `/loop` session behavior because the work stays in the visible Codex conversation.
- Schedule modes:
  - `fixed`: explicit intervals such as `5m check deploy` or `check deploy every 2 hours`.
  - `dynamic`: prompt-only input such as `check deploy`; Codex chooses the next 1m-1h delay after each run, falling back to 10m if no valid delay is emitted.
  - `asap`: explicit `asap` input such as `asap keep going`; the next run is scheduled immediately, but each terminal send waits for the target to be idle first, then waits for that turn to complete before scheduling the next immediate run. With `--require-end-tag`, it also requires the latest observed session tag to be `[end xxx]` before sending the next cycle. This preserves "never stop" without interrupting the active turn.
- Jobs live under `$CODEX_LOOP_HOME/jobs/<job_id>/`, defaulting to `~/codex-loop/jobs/<job_id>/`.
- Named jobs are supported through `--name` plus `ensure`. This is the preferred way to keep one reusable monitor, reminder, or polling loop without spawning duplicates.
- This Codex implementation is still a local background runner, not a native session hook. In `terminal` mode the background runner queues Terminal injection and uses TTY-bound Terminal contents for post-send idle detection.
- Detached `exec` mode is disabled. Historical jobs with `MODE=exec` are blocked at runtime instead of launching detached Codex.
- No overlap per job. A loop never spawns multiple concurrent Codex runs for the same job.
- Reflection is on by default. Each fired prompt asks Codex to include compact `LOOP_REFLECTION_*` lines about objective drift, the loop target, the target project, active skills, prompts, workflow docs, repo instructions, and the next smallest action. Terminal loops read back output to capture reflections; captured reflections are appended to `reflection.log`.
- `state.md` is regenerated from the latest reflection and a short `reflection.log` tail using Hermes-style sections: Goal, Objective Drift Check, Constraints & Preferences, Progress, Key Decisions, Relevant Files, Next Steps, and Critical Context.
- Reflection may improve relevant user/project skills, prompts, workflow docs, repo instructions, or the loop itself when it finds a concrete defect or high-confidence improvement. Keep self-improvement edits scope-relevant and narrow, avoid unrelated rewrites, verify the result, and commit changes when the target is a git repo.
- Seconds are rounded up to one minute for fixed intervals. `asap` is the exception and intentionally uses a 0-second delay.
- Debug with the per-job artifacts:
  `prompt.txt`, `runtime_prompt.txt`, `reflection.log`, `state.md`, `run.log`, `stderr.log`, `last_message.txt`, `last_run.jsonl`
- The Terminal sender is vendored inside this skill at `scripts/codex-send-current.sh`; `loop` no longer depends on the separate `auto-continue` skill.

## Response Pattern

When you create a loop, report:

- Job ID
- Parsed interval
- Next run time
- Working directory
- Any parse note, such as defaulting to `10m` or rounding seconds up

When you cancel or restart a loop, confirm the job ID and resulting state.
