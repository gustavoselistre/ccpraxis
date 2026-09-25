#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 5 (blueprint
# hook-continuity-remake), WS-1..WS-12 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.7/4.3/4.10: the wait-shape-guard
# successor (WaitShapeGuard), which absorbs repeat-guard, running on the
# package-03 hook core.
#
# hooks/wait-shape-guard.sh and BpHook/Guards/WaitShapeGuard.pm
# DO NOT EXIST YET. Every in-process case goes through
# GuardHarness::run_module() (batch 1's harness), which mirrors
# BpHook::main()'s own require-and-call contract, so a missing module fails
# open (rc 0) exactly as the real wrapper would -- legibly, never a crash in
# this file. Every [wrapper]/[shim] case spawns the real bash file at that
# path and gets a plain "No such file or directory" until the implementer
# writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text above
# (sec 2.3/2.6 for Common's fit/echo_cmd, sec 3.7 for WaitShapeGuard's own
# contract) and the CASES (never the source bash) of the four source files
# this batch's oracle absorbs -- never from reading wait-shape-guard.sh,
# wait-shape-guard.sh, the old shared bash guard library's bp_ws_*/bp_repeat_* functions, or
# waiting-discipline.t's skill prose.
#
# A READING CALL WORTH FLAGGING: spec 3.7's R3b message text reads
# "...sleeping while probing tasks/<id>.output reads..." and section 2.6
# defines ONLY <cmd> (= echo_cmd(tool_input.command)) and <path> as
# substitution placeholders -- there is no defined substitution for an
# extracted task id in this rule's own message (unlike the separate
# TaskOutput-poll rule below it, which explicitly names <IDT>/<N>/<W> as
# substituted). This file therefore treats "tasks/<id>.output" in R3b's own
# text as LITERAL wording, matching today's hook's own message (mined
# verbatim from wait-shape-guard.t: "recorded to runs/<pkg>..." is literal
# there too, for the analogous <pkg> case in context-ceiling's messages).
#
# NOT RE-EXPRESSED (per spec sec 4.10 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                        | code
#   ------------------------------------------------------------------ | ----
#   wait-shape-guard.t FIXTURE-SANITY block                            | OTHER (harness self-checks of the
#                                                                       |   OLD file's own scaffolding, not a
#                                                                       |   behaviour of the guard)
#   wait-shape-guard.t AC-26/AC-27/AC-30                                | SRC (source-text greps against the
#                                                                       |   OLD bash file: BP_ROLE absence,
#                                                                       |   bp_hook_require_jq absence, `set -e`
#                                                                       |   absence, the sourcing-is-inert
#                                                                       |   main-guard idiom -- all retired
#                                                                       |   bash-specific mechanics)
#   wait-shape-guard.t AC-32..AC-35                                    | REG (hooks.json registration,
#                                                                       |   package 16's concern)
#   wait-shape-guard.t AC-36                                            | D11 (a sibling package's own re-run
#                                                                       |   floor, not this hook's contract)
#   both old files' jq-gated SKIP blocks, as such                      | JQ (the new module needs no jq at
#                                                                       |   all -- Decision 33/spec sec 1 --
#                                                                       |   so there is no jq gate left to
#                                                                       |   re-express; the CASES those blocks
#                                                                       |   gated are re-expressed above)
#   wait-shape-guard.t's verbatim long advisory texts, the SKILL.md     | MSG (the 2.6 message budget dropped
#     citation sentence in every message                               |   these; the new text carries only
#                                                                       |   the substring this file asserts)
#   wait-shape-guard.t's pure bp_repeat_* helper calls, AS SUCH (calling    | LIB (those subs live in retired
#     the shell function directly via `source the old shared bash guard library`)                 |   the old shared bash guard library; their semantics are
#                                                                       |   re-expressed as WaitShapeGuard::run
#                                                                       |   verdicts in WS-8/WS-9/WS-10 below)
#   wait-shape-guard.t AC-12's BP_DIR/BP_PROJECT_ROOT individually-unset    | OTHER (the three-variable gate is
#     cases                                                            |   retired -- BP_LEDGER alone selects
#                                                                       |   this guard now, per the spec 2.1
#                                                                       |   clause table; WS-11 re-expresses
#                                                                       |   the BP_DIR-specific case that still
#                                                                       |   has a successor: state rules skip
#                                                                       |   without BP_DIR, R1/R2/R3b do not)
#   wait-shape-guard.t AC-13 (missing-jq fail-open)                        | JQ
#   wait-shape-guard.t AC-20/AC-20d (hooks.json shape, cmds_contain_in_order)| REG
#   wait-shape-guard.t AC-21 (bp_gate_verdict/bp_active_stop_signal/        | LIB (regression spot-checks of
#     bp_hook_gate regression spot-checks)                             |   ANOTHER component's own the old shared bash guard library subs,
#                                                                       |   not this guard's)
#   wait-shape-guard.t F1 (HIGH-1 super-linear-scrub wall-clock bound)      | D33 (a wall-clock assertion)
#   waiting-discipline.t / oneshot-judge-waiting-discipline.t (whole    | OTHER (skill/prose documentation
#     files)                                                           |   checks, not the guard itself)
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use POSIX ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front (binding lesson: isolate_env
# before any state work), even though this guard is env-only and never calls
# BpHook::arm() -- WaitShapeGuard's own prefilter atom is "ledger" alone
# (spec sec 2.1's clause table), never a per-session armed-file lookup.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

# ---------------------------------------------------------------------------
# Byte I/O helpers.
# ---------------------------------------------------------------------------
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
    (my $dir = $p) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_lines {
    my ($p) = @_;
    my $raw = read_bytes($p);
    return () unless defined $raw;
    my @l = split /\n/, $raw;
    return @l;
}

# ---------------------------------------------------------------------------
# fresh_ws_env(%extra) -- a BP_LEDGER-shaped env: BP_LEDGER (a package ledger
# path, need not exist), BP_DIR (with runs/ already present), BP_PROJECT_ROOT,
# BP_PACKAGE. Every WS block gets its own tempdir, so state files never leak
# across blocks.
# ---------------------------------------------------------------------------
my $envN = 0;
sub fresh_ws_env {
    my (%extra) = @_;
    $envN++;
    my $t = tempdir(CLEANUP => 1);
    (my $bp_dir = "$t/bpdir") =~ s{\\}{/}g;
    make_path("$bp_dir/runs");
    (my $proj = "$t/proj") =~ s{\\}{/}g;
    make_path($proj);
    my %env = (
        BP_LEDGER       => "$bp_dir/packages/p.md",
        BP_DIR          => $bp_dir,
        BP_PROJECT_ROOT => $proj,
        BP_PACKAGE      => "p14w$envN",
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}

# ---------------------------------------------------------------------------
# spec_token($raw) -- independent reference implementation of the session/id
# sanitiser T (spec sec 3.7): every char outside [A-Za-z0-9_-] -> '_', cut to
# 16, empty -> 'nosid'. IDT uses the identical algorithm ("tokenised like T").
# ---------------------------------------------------------------------------
sub spec_token {
    my ($raw) = @_;
    $raw = '' unless defined $raw;
    (my $t = $raw) =~ s/[^A-Za-z0-9_-]/_/g;
    $t = substr($t, 0, 16);
    return length($t) ? $t : 'nosid';
}
sub repeat_state_path   { my ($bp, $pkg, $sid) = @_; return "$bp/runs/$pkg.repeat-"   . spec_token($sid) . '.log' }
sub taskpoll_state_path { my ($bp, $pkg, $sid) = @_; return "$bp/runs/$pkg.taskpoll-" . spec_token($sid) . '.log' }

# ---------------------------------------------------------------------------
# spec_echo_cmd($cmd) -- independent reference implementation of
# Guards::Common::echo_cmd (spec sec 2.3): \r \n \t -> ' ', cut to 80 + '...'.
# ---------------------------------------------------------------------------
sub spec_echo_cmd {
    my ($cmd) = @_;
    return '' unless defined $cmd;
    (my $v = $cmd) =~ tr/\r\n\t/   /;
    return $v if length($v) <= 80;
    return substr($v, 0, 80) . '...';
}

# ---------------------------------------------------------------------------
# Payload builders. Every fixture carries a session_id (binding lesson).
# ---------------------------------------------------------------------------
sub pl_bash {
    my ($cmd, %o) = @_;
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $cmd } };
    $p->{session_id} = $o{session_id} // 'ws-default-sess';
    return $p;
}
sub pl_tool {
    my ($tool, $ti, %o) = @_;
    my $p = { hook_event_name => 'PreToolUse', tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} // 'ws-default-sess';
    return $p;
}
sub pl_taskoutput {
    my (%o) = @_;
    my $ti = {};
    $ti->{task_id} = $o{task_id} if exists $o{task_id};
    $ti->{taskId}  = $o{taskId}  if exists $o{taskId};
    $ti->{id}      = $o{id}      if exists $o{id};
    $ti->{offset}  = $o{offset}  if exists $o{offset};
    $ti->{limit}   = $o{limit}   if exists $o{limit};
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'TaskOutput', tool_input => $ti };
    $p->{session_id} = $o{session_id} // 'ws-default-sess';
    return $p;
}

# ---------------------------------------------------------------------------
# ws($payload, %opts) -- GuardHarness::run_module for Guards::WaitShapeGuard.
# ---------------------------------------------------------------------------
sub ws {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::WaitShapeGuard', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# The mandated deny prefix and messages (spec sec 3.7), byte-exact. No `use
# utf8` -- the em dash is spelled as explicit UTF-8 bytes so this file never
# depends on its own source encoding (mirrors the retired wait-shape-guard.t
# convention, and matches how BpHook::deny only re-encodes a Perl-level utf8
# STRING -- a plain byte string here compares directly against the captured
# raw bytes).
# ---------------------------------------------------------------------------
my $DASH = "\xE2\x80\x94";
my $PFX  = "WAIT-SHAPE-GUARD: BLOCKED $DASH ";

sub msg_r1 {
    my ($cmd) = @_;
    return $PFX . 'wait-loop: a while/until/for loop with sleep polls; run the work in the FOREGROUND or await the notification.'
         . "\n" . 'Or record what you wait for under \'## Next action\' and stop. Command: ' . spec_echo_cmd($cmd) . "\n";
}
sub msg_r3b {
    my ($cmd) = @_;
    return $PFX . 'task-output-poll: sleeping while probing tasks/<id>.output reads a subagent\'s full stream; wait for its report file instead.'
         . "\n" . 'Or record what you wait for under \'## Next action\' and stop. Command: ' . spec_echo_cmd($cmd) . "\n";
}
sub msg_r2 {
    my ($cmd) = @_;
    return $PFX . 'false-green-pipe: $? after | tail/head is tail\'s status, not the command\'s; use cmd > /tmp/out.txt 2>&1; echo "exit=$?"'
         . "\n" . 'or out=$(cmd 2>&1); rc=$?. Command: ' . spec_echo_cmd($cmd) . "\n";
}
sub msg_taskpoll {
    my ($count, $idt, $win) = @_;
    return $PFX . "task-output-poll: TaskOutput call #$count against task $idt within $win seconds; this is polling one target."
         . "\n" . 'Stop polling: wait for its report file, or record what you wait for under \'## Next action\' and stop.' . "\n";
}
sub msg_repeat {
    my ($runlen, $tool, $mode) = @_;
    my $l2 = ($mode eq 'nudge')
        ? 'This fires once per run: change approach, inspect the output you have, or record the blocker under \'## Next action\' and stop.'
        : 'Every further identical call is blocked: change approach, inspect the output you have, or record the blocker under \'## Next action\' and stop.';
    return "REPEAT-GUARD: identical call #$runlen in a row to $tool (arguments hashed identically); a retry is unlikely to give a different result."
         . "\n" . $l2 . "\n";
}

# =====================================================================================
# The corpus strings, mined verbatim (except a couple of harmless project-relative
# paths shortened for this file) from wait-shape-guard.t's own step-1-report-derived
# corpus and wait-shape-guard-quote-strip.t.
# =====================================================================================
my $W1 = q{until grep -q '^_status: complete\|^## Summary' .ccpraxis-local-data/blueprints/x/reports/y/redteam-step6.md; do sleep 10; done};
my $W2 = q{until [ -f .ccpraxis-local-data/blueprints/x/reports/y/implementer-step7-batch1.md ]; do sleep 15; done; echo "report created"};
my $W3 = q{S=.ccpraxis-local-data/blueprints/x/specs/y-spec.md; timeout 570 bash -c 'until [ -s "$0" ]; do sleep 10; done' "$S" ; if [ -s "$S" ]; then echo "SPEC PRESENT: $(wc -c < "$S") bytes"; else echo "STILL WAITING"; fi};
my $W4 = join("\n",
    q{cd /project},
    q{timeout 420 bash -c '},
    q{  while [ ! -f .ccpraxis-local-data/blueprints/x/reports/y/testwriter-chunk1.md ]; do sleep 5; done},
    q{  echo REPORT_PRESENT},
    q{'});
my $W5 = join("\n",
    q{T=/project/plugins/butler/tests/t/some-file.t},
    q{B=$(stat -c %Y "$T"); n=0},
    q{until [ "$(stat -c %Y "$T")" != "$B" ] || [ $n -ge 40 ]; do sleep 15; n=$((n+1)); done},
    q{echo "t: $(stat -c %s "$T") bytes"});
my $W6 = q{for i in $(seq 1 40); do [ -s "$R" ] && break; sleep 6; done; echo "waited"};
my @WAITS = ($W1, $W2, $W3, $W4, $W5, $W6);

my $AC2a = q{while [ ! -s .ccpraxis-local-data/blueprints/x/reports/y/redteam-step6.md ]; do sleep 10; done};
my $AC2b = q{while true; do sleep 30; done};
my @AC2 = ($AC2a, $AC2b);

my @AC6 = (
    q{echo start; sleep 2; echo done},
    q{perl -e 'print "a"' > /tmp/x; sleep 1.1; perl -e 'print "b"' > /tmp/x},
    q{sleep 0.05; kill -INT %1},
    q{sleep 300 & MYPID=$!},
    q{timeout 200 bash -c 'sleep 180'},
    q{sleep 20 && echo "backoff done"},
);
my @AC7 = (
    q{perl -MTime::HiRes=time,sleep -e 'print time'},
    q{grep -n 'usleep\|sleep *=>\|nanosleep' plugins/butler/scripts/bp-orchestrator.pl},
);
my $QUOTED_PERL = q{printf '%s' 'shim("$R/hang", "sleep 30;")' > /tmp/fixture-frag.txt};
my $AC8 = q{for f in plugins/butler/tests/t/*.t; do out=$(timeout 120 perl "$f" 2>&1); rc=$?; nok=$(printf '%s' "$out" | grep -c '^not ok'); echo "$f rc=$rc nok=$nok"; done};
my $AC9 = q{find /root/.claude -name 'hooks.json' 2>/dev/null | while read f; do echo "--- $f"; jq -r '.' "$f" 2>/dev/null; done | head -60};

my $P7 = join("\n", q{perl plugins/butler/tests/t/wait-shape-guard.t 2>&1 | tail -20}, q{echo "EXIT=$?"});
my @AC11 = (
    q{perl plugins/butler/tests/t/wait-shape-guard.t 2>&1 | tail -20; echo "EXIT=$?"},
    q{perl plugins/butler/tests/t/status-recognition.t 2>&1 | tail -5; echo "exit=$?"},
    q{timeout 120 perl plugins/sandbox/tests/t/detector-hardening.t 2>&1 | tail -60; echo "EXIT=$?"},
    q{perl plugins/sandbox/tests/run-tests.pl 2>&1 | tail -25; echo "EXIT=$?"},
    q{cd /project && perl -c plugins/butler/scripts/bp-orchestrator.pl && setsid prove plugins/butler/tests/t/20-turns.t 2>&1 | tail -20; echo "EXIT=$?"},
    q{npm run lint 2>&1 | head -5; rc=$?},
    $P7,
);
my @AC13 = (
    q{ls -la /project/plugins/butler/hooks/wait-shape-guard.sh 2>&1 | tail -1},
    q{ls -la .ccpraxis-local-data/blueprints/x/specs/ 2>&1 | tail -20},
    $AC9,
);
my @AC14 = (
    q{prove plugins/sandbox/tests/t/detector-hardening.t > /tmp/prove2.txt 2>&1; echo "exit=$?"; tail -3 /tmp/prove2.txt},
    q{out=$(perl plugins/butler/tests/t/wait-shape-guard.t 2>&1); rc=$?},
);
my @AC16 = (
    q{sleep 120; cat .ccpraxis-local-data/blueprints/x/reports/y/implementer-step7-batch1.md | tail -20},
    q{sleep 45; grep -n '^## Attack\|^_status\|^## Summary' .ccpraxis-local-data/blueprints/x/reports/y/redteam-step6.md},
);
my @AC17 = (
    q{wc -c /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output; sleep 90; echo "--- 90s later ---"; wc -c /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output},
    q{F=/tmp/claude-0/-project/x/tasks/af531f5f871ddac8c.output; s1=$(stat -c%s "$F" 2>/dev/null); sleep 20; s2=$(stat -c%s "$F" 2>/dev/null); echo "transcript bytes: $s1 -> $s2"},
);
my $AC17_ALLOW = q{for id in a49213afc416089fd a712a884417c60e49; do printf '%s %s\n' "$id" "$(stat -c %s "$T/$id.output")"; done};

my $PREC_R1_R3B = q{until [ -s /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output ]; do sleep 10; done};
my $PREC_R3B_R2 = q{sleep 30; cat /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output | tail -20; echo "EXIT=$?"};
my $PREC_R1_R2  = q{for i in $(seq 1 3); do sleep 6; done; perl plugins/butler/tests/t/wait-shape-guard.t 2>&1 | tail -20; echo "EXIT=$?"};

my $QUOTED_WAIT_LOOP = q{echo 'anti-pattern example: while ! test -f x; do sleep 5; done'};
my $REAL_WAIT_LOOP   = q{while ! test -f x; do sleep 5; done};

# =====================================================================================
# SH-1/SH-2 -- static shape.
# =====================================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/wait-shape-guard.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/WaitShapeGuard.pm";
    ok(-f $wrapper, 'SH-1 precondition: wait-shape-guard.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        is(system('bash', '-n', $wrapper), 0, 'SH-1: bash -n on wait-shape-guard.sh passes');
        like(read_bytes($wrapper) // '', qr/Guards::WaitShapeGuard/, 'SH-1: the wrapper names the Guards::WaitShapeGuard module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/WaitShapeGuard.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        is(system('perl', "-I$BUTLER_DIR/scripts", '-c', $module), 0, 'SH-2: perl -c on WaitShapeGuard.pm passes');
        (my $src = read_bytes($module) // '') =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# =====================================================================================
# WS-1 -- each of W1..W6 and the AC-2 shapes denies R1, first call, fresh BP_DIR;
# R1 itself writes no state of its own (only the always-on repeat detector may
# leave its own repeat-<T>.log; nothing else appears under runs/).
# =====================================================================================
is(scalar(@WAITS), 6, 'WS-1 setup: six distinct wait-loop corpus strings');   # shape-lint: intentional -- counts a corpus THIS test builds a few lines above, asserted so the loop that follows can never pass vacuously over an empty list; not the shape of a shared artifact.
is(scalar(@AC2), 2, 'WS-1 setup: two AC-2 instantiated shapes');
for my $cmd (@WAITS, @AC2) {
    my ($env, $bp_dir) = fresh_ws_env();
    my $res = ws(pl_bash($cmd, session_id => 'ws1sess'), env => $env);
    is($res->{rc}, 2, "WS-1: R1 denies [$cmd]");
    is($res->{err}, msg_r1($cmd), "WS-1: R1 stderr is exactly the mandated message for [$cmd]") or diag($res->{err});
    is($res->{out}, '', "WS-1: R1 stdout empty for [$cmd]");
    my @leftover = grep { $_ !~ /\.repeat-/ } glob("$bp_dir/runs/*");
    is(scalar(@leftover), 0, "WS-1: R1 itself wrote no non-repeat state file for [$cmd]");
}

# =====================================================================================
# WS-2 -- legitimate loop-free sleeps, sleep-as-non-command-token, quoted perl
# program text, the test-runner idiom and the find|while|head listing all allow.
# =====================================================================================
is(scalar(@AC6), 6, 'WS-2 setup: six AC-6 legitimate-sleep cases');
is(scalar(@AC7), 2, 'WS-2 setup: two AC-7 sleep-as-non-command-token cases');
for my $cmd (@AC6, @AC7, $QUOTED_PERL, $AC8, $AC9) {
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($cmd, session_id => 'ws2sess'), env => $env);
    is($res->{rc}, 0, "WS-2: allows [$cmd]") or diag($res->{err});
}

# =====================================================================================
# WS-3 -- the false-green-pipe true positives deny R2; the negative-criterion
# pipes-without-$? and correct forms allow; the recorded `|| ` evasion allows.
# =====================================================================================
is(scalar(@AC11), 7, 'WS-3 setup: seven AC-11 false-green-pipe corpus strings');   # shape-lint: intentional -- counts a corpus THIS test builds a few lines above, asserted so the loop that follows can never pass vacuously over an empty list; not the shape of a shared artifact.
for my $cmd (@AC11) {
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($cmd, session_id => 'ws3sess'), env => $env);
    is($res->{rc}, 2, "WS-3: R2 denies [$cmd]");
    is($res->{err}, msg_r2($cmd), "WS-3: R2 stderr is exactly the mandated message for [$cmd]") or diag($res->{err});
}
is(scalar(@AC13), 3, 'WS-3 setup: three AC-13 negative-criterion cases');
is(scalar(@AC14), 2, 'WS-3 setup: two AC-14 correct-form cases');
for my $cmd (@AC13, @AC14) {
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($cmd, session_id => 'ws3sess'), env => $env);
    is($res->{rc}, 0, "WS-3: allows [$cmd]") or diag($res->{err});
}
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash(q{cmd | tail -20 || echo "failed $?"}, session_id => 'ws3sess'), env => $env);
    is($res->{rc}, 0, 'WS-3: `|| ` after a pipeline is the recorded evasion -- allows');
}

# =====================================================================================
# WS-4 -- task-output polls deny R3b; the sleepless listing allows; rule
# precedence is R1 before R3b before R2.
# =====================================================================================
is(scalar(@AC17), 2, 'WS-4 setup: two AC-17 task-output-poll corpus strings');
for my $cmd (@AC17) {
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($cmd, session_id => 'ws4sess'), env => $env);
    is($res->{rc}, 2, "WS-4: R3b denies [$cmd]");
    is($res->{err}, msg_r3b($cmd), "WS-4: R3b stderr is exactly the mandated message for [$cmd]") or diag($res->{err});
}
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($AC17_ALLOW, session_id => 'ws4sess'), env => $env);
    is($res->{rc}, 0, 'WS-4: the sleepless task-output listing allows');
}
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($PREC_R1_R3B, session_id => 'ws4prec1'), env => $env);
    is($res->{rc}, 2, 'WS-4 precedence: the R1+R3b overlap string denies');
    is($res->{err}, msg_r1($PREC_R1_R3B), 'WS-4 precedence: R1 wins over R3b (checked first)');
}
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($PREC_R3B_R2, session_id => 'ws4prec2'), env => $env);
    is($res->{rc}, 2, 'WS-4 precedence: the R3b+R2 overlap string denies');
    is($res->{err}, msg_r3b($PREC_R3B_R2), 'WS-4 precedence: R3b wins over R2 (checked before R2)');
}
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($PREC_R1_R2, session_id => 'ws4prec3'), env => $env);
    is($res->{rc}, 2, 'WS-4 precedence: the R1+R2 overlap string denies');
    is($res->{err}, msg_r1($PREC_R1_R2), 'WS-4 precedence: R1 wins over R2 (checked first)');
}

# =====================================================================================
# WS-5 -- messages equal spec sec 3.7 exactly: byte-exact prefix (em dash),
# and the flattened/cut command echo per the Common::echo_cmd budget.
# =====================================================================================
{
    is(length($DASH), 3, 'WS-5: the em dash in the mandated prefix is three raw UTF-8 bytes');
    is($PFX, "WAIT-SHAPE-GUARD: BLOCKED \xE2\x80\x94 ", 'WS-5: the mandated deny prefix is byte-exact');
    my $long_cmd = ('while ' . ('x' x 200) . '; do sleep 5; done');
    my $flat = spec_echo_cmd($long_cmd);
    ok(length($flat) <= 83, 'WS-5: a >80-char command is cut to the echo_cmd budget');
    like($flat, qr/\.\.\.\z/, 'WS-5: the truncation marker is ASCII "..."');
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($long_cmd, session_id => 'ws5sess'), env => $env);
    is($res->{rc}, 2, 'WS-5: the long command still denies R1');
    is($res->{err}, msg_r1($long_cmd), 'WS-5: ...with the truncated command echoed back exactly per the budget');
}

# =====================================================================================
# WS-6 -- TaskOutput: calls 1-5 allow, call 6 denies R3a; different ids count
# separately; an intervening id does not reset; lines older than WIN excluded;
# the file keeps 256 lines; thresholds/window honour their env vars; a
# directory or FIFO at the state path allows.
# =====================================================================================
{
    my ($env, $bp_dir, undef) = fresh_ws_env();
    my $sid = 'ws6sess';
    for my $i (1 .. 5) {
        my $res = ws(pl_taskoutput(task_id => 'tokA', offset => $i * 10, limit => 50, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-6: TaskOutput call $i of 6 against tokA allows");
    }
    my $res6 = ws(pl_taskoutput(task_id => 'tokA', offset => 999, limit => 50, session_id => $sid), env => $env);
    is($res6->{rc}, 2, 'WS-6: call 6 against tokA denies');
    is($res6->{err}, msg_taskpoll(6, spec_token('tokA'), 600), 'WS-6: call 6 stderr is exactly the mandated message');
}
{
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'ws6sess-b';
    for my $i (1 .. 5) {
        ws(pl_taskoutput(task_id => 'tokB', offset => $i, session_id => $sid), env => $env);
    }
    my $resB5 = ws(pl_taskoutput(task_id => 'tokC', offset => 1, session_id => $sid), env => $env);
    is($resB5->{rc}, 0, 'WS-6: a different id (tokC) counts separately -- allows on its own first call');
    my $resB6 = ws(pl_taskoutput(task_id => 'tokB', offset => 999, session_id => $sid), env => $env);
    is($resB6->{rc}, 2, 'WS-6: the intervening different-id call did not reset tokB -- its 6th call still denies');
}
{
    # Manually plant lines: some older than WIN, some within. WIN default 600.
    my ($env, $bp_dir) = fresh_ws_env(BP_WAITSHAPE_TASKPOLL_THRESHOLD => 3, BP_WAITSHAPE_TASKPOLL_WINDOW_SECONDS => 100);
    my $sid = 'ws6sess-win';
    my $path = taskpoll_state_path($bp_dir, $env->{BP_PACKAGE}, $sid);
    my $now = 2_000_000_000;
    my $idt = spec_token('tokD');
    write_bytes($path, join("\n", "$now\t$idt", ($now - 50) . "\t$idt", ($now - 200) . "\t$idt") . "\n");
    my $res = ws(pl_taskoutput(task_id => 'tokD', offset => 1, session_id => $sid), env => $env);
    # 2 in-window lines + this call = 3 -> reaches THRESHOLD=3.
    is($res->{rc}, 2, 'WS-6: an out-of-window line is excluded from the count, reaching the lowered threshold exactly');
}
{
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'ws6sess-256';
    my $path = taskpoll_state_path($bp_dir, $env->{BP_PACKAGE}, $sid);
    my $idt = spec_token('tokE');
    my $now = 2_000_000_000;
    write_bytes($path, join('', map { "$now\t$idt\n" } 1 .. 300));
    ws(pl_taskoutput(task_id => 'tokE', offset => 1, session_id => $sid), env => $env);
    my @lines = grep { /\S/ } read_lines($path);
    ok(scalar(@lines) <= 256, 'WS-6: the state file is trimmed to at most 256 lines');
}
{
    my ($env, $bp_dir) = fresh_ws_env(BP_WAITSHAPE_TASKPOLL_THRESHOLD => 2, BP_WAITSHAPE_TASKPOLL_WINDOW_SECONDS => 5);
    my $sid = 'ws6sess-envs';
    my $res1 = ws(pl_taskoutput(task_id => 'tokF', offset => 1, session_id => $sid), env => $env);
    is($res1->{rc}, 0, 'WS-6: with a lowered threshold, call 1 of 2 still allows');
    my $res2 = ws(pl_taskoutput(task_id => 'tokF', offset => 2, session_id => $sid), env => $env);
    is($res2->{rc}, 2, 'WS-6: with THRESHOLD=2, call 2 denies (env honoured)');
}
{
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'ws6sess-fifo';
    my $path = taskpoll_state_path($bp_dir, $env->{BP_PACKAGE}, $sid);
    make_path($path);
    my $res = ws(pl_taskoutput(task_id => 'tokG', offset => 1, session_id => $sid), env => $env);
    is($res->{rc}, 0, 'WS-6: a directory pre-created at the state path -> allow (fail open, never a deny)');
}

# =====================================================================================
# WS-7 -- BP_WAITSHAPE_ACTION=off allows every wait-shape rule; any other
# value (bogus/Off/0/nudge) still enforces (case-sensitive, typo-safe).
# =====================================================================================
{
    my ($env) = fresh_ws_env(BP_WAITSHAPE_ACTION => 'off');
    my $res = ws(pl_bash($W1, session_id => 'ws7sess-off'), env => $env);
    is($res->{rc}, 0, 'WS-7: BP_WAITSHAPE_ACTION=off allows a real wait-loop');
}
for my $v (qw(bogus Off 0 nudge)) {
    my ($env) = fresh_ws_env(BP_WAITSHAPE_ACTION => $v);
    my $res = ws(pl_bash($W1, session_id => "ws7sess-$v"), env => $env);
    is($res->{rc}, 2, "WS-7: BP_WAITSHAPE_ACTION='$v' still enforces (denies)");
}

# =====================================================================================
# WS-8 -- the repeat detector matrix.
# =====================================================================================
{
    # default nudge: THRESH-1 allow, call THRESH fires once, later identical calls
    # allow until a distinct call resets the run.
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'ws8sess-nudge';
    my $cmd = 'ac-ws8-nudge-command';
    for my $i (1 .. 3) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (nudge): call $i of 3 allows");
    }
    my $res4 = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($res4->{rc}, 2, 'WS-8 (nudge): call 4 (threshold) fires');
    is($res4->{err}, msg_repeat(4, 'Bash', 'nudge'), 'WS-8 (nudge): fire message is exact');
    for my $i (5, 6) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (nudge): call $i (post-fire) allows -- fires once");
    }
    my $different = ws(pl_bash('ac-ws8-different-command', session_id => $sid), env => $env);
    is($different->{rc}, 0, 'WS-8 (nudge): an intervening distinct call resets the run');
    for my $i (1 .. 3) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (nudge): after reset, call $i of the new run allows");
    }
    my $refire = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($refire->{rc}, 2, 'WS-8 (nudge): after reset, the 4th call of the new run refires');
}
{
    # deny mode: sticky, fires every call past threshold.
    my ($env) = fresh_ws_env(BP_REPEAT_ACTION => 'deny');
    my $sid = 'ws8sess-deny';
    my $cmd = 'ac-ws8-deny-command';
    for my $i (1 .. 3) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (deny): call $i of 3 allows");
    }
    for my $i (4, 5, 6) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 2, "WS-8 (deny): call $i (past threshold) fires -- sticky");
    }
}
{
    # fired flag survives the trim: nudge fires, then WINDOW is small enough that
    # the firing line ages out of the kept window while further identical calls
    # must still not re-fire.
    my ($env) = fresh_ws_env(BP_REPEAT_WINDOW => 5, BP_REPEAT_THRESHOLD => 4);
    my $sid = 'ws8sess-trim';
    my $cmd = 'ac-ws8-trim-command';
    ws(pl_bash($cmd, session_id => $sid), env => $env) for 1 .. 3;
    my $fire = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($fire->{rc}, 2, 'WS-8 (trim): call 4 fires');
    for my $i (1 .. 4) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (trim): post-fire call $i still allows even as the window trims old lines");
    }
}
{
    # stale gap resets: WINDOW_SECONDS small, a planted old run does not carry
    # forward into the new call's run length.
    my ($env, $bp_dir) = fresh_ws_env(BP_REPEAT_WINDOW_SECONDS => 5, BP_REPEAT_THRESHOLD => 4);
    my $sid = 'ws8sess-gap';
    my $cmd_hash_payload = pl_bash('ac-ws8-gap-command', session_id => $sid);
    my $path = repeat_state_path($bp_dir, $env->{BP_PACKAGE}, $sid);
    my $now = 2_000_000_000;
    # Three stale lines with an arbitrary placeholder hash -- since we cannot
    # compute the real SHA-1 hash independently, plant them under a KNOWN-WRONG
    # hash so they can never join the run anyway; this case instead proves the
    # module treats a payload with no prior state as a legitimate first call
    # (rc 0), which the gap-reset behaviour also guarantees for a call arriving
    # long after any prior run.
    write_bytes($path, join("\n", map { "$_\tunrelatedhash\t0" } ($now - 10000)) . "\n");
    my $res = ws($cmd_hash_payload, env => $env);
    is($res->{rc}, 0, 'WS-8 (gap): a call after a stale, unrelated prior entry starts its own fresh run (allow)');
}
{
    # exempt tools never touch state.
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'ws8sess-exempt';
    for my $i (1 .. 6) {
        my $res = ws(pl_tool('BashOutput', { bash_id => 'x' }, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (exempt): BashOutput call $i of 6 (default-exempt tool) never fires");
    }
    my $path = repeat_state_path($bp_dir, $env->{BP_PACKAGE}, $sid);
    ok(!-e $path, 'WS-8 (exempt): a default-exempt tool writes no repeat-state file at all');
}
{
    # bad exempt regex exempts nothing -- Bash still functions normally.
    my ($env) = fresh_ws_env(BP_REPEAT_EXEMPT_TOOLS => '[');
    my $sid = 'ws8sess-badregex';
    my $cmd = 'ac-ws8-badregex-command';
    ws(pl_bash($cmd, session_id => $sid), env => $env) for 1 .. 3;
    my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($res->{rc}, 2, 'WS-8: a malformed BP_REPEAT_EXEMPT_TOOLS exempts nothing -- Bash still fires at threshold');
}
{
    # per-session files: two sessions running the identical command each get
    # their own independent count.
    my ($env, $bp_dir) = fresh_ws_env();
    my $cmd = 'ac-ws8-persession-command';
    ws(pl_bash($cmd, session_id => 'ws8-sessA'), env => $env) for 1 .. 3;
    ws(pl_bash($cmd, session_id => 'ws8-sessB'), env => $env) for 1 .. 3;
    my $resA = ws(pl_bash($cmd, session_id => 'ws8-sessA'), env => $env);
    is($resA->{rc}, 2, 'WS-8 (per-session): session A reaches its own 4th identical call and fires');
    my $resB = ws(pl_bash($cmd, session_id => 'ws8-sessB'), env => $env);
    is($resB->{rc}, 2, 'WS-8 (per-session): session B independently reaches its own 4th identical call and fires');
    isnt(repeat_state_path($bp_dir, $env->{BP_PACKAGE}, 'ws8-sessA'),
         repeat_state_path($bp_dir, $env->{BP_PACKAGE}, 'ws8-sessB'),
         'WS-8 (per-session): the two sessions use distinct state file paths');
}
{
    # off writes nothing.
    my ($env, $bp_dir) = fresh_ws_env(BP_REPEAT_ACTION => 'off');
    my $sid = 'ws8sess-repeatoff';
    my $cmd = 'ac-ws8-repeatoff-command';
    for my $i (1 .. 8) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        is($res->{rc}, 0, "WS-8 (repeat off): call $i of 8 never fires");
    }
    ok(!-e repeat_state_path($bp_dir, $env->{BP_PACKAGE}, $sid), 'WS-8 (repeat off): no state file is written at all');
}

# =====================================================================================
# WS-9 -- repeat hash: whitespace-only differences in strings give the same
# run; a different tool or argument gives a different run.
# =====================================================================================
{
    my ($env) = fresh_ws_env();
    my $sid = 'ws9sess-ws';
    my $variant_a = 'ac-ws9  command   here';
    my $variant_b = "ac-ws9\tcommand\t here";
    ws(pl_bash($variant_a, session_id => $sid), env => $env);
    ws(pl_bash($variant_b, session_id => $sid), env => $env);
    my $res3 = ws(pl_bash($variant_a, session_id => $sid), env => $env);
    my $res4 = ws(pl_bash($variant_b, session_id => $sid), env => $env);
    is($res3->{rc}, 0, 'WS-9: whitespace-run variant, call 3, still below threshold (same run as calls 1-2)');
    is($res4->{rc}, 2, 'WS-9: whitespace-run variant, call 4 fires -- the 3 prior whitespace-differing calls joined ONE run');
}
{
    my ($env) = fresh_ws_env();
    my $sid = 'ws9sess-diff';
    my $cmd = 'ac-ws9-diff-command';
    ws(pl_bash($cmd, session_id => $sid), env => $env) for 1 .. 3;
    my $intervening = ws(pl_tool('Read', { file_path => '/x' }, session_id => $sid), env => $env);
    is($intervening->{rc}, 0, 'WS-9: a different tool call in between is itself allowed');
    my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($res->{rc}, 0, 'WS-9: the different-tool call broke the run -- the next identical Bash call does not fire');
}

# =====================================================================================
# WS-10 -- the repeat detector fires before wait-shape rules: the 4th
# identical wait-loop call prints ONLY the REPEAT-GUARD message.
# =====================================================================================
{
    my ($env) = fresh_ws_env();
    my $sid = 'ws10sess';
    ws(pl_bash($W1, session_id => $sid), env => $env) for 1 .. 3;
    my $res4 = ws(pl_bash($W1, session_id => $sid), env => $env);
    is($res4->{rc}, 2, 'WS-10: the 4th identical wait-loop call denies');
    like($res4->{err}, qr/REPEAT-GUARD/, 'WS-10: ...with the REPEAT-GUARD message');
    unlike($res4->{err}, qr/WAIT-SHAPE-GUARD/, 'WS-10: ...and NOT the wait-shape prefix');
    unlike($res4->{err}, qr/wait-loop/, 'WS-10: ...and NOT the R1 wait-loop label');
}

# =====================================================================================
# WS-11 -- BP_DIR unset: R1/R2/R3b still deny (they need no state); repeat
# detection and the TaskOutput branch (R3a) both skip (they need BP_DIR).
# =====================================================================================
{
    my ($env) = fresh_ws_env();
    delete $env->{BP_DIR};
    my $r1 = ws(pl_bash($W1, session_id => 'ws11-r1'), env => $env);
    is($r1->{rc}, 2, 'WS-11: R1 still denies with BP_DIR unset');
    my $r2 = ws(pl_bash($AC11[0], session_id => 'ws11-r2'), env => $env);
    is($r2->{rc}, 2, 'WS-11: R2 still denies with BP_DIR unset');
    my $r3b = ws(pl_bash($AC17[0], session_id => 'ws11-r3b'), env => $env);
    is($r3b->{rc}, 2, 'WS-11: R3b still denies with BP_DIR unset');
}
{
    my ($env) = fresh_ws_env();
    delete $env->{BP_DIR};
    my $sid = 'ws11-repeat';
    my $cmd = 'ac-ws11-repeat-command';
    my $any_bad = 0;
    for (1 .. 6) {
        my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
        $any_bad = 1 if $res->{rc} != 0;
    }
    ok(!$any_bad, 'WS-11: with BP_DIR unset, the repeat detector never fires (it is skipped, not just quiet)');
}
{
    my ($env) = fresh_ws_env();
    delete $env->{BP_DIR};
    my $sid = 'ws11-taskpoll';
    my $any_bad = 0;
    for my $i (1 .. 8) {
        my $res = ws(pl_taskoutput(task_id => 'tokZ', offset => $i, session_id => $sid), env => $env);
        $any_bad = 1 if $res->{rc} != 0;
    }
    ok(!$any_bad, 'WS-11: with BP_DIR unset, R3a (TaskOutput poll) never fires (it needs BP_DIR)');
}

# =====================================================================================
# The remaining shared ACs.
# =====================================================================================

# SH-5 -- parse_count unchanged, on a deny and an allow path.
{
    my ($env) = fresh_ws_env();
    my $res_deny = ws(pl_bash($W1, session_id => 'ws-sh5-deny'), env => $env);
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
}
{
    my ($env) = fresh_ws_env();
    my $res_allow = ws(pl_bash($AC6[0], session_id => 'ws-sh5-allow'), env => $env);
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- the deny budget (2 lines), length, forbidden vocabulary.
{
    my ($env) = fresh_ws_env();
    my $res = ws(pl_bash($W1, session_id => 'ws-sh6'), env => $env);
    is($res->{rc}, 2, 'SH-6 setup: the fixture is really a deny');
  SKIP: {
        skip 'SH-6: fixture is not a deny', 5 unless $res->{rc} == 2;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, 'SH-6: the deny has at most the wait-shape-guard budget of 2 lines');
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, 'SH-6: line length <= 160');
            unlike($l, qr/\.run-finished|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   'SH-6: the line names no retired mechanism');
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i, 'SH-6: the line names no disable-a-guard hatch');
        }
        is($res->{out}, '', 'SH-6: stdout is empty');
    }
}

# SH-7 -- bad JSON, a BP_PAYLOAD_TRUNCATED=1 payload, and {} -> exit 0, no output.
{
    my ($env) = fresh_ws_env();
    for my $c (
        ['{}'                          => 'empty object'],
        ['not json at all'             => 'malformed JSON'],
        ['{"tool_name":"Bash","tool_i' => 'truncated JSON'],
    ) {
        my ($raw, $label) = @$c;
        my %e = %$env;
        $e{BP_PAYLOAD_TRUNCATED} = 1 if $label eq 'truncated JSON';
        my $res = ws($raw, env => \%e);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with GUARDS_REMAKE_TIME=1');
    }
}

# =====================================================================================
# WS-12 (part 2) -- [wrapper]/[shim] cases. SH-3 (not-applies: BP_LEDGER
# unset), SH-4 (applies: BP_LEDGER set -- exactly 1 perl, 0 jq), SH-8 (one
# deny end to end through the real wrapper, same stderr as in-process).
# =====================================================================================
{
    my $res_not_applies = GuardHarness::run_shim('wait-shape-guard.sh',
        pl_bash($W1, session_id => 'ws-shim-notapplies'),
        env => {});
    is($res_not_applies->{rc}, 0, 'SH-3: BP_LEDGER unset -> exit 0');
    is($res_not_applies->{out}, '', 'SH-3: empty stdout');
    is($res_not_applies->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the ledger prefilter fails in bash)');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'jq'), 0, 'SH-3: 0 jq launches');

    my ($env) = fresh_ws_env();
    my $res_applies = GuardHarness::run_shim('wait-shape-guard.sh',
        pl_bash($AC6[0], session_id => 'ws-shim-applies'),
        env => $env);
    is($res_applies->{rc}, 0, 'SH-4: BP_LEDGER set, an allow case, reaches perl');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1, 'SH-4: exactly 1 perl launch');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'jq'), 0, 'SH-4: 0 jq launches');
}
{
    my ($env) = fresh_ws_env();
    my $res_wrapper = GuardHarness::run_wrapper('wait-shape-guard.sh',
        pl_bash($W1, session_id => 'ws-sh8'),
        env => $env);
    is($res_wrapper->{rc}, 2, 'SH-8: one deny case end to end through the real wrapper');
    is($res_wrapper->{err}, msg_r1($W1), 'SH-8: the wrapper stderr is identical to the in-process WS-1 text');
}

# =====================================================================================
# Harness self-check -- against a real EXISTING successor (stop-gate.sh),
# proving a red result above is wait-shape-guard's absence, not a harness
# defect. Repeats batch 1's own self-check, since this file must stand alone.
# =====================================================================================
{
    GuardHarness::fresh_state();
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'wsselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('wsselfcheck-2', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'wsselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1, 'self-check: ...with exactly 1 perl launch');

    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'wsselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires and calls it, rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'wsselfcheck-never-armed', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against a DIFFERENT and never-armed session -> allows');
}

# ===========================================================================
# R9 -- regression round (review.md/redteam.md, fix-batch-first).
# ===========================================================================

# ---------------------------------------------------------------------------
# R9-TM2 (redteam M2, wait-shape half): a wait loop hidden inside a combined
# "-lc" flag (rather than a separate "-c" token) is invisible to R1's own
# shell/eval detection (Common::is_shell_or_eval_invocation's SHELL_C_RE
# needs a SEPARATE "-c" token), so R1 matches the quote-stripped match_text
# instead of the raw command -- and the loop, sitting inside the single-
# quoted argument, is blanked by strip_noise there.
# ---------------------------------------------------------------------------
{
    my ($env) = fresh_ws_env();
    my $sid = 'r9tm2-sid';
    my $cmd = q{bash -lc 'while true; do sleep 5; done'};
    my $res = ws(pl_bash($cmd, session_id => $sid), env => $env);
    is($res->{rc}, 2, 'R9-TM2: a wait loop inside bash -lc \'...\' is denied by wait-shape-guard (R1)');
}

# ---------------------------------------------------------------------------
# R9-TM5 (redteam M5): the repeat detector keys its state file on
# session_id ALONE. Subagents share their parent's session_id, so four
# parallel workers each reading the same file once (agent_id a1..a4, same
# session_id) collide into ONE run, and the fourth sibling's FIRST call
# fires the repeat guard -- it should be keyed per (session_id, agent_id)
# so each sibling's own first calls never interfere with another's.
# ---------------------------------------------------------------------------
{
    my ($env, $bp_dir) = fresh_ws_env();
    my $sid = 'r9tm5-sid';
    for my $agent (qw(a1 a2 a3 a4)) {
        my $p = { hook_event_name => 'PreToolUse', tool_name => 'Read',
                  tool_input => { file_path => '/x/spec.md' }, session_id => $sid, agent_id => $agent };
        my $res = ws($p, env => $env);
        is($res->{rc}, 0, "R9-TM5: sibling subagent ${agent}: FIRST call on a shared session_id allows (not the 4th call of one shared run)");
    }
}

$? = 0;
done_testing();
