#!/usr/bin/env perl
# 187 — an unattended run does not stop to ask.
#
# THE PATTERN THIS EXISTS TO END, in the operator's own words: "a whole
# unattended run halt because of some blocking user input. 99% of the times it
# was not actually necessary and could have progressed while batching the
# question to the end or having the agent decide by itself when it's a
# non-product question."
#
# Both halves matter. The stopping is expensive -- hours of idle time where work
# was available -- and the question usually did not need an operator at all.
# There has been a standing ruling to exactly this effect
# (guidance/escalate-product-decisions-only.md) and it kept being violated,
# which is this repo's recurring lesson: a written instruction is not an
# enforcement mechanism.
#
# UNATTENDED MEANS EITHER OF TWO THINGS, and both trip the guard: a RUN is
# active, or CONTINUITY IS ARMED for the session. The first version checked only
# the run, which missed the case actually described -- a plain armed overnight
# session sets no run state at all.
#
# WHAT MUST NOT HAPPEN IS OVER-BLOCKING. A session that is neither armed nor
# driving a run is free to ask; AC3 and AC4 are the counter-checks that keep
# this from becoming a blanket ban on talking to the operator.
#
# AC1  AskUserQuestion is denied while a run is ACTIVE
# AC2  ...and the question text is queued, not lost
# AC3  ...and it is ALLOWED when the run is inert / paused / finished
# AC4  an ARMED session is unattended too, and an unarmed one may still ask
# AC5  ...with the question queued either way
# AC6  the turn-ending verb (await-operator) is GONE; `ask` replaces it
# AC7  the queue APPENDS -- several questions over a long run all survive
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
use JSON::PP ();

my $GUARD    = "$Bin/../../hooks/guard-ask-operator.sh";
my $RUNSTATE = "$Bin/../../scripts/bp-runstate.pl";
my $CONT     = "$Bin/../../scripts/bp-continuity.pl";

ok(-f $GUARD,    'guard-ask-operator.sh exists') or BAIL_OUT('guard missing');
ok(-f $RUNSTATE, 'bp-runstate.pl exists')        or BAIL_OUT('runstate missing');

sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub set_run_state {
    my ($root, $verb, @args) = @_;
    system($^X, $RUNSTATE, $verb, '--root', $root, @args) == 0 or return 0;
    return 1;
}

sub run_guard {
    my ($root, @questions) = @_;
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-q', cwd => $root, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ map { { question => $_ } } @questions ] },
    });
    my $out = `CLAUDE_PROJECT_DIR='$root' bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out // '');
}

sub queue_contents {
    my ($root) = @_;
    my $p = "$root/.ccpraxis-local-data/.subagent-guard/questions.md";
    return '' unless -f $p;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# ── AC1/AC2 — denied while active, and the question survives ──────────────
{
    my $root = new_project();
    ok(set_run_state($root, 'activate', '--reason', 'unattended work'),
       'AC1 fixture: a run is active');

    my ($rc, $out) = run_guard($root, 'Which approach, A or B?');
    is($rc, 2, 'AC1 CANONICAL: AskUserQuestion is DENIED while a run is active -- this is '
             . 'the tool call that used to halt a whole overnight run');
    like($out, qr/queued/i, 'AC1 and the refusal says the question was kept');
    like($out, qr/escalate-product-decisions-only|PRODUCT decision/,
         'AC1 and points at the standing ruling on what actually needs an operator');

    like(queue_contents($root), qr/Which approach, A or B\?/,
         'AC2 CANONICAL: the question text is in the queue -- refusing without keeping it '
       . 'would just move the loss from the run to the question');
}

# ── AC3 — NOT a blanket ban ───────────────────────────────────────────────
#
# The failure mode of a guard like this is over-blocking: an interactive session
# that can no longer talk to its operator. Each non-active state is checked
# rather than assumed.
{
    for my $state (['inert', undef], ['finished', 'finish']) {
        my ($label, $verb) = @$state;
        my $root = new_project();
        set_run_state($root, $verb, '--reason', 'done') if defined $verb;
        my ($rc) = run_guard($root, 'Is this ok?');
        is($rc, 0, "AC3 CANONICAL: a $label run does NOT block the question -- asking the "
                 . 'operator is normal when nothing unattended is in flight');
    }

    # A PAUSED run has a live watcher, so the session is not unattended in the
    # sense that matters here.
    my $root = new_project();
    set_run_state($root, 'activate', '--reason', 'work');
    my $ok = set_run_state($root, 'pause', '--watcher-pid', $$,
                           '--until', time() + 600, '--reason', 'waiting');
    SKIP: {
        skip 'could not establish a paused run', 1 unless $ok;
        my ($rc) = run_guard($root, 'Is this ok?');
        is($rc, 0, 'AC3 a paused run does not block either');
    }
}

# ── AC4/AC5 — ARMED counts as unattended, and `ask` is the way through ────
#
# The first version of this guard keyed only on a RUN being active. That missed
# the case the operator actually described: a plain armed overnight session,
# which sets no run state at all and so sailed straight past the guard.
#
# Arming IS the operator saying "watch this, I am not here", so it is unattended
# by definition. And the verb that used to end a turn for a question
# (await-operator) is gone -- an armed session ending its turn to ask something
# is the halt, not the remedy.
{
    my $root = new_project();
    my $reg  = "$root/reg";
    make_path($reg);

    # No run at all. Only the arm.
    open my $fh, '>', "$reg/sess-armed" or die $!;
    print {$fh} "operator 2026-09-10T00:00:00Z\n";
    close $fh;

    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-armed', cwd => $root, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ { question => 'Should I rename it?' } ] },
    });
    my $out = `CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;

    is($rc, 2, 'AC4 CANONICAL: an ARMED session is unattended -- the question is denied even '
             . 'with no run active, which is the overnight case the run-only check missed');
    like($out, qr/ARMED/, 'AC4 and the refusal names the real reason rather than claiming a run');
    like(queue_contents($root), qr/Should I rename it\?/, 'AC5 the question is queued');

    # An UNARMED session with no run is free to ask. Over-blocking is the real
    # risk with a guard like this.
    my $root2 = new_project();
    my $reg2  = "$root2/reg";
    make_path($reg2);
    my $p2 = JSON::PP->new->canonical->encode({
        session_id => 'sess-free', cwd => $root2, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ { question => 'Fine?' } ] },
    });
    `CLAUDE_PROJECT_DIR='$root2' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg2' bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$p2
PAYLOAD_EOF`;
    is($? >> 8, 0, 'AC4 CANONICAL: an unarmed session with no run may still ask -- talking to '
                 . 'the operator is normal when nothing unattended is in flight');
}

# ── AC6 — the halting verb is gone ────────────────────────────────────────
{
    my $root = new_project();
    my $reg  = "$root/reg";
    my $cont = "$Bin/../../scripts/bp-continuity.pl";
    system("CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' "
         . "$^X '$cont' arm --session s1 >/dev/null 2>&1");
    my $out = `CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' $^X '$cont' await-operator --reason 'x' 2>&1`;
    isnt($? >> 8, 0,
         'AC6 CANONICAL: await-operator is REMOVED. A retired escape hatch that still works '
       . 'is not retired, and this one ended turns for questions -- the exact halt being '
       . 'designed out');

    # ...and `ask` is what replaced it: it records and returns, never permitting a stop.
    my $q = `CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' $^X '$cont' ask --text 'A or B?' 2>&1`;
    is($? >> 8, 0, 'AC6 ask succeeds');
    like($q, qr/STATUS:\s*queued/, 'AC6 and reports the question queued');
    like($q, qr/QUEUED:\s*\d+/,    'AC6 with a count the statusline also shows');
}

# ── AC7 — the queue accumulates ───────────────────────────────────────────
{
    my $root = new_project();
    set_run_state($root, 'activate', '--reason', 'work');
    run_guard($root, 'First question?');
    run_guard($root, 'Second question?');
    run_guard($root, 'Third question?', 'And a fourth in the same call?');

    my $q = queue_contents($root);
    like($q, qr/First question\?/,  'AC7 first survives');
    like($q, qr/Second question\?/, 'AC7 second survives');
    like($q, qr/Third question\?/,  'AC7 third survives');
    like($q, qr/And a fourth in the same call\?/,
         'AC7 CANONICAL: and multiple questions in ONE call are all captured -- the payload '
       . 'nests them in an array, which is why this is not read with a scalar path');
}

done_testing();
