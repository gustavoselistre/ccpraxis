#!/usr/bin/env perl
# platform: any
# 04-model-allocation oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/fleet-cost-accounting/specs/04-model-allocation-spec.md
# (6 observable behaviors, AC1/AC2; AC3/AC4 are inspection/documentation-only per the
# spec and are NOT tested here -- see §4/§9 of the spec).
#
# This package is documentation-only in effect: both templates ALREADY default
# `model: sonnet` today (nothing flips), so T1/T2's `sonnet`-presence assertions are
# expected to PASS even before implementation -- only the measured-basis-citation
# assertions (84-95%, 4.7x, shell-activity finding, report id) are expected to be RED,
# since that prose does not exist in either template yet. T3 exercises `add-package
# --model`'s existing, already-implemented behavior on the blueprint.md package-status
# TABLE (not a ledger -- confirmed by the scout: add-package never touches a ledger
# file). T4/T5 exercise the REAL ledger-population mechanism -- copying
# templates/package-ledger.md verbatim, the actual `/blueprint:create` authoring
# action -- rather than add-package, which cannot populate a ledger at all.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Cwd qw(abs_path);
use lib "$Bin/../lib";
use HostCaps qw(tempdir_args);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $REPO   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";

diag("subject templates: $REPO/plugins/blueprint/templates/{package-ledger.md,blueprint.md}");

my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $pn = 0;

# =====================================================================================
# Scaffolding (self-contained, matching sibling .t convention e.g. blueprint-set-title.t).
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub run_pl {
    my ($args) = @_;
    my $n = ++$pn;
    my ($outf, $errf) = ("$ROOT/out.$n", "$ROOT/err.$n");
    write_file($outf, '');
    write_file($errf, '');
    local %ENV = (%CLEAN_ENV, MAD_SCRIPT => fwd($SCRIPT), MAD_OUT => fwd($outf), MAD_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$MAD_SCRIPT" "$@" > "$MAD_OUT" 2> "$MAD_ERR"', 'bp-blueprint', @$args);
    my ($code, $out, $err) = ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
    return ($code, $out, $err);
}

# Minimal valid package-status table fixture -- same shape blueprint-set-title.t's
# base_fixture uses, matching locate_table's requirement (a `|`-row containing
# "depends_on" inside/under a "## Package status" heading).
sub table_fixture {
    return join("\n",
        '# <Blueprint Title>',
        '',
        '## Package status',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        '| b01 | first thing | — | sonnet |',
        '',
        '## Decisions',
        '',
        '- an earlier decision.',
        '',
    );
}

# =====================================================================================
# T1 -- package-ledger.md default + basis citations (AC1 / Done clause 1)
# =====================================================================================
{
    my $tpl = read_file("$REPO/plugins/blueprint/templates/package-ledger.md");
    ok(defined $tpl && length $tpl, 'T1: package-ledger.md template is readable')
        or diag("could not read templates/package-ledger.md");

    like($tpl, qr/^model:\s*sonnet\b/m,
        'T1(AC1): ledger template still defaults model: sonnet (regression-guard, expected to '
      . 'already PASS -- nothing flips here per spec Context)');

    # Co-location: the basis lines are the comment run immediately following the
    # model: line, before the next non-comment key (max_turns:) -- not a fragile
    # exact-text match, a substring/co-location match per spec T1.
    my ($frag) = $tpl =~ /^model:\s*sonnet\b(.*?)^max_turns:/ms;
    ok(defined $frag,
        'T1(AC1): a comment run exists between `model: sonnet` and the next `max_turns:` key')
        or diag('no such fragment found -- the co-location assertions below will also fail');
    $frag //= '';

    like($frag, qr/84-95%/,
        'T1(AC1): cites the coordinator cost-share range (84-95%) adjacent to model: sonnet');
    like($frag, qr/4\.7x/i,
        'T1(AC1): cites the Opus/Sonnet per-call multiplier (4.7x) adjacent to model: sonnet');
    like($frag, qr/\bBash\b/,
        'T1(AC1): cites the shell-activity finding (Bash-call dominance) adjacent to model: sonnet');
    like($frag, qr/20260917-172750-285a/,
        'T1(AC1): cites the source report id (20260917-172750-285a) adjacent to model: sonnet');
}

# =====================================================================================
# T2 -- blueprint.md default + basis citations (AC1 / Done clause 1)
# =====================================================================================
{
    my $bp = read_file("$REPO/plugins/blueprint/templates/blueprint.md");
    ok(defined $bp && length $bp, 'T2: blueprint.md template is readable')
        or diag("could not read templates/blueprint.md");
    $bp //= '';

    like($bp, qr/\|\s*01-<slug>\s*\|.*\|\s*sonnet\s*\|/,
        'T2(AC1): package-status example row still shows sonnet (regression-guard, expected to '
      . 'already PASS -- nothing flips here per spec Context)');
    like($bp, qr/-\s*\*\*model:\*\*\s*sonnet\b/,
        'T2(AC1): per-package example block\'s model: bullet still shows sonnet (regression-guard, '
      . 'expected to already PASS)');

    like($bp, qr/84-95%/, 'T2(AC1): basis -- cost-share range (84-95%) present in blueprint.md');
    like($bp, qr/4\.7x/i, 'T2(AC1): basis -- Opus/Sonnet multiplier (4.7x) present in blueprint.md');
    like($bp, qr/20260917-172750-285a/,
        'T2(AC1): basis -- source report id present in blueprint.md');

    # Co-location, loose window: the multiplier citation appears within ~15 lines of at
    # least one `sonnet` occurrence, tolerating incidental reformatting while still
    # refusing a citation dumped somewhere unrelated in the file (spec T2 comment).
    my @lines = split /\n/, $bp, -1;
    my @sonnet_idx = grep { $lines[$_] =~ /\bsonnet\b/i } 0 .. $#lines;
    my @multiplier_idx = grep { $lines[$_] =~ /4\.7x/i } 0 .. $#lines;
    my $co_located = 0;
    OUTER: for my $s (@sonnet_idx) {
        for my $m (@multiplier_idx) {
            if (abs($s - $m) <= 15) { $co_located = 1; last OUTER; }
        }
    }
    ok($co_located,
        'T2(AC1): the 4.7x multiplier citation appears within 15 lines of a sonnet occurrence '
      . '(co-location window, not a fragile exact-line match)');
}

# =====================================================================================
# T3 -- add-package --model writes the blueprint.md TABLE cell (AC2a / Done clause 2)
# existing, already-implemented behavior -- proven here for the first time (scout: no
# such test currently exists), and pinned precisely per spec §7 edge cases (the empty-
# cell-on-omitted-model behavior must not silently change out from under this package).
# =====================================================================================
{
    my $path = "$ROOT/blueprint-t3a.md";
    write_file($path, table_fixture());
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $path, '--pkg', 'zz-probe',
                                    '--deliverable', 'x', '--model', 'opus']);
    is($rc, 0, 'T3(AC2a): add-package --model opus exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/\|\s*zz-probe\s*\|[^\n]*\|\s*opus\s*\|\s*$/m,
        'T3(AC2a): the new row\'s model cell reads "opus"');
}
{
    my $path = "$ROOT/blueprint-t3b.md";
    write_file($path, table_fixture());
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $path, '--pkg', 'zz-probe-2',
                                    '--deliverable', 'y']);
    is($rc, 0, 'T3(AC2a): add-package with --model omitted exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/\|\s*zz-probe-2\s*\|[^\n]*\|\s*\|\s*$/m,
        'T3(AC2a): the new row\'s model cell is empty when --model is omitted '
      . '(existing, documented `:791` behavior -- regression-guarded here, not fixed)');
}

# =====================================================================================
# T4 -- the REAL ledger-population mechanism: template copy (AC2b / Done clause 2)
# No script performs this step; it is /blueprint:create's human/coordinator authoring
# action. Simulated directly, per spec T4 -- NOT via add-package, which never touches
# a ledger file at all (scout-confirmed landmine, spec §1/§2).
# =====================================================================================
{
    my $dest = "$ROOT/new-ledger.md";
    my $ok_copy = copy("$REPO/plugins/blueprint/templates/package-ledger.md", $dest);
    ok($ok_copy, 'T4(AC2b): template-copy fixture step succeeds') or diag("copy failed: $!");
    my $ledger = read_file($dest);
    like($ledger, qr/^model:\s*sonnet\b/m,
        'T4(AC2b): a freshly-authored ledger (real copy mechanism) gets the sonnet default');
}

# =====================================================================================
# T5 -- a ledger's model: is independently overridable, without mutating the template
# (AC2c / Done clause 2)
# =====================================================================================
{
    my $tpl_before = read_file("$REPO/plugins/blueprint/templates/package-ledger.md");

    my $dest = "$ROOT/new-ledger-2.md";
    copy("$REPO/plugins/blueprint/templates/package-ledger.md", $dest)
        or die "copy failed: $!";
    my $ledger = read_file($dest);
    (my $overridden = $ledger) =~ s/^model:\s*sonnet\b/model: opus/m;
    write_file($dest, $overridden);

    like(read_file($dest), qr/^model:\s*opus\b/m,
        'T5(AC2c): a copied ledger can carry a non-default model value');

    is(read_file("$REPO/plugins/blueprint/templates/package-ledger.md"), $tpl_before,
        'T5(AC2c): editing a copied ledger never mutates the template on disk');
}

# No test targets AC3 (sequencing, Done clause 3) or AC4 (run/replay comparison, Done
# clause 4) -- both are evidence/documentation acceptance criteria satisfied in the
# ledger's ## Outputs section, per spec §4/§9, deliberately not embedded here.

done_testing();
