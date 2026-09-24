#!/usr/bin/env perl
# platform: any
# Oracle for blueprint usage-telemetry, package
# 02-attribution-and-report.
#
# Tests the new BpSpend::Derive::resolve_data_root / load_dispatch_records /
# blueprint_index / attribute_session / report_session library functions and
# the read-only `report-session` CLI verb on bp-spend.pl. They attribute each
# agent of a package-01 `derive_session` document to a blueprint/package
# using `bp-dispatch-log.pl`'s dispatch-log records and blueprint ledgers,
# then pivot package 01's totals by any ordered subset of role/blueprint/
# package/model/effort/token_type. Spec: specs/02-attribution-and-report-spec.md.
#
# EVERY fixture here is synthetic, built fresh in a tempdir. Nothing reads
# ~/.claude or this repo's own .ccpraxis-local-data, EXCEPT AC16, which
# deliberately points CLAUDE_PROJECT_DIR at a tempdir (never the real repo)
# to exercise the default-root resolution path itself.
#
# THIS FILE IS THE PACKAGE'S ORACLE. It must not be weakened to make an
# implementation's life easier. spend-drive-solo-session.t (package 01's
# oracle) and spend-derived-from-transcripts.t (the fleet-path oracle) are
# READ-ONLY from here, and their own suites are the evidence neither path
# regressed (Decision 9, criterion 8 / AC17); this file does not re-run them.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;
use POSIX qw(strftime);

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# CLI helper
# ---------------------------------------------------------------------------
sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# ---------------------------------------------------------------------------
# Library-load helper. Requiring bp-spend.pl must succeed even pre-
# implementation (the file already compiles standalone); only calling the
# not-yet-added subs is expected to die/be undefined.
# ---------------------------------------------------------------------------
my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

sub call_derive_session {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::derive_session(%opts) };
    return ($doc, $@);
}
sub call_report_session {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::report_session(%opts) };
    return ($doc, $@);
}
sub call_attribute_session {
    my (%opts) = @_;
    my $r = eval { BpSpend::Derive::attribute_session(%opts) };
    return ($r, $@);
}
sub call_blueprint_index {
    my ($root) = @_;
    my $r = eval { BpSpend::Derive::blueprint_index($root) };
    return ($r, $@);
}
sub call_load_dispatch_records {
    my ($root) = @_;
    my $r = eval { BpSpend::Derive::load_dispatch_records($root) };
    return ($r, $@);
}

# ---------------------------------------------------------------------------
# JSON/file fixture helpers (style of spend-drive-solo-session.t:73-93)
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

# An assistant record (mirrors spend-drive-solo-session.t's assistant_rec).
sub assistant_rec {
    my (%o) = @_;
    my %usage;
    $usage{input_tokens}  = $o{input}  if exists $o{input};
    $usage{output_tokens} = $o{output} if exists $o{output};
    my %message = (usage => \%usage);
    $message{model} = $o{model} if exists $o{model};
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
    return \%rec;
}

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

# Epoch seconds -> the ISO8601 form _session_parse_ts accepts.
sub ts_from_epoch {
    my ($epoch) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch));
}

# Writes one subagent file (+ optional sidecar) under $subdir. %o:
#   input, output (default 1/1), first_ts (epoch -> becomes the record's
#   timestamp), agent_type, description, spawn_depth.
sub write_agent {
    my ($subdir, $name, %o) = @_;
    my %rec_opts = (input => $o{input} // 1, output => $o{output} // 1);
    $rec_opts{timestamp} = ts_from_epoch($o{first_ts}) if defined $o{first_ts};
    write_jsonl(agent_jsonl_path($subdir, $name), assistant_rec(%rec_opts));
    my %meta;
    $meta{agentType}   = $o{agent_type}   if defined $o{agent_type};
    $meta{description} = $o{description}  if defined $o{description};
    $meta{spawnDepth}  = $o{spawn_depth}  if defined $o{spawn_depth};
    write_json_file(agent_meta_path($subdir, $name), \%meta) if %meta;
    return $name;
}

# Writes <data_root>/.dispatch-log/<filename_base>.json with EXACTLY the
# given fields (undef values omitted), independent of the filename -- lets
# AC6 construct an id that begins hk- under a non-hk- filename.
sub write_dispatch_record_named {
    my ($data_root, $filename_base, %fields) = @_;
    my %rec;
    for my $k (keys %fields) { $rec{$k} = $fields{$k} if defined $fields{$k}; }
    my $path = File::Spec->catfile($data_root, '.dispatch-log', "$filename_base.json");
    write_json_file($path, \%rec);
    return $path;
}

# Convenience: filename base == id.
sub write_dispatch_record {
    my ($data_root, $id, %fields) = @_;
    return write_dispatch_record_named($data_root, $id, id => $id, %fields);
}

# Writes <data_root>/blueprints/[_archive/]<blueprint>/packages/<ledger_id>.md
sub write_ledger {
    my ($data_root, $blueprint, $ledger_id, %o) = @_;
    my @parts = ('blueprints');
    push @parts, '_archive' if $o{archived};
    push @parts, $blueprint, 'packages';
    my $dir = File::Spec->catdir($data_root, @parts);
    make_path($dir) unless -d $dir;
    my $path = File::Spec->catfile($dir, "$ledger_id.md");
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh "# $ledger_id\n";
    close $fh;
    return $path;
}

# A blueprint directory with no packages/ subdir at all.
sub write_blueprint_dir {
    my ($data_root, $name, %o) = @_;
    my @parts = ('blueprints');
    push @parts, '_archive' if $o{archived};
    push @parts, $name;
    my $dir = File::Spec->catdir($data_root, @parts);
    make_path($dir) unless -d $dir;
    return $dir;
}

sub slashify { my ($p) = @_; (my $x = $p) =~ s{\\}{/}g; return $x; }

sub snapshot_tree {
    # File list + mtime + size, for the read-only proof (AC14).
    my (@dirs) = @_;
    my %snap;
    for my $dir (@dirs) {
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
    }
    return \%snap;
}

my @TOKEN_TYPES = qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit);
my @REASONS     = qw(unknown-agent ambiguous id-unresolved no-dispatch-record outside-window);

# ===========================================================================
# AC1 (criterion 1 / DC1, B2) -- window-boundary matching + default budget.
# ===========================================================================
subtest 'AC1a: window is inclusive on both ends, using ended_at OR started_at+4*budget' => sub {
    my $S = 1_700_000_000;
    my $B = 600;
    my $mk_doc = sub {
        my ($t0) = @_;
        return { agents => [
            { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
            { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $t0, description => undef },
        ] };
    };
    my $records_no_end = [ { id => 'r1', worker_type => 'bp-implementer', started_at => $S,
        budget => $B, blueprint => 'bp-x', package => '01-thing' } ];
    my $index = {};

    for my $case (
        [ $S - 120,        1, 'AC1a: t0 == started_at-120 attributes (lower bound inclusive)' ],
        [ $S - 121,        0, 'AC1a: t0 == started_at-121 does NOT attribute (just below lower bound)' ],
        [ $S + 4 * $B,     1, 'AC1a: t0 == started_at+4*budget attributes (upper bound inclusive)' ],
        [ $S + 4 * $B + 1, 0, 'AC1a: t0 == started_at+4*budget+1 does NOT attribute (just above upper bound)' ],
    ) {
        my ($t0, $want_attributed, $name) = @$case;
        my ($attrs, $err) = call_attribute_session(doc => $mk_doc->($t0), records => $records_no_end, index => $index);
        ok(!$err, "$name: attribute_session does not die") or diag($err);
      SKIP: {
            skip "$name: attribute_session unavailable", 1 unless $attrs;
            my $kind = $attrs->[1]{kind};
            is($kind, ($want_attributed ? 'attributed' : 'unattributed'), $name);
        }
    }
};

subtest 'AC1b: an ended_at record uses ended_at, not started_at+4*budget, even when the budget window is far later' => sub {
    my $S = 1_700_000_000;
    my $B = 600;               # started_at+4*B would be far later than ended_at
    my $ended_at = $S + 300;
    my $mk_doc = sub {
        my ($t0) = @_;
        return { agents => [
            { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
            { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $t0, description => undef },
        ] };
    };
    my $records = [ { id => 'r1', worker_type => 'bp-implementer', started_at => $S, ended_at => $ended_at,
        budget => $B, blueprint => 'bp-x', package => '01-thing' } ];
    my $index = {};

    for my $case (
        [ $ended_at,     1, 'AC1b: t0 == ended_at attributes' ],
        [ $ended_at + 1, 0, 'AC1b: t0 == ended_at+1 does NOT attribute, even though started_at+4*budget is later' ],
    ) {
        my ($t0, $want_attributed, $name) = @$case;
        my ($attrs, $err) = call_attribute_session(doc => $mk_doc->($t0), records => $records, index => $index);
        ok(!$err, "$name: attribute_session does not die") or diag($err);
      SKIP: {
            skip "$name: attribute_session unavailable", 1 unless $attrs;
            is($attrs->[1]{kind}, ($want_attributed ? 'attributed' : 'unattributed'), $name);
        }
    }
};

subtest 'AC1c: a record admitted with no budget_seconds normalizes to $BpDispatchLog::DEFAULT_BUDGET_SECONDS' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_dispatch_record($root, 'rec-nobudget', worker_type => 'bp-implementer', started_at => 1_700_000_000);
    my ($recs, $err) = call_load_dispatch_records($root);
    ok(!$err, 'AC1c: load_dispatch_records does not die') or diag($err);
  SKIP: {
        skip 'AC1c: load_dispatch_records unavailable', 2 unless $recs;
        my ($r) = grep { $_->{id} eq 'rec-nobudget' } @$recs;
        ok($r, 'AC1c: the record is admitted');
        is($r && $r->{budget}, $BpDispatchLog::DEFAULT_BUDGET_SECONDS,
            'AC1c: missing budget_seconds normalizes to $BpDispatchLog::DEFAULT_BUDGET_SECONDS (1800)')
            if $r;
    }
};

subtest 'AC1c companion: the default-budget window (S+4*1800) is honoured end to end via attribute_session' => sub {
    my $S = 1_700_000_000;
    my $DEFAULT_B = 1800;
    my $mk_doc = sub {
        my ($t0) = @_;
        return { agents => [
            { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
            { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $t0, description => undef },
        ] };
    };
    my $records = [ { id => 'r1', worker_type => 'bp-implementer', started_at => $S,
        budget => $DEFAULT_B, blueprint => 'bp-x', package => '01-thing' } ];
    for my $case (
        [ $S + 4 * $DEFAULT_B,     1, 'AC1c companion: t0 == S+4*1800 attributes' ],
        [ $S + 4 * $DEFAULT_B + 1, 0, 'AC1c companion: t0 == S+4*1800+1 does NOT attribute' ],
    ) {
        my ($t0, $want, $name) = @$case;
        my ($attrs, $err) = call_attribute_session(doc => $mk_doc->($t0), records => $records, index => {});
        ok(!$err, "$name: does not die") or diag($err);
      SKIP: {
            skip "$name: unavailable", 1 unless $attrs;
            is($attrs->[1]{kind}, ($want ? 'attributed' : 'unattributed'), $name);
        }
    }
};

# ===========================================================================
# AC2 (criterion 1 / DC1, B3.1) -- record-field resolution.
# ===========================================================================
subtest 'AC2: both blueprint+package on the record win verbatim with source record-fields; only one falls through' => sub {
    my $S = 1_700_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
        { path => 'a2.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
    ] };
    # a2's record supplies only `blueprint`, no `package` -> falls through to
    # id parsing, which names no indexed blueprint -> id-unresolved.
    my $records = [
        { id => 'field-rec', worker_type => 'bp-implementer', started_at => $S, budget => 600,
          blueprint => 'bp-x', package => '07-thing' },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'AC2: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC2: attribute_session unavailable', 4 unless $attrs;
        is($attrs->[1]{blueprint}, 'bp-x', 'AC2: blueprint taken verbatim from the record');
        is($attrs->[1]{package}, '07-thing', 'AC2: package taken verbatim from the record');
        is($attrs->[1]{source}, 'record-fields', 'AC2: source == record-fields, no directory lookup');
    }

    # A second, independent call: only `blueprint` present.
    my $doc2 = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
    ] };
    my $records2 = [
        { id => 'noname-rec-1-fallback-1', worker_type => 'bp-implementer', started_at => $S, budget => 600,
          blueprint => 'bp-x-only' },
    ];
    my ($attrs2, $err2) = call_attribute_session(doc => $doc2, records => $records2, index => {});
    ok(!$err2, 'AC2 companion: attribute_session does not die') or diag($err2);
  SKIP: {
        skip 'AC2 companion: attribute_session unavailable', 1 unless $attrs2;
        isnt($attrs2->[1]{source}, 'record-fields',
            'AC2 companion: a record with only `blueprint` (no `package`) falls through to id parsing');
    }
};

# ===========================================================================
# AC3 (criterion 1 / DC1, B3.2) -- longest-name id resolution (worked example).
# ===========================================================================
subtest 'AC3: the longest prefixing blueprint name wins; source record-id' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_blueprint_dir($root, 'butler-gate');
    write_ledger($root, 'butler-gate-ergonomics', '10-implement-retry');

    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC3: blueprint_index does not die') or diag($ierr);
  SKIP: {
        skip 'AC3: blueprint_index unavailable', 1 unless $index;
        ok(exists $index->{'butler-gate'} && exists $index->{'butler-gate-ergonomics'},
            'AC3: both blueprint names are indexed');
    }
    return unless $index;

    my $S = 1_790_110_001 - 10;   # first_ts just inside the window of the id's epoch
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
    ] };
    my $records = [
        { id => 'butler-gate-ergonomics-10-implementer-retry-1790110001', worker_type => 'bp-implementer',
          started_at => $S - 5, budget => 1800 },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'AC3: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC3: attribute_session unavailable', 3 unless $attrs;
        is($attrs->[1]{blueprint}, 'butler-gate-ergonomics', 'AC3: the LONGER name wins, not butler-gate');
        is($attrs->[1]{package}, '10-implement-retry', 'AC3: package resolves via the next hyphen token (10)');
        is($attrs->[1]{source}, 'record-id', 'AC3: source == record-id');
    }
};

# ===========================================================================
# AC4 (criterion 1 / DC1, B3.2) -- integer package comparison (04 == 4).
# ===========================================================================
subtest 'AC4: package numbers compare as integers regardless of leading zeros, in either direction' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp4a', '04-thing');
    write_ledger($root, 'bp4b', '4-thing');
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC4: blueprint_index does not die') or diag($ierr);
    return unless $index;

    my $S1 = 1_000_000;
    my $S2 = 2_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-worker', first_ts => $S1, description => undef },
        { path => 'a2.jsonl', role => 'butler:bp-worker', first_ts => $S2, description => undef },
    ] };
    # Distinct, non-overlapping windows so each agent has exactly one B2 match
    # (candidacy/matching is worker_type + timing only -- the id plays no role
    # until B3 -- so identical timing across records would make both agents
    # ambiguous instead of exercising B3's id resolution).
    my $records = [
        { id => 'bp4a-4-worker-1', worker_type => 'bp-worker', started_at => $S1 - 5, budget => 1800 },
        { id => 'bp4b-04-worker-2', worker_type => 'bp-worker', started_at => $S2 - 5, budget => 1800 },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'AC4: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC4: attribute_session unavailable', 4 unless $attrs;
        is($attrs->[1]{blueprint}, 'bp4a', 'AC4: bp4a resolved (holding 04-thing, id token 4)');
        is($attrs->[1]{package}, '04-thing', 'AC4: id token "4" matches ledger "04-thing"');
        is($attrs->[2]{blueprint}, 'bp4b', 'AC4: bp4b resolved (holding 4-thing, id token 04)');
        is($attrs->[2]{package}, '4-thing', 'AC4: id token "04" matches ledger "4-thing"');
    }
};

# ===========================================================================
# AC5 (criterion 1 / DC1, §2.5) -- active-over-archive.
# ===========================================================================
subtest 'AC5: a name present under both blueprints/ and blueprints/_archive/ resolves to the active one' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp5', '02-active');
    write_ledger($root, 'bp5', '02-archived', archived => 1);
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC5: blueprint_index does not die') or diag($ierr);
  SKIP: {
        skip 'AC5: blueprint_index unavailable', 2 unless $index;
        is($index->{bp5}{archived}, 0, 'AC5: the discarded-archive entry is archived => 0');
        is_deeply($index->{bp5}{packages}{2}, ['02-active'], 'AC5: only the active ledger is indexed for package 2');
    }
    return unless $index;

    my $S = 2_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-worker', first_ts => $S, description => undef },
    ] };
    my $records = [ { id => 'bp5-2-worker-1', worker_type => 'bp-worker', started_at => $S - 5, budget => 1800 } ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'AC5: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC5: attribute_session unavailable', 1 unless $attrs;
        is($attrs->[1]{package}, '02-active', 'AC5: an id resolving to package 2 of bp5 yields 02-active, not 02-archived');
    }
};

subtest 'AC5 companion: a blueprint present ONLY under _archive/ still resolves' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp5only', '01-thing', archived => 1);
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC5 companion: blueprint_index does not die') or diag($ierr);
  SKIP: {
        skip 'AC5 companion: blueprint_index unavailable', 2 unless $index;
        ok(exists $index->{bp5only}, 'AC5 companion: the archive-only blueprint is indexed');
        is($index->{bp5only}{archived}, 1, 'AC5 companion: it is flagged archived => 1');
    }
};

# ===========================================================================
# AC6 (criterion 1 / DC1, B1) -- hk- records excluded, by filename and by id.
# ===========================================================================
subtest 'AC6: an hk- filename, and an hk- id under a non-hk- filename, are both excluded' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $S = 3_000_000;
    write_dispatch_record_named($root, 'hk-1700000000', id => 'hk-1700000000',
        worker_type => 'bp-worker', started_at => $S - 5, budget_seconds => 1800);
    write_dispatch_record_named($root, 'normal-name', id => 'hk-embedded-id',
        worker_type => 'bp-worker', started_at => $S - 5, budget_seconds => 1800);
    write_dispatch_record($root, 'genuine-1-worker-999', worker_type => 'bp-other-role', started_at => $S - 5, budget_seconds => 1800);

    my ($recs, $err) = call_load_dispatch_records($root);
    ok(!$err, 'AC6: load_dispatch_records does not die') or diag($err);
  SKIP: {
        skip 'AC6: load_dispatch_records unavailable', 2 unless $recs;
        my @ids = map { $_->{id} } @$recs;
        ok(!(grep { $_ eq 'hk-1700000000' } @ids), 'AC6: hk- filename record excluded');
        ok(!(grep { $_ eq 'hk-embedded-id' } @ids), 'AC6: hk- id (non-hk- filename) record excluded');
    }
    return unless $recs;

    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-worker', first_ts => $S, description => undef },
    ] };
    my ($attrs, $aerr) = call_attribute_session(doc => $doc, records => $recs, index => {});
    ok(!$aerr, 'AC6: attribute_session does not die') or diag($aerr);
  SKIP: {
        skip 'AC6: attribute_session unavailable', 2 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'AC6: with hk- records excluded, the agent is unattributed');
        is($attrs->[1]{reason}, 'no-dispatch-record', 'AC6: reason is no-dispatch-record (as if the dir were empty)');
    }
};

# ===========================================================================
# AC7 (criterion 2 / DC2, B2) -- ambiguity.
# ===========================================================================
subtest 'AC7: two matching records leave the agent unattributed/ambiguous, never the first match' => sub {
    my $S = 4_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
    ] };
    my $records = [
        { id => 'r1', worker_type => 'bp-implementer', started_at => $S - 10, budget => 1800, blueprint => 'bp-a', package => '01-a' },
        { id => 'r2', worker_type => 'bp-implementer', started_at => $S - 20, budget => 1800, blueprint => 'bp-a', package => '01-a' },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'AC7: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC7: attribute_session unavailable', 4 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'AC7: kind == unattributed');
        is($attrs->[1]{reason}, 'ambiguous', 'AC7: reason == ambiguous');
        is($attrs->[1]{blueprint}, 'unattributed', 'AC7: blueprint == unattributed, even though both records resolve to bp-a');
        is($attrs->[1]{package}, 'unattributed', 'AC7: package == unattributed');
    }
};

# ===========================================================================
# AC8 (criterion 3 / DC3, B5) -- one subtest per reason.
# ===========================================================================
subtest 'AC8: unknown-agent -- no sidecar / no agentType, no record matching attempted' => sub {
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'unknown-agent', first_ts => 5_000_000, description => undef },
    ] };
    my $records = [ { id => 'r1', worker_type => 'unknown-agent', started_at => 4_999_990, budget => 1800, blueprint => 'bp-a', package => '01-a' } ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'unknown-agent: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'unknown-agent: unavailable', 2 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'unknown-agent: kind == unattributed');
        is($attrs->[1]{reason}, 'unknown-agent', 'unknown-agent: reason == unknown-agent, even though a matching record exists');
    }
};

subtest 'AC8: id-unresolved -- (a) id names no indexed blueprint, (b) id resolves a blueprint but no ledger matches' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp-known', '01-thing');
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'id-unresolved: blueprint_index does not die') or diag($ierr);
    return unless $index;

    my $S1 = 6_000_000;
    my $S2 = 7_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-worker', first_ts => $S1, description => undef },
        { path => 'a2.jsonl', role => 'butler:bp-worker', first_ts => $S2, description => undef },
    ] };
    # Distinct, non-overlapping windows so each agent has exactly one B2 match
    # (see AC4 above for why identical timing would make both ambiguous).
    my $records = [
        { id => 'no-such-blueprint-prefix-1-worker-1', worker_type => 'bp-worker', started_at => $S1 - 5, budget => 1800 },
        { id => 'bp-known-9-worker-2', worker_type => 'bp-worker', started_at => $S2 - 5, budget => 1800 },  # no ledger #9
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'id-unresolved: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'id-unresolved: unavailable', 4 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'id-unresolved(a): kind == unattributed');
        is($attrs->[1]{reason}, 'id-unresolved', 'id-unresolved(a): no indexed blueprint prefixes the id');
        is($attrs->[2]{kind}, 'unattributed', 'id-unresolved(b): kind == unattributed');
        is($attrs->[2]{reason}, 'id-unresolved', 'id-unresolved(b): blueprint resolves but no ledger #9 exists');
    }
};

subtest 'AC8: no-dispatch-record -- no candidate record with that worker_type exists at all' => sub {
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-lonely', first_ts => 7_000_000, description => undef },
    ] };
    my $records = [ { id => 'r1', worker_type => 'bp-someone-else', started_at => 6_999_995, budget => 1800, blueprint => 'bp-a', package => '01-a' } ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'no-dispatch-record: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'no-dispatch-record: unavailable', 2 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'no-dispatch-record: kind == unattributed');
        is($attrs->[1]{reason}, 'no-dispatch-record', 'no-dispatch-record: reason names the absence');
    }
};

subtest 'AC8: outside-window -- candidates with the worker_type exist, none in the window (incl. first_ts == null)' => sub {
    my $S = 8_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-worker', first_ts => $S, description => undef },
        { path => 'a2.jsonl', role => 'butler:bp-worker', first_ts => undef, description => undef },  # first_ts null
    ] };
    my $records = [ { id => 'r1', worker_type => 'bp-worker', started_at => $S + 100_000, budget => 600, blueprint => 'bp-a', package => '01-a' } ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'outside-window: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'outside-window: unavailable', 4 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'outside-window: kind == unattributed');
        is($attrs->[1]{reason}, 'outside-window', 'outside-window: candidates exist, none matched the window');
        is($attrs->[2]{reason}, 'outside-window', 'outside-window: a null first_ts with candidates present is ALSO outside-window, never a crash');
        ok(1, 'outside-window: no crash on null first_ts');
    }
};

subtest 'AC8 invariant: every attribution reason is in @ATTRIBUTION_REASONS and undef iff kind != unattributed' => sub {
    my $S = 9_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => $S, description => undef },
        { path => 'a2.jsonl', role => 'unknown-agent', first_ts => $S, description => undef },
    ] };
    my $records = [ { id => 'r1', worker_type => 'bp-implementer', started_at => $S - 5, budget => 1800, blueprint => 'bp-a', package => '01-a' } ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'invariant: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'invariant: unavailable', 1 unless $attrs;
        my $bad = 0;
        for my $a (@$attrs) {
            if ($a->{kind} eq 'unattributed') {
                $bad++ unless defined($a->{reason}) && grep { $_ eq $a->{reason} } @REASONS;
            }
            else {
                $bad++ if defined $a->{reason};
            }
        }
        is($bad, 0, 'invariant: reason is one of the five values iff unattributed, else undef');
    }
};

# ===========================================================================
# AC9 (criterion 3 / DC3, B4) -- description heuristic, success and failures.
# ===========================================================================
subtest 'AC9: heuristic success (case-insensitive) and heuristic failures leave the primary reason untouched' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp-a', '03-thing');
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC9: blueprint_index does not die') or diag($ierr);
    return unless $index;

    my $S = 10_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        # X: primary-attributed to bp-a via record-fields -> seeds S = {bp-a}.
        { path => 'x.jsonl', role => 'butler:bp-worker', first_ts => $S, description => undef },
        # Y1/Y2: no matching record; description names package 3, case-varied.
        { path => 'y1.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'Red-team package 3 bp-on-path' },
        { path => 'y2.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'PKG 3 also works' },
        # (c) no package phrase at all.
        { path => 'z1.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'no phrase here' },
        # (b) names a ledger number absent from S.
        { path => 'z2.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'package 9 please' },
    ] };
    my $records = [
        { id => 'x-rec', worker_type => 'bp-worker', started_at => $S - 5, budget => 1800, blueprint => 'bp-a', package => '03-thing' },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'AC9: attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC9: attribute_session unavailable', 8 unless $attrs;
        is($attrs->[2]{kind}, 'attributed', 'AC9: Y1 attributed via heuristic ("Red-team package 3 ...")');
        is($attrs->[2]{blueprint}, 'bp-a', 'AC9: Y1 blueprint == bp-a');
        is($attrs->[2]{package}, '03-thing', 'AC9: Y1 package == 03-thing');
        is($attrs->[2]{source}, 'description-heuristic', 'AC9: Y1 source == description-heuristic');
        is($attrs->[2]{reason}, undef, 'AC9: Y1 reason is undef (attributed)');

        is($attrs->[3]{kind}, 'attributed', 'AC9: Y2 attributed too ("PKG 3" case-insensitive)');
        is($attrs->[3]{blueprint}, 'bp-a', 'AC9: Y2 blueprint == bp-a (case-insensitive match)');

        is($attrs->[4]{kind}, 'unattributed', 'AC9(c): no package phrase -> primary reason stands');
        is($attrs->[5]{kind}, 'unattributed', 'AC9(b): package 9 with no ledger 9 in S -> primary reason stands');
    }
};

subtest 'AC9 failure (a): two blueprints in S each hold a package 3 -> ambiguous, primary reason stands' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_ledger($root, 'bp-a', '03-thing-a');
    write_ledger($root, 'bp-b', '03-thing-b');
    my ($index, $ierr) = call_blueprint_index($root);
    ok(!$ierr, 'AC9(a): blueprint_index does not die') or diag($ierr);
    return unless $index;

    my $S = 11_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'x.jsonl', role => 'butler:bp-worker-a', first_ts => $S, description => undef },
        { path => 'y.jsonl', role => 'butler:bp-worker-b', first_ts => $S, description => undef },
        { path => 'w.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'pkg 3' },
    ] };
    my $records = [
        { id => 'x-rec', worker_type => 'bp-worker-a', started_at => $S - 5, budget => 1800, blueprint => 'bp-a', package => '03-thing-a' },
        { id => 'y-rec', worker_type => 'bp-worker-b', started_at => $S - 5, budget => 1800, blueprint => 'bp-b', package => '03-thing-b' },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => $index);
    ok(!$err, 'AC9(a): attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC9(a): unavailable', 2 unless $attrs;
        is($attrs->[3]{kind}, 'unattributed', 'AC9(a): W stays unattributed (2+ ledgers named 3 across S)');
        is($attrs->[3]{reason}, 'no-dispatch-record', 'AC9(a): the primary reason (no matching record for bp-other) is unchanged');
    }
};

subtest 'AC9 failure (d): any description at all, when S is empty (no agent primary-attributed), never attributes' => sub {
    my $S = 12_000_000;
    my $doc = { agents => [
        { path => 'main.jsonl', role => 'driver', first_ts => undef, description => undef },
        { path => 'w.jsonl', role => 'butler:bp-other', first_ts => $S, description => 'package 1' },
    ] };
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => [], index => {});
    ok(!$err, 'AC9(d): attribute_session does not die') or diag($err);
  SKIP: {
        skip 'AC9(d): unavailable', 2 unless $attrs;
        is($attrs->[1]{kind}, 'unattributed', 'AC9(d): stays unattributed when S is empty');
        is($attrs->[1]{reason}, 'no-dispatch-record', 'AC9(d): primary reason unchanged');
    }
};

# ===========================================================================
# Shared fixture builder for the report_session/CLI-level criteria (10-19):
# a session with a driver, one agent attributed via record-fields, and one
# unattributed agent (no-dispatch-record), plus its --data-root tree.
# ===========================================================================
sub build_mixed_fixture {
    my $session_dir = tempdir(CLEANUP => 1);
    my $data_root   = tempdir(CLEANUP => 1);
    my $S = 20_000_000;
    my ($main, $subdir) = session_paths($session_dir, 'sess-mixed');
    write_jsonl($main, assistant_rec(input => 100, output => 50, model => 'claude-sonnet-5', effort => 'high'));
    write_agent($subdir, 'agent-attributed', input => 40, output => 10, model => 'claude-sonnet-5', first_ts => $S,
        agent_type => 'butler:bp-worker');
    write_agent($subdir, 'agent-unattributed', input => 25, output => 5, model => 'claude-sonnet-5', first_ts => $S,
        agent_type => 'butler:bp-lonesome');
    write_ledger($data_root, 'bp-mixed', '05-thing');
    write_dispatch_record($data_root, 'bp-mixed-5-worker-19999999', worker_type => 'bp-worker',
        started_at => $S - 5, budget_seconds => 1800);
    return ($main, $data_root, $S);
}

# ===========================================================================
# AC10 (criterion 4 / DC4, B8) -- unattributed rows never fold into another.
# ===========================================================================
subtest 'AC10: an unattributed row is distinct, sums the unattributed tokens, and absorbs nothing from other rows' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    my ($doc, $err) = call_report_session(session => $main, data_root => $data_root, by => ['blueprint', 'package']);
    ok(!$err, 'AC10: report_session does not die') or diag($err);
  SKIP: {
        skip 'AC10: report_session unavailable', 4 unless $doc;
        my @unattr_rows = grep { $_->{blueprint} eq 'unattributed' && $_->{package} eq 'unattributed' } @{ $doc->{rows} };
        ok(@unattr_rows, 'AC10: at least one unattributed/unattributed row exists');
        my $unattr_tokens = 0;
        $unattr_tokens += $_->{tokens} for @unattr_rows;
        is($unattr_tokens, $doc->{attribution}{unattributed}{input} + $doc->{attribution}{unattributed}{output},
            'AC10: unattributed row tokens equal the unattributed total (input+output for this fixture)');
        my @driver_rows = grep { $_->{blueprint} eq '(driver)' && $_->{package} eq '(driver)' } @{ $doc->{rows} };
        ok(@driver_rows, 'AC10: the driver row is (driver)/(driver)');
        my @real_bp_rows = grep { $_->{blueprint} eq 'bp-mixed' } @{ $doc->{rows} };
        my $real_bp_tokens = 0;
        $real_bp_tokens += $_->{tokens} for @real_bp_rows;
        is($real_bp_tokens, 40 + 10, 'AC10: the real blueprint row carries ONLY its own agent tokens, none absorbed');
    }
};

# ===========================================================================
# AC11 (criterion 4 / DC4, B9) -- attribution coverage invariant + key sets.
# ===========================================================================
subtest 'AC11: driver+attributed+unattributed == totals per token type, reasons sum to unattributed, exact key sets' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    for my $by (['role', 'model'], ['blueprint', 'package'], ['package', 'token_type']) {
        my $label = join(',', @$by);
        my ($doc, $err) = call_report_session(session => $main, data_root => $data_root, by => $by);
        ok(!$err, "AC11 [$label]: report_session does not die") or diag($err);
      SKIP: {
            skip "AC11 [$label]: unavailable", 4 unless $doc;
            is_deeply([sort keys %{ $doc->{attribution} }], [sort qw(driver attributed unattributed reasons agents)],
                "AC11 [$label]: attribution has exactly the five keys");
            is_deeply([sort keys %{ $doc->{attribution}{reasons} }], [sort @REASONS],
                "AC11 [$label]: reasons has exactly the five reason keys");
            my $bad_maps = 0;
            for my $m (@{ $doc->{attribution} }{qw(driver attributed unattributed)}) {
                $bad_maps++ unless join(',', sort keys %$m) eq join(',', sort @TOKEN_TYPES);
            }
            for my $r (values %{ $doc->{attribution}{reasons} }) {
                $bad_maps++ unless join(',', sort keys %$r) eq join(',', sort @TOKEN_TYPES);
            }
            is($bad_maps, 0, "AC11 [$label]: driver/attributed/unattributed/each-reason maps have exactly the six token-type keys");

            my $bad_sum = 0;
            for my $t (@TOKEN_TYPES) {
                my $sum = $doc->{attribution}{driver}{$t} + $doc->{attribution}{attributed}{$t} + $doc->{attribution}{unattributed}{$t};
                $bad_sum++ unless $sum == $doc->{totals}{$t}{tokens};
                my $rsum = 0;
                $rsum += $doc->{attribution}{reasons}{$_}{$t} for @REASONS;
                $bad_sum++ unless $rsum == $doc->{attribution}{unattributed}{$t};
            }
            is($bad_sum, 0, "AC11 [$label]: driver+attributed+unattributed==totals AND reasons sum to unattributed, for all six token types");
        }
    }
};

# ===========================================================================
# AC12 (criterion 5 / DC5, B7) -- --by acceptance and rejection.
# ===========================================================================
subtest 'AC12: --by accepts any ordered subset of the six dims; default is role,model' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    for my $dim (qw(role blueprint package model effort token_type)) {
        my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', $dim, '--json');
        is($rc, 0, "AC12: --by $dim exits 0") or diag($out);
        my $doc = eval { JSON::PP->new->decode($out) };
        is_deeply($doc && $doc->{by}, [$dim], "AC12: --by $dim echoes [$dim]") if $doc;
    }
    my $full = 'token_type,effort,model,package,blueprint,role';
    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', $full, '--json');
    is($rc, 0, 'AC12: full six-dim non-canonical order exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    is_deeply($doc && $doc->{by}, [split(/,/, $full)], 'AC12: by echoes the requested order verbatim') if $doc;

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    is_deeply($doc2 && $doc2->{by}, ['role', 'model'], 'AC12: with no --by, by == ["role","model"]') if $doc2;

    for my $bad ('bogus', 'role,bogus', 'role,role', '', 'role,', ' role') {
        my ($rc3, $out3) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', $bad);
        is($rc3, 2, "AC12: --by '$bad' rejected with exit 2") or diag($out3);
        unlike($out3, qr/^\{/, "AC12: --by '$bad' produced no stdout JSON body");
        like($out3, qr/role,blueprint,package,model,effort,token_type/, "AC12: --by '$bad' error names the allowed set");
    }
};

# ===========================================================================
# AC13 (criterion 6 / DC6, B8/B9) -- rows sum exactly to totals; coverage
# summary is not a row.
# ===========================================================================
subtest 'AC13: rows[].tokens sum exactly to totals for every --by, and no row carries a coverage-summary key' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    for my $by (['role', 'model'], ['blueprint', 'package'], ['package', 'token_type']) {
        my $label = join(',', @$by);
        my ($doc, $err) = call_report_session(session => $main, data_root => $data_root, by => $by);
        ok(!$err, "AC13 [$label]: report_session does not die") or diag($err);
      SKIP: {
            skip "AC13 [$label]: unavailable", 2 unless $doc;
            if (grep { $_ eq 'token_type' } @$by) {
                my $bad = 0;
                for my $t (@TOKEN_TYPES) {
                    my $row_sum = 0;
                    $row_sum += $_->{tokens} for grep { $_->{token_type} eq $t } @{ $doc->{rows} };
                    $bad++ unless $row_sum == $doc->{totals}{$t}{tokens};
                }
                is($bad, 0, "AC13 [$label]: per-token-type row sums equal totals[<type>].tokens");
            }
            else {
                my $row_grand = 0;
                $row_grand += $_->{tokens} for @{ $doc->{rows} };
                my $totals_grand = 0;
                $totals_grand += $_->{tokens} for values %{ $doc->{totals} };
                is($row_grand, $totals_grand, "AC13 [$label]: grand row-token sum equals grand totals sum");
            }
            my $has_coverage_key = grep {
                exists $_->{driver} || exists $_->{attributed} || exists $_->{unattributed}
            } @{ $doc->{rows} };
            is($has_coverage_key, 0, "AC13 [$label]: no row carries a driver/attributed/unattributed key");
        }
    }
};

# ===========================================================================
# AC14 (criterion 7 / DC7, B12) -- read-only.
# ===========================================================================
subtest 'AC14: report-session (text and --json) leaves BOTH the session tree and the --data-root tree untouched' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    my $session_dir = (File::Spec->splitpath($main))[1];
    my $before = snapshot_tree($session_dir, $data_root);
    my ($rc1, $out1) = run_spend('report-session', '--session', $main, '--data-root', $data_root);
    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    my $after = snapshot_tree($session_dir, $data_root);
    is_deeply($after, $before, 'AC14: file list + mtime + size unchanged across a text and a --json run, both trees')
        or diag("before: " . $JSON->encode($before) . "\nafter: " . $JSON->encode($after));
    ok(!-e File::Spec->catfile($session_dir, 'runs', 'spend-derived.json'), 'AC14: no spend-derived.json created under the session tree');
    ok(!-e File::Spec->catfile($data_root, 'runs', 'spend-derived.json'), 'AC14: no spend-derived.json created under the data-root tree');
};

# ===========================================================================
# AC15 (criterion 7 / DC7, B10/B11) -- labeling, text and --json.
# ===========================================================================
subtest 'AC15: every $-digit text line self-labels; no exponent notation; --json echoes cost_basis/price_source/price_as_of' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root);
    is($rc, 0, 'AC15: text mode exits 0') or diag($out);
    my @lines = split(/\n/, $out);
    my @missing = grep { /\$\d/ && !/notional as-if-API-billed/ } @lines;
    is_deeply(\@missing, [], 'AC15: every line with $<digit> also says "notional as-if-API-billed"') or diag(join("\n", @missing));
    like($lines[0] // '', qr/notional as-if-API-billed/, 'AC15: the first line states the cost basis');
    my @exp = grep { /\$\d+(?:\.\d+)?e[-+]?\d+/i } @lines;
    is_deeply(\@exp, [], 'AC15: no dollar figure renders in exponent notation');

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    is($rc2, 0, 'AC15: --json mode exits 0') or diag($out2);
    my $doc = eval { JSON::PP->new->decode($out2) };
    ok($doc, 'AC15: --json stdout parses') or diag($out2);
  SKIP: {
        skip 'AC15: doc unavailable', 3 unless $doc;
        is($doc->{cost_basis}, 'notional-api-equivalent', 'AC15: cost_basis is the exact literal');
        is($doc->{price_source}, 'https://platform.claude.com/docs/en/about-claude/pricing', 'AC15: price_source echoed');
        is($doc->{price_as_of}, '2026-09-23', 'AC15: price_as_of echoed');
    }
};

# ===========================================================================
# AC16 (criterion 7 / DC7, §2.3) -- default --data-root resolution.
# ===========================================================================
subtest 'AC16: with no --data-root, CLAUDE_PROJECT_DIR (a synthetic tempdir) resolves to real records' => sub {
    my $R = tempdir(CLEANUP => 1);
    my $session_dir = tempdir(CLEANUP => 1);
    my $S = 30_000_000;
    my ($main, $subdir) = session_paths($session_dir, 'sess-defaultroot');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    write_agent($subdir, 'agent-1', input => 5, output => 5, first_ts => $S, agent_type => 'butler:bp-worker');

    my $data_root = File::Spec->catdir($R, '.ccpraxis-local-data');
    write_ledger($data_root, 'demo-bp', '02-thing');
    write_dispatch_record($data_root, 'demo-bp-2-worker-1234567', worker_type => 'bp-worker',
        started_at => $S - 5, budget_seconds => 1800);

    local $ENV{CLAUDE_PROJECT_DIR} = $R;
    my ($rc, $out) = run_spend('report-session', '--session', $main, '--json');
    is($rc, 0, 'AC16: exits 0 with no --data-root, CLAUDE_PROJECT_DIR set') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'AC16: --json stdout parses') or diag($out);
  SKIP: {
        skip 'AC16: doc unavailable', 2 unless $doc;
        is($doc->{data_root}, slashify($data_root), 'AC16: data_root == $R/.ccpraxis-local-data, slashified');
        my ($agent_entry) = grep { $_->{path} =~ /agent-1\.jsonl$/ } @{ $doc->{attribution}{agents} };
        ok($agent_entry && $agent_entry->{blueprint} eq 'demo-bp' && $agent_entry->{package} eq '02-thing',
            'AC16: the subagent is attributed to demo-bp/02-thing via the default-resolved root, proving real records were read')
            or diag($JSON->encode($agent_entry // {}));
    }
};

# ===========================================================================
# AC17 (criterion 8 / DC8) -- fleet-path behaviours are unaffected by the
# new verb. Package 01's oracle and the fleet oracle are their own suites'
# concern, not re-run here (tests-never-run-tests.t).
# ===========================================================================
subtest 'AC17: derive-session/derive-package fleet-path behaviours are unaffected by the new verb' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-ac17');
    write_jsonl($main, assistant_rec(input => 1, output => 1));
    my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
    is($rc, 0, 'AC17: derive-session --json still exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    is_deeply([sort keys %$doc], [sort qw(cost_basis price_source price_as_of cells totals unpriced anomaly record_counts agents)],
        'AC17: derive-session still produces package 01\'s exact nine-key document') if $doc;

    write_jsonl(File::Spec->catfile($dir, 'runs', 'pkgAC17.jsonl'),
        { type => 'system', subtype => 'init', session_id => 'sess-1', model => 'claude-sonnet-5' },
        { type => 'assistant', message => { model => 'claude-sonnet-5', id => 'm1', usage => { input_tokens => 3, output_tokens => 3, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } },
          parent_tool_use_id => undef, session_id => 'sess-1', uuid => 'u-1' });
    my ($rc2, $out2) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgAC17');
    is($rc2, 0, 'AC17: derive-package still exits 0') or diag($out2);
    ok(-f File::Spec->catfile($dir, 'runs', 'spend-derived.json'), 'AC17: derive-package still writes spend-derived.json');

    my ($rc3, $out3) = run_spend('totally-unknown-verb');
    is($rc3, 2, 'AC17: an unknown verb still exits 2') or diag($out3);

    my ($rc4, $out4) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgAC17', '--json');
    is($rc4, 2, 'AC17: derive-package --json still exits 2 (guard predates this package)') or diag($out4);

    my ($rc5, $out5) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgAC17', '--data-root', 'X');
    is($rc5, 2, 'AC17: derive-package --data-root exits 2 with the new guard\'s message') or diag($out5);

    my ($rc6, $out6) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgAC17', '--by', 'role');
    is($rc6, 2, 'AC17: derive-package --by exits 2 with the new guard\'s message') or diag($out6);
};

# ===========================================================================
# AC18 (criterion 8 / DC8, §2.6/§2.7) -- document shape + library/CLI parity.
# ===========================================================================
subtest 'AC18: --json top-level/row/attribution.agents key sets exact; library == decoded CLI --json' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    my ($doc, $err) = call_report_session(session => $main, data_root => $data_root, by => ['role', 'model']);
    ok(!$err, 'AC18: report_session does not die') or diag($err);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'role,model', '--json');
    is($rc, 0, 'AC18: CLI --json exits 0') or diag($out);
    my $cli_doc = eval { JSON::PP->new->decode($out) };
    ok($cli_doc, 'AC18: CLI --json stdout parses') or diag($out);

  SKIP: {
        skip 'AC18: report_session/CLI unavailable', 4 unless ($doc && $cli_doc);
        # data_root_source added 2026-09-23 with the session-cwd default: a
        # defaulted data root now says which rule chose it.
        is_deeply([sort keys %$doc], [sort qw(cost_basis price_source price_as_of by data_root data_root_source rows totals attribution)],
            'AC18: top-level key set is EXACTLY the eight keys of §2.7 plus data_root_source');
        is($doc->{data_root_source}, 'explicit', 'AC18: an explicit --data-root reports source explicit');
        my $bad_rows = 0;
        for my $r (@{ $doc->{rows} }) {
            $bad_rows++ unless join(',', sort keys %$r) eq join(',', sort (qw(role model tokens cost_usd unpriced_tokens)));
        }
        is($bad_rows, 0, 'AC18: every row\'s key set is exactly the selected dims plus tokens/cost_usd/unpriced_tokens');

        my ($dsdoc) = call_derive_session(session => $main);
        is(scalar(@{ $doc->{attribution}{agents} }), scalar(@{ $dsdoc->{agents} }),
            'AC18: attribution.agents has one entry per derive_session agent, same count') if $dsdoc;
        my $order_ok = 1;
        if ($dsdoc) {
            for my $i (0 .. $#{ $dsdoc->{agents} }) {
                $order_ok = 0 unless $doc->{attribution}{agents}[$i]{path} eq $dsdoc->{agents}[$i]{path};
            }
        }
        ok($order_ok, 'AC18: attribution.agents follows derive_session\'s agents order');
        my $bad_agent_keys = 0;
        for my $a (@{ $doc->{attribution}{agents} }) {
            $bad_agent_keys++ unless join(',', sort keys %$a) eq join(',', sort qw(path role kind blueprint package reason source));
        }
        is($bad_agent_keys, 0, 'AC18: every attribution.agents entry has exactly the seven keys of §2.6');

        is_deeply($doc, $cli_doc, 'AC18: BpSpend::Derive::report_session(...) is is_deeply-equal to the decoded --json document');
    }
};

# ===========================================================================
# AC19 (criterion 1/8 / DC1/DC8) -- totals equal derive_session's totals; the
# only echoed inputs are data_root/by.
# ===========================================================================
subtest 'AC19: report_session totals is_deeply-equal to derive_session totals; only data_root/by are echoed inputs' => sub {
    my ($main, $data_root) = build_mixed_fixture();
    my ($ds_doc, $ds_err)  = call_derive_session(session => $main);
    my ($rs_doc, $rs_err)  = call_report_session(session => $main, data_root => $data_root, by => ['role', 'model']);
    ok(!$ds_err, 'AC19: derive_session does not die') or diag($ds_err);
    ok(!$rs_err, 'AC19: report_session does not die') or diag($rs_err);
  SKIP: {
        skip 'AC19: unavailable', 3 unless ($ds_doc && $rs_doc);
        is_deeply($rs_doc->{totals}, $ds_doc->{totals}, 'AC19: report_session totals is_deeply-equal to derive_session totals on the SAME session');
        is($rs_doc->{data_root}, slashify($data_root), 'AC19: data_root echoes the resolved --data-root');
        is_deeply($rs_doc->{by}, ['role', 'model'], 'AC19: by echoes the requested dims');
    }
};

# ===========================================================================
# AC20 (criterion 3/8 / DC3/DC8, §2.6) -- attribute_session exercised as a
# pure function: ambiguity, window-boundary and reason-priority, no I/O.
# ===========================================================================
subtest 'AC20: attribute_session as a pure function -- ambiguity, window-boundary, reason-priority, no filesystem' => sub {
    my $doc = {
        agents => [
            { path => 'main.jsonl', role => 'driver', first_ts => 999_999, description => undef },
            { path => 'a1.jsonl', role => 'butler:bp-implementer', first_ts => 500, description => undef },   # ambiguous
            { path => 'a2.jsonl', role => 'butler:bp-implementer', first_ts => 2000, description => undef },  # outside-window
            { path => 'a3.jsonl', role => 'unknown-agent', first_ts => 100, description => undef },           # unknown-agent priority
        ],
    };
    my $records = [
        { id => 'r1', worker_type => 'bp-implementer', started_at => 400, ended_at => 600, budget => 1800, blueprint => 'bp-x', package => '01-t' },
        { id => 'r2', worker_type => 'bp-implementer', started_at => 400, ended_at => 600, budget => 1800, blueprint => 'bp-y', package => '02-t' },
        { id => 'r3', worker_type => 'bp-implementer', started_at => 1000, ended_at => 1100, budget => 1800, blueprint => 'bp-z', package => '03-t' },
    ];
    my ($attrs, $err) = call_attribute_session(doc => $doc, records => $records, index => {});
    ok(!$err, 'AC20: attribute_session does not die on plain Perl structures (no I/O)') or diag($err);
  SKIP: {
        skip 'AC20: attribute_session unavailable', 5 unless $attrs;
        is(scalar(@$attrs), 4, 'AC20: one attribution entry per agent, same count');
        is($attrs->[0]{kind}, 'driver', 'AC20: entry 0 is always the driver');
        is($attrs->[0]{blueprint}, '(driver)', 'AC20: driver blueprint == (driver)');
        is($attrs->[1]{reason}, 'ambiguous', 'AC20: a1 matched by both r1 and r2 -> ambiguous');
        is($attrs->[2]{reason}, 'outside-window', 'AC20: a2 has candidates (r1/r2/r3 all bp-implementer) but none in its window');
        is($attrs->[3]{reason}, 'unknown-agent', 'AC20: a3\'s unknown-agent role takes priority over any record matching');
    }
};

done_testing();
