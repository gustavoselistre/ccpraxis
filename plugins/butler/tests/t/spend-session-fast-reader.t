#!/usr/bin/env perl
# platform: any
# derive-session's lazy line reader (BpSpend::Derive::_session_thin_record)
# must give, for every field derive_session reads, exactly what a full
# JSON::PP decode gives -- or decline (undef) so the caller falls back to
# JSON::PP. Exactness is the whole contract: the reader exists only because
# JSON::PP is ~1 MB/s and a day's session is ~130 MB.
#
# Each case is a crafted line. For each one this asserts:
#   * if the fast reader returns a record, JSON::PP accepts the line and the
#     record equals JSON::PP's decode projected onto the read fields;
#   * lines JSON::PP rejects are never accepted by the fast reader;
#   * the ordinary shapes really take the fast path (non-vacuity: a reader
#     that always declined would pass every other assertion).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# spend-token-report Decision 16: never let this test reach a live fetch.
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(eval { require $SPEND_PL; 1 }, 'bp-spend.pl loads as a module') or BAIL_OUT("require: $@");

my $FULL = JSON::PP->new->utf8;
my $CANON = JSON::PP->new->canonical->allow_nonref;

# The fields derive_session reads, projected from a full decode.
sub project {
    my ($r) = @_;
    my %o;
    exists $r->{$_} and $o{$_} = $r->{$_} for qw(type timestamp requestId effort uuid session_id);
    return \%o unless exists $r->{message};
    my $m = $r->{message};
    if (ref $m ne 'HASH') { $o{message} = $m; return \%o }
    my %mm;
    exists $m->{$_} and $mm{$_} = $m->{$_} for qw(model id);
    if (exists $m->{usage}) {
        my $u = $m->{usage};
        if (ref $u eq 'HASH') {
            my %uu;
            exists $u->{$_} and $uu{$_} = $u->{$_}
                for qw(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens speed);
            if (exists $u->{cache_creation}) {
                my $c = $u->{cache_creation};
                if (ref $c eq 'HASH') {
                    my %cc;
                    exists $c->{$_} and $cc{$_} = $c->{$_} for qw(ephemeral_5m_input_tokens ephemeral_1h_input_tokens);
                    $uu{cache_creation} = \%cc;
                }
                else { $uu{cache_creation} = $c }
            }
            if (exists $u->{iterations}) {
                my $i = $u->{iterations};
                $uu{iterations} = ref($i) eq 'ARRAY' ? [ (undef) x @$i ] : $i;
            }
            $mm{usage} = \%uu;
        }
        else { $mm{usage} = $u }
    }
    $o{message} = \%mm;
    return \%o;
}

my $base = '{"type":"assistant","uuid":"u1","requestId":"req_1","timestamp":"2026-09-23T10:00:00.123Z",'
         . '"effort":"medium","session_id":"s1","message":{"model":"claude-sonnet-5","id":"msg_1",'
         . '"content":[{"type":"text","text":"hello \"quoted\" \\\\ back\\nslash"}],'
         . '"usage":{"input_tokens":5,"output_tokens":379,"cache_read_input_tokens":1000,'
         . '"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":150,'
         . '"ephemeral_1h_input_tokens":50},"speed":"standard","iterations":[{"input_tokens":5}]}}}';

sub usage_line { my ($u) = @_; (my $l = $base) =~ s/"usage":\{.*\}\}\}\z/"usage":$u}}/; $l }

# [ label, line, must-take-fast-path ]
my @CASES = (
    [ 'ordinary assistant record', $base, 1 ],
    [ 'user record with a huge tool result',
      '{"type":"user","timestamp":"2026-09-23T10:00:01Z","message":{"role":"user","content":"' . ('x' x 200_000) . '"},"toolUseResult":{"stdout":"' . ('y\\n' x 5000) . '"}}', 1 ],
    [ 'whitespace between every token', " { \"type\" : \"assistant\" ,\t\"message\" : { \"usage\" : { \"input_tokens\" : 7 } } } ", 1 ],
    [ 'empty object', '{}', 1 ],
    [ 'duplicate top-level key: last wins', '{"type":"user","type":"assistant","message":{"usage":{"input_tokens":1}}}', 1 ],
    [ 'duplicate usage key: last wins', usage_line('{"input_tokens":1,"input_tokens":9}'), 1 ],
    [ 'duplicate message: last wins', '{"type":"assistant","message":{"model":"a"},"message":{"model":"b","usage":{}}}', 1 ],
    [ '15-digit integer', usage_line('{"input_tokens":123456789012345}'), 1 ],
    [ '16-digit integer', usage_line('{"input_tokens":1234567890123456}'), 1 ],
    [ '20-digit integer decodes to an NV', usage_line('{"input_tokens":12345678901234567890}'), 1 ],
    [ '25-digit integer stays its digit string', usage_line('{"input_tokens":1234567890123456789012345}'), 1 ],
    [ '400-digit integer', usage_line('{"input_tokens":' . ('9' x 400) . '}'), 1 ],
    [ 'negative, float, exponent, -0', usage_line('{"input_tokens":-5,"output_tokens":12.0,"cache_read_input_tokens":1e3,"cache_creation_input_tokens":-0}'), 1 ],
    [ 'numeric string', usage_line('{"input_tokens":"123"}'), 1 ],
    [ 'booleans and null', usage_line('{"input_tokens":true,"output_tokens":false,"cache_read_input_tokens":null,"speed":null}'), 1 ],
    [ 'object/array-valued scalars', usage_line('{"speed":{"a":1},"input_tokens":[1]}') =~ s/"uuid":"u1"/"uuid":{"x":1}/r, 1 ],
    [ 'iterations: [], [1,2,3], string, object', usage_line('{"iterations":[1,[2,3],{"a":[4]}]}'), 1 ],
    [ 'iterations empty', usage_line('{"iterations":[]}'), 1 ],
    [ 'iterations not an array', usage_line('{"iterations":"x"}'), 1 ],
    [ 'cache_creation not an object', usage_line('{"cache_creation":[1,2]}'), 1 ],
    [ 'usage not an object', '{"type":"assistant","message":{"usage":[1,2]}}', 1 ],
    [ 'message not an object', '{"type":"assistant","message":"hi"}', 1 ],
    [ 'escapes in a read field', '{"type":"assistant","effort":"hi\\u00e9\\t\\/x","message":{"model":"m\\"q"}}', 1 ],
    [ 'raw UTF-8 in a read field', qq({"type":"assistant","message":{"model":"cl\xc3\xa5ude"}}), 1 ],
    [ 'surrogate pair escape', '{"type":"assistant","effort":"\\ud83d\\ude00"}', 0 ],
    # Lines JSON::PP rejects.
    [ 'not json', '{not json', 0 ],
    [ 'trailing comma', '{"a":1,}', 0 ],
    [ 'leading zero', '{"a":01}', 0 ],
    [ 'invalid escape', '{"a":"x\\q"}', 0 ],
    [ 'raw control char in string', qq({"a":"x\x01y"}), 0 ],
    [ 'trailing garbage', '{} x', 0 ],
    [ 'unterminated string', '{"a":"x', 0 ],
    [ 'top-level array', '[1,2]', 0 ],
    [ 'top-level string', '"x"', 0 ],
    [ 'lone high surrogate', '{"a":"\\ud800"}', 0 ],
    [ 'invalid UTF-8', qq({"a":"\xff\xfe"}), 0 ],
    [ 'nesting deeper than 512', '{"a":' . ('[' x 600) . (']' x 600) . '}', 0 ],
    [ '600 brackets inside a string are not nesting', '{"type":"x","a":"' . ('[' x 600) . '"}', 1 ],
);

for my $c (@CASES) {
    my ($label, $line, $must_fast) = @$c;
    my $thin = BpSpend::Derive::_session_thin_record($line);
    my $full = eval { $FULL->decode($line) };
    $full = undef unless ref($full) eq 'HASH';
    if (defined $thin) {
        ok(defined $full, "$label: fast path only accepts what JSON::PP accepts");
        is($CANON->encode($thin), $CANON->encode(project($full // {})), "$label: same fields as JSON::PP")
            if defined $full;
    }
    else {
        pass("$label: declined, JSON::PP decides");
    }
    ok(defined $thin, "$label: takes the fast path") if $must_fast;
}

subtest 'derive_session still counts what JSON::PP rejects' => sub {
    my $dir = tempdir(CLEANUP => 1);
    open my $w, '>:raw', "$dir/s.jsonl" or die;
    print $w "$base\n{not json\n", qq({"a":"x\x01y"}\n), "$base\n";
    close $w;
    my $doc = BpSpend::Derive::derive_session(session => "$dir/s.jsonl");
    is($doc->{record_counts}{skipped_unparseable}, 2, 'both malformed lines counted');
    is($doc->{record_counts}{assistant_records}, 2, 'both valid records read');
    is($doc->{record_counts}{requests}, 1, 'deduplicated to one request by requestId');
    is($doc->{totals}{output}{tokens}, 379, 'output = the request maximum');
    is($doc->{totals}{cache_write_5m}{tokens}, 150, '5m cache write from the split');
};

done_testing();
