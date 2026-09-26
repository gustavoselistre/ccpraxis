#!/usr/bin/env perl
# platform: any
# Oracle for blueprint spend-token-report, package
# 02-derive-cost-and-time-window (DC1): derive-package/derive-blueprint fetch
# fresh pricing exactly once per CLI run (Decision 25, 26a, 27.1) and store
# the stamped api_equivalent_cost_usd/price_source/price_fetched_at/
# pricing_status next to the self-reported cross_check.total_cost_usd,
# recomputed on every derive and never read back as a rate. Spec:
# specs/02-derive-cost-and-time-window-spec.md SS4.1.
#
# This file sets CCPRAXIS_SPEND_NO_FETCH=1 at file scope (Decision 27.2); the
# seam subtests delete it, and only it, for their own child (local).
#
# THIS FILE IS THE PACKAGE'S ORACLE for the fleet-path fresh-cost behaviour.
# It must not be weakened to make an implementation's life easier.
use strict;
use warnings;
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Test::More;
use JSON::PP;

my $SPEND_PL    = "$Bin/../../scripts/bp-spend.pl";
my $PRICING_PM  = "$Bin/../../scripts/BpPricing.pm";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

# ---------------------------------------------------------------------------
# generic helpers (mirror spend-token-columns.t / spend-fresh-pricing.t)
# ---------------------------------------------------------------------------

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub call_derive_package {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::derive_package(%opts) };
    return ($doc, $@);
}
sub call_derive_blueprint {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::derive_blueprint(%opts) };
    return ($doc, $@);
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

sub write_text_file {
    my ($path, $text) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh $text;
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

sub slurp_raw {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw;
}

sub read_lines {
    my ($p) = @_;
    my $raw = slurp_raw($p);
    return () unless defined $raw;
    return split(/\n/, $raw);
}

sub runs_path    { my ($dir, $pkg) = @_; return File::Spec->catfile($dir, 'runs', "$pkg.jsonl"); }
sub derived_path { my ($dir) = @_; return File::Spec->catfile($dir, 'runs', 'spend-derived.json'); }

sub sys_init {
    my (%o) = @_;
    return { type => 'system', subtype => 'init', cwd => '/project',
             session_id => $o{session} // 'sess-1', model => $o{model} // 'claude-sonnet-5' };
}

sub fleet_assistant_rec {
    my (%o) = @_;
    my %usage = (
        input_tokens                => $o{input} // 0,
        output_tokens                => $o{output} // 0,
        cache_creation_input_tokens => $o{cache_creation} // 0,
        cache_read_input_tokens     => $o{cache_read} // 0,
    );
    if (exists $o{cache_5m} || exists $o{cache_1h}) {
        $usage{cache_creation} = {
            ephemeral_5m_input_tokens => $o{cache_5m} // 0,
            ephemeral_1h_input_tokens => $o{cache_1h} // 0,
        };
    }
    $usage{speed} = $o{speed} if exists $o{speed};
    return {
        type    => 'assistant',
        message => { model => $o{model} // 'claude-sonnet-5', id => $o{id} // ('msg_' . int(rand(1e9))),
                     type => 'message', role => 'assistant',
                     content => [ { type => 'text', text => 'x' } ], usage => \%usage },
        parent_tool_use_id => $o{parent},
        session_id         => $o{session} // 'sess-1',
        uuid               => $o{uuid} // ('u-' . int(rand(1e9))),
        timestamp          => $o{timestamp} // '2026-09-26T00:00:00.000Z',
    };
}

sub result_rec {
    my (%o) = @_;
    return { type => 'result', is_error => JSON::PP::false, session_id => $o{session} // 'sess-1',
             total_cost_usd => $o{total_cost_usd} // 0,
             usage => { input_tokens => 0, output_tokens => 0, cache_read_input_tokens => 0,
                        cache_creation_input_tokens => 0, modelUsage => {} },
             uuid => 'u-result-' . int(rand(1e9)) };
}

# ---------------------------------------------------------------------------
# Fleet fixture P1/P2 (spec SS4, "Fleet fixture P1"/"P2").
# ---------------------------------------------------------------------------

# P1: A (coordinator, m-a, sonnet, 2 records) + B (subagent, m-b, opus) +
# a result record. Priced A=4.25, B=0.6, package total 4.85, T=2,510,000.
sub write_p1 {
    my ($dir, %o) = @_;
    my @lines = (
        sys_init(session => 's1'),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-a', model => 'claude-sonnet-5',
            input => 1_000_000, cache_read => 1_000_000, cache_creation => 300_000,
            cache_5m => 100_000, cache_1h => 200_000, output => 50_000,
            timestamp => '2026-09-26T00:00:00.000Z'),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-a', model => 'claude-sonnet-5',
            input => 1_000_000, cache_read => 1_000_000, cache_creation => 300_000,
            cache_5m => 100_000, cache_1h => 200_000, output => 100_000,
            timestamp => '2026-09-26T00:00:01.000Z'),
        fleet_assistant_rec(session => 's1', parent => 'toolu_b', id => 'm-b', model => 'claude-opus-5-5',
            input => 100_000, output => 10_000, timestamp => '2026-09-26T00:00:02.000Z'),
        result_rec(session => 's1', total_cost_usd => $o{total_cost_usd} // 1.23),
    );
    write_jsonl(runs_path($dir, 'p1'), @lines);
}

# P2: C (coordinator, m-c, sonnet). Priced 1.0.
sub write_p2 {
    my ($dir) = @_;
    write_jsonl(runs_path($dir, 'p2'),
        sys_init(session => 's2'),
        fleet_assistant_rec(session => 's2', parent => undef, id => 'm-c', model => 'claude-sonnet-5',
            input => 500_000, output => 0, timestamp => '2026-09-26T00:00:00.000Z'),
        result_rec(session => 's2', total_cost_usd => 2.34),
    );
}

# ---------------------------------------------------------------------------
# Seam stub (spec SS4's ok2 extension of spec 01 SS4's stub.pl).
# F-MD-2 == F-MD with the Sonnet row's first rate cell $2/MTok -> $3/MTok.
# ---------------------------------------------------------------------------

my $F_MD = <<'MD';
# Pricing

Learn about Anthropic's pricing structure for models and features.

## Model pricing

The following table shows pricing for all Claude models.

| Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |
|---|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok | $20 / MTok |
| Claude Sonnet 5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
| Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok | $50 / MTok |
| Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |
| Claude Opus 5 ([deprecated](/docs/en/about-claude/model-deprecations)) | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
| `claude-test-9` | $3 / MTok | $3.75 / MTok | Not available | $0.30 / MTok | $15 / MTok |

## Batch processing

| Model | Batch input | Batch output |
|---|---|---|
| Claude Opus 5.5 | $2 / MTok | $10 / MTok |
| Claude Sonnet 5 | $1 / MTok | $5 / MTok |

## Long context pricing

When using the 1M token context window, requests that exceed 200K input tokens are charged at long context rates. The 200K threshold is based on input tokens, including cache reads and writes.

| Model | Input (<= 200K) | Input (> 200K) | Output (<= 200K) | Output (> 200K) |
|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $8 / MTok | $20 / MTok | $30 / MTok |

Prompt caching multipliers apply on top of long context rates.

## Fast mode pricing

| Model | Input | Output |
|---|---|---|
| Claude Opus 5.5 | $24 / MTok | $120 / MTok |
MD

(my $F_MD_2 = $F_MD) =~ s{\| Claude Sonnet 5 \| \$2 / MTok \|}{| Claude Sonnet 5 | \$3 / MTok |};

sub write_stub {
    my ($dir) = @_;
    write_text_file(File::Spec->catfile($dir, 'F-MD.md'), $F_MD);
    write_text_file(File::Spec->catfile($dir, 'F-MD-2.md'), $F_MD_2);
    my $stub = File::Spec->catfile($dir, 'stub.pl');
    write_text_file($stub, <<'STUB');
#!/usr/bin/env perl
use strict; use warnings;
use File::Basename qw(dirname);
my $here = dirname($0);
open(my $cfh, '>>', $ENV{SPEND_STUB_COUNTER}) or die "counter: $!";
print $cfh "$ARGV[0]\n";
close $cfh;
my $mode = $ENV{SPEND_STUB_MODE} // 'ok';
sub slurp { my ($p) = @_; open(my $fh, '<:raw', $p) or die $!; local $/; my $x = <$fh>; close $fh; return $x; }
if ($mode eq 'ok') {
    print slurp("$here/F-MD.md"); print "\n200";
} elsif ($mode eq 'ok2') {
    print slurp("$here/F-MD-2.md"); print "\n200";
} elsif ($mode eq 'garbage') {
    print '<html><body>Service temporarily unavailable</body></html>'; print "\n200";
} elsif ($mode eq 'fail') {
    exit 7;
} else {
    die "unknown SPEND_STUB_MODE: $mode";
}
STUB
    return $stub;
}

# Runs bp-spend.pl with the seam armed for that child only.
sub run_seam {
    my ($mode, $stub, $counter, @args) = @_;
    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}          = $mode;
    local $ENV{SPEND_STUB_COUNTER}       = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
    delete local $ENV{CCPRAXIS_SPEND_PRICING_FILE};
    return run_spend(@args);
}

# Recursive scan of a decoded doc, collecting sorted, index-agnostic paths of
# keys matching /api_equivalent|price_|pricing/ (mirrors spend-token-columns.t
# TC9's rewritten scan).
sub bad_key_paths {
    my ($doc) = @_;
    my @paths;
    my $scan;
    $scan = sub {
        my ($node, $path) = @_;
        if (ref($node) eq 'HASH') {
            for my $k (sort keys %$node) {
                push @paths, "$path.$k" if $k =~ /api_equivalent|price_|pricing/;
                $scan->($node->{$k}, "$path.$k");
            }
        } elsif (ref($node) eq 'ARRAY') {
            $scan->($_, "$path\[\]") for @$node;
        }
    };
    $scan->($doc, '$');
    return [ sort @paths ];
}

my @TOP_KEYS = qw(generated_at derived tokens by_model anomaly packages
    price_source price_fetched_at pricing_status api_equivalent_cost_usd
    unpriced_tokens unpriced_reasons);

# Pre-package-02 packages[i] key set (spec 01 shape), read from HEAD's
# _empty_package_result: pkg/status/tokens/by_model/record_counts/anomaly/
# cross_check/derived. Spec SS3.1 adds api_equivalent_cost_usd/
# unpriced_tokens/unpriced_reasons as siblings of cross_check.
my @PKG_KEYS_PRE = qw(pkg status tokens by_model record_counts anomaly cross_check derived);
my @PKG_KEYS_POST = (@PKG_KEYS_PRE, qw(api_equivalent_cost_usd unpriced_tokens unpriced_reasons));

# ===========================================================================
# DF1 -- a single derive-package run, seam ok.
# ===========================================================================
subtest 'DF1: derive-package writes the stamped api_equivalent_cost_usd/price_source/price_fetched_at/pricing_status' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    my $t0 = time;
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    my $t1 = time;
    is($rc, 0, 'DF1: exits 0') or diag($out);
    chomp(my $stdout_path = $out);
    is($stdout_path, derived_path($dir), 'DF1: stdout is exactly the path') or diag($out);

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF1: spend-derived.json parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF1: no doc to inspect', 14 unless $doc;
        my $pkg = $doc->{packages}[0];
        ok($pkg, 'DF1: packages[0] exists');
        if ($pkg) {
            ok(abs($pkg->{api_equivalent_cost_usd} - 4.85) < 1e-9, 'DF1: packages[0].api_equivalent_cost_usd == 4.85')
                or diag($pkg->{api_equivalent_cost_usd});
            is($pkg->{unpriced_tokens}, 0, 'DF1: packages[0].unpriced_tokens == 0');
            is_deeply($pkg->{unpriced_reasons}, [], 'DF1: packages[0].unpriced_reasons == []');
            is($pkg->{cross_check}{total_cost_usd}, 1.23, 'DF1: packages[0].cross_check.total_cost_usd unchanged');
            is($pkg->{cross_check}{cost_source}, 'claude-code-self-reported-headless',
                'DF1: packages[0].cross_check.cost_source unchanged');
        }
        ok(abs($doc->{api_equivalent_cost_usd} - 4.85) < 1e-9, 'DF1: top-level api_equivalent_cost_usd == 4.85')
            or diag($doc->{api_equivalent_cost_usd});
        is($doc->{pricing_status}, 'ok', 'DF1: pricing_status ok');
        my ($u) = read_lines($counter);
        is($doc->{price_source}, $u, 'DF1: price_source equals the counter\'s logged line');
        like($doc->{price_fetched_at}, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'DF1: price_fetched_at is ISO');
        if ($doc->{price_fetched_at} && $doc->{price_fetched_at} =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/) {
            require Time::Local;
            my $epoch = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
            ok(!$@ && $epoch >= $t0 - 2 && $epoch <= $t1 + 2, 'DF1: price_fetched_at within [start-2s, end+2s]');
        }
        ok($doc->{price_fetch_override}, 'DF1: price_fetch_override is true');
        my @lines = read_lines($counter);
        is(scalar(@lines), 1, 'DF1: counter has exactly 1 line');
    }
};

# ===========================================================================
# DF2 -- derive-blueprint over two packages fetches once.
# ===========================================================================
subtest 'DF2: derive-blueprint over P1+P2 fetches once and sums the two package costs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);
    write_p2($dir);

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'DF2: exits 0') or diag($out);
    my @lines = read_lines($counter);
    is(scalar(@lines), 1, 'DF2: exactly one fetch for two packages');

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF2: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF2: no doc to inspect', 4 unless $doc;
        my @pkgs = @{ $doc->{packages} // [] };
        is(scalar(@pkgs), 2, 'DF2: two packages');
        ok(abs(($pkgs[0]{api_equivalent_cost_usd} // -1) - 4.85) < 1e-9, 'DF2: packages[0] (p1) == 4.85')
            or diag($pkgs[0]{api_equivalent_cost_usd});
        ok(abs(($pkgs[1]{api_equivalent_cost_usd} // -1) - 1.0) < 1e-9, 'DF2: packages[1] (p2) == 1.0')
            or diag($pkgs[1]{api_equivalent_cost_usd});
        ok(abs($doc->{api_equivalent_cost_usd} - 5.85) < 1e-9, 'DF2: top-level cost == 5.85')
            or diag($doc->{api_equivalent_cost_usd});
    }
};

# ===========================================================================
# DF3 -- fetches again, recomputes, never reads back a poisoned file.
# ===========================================================================
subtest 'DF3: a second derive fetches again and overwrites a hand-poisoned file, never reading it back' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    my ($rc1, $out1) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc1, 0, 'DF3: first derive exits 0') or diag($out1);
    my $first_doc = slurp_json(derived_path($dir));

    # Poison every cost-related key.
    my $poison = {
        %{ $first_doc // {} },
        api_equivalent_cost_usd => 999,
        price_source            => 'file:/poison',
        price_fetched_at        => '2000-01-01T00:00:00Z',
        pricing_status          => 'ok',
    };
    if ($poison->{packages}) {
        for my $p (@{ $poison->{packages} }) { $p->{api_equivalent_cost_usd} = 999 if ref($p) eq 'HASH'; }
    }
    open(my $fh, '>:raw', derived_path($dir)) or die $!;
    print $fh $JSON->encode($poison);
    close $fh;

    my ($rc2, $out2) = run_seam('ok2', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc2, 0, 'DF3: second derive exits 0') or diag($out2);
    my @lines = read_lines($counter);
    is(scalar(@lines), 2, 'DF3: counter has 2 lines (fetched again)');

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF3: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF3: no doc to inspect', 5 unless $doc;
        my $pkg = $doc->{packages}[0];
        ok(abs(($pkg->{api_equivalent_cost_usd} // -1) - 5.85) < 1e-9, 'DF3: package cost recomputed to 5.85 under ok2 rates')
            or diag($pkg->{api_equivalent_cost_usd});
        ok(abs(($doc->{api_equivalent_cost_usd} // -1) - 5.85) < 1e-9, 'DF3: top-level cost 5.85')
            or diag($doc->{api_equivalent_cost_usd});
        cmp_ok($doc->{price_fetched_at}, 'ge', $first_doc->{price_fetched_at}, 'DF3: price_fetched_at >= the first run\'s');
        my $raw = slurp_raw(derived_path($dir));
        unlike($raw, qr/999/, 'DF3: no value 999 remains anywhere in the file');
        unlike($raw, qr/poison/, 'DF3: no string "poison" remains anywhere in the file');
    }
};

# ===========================================================================
# DF4 -- offline: null cost, pricing_status names why; overwrites a priced file.
# ===========================================================================
subtest 'DF4: offline pricing gives a null cost everywhere with pricing_status set' => sub {
    # (a) NO_FETCH=1 (the file default) with the seam variable also set.
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);
    {
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
        local $ENV{SPEND_STUB_MODE}          = 'ok';
        local $ENV{SPEND_STUB_COUNTER}       = $counter;
        my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'p1');
        is($rc, 0, 'DF4a: exits 0') or diag($out);
        ok(!-e $counter, 'DF4a: counter absent (NO_FETCH beats the seam)');
        my $doc = slurp_json(derived_path($dir));
        ok($doc, 'DF4a: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
      SKIP: {
            skip 'DF4a: no doc to inspect', 6 unless $doc;
            is($doc->{pricing_status}, 'offline', 'DF4a: pricing_status offline');
            ok(!defined($doc->{price_source}), 'DF4a: price_source null');
            ok(!defined($doc->{price_fetched_at}), 'DF4a: price_fetched_at null');
            ok(!defined($doc->{api_equivalent_cost_usd}), 'DF4a: top-level cost null');
            ok(!defined($doc->{packages}[0]{api_equivalent_cost_usd}), 'DF4a: package cost null');
            is($doc->{unpriced_tokens}, 2_510_000, 'DF4a: unpriced_tokens == T == 2,510,000');
            is_deeply($doc->{unpriced_reasons}, [ { reason => 'offline', tokens => 2_510_000 } ],
                'DF4a: unpriced_reasons is exactly [{offline,2510000}]');
        }
    }

    # (b) NO_FETCH deleted, --offline passed instead.
    my $dir_b = tempdir(CLEANUP => 1);
    write_p1($dir_b);
    {
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
        local $ENV{SPEND_STUB_MODE}          = 'ok';
        local $ENV{SPEND_STUB_COUNTER}       = $counter . '.b';
        delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
        my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir_b, '--pkg', 'p1', '--offline');
        is($rc, 0, 'DF4b: exits 0') or diag($out);
        ok(!-e ($counter . '.b'), 'DF4b: --offline never invokes the seam');
        my $doc = slurp_json(derived_path($dir_b));
      SKIP: {
            skip 'DF4b: no doc to inspect', 1 unless $doc;
            is($doc->{pricing_status}, 'offline', 'DF4b: pricing_status offline');
        }
    }

    # (c) DF1 first (priced), then (a): the file now holds the null cost.
    my $dir_c = tempdir(CLEANUP => 1);
    my $counter_c = File::Spec->catfile($stubdir, 'counter-c.txt');
    write_p1($dir_c);
    run_seam('ok', $stub, $counter_c, 'derive-package', '--run-dir', $dir_c, '--pkg', 'p1');
    my $priced_doc = slurp_json(derived_path($dir_c));
    ok(($priced_doc // {})->{api_equivalent_cost_usd}, 'DF4c: the priming run produced a non-null cost') if $priced_doc;
    my ($rc_c, $out_c) = run_spend('derive-package', '--run-dir', $dir_c, '--pkg', 'p1');
    is($rc_c, 0, 'DF4c: the offline re-run exits 0') or diag($out_c);
    my $doc_c = slurp_json(derived_path($dir_c));
  SKIP: {
        skip 'DF4c: no doc to inspect', 2 unless $doc_c;
        is($doc_c->{pricing_status}, 'offline', 'DF4c: overwritten to offline');
        ok(!defined($doc_c->{api_equivalent_cost_usd}), 'DF4c: overwritten to a null cost');
    }
};

# ===========================================================================
# DF5 -- unavailable pricing: fail and garbage seam modes.
# ===========================================================================
subtest 'DF5: an unavailable fetch (fail/garbage) gives a null cost and names the reason' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    my ($rc, $out) = run_seam('fail', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc, 0, 'DF5 fail: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF5 fail: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF5 fail: no doc to inspect', 5 unless $doc;
        is($doc->{pricing_status}, 'unavailable: fetch command exited 7', 'DF5 fail: exact pricing_status');
        my ($u) = read_lines($counter);
        is($doc->{price_source}, $u, 'DF5 fail: price_source is the URL even though the fetch failed');
        ok(!defined($doc->{price_fetched_at}), 'DF5 fail: price_fetched_at null');
        ok(!defined($doc->{api_equivalent_cost_usd}), 'DF5 fail: top-level cost null');
        is_deeply($doc->{unpriced_reasons}, [ { reason => 'pricing-unavailable', tokens => 2_510_000 } ],
            'DF5 fail: unpriced_reasons is exactly [{pricing-unavailable,2510000}]');
    }

    my $dir2 = tempdir(CLEANUP => 1);
    write_p1($dir2);
    my $counter2 = File::Spec->catfile($stubdir, 'counter2.txt');
    my ($rc2, $out2) = run_seam('garbage', $stub, $counter2, 'derive-package', '--run-dir', $dir2, '--pkg', 'p1');
    is($rc2, 0, 'DF5 garbage: exits 0') or diag($out2);
    my $doc2 = slurp_json(derived_path($dir2));
  SKIP: {
        skip 'DF5 garbage: no doc to inspect', 1 unless $doc2;
        is($doc2->{pricing_status}, 'unavailable: standard price table not found', 'DF5 garbage: exact reason');
    }
};

# ===========================================================================
# DF6 -- partial pricing: some priced, some not, exact reasons.
# ===========================================================================
subtest 'DF6: partial pricing carries the priced sum plus unpriced_tokens/unpriced_reasons' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');

    write_jsonl(runs_path($dir, 'p1'),
        sys_init(session => 's1'),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-a', model => 'claude-sonnet-5',
            input => 1_000_000, cache_read => 1_000_000, cache_creation => 300_000,
            cache_5m => 100_000, cache_1h => 200_000, output => 50_000),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-a', model => 'claude-sonnet-5',
            input => 1_000_000, cache_read => 1_000_000, cache_creation => 300_000,
            cache_5m => 100_000, cache_1h => 200_000, output => 100_000),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-d', model => 'claude-nonexistent-model',
            input => 1000, output => 1),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-e', model => 'claude-sonnet-5',
            input => 0, output => 0, cache_creation => 500),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-f', model => 'claude-sonnet-5',
            input => 200, output => 300, speed => 'fast'),
        result_rec(session => 's1', total_cost_usd => 1.23),
    );

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc, 0, 'DF6: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF6: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF6: no doc to inspect', 4 unless $doc;
        my $pkg = $doc->{packages}[0];
        ok(abs(($pkg->{api_equivalent_cost_usd} // -1) - 4.25) < 1e-9, 'DF6: package cost == 4.25 (only A priced)')
            or diag($pkg->{api_equivalent_cost_usd});
        is($pkg->{unpriced_tokens}, 2001, 'DF6: package unpriced_tokens == 2001');
        is_deeply($pkg->{unpriced_reasons},
            [ { reason => 'cache-write-unsplit', tokens => 500 },
              { reason => 'non-standard-speed',  tokens => 500 },
              { reason => 'unknown-model',       tokens => 1001 } ],
            'DF6: package unpriced_reasons in this exact order') or diag($JSON->encode($pkg->{unpriced_reasons} // []));
        ok(abs(($doc->{api_equivalent_cost_usd} // -1) - 4.25) < 1e-9, 'DF6: top-level cost also 4.25');
    }
};

# ===========================================================================
# DF7 -- same per-request rules as the session path (long context).
# ===========================================================================
subtest 'DF7: a fleet request obeys the same long-context/rate rules as the session path' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');

    write_jsonl(runs_path($dir, 'p1'),
        sys_init(session => 's1'),
        fleet_assistant_rec(session => 's1', parent => undef, id => 'm-g', model => 'claude-opus-5-5[1m]',
            input => 150_000, cache_creation => 20_000, cache_5m => 20_000, cache_1h => 0,
            cache_read => 60_000, output => 10_000),
        result_rec(session => 's1', total_cost_usd => 0),
    );

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc, 0, 'DF7: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF7: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF7: no doc to inspect', 1 unless $doc;
        ok(abs(($doc->{packages}[0]{api_equivalent_cost_usd} // -1) - 1.724) < 1e-9,
            'DF7: long-context cost == 1.724, exactly as spec 01 FP2 R2') or diag($doc->{packages}[0]{api_equivalent_cost_usd});
    }
};

# ===========================================================================
# DF8 -- self-reported cross_check untouched by pricing state.
# ===========================================================================
subtest 'DF8: cross_check.total_cost_usd/cost_source is identical under ok/offline/unavailable' => sub {
    my %docs;
    for my $case (
        ['ok',      'ok'],
        ['offline', undef],
        ['fail',    'fail'],
    ) {
        my ($label, $mode) = @$case;
        my $dir = tempdir(CLEANUP => 1);
        write_p1($dir);
        if ($mode) {
            my $stubdir = tempdir(CLEANUP => 1);
            my $stub = write_stub($stubdir);
            my $counter = File::Spec->catfile($stubdir, 'counter.txt');
            run_seam($mode, $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
        } else {
            run_spend('derive-package', '--run-dir', $dir, '--pkg', 'p1');
        }
        $docs{$label} = slurp_json(derived_path($dir));
    }
    for my $label (qw(ok offline fail)) {
        ok($docs{$label}, "DF8 [$label]: doc parses");
    }
  SKIP: {
        skip 'DF8: not every doc available', 2 unless $docs{ok} && $docs{offline} && $docs{fail};
        is_deeply($docs{ok}{packages}[0]{cross_check}, $docs{offline}{packages}[0]{cross_check},
            'DF8: cross_check identical between ok and offline');
        is_deeply($docs{ok}{packages}[0]{cross_check}, $docs{fail}{packages}[0]{cross_check},
            'DF8: cross_check identical between ok and fail');
    }
};

# ===========================================================================
# DF9 -- library calls never fetch.
# ===========================================================================
subtest 'DF9: library-level derive_package/derive_blueprint never fetch and report offline' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}          = 'ok';
    local $ENV{SPEND_STUB_COUNTER}       = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my ($bp_doc, $bp_err) = call_derive_blueprint(runs_dir => $dir, pkgs => ['p1']);
    ok(!$bp_err, 'DF9: derive_blueprint does not die') or diag($bp_err);
    my ($pkg_doc, $pkg_err) = call_derive_package(jsonl_path => runs_path($dir, 'p1'), pkg => 'p1');
    ok(!$pkg_err, 'DF9: derive_package does not die') or diag($pkg_err);

    ok(!-e $counter, 'DF9: neither library call invoked the fetch seam');
  SKIP: {
        skip 'DF9: derive_blueprint result unavailable', 2 unless $bp_doc;
        is($bp_doc->{pricing_status}, 'offline', 'DF9: derive_blueprint pricing_status offline');
        ok(!defined($bp_doc->{packages}[0]{api_equivalent_cost_usd}), 'DF9: derive_blueprint packages[0] cost undef');
    }
  SKIP: {
        skip 'DF9: derive_package result unavailable', 1 unless $pkg_doc;
        ok(!defined($pkg_doc->{api_equivalent_cost_usd}), 'DF9: derive_package\'s own result cost undef');
    }
};

# ===========================================================================
# DF10 -- missing package leaves the stamped file untouched, no fetch.
# ===========================================================================
subtest 'DF10: a missing package exits 4, never fetches, and leaves the file byte-identical' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    my ($rc1, $out1) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc1, 0, 'DF10: priming run exits 0') or diag($out1);
    my $before = slurp_raw(derived_path($dir));

    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'nope');
    is($rc2, 4, 'DF10: missing package exits 4') or diag($out2);
    my @lines = read_lines($counter);
    is(scalar(@lines), 1, 'DF10: counter unchanged at 1 line');
    my $after = slurp_raw(derived_path($dir));
    is($after, $before, 'DF10: spend-derived.json bytes are unchanged');
};

# ===========================================================================
# DF11 -- mechanical: no code path reads api_equivalent_cost_usd back as a rate.
# ===========================================================================
subtest 'DF11: source checks prove no read-back of a stored cost as a rate' => sub {
    my $pricing_src = slurp_raw($PRICING_PM);
  SKIP: {
        skip 'DF11a: BpPricing.pm not present', 2 unless defined $pricing_src;
        my @code_lines = grep { !/^\s*#/ } split(/\n/, $pricing_src);
        my $joined = join("\n", @code_lines);
        unlike($joined, qr/api_equivalent/, 'DF11a: BpPricing.pm contains no code line with "api_equivalent"');
        unlike($joined, qr/spend-derived/, 'DF11a: BpPricing.pm contains no code line with "spend-derived"');
    }

    my $spend_src = slurp_raw($SPEND_PL);
    ok(defined $spend_src, 'DF11: bp-spend.pl source read') or BAIL_OUT('DF11: cannot read bp-spend.pl');
    my @code_lines = grep { !/^\s*#/ } split(/\n/, $spend_src);

    my @bad_readback = grep {
        /api_equivalent_cost_usd/ && /rates_for_request|\{rates\}|1_000_000|1e6|\bpricing\s*=>/
    } @code_lines;
    is_deeply(\@bad_readback, [],
        'DF11b: no bp-spend.pl code line with api_equivalent_cost_usd also looks like a rate computation')
        or diag(join("\n", @bad_readback));

    my @derived_lines = grep { /spend-derived/ } @code_lines;
    is(scalar(@derived_lines), 1, 'DF11c: exactly one bp-spend.pl code line mentions spend-derived')
        or diag(join("\n", @derived_lines));
    if (@derived_lines == 1) {
        like($derived_lines[0], qr/\$out_path\s*=/, 'DF11c: that line assigns $out_path');
    }

    my @caller_idx = grep { $code_lines[$_] =~ /^unless \(caller\)/ } (0 .. $#code_lines);
    my @acquire_idx = grep { $code_lines[$_] =~ /BpPricing::acquire\s*\(/ } (0 .. $#code_lines);
    is(scalar(@acquire_idx), 3, 'DF11d: exactly 3 bp-spend.pl code lines call BpPricing::acquire(')
        or diag(join(', ', @acquire_idx));
  SKIP: {
        skip 'DF11d: no "unless (caller)" line found', 1 unless @caller_idx;
        my $caller_line = $caller_idx[0];
        my @before_caller = grep { $_ <= $caller_line } @acquire_idx;
        is_deeply(\@before_caller, [], 'DF11d: every BpPricing::acquire( call lies after "unless (caller)"')
            or diag("caller at $caller_line, acquire at " . join(', ', @acquire_idx));
    }
};

# ===========================================================================
# DF12 -- every test file that reaches the derive/report verbs guards itself.
# ===========================================================================
subtest 'DF12: every package test file that reaches a derive/report path sets the NO_FETCH guard' => sub {
    my @files = qw(
        spend-derive-fresh-cost.t spend-time-window.t spend-derived-from-transcripts.t
        spend-package-request-dedup.t spend-drive-solo-session.t spend-session-attribution.t
        spend-token-columns.t spend-fresh-pricing.t
    );
    for my $f (@files) {
        my $path = "$Bin/$f";
        my $src = slurp_raw($path);
        ok(defined $src, "DF12: $f exists") or next;
        if ($src =~ /derive-package|derive-blueprint|derive_package|derive_blueprint|report-session|derive-session|report_session|derive_session/) {
            like($src, qr/^\$ENV\{CCPRAXIS_SPEND_NO_FETCH\}\s*=\s*1\s*;/m,
                "DF12: $f reaches a derive/report path and sets the file-scope NO_FETCH guard");
        } else {
            pass("DF12: $f does not reach a derive/report path, no guard required");
        }
    }
};

# ===========================================================================
# DF13 -- exact key sets; price-shaped keys only at the documented paths.
# ===========================================================================
subtest 'DF13: top-level and packages[0] key sets are exact; price-shaped keys appear only at SS3.1 paths' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);
    run_seam('ok', $stub, $counter, 'derive-package', '--run-dir', $dir, '--pkg', 'p1');
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'DF13: DF1-shaped doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'DF13: no doc to inspect', 3 unless $doc;
        is_deeply([ sort keys %$doc ], [ sort (@TOP_KEYS, 'price_fetch_override') ],
            'DF13: top-level key set is exactly SS2.3\'s list plus price_fetch_override') or diag(join(',', sort keys %$doc));
        for my $k (qw(api_equivalent_cost_usd unpriced_tokens unpriced_reasons)) {
            ok(exists $doc->{packages}[0]{$k}, "DF13: packages[0].$k exists as a sibling of cross_check");
        }
        is_deeply([ sort keys %{ $doc->{packages}[0] } ], [ sort @PKG_KEYS_POST ],
            'DF13: packages[0] key set is exactly the pre-change set plus the three new keys, nothing else')
            or diag(join(',', sort keys %{ $doc->{packages}[0] }));
        is_deeply(bad_key_paths($doc),
            [ '$.api_equivalent_cost_usd', '$.packages[].api_equivalent_cost_usd',
              '$.price_fetch_override', '$.price_fetched_at', '$.price_source', '$.pricing_status' ],
            'DF13: price-shaped keys appear only at the SS3.1 paths (this run has the seam armed, so price_fetch_override is present)')
            or diag($JSON->encode(bad_key_paths($doc)));
    }

    my $dir2 = tempdir(CLEANUP => 1);
    write_p1($dir2);
    run_spend('derive-package', '--run-dir', $dir2, '--pkg', 'p1');
    my $doc2 = slurp_json(derived_path($dir2));
  SKIP: {
        skip 'DF13 offline: no doc to inspect', 1 unless $doc2;
        is_deeply([ sort keys %$doc2 ], [ sort @TOP_KEYS ],
            'DF13: under offline (no override), top-level key set is exactly SS2.3\'s list') or diag(join(',', sort keys %$doc2));
    }
};

# ===========================================================================
# S2 (review 02-review.md) -- derive_package() as a library call must not
# leak the private unrounded-cost carrier. Spec SS2.2: "the implementer
# keeps the unrounded package sums privately (for example, a key deleted
# before return). No private key may reach the JSON." That invariant must
# hold for derive_package()'s OWN return, not only for derive_blueprint's
# JSON (which is where the deletion currently happens, per the review).
# ===========================================================================
subtest 'S2: derive_package() returns no key named _api_equivalent_cost_unrounded, nor any underscore-prefixed key' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    write_p1($dir);

    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}          = 'ok';
    local $ENV{SPEND_STUB_COUNTER}       = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my $pricing = eval { BpPricing::acquire() };
    ok(!$@, 'S2: BpPricing::acquire does not die') or diag($@);
    my ($pkg_doc, $err) = call_derive_package(jsonl_path => runs_path($dir, 'p1'), pkg => 'p1', pricing => $pricing);
    ok(!$err, 'S2: derive_package does not die') or diag($err);
  SKIP: {
        skip 'S2: derive_package result unavailable', 2 unless $pkg_doc;
        ok(!exists $pkg_doc->{_api_equivalent_cost_unrounded},
            'S2: derive_package() library return has no _api_equivalent_cost_unrounded key');
        my @underscore_keys = grep { /^_/ } keys %$pkg_doc;
        is_deeply(\@underscore_keys, [], 'S2: derive_package() library return has no underscore-prefixed key at all')
            or diag(join(',', @underscore_keys));
    }
};

done_testing();
