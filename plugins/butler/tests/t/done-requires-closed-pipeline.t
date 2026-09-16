#!/usr/bin/env perl
# "status: done" WITH PIPELINE STEPS STILL OPEN IS THE SILENT FAILURE.
#
# bp-drive-next.pl SKIPS a package whose status is done. So a package marked done
# prematurely stops being scheduled: its review never runs, its fix-batch never
# runs, its validation is never recorded -- and nothing reports any of it. It
# simply reads as finished. Three packages ended that way in one run (almanac
# 20260911-224554-e404):
#
#   05-normalisation-verify  done, steps 4-8 open, no review report on disk
#   02-rich-extraction       done, step 6 open (review had run; checkbox missed)
#   04-merged-links          done, steps 7-8 open (8 genuinely never ran)
#
# Two of those were the driver's own bookkeeping; one came from a second writer.
# The origins differ and the end state is identical, which is the argument for a
# check rather than for more care.
#
# It is silent BY CONSTRUCTION. A destructive git command announces itself when a
# test fails against a missing file. A falsely-completed package announces
# nothing; it was found by accident, by a human filling in a status table.
#
# THE ASSERTION THAT MATTERS MOST HERE IS THE ONE THAT ALLOWS. A gate on the
# ledger write path can wedge every package in every run, so the conditional
# steps -- step 1 "skip if scope already maps cleanly", step 8 "only if package
# touches UI" -- must keep passing while unchecked. Most packages touch no UI.
# Section C is not politeness; it is the assertion that stops this fix from
# being worse than the bug.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

my $LEDGER = "$Bin/../../scripts/bp-ledger.pl";
ok(-f $LEDGER, 'bp-ledger.pl is present') or BAIL_OUT('no bp-ledger.pl');
my $SRC = do { local (@ARGV, $/) = ($LEDGER); <> };

# ===========================================================================
# A. THE PREDICATE, EXTRACTED AND RUN.
# ===========================================================================
my ($fn) = ($SRC =~ /(sub open_unconditional_steps \{.*?\n\})/s);
ok(defined $fn, 'A0: open_unconditional_steps is extractable');

my $PIPE = <<'PIPE';
## Pipeline

- [x] 1. Scout (skip if scope already maps cleanly — record the skip)
- [x] 2. Spec written to specs/01-x-spec.md and checked against done criteria
- [x] 3. Tests written from spec (bp-test-writer) and sanity-checked against spec
- [x] 4. Implementation converged (bp-implementer; tests immutable; loop <= 4 attempts)
- [x] 5. Validation suite green from disk (commands + exit codes recorded below)
- [x] 6. Review || red-team complete (report paths below)
- [x] 7. Fix-batch applied (single dispatch) and re-validated
- [ ] 8. UI pass (only if package touches UI) — screenshots read, checklist applied

## Decisions & attempt log
PIPE

SKIP: {
    skip 'predicate not extractable', 9 unless defined $fn;
    my $ok = eval "package TDONE; $fn 1";
    ok($ok, 'A1: the extracted predicate evaluates') or diag($@);
    skip 'predicate did not evaluate', 8 unless $ok;

    # ---- B. THE OBSERVED CASES. ----
    my $six_open = $PIPE;
    $six_open =~ s/- \[x\] 6\./- [ ] 6./;
    my @o = TDONE::open_unconditional_steps($six_open);
    is(scalar @o, 1, 'B1: 02-rich-extraction, step 6 open, is caught');
    like($o[0], qr/Review/, 'B2: ... and the step is named, so the message is actionable');

    my $many = $PIPE;
    $many =~ s/- \[x\] ([4567])\./- [ ] $1./g;
    is(scalar TDONE::open_unconditional_steps($many), 4,
       'B3: 05-normalisation-verify, four steps open, counts all four');

    # ---- C. THE CONDITIONAL STEPS MUST STILL PASS. ----
    is(scalar TDONE::open_unconditional_steps($PIPE), 0,
       'C1: the canonical pipeline with only step 8 (UI, "only if") unchecked is ACCEPTED -- '
       . 'most packages touch no UI and this gate must not wedge them');

    my $no_scout = $PIPE;
    $no_scout =~ s/- \[x\] 1\./- [ ] 1./;
    is(scalar TDONE::open_unconditional_steps($no_scout), 0,
       'C2: step 1 ("skip if scope already maps cleanly") unchecked is ACCEPTED too');

    # ---- D. THE DELIBERATE-SKIP MARKER. ----
    my $tilde = $PIPE;
    $tilde =~ s/- \[x\] 7\./- [~] 7./;
    is(scalar TDONE::open_unconditional_steps($tilde), 0,
       'D1: "- [~]" marks a step deliberately skipped, so it stops looking like a forgotten one');

    # ---- E. SCOPE AND TOTALITY. ----
    my $other = "## Outputs\n\n- [ ] not a pipeline step at all\n\n" . $PIPE;
    is(scalar TDONE::open_unconditional_steps($other), 0,
       'E1: an unchecked box in another section is not a pipeline step');
    is(scalar TDONE::open_unconditional_steps(undef), 0, 'E2: undef input is total, not fatal');
}

# ===========================================================================
# F. END TO END. The refusal must happen BEFORE anything reaches disk -- an
# earlier draft hung this on run_op's $post_cb, which fires after the rename.
# ===========================================================================
my $tmp = tempdir(CLEANUP => 1);

sub write_ledger {
    my ($pipe) = @_;
    my $p = "$tmp/pkg-" . (++our $n) . ".md";
    open my $fh, '>:raw', $p or die $!;
    # All five REQUIRED_KEYS. An earlier draft omitted two, and set-status then
    # failed on the FRONTMATTER -- so F1 went green while the gate under test was
    # never reached at all. F2 is what caught it; a refusal assertion that does
    # not check the reason is not checking anything.
    print $fh "---\npackage: x\nblueprint: b\nstatus: reviewing\n"
            . "write_set: scripts/x.pl\nlast_updated: 2026-09-16T00:00:00Z\n---\n\n"
            . "## Next action\n\nnone\n\n$pipe\n\nnothing\n\n## Outputs\n\nnone\n\n## Escalation\n\nnone\n";
    close $fh;
    return $p;
}

my $open_one = $PIPE;
$open_one =~ s/- \[x\] 6\./- [ ] 6./;
my $bad = write_ledger($open_one);
my $before = do { local (@ARGV, $/) = ($bad); <> };
my $out = `perl "$LEDGER" set-status --ledger "$bad" --status done 2>&1`;
my $rc  = $? >> 8;
my $after = do { local (@ARGV, $/) = ($bad); <> };

isnt($rc, 0, 'F1: set-status done is REFUSED while an unconditional step is open');
like($out, qr/unchecked/i, 'F2: ... and says what is unchecked');
is($after, $before, 'F3: ... and the ledger on disk is byte-for-byte unchanged, so the '
                  . 'refusal beat the write rather than following it');

my $good = write_ledger($PIPE);
my $out2 = `perl "$LEDGER" set-status --ledger "$good" --status done 2>&1`;
is($? >> 8, 0, 'F4: a pipeline with only conditional steps open is ACCEPTED end to end')
    or diag($out2);
my $after2 = do { local (@ARGV, $/) = ($good); <> };
like($after2, qr/^status:\s*done/m, 'F5: ... and the status really was written');

done_testing();
