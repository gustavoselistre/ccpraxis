#!/usr/bin/env perl
# platform: any
# Enforces four naming rules across every file collected by
# glob("plugins/*/tests/t/*.t") -- the exact same collection expression
# scripts/run-tests.pl uses to build its suite:
#
#   R1 -- lowercase kebab-case, no numeric prefix
#   R2 -- every basename globally unique across all plugins
#   R3 -- a file's own leading comment block never repeats its own basename
#   R4 -- every basename is at least two hyphen-separated words
#
# R3's positive "citing a SIBLING file is legal" case is covered by an inline
# unit test of the header_self_references() subroutine below, not by a
# throwaway fixture file on disk -- see plugins/butler/tests/t/oracle-
# hygiene.t for why a convention needs to run in the suite to matter at all.
#
# THIS FILE IS ITSELF SCANNED BY ITS OWN R1-R4 CHECKS. Its header must not
# repeat its own filename, so it doesn't -- describe intent, never cite self.

use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use FindBin qw($Bin);

my $ROOT = "$Bin/../../../..";

# ---------------------------------------------------------------------------
# header_self_references($header_text, $basename)
#
# TRUE if $header_text names this file, FALSE otherwise. Citing a DIFFERENT
# file is not a self-reference.
#
# TOKEN-AWARE, per Decision 11, which supersedes Decision 8's R3 clause. The
# stem counts only when it stands as a WHOLE FILENAME TOKEN:
#
#   left  — not preceded by [A-Za-z0-9_-]
#   right — followed by ".t", OR by something that is not [A-Za-z0-9_.-]
#
# The original rule was a plain substring test, and it was wrong in two ways
# that only showed up once the tree was actually renamed:
#
#   1. It forbade a test from naming the very script it tests whenever the two
#      share a name. gate-headless-background.t could not write
#      "gate-headless-background.sh" in its header. Roughly twelve headers had
#      to be reworded into unnatural word order to avoid reproducing a literal
#      filename that referred to a DIFFERENT FILE.
#   2. It fired on ordinary English. A file named hard-exclude.t whose header
#      says "hard-excludes are honoured" matched, because the plural contains
#      the stem. That inflated the real violation count from ~140 to 193.
#
# Decision 3's intent was to stop a file carrying a second stale copy of ITS
# OWN name. A sibling .sh/.pl/.pm filename is not that, and neither is an
# English plural — so neither bought any staleness protection, while both cost
# the clearest sentence a header can contain.
#
# A bare stem with no extension IS still a self-reference ("# the
# dashboard-framework oracle"), so Decision 8's stated intent — a citation that
# drops the extension is still caught — is preserved exactly.
# ---------------------------------------------------------------------------
sub header_self_references {
    my ($header_text, $basename) = @_;
    return 0 unless defined $header_text && defined $basename;
    (my $stem = $basename) =~ s/\.t$//;
    return 0 unless length $stem;
    my $q = quotemeta $stem;
    return $header_text =~ /(?<![A-Za-z0-9_-])$q(?:\.t|(?![A-Za-z0-9_.-]))/ ? 1 : 0;
}

# ---------------------------------------------------------------------------
# extract_header($filepath)
#
# The contiguous run of lines from line 1 that are either a shebang (#!...)
# or a plain #-comment line, stopping at the first line that is neither
# (blank line, "use strict;", etc.) -- both forms start with "#", so a
# single leading-"#" test on each line covers both without special-casing
# the shebang separately.
# ---------------------------------------------------------------------------
sub extract_header {
    my ($filepath) = @_;
    open my $fh, '<', $filepath or return '';
    my $header = '';
    while (my $line = <$fh>) {
        last unless $line =~ /^#/;
        $header .= $line;
    }
    close $fh;
    return $header;
}

# ---------------------------------------------------------------------------
# find_self_ref($filepath, $stem)
#
# Diagnostic helper only: returns (line_number, line_text) of the first
# header line containing $stem, for a readable failure message. Returns
# (0, '') if none found.
# ---------------------------------------------------------------------------
sub find_self_ref {
    my ($filepath, $stem) = @_;
    open my $fh, '<', $filepath or return (0, '');
    my $lineno = 0;
    while (my $line = <$fh>) {
        $lineno++;
        last unless $line =~ /^#/;
        if (index($line, $stem) >= 0) {
            chomp $line;
            close $fh;
            return ($lineno, $line);
        }
    }
    close $fh;
    return (0, '');
}

# ---------------------------------------------------------------------------
# Collect the REAL tree -- same expression as scripts/run-tests.pl:64. Not
# fixtured, not special-cased: R1/R2/R4 must fail for real if a future PR
# reintroduces a numbered file under plugins/*/tests/t/.
# ---------------------------------------------------------------------------
my @files = sort glob("$ROOT/plugins/*/tests/t/*.t");

ok(scalar(@files) > 0, 'collected at least one file via glob("plugins/*/tests/t/*.t")')
    or BAIL_OUT('no test files collected -- glob expression is broken, nothing else in this file can be trusted');

# --- R1 (AC-1) --------------------------------------------------------------
my @r1_violations;
for my $f (@files) {
    my $b = basename($f);
    push @r1_violations,
        "R1: '$b' does not match ^[a-z][a-z0-9-]*\\.t\$ (lowercase kebab-case, no numeric prefix)"
        unless $b =~ /^[a-z][a-z0-9-]*\.t$/;
}
unless (ok(@r1_violations == 0,
    'R1: every collected basename is lowercase kebab-case with no numeric prefix (AC-1)')) {
    diag($_) for @r1_violations;
}

# --- R2 (AC-2) --------------------------------------------------------------
my %by_basename;
push @{ $by_basename{ basename($_) } }, $_ for @files;

my @r2_violations;
for my $name (sort keys %by_basename) {
    my @paths = @{ $by_basename{$name} };
    next unless @paths > 1;
    push @r2_violations,
        "R2: basename '$name' is used by " . scalar(@paths) . " files: " . join(', ', @paths);
}
unless (ok(@r2_violations == 0,
    'R2: every basename is unique across all plugins (AC-2)')) {
    diag($_) for @r2_violations;
}

# --- R4 (AC-5) --------------------------------------------------------------
my @r4_violations;
for my $f (@files) {
    my $b = basename($f);
    (my $stem = $b) =~ s/\.t$//;
    push @r4_violations,
        "R4: '$b' is a single word (no hyphen) -- needs at least two hyphen-separated words"
        unless $stem =~ /^[a-z0-9]+(-[a-z0-9]+)+$/;
}
unless (ok(@r4_violations == 0,
    'R4: every basename has at least two hyphen-separated words (AC-5)')) {
    diag($_) for @r4_violations;
}

# --- R3 negative case, real tree (AC-3) -------------------------------------
my @r3_violations;
for my $f (@files) {
    my $b = basename($f);
    (my $stem = $b) =~ s/\.t$//;
    my $header = extract_header($f);
    if (header_self_references($header, $b)) {
        my ($lineno, $text) = find_self_ref($f, $stem);
        push @r3_violations,
            "R3: '$b' names its own basename in its header (line $lineno: $text)";
    }
}
unless (ok(@r3_violations == 0,
    "R3: no file's header contains its own stem as a substring (AC-3)")) {
    diag($_) for @r3_violations;
}

# --- R3 positive case, sibling citation stays legal (AC-4 / AC-7) ----------
# Deliberately an inline-string unit test of header_self_references() rather
# than a throwaway fixture file on disk -- no real file exercised a full
# hyphenated sibling citation before this guard existed, so this is the
# mechanism of record for the sibling-legal behavior, not a substitute for
# scanning the real tree above.
ok(!header_self_references(
        "# See judge-decision-core.t for the seam test.\n",
        "graceful-stop-gate.t",
    ),
    'header_self_references(): citing a SIBLING basename is not a self-reference (AC-4 / AC-7)');

ok(header_self_references(
        "# graceful-stop-gate.t -- the gate matrix.\n",
        "graceful-stop-gate.t",
    ),
    'header_self_references(): citing its OWN basename IS a self-reference (sanity check for the negative case above)');

ok(!header_self_references('', 'graceful-stop-gate.t'),
    'header_self_references(): an empty header cannot self-reference');

# --- Decision 11: the token-aware boundaries -------------------------------
# Each of these was a FALSE POSITIVE under the original plain-substring rule,
# and each cost something real: the first forced ~12 headers into unnatural
# word order, the second inflated the tree's violation count from ~140 to 193.

ok(!header_self_references(
        "# Proves gate-headless-background.sh denies a backgrounded Bash call.\n",
        "gate-headless-background.t",
    ),
    'naming the .sh script under test is NOT a self-reference (Decision 11, right boundary)');

ok(!header_self_references(
        "# The bp-write-guard.pl containment rules.\n",
        "write-guard.t",
    ),
    'a longer name that merely ENDS with the stem is not a self-reference (Decision 11, left boundary)');

ok(!header_self_references(
        "# hard-excludes are honoured at WALK time.\n",
        "hard-exclude.t",
    ),
    'an English plural containing the stem is not a self-reference (Decision 11, right boundary)');

# ...and the boundaries must not have opened a hole. Decision 8's own stated
# intent — a citation that drops the extension is still caught — must survive.

ok(header_self_references(
        "# the dashboard-framework oracle, and what it covers.\n",
        "dashboard-framework.t",
    ),
    'a BARE stem with no extension is still a self-reference (Decision 8 intent preserved)');

ok(header_self_references(
        "# Runs standalone: perl plugins/butler/tests/t/resources-panel.t\n",
        "resources-panel.t",
    ),
    'a full self-path citation is still a self-reference');

ok(header_self_references(
        "# resources-panel, the probe oracle.\n",
        "resources-panel.t",
    ),
    'a bare stem followed by a comma is still a self-reference');

done_testing();
