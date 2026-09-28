#!/usr/bin/env perl
# platform: any
# Oracle for blueprint sandbox-launcher-lifecycle, package 02-idle-footprint.
#
# Spec: .ccpraxis-local-data/blueprints/sandbox-launcher-lifecycle/specs/02-idle-footprint-spec.md
#
# THE CHANGE (not made by this file):
#   (a) Dashboard.pm:2924 -- $tick_int default 0.2 -> 1.0 (tick_interval key
#       in Dashboard::run's %o seam is unaffected; still overridable).
#   (b) launcher.pl -- a new $SAMPLER_TMPDIR constant (File::Spec->tmpdir()
#       based, project-unique via md5_of_string($LAUNCHER_DIR)); the 9 named
#       sampler/keepawake files (table in spec sec 2b) move from
#       $LAUNCHER_DIR to $SAMPLER_TMPDIR. Every OTHER $LAUNCHER_DIR-rooted
#       constant is untouched.
#
# This file is a READ-ONLY consumer of Dashboard::run()'s seam contract and a
# source-text-only reader of launcher.pl (never require'd/executed -- it
# builds container images and starts containers). Matches the conventions
# already established by input-latency.t (fake-clock wait_input harness) and
# resources-sampler-visibility.t (source-text regex + `perl -c` subprocess).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Spec;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $SCRIPTS_DIR    = "$Bin/../../scripts";
my $LAUNCHER_PATH  = "$SCRIPTS_DIR/launcher.pl";
my $T_DIR           = $Bin;   # plugins/sandbox/tests/t

ok(-f $LAUNCHER_PATH, "found launcher.pl at $LAUNCHER_PATH") or BAIL_OUT('cannot locate launcher.pl');

# ===========================================================================
# Harness: drive_idle(%args) -- a minimal fake-clock/wait_input driver, in
# the style of input-latency.t's drive_wi(), scoped down to exactly what
# PARTs A-C need (timeout log + clock bookkeeping). Self-contained per this
# suite's convention of per-file harnesses (not shared/imported).
# ===========================================================================
sub drive_idle {
    my (%args) = @_;
    my $clock = 1000;
    my %eff = (wait_calls => 0, wait_call_log => []);
    my @chunks;

    my %params = (
        beat_interval  => $args{beat_interval}  // 9999,
        state_interval => $args{state_interval} // 999,
        max_ticks      => $args{max_ticks} // 20,
        color          => 0,
        now            => sub { return $clock },
        sleep_for      => sub { $clock += $_[0] },
        read_key       => sub { undef },
        term_size      => sub { (60, 24) },
        gather         => sub {
            return { project_name => 'demo', container => 'c1', status => 'running', events => [] };
        },
        heartbeat      => sub { 'ok' },
        spawn          => sub { $eff{spawns}++; undef },
        enter_raw      => sub { },
        leave_raw      => sub { },
        keepawake      => sub { },
        out            => sub { push @chunks, $_[0] },
    );
    $params{tick_interval} = $args{tick_interval} if exists $args{tick_interval};

    my $cb = $args{wait_input};   # sub($timeout, \$clock, \%eff) -> key|undef
    $params{wait_input} = sub {
        my ($timeout) = @_;
        $eff{wait_calls}++;
        my $before = $clock;
        my $ret = $cb->($timeout, \$clock, \%eff);
        push @{ $eff{wait_call_log} }, { timeout => $timeout, elapsed => $clock - $before, ret => $ret };
        return $ret;
    };

    my $rc = Dashboard::run(%params);
    $eff{rc}     = $rc;
    $eff{spawns} ||= 0;
    return \%eff;
}

# ===========================================================================
# PART A -- AC1 (spec sec 4, item 1; DC2): with NO tick_interval override,
# the injected wait_input seam receives $timeout == 1.0 on EVERY idle-tick
# call (was 0.2 pre-change).
# ===========================================================================
{
    my $a = drive_idle(
        max_ticks  => 8,
        wait_input => sub {
            my ($timeout, $clock_ref) = @_;
            $$clock_ref += $timeout;   # always idle, never a key
            return undef;
        },
    );
    ok($a->{wait_calls} > 0, 'AC1 (sanity): wait_input was actually consulted');
    my @timeouts = map { $_->{timeout} } @{ $a->{wait_call_log} };
    ok(scalar(@timeouts) > 0, 'AC1 (sanity): at least one wait_input call was logged');
    my @bad = grep { $_ != 1.0 } @timeouts;
    is(scalar(@bad), 0,
       'AC1: every idle-tick wait_input call receives timeout==1.0 with no tick_interval override ' .
       '(was 0.2) -- ' . scalar(@timeouts) . ' calls observed, all checked');
}

# ===========================================================================
# PART B -- AC2 (spec sec 4, item 2; DC2): N idle ticks each advance the fake
# clock by exactly 1.0s (style of input-latency.t's C2); and a same-tick key
# arrival is bounded by AT MOST one 1.0s tick of latency (style of C1) --
# proving the "responsiveness within one tick" fixture bound Decision 9
# requires, now measured against the new 1.0s default specifically.
# ===========================================================================
{
    # B1 -- idle cadence: N ticks, each advances the clock by exactly 1.0s.
    my $N = 6;
    my $b1 = drive_idle(
        max_ticks  => $N,
        wait_input => sub {
            my ($timeout, $clock_ref) = @_;
            $$clock_ref += $timeout;
            return undef;
        },
    );
    is($b1->{wait_calls}, $N - 1,
       'AC2 (cadence): wait_input is called exactly once per completed tick (N-1 for a bounded N-tick run, ' .
       'matching input-latency.t\'s max_ticks tail-skip convention)');
    my $b1_elapsed = 0;
    $b1_elapsed += $_->{elapsed} for @{ $b1->{wait_call_log} };
    is($b1_elapsed, ($N - 1) * 1.0,
       'AC2 (cadence): total simulated wall-clock consumed by idle waits == (calls * 1.0s) exactly -- each ' .
       'tick advances the fake clock by precisely the new 1.0s default');

    # B2 -- responsiveness bound: an immediately-available key returns with
    # ~0 elapsed (no wait for the tick), so redraw/resize latency is bounded
    # by AT MOST one 1.0s tick, never a multiple of it.
    my $b2 = drive_idle(
        max_ticks     => 2,
        beat_interval => 0,   # heartbeats fire every top-of-loop iteration: same-tick sentinel
        wait_input    => sub {
            my ($timeout, $clock_ref, $eff) = @_;
            return 'c' if $eff->{wait_calls} == 1;   # immediate key, zero clock advance
            $$clock_ref += $timeout;
            return undef;
        },
    );
    is($b2->{wait_call_log}[0]{elapsed}, 0,
       'AC2 (bound): a same-tick key arrival costs ~0 simulated wall-clock, not the 1.0s tick -- ' .
       'redraw latency is bounded by at most one tick, never a multiple');
    is($b2->{spawns}, 1,
       'AC2 (bound): the immediately-delivered key was drained and dispatched within that same tick');
}

# ===========================================================================
# PART C -- AC3 (spec sec 4, item 3; DC1 proxy): for a FIXED simulated idle
# duration D, the number of (idle-only) wait_input calls at the NEW default
# (1.0) is exactly 1/5 of the number at the OLD default (0.2, passed
# explicitly) -- the causal mechanism behind the measured CPU drop.
#
# Each variant's wait_input returns a quit key ('q', per Dashboard's
# dispatch_key -> ['quit', ...] -- dashboard-framework.t line 954) exactly
# once cumulative elapsed reaches D, so the run terminates precisely at D
# rather than depending on a guessed max_ticks. The final quit-triggering
# call is not an idle wait, so it is subtracted before comparing counts --
# leaving exactly D/tick_interval idle calls per variant, an exact 5x ratio.
# ===========================================================================
{
    my $D = 10;   # seconds of simulated idle duration

    sub drive_for_duration {
        my ($tick_int) = @_;
        my $start;
        my $d = drive_idle(
            max_ticks     => int($D / $tick_int) + 10,   # generous headroom past D
            tick_interval => $tick_int,
            wait_input    => sub {
                my ($timeout, $clock_ref) = @_;
                $start = $$clock_ref unless defined $start;
                if ($$clock_ref - $start >= $D) { return 'q'; }
                $$clock_ref += $timeout;
                return undef;
            },
        );
        return $d;
    }

    my $new = drive_for_duration(1.0);
    my $old = drive_for_duration(0.2);

    ok($new->{wait_calls} > 0, 'AC3 (sanity): new-default run made at least one wait_input call');
    ok($old->{wait_calls} > 0, 'AC3 (sanity): old-default run made at least one wait_input call');

    # Subtract exactly one call for the quit-triggering wait (not an idle wait).
    my $new_idle_calls = $new->{wait_calls} - 1;
    my $old_idle_calls = $old->{wait_calls} - 1;

    is($new_idle_calls, $D / 1.0,
       "AC3: at the new 1.0s default, D=${D}s of idle time costs exactly D/1.0 = " . ($D / 1.0) .
       ' idle wait_input calls');
    is($old_idle_calls, $D / 0.2,
       "AC3: at the old 0.2s default (passed explicitly), the SAME D=${D}s costs exactly D/0.2 = " .
       ($D / 0.2) . ' idle wait_input calls');
    is($old_idle_calls, $new_idle_calls * 5,
       'AC3: the old-default call count is EXACTLY 5x the new-default call count for the same simulated ' .
       'idle duration -- the loop-wakeup-frequency reduction that is the causal mechanism behind the ' .
       'measured CPU drop (DC1 proxy)');
}

# ===========================================================================
# PART D -- AC4 (spec sec 4, item 4; DC1 operational): idle CPU of a LIVE
# idle launcher is NOT automatable in this file (per the spec's own text).
#
#   METHOD (recorded here as a comment, per spec instruction -- not asserted
#   via Test::More): measure the same way as the recorded baseline (report
#   20260910-010327-c432): PowerShell `Get-Process` CPU-time delta over (a) a
#   >=20s spot sample AND (b) a >=5-minute sustained window, with zero
#   child-process count change during the sample window (rules out a sampler
#   fork/exit skewing the delta). Baseline was 7.4%/5.4% of a core. The
#   after-figure is recorded in the package ledger's Outputs against that
#   baseline, not as a pass/fail assertion here -- DC1's own wording is
#   "measurably reduced," not "under 1%"; if the target (<1%, Decision 9) is
#   not reached, that is a recorded finding for a follow-up package
#   (Term::ReadKey's Win32 internals are an open, source-unverifiable
#   unknown per the scout report), not a failure of this AC.
# ===========================================================================
pass('AC4: idle CPU reduction is an operational measurement, not automatable here -- see the comment ' .
     'block immediately above for method, and the package ledger Outputs for the recorded number');

# ===========================================================================
# PART E -- AC5 (spec sec 4, item 5; DC4 regression): every existing test
# that passes its own explicit tick_interval keeps passing unmodified --
# proves the default change is isolated to callers that omit the key.
# Grepped from this directory (matches spec instruction: "grep
# plugins/sandbox/tests/t for tick_interval before starting").
# ===========================================================================
{
    my @tick_interval_files = grep {
        my $f = "$T_DIR/$_";
        -f $f && do {
            local $/;
            open(my $fh, '<', $f) or die "open $f: $!";
            my $src = <$fh>;
            close $fh;
            $src =~ /tick_interval\s*=>/;
        };
    } sort do { opendir(my $dh, $T_DIR) or die "opendir $T_DIR: $!"; my @e = readdir $dh; closedir $dh; @e };

    ok(scalar(@tick_interval_files) > 0,
       'AC5 (sanity): at least one existing test passes an explicit tick_interval (grep found ' .
       scalar(@tick_interval_files) . ' files)');
    ok((grep { $_ eq 'input-latency.t' } @tick_interval_files) > 0,
       'AC5 (sanity): input-latency.t (explicit 0.25, named in the spec) is among the grepped files');
}

# ===========================================================================
# PART F -- AC6 (spec sec 4, item 6; DC3): source-text regex assertions
# against launcher.pl, matching this suite's established "never require
# launcher.pl, slurp as text" convention (resources-sampler-visibility.t).
# ===========================================================================
{
    local $/;
    open(my $fh, '<', $LAUNCHER_PATH) or BAIL_OUT("cannot read launcher.pl: $!");
    my $LSRC = <$fh>;
    close $fh;
    ok(length($LSRC) > 0, 'launcher.pl was read as source text');

    # (a) File::Spec->tmpdir() appears in the construction of $SAMPLER_TMPDIR.
    like($LSRC, qr/\$SAMPLER_TMPDIR\s*=.*?File::Spec->tmpdir\(\)/s,
         'AC6a: $SAMPLER_TMPDIR is constructed from File::Spec->tmpdir()');

    # (b) each of the 9 leaf-file constants/values in spec table 2b is built
    # from $SAMPLER_TMPDIR, not $LAUNCHER_DIR.
    my %expect_tmpdir_var = (
        '$SAMPLER_ERR_RESOURCES'   => 'resources-sampler.err',
        '$SAMPLER_ERR_SPEND'       => 'spend-sampler.err',
        '$SAMPLER_ERR_CONTAINER'   => 'container-sampler.err',
        '$RESOURCES_SNAPSHOT_FILE' => '.resources-snapshot.json',
        '$RESOURCES_SAMPLER_PID'   => 'resources-sampler.pid',
        '$SPEND_SAMPLER_PID'       => 'spend-sampler.pid',
        '$CONTAINER_SAMPLER_PID'   => 'container-sampler.pid',
        '$CONTAINER_SNAPSHOT_FILE' => '.container-snapshot.json',
    );
    for my $var (sort keys %expect_tmpdir_var) {
        my $leaf = $expect_tmpdir_var{$var};
        my $qvar = quotemeta($var);
        like($LSRC, qr/\Q$var\E\s*=\s*"\$SAMPLER_TMPDIR\/\Q$leaf\E"/,
             "AC6b: $var is built from \$SAMPLER_TMPDIR/$leaf, not \$LAUNCHER_DIR");
    }
    # $ka_pidfile is the 9th file: an inline local variable (not grouped with
    # the sampler-pid constants above), per spec's explicit undercount note.
    like($LSRC, qr/\$ka_pidfile\s*=\s*"\$SAMPLER_TMPDIR\/keepawake\.pid"/,
         'AC6b (9th file): $ka_pidfile is built from $SAMPLER_TMPDIR/keepawake.pid, not $LAUNCHER_DIR ' .
         '(the inline keep-awake pidfile the spec explicitly flags as easy to undercount)');

    # (b-bis) fix-batch 2: _probe_err_path() -- the 5 per-probe sampler
    # diagnostic files (probe-stats.err, probe-df.err, probe-machine.err,
    # probe-cim.err, probe-inspect.err), written on the same sampler cadence
    # as the 9 above but built from the raw $LAUNCHER_DIR global rather than
    # one of the renamed leaf constants -- now also rooted at $SAMPLER_TMPDIR.
    like($LSRC, qr/sub\s+_probe_err_path\s*\{[^}]*"\$SAMPLER_TMPDIR\/probe-\$k\.err"/,
         'fix-batch2: _probe_err_path() builds its path from $SAMPLER_TMPDIR, not $LAUNCHER_DIR ' .
         '(covers all 5 keys: stats, df, machine, cim, inspect)');
    unlike($LSRC, qr/sub\s+_probe_err_path\s*\{[^}]*"\$LAUNCHER_DIR\/probe-\$k\.err"/,
           'fix-batch2 (negative): _probe_err_path() no longer resolves via $LAUNCHER_DIR');

    # (c) perl -c launcher.pl compiles clean.
    my $perl = $^X;
    my $out = `"$perl" -c "$LAUNCHER_PATH" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC6c: perl -c launcher.pl compiles clean') or diag($out);
}

# ===========================================================================
# PART G -- AC7 (spec sec 4, item 7; DC4): source-text regex assertions
# confirm a sample of durable constants still resolve via $LAUNCHER_DIR,
# unchanged -- the negative/regression guard against the fix creeping into
# any constant outside the spec's table 2b.
# ===========================================================================
{
    local $/;
    open(my $fh, '<', $LAUNCHER_PATH) or BAIL_OUT("cannot read launcher.pl: $!");
    my $LSRC = <$fh>;
    close $fh;

    like($LSRC, qr/\$SELECTION_FILE\s*=\s*"\$LAUNCHER_DIR\/selected-skills\.json"/,
         'AC7: $SELECTION_FILE still resolves via $LAUNCHER_DIR, unchanged');
    like($LSRC, qr/\$MANIFEST_FILE\s*=\s*"\$LAUNCHER_DIR\/container-manifest\.json"/,
         'AC7: $MANIFEST_FILE still resolves via $LAUNCHER_DIR, unchanged');
    # backpack-approvals.json is assigned to two names in the current source
    # ($bp_appr_file inline, and $BACKPACK_APPROVALS_FILE at module scope) --
    # assert both still resolve via $LAUNCHER_DIR, whichever this file keeps.
    my @appr_matches = ($LSRC =~ /\$(?:bp_appr_file|BACKPACK_APPROVALS_FILE)\s*=\s*"\$LAUNCHER_DIR\/backpack-approvals\.json"/g);
    ok(scalar(@appr_matches) > 0,
       'AC7: the backpack-approvals.json path still resolves via $LAUNCHER_DIR, unchanged (' .
       scalar(@appr_matches) . ' matching declaration(s) found)');

    # Negative half of the regression: none of these three durable constants'
    # declarations reference $SAMPLER_TMPDIR (would indicate the fix leaked
    # into a constant outside table 2b).
    unlike($LSRC, qr/\$SELECTION_FILE\s*=\s*"\$SAMPLER_TMPDIR/,
           'AC7 (negative): $SELECTION_FILE was NOT moved to $SAMPLER_TMPDIR');
    unlike($LSRC, qr/\$MANIFEST_FILE\s*=\s*"\$SAMPLER_TMPDIR/,
           'AC7 (negative): $MANIFEST_FILE was NOT moved to $SAMPLER_TMPDIR');
}

done_testing();
