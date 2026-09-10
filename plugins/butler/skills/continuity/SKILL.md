---
name: continuity
description: Toggle or check explicit continuity arming for THIS session — a Stop gate that blocks
  ending a turn with nothing scheduled to resume it, for sessions doing unattended work with no
  blueprint, drive-solo run, or reporter involved. `on` arms, `off` disarms, no argument or
  `status` reports current state. Use when the operator asks to be "watched" or to arm/disarm
  continuity, or when the agent is about to start open-ended unattended work with no blueprint.
argument-hint: "[on|off|status]  (default: status)"
user-invocable: true
allowed-tools: Bash
---

# /butler:continuity

Explicit continuity arming for the current session. Once armed, `gate-continuity.sh` (a Stop hook)
blocks a turn from ending with nothing scheduled to resume this session — unless the arm is
explicitly lifted with `off`. This is independent of `/butler:drive-solo` and the reporter; it exists
for unattended work that involves neither.

## What counts as "scheduled to resume"

A **bounded** wait, and only that. Dispatching a subagent or backgrounding a Bash call is not
enough on its own: a dispatch records that something *started*, never that anything will come
back. A subagent that runs forever, or a background command with no timeout, satisfies a naive
gate and then never returns — leaving the session idle with nothing left to re-invoke it, which is
the exact outcome this gate exists to prevent.

So take a bounded wait alongside whatever you dispatched, as a **background** Bash call:

```bash
perl "<plugin-root>/scripts/bp-continuity.pl" hold --seconds 600
```

One command both records the promise and keeps it: it writes the deadline, sleeps, and exits — and
a backgrounded command that exits is what actually re-invokes the session. When it elapses, poll
whatever you were really waiting on and either finish or hold again. Pick the horizon to match what
you are waiting for; it may not exceed the wake-up TTL (900s by default).

## `on` does not arm immediately, and that is deliberate

Nothing running as a Bash tool call is told which session Claude Code considers live — including
this skill. `${CLAUDE_SESSION_ID}` is a *template substitution* pasted into this file's text before
it runs, never re-checked, while the Stop gate keys its marker off the `session_id` in its own hook
payload. When those disagreed, `on` reported success and the gate enforced nothing.

So `on` reports **`STATUS: arming`** and prints a nonce. The arm binds at the next turn boundary,
when the Stop hook — which *is* handed the live session id — confirms which session actually
printed that nonce. Tell the operator it is armed *from the next turn boundary*; `status` after
that shows `STATUS: armed` with the real id.

`status` also reports `GATE_SEEN`. The gate touches the marker on every run, so `GATE_SEEN: no`
well after binding means no Stop has been gated for this id — disarm and re-arm to rebind.

## Arguments

- `$ARGUMENTS` — one of `on`, `off`, `status`. Empty defaults to `status`.

## Steps

### 1. Run the script

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution for this skill's own directory; the
canonical script lives two levels up at `<plugin-root>/scripts/`.

**No `--session` is passed, deliberately.** This file used to interpolate `${CLAUDE_SESSION_ID}`
into every command, and that value is a template substitution rendered into this text — not a live
lookup, and not checked against anything. When it was wrong, the gate silently enforced nothing.
The script identifies the session through the Stop hook instead (see above), so passing an id here
would only reintroduce the guess.

- `on` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" arm --by operator
  ```
- `off` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" disarm
  ```
- `status` (or no argument) →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" status
  ```

### 2. Parse the result

The script emits `KEY: value` lines on stdout:

- `STATUS: arming` → `on` succeeded. The arm binds at the next turn boundary; say so rather than
  claiming it is already in force. `NONCE:` is how the session will be identified.
- `STATUS: armed` → the arm is bound and in force. `ARMED_BY:` and `SINCE:` are present, and
  `GATE_SEEN:` says whether a Stop has actually been gated for it yet.
- `STATUS: disarmed` → disarm succeeded (a `NOTE:` says so if it cancelled a still-pending arm).
- `STATUS: not_armed` → disarm on a session that was not armed (not a failure — report it plainly).
- `STATUS: unarmed` → status on a session that is not armed.
- `CONFIDENCE: unverified` on a status line → the id was taken from a process-scoped env value with
  nothing to check it against. Treat the reading as advisory and re-arm if it matters.
- `STATUS: error` followed by `ERROR: …` → report the error verbatim and stop.

### 3. Confirm to the user

One short sentence confirming the new state to the user.

Examples:

> Continuity arms from the next turn boundary — from then on I'll be blocked from ending a turn
> with nothing scheduled to resume it, until you run `/butler:continuity off`.

> Continuity disarmed for this session.

> This session is not currently armed.
