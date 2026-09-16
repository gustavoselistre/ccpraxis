#!/usr/bin/env perl
# platform: any
# THE VAULT LOCK WROTE THE HOLDER'S PID DOWN AND NEVER READ IT.
#
# acquire_lock records three things about whoever holds the vault lock: session
# id, PID, and a timestamp. Only the timestamp was ever read back. A holder that
# died -- killed, crashed, or taken out along with the whole WSL VM, which is a
# documented failure mode on this host -- left every project in the vault waiting
# out the full $LOCK_STALE_SEC ceiling, with nothing able to tell "someone is
# working" from "nobody is there" (almanac 20260829-193916-e091).
#
# The report called it an indefinite wedge. It is not quite that: a 30-minute
# age-based reclaim has existed since 387309e, so the lock does self-heal. That
# makes this less severe than filed, and still worth fixing -- thirty minutes is
# a backstop, not an answer, and the recorded PID could have answered instantly
# the whole time.
#
# THE ASYMMETRY IS THE POINT, and it is the same one launcher.pl's _pid_alive
# documents: kill(0,...) can prove a process EXISTS, and on ESRCH under a
# foreign PID namespace it proves nothing at all. So only a positive "dead"
# may reclaim. An unknown answer must fall through to the age ceiling -- because
# reclaiming a lock whose holder is still working would let two syncs write the
# vault simultaneously, while waiting thirty minutes merely costs time. Every
# assertion below exists to hold that direction in place.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $VS = "$Bin/../../scripts/vault-sync.pl";
ok(-f $VS, 'vault-sync.pl is present') or BAIL_OUT('no vault-sync.pl');
my $SRC = do { local (@ARGV, $/) = ($VS); <> };

# ===========================================================================
# A. THE PROBE, EXTRACTED AND RUN AGAINST REAL PIDS.
# ===========================================================================
my ($fn) = ($SRC =~ /(sub lock_holder_is_dead \{.*?\n\})/s);
ok(defined $fn, 'A0: lock_holder_is_dead is extractable');

SKIP: {
    skip 'probe not extractable', 8 unless defined $fn;
    my $ok = eval "package TLOCK; $fn 1";
    ok($ok, 'A1: the extracted probe evaluates') or diag($@);
    skip 'probe did not evaluate', 7 unless $ok;

    ok(!TLOCK::lock_holder_is_dead($$),
       'A2: this very process is not reported dead');

    # A PID that cannot exist. Chosen high and verified absent rather than
    # assumed: if something really is running there, the assertion would be
    # asserting the opposite of what it says.
    my $ghost = 999_999;
    $ghost++ while kill(0, $ghost) && $ghost < 1_000_050;
  SKIP: {
        skip 'could not find a provably-absent pid on this host', 1 if kill(0, $ghost);
        ok(TLOCK::lock_holder_is_dead($ghost),
           'A3: a provably absent PID IS reported dead -- the reclaim this fix exists for');
    }

    # Everything unusable must read as ALIVE, never dead. These are the
    # assertions that stop a malformed lock file from handing the vault to two
    # writers at once.
    for my $junk (undef, '', 'not-a-pid', '0', -1, '12x', [ 1 ]) {
        my $label = defined $junk ? (ref $junk ? ref $junk : "'$junk'") : 'undef';
        ok(!TLOCK::lock_holder_is_dead($junk),
           "A4: an unusable pid ($label) is NOT treated as dead");
    }
}

# ===========================================================================
# B. THE DECISION ORDER INSIDE acquire_lock.
#
# Our-own-lock first, then liveness, then the age ceiling, then refuse. The
# ceiling must SURVIVE as the fallback: it is what covers the case where
# liveness cannot be determined, including PID reuse.
# ===========================================================================
my ($acq) = ($SRC =~ /(sub acquire_lock \{.*?\n\})/s);
ok(defined $acq, 'B0: acquire_lock is extractable') or BAIL_OUT('acquire_lock gone');

like($acq, qr/lock_holder_is_dead\(\$info->\{pid\}\)/,
     'B1: acquire_lock consults the holder PID it has been recording all along');
like($acq, qr/\$age > \$LOCK_STALE_SEC/,
     'B2: the age ceiling is still there as the fallback for an undeterminable holder');

my $i_self  = index($acq, 'eq $SESSION_ID');
my $i_dead  = index($acq, 'lock_holder_is_dead');
my $i_age   = index($acq, '$age > $LOCK_STALE_SEC');
cmp_ok($i_self, '<', $i_dead, 'B3: our own lock is recognised before any liveness probe');
cmp_ok($i_dead, '<', $i_age,  'B4: a dead holder reclaims without waiting out the ceiling');

# ===========================================================================
# C. THE REFUSAL SAYS WHO. "Held by another session" with no PID, no age and no
# path gave an operator nothing to act on, at five separate call sites.
# ===========================================================================
my ($detail) = ($SRC =~ /(sub lock_refusal_detail \{.*?\n\})/s);
ok(defined $detail, 'C0: lock_refusal_detail is extractable');

SKIP: {
    skip 'detail builder not extractable', 4 unless defined $detail;
    my $ok = eval "package TDET; our \$LOCK_STALE_SEC = 1800; our %LAST_LOCK_REFUSAL; $detail 1";
    ok($ok, 'C1: the extracted builder evaluates') or diag($@);
    skip 'builder did not evaluate', 3 unless $ok;

    {
        no warnings 'once';
        %TDET::LAST_LOCK_REFUSAL = ();
    }
    is(TDET::lock_refusal_detail(), '',
       'C2: with nothing recorded it adds nothing -- no fabricated detail');

    {
        no warnings 'once';
        %TDET::LAST_LOCK_REFUSAL = (pid => 4321, age => 95, path => '/v/.lock');
    }
    my $txt = TDET::lock_refusal_detail();
    like($txt, qr/pid 4321/,      'C3: the refusal names the holding PID');
    like($txt, qr/held for 95s/,  'C4: ... and how long it has held, so the ceiling is predictable');
}

# Every call site must actually use it, or C is decoration.
my @bare = ($SRC =~ /emit_error\("Vault lock held by another session\."\)/g);
is(scalar @bare, 0,
   'C5: no call site still emits the bare, unactionable message');
my @rich = ($SRC =~ /emit_error\("Vault lock held by another session\." \. lock_refusal_detail\(\)\)/g);
cmp_ok(scalar @rich, '>=', 5,
       'C6: every one of the five call sites carries the detail');

done_testing();
