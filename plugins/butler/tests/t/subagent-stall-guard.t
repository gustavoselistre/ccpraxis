#!/usr/bin/env perl
# platform: windows
# t/112 — the stop gate is a STATE MACHINE.
#
# THE FAILURE. A turn that ends mid-run schedules nothing: no notification is
# pending, nothing wakes the session, and an unattended run simply stops until
# someone notices hours later. It recurred all evening, and each time the
# remedy was written down as guidance. Guidance did not hold — the same lesson
# guard-git-mutations.sh was born from, where a prohibited command destroyed a
# completed fix-batch that an instruction was supposed to protect.
#
# TWO DETECTORS WERE TRIED FIRST, AND BOTH WERE WRONG IN THE SAME WAY.
#   1. "A Bash command containing the token BP_STALL_GUARD clears the alarm."
#      A guard that died on launch contains the token just as well as a live
#      one. It verified ceremony, not function.
#   2. "Deny if the closing prose promises work." Sidestepped by rephrasing a
#      sentence — a gate the guarded party can talk its way out of.
# A detector is only as good as its guesses. So the default is inverted:
#
#   INERT until a run demonstrably starts; then DENY until the agent RESOLVES
#   it, with exactly two resolutions and no third:
#       finish — nothing pending
#       pause  — a LIVE watcher will wake us (verified pid + future deadline)
#
# Silence is not a resolution, and neither is a plausible sentence.
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives bp-continuity.pl /
# bp-runstate.pl / gate-continuity.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use JSON::PP;

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD = "$HOOKS/guard-subagent-stall.sh";

ok(-f $GUARD, 'guard-subagent-stall.sh exists') or BAIL_OUT('hook missing');
ok(-x $GUARD, 'guard-subagent-stall.sh is executable');

my $J = JSON::PP->new->canonical;

# The drive-solo marker registry is pinned inside each fixture root
# (CCPRAXIS_DRIVE_ACTIVE_DIR), never the machine's real one: whether a real
# drive happens to be running must not change what this file observes.
sub fire {                    # feed a payload to the hook -> (exit, stderr)
    my ($root, $payload, %env) = @_;
    my ($fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
    print {$fh} $J->encode($payload); close $fh;
    my $err = "$tmp.err";
    my $envs = join(' ', map { qq{$_="$env{$_}"} } sort keys %env);
    my $rc  = system(qq{$envs CLAUDE_PROJECT_DIR="$root" CCPRAXIS_DRIVE_ACTIVE_DIR="$root/.drive-active" bash "$GUARD" < "$tmp" 2> "$err"});
    my $se  = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
    unlink $tmp, $err;
    return ($rc >> 8, $se);
}
sub dispatch {
    my ($bg, $desc) = @_;
    my %ti = (description => ($desc // 'a worker'), prompt => 'x');
    $ti{run_in_background} = $bg if defined $bg;
    return { hook_event_name=>'PostToolUse', session_id=>'sess-t112',
             tool_name=>'Task', tool_input=>\%ti };
}
sub bash_ev {
    my ($cmd, $resp) = @_;
    return { hook_event_name=>'PostToolUse', session_id=>'sess-t112', tool_name=>'Bash',
             tool_input=>{ command=>$cmd }, tool_response=>{ stdout=>($resp // '') } };
}
sub stop { { hook_event_name=>'Stop', session_id=>'sess-t112' } }
# Every fixture session is a drive-solo DRIVER by default -- the gate applies
# only to a session running the run -- so it holds its own marker.
# newroot(driver => 0) builds a root where it does not.
sub newroot {
    my (%o) = @_;
    my $r = tempdir(CLEANUP => 1);
    mkdir "$r/.ccpraxis-local-data";
    make_path("$r/.drive-active");
    unless (defined $o{driver} && !$o{driver}) {
        open my $m, '>', "$r/.drive-active/sess-t112" or die "marker: $!";
        print {$m} "$r/.ccpraxis-local-data\n";
        close $m;
    }
    return $r;
}

# ============================ THE STATE MACHINE ============================
# RETIRED (blueprint butler-gate-ergonomics, package 03-retire-runstate,
# spec §5.1's subagent-stall-guard.t entry). This block ('activate'/'pause'/
# 'finish'/reversion-on-stale-watcher/reversion-on-past-deadline) pinned
# bp-runstate.pl's OWN state machine directly, via rs()/state_of() shelling
# out to the script itself -- it never exercised guard-subagent-stall.sh (the
# hook this file is the oracle for) at all. Package 03 deletes bp-runstate.pl
# and, with it, the 'activate'/'pause'/'finish' verbs and the run-state.json
# it wrote; there is no probe-based equivalent to migrate this block onto,
# because the gate no longer reads or writes any persisted state of its own
# (D3/D4: the (probe, finish marker) pair replaced the read entirely). The
# hook-facing property this block's reversion sub-block existed to protect --
# "a stale claim about liveness must not hold the gate open" -- is retained,
# strictly reinforced: "THE GATE" section below no longer trusts ANY written
# record (AC19c/AC19c2 hand-write run-state.json directly and are still
# DENIED), which subsumes "a stale record self-heals" with "no record is ever
# trusted in the first place".
# ---------------------------------------------------------------------------
# PACKAGE 02 fixture helpers — the probe (Signal A) and the finish marker
# (Signal B), per spec 02-gates-use-the-probe-spec.md §2.1. BP_PROBE_PROC_DIR/
# BP_PROBE_SELF_PID/BP_PROBE_CLK_TCK are bp-watch.pl's own fixture knobs
# (package 01's own watcher-probe-liveness.t AC3/AC4/AC5 technique); a fresh
# synthetic stat pair with IDENTICAL tick counts on both self and candidate
# gives age==0 regardless of clk_tck's real meaning, per AC1's own "fresh
# stat" instruction — no dependency on the ticks<->epoch conversion formula.
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
sub proc_dir_none { return tempdir(CLEANUP => 1) }   # empty -> probe verdict 1 (NONE)
sub proc_dir_cannot_tell {                            # not-a-directory -> probe verdict 2
    my $r = tempdir(CLEANUP => 1);
    my $f = "$r/not-a-directory-file";
    open my $fh, '>', $f or die $!; print {$fh} 'x'; close $fh;
    return $f;
}
sub proc_dir_live {                                   # one fresh armed watcher -> verdict 0
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
sub proc_dir_expired {                                # armed but past its budget -> verdict 1
    my ($data_dir) = @_;
    my $procdir  = tempdir(CLEANUP => 1);
    my $self_pid = 900001;
    my $pid      = 900002;
    _pw_stat($procdir, $self_pid, 1_000_300);          # 300 ticks / clk_tck(100) = 3s elapsed
    _pw_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--max-seconds', 2, '--data', $data_dir);
    _pw_stat($procdir, $pid, 1_000_000);
    return ($procdir, $self_pid);
}
sub proc_dir_unarmed_worker {                         # a live worker, not an armed watcher -> 1
    my ($data_dir) = @_;
    my $procdir = tempdir(CLEANUP => 1);
    _pw_cmdline($procdir, 900003, 'perl', 'plugins/butler/scripts/bp-drive-next.pl', 'next');
    return $procdir;
}

# fire_with_probe(ROOT, PAYLOAD, PROCDIR, SELF_PID) — fire() with the probe
# forced via env, restored on return (local).
sub fire_with_probe {
    my ($r, $payload, $procdir, $self_pid) = @_;
    local $ENV{BP_PROBE_PROC_DIR} = $procdir;
    local $ENV{BP_PROBE_SELF_PID} = $self_pid if defined $self_pid;
    local $ENV{BP_PROBE_CLK_TCK}  = 100;
    return fire($r, $payload);
}

# touch_finish_marker(ROOT) — the OPERATOR's own lever (spec §2.1 Signal B):
# <ROOT>/.ccpraxis-local-data/.drive-solo/.run-finished
sub touch_finish_marker {
    my ($r) = @_;
    my $ds = "$r/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    open my $fh, '>', "$ds/.run-finished" or die $!;
    close $fh;
    return "$ds/.run-finished";
}
sub finish_consumed_path { my ($r) = @_; return "$r/.ccpraxis-local-data/.drive-solo/.run-finished.consumed" }

# ================================ THE GATE =================================

{
    my $r = newroot();
    my ($rc) = fire($r, stop());
    is($rc, 0, 'INERT: stopping is allowed and nothing is in the way');
}

{
    my $r = newroot();
    my ($rc) = fire($r, dispatch(JSON::PP::true, 'b01 test-writer'));
    is($rc, 0, 'a background dispatch is recorded silently');

    # MIGRATED (§4.8): every `state_of($r) eq 'active'` after a dispatch
    # becomes "the same fixture's Stop is denied (probe 1, no marker)" — the
    # gate no longer consults bp-runstate.pl at all (D4).
    my $procdir = proc_dir_none();
    my ($src, $serr) = fire_with_probe($r, stop(), $procdir);
    is($src, 2, 'ACTIVE (migrated): pending set non-empty, probe says NONE, no finish '
              . 'marker -> stopping is DENIED');
    like($serr, qr/BLOCKED/,          'the denial says BLOCKED');
    like($serr, qr/b01 test-writer/,  'the denial names the unresolved worker');
    # MIGRATED: "the denial gives the finish verb" (bp-runstate.pl finish) ->
    # "the denial gives the operator's finish marker" (.run-finished path).
    like($serr, qr/\.run-finished/, 'the denial gives the operator\'s finish marker');
    # MIGRATED: "the denial gives the pause verb" (bp-runstate.pl pause) ->
    # "the denial gives the arm-a-watcher remedy" (bp-watch.pl --arm).
    like($serr, qr/bp-watch\.pl --arm/, 'the denial gives the arm-a-watcher remedy');
}

{   # A director tick that hands back work activates too — no subagent needed.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next',
                     '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    # MIGRATED (§4.8): state_of($r) eq 'active' -> the same fixture's Stop is
    # denied (probe 1, no marker).
    my ($rc) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 2, 'a director response of run-package leaves the pending set unresolved, '
             . 'so the turn may not simply end');
}

{   # fix-batch B1 (red-team HIGH-1): the SAME activation, but via the
    # .sh-shim spelling package 04-bp-on-path put on PATH -- proves the
    # case statement's broadening (bp-drive-next.pl|.sh|bare) recognizes
    # this spelling identically to the .pl form above, not just by name.
    my $r = newroot();
    fire($r, bash_ev('bp-drive-next.sh next',
                     '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    my ($rc) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 2, 'B1: the .sh-spelled invocation activates identically to the .pl form -- '
             . 'the turn may not simply end');
}

{   # fix-batch B1: and the bare/extensionless alias (non-Windows installs).
    my $r = newroot();
    fire($r, bash_ev('bp-drive-next next',
                     '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    my ($rc) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 2, 'B1: the bare-spelled invocation activates identically to the .pl form -- '
             . 'the turn may not simply end');
}

{   # Reading the RESPONSE, not the command: asking is not the same as being
    # handed work. A tick that returns done must not start a run.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next', '{"action":"done"}'));
    # MIGRATED (§4.8): state_of($r) eq 'inert' -> the same fixture's Stop is
    # allowed (pending set empty).
    my ($rc) = fire($r, stop());
    is($rc, 0, 'a director response of done does NOT leave anything pending, so stopping '
             . 'stays allowed');
}

{   # ...and neither does need-order, which used to activate here.
    #
    # need-order is the director DECLINING to choose, because the answer belongs
    # to the operator (e.g. `scope-extends-order`: delivered blueprints with no
    # order covering them). Nothing is underway, so there is nothing for a stop
    # gate to protect.
    #
    # Treating it as work handed back produced a CLOSED LOOP, observed
    # 2026-08-24: an agent consulting the director to CHECK whether anything was
    # pending reactivated the run it had just finished, so the stop gate blocked,
    # so it finished again, so it consulted again. The diagnostic mutated the
    # thing being diagnosed and the session could not leave.
    #
    # This costs nothing: when a drive is genuinely underway and hits
    # need-order, the run is ALREADY active, and activation only has an effect
    # on a run that is idle or finished — precisely the false positive.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next',
                     '{"action":"need-order","candidates":["a","b"],"reason":"scope-extends-order"}'));
    # MIGRATED (§4.8): state_of($r) eq 'inert' -> the same fixture's Stop is
    # allowed (pending set empty). need-order records nothing to $STATE, so
    # nothing is pending and stopping stays allowed regardless of the probe.
    my ($rc) = fire($r, stop());
    is($rc, 0, 'a director response of need-order does NOT record anything pending — it is '
             . 'a question for the operator, not work in flight, so merely ASKING the '
             . 'director cannot trap the session');
}

{   # Non-vacuity for the pair above: the activation path is still wired, so the
    # two `inert` assertions describe a discriminating rule rather than a hook
    # that has quietly stopped activating anything at all.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next',
                     '{"action":"run-package","blueprint":"bp","package":"p9"}'));
    # MIGRATED (§4.8): state_of($r) eq 'active' -> the same fixture's Stop is
    # denied (probe 1, no marker).
    my ($rc) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 2, 'counter-fixture: run-package still records a pending dispatch, so '
             . '`done`/`need-order` staying inert is a distinction the hook actually draws');
}

{   # A command that merely PRINTS the verdict is not a director tick.
    #
    # The activation trigger used to match the TEXT of any Bash output, so
    # grepping this hook's own source, cat-ing it, or running its tests started
    # a run -- and the session then could not end, because a diagnostic had
    # manufactured the very state the Stop gate exists to protect. Observed
    # 2026-08-24 while investigating this file, which is as close to a
    # self-demonstrating bug as this repo has produced.
    #
    # Same class as almanac 20260819-054052-1168: mention-matching raw command
    # text with no reader veto.
    my $r = newroot();
    fire($r, bash_ev('grep -n "action" plugins/butler/hooks/guard-subagent-stall.sh',
                     '158:          *\'"action":"run-package"\'*)'));
    # MIGRATED (§4.8): state_of($r) eq 'inert' -> the same fixture's Stop is
    # allowed (pending set empty).
    my ($rc1) = fire($r, stop());
    is($rc1, 0, 'a command that merely PRINTS "action":"run-package" records nothing '
              . 'pending — reading a verdict out of a file is not receiving one from the '
              . 'director, so stopping stays allowed');

    # ...and the veto is on the COMMAND, so a real director call still works
    # even though its output is byte-identical in the part that matters.
    my $r2 = newroot();
    fire($r2, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next --scope x',
                      '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    # MIGRATED (§4.8): state_of($r2) eq 'active' -> the same fixture's Stop is
    # denied (probe 1, no marker).
    my ($rc2) = fire_with_probe($r2, stop(), proc_dir_none());
    is($rc2, 2, 'counter-fixture: the same verdict from bp-drive-next.pl DOES record a '
              . 'pending dispatch, so the veto discriminates on producer rather than simply '
              . 'refusing everything');
}

{   # READING THE DIRECTOR'S SOURCE IS NOT CALLING IT (2026-09-23). The command
    # names bp-drive-next.pl and the output contains the director's own header
    # comment, {"action":"run-package",...} -- both halves of the old substring
    # test matched, and the session was refused every later stop.
    my $r = newroot();
    fire($r, bash_ev('grep -n "sub \\|package =>" plugins/butler/scripts/bp-drive-next.pl',
                     qq{27:#   {"action":"run-package","blueprint":B,"package":P} drive this package next\n}
                   . qq{951:            my \$action = { action => 'run-package', blueprint => \$bp };}));
    fire($r, bash_ev('sed -n 40,75p plugins/butler/scripts/bp-drive-next.pl; sed -n 1p plugins/butler/scripts/bp-drive-next.pl',
                     qq{   {"action":"run-package","blueprint":"b","package":"p"}}));
    my ($rc) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 0, 'grep/sed of the director source records nothing, even from a driver session');

    # The anchors are not so tight that real invocations stop counting.
    for my $cmd ('perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-drive-next.pl" next --scope all',
                 'cd /x && perl plugins/butler/scripts/bp-drive-next.pl next',
                 'bp-drive-next.sh next;') {
        my $r2 = newroot();
        fire($r2, bash_ev($cmd, qq{{"action":"run-package","blueprint":"bp","package":"p1"}\n}));
        my ($rc2) = fire_with_probe($r2, stop(), proc_dir_none());
        is($rc2, 2, "a real director call still activates: $cmd");
    }
    # A verb that cannot hand out a package does not activate.
    my $r3 = newroot();
    fire($r3, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl park bp stale',
                      '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    my ($rc3) = fire_with_probe($r3, stop(), proc_dir_none());
    is($rc3, 0, 'park is not next: nothing recorded');
}

{   # THE GATE BELONGS TO THE SESSION RUNNING THE RUN (2026-09-23). A session
    # that is not driving -- no marker of its own, no director hand-back, not
    # a coordinator -- dispatched a background agent while ANOTHER session
    # drove, and was told only the operator could end "the run".
    #
    # The idle exit ("no outstanding work anywhere") is switched off for this
    # whole block: these fixtures have no blueprints, so it would allow every
    # stop and hide which rule decided.
    local $ENV{CCPRAXIS_STALL_SKIP_IDLE_EXIT} = 1;
    my $r = newroot(driver => 0);
    open my $m, '>', "$r/.drive-active/sess-someone-else" or die; close $m;
    fire($r, dispatch(JSON::PP::true, 'research agent'));
    my ($rc, $err) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc, 0, 'a non-driving session may stop with its own background agent pending');
    my ($rc_again) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc_again, 0, '...and its pending set was cleared, not left to re-trigger');

    my $r2 = newroot(driver => 0);
    fire($r2, dispatch(JSON::PP::true, 'w'));
    my ($rc2) = fire_with_probe($r2, stop(), proc_dir_none());
    is($rc2, 0, 'counter-fixture baseline: same, no marker at all');

    # Each of the three ways of driving turns the gate back on.
    my $r3 = newroot(driver => 1);
    fire($r3, dispatch(JSON::PP::true, 'w'));
    my ($rc3) = fire_with_probe($r3, stop(), proc_dir_none());
    is($rc3, 2, 'own driver marker: gated');

    my $r4 = newroot(driver => 0);
    fire($r4, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next',
                      '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    my ($rc4) = fire_with_probe($r4, stop(), proc_dir_none());
    is($rc4, 2, 'no marker, but this session\'s own director call handed back work: gated');

    my $r5 = newroot(driver => 0);
    fire($r5, dispatch(JSON::PP::true, 'w'));
    local $ENV{BP_LEDGER} = "$r5/ledger.md";
    my ($rc5) = fire_with_probe($r5, stop(), proc_dir_none());
    is($rc5, 2, 'fleet coordinator (BP_LEDGER): gated');
}

{   # The two resolutions, end to end.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    is((fire($r, stop()))[0], 2, 'denied before resolving');
    # MIGRATED (§4.8): "FINISH resolves it — stopping is allowed" (bp-runstate.pl
    # finish) -> the operator's marker resolves it, and is consumed in the same
    # step (Decisions 7/16).
    touch_finish_marker($r);
    my ($rc, undef) = fire($r, stop());
    is($rc, 0, 'the operator\'s finish marker resolves it — stopping is allowed');
    ok(!-f "$r/.ccpraxis-local-data/.drive-solo/.run-finished",
       '...and the marker no longer exists (consumed in the same step)');
    ok(-f finish_consumed_path($r), '...and .run-finished.consumed now exists');
}
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    # MIGRATED (§4.8): "PAUSE resolves it — stopping is allowed while the watcher
    # lives" (bp-runstate.pl pause) -> probe 0 (a live bounded watcher) resolves
    # it.
    my ($procdir, $self_pid) = proc_dir_live("$r/.ccpraxis-local-data");
    my ($rc) = fire_with_probe($r, stop(), $procdir, $self_pid);
    is($rc, 0, 'a live bounded watcher (probe 0) resolves it — stopping is allowed while '
             . 'the watcher lives');
}

{   # Retrying does not wear the gate down. The prose version cleared its marker
    # on denial, so a second stop sailed through; enforcement a retry defeats is
    # advice.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    is((fire($r, stop()))[0], 2, 'first stop denied');
    is((fire($r, stop()))[0], 2, 'second stop denied too — retrying does not bypass it');
    is((fire($r, stop()))[0], 2, 'and a third');
}

{   # Synchronous dispatches hold the turn open, so a hang is already visible.
    #
    # The `is(state_of($r), 'inert', ...)` half is RETIRED (package
    # 03-retire-runstate): it called bp-runstate.pl's own state machine
    # directly (same class as "THE STATE MACHINE" section, retired above)
    # and was already flagged as a migration leftover from package 02
    # ("this line was missed by the same migration this file already
    # applies everywhere else"). §1's own evidence table establishes nothing
    # in production has ever written the 'active' state, synchronous or
    # not, so there is nothing left to assert was not activated. The half
    # that actually exercises the GATE survives unchanged.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::false, 'sync worker'));
    is((fire($r, stop()))[0], 0, 'a SYNCHRONOUS dispatch does not block the stop');
}
{   # The Agent tool defaults to background, so an absent field is the dangerous
    # case and must be treated as such. ORACLE EDIT (authorized 2026-09-22,
    # package 02-gates-use-the-probe step 4/5): state_of() reads bp-runstate.pl
    # status directly, the mechanism D4/AC6 remove -- this line was missed by
    # the same migration this file already applies everywhere else (a director
    # response / dispatch activating -> the fixture's Stop is denied). Same
    # class as the other migrated `state_of eq 'active'` assertions above.
    my $r = newroot();
    fire($r, dispatch(undef, 'defaulted worker'));
    is((fire($r, stop()))[0], 2, 'omitting run_in_background counts as BACKGROUND -- the stop is denied');
}

{   # force-stop: a gate with no override can strand the operator.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    my $d = "$r/.ccpraxis-local-data/.subagent-guard";
    open my $f, '>', "$d/force-stop" or die $!; close $f;
    is((fire($r, stop()))[0], 0, 'force-stop overrides the gate outright');

    # ONE-SHOT, AND THIS IS THE HALF THAT WAS MISSING. Until 2026-09-18 the
    # override was only TESTED for, never removed, so one touch disabled this
    # guard permanently and silently -- for every later turn and every later run
    # in the project. Its sibling lever on gate-drive-loop.sh (.stop-ok) is
    # genuinely one-shot, so two sibling gates had opposite lifetimes and the
    # dangerous one was the quiet one. Found by using it: the override was
    # touched to end a single turn, and the guard stayed inert for the rest of
    # the session.
    ok(!-e "$d/force-stop",
        'force-stop is CONSUMED on use, not left behind to disable the guard forever');

    # And the proof that consuming it restores the gate rather than merely
    # tidying a file: the very next stop, with the same dispatch still
    # unresolved, must block again.
    is((fire($r, stop()))[0], 2,
        'the NEXT stop is gated again -- the override allowed exactly one');
}

{   # NOT bp_hook_gate'd: it must fire in drive-solo, which is where subagents
    # are dispatched by hand and where this failure actually happens.
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    unlike($src, qr/^\s*bp_hook_gate\s*$/m,
        'the hook does NOT call bp_hook_gate (it would be inert in drive-solo)');
    like($src, qr/NO bp_hook_gate here, by design/,
        '...and says so, so nobody "fixes" it by adding one');

    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ungated worker'));
    is((fire($r, stop()))[0], 2, 'it denies with no BP_* contract in the environment');
}

{   # No prose anywhere in the DECISION. The gate must not be talkable-out-of.
    #
    # Comments are stripped first, on purpose: the header explains at length why
    # the token and prose-matching designs were wrong, so it legitimately
    # contains both strings. What must not contain them is the executable part.
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;

    unlike($code, qr/\bnext\b.{0,20}I\x27ll/i,
        'the executable gate does not pattern-match the assistant\'s prose (the sidesteppable design)');
    unlike($code, qr/BP_STALL_GUARD/,
        'the executable gate does not accept a magic token in a command (the ceremony design)');
    # MIGRATED (§4.8): "the decision is delegated to the state machine"
    # (like $code =~ bp-runstate.pl) -> "the decision is delegated to the
    # live-process probe" (Decision 2), plus an explicit unlike() pinning
    # bp-runstate.pl's total absence from the executable part (AC6).
    like($code, qr/bp-watch\.pl/,
        'the decision is delegated to the live-process probe');
    unlike($code, qr/bp-runstate\.pl/,
        'AC6: bp-runstate.pl appears nowhere in the executable part of the hook');
}

# ---- THE REGISTRATION IS THE LOAD-BEARING HALF ------------------------------
#
# A hook nothing invokes is prose with a shebang. CLAUDE.md makes this argument
# about guard-git-mutations.sh and cited t/settings-scope-split.t as its
# protection — a file that DOES NOT EXIST (t/61 is judge-starvation.t, and
# t/14 only checks a generated blob for the subagent self-test). The protection
# was itself imaginary. Both registrations are asserted here instead.
{
    my $sj = "$Bin/../../../../.claude/settings.json";
    ok(-f $sj, '.claude/settings.json exists and is tracked') or BAIL_OUT('no settings.json');
    my $cfg = eval { JSON::PP->new->decode(do { open my $f,'<',$sj or die; local $/; <$f> }) };
    ok($cfg, '.claude/settings.json is valid JSON');

    my @cmds;
    for my $ev (keys %{ $cfg->{hooks} || {} }) {
        for my $blk (@{ $cfg->{hooks}{$ev} || [] }) {
            push @cmds, map { +{ event=>$ev, matcher=>($blk->{matcher}//''), cmd=>($_->{command}//'') } }
                        @{ $blk->{hooks} || [] };
        }
    }
    ok(scalar(grep { $_->{cmd} =~ /guard-git-mutations\.sh/ && $_->{event} eq 'PreToolUse' } @cmds),
       'guard-git-mutations.sh is registered PreToolUse');
    ok(scalar(grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'Stop' } @cmds),
       'guard-subagent-stall.sh is registered Stop — without this it can never deny');
    my ($post) = grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'PostToolUse' } @cmds;
    ok($post, 'guard-subagent-stall.sh is registered PostToolUse — without this it never activates');
    like(($post//{})->{matcher}//'', qr/Task/, '...its matcher covers Task');
    like(($post//{})->{matcher}//'', qr/Bash/, '...and Bash');
}

# ======================= THE PENDING SET HAS A LIFECYCLE ====================
#
# Closes almanac report 20260819-014748-0b41, filed against this hook. The
# pending-dispatch file was APPEND-ONLY and nothing ever truncated it, so the
# denial message listed every background dispatch of the whole session under the
# heading "this turn". By the end of a long unattended run that is dozens of
# entries, most hours old and already resolved -- noise burying the two lines an
# operator needs.
#
# Broad write, no clear: the same shape as the runs/escalations/ defect package
# t07 exists to fix, which is why the two were closed together. The rule that
# resolves both is the same one -- clear when the thing the record tracked is
# demonstrably over.
{
    my $r = newroot();
    my $state = "$r/.ccpraxis-local-data/.subagent-guard/sess-t112";

    fire($r, dispatch(1, 'worker one'));
    fire($r, dispatch(1, 'worker two'));
    ok(-s $state, 'pending-set precondition: two background dispatches are recorded');

    # A DENIED stop must NOT clear. A dispatch made two turns ago and still
    # unresolved is still unresolved, and dropping it would hide exactly what
    # this hook exists to surface.
    #
    # Probe forced to NONE deterministically (rather than trusting the real
    # host /proc to have no stray watcher) -- package 02's own migration of
    # the deny path (§4.8: state_of eq 'active' -> probe 1, no marker).
    my (undef, $denied) = fire_with_probe($r, stop(), proc_dir_none());
    like($denied, qr/worker one/, 'a denied Stop still names the earlier dispatch');
    like($denied, qr/worker two/, '...and the later one');
    ok(-s $state, 'a DENIED Stop leaves the pending set intact -- an unresolved dispatch stays reported');

    # ...and the heading no longer claims a window the file never had.
    unlike($denied, qr/dispatch\(es\) this turn/,
        'the denial no longer says "this turn" about a set that spans the session');
    like($denied, qr/since the last resolved turn/,
        'it names the window the set actually covers');

    # A RESOLVED run means every recorded dispatch is accounted for, so an
    # ALLOWED stop clears.
    #
    # MIGRATED (compelled by AC19a): the resolution step used to be
    # `bp-runstate.pl finish`, which the new gate no longer reads at all
    # (Decision 23: the legacy verb no longer influences either gate). The
    # operator's own finish marker is the only thing that still resolves a
    # denied stop, so it replaces the legacy verb here.
    touch_finish_marker($r);
    my ($rc2, $err2) = fire($r, stop());
    is($rc2, 0, 'a finished run (operator marker) lets the turn end');
    # ORACLE EDIT (fix-batch 1, review SHOULD-FIX-4): this used to pin
    # SILENCE on the finish-marker allow path, but gate-drive-loop.sh's
    # equivalent path has always printed a one-line stderr naming the
    # marker as the reason, and the asymmetry between two sibling hooks
    # reacting identically to the same signal was unexplained. Harmonized
    # toward PRINTING in both (matches Decision 14's "never fail open
    # silently" posture, extended here to the allow path for consistency).
    like($err2, qr/the operator's \.run-finished marker ended the run/,
        '...and says so -- no longer silent, matching gate-drive-loop.sh\'s equivalent path');
    ok(!-s $state, 'and an ALLOWED Stop clears the pending set, so the next turn starts from empty');

    # Non-vacuity: the clear is real, not an artefact of the file never having
    # been written. A fresh dispatch after the clear must reappear.
    fire($r, dispatch(1, 'worker three'));
    my (undef, $again) = fire_with_probe($r, stop(), proc_dir_none());
    like($again, qr/worker three/, 'a dispatch AFTER the clear is reported again');
    unlike($again, qr/worker one/,
        'and the cleared ones do not come back -- the truncation is a real reset, not a display filter');
}

# =================== PACKAGE 02 — PROBE-BASED ACCEPTANCE CRITERIA ===========
#
# The named migrations above re-point every existing GATE assertion off
# bp-runstate.pl. This section adds the acceptance criteria that have no
# pre-existing assertion to migrate onto: the probe's cannot-tell/expired/
# unarmed-worker verdicts, the finish-marker's grace window, Decision 23's
# attempt suite, and the denial-content pins specific to this hook's surface.
# ===========================================================================

# AC3 — probe forced to 2 (cannot-tell) ALLOWS, asserted separately from AC1/
# AC2, with a stderr line naming the indeterminate verdict.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac3 worker'));
    my ($rc, $err) = fire_with_probe($r, stop(), proc_dir_cannot_tell());
    is($rc, 0, 'AC3: probe forced to CANNOT-TELL (2) ALLOWS the stop, even with a pending '
             . 'dispatch');
    like($err, qr/(?i:cannot.?tell|indeterminate|fail.?open)/,
        'AC3b: ...and stderr names the verdict as indeterminate');
    # AC3 non-vacuity: the pending set is NOT cleared on a cannot-tell allow
    # (behaviour 3) -- the next stop, with the probe now saying NONE, still
    # denies on the same unresolved dispatch.
    my ($rc2) = fire_with_probe($r, stop(), proc_dir_none());
    is($rc2, 2, 'AC3c: a cannot-tell allow clears NOTHING -- the unresolved dispatch is '
              . 'still denied on the very next stop once the probe can tell');
}

# AC5 — every code outside {0,1} is an ALLOW: bp-watch.pl missing/unreadable.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac5 worker'));
    local $ENV{BP_PROBE_PROC_DIR} = proc_dir_none();
    # There is no portable, hook-external way to make bp-watch.pl itself
    # "missing" without touching the write set, so this exercises the other
    # half of AC5's own text: a call that cannot resolve to {0,1} still
    # allows. BP_PROBE_CLK_TCK left malformed forces the probe's own
    # cannot-tell path (behaviour 16), which is exactly the "any code
    # outside {0,1}" contract AC5 pins.
    local $ENV{BP_PROBE_CLK_TCK} = 'not-a-number';
    my ($rc) = fire($r, stop());
    is($rc, 0, 'AC5: a probe call that cannot resolve to a trusted 0/1 verdict ALLOWS');
}

# AC12 — Decision 5 stall variant 1: the watcher was the work itself (a live
# process that is not an armed bp-watch.pl) -> DENY.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac12 worker'));
    my ($rc) = fire_with_probe($r, stop(), proc_dir_unarmed_worker("$r/.ccpraxis-local-data"));
    is($rc, 2, 'AC12: a live process that is not an armed bp-watch.pl watcher still DENIES');
}

# AC14 — Decision 5 stall variant 3: past its --max-seconds budget -> DENY,
# paired with a fresh-start counter-fixture that ALLOWS, so the denial is
# attributable to expiry.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac14 worker'));
    my ($procdir, $self_pid) = proc_dir_expired("$r/.ccpraxis-local-data");
    my ($rc) = fire_with_probe($r, stop(), $procdir, $self_pid);
    is($rc, 2, 'AC14: a watcher whose --max-seconds budget has already elapsed still DENIES');

    my $r2 = newroot();
    fire($r2, dispatch(JSON::PP::true, 'ac14b worker'));
    my ($procdir2, $self_pid2) = proc_dir_live("$r2/.ccpraxis-local-data");
    my ($rc2) = fire_with_probe($r2, stop(), $procdir2, $self_pid2);
    is($rc2, 0, 'AC14b counter-fixture: the identical shape with a FRESH start time ALLOWS -- '
              . 'the denial above is attributable to expiry, not to the fixture shape');
}

# AC19 — Decision 23's attempt suite: an agent cannot manufacture the finish
# condition. Every attempt below is performed on ONE fixture (armed pending
# set, probe forced to NONE, no marker) and the Stop is still DENIED after
# each. AC20 is the positive control on the same fixture.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac19 worker'));
    my $ds = "$r/.ccpraxis-local-data/.drive-solo";
    make_path($ds);

    # (a)/(b) MIGRATED (package 03-retire-runstate, spec §5.1): the fixtures
    # used to shell out to the legacy `bp-runstate.pl finish`/`pause` verbs
    # before firing the gate. Those verbs are deleted along with the file, so
    # there is no longer any "irrelevant state" to construct -- the migrated
    # form fires the gate directly on the baseline fixture (armed pending
    # set, probe forced to NONE, no marker) and keeps the same claim: no
    # record of any kind influences this gate, only the probe and the marker
    # do. (c)/(d)/(e) below already assert the same class without touching
    # bp-runstate.pl at all and are kept as the surviving non-vacuity proof
    # that "no record" really means no record, including a hand-written one.
    is((fire_with_probe($r, stop(), proc_dir_none()))[0], 2,
       'AC19a MIGRATED: a Stop fired on the baseline fixture (armed pending set, probe NONE, '
     . 'no operator marker, and critically no run-state.json of any kind ever written) is still '
     . 'DENIED -- no legacy finish/pause declaration was needed to produce this DENY, because '
     . 'none can exist any more');
    is((fire_with_probe($r, stop(), proc_dir_none()))[0], 2,
       'AC19b MIGRATED: repeating the identical fixture is still DENIED -- the denial is not a '
     . 'one-shot artifact of the first call, reinforcing that nothing about firing the gate '
     . 'itself ever resolves it');

    # (c) a hand-crafted run-state.json claiming finished, then paused.
    make_path("$r/.ccpraxis-local-data/.subagent-guard");
    my $rsp = "$r/.ccpraxis-local-data/.subagent-guard/run-state.json";
    open my $f1, '>', $rsp or die $!; print {$f1} '{"state":"finished"}'; close $f1;
    is((fire_with_probe($r, stop(), proc_dir_none()))[0], 2,
       'AC19c: a hand-written run-state.json claiming "finished" still DENIED');
    open my $f2, '>', $rsp or die $!;
    print {$f2} qq({"state":"paused","watcher_pid":$$,"until":} . (time + 600) . '}');
    close $f2;
    is((fire_with_probe($r, stop(), proc_dir_none()))[0], 2,
       'AC19c2: ...and claiming "paused" with a live non-watcher pid still DENIED');

    # (d) an adversarial Stop payload.
    my $adversarial = { hook_event_name => 'Stop', session_id => 'sess-t112',
        run_finished => JSON::PP::true, finish => 'yes', stop_reason => 'finished',
        transcript_path => "$ds/.run-finished" };
    is((fire_with_probe($r, $adversarial, proc_dir_none()))[0], 2,
       'AC19d: a Stop payload carrying run_finished/finish/stop_reason/transcript_path '
     . 'fields still DENIED -- none of them is read as a finish signal');

    # (e) extra argv on the hook invocation itself.
    {
        local $ENV{BP_PROBE_PROC_DIR} = proc_dir_none();
        my ($fh, $tmp) = File::Temp::tempfile('t112-argv-XXXXXX', TMPDIR => 1);
        print {$fh} $J->encode(stop()); close $fh;
        my $rcx = system(qq{CLAUDE_PROJECT_DIR="$r" CCPRAXIS_DRIVE_ACTIVE_DIR="$r/.drive-active" bash "$GUARD" --finish < "$tmp" >/dev/null 2>&1});
        unlink $tmp;
        is($rcx >> 8, 2, 'AC19e: invoking the hook with extra argv (--finish) still DENIED');
    }

    ok(!-f "$ds/.run-finished",
       'AC19: after the whole attempt suite, .run-finished still does not exist -- no path '
     . 'in the hook creates it');

    # AC20 — the positive control, same fixture: the operator's own touch allows.
    touch_finish_marker($r);
    is((fire($r, stop()))[0], 0,
       'AC20: the operator\'s own touch of .run-finished, on the SAME fixture, IS allowed -- '
     . 'the denials above are attributable to the missing marker, not to a gate that denies '
     . 'everything');
}

# AC21 — turn != run: arming a watcher ends the turn but not the run. The
# very next stop, once the watcher is gone, is denied again.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac21 worker'));
    my ($procdir, $self_pid) = proc_dir_live("$r/.ccpraxis-local-data");
    is((fire_with_probe($r, stop(), $procdir, $self_pid))[0], 0,
       'AC21a: a live bounded watcher ends the turn');
    is((fire_with_probe($r, stop(), proc_dir_none()))[0], 2,
       'AC21b: ...but NOT the run -- the very next stop, watcher gone, is denied again');
}

# AC22/AC27 — denial content, this hook's own surface.
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac22 worker'));
    my (undef, $err) = fire_with_probe($r, stop(), proc_dir_none());
    like($err, qr/BLOCKED/, 'AC22a: the denial contains BLOCKED');
    like($err, qr/bp-watch\.pl --arm/, 'AC22b: ...bp-watch.pl --arm');
    like($err, qr/\.run-finished/, 'AC22c: ...the absolute .run-finished path');
    like($err, qr/only the operator/, 'AC22d: ...only the operator');
    like($err, qr/wrongly stopping abandons an unattended run/,
        'AC22e: ...the asymmetry clause');
    like($err, qr/force-stop/i, 'AC22f: ...the ONE-SHOT force-stop lever');
    unlike($err, qr/bp-runstate\.pl/, 'AC27: the denial never mentions bp-runstate.pl');
}

# AC10 (fix-batch 1, MAJOR-1) — BOTH gates, one Stop, one touch. A session
# that is both an armed driver (order.json + drive-active registry entry)
# and has a non-empty pending set on THIS hook: a single
# `touch .run-finished`, then firing guard-subagent-stall.sh and
# gate-drive-loop.sh with the same payload must yield exit 0 from BOTH,
# in either firing order. This is exactly the scenario
# .run-finished.consumed + FINISH_GRACE_S exist for (spec §2.1: "a single
# operator touch would allow one hook and be denied by its sibling"), and
# it is the scenario MAJOR-1's epoch-in-contents fix directly affects.
{
    my $GATE = "$HOOKS/gate-drive-loop.sh";

    sub _ac10_setup {
        my $r = newroot();
        my $ds = "$r/.ccpraxis-local-data/.drive-solo";
        make_path($ds);
        open my $o, '>', "$ds/order.json" or die $!;
        print {$o} '{"order":["x"],"recorded_at":1}';
        close $o;
        my $active = "$r/.active-drivers";
        make_path($active);
        open my $m, '>', "$active/sess-t112" or die $!;
        print {$m} "$r/.ccpraxis-local-data\n";
        close $m;
        fire($r, dispatch(JSON::PP::true, 'ac10 worker'));  # a non-empty pending set
        return ($r, $active);
    }

    sub fire_gate {   # like fire(), but for gate-drive-loop.sh with extra env
        my ($gate, $envh, $payload) = @_;
        my ($fh, $tmp) = File::Temp::tempfile('t112-gate-XXXXXX', TMPDIR => 1);
        print {$fh} $J->encode($payload); close $fh;
        my $err = "$tmp.err";
        my $envstr = join(' ', map { qq{$_='$envh->{$_}'} } sort keys %$envh);
        my $rc = system(qq{$envstr bash "$gate" < "$tmp" 2> "$err"});
        my $se  = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
        unlink $tmp, $err;
        return ($rc >> 8, $se);
    }

    # Order 1: guard-subagent-stall.sh fires first, gate-drive-loop.sh second.
    {
        my ($r, $active) = _ac10_setup();
        touch_finish_marker($r);
        my ($rc1) = fire($r, stop());
        is($rc1, 0, 'AC10a: guard-subagent-stall.sh allows on the operator\'s touch (fired first)');
        my ($rc2) = fire_gate($GATE,
            { CCPRAXIS_DRIVE_ACTIVE_DIR => $active, BP_PROBE_PROC_DIR => proc_dir_none(),
              BP_PROBE_CLK_TCK => 100 }, stop());
        is($rc2, 0, 'AC10b: gate-drive-loop.sh ALSO allows on the SAME touch (fired second)');
    }

    # Order 2: gate-drive-loop.sh fires first, guard-subagent-stall.sh second.
    {
        my ($r, $active) = _ac10_setup();
        touch_finish_marker($r);
        my ($rc1) = fire_gate($GATE,
            { CCPRAXIS_DRIVE_ACTIVE_DIR => $active, BP_PROBE_PROC_DIR => proc_dir_none(),
              BP_PROBE_CLK_TCK => 100 }, stop());
        is($rc1, 0, 'AC10c: gate-drive-loop.sh allows on the operator\'s touch (fired first, reversed order)');
        my ($rc2) = fire($r, stop());
        is($rc2, 0, 'AC10d: guard-subagent-stall.sh ALSO allows on the SAME touch (fired second, reversed order)');
    }
}

# =========== PACKAGE 05 — DISPATCH-LOG CROSS-CHECK ON THE DENIAL (AC1-AC17) =
#
# Spec: 05-subagent-stall-guard-accuracy-spec.md. `_bp_outstanding_report`
# (spec §2.1) runs ONLY on the denial path, cross-checking the pending set
# against `bp-dispatch-log.pl outstanding` (package 01's own live/stale
# tracking) and rendering one of three sections (§2.2) below the existing
# `${PENDING:+...}` block, without ever changing the verdict (D-B).
#
# Fixtures write `<root>/.ccpraxis-local-data/.dispatch-log/<id>.json`
# directly (spec §5 point 8) rather than going through `bp-dispatch-log.pl
# start`'s write-guard/lock machinery.
sub write_dispatch_record {
    my ($root, $id, %f) = @_;
    my $dir = "$root/.ccpraxis-local-data/.dispatch-log";
    make_path($dir);
    my %rec = (
        id          => $id,
        worker_type => ($f{worker_type} // 'implementer'),
        status      => ($f{status} // 'running'),
    );
    $rec{started_at}     = $f{started_at}     if exists $f{started_at} && defined $f{started_at};
    $rec{budget_seconds} = $f{budget_seconds} if exists $f{budget_seconds} && defined $f{budget_seconds};
    for my $k (qw(blueprint package dispatch_key)) {
        $rec{$k} = $f{$k} if exists $f{$k} && defined $f{$k};
    }
    open my $fh, '>', "$dir/$id.json" or die "write record $id: $!";
    print {$fh} $J->encode(\%rec);
    close $fh;
    return "$dir/$id.json";
}
sub dispatch_log_dir { my ($r) = @_; return "$r/.ccpraxis-local-data/.dispatch-log" }

# A denial fixture: one background dispatch pending, probe forced NONE, no
# finish marker -> the Stop falls through to the DENIED path every time.
sub denial_root {
    my ($desc) = @_;
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, $desc // 'w05 worker'));
    return $r;
}
sub deny { my ($r) = @_; return fire_with_probe($r, stop(), proc_dir_none()) }

# An isolated copy of the hook + its companions, so a fixture can remove or
# replace scripts/bp-dispatch-log.pl WITHOUT touching the real write-set
# file. lib.sh and bp-watch.pl are self-contained (no further sourcing), so
# copying them verbatim reproduces the real hook's environment exactly.
# with_dispatch_log => 0 omits scripts/bp-dispatch-log.pl entirely (AC13,
# "script not readable"); with_dispatch_log => 'garbage' installs a stub
# that prints unparseable stdout (AC13, "output not understood").
sub isolated_guard {
    my (%opt) = @_;
    my $iso = tempdir(CLEANUP => 1);
    make_path("$iso/hooks", "$iso/scripts");
    copy("$HOOKS/lib.sh", "$iso/hooks/lib.sh") or die "copy lib.sh: $!";
    copy($GUARD, "$iso/hooks/guard-subagent-stall.sh") or die "copy guard: $!";
    copy("$SCRIPTS/bp-watch.pl", "$iso/scripts/bp-watch.pl") or die "copy bp-watch.pl: $!";
    if (!exists $opt{with_dispatch_log} || $opt{with_dispatch_log} eq 'real') {
        copy("$SCRIPTS/bp-dispatch-log.pl", "$iso/scripts/bp-dispatch-log.pl")
            or die "copy bp-dispatch-log.pl: $!";
        # ...and the sibling module it loads its project-root rule from.
        copy("$SCRIPTS/BpProjectRoot.pm", "$iso/scripts/BpProjectRoot.pm")
            or die "copy BpProjectRoot.pm: $!";
    }
    elsif ($opt{with_dispatch_log} eq 'garbage') {
        open my $fh, '>', "$iso/scripts/bp-dispatch-log.pl" or die $!;
        print {$fh} "#!/usr/bin/env perl\nprint \"not the expected output shape at all\\n\";\n";
        close $fh;
    }
    # 'absent' (or any other value): leave scripts/bp-dispatch-log.pl unwritten.
    return "$iso/hooks/guard-subagent-stall.sh";
}
sub fire_isolated {                       # like fire(), but against a given hook path
    my ($hook, $root, $payload, $procdir, $self_pid) = @_;
    local $ENV{BP_PROBE_PROC_DIR} = $procdir if defined $procdir;
    local $ENV{BP_PROBE_SELF_PID} = $self_pid if defined $self_pid;
    local $ENV{BP_PROBE_CLK_TCK}  = 100 if defined $procdir;
    my ($fh, $tmp) = File::Temp::tempfile('t112-iso-XXXXXX', TMPDIR => 1);
    print {$fh} $J->encode($payload); close $fh;
    my $err = "$tmp.err";
    my $rc  = system(qq{CLAUDE_PROJECT_DIR="$root" CCPRAXIS_DRIVE_ACTIVE_DIR="$root/.drive-active" bash "$hook" < "$tmp" 2> "$err"});
    my $se  = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
    unlink $tmp, $err;
    return ($rc >> 8, $se);
}

# ---- AC1/AC2 (B4, DC-1) — the most important behavioral claim: a STALE
# record still blocks; it is labelled, never treated as completion (D-D). ----
{
    my $r = denial_root('ac1 worker');
    write_dispatch_record($r, 'ac1-stale-dispatch',
        started_at => time() - 10000, budget_seconds => 60);
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC1: a stale running record still DENIES the stop (D-D)');
    like($err, qr/STALE/, 'AC1: ...stderr mentions STALE');
    like($err, qr/(?i:cannot.{0,4}be told apart|cannot.?tell)/,
        'AC1: ...and a "cannot tell apart from a dispatch that died" phrasing');
    like($err, qr/(?i:not evidence)/, 'AC1: ...and a "not evidence [it] finished" phrasing');
    like($err, qr/\bac1-stale-dispatch\b/, 'AC1: ...and the record\'s own id');

    # AC2 — the same fixture must not read as a completion claim, and staleness
    # alone must never be the thing that allows the stop.
    is($rc, 2, 'AC2: the stop is not allowed on staleness alone');
    unlike($err, qr/dispatch (?:is|was|has) (?:confirmed |verified )?finished/i,
        'AC2: stderr never claims the dispatch finished');
}

# ---- AC3 (B3, DC-2/DC-1) — a genuinely live, in-budget record still blocks,
# labelled LIVE, with no STALE sentence attached. ----
{
    my $r = denial_root('ac3 worker');
    write_dispatch_record($r, 'ac3-live-dispatch',
        started_at => time(), budget_seconds => 1800);
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC3: a live in-budget outstanding dispatch still DENIES, unchanged from today');
    like($err, qr/LIVE \(within 4x budget\)/, 'AC3: ...row labelled LIVE');
    like($err, qr/\bac3-live-dispatch\b/, 'AC3: ...and names the id');
    unlike($err, qr/STALE means past 4x its own budget/,
        'AC3: ...no STALE sentence when nothing is stale or unevaluable');
}

# ---- AC4/AC5 (B10, DC-2/DC-4) — zero-cost-on-allow-paths (D-A): the query
# runs NEVER on any allow path, live/cannot-tell/finish-marker/force-stop/
# empty-pending, even when outstanding records exist. ----
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac4 worker'));
    write_dispatch_record($r, 'ac4-record', started_at => time(), budget_seconds => 1800);
    my ($procdir, $self_pid) = proc_dir_live("$r/.ccpraxis-local-data");
    my ($rc, $err) = fire_with_probe($r, stop(), $procdir, $self_pid);
    is($rc, 0, 'AC4: probe LIVE (verdict 0) allows even with outstanding dispatch-log records');
    unlike($err, qr/Dispatch log/, 'AC4: ...and stderr contains no Dispatch log text at all');
}
{
    # AC5a — probe cannot-tell (verdict 2).
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac5a worker'));
    write_dispatch_record($r, 'ac5a-record', started_at => time(), budget_seconds => 1800);
    my ($rc, $err) = fire_with_probe($r, stop(), proc_dir_cannot_tell());
    is($rc, 0, 'AC5a: probe cannot-tell (2) allows with outstanding records present');
    unlike($err, qr/Dispatch log/, 'AC5a: ...no Dispatch log text');
}
{
    # AC5b — operator .run-finished marker.
    #
    # review NIT-6(b): this fixture must be attributable to the finish-marker
    # signal it claims to exercise, not to the earlier "third exit" branch
    # (bp_outstanding_work) firing first -- which it does today only because
    # this repo's own blueprint state happens to have a non-terminal package
    # when cwd is the repo. CCPRAXIS_STALL_SKIP_IDLE_EXIT=1 disables that
    # earlier exit for this fixture so the assertion holds regardless of
    # repo state.
    local $ENV{CCPRAXIS_STALL_SKIP_IDLE_EXIT} = 1;
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac5b worker'));
    write_dispatch_record($r, 'ac5b-record', started_at => time(), budget_seconds => 1800);
    touch_finish_marker($r);
    my ($rc, $err) = fire($r, stop());
    is($rc, 0, 'AC5b: the operator finish marker allows with outstanding records present');
    unlike($err, qr/Dispatch log/, 'AC5b: ...no Dispatch log text');
}
{
    # AC5c — one-shot force-stop marker.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ac5c worker'));
    write_dispatch_record($r, 'ac5c-record', started_at => time(), budget_seconds => 1800);
    my $d = "$r/.ccpraxis-local-data/.subagent-guard";
    make_path($d);
    open my $f, '>', "$d/force-stop" or die $!; close $f;
    my ($rc, $err) = fire($r, stop());
    is($rc, 0, 'AC5c: force-stop allows with outstanding records present');
    unlike($err, qr/Dispatch log/, 'AC5c: ...no Dispatch log text');
}
{
    # AC5d — empty pending set (INERT).
    my $r = newroot();
    write_dispatch_record($r, 'ac5d-record', started_at => time(), budget_seconds => 1800);
    my ($rc, $err) = fire($r, stop());
    is($rc, 0, 'AC5d: an empty pending set allows (INERT) with outstanding records present');
    unlike($err, qr/Dispatch log/, 'AC5d: ...no Dispatch log text');
}

# ---- AC6 (B1,B3,B11, DC-3) — every DENIAL carries a Dispatch log section, in
# addition to the existing BLOCKED text. ----
{
    # B1: store absent entirely -> section (a).
    my $r = denial_root('ac6a worker');
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC6a fixture: denied with no dispatch-log store at all');
    like($err, qr/BLOCKED/, 'AC6a: ...still contains BLOCKED');
    like($err, qr/Dispatch log/, 'AC6a: ...and a Dispatch log section');

    # B3: one live record -> section (b).
    my $r2 = denial_root('ac6b worker');
    write_dispatch_record($r2, 'ac6b-record', started_at => time(), budget_seconds => 1800);
    my ($rc2, $err2) = deny($r2);
    is($rc2, 2, 'AC6b fixture: denied with one live record');
    like($err2, qr/BLOCKED/, 'AC6b: ...still contains BLOCKED');
    like($err2, qr/Dispatch log/, 'AC6b: ...and a Dispatch log section');

    # B11: store path is a plain file -> unreadable -> section (c).
    my $r3 = denial_root('ac6c worker');
    make_path("$r3/.ccpraxis-local-data");
    open my $fh, '>', dispatch_log_dir($r3) or die $!; print {$fh} 'x'; close $fh;
    my ($rc3, $err3) = deny($r3);
    is($rc3, 2, 'AC6c fixture: denied with an unreadable dispatch-log store');
    like($err3, qr/BLOCKED/, 'AC6c: ...still contains BLOCKED');
    like($err3, qr/Dispatch log/, 'AC6c: ...and a Dispatch log section');
}

# ---- AC7 (B3,B4,B6, DC-3) — every rendered row names its own record id. ----
{
    my $r = denial_root('ac7 worker');
    write_dispatch_record($r, 'ac7-live', started_at => time(), budget_seconds => 1800);
    write_dispatch_record($r, 'ac7-stale', started_at => time() - 10000, budget_seconds => 60);
    my (undef, $err) = deny($r);
    like($err, qr/\bac7-live\b/, 'AC7: the live row names its own id');
    like($err, qr/\bac7-stale\b/, 'AC7: the stale row names its own id');
}

# ---- AC8 (B1,B7, DC-3/DC-2) — 0 outstanding records: says so, and says it is
# NOT a resolution; still denied. Covers both "no store" (B1) and "records
# exist but all finished" (B7). ----
{
    my $r = denial_root('ac8a worker');
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC8a: no dispatch-log store at all is still denied');
    like($err, qr/0 records outstanding/, 'AC8a: ...stderr says 0 outstanding');
    like($err, qr/NOT a resolution/, 'AC8a: ...and that this is NOT a resolution');
}
{
    my $r = denial_root('ac8b worker');
    write_dispatch_record($r, 'ac8b-finished', status => 'finished', started_at => time());
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC8b: a record that exists but is not status=running is still denied');
    like($err, qr/0 records outstanding/, 'AC8b: ...stderr says 0 outstanding (finished records do not count)');
    like($err, qr/NOT a resolution/, 'AC8b: ...and that this is NOT a resolution');
}

# ---- AC9 (B6, DC-1/DC-3) — mixed live+stale: both labels, correct counts. --
{
    my $r = denial_root('ac9 worker');
    write_dispatch_record($r, 'ac9-live', started_at => time(), budget_seconds => 1800);
    write_dispatch_record($r, 'ac9-stale', started_at => time() - 10000, budget_seconds => 60);
    my (undef, $err) = deny($r);
    like($err, qr/LIVE \(within 4x budget\)/, 'AC9: the live row is labelled LIVE');
    like($err, qr/STALE \(cannot tell if alive\)/, 'AC9: the stale row is labelled STALE');
    like($err, qr/2 outstanding \(1 live, 1 stale, 0 unevaluable, 0 unreadable\)/,
        'AC9: the header counts read 1 live, 1 stale');
}

# ---- AC10 (B8, DC-3) — blueprint/package render '-' when absent, and their
# real values when present; and (D-C, §3 B8's second sentence) a record from
# an UNRELATED blueprint is still listed -- the query is unfiltered. ----
{
    my $r = denial_root('ac10 worker');
    write_dispatch_record($r, 'ac10-bare', started_at => time(), budget_seconds => 1800);
    write_dispatch_record($r, 'ac10-attributed', started_at => time(), budget_seconds => 1800,
        blueprint => 'coordinator-context-discipline', package => '05-subagent-stall-guard-accuracy');
    write_dispatch_record($r, 'ac10-unrelated', started_at => time(), budget_seconds => 1800,
        blueprint => 'some-other-blueprint-entirely', package => 'zz-unrelated-package');
    my (undef, $err) = deny($r);
    like($err, qr/id=ac10-bare\s+worker_type=\S+\s+blueprint=-\s+package=-/,
        'AC10a: a record with no blueprint/package renders "-" for both');
    like($err,
        qr/id=ac10-attributed\s+worker_type=\S+\s+blueprint=coordinator-context-discipline\s+package=05-subagent-stall-guard-accuracy/,
        'AC10b: a record WITH blueprint/package renders the real values');
    like($err, qr/\bac10-unrelated\b/,
        'AC10c (D-C): a record from an unrelated blueprint is still listed -- the query is unfiltered');
}

# ---- AC11 (B9, DC-3) — >=6 outstanding records: exactly 5 rows rendered,
# oldest first, plus a "+K more" overflow line with the right K. ----
{
    my $r = denial_root('ac11 worker');
    my $now = time();
    for my $i (1 .. 7) {
        write_dispatch_record($r, "ac11-rec-$i",
            started_at => $now - (7 - $i), budget_seconds => 1800);
    }
    my (undef, $err) = deny($r);
    my @ids_in_order = ($err =~ /\bid=(ac11-rec-\d)\b/g);
    is(scalar(@ids_in_order), 5, 'AC11: exactly 5 rows are rendered out of 7 outstanding records');
    is_deeply(\@ids_in_order, ['ac11-rec-1', 'ac11-rec-2', 'ac11-rec-3', 'ac11-rec-4', 'ac11-rec-5'],
        'AC11: ...oldest-first, by started_at');
    like($err, qr/\(\+2 more/, 'AC11: ...followed by a "+2 more" overflow line');
}

# ---- AC12 (B5, DC-1) — a record with no usable start time renders
# UNEVALUABLE and elapsed_seconds=unknown. ----
{
    my $r = denial_root('ac12 worker');
    write_dispatch_record($r, 'ac12-record', budget_seconds => 1800);  # started_at omitted
    my (undef, $err) = deny($r);
    like($err, qr/UNEVALUABLE \(no usable start time\)/, 'AC12: the row is labelled UNEVALUABLE');
    like($err, qr/id=ac12-record\b.*elapsed_seconds=unknown/,
        'AC12: ...and elapsed_seconds reads "unknown"');
}

# ---- AC13 (B11, DC-4) — every unavailable-script/unparseable-output path
# degrades gracefully: exit stays 2, "cross-check unavailable" + a reason,
# and the full existing BLOCKED text survives. ----
{
    # (i) the dispatch-log store path is a plain file (already covered as
    # AC6c's fixture; re-asserted here under its own AC number for the
    # "unavailable" wording specifically).
    my $r = denial_root('ac13a worker');
    make_path("$r/.ccpraxis-local-data");
    open my $fh, '>', dispatch_log_dir($r) or die $!; print {$fh} 'x'; close $fh;
    my ($rc, $err) = deny($r);
    is($rc, 2, 'AC13a: an unreadable dispatch-log store still DENIES (exit 2)');
    like($err, qr/cross-check unavailable/, 'AC13a: ...stderr says cross-check unavailable');
    like($err, qr/BLOCKED/, 'AC13a: ...and the full BLOCKED denial text survives');
    like($err, qr/\.run-finished/, 'AC13a: ...including the operator remedy');
    like($err, qr/force-stop/i, 'AC13a: ...and the force-stop lever');

    # (ii) scripts/bp-dispatch-log.pl is entirely absent (an isolated hook
    # copy, per spec §2.1 point 1: "not readable" -> unavailable section).
    my $hook_no_script = isolated_guard(with_dispatch_log => 'absent');
    my $r2 = newroot();
    fire_isolated($hook_no_script, $r2, dispatch(JSON::PP::true, 'ac13b worker'));
    my ($rc2, $err2) = fire_isolated($hook_no_script, $r2, stop(), proc_dir_none());
    is($rc2, 2, 'AC13b: bp-dispatch-log.pl absent still DENIES (exit 2)');
    like($err2, qr/cross-check unavailable/, 'AC13b: ...stderr says cross-check unavailable');
    like($err2, qr/BLOCKED/, 'AC13b: ...and the full BLOCKED denial text survives');

    # (iii) bp-dispatch-log.pl exists but its stdout is not the expected
    # "outstanding_count: <digits>" shape (spec §2.1 point 3: unparseable
    # output -> unavailable section).
    my $hook_garbage = isolated_guard(with_dispatch_log => 'garbage');
    my $r3 = newroot();
    fire_isolated($hook_garbage, $r3, dispatch(JSON::PP::true, 'ac13c worker'));
    my ($rc3, $err3) = fire_isolated($hook_garbage, $r3, stop(), proc_dir_none());
    is($rc3, 2, 'AC13c: unparseable bp-dispatch-log.pl output still DENIES (exit 2)');
    like($err3, qr/cross-check unavailable/, 'AC13c: ...stderr says cross-check unavailable');
    like($err3, qr/BLOCKED/, 'AC13c: ...and the full BLOCKED denial text survives');
}

# ---- AC14 (B2, DC-4) — the dispatch-log store directory does not exist
# before a denial, and still does not exist after it (no side-effect create).
{
    my $r = denial_root('ac14 worker');
    ok(!-e dispatch_log_dir($r), 'AC14 precondition: the dispatch-log store does not exist yet');
    my ($rc) = deny($r);
    is($rc, 2, 'AC14 fixture: the stop is denied');
    ok(!-e dispatch_log_dir($r),
        'AC14: the dispatch-log store STILL does not exist after the denial -- a query is not a write');
}

# ---- AC15 (B12, DC-4) — the pending set file is byte-identical after a
# denial that ran the cross-check. ----
{
    my $r = denial_root('ac15 worker');
    write_dispatch_record($r, 'ac15-record', started_at => time(), budget_seconds => 1800);
    my $state = "$r/.ccpraxis-local-data/.subagent-guard/sess-t112";
    my $before = do { open my $f, '<', $state or die $!; local $/; <$f> };
    my ($rc) = deny($r);
    is($rc, 2, 'AC15 fixture: the stop is denied');
    my $after = do { open my $f, '<', $state or die $!; local $/; <$f> };
    is($after, $before, 'AC15: the pending set file is byte-identical before and after the denial');
}

# ---- AC17 (B13, DC-4) — no bp-runstate.pl reference is reintroduced, and no
# new persisted state-machine file is created by the cross-check. ----
{
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    unlike($code, qr/bp-runstate\.pl/,
        'AC17a: bp-runstate.pl still appears nowhere in the executable part of the hook');

    my $r = denial_root('ac17 worker');
    write_dispatch_record($r, 'ac17-record', started_at => time(), budget_seconds => 1800);
    deny($r);
    ok(!-e "$r/.ccpraxis-local-data/.subagent-guard/run-state.json",
        'AC17b: no run-state.json (or equivalent persisted state-machine file) is created');
    my @after_dispatch = sort glob(dispatch_log_dir($r) . '/*');
    is_deeply(\@after_dispatch, [dispatch_log_dir($r) . '/ac17-record.json'],
        'AC17c: the cross-check creates no new dispatch-log record of its own');
}

# =========== FIX-BATCH 05 ADDITIVE — accuracy fix-batch regression guards ===
#
# Spec §7 DRIVER AMENDMENT / consolidated review+redteam findings. These three
# fixtures are NEW (additive only, per the fix-batch's authorization) and do
# not touch any assertion above.

# ---- SHOULD-1 regression guard: an unreadable *.json record must not
# silently suppress the STALE explanatory sentence, and its header count
# lands in unreadable_count (not stale/unevaluable). ----
{
    my $r = denial_root('fb-unreadable worker');
    my $dir = dispatch_log_dir($r);
    make_path($dir);
    open my $fh, '>', "$dir/broken.json" or die $!;
    print {$fh} "x\n";
    close $fh;
    my ($rc, $err) = deny($r);
    is($rc, 2, 'fix-batch: an unreadable *.json record still DENIES');
    like($err, qr/1 outstanding \(0 live, 0 stale, 0 unevaluable, 1 unreadable\)/,
        'fix-batch: the header counts the broken record as unreadable, not stale/unevaluable');
    like($err, qr/UNEVALUABLE \(no usable start time\)/,
        "fix-batch: the row itself still renders UNEVALUABLE (the verb's own label for stale=unknown)");
    like($err, qr/STALE means past 4x its own budget/,
        'fix-batch (SHOULD-1): the STALE sentence still appears for an unreadable-only record -- '
      . 'the sentence gate now reads unreadable_count too, not just stale/unevaluable');
}

# ---- Items 1 and 6 together: a >=6-record fixture where the ONLY stale
# record sorts past the 5-row cutoff. The STALE sentence must still appear
# (proving the sentence gate reads the header counts, not the rendered
# rows), and the overflow "+K more" must reflect the true header-derived
# remainder even though the stale row itself is never rendered. ----
{
    my $r = denial_root('fb-cutoff worker');
    my $now = time();
    for my $i (1 .. 5) {
        write_dispatch_record($r, "fb-cutoff-live-$i",
            started_at => $now - (6000 - $i * 100), budget_seconds => 100000);
    }
    # The 6th record has the LARGEST (most recent) started_at of the six, so
    # it sorts LAST -- past the 5-row cutoff -- yet it is the only
    # stale/unevaluable one (tiny budget_seconds).
    write_dispatch_record($r, 'fb-cutoff-stale',
        started_at => $now - 500, budget_seconds => 10);
    my (undef, $err) = deny($r);
    unlike($err, qr/\bfb-cutoff-stale\b/,
        'fix-batch: the stale record past the cutoff is NOT among the 5 rendered rows');
    like($err, qr/6 outstanding \(5 live, 1 stale, 0 unevaluable, 0 unreadable\)/,
        'fix-batch: ...the header counts are correct regardless');
    like($err, qr/STALE means past 4x its own budget/,
        'fix-batch (items 1+6): ...yet the STALE sentence still appears -- the gate reads the '
      . 'header counts, not the rendered rows');
    like($err, qr/\(\+1 more/,
        'fix-batch (item 1): ...and the overflow "+1 more" reflects the true header-derived '
      . 'remainder, not a count of rendered/parsed rows');
}

# ---- CRITICAL-1 regression guard: an oversized worker_type field must not
# make the hook slow -- the capture cap engages, and the denial still
# completes in low single digits of seconds (scaled down from redteam's
# 10.2MB/68.2s repro; a few hundred KB is enough to prove the mechanism at
# test speed). ----
{
    my $r = denial_root('fb-oversized worker');
    write_dispatch_record($r, 'fb-oversized-record',
        worker_type => ('x' x 300_000), started_at => time(), budget_seconds => 1800);
    my $t0 = time();
    my ($rc, $err) = deny($r);
    my $elapsed = time() - $t0;
    is($rc, 2, 'fix-batch (CRITICAL-1): an oversized worker_type field still DENIES');
    ok($elapsed < 5,
        "fix-batch (CRITICAL-1): ...and completes in ${elapsed}s, well under the 10s query bound -- "
      . 'the capture cap engages rather than the bash-side parse scaling with input size');
}

done_testing();
