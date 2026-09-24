#!/usr/bin/env perl
# platform: any
# guard-run-finish.sh must recognise a run-ending command whatever letters the
# paths in it contain.
#
# Its three patterns used the bracket expression [^;&|(){}\n]. In a POSIX ERE
# bracket expression `\n` is not a newline: it is a backslash and the letter n.
# So the "anything up to the target" run refused to cross any `n`, and a
# `touch <path>/.run-finished`, or a `bp-runstate ... finish` with an argument
# containing an n, was classified as NOT run-ending and allowed through without
# the operator's authorisation. This project's own path, C:/Development/...,
# contains an n. run-finish-guard.t E1a failed about one run in seven, exactly
# when File::Temp's random directory name happened to contain an n
# (2026-09-24). grep matches line by line, so a newline can never be inside a
# match and needs no exclusion.
#
# Deterministic: every case sources the guard's classifier directly and feeds
# it a fixed command. No drive, transcript or payload is involved.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $GUARD = "$Bin/../../hooks/guard-run-finish.sh";
ok(-f $GUARD, 'guard-run-finish.sh exists') or BAIL_OUT('no guard');

sub run_ending {
    my ($cmd) = @_;
    my $rc = system('bash', '-c', 'source "$1"; CMD="$2"; bp_rf_is_run_ending', '_', $GUARD, $cmd);
    return $rc == 0 ? 1 : 0;
}

# Every character a real path segment commonly holds, each alone in the path.
for my $ch ('a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-') {
    my $root = "/tmp/x${ch}x";
    ok(run_ending(qq{touch "$root/.ccpraxis-local-data/.drive-solo/.run-finished"}),
       "touch of .run-finished under a path containing '$ch' is run-ending");
}

my $repo = '/c/Development/ccpraxis';
ok(run_ending(qq{touch "$repo/.ccpraxis-local-data/.drive-solo/.run-finished"}),
   'touch of .run-finished under this repo\x27s own path (contains n) is run-ending');
ok(run_ending(qq{touch $repo/.ccpraxis-local-data/.drive-solo/.run-finished}),
   '...unquoted too');
ok(run_ending(qq{perl $repo/plugins/butler/scripts/bp-runstate.pl --data $repo/.ccpraxis-local-data finish}),
   'bp-runstate ... finish with arguments containing n is run-ending');
ok(run_ending(qq{perl $repo/plugins/butler/scripts/bp-continuity.pl disarm --session nnn}),
   'bp-continuity ... disarm with arguments containing n is run-ending');

# Controls: an ordinary command that merely mentions the file is not.
ok(!run_ending(qq{cat "$repo/.ccpraxis-local-data/.drive-solo/.run-finished"}),
   'control: reading .run-finished is not run-ending');
ok(!run_ending(qq{ls $repo}), 'control: an unrelated command is not run-ending');

done_testing();
