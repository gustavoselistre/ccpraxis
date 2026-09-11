#!/usr/bin/env perl
# Regression for 20260911-225720-4c57 (defect 2's second half): a registered
# project whose root no longer resolves on this machine used to vanish from
# `collect` with NO diagnostic at all -- silence is what hid six open
# job-search reports, because nothing distinguished "this root is gone" from
# "this project has simply never filed a bug" (the overwhelmingly common,
# entirely normal case). `collect` must now name the unreadable root on
# STDERR, and must still complete -- a bad registry entry cannot take down
# the whole run.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);
my $GOOD = tempdir(CLEANUP => 1);
(my $GOOD_WIN = $GOOD) =~ s{\\}{/}g;

sub run_split {
    my (@args) = @_;
    my ($ofh, $opath) = File::Temp::tempfile('alm-out-XXXXXX', TMPDIR => 1, UNLINK => 1);
    my ($efh, $epath) = File::Temp::tempfile('alm-err-XXXXXX', TMPDIR => 1, UNLINK => 1);
    close $ofh; close $efh;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args)
            . qq{ > "$opath" 2> "$epath"};
    system($cmd);
    my $rc = $? >> 8;
    my $out = do { open my $f, '<', $opath or die $!; local $/; <$f> // '' };
    my $err = do { open my $f, '<', $epath or die $!; local $/; <$f> // '' };
    unlink $opath, $epath;
    return ($rc, $out, $err);
}

my ($rc_f, $out_f) = run_split('file', '--project', qq{"$GOOD_WIN"}, '--title', '"visible report"',
                                '--body', '"this one must survive a bad sibling entry"');
is($rc_f, 0, 'fixture: report filed in the GOOD project') or diag $out_f;

# The registry names a project directory that does not exist ANYWHERE on
# this machine -- the shape of a moved/deleted project, or a stale entry.
my $GONE = "$GOOD_WIN-does-not-exist-anywhere";
ok(!-e $GONE, 'fixture sanity: the gone-root path really does not exist');

mkdir "$HOME/.claude" or die $!;
mkdir "$HOME/.claude/claude-code-vault" or die $!;
my %j = (version => 1, projects => {
    'gone-fixture' => { path => $GONE },
});
open my $fh, '>:raw', "$HOME/.claude/claude-code-vault/.registry-local.json" or die $!;
print {$fh} JSON::PP->new->utf8->canonical->encode(\%j);
close $fh;

my ($rc_c, $out_c, $err_c) = run_split('collect', '--project', qq{"$GOOD_WIN"}, '--json');
is($rc_c, 0, 'collect: still completes despite one unreadable registered root') or diag "stderr: $err_c";

my $rows = eval { JSON::PP->new->decode($out_c) };
ok(ref $rows eq 'ARRAY', 'collect --json: stdout is still clean, parseable JSON (the warning went to stderr)')
    or diag $out_c;
my @mine = grep { ($_->{title} // '') eq 'visible report' } @{ $rows // [] };
is(scalar(@mine), 1, 'collect: the GOOD project is still fully reported')
    or diag $out_c;

like($err_c, qr/\Q$GONE\E/, 'collect: STDERR names the unreadable root by path')
    or diag "stderr was: $err_c";
like($err_c, qr/(?i:skip|not (?:a )?readable|does not exist)/,
     'collect: STDERR says why (skipped / not readable / does not exist)')
    or diag "stderr was: $err_c";

done_testing();
