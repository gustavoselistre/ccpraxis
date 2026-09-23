#!/usr/bin/env perl
# platform: windows
# IMMUTABLE ORACLE for package 01-live-watcher-probe (blueprint
# butler-gate-ergonomics), AC1-AC14 and AC21 of
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/
# 01-live-watcher-probe-spec.md.
#
# `bp-watch.pl probe` DOES NOT EXIST YET at the time this file is written
# (test-writer runs before the implementer). Every assertion that drives the
# `probe` verb is therefore expected to fail right now for the RIGHT reason:
# `probe` is not recognised as $ARGV[0] yet, so it falls through to the
# existing "any non-flag token is an unknown option" rule and exits 64 --
# never the 0/1/2 this file expects. AC13/AC14 (existing CLI surface
# unchanged) and the three baseline-suite re-runs are expected to be GREEN
# already, since nothing in the write set has touched them yet.
#
# WHY REAL PROCESSES DOMINATE THIS FILE, NOT SYNTHETIC /proc FIXTURES. The
# spec's own age model (started=<EPOCH>, remaining=max-age) is never spelled
# out as an exact ticks<->epoch formula anywhere in the spec text, only that
# BpWatch::proc_start_ticks returns the raw field-20 tick counter verbatim
# (AC10 pins that, and only that). Guessing the conversion formula to hand-
# build a synthetic "this candidate is definitely still live" /proc fixture
# would risk asserting an implementation detail the spec never committed to.
# Every test in this file that needs a TRUE liveness/expiry judgement
# therefore uses a REAL process (either the real bp-watch.pl, or a tiny stub
# script literally named bp-watch.pl that presents a real, OS-supplied
# cmdline/stat pair) so the probe's real host /proc answers for itself.
# Synthetic /proc fixtures are used only where the expected classification
# does NOT depend on ticks/age arithmetic at all: an unreadable stat file
# (AC4, undecided regardless of age), a malformed --max-seconds value (AC5,
# undecided regardless of age), a not-a-directory proc root (AC3, fails
# before any candidate is even read), and the ancestor-exclusion walk (self/
# parent pids are excluded before their cmdline is even inspected, per §3.6
# -- classification never runs on them at all).
#
# Every test that starts a process pushes its pid onto @KILL_PIDS and the
# END block below TERMs then KILLs everything left standing. Nothing in this
# file spawns plugins/sandbox/scripts/launcher.pl.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK -- see t/test-wakelock-hygiene.t.
# This file execs real bp-watch.pl subprocesses; CCPRAXIS_NO_WAKELOCK is
# inherited across exec.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use POSIX qw(_exit);
use Time::HiRes qw(time sleep);

my $WATCH = "$Bin/../../scripts/bp-watch.pl";

# ---------------------------------------------------------------------------
# Process bookkeeping -- every test that starts a real process (fork+exec)
# must push the pid here. TERM, poll, then KILL, on every path (pass, fail,
# or die).
# ---------------------------------------------------------------------------
my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) {
        next unless $pid;
        kill('TERM', $pid);
    }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) {
            next unless $pid;
            kill('KILL', $pid) if kill(0, $pid);
        }
        for my $pid (@KILL_PIDS) {
            next unless $pid;
            local $@;
            eval { waitpid($pid, 0) };
        }
    }
    # waitpid() above (and every backtick subprocess this file runs)
    # clobbers the process-global $?. Test::Builder's own END block (which
    # runs AFTER this one -- END blocks fire in LIFO registration order, and
    # Test::More's is registered before ours) inspects $? to detect a script
    # that died via a failed system()/exec(). Reset it so a reaped child's
    # exit status is never mistaken for this script's own.
    $? = 0;
}
# A runner timeout or Ctrl-C sends a signal, and perl's default action for
# one exits WITHOUT running END blocks -- so the reaper above never ran and
# every fixture outlived the test. Observed 2026-09-23: fourteen leaked
# `perl -e 'sleep 99999' bp-watch.pl --arm ...` forgers on the host, each
# good for another ~28 hours. Routing the signal through exit() runs END.
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# new_project() -> ($root, $data). $data (<root>/.ccpraxis-local-data)
# already exists as a directory; nothing under blueprints/ yet.
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    make_path($data);
    return ($root, $data);
}

sub write_ledger {
    my ($bpdir, $id, $status_line) = @_;
    make_path("$bpdir/packages");
    my $body = "---\npackage: $id\n";
    $body .= "$status_line\n" if defined $status_line;
    $body .= "---\n\nbody\n";
    open my $fh, '>', "$bpdir/packages/$id.md" or die "write $id.md: $!";
    print {$fh} $body;
    close $fh;
}

# new_running_bp($data, $bpname, $pkg) -- a real, non-terminal ledger a real
# bp-watch.pl can arm against and stay alive on.
sub new_running_bp {
    my ($data, $bpname, $pkg) = @_;
    my $bpdir = "$data/blueprints/$bpname";
    make_path("$bpdir/runs");
    write_ledger($bpdir, $pkg, 'status: running');
}

sub new_proc_dir { return tempdir(CLEANUP => 1) }

sub write_cmdline {
    my ($procdir, $pid, @argv) = @_;
    make_path("$procdir/$pid");
    open my $fh, '>', "$procdir/$pid/cmdline" or die "write cmdline($pid): $!";
    binmode $fh;
    print {$fh} join("\0", @argv) . "\0";
    close $fh;
}

# write_stat PROCDIR PID PPID TICKS -- 20 whitespace-separated fields after
# the ")", field 20 (index 19) is TICKS, per spec §4 notes-for-the-test-
# writer and BpResumption::pid_fingerprint's own /proc/<pid>/stat rule.
sub write_stat {
    my ($procdir, $pid, $ppid, $ticks, %opt) = @_;
    make_path("$procdir/$pid");
    my $comm  = $opt{comm}  // 'perl';
    my $state = $opt{state} // 'S';
    open my $fh, '>', "$procdir/$pid/stat" or die "write stat($pid): $!";
    print {$fh} "$pid ($comm) $state $ppid " . join(' ', (0) x 17) . " $ticks\n";
    close $fh;
}

sub write_stub_sleep {
    my ($path, $secs) = @_;
    open my $fh, '>', $path or die "write stub: $!";
    # BLOCKER-1 (redteam-step6.md): classify_candidate now requires a
    # matching arm-registry entry (pid + start-ticks fingerprint) before a
    # same-project candidate can classify 'live' -- see bp-watch.pl's own
    # comment on arm_registry_verified. This stub is meant to present a
    # GENUINELY armed watcher (AC6's undecidable half and AC8's live-then-
    # expired half), so it now performs that registration itself, off its
    # own real pid and its own real /proc/$$/stat, exactly as the real
    # --arm code path does -- not a new liveness mechanism, the SAME one,
    # exercised by a stub instead of the genuine script. A caller that
    # passes no --data (or whose /proc/$$/stat cannot be read) simply skips
    # this, unchanged from before.
    print {$fh} <<'PERL_STUB';
#!/usr/bin/env perl
use strict;
use warnings;
my $data;
for (my $i = 0; $i < @ARGV; $i++) {
    if ($ARGV[$i] eq '--data') { $data = $ARGV[$i + 1]; last }
}
if (defined $data) {
    my $stat_text = do {
        local $/;
        open my $sfh, '<', "/proc/$$/stat" or undef;
        $sfh ? <$sfh> : undef;
    };
    if (defined $stat_text && $stat_text =~ /\)\s*(.*)$/s) {
        my @f = split ' ', $1;
        my $ticks = $f[19];
        if (defined $ticks && $ticks =~ /^\d+$/) {
            my $dir = "$data/.watchers/arm-registry";
            unless (-d $dir) {
                eval { require File::Path; File::Path::make_path($dir) };
            }
            if (open my $rfh, '>', "$dir/$$") {
                print {$rfh} "$ticks\n";
                close $rfh;
            }
        }
    }
}
PERL_STUB
    print {$fh} "sleep($secs);\n";
    close $fh;
}

# write_arm_registry DATA PID TICKS -- the fixture-side equivalent of the
# entry a real `bp-watch.pl --arm` invocation writes for itself
# (arm_registry_path, bp-watch.pl). Used only by fully-synthetic /proc
# fixtures (no real process) that must still present as a genuinely-armed
# candidate under BLOCKER-1's new registry check.
sub write_arm_registry {
    my ($data, $pid, $ticks) = @_;
    my $dir = "$data/.watchers/arm-registry";
    make_path($dir);
    open my $fh, '>', "$dir/$pid" or die "write arm-registry($pid): $!";
    print {$fh} "$ticks\n";
    close $fh;
}

# write_stub_relay -- a stub literally named bp-watch.pl which, run with
# --arm ... args (ignored), forks a child that execs the REAL probe (path
# taken from $ENV{AC7_REAL_BP_WATCH} at run time, never baked into the
# source, to dodge any path-quoting/escaping question) and exits with that
# child's exit code. Used for AC7: the PARENT (this stub) keeps presenting
# the original --arm cmdline the whole time it waits.
sub write_stub_relay {
    my ($path) = @_;
    open my $fh, '>', $path or die "write stub: $!";
    print {$fh} <<'PERL_STUB';
#!/usr/bin/env perl
use strict;
use warnings;
my @a = @ARGV;
my $data;
for (my $i = 0; $i < @a; $i++) {
    if ($a[$i] eq '--data') { $data = $a[$i + 1]; last }
}
my $real = $ENV{AC7_REAL_BP_WATCH};
my $pid = fork();
if (!defined $pid) { exit 90 }
if ($pid == 0) {
    exec('perl', $real, 'probe', '--data', $data) or exit 91;
}
waitpid($pid, 0);
exit($? >> 8);
PERL_STUB
    close $fh;
}

sub spawn {
    my (@cmd) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        exec(@cmd) or POSIX::_exit(127);
    }
    # Recorded HERE, not at each call site: the BLOCKER-1a forger was spawned
    # without the call-site push, so it outlived every run of this file.
    push @KILL_PIDS, $pid;
    return $pid;
}

# spawn_watcher(@args) -- real bp-watch.pl --arm subprocess.
sub spawn_watcher {
    my (@args) = @_;
    my $pid = spawn('perl', $WATCH, @args);
    return $pid;
}

sub wait_proc_visible {
    my ($pid, $timeout) = @_;
    $timeout //= 5;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if -e "/proc/$pid/cmdline" || -e "/proc/$pid";
        select(undef, undef, undef, 0.05);
    }
    return 0;
}

sub run_probe {
    my (@args) = @_;
    return (undef, '', undef) unless -f $WATCH;
    my $cmd = join(' ', 'perl', qq("$WATCH"), 'probe', map { qq("$_") } @args);
    my $t0  = Time::HiRes::time();
    my $out = `$cmd 2>&1`;
    my $dt  = Time::HiRes::time() - $t0;
    return ($? >> 8, $out, $dt);
}

sub run_probe_env {
    my ($envs, @args) = @_;
    local %ENV = %ENV;
    for my $k (keys %$envs) {
        my $v = $envs->{$k};
        if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
    }
    return run_probe(@args);
}

sub run_cli {
    my (@args) = @_;
    return (undef, '') unless -f $WATCH;
    my $cmd = join(' ', 'perl', qq("$WATCH"), map { qq("$_") } @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub run_suite {
    my ($path) = @_;
    return (undef, undef, '') unless -f $path;
    my $out = `perl "$path" 2>&1`;
    my $rc  = $? >> 8;
    my $not_ok = () = ($out =~ /^not ok\b/mg);
    return ($rc, $not_ok, $out);
}

# ===========================================================================
# AC1 -- real live watcher on a non-terminal package -> probe exits 0, pid
# printed as the bare first field.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC1 fixture: real live watcher kept alive for probe', '--data', $data,
    );
    wait_proc_visible($pid, 5) or diag('AC1: watcher pid not visible in /proc within timeout');

    my ($rc, $out) = run_probe('--data', $data);
    is($rc, 0, 'AC1: probe exits 0 with a real, live, bounded bp-watch.pl watcher armed on a '
             . 'non-terminal package');
    my ($first_line) = split /\n/, ($out // '');
    my ($first_field) = split ' ', ($first_line // '');
    is($first_field, $pid, 'AC1b: stdout\'s first line begins with the watcher\'s pid as the '
                          . 'bare first field (awk \'{print $1}\' contract, spec §2.2)');
}

# ===========================================================================
# AC2 -- no watcher running for this data dir -> exit 1, single NONE: line.
# Asserted separately from AC1/AC3.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my ($rc, $out) = run_probe('--data', $data);
    is($rc, 1, 'AC2: with no watcher running for this data dir, the probe exits 1');
    like($out, qr/^NONE:/m, 'AC2b: ...and prints a NONE: line');
    my @lines = grep { length } split /\n/, ($out // '');
    is(scalar(@lines), 1, 'AC2c: exactly one line of stdout');
}

# ===========================================================================
# AC3 -- BP_PROBE_PROC_DIR pointed at a path that is NOT a directory -> exit
# 2, single CANNOT-TELL: line. Asserted separately, and asserted to be 2, not
# 1: collapsing 2 into 1 fails the gate closed against Decision 3.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $not_a_dir = "$root/not-a-directory-file";
    open my $fh, '>', $not_a_dir or die "write $not_a_dir: $!";
    print {$fh} "x";
    close $fh;

    my ($rc, $out) = run_probe_env({ BP_PROBE_PROC_DIR => $not_a_dir }, '--data', $data);
    is($rc, 2, 'AC3 CANONICAL: BP_PROBE_PROC_DIR pointed at a path that is not a directory -> '
             . 'exit 2, a distinct third outcome');
    isnt($rc, 1, 'AC3b: explicitly NOT 1 -- collapsing 2 into 1 fails the gate closed');
    like($out, qr/^CANNOT-TELL:/m, 'AC3c: stdout is a CANNOT-TELL: line');
    my @lines = grep { length } split /\n/, ($out // '');
    is(scalar(@lines), 1, 'AC3d: exactly one line of stdout');
}

# ===========================================================================
# AC4 -- an armed candidate whose stat file is unreadable -> 2, not 1; the
# SAME tree minus that entry -> 1. The pair proves the third outcome is real
# and attributable, not an artifact of the fixture/env plumbing.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $procdir = new_proc_dir();
    my $pid = 40001;
    write_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--package', 'bpz/pkg',
                  '--max-seconds', '99999', '--data', $data);
    # deliberately NO stat file at all -> unreadable.

    my ($rc, $out) = run_probe_env(
        { BP_PROBE_PROC_DIR => $procdir, BP_PROBE_SELF_PID => 999999, BP_PROBE_CLK_TCK => 100 },
        '--data', $data,
    );
    is($rc, 2, 'AC4a CANONICAL: an armed candidate whose stat file is unreadable classifies '
             . 'undecidable -> probe verdict CANNOT-TELL (2), never 1');
    like($out, qr/^CANNOT-TELL:/m, 'AC4b: stdout is CANNOT-TELL:');

    my $procdir2 = new_proc_dir();   # the SAME tree, minus that one entry
    my ($rc2, $out2) = run_probe_env(
        { BP_PROBE_PROC_DIR => $procdir2, BP_PROBE_SELF_PID => 999999, BP_PROBE_CLK_TCK => 100 },
        '--data', $data,
    );
    is($rc2, 1, 'AC4c: the identical scenario minus the unreadable-stat entry yields 1 (NONE) -- '
              . 'proves AC4a\'s 2 is attributable to that entry, not to fixture/env plumbing');
}

# ===========================================================================
# AC5 -- a candidate with --max-seconds present but non-numeric -> 2.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $procdir = new_proc_dir();
    my $pid = 40002;
    write_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--package', 'bpz/pkg',
                  '--max-seconds', 'notanumber', '--data', $data);
    write_stat($procdir, $pid, 1, int(time()));

    my ($rc, $out) = run_probe_env(
        { BP_PROBE_PROC_DIR => $procdir, BP_PROBE_SELF_PID => 999999, BP_PROBE_CLK_TCK => 100 },
        '--data', $data,
    );
    is($rc, 2, 'AC5: a candidate with --max-seconds present but non-numeric classifies '
             . 'undecidable -> CANNOT-TELL (2)');
    like($out, qr/^CANNOT-TELL:/m, 'AC5b: stdout is CANNOT-TELL:');
}

# ===========================================================================
# AC6 -- behavior 4: one genuinely LIVE candidate plus one UNDECIDABLE
# candidate -> verdict is live (0). Both are real processes, so no ticks/age
# formula is assumed: the live half is a real bp-watch.pl with a generous
# bound; the undecidable half is a stub presenting a malformed --max-seconds
# on its real cmdline (undecided regardless of age, per AC5's own rule).
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $live_pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC6 fixture: the live half', '--data', $data,
    );
    wait_proc_visible($live_pid, 5);

    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = "$stubdir/bp-watch.pl";
    write_stub_sleep($stub, 15);
    my $undecidable_pid = spawn(
        'perl', $stub, '--arm', '--package', 'bpx/other', '--max-seconds', 'garbage',
        '--data', $data,
    );
    wait_proc_visible($undecidable_pid, 5);

    my ($rc, $out) = run_probe('--data', $data);
    is($rc, 0, 'AC6 CANONICAL (behavior 4): one genuinely live candidate plus one undecidable '
             . 'candidate -> verdict is live (0) -- a positive observation is never downgraded '
             . 'by an unrelated unknown');
    like($out, qr/\b$live_pid\b/, 'AC6b: the live pid appears on stdout');
}

# ===========================================================================
# AC7 -- self/caller exclusion. Invoked from a PARENT process whose own
# command line is itself "perl <tmp>/bp-watch.pl --arm --package bp/p1
# --max-seconds 3000 --data <fixture>" (a stub that forks a child which execs
# the real probe and waits) -- the probe counts neither itself nor its
# caller -> exit 1.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = "$stubdir/bp-watch.pl";
    write_stub_relay($stub);

    local $ENV{AC7_REAL_BP_WATCH} = $WATCH;
    my $cmd = join(' ', 'perl', qq("$stub"), '--arm', '--package', 'bp/p1',
                   '--max-seconds', '3000', '--data', qq("$data"));
    my $out = `$cmd 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 1, 'AC7 CANONICAL: invoked from a parent whose own command line is itself a '
             . '"bp-watch.pl --arm" invocation, the probe counts neither itself nor its caller '
             . '-> exit 1 (NONE)');
}

# ===========================================================================
# AC8 -- a REAL process presenting an already-elapsed --max-seconds budget is
# not counted, even though it is still genuinely alive; the SAME process
# probed WITHIN its budget IS counted. Both halves against one real process
# (a stub literally named bp-watch.pl that just sleeps, ignoring its argv --
# unlike the real script it does not exit near its own bound, so the
# assertion is deterministic rather than racy, per the spec's own note).
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = "$stubdir/bp-watch.pl";
    write_stub_sleep($stub, 20);
    my $pid = spawn(
        'perl', $stub, '--arm', '--package', 'bp/p1', '--max-seconds', '2',
        '--reason', 'AC8 fixture: real short-budget watcher', '--data', $data,
    );
    wait_proc_visible($pid, 5) or diag("AC8: stub pid $pid not visible in /proc within timeout");

    my ($rc0) = run_probe('--data', $data);
    is($rc0, 0, 'AC8a: probed WITHIN its 2s budget, the real short-budget stub watcher IS '
              . 'counted (exit 0)');

    sleep(3.5);   # push elapsed well past the 2s budget; the stub sleeps 20s total, still alive
    ok(kill(0, $pid), 'AC8 precondition: the stub process is still alive at ~4s (proves the '
                     . 'non-counting below is attributable to elapsed budget, not process exit)');
    my ($rc1) = run_probe('--data', $data);
    is($rc1, 1, 'AC8b CANONICAL: the SAME real process, now past its 2s --max-seconds budget, is '
              . 'NOT counted (exit 1) even though it is still genuinely alive');
}

# ===========================================================================
# AC9 -- with 20 unrelated perl processes alive, one full probe subprocess
# completes in <500ms wall clock and returns a definite verdict (0, 1 or 2 --
# never a hang, never 64).
# ===========================================================================
{
    my ($root, $data) = new_project();
    my @noise = map { spawn('perl', '-e', 'sleep 8') } 1 .. 20;
    # Wait for every one to have EXEC'D (its cmdline reads "perl -e sleep 8"),
    # so the fixture is what the assertion says: twenty processes RUNNING,
    # not twenty still starting. (AC9 read 0.61-0.63s on 2026-09-24. The
    # cause was not this settle but the probe itself: MSYS /proc/<pid>/stat
    # costs 45-70ms per read -- see _probe_ppid in bp-watch.pl.)
    my $deadline = time() + 10;
    for my $p (@noise) {
        while (time() < $deadline) {
            my $cl = '';
            if (open my $fh, '<', "/proc/$p/cmdline") { local $/; $cl = <$fh> // ''; close $fh }
            last if $cl =~ /sleep/;
            select(undef, undef, undef, 0.05);
        }
    }
    select(undef, undef, undef, 0.3);   # and let the last exec finish settling

    my ($rc, $out, $dt) = run_probe('--data', $data);
    ok(defined $dt && $dt < 0.5,
       'AC9: probe completes in <500ms wall clock with 20 unrelated perl processes running (got '
     . (defined $dt ? sprintf('%.3f', $dt) : 'undef') . 's)');
    ok(defined $rc && grep({ $rc == $_ } (0, 1, 2)),
       'AC9b: ...and returns a definite verdict code (0, 1 or 2), never a hang or 64');
}

# ===========================================================================
# AC10 -- BpWatch::proc_start_ticks applied to the real /proc/$$/stat yields
# exactly the numeric tail of BpResumption::pid_fingerprint($$). Pins
# TECHNIQUE REUSE, not a second, divergent liveness mechanism.
# ===========================================================================
{
    require "$Bin/../../scripts/BpResumption.pm";
    my $LOADED = eval { require $WATCH; 1 };
    ok($LOADED, 'AC10 precondition: bp-watch.pl requires cleanly as (at least) package BpWatch')
        or diag("require died with: $@");

    my $expect = BpResumption::pid_fingerprint($$);
    my $stat_text = do {
        local $/;
        open my $fh, '<', "/proc/$$/stat" or undef;
        $fh ? <$fh> : undef;
    };
  SKIP: {
        skip 'no /proc/$$/stat on this host', 1 unless defined $stat_text;
        skip 'BpWatch::proc_start_ticks not yet defined', 1
            unless defined &BpWatch::proc_start_ticks;
        my $ticks = eval { BpWatch::proc_start_ticks($stat_text) };
        is(defined $ticks ? "proc:$ticks" : undef, $expect,
           'AC10 CANONICAL: BpWatch::proc_start_ticks(own /proc/$$/stat) matches the numeric '
         . 'tail of BpResumption::pid_fingerprint($$) exactly -- reuse of the existing '
         . 'technique, not a second liveness mechanism');
    }
}

# ===========================================================================
# AC11 -- a real watcher armed WITHOUT --data, whose cwd is inside the
# fixture project, is found by probe --data <fixture> (exit 0). This is the
# doctrine's own canonical invocation shape.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{CCPRAXIS_DATA_DIR};
        delete $ENV{BP_PROJECT_ROOT};
        chdir($root) or POSIX::_exit(96);
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        exec('perl', $WATCH, '--arm', '--package', 'bpx/p1', '--max-seconds', '300',
             '--poll', '1', '--reason', 'AC11 fixture: cwd-based data dir, no --data flag')
            or POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    wait_proc_visible($pid, 5) or diag('AC11: watcher pid not visible in /proc within timeout');

    my ($rc, $out) = run_probe('--data', $data);
    is($rc, 0, 'AC11 CANONICAL: a real watcher armed WITHOUT --data, whose cwd is inside the '
             . 'fixture project, IS found by probe --data <fixture> -- the cwd rung of §3.9 '
             . 'works on this host');
}

# ===========================================================================
# AC12 -- a watcher whose resolved data dir is a DIFFERENT project yields
# exit 1 (foreign, silently excluded), not cannot-tell.
# ===========================================================================
{
    my ($root1, $this_data)    = new_project();
    my ($root2, $foreign_data) = new_project();
    new_running_bp($foreign_data, 'foreignbp', 'p1');

    my $pid = spawn_watcher(
        '--arm', '--package', 'foreignbp/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC12 fixture: foreign project watcher', '--data', $foreign_data,
    );
    wait_proc_visible($pid, 5);

    my ($rc, $out) = run_probe('--data', $this_data);
    is($rc, 1, 'AC12: a watcher whose resolved data dir is a DIFFERENT project yields exit 1 '
             . '(foreign, silently excluded), never counted for this project');
    like($out, qr/^NONE:/m, 'AC12b: stdout is NONE:, not CANNOT-TELL -- foreign is a positive '
                           . 'exclusion, not an unknown');
}

# ===========================================================================
# AC13 -- bp-watch.pl still requires cleanly as package BpWatch, every
# pre-existing BpWatch:: sub from bp-watch-decision-core.t's A2 list is still
# defined, and bp-watch-cli.t / bp-watch-decision-core.t / bp-watch-doctrine.t
# all pass unchanged (not ok count 0).
# ===========================================================================
{
    my $LOADED = eval { require $WATCH; 1 };
    ok($LOADED, 'AC13a: bp-watch.pl requires cleanly as (at least) package BpWatch')
        or diag("require died with: $@");

    for my $sub (qw(is_terminal_status read_packages_dir blueprint_settled
                    all_pids_alive artifact_snapshot artifact_changed
                    resolve_condition format_change_line)) {
        ok(defined &{"BpWatch::$sub"},
           "AC13b: pre-existing BpWatch::$sub is still defined (decision-core.t's own A2 list)");
    }
}
{
    for my $suite (qw(bp-watch-cli.t bp-watch-decision-core.t bp-watch-doctrine.t)) {
        my $path = "$Bin/$suite";
        my ($rc, $not_ok, $out) = run_suite($path);
        is($rc, 0, "AC13c: $suite exits 0 (pre-existing suite unaffected by the probe addition)")
            or diag(substr($out // '', -2000));
        is($not_ok, 0, "AC13d: $suite reports zero 'not ok' lines")
            or diag(substr($out // '', -2000));
    }
}

# ===========================================================================
# AC14 -- probe is recognised ONLY as $ARGV[0]; everywhere else it is still
# an unrecognised token -> 64. A bogus flag and a bare invocation are also
# still 64.
# ===========================================================================
{
    my ($rc) = run_cli('--bogus-flag-xyz-ac14');
    is($rc, 64, 'AC14a: bp-watch.pl --bogus-flag-xyz ... is still 64');
}
{
    my ($rc) = run_cli('--arm', '--package', 'bp/p1', 'probe');
    is($rc, 64, 'AC14b: bp-watch.pl --arm ... probe (probe NOT in position 0) is still 64 -- '
              . 'only probe as $ARGV[0] reaches the new verb');
}
{
    my ($rc) = run_cli();
    is($rc, 64, 'AC14c: a bare bp-watch.pl with no args is still 64');
}

# ===========================================================================
# AC21 -- container question (audit-01 B9). Structural: the probe's process-
# enumeration, cmdline-reading and start-time subs contain no MSWin32/msys/
# cygwin conditional and no tasklist/wmic/ps -W call. Functional: probe_scan
# driven against fixture/real trees returns the full 0/1/2 verdict set.
# ===========================================================================
{
    my $src = -f $WATCH ? do { local (@ARGV, $/) = ($WATCH); <> } : undef;
    ok(defined $src, 'AC21 pre: bp-watch.pl source is readable') or diag('bp-watch.pl absent');

    my @probe_subs = qw(parse_proc_cmdline is_armed_watcher watcher_max_seconds
                         watcher_subject proc_start_ticks proc_ppid classify_candidate
                         probe_verdict probe_format_lines probe_scan);
    if (defined $src) {
        for my $name (@probe_subs) {
            if ($src =~ /^sub \Q$name\E\b(.*?)(?=^sub\s+\w+\s*[\{(]|\z)/ms) {
                my $body = $1;
                unlike($body, qr/\b(?:MSWin32|msys|cygwin)\b/,
                   "AC21: BpWatch::$name's body contains no MSWin32/msys/cygwin conditional");
                unlike($body, qr/\btasklist\b/i, "AC21: BpWatch::$name's body has no tasklist call");
                unlike($body, qr/\bwmic\b/i,     "AC21: BpWatch::$name's body has no wmic call");
                unlike($body, qr/\bps\s+-W\b/,   "AC21: BpWatch::$name's body has no 'ps -W' call");
            } else {
                fail("AC21: sub $name not found in bp-watch.pl source (required to inspect it)");
                fail("AC21: (placeholder -- $name body could not be extracted)") for 1 .. 3;
            }
        }
    } else {
        fail("AC21: cannot check source for $_ (file absent)") for @probe_subs;
    }
}
{
    require $WATCH if !defined &BpWatch::probe_scan && -f $WATCH;
  SKIP: {
        skip 'BpWatch::probe_scan not yet defined', 3 unless defined &BpWatch::probe_scan;

        # 'cannot-tell': synthetic, proc_dir itself does not exist.
        my ($root, $data) = new_project();
        my $res_ct = eval {
            BpWatch::probe_scan({
                proc_dir => "$root/does-not-exist-proc", self_pid => 555501, clk_tck => 100,
                project_data_dir => $data, now => time(), default_max_seconds => 2900,
                max_ancestor_hops => 32,
            });
        };
        is(ref($res_ct) eq 'HASH' ? $res_ct->{verdict} : undef, 'cannot-tell',
           'AC21 functional: probe_scan against a missing proc_dir returns verdict=cannot-tell');

        # 'none': synthetic, empty (but existing) proc_dir, no matching candidates at all.
        my $procdir_none = new_proc_dir();
        my $res_none = eval {
            BpWatch::probe_scan({
                proc_dir => $procdir_none, self_pid => 555502, clk_tck => 100,
                project_data_dir => $data, now => time(), default_max_seconds => 2900,
                max_ancestor_hops => 32,
            });
        };
        is(ref($res_none) eq 'HASH' ? $res_none->{verdict} : undef, 'none',
           'AC21 functional: probe_scan against an empty, Linux-shaped proc_dir returns '
         . 'verdict=none');

        # 'live': the real host /proc, a real running watcher.
        new_running_bp($data, 'bpx', 'p1');
        my $pid = spawn_watcher(
            '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
            '--reason', 'AC21 fixture: real live watcher for probe_scan', '--data', $data,
        );
        wait_proc_visible($pid, 5);
        my $res_live = eval {
            BpWatch::probe_scan({
                proc_dir => '/proc', self_pid => $$, clk_tck => 100,
                project_data_dir => $data, now => time(), default_max_seconds => 2900,
                max_ancestor_hops => 32,
            });
        };
        is(ref($res_live) eq 'HASH' ? $res_live->{verdict} : undef, 'live',
           'AC21 functional: probe_scan against the real host /proc with a real live watcher '
         . 'returns verdict=live -- the full 0/1/2 (live/none/cannot-tell) set is reachable '
         . 'from the pure function directly, not just via the CLI');
    }
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- BLOCKER-2 (redteam-step6.md). A --package
# value containing an embedded newline used to be emitted VERBATIM onto
# stdout by the sole sprintf in probe_format_lines, forging a second,
# fully-attacker-controlled line (arbitrary pid, arbitrary started=) that
# mark-wakeup.sh's line filter would then TERM/KILL. Fixed by watcher_subject
# collapsing any whitespace-bearing captured value to '-', plus
# probe_format_lines refusing to emit a whitespace-bearing subject as a
# belt-and-braces second layer. Pinned directly against a fixture /proc
# entry carrying the exact forged value from the red-team repro.
# ===========================================================================
{
    my ($root, $data) = new_project();
    my $procdir = new_proc_dir();
    my $self_pid = 40099;
    write_stat($procdir, $self_pid, 1, int(time()));
    my $pid = 40100;
    my $forged = "x\n99999 max=1 remaining=1 started=2000000000 subject=package:evil/pkg data=/d";
    write_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--data', $data, '--package', $forged);
    my $pid_ticks = int(time());
    write_stat($procdir, $pid, 1, $pid_ticks);
    # BLOCKER-1 (redteam-step6.md): this fixture is a purely synthetic
    # candidate (no real process), so it must present the arm-registry
    # entry a genuine --arm invocation would have written for itself --
    # this test is about subject-line sanitisation (BLOCKER-2), not about
    # BLOCKER-1's forgery question, and must not become a forgery repro by
    # omission.
    write_arm_registry($data, $pid, $pid_ticks);

    my ($rc, $out) = run_probe_env(
        { BP_PROBE_PROC_DIR => $procdir, BP_PROBE_SELF_PID => $self_pid, BP_PROBE_CLK_TCK => 100 },
        '--data', $data,
    );
    is($rc, 0, 'BLOCKER-2 regression precondition: the forged candidate still classifies live '
             . '(the sanitisation must not change the VERDICT, only the emitted subject text)');
    my @lines = grep { length } split /\n/, ($out // '');
    is(scalar(@lines), 1, 'BLOCKER-2 CANONICAL: exactly ONE stdout line is produced -- the embedded '
                         . 'newline in --package never forges a second, attacker-controlled line');
    like($lines[0], qr/^\d+ max=\d+ remaining=\d+ started=\d+ subject=\S+ data=/,
         'BLOCKER-2b: the single line still matches the §2.2 shape (no stray fields, no unescaped '
       . 'whitespace inside subject=)');
    unlike($lines[0], qr/subject=package:evil/,
           'BLOCKER-2c: the forged "subject=package:evil/pkg" text never reaches stdout as a real '
         . 'field -- watcher_subject collapsed the whitespace-bearing value to \'-\'');
}

# ===========================================================================
# CROSSCUTTING-DEFECTS -- BLOCKER-1 (redteam-step6.md). The probe's "live
# bounded watcher" used to be a pure text test over /proc/<pid>/cmdline: any
# process whose argv contained a bp-watch.pl basename AND '--arm' classified
# live, for whatever --max-seconds it claimed, with NO check that the pid
# was actually running this file. Fixed by requiring a matching arm-registry
# entry (pid + start-ticks fingerprint), written only by the real --arm code
# path at the moment it actually starts. (a) reproduces red-team's exact
# repro shape verbatim: a REAL process whose cmdline structurally satisfies
# is_armed_watcher, but which never executes this script and so never
# writes the registry entry. (b) is the counter-fixture: a genuine --arm
# invocation, which the CLI itself now registers, still classifies live.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');

    # (a) THE EXACT REPRO (sleep shortened, see below): `perl -e 'sleep 99999' ./bp-watch.pl --arm
    # --max-seconds 99999` -- the trailing tokens are unused arguments to
    # `perl -e`, never parsed or executed as this script. A real process,
    # a real /proc/<pid>/cmdline containing exactly those tokens, and (by
    # construction) no arm-registry entry anywhere, because the code that
    # would write one never ran.
    # The forger's own lifetime is bounded (120s -- far past the one probe
    # it has to survive) so that even a SIGKILLed test run, which no END
    # block can survive, leaves it behind for minutes rather than a day.
    # The "--max-seconds 99999" it CLAIMS is the forged part and stays.
    my $forger_pid = spawn(
        'perl', '-e', 'sleep 120',
        'bp-watch.pl', '--arm', '--max-seconds', '99999',
        '--package', 'bpx/p1', '--data', $data,
    );
    wait_proc_visible($forger_pid, 5)
        or diag('BLOCKER-1a: forger pid not visible in /proc within timeout');

    ok(!-e "$data/.watchers/arm-registry/$forger_pid",
       'BLOCKER-1a precondition: the forger never wrote an arm-registry entry for its own pid '
     . '(it never ran bp-watch.pl at all)');

    my ($rc_forged, $out_forged) = run_probe('--data', $data);
    isnt($rc_forged, 0,
         'BLOCKER-1a CANONICAL: red-team\'s exact repro (armed-looking cmdline, no arm-registry '
       . 'entry) no longer classifies live -- probe must NOT exit 0');
    like($out_forged, qr/^CANNOT-TELL:/m,
         'BLOCKER-1a2: ...and reads CANNOT-TELL, the same posture as an unreadable stat file or '
       . 'a malformed --max-seconds, never NONE (which would silently drop the candidate instead '
       . 'of flagging it as unverifiable)');

    # (b) THE COUNTER-FIXTURE: a genuine `bp-watch.pl --arm` invocation.
    # bp-watch.pl's own --arm code path now writes its own registry entry at
    # start, off its own real pid and /proc/$$/stat -- prove BOTH the file
    # and the resulting verdict.
    my $real_pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'BLOCKER-1b fixture: a genuine arm must still classify live', '--data', $data,
    );
    wait_proc_visible($real_pid, 5)
        or diag('BLOCKER-1b: real watcher pid not visible in /proc within timeout');

    my $reg_path = "$data/.watchers/arm-registry/$real_pid";
    my $reg_deadline = time() + 5;
    while (!-f $reg_path && time() < $reg_deadline) { select(undef, undef, undef, 0.05) }
    ok(-f $reg_path,
       'BLOCKER-1b precondition: a genuine --arm invocation wrote its own arm-registry entry');

    my ($rc_real, $out_real) = run_probe('--data', $data);
    is($rc_real, 0,
       'BLOCKER-1b CANONICAL: a genuine --arm invocation, registry entry present and matching, '
     . 'still classifies live -- the fix closes the forgery without breaking the real thing');
    like($out_real, qr/\b$real_pid\b/, 'BLOCKER-1b2: the real watcher\'s pid appears on stdout');
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- MINOR-5. `probe --data` with no following
# value (or an empty one) must be a usage error (64), never a silent fall-
# through to the CCPRAXIS_DATA_DIR/git-toplevel ladder that answers about a
# DIFFERENT directory with unwarranted confidence.
# ===========================================================================
{
    my ($rc, $out) = run_cli('probe', '--data');
    is($rc, 64, 'MINOR-5 CANONICAL: bp-watch.pl probe --data (missing value) exits 64, not a '
              . 'confident 0/1/2 about some other directory');
}

# Test::Builder inspects the process-global $? at END time to catch a script
# that DIED via a failed system()/exec(); this file legitimately runs many
# backtick subprocesses whose exit codes are non-zero BY DESIGN (64, 1, 2,
# ...), leaving $? stale and non-zero for no reason related to test outcome.
# Clear it so the script's own exit status reflects only actual test
# failures, never a leftover subprocess status.
$? = 0;
done_testing();
