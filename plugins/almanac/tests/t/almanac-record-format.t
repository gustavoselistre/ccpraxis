#!/usr/bin/env perl
# platform: any
# Immutable oracle for Almanac::Record's ROUND-TRIP half (blueprint
# almanac-records, package 02-record-format): the grammar (parse/serialize),
# key-order rules, id generation, and the live bug-report store as the true
# acceptance test (spec section 1, "Why").
# Refusal / error-shape / structured-problem ACs live in the sibling
# almanac-record-refusals.t. See specs/02-record-format-spec.md.
#
# STEP-2 GATE INSTRUCTION (binding; the spec text alone gets this wrong).
# AC4/AC5 -- round-tripping the LIVE bug reports -- are the real oracle of
# this package. Per the ledger's step-2 gate: where
# .ccpraxis-local-data/bug-reports/ EXISTS (it does on this host, 94 entries
# including *.md.lock sidecars measured 2026-09-17), those assertions RUN
# and their result COUNTS -- never a bare skip_all. Only when the directory
# is genuinely absent (fresh clone / container) does this file skip, and it
# does so LOUDLY, with diagnostics that make a green run there unmistakable
# from an actually-verified run. See the AC4/AC5 block below.
#
# HOUSE PATTERN for a not-yet-built module (t/98 bp-write-guard, this
# blueprint's own step-2 note): every direct call to Almanac::Record::* is
# wrapped in eval{} so "Undefined subroutine" is a caught, reported failure
# for THIS assertion rather than an abort of the whole file -- every
# assertion below is expected to fail for exactly that reason right now,
# not for a fixture defect of this file's own making.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);

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

# =============================================================================
# AC1 -- Record.pm exists, compiles, requires cleanly with only the
#        `$Bin/../../scripts` lib convention almanac-lock-bounded-acquire.t
#        already uses.
# =============================================================================
my $RECORD_PM = "$S/Almanac/Record.pm";
ok(-f $RECORD_PM, 'AC1: plugins/almanac/scripts/Almanac/Record.pm exists')
    or diag('Almanac::Record.pm is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

my $LOAD_ERR;
eval { require Almanac::Record; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'AC1: Almanac::Record requires cleanly')
    or diag("load error: $LOAD_ERR");

# =============================================================================
# AC2 -- round-trip: pipes, angle brackets, a column-0 ---, a TAB, an em
#        dash, and a trailing newline, all in the body.
# =============================================================================
{
    my $body = join("\n",
        'a | b | c',
        '<tag attr="x">',
        '---',
        "line with a tab:\tend",
        "an em dash \xE2\x80\x94 here",
    ) . "\n";
    my $raw = "---\nid: 1\n---\n" . $body;

    my $rec = eval { Almanac::Record::parse($raw) };
    ok(defined $rec, 'AC2: parse() succeeds on the synthetic body fixture') or diag($@);
    if (defined $rec) {
        my $out = eval { Almanac::Record::serialize($rec) };
        is($out, $raw,
           'AC2: serialize(parse($b)) eq $b byte-for-byte (pipes, angle brackets, '
         . 'column-0 ---, TAB, em dash, trailing newline)')
            or diag($@);
    }
}

# =============================================================================
# AC3 -- same shape with NO trailing newline, and with an EMPTY body.
# =============================================================================
{
    my $body_no_nl = join("\n",
        'a | b | c', '<tag attr="x">', '---', "tab\there", "em dash \xE2\x80\x94");
    my $raw = "---\nid: 1\n---\n" . $body_no_nl;
    my $rec = eval { Almanac::Record::parse($raw) };
    ok(defined $rec, 'AC3a: parse() succeeds on a body with NO trailing newline') or diag($@);
    if (defined $rec) {
        my $out = eval { Almanac::Record::serialize($rec) };
        is($out, $raw, 'AC3a: serialize(parse($b)) eq $b for a body with NO trailing newline')
            or diag($@);
    }
}
{
    my $raw = "---\nid: 1\n---\n";
    my $rec = eval { Almanac::Record::parse($raw) };
    ok(defined $rec, 'AC3b: parse() succeeds on an EMPTY body') or diag($@);
    if (defined $rec) {
        is($rec->{body}, '', 'AC3b: an empty body decodes to the empty string');
        my $out = eval { Almanac::Record::serialize($rec) };
        is($out, $raw, 'AC3b: serialize(parse($b)) eq $b for an EMPTY body') or diag($@);
    }
}
{
    # fix-batch A5 (red-team MEDIUM-2): the closing delimiter is the VERY
    # LAST line, with NO trailing newline at all after it -- distinct from
    # AC3b, whose raw text has a newline after '---' and an empty body
    # after that. Both must round-trip to DIFFERENT byte strings.
    my $raw = "---\nid: 1\n---";
    my $rec = eval { Almanac::Record::parse($raw) };
    ok(defined $rec, 'AC3c: parse() succeeds on a closing delimiter with NO trailing newline at all')
        or diag($@);
    if (defined $rec) {
        is($rec->{body}, undef,
           'AC3c: body is undef (not an empty string) when nothing at all follows the closing '
         . 'delimiter -- distinct from AC3b\'s empty-body-with-trailing-newline shape');
        my $out = eval { Almanac::Record::serialize($rec) };
        is($out, $raw,
           'AC3c: serialize(parse($b)) eq $b -- no newline is added where the original had none')
            or diag($@);
        isnt($out, "---\nid: 1\n---\n",
             'AC3c: this round-trip is NOT byte-identical to AC3b\'s (a record that checks clean '
           . 'must round-trip to the SAME byte string it came from, not to a DIFFERENT clean one)');
    }
}

# =============================================================================
# AC4 / AC5 -- the live store is the real oracle (spec section 1, edge case
# 1). Loud skip only when the directory is genuinely absent.
# =============================================================================
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE = "$REPO/.ccpraxis-local-data/bug-reports";

sub _live_md_files {
    my @f;
    if (opendir(my $dh, $LIVE)) {
        @f = sort grep { /\.md\z/ } readdir($dh);
        closedir $dh;
    }
    return @f;
}

my @live_before = _live_md_files();

if (@live_before) {
    ok(1, "AC4/AC5: live bug-report store FOUND at '$LIVE' with "
        . scalar(@live_before) . " *.md file(s) -- the round-trip criterion "
        . "RUNS FOR REAL on this host, per the step-2 gate.");

    my $checked = 0;
    for my $fname (@live_before) {
        my $path   = "$LIVE/$fname";
        my $before = slurp_raw($path);

        my $problems = eval { Almanac::Record::check_file($path) };
        ok(!$@, "AC4: check_file does not die for live report $fname") or diag($@);
        if (defined $problems) {
            is_deeply($problems, [], "AC4: check_file([]) for live report $fname")
                or diag('problems: ' . join('; ', map { $_->{message} } @$problems));
        }

        my $rec = eval { Almanac::Record::read_file($path) };
        ok(defined $rec, "AC4: read_file succeeds for $fname") or diag($@);
        if (defined $rec) {
            my $ser = eval { Almanac::Record::serialize($rec) };
            is($ser, $rec->{raw}, "AC4: serialize(read_file($fname)) is byte-identical to raw")
                if defined $ser;
        }

        my $after = slurp_raw($path);
        is($after, $before, "AC4: $fname bytes UNCHANGED by this test (live store is read-only here)");
        $checked++;
    }
    is($checked, scalar(@live_before),
       'AC4: every *.md file named by the sweep was actually opened and checked '
     . '(the fixture list this test names is the one it read)');

    # AC5 -- named fixtures, asserted individually, with a content-identity
    # sanity check so "round-tripped the live reports" cannot be true of a
    # renamed or emptied file wearing the right name.
    for my $case (
        { file => '20260917-033101-c455.md', needle => qr/reap-orphans\.pl/,
          desc => 'column-0 --- line, em dash, fenced code, angle brackets' },
        { file => '20260814-123809-ee3c.md', needle => qr/almanac-bug\.pl/,
          desc => 'indented --- lines inside a code block, $ sigils' },
    ) {
        my $path = "$LIVE/$case->{file}";
        unless (ok(-f $path, "AC5: named live fixture $case->{file} exists ($case->{desc})")) {
            next;
        }
        my $raw = slurp_raw($path);
        like($raw, $case->{needle},
             "AC5: $case->{file} content matches its named identity -- proves the file "
           . "actually read is the one named here, not an empty or renamed stand-in");

        my $rec = eval { Almanac::Record::read_file($path) };
        ok(defined $rec, "AC5: read_file succeeds for $case->{file}") or diag($@);
        if (defined $rec) {
            my $ser = eval { Almanac::Record::serialize($rec) };
            is($ser, $rec->{raw}, "AC5: $case->{file} round-trips byte-identically") if defined $ser;
        }
    }
}
else {
    diag('=' x 78);
    diag("AC4/AC5 SKIPPED: live bug-report store not found at '$LIVE'.");
    diag('This is EXPECTED on a fresh clone or in a container: .ccpraxis-local-data/');
    diag('is gitignored and does not exist there.');
    diag('*** THE LIVE-STORE ROUND-TRIP CRITERION DID NOT RUN IN THIS SESSION. ***');
    diag('A green result immediately below is NOT evidence AC4/AC5 were verified --');
    diag("re-run this suite on a host where '$LIVE' exists.");
    diag('=' x 78);
    ok(1, "AC4/AC5: SKIPPED -- live bug-report store absent at '$LIVE' "
        . "(loud skip; criterion NOT verified this run -- see diagnostics above)");
}

# The live store must be untouched by the WHOLE suite, not just the sweep
# loop above (house convention: frontmatter-injection.t's AC16).
{
    my @live_after = _live_md_files();
    is_deeply(\@live_after, \@live_before,
        'AC4: the live store *.md file LIST is unchanged at the end of this suite');
}

# =============================================================================
# AC6 -- serialize() key-order rules, locked by spec section 2.3.
# =============================================================================
{
    my $rec = { fields => { b => '2', a => '1', c => '3' }, order => [qw(c a b)], body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC6a: serialize succeeds honouring the given order') or diag($@);
    is($bytes, "---\nc: 3\na: 1\nb: 2\n---\n", 'AC6a: order is honoured verbatim')
        if defined $bytes;
}
{
    my $rec = { fields => { a => '1' }, order => [qw(a missing)], body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC6b: serialize succeeds with a dangling order entry') or diag($@);
    is($bytes, "---\na: 1\n---\n",
       'AC6b: a key in order but absent from fields is skipped') if defined $bytes;
}
{
    my $rec = { fields => { a => '1', z => '9', m => '5' }, order => [qw(a)], body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC6c: serialize succeeds with extra un-ordered fields') or diag($@);
    is($bytes, "---\na: 1\nm: 5\nz: 9\n---\n",
       'AC6c: a key in fields but absent from order is appended in sort order')
        if defined $bytes;
}
{
    my $rec = { fields => { z => '9', a => '1', m => '5' }, body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC6d: serialize succeeds with no order at all') or diag($@);
    is($bytes, "---\na: 1\nm: 5\nz: 9\n---\n",
       'AC6d: with no order, all keys come out in sort order') if defined $bytes;
}
{
    my $rec = { fields => { a => '1', b => '2' }, order => [qw(a a b)], body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC6e: serialize succeeds with a repeated key in order') or diag($@);
    is($bytes, "---\na: 1\nb: 2\n---\n",
       'AC6e: a repeated key in order is emitted once (later occurrence skipped)')
        if defined $bytes;
}

# =============================================================================
# AC7 -- parse() returns fields/order/body; read_file() additionally returns
#        path and the original bytes in raw.
# =============================================================================
{
    my $raw = "---\nid: 42\ntitle: hello\n---\nbody text\n";
    my $rec = eval { Almanac::Record::parse($raw) };
    ok(defined $rec, 'AC7: parse() returns a record') or diag($@);
    if (defined $rec) {
        is_deeply($rec->{fields}, { id => '42', title => 'hello' }, 'AC7: parse() fields are correct');
        is_deeply($rec->{order}, ['id', 'title'], 'AC7: parse() order matches file order');
        is($rec->{body}, "body text\n", 'AC7: parse() body is correct');
    }

    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/rec.md";
    write_raw($path, $raw);
    my $rf = eval { Almanac::Record::read_file($path) };
    ok(defined $rf, 'AC7: read_file() returns a record') or diag($@);
    if (defined $rf) {
        is($rf->{path}, $path, 'AC7: read_file() sets path');
        is($rf->{raw}, $raw, 'AC7: read_file() sets raw to the original bytes');
        is_deeply($rf->{fields}, { id => '42', title => 'hello' },
                  'AC7: read_file() fields match parse()');
    }
}

# =============================================================================
# AC10 -- forbidden-byte ACCEPTANCE half (D2): em dash, e-acute, TAB, |, <,
#         >, :, internal spaces are all fine, and round-trip verbatim.
# =============================================================================
{
    my $value = "em dash \x{2014} eacute \x{00E9} tab:\tend pipe:| angle:<x> colon: internal spaces here";

    my $hf = eval { Almanac::Record::has_forbidden_bytes($value) };
    ok(!$@, 'AC10: has_forbidden_bytes is callable on the combined acceptance value') or diag($@);
    ok(defined($hf) && !$hf, 'AC10: the combined acceptance value is NOT forbidden')
        if !$@;

    for my $case (
        ['em dash', "\x{2014}"], ['eacute', "\x{00E9}"], ['tab', "\t"],
        ['pipe', '|'], ['lt', '<'], ['gt', '>'], ['colon', ':'], ['space', ' '],
    ) {
        my $ok = eval { Almanac::Record::has_forbidden_bytes("safe $case->[1] value") };
        ok(!$@, "AC10: has_forbidden_bytes is callable for $case->[0]") or diag($@);
        ok(defined($ok) && !$ok, "AC10: has_forbidden_bytes returns 0 for $case->[0]") if !$@;
    }

    my $rec = { fields => { value => $value }, order => ['value'], body => '' };
    my $bytes = eval { Almanac::Record::serialize($rec) };
    ok(defined $bytes, 'AC10: serialize accepts the combined acceptance value') or diag($@);
    if (defined $bytes) {
        my $rec2 = eval { Almanac::Record::parse($bytes) };
        ok(defined $rec2, 'AC10: parse succeeds on the re-serialized bytes') or diag($@);
        is($rec2->{fields}{value}, $value,
           'AC10: parsed back identical to the original decoded value') if defined $rec2;
    }
}

# =============================================================================
# AC16 -- 10 000 new_id($fixed_epoch) calls are all distinct, well-formed,
#         and share one timestamp prefix.
# =============================================================================
{
    my $epoch = 1_700_000_000;
    my (%seen, $dupes, $call_err);
    $dupes = 0;
    for (1 .. 10_000) {
        my $id = eval { Almanac::Record::new_id($epoch) };
        if ($@) { $call_err = $@; last }
        $dupes++ if $seen{$id}++;
    }
    ok(!$call_err, 'AC16: new_id($fixed_epoch) is callable 10000 times without dying')
        or diag($call_err);
    if (!$call_err) {
        is($dupes, 0, 'AC16: 10000 calls to new_id($fixed_epoch) yield 10000 DISTINCT ids');
        is(scalar(keys %seen), 10_000, 'AC16: exactly 10000 distinct ids were produced');
        my @bad = grep { !/\A\d{8}-\d{6}-[0-9a-f]{8}\z/ } keys %seen;
        is(scalar(@bad), 0, 'AC16: every id matches /\A\d{8}-\d{6}-[0-9a-f]{8}\z/')
            or diag("first bad id: $bad[0]");
        my %prefixes;
        for my $id (keys %seen) {
            my ($d, $t) = split /-/, $id;
            $prefixes{"$d-$t"} = 1;
        }
        is(scalar(keys %prefixes), 1, 'AC16: all 10000 ids share one YYYYMMDD-HHMMSS prefix');
    }
}

# =============================================================================
# AC17 -- two CHILD PROCESSES generate different ids for the same fixed
#         epoch; ids sort chronologically as plain strings.
# =============================================================================
{
    my $epoch = 1_700_000_100;
    my ($fh, $child) = tempfile('record-new-id-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    print {$fh} qq{use lib "$S";\nrequire Almanac::Record;\nprint Almanac::Record::new_id(\$ARGV[0]);\n};
    close $fh;

    my $id1 = `perl "$child" $epoch`;
    my $id2 = `perl "$child" $epoch`;
    isnt($id1, $id2, 'AC17: two CHILD PROCESSES generate different ids for the same fixed epoch')
        or diag("id1=[$id1] id2=[$id2]");
    unlink $child;

    my $id_t  = eval { Almanac::Record::new_id($epoch) };
    my $id_t1 = eval { Almanac::Record::new_id($epoch + 1) };
    ok(defined($id_t) && defined($id_t1), 'AC17: new_id is callable for the chronological-sort check')
        or diag($@);
    ok($id_t lt $id_t1, 'AC17: new_id($t) lt new_id($t+1) as plain strings')
        if defined($id_t) && defined($id_t1);
}

# =============================================================================
# AC17b -- fix-batch A7 (red-team MEDIUM-4): a bare ($$ & 0xffff) is NOT
# injective in the pid -- two processes whose real pids are 65536 apart
# collide on the id's pid-derived segment outright, which is realistic the
# moment a container pid namespace and a host pid namespace share one store
# over a bind mount. Forcing an actual OS-level pid collision isn't portable
# from a test, so this instead proves the FIX's mechanism directly: across
# several fresh child processes, the id's pid-derived hex segment must not
# always equal the naive $$ & 0xffff mask -- which is exactly what it always
# equalled before the fix, and what it would go back to equalling on EVERY
# run if the fix were reverted.
# =============================================================================
{
    my $epoch = 1_700_000_200;
    my $child = qq{use lib "$S";\n}
              . qq{require Almanac::Record;\n}
              . qq{my \$id = Almanac::Record::new_id(\$ARGV[0]);\n}
              . qq{my (\$seg) = \$id =~ /-([0-9a-f]{4})[0-9a-f]{4}\\z/;\n}
              . qq{printf("%s %s\\n", sprintf('%04x', \$\$ & 0xffff), \$seg);\n};
    my ($fh, $childfile) = tempfile('record-pidmix-XXXXXX', SUFFIX => '.pl', TMPDIR => 1);
    print {$fh} $child;
    close $fh;

    my $runs = 5;
    my $any_diff = 0;
    my $call_ok  = 1;
    for (1 .. $runs) {
        my $line = `perl "$childfile" $epoch`;
        chomp $line;
        my ($naive, $seg) = split ' ', $line;
        $call_ok = 0 unless defined $naive && defined $seg;
        $any_diff = 1 if defined $naive && defined $seg && $naive ne $seg;
    }
    ok($call_ok, 'AC17b: every child process printed a naive-mask/pid-segment pair');
    ok($any_diff,
       'AC17b: across several child processes, the id\'s pid-derived segment is NOT always '
     . 'equal to a bare $$ & 0xffff mask (MEDIUM-4) -- with the fix this is expected on every '
     . 'run; reverting the fix makes the segment equal the naive mask on EVERY run instead')
        if $call_ok;
    unlink $childfile;
}

# =============================================================================
# AC19 -- the em-dash regression: ordinary Unicode punctuation is NOT a
#         control character, decoded correctly, zero problems, round-trips,
#         and survives a subsequent re-serialize (the 82bf wedge).
# =============================================================================
{
    my %vectors = (
        'em dash'      => "\xE2\x80\x94",
        'en dash'      => "\xE2\x80\x93",
        'curly quotes' => "\xE2\x80\x9Cthing\xE2\x80\x9D",
        'ellipsis'     => "\xE2\x80\xA6",
        'accented'     => "Andr\xC3\xA9",
    );
    for my $name (sort keys %vectors) {
        my $frag = $vectors{$name};
        my $raw  = "---\nid: 1\ntitle: backpack $frag two bugs\n---\nbody\n";

        my $problems = eval { Almanac::Record::check($raw, '(fixture)') };
        ok(!$@, "AC19: check() is callable for $name in title") or diag($@);
        is_deeply($problems, [], "AC19: $name in title yields ZERO problems (the em-dash regression)")
            if !$@;

        my $rec = eval { Almanac::Record::parse($raw) };
        ok(defined $rec, "AC19: parse succeeds for $name") or diag($@);
        if (defined $rec) {
            my $ser = eval { Almanac::Record::serialize($rec) };
            is($ser, $raw, "AC19: $name round-trips byte-identically") if defined $ser;

            $rec->{fields}{title} .= ' (edited)';
            my $ser2 = eval { Almanac::Record::serialize($rec) };
            ok(defined $ser2, "AC19: $name can be re-serialized after a field edit without any refusal")
                or diag($@);
        }
    }
}

done_testing();
