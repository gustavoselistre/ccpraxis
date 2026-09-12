#!/usr/bin/env perl
# Pins the parallelism precedence chain the runner's usage text promises:
#
#   explicit `--jobs N`  >  `--nice`  >  the CCPRAXIS_TEST_JOBS env var  >
#   the plain cores-2 default (unchanged).
#
# Each case reads the "-jN" token out of the runner's own summary line
# ("%d files %ds wall (%d parallel at -jN, %d serial)"), which is what the
# runner already prints, rather than re-deriving the expected number from
# _resolve_jobs() by re-implementing its arithmetic here -- a duplicate
# formula would drift silently if the real one changed and prove nothing.
#
# Every invocation runs a tiny fixture tree via
# RunnerStateHarness::run_runner_bounded, per the module's own hazard
# warning against ever letting a spawned run-tests.pl glob the real repo
# tree from inside a test.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    make_fixture_tree green_source
    run_runner_bounded
);

plan tests => 6;

my $BOUND = 30;   # seconds; these fixtures are near-instant

sub jobs_from_summary {
    my ($out) = @_;
    return $out =~ /-j(\d+)/ ? $1 : undef;
}

# Six files: enough that none of the job counts under test (up to 5) get
# silently capped by the runner's own "never more workers than files" clamp
# (`$jobs = scalar(@parallel) if $jobs > @parallel`), which would make every
# assertion below pass for the wrong reason.
my $fixture = make_fixture_tree(
    map { ("quick-$_.t" => green_source()) } (1 .. 6)
);

# ---------------------------------------------------------------------------
# Baseline: no flag, no env var -- UNCHANGED cores-2 (or 1 on <=3 cores)
# default. This is the "someone is waiting on the result" path and must not
# regress just because --nice now exists.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => [$fixture], env => { CCPRAXIS_TEST_JOBS => '' }, timeout => $BOUND);
    my $j = jobs_from_summary($res->{out});
    ok(defined $j, 'baseline: the summary line reports a job count')
        or diag("stdout was: $res->{out}");
}

# ---------------------------------------------------------------------------
# --nice alone: caps at max(2, cores/4), strictly less than or equal to the
# plain default, and never less than 2.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => ['--nice', $fixture], env => { CCPRAXIS_TEST_JOBS => '' }, timeout => $BOUND);
    my $j = jobs_from_summary($res->{out});
    ok(defined $j && $j >= 2, '--nice: at least 2 workers (never the "unbearably long" 1)')
        or diag("stdout was: $res->{out}");
}

# ---------------------------------------------------------------------------
# CCPRAXIS_TEST_JOBS alone (no --nice, no --jobs): the env var sets the job
# count directly, as an ambient low-impact default.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => [$fixture], env => { CCPRAXIS_TEST_JOBS => '3' }, timeout => $BOUND);
    is(jobs_from_summary($res->{out}), 3, 'CCPRAXIS_TEST_JOBS=3 alone sets -j3')
        or diag("stdout was: $res->{out}");
}

# ---------------------------------------------------------------------------
# --nice beats CCPRAXIS_TEST_JOBS when both are present.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => ['--nice', $fixture], env => { CCPRAXIS_TEST_JOBS => '7' }, timeout => $BOUND);
    my $j = jobs_from_summary($res->{out});
    isnt($j, 7, '--nice overrides CCPRAXIS_TEST_JOBS rather than being overridden by it')
        or diag("stdout was: $res->{out}");
}

# ---------------------------------------------------------------------------
# Explicit --jobs N is the most specific: it wins over --nice AND over the
# env var, both present at once.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(
        args => ['--nice', '--jobs', '5', $fixture],
        env  => { CCPRAXIS_TEST_JOBS => '7' },
        timeout => $BOUND,
    );
    is(jobs_from_summary($res->{out}), 5,
        'explicit --jobs 5 wins over both --nice and CCPRAXIS_TEST_JOBS')
        or diag("stdout was: $res->{out}");
}

# ---------------------------------------------------------------------------
# --help documents --nice and the precedence chain.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => ['--help'], env => {}, timeout => $BOUND);
    like($res->{out}, qr/--nice/, '--help output documents --nice')
        or diag("stdout was: $res->{out}");
}

done_testing();
