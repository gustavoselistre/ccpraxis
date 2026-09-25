#!/usr/bin/env perl
# platform: any
# any_active's liveness filter does not pin the machine-global wake-lock
# behind a crashed session for up to 12h.
#
# THE BUG THIS PINS (20260916-134204-3645). A crashed session's marker is
# FRESH BY MTIME — nothing touched it after the crash — so a TTL alone
# would count it as armed until some unrelated session's Stop hook happened
# to sweep the registry. any_active() also asks whether the marker's session
# resolves to a transcript that is itself still moving, and skips the
# marker (never deletes it) when the transcript is provably stale.
#
# Batch C (spec 16-cutover, criterion C-6, reason DEL/SW): this file
# originally exercised the LEGACY registry's per-marker liveness filter
# (_marker_is_live, resolved through the $FIND_TRANSCRIPT seam and
# BpSession::find_transcript). That whole mechanism is deleted -- any_active
# no longer reads the legacy registry at all (see BpContinuityLease.pm's
# any_active header). Retargeted to the SAME liveness questions against the
# NEW store instead: a real armed/<sid> file (via BpHook::arm's
# transcript_path option), read through new_store_active/
# _transcript_path_is_live, which any_active() calls via store_root_for().
# The final case ("past the 12h TTL still wins outright") is DELETED
# outright rather than retargeted: Decision 53 (see
# continuity-lease-follows-arm.t's R6-D53(a)) makes that exact claim FALSE
# for the new store -- a determinable, live transcript now overrides the
# arm file's own stale mtime, the opposite of what this case asserted.
#
# THE REJECTED FIX, AND WHY THIS ONE LOOKS DIFFERENT ON DISK. The report's
# "minimum" alternative was to have this lease consult the old bash registry's REAPING
# any_active — which would let a detached background process delete another
# session's state, exactly what the comment above any_active forbids. This
# fix is read-only: every case below re-asserts that the arm file still
# exists after the call, which is the one property that tells the two fixes
# apart from the outside.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";

# Silences perl's "used only once" for package vars read exactly once below;
# real cross-package references, not typos.
() = \$BpContinuityLease::STATE_ROOT;
() = \$BpContinuityLease::TRANSCRIPT_LIVENESS_SECONDS;

delete $ENV{$_} for qw(
    CCPRAXIS_CONTINUITY_TTL_H
    CCPRAXIS_CONTINUITY_LEASE_TICK
    CCPRAXIS_CONTINUITY_ACTIVE_DIR
    BP_BUSY_PATH
);

sub mk {
    my ($p, $age) = @_;
    open my $fh, '>', $p or die $!;
    print {$fh} "x\n";
    close $fh;
    if ($age) { my $t = time - $age; utime($t, $t, $p) }
    return $p;
}

# fresh_env() -- a fresh $home (BUTLER_STATE_DIR) and a fresh legacy dir
# (unused for arming now, kept only because any_active($dir) still takes a
# legacy-shaped path argument; store_root_for maps it to $home/continuity).
sub fresh_env {
    my $t = tempdir(CLEANUP => 1);
    (my $home = "$t/home") =~ s{\\}{/}g;
    make_path($home);
    (my $legacy = "$t/legacy") =~ s{\\}{/}g;
    make_path($legacy);
    $ENV{BUTLER_STATE_DIR}               = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    return ($home, $legacy);
}

my $TDIR = tempdir(CLEANUP => 1);
my $SEQ = 0;
sub next_sid { return 'sess-' . (++$SEQ) . '-' . $$ }

# ---------------------------------------------- fresh transcript -> counted --
{
    local %ENV = %ENV;
    my ($home, $legacy) = fresh_env();
    my $transcript = mk("$TDIR/fresh-$$.jsonl");   # mtime: now
    my $sid = next_sid();

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $transcript),
        'setup: arm succeeds with a fresh transcript_path');
    my $armed_path = BpHook::state_dir() . "/armed/$sid";

    is(BpContinuityLease::any_active($legacy), 1,
       'a marker whose transcript is still fresh -> counted');
    ok(-f $armed_path, 'and the arm file was not touched, let alone deleted');
}

# --------------------------------------- stale transcript -> skipped ---------
# Paired with a counter-fixture (refreshing the SAME transcript back to now)
# so the stale branch is shown to actually fire, not merely to pass vacuously.
{
    local %ENV = %ENV;
    my ($home, $legacy) = fresh_env();
    my $transcript = mk("$TDIR/stale-$$.jsonl");
    my $stale_at = time - ($BpContinuityLease::TRANSCRIPT_LIVENESS_SECONDS + 400);
    utime($stale_at, $stale_at, $transcript);
    my $sid = next_sid();

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $transcript),
        'setup: arm succeeds with a stale transcript_path');
    my $armed_path = BpHook::state_dir() . "/armed/$sid";

    is(BpContinuityLease::any_active($legacy), 0,
       'a marker whose transcript is older than the liveness window -> skipped, '
     . 'even though the arm file itself is fresh by mtime');
    ok(-f $armed_path,
       'skipped, not reaped -- the arm file still exists (the property the '
     . 'rejected fix could not have preserved)');

    # Counter-fixture: same arm file, same session id, transcript now fresh.
    utime(time, time, $transcript);
    is(BpContinuityLease::any_active($legacy), 1,
       'the identical marker counts again once its transcript is fresh -- proves '
     . 'the stale branch above was doing real work, not vacuously passing');
}

# --------------------------------------- no transcript at all -> fail-safe ---
{
    local %ENV = %ENV;
    my ($home, $legacy) = fresh_env();
    my $sid = next_sid();

    ok(BpHook::arm($sid, role => 'manual', by => 'on'),
        'setup: arm succeeds with NO transcript_path at all');
    my $armed_path = BpHook::state_dir() . "/armed/$sid";

    is(BpContinuityLease::any_active($legacy), 1,
       'no transcript_path on the arm file at all -> counted by mtime (undeterminable, fail SAFE)');
    ok(-f $armed_path, 'and nothing was deleted while failing safe');
}

# --------------------------------------- future mtime -> fail-safe -----------
{
    local %ENV = %ENV;
    my ($home, $legacy) = fresh_env();
    my $transcript = mk("$TDIR/future-$$.jsonl");
    my $future = time + 3600;
    utime($future, $future, $transcript);
    my $sid = next_sid();

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $transcript),
        'setup: arm succeeds with a future-stamped transcript_path');
    my $armed_path = BpHook::state_dir() . "/armed/$sid";

    is(BpContinuityLease::any_active($legacy), 1,
       'a transcript stamped in the future -> counted -- clock skew is not '
     . 'evidence of death, and this is a different question from ensure_daemon\'s '
     . 'own future-pid-file check, which treats a future stamp as stale on purpose '
     . 'for an unrelated reason');
    ok(-f $armed_path, 'and nothing was deleted');
}

# --------------------------------------- a failed stat -> fail-safe ----------
{
    local %ENV = %ENV;
    my ($home, $legacy) = fresh_env();
    my $sid = next_sid();

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => "$TDIR/does-not-exist-$$.jsonl"),
        'setup: arm succeeds with a transcript_path that does not stat');
    my $armed_path = BpHook::state_dir() . "/armed/$sid";

    is(BpContinuityLease::any_active($legacy), 1,
       'a transcript_path that no longer stats -> counted, fail SAFE');
    ok(-f $armed_path, 'and nothing was deleted');
}

done_testing();
