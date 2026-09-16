#!/usr/bin/env perl
# platform: windows
# THE STOP GATE RACES THE HOLD IT JUST TOLD THE SESSION TO DISPATCH.
#
# An armed session that had done exactly what the continuity skill instructs was
# blocked by its own gate (almanac 20260916-105540-0d46):
#
#     10:54:0x  hold A expires -- its exit is what re-invokes the session
#     10:54:0x  the woken turn dispatches hold B in the background
#     10:54:16  Stop hook reads the record: still hold A's, deadline PASSED -> BLOCKS
#     10:54:17  hold B writes its record
#
# One second. And it is STRUCTURAL, not unlucky: what wakes an armed session is
# the previous hold's own expiry, so a woken turn ALWAYS begins with an expired
# record on disk. The skill instructs that the replacement be taken as a
# BACKGROUND call -- its exit is the next wake-up -- which is precisely what puts
# the write in a race with the gate's read. Every continuity cycle runs it.
#
# So the gate now re-reads across a short bounded window before refusing. The
# wait costs nothing on the permitted path and only delays the outcome that was
# about to block the turn anyway.
#
# THE TWO ASSERTIONS THAT MATTER ARE IN TENSION, and both are here:
#   B -- a record that arrives late is waited for.
#   C -- a record that is present and genuinely invalid is refused AT ONCE.
# Without C this is a gate that pauses three seconds on every real refusal, and
# a slow gate is one an agent learns to route around.
use strict;
use warnings;
# THIS FILE DRIVES gate-continuity.sh, WHICH HOLDS A REAL OS WAKE-LOCK.
#
# Arming is what takes the lock out, and this file arms sessions repeatedly. Set
# BEFORE anything else, because a run that forgets leaves keep-awake processes
# on the host with nothing left that knows to reap them -- the exact failure
# test-wakelock-hygiene.t exists to catch, and which it caught on this file's
# first draft.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Time::HiRes ();
# NOT importing Time::HiRes::time: it shadows core time() and a marker_line
# built from it carries a FRACTIONAL deadline, which parse_line rejects as "no
# deadline". The first draft of this file did that and spent a debugging round
# chasing the gate for a fault in its own fixture.
sub now_hi { Time::HiRes::time() }
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $GATE  = "$HOOKS/gate-continuity.sh";
ok(-f $GATE, 'gate-continuity.sh exists') or BAIL_OUT('no gate');

require BpResumption;

my $SRC = do { local (@ARGV, $/) = ($GATE); <> };

# ===========================================================================
# A. THE RETRY EXISTS, IS BOUNDED, AND IS SELECTIVE.
# ===========================================================================
like($SRC, qr/VERIFY_RETRY_MAX=\d+/,
     'A1: the retry ceiling is a named constant, not a literal buried in the loop');
like($SRC, qr/VERIFY_RETRY\b.*-ge.*VERIFY_RETRY_MAX|-ge "\$VERIFY_RETRY_MAX"/,
     'A2: the loop is bounded -- a gate that hangs is worse than one that refuses');
like($SRC, qr/deadline has passed/,
     'A3: the race-shaped refusal is one of the ones waited out');
like($SRC, qr/\*\)\s*break\s*;;/,
     'A4: every OTHER refusal breaks immediately rather than waiting');

# ===========================================================================
# Harness, matching continuity-gate.t's.
# ===========================================================================
sub marker_path { my ($cdir, $sid) = @_; return "$cdir/$sid" }

sub arm {
    my ($cdir, $sid) = @_;
    open my $fh, '>', marker_path($cdir, $sid) or die "arm: $!";
    print {$fh} "operator\n" . time() . "\n";
    close $fh;
}

sub run_gate {
    my ($cdir, $sid, $cwd) = @_;
    my $payload = JSON::PP->new->canonical->encode({ session_id => $sid, cwd => $cwd });
    my $t0 = now_hi();
    my $out = `CCPRAXIS_CONTINUITY_ACTIVE_DIR='$cdir' bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    return ($rc, $out, now_hi() - $t0);
}

my $root = tempdir(CLEANUP => 1);

# ===========================================================================
# THE HOST'S OWN FAST-REFUSAL COST, MEASURED RATHER THAN ASSUMED.
#
# This gate does real work before it ever reaches the verify -- reading run
# state, checking for a drive-solo run, parsing the payload. On this host that is
# over a second by itself and it moves with load. The first draft of this file
# used absolute second-thresholds, which failed for that reason alone while
# saying nothing about the retry. Every timing assertion below is a MULTIPLE of
# this baseline, so it measures the retry rather than the machine.
#
# A dead holder is the baseline case: a refusal no amount of waiting could
# change, so it must leave the loop on the first pass. That makes this both the
# measurement and an assertion in its own right.
# ===========================================================================
my $BASELINE;
my $GHOST = 999_999;
$GHOST++ while kill(0, $GHOST) && $GHOST < 1_000_050;
SKIP: {
    skip 'no provably-absent pid on this host', 2 if kill(0, $GHOST);
    my $cdir = tempdir(CLEANUP => 1);
    arm($cdir, 'sess-base');
    open my $fh, '>', marker_path($cdir, 'sess-base') . '.wakeup-pending' or die "fixture: $!";
    print {$fh} BpResumption::marker_line(deadline => time() + 600, pid => $GHOST);
    close $fh;
    my ($rc, undef, $el) = run_gate($cdir, 'sess-base', $root);
    isnt($rc, 0, 'BASE-1: a bounded promise from a dead process is refused');
    $BASELINE = $el;
    note(sprintf('baseline fast-refusal cost on this host: %.2fs', $BASELINE));
    cmp_ok($BASELINE, '<', 20, 'BASE-2: ... and the baseline itself is sane');
}
$BASELINE = 2 unless defined $BASELINE;

# ===========================================================================
# B. A RECORD THAT ARRIVES LATE IS WAITED FOR.
#
# Reproduces the measured sequence: an expired record on disk, and a background
# writer that replaces it with a live one a beat later -- exactly what a
# freshly-dispatched `hold` does.
# ===========================================================================
SKIP: {
    my $cdir = tempdir(CLEANUP => 1);
    arm($cdir, 'sess-race');
    my $wp = marker_path($cdir, 'sess-race') . '.wakeup-pending';

    # The expired record the previous hold left behind on its way out.
    open my $fh, '>', $wp or die "fixture: $!";
    print {$fh} BpResumption::marker_line(deadline => time() - 5, pid => $$);
    close $fh;

    # The replacement, landing after the gate has already started reading --
    # a detached writer, which is what makes this a race rather than a fixture.
    my $line = BpResumption::marker_line(deadline => time() + 600, pid => $$);
    my $child = fork();
    skip 'fork unavailable', 3 unless defined $child;
    if (!$child) {
        # LATER THAN THE GATE REACHES ITS FIRST VERIFY. At 0.7s the record landed
        # during the gate's own startup work and it passed on the first read --
        # green, but proving nothing about the retry. The baseline above is what
        # says where that boundary is on this host.
        sleep $BASELINE + 0.8;
        open my $w, '>', $wp or POSIX::_exit(1);
        print {$w} $line;
        close $w;
        POSIX::_exit(0);
    }

    my ($rc, $out, $elapsed) = run_gate($cdir, 'sess-race', $root);
    waitpid($child, 0);

    is($rc, 0, 'B1: the stop is PERMITTED -- the gate waited for the record the session '
             . 'had already dispatched')
        or diag($out);
    cmp_ok($elapsed, '>', $BASELINE + 0.4,
       'B2: ... and it measurably WAITED -- the record landed after the gate had already read once');
    cmp_ok($elapsed, '<', $BASELINE + 12,
       'B3: ... within the bounded window, not indefinitely');
}

# ===========================================================================
# C. A GENUINELY INVALID RECORD IS REFUSED AT ONCE.
#
# Waiting cannot make an unbounded marker bounded. If this ever starts taking
# the full ceiling, every real refusal in every armed session pays for it.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    arm($cdir, 'sess-unbounded');
    my $wp = marker_path($cdir, 'sess-unbounded') . '.wakeup-pending';
    open my $fh, '>', $wp or die "fixture: $!";
    print {$fh} time() . " dispatch - - -\n";     # a dispatch, not a bounded hold
    close $fh;

    my ($rc, $out, $elapsed) = run_gate($cdir, 'sess-unbounded', $root);
    isnt($rc, 0, 'C1: an unbounded marker is still refused');
    cmp_ok($elapsed, '<', $BASELINE * 2 + 0.5,
       'C2: ... IMMEDIATELY -- no refusal that waiting cannot change may pay the retry cost')
        or diag(sprintf('took %.2fs against a %.2fs baseline; the selective case list has '
                      . 'stopped being selective', $elapsed, $BASELINE));
}

done_testing();
