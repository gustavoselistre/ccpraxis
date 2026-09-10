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
use File::Basename qw(dirname);
use File::Spec;

# The session-identity resolver. All of "which session am I" lives there, once,
# for every consumer -- see BpSession.pm's header.
my $SCRIPT_DIR = dirname(File::Spec->rel2abs(__FILE__));
require "$SCRIPT_DIR/BpSession.pm";

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
        open my $fh, '>', $mark or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot write $mark: $!");
            exit 1;
        };
        print {$fh} "$by $since\n";
        close $fh;
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
    write_beacon($dir, $nonce);

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
    my $sid = resolve_session($opts) or return;

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
            emit('NOTE',    'a pending arm was cancelled before it bound');
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
            if (-f "$dir/pending/$nonce") {
                emit('STATUS', 'arming');
                emit('NONCE',  $nonce);
                emit('NOTE', 'a ticket is waiting to bind at the next turn '
                           . 'boundary; nothing is enforced until it does');
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
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
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
    return undef if $key =~ m{[/\*.\x00]};
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
