#!/usr/bin/env bash
# guard-subagent-stall.sh — refuse to end a turn that dispatched a background
# subagent without arming a stall guard for it.
#
# WHY THIS EXISTS
#
# A background subagent that hangs or dies silently never wakes the session. The
# harness notifies on completion; it does not notify on "never completed". So an
# unattended run dispatches a worker, ends the turn, and simply stops — and the
# operator finds it hours later. This has happened repeatedly, and the fix was
# repeatedly written down as guidance: dispatch, then arm a bounded guard.
#
# Guidance did not hold. That is not a surprise in this repo: guard-git-mutations.sh
# exists because a prohibited `git stash` destroyed a completed fix-batch that a
# written instruction was supposed to protect. The thesis there applies here —
# A WRITTEN INSTRUCTION IS NOT AN ENFORCEMENT MECHANISM. So this is a gate.
#
# HOW IT WORKS — THE LIVE-PROCESS PROBE + THE OPERATOR'S OWN MARKER, NOT A
# STATE MACHINE
#
# Three earlier versions of this gate all asked the same kind of question --
# does the agent's BEHAVIOUR suggest something is in flight? -- and were wrong
# in the same shape. The first cleared the alarm when a Bash command merely
# CONTAINED a token, so a guard that died on launch satisfied it: ceremony,
# not function. The second read the closing prose for "next I'll ...", which
# can be sidestepped by rephrasing a sentence. The third replaced both with a
# state machine (bp-runstate.pl activate/pause/finish): better, but still a
# claim about intent, mediated by a RECORD the guarded party itself wrote and
# could leave stale. A detector -- or a self-written record -- is only ever as
# good as its guesses.
#
# So the default is inverted, and the resolution no longer reads anything the
# agent can write. The gate is INERT until a run demonstrably starts, and from
# then on the turn may not end until one of exactly two signals resolves it --
# see package 02's spec (02-gates-use-the-probe-spec.md §1) for the full
# argument for why a live-process probe is not a fourth failed detector:
#
#   PostToolUse/Task  — a background dispatch ACTIVATES the run (and is
#                       recorded by name, so the denial can name it).
#   PostToolUse/Bash  — a director tick whose RESPONSE handed back work also
#                       activates. Activation is never something the agent must
#                       remember to do.
#   Stop              — pending dispatch? DENY, unless package 01's live-
#                       process PROBE (bp-watch.pl probe) finds a genuinely
#                       live, armed, unexpired watcher for this project, or
#                       the OPERATOR's own one-shot .run-finished marker is
#                       present. This file never creates the marker itself,
#                       and the probe now additionally requires a
#                       pid-fingerprinted arm-registry entry that only the
#                       real --arm code path writes (bp-watch.pl, BLOCKER-1
#                       fix) and guard-run-finish.sh requires operator
#                       authorisation, found in the transcript, before a
#                       Bash command may create the marker at all
#                       (BLOCKER-2 fix) — both close the CASUAL, one-command
#                       forgeries a red-team review found.
#
# NEITHER SIGNAL IS A SECURITY BOUNDARY, and cannot be one — same posture as
# gate-continuity.sh's own header states plainly: an agent that has decided
# to defeat this can always edit the hook files or hooks.json directly, the
# same way it always could. What these two signals ARE is something an
# ordinary, well-intentioned agent's own behaviour cannot produce by
# accident — silence is not a resolution, and neither is a plausible
# sentence, so there is nothing here for an UNREMARKABLE turn to assert and
# nothing that can go stale the way a self-written record could.
#
# DELIBERATELY NOT GATED. There is no bp_hook_gate call here, by design and for
# the same reason guard-git-mutations.sh has none: bp_hook_gate exits 0 unless
# BP_LEDGER/BP_DIR/BP_PROJECT_ROOT are set, and those are exported only by
# bp-launch.sh into headless coordinators. A drive-solo run — the exact place
# subagents are dispatched by hand and the exact place this failure has bitten —
# would open the gate and enforce nothing. See coordinator-protocol/SKILL.md,
# "…but only inside a butler-LAUNCHED coordinator".
#
# FAIL-OPEN, ON PURPOSE. Every unexpected condition (no JSON parser, unwritable
# state dir, unreadable payload) exits 0 and allows the turn to end. A guard that
# can wedge a session is worse than the stall it prevents: the stall costs
# latency, a wedge costs the run. The one thing it will not do is fail open
# SILENTLY on the case it exists for — a pending dispatch always denies.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate here, by design (see above).
source "$HOOK_DIR/lib.sh"

bp_read_payload open
[ -n "$PAYLOAD" ] || exit 0

EVENT=$(bp_json_get "$PAYLOAD" hook_event_name) || exit 0
SESSION=$(bp_json_get "$PAYLOAD" session_id) || SESSION=""
[ -n "$SESSION" ] || SESSION="nosession"
# Session ids are uuid-shaped; refuse anything else rather than build a path
# from unvalidated input.
case "$SESSION" in
  *[!A-Za-z0-9._-]*) SESSION="nosession" ;;
esac

# State lives beside the project's other local data, never in the repo proper.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../../.." && pwd)}"
STATE_DIR="$ROOT/.ccpraxis-local-data/.subagent-guard"
STATE="$STATE_DIR/$SESSION"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

case "$EVENT" in
  PostToolUse)
    TOOL=$(bp_json_get "$PAYLOAD" tool_name) || exit 0
    case "$TOOL" in
      Task|Agent)
        # Only BACKGROUND dispatches can strand the session. A synchronous run
        # (run_in_background:false) holds the turn open, so the harness is still
        # waiting and a hang is visible. The Agent tool defaults to background,
        # so absence of the field counts as background.
        #
        # bp_json_get CANNOT answer this one: it yields the first NON-EMPTY
        # scalar, so a JSON `false` and an absent key both come back empty, and
        # every synchronous dispatch would be recorded as background. This needs
        # a tri-state read — true / false / absent — so it gets its own decode.
        #
        # Undeterminable (no perl, unparseable payload) is treated as BACKGROUND,
        # i.e. a guard is required. That is the safe direction for THIS decision
        # even though the hook is fail-open overall: guessing "synchronous" would
        # silently disable the gate, which is the defect, not a degradation of it.
        BG=$(printf '%s' "$PAYLOAD" | perl -MJSON::PP -0777 -ne '
            my $j = eval { JSON::PP->new->decode($_) } or exit 0;
            my $v = eval { $j->{tool_input}{run_in_background} };
            exit 0 unless defined $v;
            print( (ref $v ? !!$v : ($v ne "" && $v ne "0" && $v ne "false")) ? "true" : "false" );
        ' 2>/dev/null) || BG=""
        [ "$BG" = "false" ] && exit 0
        DESC=$(bp_json_get "$PAYLOAD" tool_input.description) || DESC="(unnamed)"
        # RECORD the observable fact that a run started, in the file this
        # hook already owns. Recording must never be a thing the agent
        # remembers to do -- anything it must remember is a thing it will
        # eventually forget, which is the entire reason this gate exists.
        # (Package 02: no longer relayed to bp-runstate.pl -- this file's own
        # pending set IS the record now; see the Stop block below.)
        printf '%s\n' "$DESC" >> "$STATE" 2>/dev/null || true
        exit 0
        ;;
      Bash)
        # NOTHING is cleared here, deliberately.
        #
        # The first version of this hook cleared the pending set when it saw a
        # Bash command containing the token BP_STALL_GUARD. That verified
        # CEREMONY, NOT FUNCTION: a guard that exits immediately, watches the
        # wrong path, or is syntactically broken contains the token just as well
        # as a working one. It is the same vacuity trap this repo keeps paying
        # for -- a check that cannot fail (see bp-ledger.pl's
        # INSTALLED+SKIPPED+FAILED==ITEMS identity, package a03).
        #
        # A guard now proves itself instead, through package 01's live-process
        # PROBE, which only reports a watcher LIVE when a real, armed,
        # unexpired bp-watch.pl process actually exists in /proc -- there is
        # no record to write and nothing to refuse; a process either is there
        # or it is not. Ceremony cannot satisfy it.
        #
        # What DOES happen here is the second activation trigger: a director
        # tick that handed back work means a run is underway, whether or not a
        # subagent was dispatched. Reading the RESPONSE (not the command) is
        # deliberate -- the command only says what was asked, the response says
        # what came back.
        #
        # `run-package` ONLY. `need-order` used to activate here too, and that
        # was wrong in a way that produced a closed loop.
        #
        # `need-order` is not work handed back -- it is the director DECLINING
        # to choose, because the answer belongs to the operator (e.g. two
        # delivered blueprints and no order covering them: `scope-extends-order`).
        # Nothing is underway, so there is nothing for a Stop gate to protect.
        # Worse: an agent that consults the director to CHECK whether anything
        # is pending was reactivating the very run it had just finished. The
        # diagnostic mutated the thing being diagnosed, and the session could
        # not leave: finish -> consult -> reactivate -> blocked stop -> finish.
        # Observed 2026-08-24.
        #
        # This loses nothing. When a drive is genuinely underway and hits
        # need-order, the run is ALREADY active and activation is a no-op --
        # activation only has an effect on a run that is idle or finished, and
        # that is exactly the false positive.
        # ...but the response alone is NOT ENOUGH, and reading it alone was a
        # third bug of the same family, observed the same day.
        #
        # This matched the TEXT of any Bash output. So a command that merely
        # PRINTED the pattern activated a run: a grep over this hook's own
        # source, a `cat` of it, a test run echoing its fixtures, a commit
        # message quoting it. Investigating the escalation machinery started a
        # run about the escalation machinery -- and the session then could not
        # end, because a diagnostic had manufactured the state the Stop gate
        # exists to protect.
        #
        # That is exactly the class filed as almanac 20260819-054052-1168:
        # butler guard hooks that mention-match raw command text with no reader
        # veto. The veto here is cheap and exact -- the ONLY producer of these
        # verdicts as a Bash tool call is bp-drive-next.pl. (The orchestrator and
        # gate-drive-loop.sh both invoke it in-process, so neither surfaces as a
        # tool event and neither is affected.)
        #
        # Response AND command, not either: the command says what was asked, the
        # response says what came back, and activation needs both to be true.
        # Keeping the response check is what stops a mere ASK from activating.
        # Covers all three on-PATH spellings package 04-bp-on-path put into
        # circulation for this command (fix-batch B1, red-team HIGH-1): the
        # perl form (bp-drive-next.pl), the .sh shim (bp-drive-next.sh), and
        # -- non-Windows installs only -- the extensionless alias
        # (bp-drive-next), which must be matched as a whole word (a trailing
        # space or end-of-string) so it does not also swallow an unrelated
        # command that merely starts with the same prefix.
        CMD=$(bp_json_get "$PAYLOAD" tool_input.command) || CMD=""
        case "$CMD" in
          *bp-drive-next.pl*|*bp-drive-next.sh*|*bp-drive-next\ *|*bp-drive-next) ;;
          *) exit 0 ;;
        esac
        RESP=$(bp_json_get "$PAYLOAD" tool_response.stdout tool_response) || RESP=""
        case "$RESP" in
          *'"action":"run-package"'*)
            printf '%s\n' "director handed back work" >> "$STATE" 2>/dev/null || true
            ;;
        esac
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;

  Stop)
    # THE GATE. Inert until a run starts; once a dispatch is pending, the turn
    # may not end until either a live bounded watcher (the PROBE) or the
    # operator's own finish marker resolves it. See package 01's
    # bp-watch.pl and this package's spec (02-gates-use-the-probe) for why a
    # live-process check replaced the earlier bp-runstate.pl state machine,
    # which itself replaced two failed detectors: one matched a magic token
    # in a Bash command (ceremony, not function), one matched the assistant's
    # closing prose (sidestepped by rephrasing a sentence). A detector is only
    # as good as its guesses; a process either exists or it does not.
    # THE PENDING SET IS CLEARED WHEN THE TURN IS ALLOWED TO END, AND ONLY THEN.
    #
    # Closes almanac report 20260819-014748-0b41, filed against this hook: the
    # state file was append-only and nothing ever truncated it, so the denial
    # message below listed EVERY background dispatch of the whole session under
    # the heading "this turn". By the end of a long unattended run that is fifty
    # entries, most of them hours old and already resolved -- noise that buries
    # the two lines an operator actually needs to read.
    #
    # It is the same shape as the defect package t07 exists to fix in
    # runs/escalations/: broad write, no clear. The rule that resolves both is the
    # same one -- clear when the thing the record was tracking is demonstrably
    # over -- and here that moment is unambiguous: an ALLOWED Stop means the run
    # was resolved (a live watcher proven by the probe, or the operator's own
    # finish marker), so every dispatch recorded up to now is accounted for.
    #
    # DELIBERATELY NOT CLEARED ON A DENIED STOP. A dispatch made two turns ago
    # and still unresolved is still unresolved, and dropping it would hide
    # exactly the thing this hook exists to surface. That is why the heading now
    # says "since the last resolved turn" rather than "this turn" -- the old
    # wording was a second, smaller defect in the same report: it described a
    # window the file never had.
    _clear_pending() { : > "$STATE" 2>/dev/null || true; }

    # ONE-SHOT, CONSUMED ON USE -- it was not, and that was a trap.
    #
    # Until 2026-09-18 this only tested for the file and never removed it, so a
    # single touch disabled this guard PERMANENTLY, silently, for every later
    # turn and every later run in the project. Nothing said so: the denial text
    # below advertises the override as the way out of one blocked stop, and its
    # sibling lever on gate-drive-loop.sh (.stop-ok) genuinely IS one-shot. Two
    # sibling gates, opposite lifetimes, and the dangerous one was the quiet one.
    #
    # Found the way these things usually are -- by using it. The override was
    # touched to end one turn, and the guard stayed inert for the rest of the
    # session until someone thought to look.
    #
    # Consuming it makes the override mean what it says: this stop is allowed.
    # Wanting the next one allowed is a decision worth making again.
    if [ -f "$STATE_DIR/force-stop" ]; then
        rm -f "$STATE_DIR/force-stop" 2>/dev/null || true
        # NOT cleared here (deviates from a literal "clear $STATE" reading of
        # the spec's step 1): AC15 requires the NEXT stop, with the same
        # unresolved pending set, to be denied again -- force-stop overrides
        # exactly the one stop it is spent on, not the record of what is
        # still unresolved. Confirmed against t/subagent-stall-guard.t's
        # "the NEXT stop is gated again" assertion.
        exit 0
    fi

    # THE INERT CONDITION. An empty or absent pending set means no background
    # dispatch is unresolved, so there is nothing for this gate to protect --
    # a scope test, not a verdict about a run in flight. Replaces the old
    # `bp-runstate.pl status` read entirely (package 02, Decision 2/3).
    if [ ! -s "$STATE" ]; then
        _clear_pending
        exit 0
    fi

    # THE THIRD EXIT: THERE IS NO WORK, ANYWHERE.
    #
    # This gate's two resolutions are a live bounded watcher (the probe) and
    # the operator's own finish marker. Neither is reachable when every
    # package of every non-archived blueprint is already terminal -- there is
    # nothing left for a watcher to be watching and nothing left to finish.
    # What would be left, without this exit, is the one-shot override, every
    # turn, which is a permanent bypass wearing a one-shot label.
    #
    # Measured 2026-09-18: the override was used four times across consecutive
    # turns with zero dispatches outstanding, zero background processes and zero
    # open bug reports, because `finish` was refused on a stale drive marker.
    # Report 20260918-134732-acfd. gate-continuity.sh got this same third exit
    # in 1dda97d; leaving it off THIS gate left the trap fully intact, which is
    # what the operator saw when it kept firing after that fix.
    #
    # KEPT VERBATIM through package 02 (spec §5.1): removing it turns two
    # assertions red in continuity-gate-idle-exit.t, which is outside this
    # write set, and it is classifiable as SCOPE ("no run is in flight
    # anywhere") rather than a verdict about a run mid-flight.
    if [ -z "${CCPRAXIS_STALL_SKIP_IDLE_EXIT:-}" ] && command -v bp_outstanding_work >/dev/null 2>&1; then
      _sg_rl=1
      bp_drive_any_active 2>/dev/null || _sg_rl=0
      if [ -z "$(bp_outstanding_work "$_sg_rl" 2>/dev/null)" ]; then
        _clear_pending
        echo "butler subagent-stall gate: allowing this stop -- no outstanding work. Every package of every non-archived blueprint is at a terminal status, so there is nothing a watcher could name and nothing a dispatch could still be doing for it. NOTE: this is a THIRD, agent-reachable exit (inferred from ledgers the agent itself writes) alongside the two named in the BLOCKED text below -- kept deliberately (spec 02-gates-use-the-probe §5.1) as a project-wide SCOPE check, not a verdict about a run mid-flight, so the denial's 'no third' wording is about THAT distinction, not a claim this exit does not exist." >&2
        exit 0
      fi
    fi

    # SIGNAL B -- THE FINISH MARKER (spec §2.1, Decisions 7/16). Checked
    # BEFORE the probe: only the operator can create this file (neither hook
    # ever does -- AC19), so it ends a run unconditionally, regardless of what
    # the probe would say. ONE-SHOT: consumed by renaming to .consumed with a
    # 15s grace window, so a second Stop hook firing on the SAME Stop event
    # (four Stop hooks fire on one event, from two registration files --
    # Decision 17) still sees it as fresh, without a second hook able to
    # re-spend it on a later, unrelated stop.
    FINISH_GRACE_S=15
    # MAJOR-1 (fix-batch 1): the earlier `<=`->`<` tie-break compared $STATE's
    # mtime against the marker's CONSUMPTION time, not the OPERATOR's own
    # touch time -- and $STATE is normally appended by PostToolUse/Task an
    # instant before the Stop that follows a dispatch, so on the operator's
    # own legitimate finish path those two mtimes land in the SAME
    # wall-clock second as the common case, not a rare race. The strict "<"
    # then wrongly denied the operator's own finish. Fixed by capturing the
    # marker's OWN pre-consumption mtime (the operator's touch epoch) into
    # the consumed record's CONTENTS, and comparing $STATE against THAT,
    # instead of against the (later, hook-dependent) consumption time.
    _bp_finish_signal() {
        local _fs_ds="$1"
        if [ -f "$_fs_ds/.run-finished" ]; then
            local _fs_touch_epoch
            _fs_touch_epoch=$(bp_mtime "$_fs_ds/.run-finished")
            mv -f "$_fs_ds/.run-finished" "$_fs_ds/.run-finished.consumed" 2>/dev/null \
              || rm -f "$_fs_ds/.run-finished" 2>/dev/null
            if [ -f "$_fs_ds/.run-finished.consumed" ]; then
                # The touch epoch lives in the consumed record's CONTENTS --
                # mtime alone cannot distinguish "operator touched at T" from
                # "a hook consumed it at T+epsilon".
                printf '%s\n' "$_fs_touch_epoch" > "$_fs_ds/.run-finished.consumed" 2>/dev/null || true
                touch "$_fs_ds/.run-finished.consumed" 2>/dev/null || true
            else
                # MAJOR-3: both mv and rm failed -- the one-shot marker was
                # NOT consumed (a held file handle, a read-only dir, ...).
                # Allow THIS stop anyway (fail-open, Decision 3), but never
                # again silently: an un-consumable marker is a project-wide,
                # permanent bypass if nobody is told.
                echo "butler subagent-stall gate: WARNING -- $_fs_ds/.run-finished could not be consumed (rename and delete both failed). The one-shot finish marker was NOT spent; investigate a held file handle or permissions at that path." >&2
            fi
            return 0
        fi
        if [ -f "$_fs_ds/.run-finished.consumed" ]; then
            local _fs_now _fs_mt _fs_smt _fs_touch_epoch _fs_age
            _fs_now=$(date +%s 2>/dev/null || echo 0)
            _fs_mt=$(bp_mtime "$_fs_ds/.run-finished.consumed")
            _fs_smt=$(bp_mtime "$STATE")
            _fs_touch_epoch=$(head -n 1 "$_fs_ds/.run-finished.consumed" 2>/dev/null)
            case "$_fs_touch_epoch" in ''|*[!0-9]*) _fs_touch_epoch=0 ;; esac
            if [ "$_fs_now" -gt 0 ] && [ "$_fs_mt" -gt 0 ]; then
                _fs_age=$(( _fs_now - _fs_mt ))
                if [ "$_fs_age" -lt 0 ]; then
                    # MAJOR-2: a future mtime (clock skew, or `mv` preserving
                    # a future source mtime) must not become an unbounded
                    # grant -- "cannot tell -> no grace", not "always < 15".
                    echo "butler subagent-stall gate: .run-finished.consumed has a future mtime -- cannot judge the grace window, treating it as expired." >&2
                elif [ "$_fs_age" -lt "$FINISH_GRACE_S" ]; then
                    # THIS HOOK'S OWN NARROWING, not part of the shared
                    # pseudocode: the grace window exists so SIBLING Stop
                    # hooks firing on the SAME Stop event still see a
                    # just-consumed marker as fresh (Decision 17: four Stop
                    # hooks fire on one event). It must NOT also wave through
                    # a LATER, genuinely different Stop for a dispatch that
                    # did not exist when the OPERATOR touched the marker --
                    # $STATE is this hook's own record of what is pending,
                    # so if it was written strictly AFTER the operator's own
                    # touch, it postdates (and cannot have been resolved by)
                    # that touch. A tie, or an epoch this hook cannot read,
                    # resolves toward ALLOW (Decision 23's own asymmetry:
                    # denying here destroys an operator lever and forces a
                    # re-touch, while over-granting a few seconds of grace
                    # costs at most one extra stop).
                    if [ "$_fs_touch_epoch" -le 0 ] || [ "$_fs_smt" -le "$_fs_touch_epoch" ]; then
                        return 0
                    fi
                fi
            fi
        fi
        return 1
    }
    if _bp_finish_signal "$ROOT/.ccpraxis-local-data/.drive-solo"; then
        _clear_pending
        echo "butler subagent-stall gate: allowing this stop -- the operator's .run-finished marker ended the run." >&2
        exit 0
    fi

    # SIGNAL A -- THE LIVE-PROCESS PROBE (spec §2.1, package 01's
    # bp-watch.pl probe). Local copy, not shared via lib.sh (write-set
    # boundary; gate-drive-loop.sh already duplicates its own bounded-
    # timeout block for the identical reason). Only exit 0/1 are trusted;
    # every other code -- missing script, missing perl, a timeout, anything
    # unforeseen -- maps to 2 = cannot tell, and 2 ALLOWS (Decision 3). No
    # code-list special-casing: package 01's own red-team MAJOR-2 was a
    # consumer that special-cased a code list and silently misbehaved on
    # everything outside it.
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
            # ⚠ MUST FORK, NOT EXEC -- alarm() does not bound an exec'd child
            # under Git-for-Windows perl (measured: a 60s child ran the full
            # 60s under `perl -e 'alarm N; exec @ARGV'`). Forking and killing
            # the child from the parent's SIGALRM handler bounds it correctly.
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

    # THE DISPATCH-LOG CROSS-CHECK (spec 05-subagent-stall-guard-accuracy
    # §2.1/§2.2). Called ONLY from the denial path below, between PENDING and
    # the heredoc (D-A): every allow path above this point returns before
    # this function is ever referenced, so it spawns nothing on the
    # overwhelmingly common turn. Its stdout INFORMS the denial message; it
    # NEVER moves the verdict in either direction (D-B) -- callers must not
    # branch on its return code, and it always returns 0. A stale record
    # still counts as outstanding and is labelled, never discounted (D-D).
    # Every failure mode (missing script, missing perl, timeout, exit 4,
    # unparseable output) degrades to the same "unavailable" section (D-F) --
    # this function can change what the message says, never whether the stop
    # is denied.
    _bp_outstanding_report() {
        local _or_root="$1"
        local _or_script="$HOOK_DIR/../scripts/bp-dispatch-log.pl"

        if [ ! -r "$_or_script" ]; then
            echo "Dispatch log: cross-check unavailable (script not readable) -- the pending set above is the whole record."
            return 0
        fi
        if ! command -v perl >/dev/null 2>&1; then
            echo "Dispatch log: cross-check unavailable (no perl) -- the pending set above is the whole record."
            return 0
        fi

        # MEDIUM-2 (redteam) -- a command-substitution PIPE waits for EOF, not
        # for the query's own exit: a descendant that inherits stdout and
        # survives past the `timeout`/SIGALRM kill can hold the pipe open and
        # block this hook indefinitely (measured: a 3s bound blocked 25s
        # against a stdout-holding grandchild). Redirecting to a regular file
        # instead cannot block on a surviving writer the same way, so the
        # query's output is captured there and read back afterward.
        local _or_tmp
        _or_tmp=$(mktemp 2>/dev/null) || _or_tmp=""
        if [ -z "$_or_tmp" ]; then
            echo "Dispatch log: cross-check unavailable (query failed or timed out) -- the pending set above is the whole record."
            return 0
        fi

        local _or_rc
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 perl "$_or_script" outstanding --root "$_or_root" >"$_or_tmp" 2>/dev/null
            _or_rc=$?
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 10 perl "$_or_script" outstanding --root "$_or_root" >"$_or_tmp" 2>/dev/null
            _or_rc=$?
        else
            # Same fork+SIGALRM shape as _bp_probe_verdict, copied rather than
            # reinvented: alarm() does not bound an exec'd child under
            # Git-for-Windows perl (measured there).
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
              ' perl "$_or_script" outstanding --root "$_or_root" >"$_or_tmp" 2>/dev/null
            _or_rc=$?
        fi

        # CRITICAL-1 (redteam) -- cap the read at 65536 bytes IMMEDIATELY,
        # before any parsing touches it. Unbounded, a crafted multi-megabyte
        # record drove the bash-side printf|grep|sed/while-read parse past
        # the harness's own hook timeout (measured: ~2MB -> 14.4s wall time;
        # 10.2MB -> 68.2s, past a 60s default timeout) -- a timeout CANCELS
        # this hook before its `exit 2` runs, which is the exact DENY-to-
        # ALLOW flip D-B forbids. Reading from the file (not the pipe) also
        # closes MEDIUM-2 above.
        local _or_out
        _or_out=$(head -c 65536 "$_or_tmp" 2>/dev/null)
        rm -f "$_or_tmp" 2>/dev/null

        # SHOULD-2 (review) -- a timed-out query must be caught by EXIT CODE,
        # not inferred from output shape: bp-dispatch-log.pl prints its
        # count lines before any row, so a capture killed mid-stream can
        # still contain a parseable outstanding_count and would otherwise
        # render as a successful section (b) instead of the promised
        # section (c). timeout/gtimeout and the fork+SIGALRM fallback all
        # use exit code 124 for a timeout (D-F's rule that 0/1/4 are never
        # used to classify is unaffected -- this only special-cases 124).
        if [ "$_or_rc" = "124" ]; then
            echo "Dispatch log: cross-check unavailable (query failed or timed out) -- the pending set above is the whole record."
            return 0
        fi

        # Classification from here on is by PARSED OUTPUT ONLY (D-F / spec
        # §2.1 step 2) -- exit 1 is the verb's own normal "something is
        # outstanding" code, so it must never be mistaken for a failure. An
        # empty capture is the one case with nothing to parse at all.
        if [ -z "$_or_out" ]; then
            echo "Dispatch log: cross-check unavailable (query failed or timed out) -- the pending set above is the whole record."
            return 0
        fi

        local _or_count
        _or_count=$(printf '%s\n' "$_or_out" | grep -m1 '^outstanding_count:' | sed 's/^outstanding_count:[[:space:]]*//')
        case "$_or_count" in
            ''|*[!0-9]*)
                # Absent, non-numeric, or the literal "unknown" exit-4 prints
                # all land here.
                echo "Dispatch log: cross-check unavailable (output not understood) -- the pending set above is the whole record."
                return 0
                ;;
        esac
        # LOW-3 (redteam) -- strip leading zeros before every arithmetic
        # test below. A value like "08" is invalid octal to `[ -gt ]`, which
        # aborts the test silently (swallowed by the surrounding 2>/dev/null
        # elsewhere in this function) and can suppress the STALE sentence
        # without anyone noticing. Applied defensively to every count read
        # out of the query's output.
        _or_count=${_or_count#"${_or_count%%[!0]*}"}
        [ -n "$_or_count" ] || _or_count=0

        if [ "$_or_count" -eq 0 ]; then
            echo "Dispatch log (bp-dispatch-log.pl outstanding): 0 records outstanding."
            echo "  The pending entries above were never recorded there, or were resolved without this gate being"
            echo "  told. That is NOT a resolution -- this gate's record is the pending set above, not the log."
            return 0
        fi

        local _or_live _or_stale _or_uneval _or_unread
        _or_live=$(printf '%s\n' "$_or_out" | grep -m1 '^live_count:' | sed 's/^live_count:[[:space:]]*//')
        case "$_or_live" in ''|*[!0-9]*) _or_live=0 ;; esac
        _or_live=${_or_live#"${_or_live%%[!0]*}"}; [ -n "$_or_live" ] || _or_live=0
        _or_stale=$(printf '%s\n' "$_or_out" | grep -m1 '^stale_count:' | sed 's/^stale_count:[[:space:]]*//')
        case "$_or_stale" in ''|*[!0-9]*) _or_stale=0 ;; esac
        _or_stale=${_or_stale#"${_or_stale%%[!0]*}"}; [ -n "$_or_stale" ] || _or_stale=0
        _or_uneval=$(printf '%s\n' "$_or_out" | grep -m1 '^unevaluable_count:' | sed 's/^unevaluable_count:[[:space:]]*//')
        case "$_or_uneval" in ''|*[!0-9]*) _or_uneval=0 ;; esac
        _or_uneval=${_or_uneval#"${_or_uneval%%[!0]*}"}; [ -n "$_or_uneval" ] || _or_uneval=0
        _or_unread=$(printf '%s\n' "$_or_out" | grep -m1 '^unreadable_count:' | sed 's/^unreadable_count:[[:space:]]*//')
        case "$_or_unread" in ''|*[!0-9]*) _or_unread=0 ;; esac
        _or_unread=${_or_unread#"${_or_unread%%[!0]*}"}; [ -n "$_or_unread" ] || _or_unread=0

        echo "Dispatch log (bp-dispatch-log.pl outstanding): $_or_count outstanding ($_or_live live, $_or_stale stale, $_or_uneval unevaluable, $_or_unread unreadable)."

        # Rows are parsed by KEY=VALUE TOKEN, not by position (spec §2.2), and
        # rendered oldest-first exactly as the verb already sorted them
        # (:1482) -- up to 5, then an overflow line. Fed via process
        # substitution, not a heredoc, so a hostile field value containing
        # `$` or a backtick is never re-interpreted by the shell (edge case
        # 4): it is captured once into $_or_out (now capped at 65536 bytes)
        # and only ever handed to printf/read as data.
        #
        # NIT-2 (review): blueprint=/package= (unlike id=) are NOT
        # shape-validated at the writer (bp-dispatch-log.pl validates id
        # only) -- a value rendered below is untrusted display text, not a
        # validated field. Do not mistake it for one when reading this.
        #
        # LOW-1 (redteam): `for tok in $rest` performs pathname expansion
        # against THIS HOOK'S OWN CWD when a field value contains a glob
        # character (e.g. worker_type="a *"). `set -f` brackets every such
        # loop so no field value is ever glob-expanded.
        local _or_shown=0
        local _or_line _or_rest _or_tok _or_idcount
        local _or_id _or_wt _or_bp _or_pkg _or_elapsed _or_stale_flag _or_label
        while IFS= read -r _or_line; do
            case "$_or_line" in
                "outstanding: "*) ;;
                *) continue ;;
            esac
            _or_rest="${_or_line#outstanding: }"

            # MEDIUM-1(a)/(b) (redteam), partial shell-side hardening: reject
            # any outstanding: line that does not carry EXACTLY ONE id=
            # token. Closes the crudest forgeries (an injected line with
            # zero or multiple id= tokens) -- it does NOT close a within-cap
            # single-line field forgery (e.g. an embedded literal newline
            # manufacturing a counterfeit stale=/id= token), which needs
            # reader-side shape validation in bp-dispatch-log.pl itself and
            # is recorded as an accepted residual in this package's spec §7
            # driver amendment (out of this write set).
            _or_idcount=0
            set -f
            for _or_tok in $_or_rest; do
                case "$_or_tok" in
                    id=*) _or_idcount=$((_or_idcount + 1)) ;;
                esac
            done
            set +f
            [ "$_or_idcount" -eq 1 ] || continue

            _or_shown=$((_or_shown + 1))
            # CRITICAL-1: break, not continue, once 5 rows have been
            # rendered -- the overflow count below is derived from the
            # header's own outstanding_count, never from a count of parsed/
            # rendered lines, so there is no need to keep scanning the rest
            # of the (now-capped) capture.
            [ "$_or_shown" -gt 5 ] && break

            _or_id="" _or_wt="" _or_bp="" _or_pkg="" _or_elapsed="" _or_stale_flag=""
            set -f
            for _or_tok in $_or_rest; do
                case "$_or_tok" in
                    id=*)              _or_id="${_or_tok#id=}" ;;
                    worker_type=*)     _or_wt="${_or_tok#worker_type=}" ;;
                    blueprint=*)       _or_bp="${_or_tok#blueprint=}" ;;
                    package=*)         _or_pkg="${_or_tok#package=}" ;;
                    elapsed_seconds=*) _or_elapsed="${_or_tok#elapsed_seconds=}" ;;
                    stale=*)           _or_stale_flag="${_or_tok#stale=}" ;;
                esac
            done
            set +f
            case "$_or_stale_flag" in
                false) _or_label="LIVE (within 4x budget)" ;;
                true)  _or_label="STALE (cannot tell if alive)" ;;
                *)     _or_label="UNEVALUABLE (no usable start time)" ;;
            esac
            echo "  $_or_label id=$_or_id worker_type=${_or_wt:--} blueprint=${_or_bp:--} package=${_or_pkg:--} elapsed_seconds=${_or_elapsed:-unknown}"
        done < <(printf '%s\n' "$_or_out")

        # CRITICAL-1 (item 3): the overflow count is derived from the
        # header's own outstanding_count value, NOT from a count of parsed/
        # rendered lines -- a forged extra row can no longer inflate the
        # overflow number, since the header counts are printed and read
        # before any row (D-B's existing structural guarantee).
        if [ "$_or_count" -gt 5 ]; then
            echo "  (+$((_or_count - 5)) more -- run: perl plugins/butler/scripts/bp-dispatch-log.pl outstanding)"
        fi

        # Emitted when at least one row is stale, unevaluable, OR unreadable
        # (SHOULD-1: widened to include unreadable_count -- an unreadable
        # dispatch-log record must not silently suppress this sentence, D-D's
        # own point: a STALE/unreadable record still blocks, so the message
        # must say which case applied rather than let staleness read as
        # completion).
        if [ "$_or_stale" -gt 0 ] || [ "$_or_uneval" -gt 0 ] || [ "$_or_unread" -gt 0 ]; then
            echo "STALE means past 4x its own budget: it CANNOT be told apart from a dispatch that died, and it is"
            echo "NOT evidence the work finished -- so it still blocks this stop."
        fi

        return 0
    }

    _bp_probe_verdict "$ROOT/.ccpraxis-local-data"
    PV=$?
    case "$PV" in
      0)
        # NOT cleared (deviates from a literal "clear $STATE" reading of the
        # spec's step 5): AC21/behaviour 25 (turn != run) requires that once
        # this watcher is gone, the VERY NEXT stop on the same unresolved
        # dispatch denies again -- arming a watcher ends a turn, never the
        # run itself. Only the operator's own finish marker (above) or an
        # explicit resolution clears the pending set.
        exit 0
        ;;
      2)
        echo "butler subagent-stall gate: allowing this stop -- probe verdict is CANNOT TELL (fail-open). The pending dispatch stays recorded for the next turn." >&2
        exit 0
        ;;
    esac

    PENDING=""
    [ -s "$STATE" ] && PENDING=$(tr '\n' ';' < "$STATE" 2>/dev/null | sed 's/;$//')

    # THE CROSS-CHECK RUNS HERE, AND ONLY HERE (D-A) -- every path above this
    # line that could still allow the stop has already exited. Its output
    # decorates the message below; it never changes the fact that we are
    # about to exit 2 (D-B).
    XCHECK=$(_bp_outstanding_report "$ROOT" 2>/dev/null) || XCHECK=""

    # KEEP THIS SHORT. It fires repeatedly in a long run, and an operator who
    # has read the rationale once does not need it again on every denial. The
    # argument for the gate lives in this file's header and in
    # drive-solo/SKILL.md; what a reader needs HERE is the remedy. Pinned by
    # t/subagent-stall-guard.t -- BLOCKED, the unresolved worker's name, both
    # remedies, "only the operator", the asymmetry sentence, and the
    # ONE-SHOT force-stop lever. Everything else is a pointer.
    cat >&2 <<EOF
BLOCKED: nothing will wake this session, and only the operator can end the run.
${PENDING:+Unresolved since the last resolved turn: $PENDING
}
${XCHECK:+$XCHECK
}
Two ways to end a turn, and no third:

  1. Arm a bounded watcher around the work, then stop:
       perl plugins/butler/scripts/bp-watch.pl --arm --max-seconds <N> --package <bp>/<pkg> ...
     A live bp-watch.pl is what proves something will wake this session.

  2. The OPERATOR ends the run. There is no verb, flag or argument that does it:
       touch $ROOT/.ccpraxis-local-data/.drive-solo/.run-finished

When the signal is ambiguous, CONTINUE -- wrongly continuing costs some tokens,
wrongly stopping abandons an unattended run with nobody present to notice.

Override (ONE-SHOT -- consumed on use, allows exactly this stop): touch $STATE_DIR/force-stop
EOF
    exit 2
    ;;

  *) exit 0 ;;
esac
