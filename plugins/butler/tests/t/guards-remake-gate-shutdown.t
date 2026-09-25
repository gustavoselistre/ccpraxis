#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 3 (blueprint
# hook-continuity-remake), GS-1..GS-7 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.5/4.3/4.8: the gate-shutdown
# successor (GateShutdown), running on the package-03 hook core. This one
# module now serves BOTH old registrations (the Task registration and the
# edit-tool registration), per spec sec 3.5's closing line.
#
# hooks/gate-shutdown.sh and BpHook/Guards/GateShutdown.pm DO
# NOT EXIST YET. Every in-process call goes through GuardHarness::run_module()
# (batch 1's harness, plugins/butler/tests/lib/GuardHarness.pm), which
# mirrors BpHook::main()'s own require-and-call contract, so a missing
# module fails open (rc 0) exactly as the real wrapper would -- legibly,
# never a crash in this file. Every [wrapper]/[shim] case spawns the real
# bash file at that path and gets a plain "No such file or directory" until
# the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above and the CASES (not the source bash) of the retired graceful-stop-gate coverage and
# timestamp-authorship.t -- never from reading gate-shutdown.sh itself.
#
# NOT RE-EXPRESSED (per spec sec 4.8 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                     | code
#   --------------------------------------------------------------- | ----
#   the retired graceful-stop-gate coverage, the stop-gate.sh-specific parts            | OTHER (package 06 owns stop-gate.sh;
#                                                                       this successor is gate-shutdown only)
#   the retired graceful-stop-gate coverage, jq-availability skips                      | JQ
#   timestamp-authorship.t AC-03 (source-text grep)                  | SRC
#   timestamp-authorship.t AC-20 source-text grep half                | SRC (the behavioural half is
#                                                                       re-expressed as GS-4's AC-20 line)
#   orchestrate-shutdown-clear.t (bp_clear_stale_shutdown)            | OTHER (a different hook/helper;
#                                                                       this successor writes no file, ever)
#   hooks-selftest.t                                                  | OTHER/REG (registration self-test;
#                                                                       package 16's concern)
#   the retired repeat-guard coverage AC-21 (duplicate stop-signal matrix)                | LIB (the matrix itself is this
#                                                                       file's GS-2/GS-3, not repeated
#                                                                       there; listed here as the sibling
#                                                                       that would otherwise duplicate it)
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Find ();
use File::Spec ();
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front. R9-RM4 (review M4):
# GuardHarness.pm itself now isolates the environment unconditionally at
# "use GuardHarness;" above (deletes BP_*/CCPRAXIS_*/CLAUDE_*, deletes any
# inherited BUTLER_STATE_DIR, pins a decoy HOME/USERPROFILE), so this block
# is redundant, not load-bearing. The PRIOR claim here that "every
# individual block wraps its own env changes in local %ENV = %ENV" was
# false (no such wrap exists anywhere in this file) and is removed.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

# This file's own GS-*/SH-* fixtures never touch session arm state (spec
# sec 3.5: "Env-only ... no session state"), so nothing above needed a real
# HOME. The harness self-check at the bottom DOES arm a session; HOME/
# USERPROFILE are already pinned to a decoy by GuardHarness's own load-time
# isolation, so the explicit call below is a (harmless) re-pin.
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_bytes {
    my ($p, $bytes) = @_;
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

# ---------------------------------------------------------------------------
# mk_bp_dir() -- a fresh $BP_DIR (with a runs/ subdirectory), forward-slashed
# and resolved through Cwd::abs_path so a host whose tempdir() answer is
# itself a mount alias (e.g. this Windows host's "/tmp" -> "/c/Users/...")
# returns the REAL underlying path -- otherwise "$dir/../elsewhere" would
# land back under "/tmp/" and trip GateShutdown's own "/tmp/" allow rule by
# accident, and the C:/ vs /c/ drive-letter case (GS-2) would have nothing
# real to compare against.
# ---------------------------------------------------------------------------
sub mk_bp_dir {
    my $t = tempdir(CLEANUP => 1);
    my $resolved = Cwd::abs_path($t) // $t;
    (my $dir = "$resolved/pkgroot") =~ s{\\}{/}g;
    make_path("$dir/runs");
    return $dir;
}

# ---------------------------------------------------------------------------
# tree_snapshot($dir) -- a stable map of every regular file under $dir to
# its byte content, for GS-6's "no file created or changed" assertion.
# ---------------------------------------------------------------------------
sub tree_snapshot {
    my ($dir) = @_;
    my %snap;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        (my $rel = $_) =~ s{\\}{/}g;
        $snap{$rel} = read_bytes($_);
    } }, $dir);
    return \%snap;
}

# ---------------------------------------------------------------------------
# drive_letter_form($path) -- given a "/x/..." single-letter-mount path
# (this host's Cwd::abs_path answers look like "/c/Users/..."), returns the
# "X:/..." drive-letter spelling of the SAME real directory, for the
# canon() C:/-vs-/c/ equivalence test (GS-2). undef when $path does not
# have that shape at all (a real POSIX host with no drive letters) -- the
# caller skips that half of the case there rather than fabricating one.
# ---------------------------------------------------------------------------
sub drive_letter_form {
    my ($path) = @_;
    return undef unless $path =~ m{^/([A-Za-z])/(.*)$};
    return uc($1) . ':/' . $2;
}

# ---------------------------------------------------------------------------
# payload(%o) -- a tool_input payload for any tool. %o: tool, file_path,
# notebook_path, session_id, cwd.
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $tool = $o{tool} // 'Write';
    my $ti = {};
    $ti->{file_path}     = $o{file_path}     if exists $o{file_path};
    $ti->{notebook_path} = $o{notebook_path}  if exists $o{notebook_path};
    my $p = { tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# gs($payload, %opts) -- GuardHarness::run_module for Guards::GateShutdown.
# %opts always needs env => { BP_DIR => ..., BP_PACKAGE => ... } for a
# signal to be found.
# ---------------------------------------------------------------------------
sub gs {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GateShutdown', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

my $SHUTDOWN_L1 = "STOP-AND-PARK: a fleet-wide graceful shutdown is in progress; set status: parked, last_updated via iso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock), stop.";
my $SHUTDOWN_L2 = "Record the in-flight result and '## Next action' first; new work is denied and the run stays down until relaunched.";
my $PAUSED_L1   = "STOP-AND-PARK: the fleet is paused to preserve the usage reserve; stay non-terminal, last_updated via iso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock).";
my $PAUSED_L2   = "Record the drained result and a concrete '## Next action', then stop; this package auto-resumes after the window resets.";
my $NO_TOOLNAME = "STOP-AND-PARK: a fleet stop is active and this tool call has no identifiable tool_name; denied. Record '## Next action' and stop.";

sub forcestop_l1 { my ($pkg) = @_; return "STOP-AND-PARK: this package is being force-stopped (runs/$pkg.force-stop); new work is denied." }
my $FORCESTOP_L2 = "Record a concrete '## Next action', then stop.";

# ===========================================================================
# SH-1/SH-2 -- static shape.
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/gate-shutdown.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/GateShutdown.pm";
    ok(-f $wrapper, 'SH-1 precondition: gate-shutdown.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on gate-shutdown.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::GateShutdown/,
             'SH-1: the wrapper names the Guards::GateShutdown module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/GateShutdown.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on GateShutdown.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# GS-1 -- no signal: every tool allows.
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    for my $tool (qw(Task Agent Write Edit MultiEdit NotebookEdit Bash Read Grep)) {
        my %po = (tool => $tool, session_id => 'gs1-sid');
        $po{file_path} = "$bpdir/anywhere.md" if $tool =~ /^(?:Write|Edit|MultiEdit)$/;
        $po{notebook_path} = "$bpdir/nb.ipynb" if $tool eq 'NotebookEdit';
        my $res = gs(payload(%po), env => { BP_DIR => $bpdir, BP_PACKAGE => 'pkg1' });
        is($res->{rc}, 0, "GS-1: no signal, tool $tool allows");
    }
}

# ===========================================================================
# GS-2 -- each signal: Task/Agent deny; an edit under BP_DIR (POSIX and
# C:/ vs /c/ forms) and under /tmp/ allows; elsewhere denies; Bash/Read/
# Grep allow.
# ===========================================================================
for my $sig (qw(shutdown forcestop paused)) {
    my $bpdir = mk_bp_dir();
    my $pkg = 'gs2pkg';
    if    ($sig eq 'shutdown')  { write_bytes("$bpdir/runs/.shutdown", '') }
    elsif ($sig eq 'forcestop') { write_bytes("$bpdir/runs/$pkg.force-stop", '') }
    elsif ($sig eq 'paused')    { write_bytes("$bpdir/runs/.paused", '') }
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => $pkg, BP_LEDGER => '/x/ledger.md');

    for my $tool (qw(Task Agent)) {
        my $res = gs(payload(tool => $tool, session_id => "gs2-$sig-$tool"), env => \%env);
        is($res->{rc}, 2, "GS-2 ($sig): $tool denies");
    }

    my $res_under_posix = gs(payload(tool => 'Write', session_id => "gs2-$sig-underposix",
        file_path => "$bpdir/notes.md"), env => \%env);
    is($res_under_posix->{rc}, 0, "GS-2 ($sig): an edit under BP_DIR (POSIX form) allows");

    my $drive_form = drive_letter_form($bpdir);
    if (defined $drive_form) {
        my $res_under_drive = gs(payload(tool => 'Write', session_id => "gs2-$sig-underdrive",
            file_path => "$drive_form/notes.md"), env => \%env);
        is($res_under_drive->{rc}, 0, "GS-2 ($sig): an edit under BP_DIR (the X:/ drive-letter form of the same dir) allows");
    } else {
        pass("GS-2 ($sig): drive-letter form skipped (BP_DIR has no /x/ mount-style prefix on this host) -- still counted");
    }

    my $res_tmp = gs(payload(tool => 'Write', session_id => "gs2-$sig-tmp",
        file_path => '/tmp/somefile.md'), env => \%env);
    is($res_tmp->{rc}, 0, "GS-2 ($sig): an edit under /tmp/ allows");

    my $res_elsewhere = gs(payload(tool => 'Write', session_id => "gs2-$sig-elsewhere",
        file_path => "$bpdir/../elsewhere/notes.md"), env => \%env);
    is($res_elsewhere->{rc}, 2, "GS-2 ($sig): an edit elsewhere denies");

    for my $tool (qw(Bash Read Grep)) {
        my $res = gs(payload(tool => $tool, session_id => "gs2-$sig-$tool"), env => \%env);
        is($res->{rc}, 0, "GS-2 ($sig): $tool allows");
    }
}

# ===========================================================================
# GS-3 -- precedence: shutdown+paused+forcestop -> shutdown; forcestop+
# paused -> forcestop; paused alone -> paused (contains "auto-resumes").
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    my $pkg = 'gs3pkg';
    write_bytes("$bpdir/runs/.shutdown", '');
    write_bytes("$bpdir/runs/.paused", '');
    write_bytes("$bpdir/runs/$pkg.force-stop", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => $pkg, BP_LEDGER => '/x/ledger.md');

    my $res_all = gs(payload(tool => 'Task', session_id => 'gs3-all'), env => \%env);
    is($res_all->{rc}, 2, 'GS-3: all three present -> deny');
    is($res_all->{err}, "$SHUTDOWN_L1\n$SHUTDOWN_L2\n", 'GS-3: all three present -> the shutdown text wins');

    unlink("$bpdir/runs/.shutdown");
    my $res_fs_paused = gs(payload(tool => 'Task', session_id => 'gs3-fs-paused'), env => \%env);
    is($res_fs_paused->{rc}, 2, 'GS-3: forcestop+paused -> deny');
    is($res_fs_paused->{err}, forcestop_l1($pkg) . "\n$FORCESTOP_L2\n", 'GS-3: forcestop+paused -> the forcestop text wins');

    unlink("$bpdir/runs/$pkg.force-stop");
    my $res_paused = gs(payload(tool => 'Task', session_id => 'gs3-paused'), env => \%env);
    is($res_paused->{rc}, 2, 'GS-3: paused alone -> deny');
    is($res_paused->{err}, "$PAUSED_L1\n$PAUSED_L2\n", 'GS-3: paused alone -> the exact paused text');
    like($res_paused->{err}, qr/auto-resumes/, 'GS-3: paused alone -> contains "auto-resumes"');
}

# ===========================================================================
# GS-4 -- every message line equals 3.5 exactly; the S4/S5 iso_now/"no
# clock" anchor holds on the shutdown and paused lines.
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    my $pkg = 'gs4pkg';
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => $pkg, BP_LEDGER => '/x/ledger.md');
    my $res_shutdown = gs(payload(tool => 'Task', session_id => 'gs4-shutdown'), env => \%env);
    is($res_shutdown->{err}, "$SHUTDOWN_L1\n$SHUTDOWN_L2\n", 'GS-4: shutdown text matches 3.5 exactly');
    like($res_shutdown->{err}, qr/\Qiso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock)\E/,
         'GS-4/S4: the shutdown line carries the iso_now/date -u/"no clock" anchor');

    unlink("$bpdir/runs/.shutdown");
    write_bytes("$bpdir/runs/.paused", '');
    my $res_paused = gs(payload(tool => 'Task', session_id => 'gs4-paused'), env => \%env);
    is($res_paused->{err}, "$PAUSED_L1\n$PAUSED_L2\n", 'GS-4: paused text matches 3.5 exactly');
    like($res_paused->{err}, qr/\Qiso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock)\E/,
         'GS-4/S5: the paused line carries the same anchor');

    unlink("$bpdir/runs/.paused");
    write_bytes("$bpdir/runs/$pkg.force-stop", '');
    my $res_fs = gs(payload(tool => 'Task', session_id => 'gs4-forcestop'), env => \%env);
    is($res_fs->{err}, forcestop_l1($pkg) . "\n$FORCESTOP_L2\n", 'GS-4: forcestop text matches 3.5 exactly, <pkg> substituted');

    # No BP_PACKAGE at all: the stopfile atom looks for runs/pkg.force-stop.
    unlink("$bpdir/runs/$pkg.force-stop");
    write_bytes("$bpdir/runs/pkg.force-stop", '');
    my $res_fs_default = gs(payload(tool => 'Task', session_id => 'gs4-forcestop-default'),
        env => { BP_DIR => $bpdir, BP_LEDGER => '/x/ledger.md' });
    is($res_fs_default->{err}, forcestop_l1('pkg') . "\n$FORCESTOP_L2\n",
       'GS-4: with BP_PACKAGE unset, <pkg> defaults to the literal "pkg"');
}

# ===========================================================================
# GS-5 -- fail closed under a signal: {}/bad JSON/truncated payload and a
# missing tool_name deny with the single no-tool_name line; an edit with no
# path denies.
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    my $pkg = 'gs5pkg';
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => $pkg, BP_LEDGER => '/x/ledger.md');

    for my $c (
        ['{}'                             => 'empty object'],
        ['not json at all'                => 'malformed JSON'],
        ['{"tool_name":"Write","tool_i'   => 'truncated JSON'],
    ) {
        my ($raw, $label) = @$c;
        my %e = %env;
        $e{BP_PAYLOAD_TRUNCATED} = 1 if $label eq 'truncated JSON';
        my $res = gs($raw, env => \%e);
        is($res->{rc}, 2, "GS-5: $label under a signal -> deny (fail closed)");
        is($res->{err}, "$NO_TOOLNAME\n", "GS-5: $label -> the single no-tool_name line");
    }

    my $res_missing_toolname = gs({ tool_input => { file_path => "$bpdir/x.md" }, session_id => 'gs5-notoolname' }, env => \%env);
    is($res_missing_toolname->{rc}, 2, 'GS-5: a hash payload with no tool_name key -> deny');
    is($res_missing_toolname->{err}, "$NO_TOOLNAME\n", 'GS-5: -> the single no-tool_name line');

    my $res_nopath = gs(payload(tool => 'Write', session_id => 'gs5-nopath'), env => \%env);
    is($res_nopath->{rc}, 2, 'GS-5: an edit tool with no file_path/notebook_path at all denies');
}

# ===========================================================================
# GS-6 -- no file is created or changed under BP_DIR on any path.
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    my $pkg = 'gs6pkg';
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => $pkg, BP_LEDGER => '/x/ledger.md');
    my $before = tree_snapshot($bpdir);

    gs(payload(tool => 'Task', session_id => 'gs6-a'), env => \%env);
    gs(payload(tool => 'Write', session_id => 'gs6-b', file_path => "$bpdir/notes.md"), env => \%env);
    gs(payload(tool => 'Write', session_id => 'gs6-c', file_path => '/tmp/elsewhere.md'), env => \%env);
    gs(payload(tool => 'Bash', session_id => 'gs6-d'), env => \%env);
    gs('{}', env => \%env);

    my $after = tree_snapshot($bpdir);
    is_deeply($after, $before, 'GS-6: BP_DIR\'s file tree is byte-identical after every call above');
}

# ===========================================================================
# GS-7 -- the remaining shared ACs.
# ===========================================================================

# SH-5 -- run() leaves BpHook::parse_count() unchanged, deny and allow.
{
    my $bpdir = mk_bp_dir();
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => 'sh5pkg', BP_LEDGER => '/x/ledger.md');
    my $res_deny = gs(payload(tool => 'Task', session_id => 'sh5-deny'), env => \%env);
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
    my $res_allow = gs(payload(tool => 'Bash', session_id => 'sh5-allow'), env => \%env);
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- budget (2 lines) and forbidden vocabulary on every deny collected.
{
    my $bpdir = mk_bp_dir();
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => 'sh6pkg', BP_LEDGER => '/x/ledger.md');
    my @denies = (
        gs(payload(tool => 'Task', session_id => 'sh6-a'), env => \%env),
        gs(payload(tool => 'Agent', session_id => 'sh6-b'), env => \%env),
        gs(payload(tool => 'Write', session_id => 'sh6-c', file_path => "$bpdir/../out.md"), env => \%env),
    );
    is(scalar(@denies), 3, 'SH-6 setup: three deny fixtures collected');
    for my $i (0 .. $#denies) {
        my $res = $denies[$i];
        is($res->{rc}, 2, "SH-6: fixture $i is really a deny") or next;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, "SH-6: fixture $i has at most the gate-shutdown budget of 2 lines");
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, "SH-6: fixture $i line length <= 160");
            unlike($l, qr/\.run-finished|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   "SH-6: fixture $i line names no retired mechanism");
            unlike($l, qr/BP_[A-Z_]*_ACTION|threshold/i,
                   "SH-6: fixture $i line names no disable-a-guard hatch");
        }
        is($res->{out}, '', "SH-6: fixture $i stdout is empty");
    }
}

# SH-7 -- the general "bad JSON -> exit 0" contract does NOT apply to
# GateShutdown when a signal is active (GS-5 above covers that fail-closed
# exception); here we confirm the ordinary baseline WITHOUT a signal.
{
    my $bpdir = mk_bp_dir();
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => 'sh7pkg');
    for my $c (
        ['not json at all'                          => 'malformed JSON'],
        ['{"tool_name":"Task"'                       => 'truncated JSON'],
        ['{}'                                        => 'empty object'],
    ) {
        my ($raw, $label) = @$c;
        my %e = %env;
        $e{BP_PAYLOAD_TRUNCATED} = 1 if $label eq 'truncated JSON';
        my $res = gs($raw, env => \%e);
        is($res->{rc}, 0, "SH-7 (no signal): $label -> exit 0");
        is($res->{out}, '', "SH-7 (no signal): $label -> empty stdout");
        is($res->{err}, '', "SH-7 (no signal): $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# [wrapper]/[shim] cases: SH-3 (not-applies: no signal file) and SH-4
# (applies: Task under .shutdown). Both registrations (edit tools and
# Task) are exercised via run_module above; here we only need one wrapper
# round trip of each population to pin the process budget end to end.
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    my $res_not_applies = GuardHarness::run_shim('gate-shutdown.sh',
        { tool_name => 'Task', tool_input => {}, session_id => 'gs-shim-nosignal' },
        env => { BP_DIR => $bpdir, BP_PACKAGE => 'gsshim' });
    is($res_not_applies->{rc}, 0, 'SH-3: no signal file -> exit 0');
    is($res_not_applies->{out}, '', 'SH-3: empty stdout');
    is($res_not_applies->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the wrapper exits in bash before ever reaching perl)');

    write_bytes("$bpdir/runs/.shutdown", '');
    my $res_applies = GuardHarness::run_shim('gate-shutdown.sh',
        { tool_name => 'Task', tool_input => {}, session_id => 'gs-shim-shutdown' },
        env => { BP_DIR => $bpdir, BP_PACKAGE => 'gsshim', BP_LEDGER => '/x/ledger.md' });
    is($res_applies->{rc}, 2, 'SH-4: Task under an active .shutdown signal (coordinator session) reaches perl and denies');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1,
       'SH-4: exactly 1 perl launch');
}

# ---------------------------------------------------------------------------
# GS-8 -- the gate fires ONLY in coordinator sessions: BP_LEDGER is the
# coordinator signal (spec sec 3.5/hook-architecture.md:1095). A stop file
# present but BP_LEDGER unset allows without ever reaching perl; BP_LEDGER
# set with no stop file present also allows without ever reaching perl.
# ---------------------------------------------------------------------------
{
    my $bpdir = mk_bp_dir();
    write_bytes("$bpdir/runs/.shutdown", '');
    my $res_no_ledger = GuardHarness::run_shim('gate-shutdown.sh',
        { tool_name => 'Task', tool_input => {}, session_id => 'gs8-shim-noledger' },
        env => { BP_DIR => $bpdir, BP_PACKAGE => 'gs8shim' });
    is($res_no_ledger->{rc}, 0, 'GS-8: a stop file present but BP_LEDGER unset -> allow (not a coordinator session)');
    is($res_no_ledger->{out}, '', 'GS-8: no-ledger case -> empty stdout');
    is($res_no_ledger->{err}, '', 'GS-8: no-ledger case -> empty stderr');
    is(GuardHarness::count_lines($res_no_ledger->{shim_log}, 'perl'), 0,
       'GS-8: 0 perl launches (the wrapper exits in bash before ever reaching perl)');
}
{
    my $bpdir = mk_bp_dir();
    my $res_ledger_no_signal = GuardHarness::run_shim('gate-shutdown.sh',
        { tool_name => 'Task', tool_input => {}, session_id => 'gs8-shim-ledger-nosignal' },
        env => { BP_DIR => $bpdir, BP_PACKAGE => 'gs8shim2', BP_LEDGER => '/x/ledger.md' });
    is($res_ledger_no_signal->{rc}, 0, 'GS-8: BP_LEDGER set (coordinator) but no stop file present -> allow');
    is($res_ledger_no_signal->{out}, '', 'GS-8: ledger-no-signal case -> empty stdout');
    is($res_ledger_no_signal->{err}, '', 'GS-8: ledger-no-signal case -> empty stderr');
    is(GuardHarness::count_lines($res_ledger_no_signal->{shim_log}, 'perl'), 0,
       'GS-8: 0 perl launches (the wrapper exits in bash before ever reaching perl)');
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a real
# EXISTING successor (stop-gate.sh, package 06), not GateShutdown. Proves a
# red result above is gate-shutdown's absence, not a harness defect. Repeats
# batch 1's own self-check independently, since this file must stand on its
# own when the runner parallelises files.
# ===========================================================================
{
    GuardHarness::fresh_state();  # a fixed BUTLER_STATE_DIR for arm() and run_shim/run_module below to agree on
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_wrapper = GuardHarness::run_wrapper($stopgate,
        { session_id => 'gsselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_wrapper->{rc}, 0, 'self-check: run_wrapper against the real stop-gate.sh (unarmed) allows');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'gsselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('gsselfcheck-3', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'gsselfcheck-3', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1,
       'self-check: ...with exactly 1 perl launch');

    ok(GuardHarness::arm('gsselfcheck-run-module-armed', 'manual'),
       'self-check/run_module setup: a distinct session armed');
    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'gsselfcheck-run-module-armed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its '
     . 'run(), rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'gsselfcheck-run-module-unarmed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and '
     . 'never-armed session -> allows');
}

# ===========================================================================
# R9-Rm1 (review m1): the module has no BP_LEDGER test at all -- it denies
# Task/Agent/edits for ANY caller whose BP_DIR holds a signal file, even
# when BP_LEDGER is unset (called directly, in-process, never through the
# wrapper's own --pre coordinator prefilter clause).
# ===========================================================================
{
    my $bpdir = mk_bp_dir();
    write_bytes("$bpdir/runs/.shutdown", '');
    my %env = (BP_DIR => $bpdir, BP_PACKAGE => 'r9pkg'); # BP_LEDGER deliberately unset
    is(gs(payload(tool => 'Task', session_id => 'r9-rm1-task'), env => \%env)->{rc}, 0,
       'R9-Rm1: module called directly with BP_LEDGER unset -> allows Task despite an active .shutdown signal');
    is(gs(payload(tool => 'Write', file_path => "$bpdir/../outside.md", session_id => 'r9-rm1-write'), env => \%env)->{rc}, 0,
       'R9-Rm1: module called directly with BP_LEDGER unset -> allows an edit outside BP_DIR too');
    # control: with BP_LEDGER set, the same fixture still denies (GS-2 territory).
    my %env_coord = (%env, BP_LEDGER => '/x/ledger.md');
    is(gs(payload(tool => 'Task', session_id => 'r9-rm1-coord'), env => \%env_coord)->{rc}, 2,
       'R9-Rm1 control: with BP_LEDGER set, the same signal still denies Task');
}

$? = 0;
done_testing();
