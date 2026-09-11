#!/usr/bin/env perl
# 191 — a wrapped row keeps the indent it arrived
# with, even when that indent is baked into a content span.
#
# WHAT WAS WRONG
#
# Frame::wrap_line's step (3a) splits every span on runs of spaces and drops a
# leading run (there is no preceding word to attach it to), so step (3a-pre)
# rescues the row's leading indent first. That rescue collected only spans that
# were ENTIRELY whitespace and stopped at the first span carrying content —
# right for the case it was written for (Screen.pm's own body indent, its own
# span) and wrong for the case where the indent is simply the first characters
# of a content span.
#
# LaunchScreens renders a subheader as ONE span, '  ' . $display, and
# launcher.pl's stale-sandbox reasons already carry a '  - ' prefix inside that
# display text. So the row arrives as a single span whose text starts with four
# spaces, the rescue stopped on iteration one, and line 0 was built from words
# alone. Operator-reported from the live stale-sandbox prompt:
#
#     |- Skills changed since container was created: 5 plugin added          |
#     |  (backpack@ccpraxis-local,...); 1 plugin removed                     |
#     |  (chrome-devtools-mcp@chrome-devtools-plugins)                       |
#     |    - Launcher scripts have changed since container was created       |
#
# Line 0 at column 0, its own continuations at 2, its unwrapped sibling at 4:
# three different indents in one block, and the wrapped row's first line sitting
# LEFT of the text continuing it. almanac 20260909-223849-1870.
#
# AC1  indent baked into a content span survives wrapping
# AC2  a wrapped row's line 0 aligns with an unwrapped sibling's
# AC3  continuation lines are MORE indented than line 0, not merely equal
# AC4  a pure-whitespace indent span still works (the case already fixed)
# AC5  a whitespace span followed by a content span's own leading run sums
# AC6  a row with no leading indent is unchanged
# AC7  the non-wrapping fast path is untouched
# AC8  every cell says whether it is a continuation, so nothing downstream has
#      to infer it from the shape of the first span
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use tui::Frame;

my $W    = 70;
my $CONT = 2;

sub texts {
    my ($line, @rest) = @_;
    return [ map { $_->{text} } @{ tui::Frame::wrap_line($line, 'text.muted', @rest ? @rest : ($W, $CONT)) } ];
}

sub lead {
    my ($s) = @_;
    return $s =~ /^( *)/ ? length($1) : 0;
}

# The exact shape LaunchScreens produces: '  ' prepended by _row_spans to a
# display string that already begins with launcher.pl's '  - ' prefix.
my $SHORT = '    - Launcher scripts have changed since container was created';
my $LONG  = '    - Skills changed since container was created: 5 plugin added'
          . ' (backpack@ccpraxis-local,blueprint@ccpraxis-local); 1 plugin removed'
          . ' (chrome-devtools-mcp@chrome-devtools-plugins)';

my $wrapped   = texts($LONG);
my $unwrapped = texts($SHORT);

cmp_ok(scalar @$wrapped, '>', 1, 'fixture: the long reason really does wrap');
is(scalar @$unwrapped, 1, 'fixture: the short reason really does not');

# AC1/AC2 — line 0 keeps the four columns it came with.
is(lead($wrapped->[0]), 4,
   'AC1 indent baked into a content span survives wrapping');
is(lead($wrapped->[0]), lead($unwrapped->[0]),
   'AC2 a wrapped row aligns with its unwrapped sibling');

# AC3 — continuations are deeper than line 0 (leading 4 + continuation 2).
for my $i (1 .. $#$wrapped) {
    cmp_ok(lead($wrapped->[$i]), '>', lead($wrapped->[0]),
           "AC3 continuation line $i is more indented than line 0");
}
is(lead($wrapped->[1]), 6,
   'AC3 continuation indent stacks on the leading indent rather than replacing it');

# Content fidelity: the fix must not eat or invent text.
my $rejoined = join(' ', map { my $t = $_; $t =~ s/^ +//; $t =~ s/ +$//; $t } @$wrapped);
(my $expect = $LONG) =~ s/^ +//;
is($rejoined, $expect, 'AC1 every word survives the wrap, in order');

# AC4 — the originally-fixed case: indent as its own pure-whitespace span.
{
    my $spans = [
        { text => '  ',                     role => 'text.muted' },
        { text => 'label with a great many words that will certainly need to wrap at seventy',
          role => 'text.muted' },
    ];
    my $cells = tui::Frame::wrap_line($spans, 'text.muted', $W, $CONT);
    my @t = map { $_->{text} } @$cells;
    cmp_ok(scalar @t, '>', 1, 'AC4 fixture wraps');
    is(lead($t[0]), 2, 'AC4 a pure-whitespace indent span still survives');
    cmp_ok(lead($t[1]), '>', lead($t[0]), 'AC4 continuation still deeper');
}

# AC5 — both sources of indent add up rather than one shadowing the other.
{
    my $spans = [
        { text => '  ',                     role => 'text.muted' },
        { text => '  - a reason long enough to force wrapping at seventy columns for sure',
          role => 'text.muted' },
    ];
    my $cells = tui::Frame::wrap_line($spans, 'text.muted', $W, $CONT);
    my @t = map { $_->{text} } @$cells;
    cmp_ok(scalar @t, '>', 1, 'AC5 fixture wraps');
    is(lead($t[0]), 4, 'AC5 whitespace span plus content-span run sum to four');
}

# AC6 — a row that never had a leading indent must not acquire one.
{
    my $flush = 'Skills changed since container was created and this line is long'
              . ' enough to wrap somewhere past seventy columns of display width';
    my $t = texts($flush);
    cmp_ok(scalar @$t, '>', 1, 'AC6 fixture wraps');
    is(lead($t->[0]), 0, 'AC6 a flush row stays flush on line 0');
    is(lead($t->[1]), $CONT,
       'AC6 continuation gets only the continuation indent');
}

# AC7 — no overflow, no change. wrap_line returns make_cell's output verbatim
# on the fast path, so the indent logic must not run at all.
{
    my $t = texts($SHORT);
    like($t->[0], qr/^\Q    - Launcher scripts\E/,
         'AC7 an unwrapped row is passed through with its indent intact');
    is(length($t->[0]), length($unwrapped->[0]),
       'AC7 fast path is stable across calls');
}

# AC8 — the continuation flag. Fixing the indent made line 0 carry a leading
# indent span of its own, which broke the one thing downstream code had to
# recognise a continuation by (dashboard-framework.t's banner counter, inferring it
# from the first span's role). The wrapper knows the answer, so it records it.
{
    my $cells = tui::Frame::wrap_line($LONG, 'text.muted', $W, $CONT);
    cmp_ok(scalar @$cells, '>', 1, 'AC8 fixture wraps to several cells');
    is($cells->[0]{continuation}, 0, 'AC8 the first row is not a continuation');
    for my $i (1 .. $#$cells) {
        is($cells->[$i]{continuation}, 1, "AC8 row $i is marked a continuation");
    }

    # The fast path returns one cell without entering the wrap loop, and it must
    # carry the flag too -- an unwrapped row is the first row of its own line.
    my $one = tui::Frame::wrap_line($SHORT, 'text.muted', $W, $CONT);
    is(scalar @$one, 1, 'AC8 the short row does not wrap');
    is($one->[0]{continuation}, 0, 'AC8 a single-row fast path still states it');

    # make_cell is the single cell constructor; the default belongs there.
    my $bare = tui::Frame::make_cell('anything', 'text.muted', $W);
    is($bare->{continuation}, 0, 'AC8 make_cell defaults the flag to 0');
}

done_testing();
