#!/usr/bin/env perl
# platform: any
# Immutable oracle for Almanac::Record's REFUSAL / error-shape half
# (blueprint almanac-records, package 02-record-format): field refusal (D2),
# "exit 2 naming file and line" (D3), check_file()'s structured-data
# contract (D4), and the equivalence test against the CLI's
# has_forbidden_bytes. Round-trip / id-generation ACs live in the sibling
# almanac-record-format.t. See specs/02-record-format-spec.md.
#
# HOUSE PATTERN for a not-yet-built module (t/98 bp-write-guard): every
# direct call to Almanac::Record::* is wrapped in eval{} so "Undefined
# subroutine" is a caught, reported failure for THIS assertion rather than
# an abort of the whole file -- every assertion below is expected to fail
# for exactly that reason right now, not for a fixture defect of this
# file's own making.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Encode ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "cannot write fixture $p: $!";
    print {$fh} $bytes;
    close $fh;
}
sub tmp_files_in {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.tmp\./ } readdir($dh);
    closedir $dh;
    return @f;
}

my $RECORD_PM = "$S/Almanac/Record.pm";
my $LOAD_ERR;
eval { require Almanac::Record; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::Record requires cleanly (prerequisite for every assertion below)')
    or diag("load error: $LOAD_ERR -- every assertion below is expected to fail for exactly this reason");

# =============================================================================
# AC21 -- scope guard: no locking vocabulary anywhere in Record.pm's text.
# =============================================================================
{
    my $text = slurp_raw($RECORD_PM);
    if (defined $text) {
        unlike($text, qr/\b(?:acquire|release|suspend|resume|flock)\b/,
            'AC21: Record.pm text contains none of acquire/release/suspend/resume/flock '
          . '(locking is package 01/03\'s, not this module\'s)');
    }
    else {
        fail('AC21: Record.pm does not exist yet, so the scope-guard grep cannot run');
    }
}

# =============================================================================
# AC8 -- serialize() dies for each forbidden-byte vector: a blessed
#        Almanac::Record::Error, kind => 'refused', exit_code == 2, message
#        matching 'must be one line' AND naming the offending field's key.
# =============================================================================
{
    my %bad_vectors = (
        'LF (\n)'                    => "a\nb",
        'CR (\r)'                    => "a\rb",
        'NUL (\x00)'                 => "a\x00b",
        'VT (\x0B)'                  => "a\x0Bb",
        'FF (\x0C)'                  => "a\x0Cb",
        'DEL (\x7F)'                 => "a\x7Fb",
        'NEL decoded (\x{0085})'     => "a\x{0085}b",
        'LINE SEP decoded (\x{2028})' => "a\x{2028}b",
        'PARA SEP decoded (\x{2029})' => "a\x{2029}b",
        'LINE SEP utf8 bytes (\xE2\x80\xA8)' => "a\xE2\x80\xA8b",
    );
    for my $name (sort keys %bad_vectors) {
        my $rec = { fields => { note => $bad_vectors{$name} }, order => ['note'], body => '' };
        my $ok  = eval { Almanac::Record::serialize($rec); 1 };
        my $err = $@;
        ok(!$ok, "AC8: serialize dies for $name");
        is(ref($err), 'Almanac::Record::Error', "AC8: $name death is an Almanac::Record::Error");
        my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
        is($is_err_obj ? $err->{kind} : undef, 'refused',
           "AC8: $name death has kind => 'refused'");
        is($is_err_obj ? $err->{exit_code} : undef, 2,
           "AC8: $name death has exit_code == 2");
        my $msg = $is_err_obj ? $err->{message} : (ref($err) ? '' : "$err");
        like($msg, qr/must be one line/, "AC8: $name message matches /must be one line/");
        like($msg, qr/\bnote\b/, "AC8: $name message names the offending field 'note'");
    }
}

# =============================================================================
# AC9 -- write_file() refusal: a NEW target is never created; an EXISTING
#        clean target is left byte-identical with no *.tmp.* remaining.
# =============================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $new_path = "$tmp/new.md";
    my $bad_rec  = { fields => { note => "a\nb" }, order => ['note'], body => '' };
    my $ok = eval { Almanac::Record::write_file($new_path, $bad_rec); 1 };
    ok(!$ok, 'AC9: write_file to a NEW path with a refused field dies');
    ok(!-e $new_path, 'AC9: the NEW path does not exist after the refusal');
}
{
    my $tmp      = tempdir(CLEANUP => 1);
    my $path     = "$tmp/existing.md";
    my $good_raw = "---\nid: 1\n---\nclean body\n";
    write_raw($path, $good_raw);
    my $bad_rec = { fields => { note => "a\nb" }, order => ['note'], body => '' };
    my $ok = eval { Almanac::Record::write_file($path, $bad_rec); 1 };
    ok(!$ok, 'AC9: write_file to an EXISTING clean path with a refused field dies');
    is(slurp_raw($path), $good_raw, 'AC9: the existing file bytes are UNCHANGED');
    my @tmps = tmp_files_in($tmp);
    is(scalar(@tmps), 0, 'AC9: no *.tmp.* file remains in the directory') or diag("@tmps");
}

# =============================================================================
# AC8b / AC8c -- fix-batch A6 (mutation coverage for M11 and M14, the
# "empty-record refusal" and "field-name validation" paths red-team's M35
# deleted along with seven others and scored identically to baseline).
# =============================================================================
{
    my $rec = { fields => {}, order => [], body => '' };
    my $ok  = eval { Almanac::Record::serialize($rec); 1 };
    my $err = $@;
    ok(!$ok, 'AC8b: serialize dies for a record with zero fields (M11)');
    is(ref($err), 'Almanac::Record::Error', 'AC8b: the zero-fields death is an Almanac::Record::Error');
    my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
    is($is_err_obj ? $err->{kind} : undef, 'refused', "AC8b: zero-fields death has kind => 'refused'");
    is($is_err_obj ? $err->{exit_code} : undef, 2, 'AC8b: zero-fields death has exit_code == 2');
    my $msg = $is_err_obj ? $err->{message} : (ref($err) ? '' : "$err");
    like($msg, qr/at least one field/, 'AC8b: zero-fields message matches /at least one field/');
}
{
    my $rec = { fields => { 'bad key' => 'v' }, order => ['bad key'], body => '' };
    my $ok  = eval { Almanac::Record::serialize($rec); 1 };
    my $err = $@;
    ok(!$ok, 'AC8c: serialize dies for an illegal field NAME (M14)');
    is(ref($err), 'Almanac::Record::Error', 'AC8c: the illegal-field-name death is an Almanac::Record::Error');
    my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
    is($is_err_obj ? $err->{kind} : undef, 'refused', "AC8c: illegal-field-name death has kind => 'refused'");
    is($is_err_obj ? $err->{exit_code} : undef, 2, 'AC8c: illegal-field-name death has exit_code == 2');
    my $msg = $is_err_obj ? $err->{message} : (ref($err) ? '' : "$err");
    like($msg, qr/not a legal frontmatter key/,
         'AC8c: illegal-field-name message matches /not a legal frontmatter key/');
}

# =============================================================================
# AC19b -- fix-batch A2 (HIGH-2): a field value supplied as raw UTF-8 BYTES,
# not decoded characters -- how @ARGV/<:raw> actually deliver it -- must
# round-trip through write_file()/read_file() without serialize() emitting
# bytes its own check() rejects (the em-dash incident, moved to the write
# side).
# =============================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $path = "$tmp/bytes-title.md";
    my $title_bytes = "backpack \xE2\x80\x94 two bugs"; # raw UTF-8 bytes, NOT decoded
    my $rec = { fields => { id => '1', title => $title_bytes }, order => ['id', 'title'], body => '' };

    my $ok = eval { Almanac::Record::write_file($path, $rec); 1 };
    ok($ok, 'AC19b: write_file accepts a field value supplied as raw UTF-8 BYTES') or diag($@);

    if ($ok) {
        my $problems = eval { Almanac::Record::check_file($path) };
        ok(!$@, 'AC19b: check_file does not die on the file just written') or diag($@);
        is_deeply($problems, [],
            'AC19b: the file check_file() just wrote back is CLEAN -- serialize() must never '
          . 'emit bytes its own check() rejects (HIGH-2, the em-dash incident on the write side)')
            if !$@;

        my $rf = eval { Almanac::Record::read_file($path) };
        ok(defined $rf, 'AC19b: read_file succeeds on the file just written from byte-string fields')
            or diag($@);
        is($rf->{fields}{title}, Encode::decode('UTF-8', $title_bytes),
           'AC19b: the round-tripped title decodes to the same characters as the original bytes')
            if defined $rf;
    }
}

# =============================================================================
# AC20c -- fix-batch A4 (MEDIUM-3b): a surrogate or Unicode noncharacter must
# be REFUSED by serialize(), never silently substituted with U+FFFD.
# =============================================================================
{
    my %vectors = (
        'surrogate U+D800'      => "a" . chr(0xD800) . "b",
        'noncharacter U+FFFE'   => "a" . chr(0xFFFE) . "b",
        'noncharacter U+10FFFF' => "a" . chr(0x10FFFF) . "b",
    );
    for my $name (sort keys %vectors) {
        my $rec = { fields => { note => $vectors{$name} }, order => ['note'], body => '' };
        my $ok  = eval { Almanac::Record::serialize($rec); 1 };
        my $err = $@;
        ok(!$ok, "AC20c: serialize refuses $name rather than silently substituting U+FFFD");
        my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
        is($is_err_obj ? $err->{kind} : undef, 'refused', "AC20c: $name death has kind => 'refused'")
            if !$ok;
    }
}

# =============================================================================
# AC20b -- fix-batch A4 (MEDIUM-3a): five invalid UTF-8 byte sequences that
# survived the old byte-range fallback (none of their bytes fall in
# \x7F-\x9F) must now be rejected by has_forbidden_bytes().
# =============================================================================
{
    my %invalid_utf8 = (
        'overlong U+007F (C1 BF)'      => "\xC1\xBF",
        'overlong U+002F (C0 AF)'      => "\xC0\xAF",
        'lone continuation byte (BF)'  => "\xBF",
        'CP1252 nbsp byte (A0)'        => "\xA0",
        'above U+10FFFF (F5 BF BF BF)' => "\xF5\xBF\xBF\xBF",
    );
    for my $name (sort keys %invalid_utf8) {
        my $v  = $invalid_utf8{$name};
        my $hf = eval { Almanac::Record::has_forbidden_bytes($v) };
        ok(!$@, "AC20b: has_forbidden_bytes is callable for invalid UTF-8 vector $name") or diag($@);
        ok($hf, "AC20b: has_forbidden_bytes REJECTS the invalid UTF-8 vector $name") if !$@;
    }
}

# =============================================================================
# AC11 -- six malformed shapes, each a hard error naming file and line
#         (D3): no frontmatter, unterminated frontmatter, empty frontmatter,
#         duplicate key, bad field line, CR in the frontmatter.
# =============================================================================
my %malformed = (
    no_frontmatter           => { raw => "not-delim\nid: 1\n---\nbody\n",                       line => 1, problem_kind => 'no_frontmatter' },
    unterminated_frontmatter => { raw => "---\nid: 1\nbody with no closing delimiter\n",         line => 1, problem_kind => 'unterminated_frontmatter' },
    empty_frontmatter        => { raw => "---\n---\nbody\n",                                    line => 2, problem_kind => 'empty_frontmatter' },
    duplicate_key            => { raw => "---\nid: 1\nid: 2\n---\nbody\n",                      line => 3, problem_kind => 'duplicate_key' },
    bad_field_line           => { raw => "---\nnotakeyvalueline\n---\nbody\n",                  line => 2, problem_kind => 'bad_field_line' },
    carriage_return          => { raw => "---\r\nid: 1\n---\nbody\n",                           line => 1, problem_kind => 'carriage_return' },
    # fix-batch A1/A6 additions: HIGH-1 named these as unasserted-detection
    # kinds (forbidden_field_value from check(), closing-delimiter CR,
    # field-line CR, "key:value" with no space) whose absence let mutants
    # M01, M02, M03 and M15 survive all 564 assertions.
    carriage_return_closing  => { raw => "---\nid: 1\n---\r\nbody\n",                           line => 3, problem_kind => 'carriage_return' },
    carriage_return_field    => { raw => "---\nid: 1\r\n---\nbody\n",                           line => 2, problem_kind => 'carriage_return' },
    forbidden_field_value    => { raw => "---\nid: 1\nnote: a\x0Bb\n---\nbody\n",               line => 3, problem_kind => 'forbidden_field_value' },
    colon_no_space           => { raw => "---\nid:1\n---\nbody\n",                              line => 2, problem_kind => 'bad_field_line' },
);
for my $kind (sort keys %malformed) {
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/$kind.md";
    write_raw($path, $malformed{$kind}{raw});

    my $ok  = eval { Almanac::Record::read_file($path); 1 };
    my $err = $@;
    ok(!$ok, "AC11 [$kind]: read_file dies on the malformed fixture");
    my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
    is($is_err_obj ? $err->{kind} : undef, 'malformed', "AC11 [$kind]: death has kind => 'malformed'");
    is($is_err_obj ? $err->{exit_code} : undef, 2, "AC11 [$kind]: death has exit_code == 2");
    my $msg = $is_err_obj ? $err->{message} : (ref($err) ? '' : "$err");
    like($msg, qr/\Q$path\E/, "AC11 [$kind]: message names the file path");
    my $n = $malformed{$kind}{line};
    like($msg, qr/line $n:/, "AC11 [$kind]: message names 'line $n:'");

    # fix-batch A1 (HIGH-1's root cause): the assertions above only ever
    # checked the OVERALL error shape ('malformed', exit 2, a line number in
    # the message text) -- never the SPECIFIC problem kind that produced it.
    # That is what let mutants relabel one detection as another and still
    # pass every one of the checks above. Assert the real kind too.
    my $first_problem_kind = ($is_err_obj && ref($err->{problems}) eq 'ARRAY' && @{ $err->{problems} })
        ? $err->{problems}[0]{kind} : undef;
    is($first_problem_kind, $malformed{$kind}{problem_kind},
       "AC11 [$kind]: the first problem's kind is '$malformed{$kind}{problem_kind}'");
}

# =============================================================================
# AC11 [empty_frontmatter_terminal] -- fix-batch A6, mutant M26: empty_
# frontmatter must be TERMINAL. A fixture combining an empty frontmatter
# with a CR on the opening delimiter proves it: if the terminal `return` is
# removed, execution falls through to the CR check below it and reports
# TWO problems instead of one.
# =============================================================================
{
    my $raw = "---\r\n---\nbody\n";
    my $problems = eval { Almanac::Record::check($raw, '(fixture)') };
    ok(!$@, 'AC11 [empty_frontmatter_terminal]: check() is callable on an empty frontmatter '
          . 'with a CR on the opening delimiter') or diag($@);
    if (!$@) {
        is(scalar(@$problems), 1,
           'AC11 [empty_frontmatter_terminal]: exactly one problem is reported -- empty_'
         . 'frontmatter is terminal, so the opening-delimiter CR is never ALSO reported');
        is($problems->[0]{kind}, 'empty_frontmatter',
           "AC11 [empty_frontmatter_terminal]: the one problem's kind is 'empty_frontmatter'");
    }
}

# =============================================================================
# AC11 [ascending_sort] -- fix-batch A6, mutant M13: check() must return
# problems in ascending line order even when they were PUSHED out of order.
# The opening/closing delimiter CR checks run before the field-line loop, so
# a CR on the closing delimiter (a late line) is pushed before a bad field
# line earlier in the file -- exposing the sort if it is ever dropped.
# =============================================================================
{
    my $raw = "---\nnotakeyvalueline\n---\r\nbody\n";
    my $problems = eval { Almanac::Record::check($raw, '(fixture)') };
    ok(!$@, 'AC11 [ascending_sort]: check() is callable on a fixture whose problems are '
          . 'pushed out of line order') or diag($@);
    if (!$@) {
        is(scalar(@$problems), 2, 'AC11 [ascending_sort]: exactly two problems are reported');
        if (ref($problems) eq 'ARRAY' && @$problems == 2) {
            is($problems->[0]{line}, 2,
               'AC11 [ascending_sort]: the FIRST returned problem is the earlier line (2), '
             . 'proving problems are sorted ascending rather than left in push order');
            is($problems->[1]{line}, 3,
               'AC11 [ascending_sort]: the SECOND returned problem is the later line (3)');
        }
    }
}

# =============================================================================
# AC11 [unreadable_missing] -- fix-batch A1, mutant M09: the overall Error
# kind must be 'unreadable' for a read that failed because the file could
# not be opened at all -- never 'malformed', which is reserved for a file
# that opened fine but failed structural checks.
# =============================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $missing_path = "$tmp/does-not-exist.md";
    my $ok  = eval { Almanac::Record::read_file($missing_path); 1 };
    my $err = $@;
    ok(!$ok, 'AC11 [unreadable_missing]: read_file dies on a missing path');
    my $is_err_obj = (ref($err) eq 'Almanac::Record::Error');
    is($is_err_obj ? $err->{kind} : undef, 'unreadable',
       "AC11 [unreadable_missing]: death has kind => 'unreadable' (never 'malformed')");
    is($is_err_obj ? $err->{exit_code} : undef, 2, 'AC11 [unreadable_missing]: death has exit_code == 2');
}

# =============================================================================
# AC12 -- end-to-end exit status through fatal(), from a REAL child process:
#         read_file and write_file against a malformed target both exit 2,
#         never print NOT REACHED, and (for write_file) leave the target
#         byte-identical with no *.tmp.* remaining.
# =============================================================================
{
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/bad.md";
    write_raw($path, "---\nnotakeyvalueline\n---\nbody\n");

    my $read_child = qq{use lib "$S";\n}
                   . qq{require Almanac::Record;\n}
                   . qq{eval { Almanac::Record::read_file(\$ARGV[0]) };\n}
                   . qq{Almanac::Record::fatal(\$\@) if \$\@;\n}
                   . qq{print "NOT REACHED\\n";\n};
    my ($rfh, $read_script) = tempfile('record-ac12-read-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    print {$rfh} $read_child;
    close $rfh;

    my ($out_f, $err_f) = ("$tmp/out1", "$tmp/err1");
    system(qq{perl "$read_script" "$path" > "$out_f" 2> "$err_f"});
    my $rc  = ($? == -1) ? undef : ($? >> 8);
    my $out = slurp_raw($out_f) // '';
    my $err = slurp_raw($err_f) // '';
    is($rc, 2, 'AC12 [read_file]: child process exits 2 via fatal()') or diag("stderr: $err");
    unlike($out, qr/NOT REACHED/, 'AC12 [read_file]: NOT REACHED is never printed');
    like($err, qr/almanac record:/, 'AC12 [read_file]: the message is on STDERR');
    unlink $read_script;
}
{
    my $tmp    = tempdir(CLEANUP => 1);
    my $path   = "$tmp/bad.md";
    my $before = "---\nnotakeyvalueline\n---\nbody\n";
    write_raw($path, $before);

    my $write_child = qq{use lib "$S";\n}
                     . qq{require Almanac::Record;\n}
                     . qq{eval \{ Almanac::Record::write_file(\$ARGV[0], }
                     . qq{\{ fields => \{ id => '1' \}, order => ['id'], body => '' \}) \};\n}
                     . qq{Almanac::Record::fatal(\$\@) if \$\@;\n}
                     . qq{print "NOT REACHED\\n";\n};
    my ($wfh, $write_script) = tempfile('record-ac12-write-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    print {$wfh} $write_child;
    close $wfh;

    my ($out_f, $err_f) = ("$tmp/out2", "$tmp/err2");
    system(qq{perl "$write_script" "$path" > "$out_f" 2> "$err_f"});
    my $rc  = ($? == -1) ? undef : ($? >> 8);
    my $out = slurp_raw($out_f) // '';
    my $err = slurp_raw($err_f) // '';
    is($rc, 2, 'AC12 [write_file]: child process exits 2 via fatal() against a malformed existing target')
        or diag("stderr: $err");
    unlike($out, qr/NOT REACHED/, 'AC12 [write_file]: NOT REACHED is never printed');
    like($err, qr/almanac record:/, 'AC12 [write_file]: the message is on STDERR');
    is(slurp_raw($path), $before, 'AC12 [write_file]: the malformed target is byte-identical afterwards');
    my @tmps = tmp_files_in($tmp);
    is(scalar(@tmps), 0, 'AC12 [write_file]: no *.tmp.* file remains beside the target') or diag("@tmps");
    unlink $write_script;
}

# =============================================================================
# AC13 -- check_file() is structured data: ARRAY of HASHes with
#         kind/path/line/message; [] for clean; exactly one 'unreadable'
#         for a missing path and for a directory; never dies.
# =============================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $clean_path = "$tmp/clean.md";
    write_raw($clean_path, "---\nid: 1\n---\nbody\n");

    my $problems = eval { Almanac::Record::check_file($clean_path) };
    ok(!$@, 'AC13: check_file never dies on a clean file') or diag($@);
    if (!$@) {
        is(ref($problems), 'ARRAY', 'AC13: check_file returns an ARRAY ref (clean)');
        is_deeply($problems, [], 'AC13: a clean file gives []');
    }

    my $missing_path = "$tmp/does-not-exist.md";
    my $missing = eval { Almanac::Record::check_file($missing_path) };
    ok(!$@, 'AC13: check_file never dies on a missing file') or diag($@);
    if (!$@) {
        is(ref($missing), 'ARRAY', 'AC13: missing-file result is an ARRAY ref');
        is(scalar(@{ $missing || [] }), 1, 'AC13: a missing path gives exactly one problem');
        is($missing->[0]{kind}, 'unreadable', 'AC13: the missing-path problem has kind => unreadable')
            if ref($missing) eq 'ARRAY' && @$missing;
    }

    my $dir_path = tempdir(CLEANUP => 1);
    my $dirres = eval { Almanac::Record::check_file($dir_path) };
    ok(!$@, 'AC13: check_file never dies on a directory path') or diag($@);
    if (!$@) {
        is(scalar(@{ $dirres || [] }), 1, 'AC13: a directory path gives exactly one problem');
        is($dirres->[0]{kind}, 'unreadable', 'AC13: the directory problem has kind => unreadable')
            if ref($dirres) eq 'ARRAY' && @$dirres;
        # fix-batch A6, mutant M12: dropping the -f "plain file" guard gives
        # the SAME overall kind on this host (opening a directory handle
        # succeeds here, but reading from it returns undef, which still
        # ends up classified 'unreadable') -- the mutant is invisible unless
        # something checks the MESSAGE that guard produces.
        like($dirres->[0]{message}, qr/not a plain file/,
             'AC13: the directory problem message says "not a plain file" (M12)')
            if ref($dirres) eq 'ARRAY' && @$dirres;
    }

    for my $p (@{ $problems || [] }, @{ $missing || [] }, @{ $dirres || [] }) {
        ok((ref($p) eq 'HASH' && exists $p->{kind} && exists $p->{path}
             && exists $p->{line} && exists $p->{message}),
           'AC13: every problem hash has kind/path/line/message');
        ok((defined $p->{line} && $p->{line} =~ /\A\d+\z/), 'AC13: line is an integer')
            if ref($p) eq 'HASH';
    }
}

# =============================================================================
# AC14 -- check_file() prints NOTHING, verified from a REAL child process
#         whose STDOUT/STDERR are redirected to real files (never an
#         in-memory scalar -- that fails on Git-for-Windows perl).
# =============================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $clean_path = "$tmp/clean.md";
    write_raw($clean_path, "---\nid: 1\n---\nbody\n");
    my $bad_path = "$tmp/bad.md";
    write_raw($bad_path, "---\nnotakeyvalueline\n---\nbody\n");
    my $missing_path = "$tmp/missing.md";
    # fix-batch A3 (red-team MEDIUM-1): a genuinely empty (zero-byte) file --
    # an interrupted write, a `touch`, a crashed editor -- used to print
    # "Use of uninitialized value" to STDERR, breaking the print-nothing
    # contract AC14 exists to enforce. AC14's own child-process method
    # already catches it; this fixture keeps it caught.
    my $empty_path = "$tmp/empty.md";
    write_raw($empty_path, '');

    for my $case ([clean => $clean_path], [malformed => $bad_path], [missing => $missing_path],
                  [empty => $empty_path]) {
        my ($label, $target) = @$case;
        my $child = qq{use lib "$S";\n}
                  . qq{require Almanac::Record;\n}
                  . qq{Almanac::Record::check_file(\$ARGV[0]);\n};
        my ($cfh, $script) = tempfile("record-ac14-$label-XXXXXX", SUFFIX => '.pl', TMPDIR => 1);
        print {$cfh} $child;
        close $cfh;
        my ($out_f, $err_f) = ("$tmp/out-$label", "$tmp/err-$label");
        system(qq{perl "$script" "$target" > "$out_f" 2> "$err_f"});
        my @out_stat = stat($out_f);
        my @err_stat = stat($err_f);
        is($out_stat[7], 0, "AC14 [$label]: STDOUT is zero-length after check_file");
        is($err_stat[7], 0, "AC14 [$label]: STDERR is zero-length after check_file");
        unlink $script;
    }

    # fix-batch A3: an empty file is a structural problem (no frontmatter
    # delimiter), not an I/O failure -- it opened and read fine, it just had
    # nothing in it.
    my $empty_problems = eval { Almanac::Record::check_file($empty_path) };
    ok(!$@, 'AC14 [empty]: check_file does not die on a zero-byte file') or diag($@);
    if (!$@) {
        is(scalar(@{ $empty_problems || [] }), 1, 'AC14 [empty]: a zero-byte file gives exactly one problem');
        is($empty_problems->[0]{kind}, 'no_frontmatter',
           "AC14 [empty]: a zero-byte file reports kind => 'no_frontmatter', not 'unreadable'")
            if ref($empty_problems) eq 'ARRAY' && @$empty_problems;
    }
}

# =============================================================================
# AC15 -- multiple problems: a duplicate key on line 4 and a bad field line
#         on line 6 both come back, ascending by line, with the duplicate's
#         key field set.
# =============================================================================
{
    my $raw = join("\n",
        '---',               # line 1
        'id: 1',             # line 2
        'status: open',      # line 3
        'status: resolved',  # line 4 -- duplicate 'status'
        'title: t',          # line 5
        'bad line no colon', # line 6 -- bad_field_line
        '---',               # line 7
        'body',              # line 8
    ) . "\n";
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/multi.md";
    write_raw($path, $raw);

    my $problems = eval { Almanac::Record::check_file($path) };
    ok(!$@, 'AC15: check_file does not die on the multi-problem fixture') or diag($@);
    if (!$@) {
        is(ref($problems), 'ARRAY', 'AC15: check_file returns an ARRAY ref');
        is(scalar(@{ $problems || [] }), 2, 'AC15: exactly two problems are returned');
        if (ref($problems) eq 'ARRAY' && @$problems == 2) {
            is($problems->[0]{kind}, 'duplicate_key', 'AC15: the first problem (ascending line) is duplicate_key');
            is($problems->[0]{line}, 4, 'AC15: duplicate_key is reported at line 4 (the later occurrence)');
            is($problems->[0]{key}, 'status', "AC15: duplicate_key's key field is the repeated key 'status'");
            is($problems->[1]{kind}, 'bad_field_line', 'AC15: the second problem (ascending line) is bad_field_line');
            is($problems->[1]{line}, 6, 'AC15: bad_field_line is reported at line 6');
        }
    }
}

# =============================================================================
# AC18 -- a lone invalid UTF-8 byte (\x94) yields exactly one problem,
#         kind => 'not_utf8', naming the correct line and a byte offset --
#         never forbidden_field_value, never a silently mangled parse.
# =============================================================================
{
    my $raw = "---\nid: 1\ntitle: bad\x94byte\n---\nbody\n";

    my $problems = eval { Almanac::Record::check($raw, '(fixture)') };
    ok(!$@, 'AC18: check() is callable on invalid UTF-8 bytes') or diag($@);
    if (!$@) {
        is(ref($problems), 'ARRAY', 'AC18: check() returns an ARRAY ref for invalid UTF-8 bytes');
        is(scalar(@{ $problems || [] }), 1, 'AC18: exactly one problem for a lone invalid UTF-8 byte');
        if (ref($problems) eq 'ARRAY' && @$problems == 1) {
            is($problems->[0]{kind}, 'not_utf8', 'AC18: the problem kind is not_utf8');
            is($problems->[0]{line}, 3, 'AC18: the invalid byte is attributed to line 3 (the title field line)');
            like($problems->[0]{message}, qr/not valid UTF-8/, 'AC18: message matches /not valid UTF-8/');
            like($problems->[0]{message}, qr/offset/, 'AC18: message names a byte offset');
        }
    }

    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/badutf8.md";
    write_raw($path, $raw);
    my $ok  = eval { Almanac::Record::read_file($path); 1 };
    my $err = $@;
    ok(!$ok, 'AC18: read_file dies on invalid UTF-8');
    is((ref($err) eq 'Almanac::Record::Error') ? $err->{exit_code} : undef, 2,
       'AC18: the death carries exit_code == 2');
}

# =============================================================================
# AC20 -- equivalence with the CLI's rule: Almanac::Record::has_forbidden_bytes
#         must agree with AlmanacBug::has_forbidden_bytes on every shared
#         vector, do-loaded exactly as frontmatter-injection.t already does.
# =============================================================================
{
    my $A = "$S/almanac-bug.pl";
    ok(-f $A, 'AC20: almanac-bug.pl exists for the equivalence check') or BAIL_OUT('script missing');
    do $A;
    die "AC20: could not load almanac-bug.pl: $@" if $@;

    my @vectors = (
        'safe value', "evil\x00injected", "a\x7Fb", "a\x{2028}b", "a\xe2\x80\xa8b",
        "a\x{2029}b", "a\nb", "a\rb", "a\x94b", "before\tafter",
        "backpack \xe2\x80\x94 two bugs", "Andr\xc3\xa9's report", undef,
    );
    for my $v (@vectors) {
        my $label = defined $v ? $v : '(undef)';
        $label =~ s/[\x00-\x1f\x7f-\xff]/./g;

        my $ours_val = eval { Almanac::Record::has_forbidden_bytes($v) };
        my $ours_err = $@;
        ok(!$ours_err, "AC20: has_forbidden_bytes is callable for [$label]") or diag($ours_err);
        next if $ours_err;

        my $ours = $ours_val ? 1 : 0;
        my $cli  = AlmanacBug::has_forbidden_bytes($v) ? 1 : 0;
        is($ours, $cli, "AC20: has_forbidden_bytes agrees with AlmanacBug:: for [$label]");
    }
}

done_testing();
