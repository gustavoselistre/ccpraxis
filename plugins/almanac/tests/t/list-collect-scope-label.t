#!/usr/bin/env perl
# platform: any
# Regression for 20260911-225720-4c57 (defect 4): `list` printed a bare
# "N report(s)" with no hint the answer was scoped to one project. Asked to
# "fetch all bug reports", an agent reached for `list`, got a confident
# total, and reported a partial number as if it were the whole one -- and
# `collect` itself never said its project set comes from steward's backup
# registry, so an unregistered project (filing a bug and registering for
# backup are unrelated decisions) was excluded with no indication of that.
# Both surfaces must now say so in their own human-readable output.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);
my $PROJ = tempdir(CLEANUP => 1);
(my $PROJ_WIN = $PROJ) =~ s{\\}{/}g;

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}

my ($rc_f) = run('file', '--project', qq{"$PROJ_WIN"}, '--title', '"scope label fixture"',
                  '--body', '"just needs to exist"');
is($rc_f, 0, 'fixture: report filed');

my (undef, $list_out) = run('list', '--project', qq{"$PROJ_WIN"});
like($list_out, qr/1 report\(s\)/, 'list: still reports the right count');
like($list_out, qr/(?i:this project)/,
     'list: its own output states the answer is scoped to this project')
    or diag $list_out;
like($list_out, qr/collect/,
     'list: its own output points at collect for the wider view')
    or diag $list_out;

my (undef, $collect_out) = run('collect', '--project', qq{"$PROJ_WIN"});
like($collect_out, qr/1 report\(s\)/, 'collect: still reports the right count');
like($collect_out, qr/(?i:registry)/,
     'collect: its own output says its project set comes from a registry')
    or diag $collect_out;
like($collect_out, qr/(?i:not registered|unregistered|excluded)/,
     'collect: its own output says an unregistered project is excluded')
    or diag $collect_out;

done_testing();
