#!/usr/bin/env perl
# platform: any
# Report 20260918-042312-02db, the reporting half.
#
# `scripts/run-tests.pl --fast` is the sweep this repo's CLAUDE.md names as the
# baseline to record before changing anything. It empties the host-serial lane
# and then printed `0 serial` -- a true statement that reads as "there were
# none" rather than "sixteen were dropped". Measured 2026-09-18: a --fast sweep
# reported 345 files all green while 16 files were never run, and nothing in the
# output said which.
#
# That lands directly on 20260916-162952-5ae3, whose thesis is that the repo's
# red signal cannot be trusted in either direction. A baseline whose COVERAGE is
# invisible is the same defect one level up: the number is accurate and the
# conclusion drawn from it is not.
#
# The other half of 02db -- that the serial lane is a text match on
# TestSandbox|podman_run_capture|podman_bin|probe_image rather than "starts a
# real container", so files that merely DISCUSS the lane are dropped with the
# ones that use it -- is a lane-model change and is NOT asserted here.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

(my $ROOT   = "$Bin/../../../..") =~ s{\\}{/}g;
my $RUNNER  = "$ROOT/scripts/run-tests.pl";
ok(-f $RUNNER, 'run-tests.pl is present') or BAIL_OUT("no runner at $RUNNER");

# Two real files from the tree: one the serial heuristic catches, one it does
# not. Using real files rather than a fixture tree keeps this honest about the
# classifier actually in force.
my $SERIAL   = "plugins/butler/tests/t/lane-routing.t";
my $PARALLEL = "plugins/butler/tests/t/repeat-guard.t";
ok(-f "$ROOT/$SERIAL",   'the serial-classified sample exists');
ok(-f "$ROOT/$PARALLEL", 'the parallel sample exists');

sub sweep {
    my (@args) = @_;
    my @cmd = ($^X, $RUNNER, @args);
    open(my $fh, '-|', @cmd) or die "spawn: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

# ---- --fast NAMES what it dropped -------------------------------------------
{
    my $out = sweep('--fast', '--nice', "$ROOT/$SERIAL", "$ROOT/$PARALLEL");

    like($out, qr/--fast skipped 1 host-serial file\(s\)/,
         '--fast states how many files it skipped');
    like($out, qr/this run did NOT cover them/,
         'and says plainly that they were not covered');
    like($out, qr/^\s+lane-routing\.t$/m,
         'and names the file, so the gap is checkable rather than merely admitted');

    # The regression that motivated this: the count line alone is not enough.
    like($out, qr/0 serial/,
         'the count line still reports 0 serial (it ran none) -- which is why the skip list is needed');
}

# ---- a run with nothing to skip says nothing --------------------------------
# A notice that fires every time is a notice nobody reads.
{
    my $out = sweep('--fast', '--nice', "$ROOT/$PARALLEL");
    unlike($out, qr/--fast skipped/,
           'a --fast run with no host-serial files in scope prints no skip notice');
}

# ---- WITHOUT --fast the file is run, not skipped -----------------------------
# The skip is a property of --fast, not of the file, and the notice must not
# appear on a full sweep that actually covered it.
{
    my $out = sweep('--nice', "$ROOT/$SERIAL");
    unlike($out, qr/--fast skipped/,
           'a full sweep prints no skip notice');
    like($out, qr/1 serial/,
         'and reports the file in the serial lane, having actually run it');
}

done_testing();
