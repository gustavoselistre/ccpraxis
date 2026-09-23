#!/usr/bin/env perl
# platform: any
# Oracle for blueprint fleet-cost-accounting,
# package 01-spend-is-recorded.
#
# Tests the new `derive-package` / `derive-blueprint` verbs on bp-spend.pl,
# which read a package's existing `runs/<pkg>.jsonl` coordinator transcript
# directly (no external provider, no network, no credential) and produce a
# token/cost figure split coordinator-vs-subagent, plus a named cache-write
# anomaly report. Spec: specs/01-spend-is-recorded-spec.md.
#
# Fixture record shapes are grounded in the real archived transcript at
# .ccpraxis-local-data/blueprints/_archive/sandbox-butler-overhaul/runs/
# b04-dependency-version-governance.jsonl (assistant.message.usage,
# system/task_progress.usage, result.usage/modelUsage all mirror that file's
# actual field names).
#
# THIS FILE IS THE PACKAGE'S IMMUTABLE ORACLE. Only bp-spend.pl may change to
# make these pass.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
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

sub slurp_raw {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw;
}

# Writes a runs/<pkg>.jsonl fixture. @lines entries that are refs get JSON
# encoded; plain scalars are written verbatim (used for injecting malformed
# JSON lines for AC7).
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

sub runs_path {
    my ($dir, $pkg) = @_;
    return File::Spec->catfile($dir, 'runs', "$pkg.jsonl");
}

sub derived_path {
    my ($dir) = @_;
    return File::Spec->catfile($dir, 'runs', 'spend-derived.json');
}

# --- fixture record builders, mirroring the b04 archived shapes exactly ----

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

sub assistant_rec {
    my (%o) = @_;
    my %usage = (
        input_tokens               => $o{input} // 0,
        output_tokens              => $o{output} // 0,
        cache_creation_input_tokens => $o{cache_creation} // 0,
        cache_read_input_tokens    => $o{cache_read} // 0,
    );
    my $rec = {
        type    => 'assistant',
        message => {
            model => $o{model} // 'claude-sonnet-5',
            id    => $o{id} // ('msg_' . int(rand(1e9))),
            type  => 'message',
            role  => 'assistant',
            content => [ { type => 'text', text => 'x' } ],
            usage   => \%usage,
        },
        parent_tool_use_id => $o{parent},
        session_id         => $o{session} // 'sess-1',
        uuid               => $o{uuid} // ('u-' . int(rand(1e9))),
        timestamp          => $o{timestamp} // '2026-09-19T00:00:00.000Z',
    };
    $rec->{subagent_type} = $o{subagent_type} if defined $o{subagent_type};
    return $rec;
}

sub sys_task_progress {
    my (%o) = @_;
    return {
        type       => 'system',
        subtype    => 'task_progress',
        task_id    => $o{task_id} // 'task-1',
        session_id => $o{session} // 'sess-1',
        usage      => { total_tokens => $o{total_tokens} // 0, tool_uses => 1, duration_ms => 1000 },
        uuid       => 'u-tp-' . int(rand(1e9)),
    };
}

sub result_rec {
    my (%o) = @_;
    return {
        type            => 'result',
        is_error        => JSON::PP::false,
        session_id      => $o{session} // 'sess-1',
        total_cost_usd  => $o{total_cost_usd} // 0,
        usage           => {
            input_tokens               => $o{input} // 0,
            output_tokens              => $o{output} // 0,
            cache_read_input_tokens    => $o{cache_read} // 0,
            cache_creation_input_tokens => $o{cache_creation} // 0,
            modelUsage => $o{model_usage} // {},
        },
        uuid => 'u-result-' . int(rand(1e9)),
    };
}

sub coord_tokens_from {
    # Sum a list of assistant_rec-shaped hashrefs by role, for hand-computed
    # oracles independent of the tool under test.
    my (@recs) = @_;
    my %tot = (
        coordinator => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
        subagent    => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
    );
    for my $r (@recs) {
        my $role = defined($r->{parent_tool_use_id}) ? 'subagent' : 'coordinator';
        my $u = $r->{message}{usage};
        $tot{$role}{input}          += $u->{input_tokens}               // 0;
        $tot{$role}{output}         += $u->{output_tokens}              // 0;
        $tot{$role}{cache_creation} += $u->{cache_creation_input_tokens} // 0;
        $tot{$role}{cache_read}     += $u->{cache_read_input_tokens}    // 0;
    }
    return \%tot;
}

sub tokens_match {
    my ($got, $want, $label) = @_;
    is($got->{coordinator}{input},          $want->{coordinator}{input},          "$label: coordinator.input");
    is($got->{coordinator}{output},         $want->{coordinator}{output},         "$label: coordinator.output");
    is($got->{coordinator}{cache_creation}, $want->{coordinator}{cache_creation}, "$label: coordinator.cache_creation");
    is($got->{coordinator}{cache_read},     $want->{coordinator}{cache_read},     "$label: coordinator.cache_read");
    is($got->{subagent}{input},          $want->{subagent}{input},          "$label: subagent.input");
    is($got->{subagent}{output},         $want->{subagent}{output},         "$label: subagent.output");
    is($got->{subagent}{cache_creation}, $want->{subagent}{cache_creation}, "$label: subagent.cache_creation");
    is($got->{subagent}{cache_read},     $want->{subagent}{cache_read},     "$label: subagent.cache_read");
}

sub json_truthy {
    my ($v) = @_;
    return 0 unless defined $v;
    return 1 if "$v" eq '1';
    return 1 if ref($v) eq 'JSON::PP::Boolean' && $v;
    return 0;
}

# ===========================================================================
# AC1 -- derive-package: non-zero tokens matching a hand-computed sum, exit 0.
# ===========================================================================
subtest 'AC1: derive-package sums a real fixture and exits 0' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @recs = (
        sys_init(session => 'sess-1'),
        assistant_rec(session => 'sess-1', parent => undef, model => 'claude-opus-5',
            input => 100, output => 50, cache_creation => 200, cache_read => 10),
        assistant_rec(session => 'sess-1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
            model => 'claude-haiku-4-5-20251001',
            input => 20, output => 5, cache_creation => 30, cache_read => 2),
    );
    write_jsonl(runs_path($dir, 'pkgA'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgA');
    is($rc, 0, 'AC1: exits 0') or diag($out);

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC1: spend-derived.json parses as JSON') or diag(slurp_raw(derived_path($dir)) // '<missing>');

  SKIP: {
        skip 'AC1: no written doc to inspect', 9 unless $doc;
        my $want = coord_tokens_from(grep { $_->{type} eq 'assistant' } @recs);
        ok($want->{coordinator}{input} > 0 || $want->{subagent}{input} > 0, 'AC1: sanity -- fixture is non-trivial');
        tokens_match($doc->{tokens}, $want, 'AC1');
        is(scalar(@{ $doc->{packages} // [] }), 1, 'AC1: packages[] has exactly the one requested package');
    }
};

# ===========================================================================
# AC2 (Decision 1) -- system.usage and result.usage are NOT summed in.
# ===========================================================================
subtest 'AC2: assistant.message.usage summed ONLY -- system/result usage excluded' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $assistant = assistant_rec(session => 'sess-1', parent => undef, model => 'claude-sonnet-5',
        input => 11, output => 22, cache_creation => 33, cache_read => 44);
    my @recs = (
        sys_init(session => 'sess-1'),
        $assistant,
        # a huge running counter -- would grossly inflate the sum if wrongly added
        sys_task_progress(session => 'sess-1', total_tokens => 999999),
        # a whole-session summary -- would double-count if wrongly added
        result_rec(session => 'sess-1', total_cost_usd => 1.23,
            input => 55555, output => 66666, cache_read => 77777, cache_creation => 88888,
            model_usage => { 'claude-sonnet-5' => { inputTokens => 55555, outputTokens => 66666,
                cacheReadInputTokens => 77777, cacheCreationInputTokens => 88888, costUSD => 1.23 } }),
    );
    write_jsonl(runs_path($dir, 'pkgB'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgB');
    is($rc, 0, 'AC2: exits 0') or diag($out);

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC2: spend-derived.json parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');

  SKIP: {
        skip 'AC2: no written doc to inspect', 10 unless $doc;
        my $want = coord_tokens_from($assistant);
        tokens_match($doc->{tokens}, $want, 'AC2');

        my $sum = $doc->{tokens}{coordinator}{input} + $doc->{tokens}{subagent}{input};
        isnt($sum, 11 + 999999, 'AC2: total is NOT inflated by system.usage.total_tokens');
        isnt($sum, 11 + 55555,  'AC2: total is NOT inflated by result.usage.input_tokens');

        # cross_check may independently reflect the result record (audit only,
        # never blended into tokens/by_model -- see spec 2.2).
        if (ref($doc->{cross_check}) eq 'HASH' && $doc->{cross_check}{seen}) {
            is($doc->{cross_check}{total_cost_usd}, 1.23, 'AC2: cross_check captures result.total_cost_usd verbatim (audit only)');
        }
    }
};

# ===========================================================================
# AC3 -- coordinator and subagent spend reported separately, never merged.
# ===========================================================================
subtest 'AC3: coordinator and subagent tokens are split, not merged' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $coord = assistant_rec(session => 'sess-1', parent => undef,
        input => 7, output => 3, cache_creation => 0, cache_read => 0);
    my $sub = assistant_rec(session => 'sess-1', parent => 'toolu_x', subagent_type => 'butler:bp-scout',
        input => 11, output => 13, cache_creation => 0, cache_read => 0);
    write_jsonl(runs_path($dir, 'pkgC'), sys_init(session => 'sess-1'), $coord, $sub);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgC');
    is($rc, 0, 'AC3: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC3: doc parses');

  SKIP: {
        skip 'AC3: no doc', 4 unless $doc;
        is($doc->{tokens}{coordinator}{input},  7,  'AC3: coordinator.input == first record only');
        is($doc->{tokens}{coordinator}{output}, 3,  'AC3: coordinator.output == first record only');
        is($doc->{tokens}{subagent}{input},  11, 'AC3: subagent.input == second record only');
        is($doc->{tokens}{subagent}{output}, 13, 'AC3: subagent.output == second record only');
    }
};

# ---------------------------------------------------------------------------
# AC3 companion: a realistically-shaped 80-95% / 5-16% split. The spec is
# explicit that NO threshold/percentage is asserted (2.3) -- these numbers
# are hand-picked to fall in that real-world band, and we assert only the
# exact hand-computed token totals, never a ratio.
# ---------------------------------------------------------------------------
subtest 'AC3 companion: realistically-shaped coordinator/subagent split' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $coord = assistant_rec(session => 'sess-1', parent => undef, model => 'claude-opus-5',
        input => 800, output => 400, cache_creation => 8000, cache_read => 1000);
    my $sub = assistant_rec(session => 'sess-1', parent => 'toolu_split', subagent_type => 'butler:bp-scout',
        model => 'claude-haiku-4-5-20251001',
        input => 100, output => 50, cache_creation => 900, cache_read => 150);
    write_jsonl(runs_path($dir, 'pkgSplit'), sys_init(session => 'sess-1'), $coord, $sub);

    my $coord_total = 800 + 400 + 8000 + 1000;   # 10200
    my $sub_total   = 100 + 50 + 900 + 150;      # 1200
    my $ratio = $sub_total / ($coord_total + $sub_total);
    ok($ratio >= 0.05 && $ratio <= 0.16, 'sanity: fixture subagent share falls in the 5-16% band')
        or diag("ratio=$ratio");

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgSplit');
    is($rc, 0, 'split fixture: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'split fixture: doc parses');

  SKIP: {
        skip 'split fixture: no doc', 8 unless $doc;
        my $want = coord_tokens_from($coord, $sub);
        tokens_match($doc->{tokens}, $want, 'split');
    }
};

# ===========================================================================
# AC4 (Decision 5) -- consecutive same-size cache-write anomaly.
# ===========================================================================
subtest 'AC4: two consecutive same-size (>0) cache writes -> one anomaly pair' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = assistant_rec(session => 's1', parent => undef, cache_creation => 359225, uuid => 'u-a');
    my $b = assistant_rec(session => 's1', parent => undef, cache_creation => 359225, uuid => 'u-b');
    write_jsonl(runs_path($dir, 'pkgD'), sys_init(session => 's1'), $a, $b);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgD');
    is($rc, 0, 'AC4 positive: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC4 positive: doc parses');

  SKIP: {
        skip 'AC4 positive: no doc', 3 unless $doc;
        is($doc->{anomaly}{name}, 'consecutive-same-size-cache-write', 'AC4: anomaly is named');
        is($doc->{anomaly}{count}, 1, 'AC4: one pair detected');
        is($doc->{anomaly}{total_tokens}, 359225, 'AC4: total_tokens == the shared size');
    }
};

subtest 'AC4 negative: no consecutive same-size writes -> zero anomalies' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = assistant_rec(session => 's1', parent => undef, cache_creation => 100, uuid => 'u-a');
    my $b = assistant_rec(session => 's1', parent => undef, cache_creation => 200, uuid => 'u-b');
    my $c = assistant_rec(session => 's1', parent => undef, cache_creation => 300, uuid => 'u-c');
    write_jsonl(runs_path($dir, 'pkgE'), sys_init(session => 's1'), $a, $b, $c);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgE');
    is($rc, 0, 'AC4 negative: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC4 negative: doc parses');

  SKIP: {
        skip 'AC4 negative: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 0, 'AC4 negative: zero pairs');
        is($doc->{anomaly}{total_tokens}, 0, 'AC4 negative: zero total_tokens');
    }
};

subtest 'AC4 detail: three consecutive equal writes yield TWO adjacent pairs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @recs = (
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'u-1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'u-2'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'u-3'),
    );
    write_jsonl(runs_path($dir, 'pkgF'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgF');
    is($rc, 0, 'AC4 detail: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
  SKIP: {
        skip 'AC4 detail: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 2, 'AC4 detail: A=B=C yields 2 pairs (A-B, B-C), not 1');
        is($doc->{anomaly}{total_tokens}, 1000, 'AC4 detail: total_tokens == 2 * shared size (one instance per pair)');
    }
};

subtest 'AC4 detail: a zero-size cache write does not reset comparison' => sub {
    # A(100) -> B(0, skipped) -> C(100): B does not participate as either
    # half of a pair, so A and C are still compared as consecutive >0 writes.
    my $dir = tempdir(CLEANUP => 1);
    my @recs = (
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 100, uuid => 'u-a'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 0,   uuid => 'u-b'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 100, uuid => 'u-c'),
    );
    write_jsonl(runs_path($dir, 'pkgG'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgG');
    is($rc, 0, 'AC4 zero-skip: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
  SKIP: {
        skip 'AC4 zero-skip: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 1, 'AC4 zero-skip: a 0-write in between does not break the A/C comparison');
        is($doc->{anomaly}{total_tokens}, 100, 'AC4 zero-skip: total_tokens == the shared size');
    }
};

subtest 'anomaly never spans a session_id boundary' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @recs = (
        sys_init(session => 'sess-A'),
        assistant_rec(session => 'sess-A', parent => undef, cache_creation => 777, uuid => 'u-a'),
        sys_init(session => 'sess-B'),
        assistant_rec(session => 'sess-B', parent => undef, cache_creation => 777, uuid => 'u-b'),
    );
    write_jsonl(runs_path($dir, 'pkgH'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgH');
    is($rc, 0, 'session boundary: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
  SKIP: {
        skip 'session boundary: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 0, 'session boundary: a resumed package (2nd session_id) is NOT treated as adjacent');
        is($doc->{anomaly}{total_tokens}, 0, 'session boundary: zero total_tokens across the boundary');
    }
};

# ===========================================================================
# AC5 -- derived figure with no external provider configured; distinguishable
# from the existing billed/provider path.
# ===========================================================================
subtest 'AC5: derive-package works with no credentials/network, marks derived=>1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'pkgI'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 5, output => 5));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgI');
    is($rc, 0, 'AC5: succeeds with no credential env vars set and no http seam') or diag($out);

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC5: doc parses');
  SKIP: {
        skip 'AC5: no doc', 2 unless $doc;
        ok(json_truthy($doc->{derived}), 'AC5: top-level derived is JSON-truthy');
        ok(json_truthy($doc->{packages}[0]{derived}), 'AC5: per-package derived is JSON-truthy too');
    }
};

subtest 'AC5 companion: existing snapshot --offline path is distinguishable (no derived key)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($rc, $out) = run_spend('snapshot', '--run-dir', $dir, '--offline', '--now', 1787000000);
    is($rc, 0, 'AC5 companion: snapshot --offline exits 0') or diag($out);

    my $snap = slurp_json(File::Spec->catfile($dir, 'spend.json'));
    ok($snap, 'AC5 companion: spend.json parses');
  SKIP: {
        skip 'AC5 companion: no snapshot', 3 unless $snap;
        ok(!exists $snap->{derived}, 'AC5 companion: the billed/provider snapshot carries NO derived key');
        ok(ref($snap->{results}) eq 'ARRAY' && @{ $snap->{results} }, 'AC5 companion: results[] is populated');
        my ($has_absent) = grep { ref($_) eq 'HASH' && ($_->{status} // '') eq 'absent' } @{ $snap->{results} };
        ok($has_absent, 'AC5 companion: --offline still reports provider status=>absent, the billed shape');
    }
};

# ===========================================================================
# AC6 -- derive-blueprint sums per-package results additively.
# ===========================================================================
subtest 'AC6: derive-blueprint == field-wise sum of independent per-package results' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a1 = assistant_rec(session => 'sX', parent => undef, input => 10, output => 20, cache_creation => 30, cache_read => 40);
    my $a2 = assistant_rec(session => 'sX', parent => 'toolu_y', input => 1, output => 2, cache_creation => 3, cache_read => 4);
    write_jsonl(runs_path($dir, 'pkgJ1'), sys_init(session => 'sX'), $a1, $a2);

    my $b1 = assistant_rec(session => 'sY', parent => undef, input => 100, output => 200, cache_creation => 300, cache_read => 400);
    my $b2 = assistant_rec(session => 'sY', parent => 'toolu_z', input => 5, output => 6, cache_creation => 7, cache_read => 8);
    write_jsonl(runs_path($dir, 'pkgJ2'), sys_init(session => 'sY'), $b1, $b2);

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'AC6: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC6: doc parses');

  SKIP: {
        skip 'AC6: no doc', 3 unless $doc;
        my $want = coord_tokens_from($a1, $a2, $b1, $b2);
        tokens_match($doc->{tokens}, $want, 'AC6');
        is(scalar(@{ $doc->{packages} }), 2, 'AC6: packages[] has one entry per fixture file');
        ok(json_truthy($doc->{derived}), 'AC6: top-level derived is truthy');
    }
};

# ===========================================================================
# AC7 -- a malformed line is skipped, not fatal; valid records still summed.
# ===========================================================================
subtest 'AC7: an unparseable line is skipped, not fatal' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $good = assistant_rec(session => 's1', parent => undef, input => 9, output => 9, cache_creation => 9, cache_read => 9);
    write_jsonl(runs_path($dir, 'pkgK'),
        sys_init(session => 's1'),
        '{this is not valid json,,,',
        $good,
    );

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgK');
    is($rc, 0, 'AC7: still exits 0 despite a malformed line') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'AC7: doc parses');

  SKIP: {
        skip 'AC7: no doc', 3 unless $doc;
        ok($doc->{packages}[0]{record_counts}{skipped_unparseable} >= 1,
            'AC7: skipped_unparseable counts the bad line');
        is($doc->{tokens}{coordinator}{input}, 9, 'AC7: the valid record is still summed correctly');
        is($doc->{tokens}{coordinator}{output}, 9, 'AC7: the valid record is still summed correctly (output)');
    }
};

# ===========================================================================
# AC8 -- derive-* never touches an existing spend.json (isolation).
# ===========================================================================
subtest 'AC8: derive-* leaves a pre-existing spend.json byte-identical' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($rc0, $out0) = run_spend('snapshot', '--run-dir', $dir, '--offline', '--now', 1787000000);
    is($rc0, 0, 'AC8 setup: snapshot writes spend.json first') or diag($out0);
    my $spend_json_path = File::Spec->catfile($dir, 'spend.json');
    my $before = slurp_raw($spend_json_path);
    ok(defined $before, 'AC8 setup: spend.json exists before derive-*') or return;

    write_jsonl(runs_path($dir, 'pkgL'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 1, output => 1));

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'AC8: derive-blueprint exits 0') or diag($out);

    my $after = slurp_raw($spend_json_path);
    is($after, $before, 'AC8: pre-existing spend.json is byte-identical after running derive-*');
};

# ===========================================================================
# Edge cases named in the spec (§6) but not already covered above.
# ===========================================================================

subtest 'edge: zero assistant records -> status=>empty, distinct from no-file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'pkgM'), sys_init(session => 's1'));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgM');
    is($rc, 0, 'edge empty: exits 0 (not a caller error)') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'edge empty: doc parses');

  SKIP: {
        skip 'edge empty: no doc', 5 unless $doc;
        is($doc->{packages}[0]{status}, 'empty', 'edge empty: status is "empty"');
        is($doc->{tokens}{coordinator}{input}, 0, 'edge empty: coordinator totals are zero');
        is($doc->{tokens}{subagent}{input}, 0, 'edge empty: subagent totals are zero');
        ok(json_truthy($doc->{derived}), 'edge empty: still marked derived');
    }
};

subtest 'edge: derive-package on a missing file exits 4 and writes nothing new' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($dir, 'runs'));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'ghost-pkg');
    is($rc, 4, 'edge no-file: exits 4 for a specifically-requested missing package') or diag($out);
    ok(!-f derived_path($dir), 'edge no-file: no spend-derived.json is created from scratch');
};

subtest 'edge: derive-package missing-file leaves an EXISTING spend-derived.json untouched' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'pkgN'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 3, output => 3));
    my ($rc1, $out1) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgN');
    is($rc1, 0, 'edge untouched: setup call succeeds') or diag($out1);
    my $before = slurp_raw(derived_path($dir));
    ok(defined $before, 'edge untouched: spend-derived.json exists after the successful call') or return;

    my ($rc2, $out2) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'ghost-pkg-2');
    is($rc2, 4, 'edge untouched: the missing-package call exits 4') or diag($out2);
    my $after = slurp_raw(derived_path($dir));
    is($after, $before, 'edge untouched: the prior successful spend-derived.json is left byte-identical');
};

subtest 'edge: derive-blueprint on a runs/ dir with zero jsonl files exits 0, packages=>[]' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($dir, 'runs'));

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'edge fresh blueprint: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'edge fresh blueprint: doc parses');

  SKIP: {
        skip 'edge fresh blueprint: no doc', 4 unless $doc;
        is_deeply($doc->{packages}, [], 'edge fresh blueprint: packages=>[]');
        is($doc->{tokens}{coordinator}{input}, 0, 'edge fresh blueprint: all-zero coordinator tokens');
        is($doc->{tokens}{subagent}{input}, 0, 'edge fresh blueprint: all-zero subagent tokens');
        ok(json_truthy($doc->{derived}), 'edge fresh blueprint: still marked derived=>1');
    }
};

subtest 'edge: a model missing message.model buckets under by_model.unknown, does not crash' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $rec = assistant_rec(session => 's1', parent => undef, input => 4, output => 4);
    delete $rec->{message}{model};
    write_jsonl(runs_path($dir, 'pkgO'), sys_init(session => 's1'), $rec);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgO');
    is($rc, 0, 'edge no-model: does not crash on a missing message.model') or diag($out);
    my $doc = slurp_json(derived_path($dir));
  SKIP: {
        skip 'edge no-model: no doc', 2 unless $doc;
        ok(exists $doc->{packages}[0]{by_model}{unknown}, 'edge no-model: bucketed under by_model.unknown');
        is($doc->{tokens}{coordinator}{input}, 4, 'edge no-model: the record still contributes to tokens.coordinator');
    }
};

subtest 'edge: a partial usage hash (missing sub-fields) treats them as zero, not fatal' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $rec = {
        type    => 'assistant',
        message => {
            model => 'claude-sonnet-5', id => 'msg_partial', type => 'message', role => 'assistant',
            content => [ { type => 'text', text => 'x' } ],
            usage   => { input_tokens => 42 },   # output/cache_* fields absent entirely
        },
        parent_tool_use_id => undef,
        session_id         => 's1',
        uuid               => 'u-partial',
    };
    write_jsonl(runs_path($dir, 'pkgP'), sys_init(session => 's1'), $rec);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgP');
    is($rc, 0, 'edge partial usage: does not crash on missing usage sub-fields') or diag($out);
    my $doc = slurp_json(derived_path($dir));
  SKIP: {
        skip 'edge partial usage: no doc', 2 unless $doc;
        is($doc->{tokens}{coordinator}{input}, 42, 'edge partial usage: present field is summed');
        is($doc->{tokens}{coordinator}{output}, 0, 'edge partial usage: absent field defaults to zero, not fatal');
    }
};

# ===========================================================================
# Fix-batch M1 -- --pkg is validated before use, rejecting traversal.
# ===========================================================================
subtest 'M1: a --pkg with path-traversal characters is rejected, not resolved' => sub {
    my $dir = tempdir(CLEANUP => 1);
    # A sibling "blueprint" with its own runs/ dir and a transcript that would
    # get summed in if --pkg were used unsanitized to build the read path.
    my $victim_dir = File::Spec->catdir($dir, 'other-blueprint');
    write_jsonl(File::Spec->catfile($victim_dir, 'runs', 'other-pkg.jsonl'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 999, output => 999));
    make_path(File::Spec->catdir($dir, 'runs'));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir,
        '--pkg', '../other-blueprint/runs/other-pkg');
    isnt($rc, 0, 'M1: a traversal-shaped --pkg is rejected (non-zero exit)') or diag($out);
    ok(!-f derived_path($dir), 'M1: no spend-derived.json is written for a rejected --pkg');
};

subtest 'M1 companion: an ordinary bare-alnum --pkg is still accepted' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'pkgQ'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 1, output => 1));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgQ');
    is($rc, 0, 'M1 companion: a valid --pkg still exits 0') or diag($out);
    ok(-f derived_path($dir), 'M1 companion: a valid --pkg still writes spend-derived.json');
};

# ===========================================================================
# Fix-batch M2 -- anomaly detector scoped by (session_id, role), not
# session_id alone, so interleaved coordinator/subagent turns are never
# compared against each other.
# ===========================================================================
subtest 'M2: an interleaved subagent write no longer masks a real coordinator duplicate' => sub {
    my $dir = tempdir(CLEANUP => 1);
    # coordinator(500) -> subagent(500, different branch) -> coordinator(500)
    # again: session-only scoping would let the subagent's write "reset" the
    # tracked previous value, hiding the real coordinator duplicate (500 ==
    # 500 across the two coordinator turns). Role-scoping must still catch it.
    my @recs = (
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'coord-1'),
        assistant_rec(session => 's1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
            cache_creation => 500, uuid => 'sub-1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'coord-2'),
    );
    write_jsonl(runs_path($dir, 'pkgR'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgR');
    is($rc, 0, 'M2 false-negative case: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'M2 false-negative case: doc parses');

  SKIP: {
        skip 'M2 false-negative case: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 1,
            'M2: the real coordinator-coordinator duplicate is still caught despite the interleaved subagent write');
        is($doc->{anomaly}{total_tokens}, 500, 'M2: total_tokens reflects only the genuine same-role pair');
    }
};

subtest 'M2 companion: a coincidental same-size write across roles is NOT flagged' => sub {
    my $dir = tempdir(CLEANUP => 1);
    # coordinator(500) immediately followed by an unrelated subagent(500):
    # session-only scoping would flag this pair; role-scoping must not.
    my @recs = (
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, cache_creation => 500, uuid => 'coord-1'),
        assistant_rec(session => 's1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
            cache_creation => 500, uuid => 'sub-1'),
    );
    write_jsonl(runs_path($dir, 'pkgS'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgS');
    is($rc, 0, 'M2 false-positive case: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'M2 false-positive case: doc parses');

  SKIP: {
        skip 'M2 false-positive case: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 0,
            'M2: a coincidental same-size write from a DIFFERENT role is not flagged as a duplicate');
        is($doc->{anomaly}{total_tokens}, 0, 'M2: zero total_tokens for the coincidental cross-role pair');
    }
};

subtest 'M2 companion: a real same-role duplicate is still caught (no false loss of coverage)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my @recs = (
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
            cache_creation => 700, uuid => 'sub-1'),
        assistant_rec(session => 's1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
            cache_creation => 700, uuid => 'sub-2'),
    );
    write_jsonl(runs_path($dir, 'pkgT'), @recs);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgT');
    is($rc, 0, 'M2 same-role duplicate: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'M2 same-role duplicate: doc parses');

  SKIP: {
        skip 'M2 same-role duplicate: no doc', 2 unless $doc;
        is($doc->{anomaly}{count}, 1, 'M2: a genuine same-role (subagent-subagent) duplicate is still detected');
        is($doc->{anomaly}{total_tokens}, 700, 'M2: total_tokens reflects the genuine subagent duplicate');
    }
};

# ===========================================================================
# Fix-batch M3 -- malformed/negative numeric usage fields are surfaced, not
# silently absorbed into (or silently subtracted from) the reported total.
# ===========================================================================
subtest 'M3: a negative usage field is not summed and is counted as malformed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $rec = {
        type    => 'assistant',
        message => {
            model => 'claude-sonnet-5', id => 'msg_neg', type => 'message', role => 'assistant',
            content => [ { type => 'text', text => 'x' } ],
            usage   => { input_tokens => 10, output_tokens => 10,
                         cache_creation_input_tokens => -50000, cache_read_input_tokens => 0 },
        },
        parent_tool_use_id => undef,
        session_id         => 's1',
        uuid               => 'u-neg',
    };
    write_jsonl(runs_path($dir, 'pkgU'), sys_init(session => 's1'), $rec);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgU');
    is($rc, 0, 'M3 negative: exits 0 (a malformed field is surfaced, not fatal)') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'M3 negative: doc parses');

  SKIP: {
        skip 'M3 negative: no doc', 4 unless $doc;
        is($doc->{tokens}{coordinator}{cache_creation}, 0,
            'M3: a negative cache_creation_input_tokens is NOT summed in (would otherwise silently lower the total)');
        is($doc->{tokens}{coordinator}{input}, 10, 'M3: the other, well-formed fields on the same record still sum normally');
        ok($doc->{packages}[0]{record_counts}{malformed_usage_field} >= 1,
            'M3: the negative field is counted in record_counts.malformed_usage_field');
        is($doc->{anomaly}{count}, 0, 'M3: a malformed cache_creation value never participates in anomaly tracking');
    }
};

subtest 'M3 companion: a non-numeric usage field is not summed and is counted as malformed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $rec = {
        type    => 'assistant',
        message => {
            model => 'claude-sonnet-5', id => 'msg_str', type => 'message', role => 'assistant',
            content => [ { type => 'text', text => 'x' } ],
            usage   => { input_tokens => 'lots', output_tokens => 20,
                         cache_creation_input_tokens => 0, cache_read_input_tokens => 0 },
        },
        parent_tool_use_id => undef,
        session_id         => 's1',
        uuid               => 'u-str',
    };
    write_jsonl(runs_path($dir, 'pkgV'), sys_init(session => 's1'), $rec);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgV');
    is($rc, 0, 'M3 non-numeric: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'M3 non-numeric: doc parses');

  SKIP: {
        skip 'M3 non-numeric: no doc', 3 unless $doc;
        is($doc->{tokens}{coordinator}{input}, 0,
            'M3: a non-numeric input_tokens value is NOT summed in (treated as absent, not as a crash or a silent number)');
        is($doc->{tokens}{coordinator}{output}, 20, 'M3: the other, well-formed field on the same record still sums normally');
        ok($doc->{packages}[0]{record_counts}{malformed_usage_field} >= 1,
            'M3 non-numeric: counted in record_counts.malformed_usage_field');
    }
};

# ===========================================================================
# Reviewer should-fix #2 -- derive_blueprint's spend.jsonl (reserved,
# singular) exclusion actually fires, not merely dead code that compiles.
# ===========================================================================
subtest "reviewer #2: a literal spend.jsonl in runs/ is excluded from derive-blueprint's scan" => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'pkgW'),
        sys_init(session => 's1'),
        assistant_rec(session => 's1', parent => undef, input => 6, output => 6));
    # A file literally named spend.jsonl (the reserved name, spec §2.1) sitting
    # right next to a real package transcript in the same runs/ dir.
    write_jsonl(File::Spec->catfile($dir, 'runs', 'spend.jsonl'),
        sys_init(session => 's-reserved'),
        assistant_rec(session => 's-reserved', parent => undef, input => 777777, output => 777777));

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'reviewer #2: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'reviewer #2: doc parses');

  SKIP: {
        skip 'reviewer #2: no doc', 3 unless $doc;
        is(scalar(@{ $doc->{packages} }), 1,
            'reviewer #2: packages[] contains ONLY pkgW -- spend.jsonl is excluded from the scan, not just from the sum');
        is($doc->{packages}[0]{pkg}, 'pkgW', 'reviewer #2: the one included package is the real one, not spend');
        is($doc->{tokens}{coordinator}{input}, 6,
            'reviewer #2: the reserved file never contributes tokens (would be 777783 if it were included)');
    }
};

# ===========================================================================
# Reviewer should-fix #3 -- by_model role=>'mixed' behavior (spec §2.3),
# both package- and blueprint-level.
# ===========================================================================
subtest 'reviewer #3: by_model flips to role=>mixed when a model appears under both roles (package-level)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $coord = assistant_rec(session => 's1', parent => undef, model => 'claude-sonnet-5',
        input => 10, output => 10, cache_creation => 0, cache_read => 0);
    my $sub = assistant_rec(session => 's1', parent => 'toolu_1', subagent_type => 'butler:bp-scout',
        model => 'claude-sonnet-5', input => 5, output => 5, cache_creation => 0, cache_read => 0);
    write_jsonl(runs_path($dir, 'pkgX'), sys_init(session => 's1'), $coord, $sub);

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'pkgX');
    is($rc, 0, 'reviewer #3 package: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'reviewer #3 package: doc parses');

  SKIP: {
        skip 'reviewer #3 package: no doc', 3 unless $doc;
        my $pkg_result = $doc->{packages}[0];
        is($pkg_result->{by_model}{'claude-sonnet-5'}{role}, 'mixed',
            'reviewer #3: same model under both coordinator and subagent flips role to mixed (package-level)');
        is($pkg_result->{by_model}{'claude-sonnet-5'}{input}, 15,
            'reviewer #3: the mixed bucket still sums both roles contributions together');
        is($doc->{by_model}{'claude-sonnet-5'}{role}, 'mixed',
            'reviewer #3: mixed propagates to the blueprint-level by_model too');
    }
};

subtest 'reviewer #3 companion: two packages disagreeing on a shared model role -> mixed at blueprint level' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $coord_only = assistant_rec(session => 's1', parent => undef, model => 'claude-opus-5',
        input => 20, output => 20, cache_creation => 0, cache_read => 0);
    write_jsonl(runs_path($dir, 'pkgY1'), sys_init(session => 's1'), $coord_only);

    my $sub_only = assistant_rec(session => 's2', parent => 'toolu_2', subagent_type => 'butler:bp-scout',
        model => 'claude-opus-5', input => 3, output => 3, cache_creation => 0, cache_read => 0);
    write_jsonl(runs_path($dir, 'pkgY2'), sys_init(session => 's2'), $sub_only);

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'reviewer #3 blueprint: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'reviewer #3 blueprint: doc parses');

  SKIP: {
        skip 'reviewer #3 blueprint: no doc', 2 unless $doc;
        is($doc->{by_model}{'claude-opus-5'}{role}, 'mixed',
            'reviewer #3: a model coordinator-only in one package and subagent-only in another is mixed at blueprint level');
        is($doc->{by_model}{'claude-opus-5'}{input}, 23,
            'reviewer #3: the blueprint-level mixed bucket sums across both packages');
    }
};

done_testing();
