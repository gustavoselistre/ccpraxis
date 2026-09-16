#!/usr/bin/env perl
# platform: windows
# No test may actuate a real OS wake-lock.
#
# WHY THIS FILE EXISTS, AND WHY THE RULE IT ENFORCES IS NOT THE OBVIOUS ONE.
#
# bp-keepawake.pl's spawn() already refuses when $0 ends in ".t", and the comment
# there says a test therefore cannot leak an immortal helper. That is true only
# for a test that calls the perl directly. IT IS FALSE FOR A SUBPROCESS: a test
# that shells out to `perl bp-continuity.pl arm` hands the decision to a process
# whose own $0 is a .pl, and the guard never fires.
#
# That hole was live and costing real processes. t/runstate-pause-holds-lease.t
# ran `bp-runstate.pl pause`, which calls BpKeepAwake::apply with production
# seams; every run of it started a real keep-awake.ps1 on the host. It looked
# clean only because apply() used to return before the helper had written its pid
# file, so the assertion "a pause never fabricates a lease" was reading an empty
# directory a second too early. Making apply() claim the pid file up front — which
# it had to, to stop a fifteen-helper storm — is what exposed it.
#
# The repo has paid for this class twice already: 52 orphaned helpers holding
# 2.7 GB (2026-08-13), and 53 whose -PidFile pointed into File::Temp fixture
# directories (2026-08-14), which forced a machine restart. CLAUDE.md states the
# rule for launcher.pl; this is the same rule one level over, for a whole family
# of scripts, enforced instead of remembered.
#
# THE RULE. Any .t that so much as NAMES bp-continuity.pl, bp-runstate.pl or
# gate-continuity.sh must set CCPRAXIS_NO_WAKELOCK=1 — the supported opt-out,
# and the only one that survives exec into a child process.
#
# Deliberately blunt: it matches a mention, not an invocation. Distinguishing
# "runs it" from "mentions it in a comment" means parsing perl in a regex, and
# the two false positives that costs are one line each, while the false NEGATIVE
# costs a process that outlives the suite. The asymmetry decides it.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $T = $Bin;

# The scripts that can reach BpKeepAwake::apply / BpContinuityLease::ensure_daemon
# from a subprocess. Add to this list when another one learns to hold the lease.
my $ACTUATORS = qr/(?:bp-continuity\.pl|bp-runstate\.pl|gate-continuity\.sh)/;

# A POSITIVE setting, not a mention. `delete $ENV{CCPRAXIS_NO_WAKELOCK}` is a
# legitimate thing for a test of the lease itself to do, and it is the opposite
# of a guard — so matching the bare name would bless exactly the file most able
# to do damage.
my $GUARD = qr/CCPRAXIS_NO_WAKELOCK(?:\}\s*=\s*1|\s*=\s*['"]?1)/;

my @files = sort glob("$T/*.t");
ok(scalar @files, 'found the butler test files') or BAIL_OUT('no .t files');

my (@drivers, @unguarded);
for my $f (@files) {
    open my $fh, '<:raw', $f or die "read $f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    next unless $src =~ $ACTUATORS;
    my ($base) = $f =~ m{([^/\\]+)$};
    push @drivers, $base;
    push @unguarded, $base unless $src =~ $GUARD;
}

ok(scalar @drivers,
   'at least one test drives a wake-lock actuator (if this ever fails, the '
 . 'ACTUATORS pattern has drifted from the filenames and this file is guarding nothing)');

is(scalar @unguarded, 0,
   'every test that names a wake-lock actuator sets CCPRAXIS_NO_WAKELOCK=1')
    or diag("unguarded: @unguarded\n"
          . "Add near the top, above the first `use` that matters:\n"
          . "  BEGIN { \$ENV{CCPRAXIS_NO_WAKELOCK} = 1 }\n");

# The opt-out has to still be honoured at BOTH actuation points, or the line
# above is enforcing a variable nobody reads. Asserted against the source
# because "did not start an OS process" has no in-process observable.
for my $pair (['bp-keepawake.pl',      'spawn'],
              ['BpContinuityLease.pm', 'ensure_daemon']) {
    my ($file, $what) = @$pair;
    open my $fh, '<:raw', "$T/../../scripts/$file" or die "read $file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    like($src, qr/CCPRAXIS_NO_WAKELOCK/,
         "$file still honours CCPRAXIS_NO_WAKELOCK (the guard $what depends on)");
}

done_testing();
