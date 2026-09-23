#!/usr/bin/env perl
# platform: any
# ledger-create-api.t -- oracle for `bp-ledger.pl create` (04-model-effort-ledger-validation).
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/04-model-effort-ledger-validation-spec.md
# section 2.1/3 (B-1..B-20, AC-1..AC-9). WRITTEN BLIND TO ANY IMPLEMENTATION: `create` is not in
# bp-ledger.pl's %DISPATCH at authoring time, so every assertion below is expected to fail on
# MISSING BEHAVIOUR (an "unknown subcommand 'create'" exit-3 refusal), never on a bug in this file.
#
# Convention mirrored from plugins/butler/tests/t/blueprint-write-api.t: bash -c wrapper with
# BWA_*-style env-passed paths (avoids quoting hazards on non-ASCII repo paths), :raw file IO
# throughout, no PreToolUse block COUNT ever asserted (not applicable here, but keeping the house
# rule visible).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use File::Basename ();
use Digest::MD5 qw(md5_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..")   // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-ledger.pl";
my $TEMPLATE = "$PROJ/plugins/blueprint/templates/package-ledger.md";

diag("subject under test: $SCRIPT create "
     . (-e $SCRIPT ? "(script present, verb expected ABSENT)" : "(script ABSENT)"));
diag("template fixture: $TEMPLATE " . (-e $TEMPLATE ? "(present)" : "(ABSENT -- AC-3/4/5/6 will skip)"));

my $EMDASH = "\xE2\x80\x94";
my @MODELS  = qw(sonnet opus haiku);
my @EFFORTS = qw(low medium high xhigh max);

my $ROOT = tempdir(CLEANUP => 1);
my $dn = 0;
sub fresh_dir { my $d = "$ROOT/w" . (++$dn); mkdir $d or die "mkdir $d: $!"; return $d }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

sub digest_of { md5_hex(read_file($_[0]) // '') }

my $pn = 0;
sub run_create {
    my ($args, %opt) = @_;
    my $n    = ++$pn;
    my $outf = "$ROOT/out.$n";
    my $errf = "$ROOT/err.$n";
    write_file($outf, '');
    write_file($errf, '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra,
                  BWA_SCRIPT => fwd($SCRIPT), BWA_OUT => fwd($outf), BWA_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BWA_SCRIPT" create "$@" > "$BWA_OUT" 2> "$BWA_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# base_args(%overrides) -> ($ledger_path, @argv). $ledger_path's parent dir does not exist yet
# unless the caller pre-creates it -- exercising `create`'s own make_path (B-1 requires the
# target's parent to spring into existence on success).
sub base_args {
    my (%o) = @_;
    my $dir = $o{dir} // fresh_dir();
    my $pkg = $o{package} // '04-demo-pkg';
    my $ledger = $o{ledger} // "$dir/packages/$pkg.md";
    my @args = (
        '--ledger', $ledger,
        '--package', $pkg,
        '--blueprint', $o{blueprint} // 'demo-blueprint',
        '--template', $o{template} // $TEMPLATE,
        '--write-set', $o{write_set} // 'plugins/foo/bar.pl',
    );
    push @args, '--test-paths', $o{test_paths} if defined $o{test_paths};
    push @args, '--checks',     $o{checks}     if defined $o{checks};
    push @args, '--model',      $o{model}      if defined $o{model};
    push @args, '--effort',     $o{effort}     if defined $o{effort};
    push @args, '--max-turns',  $o{max_turns}  if defined $o{max_turns};
    push @args, '--title',      $o{title}      if defined $o{title};
    return ($ledger, @args);
}

my @FM_KEYS = qw(package blueprint status model effort max_turns write_set test_paths checks last_updated);

sub frontmatter_block {
    my ($text) = @_;
    my ($fm) = $text =~ /\A---\r?\n(.*?)\r?\n---\r?\n/s;
    return $fm;
}

# =====================================================================================
# AC-1 (B-8, B-10, B-11): bad --model refuses, creates nothing, one stderr line.
# =====================================================================================
{
    my ($ledger, @args) = base_args(model => 'fable');
    my ($rc, $out, $err) = run_create(\@args);
    is($rc, 2, "AC-1/B-8: create --model fable exits 2");
    is($out, '', "AC-1/B-8: stdout empty on a bad --model");
    ok(!-e $ledger, "AC-1/B-8: no ledger file is created");
    my @errlines = grep { length } split /\r?\n/, $err;
    is(scalar(@errlines), 1, "AC-1/B-8: exactly one stderr line");
    like($err, qr/fable/, "AC-1/B-8: stderr names the offending value 'fable'");
    like($err, qr/sonnet, opus, haiku/, "AC-1/B-8: stderr names the full accepted model set");
}
{
    # B-10: even when the target's parent directory does not exist, nothing is created --
    # not even the directory.
    my $dir = fresh_dir();
    my ($ledger, @args) = base_args(dir => $dir, ledger => "$dir/deep/nested/packages/01-x.md",
                                     model => 'fable');
    my ($rc) = run_create(\@args);
    is($rc, 2, "B-10: bad --model with a missing parent dir still exits 2");
    ok(!-d "$dir/deep", "B-10: not even the parent directory is created");
}
{
    # B-11: checked before the template is even opened.
    my ($ledger, @args) = base_args(model => 'fable', template => "$ROOT/does-not-exist-tpl.md");
    my ($rc, $out, $err) = run_create(\@args);
    is($rc, 2, "B-11: bad --model with an unreadable --template still exits 2, not 4");
    like($err, qr/fable/, "B-11: ...and the message is still the model message");
}

# =====================================================================================
# AC-2 (B-9, B-10): bad --effort refuses, creates nothing, one stderr line.
# =====================================================================================
{
    my ($ledger, @args) = base_args(effort => 'turbo');
    my ($rc, $out, $err) = run_create(\@args);
    is($rc, 2, "AC-2/B-9: create --effort turbo exits 2");
    is($out, '', "AC-2/B-9: stdout empty");
    ok(!-e $ledger, "AC-2/B-9: no ledger file is created");
    like($err, qr/turbo/, "AC-2/B-9: stderr names the offending value 'turbo'");
    like($err, qr/low, medium, high, xhigh, max/, "AC-2/B-9: stderr names the full accepted effort set");
}
{
    my $dir = fresh_dir();
    my ($ledger, @args) = base_args(dir => $dir, ledger => "$dir/deep2/nested/packages/01-x.md",
                                     effort => 'turbo');
    my ($rc) = run_create(\@args);
    is($rc, 2, "B-10: bad --effort with a missing parent dir still exits 2");
    ok(!-d "$dir/deep2", "B-10: not even the parent directory is created");
}

# =====================================================================================
# AC-3 (B-1): every supported model and every supported effort is individually accepted
# (8 invocations total: 3 varying --model at default effort, 5 varying --effort at default
# model), each exits 0, empty stdout/stderr, target exists.
# =====================================================================================
my @produced; # collect (path, %opts) for AC-4/5/6 reuse
SKIP: {
    skip('AC-3: template fixture missing', 8 * 4) unless -e $TEMPLATE;
    for my $m (@MODELS) {
        my ($ledger, @args) = base_args(package => "04-model-$m", model => $m);
        my ($rc, $out, $err) = run_create(\@args);
        is($rc, 0, "AC-3/B-1: --model $m exits 0");
        is($out, '', "AC-3/B-1: --model $m stdout empty");
        is($err, '', "AC-3/B-1: --model $m stderr empty");
        ok(-f $ledger, "AC-3/B-1: --model $m target file exists");
        push @produced, [$ledger, { model => $m, effort => 'medium', package => "04-model-$m" }];
    }
    for my $e (@EFFORTS) {
        my ($ledger, @args) = base_args(package => "04-effort-$e", effort => $e);
        my ($rc, $out, $err) = run_create(\@args);
        is($rc, 0, "AC-3/B-1: --effort $e exits 0");
        is($out, '', "AC-3/B-1: --effort $e stdout empty");
        is($err, '', "AC-3/B-1: --effort $e stderr empty");
        ok(-f $ledger, "AC-3/B-1: --effort $e target file exists");
        push @produced, [$ledger, { model => 'sonnet', effort => $e, package => "04-effort-$e" }];
    }
}

# =====================================================================================
# AC-4 (B-2): every file produced by AC-3 passes `bp-ledger.pl validate`.
# =====================================================================================
SKIP: {
    skip('AC-4: no files produced by AC-3', 2) unless @produced;
    for my $p (@produced) {
        my ($ledger) = @$p;
        my $n = ++$pn;
        my $outf = "$ROOT/vout.$n"; my $errf = "$ROOT/verr.$n";
        write_file($outf, ''); write_file($errf, '');
        local %ENV = (%CLEAN_ENV, BWA_SCRIPT => fwd($SCRIPT), BWA_LEDGER => fwd($ledger),
                      BWA_OUT => fwd($outf), BWA_ERR => fwd($errf));
        my $rc = system('bash', '-c',
            'timeout 30 perl "$BWA_SCRIPT" validate --ledger "$BWA_LEDGER" > "$BWA_OUT" 2> "$BWA_ERR"');
        is($rc >> 8, 0, "AC-4/B-2: validate --ledger $ledger exits 0");
        is(read_file($errf), '', "AC-4/B-2: validate stderr empty for $ledger");
    }
}

# =====================================================================================
# AC-5 (B-3, B-4, B-5): frontmatter keys are exactly the ten, in template order,
# comment-free, with the expected values -- both explicit values and all-defaults.
# =====================================================================================
SKIP: {
    skip('AC-5: template fixture missing', 20) unless -e $TEMPLATE;
    my ($ledger, @args) = base_args(package => '04-explicit', blueprint => 'my-bp',
        model => 'opus', effort => 'high', max_turns => 950,
        write_set => 'a.pl:b.pl', test_paths => 't/a.t', checks => 'perl-compile');
    my ($rc) = run_create(\@args);
    is($rc, 0, "AC-5/B-3/B-4: explicit-values create exits 0") or skip('create failed', 19);
    my $text = read_file($ledger);
    my $fm = frontmatter_block($text);
    ok(defined $fm, "AC-5/B-3: a \\A---anchored frontmatter block exists");
    my @lines = grep { length } split /\r?\n/, $fm // '';
    my @found_keys = map { /^(\w+):/ ? $1 : () } @lines;
    is_deeply(\@found_keys, \@FM_KEYS, "AC-5/B-3: keys appear exactly in template order");
    ok(!(grep { /^\s*#/ } @lines), "AC-5/B-3: no #-prefixed comment line survives in frontmatter");
    like($fm, qr/^package:\s*04-explicit\s*$/m, "AC-5/B-4: package carries --package");
    like($fm, qr/^blueprint:\s*my-bp\s*$/m, "AC-5/B-4: blueprint carries --blueprint");
    like($fm, qr/^status:\s*pending\s*$/m, "AC-5/B-4: status is the literal 'pending'");
    like($fm, qr/^model:\s*opus\s*$/m, "AC-5/B-4: model carries --model");
    like($fm, qr/^effort:\s*high\s*$/m, "AC-5/B-4: effort carries --effort");
    like($fm, qr/^max_turns:\s*950\s*$/m, "AC-5/B-4: max_turns carries --max-turns");
    like($fm, qr/^write_set:\s*a\.pl:b\.pl\s*$/m, "AC-5/B-4: write_set carries --write-set");
    like($fm, qr/^test_paths:\s*t\/a\.t\s*$/m, "AC-5/B-4: test_paths carries --test-paths");
    like($fm, qr/^checks:\s*perl-compile\s*$/m, "AC-5/B-4: checks carries --checks");
    like($fm, qr/^last_updated:\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\s*$/m,
         "AC-5/B-4: last_updated is an ISO-8601 UTC timestamp shape");

    my ($ledger2, @args2) = base_args(package => '04-defaults');
    my ($rc2) = run_create(\@args2);
    is($rc2, 0, "AC-5/B-5: all-defaults create exits 0") or skip('create failed', 8);
    my $fm2 = frontmatter_block(read_file($ledger2));
    like($fm2, qr/^model:\s*sonnet\s*$/m, "AC-5/B-5: default model is sonnet");
    like($fm2, qr/^effort:\s*medium\s*$/m, "AC-5/B-5: default effort is medium");
    like($fm2, qr/^max_turns:\s*800\s*$/m, "AC-5/B-5: default max_turns is 800");
    like($fm2, qr/^test_paths:\s*$/m, "AC-5/B-5: default test_paths is empty");
    like($fm2, qr/^checks:\s*$/m, "AC-5/B-5: default checks is empty");

    my $n = ++$pn;
    my $outf = "$ROOT/vout2.$n"; my $errf = "$ROOT/verr2.$n";
    write_file($outf, ''); write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BWA_SCRIPT => fwd($SCRIPT), BWA_LEDGER => fwd($ledger2),
                  BWA_OUT => fwd($outf), BWA_ERR => fwd($errf));
    my $rc3 = system('bash', '-c',
        'timeout 30 perl "$BWA_SCRIPT" validate --ledger "$BWA_LEDGER" > "$BWA_OUT" 2> "$BWA_ERR"');
    is($rc3 >> 8, 0, "AC-5/B-5: the all-defaults ledger still satisfies B-2 (validate exits 0)");
}

# =====================================================================================
# AC-6 (B-6, B-7): the # Package title line and the body's section headings.
# =====================================================================================
SKIP: {
    skip('AC-6: template fixture missing', 6) unless -e $TEMPLATE;
    my ($ledger, @args) = base_args(package => '04-titled', title => 'a real title');
    my ($rc) = run_create(\@args);
    is($rc, 0, "AC-6/B-6: create with --title exits 0") or skip('create failed', 5);
    my $text = read_file($ledger);
    like($text, qr/^# Package 04-titled \Q$EMDASH\E a real title\s*$/m,
         "AC-6/B-6: title line uses --title verbatim with the U+2014 em dash");
    for my $h ('## Next action', '## Decisions & attempt log', '## Pipeline', '## Outputs', '## Escalation') {
        # \b, not \s*$: mirrors validate_bytes()'s own V5 regex (qr/^##\s+Escalation\b/m),
        # since the real template's Escalation heading carries a parenthetical suffix
        # ("## Escalation (when status: blocked)") that an exact-line match would wrongly reject.
        like($text, qr/^\Q$h\E\b/m, "AC-6/B-7: body retains required section heading '$h'");
    }

    my ($ledger2, @args2) = base_args(package => '04-notitle');
    my ($rc2) = run_create(\@args2);
    is($rc2, 0, "AC-6/B-6: create without --title exits 0") or skip('create failed', 1);
    my $text2 = read_file($ledger2);
    like($text2, qr/^# Package 04-notitle \Q$EMDASH\E 04-notitle\s*$/m,
         "AC-6/B-6: --title defaults to the --package value");
}

# =====================================================================================
# AC-7 (B-12, B-18, B-19): atomicity -- pre-existing target refused (byte-identical),
# BP_LEDGER_FAIL_RENAME -> exit 4 with no target, and no .tmp.* residue after any failure.
# =====================================================================================
SKIP: {
    skip('AC-7: template fixture missing', 6) unless -e $TEMPLATE;
    my ($ledger, @args) = base_args(package => '04-exists');
    my ($rc0) = run_create(\@args);
    is($rc0, 0, "AC-7/B-12: first create against a fresh target exits 0") or skip('setup failed', 5);
    my $before = digest_of($ledger);
    my ($rc, $out, $err) = run_create(\@args);
    is($rc, 2, "AC-7/B-12: a second create against the same --ledger exits 2 (refuses to overwrite)");
    like($err, qr/overwrite|exist/i, "AC-7/B-12: stderr says it refuses to overwrite");
    is(digest_of($ledger), $before, "AC-7/B-12: the existing file is byte-identical afterwards");

    my ($dir) = fresh_dir();
    my ($ledger2, @args2) = base_args(dir => $dir, package => '04-fail-rename');
    my ($rc2) = run_create(\@args2, env => { BP_LEDGER_FAIL_RENAME => '1' });
    is($rc2, 4, "AC-7/B-18: BP_LEDGER_FAIL_RENAME=1 exits 4");
    ok(!-e $ledger2, "AC-7/B-18: the target file does not exist after a forced rename failure");

    my $scan_dir = -d "$dir/packages" ? "$dir/packages" : $dir;
    opendir(my $dh, $scan_dir);
    my @tmp = $dh ? grep { /\.tmp\.\d+/ } readdir($dh) : ();
    closedir $dh if $dh;
    is(scalar(@tmp), 0, "AC-7/B-19: no <ledger>.tmp.* residue after a rename failure");
}

# =====================================================================================
# AC-8 (B-13, B-14, B-15, B-16, B-20): usage surface.
# =====================================================================================
{
    # B-13: missing required options exit 3 with one bp-ledger: create: ... line.
    for my $missing (qw(--ledger --package --blueprint --template --write-set)) {
        my ($ledger, @args) = base_args();
        my @filtered;
        my $skip_next = 0;
        for my $a (@args) {
            if ($skip_next) { $skip_next = 0; next }
            if ($a eq $missing) { $skip_next = 1; next }
            push @filtered, $a;
        }
        my ($rc, $out, $err) = run_create(\@filtered);
        is($rc, 3, "B-13: create without $missing exits 3");
        like($err, qr/^bp-ledger: create:/, "B-13: stderr line for missing $missing follows the frame");
    }
    # B-13: unknown option, trailing positional args.
    {
        my (undef, @args) = base_args();
        my ($rc) = run_create([@args, '--bogus-option', 'x']);
        is($rc, 3, "B-13: an unknown option exits 3");
    }
    {
        my (undef, @args) = base_args();
        my ($rc) = run_create([@args, 'trailing-positional']);
        is($rc, 3, "B-13: trailing positional arguments exit 3");
    }
}
{
    # B-14: field_safe violations (pipe / CR / LF) exit 3 and write nothing.
    my @cases = (
        [ package  => "04-bad|pkg" ],
        [ blueprint => "bad\nbp" ],
        [ write_set => "a.pl\rb.pl" ],
        [ title => "a|title" ],
        [ test_paths => "t/a\nt/b" ],
        [ checks => "perl|compile" ],
    );
    for my $c (@cases) {
        my ($field, $val) = @$c;
        my ($ledger, @args) = base_args($field => $val);
        my ($rc) = run_create(\@args);
        is($rc, 3, "B-14: --$field containing a pipe/CR/LF exits 3");
        ok(!-e $ledger, "B-14: ...and nothing is written for --$field");
    }
}
{
    # B-15: malformed --package / --blueprint / --max-turns.
    for my $pkg ('4-foo', 'Foo-Bar') {
        my ($ledger, @args) = base_args(package => $pkg);
        my ($rc) = run_create(\@args);
        is($rc, 3, "B-15: --package '$pkg' exits 3");
    }
    {
        my ($ledger, @args) = base_args(blueprint => 'Not_Kebab');
        my ($rc) = run_create(\@args);
        is($rc, 3, "B-15: --blueprint 'Not_Kebab' exits 3");
    }
    for my $mt (0, 'abc') {
        my ($ledger, @args) = base_args(max_turns => $mt);
        my ($rc) = run_create(\@args);
        is($rc, 3, "B-15: --max-turns '$mt' exits 3");
    }
}
{
    # B-16: unreadable template exits 4; a readable template missing a frontmatter key exits 2.
    my ($ledger, @args) = base_args(template => "$ROOT/no-such-template-file.md");
    my ($rc) = run_create(\@args);
    is($rc, 4, "B-16: an unreadable --template exits 4");
    ok(!-e $ledger, "B-16: ...and nothing is written");

    my $bad_tpl = "$ROOT/bad-template.md";
    write_file($bad_tpl, join("\n",
        '---',
        'package: <NN-slug>',
        'blueprint: <blueprint-name>',
        'status: pending',
        'model: sonnet',
        'effort: medium',
        'max_turns: 800',
        'write_set: <colon-separated>',
        'test_paths: <colon-separated>',
        # 'checks:' key deliberately OMITTED
        'last_updated: <timestamp>',
        '---',
        '# Package <NN-slug> — <title>',
        '',
        '## Next action',
        '## Decisions & attempt log',
        '## Pipeline',
        '## Outputs',
        '## Escalation',
        '',
    ));
    my ($ledger2, @args2) = base_args(template => $bad_tpl);
    my ($rc2, $out2, $err2) = run_create(\@args2);
    is($rc2, 2, "B-16: a template missing a required frontmatter key exits 2");
    like($err2, qr/checks/, "B-16: stderr names the missing key 'checks'");
    ok(!-e $ledger2, "B-16: ...and nothing is written");
}
{
    # B-20: `create` is listed among the expected subcommands in the no-subcommand usage line.
    my $n = ++$pn;
    my $outf = "$ROOT/usage-out.$n"; my $errf = "$ROOT/usage-err.$n";
    write_file($outf, ''); write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BWA_SCRIPT => fwd($SCRIPT), BWA_OUT => fwd($outf), BWA_ERR => fwd($errf));
    my $rc = system('bash', '-c', 'timeout 30 perl "$BWA_SCRIPT" > "$BWA_OUT" 2> "$BWA_ERR"');
    isnt($rc >> 8, 0, "B-20: bp-ledger.pl with no subcommand exits non-zero");
    like(read_file($errf), qr/\bcreate\b/, "B-20: ...and the usage line lists 'create' among the subcommands");
}

# =====================================================================================
# AC-9 (B-17): create cannot emit a ledger its own validator would reject -- a
# V4b-violating --write-set (whitespace-bearing segment) exits 2, creates nothing.
# =====================================================================================
{
    my ($ledger, @args) = base_args(write_set => 'a/b.pl:c d.t');
    my ($rc, $out, $err) = run_create(\@args);
    is($rc, 2, "AC-9/B-17: a whitespace-bearing write_set segment exits 2");
    ok(!-e $ledger, "AC-9/B-17: ...and creates no file");
}

done_testing();
