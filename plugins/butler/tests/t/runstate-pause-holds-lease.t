#!/usr/bin/env perl
# A paused run must keep holding the machine awake.
#
# THE CHICKEN-AND-EGG THIS CLOSES
#
# Two mechanisms each assumed the other would keep the wake-lock alive:
#
#   * bp-keepawake.pl's helper self-expires after 900s unless something
#     refreshes its pid file.
#   * Only the DIRECTOR (bp-drive-next.pl) ever creates the first lease.
#     bp-watch.pl's --keepawake refuses to spawn one, deliberately, so it can
#     never become a second independent lock-holder -- it refreshes an
#     existing lease and is otherwise a no-op.
#   * But the director only runs when the DRIVER calls it, and a driver deep
#     inside one long package legitimately does not call it for hours.
#
# So once the lease lapsed, the only thing that could restore it was the one
# thing not running. Measured 2026-09-11 on a live drive-solo run: ~80 minutes
# with no wake-lock at all, on a host that sleeps.
#
# `pause` is the fix's home because it is the one call a driver CANNOT skip --
# guard-subagent-stall.sh denies the turn end without it. That makes the lease
# exactly as reliable as a gate that is already enforced.
#
# WHAT THIS FILE CAN AND CANNOT ASSERT. bp-keepawake.pl's spawn() returns undef
# when $0 ends in ".t", because a test that spawns a real OS wake-lock leaks an
# immortal process (53 leaked helpers once filled this machine). That guard is
# correct and must stay, so no test may assert the SPAWN path. The REFRESH path
# is fully observable though: with a live pid already recorded, apply() touches
# the pid file and returns before it ever reaches spawn(). That is what the
# lease actually depends on tick to tick, so it is the behaviour worth pinning.
#
# AND THE $0 GUARD DOES NOT REACH THIS FILE'S SUBPROCESSES — corrected 2026-09-15.
# `pause` is exercised by running bp-runstate.pl, where $0 is bp-runstate.pl, not
# a ".t". So sections C and D were reaching the REAL spawn and starting a real
# keep-awake helper on every run; they passed only because apply() used to
# return before the helper had written its pid file, so the assertion looked at
# an empty directory a second too early. apply() now claims the pid file up
# front (it had to, to stop a fifteen-helper storm), which made the leak
# visible. CCPRAXIS_NO_WAKELOCK is the supported opt-out and IS inherited across
# exec, so it is what actually holds the "no test leaks a wake-lock" line here.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $T      = dirname(abs_path(__FILE__));
my $SCRIPT = abs_path("$T/../../scripts/bp-runstate.pl");
ok(-f $SCRIPT, 'bp-runstate.pl found') or BAIL_OUT("missing: $SCRIPT");

my $root = abs_path(tempdir(CLEANUP => 1));
my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
make_path($ds);
make_path("$root/.ccpraxis-local-data/.subagent-guard");

my $LEASE = "$ds/keepawake.pid";

# Record a lease held by a pid that is genuinely alive -- this test process.
# apply()'s idempotence check reads the pid, finds it live, refreshes the file's
# mtime and returns, never reaching the availability probe or spawn().
sub seed_lease {
    open my $fh, '>', $LEASE or die "seed lease: $!";
    print $fh "$$\n";
    close $fh;
    my $old = time - 600;          # ten minutes stale
    utime($old, $old, $LEASE) or die "utime: $!";
    return $old;
}

sub lease_mtime { return (stat $LEASE)[9] }

sub pause_now {
    my (@extra) = @_;
    my $until = time + 600;
    my $cmd = qq{"$^X" "$SCRIPT" pause --root "$root" --watcher-pid $$ }
            . qq{--until $until --watching "a fixture" --reason "lease test" }
            . join(' ', @extra) . ' 2>&1';
    return scalar `$cmd`;
}

# ------------------------------------------- A. the driver surface refreshes
{
    my $old = seed_lease();
    my $out = pause_now();
    like($out, qr/paused until/, 'the pause itself succeeded');

    cmp_ok(lease_mtime(), '>', $old,
           'a driver pause REFRESHES a live wake-lock lease');
}

# ------------------------------------ B. the reporter surface does not touch it
# The reporter pauses on its own surface and does not own the run's
# machine-level lifetime; only the driver does.
{
    my $old = seed_lease();
    my $out = pause_now('--surface', 'reporter');
    like($out, qr/paused until/, 'the reporter-surface pause succeeded');

    is(lease_mtime(), $old,
       'a reporter pause leaves the lease alone -- it does not own the machine');
}

# --------------------------------------------- C. no lease is ever FABRICATED
# With no lease file at all, a pause must not conjure one from a test process.
# This is the guard that keeps leaked immortal helpers impossible, and it is
# what stops this fix from becoming the very problem bp-watch.pl refuses to be.
{
    unlink $LEASE;
    my $out = pause_now();
    like($out, qr/paused until/, 'a pause with no lease present still succeeds');
    ok(!-e $LEASE,
       'a pause never fabricates a lease from a test process (CCPRAXIS_NO_WAKELOCK, '
     . 'which — unlike the $0 guard — survives the exec into bp-runstate.pl)');
}

# ------------------------------- D. a broken lease never refuses a valid pause
# Holding the machine awake is strictly less important than the run continuing,
# so every failure in the lease path is swallowed.
{
    make_path($ds) unless -d $ds;
    open my $fh, '>', $LEASE or die $!;
    print $fh "not-a-pid\n";
    close $fh;

    my $out = pause_now();
    like($out, qr/paused until/,
         'a corrupt lease file does not refuse an otherwise valid pause');
}

done_testing();
