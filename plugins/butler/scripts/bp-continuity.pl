#!/usr/bin/env perl
# bp-continuity.pl — explicit continuity arm/disarm/status for THIS session.
#
# g01-explicit-continuity-arming: the canonical mechanism for arming a
# session doing unattended work with no blueprint, no drive-solo, no
# reporter. Callable directly by the agent (Bash tool) or wrapped by the
# /butler:continuity skill (operator-facing). See
# specs/g01-explicit-continuity-arming-spec.md SS2.1/SS2.2.
#
# Subcommands:
#   arm    [--session <id>] [--by operator|agent]   (default --by agent)
#   disarm [--session <id>]
#   status [--session <id>]
#
# Session resolution: see resolve_session_full() and BpSession.pm.
# ERROR (exit 1) when there is none, because this is a direct, non-hook
# invocation and silently no-op-ing on a missing session id would be exactly
# the "correct, tested, never invoked" defect this run has hit repeatedly.
#
# This used to read "--session if given, else $ENV{CLAUDE_SESSION_ID}". That
# second half never worked. ${CLAUDE_SESSION_ID} is a Claude Code TEMPLATE
# SUBSTITUTION, replaced inside SKILL.md before the body runs — this repo's own
# references/extending-ccpraxis.md says so — and it is not exported to the Bash
# environment at all (measured: unset; $CLAUDE_CODE_SESSION_ID is what is set).
# So the fallback was a category error, and the id substituted into the skill
# body was the only source, unverified.
#
# Registry: ${CCPRAXIS_CONTINUITY_ACTIVE_DIR:-$HOME/.claude/ccpraxis/.continuity-active},
# duplicated from lib.sh's bp_continuity_active_dir on purpose (this script
# imports nothing bash-side) — the resolutions must agree. There are FOUR legs,
# not three: lib.sh, this file, bp-session.pl and scripts/statusline.pl.
#
# PATH RESOLUTION — see lib.sh's bp_continuity_active_dir for the single rule
# all three components follow (fix-batch F1): override, else $HOME, else
# $USERPROFILE, else UNRESOLVABLE. Because THIS script is the write path
# (arm/disarm/status all mutate or authoritatively read the registry), an
# unresolvable directory here FAILS LOUDLY (STATUS: error, exit 1) rather
# than guessing — see resolve_registry_dir_or_die() below. That is what makes
# the gate's and the badge's own "unresolvable => treat as nothing armed"
# fail-safe behavior correct rather than a fourth divergent guess: if this
# script could never resolve a directory, it could never have written a
# marker there either.
use strict;
use warnings;
use POSIX qw(strftime);
use IO::Handle;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;

# The session-identity resolver. All of "which session am I" lives there, once,
# for every consumer -- see BpSession.pm's header.
my $SCRIPT_DIR = dirname(File::Spec->rel2abs(__FILE__));
require "$SCRIPT_DIR/BpSession.pm";
require "$SCRIPT_DIR/BpResumption.pm";

my $cmd = shift @ARGV // '';

if    ($cmd eq 'arm')    { cmd_arm()    }
elsif ($cmd eq 'disarm') { cmd_disarm() }
elsif ($cmd eq 'status') { cmd_status() }
elsif ($cmd eq 'hold')   { cmd_hold()   }
elsif ($cmd eq 'await-operator') { cmd_await_operator() }
else {
    emit('STATUS', 'error');
    emit('ERROR',  "Unknown command '$cmd' (usage: arm|disarm|status|hold|await-operator)");
    exit 1;
}

# ── Subcommands ─────────────────────────────────────────────

sub cmd_arm {
    my $opts = parse_args(qw(session by));

    if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
        emit('STATUS', 'error');
        emit('ERROR',  'refused: BP_LEDGER is set (this is a coordinator process; '
                      . 'gate-stop.sh and gate-headless-background.sh already cover it)');
        exit 1;
    }

    my $by = $opts->{by} // 'agent';
    unless ($by eq 'operator' || $by eq 'agent') {
        emit('STATUS', 'error');
        emit('ERROR',  "--by must be 'operator' or 'agent' (got: $by)");
        exit 1;
    }

    my $dir = resolve_registry_dir_or_die();
    make_path($dir) unless -d $dir;
    my $since = iso_now();

    # ── explicit id: arm it directly ───────────────────────────────────────
    # The direct path stays for callers that genuinely know the id -- the gate's
    # own claim step, tests, and an operator repairing state by hand. It is not
    # the path /butler:continuity uses, because a skill body cannot know the id.
    if (defined $opts->{session} && length $opts->{session}) {
        my $sid = $opts->{session};
        my $mark = continuity_marker($sid, $dir);
        unless (defined $mark) {
            emit('STATUS', 'error');
            emit('ERROR',  "invalid session id: $sid");
            exit 1;
        }
        # WRITE ATOMICALLY. A crash or ENOSPC between open and print leaves a
        # ZERO-BYTE marker, and the two readers disagree about what that means:
        # the gate keys on the file EXISTING (so it blocks), while status keyed
        # on parseable content (so it said "unarmed"). The operator is then told
        # they are not armed, cannot end the turn, and has no reason to try
        # disarm. temp-file + rename makes the marker appear whole or not at all.
        write_marker_atomic($mark, "$by $since\n") or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot write $mark: $!");
            exit 1;
        };
        # Explicit touch: on some filesystems a fresh open+print already sets
        # mtime to now, but idempotent re-arm (behavior 8) requires the mtime to
        # move forward on every arm call, not just the first — utime() makes
        # that true unconditionally rather than depending on open() semantics.
        my $now = time();
        utime($now, $now, $mark);

        emit('STATUS',   'armed');
        emit('SESSION',  $sid);
        emit('ARMED_BY', $by);
        emit('SINCE',    $since);
        return;
    }

    # ── no id: write a ticket and let the gate bind it ─────────────────────
    #
    # The nonce reaches this session's transcript by being printed, and the Stop
    # hook binds the ticket to the session whose transcript carries it AND whose
    # payload session_id matches. Nothing is armed until then, which is exactly
    # when it first matters: the gate is a Stop hook, so binding at the first
    # Stop cannot miss an enforcement point.
    #
    # This is the whole fix. The previous version guessed an id from a template
    # substitution and reported success either way; if the guess was wrong, the
    # gate looked up a marker that did not exist and exited silently.
    my $nonce = BpSession::new_nonce();
    my $pending = "$dir/pending";
    make_path($pending) unless -d $pending;

    my $ticket = "$pending/$nonce";
    open my $fh, '>', $ticket or do {
        emit('STATUS', 'error');
        emit('ERROR',  "Cannot write $ticket: $!");
        exit 1;
    };
    print {$fh} "$by $since\n";
    close $fh;

    # The beacon lets status/disarm resolve THIS session between Stops. Keyed by
    # a process-scoped value that only has to be stable, never correct: whatever
    # it says, the nonce it points at resolves through the transcript.
    # A FAILED BEACON IS NOT COSMETIC. status's `arming` branch finds the ticket
    # THROUGH the beacon, so without one this session reports `unarmed` right up
    # until the gate arms it -- "not armed" followed by being armed anyway is the
    # same lie as "armed" followed by nothing, just inverted. Say so instead.
    unless (write_beacon($dir, $nonce)) {
        emit('WARN', 'could not record the local beacon, so `status` and `disarm` in this '
                   . 'session will not see the pending arm. The ticket is live and will '
                   . 'still bind at the next turn boundary.');
    }

    emit('STATUS',  'arming');
    emit('NONCE',   $nonce);
    emit('ARMED_BY', $by);
    emit('SINCE',   $since);
    emit('NOTE', 'the arm binds to this session at the next turn boundary, when '
               . 'the Stop hook can confirm which session actually printed this '
               . 'nonce. Run `status` after that to see it bound.');
}

sub cmd_disarm {
    my $opts = parse_args(qw(session));
    my ($sid, $confidence) = resolve_session_full($opts);

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    # An UNBOUND ticket is also an arm, and disarm has to reach it. Otherwise
    # "off" would report not_armed while a ticket sat waiting to bind at the
    # next turn boundary -- arming the session the operator had just switched
    # off. Done before the marker check so it happens on both paths.
    my $ticket_dropped = 0;
    if (my $nonce = read_beacon($dir)) {
        if (-f "$dir/pending/$nonce") {
            unlink "$dir/pending/$nonce";
            $ticket_dropped = 1;
        }
        my $bp = beacon_path($dir);
        unlink $bp if defined $bp && -f $bp;
    }

    unless (-f $mark) {
        if ($ticket_dropped) {
            emit('STATUS',  'disarmed');
            emit('SESSION', $sid);
            emit('CONFIDENCE', $confidence);
            emit('NOTE',    'a pending arm was cancelled before it bound');
            disarm_confidence_warning($confidence);
            return;
        }
        emit('STATUS',  'not_armed');
        emit('SESSION', $sid);
        exit 2;
    }

    # fix-batch F4: a false "disarmed" is the exact mirror of a false
    # "armed" -- both lie about whether the session is watched. Verify the
    # PRIMARY marker is actually gone (re-stat rather than trust unlink's
    # return value alone, since the goal is "is it still enforceable", not
    # "did the syscall report success") before ever claiming disarmed.
    # Companion files are best-effort cleanup: their survival cannot cause
    # gate-continuity.sh to re-block (it only blocks off the PRIMARY
    # marker's presence), so a companion unlink failure does not change the
    # STATUS this command reports.
    unlink $mark;
    unlink "$mark.wakeup-pending";
    unlink "$mark.stop-blocks";
    unlink "$mark.stop-ok";
    unlink "$mark.gave-up";

    if (-f $mark) {
        emit('STATUS',  'error');
        emit('SESSION', $sid);
        emit('ERROR',   "primary marker $mark still exists after unlink (permission or lock?) "
                       . "-- refusing to report disarmed while continuity enforcement may still "
                       . "be in force");
        exit 1;
    }

    emit('STATUS',  'disarmed');
    emit('SESSION', $sid);
    emit('CONFIDENCE', $confidence);
    disarm_confidence_warning($confidence);
}

# A disarm on an UNVERIFIED id may have removed a marker belonging to nothing
# while the live session's own marker survives -- and the operator would be told
# "disarmed" either way. It is not refused: with no beacon (arm never ran here,
# or its nonce was ambiguous) the env id is the only handle there is, and
# refusing would leave a session unable to switch itself off at all. So it acts,
# and says how sure it was.
sub disarm_confidence_warning {
    my ($confidence) = @_;
    return unless defined $confidence && $confidence eq 'unverified';
    emit('WARN', 'this session could not be identified from a transcript, so the id '
               . 'came from a process-scoped env value with nothing to check it against. '
               . 'If the gate still blocks, the live session has its own marker: run '
               . 'status to see which id is actually armed.');
}

# read_marker($mark) -> ($by, $since) or () when unreadable.
#
# There was briefly a third field, `candidate`, tagging markers written by an
# arm that armed every session id it could guess at. That approach is gone --
# the gate binds a ticket to the one session whose transcript carries its nonce,
# so there is nothing to hedge and nothing to tag.
sub read_marker {
    my ($mark) = @_;
    open my $fh, '<', $mark or return ();
    my $line = <$fh>;
    close $fh;
    chomp($line //= '');
    my ($by, $since) = $line =~ /^(\S+)\s+(\S+)/;
    return ($by, $since);
}

# iso_to_epoch($iso) -> epoch seconds, or undef. iso_now() writes UTC with a
# trailing Z, so this parses exactly that and nothing else.
sub iso_to_epoch {
    my ($iso) = @_;
    return undef unless defined $iso
        && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    require Time::Local;
    return eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
}

sub cmd_status {
    my $opts = parse_args(qw(session));
    my ($sid, $confidence) = resolve_session_full($opts);

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    unless (-f $mark) {
        # An arm that has not reached a turn boundary yet is not "unarmed" --
        # it is waiting for the Stop hook to confirm which session printed its
        # nonce. Saying "unarmed" here would look exactly like the failure this
        # whole mechanism removes.
        if (my $nonce = read_beacon($dir)) {
            my $ticket = "$dir/pending/$nonce";
            if (-f $ticket) {
                emit('STATUS', 'arming');
                emit('NONCE',  $nonce);
                emit('NOTE', 'a ticket is waiting to bind at the next turn '
                           . 'boundary; nothing is enforced until it does');

                # AN ARM THAT NEVER BINDS MUST NOT LOOK LIKE ONE THAT HAS NOT
                # BOUND YET. Binding needs the nonce to be findable in a
                # transcript whose record names the session the Stop hook
                # reports. Two known ways that never happens:
                #
                #   * `arm` ran inside a SUBAGENT. Its transcript is a separate
                #     file under <session>/subagents/, and its records carry the
                #     subagent's own id -- which is never the id any Stop hook
                #     reports, so no gate can ever match it. Arming from a
                #     subagent is meaningless: it has no Stop of its own that
                #     gates the parent.
                #   * the nonce turned out to be AMBIGUOUS (present in more than
                #     one transcript), which resolves to nothing by design.
                #
                # Detecting the subagent case from an env var was considered and
                # rejected: CLAUDE_CODE_CHILD_SESSION is set in ordinary
                # top-level sessions on this machine (measured), so refusing on
                # it would break arming exactly where it should work. Reporting
                # the observable fact -- "this ticket has aged and still does not
                # resolve" -- needs no such guess.
                my $age = time() - ((stat $ticket)[9] // time());
                if ($age >= 120 && !BpSession::session_for_nonce($nonce)) {
                    emit('WARN', "this ticket has been pending ${age}s and its nonce still "
                               . "resolves to no session, so it may never bind. Arming from "
                               . "inside a subagent cannot bind (its transcript is its own, "
                               . "and no Stop hook reports its id); an ambiguous nonce cannot "
                               . "either. Disarm and re-arm from the main session.");
                }
                return;
            }
        }
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
        emit('CONFIDENCE', $confidence);
        return;
    }

    my ($by, $since) = read_marker($mark);
    unless (defined $by || defined $since) {
        # THE GATE READS EXISTENCE, SO SO DOES THIS. An empty or corrupt marker
        # still blocks every stop; reporting "unarmed" here made status the only
        # component that disagreed, and sent the operator looking for a problem
        # they had no way to name. Report armed, and say the content is bad.
        emit('STATUS',  'armed');
        emit('SESSION', $sid);
        emit('ARMED_BY', 'unknown');
        emit('SINCE',    '');
        emit('WARN', 'the marker exists but its content is unreadable. The gate keys on '
                   . 'the file existing, so this session IS gated; disarm works normally.');
        return;
    }

    emit('STATUS',   'armed');
    emit('SESSION',  $sid);
    emit('CONFIDENCE', $confidence);
    emit('ARMED_BY', $by // 'unknown');
    emit('SINCE',    $since // '');

    # HAS THE GATE ACTUALLY RUN FOR THIS MARKER?
    # This is the diagnostic, and it is decisive rather than circumstantial:
    # gate-continuity.sh touches the marker on every run that gets past its TTL
    # check, so a marker whose mtime is still its arm time is a marker no gate
    # has ever looked up. With the ticket flow that should no longer be possible
    # -- the gate is what created the marker -- so if this ever says no, the
    # binding assumption itself is wrong and that is worth surfacing loudly.
    #
    # A grace period, because "armed 4 seconds ago" has legitimately not reached
    # a Stop boundary yet. Past that, silence is the finding.
    # DID THE GATE EVER STAND ASIDE? gate-continuity.sh yields after N
    # consecutive blocks rather than wedge the session, and leaves this record
    # so the yield is discoverable. Without it the session reads as armed and
    # watched while continuity has, at least once, let a turn end with nothing
    # scheduled -- which is the state an operator most needs to know about.
    if (-f "$mark.gave-up") {
        open my $gh, '<', "$mark.gave-up";
        my $when = $gh ? <$gh> : undef;
        close $gh if $gh;
        chomp($when //= '');
        my $ago = ($when =~ /^\d+$/) ? (time() - $when) : undef;
        emit('GAVE_UP', defined $ago
            ? strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($when)) . " (${ago}s ago)"
            : 'yes');
        emit('WARN', 'continuity stood aside at least once rather than block again. '
                   . 'The arm still stands, but a turn has ended with nothing scheduled; '
                   . 'if that work mattered, nothing woke it.');
    }

    my $armed_at = iso_to_epoch($since);
    my $mtime    = (stat $mark)[9];
    if (defined $armed_at && defined $mtime) {
        my $seen = ($mtime - $armed_at) >= 2 ? 1 : 0;
        emit('GATE_SEEN', $seen ? 'yes' : 'no');
        emit('GATE_LAST', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($mtime)));
        my $age = time() - $armed_at;
        if (!$seen && $age >= 120) {
            emit('WARN', "the Stop gate has not run for this session id in the "
                       . "${age}s since it was armed. Either no turn has ended "
                       . "yet, or this marker is keyed to a session Claude Code "
                       . "does not consider live -- in which case it is "
                       . "enforcing nothing. Disarm and re-arm to rebind.");
        }
    }
}

# hold --seconds N : the BOUNDED WAIT.
#
# THE PROBLEM IT SOLVES. gate-continuity.sh let a turn end whenever something
# had been DISPATCHED -- a subagent, a backgrounded Bash call. That is naive in
# one specific way: a dispatch is not a promise to come back. A subagent that
# runs forever, or a background command with no timeout, satisfies the gate and
# then never returns, and the session sits idle with nothing left to re-invoke
# it. The marker's TTL does not help: it governs whether a LATER stop is
# permitted, and there is no later stop, because nothing wakes the session to
# have one.
#
# WHAT MAKES A WAKE-UP REAL. Something must re-invoke the agent at a time known
# in advance. In this harness a backgrounded Bash call does exactly that when it
# EXITS. So the bounded wait is a command that sleeps and exits:
#
#     perl .../bp-continuity.pl hold --seconds 600     (run_in_background)
#
# and this one command both records the promise and IS the promise -- the same
# process writes the deadline and then delivers it. Two separate steps (record,
# then remember to start a timer) is precisely the arrangement that leaves a
# marker claiming a wake-up nothing will honour.
#
# On return, poll whatever the session was really waiting on and either finish,
# or hold again. Deliberately NOT a fixed schedule: the caller picks the horizon
# that fits what it is waiting for.
sub cmd_hold {
    my $opts = parse_args(qw(session seconds));

    my $secs = $opts->{seconds};
    $secs = 600 unless defined $secs && length $secs;
    unless ($secs =~ /^\d+$/ && $secs >= 1) {
        emit('STATUS', 'error');
        emit('ERROR',  "--seconds must be a positive integer (got: $secs)");
        exit 1;
    }
    # A hold longer than the marker's own TTL would expire mid-wait and block
    # the very stop it was taken out to permit.
    my $ttl = $ENV{CCPRAXIS_CONTINUITY_WAKEUP_TTL_S};
    $ttl = 900 unless defined $ttl && $ttl =~ /^\d+$/ && $ttl > 0;
    if ($secs > $ttl) {
        emit('STATUS', 'error');
        emit('ERROR',  "--seconds $secs exceeds the wake-up TTL (${ttl}s); the marker would "
                      . "expire before the wait ended. Hold for less, or raise "
                      . "CCPRAXIS_CONTINUITY_WAKEUP_TTL_S.");
        exit 1;
    }

    my $sid = resolve_session($opts);
    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    my $now      = time();
    my $deadline = $now + $secs;

    # Write the pending marker for a session that is armed OR ARMING.
    #
    # "Arming" matters because of an ordering the first version got wrong. The
    # primary marker does not exist until the gate BINDS the ticket, and that
    # happens at a Stop -- so on the very first turn after `arm`, a hold taken
    # in that same turn found no marker, declined to write anything, and the
    # Stop blocked. The correct first-use sequence (arm, dispatch, hold, end
    # turn) was therefore guaranteed to be refused once, and the explanation
    # went to a BACKGROUND process's stdout that nobody reads.
    #
    # A pending ticket for this same session is the arm, just not yet bound; the
    # gate claims tickets BEFORE it looks for the wake-up marker, so a file
    # written here is found in that same run. The ticket is this session's by
    # construction: resolve_session reached $sid by way of this beacon's nonce.
    my $armed = (-f $mark) ? 1 : 0;
    my $arming = 0;
    if (!$armed) {
        if (my $nonce = read_beacon($dir)) {
            $arming = 1 if -f "$dir/pending/$nonce";
        }
    }
    if ($armed || $arming) {
        # ATOMIC, for the same reason the primary marker is. A reader that
        # catches this file between open() and print() sees a zero-byte marker
        # and cannot tell it from a malformed one -- and the window is not
        # theoretical: capturing this process's identity reads /proc first, so
        # there is real work between creating the file and filling it. A test
        # polling for the file caught exactly that.
        write_marker_atomic("$mark.wakeup-pending",
            BpResumption::marker_line(deadline => $deadline, pid => $$)) or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot write $mark.wakeup-pending: $!");
            exit 1;
        };
    }

    emit('STATUS',   ($armed || $arming) ? 'holding' : 'holding_unarmed');
    emit('BINDS_AT', 'next turn boundary') if $arming && !$armed;
    emit('SESSION',  $sid);
    emit('SECONDS',  $secs);
    emit('DEADLINE', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($deadline)));
    emit('NOTE', 'not armed, so no wake-up marker was written; this is only a timer')
        unless $armed || $arming;
    # Flush before sleeping: a backgrounded caller should be able to read this
    # immediately rather than when the wait ends.
    STDOUT->flush() if STDOUT->can('flush');

    sleep_until($deadline);

    emit('STATUS',  'hold_elapsed');
    emit('SESSION', $sid);
    exit 0;
}

# sleep_until($epoch) — sleep in bounded slices so a clock jump or a signal
# cannot turn a ten-minute wait into an indefinite one.
sub sleep_until {
    my ($deadline) = @_;
    while (1) {
        my $left = $deadline - time();
        last if $left <= 0;
        $left = 60 if $left > 60;
        sleep $left;
    }
}

# await-operator --reason "..." : the turn ends because A HUMAN WAS ASKED.
#
# THE GAP THIS FILLS. The gate permits a turn to end only if something will
# resume the session, the arm is lifted, or a one-shot exemption is present. An
# agent that has FINISHED the watched work and is now asking the operator a
# question satisfies none of them:
#
#   * nothing is pending, and the only way to pretend otherwise is to background
#     a wait for work that does not exist -- the hollow pause this whole
#     subsystem exists to prevent;
#   * lifting an arm the operator set, unasked, is worse than the block;
#   * the exemption file is reachable only by touching a dotfile whose sole
#     purpose is to relax a safety gate, which a permission layer may quite
#     reasonably refuse -- measured on this machine, it does.
#
# So an agent could be left with no honest exit. Waiting on a human is not a
# stall: it is the correct end of a turn, and the operator's next message is
# what resumes the session. The sibling guard has had a verb for "nothing is
# pending and that is correct" (bp-runstate.pl's `finish`) since it was written;
# continuity had none.
#
# WHAT KEEPS IT HONEST. It is ONE-SHOT -- the gate consumes the exemption -- so
# it can never silence the gate, only end the turn in which it was taken. It
# records a reason, so a chain of them is visible rather than anonymous. And it
# refuses on an unarmed session, where it would be meaningless. It is NOT a
# claim that anything will return, which is exactly why it is a separate verb
# rather than a hold with a lie in it.
sub cmd_await_operator {
    my $opts = parse_args(qw(session reason));

    my $reason = $opts->{reason};
    $reason = 'waiting for the operator' unless defined $reason && length $reason;
    $reason =~ s/[\r\n]+/ /g;

    # NOT WHILE A RUN IS IN FLIGHT.
    #
    # This verb exists so a turn can end honestly when a human has been asked.
    # It must not become the way an UNATTENDED run stops dead. The operator's
    # report is blunt about the pattern: "a whole unattended run halt because of
    # some blocking user input... 99% of the times it was not actually necessary
    # and could have progressed while batching the question to the end".
    #
    # An active run is exactly the state where nobody is watching, so a question
    # asked now is answered hours later at best. The question is not discarded --
    # it is appended to the run's question queue, which is what "batch it to the
    # end" needs to be more than an instruction -- and the turn is refused, so
    # the agent carries on with the work it can still do.
    #
    # A PAUSED or FINISHED run does not trip this: the first has a watcher and
    # the second is over. Only `active` means work is underway right now.
    my $run_state = active_run_state();
    if (defined $run_state) {
        record_question($reason);
        emit('STATUS', 'refused_run_active');
        emit('RUN_STATE', $run_state);
        emit('QUESTION_QUEUED', questions_path() // '(could not record)');
        emit('ERROR', 'a run is ACTIVE, so this would halt unattended work for an answer '
                    . 'nobody is there to give. The question has been queued; batch it with '
                    . 'the others and keep going. If it truly blocks everything, finish or '
                    . 'pause the run first (bp-runstate.pl finish|pause), which is a '
                    . 'deliberate act rather than a side effect of asking.');
        exit 3;
    }

    my $sid = resolve_session($opts);
    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    unless (-f $mark) {
        emit('STATUS',  'not_armed');
        emit('SESSION', $sid);
        emit('NOTE',    'nothing is gating this session, so no exemption is needed');
        exit 2;
    }

    open my $fh, '>', "$mark.stop-ok" or do {
        emit('STATUS', 'error');
        emit('ERROR',  "Cannot write $mark.stop-ok: $!");
        exit 1;
    };
    print {$fh} 'awaiting-operator ' . time() . " $reason\n";
    close $fh;

    emit('STATUS',  'awaiting_operator');
    emit('SESSION', $sid);
    emit('REASON',  $reason);
    emit('NOTE', 'this permits exactly ONE turn to end and is consumed by the gate; '
               . 'the arm stays in force for every turn after it');
}

# active_run_state() -> the run's state when it is ACTIVE, else undef.
#
# Read through BpRunState so this agrees with guard-subagent-stall.sh rather
# than forming a second opinion: `effective` resolves a pause whose watcher died
# back to active, and that resolution is the whole reason a stale pause cannot
# keep permitting things.
sub active_run_state {
    my $rs = "$SCRIPT_DIR/bp-runstate.pl";
    return undef unless -f $rs;
    my $out = `"$^X" "$rs" status 2>/dev/null`;
    return undef unless defined $out && $out =~ /"state"\s*:\s*"([a-z_]+)"/;
    my $state = $1;
    return $state eq 'active' ? $state : undef;
}

# Where a deferred question goes. Beside the run state it belongs to, not in
# the continuity registry: the queue is a property of the RUN (it is emptied
# when the run is reported on), and continuity is per session.
sub questions_path {
    my $rs = "$SCRIPT_DIR/bp-runstate.pl";
    return undef unless -f $rs;
    my $dir = `"$^X" "$rs" state-dir 2>/dev/null`;
    return undef unless defined $dir;
    chomp $dir;
    return undef unless length $dir;
    return "$dir/questions.md";
}

# APPEND, never overwrite. Several questions across a long run are the norm, and
# the whole point is that none of them is lost.
sub record_question {
    my ($text) = @_;
    my $p = questions_path() or return 0;
    my $d = dirname($p);
    make_path($d) unless -d $d;
    open my $fh, '>>', $p or return 0;
    print {$fh} '- [' . iso_now() . "] $text\n";
    close $fh;
    return 1;
}

# ── Helpers ────────────────────────────────────────────────

# write_marker_atomic($path, $content) -> 1 on success, 0 on failure.
# temp-file + rename, so a reader never sees a half-written marker. See the
# call sites for why a zero-byte marker was worse than no marker at all.
sub write_marker_atomic {
    my ($path, $content) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} $content or do { close $fh; unlink $tmp; return 0 };
    close $fh or do { unlink $tmp; return 0 };
    unless (rename $tmp, $path) {
        unlink $tmp;
        return 0;
    }
    return 1;
}

sub emit {
    my ($key, $val) = @_;
    print "$key: $val\n";
}

sub iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

# resolve_session(\%opts) -> session id, or exits 1 with STATUS: error.
# ── which session am I ─────────────────────────────────────────────────────
#
# THE ANSWER IS NOT AVAILABLE DIRECTLY, and pretending otherwise is what broke.
# See BpSession.pm's header for the full account; the short version is that
# ${CLAUDE_SESSION_ID} is a template substitution baked into a skill body at
# render time (not an env var, and never verified), while the gate that consumes
# the marker uses the session_id from its own hook payload and exits silently
# when the two disagree.
#
# So this script does not guess. `arm` writes a TICKET carrying a nonce and
# prints the nonce, which lands in the arming session's transcript; the Stop
# hook -- which IS told the live session id -- binds that ticket to the session
# whose transcript actually carries the nonce. Two independent facts must agree
# before anything is armed, which is what makes it safe with any number of
# concurrent sessions sharing one registry.
#
# For `status` and `disarm`, which run between Stops and need an answer now, the
# nonce is remembered in a beacon keyed by $CLAUDE_CODE_SESSION_ID. That key
# only has to be STABLE within a process, not correct: whatever it says, the
# nonce it points at resolves through the transcript to the real session id.
sub beacon_path {
    my ($dir) = @_;
    my $key = $ENV{CLAUDE_CODE_SESSION_ID};
    return undef unless defined $key && length $key;
    # Same character rules as continuity_marker, INCLUDING the backslash: on
    # this host a backslash nests one directory level, so omitting it here (as
    # this did) let an env value place a beacon outside the beacons dir.
    return undef if $key =~ m{[/*.\x00]};
    return undef if index($key, chr(92)) >= 0;
    return "$dir/beacons/$key";
}

sub write_beacon {
    my ($dir, $nonce) = @_;
    my $bp = beacon_path($dir) or return 0;
    make_path(dirname($bp)) unless -d dirname($bp);
    open my $fh, '>', $bp or return 0;
    print {$fh} "$nonce\n";
    close $fh;
    return 1;
}

sub read_beacon {
    my ($dir) = @_;
    my $bp = beacon_path($dir) or return undef;
    open my $fh, '<', $bp or return undef;
    my $n = <$fh>;
    close $fh;
    chomp($n //= '');
    return length($n) ? $n : undef;
}

# resolve_session($opts) -> ($sid, $confidence). $confidence is:
#   'explicit'   -- the caller passed --session
#   'verified'   -- resolved through a beacon nonce to a transcript record
#   'unverified' -- the process-scoped env value, with nothing to check it
# Exits 1 when there is nothing at all.
sub resolve_session_full {
    my ($opts) = @_;

    my $explicit = $opts->{session};
    return ($explicit, 'explicit') if defined $explicit && length $explicit;

    my $dir = continuity_active_dir();
    if (defined $dir) {
        if (my $nonce = read_beacon($dir)) {
            if (my $sid = BpSession::session_for_nonce($nonce)) {
                return ($sid, 'verified');
            }
        }
    }

    my $env = $ENV{CLAUDE_CODE_SESSION_ID};
    return ($env, 'unverified') if defined $env && length $env;

    emit('STATUS', 'error');
    emit('ERROR',  'cannot determine this session: pass --session, or run `arm` '
                  . 'first so a beacon exists to resolve through');
    exit 1;
}

sub resolve_session {
    my ($opts) = @_;
    my ($sid) = resolve_session_full($opts);
    return $sid;
}

# continuity_active_dir() -> the registry dir, or undef if UNRESOLVABLE.
# Duplicated from lib.sh's bp_continuity_active_dir on purpose; must resolve
# IDENTICALLY for a given environment (spec SS2.6/AC-13; fix-batch F1's
# single rule, documented in full at lib.sh's bp_continuity_active_dir):
# override, else $HOME, else $USERPROFILE, else undef. Does NOT guess $PWD
# or '.' -- see resolve_registry_dir_or_die(), the only caller, which is
# where the "fail loudly" half of F1's rule actually lives.
# ABSOLUTE, OR UNRESOLVED. lib.sh's bp_is_absolute_path is the rule of record:
# a value beginning '/' or a Windows drive letter, and nothing else. The perl
# copies used to accept ANY non-empty string, so bash and perl disagreed about
# the same environment -- a relative CCPRAXIS_CONTINUITY_ACTIVE_DIR let `arm`
# write a marker under the caller's cwd and report success while the gate,
# which rejects it, enforced nothing. That is precisely the "armed, enforcing
# nothing" failure this subsystem exists to remove, reached through the parity
# these copies are supposed to guarantee.
sub _bp_is_absolute_path {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 0 unless $v =~ m{^[A-Za-z]:};
    # The drive-letter form may be bare ("C:"), slashed, or backslashed. The
    # backslash is matched via chr(92) rather than written into a character
    # class: this repo edits perl through shell heredocs, which collapse a
    # doubled backslash and silently produce an unterminated class.
    my $rest = substr($v, 2);
    return 1 if $rest eq q{} || $rest =~ m{^/} || substr($rest, 0, 1) eq chr(92);
    return 0;
}

sub continuity_active_dir {
    my $override = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    return $override if _bp_is_absolute_path($override);
    return undef if defined $override && length $override;   # set but relative
    for my $home ($ENV{HOME}, $ENV{USERPROFILE}) {
        next unless _bp_is_absolute_path($home);
        return "$home/.claude/ccpraxis/.continuity-active";
    }
    return undef;
}

# resolve_registry_dir_or_die() -> the registry dir, or exits 1 with
# STATUS: error if UNRESOLVABLE (fix-batch F1). This script is the WRITE
# path (arm mutates the registry; disarm/status are its authoritative
# reads), so an unresolvable directory here must never silently fall back
# to $PWD or '.' -- that is exactly how the gate and the badge would end up
# looking in a different place than arm just wrote to.
sub resolve_registry_dir_or_die {
    my $dir = continuity_active_dir();
    unless (defined $dir) {
        emit('STATUS', 'error');
        # Name the ACTUAL cause. A relative override is now rejected as well as
        # an unset one, and telling someone a variable "is not set" when it is
        # set but relative sends them looking in the wrong place.
        my $ov = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
        my $why = (defined $ov && length $ov)
            ? "CCPRAXIS_CONTINUITY_ACTIVE_DIR is set to '$ov', which is not an absolute path"
            : 'neither $HOME nor $USERPROFILE is set, and CCPRAXIS_CONTINUITY_ACTIVE_DIR is not set either';
        emit('ERROR',  "cannot resolve continuity registry directory: $why"
                      . ' -- refusing to guess a location (e.g. $PWD or \'.\') that the '
                      . 'gate and the statusline badge would not agree with');
        exit 1;
    }
    return $dir;
}

# continuity_marker($sid, $dir) -> marker path, or undef for an invalid id.
# Mirrors bp_continuity_marker's refusals exactly: a path separator, a
# backslash (fix-batch F3 -- see lib.sh's bp_continuity_marker for why),
# a glob metacharacter, or a literal '.' anywhere in the id. Takes $dir
# explicitly (rather than re-resolving) so callers control whether/how an
# unresolvable directory is reported -- see resolve_registry_dir_or_die().
sub continuity_marker {
    my ($sid, $dir) = @_;
    return undef unless defined $sid && length $sid;
    return undef if $sid =~ m{[/\\*.\x00]};
    return undef unless defined $dir;
    return "$dir/$sid";
}

sub parse_args {
    my @known = @_;
    my %known = map { $_ => 1 } @known;
    my %opts;
    while (defined(my $arg = shift @ARGV)) {
        unless ($arg =~ /^--([\w-]+)$/ && $known{$1}) {
            emit('STATUS', 'error');
            emit('ERROR',  "Unknown or unexpected argument: $arg");
            exit 1;
        }
        my $key = $1;
        my $val = shift @ARGV;
        unless (defined $val) {
            emit('STATUS', 'error');
            emit('ERROR',  "Flag --$key requires a value");
            exit 1;
        }
        $opts{$key} = $val;
    }
    return \%opts;
}
