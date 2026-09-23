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
use JSON::PP;

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD = "$HOOKS/guard-subagent-stall.sh";

ok(-f $GUARD, 'guard-subagent-stall.sh exists') or BAIL_OUT('hook missing');
ok(-x $GUARD, 'guard-subagent-stall.sh is executable');

my $J = JSON::PP->new->canonical;

sub fire {                    # feed a payload to the hook -> (exit, stderr)
    my ($root, $payload) = @_;
    my ($fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
    print {$fh} $J->encode($payload); close $fh;
    my $err = "$tmp.err";
    my $rc  = system(qq{CLAUDE_PROJECT_DIR="$root" bash "$GUARD" < "$tmp" 2> "$err"});
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
sub newroot { my $r = tempdir(CLEANUP => 1); mkdir "$r/.ccpraxis-local-data"; return $r }

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
        my $rcx = system(qq{CLAUDE_PROJECT_DIR="$r" bash "$GUARD" --finish < "$tmp" >/dev/null 2>&1});
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

done_testing();
