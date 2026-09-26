#!/usr/bin/env perl
# platform: any
# Unit tests for the select-session.pl picker's pure helpers — the load-
# bearing logic behind the scrolling/rendering TUI, testable without a real
# TTY by `require`-ing the script (its main flow is guarded by
# `unless (caller)`):
#
#   sanitize_cell  — strips terminal-control bytes from attacker-influenceable
#                    session text before it's rendered.
#   build_options  — "Start a new session" is always option 0; each session
#                    option carries a card built from the new SessionIndex-
#                    shaped session hash (blueprint sandbox-session-ux,
#                    package 03-picker-cards).
#   plan_frame     — the plain loop's row-budget chrome, unchanged by
#                    package 03.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, 'select-session.pl exists') or BAIL_OUT("script missing");

# Requiring the script must NOT run its main flow (it would call exit). The
# `unless (caller)` guard makes this safe and exposes the helpers in main::.
require $script;
pass('require did not run main() — caller guard holds');

# Strip ANSI to recover the visible payload of a clipped row.
sub visible { my $s = shift; $s =~ s/\e\[[0-9;]*[A-Za-z]//g; return $s; }

# ---------------------------------------------------------------------
# sanitize_cell($s)
# ---------------------------------------------------------------------
is(sanitize_cell("a\x1bb"),  "ab",  'ESC (0x1b) stripped');
is(sanitize_cell("a\x07b"),  "ab",  'BEL (0x07) stripped');
is(sanitize_cell("a\x7fb"),  "ab",  'DEL (0x7f) stripped');
is(sanitize_cell("a\tb\nc"), "abc", 'TAB/newline stripped');
is(sanitize_cell("caf\xc3\xa9"), "caf\xc3\xa9", 'printable multi-byte UTF-8 preserved');
{
    my $dirty = join('', map { chr } 0 .. 0x1f) . "ok\x7f";
    my $clean = sanitize_cell($dirty);
    unlike($clean, qr/[\x00-\x1f\x7f]/, 'no control bytes survive sanitize');
    is($clean, "ok", 'only printable payload remains');
}

# ---------------------------------------------------------------------
# build_options(@sessions) — "new" first + card built from the new,
# SessionIndex-shaped session hash (uuid, mtime, kind, started_at,
# last_active_at, first_typed, last_typed, same_message).
# ---------------------------------------------------------------------
{
    my @opts = build_options();
    is($opts[0]{action}, 'NEW', 'option 0 is always "Start a new session" (NEW)');
}
{
    my $sess = {
        uuid           => 'abcd1234-1111-2222-3333-444455556666',
        mtime          => 1_700_000_000,
        kind           => 'human',
        started_at     => 1_700_000_000,
        last_active_at => 1_700_000_000,
        first_typed    => "fix\x1bthe\x07bug",     # contains ESC + BEL injection bytes
        last_typed     => undef,
        same_message   => 1,
    };
    my @opts = build_options($sess);
    is(scalar @opts, 2,                  'one NEW + one session => 2 options');
    is($opts[0]{action}, 'NEW',          'NEW still first when sessions exist');
    like($opts[1]{action}, qr/^RESUME abcd1234-/, 'session yields RESUME <uuid>');
    unlike($opts[1]{label}, qr/\x1b/,    'no ESC byte survives into the session label');
    unlike($opts[1]{label}, qr/[\x00-\x08\x0e-\x1f\x7f]/, 'no control bytes in the label');
    like($opts[1]{label}, qr/fixthebug/, 'message text preserved minus the control bytes');
}
{
    # A message that is *only* control bytes collapses to the no-message marker.
    my $sess = {
        uuid           => '99999999-0000-0000-0000-000000000000',
        mtime          => 1_700_000_000,
        kind           => 'human',
        started_at     => 1_700_000_000,
        last_active_at => 1_700_000_000,
        first_typed    => "\x1b\x07\x00",
        last_typed     => undef,
        same_message   => 1,
    };
    my @opts = build_options($sess);
    like($opts[1]{label}, qr/\(no message\)/, 'all-control message => "(no message)"');
}

# ---------------------------------------------------------------------
# s14-session-filter (AC-18 -> DC-3): is_butler tagging on build_options.
# build_options' signature/return shape is otherwise unchanged (asserted
# above); requiring the script must still not run main() even though the
# script body now references the SessionFilter/SessionIndex packages (only
# reached from the `unless (caller)` entry point) — the existing
# `pass('require did not run main() — caller guard holds')` near the top of
# this file already covers that half of AC-18 and must stay green.
# ---------------------------------------------------------------------
{
    my @opts = build_options();
    is($opts[0]{action}, 'NEW', 'AC-18 -> DC-3: option 0 is still NEW with no sessions');
    ok(!exists $opts[0]{is_butler}, 'AC-18 -> DC-3: option 0 carries no is_butler key');
}
{
    my $butler_sess = {
        uuid           => 'ffffffff-1111-2222-3333-444455556666',
        mtime          => 1_700_000_000,
        kind           => 'human',
        started_at     => 1_700_000_000,
        last_active_at => 1_700_000_000,
        first_typed    => 'a butler-spawned session',
        last_typed     => undef,
        same_message   => 1,
        is_butler      => 1,
    };
    my $user_sess = {
        uuid           => '01234567-1111-2222-3333-444455556666',
        mtime          => 1_700_000_001,
        kind           => 'human',
        started_at     => 1_700_000_001,
        last_active_at => 1_700_000_001,
        first_typed    => 'a regular user session',
        last_typed     => undef,
        same_message   => 1,
        # no is_butler key at all
    };
    my @opts = build_options($butler_sess, $user_sess);
    is(scalar @opts, 3, 'AC-18 -> DC-3: one NEW + two sessions => 3 options');
    is($opts[1]{is_butler}, 1, 'AC-18 -> DC-3: a session with is_butler=>1 tags its option is_butler==1');
    is($opts[2]{is_butler}, 0, 'AC-18 -> DC-3: a session with no is_butler key tags its option is_butler==0');
    like($opts[1]{action}, qr/^RESUME \Qffffffff-1111-2222-3333-444455556666\E$/, 'AC-18 -> DC-3: action shape unchanged for the butler session');
    like($opts[2]{action}, qr/^RESUME \Q01234567-1111-2222-3333-444455556666\E$/, 'AC-18 -> DC-3: action shape unchanged for the user session');
}

# ---------------------------------------------------------------------
# plan_frame($rows, $n) — the frame must NEVER exceed the terminal height
# (otherwise it scrolls and reintroduces the bug), at any size, with cap >= 1.
# ---------------------------------------------------------------------
{
    my $overflow = 0;
    my $bad_cap  = 0;
    for my $rows (1 .. 40) {
        for my $n (0 .. 60) {
            my $L = plan_frame($rows, $n);
            my $max_height = $L->{head} + $L->{foot}
                           + ($L->{hints} ? 2 : 0) + $L->{cap};
            $overflow++ if $max_height > ($rows < 1 ? 1 : $rows);
            $bad_cap++  if $L->{cap} < 1;
        }
    }
    is($overflow, 0, 'plan_frame: frame height never exceeds the terminal at any size');
    is($bad_cap,  0, 'plan_frame: always leaves room for at least one option');
}
{
    # On a normal terminal the full chrome (title+rule+blank header, blank+keys
    # footer) is used; on a tiny one it degrades.
    my $big = plan_frame(40, 100);
    is($big->{head}, 3, 'normal terminal: full 3-row header');
    is($big->{foot}, 2, 'normal terminal: full 2-row footer');
    ok($big->{hints}, 'normal terminal with overflow: hints reserved');
    my $small = plan_frame(6, 100);
    ok($small->{head} <= 1, 'tiny terminal: header degraded');
    my $tiny = plan_frame(2, 100);
    ok($tiny->{head} + $tiny->{foot} + ($tiny->{hints} ? 2 : 0) + $tiny->{cap} <= 2,
       'rows=2: degenerate frame still fits');
}

done_testing();
