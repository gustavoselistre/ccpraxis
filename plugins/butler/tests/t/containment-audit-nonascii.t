#!/usr/bin/env perl
# DIFFING A SNAPSHOT AGAINST ITSELF MUST REPORT ZERO.
#
# bp-containment-audit.pl exists so a coordinator can run it around a step that
# spawns subprocesses and "treat any finding as evidence to investigate". On the
# reporting host it produced 429 findings against a project where nothing had
# been written -- every one a non-ASCII filename, reported twice, once [deleted]
# and once [new], with identical byte sizes (almanac 20260915-224959-7836). 214
# such files, because the person's name is Andre-with-an-acute.
#
# THE ROUND-TRIP WAS ASYMMETRIC. readdir yields raw BYTES. save_snapshot encoded
# without ->utf8 and printed unlayered, so those bytes reached the file intact.
# load_snapshot read them back with decode_json, which IS ->utf8, and DECODED
# them into characters. Ten bytes in, nine characters out; the key could never
# match a later readdir again, so the same file looked simultaneously deleted
# and created.
#
# WHY THIS TEST USES A REAL FILE ON A REAL DISK. The defect lives exactly at the
# boundary between what readdir produces and what JSON hands back. A fixture
# that constructs the key in Perl would be asserting against my own idea of what
# readdir returns, which is the assumption that was wrong in the first place.
# So: create a file whose name carries a non-ASCII byte, let the real script
# walk it, and compare the snapshot with itself.
#
# A tool whose findings are overwhelmingly false teaches people to ignore its
# true ones, which is worse than not having the tool. That is what makes a
# false-positive bug in an audit worth a test.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $AUDIT = "$Bin/../../scripts/bp-containment-audit.pl";
ok(-f $AUDIT, 'bp-containment-audit.pl is present') or BAIL_OUT('no audit script');

# THE FIXTURE MUST NOT LIVE UNDER /tmp, and finding that out is worth a note.
#
# in_set() exempts everything under /tmp unconditionally, mirroring
# guard-writes.sh's exemption so the hook and the audit enforce one boundary. On
# this host File::Temp's default lands in exactly there (MSYS sets TMPDIR=/tmp),
# so a fixture built the obvious way is 100% in-set and the audit reports zero
# for every input -- including inputs it SHOULD flag. The first draft of this
# file did that, and its "diffing a snapshot against itself reports zero"
# assertion passed against the unfixed script. Section D below is what caught
# it, which is the entire reason a counter-fixture is not optional.
my $tmp  = tempdir(DIR => $Bin, CLEANUP => 1);
my $root = "$tmp/proj";
make_path("$root/sub");
unlike($root, qr{^/tmp/}, 'A0: the fixture is outside the /tmp exemption, so findings are reachable at all');

# The exact byte sequence readdir returns for this host's own home directory
# name. Written as bytes deliberately -- \xc3\xa9 is UTF-8 for an e-acute, and
# the whole point is that it is TWO bytes, not one character.
my $NAME = "Andr\xc3\xa9 Carini - CV.txt";
my $path = "$root/sub/$NAME";
open(my $fh, '>:raw', $path) or BAIL_OUT("cannot create non-ASCII fixture: $!");
print $fh 'x';
close $fh;

# A plain-ASCII sibling, so a run that reports nothing is reporting nothing
# about a directory that genuinely has files in it.
open(my $fh2, '>:raw', "$root/plain.txt") or BAIL_OUT("cannot create fixture: $!");
print $fh2 'y';
close $fh2;

ok(-f $path, 'the non-ASCII fixture exists on disk')
    or BAIL_OUT('this filesystem would not take the name -- the test cannot run here');

my $snap = "$tmp/snap.json";
my $snap_out = `perl "$AUDIT" snapshot --out "$snap" --project-root "$root" 2>&1`;
is($? >> 8, 0, 'A1: snapshot exits clean') or diag($snap_out);
ok(-s $snap, 'A2: the snapshot has content');

# ===========================================================================
# THE ASSERTION. Nothing has changed between the two calls.
# ===========================================================================
my $diff = `perl "$AUDIT" diff --before "$snap" --project-root "$root" --write-set "nothing-is-in-set" --format text 2>&1`;
my $rc = $? >> 8;

like($diff, qr/containment audit: (\d+) out-of-set write/,
     'B0: the diff produced a parseable summary line') or diag($diff);
my ($n) = ($diff =~ /containment audit: (\d+) out-of-set write/);
$n = -1 unless defined $n;

is($n, 0, 'B1: diffing a snapshot against itself reports ZERO findings')
    or diag("findings:\n$diff");

# Named separately, because "0 findings" could also be reached by a script that
# walked nothing at all. These two say the false pair specifically is gone.
unlike($diff, qr/\[new\].*Carini/,      'B2: the untouched non-ASCII file is not reported as new');
unlike($diff, qr/\[deleted\].*Carini/,  'B3: ... nor as deleted');

# The "Wide character in print" warning was the same defect surfacing at the
# report writer. Its absence is a second, independent witness that nothing is
# being decoded any more.
unlike($diff, qr/Wide character/, 'B4: no wide-character warning escapes the report writer');

# ===========================================================================
# C. THE FIXTURE IS LOAD-BEARING. If the walk never saw the file, B1-B3 would
# pass for the wrong reason. Prove the snapshot actually contains it.
# ===========================================================================
my $raw = do { local (@ARGV, $/) = ($snap); <> };
like($raw, qr/\Qsub\/$NAME\E/,
     'C1: the snapshot really recorded the non-ASCII path, so the zero above is '
     . 'a match rather than an absence');

# ===========================================================================
# D. AND A GENUINE CHANGE IS STILL REPORTED. A guard that reports zero for
# everything is not a fix, it is a broken tool that looks fixed.
# ===========================================================================
open(my $fh3, '>:raw', "$root/sub/Andr\xc3\xa9 - NEW FILE.txt") or BAIL_OUT("cannot create: $!");
print $fh3 'zz';
close $fh3;
my $diff2 = `perl "$AUDIT" diff --before "$snap" --project-root "$root" --write-set "nothing-is-in-set" --format text 2>&1`;
my ($n2) = ($diff2 =~ /containment audit: (\d+) out-of-set write/);
is($n2, 1, 'D1: a genuinely new non-ASCII file IS reported -- exactly one finding')
    or diag("findings:\n$diff2");
like($diff2, qr/\[new\].*NEW FILE/, 'D2: ... and it is reported as new, by name');

done_testing();
