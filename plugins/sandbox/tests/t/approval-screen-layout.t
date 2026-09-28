#!/usr/bin/env perl
# platform: any
# 192 — the backpack approval screen's layout.
#
# WHY A SECURITY GATE HAS A LAYOUT ORACLE
#
# triage_model's own comment states the case: rendering only the item's NAME
# "made the screen approve, as root, text the operator was never shown". The
# commands are on screen precisely so they get read — so a layout that buries
# them defeats the reason the display exists. Operator, from a live launch:
# "Clunky, busy, hard to read. misaligned. this whole screen needs a UI UX
# redesign." almanac 20260909-223940-1a04.
#
# What was wrong, and what each AC pins:
#
#   * _detail_row pre-glued "label: value" into one display string and
#     _row_spans prepended two more columns to it, so all three rows of an item
#     rendered at one indent in one role — the agent-written, unbounded
#     `rationale` carrying the same weight as the command about to run as root,
#     and the whole block sitting at the item's own indent so nothing said which
#     item the commands belonged to.
#   * That single glued span is also what made the row's indent vanish on wrap
#     (20260909-223849-1870): the value started at one column and its own
#     continuation resumed at another.
#   * "1 item(s), 0 selected" on a walk whose label already says "item 1 of 1" —
#     multi-select language, a stray "(s)", and a row spent on bookkeeping in a
#     gate whose scarce resource is the rows that show commands.
#
# AC1  a detail row renders as indent + gutter-padded label + value, in spans
# AC2  detail rows are indented DEEPER than the item row they belong to
# AC3  install/verify take a different role from rationale
# AC4  every detail value starts in the same column
# AC5  a wrapped value's continuation lands under the value column
# AC6  the single-item walk shows no counter; a multi-item screen counts
#      approvals rather than "selections"
# AC7  state markers are padded so item names align across differing states
# AC8  the as-root warning is still on screen, in a critical role
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use tui::LaunchScreens;
use tui::Screen;
use tui::Layout;

sub item {
    my ($key, $rationale) = @_;
    return {
        _approval_key => $key,
        install       => "apt-get update -qq && apt-get install -y $key",
        verify        => "command -v $key",
        rationale     => $rationale,
    };
}

my $LONG = 'The JRM binds 127.0.0.1:8080, which is not in the sandbox published '
         . 'range, so /serve publishes it with a detached socat from '
         . '$SANDBOX_PORT_BASE to 127.0.0.1:8080 - without socat the board is '
         . 'unreachable from the browser. Present in the base image today but '
         . 'undeclared, so a rebuild could drop it.';

# ── model-level: the rows carry structure, not pre-glued presentation ──────
my $model = tui::LaunchScreens::triage_model([ item('socat', $LONG) ], [],
                                             label => 'backpack approval - item 1 of 1');
my @details = grep { ref $_ eq 'HASH' && exists $_->{detail_label} }
              @{ $model->{items} || [] };
is(scalar @details, 3, 'AC1 the item contributes three structured detail rows');
is_deeply([ map { $_->{detail_label} } @details ], [qw(install verify rationale)],
          'AC1 labelled install, verify, rationale, in that order');

# AC3 — the two commands and the prose are not the same kind of thing.
my %role_of = map { $_->{detail_label} => ($_->{detail_role} // '') } @details;
is($role_of{install}, $role_of{verify},
   'AC3 install and verify share one role');
isnt($role_of{rationale}, $role_of{install},
     'AC3 rationale is rendered in a different role from the commands');

# ── rendered: spans, columns, indents ─────────────────────────────────────
my $ls  = tui::LaunchScreens::list_init(model => $model);
my $COLS = 100;
my $scr = tui::LaunchScreens::list_screen($ls, $COLS, 30);

my @panel_lines = @{ $scr->{panels}[0]{lines} || [] };
my ($item_line) = grep { ref $_ eq 'ARRAY' } @panel_lines;
ok($item_line, 'fixture: the item row rendered');

sub line_text {
    my ($spans) = @_;
    return join('', map { defined $_->{text} ? $_->{text} : '' } @$spans);
}
sub lead {
    my ($s) = @_;
    return $s =~ /^( *)/ ? length($1) : 0;
}

my @texts = map { line_text($_) } grep { ref $_ eq 'ARRAY' } @panel_lines;
my ($item_txt, @detail_txt) = @texts;

# AC1 — three spans: whitespace indent, padded label, value.
my ($first_detail) = grep {
    ref $_ eq 'ARRAY' && @$_ == 3 && $_->[0]{text} =~ /^ +$/
} @panel_lines;
ok($first_detail, 'AC1 a detail row is three spans, opening with a pure-space indent');
like($first_detail->[1]{text}, qr/^install\s{2,}$/,
     'AC1 the label span is padded to a gutter rather than glued to its value');
like($first_detail->[2]{text}, qr/^apt-get /,
     'AC1 the value is a span of its own');

# AC2 — details sit deeper than the item row.
for my $d (@detail_txt) {
    next unless $d =~ /\S/;
    cmp_ok(lead($d), '>', lead($item_txt),
           'AC2 a detail row is indented deeper than its item row');
}

# AC4 — every value starts in one column.
my @value_cols;
for my $ln (@panel_lines) {
    next unless ref $ln eq 'ARRAY' && @$ln == 3 && $ln->[0]{text} =~ /^ +$/;
    next unless length $ln->[2]{text};
    push @value_cols, length($ln->[0]{text}) + length($ln->[1]{text});
}
is(scalar @value_cols, 3, 'AC4 three detail values rendered');
is(scalar(keys %{ { map { $_ => 1 } @value_cols } }), 1,
   'AC4 every detail value starts in the same column');

# AC5 — the wrapped rationale hangs to the value column.
my @rows = @{ tui::Screen::compose($scr, 30, $COLS) || [] };
my @flat = map {
    my $r = $_;
    my $t = ref $r eq 'HASH' ? ($r->{text} // '')
          : ref $r eq 'ARRAY' ? join('', map { $_->{text} // '' } @$r)
          : $r;
    $t =~ s/\s+$//;
    $t;
} @rows;

my ($rat_i) = grep { $flat[$_] =~ /^\s+rationale\s/ } 0 .. $#flat;
ok(defined $rat_i, 'fixture: the rationale row is on screen');
my $value_col = $value_cols[0];
if (defined $rat_i) {
    my @cont = grep { /\S/ } @flat[ $rat_i + 1 .. $#flat ];
    # Continuations run until the panel's closing rule.
    @cont = grep { !/^[─\s]*$/ } @cont;
    my @wrapped = grep { lead($_) >= $value_col } @cont;
    cmp_ok(scalar @wrapped, '>', 0, 'fixture: the long rationale really wraps');
    is(lead($wrapped[0]), $value_col,
       'AC5 a wrapped value resumes under the value column, not at the default indent');
}

# AC8 — the warning survived the redesign.
is($model->{notice}, tui::LaunchScreens::AS_ROOT_WARNING(),
   'AC8 the as-root warning is still declared by the model');
is($model->{notice_role}, 'state.crit', 'AC8 in a critical role');

# ── AC6/AC7 — the counter, and marker padding ─────────────────────────────
# The summary is the last line of the items panel, not a field of its own.
sub footer_summary {
    my ($m) = @_;
    my $l = tui::LaunchScreens::list_init(model => $m);
    my $s = tui::LaunchScreens::list_screen($l, $COLS, 30);
    my @lines = @{ $s->{panels}[0]{lines} || [] };
    return '' unless @lines;
    my $last = $lines[-1];
    return '' unless ref $last eq 'ARRAY';
    return join('', map { defined $_->{text} ? $_->{text} : '' } @$last);
}

my $one = footer_summary($model);
unlike($one, qr/item\(s\)/,
       'AC6 the single-item walk shows no "N item(s), M selected" tally');

my $multi = tui::LaunchScreens::triage_model(
    [ item('socat', 'short'), item('jq', 'short') ], [], label => 'backpack approval');
$multi->{items}[0]{state} = 'approve';
my $many = footer_summary($multi);
if (length $many) {
    like($many, qr/approved/, 'AC6 a multi-item screen counts approvals');
    unlike($many, qr/selected/, 'AC6 and does not call them selections');
}

# AC7 — differing states must not shift the names.
{
    my $ls2 = tui::LaunchScreens::list_init(model => $multi);
    my $s2  = tui::LaunchScreens::list_screen($ls2, $COLS, 30);
    my @item_rows = grep {
        ref $_ eq 'ARRAY' && grep { ($_->{text} // '') =~ /^\[/ } @$_
    } @{ $s2->{panels}[0]{lines} || [] };
    cmp_ok(scalar @item_rows, '>=', 2, 'fixture: two item rows rendered');
    # The name is the span after the cursor marker and the state mark, so its
    # column is the width of those two. DISPLAY width, not byte length: the
    # cursor glyph is multi-byte, so a byte count reports the cursor row two
    # columns wider than it renders and would fail an alignment that is correct.
    my %name_col;
    for my $r (@item_rows) {
        my $col = 0;
        $col += tui::Layout::display_width($r->[$_]{text} // '') for 0 .. 1;
        $name_col{$col} = 1;
    }
    is(scalar(keys %name_col), 1,
       'AC7 item names start in one column regardless of decision state');
}

done_testing();
