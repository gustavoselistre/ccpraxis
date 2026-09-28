#!/usr/bin/env perl
# platform: any
# Pins the --state=failed CLI grammar from
# .ccpraxis-local-data/blueprints/test-naming-hygiene/specs/03-runner-state-failed-spec.md
# section 2.1: only the single-token "--state=failed" spelling is state-mode;
# "--state failed" (two tokens) falls through as an ordinary positional
# target unchanged; any other "--state=X" is a distinguishable usage error;
# "--state=failed" combined with a path/glob target refuses to compose. None
# of this exists in scripts/run-tests.pl yet, so every state-mode assertion
# below is expected to fail against the script as it stands today.
#
# Every invocation here targets a tiny File::Temp fixture (never the real
# plugins/*/tests/t/ tree) and is bounded via
# RunnerStateHarness::run_runner_bounded's fork+timeout wrapper, per the
# package's hazard warning against ever letting an invocation glob the real
# tree from inside a test.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    make_fixture_tree green_source red_source
    state_file_path
    run_runner_bounded
);

plan tests => 15;

my $BOUND = 20;   # seconds; these fixtures are 1-2 near-instant files

# ---------------------------------------------------------------------------
# AC-12: "--state=failed" combined with a positional target refuses to
# compose -- usage error, exit 2, nothing collected/executed/written, before
# any collection happens.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree(
        'quick-green.t' => green_source(),
        'quick-red.t'   => red_source('AC-12 sentinel'),
    );
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--state=failed', $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 2,
        'AC-12: --state=failed plus a positional target exits 2');
    like($res->{err}, qr/--state=failed/,
        'AC-12: the usage error on STDERR names --state=failed');
    unlike($res->{out}, qr/^\d+ files/m,
        'AC-12: no summary "N files" line -- collection never ran');
    ok(!-f state_file_path($state_dir),
        'AC-12: no state file was written for the refused invocation');
}

# ---------------------------------------------------------------------------
# AC-13: "--state=<anything but failed>" is a usage error with a message that
# names the bad value -- distinguishable from the generic "no test files
# matched" the pre-existing target-resolution code already prints for any
# unmatched positional.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(
        args    => ['--state=bogus'],
        env     => {},
        timeout => $BOUND,
    );

    is($res->{rc}, 2, 'AC-13: --state=bogus exits 2');
    like($res->{err}, qr/--state=bogus/,
        'AC-13: the usage error on STDERR names the bad value (bogus)');
    unlike($res->{err}, qr/no test files matched/,
        'AC-13: the message is distinguishable from the generic "no test files matched" fallback');
}

# ---------------------------------------------------------------------------
# AC-13b: the empty-value spelling "--state=" is likewise a usage error, not
# silently treated as an empty positional target.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(
        args    => ['--state='],
        env     => {},
        timeout => $BOUND,
    );

    is($res->{rc}, 2, 'AC-13: --state= (empty value) exits 2');
    like($res->{err}, qr/--state=/,
        'AC-13: the usage error on STDERR names the --state= spelling');
}

# ---------------------------------------------------------------------------
# AC-14: "--state failed" as TWO argv tokens is not recognized as state-mode
# at all -- "--state" is an unrecognized flag, "failed" is an ordinary
# positional target, and (with no file/dir literally named "failed" in the
# repo root) this falls through to the pre-existing "no test files matched"
# path, exit 2 -- exactly as it already does today, deliberately unchanged.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(
        args    => ['--state', 'failed'],
        env     => {},
        timeout => $BOUND,
    );

    is($res->{rc}, 2,
        'AC-14: --state failed (two tokens) is not state-mode -- falls through to "no test files matched"');
    like($res->{err}, qr/no test files matched/,
        'AC-14: the pre-existing generic message fires, proving no state-mode branch was taken');
    unlike($res->{out}, qr/no recorded failures/,
        'AC-14: the state-mode short-circuit string never appears -- "--state" alone never triggers state-mode');
}

# ---------------------------------------------------------------------------
# AC-15: --help / -h documents --state=failed.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => ['--help'], env => {}, timeout => $BOUND);
    is($res->{rc}, 0, 'AC-15: --help exits 0');
    like($res->{out}, qr/--state=failed/,
        'AC-15: --help output documents --state=failed');

    my $res_h = run_runner_bounded(args => ['-h'], env => {}, timeout => $BOUND);
    like($res_h->{out}, qr/--state=failed/,
        'AC-15: -h output documents --state=failed too');
}

done_testing();
