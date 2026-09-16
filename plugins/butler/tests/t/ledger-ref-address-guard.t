#!/usr/bin/env perl
# platform: any
# A STRINGIFIED PERL REFERENCE MUST NOT REACH A LEDGER BODY.
#
# Observed on a live run, almanac 20260915-191939-da6e. A package's Escalation
# section ended:
#
#     ...or adding the boolean fallback.SCALAR(0x5c7bd4bd3308)
#
# concatenated onto the last sentence with no separator. A writer interpolated a
# reference where it meant the referent. The text that ref pointed at is gone --
# not mis-rendered, LOST -- and nothing refused the write, because the result
# still parses as prose. The Escalation section is precisely what the
# orchestrator and the reporter read to decide what a blocked package needs, so
# the failure is silent in the place it can least afford to be.
#
# THE SHAPE OF THE GUARD IS THE INTERESTING PART, and it is why this is not just
# another validate_bytes rule. run_op validates the ORIGINAL bytes as well as
# the new ones. A blanket rule would therefore reject every subsequent operation
# on a ledger that ALREADY carries this corruption -- bricking the very package
# the rule exists to protect, and doing it to the one blueprint where the bug has
# already fired. So the check is differential: it fires only on an operation that
# INTRODUCES a ref address. Existing damage stays operable and repairable; new
# damage cannot get in.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $LEDGER = "$Bin/../../scripts/bp-ledger.pl";
ok(-f $LEDGER, 'bp-ledger.pl is present') or BAIL_OUT('no bp-ledger.pl');

my $SRC = do { local (@ARGV, $/) = ($LEDGER); <> };

# Lift the two subs out and run them, rather than grepping for their text.
my ($re)    = ($SRC =~ /(my \$REF_ADDR_RE = qr\/.*?\/;)/s);
my ($count) = ($SRC =~ /(sub count_ref_addrs \{.*?\n\})/s);
my ($check) = ($SRC =~ /(sub validate_no_new_ref_addr \{.*?\n\})/s);
ok(defined $re,    'the ref-address pattern is extractable');
ok(defined $count, 'count_ref_addrs is extractable');
ok(defined $check, 'validate_no_new_ref_addr is extractable');

SKIP: {
    skip 'guard not extractable', 14 unless defined $re && defined $count && defined $check;
    my $ok = eval "package TREF; $re $count $check 1";
    ok($ok, 'the extracted guard evaluates') or diag($@);
    skip 'guard did not evaluate', 13 unless $ok;

    my $HEAD = "---\nstatus: reviewing\n---\n\n## Escalation\n\n";

    # ---- A. THE MEASURED STRING. ----
    my $clean  = $HEAD . "Blocked on whether to widen the type or add a fallback.\n";
    my $broken = $HEAD . "Blocked on whether to widen the type or adding the boolean "
               . "fallback.SCALAR(0x5c7bd4bd3308)\n";

    ok(!defined TREF::validate_no_new_ref_addr($clean, $clean),
       'A1: an ordinary body is accepted');
    my $d = TREF::validate_no_new_ref_addr($clean, $broken);
    ok(defined $d, 'A2: the exact string observed on the live run is REJECTED');
    like($d, qr/SCALAR\(0x5c7bd4bd3308\)/,
         'A3: ... and the rejection names the offending value, so the writer bug is findable');
    like($d, qr/LOST/,
         'A4: ... and says what is actually at stake, not just that a pattern matched');

    # ---- B. EVERY REF FLAVOUR, INCLUDING BLESSED. ----
    for my $flavour (qw(SCALAR ARRAY HASH CODE REF GLOB Regexp)) {
        my $body = $HEAD . "text ${flavour}(0xdeadbeef)\n";
        ok(defined TREF::validate_no_new_ref_addr($clean, $body), "B: $flavour is caught");
    }
    ok(defined TREF::validate_no_new_ref_addr($clean, $HEAD . "x My::Class=HASH(0x1a2b3c)\n"),
       'B: a blessed ref, which stringifies with a class prefix, is caught too');

    # ---- C. THE DIFFERENTIAL RULE. This is the assertion that keeps an
    # already-corrupted ledger from becoming unusable. ----
    my $already = $HEAD . "old note.SCALAR(0xaaaa)\n";
    my $plus    = $already . "\nA new attempt entry that is perfectly fine.\n";
    ok(!defined TREF::validate_no_new_ref_addr($already, $plus),
       'C1: an operation on an ALREADY-corrupted ledger is allowed through, so the '
       . 'package stays operable and repairable');

    my $worse = $already . "\nand another.HASH(0xbbbb)\n";
    ok(defined TREF::validate_no_new_ref_addr($already, $worse),
       'C2: ... but an operation that ADDS a second one is still rejected');

    # Removing corruption must never be blocked -- that is the repair path.
    ok(!defined TREF::validate_no_new_ref_addr($already, $clean),
       'C3: an operation that REMOVES the corruption is allowed -- the guard cannot '
       . 'stand in the way of fixing what it detected');

    # ---- D. NOT FOOLED BY PROSE THAT MERELY MENTIONS A TYPE. ----
    ok(!defined TREF::validate_no_new_ref_addr($clean, $HEAD . "Use a HASH for this, not an ARRAY.\n"),
       'D1: prose naming the ref types is not a ref address');
    ok(!defined TREF::validate_no_new_ref_addr($clean, $HEAD . "see HASH(key) for the shape\n"),
       'D2: a parenthesised non-hex argument is not a ref address either');
}

# ---- E. IT IS WIRED INTO THE ONE CHOKEPOINT, ON THE NEW BYTES. ----
my ($runop) = ($SRC =~ /(sub run_op \{.*?\n\})/s);
ok(defined $runop, 'E0: run_op is extractable');
SKIP: {
    skip 'run_op not extractable', 2 unless defined $runop;
    like($runop, qr/validate_no_new_ref_addr\(\$orig,\s*\$new\)/,
         'E1: run_op consults the guard with BOTH bodies, which is what makes it differential');
    my $at_guard = index($runop, 'validate_no_new_ref_addr');
    my $at_write = index($runop, 'cannot open temp file');
    cmp_ok($at_guard, '<', $at_write,
           'E2: ... and does so BEFORE anything is written to disk');
}

done_testing();
