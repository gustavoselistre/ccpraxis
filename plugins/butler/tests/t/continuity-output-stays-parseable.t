#!/usr/bin/env perl
# platform: any
# bp-continuity.pl's output is a PARSED INTERFACE, not decoration.
#
# The /butler:continuity skill's step 2 reads it as `KEY: value` lines and
# branches on STATUS. Anything else on that stream is noise in a channel
# something reads.
#
# THE DEFECT, measured 2026-09-18. BpSession.pm is required from four places
# that compute their script directory differently -- bp-continuity.pl via
# dirname(File::Spec->rel2abs(__FILE__)), BpContinuityLease.pm via
# Cwd::abs_path. `require EXPR` keys %INC by the LITERAL string it is handed, so
# two spellings of one directory meant two keys, the file was compiled twice, and
# every sub in it was redefined:
#
#   Subroutine transcript_roots redefined at .../BpSession.pm line 62.
#   Subroutine find_transcript redefined at .../BpSession.pm line 96.
#   ... eight in total, on EVERY invocation
#
# Harmless to behaviour and hostile to the one consumer that exists.
#
# ASSERTED ON THE OUTPUT, not on the fix. A test that grepped for the %INC guard
# would pass for a reimplementation that reintroduced the warnings by another
# route; this one fails whenever the stream stops being parseable, whatever the
# cause.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

my $SCRIPT = "$Bin/../../scripts/bp-continuity.pl";
ok(-f $SCRIPT, 'bp-continuity.pl exists') or BAIL_OUT('script missing');

# Hermetic: never read or write the real machine registry.
my $reg = tempdir(CLEANUP => 1);
my $errf = File::Spec->catfile(tempdir(CLEANUP => 1), 'err');

local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $reg;
my $out = `"$^X" "$SCRIPT" status 2> "$errf"`;
my $err = -f $errf ? do { local (@ARGV, $/) = ($errf); <> } : '';
$err = '' unless defined $err;
$out = '' unless defined $out;

# AC-1: the thing the skill actually parses.
my @lines = grep { /\S/ } split /\n/, $out;
ok(scalar(@lines) > 0, 'AC-1: status produces output');
my @bad = grep { !/^[A-Z][A-Z0-9_]*:\s/ } @lines;
is_deeply(\@bad, [],
    'AC-1: every stdout line is a KEY: value pair, which is the documented contract')
    or diag("offending lines:\n" . join("\n", @bad));

like($out, qr/^STATUS:\s*\S+/m, 'AC-2: STATUS is present, so the skill can branch');

# AC-3: the specific regression. Eight of these appeared on every call.
unlike($out, qr/redefined/i, 'AC-3: no "redefined" warnings on stdout');
unlike($err, qr/redefined/i, 'AC-3: none on stderr either');

# AC-4: and nothing else perl-ish leaking out of either stream. "Subroutine ...
# redefined" was only the symptom that happened to be noticed; the contract is
# that neither stream carries diagnostics at all.
unlike($out, qr/\bat .*\.pm line \d+/, 'AC-4: no perl diagnostics on stdout');
unlike($err, qr/\bat .*\.pm line \d+/, 'AC-4: no perl diagnostics on stderr');

# AC-5: NON-VACUITY. A test asserting "no warnings" passes trivially if the
# script never ran. Prove it did real work by requiring a status value that only
# the resolver can produce.
like($out, qr/^STATUS:\s*(?:armed|arming|unarmed|disarmed|not_armed|error)\b/m,
    'AC-5: STATUS carries a value the resolver actually computed, so the run was real');

done_testing();
