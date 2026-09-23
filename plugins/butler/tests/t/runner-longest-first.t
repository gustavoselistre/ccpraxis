#!/usr/bin/env perl
# platform: any
# scripts/run-tests.pl records how long each test file took
# (test-state/durations.tsv) and starts the parallel queue longest-first on
# the next sweep, so the slowest file is never the tail every other worker
# waits behind.
#
# Fixture files append their own name to a log as they start; the runner is
# held to --jobs 1 so start order is observable. Every run points
# CCPRAXIS_TEST_STATE_DIR at a tempdir, so the repo's own state is untouched.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use RunnerStateHarness qw(make_fixture_tree run_runner_bounded runner_script slurp_raw);

my $log   = tempdir(CLEANUP => 1) . '/order.log';
my $state = tempdir(CLEANUP => 1);

sub fixture {
    my ($name, $sleep) = @_;
    return "#!/usr/bin/env perl\n# platform: any\n"
         . "open my \$l, '>>', \$ENV{ORDER_LOG} or die; print {\$l} \"$name\\n\"; close \$l;\n"
         . ($sleep ? "sleep $sleep;\n" : '')
         . "print \"ok 1\\n\";\nexit 0;\n";
}

my $dir = make_fixture_tree(
    'a-fast.t' => fixture('a-fast', 0),
    'b-slow.t' => fixture('b-slow', 3),
    'c-mid.t'  => fixture('c-mid', 1),
);

sub sweep {
    unlink $log;
    my $r = run_runner_bounded(args => ['--jobs', '1', $dir],
                               env  => { CCPRAXIS_TEST_STATE_DIR => $state, ORDER_LOG => $log },
                               timeout => 60);
    my @order = split /\n/, (slurp_raw($log) // '');
    return ($r, \@order);
}

my ($r1, $o1) = sweep();
is($r1->{rc}, 0, 'first sweep green') or diag($r1->{out} . $r1->{err});
is_deeply($o1, [qw(a-fast b-slow c-mid)], 'no timings yet: path order, as before');

my $tsv = slurp_raw("$state/durations.tsv") // '';
my %d = map { my ($s, $p) = split /\t/; ($p =~ m{([^/]+)\.t\z})[0] => $s } grep { length } split /\n/, $tsv;
is(scalar(keys %d), 3, 'durations.tsv holds one line per file') or diag($tsv);
cmp_ok($d{'b-slow'} // 0, '>=', 2, 'the slow fixture is recorded as slow');
cmp_ok($d{'a-fast'} // 99, '<', $d{'b-slow'} // 0, 'and the fast one as faster');

my ($r2, $o2) = sweep();
is($r2->{rc}, 0, 'second sweep green');
is($o2->[0], 'b-slow', 'second sweep starts the longest file first');
is($o2->[-1], 'a-fast', '...and the shortest last');

# A file with no recorded time is started before every timed one.
open my $w, '>', "$dir/tests/t/d-new.t" or die; print {$w} fixture('d-new', 0); close $w;
my ($r3, $o3) = sweep();
is($o3->[0], 'd-new', 'an untimed (new) file goes first');

# The pure ordering function, directly.
do { local @ARGV; require(runner_script()) };
my @files = map { "/r/$_.t" } qw(x y z w);
{
    no warnings 'redefine';
    local *main::_relpath = sub { $_[0] };
    is_deeply([ main::_order_longest_first(\@files, { '/r/x.t' => 5, '/r/y.t' => 50, '/r/z.t' => 5 }) ],
              [ '/r/w.t', '/r/y.t', '/r/x.t', '/r/z.t' ],
              'untimed first, then longest, ties in path order');
}

done_testing();
