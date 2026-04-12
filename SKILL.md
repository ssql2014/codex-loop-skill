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
5. Target binding must be reliable. Prefer creating the loop from inside the target Codex Terminal session so `codex-loop` can bind that Terminal tab's TTY. If creating from another session, pass `--tty /dev/ttysNNN`, `--window-id ID`, or `--title-pattern TEXT`; do not rely on front-window guessing.
6. The background worker only schedules and queues Terminal input. The actual reasoning and tool work happen in the current Terminal Codex session.

## Commands

- Create a loop:
  `codex-loop --cwd "$PWD" -- "<raw loop input>"`
- Ensure one named loop exists and stays reusable:
  `codex-loop ensure --name JOB_NAME --cwd "$PWD" -- "<raw loop input>"`
- Limit a loop to N runs:
  `codex-loop --count 5 -- "asap continue"`
- Create or ensure a loop that sends the prompt back into a Terminal Codex session:
  `codex-loop ensure --name JOB_NAME --mode terminal --window-id WINDOW_ID --cwd "$PWD" -- "<raw loop input>"`
  Use `--tty /dev/ttysNNN` for the most reliable Terminal tab binding, or `--title-pattern TEXT` when the Terminal title is stable.
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

`asap` mode queues the next iteration immediately after the previous iteration finishes. In `terminal` mode this is conservative: wait for the bound Terminal tab to be idle before sending, send the prompt, then require one observed busy/working turn before accepting the next idle state. If no turn-start is observed, pause the job rather than risk pasting multiple prompts into the same input field.

If the user gives only an interval and no prompt, use the default maintenance prompt. Resolve it from `.claude/loop.md` in the loop working directory, then `~/.claude/loop.md`, then the built-in maintenance prompt.

When the user invokes the skill as `/loop ...`, pass the raw argument string through unchanged. Do not force an extra `create` verb.

## Behavior

- Default `terminal` mode: each loop fire pastes the parsed prompt into the bound Terminal tab and presses Return via `codex-send-current.sh`. The binding is TTY/window/title based and must be captured at creation time. This is the closest local approximation of Claude's native `/loop` session behavior because the work stays in the visible Codex conversation.
- Schedule modes:
  - `fixed`: explicit intervals such as `5m check deploy` or `check deploy every 2 hours`.
  - `dynamic`: prompt-only input such as `check deploy`; Codex chooses the next 1m-1h delay after each run, falling back to 10m if no valid delay is emitted.
  - `asap`: explicit `asap` input such as `asap keep going`; the next run is queued after the bound target tab has run one turn and returned to idle. A failed turn-start observation pauses the job as a safety stop.
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
