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

# --- MAJOR-6 (redteam-step6.md) -------------------------------------------
#
# Four Stop hooks fire on one Stop event; only guard-subagent-stall.sh and
# gate-drive-loop.sh (package 02) read the operator's one-shot
# .drive-solo/.run-finished marker. On a session that is BOTH continuity-
# armed AND drive-solo-active, those two consume the marker and allow --
# and THIS gate, knowing nothing about it, still denies on its own terms.
# The turn does not end, and the operator's marker is already spent on a
# stop that never happened -- the same "token spent for nothing" defect
# gate-drive-loop.sh's own .stop-ok carry exists to fix, reintroduced here
# for the operator's PRIMARY lever.
#
# FINISH_GRACE_S / _bp_continuity_finish_present -- a LOCAL, NON-MUTATING
# copy of gate-drive-loop.sh's own _bp_finish_present (MINOR-1) plus its
# lower-bounded grace window (MAJOR-2). Write-set boundary, this whole
# hook family's own convention (see this file's header on why there is no
# shared bp_hook_gate call): duplicated rather than sourced from a sibling
# package's file. NON-MUTATING is deliberate -- the two sibling hooks
# already consume (rename) the marker on this same Stop event; this gate
# only needs to recognise a fresh-or-just-consumed one as "the operator is
# ending this run", never spend it a second time.
FINISH_GRACE_S=15
_bp_continuity_finish_present() {
    local _cfp_ds="$1"
    [ -f "$_cfp_ds/.run-finished" ] && return 0
    if [ -f "$_cfp_ds/.run-finished.consumed" ]; then
        local _cfp_now _cfp_mt
        _cfp_now=$(date +%s 2>/dev/null || echo 0)
        _cfp_mt=$(bp_mtime "$_cfp_ds/.run-finished.consumed")
        if [ "$_cfp_now" -gt 0 ] && [ "$_cfp_mt" -gt 0 ] \
           && [ $(( _cfp_now - _cfp_mt )) -ge 0 ] \
           && [ $(( _cfp_now - _cfp_mt )) -lt "$FINISH_GRACE_S" ]; then
            return 0
        fi
    fi
    return 1
}

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

# --- HOLD THE MACHINE AWAKE WHILE THIS SESSION IS ARMED ----------------------
#
# An armed session IS unattended work, so the two things that silently end it
# must be held off for as long as the arm stands: the host suspending (Windows
# connected standby) and, in a sandbox, heartbeat.sh reaping the container. The
# refresher process started by `arm` does that; this block is its safety net at
# the one moment the session is guaranteed to be alive and observable.
#
# THE TOUCHES ARE PURE SHELL AND SPAWN NOTHING. Both mechanisms are leased off a
# file's mtime — keep-awake.ps1 polls keepawake.pid, heartbeat.sh polls
# /tmp/.butler-busy — so re-asserting them is a stat and a utime, not a decision.
# That matters here: this hook runs on EVERY turn end, and the 2026-08-13
# incident (a machine buried in powershell.exe/conhost.exe until a forced
# restart) came from putting a process spawn on exactly such a path. Starting a
# helper is a decision, and decisions are left to bp-continuity.pl below.
#
# The busy-lease is touched only on Linux, i.e. inside a container: on the
# Windows host there is nothing watching that file, and the wake-lock is the
# mechanism that matters. See BpContinuityLease.pm for the full split.
#
# CCPRAXIS_NO_WAKELOCK SKIPS THE WHOLE BLOCK, TOUCHES INCLUDED. It used to gate
# only the restart, which was worse than doing nothing: the touch kept an orphan
# helper's 900s lease alive on every turn end while the one code path able to
# RELEASE it was skipped, so "hold nothing" turned into "hold this one forever".
# The test matches perl's truthiness (empty and "0" are off) so the two halves of
# the mechanism cannot disagree about whether the opt-out is in force.
NO_WAKELOCK=0
case "${CCPRAXIS_NO_WAKELOCK:-}" in ''|0) ;; *) NO_WAKELOCK=1 ;; esac

if [ -n "${CONT_DIR:-}" ] && [ "$NO_WAKELOCK" -eq 0 ]; then
  # -s, not -f: an EMPTY pid file is BpKeepAwake's atomic claim, waiting for a
  # helper that has not written its pid yet. Its age is the only thing that can
  # expire it, so touching it would freeze a claim whose helper died at birth
  # into a permanent "starting" that nothing ever replaces.
  [ -s "$CONT_DIR/keepawake.pid" ] && touch "$CONT_DIR/keepawake.pid" 2>/dev/null
  # $OSTYPE, not `uname -s`: uname is a fork+exec, and this block's whole claim
  # is that it costs no process on a path that runs at every turn end. bash sets
  # OSTYPE itself — "linux-gnu" in the container, "cygwin" in this host's
  # Git-Bash (measured; "msys" in some builds — neither matches linux*, which is
  # the only thing this needs).
  case "${OSTYPE:-}" in
    linux*) touch "${BP_BUSY_PATH:-/tmp/.butler-busy}" 2>/dev/null || true ;;
  esac

  # Restart the refresher if its heartbeat has gone stale. LIVENESS BY MTIME,
  # NOT BY PID: bash cannot tell a live native Windows pid from a dead one
  # (kill -0 reports a healthy one as dead — the asymmetry BpKeepAwake::_pid_alive
  # exists to work around), whereas a file's age means the same thing on every
  # platform and costs one stat. 300s is BpContinuityLease's $TICK_SECONDS *
  # $STALE_TICKS; keep the two in step.
  #
  # A heartbeat stamped in the FUTURE (negative age) counts as stale, matching
  # BpContinuityLease::ensure_daemon: a backwards clock jump would otherwise
  # make a dead refresher look healthy for the whole skew, and a needless
  # restart costs nothing because the flock makes the loser exit at once.
  LEASE_PID_F="$CONT_DIR/lease.pid"
  LEASE_STALE=1
  if [ -f "$LEASE_PID_F" ] && [ "${MNOW:-0}" -gt 0 ]; then
    LEASE_MT=$(bp_mtime "$LEASE_PID_F")
    LEASE_AGE=$(( MNOW - LEASE_MT ))
    if [ "$LEASE_MT" -gt 0 ] && [ "$LEASE_AGE" -ge 0 ] && [ "$LEASE_AGE" -lt 300 ]; then
      LEASE_STALE=0
    fi
  fi
  if [ "$LEASE_STALE" -eq 1 ]; then
    perl "$HOOK_DIR/../scripts/bp-continuity.pl" lease >/dev/null 2>&1 || true
  fi
fi

# --- escape hatch: one-shot file, consumed ----------------------------------
if [ -f "$MARK.stop-ok" ]; then
  rm -f "$MARK.stop-ok" "$MARK.wakeup-pending" "$MARK.stop-blocks" 2>/dev/null
  exit 0
fi

# --- MAJOR-6: the operator's drive-solo .run-finished marker, for THIS ------
# session, also ends an armed continuity turn -- see the header comment on
# _bp_continuity_finish_present above for why this must be checked here and
# why it is non-mutating. bp_drive_marker resolves this SID's OWN
# drive-solo marker (never another session's); its content's first line is
# the data dir a real drive-solo run recorded, same convention
# gate-drive-loop.sh itself reads.
_CFM_DRIVE_MARK=$(bp_drive_marker "$SID" 2>/dev/null) || _CFM_DRIVE_MARK=""
if [ -n "$_CFM_DRIVE_MARK" ] && [ -f "$_CFM_DRIVE_MARK" ]; then
  _CFM_DATA=$(head -n 1 "$_CFM_DRIVE_MARK" 2>/dev/null || true)
  if [ -n "$_CFM_DATA" ] && [ -d "$_CFM_DATA/.drive-solo" ] \
     && _bp_continuity_finish_present "$_CFM_DATA/.drive-solo"; then
    rm -f "$MARK.stop-blocks" 2>/dev/null
    echo "butler continuity-gate: allowing this stop -- the operator's .run-finished marker (drive-solo, this session) already ended this run; not spending it a second time." >&2
    exit 0
  fi
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
  # THE RECORD ON DISK IS ALWAYS THE EXPIRED ONE AT THIS MOMENT, AND THAT IS
  # STRUCTURAL RATHER THAN UNLUCKY.
  #
  # What re-invokes an armed session is the PREVIOUS hold's own expiry. So a
  # woken turn begins with an expired record on disk, dispatches a fresh
  # background `hold`, and ends. The Stop hook then reads the same file the new
  # hold is racing to write. Measured (almanac 20260916-105540-0d46): the gate
  # read at 10:54:16, the background hold wrote at 10:54:17, and a session that
  # had done exactly what the skill instructs was blocked by one second.
  #
  # Every continuity cycle is that race, so retrying is not papering over a
  # flake -- it is reading the file at a moment when the answer can be right.
  # The wait only happens on the path that is ABOUT TO BLOCK THE TURN, which is
  # the expensive outcome; a permitted stop still costs one verify and no sleep.
  # Bounded hard, because a gate that hangs is worse than one that refuses.
  VERIFY_RETRY_MAX=12          # x 250ms = 3s ceiling
  VERIFY_RETRY=0
  while : ; do
    VERIFY_OUT=$(perl "$HOOK_DIR/../scripts/bp-resumption.pl" verify \
                   --file "$MARK.wakeup-pending" --ttl "$WAKEUP_TTL_S" 2>&1)
    VERIFY_RC=$?
    [ "$VERIFY_RC" -eq 0 ] && break
    # Only the refusals a not-yet-written record can produce are worth waiting
    # out. A marker that is present and genuinely invalid -- not bounded, no
    # pid, a dead or recycled process -- will not become valid by waiting, and
    # must refuse at once.
    case "$VERIFY_OUT" in
      *'deadline has passed'*|*unreadable*|*'no deadline'*|*'no write timestamp'*|*'cannot open'*|*'does not exist'*) ;;
      *) break ;;
    esac
    VERIFY_RETRY=$((VERIFY_RETRY + 1))
    [ "$VERIFY_RETRY" -ge "$VERIFY_RETRY_MAX" ] && break
    sleep 0.25
  done

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
# --- THE THIRD EXIT: THERE IS NO WORK ----------------------------------------
#
# A gate with only two exits assumes one of them is always reachable. Both of
# this gate's were "keep going" (hold) and "I am finished" (disarm) -- and when
# the work IS finished and `disarm` is refused by guard-run-finish.sh, neither
# is true and neither is available. The session can then do nothing but re-arm a
# bounded hold, at one full turn per expiry, until whatever is blocking `disarm`
# resolves itself. Measured 2026-09-18: about fifteen consecutive turns whose
# entire content was re-arming a 900s hold and reporting "Holding", with zero
# open bug reports, zero dispatches and zero background processes. The exit
# condition was a 12-hour TTL elapsing on a stale marker -- not an event any
# party could cause. Report 20260918-134732-acfd; the operator's words were
# "holding only makes sense if there is work you are doing".
#
# So: if there is genuinely no outstanding work, the turn may end. Not disarmed
# -- the arm stands, and the next turn is gated exactly as before -- just not
# forced to manufacture a wait for work that does not exist.
#
# THIS CANNOT BE GAMED INTO A FALSE "FINISHED". bp_outstanding_work reads the
# package ledgers on disk, the same ones guard-run-finish.sh consults, and it is
# the SAME function so the two can no longer disagree -- their disagreement is
# what built the trap. Nothing the agent asserts is an input. It fails toward
# WORK EXISTS when it cannot tell, so ignorance keeps the gate shut.
#
# Deliberately AFTER the wake-up checks above: a session with a live hold still
# takes that path and this never runs.
if [ -z "${CCPRAXIS_CONTINUITY_SKIP_IDLE_EXIT:-}" ]; then
  _rl=1
  bp_drive_any_active 2>/dev/null || _rl=0
  _out="$(bp_outstanding_work "$_rl" 2>/dev/null)"
  if [ -z "${_out:-}" ]; then
    rm -f "$MARK.stop-blocks" 2>/dev/null
    echo "butler continuity-gate: allowing this stop -- no outstanding work. Every package of every non-archived blueprint is at a terminal status, so there is nothing for a hold to wait on. The session STAYS ARMED: the next turn is gated exactly as before. If you meant to finish for good, disarm; if work appears, hold as usual." >&2
    exit 0
  fi
fi

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
