#!/usr/bin/env perl
# platform: any
# Bug report 20260922-214319-9389: bp-status.sh and the orchestrator's own
# end-of-run reconcile call both invoke `bp-lifecycle.pl reconcile` without
# --data-dir, so the reconciler falls back to re-deriving ITS OWN data root
# from its cwd. When that guess differs from the data root the caller is
# actually running against, the P4 solo-driver claim check in the
# orphan_running repair (solo_claimed(), which reads
# <data-root>/.drive-solo/inflight.json, spec 16-cutover 2.8) looks in the
# wrong place, reads a missing file, and silently returns false -- so a genuinely live,
# solo-claimed package loses its protection and gets repaired out from under
# a real driver.
#
# Two call sites, two fixtures:
#   A. bp-status.sh's two `reconcile` invocations (--blueprint and --all) --
#      captured via a stub bp-lifecycle.pl dropped beside a copy of
#      bp-status.sh/bp-lib.sh, so the real argv can be inspected without
#      running the reconciler for real.
#   B. bp-orchestrator.pl's end-of-run reconcile call -- exercised for real
#      (a genuine bp-lifecycle.pl subprocess), reproducing the full defeat:
#      a solo-claimed package's ledger flips to pending anyway when the data
#      root is wrong, and stays running once it is threaded through
#      correctly. Also pins the extracted pure helper, BpOrch::lifecycle_data_dir.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;

my $DIR     = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }));
my $SCRIPTS = "$DIR/../../scripts";
my $STATUS_SH = "$SCRIPTS/bp-status.sh";
my $LIB_SH    = "$SCRIPTS/bp-lib.sh";
my $LIFECYCLE = "$SCRIPTS/bp-lifecycle.pl";
my $ORCH      = "$SCRIPTS/bp-orchestrator.pl";

ok(-f $STATUS_SH, 'bp-status.sh exists') or BAIL_OUT('nothing to test');
ok(-f $LIB_SH,    'bp-lib.sh exists')    or BAIL_OUT('nothing to test');
ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');
ok(-f $ORCH,      'bp-orchestrator.pl exists') or BAIL_OUT('nothing to test');

require $ORCH;

my $J = JSON::PP->new->canonical->pretty;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

# ===========================================================================
# A. bp-status.sh: argv capture via a stub bp-lifecycle.pl.
#
# A fresh SCRIPT_DIR holds a copy of bp-status.sh + bp-lib.sh (bp-status.sh
# sources bp-lib.sh via "$SCRIPT_DIR/bp-lib.sh", so both must sit together)
# plus a stub bp-lifecycle.pl that only dumps its own @ARGV to a file and
# exits 0 -- the real reconciler is never run here, only the CALLER's
# command line is inspected.
# ===========================================================================
{
    my $work = tempdir(CLEANUP => 1);
    my $bin  = "$work/bin";
    make_path($bin);
    copy($STATUS_SH, "$bin/bp-status.sh") or die "copy bp-status.sh: $!";
    copy($LIB_SH,    "$bin/bp-lib.sh")    or die "copy bp-lib.sh: $!";
    chmod 0755, "$bin/bp-status.sh";

    my $argv_file = "$work/argv.txt";
    write_file("$bin/bp-lifecycle.pl", <<'PERL');
#!/usr/bin/env perl
open my $fh, '>>', $ENV{ARGV_CAPTURE_FILE} or die $!;
print $fh join("\x1f", @ARGV), "\n";
close $fh;
exit 0;
PERL
    chmod 0755, "$bin/bp-lifecycle.pl";

    my $proj = "$work/proj";
    my $data = "$proj/.ccpraxis-local-data";
    make_path("$data/blueprints/onlybp");
    write_file("$data/blueprints/onlybp/blueprint.md", "# onlybp\n\n## Package status\n\n");

    sub run_status {
        my (@args) = @_;
        my @cmd = ('bash', "$bin/bp-status.sh", @args);
        local $ENV{BP_PROJECT_ROOT}      = $proj;
        local $ENV{ARGV_CAPTURE_FILE}    = $argv_file;
        unlink $argv_file if -f $argv_file;
        my $rc = system(@cmd);
        return $rc;
    }

    run_status();
    my @lines = defined(slurp($argv_file)) ? split(/\n/, slurp($argv_file)) : ();
    is(scalar(@lines), 1, 'A (--all path): bp-status.sh with no argument invokes the stub bp-lifecycle.pl exactly once');
    my @argv = split(/\x1f/, $lines[0] // '');
    ok((grep { $_ eq '--data-dir' } @argv),
       'A (--all path, bp-status.sh:47): the reconcile call now carries --data-dir')
        or diag('argv: ' . join(' ', @argv));
    my ($i) = grep { $argv[$_] eq '--data-dir' } 0 .. $#argv;
    is($argv[$i + 1], $data,
       'A (--all path): --data-dir names the SAME data root bp-status.sh itself resolved (BP_PROJECT_ROOT-derived), not something else')
        if defined $i;

    run_status('onlybp');
    @lines = defined(slurp($argv_file)) ? split(/\n/, slurp($argv_file)) : ();
    is(scalar(@lines), 1, 'A (--blueprint path): bp-status.sh <name> invokes the stub bp-lifecycle.pl exactly once');
    @argv = split(/\x1f/, $lines[0] // '');
    ok((grep { $_ eq '--data-dir' } @argv),
       'A (--blueprint path, bp-status.sh:44): the reconcile call now carries --data-dir')
        or diag('argv: ' . join(' ', @argv));
    ($i) = grep { $argv[$_] eq '--data-dir' } 0 .. $#argv;
    is($argv[$i + 1], $data,
       'A (--blueprint path): --data-dir names the same resolved data root')
        if defined $i;
}

# ===========================================================================
# B1. BpOrch::lifecycle_data_dir($bpdir) -- pure helper unit test.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/proj/.ccpraxis-local-data/blueprints/bp1";
    make_path($bpdir);
    is(BpOrch::lifecycle_data_dir($bpdir), abs_path("$root/proj/.ccpraxis-local-data"),
       'B1: lifecycle_data_dir finds the .ccpraxis-local-data ancestor of $bpdir');

    my $plain = tempdir(CLEANUP => 1);
    is(BpOrch::lifecycle_data_dir("$plain/blueprints/bp2"), undef,
       'B1: lifecycle_data_dir is undef when no .ccpraxis-local-data ancestor exists (no wrong guess ever offered)');

    is(BpOrch::lifecycle_data_dir(undef), undef, 'B1: lifecycle_data_dir(undef) is undef, never dies');
}

# ===========================================================================
# B2. bp-orchestrator.pl's end-of-run reconcile call, exercised for real:
# a solo-claimed, orphan-shaped package must survive the run whether or not
# bp-lifecycle.pl's OWN cwd-derived guess happens to agree with the real data
# root. $ENV{BP_PROJECT_ROOT} is pinned to an unrelated decoy tempdir for the
# whole block so bp-lifecycle.pl's fallback (project_root(), which checks
# BP_PROJECT_ROOT before ever touching git or cwd) is deterministic and
# provably wrong -- the fix must override it via --data-dir regardless.
# ===========================================================================
{
    my $root  = tempdir(CLEANUP => 1);
    my $decoy = tempdir(CLEANUP => 1);   # a data root that is NOT this fixture's
    my $proj  = "$root/proj";
    my $bpdir = "$proj/.ccpraxis-local-data/blueprints/T1";
    make_path("$bpdir/packages", "$bpdir/runs");

    write_file("$bpdir/blueprint.md", <<'MD');
# T1

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
| p1 | thing | — | sonnet | running |

## Harvest log

## Incidents
MD

    write_file("$bpdir/packages/p1.md", <<'MD');
---
package: p1
blueprint: T1
status: running
write_set: src/
test_paths: t/
last_updated: 2026-01-01T00:00:00Z
---

# Package p1

## Next action

None.
MD

    # p1 carries NO marker, NO registry row, NO pidfile -- the AC4d/e shape
    # from t/unreapable-running.t: nothing else claims it alive, so only the
    # solo-claim pointer stands between it and the orphan_running repair.
    # Batch C (spec 16-cutover 2.8, reason DEL): solo_claimed is re-pointed
    # from current.json to inflight.json -- current.json is gone.
    write_file("$proj/.ccpraxis-local-data/.drive-solo/inflight.json",
        $J->encode({ packages => [
            { blueprint => 'T1', package => 'p1', ledger => 'x/blueprints/T1/packages/p1.md', since => 1_800_000_000 },
        ], updated_at => 1_800_000_000 }));

    write_file("$bpdir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (2_000_000_000 * 1000), scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));

    my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                                seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });

    my %opt = (
        blueprint => 'T1', bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
        tunables  => { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 600,
                       watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
                       jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60,
                       busy_path => "$root/busy", harvest => 'audit', resolve_cap => 1,
                       corr_cap => 1, judge_to => 1800, judge_spawn_cap => 2, conformance_spawn_cap => 2 },
        once => 1, now => sub { 1_800_000_000 }, sleep => sub {},
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        launch    => sub { 0 },
        spawn_judge => sub { 0 },
        pid_alive   => sub { 0 },
    );

    local $ENV{BP_PROJECT_ROOT} = $decoy;   # deliberately wrong for bp-lifecycle.pl's own fallback
    local $ENV{IS_SANDBOX} = 1;             # matches t/unreapable-running.t's own gate precondition

    my $err;
    eval { BpOrch::run({ %opt }); 1 } or $err = $@;

    my $after = slurp("$bpdir/packages/p1.md") // '';
    like($after, qr/^status:\s*running\s*$/m,
         'B2: a solo-claimed, orphan-shaped package survives the orchestrator\'s own end-of-run reconcile '
       . 'even though BP_PROJECT_ROOT points bp-lifecycle.pl\'s OWN fallback at an unrelated decoy root')
        or diag("ledger after run:\n$after\nrun err: " . ($err // '(none)'));
}

done_testing();
