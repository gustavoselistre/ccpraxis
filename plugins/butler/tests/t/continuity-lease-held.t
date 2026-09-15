#!/usr/bin/env perl
# An ARMED session holds the machine awake, on both platforms, until it is
# turned off.
#
# WHAT THIS PINS, AND WHY IT IS NOT PARANOIA.
#
# `/butler:continuity on` exists for unattended work with no blueprint, no
# drive-solo and no reporter — i.e. for exactly the sessions where nothing else
# holds a wake-lock and nobody is watching. It held nothing. On the host that
# means Windows connected standby ends the run mid-turn (the 3c661a0 signature:
# a watchdog armed for 1800s reporting 7962s elapsed); in a sandbox it means
# heartbeat.sh reaps the container out from under it. Both are silent.
#
# The properties below are the whole contract, and each has a way of being
# quietly wrong that this file is here to catch:
#
#   * BOTH PLATFORMS. The host holds a wake-lock, a container holds the
#     busy-lease, and a host can only ever execute one of the two branches — so
#     the other is pinned through the $PLATFORM seam rather than left to drift.
#   * UNTIL TURNED OFF. The lease survives the arm, not just the call that took
#     it out; the refresher re-asserts it every tick and stops only when nothing
#     is armed any more.
#   * CONCURRENT SESSIONS. The lease is one machine-level resource. Disarming
#     one of two armed sessions must NOT release it.
#   * THE SHARED BUSY FILE IS NEVER UNLINKED. bp-orchestrator.pl writes the same
#     path; deleting it on disarm would cancel a live fleet run's lease.
#   * NO PROCESS IS EVER STARTED BY A TEST. The actuator refuses under a .t, so
#     the suite cannot leak an immortal holder — the 2026-08-13 failure, one
#     level over.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpContinuityLease.pm";
require "$S/bp-keepawake.pl";

# Never let this file touch the real busy-lease or the real registry, and never
# let an AMBIENT value decide an assertion. Caught in the sandbox: run with
# CCPRAXIS_CONTINUITY_LEASE_TICK=3 exported (as an operator debugging a holder
# would), the "default cadence is 60s" case failed — the suite was reading the
# shell's opinion rather than the code's.
my $BUSY = tempdir(CLEANUP => 1) . '/busy';
delete $ENV{$_} for qw(
    CCPRAXIS_NO_WAKELOCK
    CCPRAXIS_CONTINUITY_TTL_H
    CCPRAXIS_CONTINUITY_LEASE_TICK
    CCPRAXIS_CONTINUITY_ACTIVE_DIR
    BP_BUSY_PATH
);

sub reg {
    my $d = tempdir(CLEANUP => 1);
    make_path("$d/pending");
    return $d;
}
sub mk { my ($p, $age) = @_; open my $fh, '>', $p or die $!; print {$fh} "x\n"; close $fh;
         if ($age) { my $t = time - $age; utime($t, $t, $p) } return $p }

# ------------------------------------------------------- any_active ---------
{
    my $d = reg();
    is(BpContinuityLease::any_active($d), 0, 'empty registry -> nothing armed');

    mk("$d/sessone");
    is(BpContinuityLease::any_active($d), 1, 'a bound marker -> armed');

    # Past the TTL it stops counting, WITHOUT being deleted: this runs in a
    # detached process, and a background process silently removing another
    # session's state is worse than one that merely stops holding a lock.
    utime(time - 13 * 3600, time - 13 * 3600, "$d/sessone");
    is(BpContinuityLease::any_active($d), 0, 'a marker past the TTL -> not armed');
    ok(-f "$d/sessone", 'and it is NOT reaped here — that is the Stop hook\'s job');
    unlink "$d/sessone";

    # A pending ticket is an arm too. The turn between `arm` and the Stop that
    # binds it can run for hours, and that is a turn the machine must stay up
    # for — counting only bound markers would leave exactly that gap open.
    mk("$d/pending/abc123");
    is(BpContinuityLease::any_active($d), 1, 'an unbound pending ticket -> armed');
    utime(time - 13 * 3600, time - 13 * 3600, "$d/pending/abc123");
    is(BpContinuityLease::any_active($d), 0, 'a ticket past the TTL -> not armed');
    unlink "$d/pending/abc123";

    # Our own bookkeeping must never read as an arm, or the lease would hold
    # itself up forever off the artifacts it just created.
    mk("$d/keepawake.pid");
    mk("$d/lease.pid");
    mk("$d/lease.lock");
    mk("$d/sessone.wakeup-pending");
    is(BpContinuityLease::any_active($d), 0,
       'dotted names (our pid/lock files, marker companions) are never mistaken for arms');
}

# ------------------------------------------------- platform split -----------
{
    my $d = reg();

    # --- POSIX / sandbox: the busy-lease is the mechanism -------------------
    local $BpContinuityLease::PLATFORM = 'posix';
    unlink $BUSY;
    is(BpContinuityLease::sync($d, active => 1, busy_path => $BUSY), 'held',
       'posix: sync(active) reports held');
    ok(-f $BUSY, 'posix: the busy-lease file exists after a hold');

    my $old = time - 400;
    utime($old, $old, $BUSY);
    BpContinuityLease::refresh($d, busy_path => $BUSY);
    cmp_ok((stat($BUSY))[9], '>', $old, 'posix: refresh() bumps the busy-lease mtime');

    is(BpContinuityLease::state($d, busy_path => $BUSY), 'held',
       'posix: a fresh busy-lease reads as held');
    utime(time - 700, time - 700, $BUSY);
    is(BpContinuityLease::state($d, busy_path => $BUSY), 'released',
       'posix: a busy-lease older than the 600s window reads as released');

    # THE FILE IS SHARED WITH bp-orchestrator.pl. Releasing must mean "stop
    # touching it", never "delete it" — a fleet run's own lease lives here too.
    is(BpContinuityLease::sync($d, active => 0, busy_path => $BUSY), 'released',
       'posix: sync(inactive) reports released');
    ok(-f $BUSY, 'posix: release leaves the shared busy-lease file in place');
}

{
    my $d = reg();

    # --- Windows / host: the wake-lock is the mechanism ---------------------
    local $BpContinuityLease::PLATFORM = 'windows';
    my (@spawned, @killed);
    my %seams = (
        spawn                => sub { my $pf = shift; open my $w, '>', $pf or die $!;
                                      print {$w} "424242\n"; close $w; push @spawned, $pf; 424242 },
        kill_pid             => sub { push @killed, $_[0] },
        powershell_available => sub { 1 },
    );

    is(BpContinuityLease::sync($d, active => 1, %seams), 'held', 'windows: sync(active) holds');
    is(scalar @spawned, 1, 'windows: the wake-lock helper is started exactly once');
    ok(-f "$d/keepawake.pid", 'windows: the helper records a pid file');

    # Idempotence: a second hold must not double the helper. $$ is alive.
    open my $w, '>', "$d/keepawake.pid" or die $!; print {$w} "$$\n"; close $w;
    BpContinuityLease::sync($d, active => 1, %seams);
    is(scalar @spawned, 1, 'windows: a live lock is left alone, never doubled');

    my $old = time - 400;
    utime($old, $old, "$d/keepawake.pid");
    BpContinuityLease::refresh($d);
    cmp_ok((stat("$d/keepawake.pid"))[9], '>', $old,
           'windows: refresh() bumps the pid file — the heartbeat keep-awake.ps1 leases off');

    is(BpContinuityLease::state($d, pid_alive => sub { 1 }), 'held',
       'windows: a live helper pid reads as held');
    is(BpContinuityLease::state($d, pid_alive => sub { 0 }), 'released',
       'windows: a recorded-but-dead helper reads as released, not as held');

    is(BpContinuityLease::sync($d, active => 0, %seams), 'released', 'windows: sync(inactive) releases');
    is(scalar @killed, 1, 'windows: release kills the recorded helper');
    ok(!-e "$d/keepawake.pid", 'windows: release removes the pid file (keep-awake.ps1 exits on that alone)');
    is(BpContinuityLease::state($d), 'released', 'windows: nothing recorded -> released');
}

# ------------------------------------- refresh never STARTS anything --------
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'windows';
    is(BpContinuityLease::refresh($d), 0, 'windows: refresh with no helper running does nothing');
    ok(!-e "$d/keepawake.pid",
       'windows: refresh never creates a pid file — starting a helper is sync()\'s decision alone, '
       . 'and the Stop gate calls refresh on EVERY turn end');

    # AN EMPTY PID FILE IS A CLAIM, NOT A LOCK. BpKeepAwake writes it
    # immediately before spawning and keep-awake.ps1 fills it a second later;
    # its AGE is the only thing that can ever expire it. Refreshing it would
    # freeze a claim whose helper died at birth into a permanent "starting".
    open my $c, '>', "$d/keepawake.pid" or die $!; close $c;
    my $born = time - 20;
    utime($born, $born, "$d/keepawake.pid");
    is(BpContinuityLease::refresh($d), 0, 'windows: an unfilled claim is not refreshed');
    is((stat("$d/keepawake.pid"))[9], $born, 'windows: and its mtime — its only expiry — is untouched');
}

# ------------------------------- the spawn race that made fifteen helpers ---
#
# Measured 2026-09-15: three concurrent arms plus a refresher left FIFTEEN live
# keep-awake.ps1 processes. spawn() returns as soon as fork+exec is away, but
# the helper does not write its pid until PowerShell has started — so every
# caller inside that window saw an empty registry and started another one. Both
# halves of the fix are pinned here.
{
    my $d = tempdir(CLEANUP => 1);
    my @spawned;
    my %seams = (
        # A REALISTIC spawn seam: it returns without writing a pid, exactly as
        # the real one does. A seam that writes the pid file itself cannot
        # reproduce this bug, which is why it went unnoticed.
        spawn                => sub { push @spawned, $_[0]; 4242 },
        powershell_available => sub { 1 },
    );

    BpKeepAwake::apply('active', $d, \%seams);
    is(scalar @spawned, 1, 'apply: the first call starts one helper');
    ok(-e "$d/keepawake.pid", 'apply: and claims the pid file BEFORE the helper can write it');
    ok(-z "$d/keepawake.pid", 'apply: the claim is empty — the helper fills it when it comes up');

    BpKeepAwake::apply('active', $d, \%seams);
    BpKeepAwake::apply('active', $d, \%seams);
    is(scalar @spawned, 1,
       'apply: further calls while the helper is still starting do NOT start more — '
     . 'this is the fifteen-helper storm, and it is the whole reason the claim exists');

    # A claim that never fills IS eventually replaced: a helper that died at
    # birth must not suppress every future attempt.
    my $old = time - (BpKeepAwake::starting_grace_seconds() + 5);
    utime($old, $old, "$d/keepawake.pid");
    BpKeepAwake::apply('active', $d, \%seams);
    is(scalar @spawned, 2, 'apply: a claim past the starting grace is replaced');
}
{
    # And a failed spawn leaves no claim behind to suppress the next attempt.
    my $d = tempdir(CLEANUP => 1);
    BpKeepAwake::apply('active', $d, {
        spawn                => sub { die "no powershell today\n" },
        powershell_available => sub { 1 },
        log                  => sub { },
    });
    ok(!-e "$d/keepawake.pid", 'apply: a spawn that dies leaves no unfillable claim');
}

# ------------------------------------------------------ converge -----------
#
# ONE PROCESS MAY START THE WAKE-LOCK, AND IT IS THE REFRESHER. Every other
# caller — arm, disarm, status, the repair verb, the Stop gate — goes through
# converge, which re-asserts what is running and delegates starting. Without
# that rule three simultaneous arms each decided the lock was missing and each
# started one; with it they decide nothing at all.
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'windows';
    my @daemons;

    mk("$d/sessone");
    my ($verdict, $holder) = BpContinuityLease::converge($d,
        powershell_available => sub { die "converge must not even ask about powershell\n" },
        spawn                => sub { push @daemons, $_[0]; 7777 });
    is($verdict, 'held', 'converge: armed -> held');
    is($holder,  'spawned', 'converge: and it starts the refresher');
    ok(!-e "$d/keepawake.pid",
       'converge: no wake-lock helper and not even a claim — starting one is the refresher\'s '
     . 'job alone, and three arms in the same instant is what made fifteen of them');

    # The holder comes back from the SAME call. Asking ensure_daemon again in
    # the second before the daemon writes its pid file would start a second one.
    is(scalar @daemons, 1, 'converge: exactly one refresher, from one decision');

    # Nothing armed -> release, immediately, from whichever process noticed.
    unlink "$d/sessone";
    open my $w, '>', "$d/keepawake.pid" or die $!; print {$w} "424242\n"; close $w;
    my @killed;
    my ($v2, $h2) = BpContinuityLease::converge($d, kill_pid => sub { push @killed, $_[0] },
                                                    powershell_available => sub { 1 },
                                                    spawn => sub { die "must not spawn\n" });
    is($v2, 'released', 'converge: nothing armed -> released');
    is($h2, 'idle',     'converge: and no refresher is wanted');
    is(scalar @killed, 1, 'converge: release happens in-process, not at some later daemon tick');
}

# --------------------------------------------- ensure_daemon decisions ------
{
    my $d = reg();
    my @spawns;
    my %seam = (spawn => sub { push @spawns, $_[0]; 4242 });

    is(BpContinuityLease::ensure_daemon($d, %seam), 'idle',
       'nothing armed -> no refresher is started');
    is(scalar @spawns, 0, 'and nothing was spawned');

    mk("$d/sessone");
    is(BpContinuityLease::ensure_daemon($d, %seam), 'spawned', 'armed with no holder -> spawn');
    is(scalar @spawns, 1, 'exactly one');

    # Liveness is the pid file's HEARTBEAT, not the recorded pid: MSYS perl's $$
    # is an MSYS pid that neither kill(0) nor tasklist can validate (measured —
    # a live daemon recorded 16818 and tasklist reported no such task), so a
    # pid-based check would report every healthy daemon dead and respawn on
    # every call. That is the 2026-08-13 leak's exact shape.
    mk("$d/lease.pid");
    is(BpContinuityLease::ensure_daemon($d, %seam), 'running', 'a fresh heartbeat -> leave it alone');
    is(scalar @spawns, 1, 'no second refresher');

    utime(time - 3600, time - 3600, "$d/lease.pid");
    is(BpContinuityLease::ensure_daemon($d, %seam), 'spawned', 'a stale heartbeat -> restart it');
    is(scalar @spawns, 2, 'restarted once');

    # A seam that cannot start anything must not be reported as if it had.
    is(BpContinuityLease::ensure_daemon($d, spawn => sub { undef }), 'refused',
       'a spawn that returns nothing is reported as refused, never as spawned');

    local $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    is(BpContinuityLease::ensure_daemon($d, %seam), 'refused',
       'CCPRAXIS_NO_WAKELOCK refuses outright');
}

# ------------------------------------------- THE SUITE CANNOT LEAK ONE ------
{
    my $d = reg();
    mk("$d/sessone");
    # No seam: this reaches the production actuator, which must refuse because
    # $0 ends in .t.
    #
    # SCOPE THE CLAIM. This proves only that an IN-PROCESS call cannot leak a
    # holder. It says nothing about a test that shells out — the child's $0 is a
    # .pl and this guard never sees it, which is how t/runstate-pause-holds-lease.t
    # started a real keep-awake.ps1 on every run for as long as it existed.
    # CCPRAXIS_NO_WAKELOCK is what covers that, per file and in run-tests.pl,
    # and t/test-wakelock-hygiene.t is what keeps it covered.
    is(BpContinuityLease::ensure_daemon($d), 'refused',
       'the real spawn path refuses inside a .t — an in-process call cannot leak a holder');
    ok(!-e "$d/lease.pid", 'and no refresher pid file was written');
}

# --------------------------------------- a LINUX/macOS HOST holds nothing ---
#
# The third platform, and the one that would otherwise be lied about. There is
# no SetThreadExecutionState and no heartbeat.sh or dashboard reading
# /tmp/.butler-busy, so writing that file would be a lease in name only — and
# state() would then report "held" off the file it had just created, the one
# thing bp-keepawake.pl's header forbids outright.
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'unsupported';
    mk("$d/sessone");
    unlink $BUSY;

    is(BpContinuityLease::state($d, busy_path => $BUSY), 'unsupported',
       'an unsupported host says so rather than claiming a lease');
    is(BpContinuityLease::refresh($d, busy_path => $BUSY), 0, 'refresh does nothing there');
    BpContinuityLease::sync($d, active => 1, busy_path => $BUSY);
    ok(!-e $BUSY,
       'and sync writes no busy-lease — a file nothing reads is not a lock, and reporting '
     . 'it as one is exactly the false claim this whole mechanism is built to avoid');
}

# ---------------------------------------------- the tick cannot run wild ----
#
# Both ends of the clamp were found by red-teaming and both are real: 0 busy
# -spins (each iteration costing a tasklist — measured 2.3s of system time in 3s
# of wall clock), and a huge value makes the daemon an unreplaceable zombie,
# sleeping for a day holding the lock while the Stop gate calls its heartbeat
# stale and starts replacements that all lose the flock and exit.
{
    is(BpContinuityLease::clamp_tick(0),      1,  'a zero tick is floored — sleep(0) is a busy-spin');
    is(BpContinuityLease::clamp_tick(5),      5,  'a faster tick is honoured');
    is(BpContinuityLease::clamp_tick(100000), 60, 'a slower-than-default tick is capped at the default');
    is(BpContinuityLease::clamp_tick('x'),    60, 'garbage falls back to the default');

    local $ENV{CCPRAXIS_CONTINUITY_LEASE_TICK} = 0;
    is(BpContinuityLease::tick_seconds(), 1, 'and the env override goes through the same clamp');
}

# ------------------------------- a clock jumped backwards is not liveness ---
#
# A heartbeat stamped in the FUTURE is not evidence of life. Reading it as "very
# fresh" would let a DEAD refresher look healthy for the whole skew — no lease,
# nothing to notice, nothing to repair it. A needless restart costs nothing,
# because the flock turns the loser into an immediate exit.
{
    my $d = reg();
    mk("$d/sessone");
    my @spawns;
    mk("$d/lease.pid");
    my $future = time + 3600;
    utime($future, $future, "$d/lease.pid");
    is(BpContinuityLease::ensure_daemon($d, spawn => sub { push @spawns, 1; 42 }), 'spawned',
       'a heartbeat stamped in the future is treated as stale, not as very fresh');
    is(scalar @spawns, 1, 'so the refresher is restarted');
}

# --------------------------------------------------- daemon_loop ------------
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'posix';
    unlink $BUSY;
    mk("$d/sessone");

    is(BpContinuityLease::daemon_loop($d, tick => 0, max_iterations => 2,
                                      busy_path => $BUSY), 'done',
       'the refresher runs while something is armed');
    ok(-f $BUSY, 'it asserted the lease');
    ok(!-e "$d/lease.pid", 'and removed its own heartbeat on the way out');

    # Nothing armed: it must not assert anything at all, then leave.
    unlink "$d/sessone", $BUSY;
    is(BpContinuityLease::daemon_loop($d, tick => 0, busy_path => $BUSY), 'done',
       'with nothing armed it exits immediately');
    ok(!-e $BUSY, 'and never took the lease out in the first place');
}

# ------------------------------------------ TWO SESSIONS, ONE LEASE ---------
#
# The lease is a machine-level resource, so the question it answers is "is
# ANYONE armed", never "am I". A per-session release would let one session's
# `off` drop the wake-lock while another's unattended run was still going.
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'posix';
    unlink $BUSY;
    mk("$d/sessone");
    mk("$d/sesstwo");

    is(BpContinuityLease::sync($d, busy_path => $BUSY), 'held', 'two armed -> held');
    unlink "$d/sessone";
    is(BpContinuityLease::sync($d, busy_path => $BUSY), 'held',
       'one disarms -> STILL held, because the other is still armed');
    unlink "$d/sesstwo";
    is(BpContinuityLease::sync($d, busy_path => $BUSY), 'released',
       'the last disarm is what releases it');
}

# ------------------------------------------------------ tick override -------
{
    is(BpContinuityLease::tick_seconds(), 60, 'default cadence is 60s');
    local $ENV{CCPRAXIS_CONTINUITY_LEASE_TICK} = 5;
    is(BpContinuityLease::tick_seconds(), 5, 'the cadence is overridable');
    local $ENV{CCPRAXIS_CONTINUITY_LEASE_TICK} = 'nonsense';
    is(BpContinuityLease::tick_seconds(), 60, 'garbage falls back to the default');
}

# ------------------------------------------- the Stop gate re-asserts ------
#
# THE PROPERTY THAT MAKES THIS AUTOMATIC. The refresher is a process, and
# processes die — a forced restart, a WSL VM kill, an operator closing a
# terminal. Every turn end runs this gate, so the gate is the one place
# guaranteed to notice. It re-asserts the lease with stats and utimes only (it
# runs on EVERY turn end; a process spawn here is what buried the machine on
# 2026-08-13) and restarts the refresher only when the heartbeat says it is gone.
#
# CCPRAXIS_NO_WAKELOCK is set throughout: the gate invokes bp-continuity.pl as a
# SUBPROCESS, where $0 is a .pl and the ".t" guard cannot reach — the same hole
# that made t/runstate-pause-holds-lease.t leak a real helper on every run.
SKIP: {
    my $gate = "$Bin/../../hooks/gate-continuity.sh";
    skip 'gate-continuity.sh missing', 8 unless -f $gate;

    my $payload = qq({"session_id":"gatesess","cwd":"."});
    my $busy    = tempdir(CLEANUP => 1) . '/busy';

    # run_gate(\%fixture) -> rc. NO CCPRAXIS_NO_WAKELOCK here, on purpose: with
    # it set the gate skips this whole block, so a test that sets it proves the
    # refresh works only in the one configuration where it never runs. What
    # keeps this safe instead is the FIXTURE — a FRESH lease.pid means the
    # refresher looks healthy, so the gate re-asserts the lease and never shells
    # out to start anything. The one line that could spawn a process is the one
    # the fixture makes unreachable.
    my $run_gate = sub {
        my ($d) = @_;
        my $env = "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$d' BP_BUSY_PATH='$busy' ";
        my $out = `${env}bash "$gate" <<'P_EOF' 2>&1
$payload
P_EOF`;
        return $? >> 8;
    };

    my $stale = time - 900;

    # (a) a FILLED pid file: a helper is really running, and its lease must be
    #     kept alive on the way past.
    my $d = reg();
    mk("$d/gatesess");
    mk($busy); utime($stale, $stale, $busy);
    open my $k, '>', "$d/keepawake.pid" or die $!; print {$k} "424242\n"; close $k;
    utime($stale, $stale, "$d/keepawake.pid");
    mk("$d/lease.pid");                      # fresh: no restart, no subprocess

    is($run_gate->($d), 2, 'the gate still blocks an armed session with nothing scheduled');
    cmp_ok((stat("$d/keepawake.pid"))[9], '>', $stale,
           'and it refreshed the wake-lock heartbeat on the way past');
    ok(!-e "$d/lease.lock",
       'without starting anything — the refresher looked healthy, so nothing was spawned');

    SKIP: {
        skip 'the busy-lease is touched only on Linux — on the host the wake-lock is the mechanism', 1
            unless $^O eq 'linux';
        cmp_ok((stat($busy))[9], '>', $stale, 'and, in a container, the busy-lease too');
    }

    # (b) an EMPTY pid file is a CLAIM. Touching it would freeze a helper that
    #     died at birth into a permanent "starting" that nothing ever replaces.
    my $d2 = reg();
    mk("$d2/gatesess");
    open my $c2, '>', "$d2/keepawake.pid" or die $!; close $c2;
    my $born = time - 20;
    utime($born, $born, "$d2/keepawake.pid");
    mk("$d2/lease.pid");
    $run_gate->($d2);
    is((stat("$d2/keepawake.pid"))[9], $born,
       'the gate leaves an unfilled claim alone — only its age can expire it');

    # (c) CCPRAXIS_NO_WAKELOCK skips the block ENTIRELY, touches included.
    #     Gating only the restart was worse than doing nothing: the touch kept an
    #     orphan helper's 900s lease alive on every turn end while the one path
    #     able to RELEASE it was skipped, so "hold nothing" became "hold this one
    #     forever".
    my $d3 = reg();
    mk("$d3/gatesess");
    open my $k3, '>', "$d3/keepawake.pid" or die $!; print {$k3} "424242\n"; close $k3;
    utime($stale, $stale, "$d3/keepawake.pid");
    my $env3 = "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$d3' CCPRAXIS_NO_WAKELOCK=1 BP_BUSY_PATH='$busy' ";
    `${env3}bash "$gate" <<'P_EOF' 2>&1
$payload
P_EOF`;
    is((stat("$d3/keepawake.pid"))[9], $stale,
       'CCPRAXIS_NO_WAKELOCK: an orphan helper\x27s lease is NOT refreshed');
    ok(!-e "$d3/lease.pid",  'CCPRAXIS_NO_WAKELOCK: and no refresher is started');
    ok(!-e "$d3/lease.lock", 'CCPRAXIS_NO_WAKELOCK: and no lock is taken');
}

# ------------------------------------------------ flock single-instance ----
#
# THE CORE OF THE FIFTEEN-HELPER FIX, and the half that a heartbeat check alone
# cannot provide: two `arm`s in the same instant BOTH find no pid file and BOTH
# start a refresher, and two refreshers each want their own wake-lock. Only a
# lock held for the process's lifetime is actually exclusive. Asserted by taking
# the lock here and watching daemon_loop stand down.
{
    my $d = reg();
    local $BpContinuityLease::PLATFORM = 'posix';
    mk("$d/sessone");

    open my $held, '>>', "$d/lease.lock" or die $!;
    ok(flock($held, 2 | 4), 'took the refresher lock as a rival would');  # LOCK_EX|LOCK_NB

    unlink $BUSY;
    is(BpContinuityLease::daemon_loop($d, tick => 0, max_iterations => 1,
                                      busy_path => $BUSY), 'duplicate',
       'a second refresher stands down rather than running alongside the first');
    ok(!-e $BUSY, 'and asserts nothing — the incumbent owns the lease');
    ok(!-e "$d/lease.pid", 'and does not overwrite the incumbent\'s heartbeat');

    flock($held, 8); close $held;                                        # LOCK_UN
    is(BpContinuityLease::daemon_loop($d, tick => 0, max_iterations => 1,
                                      busy_path => $BUSY), 'done',
       'once the lock is free the next refresher takes over');
    ok(-f $BUSY, 'and asserts the lease');
}

# ------------------------------------------------------ the CLI verbs -------
#
# Through the DISPATCHER, not the module. `lease` is the repair verb the Stop
# gate shells out to, and the boolean-flag form of parse_args it needs (--daemon
# takes no value) is new — a flag that silently swallowed the next argument
# would be invisible from the module side. CCPRAXIS_NO_WAKELOCK throughout:
# these are subprocesses, where the ".t" guard cannot reach.
{
    my $cli = "$S/bp-continuity.pl";
    my $d   = reg();
    my $run = sub {
        my $args = join ' ', @_;
        my $out = `CCPRAXIS_CONTINUITY_ACTIVE_DIR='$d' CCPRAXIS_NO_WAKELOCK=1 perl "$cli" $args 2>&1`;
        return ($out // '', $? >> 8);
    };
    my $kv = sub { my ($o, $k) = @_; return $o =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef };

    my ($out, $rc) = $run->('lease');
    is($rc, 0, 'lease exits 0 with nothing armed');
    is($kv->($out, 'STATUS'),    'released', 'and converges toward released');
    is($kv->($out, 'ARMED_ANY'), 'no',       'and says why');

    ($out, $rc) = $run->('arm', '--session', 'clisess');
    is($kv->($out, 'STATUS'), 'armed', 'arm still works with the lease wired in');
    is($kv->($out, 'LEASE'),  'disabled',
       'and reports the lease as DISABLED rather than held — CCPRAXIS_NO_WAKELOCK '
     . 'is set, so claiming "held" would be the false claim this all exists to avoid');

    ($out, $rc) = $run->('lease');
    is($kv->($out, 'STATUS'),    'held', 'with a session armed, lease converges toward held');
    is($kv->($out, 'ARMED_ANY'), 'yes',  'and sees the arm');

    ($out, $rc) = $run->('status', '--session', 'clisess');
    is($kv->($out, 'LEASE'), 'disabled', 'status reports the lease too');

    ($out, $rc) = $run->('disarm', '--session', 'clisess');
    is($kv->($out, 'STATUS'), 'disarmed', 'disarm works');

    # A disarm on a session that was NOT armed still re-syncs: "I was not armed"
    # says nothing about whether anyone else is, and the usual way to get here is
    # a marker the Stop gate already reaped.
    ($out, $rc) = $run->('disarm', '--session', 'clisess');
    is($rc, 2, 'a second disarm reports not_armed');
    is($kv->($out, 'STATUS'), 'not_armed', 'plainly');
    is($kv->($out, 'LEASE'),  'disabled',  'and still reports the lease rather than skipping it');

    # The boolean flag: --daemon must not swallow the next argument.
    ($out, $rc) = $run->('lease', '--tick', '1', '--daemon');
    is($rc, 0, '--daemon parses as a switch, with a valued flag before it');
    like($out, qr/^STATUS:\s*(?:done|duplicate)$/m,
         'and runs the refresher loop, which exits at once with nothing armed');

    ($out, $rc) = $run->('lease', '--nonsense', '1');
    is($rc, 1, 'an unknown flag is still refused');
    like($out, qr/^ERROR:/m, 'loudly');
}

# --------------------------------------- the gate and the module agree ------
#
# gate-continuity.sh cannot read a perl constant, so it hardcodes the staleness
# window it uses to decide whether to restart the refresher. If either side
# moves without the other, the hook either restarts a healthy daemon on every
# turn or never restarts a dead one.
{
    my $hook = do {
        open my $fh, '<', "$Bin/../../hooks/gate-continuity.sh" or die $!;
        local $/; <$fh>;
    };
    my $expect = BpContinuityLease::clamp_tick(undef) * BpContinuityLease::stale_ticks();
    like($hook, qr/LEASE_AGE" -lt \Q$expect\E\b/,
         "gate-continuity.sh's refresher staleness window is still ${expect}s");
    like($hook, qr/bp-continuity\.pl" lease\b/,
         'and it restarts the refresher through the lease verb');
}

done_testing();
