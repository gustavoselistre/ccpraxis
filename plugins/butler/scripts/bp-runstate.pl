#!/usr/bin/env perl
# bp-runstate.pl — the run-state machine behind the stop gate.
#
# WHY IT IS A STATE MACHINE AND NOT A DETECTOR
#
# The first two attempts at this gate both asked "does anything look wrong?" —
# first "did a Bash command mention a guard token", then "does the closing
# prose promise work". Both are detectors, and a detector is only as good as
# its guesses: the token version accepted a guard that died on launch, and the
# prose version can be sidestepped by rephrasing a sentence.
#
# This inverts the default. The gate is INERT until a run actually starts, and
# once active the turn may not end until the agent RESOLVES it — explicitly,
# with a verb, in one of exactly two ways:
#
#   finish  — the run is over. Nothing pending. Back to inert.
#   pause   — the run continues, but something else will wake it. Requires a
#             LIVE watcher (real pid + future deadline), which the gate
#             verifies rather than takes on trust.
#
# There is no third way and no "looks fine to me". Silence is not a resolution.
#
# STATES
#   (absent)  inert   — no run. Stopping is always allowed.
#   active            — work is underway. Stopping is DENIED.
#   paused            — resolved temporarily; a verified watcher will resume it.
#                       Stopping is allowed WHILE the watcher is alive; once it
#                       dies or its deadline passes the pause is stale and the
#                       state reverts to active on the next read.
#   finished          — resolved permanently. Stopping is allowed.
#
# ACTIVATION IS NOT A THING THE AGENT MUST REMEMBER. The hook activates on the
# observable fact that a run started: a background subagent dispatch, or a
# director tick that returned run-package. Anything the agent must remember to
# do is a thing it will eventually forget — that is the whole reason this file
# exists.
#
# SCOPE. Project-level, not session-level: "a run" is a property of the
# project. drive-solo is explicitly one interactive session, so the simpler
# scope is the correct one here. Two concurrent drive sessions in one project
# would share this state; that is out of contract for drive-solo.

package BpRunState;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();
use File::Spec;

# The pause cap: 50 minutes, ~10 minutes of headroom under the provider's
# one-hour prompt-cache TTL (see pause()'s own comment for the full
# reasoning). Exported as a callable constant, not just a lexical inside
# pause(), so any OTHER file that needs to stay under this same cap (e.g.
# bp-watch.pl's --self-pause default) derives it from here instead of
# restating the number as an independent literal that could silently drift.
use constant MAX_PAUSE_SECONDS => 50 * 60;

# The resumption contract -- process liveness and process IDENTITY -- is shared
# with the continuity gate. See BpResumption.pm's header for why these two
# guards keep separate SCOPES but must not keep separate MECHANISMS: both
# lessons below were learned here first, and the continuity gate then shipped a
# liveness check without either, because the knowledge lived in this file rather
# than anywhere it could be reached from.
require File::Spec->catfile(
    dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f }),
    'BpResumption.pm');

# PROJECT-ANCHORED ROOT RESOLUTION — never script-relative.
#
# This file used to fall back to Cwd::abs_path("$DIR/../../.."), i.e. three
# levels up from its OWN location. That is the guess bp-drive-next.pl:1105
# already documents as wrong, and for the same reason: butler normally runs
# from an INSTALL outside the project (~/.claude/ccpraxis, or a marketplace
# dir), so the guess resolves the install root, not the project.
#
# It failed silently and expensively. guard-subagent-stall.sh reads this state
# with --root "$CLAUDE_PROJECT_DIR" — hooks always have that variable — while a
# driver following drive-solo/SKILL.md's own documented `pause` invocation
# passes no --root at all. The Bash tool's environment does NOT carry
# CLAUDE_PROJECT_DIR, so the driver's pause landed under the install root and
# the gate went on reading the project's, where the state was still `active`.
# The pause was well-formed, verified, and invisible: the gate denied every
# Stop, and the run could not advance past its first dispatch.
#
# So resolve the way every other butler entry point does. Priority mirrors
# bp-drive-next.pl's _resolve_project_root and bp-lib.sh's bp_project_root:
#
#   explicit --root > $CLAUDE_PROJECT_DIR > $BP_PROJECT_ROOT > git toplevel
#     > walk up from cwd for a dir holding .ccpraxis-local-data > cwd
#
# CLAUDE_PROJECT_DIR stays first because in a hook it is authoritative and is
# exactly what the reader uses. The chain now ENDS at cwd rather than at the
# install dir: a wrong answer anchored to the project is recoverable, one
# anchored to the install is a different repo's state file.
sub _resolve_project_root {
    return $ENV{BP_PROJECT_ROOT}
        if defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT};

    # git toplevel — trust only a clean exit and a real directory.
    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    if ($? == 0 && defined $top) {
        chomp $top;
        return $top if length $top && -d $top;
    }

    # Walk up from cwd for the first ancestor that already holds .ccpraxis-local-data.
    my $d = Cwd::getcwd();
    if (defined $d && length $d) {
        my %seen;
        while (!$seen{$d}++) {
            return $d if -d "$d/.ccpraxis-local-data";
            my $parent = dirname($d);
            last if $parent eq $d;    # reached the filesystem / drive root
            $d = $parent;
        }
    }

    return Cwd::getcwd() // '.';
}

sub state_dir {
    my ($root) = @_;
    $root //= $ENV{CLAUDE_PROJECT_DIR};
    $root = _resolve_project_root() unless defined $root && length $root;
    return "$root/.ccpraxis-local-data/.subagent-guard";
}

# state_path($root, $surface) -- $surface optional, trailing, default 'driver'.
# 'driver' resolves to the byte-identical pre-existing path
# (.subagent-guard/run-state.json) so every existing caller that never passes
# a surface takes an unchanged route. Any other surface is a SIBLING file
# (run-state.<surface>.json), never the default -- see spec §1.3/§2.3: this is
# what keeps the reporter's own pause/finish/activate contract from
# overwriting the driver's project-scoped record (and vice versa).
sub state_path {
    my ($root, $surface) = @_;
    $surface = 'driver' unless defined $surface && length $surface;
    my $base = state_dir($root);
    return "$base/run-state.json" if $surface eq 'driver';
    return "$base/run-state.$surface.json";
}

# pid_alive / pid_fingerprint now live in BpResumption.pm, shared with the
# continuity gate. These wrappers keep every call site below reading unchanged.
#
# What they encode is worth restating where it is used: kill(0) reports a
# healthy NATIVE Windows process as dead, and -- the one that actually bit --
# a live pid is not the SAME pid once a watcher has exited and the OS recycled
# the number. A red-team demonstrated the second concretely here: an unrelated
# `sleep &` occupying the recorded watcher_pid made a pause read as verified
# with nothing watching.
sub pid_alive       { return BpResumption::pid_alive(@_) }
sub pid_fingerprint { return BpResumption::pid_fingerprint(@_) }

sub _read {
    my ($root, $surface) = @_;
    my $p = state_path($root, $surface);
    open my $fh, '<', $p or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw && length $raw;
    my $j = eval { JSON::PP->new->decode($raw) };
    return (ref $j eq 'HASH') ? $j : undef;
}

sub _write {
    my ($root, $rec, $surface) = @_;
    my $d = state_dir($root);
    unless (-d $d) {
        # mkdir -p, and the leading separator is LOAD-BEARING. An earlier version
        # started $cur at '' and skipped empty components, which turned an
        # absolute "/tmp/x/y" into a RELATIVE "tmp/x/y" and created the whole
        # tree under the current working directory. Reproduced immediately: it
        # left ./tmp/tmp.K4d60R6Qym/... in the repo root — the same stray class
        # as the 576 drive-root entries in CLAUDE.md, from the same root cause
        # of treating an absolute path as relative.
        my $cur = ($d =~ m{^/}) ? '/' : '';
        for my $part (grep { length } split m{/}, $d) {
            $cur = ($cur eq '' || $cur eq '/') ? "$cur$part" : "$cur/$part";
            next if $cur =~ /^[A-Za-z]:$/;      # bare drive letter is not a dir
            unless (-d $cur) { mkdir $cur or return 0 }
        }
        return 0 unless -d $d;
    }
    my $p   = state_path($root, $surface);
    my $tmp = "$p.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($rec);
    close $fh;
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

# effective($root) -> ($state, \%rec)
#
# The ONLY reader anything else should use. It resolves a stale pause back to
# active, which is the property that makes a pause safe to grant: a pause whose
# watcher died is indistinguishable from an abandoned run, so it must not keep
# permitting stops.
sub effective {
    my ($root, $surface) = @_;
    my $rec = _read($root, $surface) or return ('inert', {});
    my $st  = $rec->{state} // 'inert';
    return ($st, $rec) unless $st eq 'paused';

    my $ok = pid_alive($rec->{watcher_pid});
    if ($ok) {
        # fixbatch step7 / HIGH-2: a live pid at the recorded number is
        # NECESSARY but not SUFFICIENT -- it must still be the SAME process
        # `pause` verified, not one the OS handed the number to afterward.
        # `pause` always stores the fingerprint it captured at grant time;
        # its absence (or a live-recompute that cannot be determined, or one
        # that no longer matches) is UNVERIFIABLE, and an unverifiable
        # identity must resolve to NOT-paused -- never to paused.
        my $want = $rec->{watcher_fingerprint};
        my $have = pid_fingerprint($rec->{watcher_pid});
        $ok = (defined $want && defined $have && $want eq $have) ? 1 : 0;
    }
    $ok = 0 if $ok && defined $rec->{until} && $rec->{until} =~ /^\d+$/ && $rec->{until} <= time;
    return ('active', { %$rec, stale_pause => 1 }) unless $ok;
    return ('paused', $rec);
}

sub activate {
    my ($root, $reason, $surface) = @_;
    my ($st, $rec) = effective($root, $surface);
    # Never downgrade an explicit pause into active on a fresh dispatch — the
    # watcher is still live and the agent already resolved this turn.
    return 1 if $st eq 'paused';
    return _write($root, { state => 'active', reason => ($reason // 'run in progress'),
                           updated_at => time }, $surface);
}

sub pause {
    my ($root, %o) = @_;
    my $surface = $o{surface};
    my $pid = $o{watcher_pid};
    return (0, 'a pause needs --watcher-pid: an unwatched pause is just a stop')
        unless defined $pid && $pid =~ /^\d+$/;
    return (0, "watcher pid $pid is not running — a dead watcher cannot resume anything")
        unless pid_alive($pid);
    # fixbatch step7 / HIGH-2: captured NOW, while we know this pid really is
    # the live watcher that just asked for the pause. If this process cannot
    # be fingerprinted, we could never re-verify it later either -- refusing
    # here (rather than granting an unverifiable pause) is the same
    # safe-direction discipline effective() applies on the read side.
    my $fp = pid_fingerprint($pid);
    return (0, "could not verify the identity of watcher pid $pid — a bare pid is not enough to "
             . "hold a pause open against; refusing rather than trusting it blindly")
        unless defined $fp;
    my $until = $o{until};
    return (0, 'a pause needs --until (epoch seconds): an unbounded pause never resumes')
        unless defined $until && $until =~ /^\d+$/;
    return (0, "--until $until is in the past")
        unless $until > time;

    # --- MAX_PAUSE_SECONDS: a pause may not outlive the prompt cache ---------
    #
    # An interactive driver's whole conversation is held in the provider's
    # prompt cache, whose TTL for these sessions is ONE HOUR. A pause longer
    # than that wakes a session whose context has gone cold: every turn of the
    # run has to be re-read before the first useful thing happens, which is the
    # single most expensive way a long run can resume. Operator's call,
    # 2026-09-11, after a driver armed a 58-minute pause -- inside the hour, but
    # with no margin for the wake-up itself to be late. MAX_PAUSE_SECONDS
    # (declared above) leaves ~10 minutes of headroom against that TTL.
    #
    # WHY CLAMP RATHER THAN REFUSE. Refusing is the more usual discipline in
    # this file, and every other check above refuses -- but those checks all
    # reject a pause that would be WRONG (a dead watcher, a past deadline, an
    # unverifiable pid), where granting it is the unsafe direction. This one is
    # different: the pause is well-formed, it is merely too long, and clamping
    # can only ever make the gate MORE conservative. A shorter pause cannot hold
    # the gate open for a stalled run; it just wakes the driver sooner, which
    # costs one cheap re-check. Refusing, by contrast, risks a retry loop
    # against a gate whose entire purpose is to keep a run moving -- paying a
    # wedge to prevent something harmless.
    #
    # It is not a SILENT clamp: the returned message states the deadline
    # actually recorded and says it was shortened, so a caller that reads its
    # own output cannot come away believing it has longer than it does.
    my $max_pause  = MAX_PAUSE_SECONDS;
    my $cap_until  = time + $max_pause;
    my $asked      = $until;
    $until = $cap_until if $until > $cap_until;
    # --- t10-run-continuity-gaps: the HOLLOW PAUSE ---------------------------
    #
    # Closes almanac report 20260819-123218-45c3, which the operator noticed
    # live ("dont know why you stopped and why the stop hook didn't catch
    # that") after a run idled roughly seven hours.
    #
    # Everything above verifies that a pause is WELL-FORMED: the watcher pid is
    # running, its identity is fingerprinted, the deadline is in the future.
    # None of it establishes that any WORK is in flight. A backgrounded sleep
    # loop armed solely to satisfy the gate passes every check, and a turn that
    # ends with every dispatched agent already finished and nothing new
    # dispatched is then permitted -- with nothing scheduled to wake the
    # session. That is the very failure the gate's own message describes; the
    # gate prevented the unresolved version and allowed a well-formed empty one.
    #
    # THIS WARNS. IT DOES NOT BLOCK, and the report itself argued for that: the
    # hook cannot see the harness's agent table, so any attempt to prove work is
    # pending would be a guess, and a wrong guess here blocks a CORRECT run --
    # strictly worse than the gap it closes (done-criterion 4). A warning costs
    # nothing when wrong and is visible in the transcript at the exact moment
    # the driver can still fix it.
    #
    # WHAT IT CAN HONESTLY CHECK is the one thing the caller alone knows: what
    # the watcher is waiting FOR. `--watching` is that declaration. An absent or
    # timer-shaped one is the signature of a pause armed for the gate rather
    # than for the work, and it is recorded in the state so a later reader --
    # and the gate's own stale-pause message -- can say so rather than
    # rediscovering it.
    #
    # A self-declaration is weaker evidence than an observation, and calling it
    # anything else would repeat the mistake the FIRST version of the stall
    # guard made (it accepted a Bash command that merely CONTAINED a token,
    # verifying ceremony rather than function). The difference is that this one
    # does not gate on the answer: nothing is permitted or refused because of
    # it, so there is nothing for a ceremony to buy.
    my $watching = $o{watching};
    $watching = undef unless defined $watching && !ref($watching) && $watching =~ /\S/;
    my $hollow = 0;
    if (!defined $watching) {
        $hollow = 1;
    } elsif ($watching =~ /^\s*(?:sleep|timer|wait|watcher|nothing|n\/?a|-+)\s*$/i) {
        # A watcher described only as a timer IS only a timer.
        $hollow = 1;
    }

    _write($root, { state => 'paused', reason => ($o{reason} // 'waiting on a watcher'),
                    watcher_pid => $pid + 0, watcher_fingerprint => $fp,
                    (defined $watching ? (watching => $watching) : ()),
                    hollow_pause => $hollow,
                    until => $until + 0, updated_at => time }, $surface)
        or return (0, 'could not write the run state');

    # --- HOLD THE WAKE-LOCK. A paused run is a run that must survive the wait.
    #
    # The lease was going unheld for most of a live drive-solo run, and the
    # cause is a chicken-and-egg between two mechanisms that each assumed the
    # other:
    #
    #   * bp-keepawake.pl's helper self-expires after 900s unless something
    #     refreshes its pid file.
    #   * Only the DIRECTOR (bp-drive-next.pl) ever creates the first lease.
    #     bp-watch.pl's --keepawake deliberately refuses to spawn one
    #     (bp-watch.pl:549) so it can never become a second, independent
    #     lock-holder -- it refreshes an existing lease and is otherwise a
    #     no-op.
    #   * But the director only runs when the DRIVER calls it, and a driver
    #     deep inside one long package does not call it for hours.
    #
    # So the moment the lease lapses, the only thing that could restore it is
    # the one thing that is not running. Measured 2026-09-11: ~80 minutes of a
    # live run with no wake-lock at all, on a host that sleeps.
    #
    # `pause` is the right place to close it because `pause` is the one call a
    # driver CANNOT skip: guard-subagent-stall.sh denies the turn end without
    # it. Tying the lease to it makes the lease exactly as reliable as the gate
    # that is already enforced, rather than depending on a loop the driver may
    # legitimately not be in.
    #
    # Safe by construction in the two places that would otherwise be hazards.
    # bp-keepawake.pl's own spawn() returns undef when $0 ends in ".t", so a
    # test calling pause() can never leak an immortal OS wake-lock (that guard
    # exists because 53 leaked helpers once filled this machine). And apply()
    # is idempotent: a live lease is refreshed, never duplicated.
    #
    # Driver surface only. The reporter pauses on its own surface and does not
    # own the run's machine-level lifetime.
    if (!defined $surface || $surface eq 'driver') {
        eval {
            my $scriptdir = dirname(do {
                (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f
            });
            require File::Spec->catfile($scriptdir, 'bp-keepawake.pl');
            my $r = $root // $ENV{CLAUDE_PROJECT_DIR};
            $r = _resolve_project_root() unless defined $r && length $r;
            BpKeepAwake::apply('active', "$r/.ccpraxis-local-data/.drive-solo", {});
            1;
        };
        # Never fatal: failing to hold a wake-lock must not refuse a pause that
        # is otherwise valid. The run continuing matters more than the machine
        # staying awake.
    }

    my $msg = "paused until $until, watched by pid $pid";
    $msg .= "\nNOTE: --until was shortened from $asked to $until ("
          . int($max_pause / 60) . "-minute cap). A pause may not outlive this"
          . "\n  session's prompt cache, or the run resumes with a cold context and has to"
          . "\n  re-read every turn before doing anything useful. Re-pause when this expires"
          . "\n  if the work is still in flight."
        if $asked > $until;
    $msg .= "\nWARNING: this pause names nothing it is waiting FOR"
          . (defined $watching ? " (--watching '$watching' describes a timer, not work)" : ' (no --watching given)')
          . ".\n  A live pid is not evidence that anything is in flight. If every dispatched"
          . "\n  worker has already finished and nothing new was dispatched, this pause will"
          . "\n  simply idle until its deadline and then go stale -- which is the same end"
          . "\n  state as an unattended run dying, only later. Dispatch first, then pause."
        if $hollow;
    return (1, $msg);
}

sub finish {
    my ($root, $reason, $surface) = @_;
    _write($root, { state => 'finished', reason => ($reason // 'run complete'),
                    updated_at => time }, $surface)
        or return (0, 'could not write the run state');
    return (1, 'run finished; the gate is inert again');
}

package main;
use strict;
use warnings;

unless (caller) {
    my $cmd  = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--reason')      { $o{reason}      = shift @ARGV }
        elsif ($a eq '--watcher-pid') { $o{watcher_pid} = shift @ARGV }
        elsif ($a eq '--until')       { $o{until}       = shift @ARGV }
        elsif ($a eq '--seconds')     { $o{seconds}     = shift @ARGV }
        # t10: what the watcher is waiting FOR. Never gates anything; its
        # absence produces a warning, never a refusal (see BpRunState::pause).
        elsif ($a eq '--watching')    { $o{watching}    = shift @ARGV }
        elsif ($a eq '--root')        { $o{root}        = shift @ARGV }
        elsif ($a eq '--surface')     { $o{surface}     = shift @ARGV }
        else { print STDERR "bp-runstate: unknown option '$a'\n"; exit 3 }
    }
    my $root = $o{root};

    # A typo must fail LOUDLY at parse time, never silently write to a
    # garbled filename (spec §2.3). Validated once, here, before any verb
    # dispatch -- 'driver' (the default) always passes this, so an omitted
    # --surface never hits this check at all.
    if (defined $o{surface}) {
        if (!length($o{surface}) || $o{surface} !~ /^[a-z][a-z0-9_-]*$/) {
            print STDERR "bp-runstate: invalid --surface '$o{surface}' (must match ^[a-z][a-z0-9_-]*\$)\n";
            exit 3;
        }
    }
    my $surface = $o{surface};

    # state-dir: print where this surface's state lives, for callers that need
    # to put something BESIDE it (the deferred-question queue). Exposed as a
    # verb rather than letting each caller rebuild the path -- that rule is
    # already duplicated more than it should be, and a queue written to a
    # different directory than the one the run is read from is a queue nobody
    # finds.
    if ($cmd eq 'state-dir') {
        print BpRunState::state_dir($root), "\n";
        exit 0;
    }

    if ($cmd eq 'status') {
        my ($st, $rec) = BpRunState::effective($root, $surface);
        # ORDER MATTERS: the record's own `state` is what was WRITTEN; $st is
        # what it EFFECTIVELY is now (a pause whose watcher died reads back as
        # active). Spreading %$rec last would let the stored value clobber the
        # computed one, and a stale pause would go on permitting stops — the
        # exact hole the reversion exists to close. Caught by t/112.
        print JSON::PP->new->canonical->encode({ %$rec, state => $st }), "\n";
        exit 0;
    }
    elsif ($cmd eq 'activate') {
        BpRunState::activate($root, $o{reason}, $surface) or exit 4;
        exit 0;
    }
    elsif ($cmd eq 'pause') {
        # --until is the explicit, lower-level form (an exact epoch); --seconds
        # is the ergonomic one (a duration from now); omitting BOTH defaults to
        # the full 50-minute cap -- a caller with nothing shorter to say should
        # never have to compute time()+1800 by hand to get the common case.
        # --until wins if both are given.
        if (!defined $o{until}) {
            my $secs = defined $o{seconds} ? $o{seconds} : BpRunState::MAX_PAUSE_SECONDS();
            if ($secs !~ /^\d+$/) {
                print STDERR "bp-runstate: --seconds must be a non-negative integer\n";
                exit 3;
            }
            $o{until} = time + $secs;
        }
        my ($ok, $msg) = BpRunState::pause($root, %o);
        print STDERR "bp-runstate: pause refused: $msg\n" unless $ok;
        print "$msg\n" if $ok;
        exit($ok ? 0 : 2);
    }
    elsif ($cmd eq 'finish') {
        my ($ok, $msg) = BpRunState::finish($root, $o{reason}, $surface);
        print STDERR "bp-runstate: $msg\n" unless $ok;
        print "$msg\n" if $ok;
        exit($ok ? 0 : 4);
    }
    else {
        print STDERR <<'USAGE';
bp-runstate.pl — the run-state behind the stop gate.

  status                                   print the effective state as JSON
  activate [--reason R]                    mark a run underway (the hook does
                                           this automatically; rarely manual)
  pause --watcher-pid N [--seconds S | --until EPOCH] [--watching W] [--reason R]
                                           resolve THIS turn: something live
                                           will wake the session. Neither
                                           --seconds nor --until given defaults
                                           to the full 50-minute cap; --seconds
                                           is a duration from now, --until an
                                           exact epoch (wins if both given).
                                           Refused if the pid is not running or
                                           the deadline is not in the future.
  finish [--reason R]                      resolve permanently: nothing pending

  --surface NAME       (all verbs, optional, default 'driver') scopes the
                        state to an independent record -- 'driver' resolves
                        to the pre-existing run-state.json path unchanged;
                        any other NAME (^[a-z][a-z0-9_-]*\$) writes/reads a
                        sibling run-state.NAME.json, never colliding with the
                        default. e.g. --surface reporter for the reporter's
                        own bp-watch.pl-backed pause/finish contract.

Stopping is DENIED while the state is active. `pause` and `finish` are the only
two resolutions; there is no third.
USAGE
        exit 3;
    }
}
1;
