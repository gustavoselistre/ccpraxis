#!/usr/bin/env bash
# gate-drive-loop.sh — Stop hook inside a /butler:drive-solo DRIVER session.
#
# THE RULE IT ENFORCES
#
#   A driver turn may end EITHER because package 01's live-process PROBE
#   (bp-watch.pl probe) finds a genuinely live, armed, unexpired bp-watch.pl
#   watcher for this project, OR because the OPERATOR's own one-shot
#   .run-finished marker is present. Never for any other reason. The
#   director is no longer consulted at all here (package 02, Decision 23):
#   its `done`/`pause` verdicts were an agent-reachable way to end a run,
#   computed from ledgers the agent itself writes -- the "second door" that
#   criterion forbids. See 02-gates-use-the-probe-spec.md §1/§2.6.
#
# WHY IT EXISTS
#
# drive-solo casts the driver as "a thin loop over the director": call
# `bp-drive-next.pl next`, dispatch the action, call `next` again. That is
# prose, and prose decays over a long context. Observed three times in one
# 12-hour run (2026-08-07): a turn ends immediately after a ledger write,
# the text promises the next step, and nothing is scheduled to perform it.
# A dispatched agent notifies; a finished foreground Bash call does not. The
# run dies silently, mid-package, LOOKING finished — which is the worst
# property an unattended run can have, because the operator only discovers it
# by asking.
#
# gate-stop.sh already makes this exact argument one level down, for
# coordinators: it "converts ledger discipline from a prompt rule (which
# decays over long contexts) into a mechanical gate". But every butler hook
# begins with bp_hook_gate, which requires BP_LEDGER — exported only into
# coordinator processes. So the DRIVER, the one session nothing supervises,
# was the only participant with no stop discipline at all. This closes that.
#
# POSTURE: FAIL OPEN, ALWAYS BOUNDED
#
# A stop gate that misfires traps a human's session, which is far worse than
# a missed nudge. So: every error path exits 0; the director is called under a
# timeout; consecutive blocks are capped (MAX_BLOCKS) and then the stop is
# allowed with an explanation; and there are two explicit escape hatches.
#
# ESCAPE HATCHES
#   * touch <data>/.drive-solo/.stop-ok   — one-shot; consumed on the stop it
#                                           actually lets through (see below)
#   * export CCPRAXIS_DRIVE_STOP_OK=1     — session-wide
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

MAX_BLOCKS=3          # never nag more than this many times in a row
STOP_OK_MAX_CARRY=3   # how many blocked-by-a-sibling stops .stop-ok may survive
FINISH_GRACE_S=15     # a just-consumed .run-finished stays "fresh" for this long

# --- PACKAGE 02 SIGNALS: the live-process probe and the finish marker -------
# Local copies (write-set boundary: hooks/lib.sh is outside this package's
# write set, and this file already duplicates its own bounded-timeout block
# for the identical reason). Used by BOTH branches below (driver and
# reporter), each against its own data dir.
#
# SIGNAL A -- THE PROBE (spec 02-gates-use-the-probe-spec.md §2.1, package
# 01's bp-watch.pl probe). Only exit 0/1 are trusted; every other code --
# missing script, missing perl, a timeout, anything unforeseen -- maps to
# 2 = cannot tell, and 2 ALLOWS (Decision 3). No code-list special-casing.
_bp_probe_verdict() {
    local _pv_data="$1"
    local _pv_p="$HOOK_DIR/../scripts/bp-watch.pl"
    [ -r "$_pv_p" ] || return 2
    command -v perl >/dev/null 2>&1 || return 2
    local _pv_rc
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 perl "$_pv_p" probe --data "$_pv_data" >/dev/null 2>&1
        _pv_rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 10 perl "$_pv_p" probe --data "$_pv_data" >/dev/null 2>&1
        _pv_rc=$?
    else
        # ⚠ MUST FORK, NOT EXEC -- see the director-call comment further down
        # this file for the measured reason (alarm() does not bound an
        # exec'd child under Git-for-Windows perl).
        perl -e '
            my $pid = fork();
            exit 127 unless defined $pid;
            if ($pid == 0) { exec @ARGV; exit 127 }
            my $killed = 0;
            $SIG{ALRM} = sub { $killed = 1; kill 9, $pid };
            alarm 10;
            waitpid($pid, 0);
            my $rc = $?;
            alarm 0;
            exit(124) if $killed;
            exit($rc == 0 ? 0 : ($rc >> 8));
          ' perl "$_pv_p" probe --data "$_pv_data" >/dev/null 2>&1
        _pv_rc=$?
    fi
    case "$_pv_rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# SIGNAL B -- THE FINISH MARKER (Decisions 7/16). Neither hook ever CREATES
# this file (AC19) -- only the operator does, so its presence ends a run
# unconditionally. ONE-SHOT: consumed by renaming to .consumed with a grace
# window, so a second Stop hook firing on the SAME Stop event (four Stop
# hooks fire on one event, from two registration files -- Decision 17) still
# sees it as fresh.
_bp_finish_signal() {
    local _fs_ds="$1"
    if [ -f "$_fs_ds/.run-finished" ]; then
        mv -f "$_fs_ds/.run-finished" "$_fs_ds/.run-finished.consumed" 2>/dev/null \
          || rm -f "$_fs_ds/.run-finished" 2>/dev/null
        if [ -f "$_fs_ds/.run-finished.consumed" ]; then
            touch "$_fs_ds/.run-finished.consumed" 2>/dev/null || true
        else
            # MAJOR-3: both mv and rm failed -- the one-shot marker was NOT
            # consumed (a held file handle, a read-only dir, ...). Allow
            # THIS stop anyway (fail-open, Decision 3), but never again
            # silently: an un-consumable marker is a project-wide, permanent
            # bypass if nobody is told.
            echo "gate-drive-loop: WARNING -- $_fs_ds/.run-finished could not be consumed (rename and delete both failed). The one-shot finish marker was NOT spent; investigate a held file handle or permissions at that path." >&2
        fi
        return 0
    fi
    if [ -f "$_fs_ds/.run-finished.consumed" ]; then
        local _fs_now _fs_mt _fs_age
        _fs_now=$(date +%s 2>/dev/null || echo 0)
        _fs_mt=$(bp_mtime "$_fs_ds/.run-finished.consumed")
        if [ "$_fs_now" -gt 0 ] && [ "$_fs_mt" -gt 0 ]; then
            _fs_age=$(( _fs_now - _fs_mt ))
            if [ "$_fs_age" -lt 0 ]; then
                # MAJOR-2: a future mtime (clock skew, or `mv` preserving a
                # future source mtime) must not become an unbounded grant --
                # "cannot tell -> no grace", not "always < 15".
                echo "gate-drive-loop: .run-finished.consumed has a future mtime -- cannot judge the grace window, treating it as expired." >&2
            elif [ "$_fs_age" -lt "$FINISH_GRACE_S" ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# MINOR-1: a NON-MUTATING variant for PREDICATE use only. _bp_finish_signal
# above CONSUMES the marker (renames/touches it) as a side effect of merely
# asking whether it exists -- fine when the caller is about to act on that
# answer by allowing the stop, wrong when the caller only wants to know
# whether a finish signal exists in order to decide something ELSE (the
# .stop-ok carry predicate below). Mirrors _bp_finish_signal's two file
# tests without ever touching the filesystem.
_bp_finish_present() {
    local _fp_ds="$1"
    [ -f "$_fp_ds/.run-finished" ] && return 0
    if [ -f "$_fp_ds/.run-finished.consumed" ]; then
        local _fp_now _fp_mt
        _fp_now=$(date +%s 2>/dev/null || echo 0)
        _fp_mt=$(bp_mtime "$_fp_ds/.run-finished.consumed")
        if [ "$_fp_now" -gt 0 ] && [ "$_fp_mt" -gt 0 ] \
           && [ $(( _fp_now - _fp_mt )) -ge 0 ] \
           && [ $(( _fp_now - _fp_mt )) -lt "$FINISH_GRACE_S" ]; then
            return 0
        fi
    fi
    return 1
}

# Coordinators are gate-stop.sh's business. BP_LEDGER is exported only into
# coordinator processes, so its ABSENCE identifies an interactive driver.
[ -n "${BP_LEDGER:-}" ] && exit 0

# fixbatch step7 / F2: SCOPING for BOTH surfaces, cheap, BEFORE reading stdin
# or forking anything. hooks.json's Stop entry has no matcher, so this file
# runs on every Stop event in every project on the machine (verified against
# hooks.json:60-67) -- the reporter branch below used to read PAYLOAD and
# fork bp_json_get unconditionally, which meant that cost landed on every one
# of those events too, once any reporter had ever registered anywhere.
#
# Neither surface can possibly match here unless ITS OWN registry has at
# least one entry: bp_drive_any_active (lib.sh) is a pure stat+glob for the
# driver side, and the check below is the same shape for the reporter's
# $RDIR. Both run before PAYLOAD/stdin is touched at all, so the overwhelming
# common case (nothing driving, no reporter ever registered) costs a few
# stats and ONE fork here (d04-registry-path-one-rule: $RDIR now resolves via
# bp_reporter_active_dir, a command substitution, rather than the old inline
# HOME-or-cwd expression -- no longer literally zero forks; a registry keyed
# on the current directory is not a registry, so the guess this replaced had
# to go. bp_drive_any_active immediately below already forks once via
# bp_drive_active_dir, so the total per-Stop fork count in the common case
# goes from 1 to 2, not from 0 to 1. Accepted, not eliminated -- see the
# package spec §5).
# This used to ask only "does any file exist in the registry", which is true
# forever once a marker leaks -- and reporter markers DID leak, because the only
# reap below runs against the current session's own id and a dead reporter never
# returns to match it. bp_reporter_any_active answers the same question but reaps
# expired markers on the way past, so a dead reporter stops making every session
# on the machine do the expensive path on every Stop.
REPORTER_MAYBE=0
if bp_reporter_any_active 2>/dev/null; then
  REPORTER_MAYBE=1
fi
if [ "$REPORTER_MAYBE" = "0" ]; then
  bp_drive_any_active || exit 0
fi

# Read stdin ONCE, here -- both the reporter branch below and the
# pre-existing driver logic further down need it, and a second read from an
# already-drained stdin returns empty.
bp_read_payload open

# ---------------------------------------------------------------------------
# REPORTER BRANCH (g03-reporter-stop-gate). Self-contained; on BLOCK, exits 2
# immediately. On ALLOW or "not a registered reporter", falls through to the
# existing driver logic below, UNCHANGED. A session registered as BOTH (rare)
# must satisfy both branches independently to stop cleanly.
#
# WHY IT NAMES ITS OWN REMEDY. gate-drive-loop.sh's driver-branch BLOCK text
# tells a driver to dispatch a worker or consult bp-drive-next.pl -- neither
# concept exists in a reporter's vocabulary. Training an operator to reach
# for a remedy that does not fit the surface it fires on is exactly what this
# package's own criterion 3 warns against, so this branch never reuses that
# text and never falls through to it.
#
# ESCAPE HATCHES, INDEPENDENT OF THE DRIVER'S OWN:
#   * touch <data>/.reporter-stop-ok        — one-shot; consumed on use
#   * export CCPRAXIS_REPORTER_STOP_OK=1    — session-wide
[ "${CCPRAXIS_REPORTER_STOP_OK:-}" = "1" ] || {
  if RDIR=$(bp_reporter_active_dir 2>/dev/null) && [ -d "$RDIR" ]; then
    RSID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
    RMARK=""
    case "$RSID" in
      ''|*/*|*\**|.|..|*..*) ;;                          # invalid -> not registered
      *) [ -f "$RDIR/$RSID" ] && RMARK="$RDIR/$RSID" ;;
    esac
    if [ -n "$RMARK" ]; then
      # TTL reap -- same staleness discipline as the driver's own marker below.
      RTTL_H="${CCPRAXIS_REPORTER_TTL_H:-12}"
      case "$RTTL_H" in ''|*[!0-9]*) RTTL_H=12 ;; esac
      RNOW=$(date +%s 2>/dev/null || echo 0)
      RMT=$(bp_mtime "$RMARK")
      if [ "$RNOW" -gt 0 ] && [ "$RMT" -gt 0 ] \
         && [ $(( (RNOW - RMT) / 3600 )) -ge "$RTTL_H" ]; then
        rm -f "$RMARK" 2>/dev/null
      else
        RDATA=$(head -n 1 "$RMARK" 2>/dev/null || true)
        if [ -n "$RDATA" ]; then
          touch "$RMARK" 2>/dev/null || true
          if [ -f "$RDATA/.reporter-stop-ok" ]; then
            rm -f "$RDATA/.reporter-stop-ok" "$RDATA/.reporter-stop-blocks" 2>/dev/null
            exit 0
          fi
          # PACKAGE 02: the (probe, finish marker) pair replaces the
          # `bp-runstate.pl status --surface reporter` read entirely (D3).
          # Finish marker checked FIRST -- it ends a run unconditionally,
          # regardless of what the probe says (behaviour 5).
          if _bp_finish_signal "$RDATA/.drive-solo"; then
            rm -f "$RDATA/.reporter-stop-blocks" 2>/dev/null
            exit 0
          fi

          _bp_probe_verdict "$RDATA"
          RPV=$?
          case "$RPV" in
            0)
              rm -f "$RDATA/.reporter-stop-blocks" 2>/dev/null
              exit 0
              ;;
            2)
              echo "butler reporter-gate: allowing this stop -- probe verdict is CANNOT TELL (fail-open)." >&2
              exit 0
              ;;
          esac

          # RPV == 1 (no live watcher, no finish marker): DENY, bounded.
          RBLOCKS=0
          [ -f "$RDATA/.reporter-stop-blocks" ] && RBLOCKS=$(cat "$RDATA/.reporter-stop-blocks" 2>/dev/null || echo 0)
          case "$RBLOCKS" in ''|*[!0-9]*) RBLOCKS=0 ;; esac
          if [ "$RBLOCKS" -ge 3 ]; then
            rm -f "$RDATA/.reporter-stop-blocks" 2>/dev/null
            echo "butler reporter-gate: allowing this stop after $RBLOCKS consecutive blocks." >&2
            exit 0
          fi
          echo $((RBLOCKS + 1)) > "$RDATA/.reporter-stop-blocks" 2>/dev/null
          cat >&2 <<EOF
BLOCKED (butler reporter-gate): nothing will resume observation of this run,
and only the operator can end it.

Two ways to end a turn, and no third:

  1. Arm a bounded watcher around the work, then stop:
       perl plugins/butler/scripts/bp-watch.pl --arm --max-seconds <N> --package <bp>/<pkg> ...
     A live bp-watch.pl is what proves something will resume observation.

  2. The OPERATOR ends the run. There is no verb, flag or argument that does it:
       touch $RDATA/.drive-solo/.run-finished

When the signal is ambiguous, CONTINUE -- wrongly continuing costs some tokens,
wrongly stopping abandons an unattended run with nobody present to notice.

To stop anyway just this once: touch $RDATA/.reporter-stop-ok
EOF
          exit 2
        fi
      fi
    fi
  fi
}
# --- end reporter branch -----------------------------------------------------

[ "${CCPRAXIS_DRIVE_STOP_OK:-}" = "1" ] && exit 0

# --- SCOPING, and it must be cheap for the 99% who are not driving ----------
#
# THE OLD TEST WAS WRONG AND EXPENSIVE. It asked "does an ancestor of my cwd
# contain .ccpraxis-local-data/.drive-solo/order.json". That is yes for every
# session in a tree where drive-solo has EVER run — order.json was never
# deleted when a run finished — and yes for sessions that are not the driver
# at all. Worse, the ancestor walk did not terminate on a Windows drive-letter
# cwd (dirname("C:") == "C:"), so an unrelated session hung here until the
# hook timeout on every single stop.
#
# The right question is "is THIS session driving", and mark-wakeup.sh answers
# it by registering a session the moment it calls the director. This call
# itself is still two stats and no subprocess -- but it is no longer the
# FIRST thing this file does (fixbatch step7 / F3): the reporter-surface
# pre-check above now runs ahead of it, and PAYLOAD/stdin is read once,
# unconditionally, immediately after both cheap pre-checks pass or fail.
# So "nothing is driving anywhere AND no reporter has ever registered" is
# still cheap (a handful of stats, zero forks, no stdin read) -- but "nothing
# is driving, yet some reporter marker exists somewhere on this machine" now
# costs the reporter branch's own subprocess work even though THIS session
# is neither. That is the corrected claim; see the block above this one for
# why it could not be avoided without losing the reporter branch's ability to
# read PAYLOAD at all.
bp_drive_any_active || exit 0

# PAYLOAD was already read once, right after the BP_LEDGER check and the two
# cheap pre-checks above (the reporter branch needs it too, and stdin can
# only be read once) -- reused here rather than re-cat'd.
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
[ -n "$SID" ] || exit 0
MARK=$(bp_drive_marker "$SID" 2>/dev/null) || exit 0
[ -f "$MARK" ] || exit 0

# --- staleness: a driver that died must not gate its session id forever -----
# Belt to the disarm-on-settle braces below. A crashed or killed driver leaves
# its marker behind, and without a TTL that id would be gated until someone
# noticed. Refreshed on every stop of a live driver, so only genuine silence
# ages it out.
TTL_H="${CCPRAXIS_DRIVE_TTL_H:-12}"
case "$TTL_H" in ''|*[!0-9]*) TTL_H=12 ;; esac
MNOW=$(date +%s 2>/dev/null || echo 0)
MMT=$(bp_mtime "$MARK")
if [ "$MNOW" -gt 0 ] && [ "$MMT" -gt 0 ] \
   && [ $(( (MNOW - MMT) / 3600 )) -ge "$TTL_H" ]; then
  bp_drive_retire "$SID" 2>/dev/null || true
  exit 0
fi

# The marker holds the data dir the driver was working in, so this hook needs
# no path walk of its own — the walk that used to be here is the one that hung.
DATA=$(head -n 1 "$MARK" 2>/dev/null || true)
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || { bp_drive_retire "$SID" 2>/dev/null || true; exit 0; }
DS="$DATA/.drive-solo"

# A drive-solo run is only "in progress" once an order has been recorded.
[ -f "$DS/order.json" ] || exit 0

# MAJOR-5/AC11b: suppress the refresh once a finish has already been
# consumed for this session. Without this, a session that keeps producing
# Stops after a genuine finish (an accidental resume, a stray retry) kept
# $MARK perpetually fresh forever -- the TTL reap above could never fire,
# because it only ever sees an mtime from moments ago. Once
# .run-finished.consumed exists, $MARK is left to age on the TTL clock
# measured from the finish itself, so an unattended, already-finished
# session is not gated indefinitely.
[ -f "$DS/.run-finished.consumed" ] || touch "$MARK" 2>/dev/null || true

# --- escape hatch: one-shot, spent on the stop it actually lets through ------
#
# THIS HOOK IS NOT THE ONLY STOP GATE. guard-subagent-stall.sh independently
# blocks whenever it has an unresolved dispatch and neither signal below
# resolves it. The original branch deleted the marker and exited 0, which is
# correct only if exiting 0 ends the turn -- and it does not when the sibling
# blocks. The operator's one-shot token was then spent on a stop that never
# happened, and the next stop -- the one they touched it for -- blocked HERE
# again, demanding a marker they had already provided. Observed 2026-08-24,
# and the loop it creates is closed: consult the director, get reactivated,
# re-finish, lose the token, block again.
#
# So while a sibling gate would still block, PASS WITHOUT CONSUMING and let it
# do its job. The token survives to cover the stop that follows resolution,
# which is the stop the operator meant.
#
# PACKAGE 02 RE-POINT: the predicate "a sibling gate is about to block this
# stop", formerly `bp-runstate.pl status` reporting "active", becomes "the
# probe does not say live AND there is no finish signal" -- which is now
# literally the predicate the sibling gate (guard-subagent-stall.sh) blocks
# on, so the carry is more accurate than it was.
#
# Bounded, because that reasoning leans on a sibling hook actually being
# registered: if none is, nothing else will ever block and an unconsumed marker
# would become a permanent escape hatch rather than a one-shot. After
# STOP_OK_MAX_CARRY carries it is spent regardless, so the degenerate case is
# the old behaviour, not an open gate.
if [ -f "$DS/.stop-ok" ]; then
  _SIBLING_WOULD_BLOCK=""
  # MINOR-1: a non-mutating PREDICATE check here -- _bp_finish_signal
  # consumes the marker, and merely deciding whether to carry a token must
  # not itself spend the operator's other lever as a side effect.
  if _bp_finish_present "$DS"; then
    :   # a finish signal exists -- no sibling would block on this stop
  else
    _bp_probe_verdict "$DATA"
    _pv_rc=$?
    # MAJOR-4: only a DEFINITE "none" (1) predicts a sibling deny. Verdict 2
    # (cannot-tell) ALLOWS in both gates (Decision 3), so treating it as "a
    # sibling would block" carried the token for nothing.
    if [ "$_pv_rc" -eq 1 ]; then
      # ...and only when the sibling (guard-subagent-stall.sh) actually HAS
      # something to block on. An empty/absent pending set is that hook's
      # own INERT condition -- it exits 0 unconditionally in that case -- so
      # a carry is never correct when the sibling is inert. Same path
      # convention as guard-subagent-stall.sh's own STATE_DIR/SESSION
      # (project-local, sanitised the same way).
      _sib_sid="$SID"
      case "$_sib_sid" in
        ''|*[!A-Za-z0-9._-]*) _sib_sid="nosession" ;;
      esac
      _sib_state="$DATA/.subagent-guard/$_sib_sid"
      [ -s "$_sib_state" ] && _SIBLING_WOULD_BLOCK=1
    fi
  fi

  _CARRY=$(cat "$DS/.stop-ok" 2>/dev/null || echo 0)
  case "$_CARRY" in ''|*[!0-9]*) _CARRY=0 ;; esac

  if [ -n "$_SIBLING_WOULD_BLOCK" ] && [ "$_CARRY" -lt "$STOP_OK_MAX_CARRY" ]; then
    # A sibling gate is about to block this stop. Keep the token, count the
    # carry, and clear the nag counter -- this hook is not the one objecting.
    printf '%s\n' "$(( _CARRY + 1 ))" > "$DS/.stop-ok" 2>/dev/null || true
    rm -f "$DS/.stop-blocks" 2>/dev/null
    exit 0
  fi

  rm -f "$DS/.stop-ok" "$DS/.stop-blocks" "$DS/.wakeup-pending" 2>/dev/null
  exit 0
fi

# --- a wake-up is already scheduled: this turn end is legitimate -------------
# mark-wakeup.sh wrote this on a Task dispatch or a backgrounded Bash call.
# CONSUME it: the next turn must schedule its own wake-up or settle the run.
if [ -f "$DS/.wakeup-pending" ]; then
  rm -f "$DS/.wakeup-pending" "$DS/.stop-blocks" 2>/dev/null
  exit 0
fi

# --- bounded nagging --------------------------------------------------------
BLOCKS=0
[ -f "$DS/.stop-blocks" ] && BLOCKS=$(cat "$DS/.stop-blocks" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge "$MAX_BLOCKS" ]; then
  rm -f "$DS/.stop-blocks" 2>/dev/null
  echo "butler drive-loop: allowing this stop after $BLOCKS consecutive blocks — the loop is not advancing and a gate that will not yield is worse than a stalled run. Re-invoke /butler:drive-solo to resume; the director is stateless-from-disk and resumes losslessly." >&2
  exit 0
fi

# --- PACKAGE 02: the (probe, finish marker) pair replaces the director -------
#
# THE DIRECTOR CALL IS REMOVED (D1, Decision 23). `bp-drive-next.pl next`'s
# `done` verdict was an AGENT-REACHABLE path that ended a run -- the director
# computes `done` from ledgers the agent itself writes, so `action:done ->
# exit 0` was the "second door" Decision 23 forbids. Its `pause` verdict falls
# with it (same call). The disarm that used to live in the `done` arm moves to
# the marker path below; a usage/token pause now simply denies up to
# MAX_BLOCKS and is then allowed by the yield above, same as any other stall.
#
# Finish marker checked FIRST -- it ends a run unconditionally, regardless of
# what the probe says (behaviour 5). Clears the block/wakeup bookkeeping.
# $MARK (the session's own driver-registry entry) is deliberately NOT removed
# here, unlike a literal reading of the spec's disarm list: AC9 requires a
# LATER stop from this same session, once the finish marker's grace window
# has passed with nothing new, to still be evaluated and DENIED -- which is
# only possible if the session stays in scope. $MARK still ages out via the
# existing TTL reap above if the session never returns, so nothing is
# stranded; a later /butler:drive-solo re-arms it regardless.
#
# DRIVER AMENDMENT (2026-09-23), 06-drive-solo-marker-retirement, D-E note.
# This restraint's CODE is untouched -- no retirement call sits anywhere
# between _bp_finish_signal above and its exit 0 below -- but its GUARANTEE
# is deliberately ended for a session that reaches drive-solo/SKILL.md's
# documented `done` row, because that row now runs the retire sentinel as the
# session's own last act (06-drive-solo-marker-retirement). Once that
# session's $MARK has been renamed aside by the shared retire primitive
# above, a LATER stop from it never reaches this branch at all -- it falls
# out at :342's
# `[ -f "$MARK" ]` check first, well before the finish marker is even looked
# at. That is intended, not a regression of AC9: a session that has
# explicitly retired no longer needs this branch's later-stop coverage, only
# a session that reaches .run-finished WITHOUT ever running the sentinel
# does.
if _bp_finish_signal "$DS"; then
  rm -f "$DS/.stop-blocks" "$DS/.wakeup-pending" 2>/dev/null
  echo "butler drive-loop: allowing this stop -- the operator's .run-finished marker ended the run." >&2
  exit 0
fi

_bp_probe_verdict "$DATA"
PV=$?
case "$PV" in
  0)
    # A live bounded watcher is CONFIRMED. Allow the stop; do not fall
    # through to BLOCK.
    rm -f "$DS/.stop-blocks" 2>/dev/null
    exit 0
    ;;
  2)
    # Cannot tell -- fail open (Decision 3), but .stop-blocks is NOT reset:
    # an indeterminate verdict resolves nothing.
    echo "butler drive-loop: allowing this stop -- probe verdict is CANNOT TELL (fail-open)." >&2
    exit 0
    ;;
esac

# --- probe says NONE, and nothing will wake us: BLOCK ------------------------
echo $((BLOCKS + 1)) > "$DS/.stop-blocks" 2>/dev/null

# KEEP THIS SHORT -- see the matching note in guard-subagent-stall.sh. This
# fires repeatedly in a long run and the rationale is already in this file's
# header and in drive-solo/SKILL.md.
cat >&2 <<EOF
BLOCKED (butler drive-loop): nothing will wake this session, and only the operator can end the run.

Two ways to end a turn, and no third:

  1. Arm a bounded watcher around the work, then stop:
       perl plugins/butler/scripts/bp-watch.pl --arm --max-seconds <N> --package <bp>/<pkg> ...
     A live bp-watch.pl is what proves something will wake this session.

  2. The OPERATOR ends the run. There is no verb, flag or argument that does it:
       touch $DS/.run-finished

When the signal is ambiguous, CONTINUE -- wrongly continuing costs some tokens,
wrongly stopping abandons an unattended run with nobody present to notice.

To stop anyway just this once: touch $DS/.stop-ok
(Blocks at most $MAX_BLOCKS times in a row.)
EOF
exit 2
