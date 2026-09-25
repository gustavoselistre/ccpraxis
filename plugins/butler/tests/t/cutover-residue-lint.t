#!/usr/bin/env perl
# platform: any
#
# Oracle for package 16-cutover, batch E2 (blueprint hook-continuity-remake).
# Derived ONLY from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/16-cutover-spec.md
# section 2.11 ("Residue lint") and section 4's E2-1/E2-2 rows. WRITTEN BLIND to
# any implementation: it is authored before batch E2's comment/message edits
# land, so the real-tree scan below is EXPECTED to fail now, naming the
# lingering residue those edits still have to clear.
#
# What this proves:
#   - every file this package's earlier batches deleted has left no textual
#     trace (basename, word-boundary matched) anywhere under the scanned
#     tree, outside the Decision 21 exemptions and the one approved
#     absence-pin;
#   - the three retired concurrency-switch identifiers are gone from every
#     scanned file outside plugins/*/tests/;
#   - hooks/next and any SKILL.next.md are gone from disk;
#   - the "never re-run a sibling test" allowlist names no deleted file.
#
# The deletion set and why it is embedded here, not read live off the doc:
# section 2.11 says this test parses "plugins/butler/docs/hook-architecture.md,
# section## Deletion list" for its list of paths. At authoring time (after
# batches A, B, C, D and E1 have already landed) that section's own text says
# every path it used to enumerate is gone, and no longer lists any of them --
# batch E1 trimmed the last entries away in the same commit that deleted their
# files, per that section's stated "trimmed after each batch" rule. Parsing it
# now yields zero paths, which would make the whole basename scan vacuous.
# That is not what E2 is for (its file list names dozens of comments and
# messages this batch must still edit), so this file ALSO embeds the full
# historical set -- reconstructed from the doc's own pre-trim content at
# commit 6638aa8, cross-checked against every batch's own "Files:" and
# deletion prose in the spec -- and unions it with whatever the doc parses to
# right now. Flagged in the report as the one place this oracle had to fill a
# gap the spec's "parse the doc" instruction no longer produces data for.
#
# The embedded set is stored ROT13-encoded and decoded at load time. Not
# obfuscation for its own sake: this file lives under plugins/, so it is a
# member of its own scanned tree, and a handful of its 80 entries (a
# same-named hook, a same-named script) are short enough that spelling them
# in clear text here would make this file fail its own scan forever. ROT13
# only permutes ASCII letters, so the decoded value never appears in the
# file's own bytes. The same reasoning applies to the E2-1 non-vacuity
# fixtures below: each literal that would otherwise hit is assembled from two
# concatenated fragments, split so neither fragment alone spells the target.
#
# Spawns exactly one process (git ls-files), per spec 2.11's own budget. No
# tempdir, no butler-state, no .ccpraxis-local-data read.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(basename);

$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $ROOT = "$Bin/../../../..";

# ---------------------------------------------------------------------------
# rot13 -- symmetric; only ASCII letters move.
# ---------------------------------------------------------------------------
sub rot13 {
    my ($s) = @_;
    $s =~ tr/A-Za-z/N-ZA-Mn-za-m/;
    return $s;
}

# ---------------------------------------------------------------------------
# The embedded historical deletion set (ROT13-encoded repo-relative paths).
# Reconstructed from git history (commit 6638aa8's pristine doc list) plus
# run-finish-guard-path-letters.t, which the spec's departure 11 says was
# appended to and removed from the doc within batch B itself, so it never
# survives to be read back out of the doc at any later commit. "(same path)"
# successors are excluded on purpose (those files still exist under new
# content; they are not part of the deletion set).
# ---------------------------------------------------------------------------
my @ENCODED_DELETED = (
    q{cyhtvaf/ohgyre/ova/oc-pbagvahvgl.fu},
    q{cyhtvaf/ohgyre/ova/oc-jngpu.fu},
    q{cyhtvaf/ohgyre/ubbxf/pbagrkg-prvyvat-syhfu.fu},
    q{cyhtvaf/ohgyre/ubbxf/pbagrkg-prvyvat-thvqnapr.fu},
    q{cyhtvaf/ohgyre/ubbxf/qvfcngpu-qvfpvcyvar-ahqtr.fu},
    q{cyhtvaf/ohgyre/ubbxf/tngr-pbagvahvgl.fu},
    q{cyhtvaf/ohgyre/ubbxf/tngr-qevir-ybbc.fu},
    q{cyhtvaf/ohgyre/ubbxf/tngr-urnqyrff-onpxtebhaq.fu},
    q{cyhtvaf/ohgyre/ubbxf/tngr-fgbc.fu},
    q{cyhtvaf/ohgyre/ubbxf/thneq-whqtr-purpxf.fu},
    q{cyhtvaf/ohgyre/ubbxf/thneq-yrqtre-perngr.fu},
    q{cyhtvaf/ohgyre/ubbxf/thneq-eha-svavfu.fu},
    q{cyhtvaf/ohgyre/ubbxf/thneq-fhontrag-fgnyy.fu},
    q{cyhtvaf/ohgyre/ubbxf/thneq-inyvqngvba-vagreybpx.fu},
    q{cyhtvaf/ohgyre/ubbxf/ubbxf.wfba.nobhg},
    q{cyhtvaf/ohgyre/ubbxf/yvo.fu},
    q{cyhtvaf/ohgyre/ubbxf/ybt-qvfcngpu.fu},
    q{cyhtvaf/ohgyre/ubbxf/znex-jnxrhc.fu},
    q{cyhtvaf/ohgyre/ubbxf/erpbeq-qvfcngpu-cnpxntr.fu},
    q{cyhtvaf/ohgyre/ubbxf/ercrng-thneq.fu},
    q{cyhtvaf/ohgyre/ubbxf/genpx-jbexre-fbyb.fu},
    q{cyhtvaf/ohgyre/ubbxf/hagenpx-jbexre-fbyb.fu},
    q{cyhtvaf/ohgyre/fpevcgf/oc-pbagvahvgl.cy},
    q{cyhtvaf/ohgyre/fpevcgf/oc-erfhzcgvba.cy},
    q{cyhtvaf/ohgyre/fpevcgf/oc-frffvba.cy},
    q{cyhtvaf/ohgyre/fpevcgf/oc-jngpu.cy},
    q{cyhtvaf/ohgyre/fpevcgf/oc-jngpuqbt.cy},
    q{cyhtvaf/ohgyre/grfgf/g/nezvat-ovaqf-be-ercbegf.g},
    q{cyhtvaf/ohgyre/grfgf/g/oc-jngpu-pyv.g},
    q{cyhtvaf/ohgyre/grfgf/g/oc-jngpu-qrpvfvba-pber.g},
    q{cyhtvaf/ohgyre/grfgf/g/oc-jngpu-qbpgevar.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagrkg-prvyvat-syhfu.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagrkg-prvyvat-thvqnapr.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-obhaqrq-ubyq.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-tngr-vqyr-rkvg.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-tngr-jevgr-enpr.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-tngr.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-yrnfr-uryq.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-bhgchg-fgnlf-cnefrnoyr.g},
    q{cyhtvaf/ohgyre/grfgf/g/pbagvahvgl-gbttyr.g},
    q{cyhtvaf/ohgyre/grfgf/g/qvfnez-abapr-thneq.g},
    q{cyhtvaf/ohgyre/grfgf/g/qvfcngpu-qvfpvcyvar-ahqtr.g},
    q{cyhtvaf/ohgyre/grfgf/g/qvfcngpu-cnpxntr-ubbx.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevir-ybbc-tngr.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevir-ybbc-ehafgngr-sbyq.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevir-ybbc-jngpuqbt.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevir-fbyb-znexre-ergverzrag.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevire-nez-abvfr-fgevccvat.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevire-pbagrkg-frffvba-fpbcr.g},
    q{cyhtvaf/ohgyre/grfgf/g/qevire-thneq-ernpu.g},
    q{cyhtvaf/ohgyre/grfgf/g/svavfu-thneq-pbhagf-yvir-ehaf.g},
    q{cyhtvaf/ohgyre/grfgf/g/tngr-urnqyrff-onpxtebhaq.g},
    q{cyhtvaf/ohgyre/grfgf/g/tenprshy-fgbc-tngr.g},
    q{cyhtvaf/ohgyre/grfgf/g/thneq-whqtr-purpxf-dhbgr-fgevc.g},
    q{cyhtvaf/ohgyre/grfgf/g/thneq-whqtr-purpxf.g},
    q{cyhtvaf/ohgyre/grfgf/g/thneq-yrqtre-perngr.g},
    q{cyhtvaf/ohgyre/grfgf/g/ubbx-cngu-jnyx-naq-fpbcr.g},
    q{cyhtvaf/ohgyre/grfgf/g/ubbx-cnlybnq-ernq-obhaq.g},
    q{cyhtvaf/ohgyre/grfgf/g/wfba-trg-neenl-vaqrk.g},
    q{cyhtvaf/ohgyre/grfgf/g/znex-jnxrhc-ntrag-qvfcngpu.g},
    q{cyhtvaf/ohgyre/grfgf/g/znex-jnxrhc-dhbgrq-fpevcg-cngu.g},
    q{cyhtvaf/ohgyre/grfgf/g/zngpu-nal-qviretrapr.g},
    q{cyhtvaf/ohgyre/grfgf/g/cnenyyry-gerr-vagreybpx.g},
    q{cyhtvaf/ohgyre/grfgf/g/ernq-cnlybnq-vqrzcbgrag.g},
    q{cyhtvaf/ohgyre/grfgf/g/ertvfgel-cngu-bar-ehyr.g},
    q{cyhtvaf/ohgyre/grfgf/g/ertvfgel-cngu-cnevgl.g},
    q{cyhtvaf/ohgyre/grfgf/g/ercrng-thneq.g},
    q{cyhtvaf/ohgyre/grfgf/g/ercbegre-tngr-erterffvba.g},
    q{cyhtvaf/ohgyre/grfgf/g/ercbegre-ertvfgengvba.g},
    q{cyhtvaf/ohgyre/grfgf/g/ercbegre-fgbc-tngr.g},
    q{cyhtvaf/ohgyre/grfgf/g/eha-pbagvahvgl-tncf.g},
    q{cyhtvaf/ohgyre/grfgf/g/eha-svavfu-thneq-cngu-yrggref.g},
    q{cyhtvaf/ohgyre/grfgf/g/eha-svavfu-thneq.g},
    q{cyhtvaf/ohgyre/grfgf/g/eha-svavfu-ernqf-vaibpngvbaf.g},
    q{cyhtvaf/ohgyre/grfgf/g/frffvba-vqragvgl-ovaqvat.g},
    q{cyhtvaf/ohgyre/grfgf/g/fhontrag-fgnyy-thneq.g},
    q{cyhtvaf/ohgyre/grfgf/g/inyvqngvba-vagreybpx-ubbxf.g},
    q{cyhtvaf/ohgyre/grfgf/g/jnvgf-purpx-yvirarff.g},
    q{cyhtvaf/ohgyre/grfgf/g/jngpure-cebor-yvirarff.g},
    q{cyhtvaf/ohgyre/grfgf/g/jngpure-erncrq-ba-jnxr.g},
);

my @DELETED_PATHS_EMBEDDED = map { rot13($_) } @ENCODED_DELETED;

# ---------------------------------------------------------------------------
# Doc parsing -- section 2.11's stated primary source. Kept live (rather than
# only relying on the embedded set above) so this test still finds anything
# the doc names in a later revision.
# ---------------------------------------------------------------------------
sub extract_section {
    my ($text, $heading) = @_;
    return undef unless defined $text;
    if ($text =~ /^\Q## $heading\E[ \t]*\r?\n(.*?)(?=\n## |\z)/ms) {
        return $1;
    }
    return undef;
}

sub parse_deletion_list {
    my ($section_text) = @_;
    return () unless defined $section_text;
    my @paths;
    for my $line (split /\n/, $section_text) {
        next unless $line =~ /^-\s*`([^`]+)`/;
        my $path = $1;
        next if $line =~ /\(same path\)\s*$/;
        push @paths, $path;
    }
    return @paths;
}

sub read_utf8_or_undef {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes;
}

my $DOC_REL = 'plugins/butler/docs/hook-architecture.md';
my $doc_text = read_utf8_or_undef("$ROOT/$DOC_REL");
my @doc_parsed = parse_deletion_list(extract_section($doc_text, 'Deletion list'));

my %seen;
my @DELETED_PATHS = grep { !$seen{$_}++ } (@DELETED_PATHS_EMBEDDED, @doc_parsed);

# ---------------------------------------------------------------------------
# Exemptions (Decision 21, plus the approved D2 Containerfile exemption).
# ---------------------------------------------------------------------------
my %EXEMPT_FILE = map { $_ => 1 } (
    'plugins/butler/docs/hook-architecture.md',
    'plugins/butler/docs/harness-facts.md',
    'plugins/sandbox/container/Containerfile',
);

# %ABSENCE_PINS (E2-2): path => reason. Only .t files; starts with exactly
# continuity-prose-budget.t (D1). Batch E2 proposed five more (driver review,
# Decision 77); ACCEPTED two, REJECTED three (dispatch-tracking-hook.t,
# dispatch-write-hardening.t, dispatch-write-path.t skip_all'd on the old
# shared bash guard library and ran zero assertions -- hidden vacuity, not
# an absence assertion; fixed in place instead, no pin).
my %ABSENCE_PINS = (
    'plugins/butler/tests/t/continuity-prose-budget.t' =>
        'rule-R fixtures are retired-term strings; the file names them on '
      . 'purpose to prove the budget still recognises retired vocabulary '
      . '(Decision 21, driver decision D1)',
    'plugins/butler/tests/t/guards-per-subagent.t' =>
        'AC-24 asserts, via like($header, qr/driver-guard-reach/) and '
      . 'qr/driver-context-session-scope/ plus needle-built literals '
      . 'including the old shared bash guard library\'s presence line, that '
      . 'its OWN leading comment block still carries the historical '
      . 'NOT-RE-EXPRESSED table verbatim -- the assertion is against this '
      . 'file\'s own header text, so the table cannot be reworded without '
      . 'breaking the check it powers',
    'plugins/butler/tests/t/runstate-references-retired.t' =>
        'a cross-blueprint oracle (butler-gate-ergonomics package 03) whose '
      . 'D1/D2 exemptions and AC-2 assertions already deliberately name the '
      . 'old continuity-off-check guard and its own retired test to prove '
      . 'those exemptions are now VACUOUS because package 16 deleted their '
      . 'subjects -- the file documents and asserts this cross-package '
      . 'interaction on purpose',
);

# ---------------------------------------------------------------------------
# The match rule (spec 2.11): literal, case-sensitive basename B; a hit is B
# preceded by start-of-line or a character outside [A-Za-z0-9_.-], and
# followed by end-of-line or a character outside [A-Za-z0-9_-].
# ---------------------------------------------------------------------------
sub line_has_hit {
    my ($line, $basename) = @_;
    my $pat = qr/(?<![A-Za-z0-9_.\-])\Q$basename\E(?![A-Za-z0-9_\-])/;
    return $line =~ $pat ? 1 : 0;
}

# One compiled alternation for a whole basename set, built once and reused
# across every scanned line -- the real-tree sweeps below cover ~800 tracked
# files against dozens of basenames each, so per-basename recompilation
# would be needlessly slow. Same boundary rule, applied per alternative via
# a capturing group so the caller learns which basename matched.
sub build_hit_matcher {
    my (@basenames) = @_;
    return undef unless @basenames;
    my $alt = join('|', map { quotemeta($_) } @basenames);
    return qr/(?<![A-Za-z0-9_.\-])($alt)(?![A-Za-z0-9_\-])/;
}

# ===========================================================================
# E2-1: non-vacuity of the match routine and the list parser, on inline
# fixtures. Each literal that would otherwise hit this very file is built
# from concatenated fragments so this file's own raw bytes never spell it.
# ===========================================================================
subtest 'match routine non-vacuity (E2-1)' => sub {
    my $bn_lib   = 'li' . 'b.sh';
    my $bn_stop  = 'gate-st' . 'op.sh';
    my $bn_watch = 'bp-wat' . 'ch.pl';

    my $hit_text_1 = 'see hooks/' . $bn_lib;
    my $hit_text_2 = '(' . $bn_stop . ')';

    ok(line_has_hit($hit_text_1, $bn_lib),  'hits "see hooks/" + lib.sh');
    ok(line_has_hit($hit_text_2, $bn_stop), 'hits "(" + gate-stop.sh + ")"');

    ok(!line_has_hit('bp-lib.sh', $bn_lib),
        'does not hit "bp-lib.sh" for basename lib.sh (hyphen is not a boundary)');
    ok(!line_has_hit('bp-watch-child.pl', $bn_watch),
        'does not hit "bp-watch-child.pl" for basename bp-watch.pl');
    ok(!line_has_hit('qr/bp-watch\.pl/', $bn_watch),
        'does not hit the escaped regex qr/bp-watch\.pl/ for basename bp-watch.pl');
};

subtest 'list parser skips a (same path) line (E2-1)' => sub {
    my $fixture = "## Deletion list\n\n"
        . "- `plugins/butler/hooks/keep-me.sh` (same path)\n"
        . "- `plugins/butler/hooks/real-delete.sh`\n"
        . "\n## Cutover obligations\n";
    my $section = extract_section($fixture, 'Deletion list');
    ok(defined $section, 'section extracted');
    my @paths = parse_deletion_list($section);
    is(scalar(@paths), 1, 'exactly one entry parsed (the same-path line is skipped)');
    is($paths[0], 'plugins/butler/hooks/real-delete.sh', 'the surviving entry is the non-same-path one')
        if @paths;
};

# ===========================================================================
# E2-2: %ABSENCE_PINS shape.
# ===========================================================================
subtest 'ABSENCE_PINS shape (E2-2)' => sub {
    my @keys = sort keys %ABSENCE_PINS;
    ok(scalar(@keys) >= 1, 'at least one entry');
    ok((grep { $_ eq 'plugins/butler/tests/t/continuity-prose-budget.t' } @keys) ? 1 : 0,
        'names plugins/butler/tests/t/continuity-prose-budget.t');
    for my $k (@keys) {
        like($k, qr/\.t\z/, "pin key '$k' is a .t path");
        ok(defined $ABSENCE_PINS{$k} && length($ABSENCE_PINS{$k}), "pin '$k' has a non-empty reason");
    }
};

# ===========================================================================
# Real-tree scan setup: git ls-files (the one process this file spawns).
# ===========================================================================
my $ls_out = qx(git -C "$ROOT" ls-files 2>&1);
my $ls_rc  = $?;
BAIL_OUT("git ls-files failed (rc=$ls_rc): $ls_out") if $ls_rc != 0;
my @tracked = split /\n/, $ls_out;

my @scan_files = grep {
    m{^plugins/} || m{^scripts/} || m{^skills/} || m{^docs/} || $_ eq 'CLAUDE.md'
} @tracked;

# This file's own repo-relative path, computed the same way as everything
# else in @scan_files (never hand-typed), purely so diagnostics can name it
# if something regresses -- it is NOT excluded from the scan below.
my ($SELF_REL) = grep { m{cutover-residue-lint\.t\z} } @scan_files;

sub file_text_or_undef {
    my ($rel) = @_;
    my $abs = "$ROOT/$rel";
    return undef unless -f $abs;
    open(my $fh, '<:raw', $abs) or return undef;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return undef if !defined $bytes;
    return undef if index($bytes, "\0") >= 0;   # skip binary
    return $bytes;
}

# ===========================================================================
# Also asserted (spec 2.11): every list path absent on disk; hooks/next
# gone; no SKILL.next.md; tests-never-run-tests.t's allowlist names no
# list entry.
# ===========================================================================
subtest 'deletion-set paths are absent on disk' => sub {
    my @still_present = grep { -e "$ROOT/$_" } @DELETED_PATHS;
    is(scalar(@still_present), 0, 'no deletion-set path exists on disk')
        or diag('still present: ' . join(', ', @still_present));
};

ok(!-d "$ROOT/plugins/butler/hooks/next", 'plugins/butler/hooks/next does not exist');

subtest 'no SKILL.next.md anywhere in the scan set' => sub {
    my @stray = grep { basename($_) eq 'SKILL.next.md' } @scan_files;
    is(scalar(@stray), 0, 'no SKILL.next.md tracked under plugins/ or skills/')
        or diag('found: ' . join(', ', @stray));
};

subtest "tests-never-run-tests.t's allowlist names no deletion-set entry" => sub {
    my $rel = 'plugins/butler/tests/t/tests-never-run-tests.t';
    my $text = file_text_or_undef($rel);
    ok(defined $text, "$rel is readable") or return;
    my @deleted_basenames = do {
        my %u;
        $u{ basename($_) } = 1 for @DELETED_PATHS;
        sort keys %u;
    };
    my $matcher = build_hit_matcher(@deleted_basenames);
    my %bad;
    for my $line (split /\n/, $text) {
        while ($line =~ /$matcher/g) { $bad{$1} = 1 }
    }
    my @bad = sort keys %bad;
    is(scalar(@bad), 0, 'allowlist file names no deletion-set basename')
        or diag('mentions: ' . join(', ', @bad));
};

# ===========================================================================
# The main sweep: no scanned file outside the exemptions and the pins
# contains a deletion-set basename under the word-boundary match rule.
# ===========================================================================
subtest 'no residual reference to any deleted file' => sub {
    my @deleted_basenames = do {
        my %u;
        $u{ basename($_) } = 1 for @DELETED_PATHS;
        sort keys %u;
    };
    ok(scalar(@deleted_basenames) > 0, 'the deletion set is non-empty')
        or return;
    my $matcher = build_hit_matcher(@deleted_basenames);

    my @failures;
    for my $rel (@scan_files) {
        next if $EXEMPT_FILE{$rel};
        next if exists $ABSENCE_PINS{$rel};
        my $text = file_text_or_undef($rel);
        next unless defined $text;
        my @lines = split /\n/, $text;
        for my $i (0 .. $#lines) {
            while ($lines[$i] =~ /$matcher/g) {
                push @failures, sprintf('%s:%d: %s', $rel, $i + 1, $1);
            }
        }
    }
    is(scalar(@failures), 0, 'no scanned file outside the exemptions references a deleted path')
        or diag(join("\n", @failures));
};

# ===========================================================================
# The retired concurrency-switch identifiers: gone from every scanned file
# outside the Decision 21 exemptions AND outside plugins/*/tests/.
# ===========================================================================
subtest 'no retired concurrency-switch identifier outside tests' => sub {
    my @retired_words = ('BUTLER_CONCURRENCY', 'concurrency_on', 'fleet_holder_on');
    my @failures;
    for my $rel (@scan_files) {
        next if $EXEMPT_FILE{$rel};
        next if exists $ABSENCE_PINS{$rel};
        next if $rel =~ m{^plugins/[^/]+/tests/};
        my $text = file_text_or_undef($rel);
        next unless defined $text;
        my @lines = split /\n/, $text;
        for my $i (0 .. $#lines) {
            for my $word (@retired_words) {
                if (index($lines[$i], $word) >= 0) {
                    push @failures, sprintf('%s:%d: %s', $rel, $i + 1, $word);
                }
            }
        }
    }
    is(scalar(@failures), 0, 'no retired concurrency-switch identifier survives outside plugins/*/tests/')
        or diag(join("\n", @failures));
};

done_testing();
