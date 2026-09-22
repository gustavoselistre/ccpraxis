#!/usr/bin/env perl
# platform: windows
# IMMUTABLE ORACLE for package 01-live-watcher-probe (blueprint
# butler-gate-ergonomics), AC15-AC20 of
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/
# 01-live-watcher-probe-spec.md (Decision 10 -- watcher reaping).
#
# NEITHER mark-wakeup.sh's reap logic NOR bp-watch.pl's `probe` verb exists
# yet at the time this file is written. mark-wakeup.sh's reap step calls
# `bp-watch.pl probe --data ...` internally; since `probe` is not yet
# recognised (falls through to "unknown option" -> exit 64, per the sibling
# oracle watcher-probe-liveness.t), every assertion below that depends on a
# real reap actually happening is expected to fail right now for the RIGHT
# reason: nothing is being killed, because the hook cannot yet get a
# definite answer out of the probe. AC15 (arming itself, which is INDEPENDENT
# of the probe) is expected to be genuinely RED too, since the arm-record
# write is also new. The three re-run baseline suites (AC20c/d) are expected
# GREEN already, since nothing in the write set has touched them yet.
#
# Every test that starts a real process pushes its pid onto @KILL_PIDS; the
# END block TERMs then KILLs everything left standing. Nothing in this file
# spawns plugins/sandbox/scripts/launcher.pl.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK -- see t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Spec ();
use POSIX qw(_exit WNOHANG);

# proc_is_dead($pid) -> true iff $pid is genuinely gone. ORACLE EDIT (authorized
# 2026-09-22, package 01-live-watcher-probe step 4/5): a TERM-killed child this
# test process spawned and never reaped becomes a zombie -- kill(0,$pid) still
# reports it "alive" per POSIX semantics until waitpid'd, which is exactly what
# this test's own AC16/AC17 death-checks were doing. Confirmed against this
# repo's own established pattern for the identical situation
# (runner-state-kill-mid-flight.t's waitpid($pid, WNOHANG) use). Live processes
# this test does NOT own (AC17's lease, AC18/AC19's survivors) are unaffected --
# kill(0,$pid) on a genuinely-unrelated live pid is correct and untouched.
sub proc_is_dead {
    my ($pid) = @_;
    my $r = waitpid($pid, WNOHANG);
    return 1 if defined($r) && $r == $pid;   # reaped just now -> definitely dead
    return !kill(0, $pid);                    # not ours to reap (already reaped, or never a child) -> fall back
}
use Time::HiRes qw(time sleep);
use JSON::PP;

my $HOOKS   = "$Bin/../../hooks";
my $SCRIPTS = "$Bin/../../scripts";
my $MARK    = "$HOOKS/mark-wakeup.sh";
my $WATCH   = "$SCRIPTS/bp-watch.pl";

ok(-f $MARK, 'precondition: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $WATCH, 'precondition: bp-watch.pl exists') or BAIL_OUT('script missing');

# ---------------------------------------------------------------------------
# Process bookkeeping.
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

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
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

sub new_running_bp {
    my ($data, $bpname, $pkg) = @_;
    my $bpdir = "$data/blueprints/$bpname";
    make_path("$bpdir/runs");
    write_ledger($bpdir, $pkg, 'status: running');
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
    return $pid;
}

sub spawn_watcher {
    my (@args) = @_;
    my $pid = spawn('perl', $WATCH, @args);
    push @KILL_PIDS, $pid;
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

sub slurp {
    my ($path) = @_;
    return undef unless -f $path;
    local (@ARGV, $/) = ($path);
    return scalar <>;
}

# bg_bash_payload CWD SID CMD -> a run_in_background:true Bash tool_input
# payload, real JSON encoder (never string interpolation).
sub bg_bash_payload {
    my ($cwd, $sid, $cmd) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd, run_in_background => \1 },
    });
}

sub task_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Task',
        tool_input => { subagent_type => 'butler:bp-implementer' },
    });
}

# arm_cmd SUBJECT_PKG DATA MAX -> the shell text a Bash tool call would run
# to arm a bounded watcher on that subject. Matches the real doctrine shape
# (bg_bash_watch_payload in bp-watch-doctrine.t), sans --keepawake.
sub arm_cmd {
    my ($subject_pkg, $data, $max) = @_;
    return "perl plugins/butler/scripts/bp-watch.pl --arm --package $subject_pkg "
         . qq(--max-seconds $max --reason 'test fixture, watcher-reaped-on-wake' --data "$data");
}

# run_mark PAYLOAD, %env -- %env may hold BP_LEDGER and/or BP_PROBE_PROC_DIR,
# both exported into the bash subprocess (and, for BP_PROBE_PROC_DIR,
# inherited by the internal `bp-watch.pl probe` call the hook makes).
sub run_mark {
    my ($payload, %env) = @_;
    my $envstr = 'BP_LEDGER= ';
    $envstr = "BP_LEDGER='$env{BP_LEDGER}' " if defined $env{BP_LEDGER};
    $envstr .= "BP_PROBE_PROC_DIR='$env{BP_PROBE_PROC_DIR}' " if defined $env{BP_PROBE_PROC_DIR};
    my $out = `${envstr}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
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
# AC15 -- arming a watcher through mark-wakeup.sh (a run_in_background Bash
# payload naming bp-watch.pl --arm) creates <DATA>/.watchers/<SID> containing
# one record with the right subject.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $sid = 'sess-ac15';
    my ($rc, $out) = run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/p1', $data, 300)));
    is($rc, 0, 'AC15: mark-wakeup.sh never blocks on an arming Bash call');
    my $regfile = "$data/.watchers/$sid";
    ok(-f $regfile, 'AC15b CANONICAL: arming through mark-wakeup.sh creates '
                   . '<DATA>/.watchers/<SID> containing one record');
    my $content = slurp($regfile) // '';
    like($content, qr/^\d+ package:bpx\/p1\s*$/m,
         'AC15c: the record is "<epoch> package:bpx/p1" -- the right subject');
}

# ===========================================================================
# AC16 -- given that record and a live matching watcher, a second
# mark-wakeup.sh invocation for the SAME session (a Task payload) leaves the
# process gone, and the hook itself still exits 0.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $sid = 'sess-ac16';
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC16 fixture: real matching watcher', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my ($rc1) = run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/p1', $data, 300)));
    is($rc1, 0, 'AC16 precondition: arming succeeded (exit 0)');
    ok(-f "$data/.watchers/$sid", 'AC16 precondition: registry record exists');

    my ($rc2, $out2) = run_mark(task_payload($root, $sid));
    is($rc2, 0, 'AC16: the reaping mark-wakeup.sh invocation itself still exits 0');

    select(undef, undef, undef, 0.5);   # margin beyond the hook's own internal kill/poll sequence
    ok(proc_is_dead($pid), 'AC16 CANONICAL: after a second mark-wakeup.sh invocation for the SAME '
                      . 'session, the previously-armed, subject-matching, live watcher is GONE');
}

# ===========================================================================
# AC17 -- in the same run as AC16, a live bp-keepawake.pl-style lease process
# and its <DATA>/.drive-solo/keepawake.pid are UNTOUCHED.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $sid = 'sess-ac17';

    # Stand-in lease: a real, long-lived process whose cmdline never contains
    # bp-watch.pl/--arm at all, so is_armed_watcher structurally excludes it
    # (behavior 24) -- the probe can never even present it as a candidate.
    my $lease_pid = spawn('perl', '-e', 'sleep 30');
    push @KILL_PIDS, $lease_pid;
    my $ds = "$data/.drive-solo";
    make_path($ds);
    open my $lfh, '>', "$ds/keepawake.pid" or die "write keepawake.pid: $!";
    print {$lfh} "$lease_pid\n";
    close $lfh;

    my $watch_pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC17 fixture: real matching watcher', '--data', $data,
    );
    wait_proc_visible($watch_pid, 5);

    run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/p1', $data, 300)));
    run_mark(task_payload($root, $sid));
    select(undef, undef, undef, 0.5);

    ok(proc_is_dead($watch_pid), 'AC17 precondition: the matching watcher IS reaped (same mechanism '
                            . 'as AC16)');
    ok(kill(0, $lease_pid), 'AC17 CANONICAL: the keepawake-lease-style process is STILL ALIVE -- '
                           . 'reaping never touches it');
    is(slurp("$ds/keepawake.pid"), "$lease_pid\n",
       'AC17b: keepawake.pid\'s content is byte-identical, untouched');
}

# ===========================================================================
# AC18 -- a live watcher armed by a DIFFERENT session survives, three ways.
# ===========================================================================
{
    # (a) invoking session has NO registry file at all -> fast path skips
    #     before the probe ever runs.
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC18a fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $other_sid = 'sess-ac18a-other';   # never armed anything
    ok(!-f "$data/.watchers/$other_sid", 'AC18a precondition: no registry file for this session');
    my ($rc) = run_mark(task_payload($root, $other_sid));
    is($rc, 0, 'AC18a: hook exits 0');
    select(undef, undef, undef, 0.5);
    ok(kill(0, $pid), 'AC18a CANONICAL: a session with NO registry file at all (fast path) never '
                     . 'touches a live watcher it never armed');
}
{
    # (b) invoking session's registry claims a DIFFERENT subject.
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC18b fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $sid = 'sess-ac18b';
    run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/OTHERPKG', $data, 300)));
    ok(-f "$data/.watchers/$sid",
       'AC18b precondition: a registry record was written (claiming a different subject)');
    run_mark(task_payload($root, $sid));
    select(undef, undef, undef, 0.5);
    ok(kill(0, $pid), 'AC18b CANONICAL: a registry record claiming a DIFFERENT subject never '
                     . 'reaps this watcher');
}
{
    # (c) TWO sessions' registries claim the SAME subject -> neither reaps.
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC18c fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $sid1 = 'sess-ac18c-1';
    my $sid2 = 'sess-ac18c-2';
    run_mark(bg_bash_payload($root, $sid1, arm_cmd('bpx/p1', $data, 300)));
    run_mark(bg_bash_payload($root, $sid2, arm_cmd('bpx/p1', $data, 300)));
    ok(-f "$data/.watchers/$sid1", 'AC18c precondition: session 1 registry exists');
    ok(-f "$data/.watchers/$sid2", 'AC18c precondition: session 2 registry exists (same subject)');

    run_mark(task_payload($root, $sid1));
    select(undef, undef, undef, 0.5);
    ok(kill(0, $pid), 'AC18c CANONICAL: two sessions\' registries claiming the SAME subject -- '
                     . 'ambiguous attribution -- means NEITHER reaps it');
}

# ===========================================================================
# AC19 -- with the probe forced to return 2 (BP_PROBE_PROC_DIR pointed at a
# nonexistent path), the hook kills nothing AND leaves
# <DATA>/.watchers/<SID> intact.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'AC19 fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $sid = 'sess-ac19';
    run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/p1', $data, 300)));
    ok(-f "$data/.watchers/$sid", 'AC19 precondition: registry record exists');
    my $before = slurp("$data/.watchers/$sid");

    my ($rc, $out) = run_mark(
        task_payload($root, $sid),
        BP_PROBE_PROC_DIR => "$root/no-such-proc-dir-at-all",
    );
    is($rc, 0, 'AC19: the hook itself still exits 0 when the internal probe call fails');
    select(undef, undef, undef, 0.5);
    ok(kill(0, $pid), 'AC19 CANONICAL (Decision 3 fail-open): with the probe forced to return 2, '
                     . 'the hook kills nothing');
    ok(-f "$data/.watchers/$sid", 'AC19b: ...and leaves <DATA>/.watchers/<SID> intact (not '
                                 . 'consumed on an unreadable answer)');
    is(slurp("$data/.watchers/$sid"), $before,
       'AC19c: the registry file\'s content is byte-identical, not merely still present');
}

# ===========================================================================
# AC20 -- mark-wakeup.sh exits 0 for every reap path exercised above
# (already individually asserted in AC15-19); additionally: still exits 0
# when bp-watch.pl is absent from the expected relative location, and the
# baseline mark-wakeup/doctrine suites pass unchanged.
# ===========================================================================
{
    # AC20a: aggregate re-statement that every reap-path invocation above
    # returned 0 -- already individually asserted (AC15/AC16/AC17-via-AC16
    # mechanism/AC18a-c/AC19); restated once here as the criterion's own
    # cross-cutting claim.
    ok(1, 'AC20a: every reap-path mark-wakeup.sh invocation exercised above (AC15-AC19) exited '
        . '0 -- individually asserted in each of those blocks');
}
{
    # AC20b CANONICAL: bp-watch.pl absent from the expected relative
    # location. A minimal mirror of hooks/ + scripts/ (mark-wakeup.sh,
    # hooks/lib.sh, scripts/bp-lib.sh) WITHOUT scripts/bp-watch.pl, so the
    # hook's own `perl "$HOOK_DIR/../scripts/bp-watch.pl" probe ...` call
    # fails to even find the script.
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $sid = 'sess-ac20-missing-script';

    my $mirror = tempdir(CLEANUP => 1);
    make_path("$mirror/hooks");
    make_path("$mirror/scripts");
    copy("$HOOKS/mark-wakeup.sh", "$mirror/hooks/mark-wakeup.sh")
        or diag("copy mark-wakeup.sh failed: $!");
    copy("$HOOKS/lib.sh", "$mirror/hooks/lib.sh")
        or diag("copy lib.sh failed: $!");
    copy("$SCRIPTS/bp-lib.sh", "$mirror/scripts/bp-lib.sh")
        or diag("copy bp-lib.sh failed: $!");
    chmod 0755, "$mirror/hooks/mark-wakeup.sh";
    # deliberately NOT copying scripts/bp-watch.pl -- the case under test.

    make_path("$data/.watchers");
    open my $rfh, '>', "$data/.watchers/$sid" or die "write registry: $!";
    print {$rfh} time() . " package:bpx/p1\n";
    close $rfh;

    my $payload = task_payload($root, $sid);
    my $out = `bash "$mirror/hooks/mark-wakeup.sh" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC20b CANONICAL: mark-wakeup.sh still exits 0 when bp-watch.pl is absent from '
             . 'the expected relative location (../scripts/bp-watch.pl missing from the mirror)');
}
{
    for my $suite (qw(mark-wakeup-agent-dispatch.t mark-wakeup-quoted-script-path.t
                       bp-watch-doctrine.t)) {
        my $path = "$Bin/$suite";
        my ($rc, $not_ok, $out) = run_suite($path);
        is($rc, 0, "AC20c: $suite exits 0 (pre-existing suite unaffected by the reap addition)")
            or diag(substr($out // '', -2000));
        is($not_ok, 0, "AC20d: $suite reports zero 'not ok' lines")
            or diag(substr($out // '', -2000));
    }
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- BLOCKER-1 (redteam-step6.md). Two sessions
# arming the SAME subject means neither may reap (AC18c) -- but the OLD code
# only held that protection for ONE hook invocation: rc=0's unconditional
# `rm -f` consumed sid1's registry even when the ambiguity filter withheld
# the kill, so sid2's subsequent wake saw claims==1 and reaped a watcher it
# never armed. Reproduces the red-team report's own two-invocation sequence
# and asserts the watcher survives BOTH, not just the first.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'BLOCKER-1 fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $sid1 = 'sess-b1-1';
    my $sid2 = 'sess-b1-2';
    run_mark(bg_bash_payload($root, $sid1, arm_cmd('bpx/p1', $data, 300)));
    run_mark(bg_bash_payload($root, $sid2, arm_cmd('bpx/p1', $data, 300)));
    ok(-f "$data/.watchers/$sid1", 'BLOCKER-1 precondition: session 1 registry exists');
    ok(-f "$data/.watchers/$sid2", 'BLOCKER-1 precondition: session 2 registry exists (same subject)');

    my ($rc1) = run_mark(task_payload($root, $sid1));
    is($rc1, 0, 'BLOCKER-1: session 1\'s wake (the ambiguity-withheld one) still exits 0');
    select(undef, undef, undef, 0.5);
    ok(!proc_is_dead($pid), 'BLOCKER-1a: after session 1\'s wake alone, the watcher is still '
                                  . 'alive (same as AC18c)') or diag('watcher died after FIRST wake');

    my ($rc2) = run_mark(task_payload($root, $sid2));
    is($rc2, 0, 'BLOCKER-1: session 2\'s subsequent wake also still exits 0');
    select(undef, undef, undef, 0.5);
    ok(!proc_is_dead($pid), 'BLOCKER-1 CANONICAL: after a SECOND, later invocation (session '
        . '2\'s own wake), the watcher is STILL alive -- session 1\'s withheld record must not have '
        . 'been consumed, which is exactly what would have handed session 2 unilateral kill '
        . 'authority over a watcher it never armed');
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- MAJOR-1 (redteam-step6.md). A stale registry
# record (from a session that will never wake again) must not permanently
# block reaping for its subject: aged out of the ambiguity count once older
# than the fixed staleness ceiling, so a genuinely-still-active session can
# still reap.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    make_path("$data/.watchers");
    my $stale_epoch = time() - 172800;   # 2 days old, well past any real budget
    open my $sfh, '>', "$data/.watchers/sess-major1-stale" or die "write stale registry: $!";
    print {$sfh} "$stale_epoch package:bpx/p1\n";
    close $sfh;

    my $pid = spawn_watcher(
        '--arm', '--package', 'bpx/p1', '--max-seconds', '300', '--poll', '1',
        '--reason', 'MAJOR-1 fixture', '--data', $data,
    );
    wait_proc_visible($pid, 5);

    my $sid = 'sess-major1-live';
    run_mark(bg_bash_payload($root, $sid, arm_cmd('bpx/p1', $data, 300)));
    ok(-f "$data/.watchers/$sid", 'MAJOR-1 precondition: the live session\'s own registry exists '
                                 . 'alongside the stale one');

    run_mark(task_payload($root, $sid));
    select(undef, undef, undef, 0.5);
    ok(proc_is_dead($pid), 'MAJOR-1 CANONICAL: a stale (2-day-old) foreign registry record for the '
        . 'SAME subject does not permanently block reaping -- the live session\'s own wake still '
        . 'reaps its watcher');
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- MAJOR-2 (redteam-step6.md). Spec §2.5.6:
# the registry is deleted ONLY for probe exit 0 or 1. A probe that fails in
# an unexpected way (here: a compile error, rc=255) must leave the registry
# INTACT, not silently discard reap authority for a live watcher.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'p1');
    make_path("$data/.watchers");
    my $sid = 'sess-major2';
    open my $rfh, '>', "$data/.watchers/$sid" or die "write registry: $!";
    print {$rfh} time() . " package:bpx/p1\n";
    close $rfh;
    my $before = slurp("$data/.watchers/$sid");

    my $mirror = tempdir(CLEANUP => 1);
    make_path("$mirror/hooks");
    make_path("$mirror/scripts");
    copy("$HOOKS/mark-wakeup.sh", "$mirror/hooks/mark-wakeup.sh")
        or diag("copy mark-wakeup.sh failed: $!");
    copy("$HOOKS/lib.sh", "$mirror/hooks/lib.sh")
        or diag("copy lib.sh failed: $!");
    copy("$SCRIPTS/bp-lib.sh", "$mirror/scripts/bp-lib.sh")
        or diag("copy bp-lib.sh failed: $!");
    chmod 0755, "$mirror/hooks/mark-wakeup.sh";
    open my $bfh, '>', "$mirror/scripts/bp-watch.pl" or die "write broken bp-watch.pl: $!";
    print {$bfh} "this is deliberately not valid perl {{{\n";
    close $bfh;

    my $payload = task_payload($root, $sid);
    my $out = `bash "$mirror/hooks/mark-wakeup.sh" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    is($rc, 0, 'MAJOR-2: the hook itself still exits 0 when its internal probe call hits a compile '
             . 'error (rc=255)');
    ok(-f "$data/.watchers/$sid", 'MAJOR-2 CANONICAL: a probe rc OTHER than 0/1/2 (here 255, a '
        . 'compile error) leaves the registry INTACT -- only 0 or 1 may ever consume it');
    is(slurp("$data/.watchers/$sid"), $before,
       'MAJOR-2b: ...and its content is byte-identical, not merely still present');
}

# ===========================================================================
# FIXBATCH-STEP7 REGRESSION -- MAJOR-3 (redteam-step6.md). The recorded
# subject must come from the SEGMENT that actually arms the watcher, not
# first-match-wins over the whole raw command -- a decoy --package mention
# earlier in the same Bash call (a comment here) must not steal the record.
# ===========================================================================
{
    my ($root, $data) = new_project();
    new_running_bp($data, 'bpx', 'real');
    my $sid = 'sess-major3';
    my $decoy_then_real =
        "# arming a watcher on --package decoy/xx first\n"
      . arm_cmd('bpx/real', $data, 300);
    my ($rc, $out) = run_mark(bg_bash_payload($root, $sid, $decoy_then_real));
    is($rc, 0, 'MAJOR-3 precondition: mark-wakeup.sh never blocks on this Bash call');
    my $content = slurp("$data/.watchers/$sid") // '';
    like($content, qr/^\d+ package:bpx\/real\s*$/m,
         'MAJOR-3 CANONICAL: the recorded subject is the REAL arm\'s (bpx/real), not the decoy '
       . 'comment\'s (decoy/xx) -- extraction is anchored to the executing segment, not '
       . 'first-match-wins over the whole raw command');
    unlike($content, qr/decoy/, 'MAJOR-3b: the decoy subject never appears in the registry at all');
}

# Test::Builder inspects the process-global $? at END time to catch a script
# that DIED via a failed system()/exec(); this file legitimately runs many
# backtick subprocesses whose exit codes are non-zero BY DESIGN, leaving $?
# stale and non-zero for no reason related to test outcome. Clear it so the
# script's own exit status reflects only actual test failures.
$? = 0;
done_testing();
