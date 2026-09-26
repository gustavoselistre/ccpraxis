#!/usr/bin/env perl
# platform: any
# ORACLE for package 27-ledger-set-checks: a new bp-ledger.pl verb, `set-checks`,
# that REPLACES a package ledger's frontmatter `checks:` field wholesale (the
# `set-write-set` / `set-test-paths` model: `_op_set_scope_field`, bp-ledger.pl
# :1797-1871), refusing on done/dropped, requiring every ADDED check name to be
# named verbatim in a blueprint Decision row, and refusing when the new set
# still omits a check the package's write_set implies per BpChecks::missing.
#
# Written from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/27-ledger-set-checks-spec.md
# (AC-1..AC-19) and Decision 106 (blueprint.md) ONLY -- never from bp-ledger.pl's
# implementation, which does not carry `set-checks` yet (it is not in %DISPATCH,
# so every call below currently fails with "unknown subcommand 'set-checks'"; the
# tests fail for that reason, not a compile error or fixture bug).
#
# *** VOCABULARY OVERRIDE (Decision 106) ***
# The spec's own 2.3 ("table UNION a fixed eight-name list") is SUPERSEDED.
# Decision 106: "set-checks validates check names against the blueprint's live
# checks-table only, read with BpChecks::parse_table. It keeps NO fixed built-in
# list... A blueprint without a checks-table accepts any well-formed check name,
# as ledger create already does." So:
#   - a blueprint WITH a non-empty checks-table: a name is known iff some row's
#     `check` equals it -- no fixed-list fallback.
#   - a blueprint with NO table (absent, or only inside an HTML comment, which
#     BpChecks::parse_table already treats as absent): ANY well-formed name
#     (spec step 2's shape rule: non-empty, no ':' '|' CR LF, no whitespace) is
#     accepted.
# This inverts spec AC-6's "table removed -> refused" half (now: table removed
# means no vocabulary constraint at all, so it is ACCEPTED) and voids AC-7's
# "eight fixed names" (now: any well-formed name is accepted with no table, not
# just eight specific ones). AC-5's "known iff neither in table nor fixed list"
# becomes "known iff a table is present and the name is not one of its rows" --
# with no table there is no unknown-name refusal at all. The adjusted ACs below
# are marked "(Decision 106 override)".
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use POSIX qw(_exit);

# slurp() reads with '<:raw', so an em-dash in a file arrives as the raw UTF-8
# bytes E2 80 94, never as the codepoint U+2014 -- match the bytes, as
# ledger-api.t does.
my $EMDASH = "\xE2\x80\x94";

my $LEDGER_PL = "$Bin/../../scripts/bp-ledger.pl";
my $CHECKS_PL = "$Bin/../../scripts/bp-checks.pl";
my $TEMPLATE  = "$Bin/../../../blueprint/templates/package-ledger.md";
ok(-f $LEDGER_PL && -f $CHECKS_PL && -f $TEMPLATE, 'bp-ledger.pl, bp-checks.pl and the ledger template exist')
    or BAIL_OUT('missing inputs');

# BpChecks is a requireable module (dual shape, guarded `unless (caller)`), and
# the spec explicitly names it (2.4) as the shared vocabulary/audit engine this
# package must reuse -- reading it here (never bp-ledger.pl's implementation)
# is the "shared interface the spec names explicitly" case.
require $CHECKS_PL;

# ---------------------------------------------------------------------------
# small shared helpers (fork+exec only; STDIN from /dev/null; alarm-bounded --
# same idiom as ledger-rescope-verbs.t)
# ---------------------------------------------------------------------------

sub slurp {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p =~ s{/+\z}{}; return $p }

# run_cli(@args) -> ($rc, $combined_stdout_and_stderr)
sub run_cli {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull) or _exit(126);
        open(STDOUT, '>', $out) or _exit(126);
        open(STDERR, '>&', \*STDOUT) or _exit(126);
        exec($^X, $LEDGER_PL, @args) or _exit(127);
    }
    local $SIG{ALRM} = sub { kill('KILL', $pid); waitpid($pid, 0); die "run_cli: bp-ledger.pl timed out\n" };
    alarm(30);
    waitpid($pid, 0);
    alarm(0);
    return ($? >> 8, slurp($out) // '');
}

# run_cli_split(@args) -> ($rc, $stdout, $stderr) -- separate captures, used
# where the spec requires stdout to be EMPTY specifically (2.1).
sub run_cli_split {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $err = "$dir/err";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull) or _exit(126);
        open(STDOUT, '>', $out) or _exit(126);
        open(STDERR, '>', $err) or _exit(126);
        exec($^X, $LEDGER_PL, @args) or _exit(127);
    }
    local $SIG{ALRM} = sub { kill('KILL', $pid); waitpid($pid, 0); die "run_cli_split: bp-ledger.pl timed out\n" };
    alarm(30);
    waitpid($pid, 0);
    alarm(0);
    return ($? >> 8, slurp($out) // '', slurp($err) // '');
}

# run_checks_cli(@args) -> ($rc, $combined) against bp-checks.pl itself (AC-13/14).
sub run_checks_cli {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull) or _exit(126);
        open(STDOUT, '>', $out) or _exit(126);
        open(STDERR, '>&', \*STDOUT) or _exit(126);
        exec($^X, $CHECKS_PL, @args) or _exit(127);
    }
    local $SIG{ALRM} = sub { kill('KILL', $pid); waitpid($pid, 0); die "run_checks_cli: bp-checks.pl timed out\n" };
    alarm(30);
    waitpid($pid, 0);
    alarm(0);
    return ($? >> 8, slurp($out) // '');
}

sub field {
    my ($ledger, $key) = @_;
    my ($v) = slurp($ledger) =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/m;
    return $v;
}

sub frontmatter {
    my ($bytes) = @_;
    return $1 if $bytes =~ /\A(---\s*\n.*?\n---)/s;
    return undef;
}

# frontmatter_lines_excluding($bytes, $key) -> arrayref of frontmatter lines
# other than the one starting "$key:" -- used to prove a successful set-checks
# touches ONLY the checks: line (AC-4).
sub frontmatter_lines_excluding {
    my ($bytes, $key) = @_;
    my $fm = frontmatter($bytes);
    return undef unless defined $fm;
    return [ grep { !/^\Q$key\E:/ } split /\n/, $fm ];
}

sub write_blueprint {
    my ($path, %o) = @_;
    my @rows = @{ $o{decisions} // [] };
    open my $w, '>:raw', $path or die "open $path: $!";
    print {$w} "# bp1\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n";
    for my $r (@rows) {
        print {$w} "| $r->[0] | $r->[1] | driver | 2026-09-25 |\n";
    }
    if (defined $o{table}) {
        print {$w} "\n```checks-table\n$o{table}\n```\n";
    }
    if (defined $o{commented_table}) {
        print {$w} "\n<!--\n```checks-table\n$o{commented_table}\n```\n-->\n";
    }
    close $w;
}

# fixture(%opts) -> ($ledger, $bp_dir, $data_dir). Builds:
#   $data/blueprints/<bp>/blueprint.md   (Decision rows + optional checks-table)
#   $data/blueprints/<bp>/packages/<pkg>.md  (via the real `create` verb, so its
#   `checks:` starts from a real, validate()-passing ledger, per the
#   ledger-rescope-verbs.t idiom).
sub fixture {
    my (%o) = @_;
    my $bp_name = $o{blueprint} // 'bp1';
    my $pkg     = $o{package}   // '01-a';
    my $root    = fwd(tempdir(CLEANUP => 1));
    my $data    = "$root/data";
    my $bp_dir  = "$data/blueprints/$bp_name";
    make_path("$bp_dir/packages");
    my $ledger = "$bp_dir/packages/$pkg.md";

    my @create_args = ('create', '--ledger', $ledger, '--package', $pkg, '--blueprint', $bp_name,
                        '--template', $TEMPLATE, '--write-set', $o{write_set} // 'src/a.pl:t/a.t');
    push @create_args, ('--checks', $o{checks}) if defined $o{checks};
    my ($rc, $out) = run_cli(@create_args);
    die "fixture create failed ($rc): $out" unless $rc == 0;

    write_blueprint("$bp_dir/blueprint.md",
        decisions       => $o{decisions} // [],
        table           => $o{table},
        commented_table => $o{commented_table});

    if (defined $o{status}) {
        my ($rc2, $out2) = run_cli('set-status', '--ledger', $ledger, '--status', $o{status});
        die "fixture set-status failed ($rc2): $out2" unless $rc2 == 0;
    }
    return ($ledger, $bp_dir, $data);
}

sub strip_key_line {
    my ($path, $key) = @_;
    my $b = slurp($path);
    $b =~ s/^\Q$key\E:[^\n]*\n//m or die "key '$key' not found to strip in $path";
    open my $w, '>:raw', $path or die "open $path: $!";
    print {$w} $b;
    close $w;
}

# ===========================================================================
# AC-1 -- B-1 replace: exit 0, checks: equals the new set exactly, stdout empty.
# ===========================================================================

subtest 'AC-1: set-checks replaces the field wholesale; exit 0, stdout empty' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile:plugin-tests',
        decisions => [[1, 'Re-scope: checks become bash-syntax and hook-selftest.']],
    );
    my ($rc, $out, $err) = run_cli_split('set-checks', '--ledger', $l, '--decision', '1',
                                          '--check', 'bash-syntax', '--check', 'hook-selftest');
    is($rc, 0, 'exit 0') or diag($err);
    is($out, '', 'stdout is empty on success (2.1)');
    is(field($l, 'checks'), 'bash-syntax:hook-selftest', 'checks replaced wholesale');
};

# ===========================================================================
# AC-2 -- B-2 add: only the truly-new name needs naming.
# ===========================================================================

subtest 'AC-2: adding a check needs only the ADDED name named in the Decision' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile:plugin-tests',
        decisions => [[2, 'Re-scope: add the json-parse check.']],
    );
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '2',
                              '--check', 'perl-compile', '--check', 'plugin-tests', '--check', 'json-parse');
    is($rc, 0, 'exit 0 (perl-compile/plugin-tests need no naming, only json-parse does)') or diag($out);
    is(field($l, 'checks'), 'perl-compile:plugin-tests:json-parse', 'checks is exactly the requested set');
};

# ===========================================================================
# AC-3 -- B-3 remove: a pure removal needs no naming at all.
# ===========================================================================

subtest 'AC-3: removing a check needs no Decision naming' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile:plugin-tests',
        decisions => [[3, 'Unrelated decision text, names nothing relevant.']],
    );
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '3', '--check', 'plugin-tests');
    is($rc, 0, 'exit 0 (removal alone needs no naming)') or diag($out);
    is(field($l, 'checks'), 'plugin-tests', 'checks narrowed to exactly the requested set');
};

# ===========================================================================
# AC-4 -- B-4: exactly one new attempt-log line; every other frontmatter line
# byte-identical.
# ===========================================================================

subtest 'AC-4: a successful call inserts exactly one attempt-log line and touches no other frontmatter line' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile:plugin-tests',
        decisions => [[4, 'Re-scope: checks become bash-syntax.']],
    );
    my $before   = slurp($l);
    my $fm_lines_before = frontmatter_lines_excluding($before, 'checks');

    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '4', '--check', 'bash-syntax');
    is($rc, 0, 'exit 0') or diag($out);

    my $after = slurp($l);
    my $fm_lines_after = frontmatter_lines_excluding($after, 'checks');
    is_deeply($fm_lines_after, $fm_lines_before, 'every frontmatter line other than checks: is byte-identical');

    my @log_lines = grep { /checks replaced per Decision 4:/ } split /\n/, $after;
    is(scalar(@log_lines), 1, 'exactly one matching attempt-log line');
    like($log_lines[0], qr/^-\s+\S+\s+\Q$EMDASH\E\s+checks replaced per Decision 4: bash-syntax$/,
        '...with the exact stated shape');
};

# ===========================================================================
# AC-5 (Decision 106 override) -- unknown name refused when a checks-table IS
# present and the name is not one of its rows, even when the Decision names it.
# (The spec's original "neither table nor fixed list" framing no longer
# applies -- there is no fixed list -- but a present, non-empty table still
# constrains the vocabulary to its own rows.)
# ===========================================================================

subtest 'AC-5 (Decision 106 override): a table-present-but-name-absent check is refused, even when the Decision names it' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        table     => '*.pl => perl-compile',
        decisions => [[5, 'Re-scope: add the bogus-check check.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '5',
                              '--check', 'perl-compile', '--check', 'bogus-check');
    isnt($rc, 0, 'refused: bogus-check is not a row of the live table') or diag($out);
    like($out, qr/bogus-check/, '...naming the offending check');
    like($out, qr/checks-table/i, '...and says it is not in the checks-table');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
};

# ===========================================================================
# AC-6 (Decision 106 override) -- table-produced name accepted with the table
# present; the SAME name is now ACCEPTED (not refused) once the table is
# HTML-commented, because an absent table imposes no vocabulary constraint.
# ===========================================================================

subtest 'AC-6 (Decision 106 override): a table-only name is accepted with the table; accepted (not refused) once the table is commented out' => sub {
    my ($l1) = fixture(
        checks    => '',
        table     => '*.ts => typecheck',
        decisions => [[6, 'Re-scope: add the typecheck check.']],
        write_set => 'src/a.ts',
    );
    my ($rc1, $out1) = run_cli('set-checks', '--ledger', $l1, '--decision', '6', '--check', 'typecheck');
    is($rc1, 0, 'accepted: typecheck is a row of the live checks-table') or diag($out1);
    is(field($l1, 'checks'), 'typecheck', 'checks set to the table-only name');

    my ($l2) = fixture(
        checks          => '',
        commented_table => '*.ts => typecheck',
        decisions       => [[6, 'Re-scope: add the typecheck check.']],
        write_set       => 'src/a.ts',
    );
    my ($rc2, $out2) = run_cli('set-checks', '--ledger', $l2, '--decision', '6', '--check', 'typecheck');
    is($rc2, 0, '(Decision 106) accepted, NOT refused: a commented-out table is "no table", which accepts any well-formed name')
        or diag($out2);
    is(field($l2, 'checks'), 'typecheck', 'checks set to the same name with no live table constraining it');
};

# ===========================================================================
# AC-7 (Decision 106 override) -- with NO checks-table anywhere in the
# blueprint, ANY well-formed name is accepted, not merely a fixed eight.
# ===========================================================================

subtest 'AC-7 (Decision 106 override): with no checks-table, arbitrary well-formed names are accepted, not a fixed list' => sub {
    my ($l) = fixture(
        checks    => '',
        decisions => [[7, 'Re-scope: checks become my-custom-check and another_one and json-parse.']],
    );
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '7',
                              '--check', 'my-custom-check', '--check', 'another_one', '--check', 'json-parse');
    is($rc, 0, 'accepted: no table means no fixed vocabulary constrains the name at all') or diag($out);
    is(field($l, 'checks'), 'my-custom-check:another_one:json-parse', 'checks set to the arbitrary names verbatim');
};

# ===========================================================================
# AC-8 -- B-8 done/dropped refused.
# ===========================================================================

for my $bad_status (qw(done dropped)) {
    subtest "AC-8: set-checks is refused when the ledger's own status is $bad_status" => sub {
        my ($l) = fixture(
            checks    => 'perl-compile',
            decisions => [[8, 'Re-scope: checks become plugin-tests.']],
            status    => $bad_status,
        );
        my $before = slurp($l);
        my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '8', '--check', 'plugin-tests');
        isnt($rc, 0, "refused: status $bad_status") or diag($out);
        like($out, qr/\b$bad_status\b/, '...and the message says so');
        is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
    };
}

# ===========================================================================
# AC-9 -- B-8 running is NOT refused.
# ===========================================================================

subtest "AC-9: set-checks succeeds when the ledger's own status is running" => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[9, 'Re-scope: checks become plugin-tests.']],
        status    => 'running',
    );
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '9', '--check', 'plugin-tests');
    is($rc, 0, 'exit 0: running is not in the refusal list') or diag($out);
    is(field($l, 'checks'), 'plugin-tests', 'checks updated');
};

# ===========================================================================
# AC-10 -- B-9 an added-but-unnamed check is refused; a near-miss token in the
# Decision does not satisfy the bounded-token naming rule.
# ===========================================================================

subtest 'AC-10: an added check absent from the Decision text is refused; a substring near-miss does not count' => sub {
    # The Decision text names json-parser only -- json-parse must NOT be found
    # as a bounded token inside it (it is a prefix of json-parser, not a
    # standalone occurrence).
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[10, 'Re-scope: add the json-parser check.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '10',
                              '--check', 'perl-compile', '--check', 'json-parse');
    isnt($rc, 0, 'refused: Decision 10 names json-parser, not json-parse (bounded token match)') or diag($out);
    like($out, qr/json-parse\b/, '...naming the offending check');
    like($out, qr/10/, '...naming the Decision');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
};

# ===========================================================================
# AC-11 -- B-10 Decision not found.
# ===========================================================================

subtest 'AC-11: an unknown Decision id is refused, ledger unchanged' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[11, 'Re-scope: add plugin-tests.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '999', '--check', 'plugin-tests');
    isnt($rc, 0, 'refused: Decision 999 does not exist') or diag($out);
    like($out, qr/999/, '...naming the missing Decision');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
};

# ===========================================================================
# AC-12 -- B-11 implied-omission refused (audit-parity check).
# ===========================================================================

subtest 'AC-12: dropping an implied check is refused, naming it, ledger unchanged' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile:plugin-tests',
        table     => '*.pl => perl-compile',
        write_set => 'a.pl',
        decisions => [[12, 'Re-scope: checks become plugin-tests only.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '12', '--check', 'plugin-tests');
    isnt($rc, 0, "refused: dropping perl-compile while write_set 'a.pl' still implies it") or diag($out);
    like($out, qr/perl-compile/, '...naming the omitted implied check');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
};

# ===========================================================================
# AC-13 -- a successful call leaves the ledger `audit`-clean, and
# BpChecks::_fm reads back exactly what set-checks wrote (same functions as
# `audit`, per the reuse design in spec 2.4).
# ===========================================================================

subtest 'AC-13: after a successful call, bp-checks.pl audit exits 0 and BpChecks::_fm matches the new value' => sub {
    my ($l, $bp_dir) = fixture(
        checks    => 'plugin-tests',
        table     => '*.pl => perl-compile',
        write_set => 'a.pl',
        decisions => [[13, 'Re-scope: checks become perl-compile and plugin-tests.']],
    );
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '13',
                              '--check', 'perl-compile', '--check', 'plugin-tests');
    is($rc, 0, 'setup: set-checks succeeds') or diag($out);

    my ($arc, $aout) = run_checks_cli('audit', '--blueprint', "$bp_dir/blueprint.md");
    is($arc, 0, 'bp-checks.pl audit is clean after set-checks satisfies the implied check') or diag($aout);

    my $text = slurp($l);
    is(BpChecks::_fm($text, 'checks'), 'perl-compile:plugin-tests', 'BpChecks::_fm reads back exactly the new value');
};

# ===========================================================================
# AC-14 -- control: a hand-written ledger (never touched by set-checks) that
# omits an implied check makes audit fail, proving AC-13's exit 0 is meaningful.
# ===========================================================================

subtest 'AC-14 (control): a ledger omitting an implied check makes audit exit 1, naming it' => sub {
    my ($l, $bp_dir) = fixture(
        checks    => 'plugin-tests',
        table     => '*.pl => perl-compile',
        write_set => 'a.pl',
        decisions => [[14, 'Unrelated.']],
    );
    my ($arc, $aout) = run_checks_cli('audit', '--blueprint', "$bp_dir/blueprint.md");
    isnt($arc, 0, 'audit fails: perl-compile is implied by write_set a.pl but checks: only has plugin-tests') or diag($aout);
    like($aout, qr/perl-compile/, '...naming the omitted check');
};

# ===========================================================================
# AC-15 -- B-13 usage errors.
# ===========================================================================

subtest 'AC-15: usage errors exit 3 with exactly one stderr line, nothing read or written' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[15, 'Re-scope: checks become plugin-tests.']],
    );
    my $before = slurp($l);
    my @cases = (
        [['--decision', '15', '--check', 'plugin-tests'],              qr/missing required --ledger/,   'no --ledger'],
        [['--ledger', $l, '--check', 'plugin-tests'],                  qr/missing required --decision/, 'no --decision'],
        [['--ledger', $l, '--decision', '15'],                         qr/missing required --check/,    'no --check'],
        [['--ledger', $l, '--decision', '0', '--check', 'plugin-tests'], qr/not a positive integer/,    'non-positive decision'],
        [['--ledger', $l, '--decision', 'abc', '--check', 'plugin-tests'], qr/not a positive integer/,  'non-integer decision'],
        [['--ledger', $l, '--decision', '15', '--check', 'plugin-tests', '--bogus-flag'], qr/unrecognised option|unrecognized/,'unknown option'],
        [['--ledger', $l, '--decision', '15', '--check', 'plugin-tests', 'extra-positional'], qr/extra/,  'extra positional argument'],
    );
    for my $c (@cases) {
        my ($args, $re, $what) = @$c;
        my ($rc, $out) = run_cli('set-checks', @$args);
        isnt($rc, 0, "refused: $what") or diag($out);
        my @lines = split /\n/, $out;
        is(scalar(@lines), 1, "...exactly one stderr line: $what") or diag($out);
        like($out, $re, "...and says why: $what");
    }
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after every usage error');
};

# ===========================================================================
# AC-16 -- B-14 bad name shapes.
# ===========================================================================

subtest 'AC-16: a badly-shaped --check value is refused before any file is touched' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[16, 'Re-scope: checks become plugin-tests.']],
    );
    my $before = slurp($l);
    for my $bad ('a:b', '', 'a b') {
        my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '16', '--check', $bad);
        isnt($rc, 0, "refused: bad --check shape '$bad'") or diag($out);
    }
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after every bad-shape refusal');
};

# ===========================================================================
# AC-17 -- B-15 checks: key absent from frontmatter -> exit 5.
# ===========================================================================

subtest 'AC-17: a frontmatter with no checks: key at all exits 5, ledger unchanged' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[17, 'Re-scope: checks become plugin-tests.']],
    );
    strip_key_line($l, 'checks');
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '17', '--check', 'plugin-tests');
    is($rc, 5, 'exit 5: no checks: key to replace') or diag($out);
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
};

# ===========================================================================
# AC-18 -- B-16 rename failure -> exit 4, no tmp file left (existing seam).
# ===========================================================================

subtest 'AC-18: BP_LEDGER_FAIL_RENAME simulates a mid-write failure: exit 4, byte-identical, no tmp file' => sub {
    my ($l) = fixture(
        checks    => 'perl-compile',
        decisions => [[18, 'Re-scope: checks become plugin-tests.']],
    );
    my $before = slurp($l);
    local $ENV{BP_LEDGER_FAIL_RENAME} = 1;
    my ($rc, $out) = run_cli('set-checks', '--ledger', $l, '--decision', '18', '--check', 'plugin-tests');
    is($rc, 4, 'exit 4: simulated rename failure') or diag($out);
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
    my @tmp = glob("$l.tmp.*");
    is(scalar(@tmp), 0, 'no <ledger>.tmp.* file is left behind');
};

# ===========================================================================
# AC-19 -- syntax check.
# ===========================================================================

subtest 'AC-19: bp-ledger.pl compiles cleanly' => sub {
    my $rc = system($^X, '-c', $LEDGER_PL) >> 8;
    is($rc, 0, 'perl -c bp-ledger.pl exits 0');
};

done_testing();
