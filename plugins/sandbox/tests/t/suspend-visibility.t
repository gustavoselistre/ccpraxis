#!/usr/bin/env perl
# platform: any
# blueprint: host-wake-and-suspend, package 03-suspend-reaches-the-operator
# (specs/03-suspend-reaches-the-operator-spec.md). Written BLIND to
# plugins/sandbox/scripts/Dashboard.pm, plugins/butler/scripts/bp-orchestrator.pl and
# plugins/butler/scripts/bp-token-keeper.pl -- from the spec only -- so it is an
# oracle, not an echo of whatever the implementer eventually writes. Do NOT weaken
# an assertion to make a future implementation's life easier.
#
# Coverage: AC1-AC11 (spec S4). Fixture-only per the package's own done criterion
# "no live suspend required to run the suite" -- no real sleep, no elevation, no
# podman.
#
# Scaffolding is deliberately copied in SHAPE (not reinvented) from:
#   - plugins/butler/tests/t/orchestrator-suspend-gap.t (tempdir/blueprint.md/
#     creds.json/tunables, BpOrch::run(now=>..., sleep=>...) two-tick pattern)
#   - plugins/butler/tests/t/token-alert-carries-diagnosis.t (the keeper's own
#     just_woke sentence -- "resumed from a NNNNs suspend" / no "grants have
#     DIVERGED" -- used here as the oracle for the orchestrator's question field,
#     per the spec's explicit instruction not to re-prove the keeper's own
#     contract)
#   - plugins/butler/tests/t/escalation-categories.t and
#     plugins/butler/tests/t/keeper-resilience-antispam.t (reading queued
#     escalations back from $runs/escalations/*.json)
#   - plugins/sandbox/tests/t/activity-feed-ordering.t and
#     plugins/sandbox/tests/t/panel-semantics.t (LaunchLog::format_event-based
#     JSONL fixtures fed through Dashboard::recent_events, spans_text,
#     tui::DashboardScreen::activity_time_text/Dashboard::_local_hhmm for
#     reconstructing a row's wall-clock time deterministically)
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

use lib "$Bin/../../scripts";
use_ok('LaunchLog') or BAIL_OUT('LaunchLog.pm did not load');
use_ok('Dashboard')  or BAIL_OUT('Dashboard.pm did not load');

my $DS_OK = eval { require tui::DashboardScreen; 1 };
diag("  require tui::DashboardScreen failed: $@") unless $DS_OK;

require "$Bin/../../../butler/scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

# ===========================================================================
# Scaffolding
# ===========================================================================

# ev_line($type, $epoch, $pid, \%fields) -- one JSON line via the real
# formatter, never a hand-written JSON string (matches
# activity-feed-ordering.t's own idiom).
sub ev_line {
    my ($type, $epoch, $pid, $fields) = @_;
    return LaunchLog::format_event($type, $fields || {}, $epoch, $pid);
}

# A safe, deterministic, mid-day UTC base epoch, far from any midnight
# boundary, and landing exactly on a minute boundary so a gap_secs that is an
# exact multiple of 60 keeps both the suspend and resume epochs on minute
# boundaries too (needed for the wall-clock HH:MM reconstruction below).
my $BASE = 1_700_043_600;   # 2023-11-15T10:20:00Z (:00 seconds)
my $GM   = \&CORE::gmtime;

# expected_hhmm_text($epoch) -- reconstruct the exact wall-clock span text
# recent_events would render for a row carrying this epoch, via the SAME
# public helpers the render path uses (Dashboard::_local_hhmm +
# tui::DashboardScreen::activity_time_text). This is calling the public
# interface, not reading Dashboard.pm's source -- used only to pin AC2's
# "resume epoch - suspend epoch == gap_secs" claim at the finest granularity
# externally observable through recent_events's spans-of-text return shape
# (minutes), since recent_events does not hand back a raw epoch field.
sub expected_hhmm_text {
    my ($epoch) = @_;
    return undef unless $DS_OK && Dashboard->can('_local_hhmm') && tui::DashboardScreen->can('activity_time_text');
    my $hhmm = eval { Dashboard::_local_hhmm($epoch, $GM) };
    return undef if $@;
    return eval { tui::DashboardScreen::activity_time_text($hhmm) };
}

# needs_you_files($runs) -- escalation record basenames under
# $runs/escalations, matching escalation-categories.t /
# keeper-resilience-antispam.t's own convention.
sub needs_you_files {
    my ($runs) = @_;
    my $dir = "$runs/escalations";
    return () unless -d $dir;
    opendir my $dh, $dir or return ();
    my @j = sort grep { /\.json$/ } readdir $dh;
    closedir $dh;
    return @j;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }

# log_events($path) -- decode every JSONL line in an orchestrator.log.
sub log_events {
    my ($path) = @_;
    return () unless -f $path;
    return map { eval { $J->decode($_) } } grep { length } split /\n/, slurp($path);
}

# a fresh butler run tree (tempdir/bp/runs/packages/blueprint.md), matching
# orchestrator-suspend-gap.t's own scaffolding shape exactly.
sub fresh_run_tree {
    my $dir   = tempdir(CLEANUP => 1);
    my $bpdir = "$dir/bp";     mkdir $bpdir or die "mkdir: $!";
    my $runs  = "$bpdir/runs"; mkdir $runs  or die "mkdir: $!";
    mkdir "$bpdir/packages" or die "mkdir: $!";
    open(my $bm, '>', "$bpdir/blueprint.md") or die "blueprint.md: $!";
    print {$bm} "# T\n\n```\nblueprint: T\nstatus: audited\n```\n\n## Package status\n\n"
              . "| pkg | deliverable | depends_on | model |\n|-----|-------------|------------|-------|\n";
    close $bm;
    return ($dir, $bpdir, $runs);
}

sub write_creds {
    my ($dir, %o) = @_;
    my $p = "$dir/creds.json";
    open(my $c, '>', $p) or die "creds: $!";
    print {$c} $J->encode({ claudeAiOauth => {
        accessToken => 'x', refreshToken => 'y',
        expiresAt   => $o{expires_at_ms} // 4_102_444_800_000,
        scopes      => ['user:inference'],
    } });
    close $c;
    return $p;
}

# ===========================================================================
# AC1 (-> done criterion 1). A suspend_gap fixture line, shaped like what
# bp-orchestrator.pl:2909-2917 writes, renders TWO rows: one "suspend " and
# one "resume ".
# ===========================================================================
{
    my $epoch = $BASE + 3600;   # 11:20:00Z -- an hour past $BASE, still same day
    my $gap   = 10_800;         # 3h, exact multiple of 60
    my @lines = (
        ev_line('suspend_gap', $epoch, 900, {
            gap_secs => $gap, overshoot_secs => 5, intended_s => 10, slack_s => 120,
            detail => 'test fixture',
        }),
    );
    my $ev = eval { Dashboard::recent_events(\@lines, 10, $GM, $epoch + 1000) };
    ok(!$@, 'AC1: recent_events does not die on a well-formed suspend_gap fixture') or diag($@);

    if (ref($ev) eq 'ARRAY') {
        is(scalar(@$ev), 2, 'AC1: one suspend_gap line renders as exactly TWO rows')
            or diag('  rows: ' . join(' | ', map { Dashboard::spans_text($_) } @$ev));

        if (@$ev == 2) {
            my $t0 = Dashboard::spans_text($ev->[0]);
            my $t1 = Dashboard::spans_text($ev->[1]);
            like($t0, qr/\bsuspend /, 'AC1: first row body starts "suspend "') ;
            like($t1, qr/\bresume /,  'AC1: second row body starts "resume "');

            # -----------------------------------------------------------------
            # AC2 (-> done criterion 1). resume epoch - suspend epoch ==
            # gap_secs, both defined -- verified via the wall-clock HH:MM
            # text the render path produces from each row's own epoch
            # (minute granularity; see sub expected_hhmm_text above and the
            # report's "Untestable / deviations" note).
            # -----------------------------------------------------------------
            my $exp_suspend_txt = expected_hhmm_text($epoch - $gap);
            my $exp_resume_txt  = expected_hhmm_text($epoch);
            SKIP: {
                skip 'tui::DashboardScreen / Dashboard time helpers unavailable', 2
                    unless defined $exp_suspend_txt && defined $exp_resume_txt;
                like($t0, qr/\Q$exp_suspend_txt\E/,
                    'AC2: the "suspend " row carries the epoch gap_secs BEFORE the resume row (wall-clock match)');
                like($t1, qr/\Q$exp_resume_txt\E/,
                    'AC2: the "resume " row carries the ORIGINAL event epoch (wall-clock match)');
            }
        } else {
            fail('AC1: first row body starts "suspend "');
            fail('AC1: second row body starts "resume "');
        }
    } else {
        fail('AC1: one suspend_gap line renders as exactly TWO rows');
    }
}

# ===========================================================================
# AC2 continued -- ordering among other, unrelated rows spanning a wider time
# range (Observable behavior 3): the suspend/resume pair sits in
# non-decreasing epoch order relative to rows before the suspend epoch and
# after the resume epoch.
# ===========================================================================
{
    my $epoch = $BASE + 7200;   # 12:20:00Z
    my $gap   = 3_600;          # 1h
    my @lines = (
        ev_line('poll', $epoch - $gap - 600, 100, {}),   # well before the suspend
        ev_line('suspend_gap', $epoch, 900, { gap_secs => $gap, overshoot_secs => 2 }),
        ev_line('poll', $epoch + 600, 100, {}),           # well after the resume
    );
    my $ev = eval { Dashboard::recent_events(\@lines, 10, $GM, $epoch + 10_000) };
    ok(!$@, 'AC2 (ordering): recent_events does not die on the interleaved fixture') or diag($@);
    if (ref($ev) eq 'ARRAY') {
        is(scalar(@$ev), 4, 'AC2 (ordering): 3 lines (one splitting into 2) -> 4 rows');
        my @texts = map { Dashboard::spans_text($_) } @$ev;
        my ($isuspend) = grep { $texts[$_] =~ /\bsuspend / } 0 .. $#texts;
        my ($iresume)  = grep { $texts[$_] =~ /\bresume /  } 0 .. $#texts;
        ok(defined $isuspend && defined $iresume, 'AC2 (ordering): both synthesized rows are present')
            or diag('  rows: ' . join(' | ', @texts));
        if (defined $isuspend && defined $iresume) {
            cmp_ok($isuspend, '<', $iresume, 'AC2 (ordering): suspend row precedes resume row');
            is($isuspend, 1, 'AC2 (ordering): suspend row sits after the earlier unrelated row');
            is($iresume,  2, 'AC2 (ordering): resume row sits before the later unrelated row');
        }
    } else {
        fail('AC2 (ordering): 3 lines (one splitting into 2) -> 4 rows');
    }
}

# ===========================================================================
# AC3 (-> done criterion 1 / legibility, Decision 4). event_style roles for
# the new kinds are distinct from the pre-change unstyled default ('value').
# ===========================================================================
{
    my ($srole) = Dashboard::event_style('suspend', undef, undef);
    my ($rrole) = Dashboard::event_style('resume', undef, undef);
    my ($grole) = Dashboard::event_style('suspend_gap', undef, undef);
    is($srole, 'warn', "AC3: event_style('suspend',...) role is 'warn'");
    is($rrole, 'good', "AC3: event_style('resume',...) role is 'good'");
    is($grole, 'warn', "AC3: event_style('suspend_gap',...) fallback role is 'warn'");
    isnt($srole, 'value', "AC3: 'suspend' role is not the pre-change unstyled default");
    isnt($rrole, 'value', "AC3: 'resume' role is not the pre-change unstyled default");
    isnt($grole, 'value', "AC3: 'suspend_gap' role is not the pre-change unstyled default");
}

# ===========================================================================
# AC4 (-> done criterion 1, degrade path). Malformed suspend_gap fixtures
# produce exactly ONE row, never crash, never an undefined-but-required
# epoch.
# ===========================================================================
{
    my $epoch = $BASE + 20_000;

    my %cases = (
        'gap_secs missing'    => ev_line('suspend_gap', $epoch, 900, { overshoot_secs => 1 }),
        'gap_secs zero'       => ev_line('suspend_gap', $epoch, 900, { gap_secs => 0 }),
        'gap_secs negative'   => ev_line('suspend_gap', $epoch, 900, { gap_secs => -5 }),
        'gap_secs non-numeric'=> ev_line('suspend_gap', $epoch, 900, { gap_secs => 'not-a-number' }),
    );
    for my $label (sort keys %cases) {
        my @lines = ($cases{$label});
        my $ev = eval { Dashboard::recent_events(\@lines, 10, $GM, $epoch + 1000) };
        ok(!$@, "AC4 ($label): recent_events does not die") or diag($@);
        is(ref($ev) eq 'ARRAY' ? scalar(@$ev) : -1, 1,
            "AC4 ($label): degrades to exactly one row");
    }

    # Unparseable ts: format_event always writes a valid ts, so this one is
    # hand-built.
    my $bad_ts_line = $J->encode({
        ts => 'not-a-real-timestamp', pid => 900, type => 'suspend_gap',
        gap_secs => 100, overshoot_secs => 1,
    });
    my $ev2 = eval { Dashboard::recent_events([$bad_ts_line], 10, $GM, $epoch + 1000) };
    ok(!$@, 'AC4 (unparseable ts): recent_events does not die');
    # An unparseable ts may fall through as zero OR one row depending on
    # whether the generic path renders an undefined-epoch row at all; either
    # way it must never be TWO (the synthesis path must not have fired) and
    # must never crash.
    if (ref($ev2) eq 'ARRAY') {
        cmp_ok(scalar(@$ev2), '<=', 1,
            'AC4 (unparseable ts): never synthesizes a suspend/resume pair without a defined epoch');
    } else {
        fail('AC4 (unparseable ts): never synthesizes a suspend/resume pair without a defined epoch');
    }
}

# ===========================================================================
# AC5/AC6 (-> done criterion 2). Driving BpOrch::run() through a keeper 4xx
# with a .last-suspend.json marker inside the 900s wake window: the queued
# reauth escalation's `question` equals the keeper's own diagnosis (names the
# suspend, per token-alert-carries-diagnosis.t's own established oracle for
# the just_woke sentence) and does NOT contain "grants have DIVERGED".
# ===========================================================================
{
    my ($dir, $bpdir, $runs) = fresh_run_tree();
    my $NOW_S = 1_800_000_000;   # realistic epoch -- expiresAt (ms) must exceed 1e12

    # 5 minutes from expiry -- comfortably under any floor, guaranteeing the
    # refresh path is actually exercised (mirrors under_floor() in
    # token-alert-carries-diagnosis.t).
    my $creds = write_creds($dir, expires_at_ms => ($NOW_S * 1000) + 5 * 60 * 1000);

    # A recent suspend marker, shaped exactly like what
    # bp-orchestrator.pl:2918-2925 writes, well inside the 900s wake window.
    open(my $sm, '>', "$runs/.last-suspend.json") or die "marker: $!";
    print {$sm} $J->encode({ at_epoch => $NOW_S - 4, gap_secs => 10_800, overshoot_secs => 5 });
    close $sm;

    my $t = {
        ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
        keeper_int=>1, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
        tele_retry=>3, usage_fail=>60, busy_path=>"$dir/.busy",
    };
    my $ticks = 0;
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
            once => 0,
            now   => sub { $NOW_S },
            sleep => sub { $ticks++; $NOW_S += 10; die "stop\n" if $ticks >= 4; },
            http_get  => sub { { status => 200, content => '{}' } },
            http_post => sub { { status => 400, content => '{}' } },
            launch    => sub { 0 },
        });
        1;
    };
    cmp_ok($ticks, '>=', 1, 'AC5/AC6 precondition: the loop ran at least one tick');

    my @files = needs_you_files($runs);
    ok(scalar(@files) >= 1, 'AC5/AC6 precondition: at least one escalation record was queued')
        or diag("ticks=$ticks err=$@");

    my $rec;
    for my $f (@files) {
        my $d = eval { $J->decode(slurp("$runs/escalations/$f")) };
        next unless ref $d eq 'HASH';
        if (($d->{kind} // '') eq 'reauth') { $rec = $d; last; }
    }
    ok($rec, 'AC5/AC6 precondition: a reauth escalation record is present') or diag(join(',', @files));

    SKIP: {
        skip 'no reauth escalation record found', 3 unless $rec;
        ok(defined $rec->{question} && length $rec->{question}, 'AC5: the escalation carries a question field');
        like($rec->{question}, qr/resumed from a 10800s suspend/,
            'AC5: question equals the keeper\'s own diagnosis -- it names the suspend and its size');
        unlike($rec->{question}, qr/grants have DIVERGED/,
            'AC6: question does NOT contain the old hardcoded "grants have DIVERGED" sentence');
    }

    # AC11 (-> done criterion 3, paused-branch coverage). Once
    # _enter_pause_manual fires, later ticks take the paused-manual early-next
    # branch -- busy_lease_tick must still be recorded for those ticks too.
    my @all = log_events("$runs/orchestrator.log");
    my @busy = grep { ($_->{type} // '') eq 'busy_lease_tick' } @all;
    cmp_ok(scalar(@busy), '>=', $ticks,
        'AC11: a busy_lease_tick event is recorded for every tick, including paused-manual ticks after the reauth pause fires')
        or diag("ticks=$ticks busy_lease_tick count=" . scalar(@busy));
}

# ===========================================================================
# AC8-AC10 (-> done criterion 3). Per-tick busy-lease observed-mtime record.
# ===========================================================================
{
    my ($dir, $bpdir, $runs) = fresh_run_tree();
    my $creds = write_creds($dir);   # far-future expiry -- no auth traffic needed
    my $busy_path = "$dir/.busy-lease";   # deliberately does not exist yet

    my $CONTROLLED_MTIME = 1_234_567_890;   # a value distinct from any $now used below

    my $NOW_S = 2_000_000;
    my $ticks = 0;
    my $t = {
        ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
        keeper_int=>100_000, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
        tele_retry=>3, usage_fail=>60, busy_path=>$busy_path,
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
            once => 0,
            now   => sub { $NOW_S },
            sleep => sub {
                $ticks++;
                if ($ticks == 1) {
                    # Force a controlled mtime for the SECOND tick's read,
                    # regardless of whether tick 1's own gated touch_busy call
                    # created the file. Never inferred from write order.
                    unless (-e $busy_path) { open(my $fh, '>', $busy_path) or die "create busy_path: $!"; close $fh; }
                    utime($CONTROLLED_MTIME, $CONTROLLED_MTIME, $busy_path)
                        or die "utime($CONTROLLED_MTIME, $busy_path): $!";
                }
                $NOW_S += 10;
                die "stop\n" if $ticks >= 2;
            },
            http_get  => sub { { status => 200, content => '{}' } },
            http_post => sub { { status => 200, content => '{}' } },
            launch    => sub { 0 },
        });
        1;
    };
    cmp_ok($ticks, '>=', 2, 'AC8-AC10 precondition: the loop ran at least two ticks');

    my @all  = log_events("$runs/orchestrator.log");
    my @busy = grep { ($_->{type} // '') eq 'busy_lease_tick' } @all;

    cmp_ok(scalar(@busy), '>=', 2,
        'AC8: orchestrator.log contains at least two busy_lease_tick events, one per tick');

    if (@busy >= 1) {
        ok(exists $busy[0]{observed_mtime}, 'AC9 precondition: the first event carries an observed_mtime key');
        ok(!defined $busy[0]{observed_mtime},
            'AC9: the first tick\'s observed_mtime is undef/null -- the lease file did not exist yet');
    } else {
        fail('AC9: the first tick\'s observed_mtime is undef/null -- the lease file did not exist yet');
    }

    if (@busy >= 2) {
        is($busy[1]{observed_mtime}, $CONTROLLED_MTIME,
            'AC10: the second tick\'s observed_mtime equals the test-controlled utime() value -- a genuine stat(), not $now or a cached/synthesized number');
        isnt($busy[1]{observed_mtime}, $NOW_S,
            'AC10: ...and specifically is NOT the current clock value');
    } else {
        fail('AC10: the second tick\'s observed_mtime equals the test-controlled utime() value');
    }

    # Every busy_lease_tick event must carry all three documented fields.
    for my $i (0 .. $#busy) {
        ok(exists $busy[$i]{path} && length($busy[$i]{path} // ''),
            "AC8: busy_lease_tick event $i carries a path field");
        ok(exists $busy[$i]{age_s}, "AC8: busy_lease_tick event $i carries an age_s key (defined or not)");
    }
}

# ===========================================================================
# Fix-batch regression (redteam-01.md HIGH): busy_lease_tick's own _log call
# is the loop's only unconditional per-tick log write, so a transient
# BpLog::event write failure (bp-log.pl:53-55 dies on open/print/close) must
# degrade the tick, not crash the whole BpOrch::run loop -- mirroring the
# eval-wrap convention already used for checkpoint/checkpoint_failed
# (bp-orchestrator.pl:4371-4394). Simulated by intercepting BpLog::event
# itself (rather than making orchestrator.log unwritable on disk) so ONLY the
# busy_lease_tick call site is made to fail -- every other _log call in the
# run keeps its real, separately-scoped behaviour, isolating this assertion
# to exactly the call this fix-batch touched.
# ===========================================================================
{
    my ($dir, $bpdir, $runs) = fresh_run_tree();
    my $creds = write_creds($dir);
    my $busy_path = "$dir/.busy-lease-inject";

    my $real_event = \&BpLog::event;
    no warnings 'redefine';
    local *BpLog::event = sub {
        my ($path, $type, $fields, $epoch) = @_;
        die "bp-log: simulated transient write failure\n" if ($type // '') eq 'busy_lease_tick';
        return $real_event->($path, $type, $fields, $epoch);
    };

    my $NOW_S = 3_000_000;
    my $ticks = 0;
    my $t = {
        ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
        keeper_int=>100_000, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
        tele_retry=>3, usage_fail=>60, busy_path=>$busy_path,
    };
    my $died;
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
            once => 0,
            now   => sub { $NOW_S },
            sleep => sub { $ticks++; $NOW_S += 10; die "stop\n" if $ticks >= 3; },
            http_get  => sub { { status => 200, content => '{}' } },
            http_post => sub { { status => 200, content => '{}' } },
            launch    => sub { 0 },
        });
        1;
    } or do { $died = $@ };

    cmp_ok($ticks, '>=', 3,
        'fix-batch: the loop still reaches at least three ticks despite EVERY busy_lease_tick log write failing')
        or diag("ticks=$ticks died=" . ($died // '(no death)'));
    ok((!defined $died || $died =~ /^stop/),
        'fix-batch: the only death seen (if any) is the test\'s own intentional "stop", never the injected log-write failure')
        or diag("died=$died");
}

done_testing();
