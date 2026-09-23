#!/usr/bin/env perl
# platform: any
# Oracle for blueprint usage-telemetry, package
# 01-drive-solo-input-and-pricing.
#
# Tests the new `derive_session` library function and `derive-session` CLI
# verb on bp-spend.pl, which read a drive-solo session (a `<uuid>.jsonl` main
# transcript plus sibling `<uuid>/subagents/agent-<id>.jsonl` files and their
# `.meta.json` sidecars), dedup usage per API request, classify by role/
# model/effort/token-type, and price the result via an in-file table. Spec:
# specs/01-drive-solo-input-and-pricing-spec.md.
#
# EVERY fixture here is synthetic, built fresh in a tempdir. Nothing reads
# ~/.claude or this repo's own .ccpraxis-local-data.
#
# THIS FILE IS THE PACKAGE'S ORACLE for the session-input path. It must not
# be weakened to make an implementation's life easier. The neighbouring
# spend-derived-from-transcripts.t (the fleet-path oracle) is read-only from
# here — never edited, only re-run as evidence the fleet path is untouched
# (Decision 9, criterion 16).
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;

my $SPEND_PL  = "$Bin/../../scripts/bp-spend.pl";
my $ORACLE_T  = "$Bin/spend-derived-from-transcripts.t";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# CLI helpers (mirrors spend-derived-from-transcripts.t style)
# ---------------------------------------------------------------------------

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# ---------------------------------------------------------------------------
# Library-load helper. Requiring bp-spend.pl executes package BpSpend and
# BpSpend::Derive declarations; it must succeed even pre-implementation,
# since the file already compiles standalone. Only calling the not-yet-added
# derive_session/session_price_table subs is expected to die.
# ---------------------------------------------------------------------------
my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

sub call_derive_session {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::derive_session(%opts) };
    return ($doc, $@);
}

sub call_price_table {
    my $t = eval { BpSpend::Derive::session_price_table() };
    return ($t, $@);
}

# ---------------------------------------------------------------------------
# JSON/file fixture helpers
# ---------------------------------------------------------------------------

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

sub write_json_file {
    my ($path, $data) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh $JSON->encode($data);
    close $fh;
    return $path;
}

sub slurp_json {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { JSON::PP->new->decode($raw) };
}

# An assistant record. %o keys:
#   session, uuid, timestamp, request_id (top-level requestId),
#   message_id (message.id), model, effort, input, output, cache_read,
#   cache_creation (unsplit), cache_5m, cache_1h (split), speed, iterations,
#   usage_extra (hashref merged into usage AFTER the named fields, so it can
#   inject a malformed value directly), extra (hashref merged at top level).
sub assistant_rec {
    my (%o) = @_;
    my %usage;
    $usage{input_tokens}                = $o{input}          if exists $o{input};
    $usage{output_tokens}               = $o{output}         if exists $o{output};
    $usage{cache_read_input_tokens}     = $o{cache_read}      if exists $o{cache_read};
    $usage{cache_creation_input_tokens} = $o{cache_creation}  if exists $o{cache_creation};
    if (exists $o{cache_5m} || exists $o{cache_1h}) {
        $usage{cache_creation} = {
            ephemeral_5m_input_tokens => $o{cache_5m} // 0,
            ephemeral_1h_input_tokens => $o{cache_1h} // 0,
        };
    }
    $usage{speed}      = $o{speed}      if exists $o{speed};
    $usage{iterations} = $o{iterations} if exists $o{iterations};
    if (ref($o{usage_extra}) eq 'HASH') {
        $usage{$_} = $o{usage_extra}{$_} for keys %{ $o{usage_extra} };
    }

    my %message = (usage => \%usage);
    $message{model} = $o{model}      if exists $o{model};
    $message{id}    = $o{message_id} if exists $o{message_id};

    my %rec = (
        type       => 'assistant',
        message    => \%message,
        session_id => $o{session} // 'sess-1',
        uuid       => $o{uuid} // ('u-' . int(rand(1e9))),
    );
    $rec{requestId} = $o{request_id} if exists $o{request_id};
    $rec{effort}    = $o{effort}     if exists $o{effort};
    $rec{timestamp} = $o{timestamp}  if exists $o{timestamp};
    if (ref($o{extra}) eq 'HASH') {
        $rec{$_} = $o{extra}{$_} for keys %{ $o{extra} };
    }
    return \%rec;
}

# Layout helper: given a tempdir and a uuid, returns the main transcript path
# and the subagents dir path — mirrors §2.2's resolution rule.
sub session_paths {
    my ($dir, $uuid) = @_;
    my $main   = File::Spec->catfile($dir, "$uuid.jsonl");
    my $subdir = File::Spec->catdir($dir, $uuid, 'subagents');
    return ($main, $subdir);
}

sub agent_jsonl_path {
    my ($subdir, $name) = @_;
    return File::Spec->catfile($subdir, "$name.jsonl");
}

sub agent_meta_path {
    my ($subdir, $name) = @_;
    return File::Spec->catfile($subdir, "$name.meta.json");
}

sub snapshot_tree {
    # File list + mtime + size, for the read-only proof (AC11/B16).
    my ($dir) = @_;
    my %snap;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = File::Spec->catfile($d, $e);
            if (-d $p) { push @stack, $p; next; }
            my @st = stat($p);
            $snap{$p} = "$st[9]:$st[7]";   # mtime:size
        }
        closedir $dh;
    }
    return \%snap;
}

# ===========================================================================
# AC1 (criterion 1 / DC1) — dedup: 3 records, one requestId, identical
# input/cache, output 8/8/379.
# ===========================================================================
subtest 'AC1: three records sharing one requestId dedup to one request' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac1');
    write_jsonl($main,
        assistant_rec(request_id => 'req-1', model => 'claude-sonnet-5', effort => 'high',
            input => 500, cache_read => 10, cache_creation => 20, output => 8),
        assistant_rec(request_id => 'req-1', model => 'claude-sonnet-5', effort => 'high',
            input => 500, cache_read => 10, cache_creation => 20, output => 8),
        assistant_rec(request_id => 'req-1', model => 'claude-sonnet-5', effort => 'high',
            input => 500, cache_read => 10, cache_creation => 20, output => 379),
    );

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC1: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC1: derive_session unavailable', 4 unless $doc;
        is($doc->{record_counts}{requests}, 1, 'AC1: requests == 1 (one dedup group)');
        is($doc->{record_counts}{assistant_records}, 3, 'AC1: assistant_records == 3 (every admitted record counted)');
        is($doc->{totals}{output}{tokens}, 379, 'AC1: totals.output.tokens == max output (379), not the sum');
        is($doc->{totals}{input}{tokens}, 500, 'AC1: totals.input.tokens == the single dedup value, not 1500');
    }
};

subtest 'AC1 companion: a single-record request contributes that record unchanged' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac1b');
    write_jsonl($main,
        assistant_rec(request_id => 'req-solo', model => 'claude-sonnet-5',
            input => 7, output => 3, cache_read => 1, cache_creation => 2),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC1 companion: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC1 companion: derive_session unavailable', 4 unless $doc;
        is($doc->{record_counts}{requests}, 1, 'AC1 companion: requests == 1');
        is($doc->{totals}{input}{tokens},  7, 'AC1 companion: input unchanged');
        is($doc->{totals}{output}{tokens}, 3, 'AC1 companion: output unchanged');
        is($doc->{totals}{cache_read}{tokens}, 1, 'AC1 companion: cache_read unchanged');
    }
};

# ===========================================================================
# AC2 (criterion 1 / DC1, B1) — request keying by message.id, and unkeyed.
# ===========================================================================
subtest 'AC2: two records sharing message.id (no requestId) merge to one request' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac2a');
    write_jsonl($main,
        assistant_rec(message_id => 'msg-shared', input => 10, output => 1),
        assistant_rec(message_id => 'msg-shared', input => 10, output => 9),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC2a: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC2a: derive_session unavailable', 3 unless $doc;
        is($doc->{record_counts}{requests}, 1, 'AC2a: message.id keying merges to one request');
        is($doc->{record_counts}{unkeyed}, 0, 'AC2a: unkeyed == 0 when message.id was available');
        is($doc->{record_counts}{assistant_records}, 2, 'AC2a: both records still counted as admitted');
    }
};

subtest 'AC2 companion: records with neither requestId nor message.id are each their own request' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac2b');
    write_jsonl($main,
        assistant_rec(input => 1, output => 1),
        assistant_rec(input => 1, output => 1),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC2b: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC2b: derive_session unavailable', 2 unless $doc;
        is($doc->{record_counts}{unkeyed}, 2, 'AC2b: two unkeyed records increment unkeyed twice');
        is($doc->{record_counts}{requests}, 2, 'AC2b: each unkeyed record is its own request');
    }
};

# ===========================================================================
# AC3 (criterion 1 / DC1, B3) — usage mismatch flag.
# ===========================================================================
subtest 'AC3: disagreeing input_tokens on the same requestId flags a mismatch, last wins' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac3');
    write_jsonl($main,
        assistant_rec(request_id => 'req-mismatch', input => 100, output => 1),
        assistant_rec(request_id => 'req-mismatch', input => 200, output => 1),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC3: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC3: derive_session unavailable', 2 unless $doc;
        is($doc->{record_counts}{request_usage_mismatch}, 1, 'AC3: exactly one flagged request');
        is($doc->{totals}{input}{tokens}, 200, 'AC3: the LAST record supplies the merged value');
    }
};

subtest 'AC3 companion: a third disagreeing record keeps the mismatch counter at 1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac3b');
    write_jsonl($main,
        assistant_rec(request_id => 'req-mismatch3', input => 100, output => 1),
        assistant_rec(request_id => 'req-mismatch3', input => 200, output => 1),
        assistant_rec(request_id => 'req-mismatch3', input => 300, output => 1),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC3 companion: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC3 companion: derive_session unavailable', 2 unless $doc;
        is($doc->{record_counts}{request_usage_mismatch}, 1,
            'AC3 companion: mismatch is counted once per REQUEST, not once per disagreeing record');
        is($doc->{totals}{input}{tokens}, 300, 'AC3 companion: the last record still wins');
    }
};

# ===========================================================================
# AC4 (criterion 2 / DC2, B4) — role: driver vs sidecar agentType vs
# unknown-agent, all fully counted.
# ===========================================================================
subtest 'AC4: main transcript is driver; sidecar agentType kept verbatim; missing/absent sidecar -> unknown-agent' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac4');
    write_jsonl($main, assistant_rec(input => 10, output => 1));

    write_jsonl(agent_jsonl_path($subdir, 'agent-redteam'),
        assistant_rec(input => 20, output => 2));
    write_json_file(agent_meta_path($subdir, 'agent-redteam'),
        { agentType => 'butler:bp-redteam' });

    # No sidecar at all for agent-nosidecar.
    write_jsonl(agent_jsonl_path($subdir, 'agent-nosidecar'),
        assistant_rec(input => 30, output => 3));

    # Sidecar present but lacking agentType for agent-nokey.
    write_jsonl(agent_jsonl_path($subdir, 'agent-nokey'),
        assistant_rec(input => 40, output => 4));
    write_json_file(agent_meta_path($subdir, 'agent-nokey'), { spawnDepth => 1 });

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC4: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC4: derive_session unavailable', 6 unless $doc;
        my %by_role;
        for my $c (@{ $doc->{cells} }) { $by_role{ $c->{role} } += $c->{tokens} if $c->{token_type} eq 'input'; }
        ok($by_role{driver}, 'AC4: driver role present with non-zero input tokens') and
            is($by_role{driver}, 10, 'AC4: driver input == main transcript record');
        is($by_role{'butler:bp-redteam'}, 20, 'AC4: sidecar agentType kept verbatim, prefix intact');
        is($by_role{'unknown-agent'}, 30 + 40, 'AC4: both no-sidecar and no-agentType subagents fall to unknown-agent and are still summed');
        is($doc->{totals}{input}{tokens}, 10 + 20 + 30 + 40, 'AC4: totals include every role, none dropped');
    }
};

# ===========================================================================
# AC5 (criterion 3 / DC3, B5) — effort/model, never defaulted to 'medium'.
# ===========================================================================
subtest 'AC5: effort/model come from the record; absent becomes literal "unknown", never "medium"' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac5');
    write_jsonl($main,
        assistant_rec(effort => 'high', model => 'claude-sonnet-5', input => 5, output => 5),
        assistant_rec(input => 6, output => 6),   # no effort, no model field at all
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC5: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC5: derive_session unavailable', 3 unless $doc;
        my ($high_cell) = grep { $_->{effort} eq 'high' && $_->{token_type} eq 'input' } @{ $doc->{cells} };
        ok($high_cell, 'AC5: a cell with effort high/model claude-sonnet-5 exists')
            and is($high_cell->{model}, 'claude-sonnet-5', 'AC5: model preserved on the fielded record');
        my ($unknown_cell) = grep { $_->{effort} eq 'unknown' && $_->{token_type} eq 'input' } @{ $doc->{cells} };
        ok($unknown_cell && $unknown_cell->{model} eq 'unknown',
            'AC5: absent effort/model become the literal string "unknown"');
        ok(!(grep { $_->{effort} eq 'medium' } @{ $doc->{cells} }),
            'AC5: no cell anywhere defaults effort to "medium"');
    }
};

# ===========================================================================
# AC6 (criterion 4 / DC4, B6) — split vs unsplit cache-write typing.
# ===========================================================================
subtest 'AC6: a cache_creation split types 5m/1h separately; an unsplit figure never guesses a split' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac6');
    write_jsonl($main,
        assistant_rec(request_id => 'req-split', cache_5m => 100, cache_1h => 40, input => 1, output => 1),
        assistant_rec(request_id => 'req-unsplit', cache_creation => 140, input => 1, output => 1),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC6: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC6: derive_session unavailable', 4 unless $doc;
        is($doc->{totals}{cache_write_5m}{tokens}, 100, 'AC6: split produces cache_write_5m');
        is($doc->{totals}{cache_write_1h}{tokens}, 40,  'AC6: split produces cache_write_1h');
        is($doc->{totals}{cache_write_unsplit}{tokens}, 140, 'AC6: unsplit figure lands in cache_write_unsplit only');
        my $split_unsplit_total = 0;
        # The split request must contribute nothing to cache_write_unsplit.
        for my $c (@{ $doc->{cells} }) {
            $split_unsplit_total += $c->{tokens}
                if $c->{token_type} eq 'cache_write_unsplit' && $c->{tokens} == 100;
        }
        is($split_unsplit_total, 0, 'AC6: the split request contributes zero to cache_write_unsplit');
    }
};

# ===========================================================================
# AC7 (criterion 5 / DC5, §2.4) — the price table itself.
# ===========================================================================
my @REQUIRED_IDS = qw(
    claude-opus-5-5 claude-sonnet-5 claude-fable-5-1
    claude-haiku-4-5-20251001 claude-opus-5
);
my %EXPECTED_RATES = (
    'claude-opus-5-5'           => { input => 4,  output => 20, cache_write_5m => 5,     cache_write_1h => 8,  cache_read => 0.20 },
    'claude-sonnet-5'           => { input => 2,  output => 10, cache_write_5m => 2.50,  cache_write_1h => 4,  cache_read => 0.20 },
    'claude-fable-5-1'          => { input => 10, output => 50, cache_write_5m => 12.50, cache_write_1h => 20, cache_read => 0.25 },
    'claude-haiku-4-5-20251001' => { input => 1,  output => 5,  cache_write_5m => 1.25,  cache_write_1h => 2,  cache_read => 0.10 },
    'claude-opus-5'             => { input => 5,  output => 25, cache_write_5m => 6.25,  cache_write_1h => 10, cache_read => 0.50 },
);

subtest 'AC7: session_price_table() reports source/as-of and exact per-model rates' => sub {
    my ($t, $err) = call_price_table();
    ok(!$err, 'AC7: session_price_table does not die') or diag($err);
  SKIP: {
        skip 'AC7: session_price_table unavailable', 4 unless $t;
        is($t->{source}, 'https://platform.claude.com/docs/en/about-claude/pricing', 'AC7: price_source URL exact');
        is($t->{as_of}, '2026-09-23', 'AC7: price_as_of exact');
        my @missing_required = grep {
            !( exists $t->{prices}{$_} xor exists $t->{missing}{$_} )
        } @REQUIRED_IDS;
        is_deeply(\@missing_required, [], 'AC7: every required id is in EXACTLY ONE of prices/missing');
        my @bad;
        for my $id (@REQUIRED_IDS) {
            next unless exists $t->{prices}{$id};
            my $want = $EXPECTED_RATES{$id};
            my $got  = $t->{prices}{$id};
            for my $k (qw(input output cache_write_5m cache_write_1h cache_read)) {
                push @bad, "$id.$k" unless defined($got->{$k}) && $got->{$k} > 0 && $got->{$k} == $want->{$k};
            }
        }
        is_deeply(\@bad, [], 'AC7: every priced id has all five rates present, positive, and matching §2.4 exactly')
            or diag(join(', ', @bad));
    }
};

# ===========================================================================
# AC8 (criterion 5 / DC5, B8/B9) — unpriced reasons, exactly one per amount.
# ===========================================================================
subtest 'AC8: model-not-in-table, cache-write-unsplit and non-standard-speed each degrade to $0, counted once' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac8');
    # Cells are keyed by (role, model, effort, token_type) per spec Sec2.5 -- each
    # request below is given its OWN effort value so its tokens land in a cell
    # isolated from the other three requests sharing role=driver/model=claude-sonnet-5,
    # letting each assertion below target exactly one request's cell.
    write_jsonl($main,
        # 1. model absent from the table.
        assistant_rec(request_id => 'req-unknown-model', model => 'claude-nonexistent-model',
            effort => 'e-unknown-model', input => 1000, output => 1),
        # 2. cache_write_unsplit on a priced model.
        assistant_rec(request_id => 'req-unsplit', model => 'claude-sonnet-5',
            effort => 'e-unsplit', cache_creation => 500, input => 1, output => 1),
        # 3. non-standard speed -> ALL tokens on that request unpriced.
        assistant_rec(request_id => 'req-fast', model => 'claude-sonnet-5', speed => 'fast',
            effort => 'e-fast', input => 200, output => 300),
        # 4. no speed field at all -> priced as standard, increments speed_absent.
        assistant_rec(request_id => 'req-standard', model => 'claude-sonnet-5',
            effort => 'e-standard', input => 10, output => 10),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC8: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC8: derive_session unavailable', 6 unless $doc;
        is($doc->{unpriced}{'model-not-in-table'}, 1000 + 1, 'AC8: unknown-model tokens (input+output) land under model-not-in-table');
        is($doc->{unpriced}{'cache-write-unsplit'}, 500, 'AC8: unsplit cache-write tokens land under cache-write-unsplit');
        is($doc->{unpriced}{'non-standard-speed'}, 200 + 300, 'AC8: ALL tokens of a non-standard-speed request are unpriced');
        ok($doc->{record_counts}{speed_absent} >= 3, 'AC8: every record lacking usage.speed increments speed_absent');
        my ($fast_cell) = grep { $_->{token_type} eq 'output' && $_->{tokens} == 300 } @{ $doc->{cells} };
        is($fast_cell->{cost_usd}, 0, 'AC8: the non-standard-speed request contributes $0');
        my $reason_sum = $doc->{unpriced}{'model-not-in-table'} + $doc->{unpriced}{'cache-write-unsplit'} + $doc->{unpriced}{'non-standard-speed'};
        my $totals_unpriced_sum = 0;
        $totals_unpriced_sum += $_->{unpriced_tokens} for values %{ $doc->{totals} };
        is($reason_sum, $totals_unpriced_sum, 'AC8: the three unpriced reasons sum to sum(totals[*].unpriced_tokens)');
    }
};

# ===========================================================================
# AC9 (criterion 5/8, DC5/DC8, B9/B10) — hand-computable cost + agent sum
# invariant.
# ===========================================================================
subtest 'AC9: 1,000,000 input tokens on claude-sonnet-5 costs exactly $2; session cells == sum of agent cells' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac9');
    write_jsonl($main,
        assistant_rec(model => 'claude-sonnet-5', effort => 'high', input => 1_000_000, output => 0),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC9: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC9: derive_session unavailable', 3 unless $doc;
        my ($cell) = grep { $_->{token_type} eq 'input' } @{ $doc->{cells} };
        ok($cell, 'AC9: an input cell exists') and is($cell->{cost_usd}, 2, 'AC9: cell cost_usd == 2.00 exactly (2 $/MTok * 1M)');
        is($doc->{totals}{input}{cost_usd}, 2, 'AC9: totals.input.cost_usd == 2.00 exactly');

        my %agent_sum;
        for my $agent (@{ $doc->{agents} }) {
            for my $c (@{ $agent->{cells} }) {
                my $key = join("\x1f", $c->{role}, $c->{model}, $c->{effort}, $c->{token_type});
                $agent_sum{$key}{tokens}          += $c->{tokens};
                $agent_sum{$key}{cost_usd}        += $c->{cost_usd};
                $agent_sum{$key}{unpriced_tokens} += $c->{unpriced_tokens};
            }
        }
        my $mismatch = 0;
        for my $c (@{ $doc->{cells} }) {
            my $key = join("\x1f", $c->{role}, $c->{model}, $c->{effort}, $c->{token_type});
            my $want = $agent_sum{$key} // { tokens => 0, cost_usd => 0, unpriced_tokens => 0 };
            $mismatch++ unless $c->{tokens} == $want->{tokens}
                            && abs($c->{cost_usd} - $want->{cost_usd}) < 1e-9
                            && $c->{unpriced_tokens} == $want->{unpriced_tokens};
        }
        is($mismatch, 0, 'AC9: every session cell equals the element-wise sum of agents[].cells');
    }
};

# ===========================================================================
# AC10 (criterion 6 / DC6, B14/B15) — text and --json labeling.
# ===========================================================================
subtest 'AC10: text-mode dollar lines self-label; --json echoes cost_basis/price_source/price_as_of' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac10');
    write_jsonl($main, assistant_rec(model => 'claude-sonnet-5', input => 1000, output => 1000));

    my ($rc, $out) = run_spend('derive-session', '--session', $main);
    is($rc, 0, 'AC10 text: exits 0') or diag($out);
    my @lines = split(/\n/, $out);
    my @dollar_lines_missing_label = grep { /\$\d/ && !/notional as-if-API-billed/ } @lines;
    is_deeply(\@dollar_lines_missing_label, [], 'AC10: every line with $<digit> also says "notional as-if-API-billed"')
        or diag(join("\n", @dollar_lines_missing_label));
    like($lines[0] // '', qr/notional as-if-API-billed/, 'AC10: the FIRST line states the cost basis');

    my ($rc2, $out2) = run_spend('derive-session', '--session', $main, '--json');
    is($rc2, 0, 'AC10 json: exits 0') or diag($out2);
    my $doc = eval { JSON::PP->new->decode($out2) };
    ok($doc, 'AC10 json: stdout parses as JSON') or diag($out2);
  SKIP: {
        skip 'AC10 json: doc unavailable', 3 unless $doc;
        is($doc->{cost_basis}, 'notional-api-equivalent', 'AC10: cost_basis is the exact literal');
        is($doc->{price_source}, 'https://platform.claude.com/docs/en/about-claude/pricing', 'AC10: price_source echoed');
        is($doc->{price_as_of}, '2026-09-23', 'AC10: price_as_of echoed');
    }
};

# ===========================================================================
# AC11 (criterion 7 / DC7, B16) — read-only: no file created/modified/touched.
# ===========================================================================
subtest 'AC11: derive-session (text and --json) leaves the fixture tree byte- and mtime-identical' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac11');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'), assistant_rec(input => 2, output => 2));
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-scout' });

    my $before = snapshot_tree($dir);
    my ($rc1, $out1) = run_spend('derive-session', '--session', $main);
    my ($rc2, $out2) = run_spend('derive-session', '--session', $main, '--json');
    my $after = snapshot_tree($dir);

    is_deeply($after, $before, 'AC11: file list + mtime + size unchanged across a text and a --json run')
        or diag("before: " . $JSON->encode($before) . "\nafter: " . $JSON->encode($after));
    ok(!-e File::Spec->catfile($dir, 'runs', 'spend-derived.json'),
        'AC11: no spend-derived.json is created anywhere under the fixture (write_derived never called)');
};

# ===========================================================================
# AC12 (criterion 8 / DC8, §2.5) — exact key sets, library/CLI parity,
# agents[0] == driver, subagent ordering.
# ===========================================================================
subtest 'AC12: exact top-level/agent/totals/unpriced/record_counts key sets; library == --json; ordering' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac12');
    write_jsonl($main, assistant_rec(input => 1, output => 1, timestamp => '2026-09-23T10:00:00Z'));
    write_jsonl(agent_jsonl_path($subdir, 'agent-b'), assistant_rec(input => 2, output => 2));
    write_json_file(agent_meta_path($subdir, 'agent-b'), { agentType => 'butler:bp-scout' });
    write_jsonl(agent_jsonl_path($subdir, 'agent-a'), assistant_rec(input => 3, output => 3));
    write_json_file(agent_meta_path($subdir, 'agent-a'), { agentType => 'butler:bp-worker' });

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC12: derive_session does not die') or diag($err);

    my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
    is($rc, 0, 'AC12: CLI --json exits 0') or diag($out);
    my $cli_doc = eval { JSON::PP->new->decode($out) };
    ok($cli_doc, 'AC12: CLI --json stdout parses') or diag($out);

  SKIP: {
        skip 'AC12: derive_session/CLI unavailable', 8 unless ($doc && $cli_doc);
        is_deeply(
            [ sort keys %$doc ],
            [ sort qw(cost_basis price_source price_as_of cells totals unpriced anomaly record_counts agents) ],
            'AC12: top-level key set is EXACTLY the nine keys of §2.5'
        );
        is_deeply([ sort keys %{ $doc->{totals} } ],
            [ sort qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit) ],
            'AC12: totals has exactly the six token types');
        is_deeply([ sort keys %{ $doc->{unpriced} } ],
            [ sort ('model-not-in-table', 'cache-write-unsplit', 'non-standard-speed') ],
            'AC12: unpriced has exactly the three reasons');
        is_deeply([ sort keys %{ $doc->{record_counts} } ],
            [ sort qw(assistant_records requests unkeyed request_usage_mismatch multi_iteration speed_absent skipped_unparseable malformed_usage_field) ],
            'AC12: record_counts has exactly the eight counters');
        my $bad_agent_keys = 0;
        for my $a (@{ $doc->{agents} }) {
            my @got = sort keys %$a;
            my @want = sort qw(path role spawn_depth description first_ts cells anomaly);
            $bad_agent_keys++ unless "@got" eq "@want";
        }
        is($bad_agent_keys, 0, 'AC12: every agents[] entry has exactly the seven keys');

        is_deeply($doc, $cli_doc, 'AC12: the library return value is is_deeply-equal to the decoded --json document');

        is($doc->{agents}[0]{role}, 'driver', 'AC12: agents[0] is the main transcript, role driver');
        my @sub_paths = map { $_->{path} } @{ $doc->{agents} }[1 .. $#{ $doc->{agents} }];
        my @sub_basenames = map { (File::Spec->splitpath($_))[2] } @sub_paths;
        is_deeply(\@sub_basenames, [ sort @sub_basenames ], 'AC12: subagent entries follow in basename-ascending order');
    }
};

# ===========================================================================
# AC13 (criterion 8 / DC8, §2.2) — path resolution equivalence.
# ===========================================================================
subtest 'AC13: passing the <uuid>/ directory or the <uuid>.jsonl file resolve to the same document' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac13');
    write_jsonl($main, assistant_rec(input => 5, output => 5));
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'), assistant_rec(input => 6, output => 6));
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-scout' });

    my $uuid_dir = File::Spec->catdir($dir, 'sess-ac13');

    my ($doc_file, $err1) = call_derive_session(session => $main);
    my ($doc_dir,  $err2) = call_derive_session(session => $uuid_dir);
    my ($doc_dir_trailing_slash, $err3) = call_derive_session(session => "$uuid_dir/");

    ok(!$err1 && !$err2 && !$err3, 'AC13: none of the three path forms die')
        or diag("err1=$err1 err2=$err2 err3=$err3");
  SKIP: {
        skip 'AC13: derive_session unavailable', 2 unless ($doc_file && $doc_dir && $doc_dir_trailing_slash);
        is_deeply($doc_file, $doc_dir, 'AC13: <uuid>.jsonl and <uuid>/ produce is_deeply-equal documents');
        is_deeply($doc_dir, $doc_dir_trailing_slash, 'AC13: a trailing slash on the directory form is stripped and does not change the result');
    }
};

# ===========================================================================
# AC14 (criterion 9 / DC9, B7) — iterations never summed, multi_iteration
# counted from record occurrence, top-level figures authoritative.
# ===========================================================================
subtest 'AC14: usage.iterations with >1 entries is never summed in; multi_iteration counts records, not entries' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac14');
    write_jsonl($main,
        assistant_rec(request_id => 'req-multi', input => 10, output => 10,
            usage_extra => { iterations => [ { input_tokens => 9999, output_tokens => 9999 },
                                              { input_tokens => 8888, output_tokens => 8888 } ] }),
        assistant_rec(request_id => 'req-single', input => 5, output => 5,
            usage_extra => { iterations => [ { input_tokens => 7777, output_tokens => 7777 } ] }),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC14: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC14: derive_session unavailable', 3 unless $doc;
        is($doc->{record_counts}{multi_iteration}, 1, 'AC14: exactly one record has a multi-entry iterations array');
        is($doc->{totals}{input}{tokens}, 10 + 5, 'AC14: totals reflect ONLY the top-level figures, never iterations entries');
        ok($doc->{totals}{input}{tokens} < 9999, 'AC14: iterations entries (9999/8888/7777) never leak into totals');
    }
};

# ===========================================================================
# AC15 (criterion 10 / DC10, B11) — duplicate cache-write anomaly, per agent
# file, summed at session level.
# ===========================================================================
subtest 'AC15: three same-size unsplit cache-writes in one agent file yield 2 pairs; a zero-size write does not break the chain' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac15');
    write_jsonl($main, assistant_rec(input => 1, output => 1));   # driver: irrelevant to this anomaly
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'),
        assistant_rec(request_id => 'r1', cache_creation => 500, uuid => 'u-r1', input => 1, output => 1),
        assistant_rec(request_id => 'r2', cache_creation => 500, uuid => 'u-r2', input => 1, output => 1),
        assistant_rec(request_id => 'r3', cache_creation => 0,   uuid => 'u-r3', input => 1, output => 1),
        assistant_rec(request_id => 'r4', cache_creation => 500, uuid => 'u-r4', input => 1, output => 1),
    );
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-scout' });

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC15: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC15: derive_session unavailable', 5 unless $doc;
        my ($agent) = grep { $_->{role} eq 'butler:bp-scout' } @{ $doc->{agents} };
        ok($agent, 'AC15: the subagent entry exists');
        is($agent->{anomaly}{count}, 2, 'AC15: A=B=D across the 0-skip yields 2 pairs (r1-r2, r2-r4)');
        is($agent->{anomaly}{total_tokens}, 1000, 'AC15: total_tokens == 2 * 500');
        my @uuids = map { [ $_->{first_uuid}, $_->{second_uuid} ] } @{ $agent->{anomaly}{pairs} };
        is_deeply(\@uuids, [ ['u-r1', 'u-r2'], ['u-r2', 'u-r4'] ],
            'AC15: pair uuids are the first-record uuid of the earlier/later request, in order');
        is($doc->{anomaly}{name}, 'consecutive-same-size-cache-write', 'AC15: session anomaly carries the fleet name verbatim');
    }
};

subtest 'AC15 companion: two agent files each with one pair sum at the session level' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-ac15b');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'),
        assistant_rec(cache_creation => 300, uuid => 'u-a1', input => 1, output => 1),
        assistant_rec(cache_creation => 300, uuid => 'u-a2', input => 1, output => 1),
    );
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-scout' });
    write_jsonl(agent_jsonl_path($subdir, 'agent-2'),
        assistant_rec(cache_creation => 700, uuid => 'u-b1', input => 1, output => 1),
        assistant_rec(cache_creation => 700, uuid => 'u-b2', input => 1, output => 1),
    );
    write_json_file(agent_meta_path($subdir, 'agent-2'), { agentType => 'butler:bp-worker' });

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'AC15 companion: derive_session does not die') or diag($err);
  SKIP: {
        skip 'AC15 companion: derive_session unavailable', 2 unless $doc;
        is($doc->{anomaly}{count}, 2, 'AC15 companion: session-level anomaly.count == sum of per-agent counts (1+1)');
        is($doc->{anomaly}{total_tokens}, 300 + 700, 'AC15 companion: session-level total_tokens == sum of per-agent totals');
    }
};

# ===========================================================================
# AC16 (criterion 11 / DC11) — the fleet path is untouched; the fleet oracle
# stays green; new/unknown-verb/derive-package behaviour is unaffected.
# ===========================================================================
subtest 'AC16: the fleet oracle (spend-derived-from-transcripts.t) is green and byte-unchanged' => sub {
    ok(-f $ORACLE_T, 'AC16: the fleet oracle test file exists') or return;
    my $cmd = qq("$PERL" "$ORACLE_T" 2>&1);
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC16: spend-derived-from-transcripts.t exits 0') or diag($out);
    my @not_ok = grep { /^not ok/ } split(/\n/, $out);
    is(scalar(@not_ok), 0, 'AC16: zero "not ok" lines in the fleet oracle run') or diag(join("\n", @not_ok));

    my $diff = `git -C "$Bin/../../.." diff --stat -- "$ORACLE_T" 2>&1`;
    is($diff, '', 'AC16: git diff --stat shows the fleet oracle file unchanged') or diag($diff);
};

subtest 'AC16 companion: derive-package still writes spend-derived.json; unknown verb still exits 2' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $sys_init = { type => 'system', subtype => 'init', session_id => 'sess-1', model => 'claude-sonnet-5' };
    my $assistant = {
        type => 'assistant',
        message => { model => 'claude-sonnet-5', id => 'm1', usage => { input_tokens => 3, output_tokens => 3, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } },
        parent_tool_use_id => undef, session_id => 'sess-1', uuid => 'u-1',
    };
    write_jsonl(File::Spec->catfile($dir, 'runs', 'pkgAC16.jsonl'), $sys_init, $assistant);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgAC16');
    is($rc, 0, 'AC16 companion: derive-package still exits 0') or diag($out);
    ok(-f File::Spec->catfile($dir, 'runs', 'spend-derived.json'), 'AC16 companion: derive-package still writes spend-derived.json');

    my ($rc2, $out2) = run_spend('totally-unknown-verb');
    is($rc2, 2, 'AC16 companion: an unknown verb still exits 2') or diag($out2);
};

# ===========================================================================
# Edge cases & failure modes (spec §5) — not separately numbered but required
# by the coverage rule.
# ===========================================================================

subtest 'edge: a missing main transcript dies with the exact §2.1 message; CLI exits 4' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ghost = File::Spec->catfile($dir, 'ghost-uuid.jsonl');
    my ($doc, $err) = call_derive_session(session => $ghost);
    ok(!$doc, 'edge missing: derive_session does not return a partial document');
    like($err, qr/\Qderive_session: no such session transcript:\E/, 'edge missing: dies with the exact §2.1 message prefix')
        if $err;

    my ($rc, $out) = run_spend('derive-session', '--session', $ghost);
    is($rc, 4, 'edge missing: CLI exits 4 for an unresolvable session transcript') or diag($out);
    like($out, qr/no such session transcript/, 'edge missing: stderr names the failure') if $rc != 0;
};

subtest 'edge: a directory whose <uuid>.jsonl sibling does not exist is the same missing-transcript case' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($dir, 'ghost-uuid2', 'subagents'));
    my ($doc, $err) = call_derive_session(session => File::Spec->catdir($dir, 'ghost-uuid2'));
    ok(!$doc, 'edge dir-no-sibling: derive_session does not return a partial document');
    ok($err, 'edge dir-no-sibling: derive_session dies');
};

subtest 'edge: an empty main transcript with no subagents is a valid all-zero document, not an error' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-empty');
    write_jsonl($main);   # zero lines
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge empty: derive_session does not die on an empty transcript') or diag($err);
  SKIP: {
        skip 'edge empty: derive_session unavailable', 5 unless $doc;
        is_deeply($doc->{cells}, [], 'edge empty: cells is empty');
        is($doc->{record_counts}{assistant_records}, 0, 'edge empty: all counters are 0');
        is($doc->{totals}{input}{tokens}, 0, 'edge empty: totals are all zero');
        is(scalar(@{ $doc->{agents} }), 1, 'edge empty: exactly one agent entry (the driver)');
        is_deeply($doc->{agents}[0]{cells}, [], 'edge empty: the driver agent has zero cells');
    }
};

subtest 'edge: subagents/ absent entirely -> exactly one agent entry' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-nosubagents');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge no-subagents-dir: derive_session does not die') or diag($err);
  SKIP: {
        skip 'edge no-subagents-dir: derive_session unavailable', 1 unless $doc;
        is(scalar(@{ $doc->{agents} }), 1, 'edge no-subagents-dir: only the driver agent entry exists');
    }
};

subtest 'edge: subagents/ holding only a .meta.json (no matching .jsonl) is ignored' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-onlymeta');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_json_file(agent_meta_path($subdir, 'agent-orphan'), { agentType => 'butler:bp-scout' });
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge only-meta: derive_session does not die') or diag($err);
  SKIP: {
        skip 'edge only-meta: derive_session unavailable', 1 unless $doc;
        is(scalar(@{ $doc->{agents} }), 1, 'edge only-meta: an orphan .meta.json with no matching .jsonl produces no extra agent entry');
    }
};

subtest 'edge: a malformed JSON line is skipped, not fatal; valid records still counted' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-malformed-line');
    write_jsonl($main, '{not valid json,,,', assistant_rec(input => 9, output => 9));
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge malformed-line: derive_session does not die') or diag($err);
  SKIP: {
        skip 'edge malformed-line: derive_session unavailable', 2 unless $doc;
        ok($doc->{record_counts}{skipped_unparseable} >= 1, 'edge malformed-line: skipped_unparseable counts the bad line');
        is($doc->{totals}{input}{tokens}, 9, 'edge malformed-line: the valid record is still summed');
    }
};

subtest 'edge: malformed usage fields (negative/string/ref) contribute 0 and are counted, never crash' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-malformed-usage');
    write_jsonl($main,
        assistant_rec(request_id => 'req-neg', usage_extra => { input_tokens => -5, output_tokens => 1 }),
        assistant_rec(request_id => 'req-str', usage_extra => { input_tokens => 'lots', output_tokens => 2 }),
        assistant_rec(request_id => 'req-ref', usage_extra => { input_tokens => [1,2], output_tokens => 3 }),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge malformed-usage: derive_session does not die') or diag($err);
  SKIP: {
        skip 'edge malformed-usage: derive_session unavailable', 2 unless $doc;
        is($doc->{totals}{input}{tokens}, 0, 'edge malformed-usage: every malformed input_tokens value contributes 0, never crashes and never goes negative');
        ok($doc->{record_counts}{malformed_usage_field} >= 3, 'edge malformed-usage: each malformed field is counted');
    }
};

subtest 'edge: an unparseable/non-object sidecar yields role unknown-agent, spawn_depth/description null, never fatal' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-badsidecar');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'), assistant_rec(input => 5, output => 5));
    # Not valid JSON at all.
    my $meta_path = agent_meta_path($subdir, 'agent-1');
    make_path((File::Spec->splitpath($meta_path))[1]);
    open(my $fh, '>:raw', $meta_path) or die $!;
    print $fh '{not json';
    close $fh;

    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge bad-sidecar: derive_session does not die on an unparseable sidecar') or diag($err);
  SKIP: {
        skip 'edge bad-sidecar: derive_session unavailable', 3 unless $doc;
        my ($agent) = grep { $_->{path} =~ /agent-1\.jsonl$/ } @{ $doc->{agents} };
        ok($agent, 'edge bad-sidecar: the subagent entry still exists');
        is($agent->{role}, 'unknown-agent', 'edge bad-sidecar: role falls back to unknown-agent');
        ok(!defined($agent->{spawn_depth}) && !defined($agent->{description}),
            'edge bad-sidecar: spawn_depth and description are both null');
    }
};

subtest 'edge: CLI --session missing/empty exits 2 with the exact message' => sub {
    my ($rc, $out) = run_spend('derive-session');
    is($rc, 2, 'edge CLI no-session: exits 2') or diag($out);
    like($out, qr/\Qbp-spend: derive-session requires --session PATH\E/, 'edge CLI no-session: exact stderr message');
};

subtest 'edge: agent paths use forward slashes only, even on a backslash-styled input' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-slashes');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'), assistant_rec(input => 2, output => 2));
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-scout' });
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'edge slashes: derive_session does not die') or diag($err);
  SKIP: {
        skip 'edge slashes: derive_session unavailable', 1 unless $doc;
        my $bad = grep { $_->{path} =~ /\\/ } @{ $doc->{agents} };
        is($bad, 0, 'edge slashes: no emitted path contains a backslash');
    }
};

done_testing();
