#!/usr/bin/env perl
# any_active's liveness filter does not pin the machine-global wake-lock
# behind a crashed session for up to 12h.
#
# THE BUG THIS PINS (20260916-134204-3645). A crashed session's marker is
# FRESH BY MTIME — nothing touched it after the crash — so the 12h TTL alone
# counted it as armed until some unrelated session's Stop hook happened to
# sweep the registry. any_active() now also asks whether the marker's session
# id resolves to a transcript that is itself still moving, and skips the
# marker (never deletes it) when the transcript is provably stale.
#
# THE REJECTED FIX, AND WHY THIS ONE LOOKS DIFFERENT ON DISK. The report's
# "minimum" alternative was to have this lease consult lib.sh's REAPING
# any_active — which would let a detached background process delete another
# session's state, exactly what the comment above any_active forbids. This
# fix is read-only: every case below re-asserts that the marker file still
# exists after the call, which is the one property that tells the two fixes
# apart from the outside.
#
# THE SEAM. Production resolves a session id to a transcript path through
# BpSession::find_transcript; tests override $BpContinuityLease::FIND_TRANSCRIPT
# with a coderef so no fixture ever has to touch the real ~/.claude/projects
# tree — same shape as the $PLATFORM seam this file already uses.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

# Silences perl's "used only once" for a package var read exactly once below;
# it is a real cross-package reference, not a typo.
() = \$BpContinuityLease::TRANSCRIPT_LIVENESS_SECONDS;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpContinuityLease.pm";

delete $ENV{$_} for qw(
    CCPRAXIS_CONTINUITY_TTL_H
    CCPRAXIS_CONTINUITY_LEASE_TICK
    CCPRAXIS_CONTINUITY_ACTIVE_DIR
    BP_BUSY_PATH
);

sub reg {
    my $d = tempdir(CLEANUP => 1);
    make_path("$d/pending");
    return $d;
}

sub mk {
    my ($p, $age) = @_;
    open my $fh, '>', $p or die $!;
    print {$fh} "x\n";
    close $fh;
    if ($age) { my $t = time - $age; utime($t, $t, $p) }
    return $p;
}

my $TDIR = tempdir(CLEANUP => 1);

# ---------------------------------------------- fresh transcript -> counted --
{
    my $d = reg();
    mk("$d/sess-fresh");
    my $transcript = mk("$TDIR/fresh.jsonl");   # mtime: now

    local $BpContinuityLease::FIND_TRANSCRIPT = sub {
        my ($sid) = @_;
        return $sid eq 'sess-fresh' ? $transcript : undef;
    };

    is(BpContinuityLease::any_active($d), 1,
       'a marker whose transcript is still fresh -> counted');
    ok(-f "$d/sess-fresh", 'and the marker was not touched, let alone deleted');
}

# --------------------------------------- stale transcript -> skipped ---------
# Paired with a counter-fixture (refreshing the SAME transcript back to now)
# so the stale branch is shown to actually fire, not merely to pass vacuously.
{
    my $d = reg();
    mk("$d/sess-stale");
    my $transcript = mk("$TDIR/stale.jsonl");
    my $stale_at = time - ($BpContinuityLease::TRANSCRIPT_LIVENESS_SECONDS + 400);
    utime($stale_at, $stale_at, $transcript);

    local $BpContinuityLease::FIND_TRANSCRIPT = sub { return $transcript };

    is(BpContinuityLease::any_active($d), 0,
       'a marker whose transcript is older than the liveness window -> skipped, '
     . 'even though it is still within the 12h TTL');
    ok(-f "$d/sess-stale",
       'skipped, not reaped -- the marker file still exists (the property the '
     . 'rejected fix could not have preserved)');

    # Counter-fixture: same marker, same session id, transcript now fresh.
    utime(time, time, $transcript);
    is(BpContinuityLease::any_active($d), 1,
       'the identical marker counts again once its transcript is fresh -- proves '
     . 'the stale branch above was doing real work, not vacuously passing');
}

# --------------------------------------- no transcript at all -> fail-safe ---
{
    my $d = reg();
    mk("$d/sess-none");

    local $BpContinuityLease::FIND_TRANSCRIPT = sub { return undef };

    is(BpContinuityLease::any_active($d), 1,
       'no transcript resolves at all -> counted (undeterminable, fail SAFE)');
    ok(-f "$d/sess-none", 'and nothing was deleted while failing safe');
}

# --------------------------------------- future mtime -> fail-safe -----------
{
    my $d = reg();
    mk("$d/sess-future");
    my $transcript = mk("$TDIR/future.jsonl");
    my $future = time + 3600;
    utime($future, $future, $transcript);

    local $BpContinuityLease::FIND_TRANSCRIPT = sub { return $transcript };

    is(BpContinuityLease::any_active($d), 1,
       'a transcript stamped in the future -> counted -- clock skew is not '
     . 'evidence of death, and this is a different question from ensure_daemon\'s '
     . 'own future-pid-file check, which treats a future stamp as stale on purpose '
     . 'for an unrelated reason');
    ok(-f "$d/sess-future", 'and nothing was deleted');
}

# --------------------------------------- a failed stat -> fail-safe ----------
{
    my $d = reg();
    mk("$d/sess-vanished");

    local $BpContinuityLease::FIND_TRANSCRIPT = sub { return "$TDIR/does-not-exist.jsonl" };

    is(BpContinuityLease::any_active($d), 1,
       'find_transcript resolves to a path that no longer stats -> counted, fail SAFE');
    ok(-f "$d/sess-vanished", 'and nothing was deleted');
}

# ------------------------------------- past the 12h TTL still wins outright --
# The liveness filter is ADDITIVE, never a reason to count a marker the TTL
# already rejected -- a fresh transcript must not resurrect an expired marker.
{
    my $d = reg();
    my $p = mk("$d/sess-expired");
    my $expired_at = time - 13 * 3600;
    utime($expired_at, $expired_at, $p);
    my $transcript = mk("$TDIR/still-fresh.jsonl");   # would read as live on its own

    local $BpContinuityLease::FIND_TRANSCRIPT = sub { return $transcript };

    is(BpContinuityLease::any_active($d), 0,
       'a marker past the 12h TTL stays not-armed even with a fresh transcript -- '
     . 'the filter only ever narrows, never widens, what the TTL already counted');
    ok(-f "$d/sess-expired", 'and, as ever, it is not reaped here');
}

done_testing();
