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
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

MAX_BLOCKS=3

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
MMT=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
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
  rm -f "$MARK.wakeup-pending" 2>/dev/null

  if [ "$VERIFY_RC" -eq 0 ]; then
    rm -f "$MARK.stop-blocks" 2>/dev/null
    exit 0
  fi
  # Refused. Say WHY on the way to blocking -- a gate whose refusals cannot be
  # explained is one an agent learns to work around rather than satisfy.
  if [ -n "${VERIFY_OUT:-}" ]; then
    echo "butler continuity-gate: the pending wake-up was refused: ${VERIFY_OUT#REASON: }" >&2
  fi
fi

# --- bounded nagging ---------------------------------------------------------
BLOCKS=0
[ -f "$MARK.stop-blocks" ] && BLOCKS=$(cat "$MARK.stop-blocks" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge "$MAX_BLOCKS" ]; then
  # GIVING UP IS RECORDED, NOT SILENT -- and it stays a BOUNDED escape.
  #
  # Yielding after N refusals is right: a gate that will not yield is worse than
  # a stalled run. What was wrong is that it left no trace. The marker stayed, so
  # the session still read as "armed" and the statusline kept its watched glyph,
  # while nothing anywhere said continuity had just stood aside -- the same
  # "reports armed, enforces nothing" shape this subsystem exists to remove,
  # arriving at the one moment nobody is looking for it.
  #
  # DISARMING HERE WAS CONSIDERED AND REJECTED. A review argued this state is
  # terminal because no later stop exists to gate. That holds for an UNATTENDED
  # session; in an interactive one the operator speaks again and there are more
  # stops, which is exactly what t/150's D6 pins ("a bounded escape, not a
  # permanent disarm"). Disarming would silently discard an arm the operator
  # asked for, on the strength of an assumption that is only sometimes true. So
  # the counter still resets and the arm still stands; what changes is that the
  # give-up leaves a durable record `status` can surface.
  rm -f "$MARK.stop-blocks" 2>/dev/null
  date +%s > "$MARK.gave-up" 2>/dev/null || true
  echo "butler continuity-gate: allowing this stop after $BLOCKS consecutive blocks — a gate that will not yield is worse than a stalled run." >&2
  echo "butler continuity-gate: this session is STILL ARMED but continuity just stood aside. If nothing is actually scheduled, it will not be woken. Run /butler:continuity status to see it, or 'off' if the work is finished." >&2
  exit 0
fi

echo $((BLOCKS + 1)) > "$MARK.stop-blocks" 2>/dev/null

CONT_PL="$HOOK_DIR/../scripts/bp-continuity.pl"

cat >&2 <<EOF
BLOCKED (butler continuity-gate)
: this turn is ending with nothing scheduled
to resume this armed session, and it has not been disarmed.

This session was explicitly armed to be watched. A turn may end only if
something will wake it, or the arm is explicitly lifted. Neither holds now.

Do one of these NOW, in this turn:
  * take a BOUNDED wait -- run this as a BACKGROUND Bash call, so its exit
    re-invokes this session at a time known in advance:

      perl $CONT_PL hold --seconds 600

    Dispatching a subagent or backgrounding a command is NOT enough on its own.
    A dispatch is not a promise to come back: if it never returns, nothing is
    left to wake this session. Take the hold alongside whatever you dispatched,
    then poll it when the hold elapses and hold again if you are still waiting.

  * if you are ENDING THE TURN TO ASK THE OPERATOR SOMETHING, say so -- that is
    a legitimate end of a turn, not a stall, and the operator's reply is what
    resumes the session:

      perl $CONT_PL await-operator --reason "<what you asked>"

    One turn only; the arm stays in force afterwards.

  * explicitly disarm: perl plugins/butler/scripts/bp-continuity.pl disarm
    (or /butler:continuity off) if the watched work is actually finished, or
  * touch $MARK.stop-ok to skip just this once (await-operator is the same
    exemption with a reason attached, and does not need a permission layer to
    let you touch a dotfile).

(This will not block more than $MAX_BLOCKS times in a row.)
EOF
exit 2
