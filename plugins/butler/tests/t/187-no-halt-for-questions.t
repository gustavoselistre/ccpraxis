#!/usr/bin/env perl
# 187-no-halt-for-questions.t — an unattended run does not stop to ask.
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
# TWO WAYS A RUN COULD STOP TO ASK, so two guards:
#   * the AskUserQuestion tool          -> guard-ask-operator.sh (PreToolUse)
#   * bp-continuity.pl await-operator   -> refuses while a run is active
#
# WHAT MUST NOT HAPPEN IS OVER-BLOCKING. An interactive session asking its
# operator something is normal and good. Only `active` -- unattended work in
# flight right now -- trips either guard, and AC3/AC6 are the counter-checks
# that keep them from becoming a blanket ban on talking to the operator.
#
# AC1  AskUserQuestion is denied while a run is ACTIVE
# AC2  ...and the question text is queued, not lost
# AC3  ...and it is ALLOWED when the run is inert / paused / finished
# AC4  await-operator is refused while a run is ACTIVE
# AC5  ...and queues its reason too
# AC6  ...and works normally when no run is active
# AC7  the queue APPENDS -- several questions over a long run all survive
use strict;
use warnings;
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

# ── AC4/AC5/AC6 — the same rule for await-operator ────────────────────────
{
    my $root = new_project();
    my $reg  = "$root/reg";
    set_run_state($root, 'activate', '--reason', 'unattended work');

    system("CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' "
         . "$^X '$CONT' arm --session sess-a >/dev/null 2>&1");

    my $out = `CLAUDE_PROJECT_DIR='$root' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg' $^X '$CONT' await-operator --session sess-a --reason 'A or B?' 2>&1`;
    my $rc = $? >> 8;
    is($rc, 3, 'AC4 CANONICAL: await-operator is refused while a run is active -- the honest '
             . 'exit for "a human was asked" must not become the way a run stops dead');
    like($out, qr/refused_run_active/, 'AC4 and says why');
    like(queue_contents($root), qr/A or B\?/, 'AC5 the reason is queued too');

    # ...and with no run, it behaves exactly as before.
    my $root2 = new_project();
    my $reg2  = "$root2/reg";
    system("CLAUDE_PROJECT_DIR='$root2' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg2' "
         . "$^X '$CONT' arm --session sess-b >/dev/null 2>&1");
    my $out2 = `CLAUDE_PROJECT_DIR='$root2' CCPRAXIS_CONTINUITY_ACTIVE_DIR='$reg2' $^X '$CONT' await-operator --session sess-b --reason 'ok?' 2>&1`;
    is($? >> 8, 0, 'AC6 CANONICAL: with no active run it still permits the turn -- the guard '
                 . 'is scoped to unattended work, not to talking to the operator');
    like($out2, qr/awaiting_operator/, 'AC6 with the normal status');
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
