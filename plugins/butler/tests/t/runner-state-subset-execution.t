#!/usr/bin/env perl
# Pins AC-3 of the --state=failed spec: with a non-empty, all-live recorded
# list, "--state=failed" executes EXACTLY those recorded files -- proven by a
# third, unrecorded fixture file that must never appear anywhere in the
# output -- and reports them in the same four-block summary shape a normal
# sweep already uses (file/wall/parallel/serial count line, RED:, slowest:),
# with exit code equal to the red count among that subset alone.
#
# The fixture lives entirely under File::Temp; nothing here ever targets
# plugins/*/tests/t/. Every invocation is bounded by
# RunnerStateHarness::run_runner_bounded's fork+timeout wrapper.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    make_fixture_tree green_source red_source
    relpath_from_root write_state_file
    run_runner_bounded
);

plan tests => 8;

my $BOUND = 20;

my $fixture = make_fixture_tree(
    'quick-green.t'  => green_source(),
    'quick-red-a.t'  => red_source('recorded, should run'),
    'quick-red-b.t'  => red_source('unrecorded, must never run'),
);
my $green_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
my $red_a_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-red-a.t');
my $red_b_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-red-b.t');

my $state_dir = tempdir(CLEANUP => 1);
# Record exactly two of the three fixture files -- quick-red-b.t is
# deliberately left unrecorded.
write_state_file($state_dir,
    sort(relpath_from_root($green_path), relpath_from_root($red_a_path)));

my $res = run_runner_bounded(
    args    => ['--state=failed'],
    env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
    timeout => $BOUND,
);

is($res->{rc}, 1,
    'AC-3: exit code equals the red count among the 2-file recorded subset (only quick-red-a.t is red)');
like($res->{out}, qr/^2 files/m,
    'AC-3: the summary line reports exactly 2 files examined, not the fixture\'s full 3');
like($res->{out}, qr/RED:/,
    'AC-3: the RED: block is present (same summary shape as a full run)');
like($res->{out}, qr/quick-red-a\.t/,
    'AC-3: the recorded red file is named in the output');
unlike($res->{out} . $res->{err}, qr/quick-red-b\.t/,
    'AC-3: the UNRECORDED third fixture file never appears anywhere in stdout or stderr -- proof it was never examined');
like($res->{out}, qr/slowest:/,
    'AC-3: the slowest: block is present (same summary shape as a full run)');
unlike($res->{out}, qr/all green/,
    'AC-3: "all green" is not printed -- the subset is not clean');
ok((-1 != index($res->{out}, "quick-green.t")) || (-1 != index($res->{out}, 'wall')),
    'AC-3: the recorded green file was also examined (named in slowest:, or at least a wall-clock summary line was printed)');

done_testing();
