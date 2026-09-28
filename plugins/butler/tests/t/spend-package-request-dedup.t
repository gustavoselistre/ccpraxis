#!/usr/bin/env perl
# platform: any
# Regression for bug report .ccpraxis-local-data/bug-reports/20260922-214918-aa8c.md:
# BpSpend::derive_package (the FLEET path, --run-dir, runs/<pkg>.jsonl stream-json
# transcripts) used to sum EVERY per-content-block `assistant` record. A real
# Claude Code transcript writes one API response as several such records, each
# repeating that response's input/cache figures, so the derived totals were
# inflated 1.3-2.5x on measured archived runs (see the bug report's b01/b05
# tables). This file proves the fixed derive_package counts one API response
# ONCE: input/cache_creation/cache_read taken once per message.id (the fleet
# shape carries no requestId), output_tokens as the max seen across that
# response's records -- never re-summed per content block.
#
# Non-vacuity was checked once, at the fix commit, against the pre-fix
# bp-spend.pl (it triples input to 6 on the split-response fixture); it is not
# re-asserted here, because a test that runs `git show HEAD:` fails as soon
# as HEAD contains the fix, and writing a copy into scripts/ races the sweep.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;

# spend-token-report Decision 27.2: derive-package/derive-blueprint now fetch
# fresh pricing in the CLI verb (Decision 25), so every test that reaches
# them must guard against a live fetch.
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

sub run_spend_at {
    my ($script, @args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $script, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub slurp_json {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { JSON::PP->new->decode($raw) };
}

sub write_jsonl {
    my ($path, @lines) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    for my $l (@lines) {
        print $fh (ref($l) ? $JSON->encode($l) : $l), "\n";
    }
    close $fh;
    return $path;
}

sub sys_init {
    my (%o) = @_;
    return {
        type       => 'system',
        subtype    => 'init',
        cwd        => '/project',
        session_id => $o{session} // 'sess-1',
        model      => $o{model} // 'claude-sonnet-5',
    };
}

# A single real API response, as the fleet stream-json shape actually writes
# it: THREE `assistant` records sharing one message.id, each repeating the
# SAME input/cache figures (measured fact -- see the bug report's table of
# "ids with >1 record" vs "identical input+cache in every record", which
# match 1:1 on every archived file), while output_tokens stays at the
# stream-start stub value in every block (Constraint H1).
sub one_response_split_into_blocks {
    my (%o) = @_;
    my @blocks;
    for my $i (1 .. 3) {
        push @blocks, {
            type    => 'assistant',
            message => {
                model   => $o{model} // 'claude-sonnet-5',
                id      => $o{id},
                type    => 'message',
                role    => 'assistant',
                content => [ { type => 'text', text => "block $i" } ],
                usage   => {
                    input_tokens                => $o{input},
                    output_tokens               => $o{output_stub},
                    cache_creation_input_tokens => $o{cache_creation},
                    cache_read_input_tokens     => $o{cache_read},
                },
            },
            parent_tool_use_id => $o{parent},
            session_id         => $o{session} // 'sess-1',
            uuid               => "u-$o{id}-$i",
            timestamp           => '2026-09-22T00:00:00.000Z',
        };
    }
    return @blocks;
}

# ===========================================================================
# One API response, split into 3 assistant records (as real fleet transcripts
# do it) -> input/cache_creation/cache_read counted ONCE, not tripled.
# ===========================================================================
subtest 'one response split across 3 records counts input/cache once, not 3x' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @blocks = one_response_split_into_blocks(
        id => 'msg_ONE', parent => undef, session => 'sess-1',
        input => 2, output_stub => 1, cache_creation => 14472, cache_read => 33890,
    );
    write_jsonl(File::Spec->catfile($dir, 'runs', 'pkgDedup.jsonl'),
        sys_init(session => 'sess-1'), @blocks);

    my ($rc, $out) = run_spend_at($SPEND_PL, 'derive-package', '--run-dir', $dir, '--pkg', 'pkgDedup');
    is($rc, 0, 'exits 0') or diag($out);

    my $doc = slurp_json(File::Spec->catfile($dir, 'runs', 'spend-derived.json'));
    ok($doc, 'spend-derived.json parses') or diag($out);

  SKIP: {
        skip 'no doc to inspect', 6 unless $doc;
        is($doc->{tokens}{coordinator}{input},          2,     'input counted ONCE (2), not 3x (6)');
        is($doc->{tokens}{coordinator}{cache_creation}, 14472, 'cache_creation counted ONCE, not 3x (43416)');
        is($doc->{tokens}{coordinator}{cache_read},     33890, 'cache_read counted ONCE, not 3x (101670)');
        is($doc->{tokens}{coordinator}{output},         1,     'output is the max across the request (1), not summed (3)');
        is($doc->{packages}[0]{record_counts}{assistant_total}, 3,
            'record_counts.assistant_total still counts all 3 raw records (diagnostic, unchanged)');
        is($doc->{packages}[0]{record_counts}{requests_total}, 1,
            'record_counts.requests_total counts the ONE logical API response');
    }
};

# ===========================================================================
# Two distinct responses (different message.id), each split into blocks,
# interleaved with a subagent response in between -> role split and per-key
# dedup both still hold; nothing from one response leaks into the other's
# count, and role attribution survives interleaving.
# ===========================================================================
subtest 'two distinct multi-block responses stay independently deduplicated' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @coord1 = one_response_split_into_blocks(
        id => 'msg_A', parent => undef, session => 'sess-1',
        input => 10, output_stub => 4, cache_creation => 100, cache_read => 200,
    );
    my @sub1 = one_response_split_into_blocks(
        id => 'msg_B', parent => 'toolu_1', session => 'sess-1',
        input => 5, output_stub => 2, cache_creation => 50, cache_read => 60,
    );
    write_jsonl(File::Spec->catfile($dir, 'runs', 'pkgTwo.jsonl'),
        sys_init(session => 'sess-1'), @coord1, @sub1);

    my ($rc, $out) = run_spend_at($SPEND_PL, 'derive-package', '--run-dir', $dir, '--pkg', 'pkgTwo');
    is($rc, 0, 'exits 0') or diag($out);

    my $doc = slurp_json(File::Spec->catfile($dir, 'runs', 'spend-derived.json'));
    ok($doc, 'spend-derived.json parses') or diag($out);

  SKIP: {
        skip 'no doc to inspect', 5 unless $doc;
        is($doc->{tokens}{coordinator}{input},  10, 'coordinator response deduplicated to its own single value');
        is($doc->{tokens}{coordinator}{output}, 4,  'coordinator output is the max, not 3x the stub');
        is($doc->{tokens}{subagent}{input},     5,  'subagent response deduplicated independently');
        is($doc->{tokens}{subagent}{output},    2,  'subagent output is the max, not 3x the stub');
        is($doc->{packages}[0]{record_counts}{requests_total}, 2,
            'requests_total counts the two logical responses, not the six raw records');
    }
};

done_testing;
