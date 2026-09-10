#!/usr/bin/env perl
# 183-continuity-bounded-hold.t — the two changes that stop /butler:continuity
# from lying about being armed, and from accepting a promise nothing will keep.
#
# 1. WHICH SESSION AM I. bp-continuity.pl resolved --session, else
#    $ENV{CLAUDE_SESSION_ID} — and that env var does not exist. ${CLAUDE_SESSION_ID}
#    is a Claude Code TEMPLATE SUBSTITUTION replaced inside SKILL.md before the
#    body runs (references/extending-ccpraxis.md), not an environment variable.
#    So the fallback was a category error and the id substituted into the skill
#    body was the sole source, with no cross-check — while the gate looks its
#    marker up by the session_id in its OWN hook payload and exit 0's silently
#    when there is none. Any disagreement therefore produced the worst outcome
#    available: arm reports success, and enforces nothing. Reported from a live
#    session after a container rebuild + resume.
#
#    Fix: collect every candidate id and arm all of them, report the
#    disagreement, tag the fallbacks, and give `status` a way to prove whether
#    the gate has ever actually run.
#
# 2. WHAT COUNTS AS A WAKE-UP. The gate allowed a stop whenever something had
#    been DISPATCHED. A dispatch is not a promise to come back: a subagent that
#    runs forever, or a background command with no timeout, writes that marker
#    and never returns, leaving the session idle with nothing to re-invoke it.
#    The marker's TTL cannot rescue it — the TTL only governs whether a LATER
#    stop is allowed, and there is no later stop.
#
#    Fix: a wake-up must be BOUNDED, and `hold` is the command that both records
#    the deadline and delivers it (it sleeps, then exits; a backgrounded command
#    that exits is what re-invokes the session).
#
# AC1  an explicitly-passed INVALID id is an error, never quietly replaced
# AC2  status proves whether the gate has run (GATE_SEEN), and warns when it
#      has not
# AC3  hold writes a bounded marker with a future deadline, then returns
# AC4  hold refuses a wait longer than the marker's own TTL
# AC5  hold on an unarmed session is a timer and says so, writing no marker
#
# The identity half -- tickets, nonces, and the gate binding them -- is t/184.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use POSIX qw(strftime);

my $SCRIPT = "$Bin/../../scripts/bp-continuity.pl";
ok(-f $SCRIPT, 'bp-continuity.pl exists') or BAIL_OUT('script missing');

# run_cli(\@args, \%env) -> ($stdout, $rc). undef in %env truly unsets.
sub run_cli {
    my ($args, $env) = @_;
    $env //= {};
    local %ENV = %ENV;
    for my $k (sort keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} }
        else                    { delete $ENV{$k} }
    }
    my $argstr = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @$args;
    my $out = `perl "$SCRIPT" $argstr 2>&1`;
    return (defined($out) ? $out : '', $? >> 8);
}

sub kv {
    my ($out, $key) = @_;
    return $1 if $out =~ /^\Q$key\E:\s*(.*)$/m;
    return undef;
}

sub reg { return tempdir(CLEANUP => 1) }

# The blocks that used to stand here asserted the FIRST attempt at this: arm
# every candidate session id it could find, tag the fallbacks, and report the
# disagreement. That was a workaround for not knowing which session was live,
# and it carried a real cost -- a candidate id could be another LIVE session,
# which would then be armed without its operator asking. It is superseded by the
# ticket flow (t/184), which does not guess at all.

# ── AC1 — an invalid explicit id is an error, not a silent substitution ────
{
    my $r = reg();
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'has.a.dot'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r, BP_LEDGER => undef,
          CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => 'sid-valid-env' },
    );
    is($rc, 1, 'AC1 an invalid --session exits 1 even when a valid env candidate exists');
    is(kv($out, 'STATUS'), 'error', 'AC1 STATUS: error');
    ok(!-f "$r/sid-valid-env",
       'AC1 and nothing was armed -- the env candidate does not stand in for a '
     . 'request that was never honoured');
}

# ── AC2 — status proves whether the gate has run ──────────────────────────
{
    my $r = reg();
    run_cli(['arm', '--session', 'sid-gate'],
            { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r, BP_LEDGER => undef,
              CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });

    my ($fresh) = run_cli(['status', '--session', 'sid-gate'],
                          { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                            CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    is(kv($fresh, 'GATE_SEEN'), 'no', 'AC2 a just-armed marker reports GATE_SEEN: no');
    is(kv($fresh, 'WARN'), undef,
       'AC2 ...and does NOT warn yet -- "armed two seconds ago" has not reached a Stop');

    # Backdate the arm and its mtime: armed long ago, gate never ran.
    my $old = time() - 600;
    open my $fh, '>', "$r/sid-gate" or die $!;
    print {$fh} 'operator ' . strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($old)) . "\n";
    close $fh;
    utime($old, $old, "$r/sid-gate");

    my ($stale) = run_cli(['status', '--session', 'sid-gate'],
                          { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                            CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    is(kv($stale, 'GATE_SEEN'), 'no', 'AC2 still no');
    like(kv($stale, 'WARN') // '', qr/has not run/,
         'AC2 and NOW it warns -- this is the decisive symptom of arming a session '
       . 'Claude Code does not consider live');

    # The gate touches the marker on every run; that is what GATE_SEEN reads.
    my $now = time();
    utime($now, $now, "$r/sid-gate");
    my ($seen) = run_cli(['status', '--session', 'sid-gate'],
                         { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                           CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    is(kv($seen, 'GATE_SEEN'), 'yes', 'AC2 a touched marker reports GATE_SEEN: yes');
    is(kv($seen, 'WARN'), undef, 'AC2 and stops warning');
}

# ── AC3/AC4/AC5 — the bounded hold ────────────────────────────────────────
{
    my $r = reg();
    run_cli(['arm', '--session', 'sid-hold'],
            { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r, BP_LEDGER => undef,
              CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });

    my $t0 = time();
    my ($out, $rc) = run_cli(['hold', '--session', 'sid-hold', '--seconds', '2'],
                             { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                               CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    my $elapsed = time() - $t0;
    is($rc, 0, 'AC3 hold exits 0');
    # hold emits STATUS twice on purpose: `holding` up front, flushed before the
    # wait so a backgrounded caller can read it immediately, then `hold_elapsed`
    # at the end. kv() returns the first match, so assert on both explicitly.
    is(kv($out, 'STATUS'), 'holding', 'AC3 it announces the hold before waiting');
    like($out, qr/^STATUS:\s*hold_elapsed$/m,
         'AC3 and reports that the wait elapsed when it returns');
    cmp_ok($elapsed, '>=', 2, 'AC3 it actually waited -- the hold IS the wake-up, not a note about one');
    cmp_ok($elapsed, '<', 30, 'AC3 and returned promptly after its deadline');
}

# The marker it writes is what the gate requires: bounded, with a future deadline.
{
    my $r = reg();
    run_cli(['arm', '--session', 'sid-mark'],
            { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r, BP_LEDGER => undef,
              CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });

    # Read the marker WHILE the hold is still waiting.
    my $pid = fork();
    if (defined $pid && $pid == 0) {
        local %ENV = (%ENV, CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r);
        delete $ENV{CLAUDE_SESSION_ID};
        delete $ENV{CLAUDE_CODE_SESSION_ID};
        exec($^X, $SCRIPT, 'hold', '--session', 'sid-mark', '--seconds', '5');
        exit 1;
    }
    SKIP: {
        skip 'fork unavailable', 3 unless defined $pid && $pid > 0;
        my $wp = "$r/sid-mark.wakeup-pending";
        my $tries = 0;
        until (-f $wp || $tries++ > 40) { select undef, undef, undef, 0.1 }
        ok(-f $wp, 'AC3 hold writes the wake-up marker immediately, not when it finishes');
        open my $fh, '<', $wp or die $!;
        my $line = <$fh> // '';
        close $fh;
        my ($written, $bounded, $deadline) = split ' ', $line;
        is($bounded, 'bounded', 'AC3 the marker declares itself bounded');
        cmp_ok(($deadline // 0), '>', time(), 'AC3 with a deadline in the future');
        waitpid($pid, 0);
    }
}

# AC7 — a hold longer than the TTL would expire mid-wait.
{
    my $r = reg();
    run_cli(['arm', '--session', 'sid-ttl'],
            { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r, BP_LEDGER => undef,
              CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    my ($out, $rc) = run_cli(['hold', '--session', 'sid-ttl', '--seconds', '99999'],
                             { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                               CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    is($rc, 1, 'AC4 a hold longer than the wake-up TTL is refused');
    like(kv($out, 'ERROR') // '', qr/TTL/,
         'AC4 and says why -- the marker would expire before the wait ended');
}

# AC8 — holding an unarmed session.
{
    my $r = reg();
    my ($out, $rc) = run_cli(['hold', '--session', 'sid-unarmed', '--seconds', '1'],
                             { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $r,
                               CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef });
    is($rc, 0, 'AC5 holding an unarmed session is not an error');
    like($out, qr/holding_unarmed/, 'AC5 but it says the session is not armed');
    ok(!-f "$r/sid-unarmed.wakeup-pending",
       'AC5 and writes no wake-up marker for a gate that will never look it up');
}

done_testing();
