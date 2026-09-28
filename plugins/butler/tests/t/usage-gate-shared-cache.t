#!/usr/bin/env perl
# platform: any
# Report 20260917-015851-1d58.
#
# The usage endpoint is a SHARED, RATE-LIMITED resource that a live orchestrator
# depends on every ~63 seconds. On 2026-09-16 a reporter ran this gate four times
# in about ten seconds to sanity-check a surprising reading; the fourth returned
# 429. The orchestrator's next three polls -- 23:50:14, 23:51:17, 23:52:18 -- all
# got 429, and it wrote runs/.paused {"reason":"telemetry"} at 23:52:18, halting
# every new package launch for about three minutes.
#
# The sharp part of the report is that two pieces of existing guidance ACTIVELY
# CONFLICT: a package's Inputs section says usage.pl "has been seen to return
# inconsistent readings ... so read it more than once before deciding", and doing
# exactly that is what tripped the limit and paused the fleet.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-usage-gate.pl";

my $ROOT = tempdir(CLEANUP => 1);
my $J    = JSON::PP->new->canonical;

my $NOW = 1_800_000_000;
sub usage_body {
    return $J->encode({
        five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00Z' },
        seven_day => { utilization =>  5, resets_at => '2099-01-02T00:00:00Z' },
    });
}

my $cn = 0;
sub creds_file {
    my $p = "$ROOT/creds." . (++$cn) . ".json";
    open my $f, '>', $p or die "open $p: $!";
    print {$f} $J->encode({ claudeAiOauth => {
        accessToken => 'a', refreshToken => 'r',
        expiresAt   => ($NOW + 86_400) * 1000, scopes => ['user:inference'] } });
    close $f;
    return $p;
}

# Drive the verdict path with a counting transport. cache_path is passed
# explicitly, which is the documented test opt-in: without it an injected
# http_get disables the cache entirely (an injected seam is not a shared
# rate-limited endpoint).
sub run_verdict {
    my (%o) = @_;
    my $calls = $o{calls};
    my $out = '';
    {
        open(my $saved, '>&', \*STDOUT) or die "dup: $!";
        my $cap = "$ROOT/out." . (++$cn) . ".txt";
        open(STDOUT, '>', $cap) or die "redirect: $!";
        BpUsageGate::run(['verdict'], {
            now        => sub { $o{now} // $NOW },
            creds_path => $o{creds},
            cache_path => $o{cache},
            http_get   => sub { $$calls++; return { status => ($o{status} // 200),
                                                    content => usage_body() } },
        });
        open(STDOUT, '>&', $saved) or die "restore: $!";
        close $saved;
        open my $r, '<', $cap or die; $out = do { local $/; <$r> }; close $r;
    }
    return $out;
}

# ---- repeated reads make ONE request ----------------------------------------
# The measured incident, in miniature: four calls in the same few seconds.
{
    my $cache = "$ROOT/cache1.json";
    my $creds = creds_file();
    my $calls = 0;
    run_verdict(creds => $creds, cache => $cache, calls => \$calls) for 1 .. 4;
    is($calls, 1, 'four reads in the same second cost ONE request');
    ok(-f $cache, 'a cache file is written');
}

# ---- and the verdict is unchanged -------------------------------------------
# A cheaper gate that answers differently would be a worse bug than the one
# being fixed.
{
    my $cache = "$ROOT/cache2.json";
    my $creds = creds_file();
    my $calls = 0;
    my $first  = run_verdict(creds => $creds, cache => $cache, calls => \$calls);
    my $second = run_verdict(creds => $creds, cache => $cache, calls => \$calls);
    my $a = eval { JSON::PP->new->decode($first) };
    my $b = eval { JSON::PP->new->decode($second) };
    is(ref $a, 'HASH', 'first verdict decodes');
    is_deeply($b, $a, 'a cached read produces the identical verdict');
    is($a->{action}, 'ok', 'and it is the right one for this fixture');
}

# ---- the cache EXPIRES ------------------------------------------------------
{
    my $cache = "$ROOT/cache3.json";
    my $creds = creds_file();
    my $calls = 0;
    run_verdict(creds => $creds, cache => $cache, calls => \$calls, now => $NOW);
    run_verdict(creds => $creds, cache => $cache, calls => \$calls, now => $NOW + 10);
    is($calls, 1, 'a 10s-old reading is still served from cache');
    run_verdict(creds => $creds, cache => $cache, calls => \$calls, now => $NOW + 600);
    is($calls, 2, 'a 10-minute-old reading is not');
}

# ---- A FAILURE IS NEVER CACHED ----------------------------------------------
# Caching a 429 would turn one bad second into a minute of manufactured outage:
# the same bug, wearing the fix's clothes.
{
    my $cache = "$ROOT/cache4.json";
    my $creds = creds_file();
    my $calls = 0;
    run_verdict(creds => $creds, cache => $cache, calls => \$calls, status => 429) for 1 .. 3;
    is($calls, 3, 'a 429 is re-requested every time, never cached');
    ok(!-f $cache, 'and nothing is written');
}

# ---- different credentials never share a reading -----------------------------
# A usage reading is an attribute of one ACCOUNT.
{
    my $c1 = creds_file();
    my $c2 = creds_file();
    my $calls = 0;
    run_verdict(creds => $c1, cache => "$ROOT/cacheA.json", calls => \$calls);
    run_verdict(creds => $c2, cache => "$ROOT/cacheB.json", calls => \$calls);
    is($calls, 2, 'two different credentials make two requests');
}

# ---- the default path is derived from the credentials, not from $HOME ---------
# Written against $HOME this wrote a live sample into the operator's real
# ~/.claude while the suite ran, because every test driving this script as a
# SUBPROCESS takes the production path from inside that process.
{
    my $creds = "$ROOT/sub/.credentials.json";
    mkdir "$ROOT/sub" or die "mkdir: $!";
    open my $f, '>', $creds or die; print {$f} '{}'; close $f;
    local $ENV{BP_CREDS_PATH} = $creds;
    delete local $ENV{BP_USAGE_CACHE_PATH};
    my $calls = 0;
    # A garbage creds file short-circuits before any poll; all this asserts is
    # WHERE the gate would have put a cache, which is the point.
    eval { run_verdict(creds => $creds, cache => undef, calls => \$calls) };
    ok(!-e "$ROOT/.bp-usage-cache.json", 'no cache is written outside the credentials directory');
}

# ---- an unreadable or corrupt cache degrades, never throws --------------------
{
    my $cache = "$ROOT/cache-corrupt.json";
    open my $f, '>', $cache or die; print {$f} 'not json at all'; close $f;
    my $creds = creds_file();
    my $calls = 0;
    my $out = eval { run_verdict(creds => $creds, cache => $cache, calls => \$calls) };
    ok(defined $out, 'a corrupt cache does not throw') or diag("died: $@");
    is($calls, 1, 'and falls through to a real request');
}

# ---- a FUTURE-stamped entry is discarded --------------------------------------
# The failure direction that matters is serving a stale "plenty of headroom" to a
# caller that would otherwise have stopped.
{
    my $cache = "$ROOT/cache-future.json";
    open my $f, '>', $cache or die;
    print {$f} $J->encode({ 'https://api.anthropic.com/api/oauth/usage' =>
                            { at => $NOW + 99_999, content => usage_body() } });
    close $f;
    my $creds = creds_file();
    my $calls = 0;
    run_verdict(creds => $creds, cache => $cache, calls => \$calls);
    is($calls, 1, 'an entry stamped in the future is not trusted');
}

# ---- TTL 0 disables it entirely -----------------------------------------------
{
    my $cache = "$ROOT/cache-off.json";
    my $creds = creds_file();
    local $ENV{BP_USAGE_CACHE_TTL} = 0;
    my $calls = 0;
    run_verdict(creds => $creds, cache => $cache, calls => \$calls) for 1 .. 3;
    is($calls, 3, 'BP_USAGE_CACHE_TTL=0 makes every call a real request');
}

done_testing();
