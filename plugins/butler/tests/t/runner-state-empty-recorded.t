#!/usr/bin/env perl
# platform: any
# Pins AC-4 of the --state=failed spec (03-runner-state-failed-spec.md
# section 2.4): when there is nothing recorded -- the state file never
# existed, or exists but is empty -- "--state=failed" must print the exact
# short-circuit string on STDOUT, exit 0, and execute nothing (no summary
# line, no RED:/all-green block, no slowest: block), never silently falling
# back to a full sweep. That inverse -- running everything when nothing was
# recorded -- is the one behavior this package calls out as the dangerous
# failure mode, so it gets its own dedicated, isolated oracle rather than
# being folded into a grammar or write-semantics file.
#
# No fixture tree is ever passed as a target here: state-mode is meant to
# supply its own file list from the (empty) state file, never from a glob.
# CCPRAXIS_TEST_STATE_DIR isolates every invocation from the developer's real
# accumulating state file, and every invocation is bounded via
# RunnerStateHarness's fork+timeout wrapper.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    state_file_path write_state_file slurp_raw
    run_runner_bounded
);

plan tests => 10;

my $BOUND = 20;
my $EXACT = "no recorded failures -- nothing to run\n";

# ---------------------------------------------------------------------------
# Case 1: state file never existed at all.
# ---------------------------------------------------------------------------
{
    my $state_dir = tempdir(CLEANUP => 1);
    ok(!-f state_file_path($state_dir), 'sanity: no state file exists before the run (missing case)');

    my $res = run_runner_bounded(
        args    => ['--state=failed'],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 0, 'AC-4 (missing state file): exits 0');
    is($res->{out}, $EXACT,
        'AC-4 (missing state file): STDOUT is exactly the short-circuit string, nothing else');
    unlike($res->{out}, qr/files\s+\d+s wall/,
        'AC-4 (missing state file): the normal summary line is entirely absent');
    ok(!-f state_file_path($state_dir),
        'AC-4 (missing state file): still no state file after the run -- nothing was written');
}

# ---------------------------------------------------------------------------
# Case 2: state file exists but is empty (0 bytes) -- same outcome.
# ---------------------------------------------------------------------------
{
    my $state_dir = tempdir(CLEANUP => 1);
    write_state_file($state_dir);   # no lines -> 0-byte file
    my $before = slurp_raw(state_file_path($state_dir));
    is($before, '', 'sanity: pre-seeded state file is genuinely empty (empty case)');

    my $res = run_runner_bounded(
        args    => ['--state=failed'],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 0, 'AC-4 (empty state file): exits 0');
    is($res->{out}, $EXACT,
        'AC-4 (empty state file): STDOUT is exactly the short-circuit string, nothing else');
    unlike($res->{out}, qr/RED:|all green|slowest:/,
        'AC-4 (empty state file): no RED:/all-green/slowest: block appears');
    my $after = slurp_raw(state_file_path($state_dir));
    is($after, $before,
        'AC-4 (empty state file): file is byte-identical after the run -- the short-circuit performs no write');
}

done_testing();
