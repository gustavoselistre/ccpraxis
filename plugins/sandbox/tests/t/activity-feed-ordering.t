#!/usr/bin/env perl
# platform: any
# blueprint: sandbox-launcher-lifecycle, package 03-activity-feed-ordering
# (specs/03-activity-feed-ordering-spec.md). Written BLIND to
# tui::DashboardScreen.pm / Dashboard.pm / launcher.pl implementation -- from
# the spec only -- so it is an oracle, not an echo of whatever the
# implementer eventually writes. Do NOT weaken an assertion to make a future
# implementation's life easier.
#
# Coverage: AC1-AC5 (spec S4). AC6 (the activity-history.t regression guard)
# is a procedural "run that file directly, record exit code" step -- not an
# in-file assertion here; see this package's report.
#
# This file EXTENDS plugins/sandbox/tests/t/activity-history.t's scaffolding
# idiom (ev_line/write_log/touch_mtime/rlogs/rmerge, LaunchLog::format_event-
# based synthetic fixtures, eval-wrapped calls into not-yet-written subs) --
# per S4's explicit instruction, it does not reinvent fixture plumbing. There
# is no shared test-lib module for this scaffolding in plugins/sandbox/tests/,
# so the small helper set is duplicated verbatim here (same implementation,
# same names) rather than factored out -- matching what activity-history.t
# itself does relative to its own siblings.
#
# Hard constraints honoured here (spec S4.1 / AC1):
#   * PURE: no subprocesses, no network, no sleeping, no podman. Only
#     File::Temp directories and utime for mtime control.
#   * Fixture JSON lines are produced via LaunchLog::format_event(...) with
#     explicit epoch + pid, never hand-written JSON strings.
#   * mtimes are set explicitly via utime(), never inferred from write order.
#   * Every call into a not-yet-written sub (Dashboard::stitch_history_dividers)
#     is eval-wrapped (rstitch()) so a missing sub degrades to a clean
#     per-assertion FAIL rather than a fatal abort.
#   * tui::DashboardScreen is require'd under eval (matching dashboard-screen.t's
#     own $DS_OK idiom), never assumed loadable.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use List::Util qw(any);

use_ok('LaunchLog') or BAIL_OUT('LaunchLog.pm did not load');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $DS_OK = eval { require tui::DashboardScreen; 1 };
diag("  require tui::DashboardScreen failed: $@") unless $DS_OK;

# ===========================================================================
# Scaffolding -- duplicated verbatim from activity-history.t's idiom (S4:
# "do not reimplement fixture plumbing" is read here as "do not INVENT NEW
# machinery"; the actual sub bodies are the same ones activity-history.t uses).
# ===========================================================================

# write_log($path, @lines) -- write pre-formatted JSON-line strings (each
# produced by LaunchLog::format_event) to a fresh file. Zero @lines creates a
# genuinely empty (0-byte) file.
sub write_log {
    my ($path, @lines) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return $path;
}

# touch_mtime($path, $epoch) -- force mtime explicitly. Never inferred from
# write order (1s granularity is not reliable).
sub touch_mtime {
    my ($path, $t) = @_;
    utime($t, $t, $path) or diag("utime($t, $path) failed: $!");
}

# ev_line($type, $epoch, $pid, \%fields) -> one JSON line via the real
# formatter -- never a hand-written JSON string.
sub ev_line {
    my ($type, $epoch, $pid, $fields) = @_;
    return LaunchLog::format_event($type, $fields || {}, $epoch, $pid);
}

# slurp_lines($path) -> the file's lines (chomped), or () if unreadable.
sub slurp_lines {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $blob = <$fh>;
    close $fh;
    return () unless defined $blob && length $blob;
    my @lines = split /\n/, $blob;
    return @lines;
}

# basename_of($path) -> the trailing path component, slash-agnostic.
sub basename_of {
    my ($path) = @_;
    return $path unless defined $path;
    return ($path =~ m{([^/\\]+)$}) ? $1 : $path;
}

# rlogs(@args) -> LIST. Calls LaunchLog::recent_logs under eval; on ANY
# failure returns a sentinel that can never equal a real result.
sub rlogs {
    my @args = @_;
    my @r = eval { LaunchLog::recent_logs(@args) };
    return $@ ? ('::MISSING-SUB::recent_logs::') : @r;
}

# rmerge($groups, %opts) -> arrayref | undef. Calls LaunchLog::merge_sessions
# under eval; undef on any failure.
sub rmerge {
    my ($groups, %opts) = @_;
    my $r = eval { LaunchLog::merge_sessions($groups, %opts) };
    return $@ ? undef : $r;
}

# rstitch($hist_groups, $hist_epochs, $lt) -> arrayref | undef. Calls the NEW
# (not-yet-written, per S2b of the spec) Dashboard::stitch_history_dividers
# under eval; undef on any failure (including "Undefined subroutine", i.e.
# the sub not existing yet) -- callers never get a false pass from a missing
# sub.
sub rstitch {
    my ($hist_groups, $hist_epochs, $lt) = @_;
    my $r = eval { Dashboard::stitch_history_dividers($hist_groups, $hist_epochs, $lt) };
    return $@ ? undef : $r;
}

# hhmm_minutes($text) -> minutes-since-midnight parsed from a "HH:MM ..."
# prefix, or undef if it doesn't match. Used to assert DISPLAYED-time order
# without assuming any particular epoch->text formatting beyond HH:MM.
sub hhmm_minutes {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /^(\d\d):(\d\d)/;
    return $1 * 60 + $2;
}

# is_nondecreasing(\@nums) -> true iff every element is >= its predecessor.
sub is_nondecreasing {
    my ($nums) = @_;
    for my $i (1 .. $#$nums) {
        return 0 if $nums->[$i] < $nums->[ $i - 1 ];
    }
    return 1;
}

# A safe, deterministic, mid-day UTC base epoch (2023-11-15T10:20:00Z) -- far
# from any midnight/day-rollover boundary, so HH:MM lexical comparison always
# agrees with chronological order for the small (<1h) offsets used below.
my $BASE = 1_700_043_600;
my $GM   = \&CORE::gmtime;

# ===========================================================================
# AC5 (done criterion 4) -- construction site named. Per the spec, this is a
# documentation/citation requirement, not an additional runtime assertion:
# "no additional test assertion required beyond the citation existing in
# this spec and being carried into the package's Outputs." Recorded here as
# a `pass()` (mirroring activity-history.t's own AC22 citation-pass idiom)
# so the mapping table has a citable line and the file's assertion count
# reflects it, without inventing behavior to check.
# ===========================================================================
pass('AC5: construction site is tui::DashboardScreen::collapse_records '
    . '(tui/DashboardScreen.pm:323-341), called from Dashboard::recent_events '
    . '(Dashboard.pm:1530) -- cited per spec S1/S4 AC5, no separate runtime check required');

# ===========================================================================
# AC2a -- direct collapse_records fixture (spec S3 item 1 / S4 AC2, first
# half). MUST FAIL against today's unmodified collapse_records: rec A+B
# collapse into one record (epoch=1010, count=2) that stays at ARRAY POSITION
# 0 (the position of the run's first member), while rec C (epoch=1005, a
# different role, so it never joins the run) sits at position 1 -- output
# epochs by position are [1010, 1005], decreasing. After S2a's fix lands, the
# post-collapse reorder pass produces [1005, 1010] (non-decreasing).
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 6) unless $DS_OK;

        my @recs = (
            { epoch => 1000, body => 'poll',  role => 'muted',  glyph => '*' },   # A
            { epoch => 1010, body => 'poll',  role => 'muted',  glyph => '*' },   # B -- consecutive run with A
            { epoch => 1005, body => 'alert', role => 'accent', glyph => '!' },   # C -- different role, no merge
        );
        my $out = eval { tui::DashboardScreen::collapse_records(\@recs) };
        ok(!$@, 'AC2a precondition: collapse_records does not die on the A/B/C fixture') or diag($@);

        if (ref($out) eq 'ARRAY') {
            is(scalar(@$out), 2, 'AC2a: A+B collapse to 1 record, C stays separate -- 2 records total');

            my @epochs = map { $_->{epoch} } @$out;
            is_deeply(\@epochs, [ 1005, 1010 ],
                'AC2a (CANONICAL, fails pre-fix): output epochs in array order are [1005, 1010] -- '
              . 'non-decreasing by DISPLAYED epoch, coalesced group included');

            my ($collapsed) = grep { exists $_->{count} } @$out;
            if ($collapsed) {
                is($collapsed->{count}, 2, 'AC2a: the collapsed A+B record carries count == 2');
                is($collapsed->{epoch}, 1010, 'AC2a: the collapsed record still carries the NEWEST member\'s epoch (1010)');
            }
            else {
                fail('AC2a: the collapsed A+B record carries count == 2');
                fail('AC2a: the collapsed record still carries the NEWEST member\'s epoch (1010)');
            }

            my ($alert_rec) = grep { $_->{body} eq 'alert' } @$out;
            ok(defined($alert_rec), 'AC2a: the C (alert) record survives uncollapsed');
            ok(!(exists $alert_rec->{count}), 'AC2a: the C (alert) record carries no count key') if $alert_rec;
        }
        else {
            fail('AC2a: A+B collapse to 1 record, C stays separate -- 2 records total');
            fail('AC2a (CANONICAL, fails pre-fix): output epochs in array order are [1005, 1010]');
            fail('AC2a: the collapsed A+B record carries count == 2');
            fail('AC2a: the collapsed record still carries the NEWEST member\'s epoch (1010)');
            fail('AC2a: the C (alert) record survives uncollapsed');
        }
    }
}

# ===========================================================================
# AC2b -- end-to-end fixture through Dashboard::recent_events (spec S3 item 2
# / S4 AC2, second half). Same scenario as AC2a, but fed through real
# LaunchLog::format_event lines and the real recent_events render path, so
# the assertion is against the RENDERED HH:MM text order, not the internal
# record shape.
# ===========================================================================
{
    my $epoch1 = $BASE;         # poll  -- 10:20:00Z
    my $epoch3 = $BASE + 300;   # alert -- 10:25:00Z (falls BETWEEN epoch1 and epoch2)
    my $epoch2 = $BASE + 900;   # poll  -- 10:35:00Z (spaced >=60s so HH:MM differs from epoch1's)

    my @lines = (
        ev_line('poll',  $epoch1, 801),
        ev_line('poll',  $epoch2, 801),
        ev_line('alert', $epoch3, 802),
    );
    my $ev = eval { Dashboard::recent_events(\@lines, 10, $GM, $BASE + 2000) };
    ok(!$@, 'AC2b precondition: Dashboard::recent_events does not die on the poll/poll/alert fixture') or diag($@);

    if (ref($ev) eq 'ARRAY') {
        my @texts   = map { Dashboard::spans_text($_) } @$ev;
        my @minutes = map { hhmm_minutes($_) } @texts;

        ok(!(grep { !defined $_ } @minutes), 'AC2b precondition: every rendered row has a parseable HH:MM prefix')
            or diag('  rows: ' . join(' | ', map { defined($_) ? $_ : '<undef>' } @texts));

        ok(is_nondecreasing(\@minutes),
            'AC2b (CANONICAL, fails pre-fix): rendered HH:MM text order is non-decreasing across the '
          . 'poll/poll/alert fixture (the collapsed poll group and the alert record end up correctly ordered)')
            or diag('  HH:MM order seen: ' . join(' | ', map { defined($_) ? $_ : '<undef>' } @texts));
    }
    else {
        fail('AC2b precondition: every rendered row has a parseable HH:MM prefix');
        fail('AC2b (CANONICAL, fails pre-fix): rendered HH:MM text order is non-decreasing');
    }
}

# ===========================================================================
# AC3/AC4 -- three distinct prior sessions + one current session (spec S3
# item 4 / S4 AC3, AC4). Drives the NEW Dashboard::stitch_history_dividers
# (does not exist yet -- rstitch() degrades to undef, which fails every
# assertion below for the RIGHT reason: missing implementation, not a typo).
# ===========================================================================
{
    my $dir  = tempdir(CLEANUP => 1);
    my $BASE2 = $BASE + 10_000;   # 13:26:40Z -- still same day, well clear of midnight

    my %epoch_of = (
        a1 => $BASE2 + 0,   a2 => $BASE2 + 60,
        b1 => $BASE2 + 120, b2 => $BASE2 + 180,
        c1 => $BASE2 + 240, c2 => $BASE2 + 300,
        cur1 => $BASE2 + 360, cur2 => $BASE2 + 420,
    );

    my $a_path = "$dir/launch-hA.log";
    write_log($a_path, ev_line('sess-a1', $epoch_of{a1}, 901), ev_line('sess-a2', $epoch_of{a2}, 901));
    touch_mtime($a_path, $BASE2 + 0);

    my $b_path = "$dir/launch-hB.log";
    write_log($b_path, ev_line('sess-b1', $epoch_of{b1}, 902), ev_line('sess-b2', $epoch_of{b2}, 902));
    touch_mtime($b_path, $BASE2 + 10);

    my $c_path = "$dir/launch-hC.log";
    write_log($c_path, ev_line('sess-c1', $epoch_of{c1}, 903), ev_line('sess-c2', $epoch_of{c2}, 903));
    touch_mtime($c_path, $BASE2 + 20);

    my $cur_path = "$dir/launch-CUR.log";
    write_log($cur_path, ev_line('sess-cur1', $epoch_of{cur1}, 904), ev_line('sess-cur2', $epoch_of{cur2}, 904));
    touch_mtime($cur_path, $BASE2 + 100_000);

    my @prior_paths_newest_first = rlogs($dir, 5, 'launch-CUR.log');
    my @prior_paths_oldest_first = reverse @prior_paths_newest_first;
    is(scalar(@prior_paths_oldest_first), 3, 'AC3/4 setup: exactly 3 prior-session logs found, oldest first')
        or diag('  paths: ' . join(' | ', map { basename_of($_) } @prior_paths_oldest_first));

    my @hist_groups;
    for my $p (@prior_paths_oldest_first) {
        my @lines = slurp_lines($p);
        my $grp   = eval { Dashboard::recent_events(\@lines, 10, $GM, $BASE2 + 200_000) };
        push @hist_groups, (ref($grp) eq 'ARRAY') ? $grp : [];
    }
    my @hist_epochs = ($epoch_of{a2}, $epoch_of{b2}, $epoch_of{c2});   # each group's own newest-member epoch

    my $hist_flat = rstitch(\@hist_groups, \@hist_epochs, $GM);
    ok(ref($hist_flat) eq 'ARRAY',
        'AC3/4: Dashboard::stitch_history_dividers(...) returns an arrayref (fails until the sub exists)');

    my @cur_lines = slurp_lines($cur_path);
    my $cur       = eval { Dashboard::recent_events(\@cur_lines, 50, $GM, $BASE2 + 200_000) };
    my $marker    = eval { Dashboard::session_boundary_row($hist_epochs[-1], $GM) };
    my $merged    = (ref($hist_flat) eq 'ARRAY' && ref($cur) eq 'ARRAY')
        ? rmerge([ $hist_flat, $cur ], max => 100, marker => $marker)
        : undef;

    if (ref($merged) eq 'ARRAY') {
        my @texts = map { Dashboard::spans_text($_) } @$merged;

        # -- tag each row by which synthetic session it belongs to, or 'divider'.
        my @tags = map {
            my $t = $_;
            if    ($t =~ /previous session/)  { 'divider' }
            elsif ($t =~ /sess-a\d/)          { 'A' }
            elsif ($t =~ /sess-b\d/)          { 'B' }
            elsif ($t =~ /sess-c\d/)          { 'C' }
            elsif ($t =~ /sess-cur\d/)        { 'cur' }
            else                              { 'other' }
        } @texts;

        my @divider_idx = grep { $tags[$_] eq 'divider' } (0 .. $#tags);
        is(scalar(@divider_idx), 3,
            'AC3 (CANONICAL, fails pre-fix): exactly 3 session-divider rows appear -- one per prior session')
            or diag('  tags: ' . join(' | ', @tags));

        # -- split into segments by divider position; each segment must be
        #    non-empty and internally single-tagged (no mixing of two
        #    sessions' rows between two consecutive dividers, or between a
        #    divider and a list boundary).
        my @bounds = (-1, @divider_idx, scalar(@tags));
        my @segments;
        for my $i (0 .. $#bounds - 1) {
            my ($lo, $hi) = ($bounds[$i] + 1, $bounds[ $i + 1 ] - 1);
            push @segments, [ $lo, $hi ] if $lo <= $hi;
        }
        is(scalar(@segments), 4,
            'AC3/4: the 3 dividers split the list into exactly 4 non-empty session blocks (A, B, C, cur)')
            or diag('  segments: ' . join(' | ', map { "[$_->[0]..$_->[1]]" } @segments));

        my $mixed = 0;
        for my $seg (@segments) {
            my @seg_tags = @tags[ $seg->[0] .. $seg->[1] ];
            my %uniq = map { $_ => 1 } @seg_tags;
            $mixed++ if scalar(keys %uniq) != 1;
        }
        is($mixed, 0, 'AC3: no session block mixes rows from two different sessions');

        # -- AC4: within each block, displayed (HH:MM) order is non-decreasing.
        my $bad_order = 0;
        for my $seg (@segments) {
            my @seg_texts   = @texts[ $seg->[0] .. $seg->[1] ];
            my @seg_minutes = map { hhmm_minutes($_) } @seg_texts;
            $bad_order++ unless is_nondecreasing(\@seg_minutes);
        }
        is($bad_order, 0, 'AC4: every session block is internally non-decreasing in displayed (HH:MM) order');
    }
    else {
        fail('AC3 (CANONICAL, fails pre-fix): exactly 3 session-divider rows appear -- one per prior session');
        fail('AC3/4: the 3 dividers split the list into exactly 4 non-empty session blocks (A, B, C, cur)');
        fail('AC3: no session block mixes rows from two different sessions');
        fail('AC4: every session block is internally non-decreasing in displayed (HH:MM) order');
    }
}

# ===========================================================================
# Redteam-01 regression -- collapse_records's post-collapse sort comparator
# used to switch its comparison CRITERION (value vs. original index)
# depending on whether the pair being compared had both epochs defined. That
# shape is non-transitive: Perl's sort gives no consistency guarantee for a
# non-transitive comparator, and it demonstrably placed two DEFINED epochs
# out of order relative to each other whenever an undefined-epoch record sat
# between them. Exact repro from
# .ccpraxis-local-data/blueprints/sandbox-launcher-lifecycle/reports/
# 03-activity-feed-ordering/redteam-01.md: 6 records, distinct bodies (so
# the merge loop is a no-op and only the reorder pass is exercised),
# U1(undef) A(100) C(50) B(1) U2(undef) D(2) in that input array order.
# Pre-fix this produced U1, B(1), C(50), A(100), U2, D(2) -- A(100) at
# output position 3 preceding D(2) at output position 5, violating the
# spec's own pinned postcondition (S2a: "for any two records at output
# positions i < j whose epoch is defined on both, out[i]{epoch} <=
# out[j]{epoch}").
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 2) unless $DS_OK;

        my @recs = (
            { epoch => undef, body => 'u1', role => 'muted',  glyph => '*' },   # U1
            { epoch => 100,   body => 'a',  role => 'muted',  glyph => '*' },   # A
            { epoch => 50,    body => 'c',  role => 'muted',  glyph => '*' },   # C
            { epoch => 1,     body => 'b',  role => 'muted',  glyph => '*' },   # B
            { epoch => undef, body => 'u2', role => 'muted',  glyph => '*' },   # U2
            { epoch => 2,     body => 'd',  role => 'muted',  glyph => '*' },   # D
        );
        my $out = eval { tui::DashboardScreen::collapse_records(\@recs) };
        ok(!$@, 'redteam-01 fixture: collapse_records does not die on the U1/A/C/B/U2/D fixture') or diag($@);

        if (ref($out) eq 'ARRAY') {
            # Pinned postcondition: for any two output positions i < j whose
            # epoch is defined on BOTH, out[i]{epoch} <= out[j]{epoch}.
            # Undefined-epoch entries are simply skipped -- only the
            # subsequence of DEFINED epochs, in output order, is checked for
            # non-decreasing-ness.
            my @defined_epochs_in_order = map { $_->{epoch} }
                                           grep { defined $_->{epoch} } @$out;
            ok(is_nondecreasing(\@defined_epochs_in_order),
                'redteam-01 (CANONICAL, fails pre-fix): the subsequence of defined epochs in output '
              . 'order is non-decreasing, even with undefined-epoch records interleaved')
                or diag('  defined-epoch subsequence seen: ' . join(', ', @defined_epochs_in_order)
                       . '; full output body order: ' . join(', ', map { $_->{body} } @$out));
        }
        else {
            fail('redteam-01 (CANONICAL, fails pre-fix): the subsequence of defined epochs in output order is non-decreasing');
        }
    }
}

# ===========================================================================
# Redteam-01 regression, property-style -- exhaustive over all 720
# permutations of the same 6-record set {A=100, B=1, C=50, D=2, U1=undef,
# U2=undef} (redteam's own sweep found 476/720 orderings triggered the
# violation pre-fix). Exhaustive is cheap here (720 permutations of 6
# elements, pure in-process calls, no I/O) so there is no reason to sample.
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;

        my @base = (
            { epoch => 100,   body => 'a',  role => 'muted' },   # A
            { epoch => 1,     body => 'b',  role => 'muted' },   # B
            { epoch => 50,    body => 'c',  role => 'muted' },   # C
            { epoch => 2,     body => 'd',  role => 'muted' },   # D
            { epoch => undef, body => 'u1', role => 'muted' },   # U1
            { epoch => undef, body => 'u2', role => 'muted' },   # U2
        );

        # Heap's algorithm -- generate all permutations of indices 0..5
        # without pulling in a non-core module.
        my @perms;
        my $permute;
        $permute = sub {
            my ($k, $arr) = @_;
            if ($k == 1) {
                push @perms, [ @$arr ];
                return;
            }
            for my $i (0 .. $k - 1) {
                $permute->($k - 1, $arr);
                if ($k % 2 == 0) {
                    @$arr[$i, $k - 1] = @$arr[$k - 1, $i];
                }
                else {
                    @$arr[0, $k - 1] = @$arr[$k - 1, 0];
                }
            }
        };
        $permute->(6, [ 0 .. 5 ]);

        my $violations = 0;
        for my $p (@perms) {
            my @recs = map { { %{ $base[$_] } } } @$p;
            my $out = eval { tui::DashboardScreen::collapse_records(\@recs) };
            if (ref($out) ne 'ARRAY') {
                $violations++;
                next;
            }
            my @defined_epochs_in_order = map { $_->{epoch} }
                                           grep { defined $_->{epoch} } @$out;
            $violations++ unless is_nondecreasing(\@defined_epochs_in_order);
        }
        is($violations, 0,
            'redteam-01 exhaustive sweep: 0/720 permutations of {A=100,B=1,C=50,D=2,U1=undef,U2=undef} '
          . 'violate the defined-epoch non-decreasing postcondition');
    }
}

# ===========================================================================
# almanac 20260919-000106-2bdd -- launcher.pl's _row_time_key(), the key
# extractor s16's merge_by_key(key => \&_row_time_key) call actually uses,
# required "HH:MM:SS" but Dashboard.pm's current wall-clock renderer
# (activity_time_text(_local_hhmm(...))) only ever emits "HH:MM". Every row
# therefore keyed to undef, and the cross-source interleave silently
# degraded to source-order fallback for every pair, always -- confirmed by
# direct reading of both call sites, not merely asserted here.
#
# launcher.pl is NEVER require'd/do'ne by this suite (real side effects: raw
# terminal, live subprocess, blocking keypress). Per the house technique
# (precedent: container-health-detect.t, wt-profile-spawn.t), the function is
# slurped as source text from its sentinel-delimited region and eval'd into a
# fresh package, so the tested code and the production code are the same sub.
# ===========================================================================
{
    my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
    my $src = do {
        open my $fh, '<:raw', $LAUNCHER or die "cannot read $LAUNCHER: $!";
        local $/;
        <$fh>;
    };

    my $BEGIN = '# >>> s-rowtimekey:BEGIN';
    my $END   = '# <<< s-rowtimekey:END';
    my ($region) = $src =~ /\Q$BEGIN\E\n(.*?)\Q$END\E/s;

    my $KEY;
    if (!defined $region) {
        ok(0, 'extraction: the s-rowtimekey region evals cleanly into a fresh package (region not found in launcher.pl)');
        ok(0, "extraction: the resulting package ->can('_row_time_key') (region not found)");
    } else {
        my $harness = "package RowTimeKey;\nuse strict;\nuse warnings;\n" . $region . "\n1;\n";
        my $eval_ok = eval $harness;   ## no critic
        ok($eval_ok, 'extraction: the s-rowtimekey region evals cleanly into a fresh package under use strict/warnings')
            or diag("eval error: $@");
        if ($eval_ok) {
            $KEY = RowTimeKey->can('_row_time_key');
            ok(defined $KEY, "extraction: the resulting package ->can('_row_time_key')");
        } else {
            ok(0, "extraction: the resulting package ->can('_row_time_key') (region failed to eval)");
        }
    }

    SKIP: {
        skip '_row_time_key not extractable -- see extraction failure above', 6 unless $KEY;

        # THE REPORTED BUG, pinned as a regression: the actual rendered shape
        # ("HH:MM " -- activity_time_text pads with a trailing space) must
        # produce a DEFINED key, not undef. Before the fix this returned
        # undef for every row shaped like this, because the regex demanded a
        # ":SS" that this renderer has never emitted.
        is($KEY->([ { text => '17:43 ' } ]), 17 * 3600 + 43 * 60,
            'AC: "HH:MM " (the real renderer shape, no seconds) now yields a defined, correct key');
        is($KEY->([ { text => '00:00 ' } ]), 0,
            'AC: "00:00 " yields key 0');
        is($KEY->([ { text => '23:59 ' } ]), 23 * 3600 + 59 * 60,
            'AC: "23:59 " yields the expected end-of-day key');

        # Back-compat: an "HH:MM:SS"-shaped input (should this renderer ever
        # regain seconds) still parses, seconds included.
        is($KEY->([ { text => '09:05:07 muted event text' } ]), 9 * 3600 + 5 * 60 + 7,
            'AC (back-compat): "HH:MM:SS" text still yields a seconds-precise key');

        # Genuinely unparseable/malformed input still degrades to undef, not
        # a crash or a fabricated key -- merge_by_key's documented contract.
        is($KEY->([ { text => 'not a time' } ]), undef,
            'AC: unparseable text still yields undef (merge_by_key source-order fallback)');
        is($KEY->([]), undef,
            'AC: a malformed row (no elements) still yields undef, no crash');
    }
}

done_testing();
