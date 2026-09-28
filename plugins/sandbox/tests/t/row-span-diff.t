#!/usr/bin/env perl
# platform: any
# Pins render_frame's SPAN-LEVEL row diff (the top-row spinner-flash fix):
# a changed row no longer always re-emits `\e[<row>;1H\e[K` + the whole row.
# It finds the longest common span PREFIX and span SUFFIX (role+text equal,
# scanned from each end) and, when the changed middle is the SAME display
# width on both sides, repositions to `spans_width(prefix)+1` and emits ONLY
# the new middle spans -- no `\e[K`, because nothing after it moved. A
# width-changing middle falls back to repainting from the middle through
# end-of-row, `\e[K`-terminated, exactly as a whole-row diff always has.
#
# Column arithmetic is asserted against a prefix containing a DOUBLE-WIDTH
# glyph whose UTF-8 byte length exceeds its display width, so a
# length()-instead-of-display_width() regression in the column math fails
# here rather than passing on an all-ASCII fixture that can't tell the two
# apart.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

use Test::More;
use Theme;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# A double-width glyph (Theme's fullwidth vertical line, U+FF5C): 3 UTF-8
# bytes, 2 display columns. Reused as the common, unchanging lead span in
# several fixtures below so any column math that used length() instead of
# display_width() lands on the wrong column and the assertion catches it.
my $WIDE = Theme::glyph('sep.bar');
is(Dashboard::display_width($WIDE), 2, 'fixture: WIDE glyph is 2 display columns');
ok(length($WIDE) > 2, 'fixture: WIDE glyph is MORE than 2 bytes (the length()-vs-display_width trap)');

# ===========================================================================
# 1. THE SPINNER CASE: an equal-width span changes in the middle of the row,
#    flanked by an unchanged prefix (containing the wide glyph) and an
#    unchanged suffix. The emitted diff must be positioned exactly at
#    spans_width(prefix)+1, carry ONLY the new middle span's text, and
#    contain NO \e[K anywhere.
# ===========================================================================
{
    my $prefix = { text => $WIDE, role => 'rule' };            # width 2, unchanged
    my $tail   = { text => ' tail', role => 'muted' };          # unchanged suffix

    my $prev_row = { role => 'body',
        spans => [ { %$prefix }, { text => 'A', role => 'accent' }, { %$tail } ] };
    my $new_row  = { role => 'body',
        spans => [ { %$prefix }, { text => 'B', role => 'accent' }, { %$tail } ] };

    my $diff = Dashboard::render_frame([$prev_row], [$new_row], { color => 0 });

    unlike($diff, qr/\e\[K/, 'spinner case: no \e[K anywhere in the emitted diff');
    is($diff, "\e[?2026h\e[1;3HB\e[?2026l",
        'spinner case: positioned at spans_width(prefix)+1 == 3 (2-column WIDE glyph, not its 3-byte length), middle-only text, no clear');
}

# ===========================================================================
# 2. A WIDTH-CHANGING MIDDLE falls back: repaint from the prefix boundary
#    through end-of-row (middle + unchanged suffix), terminated by \e[K to
#    clear whatever tail a shorter middle would otherwise leave stale.
# ===========================================================================
{
    my $prefix = { text => $WIDE, role => 'rule' };
    my $tail   = { text => ' tail', role => 'muted' };

    my $prev_row = { role => 'body',
        spans => [ { %$prefix }, { text => 'AA', role => 'accent' }, { %$tail } ] };  # mid width 2
    my $new_row  = { role => 'body',
        spans => [ { %$prefix }, { text => 'B',  role => 'accent' }, { %$tail } ] };  # mid width 1

    my $diff = Dashboard::render_frame([$prev_row], [$new_row], { color => 0 });

    like($diff, qr/\e\[1;3H/, 'width-change case: still positioned at the prefix boundary (col 3)');
    like($diff, qr/\e\[K\e\[\?2026l\z/,
        'width-change case: \e[K immediately precedes the synchronized-output end (nothing emitted after it)')
        or diag("diff was: " . _show($diff));
    like($diff, qr/B tail\e\[K/, 'width-change case: emits middle-through-end-of-row, then \e[K');
}

# ===========================================================================
# 3. A CHANGED LEADING SPAN WITH AN UNCHANGED TAIL -- the real top-row shape
#    (a status glyph up front, static text after it). The common-suffix scan
#    must kick in even though the common-PREFIX is empty (span 0 itself
#    differs), so the unchanged tail is never re-emitted.
# ===========================================================================
{
    my $tail = { text => ' tail', role => 'muted' };

    my $prev_row = { role => 'body', spans => [ { text => 'X', role => 'accent' }, { %$tail } ] };
    my $new_row  = { role => 'body', spans => [ { text => 'Y', role => 'accent' }, { %$tail } ] };

    my $diff = Dashboard::render_frame([$prev_row], [$new_row], { color => 0 });

    is($diff, "\e[?2026h\e[1;1HY\e[?2026l",
        'leading-span change: positioned at column 1 (empty prefix), emits ONLY the new lead span');
    unlike($diff, qr/tail/, 'leading-span change: the unchanged suffix is never re-emitted (suffix optimisation)');
}

# ===========================================================================
# 4. AN UNCHANGED ROW EMITS NOTHING AT ALL -- not even a cursor move.
# ===========================================================================
{
    my $row_a = { role => 'body', spans => [ { text => 'same', role => 'body' } ] };
    my $row_b = { role => 'body', spans => [ { text => 'same', role => 'body' } ] };  # distinct ref, same value

    my $diff = Dashboard::render_frame([$row_a], [$row_b], { color => 0 });
    is($diff, "\e[?2026h\e[?2026l", 'unchanged row: diff is just the synchronized-output wrapper, nothing else');
}

# ===========================================================================
# 5. A FULL REPAINT (first frame / resize) AND AN EXPLICIT {repaint=>1} still
#    emit EVERY row via the unchanged whole-row path (\e[<row>;1H\e[K + full
#    text) -- today's behaviour, untouched by the span-diff change.
# ===========================================================================
{
    my @rows = map {
        { role => 'body', spans => [ { text => "row$_", role => 'body' } ] }
    } (1, 2, 3);

    # (a) first frame: no prev -> full clear + every row via the whole-row path.
    my $full = Dashboard::render_frame(undef, \@rows, { color => 0 });
    like($full, qr/\e\[2J\e\[H/, 'full repaint: screen cleared once');
    my @full_moves = ($full =~ /\e\[(\d+);1H\e\[K/g);
    is_deeply(\@full_moves, [1, 2, 3], 'full repaint: every row emitted via \e[<row>;1H\e[K, in order');

    # (b) resize: row COUNT changes -> forces full, same whole-row shape.
    my @rows_wide = (@rows, { role => 'body', spans => [ { text => 'row4', role => 'body' } ] });
    my $resized = Dashboard::render_frame(\@rows, \@rows_wide, { color => 0 });
    like($resized, qr/\e\[2J\e\[H/, 'resize: screen cleared once (row count changed)');
    my @resized_moves = ($resized =~ /\e\[(\d+);1H\e\[K/g);
    is_deeply(\@resized_moves, [1, 2, 3, 4], 'resize: every row (including the new one) emitted via the whole-row path');

    # (c) explicit repaint: same shape, opts->{repaint} -> NOT cleared, but
    #     still every row via the whole-row path (not the span-diff path).
    my @rows_same = map {
        { role => 'body', spans => [ { text => "row$_", role => 'body' } ] }
    } (1, 2, 3);
    my $repaint = Dashboard::render_frame(\@rows, \@rows_same, { color => 0, repaint => 1 });
    unlike($repaint, qr/\e\[2J/, 'explicit repaint: no full clear');
    my @repaint_moves = ($repaint =~ /\e\[(\d+);1H\e\[K/g);
    is_deeply(\@repaint_moves, [1, 2, 3], 'explicit repaint: every row still emitted via the whole-row path, even though content is identical');
}

sub _show {
    my ($s) = @_;
    (my $out = $s) =~ s/\e/\\e/g;
    return $out;
}

done_testing();
