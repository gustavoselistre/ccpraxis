#!/usr/bin/env perl
# platform: any
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # this file names the real lease module in prose while
# proving a FAKE stand-in leftover process is caught; it never arms the real thing.
#
# Package 21-test-sandbox (hook-continuity-remake): scripts/run-tests.pl gets a
# per-test-file throwaway sandbox (HOME/USERPROFILE/APPDATA/LOCALAPPDATA/TEMP/
# TMP/TMPDIR/BUTLER_STATE_DIR/CCPRAXIS_CONTINUITY_ACTIVE_DIR), a pre/post-sweep
# audit that fails the sweep on a new repo path or a surviving fake
# keep-lease-style process, skip_all files reported as SKIPPED rather than
# silently green, and the same treatment for a single-file invocation. None of
# that exists yet -- this file is the oracle for it.
#
# EVERYTHING RUNS AGAINST A TEMP, GIT-INIT'D FAKE REPO, NEVER THE REAL TREE AND
# NEVER THE REAL HOME. The fake repo carries its own copy of
# scripts/run-tests.pl (plus the two files it unconditionally requires:
# scripts/run-tests-container.pl and plugins/butler/tests/lib/TestPlatform.pm)
# so that copy's own ROOT_ABS computation resolves to the fake repo, not this
# one -- any git-status audit or stray-file write it performs lands there, not
# here. Fixtures report what they saw through custom env vars
# (FIXTURE_REPORT_DIR / FIXTURE_REPO_ROOT) rather than $Bin arithmetic, since
# those two names sit outside the sandbox's own reserved-name set and so pass
# through whatever the (not yet built) sandboxing does to HOME et al.
#
# Every invocation is bounded by a fork+timeout wrapper mirroring
# RunnerStateHarness::run_runner_bounded (reused directly, along with its own
# repo_root() and slurp_raw()); nothing here uses system()/backticks/qx() on a
# literal sibling .t -- every spawn below targets a .pl (the fake repo's own
# copy of run-tests.pl) or an inline perl one-liner, never a repo .t file.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use POSIX ();

use lib "$Bin/../lib";
use HostCaps ();
use RunnerStateHarness qw(repo_root reap_with_grace slurp_raw);

my $BOUND = 60;   # generous: the fake repo's sweep is tiny, but git init/commit
                   # and a forked worker wave both cost real wall time on this host.

# ---------------------------------------------------------------------------
# Scaffolding (inline: this package's write set is this single file).
# ---------------------------------------------------------------------------

# build_fake_repo(%fixtures) -> $repo_abs
# %fixtures maps a bare basename (must end .t) to file content, written under
# $repo/plugins/x/tests/t/. Copies the real run-tests.pl and the two files it
# unconditionally `require`s, git-inits, and commits everything so the repo
# starts CLEAN -- any file appearing afterwards is genuinely new.
sub build_fake_repo {
    my (%fixtures) = @_;

    my $repo = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_root = repo_root();

    make_path(File::Spec->catdir($repo, 'scripts'));
    copy(File::Spec->catfile($real_root, 'scripts', 'run-tests.pl'),
         File::Spec->catfile($repo, 'scripts', 'run-tests.pl'))
        or die "cannot copy run-tests.pl: $!";
    copy(File::Spec->catfile($real_root, 'scripts', 'run-tests-container.pl'),
         File::Spec->catfile($repo, 'scripts', 'run-tests-container.pl'))
        or die "cannot copy run-tests-container.pl: $!";

    make_path(File::Spec->catdir($repo, qw(plugins butler tests lib)));
    copy(File::Spec->catfile($real_root, qw(plugins butler tests lib TestPlatform.pm)),
         File::Spec->catfile($repo, qw(plugins butler tests lib TestPlatform.pm)))
        or die "cannot copy TestPlatform.pm: $!";

    my $ttdir = repo_plugin_tests_dir($repo);
    make_path($ttdir);
    for my $name (sort keys %fixtures) {
        my $path = File::Spec->catfile($ttdir, $name);
        open my $fh, '>', $path or die "cannot write fixture $path: $!";
        print {$fh} $fixtures{$name};
        close $fh;
    }

    my $gp = HostCaps::git_path($repo);
    system('git', '-C', $gp, 'init', '-q') == 0
        or die "git init failed in $repo";
    system('git', '-C', $gp, 'add', '-A') == 0
        or die "git add failed in $repo";
    system('git', '-C', $gp, '-c', 'user.email=oracle@ccpraxis.test',
           '-c', 'user.name=oracle', 'commit', '-q', '-m', 'fake repo: initial commit') == 0
        or die "git commit failed in $repo";

    return $repo;
}

sub repo_plugin_tests_dir {
    my ($repo) = @_;
    return File::Spec->catdir($repo, qw(plugins x tests t));
}

# run_fake_sweep(repo=>.., args=>[..], env=>{..}, timeout=>N) -> {rc,out,err,timed_out}
# Mirrors RunnerStateHarness::run_runner_bounded exactly, except the script
# path is the FAKE repo's own copy, and env{HOME} is REQUIRED -- this process's
# real HOME is never allowed to leak to the child by omission.
sub run_fake_sweep {
    my (%args) = @_;
    my $repo    = $args{repo} or die 'run_fake_sweep: repo required';
    my $arglist = $args{args} // [];
    my $env     = $args{env}  // {};
    die "run_fake_sweep: env{HOME} is required (never inherit the real HOME)\n"
        unless defined $env->{HOME} && length $env->{HOME};
    my $script  = File::Spec->catfile($repo, 'scripts', 'run-tests.pl');

    my $out_fh = File::Temp->new(UNLINK => 0);
    my $err_fh = File::Temp->new(UNLINK => 0);
    my $out_path = "$out_fh";
    my $err_path = "$err_fh";
    close $out_fh;
    close $err_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        for my $k (keys %$env) { $ENV{$k} = $env->{$k} }
        open(STDOUT, '>', $out_path) or POSIX::_exit(97);
        open(STDERR, '>', $err_path) or POSIX::_exit(98);
        exec($^X, $script, @$arglist) or POSIX::_exit(99);
    }
    my ($rc, $timed_out) = reap_with_grace($pid, timeout => ($args{timeout} // $BOUND));
    my $out = slurp_raw($out_path) // '';
    my $err = slurp_raw($err_path) // '';
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err, timed_out => $timed_out, pid => $pid };
}

# Fixture sources. Every one reports through $ENV{FIXTURE_REPORT_DIR} and/or
# $ENV{FIXTURE_REPO_ROOT}, both set explicitly by the caller below, never
# derived from $Bin/dirname arithmetic inside the fixture itself.

sub home_probe_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use File::Path qw(make_path);
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $home = defined $ENV{HOME} ? $ENV{HOME} : '';
open(my $fh, '>', "$report/home-seen.txt") or die "$!";
print {$fh} $home;
close $fh;
if (length $home) {
    my $dir = "$home/.claude/butler-state";
    make_path($dir);
    open(my $w, '>', "$dir/x") or die "$!";
    print {$w} "touched\n";
    close $w;
}
print "ok 1 - home probe fixture ran\n";
exit 0;
SRC
}

sub stray_writer_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $root = $ENV{FIXTURE_REPO_ROOT};
die "FIXTURE_REPO_ROOT not set\n" unless defined $root && length $root;
open(my $fh, '>', "$root/stray-marker-file.txt") or die "$!";
print {$fh} "stray\n";
close $fh;
print "ok 1 - stray-writer fixture ran\n";
exit 0;
SRC
}

sub skip_all_source {
    my ($reason) = @_;
    $reason //= 'fixture: deliberately skipped';
    return <<"SRC";
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use Test::More;
plan skip_all => '$reason';
SRC
}

# leftover_process_source() -- forks, execs a real "perl -e 'sleep(60)'" child
# whose own argv literally carries the fake stand-in name (the ledger's own
# example), records that child's pid to
# "$FIXTURE_REPORT_DIR/leftover-pid.txt", and exits WITHOUT waiting --
# orphaning it exactly the way a real leaked helper is orphaned.
sub leftover_process_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $pid = fork();
die "fork failed: $!" unless defined $pid;
if ($pid == 0) {
    # Close the inherited stdout/stderr BEFORE exec: run-tests.pl's own
    # run_one() captures this fixture through a backtick pipe, which does not
    # see EOF until every process holding the write end closes it -- without
    # this, the orphaned grandchild below holds that pipe open for its whole
    # sleep, and the SWEEP ITSELF hangs on this one file instead of moving on.
    open(STDIN,  '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
    exec($^X, '-e', 'sleep(60)', 'keep-awake.ps1') or exit(127);
}
open(my $fh, '>', "$report/leftover-pid.txt") or die "$!";
print {$fh} $pid;
close $fh;
print "ok 1 - leftover-process fixture ran, leaving a background process alive\n";
exit 0;
SRC
}

sub green_fixture_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - plain fixture pass\\n\";\nexit 0;\n";
}

sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/;
    return kill(0, $pid) ? 1 : 0;
}

my @KILL_ON_EXIT;   # pids of every fixture-orphaned process this file learns about;
                    # killed unconditionally in the END block below.
END {
    for my $pid (@KILL_ON_EXIT) {
        next unless pid_alive($pid);
        kill('KILL', $pid);
    }
}

sub read_report {
    my ($dir, $name) = @_;
    my $path = File::Spec->catfile($dir, $name);
    return undef unless -f $path;
    return slurp_raw($path);
}

# ---------------------------------------------------------------------------
# AC-1: a fixture writing $HOME/.claude/butler-state/x lands under the
# runner's own per-file sandbox, not under the HOME the runner was started
# with -- proven for both a full default sweep AND an explicit single-file
# target (the ledger's "single-file run gets the same sandbox" clause).
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('home-probe.t' => home_probe_source());
    my $fixture_path = File::Spec->catfile(repo_plugin_tests_dir($repo), 'home-probe.t');

    for my $case (
        { label => 'full default sweep', args => [] },
        { label => 'explicit single-file target', args => [$fixture_path] },
    ) {
        my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
        my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

        # Deliberately NO --keep-sandbox here -- AC-1 is about ISOLATION
        # (does the write land somewhere other than the outer HOME), not
        # about lifecycle (AC-5 owns that). Requiring the flag here would
        # make this block depend on --keep-sandbox parsing too, muddying
        # which missing behavior a red result points at.
        my $res = run_fake_sweep(
            repo    => $repo,
            args    => [@{ $case->{args} }],
            env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
            timeout => $BOUND,
        );

        is($res->{rc}, 0,
            "AC-1 ($case->{label}): the home-probe fixture itself runs cleanly")
            or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

        my $outer_marker = File::Spec->catfile($outer_home, qw(.claude butler-state x));
        ok(!-e $outer_marker,
            "AC-1 ($case->{label}): the HOME the runner was STARTED with is never written to "
          . "(no .claude/butler-state/x appears under it)")
            or diag("outer HOME leaked into: $outer_marker");

        my $seen_home = read_report($report_dir, 'home-seen.txt');
        ok(defined $seen_home && length $seen_home,
            "AC-1 ($case->{label}): the fixture reported the HOME it actually ran under");

        if (defined $seen_home && length $seen_home) {
            isnt($seen_home, $outer_home,
                "AC-1 ($case->{label}): the fixture's own HOME differs from the runner's "
              . "starting HOME -- it ran inside a per-file sandbox, not the outer one");
        } else {
            fail("AC-1 ($case->{label}): the fixture's own HOME differs from the runner's "
               . 'starting HOME (no HOME was reported at all)');
        }
    }
}

# ---------------------------------------------------------------------------
# AC-2: a fixture that creates a stray file directly in the fake repo's own
# root fails the sweep and NAMES the path. (The runner's own
# .ccpraxis-local-data/test-state writes, which happen on every sweep today
# regardless, are explicitly exempted by the contract -- but its exact
# wording for "ignored" isn't pinned by the spec, so this oracle does not
# assert a specific phrase for that half; only that the DELIBERATE stray is
# named and fails the sweep.)
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('stray-writer.t' => stray_writer_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        timeout => $BOUND,
    );

    isnt($res->{rc}, 0,
        'AC-2: a stray file appearing in the fake repo root FAILS the sweep')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/stray-marker-file\.txt/,
        'AC-2: the failure NAMES the stray path')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# AC-3: a skip_all file is listed as SKIPPED with its reason, not folded
# silently into a green result.
# ---------------------------------------------------------------------------
{
    my $reason = 'fixture-reason-9f3c: deliberately skipped for the sandbox oracle';
    my $repo = build_fake_repo('skip-me.t' => skip_all_source($reason));
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'AC-3: a skip_all file alone does not fail the sweep')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/SKIPPED/,
        'AC-3: the skip_all file is listed as SKIPPED')
        or diag("stdout:\n$res->{out}");
    like($res->{out}, qr/\Q$reason\E/,
        'AC-3: the SKIPPED listing carries the file\'s own skip reason')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC-4: a fixture that leaves a background process behind, whose own command
# line carries the fake stand-in name, fails the sweep's post-run audit and
# NAMES it. The process is killed unconditionally at the end of this file
# regardless of how these assertions land.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('leftover.t' => leftover_process_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    my $leftover_pid = read_report($report_dir, 'leftover-pid.txt');
    if (defined $leftover_pid && $leftover_pid =~ /(\d+)/) {
        push @KILL_ON_EXIT, $1;   # unconditional cleanup, whatever the assertions below say
    }

    isnt($res->{rc}, 0,
        'AC-4: a surviving fixture-spawned background process FAILS the sweep\'s audit')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/keep-awake\.ps1/,
        'AC-4: the audit failure NAMES the offending process')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    if (defined $leftover_pid && $leftover_pid =~ /^(\d+)$/) {
        my $pid = $1;
        kill('KILL', $pid);
        my $deadline = time() + 10;
        while (time() < $deadline && pid_alive($pid)) { select(undef, undef, undef, 0.1) }
        ok(!pid_alive($pid), 'AC-4: the leftover process is dead after this file\'s own cleanup');
    } else {
        fail('AC-4: the fixture reported a leftover pid to clean up')
            or diag("report dir contents unavailable; leftover_pid=" . (defined $leftover_pid ? $leftover_pid : '<undef>'));
    }
}

# ---------------------------------------------------------------------------
# AC-5: the per-file sandbox root is removed by default, and kept only with
# --keep-sandbox -- proven by checking whether the reported sandbox HOME
# (which lives inside that root) still exists afterward.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('home-probe-2.t' => home_probe_source());

    my $outer_home_default = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_default     = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $res_default = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home_default, FIXTURE_REPORT_DIR => $report_default },
        timeout => $BOUND,
    );
    my $home_default = read_report($report_default, 'home-seen.txt');
    ok(defined $home_default && length $home_default,
        'AC-5 (default): the fixture reported a sandbox HOME');
    ok((defined $home_default && length $home_default) ? !-e $home_default : 0,
        'AC-5 (default): the reported sandbox HOME no longer exists after the sweep (removed by default)')
        or diag('sandbox HOME still present: ' . (defined $home_default ? $home_default : '<undef>'));

    my $outer_home_keep = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_keep     = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $res_keep = run_fake_sweep(
        repo    => $repo,
        args    => ['--keep-sandbox'],
        env     => { HOME => $outer_home_keep, FIXTURE_REPORT_DIR => $report_keep },
        timeout => $BOUND,
    );
    my $home_keep = read_report($report_keep, 'home-seen.txt');
    ok(defined $home_keep && length $home_keep,
        'AC-5 (--keep-sandbox): the fixture reported a sandbox HOME');
    ok((defined $home_keep && length $home_keep) ? -e $home_keep : 0,
        'AC-5 (--keep-sandbox): the reported sandbox HOME still exists after the sweep')
        or diag('sandbox HOME missing: ' . (defined $home_keep ? $home_keep : '<undef>'));
}

# ---------------------------------------------------------------------------
# AC-6: a normal, side-effect-free fixture stays green and the audit passes
# -- the "nothing here should ever go red" floor.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('plain-pass.t' => green_fixture_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'AC-6: a plain passing fixture with no side effects stays green')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/all green/,
        'AC-6: the sweep reports "all green"')
        or diag("stdout:\n$res->{out}");
}

done_testing();
