#!/usr/bin/env perl
# platform: windows
# 137 — the w02 FOLD, MIGRATED onto package 02's probe.
#
# ORIGINALLY: gate-drive-loop.sh consulted bp-runstate.pl's effective 'paused'
# state as an ADDITIONAL escape from BLOCK, on top of everything
# t/drive-loop-gate.t already pins. Package 02 (butler-gate-ergonomics)
# replaces that consultation everywhere with the pair (probe verdict, finish
# marker) — D3 in that package's spec removes `bp-runstate.pl status` from
# every one of its three call sites, this fold's included. This file migrates
# 1:1 per 02-gates-use-the-probe-spec.md §4.8's own table: every existing I1-
# I9 assertion is re-pointed to the probe fixture that reproduces its original
# intent, and I5 ("malformed run-state still BLOCKS") is the one AUTHORISED
# RETIREMENT — inverted by Decision 3 ("cannot-tell ALLOWS"), replaced by
# AC3/AC5 below asserting the opposite direction on the same class of input.
#
# THIS FILE STILL DOES NOT TOUCH t/drive-loop-gate.t. Section H there pins
# the hard constraint this fold must survive: an in-flight package + nothing
# scheduled must still BLOCK. That file is read-only ground truth here.
#
# Fixture helpers are a DELIBERATE, LIGHT adaptation of t/94's own
# new_project/project_with_package/run_hook, reproduced here so this file
# stays self-contained.
#
# NON-VACUITY, per migrated behavior:
#   - I1 (H1-shape, probe NONE, no marker) still passes with the CURRENT,
#     unmigrated gate too — it is the "fold is inert against H's own fixture"
#     proof, not a red-before-green assertion on its own.
#   - I2 (probe LIVE) is the assertion that is RED today: the current
#     gate-drive-loop.sh never reads the probe at all, so this fixture BLOCKS
#     exactly like I1 currently. It must turn GREEN once package 02 lands.
#   - I3/I4/I6/I7/I8/I9 (expired watcher, unarmed process, missing --arm,
#     genuinely non-live) largely pass coincidentally against the CURRENT gate
#     too (which blocks everything in-flight regardless of the probe) — they
#     are the guard-rail against a WRONG implementation ("in-flight -> allow
#     unconditionally"), not a currently-red assertion on their own.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives bp-continuity.pl /
# bp-runstate.pl / gate-continuity.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $HOOKS    = "$Bin/../../hooks";
my $GATE     = "$HOOKS/gate-drive-loop.sh";
my $RUNSTATE = "$Bin/../../scripts/bp-runstate.pl";

ok(-f $GATE, 'A0: gate-drive-loop.sh exists (sanity — this file assumes it, per spec §2.1: '
           . 'the fold is additive to an EXISTING file, never a new one)');

our $ACTIVE  = '';
our $SESSION = 'sess-fold-under-test';

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    $ACTIVE = "$root/.active-drivers";
    make_path($ACTIVE);
    if ($opt{order}) {
        open my $fh, '>', "$ds/order.json" or die;
        print {$fh} '{"order":["x"],"recorded_at":1}';
        close $fh;
        open my $m, '>', "$ACTIVE/$SESSION" or die;
        print {$m} "$root/.ccpraxis-local-data\n";
        close $m;
    }
    return ($root, $ds);
}

sub run_hook {
    my ($script, $payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_USAGE_VERDICT_JSON='{\"action\":\"ok\"}' " if $opt{verdict_ok};
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$ACTIVE' " if length $ACTIVE;
    $env .= "BP_PROBE_PROC_DIR='$opt{probe_dir}' "      if defined $opt{probe_dir};
    $env .= "BP_PROBE_SELF_PID='$opt{probe_self_pid}' " if defined $opt{probe_self_pid};
    $env .= "BP_PROBE_CLK_TCK=100 "                      if defined $opt{probe_dir};
    my $out = `$env bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub payload_stop { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd"}) }

# project_with_package — DELIBERATELY BYTE-FOR-BYTE the same shape as t/94's
# own fixture (director answers 'in-flight' for a 'running' package).
sub project_with_package {
    my (%opt) = @_;
    my ($root, $ds) = new_project(order => 1);
    my $bpdir = "$root/.ccpraxis-local-data/blueprints/x";
    make_path("$bpdir/packages");
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print {$b} "# x\n\n| pkg | depends_on |\n|---|---|\n| p1 |  |\n";
    close $b;
    open my $p, '>', "$bpdir/packages/p1.md" or die;
    print {$p} "---\npackage: p1\nstatus: $opt{status}\n---\n\nbody\n";
    close $p;
    return ($root, $ds);
}

# ---------------------------------------------------------------------------
# PACKAGE 02 fixture helpers — the probe (Signal A), duplicated locally per
# spec 02-gates-use-the-probe-spec.md §2.1.
# ---------------------------------------------------------------------------
sub _pw_cmdline {
    my ($procdir, $pid, @argv) = @_;
    make_path("$procdir/$pid");
    open my $fh, '>', "$procdir/$pid/cmdline" or die "write cmdline($pid): $!";
    binmode $fh;
    print {$fh} join("\0", @argv) . "\0";
    close $fh;
}
sub _pw_stat {
    my ($procdir, $pid, $ticks) = @_;
    make_path("$procdir/$pid");
    open my $fh, '>', "$procdir/$pid/stat" or die "write stat($pid): $!";
    print {$fh} "$pid (perl) S 1 " . join(' ', (0) x 17) . " $ticks\n";
    close $fh;
}
sub proc_dir_none { return tempdir(CLEANUP => 1) }
sub proc_dir_cannot_tell {
    my $r = tempdir(CLEANUP => 1);
    my $f = "$r/not-a-directory-file";
    open my $fh, '>', $f or die $!; print {$fh} 'x'; close $fh;
    return $f;
}
sub proc_dir_live {
    my ($data_dir, %opt) = @_;
    my $procdir  = tempdir(CLEANUP => 1);
    my $self_pid = 900001;
    my $pid      = 900002;
    my $ticks    = 1_000_000;
    _pw_stat($procdir, $self_pid, $ticks);
    _pw_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--max-seconds',
                ($opt{max_seconds} // 9999), '--data', $data_dir);
    _pw_stat($procdir, $pid, $ticks);
    return ($procdir, $self_pid);
}
sub proc_dir_expired {
    my ($data_dir) = @_;
    my $procdir  = tempdir(CLEANUP => 1);
    my $self_pid = 900001;
    my $pid      = 900002;
    _pw_stat($procdir, $self_pid, 1_000_300);
    _pw_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--max-seconds', 2, '--data', $data_dir);
    _pw_stat($procdir, $pid, 1_000_000);
    return ($procdir, $self_pid);
}
sub proc_dir_unarmed_worker {                    # a live process, not an armed watcher
    my ($data_dir) = @_;
    my $procdir = tempdir(CLEANUP => 1);
    _pw_cmdline($procdir, 900003, 'perl', 'plugins/butler/scripts/bp-drive-next.pl', 'next');
    return $procdir;
}
sub proc_dir_unarmed_bp_watch {                  # bp-watch.pl present but NO --arm
    my ($data_dir) = @_;
    my $procdir = tempdir(CLEANUP => 1);
    _pw_cmdline($procdir, 900004, 'bp-watch.pl', '--data', $data_dir);
    return $procdir;
}

# ===========================================================================
# I1 (behavior 9, MIGRATED per §4.8: "I1 (in-flight, no run-state -> BLOCK)
# becomes probe 1, no marker -> DENY"). Same fixture as t/94's H1, probe
# forced to NONE, no finish marker.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_none());
    is($rc, 2, 'I1 (migrated, behavior 9): H1-shape fixture, probe NONE, no finish marker, '
             . 'still BLOCKS');
    like($out, qr/BLOCKED \(butler drive-loop\)/,
         'I1b (migrated): the block carries the new (butler drive-loop) header, not the '
       . 'removed director\'s "in-flight" vocabulary');
}

# ===========================================================================
# I2 (behavior 10, MIGRATED per §4.8: "I2 (verified live pause -> ALLOW)
# becomes probe 0 -> ALLOW"). THE ACCEPTANCE CASE — must turn GREEN once
# package 02 lands.
# ===========================================================================
{
    my ($root, $ds) = project_with_package(status => 'running');
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    ok(-d $procdir, 'I2 setup: the fixture\'s synthetic armed-watcher /proc entry is built');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => $procdir, probe_self_pid => $self_pid);
    is($rc, 0, 'I2 CANONICAL (migrated, behavior 10): in-flight + probe LIVE (0) ALLOWS the '
             . 'stop — same director-irrelevant fixture as I1, only the probe differs. This '
             . 'must stop blocking once package 02 lands.');
}

# ===========================================================================
# I8/I9 (MIGRATED per §4.8, both collapse onto the same replacement: "a live
# process that is not an armed bp-watch.pl -> DENY (= AC12)"). The
# fingerprint-forgery attack this pair used to pin no longer has any surface
# to attack: there is no run-state.json record left to forge at all.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_unarmed_worker("$root/.ccpraxis-local-data"));
    is($rc, 2, 'I8/I9 (migrated, = AC12): a live process that is NOT an armed bp-watch.pl '
             . 'watcher still BLOCKS -- liveness alone (a bare pid, forgeable identity) is '
             . 'no longer even a candidate signal; only --arm on the cmdline is');
}

# ===========================================================================
# I3 (behavior 11, MIGRATED per §4.8: "I3 (deadline passed -> BLOCK) becomes
# expired-budget watcher -> DENY (= AC14)").
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($procdir, $self_pid) = proc_dir_expired("$root/.ccpraxis-local-data");
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => $procdir, probe_self_pid => $self_pid);
    is($rc, 2, 'I3 (migrated, behavior 11 / AC14): a watcher whose --max-seconds budget has '
             . 'already elapsed still BLOCKS');
}

# ===========================================================================
# I4 (behavior 12, MIGRATED per §4.8: "I4 (watcher pid not running -> BLOCK)
# becomes exited watcher -> DENY (= AC13)"). An exited watcher is simply
# ABSENT from /proc -- the same fixture as "no watcher at all".
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_none());
    is($rc, 2, 'I4 (migrated, behavior 12 / AC13): a watcher that has already exited (absent '
             . 'from /proc) still BLOCKS -- "a watcher process exists" is not the claim; '
             . '"one is alive right now" is, and it is not');
}

# ===========================================================================
# I5 (edge case, spec §5) — RETIRED (§4.8's own authorised table): "malformed
# run-state.json still BLOCKS" is a DIRECT INVERSION of Decision 3
# ("cannot-tell ALLOWS"). Replaced below by the equivalent malformed-input
# fixtures for the PROBE (a not-a-directory BP_PROBE_PROC_DIR, and a
# malformed BP_PROBE_CLK_TCK) — both ALLOW now, the opposite direction on the
# same class of input.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_cannot_tell());
    is($rc, 0, 'I5 REPLACEMENT (= AC3/AC5, Decision 3 inversion): a probe that CANNOT resolve '
             . '(BP_PROBE_PROC_DIR pointed at a non-directory) now ALLOWS the stop -- the '
             . 'opposite of the retired "malformed input still BLOCKS" claim, by design');
    like($out, qr/(?i:cannot.?tell|indeterminate|fail.?open)/,
         'I5b REPLACEMENT: ...and stderr names the verdict as indeterminate, not silent');
}
{
    # ORACLE EDIT (authorized 2026-09-22, package 02-gates-use-the-probe step
    # 4/5): proc_dir_none() has ZERO candidates, and package 01's self_pid
    # resolution is lazy -- it is only consulted when a real armed candidate
    # needs it for age computation (bp-watch.pl behaviour 20). With no
    # candidates present the probe never touches self_pid at all and
    # legitimately, correctly returns NONE (1), not CANNOT-TELL (2) --
    # verified directly against bp-watch.pl probe with this exact env.
    # Reproducing "self reference cannot resolve" needs an actual candidate
    # for the malformed self_pid to matter, so this fixture now uses
    # proc_dir_live (one armed candidate, scoped to this project's DATA dir)
    # with probe_self_pid overridden to a value that cannot resolve.
    my ($root) = project_with_package(status => 'running');
    my ($procdir) = proc_dir_live("$root/.ccpraxis-local-data");
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                         probe_dir => $procdir, probe_self_pid => 'not-a-pid');
    is($rc, 0, 'I5c REPLACEMENT (= AC5): a probe call whose fixture cannot resolve a self '
             . 'reference also ALLOWS -- any code outside {0,1} is an ALLOW, no exceptions '
             . 'list');
}

# ===========================================================================
# I6 (edge case, spec §5, MIGRATED per §4.8: "I6 (incomplete pause record ->
# BLOCK) becomes bp-watch.pl with no --arm -> DENY"). is_armed_watcher
# requires --arm on the candidate's own cmdline; its absence excludes the
# candidate before any liveness classification even runs.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_unarmed_bp_watch("$root/.ccpraxis-local-data"));
    is($rc, 2, 'I6 (migrated): a bp-watch.pl process present on this project\'s data dir but '
             . 'WITHOUT --arm on its cmdline still BLOCKS -- an incomplete/unarmed candidate '
             . 'is excluded, not counted');
}

# ===========================================================================
# I7 (MIGRATED per §4.8: "I7 (explicitly active -> BLOCK) becomes probe 1 ->
# DENY"). The counter-fixture check: a probe verdict of NONE must not
# accidentally satisfy the ALLOW case either.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_none());
    is($rc, 2, 'I7 (migrated): probe explicitly NONE (1) still BLOCKS');
}

done_testing();
