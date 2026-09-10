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

## If `status` says the gate has never run

`status` reports `GATE_SEEN`. The gate touches the marker on every run, so `GATE_SEEN: no` well
after arming means no Stop has been gated for this session id — usually because the id armed is not
the one Claude Code considers live. Re-run `on`: it arms every candidate id it can find and reports
the disagreement, rather than trusting one source silently.

## Arguments

- `$ARGUMENTS` — one of `on`, `off`, `status`. Empty defaults to `status`.

## Steps

### 1. Run the script

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution for this skill's own directory; the
canonical script lives two levels up at `<plugin-root>/scripts/`.

- `on` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" arm --session "${CLAUDE_SESSION_ID}" --by operator
  ```
- `off` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" disarm --session "${CLAUDE_SESSION_ID}"
  ```
- `status` (or no argument) →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" status --session "${CLAUDE_SESSION_ID}"
  ```

### 2. Parse the result

The script emits `KEY: value` lines on stdout:

- `STATUS: armed` → success (arm or status-while-armed). `ARMED_BY:` and `SINCE:` are present.
- `STATUS: disarmed` → disarm succeeded.
- `STATUS: not_armed` → disarm on a session that was not armed (not a failure — report it plainly).
- `STATUS: unarmed` → status on a session that is not armed.
- `STATUS: error` followed by `ERROR: …` → report the error verbatim and stop.

### 3. Confirm to the user

One short sentence confirming the new state to the user.

Examples:

> Continuity armed for this session — I'll be blocked from ending a turn with nothing scheduled to
> resume it, until you run `/butler:continuity off`.

> Continuity disarmed for this session.

> This session is not currently armed.
