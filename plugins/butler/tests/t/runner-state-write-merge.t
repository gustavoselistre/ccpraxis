#!/usr/bin/env perl
# platform: any
# Pins the write/merge semantics of the --state=failed spec (section 2.3):
# the state file is written from the SAME @red data the RED: block already
# prints, never a second computation; a scope-narrower (--fast excluding
# serial/container files, or a path/glob target excluding everything outside
# it) carries forward whatever it did not touch rather than erasing it; a
# recorded entry that no longer resolves on disk is dropped, never carried;
# and two sequential captures of the file diff cleanly, with no reordering
# noise, because entries are written sorted. Also confirms (AC-2) that the
# state path is already git-ignored by existing rules, with no .gitignore
# edit needed -- a check independent of whether --state=failed exists yet,
# so it is expected to already pass.
#
# Every fixture lives under File::Temp; nothing here ever targets the real
# plugins/*/tests/t/ tree except the literal, deliberately-nonexistent
# sentinel path used to prove vanished-entry pruning (a string that is never
# opened, only checked with -f and expected to be false). Every invocation of
# scripts/run-tests.pl is bounded via RunnerStateHarness's fork+timeout
# wrapper.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    repo_root make_fixture_tree green_source red_source
    state_file_path write_state_file read_state_file slurp_raw
    relpath_from_root
    run_runner_bounded
);

plan tests => 17;

my $BOUND = 20;

# ---------------------------------------------------------------------------
# AC-1 (DC1): after a real --fast sweep, the state file exists and its
# content equals the sorted relpath set of @red -- and, since the sweep
# excludes the serial-classified fixture file entirely (never in @results),
# that file cannot appear via %red, and this state dir started empty so it
# cannot appear via carry-forward either.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree(
        'quick-green.t'   => green_source(),
        'quick-red.t'     => red_source('AC-1 the one true red'),
        # source text containing a classification marker (run-tests.pl:75)
        # -- classified serial, and dropped entirely under --fast (:78), so
        # it must never appear in @results, @red, or the state file.
        #
        # THE PLATFORM MARKER IS LOAD-BEARING, not decoration (test-platform-split
        # package 03, blueprint Decision 16). This fixture is written to disk and
        # run through the real run-tests.pl, so it meets the marker gate -- which
        # sits BEFORE the container heuristic and which --fast does not exempt.
        # Without a marker it is REFUSED (red, and in the state file) rather than
        # classified serial and dropped, which is what AC-1's two assertions below
        # actually observe. The gate is right; this fixture simply predates it.
        # Decision 16 marked RunnerStateHarness's three generators; this literal
        # is hand-rolled here and so was not reached by that fix.
        'serial-marker.t' => "#!/usr/bin/env perl\n# platform: any\n# would call podman_bin() if ever run\nprint \"not ok 1 - must never run under --fast\\n\";\nexit 1;\n",
    );
    my $red_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-red.t');
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--fast', $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    ok(-f state_file_path($state_dir),
        'AC-1: the state file exists after a completed --fast sweep');
    my @got = read_state_file($state_dir);
    is_deeply(\@got, [ relpath_from_root($red_path) ],
        'AC-1: state file content equals exactly the sorted relpath of @red (the one true red file)');
    unlike(slurp_raw(state_file_path($state_dir)) // '', qr/serial-marker/,
        'AC-1: the --fast-excluded serial file never appears in the state file');
}

# ---------------------------------------------------------------------------
# AC-2 (DC1): the state path is already git-ignored -- verified, not
# assumed, and independent of whether --state=failed exists yet.
# ---------------------------------------------------------------------------
{
    my $root = repo_root();
    my $target = File::Spec->catfile($root, '.ccpraxis-local-data', 'test-state', 'last-failures.txt');
    system('git', '-C', $root, 'check-ignore', '-q', $target);
    my $rc = $? >> 8;
    is($rc, 0,
        'AC-2: .ccpraxis-local-data/test-state/last-failures.txt is already git-ignored (no .gitignore edit needed)');
}

# ---------------------------------------------------------------------------
# AC-5 (DC4): merge/write sourced from the identical @red the printer used.
# No carry-forward is possible (state dir starts empty), so the written
# content can only be this run's own @red.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree(
        'quick-green.t' => green_source(),
        'forced-red.t'  => red_source('AC-5 the printed red'),
    );
    my $red_path = File::Spec->catfile($fixture, 'tests', 't', 'forced-red.t');
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => [$fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    like($res->{out}, qr/forced-red\.t/,
        'AC-5: the printed RED: block names the forced-red fixture file');
    my @got = read_state_file($state_dir);
    is_deeply(\@got, [ relpath_from_root($red_path) ],
        'AC-5: the post-run state file content is exactly that same file\'s relpath -- one write, one source of truth');
}

# ---------------------------------------------------------------------------
# AC-9 (DC6): a scoped run (a path/glob target excluding everything outside
# it) must not erase knowledge of an out-of-scope recorded failure. A
# synthetic two-"plugin"-shaped fixture stands in for the spec's literal
# `plugins/butler` example -- running the real 162-file plugins/butler tree
# from inside this suite would itself be the unbounded-sweep hazard this
# package explicitly forbids. The merge mechanism (spec section 2.3) is
# scope-agnostic by design ("%ran ... is defined identically whether a file
# was excluded by --fast, by a path/glob target, or ... --state=failed
# scope"), so a fixture path/glob target exercises the identical code path.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $a_dir = File::Spec->catdir($root, 'plugin-a', 'tests', 't');
    my $b_dir = File::Spec->catdir($root, 'plugin-b', 'tests', 't');
    make_path($a_dir, $b_dir);

    my $a_red = File::Spec->catfile($a_dir, 'a-red.t');
    open my $fh_a, '>', $a_red or die "cannot write fixture: $!";
    print {$fh_a} red_source('AC-9 in-scope red');
    close $fh_a;

    my $b_red = File::Spec->catfile($b_dir, 'b-red.t');
    open my $fh_b, '>', $b_red or die "cannot write fixture: $!";
    print {$fh_b} red_source('AC-9 out-of-scope, must be carried forward');
    close $fh_b;

    my $state_dir = tempdir(CLEANUP => 1);
    write_state_file($state_dir, relpath_from_root($b_red));

    my $res = run_runner_bounded(
        args    => [ File::Spec->catdir($root, 'plugin-a') ],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    like($res->{out}, qr/a-red\.t/,
        'AC-9: the in-scope plugin-a red file is judged and named in the output');
    my @got = sort(read_state_file($state_dir));
    my @want = sort(relpath_from_root($a_red), relpath_from_root($b_red));
    is_deeply(\@got, \@want,
        'AC-9: the rewritten state file contains BOTH the freshly-judged in-scope entry AND the untouched out-of-scope entry, carried forward');
    ok((grep { $_ eq relpath_from_root($b_red) } @got) == 1,
        'AC-9: the out-of-scope entry appears exactly once, not dropped and not duplicated');
}

# ---------------------------------------------------------------------------
# AC-10 (DC1/DC4, diffability) + spec behavior #11: two sequential captures
# after a fix, diffed line-for-line, show only the changed entry -- the
# untouched still-red entry's line is byte-identical across both captures,
# and entries stay sorted (no reordering noise).
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree(
        'file-a.t' => red_source('AC-10 initially red, will be fixed'),
        'file-b.t' => red_source('AC-10 stays red throughout'),
    );
    my $a_path = File::Spec->catfile($fixture, 'tests', 't', 'file-a.t');
    my $b_path = File::Spec->catfile($fixture, 'tests', 't', 'file-b.t');
    my $state_dir = tempdir(CLEANUP => 1);

    run_runner_bounded(
        args    => [$fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );
    my @capture1 = read_state_file($state_dir);
    is_deeply([ sort @capture1 ],
        [ sort(relpath_from_root($a_path), relpath_from_root($b_path)) ],
        'AC-10: first capture records both still-red fixture files');

    # Fix file-a.t in place (overwrite with a passing source).
    open my $fh, '>', $a_path or die "cannot rewrite fixture: $!";
    print {$fh} green_source();
    close $fh;

    run_runner_bounded(
        args    => ['--state=failed'],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );
    my @capture2 = read_state_file($state_dir);
    is_deeply(\@capture2, [ relpath_from_root($b_path) ],
        'AC-10: second capture (after fixing file-a.t) contains only the still-red file-b.t');

    my ($b_line1) = grep { $_ eq relpath_from_root($b_path) } @capture1;
    my ($b_line2) = grep { $_ eq relpath_from_root($b_path) } @capture2;
    is($b_line1, $b_line2,
        'AC-10: the untouched file-b.t entry is byte-identical text across both captures -- a real line-diff would show only the file-a.t line changing');
}

# ---------------------------------------------------------------------------
# AC-11 (DC1, live-relevance: package 01 just renamed all 310 files): a
# recorded entry whose path no longer resolves on disk does not error --
# it is skipped with a diagnostic and pruned from the rewritten state file,
# while any surviving recorded entry still runs normally.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree('red-c.t' => red_source('AC-11 the surviving entry'));
    my $red_c_path = File::Spec->catfile($fixture, 'tests', 't', 'red-c.t');
    my $vanished_relpath = 'plugins/butler/tests/t/ZZZ-does-not-exist-fixture-sentinel.t';
    # Guard the fixture's own premise: this sentinel must genuinely not exist.
    ok(!-f File::Spec->catfile(repo_root(), $vanished_relpath),
        'AC-11: sanity -- the fabricated vanished-entry sentinel path genuinely does not exist on disk');

    my $state_dir = tempdir(CLEANUP => 1);
    write_state_file($state_dir, sort(relpath_from_root($red_c_path), $vanished_relpath));

    my $res = run_runner_bounded(
        args    => ['--state=failed'],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 1, 'AC-11: exit code reflects the one surviving, still-red recorded entry');
    like($res->{err}, qr/no longer exists/,
        'AC-11: STDERR reports the vanished entry with a "no longer exists" diagnostic');
    like($res->{err}, qr/\Q$vanished_relpath\E/,
        'AC-11: the diagnostic names the specific vanished relpath');
    my @got = read_state_file($state_dir);
    is_deeply(\@got, [ relpath_from_root($red_c_path) ],
        'AC-11: the rewritten state file contains the surviving entry but not the pruned vanished one');
}

done_testing();
