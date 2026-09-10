#!/usr/bin/env bash
# gate-continuity.sh — Stop hook for an EXPLICITLY-ARMED continuity session.
#
# THE RULE IT ENFORCES
#
#   Once a session has been explicitly armed (perl bp-continuity.pl arm, or
#   /butler:continuity on), a turn may end EITHER because something will wake
#   the session (a dispatched Task/Agent, a backgrounded Bash call), OR
#   because the session has been explicitly DISARMED. Never for any other
#   reason.
#
# WHY THIS IS A NEW, DIRECTOR-FREE GATE, not a re-arming of gate-drive-loop.sh
# or gate-headless-background.sh: see
# specs/g01-explicit-continuity-arming-spec.md SS1/SS2.5. There is no oracle
# for "is this non-blueprint session's work done" — settlement is explicit
# disarm only. This file never stubs, requires, or reads bp-drive-next.pl,
# and reads BP_LEDGER in exactly one place, below, as a top-of-file
# short-circuit — never as a branching signal for block/allow.
#
# WHY THERE IS NO bp_hook_gate CALL HERE (fix-batch F2) — this is DELIBERATE,
# not an omission to "fix" by adding one. Every butler hook begins with
# bp_hook_gate, which requires BP_LEDGER — exported only into coordinator
# processes (see gate-drive-loop.sh's own header for the identical argument
# one level down, for the driver). This gate exists PRECISELY for the
# opposite case: a session with NO blueprint, NO drive-solo, NO reporter —
# i.e. one bp_hook_gate would refuse outright. Adding a bp_hook_gate call
# here would make this file live ONLY inside a coordinator process, which is
# the one class of session that arm already refuses to watch (cmd_arm's
# BP_LEDGER check, and the defense-in-depth BP_LEDGER check a few lines
# below) — i.e. it would silently disable this entire package for every
# session it was built to cover, while still compiling, still registered,
# still "correct" by every check that doesn't actually invoke it live.
#
# POSTURE: FAIL OPEN, ALWAYS BOUNDED — same discipline as gate-drive-loop.sh.
# `source lib.sh 2>/dev/null || exit 0`: a Stop gate cannot function at all
# without the registry helpers, so failing open explicitly here is correct.
#
# ESCAPE HATCHES
#   * touch <marker>.stop-ok              — one-shot; consumed on use
#   * export CCPRAXIS_CONTINUITY_STOP_OK=1 — session-wide
# WHAT THIS DEFENDS AGAINST, stated plainly because the rest of this file argues
# about soundness at length and never says.
#
# ACCIDENT, NOT ADVERSARY. Every check here answers "did the agent END A TURN
# WITH NOTHING SCHEDULED, without meaning to?" -- an agent that announces its
# next step and stops, or dispatches something unbounded and treats that as a
# plan. It is NOT a security boundary and cannot be one: anything that can run a
# Bash tool call can write a bounded marker by hand, or touch the exemption
# file, and the block message hands over the latter deliberately.
#
# That is the right trade for this problem, but it decides what "sound" means
# here. The rules exist so an agent cannot satisfy the gate BY ACCIDENT while
# believing it has scheduled something -- which is why a dispatch no longer
# counts, why a deadline must be accompanied by a live process, and why that
# process's IDENTITY is checked rather than just its pid. Each of those closed a
# way to be wrong sincerely. None of them would stop anyone determined, and
# adding checks that only stop the determined would cost clarity for nothing.

set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0


# Coordinators are gate-stop.sh's business, and arm itself already refuses
# BP_LEDGER at the source (spec SS2.2). This is defense in depth, independent
# of that refusal — a marker could predate a session later becoming a
# coordinator, or be planted directly by a test fixture.
[ -n "${BP_LEDGER:-}" ] && exit 0

[ "${CCPRAXIS_CONTINUITY_STOP_OK:-}" = "1" ] && exit 0

# Cheap pre-check + THE reap point (bp_continuity_any_active, lib.sh): the
# overwhelming common case (no one armed anywhere) costs stats only, and this
# is where a stale marker belonging to ANY session gets reaped, regardless of
# who is calling right now.
# --- cheap pre-check, now counting UNBOUND arms too --------------------------
#
# bp_continuity_any_active exits when no MARKER exists anywhere. A pending
# TICKET is not a marker -- it is an arm waiting to learn which session it
# belongs to -- so checking markers alone would exit before the ticket could
# ever bind, and every arm would silently do nothing. That is precisely the
# class of failure the ticket flow replaces, so it must not be reintroduced
# here. Cost when nothing is pending: one directory test.
CONT_DIR=$(bp_continuity_active_dir 2>/dev/null || true)
HAVE_PENDING=0
if [ -n "${CONT_DIR:-}" ] && [ -d "$CONT_DIR/pending" ]; then
  for _t in "$CONT_DIR"/pending/*; do
    [ -e "$_t" ] || break
    HAVE_PENDING=1
    break
  done
fi

if [ "$HAVE_PENDING" -eq 0 ]; then
  bp_continuity_any_active || exit 0
fi

# READ THE PAYLOAD EXACTLY ONCE. bp_read_payload consumes stdin (`read -r -d ''`),
# so a second call finds nothing and, in `open` mode, waits out the timeout and
# exits 0 -- which would make this gate stand aside on every single stop while
# looking perfectly healthy. One read, then $SID is reused below.
bp_read_payload open
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
[ -n "$SID" ] || exit 0

# --- bind any pending arm to THIS session ------------------------------------
#
# `bp-continuity.pl arm` cannot know which session Claude Code considers live: a
# Bash tool call is never told. THIS hook is told, in its payload. So arming
# writes a ticket carrying a nonce and prints the nonce into its own session's
# transcript, and the binding happens here, where the live id is a fact rather
# than a guess. bp-session.pl binds a ticket only when the transcript record
# carrying its nonce names the SAME session as this payload -- two independent
# facts agreeing, which is what makes it safe for any number of concurrent
# sessions sharing one registry.
if [ "$HAVE_PENDING" -eq 1 ]; then
  perl "$HOOK_DIR/../scripts/bp-session.pl" claim --session "$SID" >/dev/null 2>&1 || true
fi

MARK=$(bp_continuity_marker "$SID" 2>/dev/null) || exit 0
[ -f "$MARK" ] || exit 0

# Per-marker TTL — belt to the sweep's braces (mirrors gate-drive-loop.sh's
# own per-session TTL check). The sweep above already reaped anything stale
# that it found; this catches the case where THIS session's own marker just
# crossed the TTL between the sweep and this read.
TTL_H=$(bp_continuity_ttl_hours)
MNOW=$(date +%s 2>/dev/null || echo 0)
MMT=$(bp_mtime "$MARK")
if [ "$MNOW" -gt 0 ] && [ "$MMT" -gt 0 ] \
   && [ $(( (MNOW - MMT) / 3600 )) -ge "$TTL_H" ]; then
  rm -f "$MARK" "$MARK.wakeup-pending" "$MARK.stop-blocks" "$MARK.stop-ok" 2>/dev/null
  exit 0
fi

touch "$MARK" 2>/dev/null || true

# --- escape hatch: one-shot file, consumed ----------------------------------
if [ -f "$MARK.stop-ok" ]; then
  rm -f "$MARK.stop-ok" "$MARK.wakeup-pending" "$MARK.stop-blocks" 2>/dev/null
  exit 0
fi

# --- a wake-up is already scheduled: this turn end is legitimate -----------
# mark-wakeup.sh's extended write (independent of .drive-solo) wrote this on
# a Task/Agent dispatch or a backgrounded Bash call. CONSUME it.
#
# BUT ONLY IF IT IS STILL PENDING (bug report 20260829-225523-88e7).
#
# The marker used to be a bare flag with no timestamp. It records that something
# was DISPATCHED, never that anything will still wake the session -- so a marker
# written for work that had already completed several turns earlier was
# consumed by a later, unrelated stop. An armed session ended a turn having just
# written "next: promote, then re-run the sync", and the operator had to ask why
# it stopped. That is precisely what this gate is for.
#
# A wake-up that was scheduled long ago has either fired or died by now; a hook
# cannot tell which, and both mean it is no longer pending. So the marker
# expires. WAKEUP_TTL_S is generous -- a genuine background task that has not
# called back within it is not something this session should be waiting on
# silently anyway.
#
# .stop-blocks is deliberately NOT cleared here any more. "A wake-up was
# scheduled" and "this agent has been repeatedly trying to end its turn" are
# independent facts, and clearing the counter on marker consumption let a single
# backgrounded command both permit the stop AND erase the evidence of the
# pattern.
WAKEUP_TTL_S=${CCPRAXIS_CONTINUITY_WAKEUP_TTL_S:-900}
if [ -f "$MARK.wakeup-pending" ]; then
  # ONE IMPLEMENTATION OF "WILL ANYTHING BRING THIS BACK", AND IT IS NOT HERE.
  #
  # This used to parse the marker in awk and decide in shell: bounded? deadline
  # ahead? pid alive? Two of those three were subtly wrong, and both had already
  # been solved in bp-runstate.pl -- kill -0 reports a healthy native Windows
  # process as dead, and a live pid is not the SAME pid once the holding process
  # has exited and the OS recycled the number. `hold` exits at its deadline BY
  # DESIGN, so pid reuse is the ordinary case here, not an exotic one.
  #
  # Shell cannot compute a process fingerprint, so translating the rules here a
  # second time could only reproduce that gap. bp-resumption.pl answers instead,
  # over the same module bp-runstate.pl uses. The marker is consumed either way,
  # so a stale one can never be spent twice.
  VERIFY_OUT=$(perl "$HOOK_DIR/../scripts/bp-resumption.pl" verify \
                 --file "$MARK.wakeup-pending" --ttl "$WAKEUP_TTL_S" 2>&1)
  VERIFY_RC=$?

  if [ "$VERIFY_RC" -eq 0 ]; then
    # A VALID MARKER IS NOT CONSUMED. It used to be removed on every stop,
    # because the old marker was a bare "something was dispatched" flag with no
    # way to tell whether it was still pending -- spending it once was the only
    # safe reading. That is no longer true: a bounded marker names a deadline
    # and a live process, so its validity is RE-DERIVED on every check rather
    # than inferred from the file still being there.
    #
    # Consuming it broke a continuing promise. A `hold` sleeps for minutes and
    # exits; if the session wakes for any OTHER reason in the meantime -- a
    # background task finishing, a notification -- that turn's stop spends the
    # marker, and the NEXT stop is blocked even though the hold is still alive
    # and will still fire. Observed exactly that: blocked while a 890s hold was
    # sleeping, having been woken early by an unrelated task completing.
    #
    # A stale or refused marker is still removed below, so the "cannot be spent
    # twice" property that mattered is unchanged -- it just applies to markers
    # that are actually spent, rather than to every marker on sight.
    rm -f "$MARK.stop-blocks" 2>/dev/null
    exit 0
  fi

  # Refused: remove it. A marker that cannot justify a stop now will never be
  # able to, and leaving it would let a later check re-read the same dead
  # promise.
  rm -f "$MARK.wakeup-pending" 2>/dev/null
  # Refused. Say WHY on the way to blocking -- a gate whose refusals cannot be
  # explained is one an agent learns to work around rather than satisfy.
  if [ -n "${VERIFY_OUT:-}" ]; then
    echo "butler continuity-gate: the pending wake-up was refused: ${VERIFY_OUT#REASON: }" >&2
  fi
fi

# --- it blocks until something is done ---------------------------------------
#
# There used to be a bound here: after N consecutive refusals the gate yielded,
# on the reasoning that a gate which will not yield is worse than a stalled run.
# That was true when the only honest way to satisfy it was to have real work in
# flight -- an agent with nothing to schedule and no way to say so could be
# wedged, and yielding was the escape.
#
# It is not true any more. There are now three remedies, one of which is always
# available: hold (something will return), await-operator (a human was asked),
# disarm (the work is finished). Each is a single command. An agent that cannot
# satisfy any of them is an agent that has not read the message, and yielding
# for it converts a loud refusal into a silent one -- the session ends armed,
# unwatched, with nothing scheduled, which is exactly the outcome this gate
# exists to prevent. The bound was protecting against a gap that has since been
# closed.
#
# .stop-blocks is still counted, because the count is useful evidence in the
# message; it no longer decides anything.
# ONE-SHOT DIAGNOSTIC (remove once read). Three times now I have explained why
# the shim is not on this hook's PATH without measuring it. A hook cannot be
# handed an env var by the agent, so this keys on a file instead: it writes once
# and never again.
_PROBE="${CONT_DIR:-}/.path-probe"
if [ -n "${CONT_DIR:-}" ] && [ ! -e "$_PROBE" ]; then
  {
    echo "PATH=$PATH"
    echo "bp-continuity:    $(command -v bp-continuity 2>&1 || echo MISS)"
    echo "bp-continuity.sh: $(command -v bp-continuity.sh 2>&1 || echo MISS)"
    echo "perl:             $(command -v perl 2>&1 || echo MISS)"
    echo "SHELL=${SHELL:-unset}"
  } > "$_PROBE" 2>/dev/null || true
fi

# How to spell the remedy, best form first.
#
# WHY THIS IS NOT JUST `command -v`. A hook does not run in the agent's shell.
# The agent's Bash calls are profile-initialised and re-read the user's PATH, so
# they see a bin directory added to it at any time; THIS hook inherits whatever
# PATH the long-running Claude Code process started with, which can predate that
# entry by an entire session. The first message after adding the shim proved it:
# `bp-continuity.sh` resolved in every shell the agent had, and not here.
#
# So a PATH miss says nothing about whether the SHORT form would work for the
# reader, and the fallback has to be good rather than merely correct. The shim's
# own absolute path is one token and needs no interpreter; `perl <the .pl>` is
# the last resort, for a tree where the shim is missing entirely.
CONT_PL=$(cd "$HOOK_DIR/../scripts" 2>/dev/null && pwd)/bp-continuity.pl
CONT_SH=$(cd "$HOOK_DIR/../bin" 2>/dev/null && pwd)/bp-continuity.sh
if command -v bp-continuity >/dev/null 2>&1; then
  CONT="bp-continuity"
elif command -v bp-continuity.sh >/dev/null 2>&1; then
  CONT="bp-continuity.sh"
elif [ -f "$CONT_SH" ]; then
  CONT="$CONT_SH"
else
  CONT="perl $CONT_PL"
fi

cat >&2 <<EOF
BLOCKED (butler continuity-gate): nothing is scheduled to resume this armed session, and it is not disarmed.

Run ONE of these now:

  $CONT hold --seconds 600
      A bounded wait. Run it as a BACKGROUND Bash call -- its exit wakes this session. Take it alongside any subagent or background command you dispatched: a dispatch may never return, so it is not a wake-up on its own.

  $CONT disarm
      The watched work is finished. (Or /butler:continuity off.)

Got a question for the operator? It does NOT end the turn -- an armed session is unattended work, so nobody is there to answer. Queue it and carry on: $CONT ask --text "<question>". The statusline shows the count; they are answered when the work stops for a reason that is about the work.

This gate does not yield on its own -- it blocks until one of the above runs.
EOF
exit 2
