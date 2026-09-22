#!/usr/bin/env perl
# platform: windows
# 94 — the drive-solo driver's stop discipline.
#
# WHAT IS BEING PROTECTED
#
# /butler:drive-solo casts the driver as "a thin loop over the director": call
# bp-drive-next.pl next, dispatch the action, call next again. That is prose,
# and prose decays over a long context. Observed three times in a single 12-hour
# run on 2026-08-07: a driver turn ended immediately after a ledger write, its
# text promising the next step, with nothing scheduled to perform it. A
# dispatched agent notifies; a finished FOREGROUND Bash call does not. So the
# run died silently, mid-package, LOOKING finished — the worst property an
# unattended run can have, because the operator only discovers it by asking.
#
# gate-stop.sh already makes this argument one level down, for coordinators:
# it "converts ledger discipline from a prompt rule (which decays over long
# contexts) into a mechanical gate". But every butler hook opens with
# bp_hook_gate, which requires BP_LEDGER — exported only into coordinator
# processes. The DRIVER, the one participant nothing supervises, therefore had
# no stop discipline at all.
#
# THE RULE, in one line:
#   A driver turn may end EITHER because something will wake the session,
#   OR because the director says the run is settled. Never otherwise.
#
# The two hooks under test implement it as a pair: mark-wakeup.sh (PreToolUse)
# records that this turn scheduled a wake-up; gate-drive-loop.sh (Stop) consumes
# that marker, and blocks the stop when there is none and the director still
# has work.
#
# POSTURE UNDER TEST. A stop gate that misfires traps a human's session, which
# is strictly worse than the bug it prevents. So the safety properties below
# (bounded blocking, both escape hatches, fail-open, correct scoping) matter at
# least as much as the blocking behaviour itself, and each is asserted.
#
# Runs standalone: perl this file
# (`prove` does not exist on the Git-for-Windows host.) No container, no
# network, no launcher spawn; every fixture lives under File::Temp.

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

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";

# ---------------------------------------------------------------------------
# A. The hooks exist and are registered. An unregistered hook is inert, and an
#    inert gate is indistinguishable from no gate at all.
# ---------------------------------------------------------------------------
ok(-f $MARK, 'A1: mark-wakeup.sh exists');
ok(-f $GATE, 'A2: gate-drive-loop.sh exists');

my $hooks_json = do { local (@ARGV, $/) = ("$HOOKS/hooks.json"); <> };
ok(defined $hooks_json && length $hooks_json, 'A3: hooks.json is readable');
like($hooks_json, qr/gate-drive-loop\.sh/,
     'A4: gate-drive-loop.sh is REGISTERED in hooks.json (an unregistered gate is inert)');
like($hooks_json, qr/mark-wakeup\.sh/,
     'A5: mark-wakeup.sh is REGISTERED in hooks.json');

# The Stop array must carry the gate, not merely the file mention it somewhere.
my ($stop_block) = $hooks_json =~ /"Stop"\s*:\s*(\[.*?\])\s*\}\s*\}\s*$/s;
$stop_block = '' unless defined $stop_block;
like($stop_block, qr/gate-drive-loop\.sh/,
     'A6: the gate is registered specifically under the Stop event');

# ---------------------------------------------------------------------------
# Helpers. Each case gets its own project root so no test can see another's
# state — the .drive-solo dir IS the hooks' activation signal.
# ---------------------------------------------------------------------------
# The ACTIVE-DRIVER REGISTRY for the project under test. The gate is scoped by
# SESSION now, not by directory: it asks "is this session driving", answered by
# a marker that mark-wakeup.sh writes when a session calls the director.
#
# RE-POINTED, NOT WEAKENED. These fixtures used to arm the gate merely by
# creating .drive-solo/order.json, which is exactly the defect that scoping
# change fixed — that test was true for every session in the tree, including
# ones that had never driven anything, and it never became false when a run
# finished. Every claim below is unchanged; only the way a fixture declares
# "this session is the driver" has moved.
our $ACTIVE  = '';
our $SESSION = 'sess-under-test';

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    $ACTIVE = "$root/.active-drivers";
    make_path($ACTIVE);
    # order.json is what marks a run as "in progress"; omit it to model a
    # project where drive-solo has never run.
    if ($opt{order}) {
        open my $fh, '>', "$ds/order.json" or die;
        print {$fh} '{"order":["x"],"recorded_at":1}';
        close $fh;
        # ... and arm THIS session as the driver, unless the case is
        # specifically about an unarmed one.
        unless ($opt{unarmed}) {
            open my $m, '>', "$ACTIVE/$SESSION" or die;
            print {$m} "$root/.ccpraxis-local-data\n";
            close $m;
        }
    }
    return ($root, $ds);
}

sub run_hook {
    my ($script, $payload, %opt) = @_;
    my $env = '';
    $env = "CCPRAXIS_DRIVE_STOP_OK=1 " if $opt{stop_ok_env};
    # Pin the usage verdict for any case that depends on the director's answer.
    # Without it the director shells out to bp-usage-gate.pl and reads the
    # HOST's real OAuth state, so these assertions would track a token clock:
    # once the token ages under the relogin floor the director answers
    # pause/token, the gate correctly allows the stop, and a green test turns
    # red with no code change. Observed exactly that on 2026-08-08.
    $env .= "CCPRAXIS_USAGE_VERDICT_JSON='{\"action\":\"ok\"}' " if $opt{verdict_ok};
    # Point the hooks at THIS case's driver registry, so no case can see
    # another's arming and nothing touches the real one under $HOME.
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$ACTIVE' " if length $ACTIVE;
    # PACKAGE 02 — force the probe (Signal A) deterministically.
    $env .= "BP_PROBE_PROC_DIR='$opt{probe_dir}' "       if defined $opt{probe_dir};
    $env .= "BP_PROBE_SELF_PID='$opt{probe_self_pid}' "  if defined $opt{probe_self_pid};
    $env .= "BP_PROBE_CLK_TCK=100 "                       if defined $opt{probe_dir};
    # Single-quote the payload for sh; payloads here contain no single quotes.
    my $out = `$env bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# ---------------------------------------------------------------------------
# PACKAGE 02 fixture helpers — the probe (Signal A), duplicated locally per
# spec 02-gates-use-the-probe-spec.md §2.1 (each hook's own local copy).
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
sub proc_dir_unarmed_worker {
    my ($data_dir) = @_;
    my $procdir = tempdir(CLEANUP => 1);
    _pw_cmdline($procdir, 900003, 'perl', 'plugins/butler/scripts/bp-drive-next.pl', 'next');
    return $procdir;
}
sub touch_finish_marker { my ($ds) = @_; open my $fh, '>', "$ds/.run-finished" or die $!; close $fh; return "$ds/.run-finished" }
sub finish_consumed_path { my ($ds) = @_; return "$ds/.run-finished.consumed" }

sub payload_task { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Task","tool_input":{}}) }
sub payload_bash {
    my ($cwd, $bg) = @_;
    return $bg
        ? qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"ls","run_in_background":true}})
        : qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"ls"}});
}
sub payload_stop { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd"}) }

# ---------------------------------------------------------------------------
# B. mark-wakeup.sh records exactly the things that schedule a wake-up.
# ---------------------------------------------------------------------------
{
    my ($root, $ds) = new_project(order => 1);

    my ($rc) = run_hook($MARK, payload_task($root));
    is($rc, 0, 'B1: mark-wakeup never blocks (Task)');
    ok(-f "$ds/.wakeup-pending", 'B2: a Task dispatch records a pending wake-up');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, payload_bash($root, 1));
    ok(-f "$ds/.wakeup-pending",
       'B3: a BACKGROUNDED Bash call records a pending wake-up (its exit notifies)');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, payload_bash($root, 0));
    ok(!-f "$ds/.wakeup-pending",
       'B4: a FOREGROUND Bash call records NOTHING — it returns into the same turn '
     . 'and schedules no wake-up. (Regression guard: bp_json_get returns EMPTY for '
     . 'JSON booleans, so reading run_in_background through it silently classified '
     . 'every backgrounded call as foreground.)');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, qq({"cwd":"$root","tool_name":"Read","tool_input":{}}));
    ok(!-f "$ds/.wakeup-pending", 'B5: an unrelated tool records nothing');
}

# ---------------------------------------------------------------------------
# C. Scoping. The gate must be invisible to everyone it does not govern.
# ---------------------------------------------------------------------------
{
    my ($root) = new_project(order => 1);

    my ($rc) = run_hook($GATE, payload_stop($root), stop_ok_env => 1);
    is($rc, 0, 'C1: CCPRAXIS_DRIVE_STOP_OK=1 always allows the stop (session-wide hatch)');

    # A coordinator carries BP_LEDGER; gate-stop.sh owns that session.
    my $out = `BP_LEDGER=/tmp/nonexistent bash "$GATE" <<'EOF' 2>&1
{"cwd":"$root"}
EOF`;
    is($? >> 8, 0, 'C2: a COORDINATOR session (BP_LEDGER set) is untouched — gate-stop.sh owns it');

    # ORACLE EDIT (authorized 2026-09-22, package 02-gates-use-the-probe step
    # 4/5): $ACTIVE/$SESSION are package globals set by the enclosing block's
    # new_project(order=>1) above and never reset, so this fixture is NOT
    # actually "no .ccpraxis-local-data at all" -- run_hook's
    # CCPRAXIS_DRIVE_ACTIVE_DIR still points at that block's registry, which
    # still has sess-under-test armed against that block's REAL, order.json'd
    # data dir (verified directly: /tmp is only the payload cwd, not what the
    # marker resolves to). Under the OLD code this passed because the director
    # answered `done` for a data dir with no blueprints and D1 (now removed by
    # Decision 23) let that end the run for free -- the exact same root cause
    # as H3's already-authorised retirement below, just reached via a
    # different fixture shape than H3's. Migrated the same way: the fixture
    # is unchanged (it still proves the marker/probe resolution ignores the
    # payload's cwd), the assertion now reflects Decision 23's actual answer.
    my ($rc3) = run_hook($GATE, payload_stop("/tmp"));
    is($rc3, 2, 'C3: a driver session with no watcher and no finish signal is DENIED, '
              . 'regardless of the payload cwd -- Decision 23 removed the director-done '
              . 'free pass this fixture used to exercise');

    my ($noorder) = new_project(order => 0);
    my ($rc4) = run_hook($GATE, payload_stop($noorder));
    is($rc4, 0, 'C4: a project with .drive-solo but NO order.json is untouched '
              . '(no run has been started, so there is no loop to protect)');
}

# ---------------------------------------------------------------------------
# D. The marker is CONSUMED, not merely read. This is what makes the rule
#    per-turn: one scheduled wake-up buys exactly one turn end.
# ---------------------------------------------------------------------------
{
    my ($root, $ds) = new_project(order => 1);
    run_hook($MARK, payload_task($root));
    ok(-f "$ds/.wakeup-pending", 'D1: marker present before the stop');

    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 0, 'D2: a stop with a pending wake-up is ALLOWED');
    ok(!-f "$ds/.wakeup-pending",
       'D3: the marker is CONSUMED — a second turn cannot reuse the first turn\'s '
     . 'dispatch to justify ending with nothing scheduled');
}

# ---------------------------------------------------------------------------
# E. Fail-open. Every path that cannot reach a verdict must ALLOW the stop.
#    A gate that cannot consult its oracle must never trap the session.
# ---------------------------------------------------------------------------
{
    # RETIRED (§4.8): E1 ("when the director cannot return an actionable
    # verdict, the stop is allowed") pinned the director's own fail-open —
    # the director is no longer consulted at all (D1), so its absence is no
    # longer a fail-open case. Replaced by AC5 below: the PROBE's failure to
    # resolve is the new fail-open case.
    #
    # order.json present, but the project has no blueprints dir at all. Under
    # the new gate this fixture does not touch the director at all, so it now
    # exercises the ordinary probe path (real host /proc, no watcher armed).
    my ($root) = new_project(order => 1);
    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 2, 'E1 (migrated): with no blueprints dir at all and no probe stub, the real '
             . 'probe finds no live watcher and no marker -- DENIED. The old director-'
             . 'absence fail-open no longer applies: the director is never consulted.');
}

# AC5 — the probe's own failure to resolve to {0,1} is the fail-open case now.
{
    my ($root) = new_project(order => 1);
    local $ENV{BP_PROBE_PROC_DIR} = proc_dir_cannot_tell();
    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 0, 'AC5 (driver): a probe verdict outside {0,1} ALLOWS -- this is the fail-open '
             . 'case now, not a director failure');
}

# ---------------------------------------------------------------------------
# F. The escape hatch is one-shot, so it cannot silently disable the gate.
# ---------------------------------------------------------------------------
{
    # ORACLE EDIT (authorized 2026-09-22, package 02-gates-use-the-probe step
    # 4/5): an untouched fixture with no probe stub hits the real host probe,
    # which finds no watcher for this throwaway project -- verdict 1 (none),
    # no finish marker -- and that is now literally "a sibling would block"
    # (the exact predicate F3/F4 below test explicitly), so an unconditional
    # consume no longer holds here. This block's own stated intent ("an
    # operator override applies to one stop, never permanently") is about
    # plain one-shot consumption when nothing is carrying it, which needs a
    # fixture where no sibling would block -- forced here via probe_dir =>
    # proc_dir_live, so this block stays a distinct case from F3-F8's carry
    # test rather than duplicating it under a stale assertion.
    my ($root, $ds) = new_project(order => 1);
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    open my $fh, '>', "$ds/.stop-ok" or die; close $fh;
    my ($rc) = run_hook($GATE, payload_stop($root), probe_dir => $procdir,
                         probe_self_pid => $self_pid);
    is($rc, 0, 'F1: .stop-ok allows the stop');
    ok(!-f "$ds/.stop-ok",
       'F2: .stop-ok is CONSUMED — with a live watcher (no sibling would block), an '
     . 'operator override applies to one stop, never permanently, so the gate cannot '
     . 'be switched off by accident');
}

# ---------------------------------------------------------------------------
# F'. ...but "one shot" means one STOP, not one Stop-hook INVOCATION.
#
# This hook is not the only Stop gate. guard-subagent-stall.sh blocks whenever
# bp-runstate.pl reports "state":"active", independently of this one. Exiting 0
# here therefore does NOT mean the turn ended.
#
# Observed 2026-08-24: the operator touched .stop-ok, this gate consumed it and
# passed, the sibling guard blocked the same stop, and the very next stop
# blocked HERE demanding a marker that had already been spent. The loop that
# produced is closed — consult the director, get reactivated, re-finish, lose
# the token, block again — and an operator following the gate's own printed
# instructions cannot get out of it.
#
# So: while the run is active, pass WITHOUT consuming. Spend the token on the
# stop it actually lets through.
# ---------------------------------------------------------------------------
# ORACLE EDIT (authorized 2026-09-22, package 02-gates-use-the-probe step
# 4/5): this whole section used bp-runstate.pl activate/finish to simulate
# "a sibling gate is about to block". D3 removes the gate's ONLY connection
# to bp-runstate.pl, so that fixture technique is now fully disconnected
# from what the carry predicate actually reads -- it would pass or fail by
# accident, never by exercising the real logic. Migrated onto the same
# (probe verdict, finish marker) pair the gate itself now reads (spec §2.1),
# using $DATA (the resolved data dir under $root/.ccpraxis-local-data,
# established by new_project/run_hook elsewhere in this file) as the probe's
# scope. "Sibling would block" is now genuinely reproduced (probe forced to
# 1/none, no marker), and "sibling resolved" is the operator's own marker —
# not a second, unrelated bp-runstate.pl call.
#
# ORACLE EDIT (fix-batch 1, red-team MAJOR-4): the carry predicate used to
# be "probe != 0" alone, which read verdict 2 (cannot-tell, an ALLOW) as "a
# sibling would block", and ignored whether the sibling (guard-subagent-
# stall.sh) had ANY pending dispatch to block on at all -- an EMPTY/ABSENT
# pending set is that hook's own INERT condition (it exits 0
# unconditionally), so "probe says none" alone never actually implied the
# sibling would block. This fixture never wrote anything to the sibling's
# own pending-set file, so with the corrected predicate the carry no longer
# fires here -- which is CORRECT (see the new "sibling inert" regression
# test below) but means F3/F4/F7/F8 must now make "the sibling would
# genuinely block" TRUE, by populating guard-subagent-stall.sh's own
# pending-set file directly (same path convention that hook uses:
# <data>/.subagent-guard/<session>), rather than merely forcing the probe.
sub sibling_pending {
    my ($root, $desc) = @_;
    my $dir = "$root/.ccpraxis-local-data/.subagent-guard";
    make_path($dir);
    open my $fh, '>>', "$dir/$SESSION" or die $!;
    print {$fh} ($desc // 'a worker') . "\n";
    close $fh;
}
SKIP: {
    my ($root, $ds) = new_project(order => 1);
    sibling_pending($root, 'F-section worker');

    open my $fh, '>', "$ds/.stop-ok" or die; close $fh;
    my ($rc) = run_hook($GATE, payload_stop($root), probe_dir => proc_dir_none());
    is($rc, 0, "F3: with no live watcher and no finish signal the gate still allows "
             . "the stop — it is not the hook objecting, and two gates must not both block");
    ok(-f "$ds/.stop-ok",
       "F4: ...and the marker SURVIVES, because the sibling guard genuinely has a "
     . "pending dispatch and is about to block this stop (probe says none, no finish "
     . "signal, sibling pending-set non-empty — literally the predicate the sibling "
     . "blocks on) and a token spent on a stop that never happened is lost");

    # Non-vacuity: F4 must be pinning a deliberate carry, not a gate that simply
    # never consumes. Resolve the run (the operator's own marker, not a second
    # unrelated call) and the same .stop-ok is spent.
    touch_finish_marker($ds);
    my ($rc2) = run_hook($GATE, payload_stop($root), probe_dir => proc_dir_none());
    is($rc2, 0, 'F5: once the run is resolved (finish marker present) the stop is allowed');
    ok(!-f "$ds/.stop-ok",
       'F6: ...and NOW the marker is consumed — one shot, spent on the stop it let through');

    # Bounded. The carry reasoning leans on a sibling hook actually being
    # registered; if none is, an unconsumed marker would become a permanent
    # escape hatch. It must degrade to the old behaviour instead.
    my ($root2, $ds2) = new_project(order => 1);
    sibling_pending($root2, 'F-section worker 2');
    open my $f2, '>', "$ds2/.stop-ok" or die; close $f2;

    my $carries = 0;
    for (1 .. 12) {                       # far more than any sane cap
        run_hook($GATE, payload_stop($root2), probe_dir => proc_dir_none());
        last unless -f "$ds2/.stop-ok";
        $carries++;
    }
    ok(!-f "$ds2/.stop-ok",
       "F7: the carry is BOUNDED — an active run cannot keep the marker alive forever "
     . "(spent after $carries carries)");
    cmp_ok($carries, '>=', 1,
           'F8: ...and the bound is not 0, which would be the bug this section fixes');
}

# MAJOR-4 regression: probe=none but the SIBLING guard is genuinely INERT
# (empty/absent pending set) -- a carry must never fire when nothing would
# actually block. This is the exact false positive the F3-F8 fixture above
# used to exercise by accident (before this fix-batch's ORACLE EDIT gave it
# a real sibling pending-set entry): verdict 1 alone, ignoring the sibling's
# own scope test, was read as "a sibling would block".
{
    my ($root, $ds) = new_project(order => 1);
    open my $fh, '>', "$ds/.stop-ok" or die; close $fh;
    # No guard-subagent-stall.sh pending-set file exists for this session at
    # all -- the sibling's own INERT condition.
    my ($rc) = run_hook($GATE, payload_stop($root), probe_dir => proc_dir_none());
    is($rc, 0, 'MAJOR-4: probe=none, sibling inert -- the stop is still allowed');
    ok(!-f "$ds/.stop-ok",
       'MAJOR-4: ...and .stop-ok is CONSUMED, not carried -- nothing would actually block');
}

# ---------------------------------------------------------------------------
# G. Source-level invariants. These are the properties that keep the gate SAFE,
#    and each is easy to remove by accident while "simplifying".
# ---------------------------------------------------------------------------
{
    my $src = do { local (@ARGV, $/) = ($GATE); <> };
    ok(defined $src && length $src, 'G0: gate source readable');

    like($src, qr/MAX_BLOCKS=\d+/,
         'G1: the gate caps consecutive blocks — it must always yield eventually');
    like($src, qr/CCPRAXIS_DRIVE_STOP_OK/,  'G2: the session-wide escape hatch survives');
    like($src, qr/\.stop-ok/,               'G3: the one-shot escape hatch survives');
    like($src, qr/BP_LEDGER/,               'G4: coordinator sessions are still excluded');
    like($src, qr/timeout/,
         'G5: the director call is bounded by a timeout — a hanging oracle must not '
       . 'hang the stop');

    # RETIRED (§4.8): "the block message names bp-drive-next.pl next" pinned
    # the removed director call (D1). The block message's remedy vocabulary
    # is now the probe/marker pair, asserted directly against the denial text
    # in AC22 below rather than as a source-level grep.
    like($src, qr/bp-watch\.pl/,
         'G6: the gate source names the live-process probe helper (Decision 2)');

    my $msrc = do { local (@ARGV, $/) = ($MARK); <> };
    like($msrc, qr/run_in_background/,
         'G7: mark-wakeup still distinguishes backgrounded from foreground Bash');

    # G8 reads CODE, not prose. The first draft of this assertion scanned the
    # whole file and failed on mark-wakeup's own comment explaining why
    # bp_json_get must not be used here — the comment warning against the bug
    # matched the pattern looking for it. Blank full-line comments first, the
    # same way t/62's adapter guard does, or a file that documents its reasoning
    # is punished for it.
    my $mcode = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $msrc, -1;
    unlike($mcode, qr/bp_json_get[^\n]*run_in_background/,
         'G8: run_in_background is NOT read through bp_json_get — it returns empty '
       . 'for JSON booleans, which silently breaks the distinction G7 asserts');
}

# ---------------------------------------------------------------------------
# H. A package already owned by a worker is IN FLIGHT, not finished.
#
#    The gate consults the director and allows the stop when the answer is
#    'done'. For a long time the director ALSO answered 'done' whenever nothing
#    happened to be dispatchable — including the very ordinary case of a driver
#    holding packages open across concurrent workers. Every package non-terminal,
#    the run very much alive, and the one mechanism guarding an unattended run
#    waved the stop through. The run then died mid-package while looking
#    finished, which is precisely the failure this hook exists to prevent, and
#    the hook was the thing being lied to rather than the thing at fault.
#
#    Observed 2026-08-08 on this repo; the director now answers 'in-flight'.
#    These assertions are here so the distinction cannot quietly collapse back
#    into 'done' — the gate needs no change to honour it, which is exactly why
#    nothing else would notice if it regressed.
# ---------------------------------------------------------------------------
sub project_with_package {
    my (%opt) = @_;
    my ($root, $ds) = new_project(order => 1);
    my $bpdir = "$root/.ccpraxis-local-data/blueprints/x";
    make_path("$bpdir/packages");
    # The package set comes from the DAG table in blueprint.md, NOT from the
    # packages/ directory — a fixture without this table parses as a blueprint
    # with zero packages, which then reads as settled and tests nothing.
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print {$b} "# x\n\n| pkg | depends_on |\n|---|---|\n| p1 |  |\n";
    close $b;
    open my $p, '>', "$bpdir/packages/p1.md" or die;
    print {$p} "---\npackage: p1\nstatus: $opt{status}\n---\n\nbody\n";
    close $p;
    if ($opt{announced}) {
        open my $a, '>', "$ds/announced.json" or die;
        print {$a} '{"announced":["x"]}';
        close $a;
    }
    return ($root, $ds);
}

{
    # MIGRATED (§4.8): H1 ("BLOCKED while a package is still marked running")
    # becomes: same fixture, probe forced to NONE (1), no finish marker -> DENY.
    my ($root, $ds) = project_with_package(status => 'running');
    my ($procdir, $self_pid) = proc_dir_none();
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => $procdir);
    is($rc, 2, 'H1 (migrated): a stop is BLOCKED with a package still marked running, '
             . 'probe NONE and no finish marker — the probe, not the director, now '
             . 'decides');
    # RETIRED (§4.8): H1's `like($out, qr/in-flight/)` message pin named the
    # removed director's vocabulary. Replaced by AC22's denial-content pins
    # below, which assert the NEW (probe/marker) vocabulary instead.
    like($out, qr/BLOCKED \(butler drive-loop\)/,
         'H2 (migrated): the block names the new BLOCKED (butler drive-loop) header');
}

{
    # RETIRED (§4.8): H3 ("the same gate ALLOWS the stop once the package is
    # terminal") pinned the director's `done` verdict allowing a stop -- the
    # exact agent-reachable run-ender Decision 23 forbids (D1). Replaced by
    # AC19/AC20 below: no agent-reachable path ends the run; only the
    # operator's own marker does, and it does so REGARDLESS of package status.
    my ($root, $ds) = project_with_package(status => 'done', announced => 1);
    my ($procdir, $self_pid) = proc_dir_none();
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => $procdir);
    is($rc, 2, 'H3 (retired/replaced): a genuinely terminal, announced package NO LONGER '
             . 'allows a stop by itself -- the director\'s own "done" verdict is not read '
             . 'at all (D1); the marker is the only thing that ends a run');
}

# =================== PACKAGE 02 — PROBE-BASED ACCEPTANCE CRITERIA ===========

# AC1/AC2/AC3 — the verdict mapping, driver branch, all three forced outcomes.
{
    my ($root, $ds) = project_with_package(status => 'running');
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                         probe_dir => $procdir, probe_self_pid => $self_pid);
    is($rc, 0, 'AC1 (driver): probe forced to LIVE (0) ALLOWS the stop');
}
{
    my ($root, $ds) = project_with_package(status => 'running');
    my ($procdir) = proc_dir_none();
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => $procdir);
    is($rc, 2, 'AC2 (driver): probe forced to NONE (1) with no marker DENIES');
}
{
    my ($root, $ds) = project_with_package(status => 'running');
    my ($procdir) = proc_dir_cannot_tell();
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => $procdir);
    is($rc, 0, 'AC3 (driver): probe forced to CANNOT-TELL (2) ALLOWS, asserted separately');
    like($out, qr/(?i:cannot.?tell|indeterminate|fail.?open)/,
        'AC3b (driver): stderr names the verdict as indeterminate');
}

# AC7-AC9 — the finish marker: unconditional, one-shot, and grace-windowed.
{
    my ($root, $ds) = project_with_package(status => 'running');
    touch_finish_marker($ds);
    my ($procdir) = proc_dir_none();
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => $procdir);
    is($rc, 0, 'AC7 (driver): .run-finished ends the run regardless of the probe\'s answer');
    ok(!-f "$ds/.run-finished", 'AC8 (driver): ...and the marker no longer exists afterwards');
    ok(-f finish_consumed_path($ds), 'AC8b (driver): ...and .run-finished.consumed now exists');
}
{
    my ($root, $ds) = project_with_package(status => 'running');
    touch_finish_marker($ds);
    run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    # Age the consumed record PAST the 15s grace window.
    my $old = time() - 60;
    utime($old, $old, finish_consumed_path($ds));
    my ($rc2) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    is($rc2, 2, 'AC9 (driver): a stop more than FINISH_GRACE_S after consumption, with no '
              . 'watcher and no new marker, is DENIED — one touch authorises one stop');
}

# AC11 — the marker path also disarms .stop-blocks and .wakeup-pending.
{
    my ($root, $ds) = project_with_package(status => 'running');
    open my $wf, '>', "$ds/.wakeup-pending" or die $!; close $wf;
    open my $sb, '>', "$ds/.stop-blocks" or die $!; print {$sb} '2'; close $sb;
    touch_finish_marker($ds);
    run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    ok(!-f "$ds/.stop-blocks", 'AC11 (driver): the marker path removes .stop-blocks');
    ok(!-f "$ds/.wakeup-pending", 'AC11b (driver): ...and .wakeup-pending');
}

# AC11b (spec, fix-batch 1 / MAJOR-5) — once a finish is consumed, later
# Stops (allowed OR denied) must NOT refresh $MARK's mtime, so a session that
# keeps producing Stops after a genuine finish still ages out on the TTL
# clock measured from the finish, rather than being kept perpetually fresh
# and gated forever. Before this fix, `touch "$MARK"` ran unconditionally on
# every Stop, so the TTL reap above it could never fire for such a session.
{
    my ($root, $ds) = project_with_package(status => 'running');
    my $mark = "$ACTIVE/$SESSION";
    touch_finish_marker($ds);
    run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    ok(-f finish_consumed_path($ds), 'AC11b-refresh precondition: the finish was consumed');

    # Backdate $MARK to simulate time passing with no refresh, then fire
    # several more Stops -- whatever each one decides, $MARK must stay put.
    my $old = time() - 60;
    utime($old, $old, $mark);
    for (1 .. 3) {
        run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    }
    my $after = (stat($mark))[9];
    is($after, $old, 'AC11b-refresh: $MARK is NOT refreshed by Stops after a finish has been consumed');

    # And the TTL reap genuinely fires once $MARK ages past the TTL, because
    # nothing has been artificially keeping it fresh.
    my $ttl_old = time() - (13 * 3600);
    utime($ttl_old, $ttl_old, $mark);
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    is($rc, 0, 'AC11b-refresh: the TTL reap fires on the next Stop once $MARK has genuinely aged out');
    ok(!-f $mark, 'AC11b-refresh: ...and $MARK is removed by the reap');
}

# AC10 (fix-batch 1, MAJOR-1) — BOTH gates, one Stop, one touch. A session
# that is both an armed driver AND has a non-empty pending set on the
# sibling guard (guard-subagent-stall.sh): a single `touch .run-finished`,
# then firing BOTH hooks with the same payload must yield exit 0 from both,
# in either order.
{
    my $STALL = "$HOOKS/guard-subagent-stall.sh";
    sub run_stall_guard {
        my ($root, $payload, %opt) = @_;
        my $env = '';
        $env .= "BP_PROBE_PROC_DIR='$opt{probe_dir}' " if defined $opt{probe_dir};
        $env .= "BP_PROBE_CLK_TCK=100 " if defined $opt{probe_dir};
        my $out = `${env}CLAUDE_PROJECT_DIR="$root" bash "$STALL" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
        return ($? >> 8, $out);
    }
    sub payload_task_stall {
        qq({"hook_event_name":"PostToolUse","session_id":"$SESSION","tool_name":"Task",)
      . qq("tool_input":{"description":"ac10 worker","run_in_background":true}});
    }
    sub payload_stop_stall {
        my $root = shift;
        qq({"hook_event_name":"Stop","session_id":"$SESSION","cwd":"$root"});
    }

    # Order 1: guard-subagent-stall.sh fires first, gate-drive-loop.sh second.
    {
        my ($root, $ds) = project_with_package(status => 'running');
        run_stall_guard($root, payload_task_stall());
        open my $fh, '>', "$ds/.run-finished" or die $!; close $fh;
        my ($rc1) = run_stall_guard($root, payload_stop_stall($root));
        is($rc1, 0, 'AC10a: guard-subagent-stall.sh allows on the operator\'s touch (fired first)');
        my ($rc2) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
        is($rc2, 0, 'AC10b: gate-drive-loop.sh ALSO allows on the SAME touch (fired second)');
    }

    # Order 2: gate-drive-loop.sh fires first, guard-subagent-stall.sh second.
    {
        my ($root, $ds) = project_with_package(status => 'running');
        run_stall_guard($root, payload_task_stall());
        open my $fh, '>', "$ds/.run-finished" or die $!; close $fh;
        my ($rc1) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
        is($rc1, 0, 'AC10c: gate-drive-loop.sh allows on the operator\'s touch (fired first, reversed order)');
        my ($rc2) = run_stall_guard($root, payload_stop_stall($root));
        is($rc2, 0, 'AC10d: guard-subagent-stall.sh ALSO allows on the SAME touch (fired second, reversed order)');
    }
}

# AC19/AC20 — Decision 23's attempt suite, driver surface. One fixture,
# probe forced to NONE, no marker: every attempt below still DENIES.
{
    my ($root, $ds) = project_with_package(status => 'done', announced => 1);
    my $probe_none = proc_dir_none();

    my ($rc_a) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => $probe_none);
    is($rc_a, 2, 'AC19 (driver) precondition: a genuinely terminal/announced project, probe '
              . 'NONE, no marker, is DENIED (H3\'s replacement)');

    make_path("$root/.ccpraxis-local-data/.subagent-guard");
    open my $f1, '>', "$root/.ccpraxis-local-data/.subagent-guard/run-state.json" or die $!;
    print {$f1} '{"state":"finished"}';
    close $f1;
    my ($rc_c) = run_hook($GATE, payload_stop($root), verdict_ok => 1, probe_dir => proc_dir_none());
    is($rc_c, 2, 'AC19c (driver): a hand-written run-state.json claiming "finished" still '
              . 'DENIED');

    my $adversarial = qq({"session_id":"$SESSION","cwd":"$root","run_finished":true,)
                     . qq("finish":"yes","stop_reason":"finished",)
                     . qq("transcript_path":"$ds/.run-finished"});
    my ($rc_d) = run_hook($GATE, $adversarial, verdict_ok => 1, probe_dir => proc_dir_none());
    is($rc_d, 2, 'AC19d (driver): an adversarial Stop payload still DENIED');

    ok(!-f "$ds/.run-finished",
       'AC19 (driver): after the attempt suite, .run-finished still does not exist');

    touch_finish_marker($ds);
    my ($rc_control) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                                 probe_dir => proc_dir_none());
    is($rc_control, 0, 'AC20 (driver): the operator\'s own touch, on the SAME fixture, IS '
                      . 'allowed');
}

# AC22/AC23 — denial content, driver surface.
{
    my ($root, $ds) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1,
                               probe_dir => proc_dir_none());
    is($rc, 2, 'AC22 precondition: denied');
    like($out, qr/BLOCKED \(butler drive-loop\)/, 'AC22a: BLOCKED (butler drive-loop)');
    like($out, qr/bp-watch\.pl --arm/, 'AC22b: bp-watch.pl --arm');
    like($out, qr/\.run-finished/, 'AC22c: the absolute .run-finished path');
    like($out, qr/only the operator/, 'AC22d: only the operator');
    like($out, qr/wrongly stopping abandons an unattended run/, 'AC22e: the asymmetry clause');
    like($out, qr/touch \$?DS?\/?\.stop-ok|\.stop-ok/, 'AC22f: names the one-shot .stop-ok hatch');
    like($out, qr/Blocks at most \d+ times in a row/, 'AC22g: names the MAX_BLOCKS bound');
    unlike($out, qr/bp-runstate\.pl/, 'AC23: the denial never mentions bp-runstate.pl');
}

done_testing();
