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
#   hold   [--seconds N]                            the bounded wait
#   ask    --text "<question>"                      queue, do not stop
#   lease  [--daemon]                               the wake-lock / busy-lease
#
# ARMING TAKES A LEASE ON THE MACHINE, and it is not optional or manual: the
# host must not suspend, and a sandbox container must not reap itself, while a
# session is armed. arm holds it, disarm releases it, and a detached refresher
# (`lease --daemon`) keeps it asserted in between. See BpContinuityLease.pm.
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
use Cwd ();

# The session-identity resolver. All of "which session am I" lives there, once,
# for every consumer -- see BpSession.pm's header.
my $SCRIPT_DIR = dirname(File::Spec->rel2abs(__FILE__));
# GUARDED ON THE MODULE, NOT THE PATH. `require EXPR` keys %INC by the LITERAL
# string it was given, and BpSession.pm is required from four places that compute
# their script directory differently -- this file uses
# dirname(File::Spec->rel2abs(__FILE__)), BpContinuityLease.pm uses
# Cwd::abs_path. Two spellings of one directory means two %INC keys, so the file
# was compiled twice and every sub in it redefined.
#
# That printed eight "Subroutine ... redefined" warnings on EVERY invocation --
# into the same stream /butler:continuity documents as `KEY: value` lines for its
# own step 2 to parse. Noise in a channel something reads is not cosmetic.
#
# Matching any %INC key ending in BpSession.pm rather than testing for a
# particular sub keeps the guard independent of both the path spelling and the
# module's API.
require "$SCRIPT_DIR/BpSession.pm"
    unless grep { m{(?:^|/)BpSession\.pm$} } keys %INC;
require "$SCRIPT_DIR/BpResumption.pm";
# The wake-lock / busy-lease held for as long as anything is armed. See that
# file's header for why arming needs one at all, and why the two platforms hold
# two different things.
require "$SCRIPT_DIR/BpContinuityLease.pm";
require "$SCRIPT_DIR/BpProjectRoot.pm";

my $cmd = shift @ARGV // '';

if    ($cmd eq 'arm')    { cmd_arm()    }
elsif ($cmd eq 'disarm') { cmd_disarm() }
elsif ($cmd eq 'status') { cmd_status() }
elsif ($cmd eq 'hold')   { cmd_hold()   }
elsif ($cmd eq 'ask')    { cmd_ask()    }
elsif ($cmd eq 'lease')  { cmd_lease()  }
else {
    emit('STATUS', 'error');
    emit('ERROR',  "Unknown command '$cmd' (usage: arm|disarm|status|hold|ask|lease)");
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

    # SURFACE (AND CONSUME) A PRIOR ARM THAT NEVER BOUND, before anything else
    # this call does -- see 13-arming-binds-or-says-so-spec.md SS2.4. The
    # ledger's own words: the operator's false belief "was formed by the
    # `on` command's own output", so the correction belongs at the next `on`
    # / `arm`, not buried in a `status` nobody was told to run.
    report_and_consume_prior_unbound($dir);

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
        hold_lease($dir);
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
    # THE OPERATOR-FACING HALF OF THE TTL-MISMATCH FIX (spec SS2.4). The
    # binding window is now stated at the moment the arm is requested,
    # instead of being a constant only bp-session.pl's claim knew about.
    # Deliberately NOT lengthened or unified with the 12h marker TTL --
    # see 13-arming-binds-or-says-so-spec.md SS1/SS5: a ticket whose nonce
    # has not resolved across an hour of Stop events will not resolve
    # later, so lengthening the window only lengthens the ungated gap.
    my $ttl = ticket_ttl();
    emit('TICKET_TTL_S', $ttl);
    emit('BINDS_BY', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() + $ttl)));

    # THE LEASE IS TAKEN AT ARMING TIME, NOT AT BINDING TIME. The ticket does
    # not become a marker until the next Stop, and the turn in between can run
    # for hours — a host that suspends during it loses exactly the work the arm
    # was requested for. any_active() counts tickets for this reason.
    hold_lease($dir);
}

# hold_lease($dir) — assert the wake-lock / busy-lease and make sure something
# is refreshing it, then say so. Never fatal: failing to hold a lock must not
# fail an arm, and — the rule bp-keepawake.pl's header sets out — it must never
# be reported as held when it is not.
sub hold_lease {
    my ($dir) = @_;
    my ($state, $daemon);
    my $ok = eval { ($state, $daemon) = BpContinuityLease::converge($dir); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        chomp $err;
        emit('WARN', "could not hold the keep-awake / busy lease: $err. The arm itself "
                   . 'is in force; the machine may sleep (host) or the container may reap '
                   . 'itself (sandbox) while this session is unattended.');
        return;
    }
    emit('LEASE',        lease_label($dir, just_started => 1));
    emit('LEASE_HOLDER', $daemon);
}

# lease_label($dir, %opt) -> the value to report for LEASE.
#
# REPORTS THE ARTIFACT, NOT THE REQUEST — the discipline bp-keepawake.pl's
# header sets out ("never a false claim of holding one"). sync() returning
# 'held' only means the hold was ASKED for; whether anything is actually
# asserting it is a separate fact, and state() reads it off the artifacts.
#
#   held      the wake-lock helper is alive (host) / the busy-lease is fresh
#             (sandbox).
#   starting  we just asked. keep-awake.ps1 writes its own pid file a moment
#             from now, so an immediate read says nothing yet; this is reported
#             only on the call that did the asking, never by `status`.
#   releasing we just let go, but the artifact has not gone cold yet. Only ever
#             true in a sandbox, where releasing means STOPPING TOUCHING the
#             busy-lease rather than deleting it (it is shared with a fleet
#             run's own lease), so the container stays protected for the rest of
#             the 600s window. Saying "released" there would be wrong in the
#             other direction — the protection is real until the file ages out.
#   disabled  CCPRAXIS_NO_WAKELOCK is set. Nothing is held, on purpose.
#   unsupported  a Linux or macOS HOST, where neither mechanism exists. Arming
#             still gates the Stop; it just does not keep the machine awake.
#   released  nothing is holding it.
sub lease_label {
    my ($dir, %o) = @_;
    return 'disabled' if $ENV{CCPRAXIS_NO_WAKELOCK};
    my $s = eval { BpContinuityLease::state($dir) } // 'released';
    return $s if $s eq 'unsupported' || $s eq 'starting';
    if ($s eq 'held') {
        return $o{just_released} ? 'releasing' : 'held';
    }
    return $o{just_started} ? 'starting' : 'released';
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

    # MEDIUM-3 (redteam)/S4 (review): a disarmed session must not go on
    # reporting `unbound` for an arm it just deliberately cancelled --
    # mirror what arm's own report_and_consume_prior_unbound already does:
    # sweep everything past the 12h cutoff, then consume (unlink) whatever
    # names THIS session specifically, regardless of age. Best-effort and
    # unconditional: cannot fail this command, and it runs whether or not a
    # primary marker exists below.
    sweep_old_tombstones($dir);
    consume_own_tombstones($dir, $sid);

    # An UNBOUND ticket is also an arm, and disarm has to reach it. Otherwise
    # "off" would report not_armed while a ticket sat waiting to bind at the
    # next turn boundary -- arming the session the operator had just switched
    # off. Done before the marker check so it happens on both paths.
    my $ticket_dropped = 0;
    if (my $nonce = read_beacon($dir)) {
        # Bug report 20260922-233054-9a5d (same shape as MEDIUM-1/cmd_status
        # and report_and_consume_prior_unbound's $prior): a beacon value
        # reaches this script with no shape check and becomes a path below
        # ($dir/pending/$nonce, then unlinked) -- validate before either use.
        undef $nonce if defined $nonce && !BpSession::valid_nonce($nonce);
        if (defined $nonce && -f "$dir/pending/$nonce") {
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
            release_lease($dir);
            return;
        }
        emit('STATUS',  'not_armed');
        emit('SESSION', $sid);
        # STILL RE-SYNC THE LEASE. "This session was not armed" says nothing
        # about whether ANY session is, and the common way to reach here is a
        # marker the Stop gate already reaped — i.e. the last arm is gone and
        # something may still be holding the machine awake for it. Skipping the
        # release here left that to the refresher's next tick, which is up to a
        # minute of a lock nobody wants. converge only lets go when the registry
        # is genuinely empty, so this cannot cut another session's lease short.
        release_lease($dir);
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
    release_lease($dir);
}

# release_lease($dir) — the mirror of hold_lease. NOT an unconditional release:
# the lease is machine-level and two sessions can be armed at once, so converge
# re-reads the registry and only lets go when the LAST arm is gone. The
# refresher process reaches the same conclusion within a tick on its own; doing
# it here as well is what makes "off" release immediately rather than eventually.
sub release_lease {
    my ($dir) = @_;
    my $verdict;
    my $ok = eval { ($verdict) = BpContinuityLease::converge($dir); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        chomp $err;
        emit('WARN', "could not release the keep-awake / busy lease: $err "
                   . '(it is leased, so it expires on its own).');
        return;
    }
    # just_released only when this disarm actually let go. If another session is
    # still armed the lease is genuinely, deliberately still HELD, and labelling
    # that "releasing" would tell the operator the machine is about to be free
    # when it is not.
    emit('LEASE', lease_label($dir, just_released => (($verdict // '') eq 'released' ? 1 : 0)));
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

    # LOW-3: bound unbound/'s growth from status too, not only from arm --
    # cheap (a readdir + stat on a directory that is empty in the common
    # case) and this is the read path most likely to be run without anyone
    # ever arming again.
    sweep_old_tombstones($dir);

    unless (-f $mark) {
        # An arm that has not reached a turn boundary yet is not "unarmed" --
        # it is waiting for the Stop hook to confirm which session printed its
        # nonce. Saying "unarmed" here would look exactly like the failure this
        # whole mechanism removes. AND an arm whose ticket reached its binding
        # deadline without ever being claimed is a THIRD state, distinct from
        # both -- see 13-arming-binds-or-says-so-spec.md SS2.3. This decision
        # tree never reads $confidence (done criterion 4): CONFIDENCE is
        # reported alongside whichever STATUS the registry contents alone
        # decide, never used to decide it.
        my $nonce = read_beacon($dir);
        # MEDIUM-1/MEDIUM-4 (redteam): a beacon value reaches this script with
        # no shape check. It becomes a path below ($dir/pending/$nonce,
        # $dir/unbound/$nonce) -- validate before either use, the same rule
        # the gate already enforces on the write side.
        undef $nonce if defined $nonce && !BpSession::valid_nonce($nonce);
        my $ttl   = ticket_ttl();

        if (defined $nonce && -f "$dir/pending/$nonce") {
            my $ticket = "$dir/pending/$nonce";
            my $mtime  = (stat $ticket)[9] // time();
            my $age    = time() - $mtime;

            # LOW-1 (redteam)/S2 (review): use ">" here, matching the only
            # component that actually expires a ticket (bp-session.pl's
            # claim, "(time() - $mtime) > $ttl"). Spec SS2.3 wrote ">=";
            # this is a deliberate erratum -- at age == ttl, claim would
            # still bind the ticket, so declaring it unbound here first
            # (as ">=" did) was the wrong side of the only boundary that
            # matters.
            if ($age > $ttl) {
                # The ticket reached its binding deadline and no Stop hook has
                # run since to record a tombstone -- there may never be one.
                # This is the "no gate run at all" path (behavior 8).
                emit_unbound($sid, $confidence, $nonce, 'window_passed',
                    strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($mtime)));
                return;
            }

            emit('STATUS', 'arming');
            emit('NONCE',  $nonce);
            emit('NOTE', 'a ticket is waiting to bind at the next turn '
                       . 'boundary; nothing is enforced until it does');
            emit('TICKET_TTL_S', $ttl);
            emit('TICKET_AGE_S', $age);
            emit('BINDS_BY', strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($mtime + $ttl)));

            lease_report($dir);

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
            if ($age >= 120 && !BpSession::session_for_nonce($nonce)) {
                emit('WARN', "this ticket has been pending ${age}s and its nonce still "
                           . "resolves to no session, so it may never bind. Arming from "
                           . "inside a subagent cannot bind (its transcript is its own, "
                           . "and no Stop hook reports its id); an ambiguous nonce cannot "
                           . "either. Disarm and re-arm from the main session.");
            }
            return;
        }

        if (defined $nonce && -f "$dir/unbound/$nonce") {
            my ($reason, $since) = read_tombstone("$dir/unbound/$nonce");
            emit_unbound($sid, $confidence, $nonce, $reason, $since);
            return;
        }

        # FALLBACK: no beacon, or the beacon's own nonce matches neither a
        # live ticket nor a tombstone (e.g. this process's
        # CLAUDE_CODE_SESSION_ID differs from the one that armed, so its own
        # beacon is irrelevant). A tombstone the gate wrote names the Stop's
        # own session id in its third field regardless of which nonce it
        # came from -- find it that way instead.
        #
        # NOT AUTHORITATIVE (HIGH-1/S1, redteam+review). The third field is
        # "the session that ran the claim", not "the session that armed" --
        # bp-session.pl's claim expires ANY over-age ticket in the shared
        # registry, not only the caller's, so a stale ticket left behind by
        # session A can be expired by session B's own Stop and tombstoned
        # with B's id. This scan can therefore match a ticket this session
        # never issued. The driver ruling (package 13 fix-batch) is to keep
        # the scan -- AC16/behavior 12 requires it, and it is still the only
        # way a beacon-less session can be told anything at all -- but to
        # stop the WARN from asserting an ownership this branch cannot prove
        # (see emit_unbound's fallback => 1 below; AC16 pins only STATUS and
        # CONFIDENCE on this path, never the WARN wording).
        if (-d "$dir/unbound") {
            my ($best_nonce, $best_reason, $best_since, $best_mtime);
            if (opendir(my $dh, "$dir/unbound")) {
                for my $f (readdir $dh) {
                    next if $f =~ /^\.\.?$/;
                    # MEDIUM-4 (redteam): a raw readdir filename becomes the
                    # NONCE value emitted below with no sanitization -- refuse
                    # anything that is not a nonce this codebase could ever
                    # have written, before it is used for anything.
                    next unless BpSession::valid_nonce($f);
                    my $path = "$dir/unbound/$f";
                    next unless -f $path;
                    my ($reason, $since, $tsid) = read_tombstone($path);
                    next unless defined $tsid && $tsid eq $sid;
                    my $mt = (stat $path)[9] // 0;
                    if (!defined $best_mtime || $mt > $best_mtime) {
                        ($best_nonce, $best_reason, $best_since, $best_mtime)
                            = ($f, $reason, $since, $mt);
                    }
                }
                closedir $dh;
            }
            if (defined $best_nonce) {
                emit_unbound($sid, $confidence, $best_nonce, $best_reason, $best_since,
                    fallback => 1);
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
        lease_report($dir);
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

    lease_report($dir);
}

# lease_report($dir) — say whether the machine is actually being held awake,
# and repair the holder if it has died.
#
# REPORTING THE TRUTH, NOT THE INTENT: state() reads the artifacts, so LEASE
# says what is asserted right now rather than what an arm asked for. A session
# that reports `armed` while the host is free to suspend is watched in name
# only, and the whole point of `status` is to expose exactly that kind of gap
# (it is why GATE_SEEN exists one paragraph up).
#
# It also REPAIRS, because status is the operator's natural "is this still
# fine?" and a dead refresher is the one failure they would otherwise have no
# way to act on. converge is idempotent and starts nothing under a test, so this
# is safe to call from a read-only-looking verb.
sub lease_report {
    my ($dir) = @_;
    my ($verdict, $holder);
    my $ok = eval { ($verdict, $holder) = BpContinuityLease::converge($dir); 1 };
    return unless $ok;
    my $state = lease_label($dir);
    emit('LEASE',        $state);
    emit('LEASE_HOLDER', $holder);

    # THE WARNING HAS TO FIRE ON THE FAILURES THAT ACTUALLY HAPPEN.
    #
    # It used to require LEASE_HOLDER 'refused', which in production is reachable
    # only under CCPRAXIS_NO_WAKELOCK — and that case is excluded on the next
    # line, so it could never fire at all. Every real degradation leaves a live
    # refresher: powershell.exe missing from the HOOK's PATH (which differs from
    # the agent's — the gate carries a .path-probe precisely because of that), a
    # helper killed from outside, a registry that cannot be written. All of those
    # print `LEASE: released / LEASE_HOLDER: running`, which was exactly the
    # armed-but-unprotected state this function exists to expose, reported
    # without comment.
    #
    # 'spawned' is excluded because it means the refresher started moments ago
    # and has not had its first tick — 'released' there is the ordinary startup
    # window, not a fault. 'starting' and 'unsupported' are states, not failures,
    # and say enough on their own.
    emit('WARN', 'the keep-awake / busy lease is NOT held for this armed session. On the '
               . 'host that means the machine may suspend mid-run; in a sandbox it means '
               . 'the container may reap itself. Check that powershell.exe is on PATH '
               . '(host) and that the registry is writable, then re-arm.')
        if $state eq 'released'
        && ($holder eq 'running' || $holder eq 'refused')
        && !$ENV{CCPRAXIS_NO_WAKELOCK};
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

    # A `hold` is the one thing guaranteed to be running through the idle gaps
    # of an armed session, so it refreshes the lease on every slice. This is the
    # CHEAP path (stat + utime, no process), and it is belt to the refresher
    # daemon's braces rather than a replacement for it: a hold only covers the
    # gaps BETWEEN turns, and a long turn has none.
    eval { BpContinuityLease::converge($dir); 1 };
    sleep_until($deadline, sub { eval { BpContinuityLease::refresh($dir); 1 } });

    emit('STATUS',  'hold_elapsed');
    emit('SESSION', $sid);
    exit 0;
}

# sleep_until($epoch, $on_tick) — sleep in bounded slices so a clock jump or a
# signal cannot turn a ten-minute wait into an indefinite one. $on_tick, when
# given, runs once per slice (before the sleep, so a zero-slice wait still
# fires once) — the hook the lease refresh hangs off.
sub sleep_until {
    my ($deadline, $on_tick) = @_;
    $on_tick->() if $on_tick;
    while (1) {
        my $left = $deadline - time();
        last if $left <= 0;
        $left = 60 if $left > 60;
        sleep $left;
        $on_tick->() if $on_tick;
    }
}

# ask --text "..." : QUEUE a question and CARRY ON. It does not end the turn.
#
# THIS REPLACES await-operator, which was a mistake. That verb let a turn end
# because a human had been asked, and the reasoning was that waiting on a person
# is a legitimate way for a turn to finish. It is -- but not here. An armed
# session IS unattended work; that is what arming means. So a verb that ends the
# turn to ask something is, in this context, precisely the halt the gate exists
# to prevent, wearing the gate's own approval. Worse, the block message
# advertised it as one of three equal choices, which invites an agent to reach
# for it the moment it feels unsure.
#
# The operator's account of the pattern: "a whole unattended run halt because of
# some blocking user input. 99% of the times it was not actually necessary and
# could have progressed while batching the question to the end."
#
# So: no verb ends a turn for a question any more. Questions accumulate, the
# statusline shows how many are waiting, and they are answered when the work
# stops for a reason that is actually about the work -- `disarm` when it is
# finished, or the operator returning. If a question genuinely blocks
# everything, the honest report is that the work is finished pending an answer,
# which is `disarm` plus saying so.
sub cmd_ask {
    my $opts = parse_args(qw(text session));

    my $text = $opts->{text};
    unless (defined $text && length $text) {
        emit('STATUS', 'error');
        emit('ERROR',  '--text required: the question to queue');
        exit 1;
    }
    $text =~ s/[\r\n]+/ /g;

    my $p = questions_path();
    unless (defined $p) {
        emit('STATUS', 'error');
        emit('ERROR',  'cannot resolve a questions queue for this project');
        exit 1;
    }
    record_question($text) or do {
        emit('STATUS', 'error');
        emit('ERROR',  "cannot write $p");
        exit 1;
    };

    my $n = count_questions();
    emit('STATUS',   'queued');
    emit('QUEUED',   $n);
    emit('QUEUE',    $p);
    emit('NOTE', 'the question is recorded and the statusline now shows the count. '
               . 'This does NOT end the turn -- carry on with whatever does not '
               . 'depend on the answer, and decide it yourself if it is not a '
               . 'product call.');
}

# Where a deferred question goes: beside the run state, through the verb that
# owns that path. Not in the continuity registry -- the queue is a property of
# the PROJECT's work, and it is read by the statusline and by whatever reports
# at the end, neither of which is session-scoped.
# lease [--daemon] : the wake-lock / busy-lease verb.
#
# Two modes, and they are not variations of each other:
#
#   lease            one-shot. Converge the lease to whatever the registry says
#                    it should be, make sure a refresher is running, print the
#                    result. This is the repair verb — for the Stop gate's
#                    safety net, and for an operator whose holder has died.
#
#   lease --daemon   BLOCKS. This is the refresher itself: re-assert the lease
#                    every tick until nothing is armed any more, then release
#                    and exit. Never run it in the foreground of an agent turn;
#                    `arm` starts it detached.
#
# NOT session-scoped, deliberately. The lease is one machine-level resource; the
# question it answers is "is ANYONE armed", not "am I". Two armed sessions share
# one lock and the last disarm releases it.
sub cmd_lease {
    my $opts = parse_args(qw(daemon! tick session));
    my $dir  = resolve_registry_dir_or_die();

    if ($opts->{daemon}) {
        my %o;
        $o{tick} = $opts->{tick} if defined $opts->{tick} && $opts->{tick} =~ /^\d+$/;
        my $r = BpContinuityLease::daemon_loop($dir, %o);
        emit('STATUS', $r);
        return;
    }

    my ($state, $holder);
    my $ok = eval { ($state, $holder) = BpContinuityLease::converge($dir); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        chomp $err;
        emit('STATUS', 'error');
        emit('ERROR',  $err);
        exit 1;
    }
    emit('STATUS',       $state);
    emit('LEASE',        lease_label($dir, just_started => ($state eq 'held' ? 1 : 0)));
    emit('LEASE_HOLDER', $holder);
    emit('ARMED_ANY',    BpContinuityLease::any_active($dir) ? 'yes' : 'no');
}

# PROJECT-ANCHORED ROOT RESOLUTION — never script-relative. Lifted from
# bp-runstate.pl (package 03, butler-gate-ergonomics deleted that file), which
# is where this lesson was first learned and paid for.
#
# butler normally runs from an INSTALL outside the project (~/.claude/ccpraxis,
# or a marketplace dir), so a script-relative guess like
# Cwd::abs_path("$SCRIPT_DIR/../../..") resolves the INSTALL root, not the
# project. That failed silently and expensively: guard-ask-operator.sh (a
# hook) always carries $CLAUDE_PROJECT_DIR, but a driver's own Bash tool does
# not, so a driver-side write landed under the install root while the hook
# went on reading the project's — the queue was written and read from two
# different directories with nobody ever finding an error. A wrong answer
# anchored to the PROJECT is recoverable; one anchored to the INSTALL is a
# different repo's state file.
#
# Priority mirrors bp-drive-next.pl's _resolve_project_root and
# bp-lib.sh's bp_project_root, and — the four-leg duplication convention this
# file's own header already documents for the continuity registry — this is
# the same rule stated a fourth time, for the questions queue:
#
#   $CLAUDE_PROJECT_DIR > $BP_PROJECT_ROOT > git toplevel
#     > walk up from cwd for a dir holding .ccpraxis-local-data > cwd
#
# CLAUDE_PROJECT_DIR stays first because in a hook it is authoritative and is
# exactly what guard-ask-operator.sh itself uses. The chain ENDS at cwd,
# never at the install dir.
#
# The rule itself now lives once, in BpProjectRoot.pm.
sub _resolve_project_root { return BpProjectRoot::resolve() }

sub questions_path {
    my $root = _resolve_project_root();
    return "$root/.ccpraxis-local-data/.subagent-guard/questions.md";
}

# APPEND, never overwrite. Several questions across a long run are the norm and
# the entire point is that none of them is lost.
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

# count_questions() -> how many are waiting. The statusline reads the same file.
sub count_questions {
    my $p = questions_path() or return 0;
    open my $fh, '<', $p or return 0;
    my $n = 0;
    while (my $l = <$fh>) { $n++ if $l =~ /^\s*-\s/ }
    close $fh;
    return $n;
}


# ── Helpers ────────────────────────────────────────────────

# ticket_ttl() -> the arming ticket's own TTL (CCPRAXIS_CONTINUITY_TICKET_TTL_S),
# defaulting to 3600s -- a SEPARATE and deliberately shorter constant than
# the 12h marker TTL (bp_continuity_ttl_hours). See
# 13-arming-binds-or-says-so-spec.md SS1/SS5: this default is not lengthened
# or unified by this package, on purpose -- the fix is naming the window,
# not moving it. Must agree with bp-session.pl's own claim, which reads the
# same env var independently (that script is outside this write set).
sub ticket_ttl {
    my $t = $ENV{CCPRAXIS_CONTINUITY_TICKET_TTL_S};
    return 3600 unless defined $t && $t =~ /^\d+$/ && $t > 0;
    return $t;
}

# read_tombstone($path) -> ($reason, $since, $sid). Tolerates a missing,
# truncated or empty file (spec SS2.1/SS5): reason defaults to 'expired',
# since to 'unknown', sid to undef. Never dies, never returns a value
# containing a newline (spec SS2.5).
sub read_tombstone {
    my ($path) = @_;
    my $line = '';
    if (open my $fh, '<', $path) {
        $line = <$fh> // '';
        close $fh;
    }
    chomp $line;
    $line =~ s/[\r\n]+/ /g;
    my @f = split ' ', $line;
    my $reason = (defined $f[0] && length $f[0]) ? $f[0] : 'expired';
    my $since  = (defined $f[1] && length $f[1]) ? $f[1] : 'unknown';
    my $tsid   = $f[2];
    return ($reason, $since, $tsid);
}

# read_first_line($path) -> the file's first line, chomped, with any
# embedded newlines collapsed to a space -- used for CLAIM_ERROR, which
# must stay a single-line stdout value like everything else this script
# prints (spec SS2.5).
sub read_first_line {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    my $line = <$fh> // '';
    close $fh;
    chomp $line;
    $line =~ s/[\r\n]+/ /g;
    return $line;
}

# emit_unbound($sid, $confidence, $nonce, $reason, $since, %opt) -- the
# third `status` state (spec SS2.3). Emits, IN THIS ORDER (the spec's own
# words), and returns nothing: STATUS, SESSION, CONFIDENCE, NONCE,
# UNBOUND_REASON, UNBOUND_SINCE, WARN, NOTE. CONFIDENCE is reported
# unconditionally -- this decision tree never reads it to decide the
# STATUS value, only to report it alongside (done criterion 4).
#
# %opt: fallback => 1 marks a call reached through cmd_status's sid-keyed
# scan of unbound/ rather than through this session's own beacon/nonce
# match. HIGH-1/S1 (redteam+review): that scan's match is not proof the
# tombstone is this session's own arm (see the call site's comment), so
# the WARN there must not claim an ownership it cannot establish -- while
# the direct, beacon-matched path (AC1g/AC1h) keeps its original, stronger
# wording unchanged.
sub emit_unbound {
    my ($sid, $confidence, $nonce, $reason, $since, %opt) = @_;
    $reason = 'expired' unless defined $reason && length $reason;
    $since  = 'unknown'  unless defined $since  && length $since;
    emit('STATUS',  'unbound');
    emit('SESSION', $sid);
    emit('CONFIDENCE', $confidence);
    emit('NONCE',   $nonce);
    emit('UNBOUND_REASON', $reason);
    emit('UNBOUND_SINCE',  $since);
    if ($opt{fallback}) {
        emit('WARN', "an arming ticket expired while this session was stopping; it may "
                   . "not have been this session's own arm, so nothing was necessarily "
                   . "gated for this session specifically (found by session id in a "
                   . "registry shared with other sessions, not by this session's own "
                   . "beacon).");
    } else {
        emit('WARN', "an arming ticket did NOT bind, so nothing was gated for this session "
                   . "(CCPRAXIS_CONTINUITY_TICKET_TTL_S is a separate, much shorter TTL than "
                   . "the 12h marker TTL).");
    }
    emit('NOTE', 'this session is not armed. Re-arm with `arm` (or /butler:continuity on) '
               . 'to try again.');
}

# report_and_consume_prior_unbound($dir) -- the arm-time half of surfacing a
# failed binding (spec SS2.4). Runs once, at the top of cmd_arm, before
# either arm path. CONSUMES what it finds (unlinks the tombstone / stale
# ticket / .claim-error record) so a second consecutive arm with no new
# failure reports nothing (behavior 14) -- and supersedes the beacon's own
# prior live ticket (behavior 18), mirroring what cmd_disarm already does.
#
# The "previous arm never bound" WARN is printed FIRST, ahead of
# UNBOUND_PRIOR/UNBOUND_REASON: at this point in cmd_arm nothing else has
# been written to stdout yet, so this is the only place in the whole
# subcommand where a caller can rely on a WARN line beginning the output.
# None of this may fail the arm (spec SS2.4): every unlink here is
# best-effort, and no branch here exits or changes cmd_arm's own STATUS.
sub report_and_consume_prior_unbound {
    my ($dir) = @_;
    my $ttl = ticket_ttl();

    my $prior = read_beacon($dir);
    # MEDIUM-1 (redteam): $prior comes straight off the beacon file with no
    # shape check, and becomes an unlink path twice below -- validate before
    # either use (repro'd: an unvalidated beacon value here was usable for
    # arbitrary file deletion via a path like "../../victim.txt").
    undef $prior if defined $prior && !BpSession::valid_nonce($prior);
    if (defined $prior) {
        my $tomb    = "$dir/unbound/$prior";
        my $pending = "$dir/pending/$prior";
        my $reason;

        if (-f $tomb) {
            ($reason) = read_tombstone($tomb);
        } elsif (-f $pending) {
            my $mtime = (stat $pending)[9] // time();
            # LOW-1 (redteam)/S2 (review): ">" agrees with bp-session.pl's
            # claim, the only component that actually expires a ticket --
            # see the identical comment at cmd_status's own TTL check.
            $reason = 'window_passed' if (time() - $mtime) > $ttl;
        }

        if (defined $reason) {
            emit('WARN', "the previous arm (nonce $prior) never bound to a session, "
                       . "so nothing was gated. Re-arming now supersedes it.");
            emit('UNBOUND_PRIOR', $prior);
            emit('UNBOUND_REASON', $reason);
        }

        # CONSUME/SUPERSEDE regardless of whether a reason was found above --
        # an orphaned ticket whose beacon still names it, or a stale
        # tombstone this arm has now reported, must not linger for a later
        # arm to trip over again (behavior 14, behavior 18).
        unlink $tomb    if -f $tomb;
        unlink $pending if -f $pending;
    }

    # MEDIUM-2 (redteam): `.claim-error` used to be one unkeyed slot shared
    # by every session in the registry -- session B's failing claim could be
    # reported to session A, and a second failure in the same window
    # silently overwrote the first. The gate now keys it per session
    # (`.claim-error-<sid>`) when the sid is filename-safe; read this
    # session's own keyed file first, and fall back to the legacy unkeyed
    # name only when no keyed file exists -- for a claim that failed with an
    # id that could not be used in a filename, and for anything a pre-fix
    # gate left behind.
    my ($ce_keyed, $ce_legacy) = claim_error_candidates($dir);
    my $ce_file = (defined $ce_keyed && -f $ce_keyed) ? $ce_keyed
                : (-f $ce_legacy)                      ? $ce_legacy
                :                                        undef;
    if (defined $ce_file) {
        my $line = read_first_line($ce_file);
        emit('CLAIM_ERROR', $line);
        emit('WARN', "the Stop hook's claim call itself failed for a previous arm "
                   . "(see CLAIM_ERROR above); this session may not have been armed "
                   . "as reported.");
        unlink $ce_file;
    }

    sweep_old_tombstones($dir);
}

# claim_error_candidates($dir) -> ($keyed_path_or_undef, $legacy_path).
# MEDIUM-2 (redteam): the write side (gate-continuity.sh) now keys the
# record per session, same filename-safety refusal continuity_marker
# already applies to a session id. This mirrors that on the read side.
sub claim_error_candidates {
    my ($dir) = @_;
    my $legacy = "$dir/.claim-error";
    my $key = $ENV{CLAUDE_CODE_SESSION_ID};
    return (undef, $legacy) unless defined $key && length $key;
    return (undef, $legacy) if $key =~ m{[/\\*.\x00]};
    return ("$dir/.claim-error-$key", $legacy);
}

# consume_own_tombstones($dir, $sid) -- MEDIUM-3 (redteam)/S4 (review):
# unlink every tombstone in unbound/ whose third field names $sid,
# regardless of age. Called from cmd_disarm so a disarmed session's next
# `status` cannot keep reporting `unbound` about an arm that was
# deliberately cancelled -- the mirror of what report_and_consume_prior_
# unbound already does for arm's own beacon-named tombstone. Best-effort:
# never dies, never changes disarm's own STATUS.
sub consume_own_tombstones {
    my ($dir, $sid) = @_;
    return unless defined $sid && length $sid;
    my $unbound_dir = "$dir/unbound";
    return unless -d $unbound_dir;
    opendir(my $dh, $unbound_dir) or return;
    for my $f (readdir $dh) {
        next if $f =~ /^\.\.?$/;
        next unless BpSession::valid_nonce($f);
        my $path = "$unbound_dir/$f";
        next unless -f $path;
        my (undef, undef, $tsid) = read_tombstone($path);
        unlink $path if defined $tsid && $tsid eq $sid;
    }
    closedir $dh;
}

# sweep_old_tombstones($dir) -- bound the unbound/ directory's growth (spec
# SS5 "Tombstone accumulation"). arm already consumes the one tombstone its
# own beacon names; this catches everything else, aged past the 12h marker
# TTL (the same constant lib.sh's bp_continuity_ttl_hours uses, so a
# tombstone does not outlive what every other artifact in this registry
# considers stale). Best-effort: a failure to sweep is a stat, never an
# error this command reports.
#
# ALSO sweeps stray `.claim-error`/`.claim-error-<sid>` files at the
# registry root past the same cutoff (MEDIUM-2/LOW-3 folded together --
# a session that stops arming, or whose keyed file's owner never arms
# again, must not leave that record on disk forever either).
sub sweep_old_tombstones {
    my ($dir) = @_;
    my $cutoff = 12 * 3600;
    my $now = time();

    my $unbound_dir = "$dir/unbound";
    if (-d $unbound_dir && opendir(my $dh, $unbound_dir)) {
        for my $f (readdir $dh) {
            next if $f =~ /^\.\.?$/;
            my $path = "$unbound_dir/$f";
            next unless -f $path;
            my $mt = (stat $path)[9];
            next unless defined $mt;
            unlink $path if ($now - $mt) >= $cutoff;
        }
        closedir $dh;
    }

    if (-d $dir && opendir(my $rdh, $dir)) {
        for my $f (readdir $rdh) {
            next unless $f =~ /^\.claim-error(?:-|$)/;
            my $path = "$dir/$f";
            next unless -f $path;
            my $mt = (stat $path)[9];
            next unless defined $mt;
            unlink $path if ($now - $mt) >= $cutoff;
        }
        closedir $rdh;
    }
}

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
    # A name given as "foo!" is a BOOLEAN flag: present means true, and it does
    # NOT consume the next argv element. Every flag used to demand a value, so
    # a switch could only be spelled `--daemon 1` — which reads like a typo and
    # invites `--daemon` followed by a real flag being eaten as its argument.
    my %known;
    for my $k (@_) {
        if ($k =~ /^(.+)!$/) { $known{$1} = 'bool' }
        else                 { $known{$k} = 'value' }
    }
    my %opts;
    while (defined(my $arg = shift @ARGV)) {
        unless ($arg =~ /^--([\w-]+)$/ && $known{$1}) {
            emit('STATUS', 'error');
            emit('ERROR',  "Unknown or unexpected argument: $arg");
            exit 1;
        }
        my $key = $1;
        if ($known{$key} eq 'bool') { $opts{$key} = 1; next }
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
