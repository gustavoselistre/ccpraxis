#!/usr/bin/env perl
# A USAGE READING THAT CONTRADICTS ITSELF MUST NOT REACH A GATE.
#
# Measured over roughly forty minutes in one session, no config change between:
#
#   22:32Z  5h 18%  resets 2026-09-12T02:00Z   7d 79%   plausible
#   23:00Z  5h 35%  resets 2026-09-10T03:49Z   7d 40%   IMPOSSIBLE
#   23:25Z  5h 24%  resets 2026-09-12T02:00Z   7d 80%   plausible again
#
# The middle reading is self-inconsistent on its own terms. A window that resets
# every five hours cannot have a reset time thirty-six hours in the past, and its
# seven-day figure halved and then recovered with no boundary crossed. The record
# carries its own evidence of being wrong, and nothing was reading it (almanac
# 20260911-224528-e213).
#
# butler GATES on this. A reading wrong by forty percentage points either halts
# work that should proceed or lets work run past a ceiling, and the operator only
# caught it because they had started checking reset stamps by habit after being
# burned earlier the same session. A gate has no habits.
#
# WHY REFUSING IS CHEAP HERE, which is the argument for putting the check in the
# contract rather than somewhere more careful: bp-usage-gate.pl routes a
# validate_usage failure to action=unavailable, reason=telemetry. That is "no
# reading", not "pause". A false positive costs one skipped poll. A false
# negative is a gate acting on a number that cannot be true.
#
# AND WHY THE BOUNDS ARE LOOSE. b28 is the cautionary tale inside this very
# function: an over-strict usage contract false-positived a drift and paused
# whole unattended fleets. Section D exists to keep that from happening again.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $CONTRACT = "$Bin/../../scripts/bp-contract.pl";
ok(-f $CONTRACT, 'bp-contract.pl is present') or BAIL_OUT('no bp-contract.pl');

# The script defines package BpContract; load it without running its main.
my $ok = do $CONTRACT;
ok(defined &BpContract::validate_usage, 'validate_usage is loadable')
    or BAIL_OUT("could not load bp-contract.pl: $@ $!");

# A fixed clock, so nothing here depends on when it runs.
my $NOW = 1_789_000_000;                      # some Wednesday
sub iso { my $e = shift; my @t = gmtime($e);
          sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]) }

sub usage {
    my (%o) = @_;
    return {
        five_hour => { utilization => $o{u5} // 18, resets_at => $o{r5} // iso($NOW + 3600) },
        seven_day => { utilization => $o{u7} // 79, resets_at => $o{r7} // iso($NOW + 3 * 86400) },
    };
}

sub check { my ($d) = @_; my ($v, $probs) = BpContract::validate_usage($d, $NOW); return ($v, join('; ', @{ $probs || [] })) }

# ===========================================================================
# A. THE MEASURED READING.
# ===========================================================================
my ($ok_good) = check(usage());
ok($ok_good, 'A1: an ordinary forward-dated reading validates');

my ($ok_bad, $why) = check(usage(r5 => iso($NOW - 36 * 3600), u5 => 35, u7 => 40));
ok(!$ok_bad, 'A2: the reading measured at 23:00Z -- a 5-hour window that reset 36 hours ago -- is REFUSED');
like($why, qr/five_hour/, 'A3: ... and the complaint names the window');
like($why, qr/past/i,     'A4: ... and says what is wrong with it, not merely that something is');

# ===========================================================================
# B. THE PAST BOUNDARY. A grace window absorbs host/server clock skew; beyond it,
# no correct server could have emitted the stamp. There is no future boundary --
# see the note below, which is a decision rather than an omission.
# ===========================================================================
ok((check(usage(r5 => iso($NOW - 60))))[0],
   'B1: a stamp a minute in the past is ACCEPTED -- that is skew, not corruption');
ok(!(check(usage(r5 => iso($NOW - 4 * 3600))))[0],
   'B2: a stamp four hours in the past is refused');
# NO UPPER BOUND, DELIBERATELY. A stamp further ahead than one window allows is
# also impossible for a correct server -- and refusing it broke this repo's own
# fixtures, where '2099-01-01T00:00:00Z' is the established idiom for "definitely
# not expired". The measured defect was a PAST stamp; b28, in this same
# function, is the standing warning about tightening a usage contract past the
# evidence. These two assertions pin the absence so it reads as a decision.
ok((check(usage(r5 => iso($NOW + 9 * 3600))))[0],
   'B3: a far-future stamp is ACCEPTED -- no upper bound, so the 2099 fixture idiom keeps working');
ok((check(usage(r5 => '2099-01-01T00:00:00Z')))[0],
   'B4: ... that exact idiom, as used throughout usage-governor.t');

# The seven-day window gets its own span, not the five-hour one.
ok((check(usage(r7 => iso($NOW + 6 * 86400))))[0],
   'B5: six days ahead is fine for the seven-day window');
ok((check(usage(r7 => iso($NOW + 30 * 86400))))[0],
   'B6: ... and a far-future one is accepted there too, for the same reason as B3');
ok(!(check(usage(r7 => iso($NOW - 36 * 3600))))[0],
   'B7: and a past stamp is refused for the seven-day window too');

# ===========================================================================
# C. WHAT WAS ALREADY TRUE STAYS TRUE.
# ===========================================================================
ok(!(check({ five_hour => { utilization => 10 } }))[0],
   'C1: a missing window is still refused');
ok(!(check(usage(u5 => 140)))[0], 'C2: utilization out of range is still refused');
ok(!(check(usage(r5 => 'not-a-date', u5 => 5)))[0], 'C3: an unparseable stamp is still refused');
ok((check({ five_hour => { utilization => 0 }, seven_day => { utilization => 0 } }))[0],
   'C4: an IDLE window with no resets_at is still accepted -- b28: requiring it here '
 . 'false-positived a drift and paused whole unattended fleets');

# ===========================================================================
# D. BACKWARD COMPATIBILITY. Every existing caller passes one argument.
# ===========================================================================
{
    my ($v) = BpContract::validate_usage(usage(r5 => iso(time + 3600), r7 => iso(time + 3 * 86400)));
    ok($v, 'D1: a one-argument call still works, defaulting to the real clock');
}
{
    my ($v) = BpContract::validate_usage(usage(r5 => iso(time - 36 * 3600), u5 => 35));
    ok(!$v, 'D2: ... and still catches an impossible stamp against it');
}

# Hostile input must not die -- this runs inside a gate that decides whether a
# fleet may proceed.
for my $junk (undef, 'string', [], { five_hour => 'nope' }) {
    my $v = eval { my ($r) = BpContract::validate_usage($junk, $NOW); 1 };
    ok($v, 'D3: hostile input is refused, not fatal: ' . (defined $junk ? (ref($junk) || $junk) : 'undef'));
}

done_testing();
