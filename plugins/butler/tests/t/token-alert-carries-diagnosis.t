#!/usr/bin/env perl
# platform: any
# Report 20260917-110321-ff63.
#
# A 4xx on the sandbox's own OAuth refresh pauses the fleet with manual=1 -- a
# pause that never self-clears, so a human is always fetched. The message they
# were fetched with named TWO causes ("the copied token may be invalid OR the
# host/sandbox token grants have DIVERGED") and carried nothing to tell them
# apart. The keeper cannot distinguish them from inside, said the report, so the
# operator is handed a question rather than a finding.
#
# It was also wrong the one time it fired. On 2026-09-17 the host had been in
# Modern Standby for over three hours; the keeper woke four seconds later,
# refreshed under the floor, got 400, and reported a possible architectural
# fault. One second afterwards an authenticated usage poll returned 200. The
# credentials were fine.
#
# Three facts now discriminate, and all three are observable in-process:
#   creds_rewritten  -- .credentials.json changed underneath us => another holder
#                       rotated the grant and ours is stale. Divergence OBSERVED.
#   expired_by_s     -- the token was already past expiry when we called.
#   suspend_gap_s    -- this host just came back from a suspend
#                       (runs/.last-suspend.json; report 20260917-155603-b83e).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-token-keeper.pl";

my $ROOT = tempdir(CLEANUP => 1);
my $J    = JSON::PP->new->canonical;
my $n    = 0;

# A token 30 minutes from expiry sits under the 10-minute floor? No -- it sits
# ABOVE it, and keeper_tick would return 'ok' without ever calling out. Every
# case below must actually reach the refresh, so the token is put just inside
# the floor.
sub creds_file {
    my (%o) = @_;
    my $p = "$ROOT/creds." . (++$n) . ".json";
    open my $f, '>', $p or die "open $p: $!";
    print {$f} $J->encode({ claudeAiOauth => {
        accessToken  => 'acc',
        refreshToken => 'ref',
        expiresAt    => $o{expires_at},
        scopes       => ['user:inference'],
    } });
    close $f;
    return $p;
}

my $NOW_MS = 1_800_000_000_000;               # fixed clock
my $NOW_S  = int($NOW_MS / 1000);

# Under the floor: expiry 5 minutes out (floor is 10 minutes).
sub under_floor { creds_file(expires_at => $NOW_MS + 5 * 60 * 1000) }

sub tick {
    my (%o) = @_;
    my $log = "$ROOT/log." . (++$n) . ".jsonl";
    my $r = BpKeeper::keeper_tick({
        creds_path => $o{creds},
        now_ms     => $NOW_MS,
        log_path   => $log,
        http_post  => sub { { status => ($o{status} // 400), content => '{}' } },
        (exists $o{recent_suspend}      ? (recent_suspend      => $o{recent_suspend})      : ()),
        (exists $o{creds_mtime_at_read} ? (creds_mtime_at_read => $o{creds_mtime_at_read}) : ()),
    });
    my $logtxt = do { local $/; open my $h, '<', $log or return ($r, ''); my $b = <$h>; close $h; $b // '' };
    return ($r, $logtxt);
}

# ---- the shape of the return is unchanged ------------------------------------
{
    my ($r) = tick(creds => under_floor());
    is($r->{action}, 'pause-auth', 'a 4xx still pauses for auth');
    is($r->{alert},  1,            'and is still flagged as a loud alert');
}

# ---- THE REGRESSION CASE: a wake explains it, so divergence is NOT asserted ---
{
    my ($r, $log) = tick(
        creds => under_floor(),
        recent_suspend => { gap_secs => 10_800, at_epoch => $NOW_S - 4 },
    );
    is($r->{action}, 'pause-auth', 'still pauses -- the verdict did not get softer');
    unlike($r->{detail}, qr/DIVERGED/,
           'the alert does NOT claim diverged grants when the host just woke');
    like($r->{detail}, qr/resumed from a 10800s suspend/,
         'it names the suspend and its size');
    like($r->{detail}, qr/Try re-authenticating with \/login before concluding/,
         'and points at the cheap action before the expensive conclusion');
    like($log, qr/"suspend_gap_s":10800/, 'the logged diagnostics carry the gap');
}

# ---- a wake LONG ago does not excuse anything --------------------------------
{
    my ($r) = tick(
        creds => under_floor(),
        recent_suspend => { gap_secs => 10_800, at_epoch => $NOW_S - 86_400 },
    );
    like($r->{detail}, qr/ALERT/, 'a day-old suspend does not suppress the alert');
    like($r->{detail}, qr/no recent host suspend explains it/,
         'and the message says the suspend was not recent enough to explain it');
}

# ---- DIVERGENCE OBSERVED: the creds file was rewritten underneath us ----------
{
    my $c = under_floor();
    # A stale recorded mtime means "the file changed since we read it".
    my ($r, $log) = tick(creds => $c, creds_mtime_at_read => 1);
    like($r->{detail}, qr/WAS REWRITTEN by another party/,
         'a rewritten credentials file is reported as the divergence case');
    like($r->{detail}, qr/observed rather than guessed/,
         'and says it is observed rather than guessed');
    like($log, qr/"creds_rewritten":1/, 'the diagnostic is in the log too');
}

# ---- a wake does NOT mask a real divergence ----------------------------------
# The combination matters: if the file was rewritten, the suspend is not the
# story, even if one just happened.
{
    my $c = under_floor();
    my ($r) = tick(creds => $c, creds_mtime_at_read => 1,
                   recent_suspend => { gap_secs => 10_800, at_epoch => $NOW_S - 4 });
    like($r->{detail}, qr/WAS REWRITTEN by another party/,
         'a rewritten file wins over a recent wake -- divergence is not masked');
}

# ---- no suspend, no rewrite: the original conclusion, now justified -----------
{
    my ($r, $log) = tick(creds => under_floor());
    like($r->{detail}, qr/ALERT/, 'the loud alert survives when nothing explains the 4xx');
    like($r->{detail}, qr/the copied token is invalid on its own terms/,
         'and it now states a finding rather than offering two options');
    like($log, qr/"creds_rewritten":0/, 'with the discriminating facts recorded');
}

# ---- diagnostics are present and typed ---------------------------------------
{
    my ($r) = tick(creds => under_floor());
    is(ref $r->{diag}, 'HASH', 'the return carries a diag hash');
    is($r->{diag}{http_status}, 400, 'including the status');
    ok(exists $r->{diag}{expires_at},   'the token expiry');
    ok(exists $r->{diag}{expired_by_s}, 'and how far past expiry it was');
}

# ---- an ALREADY-EXPIRED token reports how long it had been dead ---------------
{
    my $c = creds_file(expires_at => $NOW_MS - 120_000);   # 2 minutes past expiry
    my ($r) = tick(creds => $c);
    is($r->{diag}{expired_by_s}, 120,
       'an already-expired grant reports its age, so "ordinary expiry" is checkable');
}

# ---- 200 still refreshes: the success path is untouched ------------------------
{
    my $c = under_floor();
    my $log = "$ROOT/ok.jsonl";
    my $r = BpKeeper::keeper_tick({
        creds_path => $c, now_ms => $NOW_MS, log_path => $log,
        http_post  => sub { { status => 200, content => $J->encode({
            access_token => 'new', refresh_token => 'newref', expires_in => 3600,
            scope => 'user:inference', token_type => 'Bearer' }) } },
    });
    is($r->{action}, 'refreshed', 'a 200 still refreshes -- the happy path is untouched');
}

# ---- a 429 is still a backoff, not an alert ----------------------------------
{
    my $c = creds_file(expires_at => $NOW_MS + 60 * 60 * 1000);   # above the floor
    my ($r) = tick(creds => $c, status => 429);
    is($r->{action}, 'backoff', 'a 429 above the floor still backs off');
    ok(!defined $r->{alert}, 'and raises no alert');
}

done_testing();
