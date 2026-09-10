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
# Session resolution: every candidate id, not one — see session_candidates().
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
# imports nothing bash-side) — the two resolutions must agree; see
# scripts/statusline.pl's own duplicate for the third leg of that parity.
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

my $cmd = shift @ARGV // '';

if    ($cmd eq 'arm')    { cmd_arm()    }
elsif ($cmd eq 'disarm') { cmd_disarm() }
elsif ($cmd eq 'status') { cmd_status() }
elsif ($cmd eq 'hold')   { cmd_hold()   }
else {
    emit('STATUS', 'error');
    emit('ERROR',  "Unknown command '$cmd' (usage: arm|disarm|status|hold)");
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

    my @sids = session_candidates($opts);         # already emitted+exited if empty
    my $by = $opts->{by} // 'agent';
    unless ($by eq 'operator' || $by eq 'agent') {
        emit('STATUS', 'error');
        emit('ERROR',  "--by must be 'operator' or 'agent' (got: $by)");
        exit 1;
    }

    my $dir = resolve_registry_dir_or_die();

    # AN EXPLICITLY-PASSED ID IS VALIDATED BEFORE ANYTHING IS ARMED. Candidates
    # gathered from the environment may be quietly skipped when malformed --
    # they are a safety net, and a broken net should not fail the call. But
    # --session is a direct instruction, and letting an env candidate silently
    # stand in for a caller's invalid id would arm SOMETHING while reporting
    # success for a request that was never honoured. That is the same class of
    # lie this whole change exists to remove.
    if (defined $opts->{session} && length $opts->{session}
            && !defined continuity_marker($opts->{session}, $dir)) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $opts->{session}");
        exit 1;
    }

    make_path($dir) unless -d $dir;
    my $since = iso_now();

    my @armed;
    my @bad;
    my $first = 1;
    for my $sid (@sids) {
        my $mark = continuity_marker($sid, $dir);
        unless (defined $mark) {
            push @bad, $sid;
            next;
        }
        # SECONDARY CANDIDATES ARE TAGGED, and the reason is concurrency. The
        # registry is shared: every session on this host (or in this sandbox)
        # keys its marker into the same directory by session id. That is the
        # right model -- one marker per session, and the gate looks up its own.
        # Arming EXTRA candidate ids is what makes a stale id survivable, but it
        # also means that if a candidate id happens to be some OTHER live
        # session, that session gets armed without its operator asking.
        #
        # It cannot be prevented from here: no non-hook caller can learn which
        # session Claude Code considers live (see session_candidates). What it
        # can do is refuse to be silent about it. A tagged marker lets the gate
        # explain itself when it blocks a session nobody deliberately armed,
        # which turns a mystery into a one-line fix ("disarm").
        my $tag = $first ? '' : ' candidate';
        open my $fh, '>', $mark or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot write $mark: $!");
            exit 1;
        };
        print {$fh} "$by $since$tag\n";
        close $fh;
        $first = 0;
        # Explicit touch: on some filesystems a fresh open+print already sets
        # mtime to now, but idempotent re-arm (behavior 8) requires the mtime to
        # move forward on every arm call, not just the first — utime() makes that
        # true unconditionally rather than depending on open() semantics.
        my $now = time();
        utime($now, $now, $mark);
        push @armed, $sid;
    }

    unless (@armed) {
        emit('STATUS', 'error');
        emit('ERROR',  'invalid session id' . (@bad > 1 ? 's' : '') . ': '
                      . join(', ', @bad));
        exit 1;
    }

    emit('STATUS',   'armed');
    emit('SESSION',  $armed[0]);
    emit('ARMED_BY', $by);
    emit('SINCE',    $since);

    # SAY IT WHEN THE SOURCES DISAGREE. Both markers are live, so the gate will
    # find whichever session is real -- but the operator should know that the
    # ambiguity existed rather than discover it from a gate that never fired.
    if (@armed > 1) {
        emit('ALSO_ARMED', join(', ', @armed[1 .. $#armed]));
        emit('NOTE', 'the session-id sources disagreed; every candidate is armed '
                   . 'so the gate cannot miss the live one. Run `status` after a '
                   . 'turn or two to see which one the gate is actually using.');
    }
    emit('WARN', 'ignored invalid session id: ' . join(', ', @bad)) if @bad;
}

sub cmd_disarm {
    my $opts = parse_args(qw(session));
    my $sid = resolve_session($opts) or return;

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
}

# read_marker($mark) -> ($by, $since, $tag) or () when unreadable. $tag is the
# optional third field ('candidate' on a fallback marker); undef when absent,
# which is every marker written before that field existed.
sub read_marker {
    my ($mark) = @_;
    open my $fh, '<', $mark or return ();
    my $line = <$fh>;
    close $fh;
    chomp($line //= '');
    my ($by, $since, $tag) = $line =~ /^(\S+)\s+(\S+)(?:\s+(\S+))?/;
    return ($by, $since, $tag);
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
    my @sids = session_candidates($opts);
    my $sid  = $sids[0];

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    unless (-f $mark) {
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
        report_other_candidates($dir, $sid, @sids);
        return;
    }

    my ($by, $since, $tag) = read_marker($mark);
    unless (defined $by || defined $since) {
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
        return;
    }

    emit('STATUS',   'armed');
    emit('SESSION',  $sid);
    emit('ARMED_BY', $by // 'unknown');
    emit('SINCE',    $since // '');
    if (defined $tag && $tag eq 'candidate') {
        emit('ARMED_AS', 'candidate');
        emit('NOTE', 'this marker was written as a FALLBACK candidate by an arm '
                   . 'whose session-id sources disagreed -- possibly by another '
                   . 'session. If this session was never meant to be watched, '
                   . 'disarm it.');
    }

    # HAS THE GATE ACTUALLY RUN FOR THIS MARKER?
    # This is the whole diagnostic,
    # and it is decisive rather than circumstantial: gate-continuity.sh touches
    # the marker on every run that gets past its TTL check, so a marker whose
    # mtime is still its arm time is a marker no gate has ever looked up. That
    # is exactly what an arm keyed to the wrong session id looks like from the
    # inside -- "armed", enforcing nothing -- and it is the reason that failure
    # went unnoticed until an operator counted turn boundaries by hand.
    #
    # A grace period, because "armed 4 seconds ago" has legitimately not
    # reached a Stop boundary yet. Past that, silence is the finding.
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
                       . "yet, or this id is not the session Claude Code thinks "
                       . "is live -- in which case the arm is enforcing nothing. "
                       . "Re-run arm (it marks every candidate id) and compare.");
        }
    }

    report_other_candidates($dir, $sid, @sids);
}

# When the session-id sources disagree, say what the OTHER candidates look
# like. Reporting only the most-trusted one is how a mismatch stays invisible.
sub report_other_candidates {
    my ($dir, $primary, @sids) = @_;
    for my $sid (@sids) {
        next if $sid eq $primary;
        my $mark = continuity_marker($sid, $dir) or next;
        my $state = (-f $mark) ? 'armed' : 'unarmed';
        emit('OTHER_CANDIDATE', "$sid ($state)");
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

    # Write the pending marker ONLY for a session that is actually armed. A hold
    # on an unarmed session is a harmless timer, and saying so is better than
    # leaving a marker for a gate that will never look it up.
    my $armed = (-f $mark) ? 1 : 0;
    if ($armed) {
        open my $fh, '>', "$mark.wakeup-pending" or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot write $mark.wakeup-pending: $!");
            exit 1;
        };
        # Line format: <written_epoch> bounded <deadline_epoch>. The gate reads
        # field 1 for the existing TTL check and fields 2/3 for boundedness, so
        # an older gate reading only field 1 still behaves exactly as before.
        print {$fh} "$now bounded $deadline\n";
        close $fh;
    }

    emit('STATUS',   $armed ? 'holding' : 'holding_unarmed');
    emit('SESSION',  $sid);
    emit('SECONDS',  $secs);
    emit('DEADLINE', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($deadline)));
    emit('NOTE', 'not armed, so no wake-up marker was written; this is only a timer')
        unless $armed;
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

# ── Helpers ────────────────────────────────────────────────

sub emit {
    my ($key, $val) = @_;
    print "$key: $val\n";
}

sub iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

# resolve_session(\%opts) -> session id, or exits 1 with STATUS: error.
# session_candidates($opts) -> list of distinct session ids this invocation
# could plausibly be about, most-trusted first. NEVER empty (it exits first).
#
# WHY A LIST AND NOT A VALUE. An arm keys a marker by session id; the gate
# looks up the marker by the session_id in its OWN hook payload, which is what
# Claude Code considers live, and exit 0's SILENTLY when there is no marker for
# it (gate-continuity.sh). So any disagreement about "which session is this"
# produces the worst possible outcome: arm reports success and watches nothing.
# It was reported from a live session -- armed, reported armed, and the gate
# never ran -- after exiting a session, rebuilding the container, and relaunching
# with the previous conversation resumed.
#
# TWO THINGS ARE INDEPENDENTLY TRUE, and only the first is verified here:
#
#   1. The documented fallback was already dead. This resolved --session, else
#      $CLAUDE_SESSION_ID -- and $CLAUDE_SESSION_ID is NOT SET in this harness's
#      Bash environment at all (measured). $CLAUDE_CODE_SESSION_ID is. So the id
#      substituted into the /butler:continuity skill body was the ONLY source,
#      with no cross-check and no second chance.
#   2. That substituted id is reported to have been a stale, pre-resume session
#      id. Plausible and consistent with the evidence (the marker's mtime had
#      not moved across two turn boundaries, and the gate touches it on every
#      run past the TTL check) but NOT reproduced here, and not something this
#      script should stake correctness on.
#
# So resolution does not pick a winner. It collects every candidate and arm
# marks ALL of them: if the two sources disagree, one marker is the live session
# and the other is reaped by the existing TTL sweep. Being right becomes
# independent of which source was stale -- which is what makes this a workaround
# for a harness behaviour we do not control rather than a bet on a diagnosis.
sub session_candidates {
    my ($opts) = @_;
    my @raw = (
        $opts->{session},
        $ENV{CLAUDE_SESSION_ID},
        $ENV{CLAUDE_CODE_SESSION_ID},
    );
    my (@out, %seen);
    for my $sid (@raw) {
        next unless defined $sid && length $sid;
        next if $seen{$sid}++;
        push @out, $sid;
    }
    unless (@out) {
        emit('STATUS', 'error');
        emit('ERROR',  'no session id: pass --session, or set $CLAUDE_SESSION_ID '
                      . 'or $CLAUDE_CODE_SESSION_ID');
        exit 1;
    }
    return @out;
}

# resolve_session($opts) -> the single most-trusted candidate. For disarm and
# status, which act on one marker; arm uses session_candidates directly.
sub resolve_session {
    my ($opts) = @_;
    my @c = session_candidates($opts);
    return $c[0];
}

# continuity_active_dir() -> the registry dir, or undef if UNRESOLVABLE.
# Duplicated from lib.sh's bp_continuity_active_dir on purpose; must resolve
# IDENTICALLY for a given environment (spec SS2.6/AC-13; fix-batch F1's
# single rule, documented in full at lib.sh's bp_continuity_active_dir):
# override, else $HOME, else $USERPROFILE, else undef. Does NOT guess $PWD
# or '.' -- see resolve_registry_dir_or_die(), the only caller, which is
# where the "fail loudly" half of F1's rule actually lives.
sub continuity_active_dir {
    return $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}
        if defined $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} && length $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    return undef unless defined $home && length $home;
    return "$home/.claude/ccpraxis/.continuity-active";
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
        emit('ERROR',  'cannot resolve continuity registry directory: neither $HOME nor '
                      . '$USERPROFILE is set, and CCPRAXIS_CONTINUITY_ACTIVE_DIR is not set '
                      . 'either -- refusing to guess a location (e.g. $PWD or \'.\') that the '
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
    while (my $arg = shift @ARGV) {
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
