#!/usr/bin/env perl
# platform: any
# Oracle for the array-indexing extension to lib.sh's dotted-path scalar
# lookup (contract at lib.sh:100, both branches at lib.sh:118): a
# digit-shaped path segment must resolve as a zero-based array index into
# the CURRENT node, in both the jq branch and the perl+JSON::PP fallback,
# agreeing byte-for-byte wherever both run. Out-of-range and type-mismatched
# indices must degrade to "nothing" exactly like a missing object key
# (stdout: zero bytes, exit 0) -- never an error, never a false match.
#
# A SECOND, independent claim is pinned here too: every path shape already
# in use across the current hook surface (no digit segment anywhere) must
# keep compiling to the EXACT SAME jq expression string it does today --
# byte-identical, not merely equivalent -- because two existing tests stand
# in a hand-written jq shim that splits naively on "//" and chokes on
# anything else. See the ARGV-CAPTURE block below.
#
# WRITTEN BLIND to how the fix is implemented; the case table and the
# expected-expression strings are both taken from the SPEC's stated grammar
# and from lib.sh's PRE-FIX source (its jq/perl split, cited above), which
# is what "byte-identical to today" has to mean.
#
# BP_JSON_GET_FORCE (unset | perl | jq) is a TEST-ONLY selector this package
# adds so the jq and perl branches can be driven deterministically without a
# second real jq binary. jq itself is absent on this host (confirmed via
# `command -v jq` below) -- every jq-branch assertion is wrapped in a SKIP
# block, the same convention guard-bash-quote-strip.t already uses for its
# own $HAVE_REAL_JQ gate.
#
# Companion file: read-payload-idempotent.t (the other half of this
# package's two defects).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $LIB = "$HOOKS/lib.sh";

ok(-f $LIB, 'lib.sh exists at plugins/butler/hooks/lib.sh') or BAIL_OUT('lib.sh missing');

my $BASH = 'bash';
my $have_bash = do {
    my $out = `$BASH -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

my $HAVE_JQ = do {
    my $out = `command -v jq 2>/dev/null`;
    (defined $out && $out =~ /\S/) ? 1 : 0;
};

my $ROOT = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# The runner. A tiny bash script, not an inline -c string: keys are passed as
# plain argv (list-form open, no shell involved), so a key containing a dot
# or a digit needs no quoting gymnastics, and Windows/non-ASCII paths in
# $HOOKS are never interpolated into a shell string at all.
# ---------------------------------------------------------------------------
my $RUNNER = "$ROOT/run-json-get.sh";
open my $rf, '>', $RUNNER or die "cannot write $RUNNER: $!";
print {$rf} <<'RUNNER';
#!/usr/bin/env bash
set -u
HOOK_DIR="$1"; shift
PAYLOAD_FILE="$1"; shift
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 9
PAYLOAD=$(cat "$PAYLOAD_FILE")
bp_json_get "$PAYLOAD" "$@"
exit $?
RUNNER
close $rf;
chmod 0755, $RUNNER;

my $pn = 0;

# bp_json_get_raw(payload_json, \@keys, %opts) -> ($rc, $stdout)
# %opts: force => 'perl'|'jq' (sets BP_JSON_GET_FORCE), path_prefix => dir
# (prepended to PATH, for the argv-capture shim below).
sub bp_json_get_raw {
    my ($payload, $keys, %opt) = @_;
    my $n = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die "cannot write $pf: $!";
    binmode $w, ':utf8';
    print {$w} $payload;
    close $w;

    local %ENV = %ENV;
    delete $ENV{BP_JSON_GET_FORCE};
    $ENV{BP_JSON_GET_FORCE} = $opt{force} if defined $opt{force};
    if (defined $opt{path_prefix}) {
        $ENV{PATH} = "$opt{path_prefix}:" . ($ENV{PATH} // '');
    }
    if (defined $opt{extra_env}) {
        $ENV{$_} = $opt{extra_env}{$_} for keys %{ $opt{extra_env} };
    }

    open(my $fh, '-|', $BASH, $RUNNER, $HOOKS, $pf, @$keys) or die "bash: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    return ($rc, defined $out ? $out : '');
}

# ===========================================================================
# The shared differential case table (spec S2.2). Each row: (id, ac, desc,
# payload_json, \@keys, expected_or_undef). expected_or_undef is undef for
# "yields nothing" (S2.3: zero stdout bytes, exit 0) and a string otherwise.
# ===========================================================================
my @CASES = (
    # -- AC-1 (DC1, DC7): plain scalar paths, no digit segment anywhere --
    # regression baseline: today's shapes must resolve exactly as before.
    [ 'S1', 'AC-1', 'plain scalar: tool_input.command',
      '{"tool_input":{"command":"git status"}}',
      ['tool_input.command'], 'git status' ],
    [ 'S2', 'AC-1', 'plain scalar: cwd',
      '{"cwd":"/tmp/x"}',
      ['cwd'], '/tmp/x' ],
    [ 'S3', 'AC-1', 'fallback across two non-digit candidates: file_path missing, notebook_path present',
      '{"tool_input":{"notebook_path":"/a/b.ipynb"}}',
      ['tool_input.file_path', 'tool_input.notebook_path'], '/a/b.ipynb' ],
    [ 'S4', 'AC-1', 'missing key -> nothing (unchanged missing-key contract)',
      '{"tool_input":{}}',
      ['tool_input.command'], undef ],

    # -- AC-2 (DC1): array-of-scalars, including the leading-zero edge case --
    [ 'S5', 'AC-2', 'array of scalars: a.1 -> "y"',
      '{"a":["x","y","z"]}',
      ['a.1'], 'y' ],
    [ 'S6', 'AC-2', 'leading-zero segment "007" is decimal index 7, not a literal string key',
      '{"a":["v0","v1","v2","v3","v4","v5","v6","v7","v8"]}',
      ['a.007'], 'v7' ],
    [ 'S7', 'AC-2', 'array element resolving to an OBJECT (not a scalar) -> nothing, matches the scalar-only contract',
      '{"a":[{"x":1},"y"]}',
      ['a.0'], undef ],

    # -- AC-3 (DC1): the real AskUserQuestion payload shape --
    [ 'S8', 'AC-3', 'AskUserQuestion shape: tool_input.questions.2.question -> "C"',
      '{"tool_input":{"questions":[{"question":"A"},{"question":"B"},{"question":"C"},{"question":"D"}]}}',
      ['tool_input.questions.2.question'], 'C' ],

    # -- AC-4 (DC2): out-of-range index on the same 4-element array --
    [ 'S9', 'AC-4', 'out-of-range index (5) on a 4-element array -> nothing, not an error',
      '{"tool_input":{"questions":[{"question":"A"},{"question":"B"},{"question":"C"},{"question":"D"}]}}',
      ['tool_input.questions.5.question'], undef ],

    # -- AC-5 (DC2): current node is an OBJECT, not an array --
    [ 'S10', 'AC-5', 'questions is an OBJECT with a digit-spelled key "0" -> the segment is NEVER reinterpreted as an object key',
      '{"tool_input":{"questions":{"0":{"question":"nope"}}}}',
      ['tool_input.questions.0.question'], undef ],

    # -- AC-6 (DC1, DC2): a hyphenated/negative-looking segment --
    [ 'S11', 'AC-6', 'segment "-1" does not match ^[0-9]+$, so it is a literal-key attempt against an array -> nothing',
      '{"a":["x","y","z"]}',
      ['a.-1'], undef ],

    # -- extra grammar edge cases from spec SS5, folded into the nearest AC --
    [ 'S12', 'AC-4/AC-6 edge', 'digit segment where the current node is a scalar (not array/object) -> nothing, never coerced',
      '{"a":"just a string"}',
      ['a.0'], undef ],
    [ 'S13', 'AC-4/AC-6 edge', 'digit segment where the current node is null -> nothing',
      '{"a":null}',
      ['a.0'], undef ],
    [ 'S14', 'AC-2/AC-3 combined', 'multi-candidate KEY set: first candidate has a digit segment out of range, second candidate (no digit) still wins',
      '{"tool_input":{"questions":[{"question":"A"}]},"fallback":"used-the-second-candidate"}',
      ['tool_input.questions.9.question', 'fallback'], 'used-the-second-candidate' ],

    # -- fix-batch FIX 2: an overflowing digit-index segment must yield
    # nothing, not wrap around to the array's LAST element. A huge digit
    # string overflows to a negative integer in some interpreters; a negative
    # index means "from the end" there -- out-of-range must still yield
    # nothing, same as any other out-of-range index (AC-4).
    [ 'S15', 'AC-4 huge-index', 'digit segment index overflows the interpreter integer range -- must yield nothing, never wrap to the last element',
      '{"a":["x","y","z"]}',
      ['a.99999999999999999999'], undef ],
);

for my $c (@CASES) {
    my ($id, $ac, $desc, $payload, $keys, $expected) = @$c;

    # -- perl branch: always runs (perl+JSON::PP is guaranteed present) --
    my ($rc, $out) = bp_json_get_raw($payload, $keys, force => 'perl');
    if (defined $expected) {
        is($rc, 0, "$id ($ac, perl branch): $desc -- exit 0");
        is($out, $expected, "$id ($ac, perl branch): $desc -- value \"$expected\"");
    } else {
        is($rc, 0, "$id ($ac, perl branch): $desc -- exit 0 (nothing found is success, not failure)");
        is($out, '', "$id ($ac, perl branch): $desc -- zero stdout bytes");
    }

    # -- jq branch: only meaningful with a real jq; SKIP is honest elsewhere --
  SKIP: {
        skip "jq is not installed on this host -- differential jq-branch run for $id not exercised", 3
            unless $HAVE_JQ;
        my ($rcj, $outj) = bp_json_get_raw($payload, $keys, force => 'jq');
        if (defined $expected) {
            is($rcj, 0, "$id ($ac, jq branch): $desc -- exit 0");
            is($outj, $expected, "$id ($ac, jq branch): $desc -- value \"$expected\"");
        } else {
            is($rcj, 0, "$id ($ac, jq branch): $desc -- exit 0");
            is($outj, '', "$id ($ac, jq branch): $desc -- zero stdout bytes");
        }
        is($outj, $out, "$id: the jq branch and the perl branch agree byte-for-byte");
    }
}

# ===========================================================================
# Mechanism sanity (spec SS2.1, the BP_JSON_GET_FORCE contract itself) --
# not independently numbered as one of AC-1..AC-7, but load-bearing for
# trusting every SKIP gate above: forcing the jq branch on a host that
# genuinely has no jq must return 2 immediately and print nothing, the SAME
# signal as "no parser available" -- never a silent fallback to perl.
# ===========================================================================
unless ($HAVE_JQ) {
    my ($rc, $out) = bp_json_get_raw('{"a":"b"}', ['a'], force => 'jq');
    is($rc, 2, 'MECHANISM: BP_JSON_GET_FORCE=jq on a host with no real jq -> exit 2 (the no-parser signal)');
    is($out, '', 'MECHANISM: ...and prints nothing, never a silent fallback to perl');
}

# ===========================================================================
# AC-7 (DC7) -- the jq-branch compiler emits a BYTE-IDENTICAL expression
# string for every existing (non-digit-segment) call shape, exactly as
# today's raw `expr="$expr.$k"` concatenation produces:
#     join(" // ", map ".$_", @keys) . " // empty"
# with NO wrapping parens (lib.sh:132's own documented constraint) -- two
# existing tests (guard-writes-specificity.t, guard-bash-quote-strip.t)
# stand in a hand-written jq shim that would choke on anything else.
#
# Proven WITHOUT editing lib.sh: an argv-capturing "jq" stand-in is put
# first on PATH. bp_json_get already prefers jq when `command -v jq`
# succeeds (unconditionally, today; unset-BP_JSON_GET_FORCE default,
# post-fix) -- the shim never has to run a real query, only record the
# exact argv it was handed and exit cleanly, giving direct visibility into
# the compiled expression string without a debug hook in lib.sh itself.
# ===========================================================================
{
    my $shim_dir = "$ROOT/argv-capture-shim";
    mkdir $shim_dir or die "mkdir $shim_dir: $!";
    open my $s, '>', "$shim_dir/jq" or die "write shim jq: $!";
    print {$s} <<'SHIM';
#!/usr/bin/env perl
# argv-capture stand-in for "jq", t/json-get-array-index only. Records the
# raw argv it received (joined on \x1e, one call per line) to the file named
# by BP_JQ_ARGV_CAPTURE, then behaves harmlessly: prints nothing, exit 0 --
# matching jq's own "-r 'EXPR // empty'" contract for a query with no match.
my $out = $ENV{BP_JQ_ARGV_CAPTURE};
if (defined $out) {
    open my $fh, '>>', $out or exit 1;
    print {$fh} join("\x1e", @ARGV), "\n";
    close $fh;
}
exit 0;
SHIM
    close $s;
    chmod 0755, "$shim_dir/jq";

    my $capture = "$ROOT/argv-capture.log";

    # The 19-caller regression surface (spec SS7), every shape enumerated
    # there that has NO all-digit segment. Two-key rows mirror the real
    # `tool_input.file_path // tool_input.notebook_path` fallback shape.
    my @SHAPES = (
        [ 'tool_input.command' ],
        [ 'cwd' ],
        [ 'tool_name' ],
        [ 'session_id' ],
        [ 'tool_input.file_path', 'tool_input.notebook_path' ],
        [ 'tool_input.subagent_type' ],
        [ 'tool_input.description' ],
        [ 'tool_input.prompt' ],
        [ 'tool_response.stdout' ],
        [ 'tool_response' ],
        [ 'hook_event_name' ],
    );

    for my $keys (@SHAPES) {
        unlink $capture;
        bp_json_get_raw('{"x":1}', $keys,
            path_prefix => $shim_dir,
            extra_env   => { BP_JQ_ARGV_CAPTURE => $capture });

        my $label = join(',', @$keys);
        open my $r, '<', $capture or do {
            fail("AC-7: argv captured for [$label] (capture file missing -- jq shim never ran)");
            next;
        };
        my $line = <$r>;
        close $r;
        chomp $line if defined $line;

        my @argv = defined $line ? split /\x1e/, $line, -1 : ();
        my $expected_expr = join(' // ', map { ".$_" } @$keys) . ' // empty';

        is(scalar(@argv), 2, "AC-7 [$label]: jq invoked with exactly 2 argv elements (-r, EXPR)");
        is($argv[0], '-r', "AC-7 [$label]: first argv element is -r") if @argv >= 1;
        is($argv[1], $expected_expr,
            "AC-7 [$label]: compiled expression is byte-identical to today's dot-concatenation, no digit segment present")
            if @argv >= 2;
    }
}

done_testing();
