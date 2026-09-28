#!/usr/bin/env perl
# platform: any
# THE HOST CANNOT PROBE A CONTAINER'S PIDS, AND USED TO HAVE NO WAY TO ASK.
#
# A sandboxed run writes its orchestrator and coordinator PIDs from inside the
# container, which has a private PID namespace -- launcher.pl passes no
# --pid=host. kill(0,...) on this host therefore cannot answer for any of them,
# and _pid_alive correctly degrades to UNKNOWN rather than fabricating a "dead"
# (04-run-panel-ledger-truth, CRITICAL-1: never claim a PID is gone because it
# is not yours to probe).
#
# Correct, and useless. It meant the Run panel rendered `orchestrator unknown`
# for the entire life of EVERY sandboxed run. The operator reported it against
# an orchestrator they could see was alive -- pid 303883, present in the
# container's own /proc the whole time (20260915-230820-d33e item 2) -- and the
# same blindness is why finished workers stayed on screen aged from their
# dispatch time, indistinguishable from wedged ones (item 3). Both symptoms,
# one prober: everything that asks "is this still running" goes through
# $RunState::PID_ALIVE.
#
# The container sampler is already exec'ing into the container every poll. It
# now brings back /proc's census, so the host can answer for the namespace the
# markers were actually written in.
#
# THE RULE THIS FILE EXISTS TO PIN. A census that could not be taken must NOT
# collapse into "nothing is running" -- that is the same "unreadable probe read
# as a definite negative" mistake the busy-lease half of this batch was about,
# and it would be worse here: it would mark a live orchestrator dead. Absent
# census -> still UNKNOWN. Present census -> a real answer, both ways.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
ok(-f $LAUNCHER, 'launcher.pl is present') or BAIL_OUT('no launcher to test');
my $SRC = do { local (@ARGV, $/) = ($LAUNCHER); <> };

# ===========================================================================
# A. THE SAMPLER TAKES THE CENSUS.
# ===========================================================================
my ($round) = ($SRC =~ /sub _container_sampler_round \{(.*?)\n\}/s);
ok(defined $round, 'A0: the sampler round is present') or BAIL_OUT('sampler round gone');

like($round, qr/ls \/proc/, 'A1: the round reads the container PID namespace');
like($round, qr/sh -c 'ls \/proc'/,
     'A2: ... through sh -c, so MSYS2 cannot rewrite the path the way it rewrote the lease');
like($round, qr/container_pids/, 'A3: ... and the census reaches the snapshot');
like($round, qr/\@container_pids \? \(container_pids => /,
     'A4: an exec that produced nothing leaves the key ABSENT rather than writing an empty list -- '
     . 'absent is what preserves UNKNOWN downstream');

# ===========================================================================
# B. THE DECISION, EXTRACTED AND EXECUTED.
#
# Same harness container-sampler.t uses for _container_probe_from_snapshot: the
# sub is lifted out of the source and evaluated into a throwaway package, with
# its one I/O call stubbed, so the rule is exercised rather than grepped.
# ===========================================================================
my ($fn)  = ($SRC =~ /(sub _container_pids_fresh \{.*?\n\})/s);
my ($max) = ($SRC =~ /my \$CONTAINER_PIDS_MAX_AGE = (\d+);/);
ok(defined $fn,  'B0: _container_pids_fresh is extractable');
ok(defined $max, 'B0: its staleness bound is a named constant, not a literal');

SKIP: {
    skip 'decision not extractable', 10 unless defined $fn && defined $max;

    our $SNAP;         # what the stubbed reader hands back
    our $READS = 0;    # how many times it was consulted

    my $ok = eval qq{
        package TPID;
        our \%CONTAINER_PIDS;
        our \$CONTAINER_PIDS_AT = 0;
        our \$CONTAINER_PIDS_TTL = 0;
        our \$CONTAINER_PIDS_MAX_AGE = $max;
        sub _container_snapshot_read { \$main::READS++; return \$main::SNAP }
        $fn
        1
    };
    ok($ok, 'B1: the extracted decision evaluates') or diag($@);
    skip 'decision did not evaluate', 8 unless $ok;

    my $now = time;

    # A fresh census answers, both ways.
    $SNAP = { v => 1, measured_at => $now, container_pids => [ 1, 303883, 484592 ] };
    my $pids = TPID::_container_pids_fresh();
    ok(ref $pids eq 'HASH', 'B2: a fresh census is returned');
    ok($pids->{303883},     'B3: ... a PID present in the container answers ALIVE '
                          . '(the exact orchestrator the panel called unknown)');
    ok(!$pids->{999999},    'B4: ... and one absent from it answers DEAD, which is what '
                          . 'lets a finished worker stop looking wedged');

    # No census at all -> decline to answer.
    $SNAP = { v => 1, measured_at => $now };
    is(TPID::_container_pids_fresh(), undef,
       'B5: a snapshot carrying no census yields NO ANSWER, not an empty one');

    # A stale census -> decline to answer. This is the assertion that stops a
    # sampler one round behind from marking a live run dead.
    $SNAP = { v => 1, measured_at => $now - $max - 1, container_pids => [ 1, 303883 ] };
    is(TPID::_container_pids_fresh(), undef,
       'B6: a census older than the bound yields NO ANSWER');

    # ...and the boundary itself is inclusive, so a reading exactly at the
    # bound is still usable. Counter-fixture for B6: proves B6 is measuring
    # staleness rather than always returning undef.
    $SNAP = { v => 1, measured_at => $now - $max, container_pids => [ 1, 303883 ] };
    ok(ref TPID::_container_pids_fresh() eq 'HASH',
       'B7: a census exactly at the bound is still usable');

    # Hostile input is total, never fatal.
    for my $bad (undef, 'not a hash', [], { v => 1, measured_at => 'soon', container_pids => [1] }) {
        $SNAP = $bad;
        my $got = eval { TPID::_container_pids_fresh() };
        ok(!$@, 'B8: hostile snapshot input does not die: ' . (defined $bad ? ref($bad) || $bad : 'undef'));
    }
}

# ===========================================================================
# C. THE PROBER CONSULTS IT -- AND ONLY AFTER ITS OWN ANSWER RUNS OUT.
#
# Order matters. A host PID this process can genuinely probe must keep being
# answered by kill(0,...); the census is the fallback for the case the host
# cannot decide, never a replacement for the case it can.
# ===========================================================================
my ($alive) = ($SRC =~ /sub _pid_alive \{(.*?)\n\}/s);
ok(defined $alive, 'C0: _pid_alive is present') or BAIL_OUT('prober gone');

like($alive, qr/_container_pids_fresh/, 'C1: the prober consults the census');

my $kill_at   = index($alive, 'kill(0, $pid)');
my $census_at = index($alive, '_container_pids_fresh');
cmp_ok($kill_at, '>', -1, 'C2: the signal probe is still there');
cmp_ok($census_at, '>', $kill_at,
       'C3: ... and the census is consulted AFTER it, so a host PID keeps its real answer');

like($alive, qr/return undef;\s*#\s*ESRCH/,
     'C4: with no census available the prober still degrades to UNKNOWN, '
     . 'never to a fabricated dead');

done_testing();
