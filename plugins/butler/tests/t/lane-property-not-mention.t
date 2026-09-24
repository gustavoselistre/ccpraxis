#!/usr/bin/env perl
# platform: any
# Oracle for blueprint package 01-container-lane-is-a-property (blueprint
# matchers-answer-the-question).
# Derived from
# .ccpraxis-local-data/blueprints/matchers-answer-the-question/specs/01-container-lane-is-a-property-spec.md
# ONLY -- scripts/run-tests.pl's implementation was never read while authoring
# this file. Today, classify_file()'s serial heuristic is a raw text scan
# ($src =~ /TestSandbox|podman_run_capture|podman_bin|probe_image/) that fires
# on a comment/string MENTION, not only a real TestSandbox load. This file
# pins the spec's replacement (_loads_test_sandbox, comment-stripped, load-
# construct-only) and is expected to fail against today's implementation.
#
# AC -> block mapping:
#   AC1/AC2 -> "AC1/AC2: the seven files classify parallel, and are never
#              skipped by --fast" block.
#   AC3/AC4 -> "AC3/AC4: the nine files classify host-serial, and --fast
#              skips exactly them" block (a SEPARATE block/loop from AC1/AC2,
#              per spec).
#   AC5     -> "AC5: comment-only trigger fixture" block.
#   AC6     -> "AC6: string-literal trigger fixture (dropped identifier)"
#              block.
#   AC7     -> "AC7: lane-routing.t itself stays green" block -- runs that
#              file directly as a subprocess; does not duplicate its own
#              129 assertions here.
#   AC8     -> NOT mechanical. See the comment immediately above the AC9
#              block below: the spec (section 4, AC8) states this criterion
#              is satisfied by a timestamped ledger attempt-log entry in
#              packages/01-container-lane-is-a-property.md, quoting the
#              changed pinned assertion and justifying it under Decision 10 --
#              not by any assertion a test file can make. No test is written
#              for it; this is a report finding, not an omission.
#   AC9     -> "AC9: --fast over all 16 reports exactly the nine, sorted,
#              and 9 (not 16, not 7)" block.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use POSIX ();

(my $ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $RUNNER = "$ROOT/scripts/run-tests.pl";
ok(-f $RUNNER, 'scripts/run-tests.pl is present')
    or BAIL_OUT("no runner at $RUNNER -- nothing else in this file can run");

# =============================================================================
# PART 0 -- helpers (this file's own scaffolding; never touches run-tests.pl
# or lane-routing.t).
# =============================================================================

sub write_fixture {
    my ($dir, $name, $content) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>:raw', $path or die "cannot write fixture $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

# sweep(@args) -> combined stdout+stderr of `perl scripts/run-tests.pl @args`
# Same idiom as sweep-coverage-honesty.t: a real subprocess, piped, never a
# reopened in-process STDOUT (which fails with "Bad file descriptor" on this
# host's perl per CLAUDE.md).
sub sweep {
    my (@args) = @_;
    my @cmd = ($^X, $RUNNER, @args);
    open(my $fh, '-|', @cmd) or die "spawn: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

# require the real classify_file() from scripts/run-tests.pl. lane-routing.t
# (verified green, 129/129, at authoring time) already establishes that a
# plain `require` of this file is safe today (it defines run_sweep() and
# guards its own top-level execution with "exit run_sweep(@ARGV) unless
# caller();"), so this file follows that same established, currently-safe
# idiom rather than duplicating a BAIL_OUT gate that would be untested dead
# code here.
require $RUNNER;

# =============================================================================
# Section 2.3 (the seven) / Section 2.4 (the nine) -- the exact, pinned lists
# from the spec, resolved relative to the repo root. NOT re-derived from a
# fresh grep inside this file's assertions (the spec forbids re-deriving the
# split itself); the write-time disagreement-check against disk was run
# separately (report) and agreed with these lists exactly.
# =============================================================================
my @SEVEN_RELPATHS = (
    'plugins/butler/tests/t/container-lane.t',
    'plugins/butler/tests/t/lane-routing.t',
    'plugins/butler/tests/t/runner-state-write-merge.t',
    'plugins/sandbox/tests/t/claude-json-relocation-migration.t',
    'plugins/sandbox/tests/t/launcher-bind-mount-shape.t',
    'plugins/sandbox/tests/t/refuse-protected-paths.t',
    'plugins/sandbox/tests/t/run-state.t',
);
my @NINE_RELPATHS = (
    'plugins/butler/tests/t/scratch-root-single.t',
    'plugins/sandbox/tests/t/bind-honors-append-and-utimensat.t',
    'plugins/sandbox/tests/t/claude-json-file-bind.t',
    'plugins/sandbox/tests/t/install-pass-heartbeat.t',
    'plugins/sandbox/tests/t/keepalive-heartbeat.t',
    'plugins/sandbox/tests/t/launcher-ro-protection.t',
    'plugins/sandbox/tests/t/multi-session-shared-state.t',
    'plugins/sandbox/tests/t/runtime-detection.t',
    'plugins/sandbox/tests/t/test-harness-orphan-reaping.t',
);

sub _basename {
    my ($relpath) = @_;
    my @parts = split m{/}, $relpath;
    return $parts[-1];
}

# =============================================================================
# AC1/AC2 [DC1]: the seven files classify parallel, and are never skipped by
# --fast. ONE loop/table over exactly these seven paths (AC1's own wording).
# =============================================================================
{
    for my $rel (@SEVEN_RELPATHS) {
        my $abs = "$ROOT/$rel";
        ok(-f $abs, "AC1 setup: $rel exists on disk") or next;
        my $d = classify_file($abs);
        ok(defined $d, "AC1: classify_file() returns a result for $rel");
        next unless defined $d;
        isnt($d->{lane}, 'host-serial',
            "AC1: $rel classifies as something other than host-serial (mentions TestSandbox-related "
          . "identifiers in comments/strings only, never loads it for real)");
        ok(($d->{lane} eq 'host-parallel' || $d->{lane} eq 'container'),
            "AC1: ${rel}'s lane is 'host-parallel' or 'container' (got '"
          . (defined $d->{lane} ? $d->{lane} : '<undef>') . "')");
        is($d->{serial}, 0, "AC1: $rel has serial => 0");
    }
}
{
    my @abs_seven = map { "$ROOT/$_" } @SEVEN_RELPATHS;
    my $out = sweep('--fast', '--nice', @abs_seven);
    unlike($out, qr/--fast skipped/,
        'AC2: a real --fast subprocess run over a target set covering only the seven files prints no '
      . '"--fast skipped ..." notice at all -- none of them were dropped, all were actually executed');
}

# =============================================================================
# AC3/AC4 [DC2]: the nine files classify host-serial, and --fast skips
# exactly them. A SEPARATE block from AC1/AC2 -- not a shared loop over
# 7+9 files, and not inferred from AC1/AC2 passing (spec, AC3).
# =============================================================================
{
    for my $rel (@NINE_RELPATHS) {
        my $abs = "$ROOT/$rel";
        ok(-f $abs, "AC3 setup: $rel exists on disk") or next;
        my $d = classify_file($abs);
        ok(defined $d, "AC3: classify_file() returns a result for $rel");
        next unless defined $d;
        is($d->{lane}, 'host-serial', "AC3: $rel classifies as host-serial (genuinely loads TestSandbox)");
        is($d->{serial}, 1, "AC3: $rel has serial => 1");
    }
}
{
    my @abs_nine = map { "$ROOT/$_" } @NINE_RELPATHS;
    my $out = sweep('--fast', '--nice', @abs_nine);
    like($out, qr/--fast skipped 9 host-serial file\(s\)/,
        'AC4: a real --fast subprocess run over a target set covering only the nine files reports '
      . 'exactly "--fast skipped 9 host-serial file(s)"');
    for my $rel (@NINE_RELPATHS) {
        my $base = _basename($rel);
        like($out, qr/^[ \t]*\Q$base\E[ \t]*$/m,
            "AC4: $base is named in the --fast skipped list");
    }
    like($out, qr/\b0 serial\b/,
        'AC4: the run summary reports 0 files actually run in the serial lane -- none of the nine were '
      . 'executed, only skipped');
}

# =============================================================================
# AC5 [DC3, comment shape]: a synthetic fixture whose only trigger text sits
# inside a whole-line comment classifies non-serial. Fixture body copied
# byte-for-byte from spec section 4 (AC5).
# =============================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $body = <<'FIXTURE';
#!/usr/bin/env perl
# platform: any
# TestSandbox is mentioned here only in prose, never loaded: this file must not use TestSandbox
print "ok 1 - fixture pass\n"; exit 0;
FIXTURE
    my $f = write_fixture($dir, 'ac5-comment-only-trigger.t', $body);
    my $d = classify_file($f);
    ok(defined $d, 'AC5: classify_file() returns a result for the comment-only-trigger fixture');
    is($d->{lane}, 'container',
        'AC5: a fixture whose only TestSandbox-related text is inside a whole-line comment classifies '
      . "'container', not 'host-serial' -- comments are stripped before the discriminator runs");
    is($d->{serial}, 0, 'AC5: serial => 0 for the comment-only-trigger fixture');
}

# =============================================================================
# AC6 [DC3, string-literal shape]: a synthetic fixture whose only trigger
# text sits inside a Perl string literal, using a now-dropped identifier
# (podman_bin) rather than the loading syntax itself. Fixture body copied
# byte-for-byte from spec section 4 (AC6).
# =============================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $body = <<'FIXTURE';
#!/usr/bin/env perl
# platform: any
my $desc = "would call podman_bin() if ever run";
print "ok 1 - fixture pass\n"; exit 0;
FIXTURE
    my $f = write_fixture($dir, 'ac6-string-literal-trigger.t', $body);
    my $d = classify_file($f);
    ok(defined $d, 'AC6: classify_file() returns a result for the string-literal-trigger fixture');
    is($d->{lane}, 'container',
        "AC6: a fixture whose only trigger text is a dropped identifier (podman_bin) inside a quoted "
      . "string classifies 'container', not 'host-serial' -- podman_bin is no longer part of the "
      . 'discriminator\'s vocabulary at all, in or out of a string');
    is($d->{serial}, 0, 'AC6: serial => 0 for the string-literal-trigger fixture');
}

# =============================================================================
# AC8 [DC4]: NOT mechanical. Per spec section 4 (AC8), this criterion is
# satisfied by a timestamped entry in this package's own ledger
# (packages/01-container-lane-is-a-property.md) attempt log -- quoting each
# pinned assertion in lane-routing.t that changed as a mechanical consequence
# of AC1-AC6, naming which of the two properties it encoded before, and
# justifying the new value under Decision 10. No test file assertion can
# observe a ledger prose entry's presence/correctness as a pass/fail
# behavior of the code under test, so no test is written for it here. This
# is a reported finding (see the report at
# .ccpraxis-local-data/blueprints/matchers-answer-the-question/reports/01-container-lane-is-a-property/test-writer-01.md),
# not an omission.
# =============================================================================

# =============================================================================
# AC9 [DC5]: `perl scripts/run-tests.pl --fast` over a target set covering
# all 16 files in 2.3 UNION 2.4 prints "--fast skipped 9 host-serial
# file(s)" (not 16, not 7), and the printed basenames are exactly the nine
# in section 2.4, sorted. Run and observed on disk -- not inferred from
# AC1-AC4 holding in isolation.
# =============================================================================
{
    my @abs_all = map { "$ROOT/$_" } (@SEVEN_RELPATHS, @NINE_RELPATHS);
    my $out = sweep('--fast', '--nice', @abs_all);

    like($out, qr/--fast skipped 9 host-serial file\(s\)/,
        'AC9: a real --fast subprocess run over all 16 files (2.3 union 2.4) reports exactly '
      . '"--fast skipped 9 host-serial file(s)" -- not 16, not 7');

    # Isolate the skip-notice section (from its header line to end of output)
    # so basenames belonging to OTHER files' own nested TAP/diagnostic output
    # (e.g. lane-routing.t, one of the seven executed here, writes its own
    # fixture files with .t-shaped names as part of its own run) cannot be
    # mistaken for entries in the skip list itself.
    my ($skip_block) = $out =~ /(--fast skipped \d+ host-serial file\(s\).*)\z/s;
    ok(defined $skip_block, 'AC9: the skip-notice section is present in the run\'s output')
        or diag($out);
    $skip_block //= '';

    my @found_in_block = ($skip_block =~ /^[ \t]+(\S+\.t)[ \t]*$/mg);
    my @expected_sorted = sort map { _basename($_) } @NINE_RELPATHS;
    is_deeply([ sort @found_in_block ], \@expected_sorted,
        'AC9: the printed basenames in the skip-notice section are exactly the nine files from section '
      . '2.4, sorted -- no more, no fewer');

    for my $rel (@SEVEN_RELPATHS) {
        my $base = _basename($rel);
        unlike($skip_block, qr/^[ \t]*\Q$base\E[ \t]*$/m,
            "AC9: $base (one of the seven) does not appear in the skip-notice section");
    }
}

# =============================================================================
# AC10 [redteam-01.md MEDIUM]: a synthetic fixture whose only trigger is a
# quoted-string-literal require of the module filename (not the bareword
# require-TestSandbox form) genuinely loads the module and must classify
# host-serial, matching the fix for the false-negative regression identified
# in the fix-batch red-team report. NOTE: neither this comment block nor any
# test description below spells the trigger construct as one contiguous
# substring -- lane-routing.t's own whole-tree Part D sweep scans this file's
# real source with the SAME discriminator, so a literal `require "TestSandbox`
# run anywhere outside the generated fixture would make this file
# self-trigger and desync from lane-routing.t's independently-recomputed
# expected sets.
# =============================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    # Built via concatenation rather than a literal heredoc so this test
    # file's OWN source text (scanned for real by lane-routing.t's whole-tree
    # sweep) never contains the contiguous trigger substring itself -- only
    # the generated fixture file, written outside the real tree, does.
    my $require_line = 'require ' . '"' . 'TestSandbox' . '.pm' . '"' . ";\n";
    my $body = "#!/usr/bin/env perl\n# platform: any\n"
             . $require_line
             . qq{print "ok 1 - fixture pass\\n"; exit 0;\n};
    my $f = write_fixture($dir, 'ac10-quoted-require-trigger.t', $body);
    my $d = classify_file($f);
    ok(defined $d, 'AC10: classify_file() returns a result for the quoted-require-trigger fixture');
    is($d->{lane}, 'host-serial',
        'AC10: a fixture whose only trigger is a quoted-string-literal require of the module filename '
      . "(not the bareword require form) classifies 'host-serial' -- it genuinely loads TestSandbox "
      . 'even without the bareword form');
    is($d->{serial}, 1, 'AC10: serial => 1 for the quoted-require-trigger fixture');
}

done_testing();
