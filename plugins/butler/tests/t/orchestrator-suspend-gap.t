#!/usr/bin/env perl
# platform: any
# Report 20260917-155603-b83e, failure 2.
#
# The orchestrator log stamps a usage_poll roughly every 60s. On 2026-09-17 it
# held two gaps -- 186.2 and 203.9 minutes -- with NO events of any kind, and
# `grep -ic suspend` over the whole log returned 0. Six and a half hours of wall
# time in a log with a sixty-second heartbeat, and nothing said anything had
# happened. The token keeper then woke into that silence, got HTTP 400 on a
# refresh, and alerted that the host and sandbox OAuth grants had DIVERGED. The
# credentials were fine; the machine had been asleep through the refresh window.
#
# THE REPORT'S DIAGNOSIS IS WRONG and this file does not encode it. It blames
# `fleet-govern.pl`'s `suspend_gap()` for never firing; that file belongs to the
# filing project's own fleet, `fleet-orchestrator.pl:405` does call it, and
# ccpraxis has no such function anywhere. The real defect is that butler's
# orchestrator never had a detector at all.
#
# The threshold is not invented here either: container/heartbeat.sh:31 already
# carries SUSPEND_SLACK=120 for the same question, so this is one rule with a
# second caller.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-orchestrator.pl";

# =====================================================================================
# The pure decision
# =====================================================================================

is(BpOrch::SUSPEND_SLACK_SECS(), 120,
   'the slack matches container/heartbeat.sh SUSPEND_SLACK -- one rule, two callers');

{
    my $v = BpOrch::suspend_gap(undef, 1000, 10);
    is($v->{suspended}, 0, 'no previous tick -> never a suspend (a fresh process cannot infer a gap it did not observe)');
    is($v->{gap_secs},  0, 'and reports no gap');
}

{
    # A normal tick: asked for 10s, took 11s.
    my $v = BpOrch::suspend_gap(1000, 1011, 10);
    is($v->{suspended}, 0, 'an ordinary tick is not a suspend');
    is($v->{gap_secs}, 11, 'gap is real elapsed time');
    is($v->{overshoot_secs}, 1, 'overshoot is elapsed minus intended');
}

{
    # A slow tick that is still WORK, not a suspend: two minutes is the boundary.
    my $under = BpOrch::suspend_gap(1000, 1000 + 10 + 119, 10);
    is($under->{suspended}, 0, 'overshoot just under the slack is not a suspend');
    my $at = BpOrch::suspend_gap(1000, 1000 + 10 + 120, 10);
    is($at->{suspended}, 1, 'overshoot exactly at the slack IS a suspend (>=, not >)');
}

{
    # The measured incident: 186.2 minutes against a ~60s intended interval.
    my $v = BpOrch::suspend_gap(0, 11_169, 60);
    is($v->{suspended}, 1, 'the 2026-09-17 gap is detected');
    is($v->{gap_secs}, 11_169, 'and its size is reported, not just its existence');
}

{
    # NTP stepping the clock backwards is not a suspend. Left unhandled this
    # produces a negative gap whose comparison depends on numeric coercion.
    my $v = BpOrch::suspend_gap(2000, 1000, 10);
    is($v->{suspended}, 0, 'a backward clock is never a suspend');
    is($v->{gap_secs},  0, 'and is reported as no gap rather than a negative one');
}

{
    # Total over garbage: a detector that dies takes the fleet with it.
    for my $case ([undef, undef], [{}, 1000], [1000, []], ['x', 'y']) {
        my $v = BpOrch::suspend_gap(@$case, 10);
        is(ref $v, 'HASH', 'suspend_gap returns a hashref for garbage input');
        is($v->{suspended}, 0, '... and never claims a suspend from it');
    }
}

{
    # A missing or nonsense intended interval must not make every tick a suspend.
    my $v = BpOrch::suspend_gap(1000, 1005, undef);
    is($v->{suspended}, 0, 'undef interval: a 5s gap is still not a suspend');
}

# =====================================================================================
# The wiring — two ticks, a clock that jumps between them
# =====================================================================================
#
# A manual pause keeps the loop alive without needing packages on disk: the
# paused branch touches the busy lease, sleeps and `next`s. The suspend check
# sits ABOVE that branch, so it runs on every tick regardless.
#
# The sleep seam advances the injected clock and dies on its second call, which
# is how the loop is stopped after exactly two ticks. run() captures that into
# $err, completes its teardown, and rethrows -- so the eval below is expected.
{
    my $dir  = tempdir(CLEANUP => 1);
    my $bpdir = "$dir/bp";       mkdir $bpdir or die "mkdir: $!";
    my $runs  = "$bpdir/runs";   mkdir $runs  or die "mkdir: $!";
    mkdir "$bpdir/packages" or die "mkdir: $!";
    open(my $bm, '>', "$bpdir/blueprint.md") or die "blueprint.md: $!";
    print {$bm} "# T\n\n```\nblueprint: T\nstatus: audited\n```\n\n## Package status\n\n| pkg | deliverable | depends_on | model |\n|-----|-------------|------------|-------|\n";
    close $bm;

    my $creds = "$dir/creds.json";
    open(my $c, '>', $creds) or die "creds: $!";
    print {$c} JSON::PP->new->encode({ claudeAiOauth => {
        accessToken => 'x', refreshToken => 'y',
        expiresAt   => 4_102_444_800_000, scopes => ['user:inference'] } });
    close $c;

    # A MANUAL pause never auto-resumes, so the loop cannot decide it is done.
    BpOrch::_enter_pause_manual($runs, undef, 'test-hold',
        { package => '_fleet', blueprint => 'T', kind => 'reauth',
          question => 'held for the test', context => 'x', created_at => 1,
          category => 'operational' });

    my $NOW   = 1_000_000;
    my $ticks = 0;
    my $t = {
        ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
        keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
        tele_retry=>3, usage_fail=>60, busy_path=>"$dir/.busy",
    };

    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
            once => 0,
            now   => sub { $NOW },
            sleep => sub {
                $ticks++;
                # Between tick 1 and tick 2 the host "sleeps" for three hours.
                $NOW += 10_800;
                die "stop-after-two-ticks\n" if $ticks >= 2;
            },
            http_get  => sub { { status => 200, content => '{}' } },
            http_post => sub { { status => 200, content => '{}' } },
            launch    => sub { 0 },
        });
        1;
    };

    cmp_ok($ticks, '>=', 2, 'the loop ran at least two ticks');

    my $log = do { local $/; open my $r, '<', "$runs/orchestrator.log" or die "log: $!"; <$r> };
    like($log, qr/"type":"suspend_gap"/, 'a suspend_gap event is logged -- `grep -i suspend` over the log now answers');
    like($log, qr/"gap_secs":10800/,     'the event carries the measured gap');
    like($log, qr/"intended_s":10/,      'and what the tick had actually asked for');

    ok(-f "$runs/.last-suspend.json", 'a marker is written for consumers that must not misread the silence');
    my $m = eval { JSON::PP->new->decode(do { local $/; open my $r,'<',"$runs/.last-suspend.json" or die; <$r> }) };
    is(ref $m, 'HASH', 'the marker is readable JSON');
    is($m->{gap_secs}, 10_800, 'and records the gap');
    cmp_ok($m->{at_epoch}, '>', 1_000_000, 'and when the wake was observed');
}

# ---- a run with no gap writes no marker and logs no event -------------------
# The counter-fixture: a detector nobody has seen decline is not a detector.
{
    my $dir  = tempdir(CLEANUP => 1);
    my $bpdir = "$dir/bp";       mkdir $bpdir or die;
    my $runs  = "$bpdir/runs";   mkdir $runs  or die;
    mkdir "$bpdir/packages" or die;
    open(my $bm, '>', "$bpdir/blueprint.md") or die;
    print {$bm} "# T\n\n```\nblueprint: T\nstatus: audited\n```\n\n## Package status\n\n| pkg | deliverable | depends_on | model |\n|-----|-------------|------------|-------|\n";
    close $bm;
    my $creds = "$dir/creds.json";
    open(my $c, '>', $creds) or die;
    print {$c} JSON::PP->new->encode({ claudeAiOauth => {
        accessToken => 'x', refreshToken => 'y',
        expiresAt => 4_102_444_800_000, scopes => ['user:inference'] } });
    close $c;
    BpOrch::_enter_pause_manual($runs, undef, 'test-hold',
        { package => '_fleet', blueprint => 'T', kind => 'reauth', question => 'held',
          context => 'x', created_at => 1, category => 'operational' });

    my $NOW = 1_000_000; my $ticks = 0;
    my $t = { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
              keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
              tele_retry=>3, usage_fail=>60, busy_path=>"$dir/.busy" };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
            once => 0, now => sub { $NOW },
            sleep => sub { $ticks++; $NOW += 10; die "stop\n" if $ticks >= 2 },
            http_get => sub { { status=>200, content=>'{}' } },
            http_post => sub { { status=>200, content=>'{}' } },
            launch   => sub { 0 },
        });
        1;
    };
    my $log = do { local $/; open my $r, '<', "$runs/orchestrator.log" or die; <$r> };
    unlike($log, qr/"type":"suspend_gap"/, 'an on-time tick logs no suspend_gap');
    ok(!-e "$runs/.last-suspend.json", 'and writes no marker');
}

done_testing();
