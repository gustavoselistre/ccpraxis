#!/usr/bin/env perl
# platform: any
# Oracle for blueprint spend-token-report, package
# 02-derive-cost-and-time-window (DC2): --since/--until on report-session
# and derive-session ([since, until) over the placement timestamp of a
# deduplicated request, Decision 27.3), the hour dimension (Decision 27.3),
# and the window's effect on attribution and the cache-write anomaly. Spec:
# specs/02-derive-cost-and-time-window-spec.md SS4.2.
#
# This file sets CCPRAXIS_SPEND_NO_FETCH=1 at file scope (Decision 27.2), so
# pricing is offline throughout; nothing here needs a dollar figure.
#
# THIS FILE IS THE PACKAGE'S ORACLE for the time-window behaviour. It must
# not be weakened to make an implementation's life easier.
use strict;
use warnings;
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;
use POSIX qw(strftime);
require Time::Local;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

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

sub slurp_raw {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw;
}

sub assistant_rec {
    my (%o) = @_;
    my %usage;
    $usage{input_tokens}                = $o{input}          // 0;
    $usage{output_tokens}               = $o{output}         // 0;
    $usage{cache_creation_input_tokens} = $o{cache_creation}  if exists $o{cache_creation};
    my %message = (usage => \%usage, model => $o{model} // 'claude-sonnet-5', id => $o{message_id});
    my %rec = (
        type       => 'assistant',
        message    => \%message,
        session_id => $o{session} // 'sess-w',
        uuid       => $o{uuid} // ('u-' . int(rand(1e9))),
    );
    $rec{timestamp} = $o{timestamp} if exists $o{timestamp};
    return \%rec;
}

sub session_paths {
    my ($dir, $uuid) = @_;
    my $main   = File::Spec->catfile($dir, "$uuid.jsonl");
    my $subdir = File::Spec->catdir($dir, $uuid, 'subagents');
    return ($main, $subdir);
}
sub agent_jsonl_path { my ($subdir, $name) = @_; return File::Spec->catfile($subdir, "$name.jsonl"); }
sub agent_meta_path  { my ($subdir, $name) = @_; return File::Spec->catfile($subdir, "$name.meta.json"); }

sub epoch {
    my ($y, $mo, $d, $h, $mi, $s) = @_;
    return Time::Local::timegm($s // 0, $mi, $h, $d, $mo - 1, $y);
}
sub iso {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

# ---------------------------------------------------------------------------
# Fixture W (spec SS4.2). All 2026-09-26, claude-sonnet-5, message.id keys,
# no requestId. Each request has a distinct input so sums identify members.
# ---------------------------------------------------------------------------

my $T_R1 = epoch(2026, 9, 26, 7, 30, 0);
my $T_R2 = epoch(2026, 9, 26, 8, 0, 0);
my $T_R3 = epoch(2026, 9, 26, 8, 59, 59);
my $T_R4A = epoch(2026, 9, 26, 9, 59, 30);
my $T_R4B = epoch(2026, 9, 26, 10, 0, 30);
my $T_R5 = epoch(2026, 9, 26, 10, 0, 0);
my $T_R6 = epoch(2026, 9, 26, 11, 15, 0);   # 13:15 +02:00
my $T_R9 = epoch(2026, 9, 26, 9, 30, 0);
my $T_R8B = epoch(2026, 9, 26, 9, 0, 0);
my $T_R10 = epoch(2026, 9, 26, 6, 0, 0);
my $NOW   = epoch(2026, 9, 26, 12, 0, 0);

my $SINCE_ISO = '2026-09-26T08:00:00Z';
my $UNTIL_ISO = '2026-09-26T10:00:00Z';

sub build_fixture_w {
    my ($dir) = @_;
    my ($main, $subdir) = session_paths($dir, 'sess-w');
    write_jsonl($main,
        assistant_rec(message_id => 'm-r1', input => 1,  timestamp => iso($T_R1)),
        assistant_rec(message_id => 'm-r2', input => 2,  timestamp => iso($T_R2)),
        assistant_rec(message_id => 'm-r3', input => 4,  timestamp => iso($T_R3)),
        assistant_rec(message_id => 'm-r4', input => 8, output => 5,  timestamp => iso($T_R4A)),
        assistant_rec(message_id => 'm-r4', input => 8, output => 20, timestamp => iso($T_R4B)),
        assistant_rec(message_id => 'm-r5', input => 16, timestamp => iso($T_R5)),
        assistant_rec(message_id => 'm-r6', input => 32, timestamp => '2026-09-26T13:15:00+02:00'),
        assistant_rec(message_id => 'm-r7', input => 64),
        assistant_rec(message_id => 'm-r8', input => 128),
        assistant_rec(message_id => 'm-r8', input => 128, timestamp => iso($T_R8B)),
    );
    write_jsonl(agent_jsonl_path($subdir, 'agent-a1'),
        assistant_rec(message_id => 'm-r9', input => 256, timestamp => iso($T_R9)));
    write_json_file(agent_meta_path($subdir, 'agent-a1'), { agentType => 'butler:bp-worker' });
    write_jsonl(agent_jsonl_path($subdir, 'agent-a2'),
        assistant_rec(message_id => 'm-r10', input => 512, timestamp => iso($T_R10)));
    write_json_file(agent_meta_path($subdir, 'agent-a2'), { agentType => 'butler:bp-worker' });
    return $main;
}

sub data_root_for {
    my ($dir) = @_;
    my $root = File::Spec->catdir($dir, '.ccpraxis-local-data');
    make_path($root) unless -d $root;
    return $root;
}

# ===========================================================================
# TW1 -- absolute window.
# ===========================================================================
subtest 'TW1: an absolute window keeps exactly the requests placed inside [since, until)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'role', '--json',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc, 0, 'TW1 report-session: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'TW1 report-session: stdout parses') or diag($out);
  SKIP: {
        skip 'TW1 report-session: doc unavailable', 3 unless $doc;
        is($doc->{totals}{input}{tokens}, 270, 'TW1: totals.input.tokens == 270 (R2+R3+R4+R9)');
        is($doc->{totals}{output}{tokens}, 20, 'TW1: totals.output.tokens == 20');
        is_deeply($doc->{window},
            { since => $SINCE_ISO, until => $UNTIL_ISO, requests_in_window => 4,
              requests_outside_window => 6, requests_no_timestamp => 2 },
            'TW1: window object is exact') or diag($JSON->encode($doc->{window} // {}));
    }

    my ($rc2, $out2) = run_spend('derive-session', '--session', $main, '--json', '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc2, 0, 'TW1 derive-session: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    ok($doc2, 'TW1 derive-session: stdout parses') or diag($out2);
  SKIP: {
        skip 'TW1 derive-session: doc unavailable', 2 unless $doc2;
        is($doc2->{totals}{input}{tokens}, 270, 'TW1 derive-session: totals.input.tokens == 270');
        is_deeply($doc2->{window},
            { since => $SINCE_ISO, until => $UNTIL_ISO, requests_in_window => 4,
              requests_outside_window => 6, requests_no_timestamp => 2 },
            'TW1 derive-session: window object is exact') or diag($JSON->encode($doc2->{window} // {}));
    }
};

# ===========================================================================
# TW2 -- relative windows and --now.
# ===========================================================================
subtest 'TW2: relative Nh/Nm windows resolved against --now equal the absolute window' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my $doc_abs = eval { JSON::PP->new->decode((run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--by', 'role', '--json', '--since', $SINCE_ISO, '--until', $UNTIL_ISO))[1]) };
    ok($doc_abs, 'TW2: baseline absolute-window doc available');

    for my $case (
        ['--since 4h --until 2h',     ['--since', '4h', '--until', '2h']],
        ['--since 240m --until 120m', ['--since', '240m', '--until', '120m']],
        ['--since=4h --until=2h',     ['--since=4h', '--until=2h']],
    ) {
        my ($label, $args) = @$case;
        my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
            '--by', 'role', '--json', '--now', $NOW, @$args);
        is($rc, 0, "TW2 [$label]: exits 0") or diag($out);
        my $doc = eval { JSON::PP->new->decode($out) };
        ok($doc, "TW2 [$label]: stdout parses") or diag($out);
      SKIP: {
            skip "TW2 [$label]: doc unavailable", 3 unless $doc && $doc_abs;
            is_deeply($doc->{rows}, $doc_abs->{rows}, "TW2 [$label]: rows equal TW1's");
            is_deeply($doc->{totals}, $doc_abs->{totals}, "TW2 [$label]: totals equal TW1's");
            is_deeply($doc->{window}, $doc_abs->{window}, "TW2 [$label]: window equals TW1's");
        }
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--since', '1d', '--now', $NOW);
    is($rc2, 0, 'TW2 1d: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    ok($doc2, 'TW2 1d: stdout parses') or diag($out2);
  SKIP: {
        skip 'TW2 1d: doc unavailable', 2 unless $doc2;
        is($doc2->{totals}{input}{tokens}, 831, 'TW2 1d: input == 831 (everything except R7/R8)');
        ok(!defined($doc2->{window}{until}), 'TW2 1d: window.until is null');
    }
};

# ===========================================================================
# TW3 -- edges: since inclusive, until exclusive; no-seconds form.
# ===========================================================================
subtest 'TW3: since is inclusive and until is exclusive at the exact boundary' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--since', '2026-09-26T10:00:00Z');
    is($rc, 0, 'TW3 since-only: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
  SKIP: {
        skip 'TW3 since-only: doc unavailable', 1 unless $doc;
        is($doc->{totals}{input}{tokens}, 48, 'TW3: --since 10:00:00Z gives input 48 (R5+R6); R4 excluded, R5 included at exactly since');
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--until', '2026-09-26T08:00:00Z');
    is($rc2, 0, 'TW3 until-only: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW3 until-only: doc unavailable', 1 unless $doc2;
        is($doc2->{totals}{input}{tokens}, 513, 'TW3: --until 08:00:00Z gives input 513 (R1+R10); R2 excluded at exactly until');
    }

    my ($rc3, $out3) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--since', '2026-09-26T08:00Z');
    is($rc3, 0, 'TW3 no-seconds: exits 0') or diag($out3);
    my $doc3 = eval { JSON::PP->new->decode($out3) };
  SKIP: {
        skip 'TW3 no-seconds: doc unavailable', 1 unless $doc3;
        is($doc3->{window}{since}, '2026-09-26T08:00:00Z', 'TW3: --since T08:00Z (no seconds) resolves to T08:00:00Z');
    }
};

# ===========================================================================
# TW4 -- dedup holds across the window edge; record_counts unaffected.
# ===========================================================================
subtest 'TW4: R4 contributes its deduplicated figures once; record_counts is window-independent' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc, 0, 'TW4: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
  SKIP: {
        skip 'TW4: doc unavailable', 1 unless $doc;
        is($doc->{record_counts}{requests}, 10, 'TW4: record_counts.requests still counts all 10 requests under a window');
    }

    my ($rc2, $out2) = run_spend('derive-session', '--session', $main, '--json');
    is($rc2, 0, 'TW4 no-window: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW4 no-window: doc unavailable', 1 unless $doc2;
        is($doc2->{record_counts}{requests}, 10, 'TW4 no-window: record_counts.requests also counts all 10 requests');
    }
};

# ===========================================================================
# TW5 -- timestamp-less requests.
# ===========================================================================
subtest 'TW5: timestamp-less requests are excluded and counted; with no window they are included' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc, 0, 'TW5: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
  SKIP: {
        skip 'TW5: doc unavailable', 1 unless $doc;
        is($doc->{window}{requests_no_timestamp}, 2, 'TW5: requests_no_timestamp == 2 (R7, R8)');
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    is($rc2, 0, 'TW5 no-window: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW5 no-window: doc unavailable', 1 unless $doc2;
        is($doc2->{totals}{input}{tokens}, 1023, 'TW5 no-window: input == 1023 (everything, timestamp-less included)');
    }
};

# ===========================================================================
# TW6 -- hour dimension, UTC.
# ===========================================================================
subtest 'TW6: --by hour buckets by the UTC hour of the placement timestamp' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'hour', '--json');
    is($rc, 0, 'TW6 no-window: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'TW6 no-window: stdout parses') or diag($out);
  SKIP: {
        skip 'TW6 no-window: doc unavailable', 2 unless $doc;
        my @got = map { [ $_->{hour}, $_->{tokens} ] } @{ $doc->{rows} // [] };
        my @want = (
            ['(no-timestamp)', 192], ['2026-09-26T06:00Z', 512], ['2026-09-26T07:00Z', 1],
            ['2026-09-26T08:00Z', 6], ['2026-09-26T09:00Z', 284], ['2026-09-26T10:00Z', 16],
            ['2026-09-26T11:00Z', 32],
        );
        is_deeply(\@got, \@want, 'TW6 no-window: rows are exactly the seven hour buckets, in order')
            or diag($JSON->encode(\@got));
        my $sum = 0; $sum += $_->[1] for @got;
        is($sum, 1043, 'TW6 no-window: row tokens sum to the grand total (1023 input + 20 output)');
        my $bad = 0;
        for my $r (@{ $doc->{rows} // [] }) {
            for my $k (qw(input_tokens cache_write_5m_tokens cache_write_1h_tokens cache_write_unsplit_tokens cache_read_tokens output_tokens)) {
                $bad++ unless exists $r->{$k};
            }
        }
        is($bad, 0, 'TW6 no-window: every row has all six *_tokens keys');
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'hour', '--json',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc2, 0, 'TW6 window: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW6 window: doc unavailable', 1 unless $doc2;
        my @got2 = map { [ $_->{hour}, $_->{tokens} ] } @{ $doc2->{rows} // [] };
        is_deeply(\@got2, [ ['2026-09-26T08:00Z', 6], ['2026-09-26T09:00Z', 284] ],
            'TW6 window: rows are exactly 08:00Z(6) and 09:00Z(284)') or diag($JSON->encode(\@got2));
    }

    my ($rc3, $out3) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'hour',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc3, 0, 'TW6 window text: exits 0') or diag($out3);
    like($out3, qr/^row: hour=2026-09-26T09:00Z \| 284 tokens, /m, 'TW6 window text: the 09:00Z row line matches');

    my ($rc4, $out4) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--by', 'role,hour');
    is($rc4, 0, 'TW6: --by role,hour exits 0') or diag($out4);
};

# ===========================================================================
# TW7 -- header line, exact text, both verbs.
# ===========================================================================
subtest 'TW7: the window header line is exact and correctly placed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc, 0, 'TW7 report-session: exits 0') or diag($out);
    my @lines = split(/\n/, $out);
    my ($wi) = grep { $lines[$_] =~ /^window:/ } (0 .. $#lines);
    my ($pi) = grep { $lines[$_] =~ /^pricing:/ } (0 .. $#lines);
    my ($bi) = grep { $lines[$_] =~ /^by:/ } (0 .. $#lines);
    ok(defined $wi, 'TW7 report-session: a window: line exists') or diag($out);
    is($lines[$wi] // '', 'window: [2026-09-26T08:00:00Z, 2026-09-26T10:00:00Z) UTC, requests in-window 4, outside-window 6 (no timestamp 2)',
        'TW7 report-session: window line matches exactly') if defined $wi;
    if (defined $wi && defined $pi) { is($wi, $pi + 1, 'TW7 report-session: window line immediately follows pricing:'); }
    if (defined $wi && defined $bi) { ok($wi < $bi, 'TW7 report-session: window line is before by:'); }

    my ($rc2, $out2) = run_spend('derive-session', '--session', $main,
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc2, 0, 'TW7 derive-session: exits 0') or diag($out2);
    my @lines2 = split(/\n/, $out2);
    my ($wi2) = grep { $lines2[$_] =~ /^window:/ } (0 .. $#lines2);
    my ($pi2) = grep { $lines2[$_] =~ /^pricing:/ } (0 .. $#lines2);
    my ($ri2) = grep { $lines2[$_] =~ /^requests:/ } (0 .. $#lines2);
    ok(defined $wi2, 'TW7 derive-session: a window: line exists') or diag($out2);
    if (defined $wi2 && defined $pi2) { is($wi2, $pi2 + 1, 'TW7 derive-session: window line immediately follows pricing:'); }
    if (defined $wi2 && defined $ri2) { ok($wi2 < $ri2, 'TW7 derive-session: window line is before requests:'); }

    my ($rc3, $out3) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--since', '2026-09-26T10:00:00Z');
    is($rc3, 0, 'TW7 unbounded until: exits 0') or diag($out3);
    like($out3, qr/^window: \[2026-09-26T10:00:00Z, -\) UTC, requests in-window 2, outside-window 8 \(no timestamp 2\)$/m,
        'TW7 unbounded until: the header shows "-" for the open side') or diag($out3);
};

# ===========================================================================
# TW8 -- no window, no change at all.
# ===========================================================================
subtest 'TW8: without --since/--until, output is byte-for-byte package 01' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root);
    is($rc, 0, 'TW8: report-session text exits 0') or diag($out);
    unlike($out, qr/^window:/m, 'TW8: no line starts window:');

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    is($rc2, 0, 'TW8: report-session json exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW8: doc unavailable', 2 unless $doc2;
        ok(!exists $doc2->{window}, 'TW8: no window key in report-session JSON');
        is_deeply([ sort keys %$doc2 ],
            [ sort qw(cost_basis price_source price_fetched_at pricing_status by data_root data_root_source rows totals attribution) ],
            'TW8: report-session top-level key set equals spec 01 SS3.1') or diag(join(',', sort keys %$doc2));
    }

    my ($rc3, $out3) = run_spend('derive-session', '--session', $main, '--json');
    is($rc3, 0, 'TW8: derive-session json exits 0') or diag($out3);
    my $doc3 = eval { JSON::PP->new->decode($out3) };
  SKIP: {
        skip 'TW8: derive doc unavailable', 3 unless $doc3;
        ok(!exists $doc3->{window}, 'TW8: no window key in derive-session JSON');
        is_deeply([ sort keys %$doc3 ],
            [ sort qw(cost_basis price_source price_fetched_at pricing_status cells totals unpriced anomaly record_counts agents) ],
            'TW8: derive-session top-level key set equals spec 01 SS3.1') or diag(join(',', sort keys %$doc3));
        my $bad = grep { exists $_->{in_window_requests} } @{ $doc3->{agents} // [] };
        is($bad, 0, 'TW8: no agents[] entry carries in_window_requests');
    }
};

# ===========================================================================
# TW9 -- attribution filtered by the window.
# ===========================================================================
subtest 'TW9: attribution sums only in-window requests; an all-outside agent is reported outside-window' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);
    # Deliberately no .dispatch-log records: absent any window, both
    # subagents are unattributed with reason no-dispatch-record.

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json',
        '--since', $SINCE_ISO, '--until', $UNTIL_ISO);
    is($rc, 0, 'TW9: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'TW9: stdout parses') or diag($out);
  SKIP: {
        skip 'TW9: doc unavailable', 6 unless $doc;
        is($doc->{attribution}{driver}{input}, 14, 'TW9: attribution.driver.input == 14 (R2+R3+R4)');
        is($doc->{attribution}{unattributed}{input}, 256, 'TW9: attribution.unattributed.input == 256 (a1, in-window)');
        my @agents = @{ $doc->{attribution}{agents} // [] };
        my ($a2) = grep { $_->{path} =~ /agent-a2/ } @agents;
        my ($a1) = grep { $_->{path} =~ /agent-a1/ } @agents;
        ok($a2, 'TW9: agent-a2 entry exists') or diag($JSON->encode(\@agents));
        ok($a1, 'TW9: agent-a1 entry exists') or diag($JSON->encode(\@agents));
        if ($a2) {
            is($a2->{reason}, 'outside-window', 'TW9: a2 (all outside) has reason outside-window');
            is($a2->{kind}, 'unattributed', 'TW9: a2 kind is unattributed');
            is($a2->{source}, 'none', 'TW9: a2 source is none');
        }
        if ($a1) {
            is($a1->{reason}, 'no-dispatch-record', 'TW9: a1 has reason no-dispatch-record');
        }
        my $rsum = 0;
        for my $t (qw(input output cache_write_5m cache_write_1h cache_write_unsplit cache_read)) {
            $rsum += $doc->{attribution}{reasons}{'outside-window'}{$t} // 0;
        }
        is($rsum, 0, 'TW9: reasons[outside-window] token sums are all 0 (a2 contributes nothing)');
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root, '--json');
    is($rc2, 0, 'TW9 no-window: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW9 no-window: doc unavailable', 1 unless $doc2;
        my ($a2b) = grep { $_->{path} =~ /agent-a2/ } @{ $doc2->{attribution}{agents} // [] };
        if ($a2b) { is($a2b->{reason}, 'no-dispatch-record', 'TW9 no-window: a2 reason is no-dispatch-record'); }
        else { fail('TW9 no-window: agent-a2 entry exists'); }
    }
};

# ===========================================================================
# TW10 -- the cache-write anomaly runs only over in-window requests.
# ===========================================================================
subtest 'TW10: the cache-write anomaly is windowed like everything else' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-w10');
    write_jsonl($main,
        assistant_rec(message_id => 'm-anom-1', input => 1, timestamp => iso(epoch(2026, 9, 26, 8, 10, 0)),
            cache_creation => 700),
        assistant_rec(message_id => 'm-anom-2', input => 1, timestamp => iso(epoch(2026, 9, 26, 11, 10, 0)),
            cache_creation => 700),
    );

    my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
    is($rc, 0, 'TW10 no-window: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
  SKIP: {
        skip 'TW10 no-window: doc unavailable', 1 unless $doc;
        is($doc->{anomaly}{count}, 1, 'TW10 no-window: anomaly.count == 1');
    }

    my ($rc2, $out2) = run_spend('derive-session', '--session', $main, '--json',
        '--since', '2026-09-26T08:00:00Z', '--until', '2026-09-26T10:00:00Z');
    is($rc2, 0, 'TW10 window: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
  SKIP: {
        skip 'TW10 window: doc unavailable', 1 unless $doc2;
        is($doc2->{anomaly}{count}, 0, 'TW10 window: anomaly.count == 0 (only one of the two requests is in-window)');
    }
};


# ===========================================================================
# TW11 -- invalid and inverted windows.
# ===========================================================================
subtest 'TW11: an invalid, missing, or inverted window exits 2 with the exact message, before any fetch' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = File::Spec->catfile($stubdir, 'stub.pl');
    open(my $sfh, '>', $stub) or die $!;
    print $sfh <<'STUB';
#!/usr/bin/env perl
open(my $fh, '>>', "$ENV{SPEND_STUB_COUNTER}") or die $!;
print $fh "$ARGV[0]\n";
close $fh;
print "ok\n200";
STUB
    close $sfh;

    my $NEED_VALID_TIME = qr/is not a valid time \(use YYYY-MM-DDTHH:MM\[:SS\]Z in UTC, or Nh, Nm or Nd\)/;

    my @cases = (
        # [ label, verb, extra_args, want_stderr_regex ]
        ['--since yesterday',              'report-session', ['--since', 'yesterday'],
            qr/^bp-spend: --since 'yesterday' $NEED_VALID_TIME$/],
        ['--until no-Z',                   'derive-session', ['--until', '2026-09-26T10:00:00'],
            qr/^bp-spend: --until '2026-09-26T10:00:00' $NEED_VALID_TIME$/],
        ['--since invalid day',            'report-session', ['--since', '2026-02-30T00:00:00Z'],
            qr/^bp-spend: --since '2026-02-30T00:00:00Z' $NEED_VALID_TIME$/],
        ['--since invalid hour',           'derive-session', ['--since', '2026-09-26T24:00:00Z'],
            qr/^bp-spend: --since '2026-09-26T24:00:00Z' $NEED_VALID_TIME$/],
        ['--since 5w',                     'report-session', ['--since', '5w'],
            qr/^bp-spend: --since '5w' $NEED_VALID_TIME$/],
        ['--since -3h',                    'derive-session', ['--since', '-3h'],
            qr/^bp-spend: --since '-3h' $NEED_VALID_TIME$/],
        ['--since 1.5h',                   'report-session', ['--since', '1.5h'],
            qr/^bp-spend: --since '1\.5h' $NEED_VALID_TIME$/],
        ["--since ''",                     'derive-session', ['--since', ''],
            qr/^bp-spend: --since '' $NEED_VALID_TIME$/],
        ['--since as last argv',           'report-session', ['--since'],
            qr/^bp-spend: --since '' $NEED_VALID_TIME$/],
        ['inverted --since/--until',       'derive-session',
            ['--since', '2026-09-26T10:00:00Z', '--until', '2026-09-26T08:00:00Z'],
            qr/^bp-spend: empty or inverted window: --since 2026-09-26T10:00:00Z is not before --until 2026-09-26T08:00:00Z$/],
        ['equal bounds',                   'report-session',
            ['--since', '2026-09-26T09:00:00Z', '--until', '2026-09-26T09:00:00Z'],
            qr/^bp-spend: empty or inverted window: --since 2026-09-26T09:00:00Z is not before --until 2026-09-26T09:00:00Z$/],
        ['relative inversion via --now',   'derive-session',
            ['--now', $NOW, '--since', '1h', '--until', '2h'],
            qr/^bp-spend: empty or inverted window: --since 2026-09-26T11:00:00Z is not before --until 2026-09-26T10:00:00Z$/],
        ['--now abc',                      'report-session', ['--now', 'abc'],
            qr/^bp-spend: --now 'abc' is not a whole-second epoch$/],
    );

    for my $case (@cases) {
        my ($label, $verb, $args, $stderr_re) = @$case;
        my $counter = File::Spec->catfile($stubdir, 'counter-' . int(rand(1e9)) . '.txt');
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
        local $ENV{SPEND_STUB_COUNTER}       = $counter;
        delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
        my @cli_args = ($verb, '--session', $main);
        push @cli_args, '--data-root', $data_root if $verb eq 'report-session';
        push @cli_args, @$args;
        my ($rc, $out) = run_spend(@cli_args);
        is($rc, 2, "TW11 [$label]: exits 2") or diag($out);
        like($out, $stderr_re, "TW11 [$label]: stderr matches exactly") or diag($out);
        ok(!-e $counter, "TW11 [$label]: never fetched");
    }
};

# ===========================================================================
# TW12 -- scope and dimensions.
# ===========================================================================
subtest 'TW12: --since/--until on fleet verbs, and hour repeated in --by' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(File::Spec->catfile($dir, 'runs', 'p.jsonl'),
        { type => 'system', subtype => 'init', cwd => '/x', session_id => 's', model => 'claude-sonnet-5' });

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'p', '--since', '1h');
    is($rc, 2, 'TW12: derive-package --since exits 2') or diag($out);
    like($out, qr/^bp-spend: --since\/--until only apply to derive-session or report-session$/m,
        'TW12: derive-package --since exact message') or diag($out);

    my ($rc2, $out2) = run_spend('derive-blueprint', '--run-dir', $dir, '--until', '1h');
    is($rc2, 2, 'TW12: derive-blueprint --until exits 2') or diag($out2);
    like($out2, qr/^bp-spend: --since\/--until only apply to derive-session or report-session$/m,
        'TW12: derive-blueprint --until exact message') or diag($out2);

    my $dir2 = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir2);
    my ($rc3, $out3) = run_spend('report-session', '--session', $main, '--by', 'hour,hour');
    is($rc3, 2, 'TW12: --by hour,hour exits 2') or diag($out3);
    like($out3, qr/role,blueprint,package,model,effort,token_type,hour/, 'TW12: --by error names the full dimension list')
        or diag($out3);
};

# ===========================================================================
# S1 (review 02-review.md) -- spec SS2.7's validation order: the existing
# --session/--data-root/--by checks come BEFORE --now/--since/--until.
# ===========================================================================
subtest 'S1: --session is required and checked before --since; --by is checked before --since' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    # report-session --since yesterday with NO --session: must exit 2 with
    # the "requires --session" error, not the --since parse error, per
    # SS2.7 step 1 (existing checks) preceding step 3 (--since).
    my ($rc, $out) = run_spend('report-session', '--since', 'yesterday');
    is($rc, 2, 'S1: report-session --since yesterday, no --session, exits 2') or diag($out);
    like($out, qr/^bp-spend: report-session requires --session PATH$/m,
        'S1: stderr is the requires --session error') or diag($out);
    unlike($out, qr/is not a valid time/, 'S1: stderr is NOT the --since parse error') or diag($out);

    # derive-session --since yesterday with NO --session: same requirement
    # applies to derive-session's own "requires --session" text.
    my ($rc1b, $out1b) = run_spend('derive-session', '--since', 'yesterday');
    is($rc1b, 2, 'S1: derive-session --since yesterday, no --session, exits 2') or diag($out1b);
    like($out1b, qr/^bp-spend: derive-session requires --session PATH$/m,
        'S1: derive-session stderr is the requires --session error') or diag($out1b);
    unlike($out1b, qr/is not a valid time/, 'S1: derive-session stderr is NOT the --since parse error') or diag($out1b);

    # A bad --by combined with a bad --since: --by's error is reported
    # first, per SS2.7's order (step 1 before step 3).
    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--by', 'bogus', '--since', 'not-a-time');
    is($rc2, 2, 'S1: bad --by + bad --since exits 2') or diag($out2);
    like($out2, qr/^bp-spend: --by 'bogus' is not a valid dimension list/m,
        'S1: stderr is the --by error, reported first') or diag($out2);
    unlike($out2, qr/--since 'not-a-time'/, 'S1: stderr does NOT contain the --since error') or diag($out2);
};

# ===========================================================================
# S3 (review 02-review.md) -- an absolute timestamp with a year below 1000
# is rejected, never silently resolved via Time::Local's two/three-digit-
# year convention (0150 -> 2050, 0000 -> 2000).
# ===========================================================================
subtest 'S3: a year below 1000 in --since is rejected, never accepted as a 2000s year' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $main = build_fixture_w($dir);
    my $data_root = data_root_for($dir);

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--json', '--since', '0150-01-01T00:00Z');
    is($rc, 2, 'S3: --since 0150-01-01T00:00Z exits 2') or diag($out);
    like($out, qr/^bp-spend: --since '0150-01-01T00:00Z' is not a valid time \(use YYYY-MM-DDTHH:MM\[:SS\]Z in UTC, or Nh, Nm or Nd\)$/,
        'S3: stderr is the exact invalid-time error') or diag($out);
    unlike($out, qr/2050/, 'S3: the year is never silently resolved to 2050') or diag($out);

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--data-root', $data_root,
        '--json', '--since', '0000-01-01T00:00Z');
    is($rc2, 2, 'S3: --since 0000-01-01T00:00Z also exits 2') or diag($out2);
    like($out2, qr/^bp-spend: --since '0000-01-01T00:00Z' is not a valid time \(use YYYY-MM-DDTHH:MM\[:SS\]Z in UTC, or Nh, Nm or Nd\)$/,
        'S3: stderr is the exact invalid-time error for 0000') or diag($out2);
    unlike($out2, qr/2000-01-01/, 'S3: the year is never silently resolved to 2000') or diag($out2);
};

done_testing();
