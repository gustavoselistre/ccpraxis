#!/usr/bin/env perl
# platform: windows
# A pause may not outlive this session's prompt cache.
#
# WHY THE CAP EXISTS
#
# An interactive driver's whole conversation lives in the provider's prompt
# cache, whose TTL for these sessions is ONE HOUR. A pause longer than that
# wakes a session whose context has gone cold: every turn of the run has to be
# re-read before the first useful thing happens. That is the most expensive way
# a long run can resume, and it is invisible -- the run looks healthy, it is
# just suddenly paying full freight for context it already had.
#
# Operator's call, 2026-09-11, after a driver armed a 58-minute pause. That was
# still inside the hour, which is exactly the problem: it left no margin for the
# wake-up itself to be late. The cap is 50 minutes, ~10 minutes of headroom.
#
# WHY CLAMP RATHER THAN REFUSE, pinned here because it is the non-obvious half:
# every other check in `pause` REFUSES, because each of those rejects a pause
# that would be wrong in the permissive direction (a dead watcher, a past
# deadline, an unverifiable pid). Granting one of those holds the gate open for
# a run that has already died. An over-long pause is not that -- it is
# well-formed, merely too long, and clamping it can only make the gate MORE
# conservative. Refusing would risk a retry loop against a gate whose whole
# purpose is to keep a run moving: paying a wedge to prevent something harmless.
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives bp-continuity.pl /
# bp-runstate.pl / gate-continuity.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $T      = dirname(abs_path(__FILE__));
my $SCRIPT = abs_path("$T/../../scripts/bp-runstate.pl");
ok(-f $SCRIPT, 'bp-runstate.pl found') or BAIL_OUT("missing: $SCRIPT");

my $CAP_SECONDS = 50 * 60;

my $root = abs_path(tempdir(CLEANUP => 1));
make_path("$root/.ccpraxis-local-data/.subagent-guard");

sub rs {
    my (@args) = @_;
    my $cmd = qq{"$^X" "$SCRIPT" } . join(' ', map { qq{"$_"} } @args) . ' 2>&1';
    my $out = `$cmd`;
    $out = '' unless defined $out;
    return $out;
}

# $$ is this test process: genuinely alive, so the watcher-liveness check passes
# and we are testing the deadline logic rather than fighting an unrelated gate.
sub pause_until {
    my ($until) = @_;
    return rs('pause', '--root', $root, '--watcher-pid', $$, '--until', $until,
              '--watching', 'a fixture dispatch', '--reason', 'cap check');
}

sub recorded_until {
    my $st = rs('status', '--root', $root);
    return $st =~ /"until"\s*:\s*(\d+)/ ? $1 : undef;
}

# ------------------------------------------- A. an over-long pause is clamped
{
    my $asked = time + 3 * 3600;          # three hours: far past the cap
    my $out   = pause_until($asked);
    like($out, qr/paused until/, 'an over-long pause is still GRANTED, not refused');

    my $got = recorded_until();
    ok(defined $got, 'a deadline was recorded');

    cmp_ok($got, '<=', time + $CAP_SECONDS,
           'the recorded deadline is clamped to at most the cap');
    cmp_ok($got, '<', $asked,
           'the recorded deadline is shorter than the one asked for');

    # The clamp must be visible. A silent one would let a caller believe it has
    # three hours when it has fifty minutes -- the same class of invisible-state
    # bug as a pause written where its reader never looks.
    like($out, qr/shortened/i, 'the clamp is reported, not applied silently');
    like($out, qr/\b50-minute\b/, 'the message names the cap that was applied');
}

# ------------------------------------ B. a pause inside the cap is untouched
{
    my $asked = time + 600;               # ten minutes: comfortably inside
    my $out   = pause_until($asked);
    my $got   = recorded_until();

    is($got, $asked, 'a deadline inside the cap is recorded exactly as asked');
    unlike($out, qr/shortened/i,
           'no clamp note is emitted when nothing was clamped');
}

# ------------------------------------------- C. the refusals still refuse
# The cap must not have turned a hard check into a soft one: a past deadline is
# still wrong in the permissive direction and must still be rejected outright.
{
    my $out = pause_until(time - 60);
    like($out, qr/in the past/, 'a past deadline is still REFUSED, not clamped forward');
    unlike($out, qr/^paused until/m, 'and no pause is granted for it');
}

done_testing();
