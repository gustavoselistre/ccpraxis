#!/usr/bin/env perl
# platform: any
# "NEEDS YOU: 1 DECISION WAITING" AGAINST AN EMPTY QUEUE, FOREVER.
#
# The escalations directory for a live run held exactly one entry:
#
#     -rwxrwxrwx 1 root root 0 Sep 15 19:17  01-fleet-...--6aa999614a30b1.json.lock
#
# Zero bytes. A LOCK, not a record. The decision it guarded was answered and its
# .json unlinked; no process held the lock. The panel counted it as a decision
# waiting for the operator and went on counting it (almanac 20260916-103055-7f5e).
#
# TWO FILTERS THAT DID NOT AGREE. Everything that writes or removes a queue
# record matches /\.json$/ -- bp-answer-decision.pl's clear_pkg_decisions and
# sweep_settled, bp-orchestrator.pl's queued_decision_pkgs. So no cleanup path
# could see a .json.lock. The COUNTER used a different set of filters (not a
# dotfile, not .tmp, is a file) and the lock passed all three. It then read as
# unparseable -- and unparseable is deliberately treated as LIVE, and
# deliberately attributed to the OPERATOR. Both of those are the right answer
# for a truncated record and the wrong answer for a stray lock.
#
# This also closes item 4 of 20260915-230820-d33e, which was filed as "1 decision
# waiting against an empty escalations dir" and which I could not reproduce when
# I triaged it: I read the directory as empty because the only thing in it was a
# lock, and looked for the fault in the counting rather than in what was being
# counted.
#
# WHAT THIS FILE MUST NOT BREAK. The fail-safe that an unreadable .json still
# counts as live exists to protect a real pending decision from a schema change
# or a truncated write. Narrowing what counts as a RECORD must not narrow that.
# Section C is that assertion.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

require RunState;

my $tmp   = tempdir(DIR => $Bin, CLEANUP => 1);
my $bp    = "$tmp/blueprint";
my $runs  = "$bp/runs";
my $queue = "$runs/escalations";
make_path("$bp/packages", $queue);

sub put {
    my ($name, $content) = @_;
    open my $fh, '>:raw', "$queue/$name" or die "cannot write $name: $!";
    print $fh (defined $content ? $content : '');
    close $fh;
}
sub clear { unlink glob("$queue/*"); }

sub counted {
    my $split = RunState::_count_decisions_split($queue, undef, 0);
    return $split->{operator} + $split->{triage};
}

my $REAL = JSON::PP->new->encode({ package => 'p1', category => 'product',
                                   question => 'which shape?' });

# ===========================================================================
# A. THE MEASURED FILE.
# ===========================================================================
clear();
put('01-fleet-state-freshness--6aa999614a30b1.json.lock', '');
is(counted(), 0,
   'A1: a zero-byte .json.lock left behind by an answered decision counts as NOTHING');

clear();
put('01-fleet--6aa999614a30b1.json.lock', '');
put('02-other--deadbeef.json.lock', '');
is(counted(), 0, 'A2: ... however many of them there are');

# ===========================================================================
# B. REAL RECORDS STILL COUNT. Without this, A passes for a counter that
# returns zero for everything.
# ===========================================================================
clear();
put('01-real--aaaa.json', $REAL);
is(counted(), 1, 'B1: a real .json record still counts');

clear();
put('01-real--aaaa.json', $REAL);
put('01-real--aaaa.json.lock', '');
is(counted(), 1,
   'B2: a record AND its own live lock count as one decision, not two -- the shape '
 . 'that exists while a decision is genuinely being written');

# ===========================================================================
# C. THE FAIL-SAFE IS UNTOUCHED. An unreadable RECORD is still live: that
# branch protects a real pending decision from a truncated write or a schema
# change, and narrowing what counts as a record must not narrow it.
# ===========================================================================
clear();
put('01-truncated--bbbb.json', '{"package": "p1", "categ');
is(counted(), 1,
   'C1: a truncated .json still counts as a live decision -- the protection that '
 . 'makes an unparseable record fail SAFE is deliberate and stays');

clear();
put('01-empty--cccc.json', '');
is(counted(), 1, 'C2: a zero-byte .json counts too -- it is a record that failed to write');

# ===========================================================================
# D. THE PRE-EXISTING FILTERS STILL HOLD.
# ===========================================================================
clear();
put('.hidden.json', $REAL);
is(counted(), 0, 'D1: a dotfile is still skipped');
clear();
put('01-partial--dddd.json.tmp', $REAL);
is(counted(), 0, 'D2: a .tmp is still skipped');
clear();
put('README.md', 'not a decision');
put('notes.txt', 'nor this');
is(counted(), 0, 'D3: and a non-.json file is not a decision either');

# ===========================================================================
# E. AN EMPTY QUEUE IS ZERO, which is the sentence the operator was owed.
# ===========================================================================
clear();
is(counted(), 0, 'E1: an empty queue counts zero');

done_testing();
