#!/usr/bin/env perl
# platform: any
# Report 20260917-063908-db14.
#
# bp-ledger.pl rejects frontmatter `depends_on:` on EVERY write. The blueprint
# template told authors to emit exactly that key, so blueprints authored before
# the rule landed carry it in every ledger -- and the rejection covers
# `set-status`, the only sanctioned way a coordinator reaches a terminal state.
# Such a package cannot be finished, blocked OR parked, stop-gate.sh will not let
# the session end until it is, and the prescribed remedy was a hand-edit to the
# very frontmatter the protocol tells coordinators never to hand-edit.
#
# `migrate-depends-on` is the sanctioned repair. Its safety property is that
# removing the key must be SUFFICIENT: a ledger broken in some further way is
# left alone and reported rather than half-repaired into a shape whose remaining
# fault now wears a "migrated" label.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use HostCaps qw(tempdir_args);

(my $SCRIPT = "$Bin/../../scripts/bp-ledger.pl") =~ s{\\}{/}g;
ok(-f $SCRIPT, 'bp-ledger.pl is present') or BAIL_OUT("no script at $SCRIPT");

my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);

sub slurp { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $b = <$f>; close $f; return $b }
sub spew  { my ($p, $b) = @_; open my $f, '>:raw', $p or die "open $p: $!"; print {$f} $b; close $f }

# bp-ledger.pl reports refusals through emit_err (stderr) and successes through
# print (stdout), so a harness capturing only stdout would assert against an
# empty string and fail for a reason that has nothing to do with the code.
# Capture BOTH, via a temp file -- reopening STDERR onto an in-memory scalar
# fails with "Bad file descriptor" on Git-for-Windows perl (project CLAUDE.md).
my $errn = 0;
sub run_pl {
    my (@args) = @_;
    my $errf = "$ROOT/stderr." . (++$errn) . ".txt";
    my $rc;
    {
        open(my $saved, '>&', \*STDERR) or die "dup STDERR: $!";
        open(STDERR, '>', $errf) or die "redirect STDERR: $!";
        my @cmd = ($^X, $SCRIPT, @args);
        open(my $fh, '-|', @cmd) or die "spawn: $!";
        my $out = do { local $/; <$fh> };
        close $fh;
        $rc = $? >> 8;
        open(STDERR, '>&', $saved) or die "restore STDERR: $!";
        close $saved;
        my $err = slurp($errf) // '';
        return ($rc, ($out // '') . $err);
    }
}

# A minimal ledger that satisfies every V-check, so the ONLY thing wrong with the
# fixtures below is whatever each test deliberately puts there.
sub base_ledger {
    my (%o) = @_;
    my $extra_fm = $o{extra_fm} // '';
    my $body     = $o{body}     // '';
    return <<"LEDGER";
---
package: 01-demo
blueprint: demo-bp
status: pending
model: sonnet
max_turns: 800
${extra_fm}write_set: plugins/butler/scripts/bp-demo.pl
test_paths: plugins/butler/tests/t/demo-thing.t
checks: perl-compile:plugin-tests
last_updated: 2026-09-18T00:00:00Z
---

# Package 01-demo — demo

## Scope

A demo package.

## Done criteria

It works.

## Pipeline

- [ ] 1. Scout

## Decisions & attempt log

- 2026-09-18T00:00:00Z — created

## Next action

Start at step 1.

## Outputs

None yet.

## Escalation (when status: blocked)

None.
${body}
LEDGER
}

my $n = 0;
sub fixture { my (%o) = @_; my $p = "$ROOT/led." . (++$n) . ".md"; spew($p, base_ledger(%o)); return $p }

# ---- the symptom: a ledger with the key cannot reach a terminal state --------
{
    my $p = fixture(extra_fm => "depends_on: 00-other\n");
    my ($rc) = run_pl('validate', '--ledger', $p);
    is($rc, 2, 'a ledger carrying frontmatter depends_on: fails validate');

    my ($rc2, $out2) = run_pl('set-status', '--ledger', $p, '--status', 'done');
    is($rc2, 2, 'set-status done is REFUSED -- the coordinator cannot terminate');
    like($out2, qr/depends_on: is not a ledger field/, 'and says why');
}

# ---- the repair -------------------------------------------------------------
{
    my $p = fixture(extra_fm => "depends_on: 00-other\n");

    my ($rc_dry, $out_dry) = run_pl('migrate-depends-on', '--ledger', $p, '--dry-run');
    is($rc_dry, 0, 'dry-run succeeds');
    like($out_dry, qr/would move depends_on: 00-other/, 'dry-run names the edge it would move');
    like(slurp($p), qr/^depends_on:/m, 'dry-run changes NOTHING on disk');

    my ($rc, $out) = run_pl('migrate-depends-on', '--ledger', $p);
    is($rc, 0, 'migrate succeeds');
    like($out, qr/moved depends_on: 00-other/, 'and reports the edge it moved');

    my $after = slurp($p);
    unlike($after, qr/\A---\s*\n(?:.*\n)*?depends_on:/m, 'the frontmatter key is gone');
    like($after, qr/^## Dependency edges$/m, 'a Dependency edges section exists');
    like($after, qr/Migrated from frontmatter `depends_on:`.*00-other/,
         'the edge is recorded there, marked as migrated rather than silently dropped');

    my ($rc_v) = run_pl('validate', '--ledger', $p);
    is($rc_v, 0, 'the repaired ledger validates');

    my ($rc_s) = run_pl('set-status', '--ledger', $p, '--status', 'done');
    is($rc_s, 0, 'and set-status done now succeeds -- the package can terminate');
}

# ---- idempotence: a clean ledger is not disturbed ----------------------------
{
    my $p = fixture();
    my $before = slurp($p);
    my ($rc, $out) = run_pl('migrate-depends-on', '--ledger', $p);
    is($rc, 0, 'migrating a ledger with no depends_on: exits 0');
    like($out, qr/nothing to do/, 'and says nothing to do');
    is(slurp($p), $before, 'the file is byte-identical');
}

# ---- multiple keys are all moved --------------------------------------------
{
    my $p = fixture(extra_fm => "depends_on: 00-a\ndepends_on: 00-b\n");
    my ($rc, $out) = run_pl('migrate-depends-on', '--ledger', $p);
    is($rc, 0, 'two depends_on: lines migrate');
    like($out, qr/00-a, 00-b/, 'both edges are named, in file order');
    unlike(slurp($p), qr/^depends_on:/m, 'neither survives in frontmatter');
}

# ---- THE SAFETY PROPERTY -----------------------------------------------------
# Removing the key must be SUFFICIENT. Here the ledger is ALSO missing a required
# section, so the migration must refuse and write nothing -- otherwise the file
# comes back still invalid, now labelled "migrated", and the next reader has a
# harder problem than the one they started with.
{
    my $p = fixture(extra_fm => "depends_on: 00-other\n");
    my $b = slurp($p);
    $b =~ s/^## Outputs\n\nNone yet\.\n//m or die 'fixture: could not remove the Outputs section';
    spew($p, $b);
    my $before = slurp($p);

    my ($rc, $out) = run_pl('migrate-depends-on', '--ledger', $p);
    isnt($rc, 0, 'a ledger with a SECOND fault is refused, not half-repaired');
    like($out, qr/removing depends_on: is not sufficient/, 'the refusal says why');
    like($out, qr/Nothing was written/, 'and states that nothing was written');
    is(slurp($p), $before, 'the file really is untouched');
}

# ---- a depends_on in the BODY is prose and must survive -----------------------
# The rejection message itself, and this repo's own docs, contain the literal
# token. A migration that ran a substitution over the whole file would eat them.
{
    my $p = fixture(extra_fm => "depends_on: 00-other\n",
                    body     => "\n## Dependency edges\n\nWe considered a depends_on: edge here and rejected it.\n");
    my ($rc) = run_pl('migrate-depends-on', '--ledger', $p);
    is($rc, 0, 'migrates cleanly when a Dependency edges section already exists');
    my $after = slurp($p);
    like($after, qr/We considered a depends_on: edge here and rejected it\./,
         'existing prose mentioning the token is untouched');
    like($after, qr/Migrated from frontmatter `depends_on:`.*00-other/,
         'and the migrated edge is added into the existing section');
    my ($rc_v) = run_pl('validate', '--ledger', $p);
    is($rc_v, 0, 'result validates');
}

# ---- argument handling -------------------------------------------------------
{
    my ($rc, $out) = run_pl('migrate-depends-on');
    isnt($rc, 0, '--ledger is required');
    like($out, qr/missing required --ledger/, 'and says so');
}

done_testing();
