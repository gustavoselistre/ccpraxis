#!/usr/bin/env perl
# platform: windows
# bp-runstate.pl must anchor its state to the PROJECT, never to its own
# install location.
#
# THE FAILURE THIS PINS, TRACED CONCRETELY
#
# bp-runstate.pl used to resolve its root as Cwd::abs_path("$DIR/../../.."),
# three levels up from the SCRIPT. butler normally runs from an install
# outside the project (~/.claude/ccpraxis, or a marketplace dir), so that
# guess resolves the INSTALL root, not the project. bp-drive-next.pl:1105
# already documents the identical guess as wrong, for the identical reason.
#
# The cost was a wedged drive-solo run, not a cosmetic path difference:
#
#   * guard-subagent-stall.sh reads the state with --root "$CLAUDE_PROJECT_DIR".
#     A hook always has that variable.
#   * A driver following drive-solo/SKILL.md's own documented `pause`
#     invocation passes no --root. The Bash tool's environment does NOT carry
#     CLAUDE_PROJECT_DIR.
#   * So the driver's pause was written under the INSTALL root while the gate
#     kept reading the PROJECT root, where the state was still `active`.
#
# The pause was well-formed and genuinely verified -- live pid, future
# deadline -- and completely invisible to its only reader. Every Stop was
# denied, and the run could not advance past its first dispatch. A wrong root
# anchored to the project is recoverable; one anchored to the install is a
# different repo's state file.
#
# Section A pins the resolution itself, B pins the round-trip that actually
# failed, C pins that the explicit and hook-supplied roots still win.
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives bp-continuity.pl /
# bp-runstate.pl / gate-continuity.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(getcwd abs_path);

my $T      = dirname(abs_path(__FILE__));
my $SCRIPT = abs_path("$T/../../scripts/bp-runstate.pl");
ok(-f $SCRIPT, 'bp-runstate.pl found') or BAIL_OUT("missing: $SCRIPT");

# The install root the old guess would have produced: three levels up from the
# script's own directory. Everything below asserts we never land here.
my $INSTALL_GUESS = abs_path(dirname($SCRIPT) . '/../../..');

my $ORIG = getcwd();

# A throwaway "project": a directory that already holds .ccpraxis-local-data,
# which is exactly what the walk-up leg of the ladder looks for.
my $proj = tempdir(CLEANUP => 1);
$proj = abs_path($proj);
make_path("$proj/.ccpraxis-local-data");

# The walk-up leg is only reached when the git leg declines. If the system temp
# dir happens to sit inside a repository, this fixture cannot isolate the leg it
# means to test -- say so rather than assert something else by accident.
chdir $proj or BAIL_OUT("cannot chdir to $proj");
my $top = `git rev-parse --show-toplevel 2>/dev/null`;
my $in_repo = ($? == 0 && defined $top && length $top);
chdir $ORIG or BAIL_OUT("cannot chdir back to $ORIG");

# run($cwd, \%env_overrides, @args) -> trimmed stdout
# Undef in %env_overrides DELETES the variable for the child, which is the
# whole point: the driver's shell genuinely lacks CLAUDE_PROJECT_DIR.
sub run {
    my ($cwd, $env, @args) = @_;
    local %ENV = %ENV;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} }
        else                    { delete $ENV{$k} }
    }
    my $here = getcwd();
    chdir $cwd or die "chdir $cwd: $!";
    my $out = `"$^X" "$SCRIPT" @{[ join ' ', map { qq{"$_"} } @args ]} 2>&1`;
    chdir $here or die "chdir back: $!";
    $out = '' unless defined $out;
    $out =~ s/\s+\z//;
    return $out;
}

my %CLEAR = (CLAUDE_PROJECT_DIR => undef, BP_PROJECT_ROOT => undef);

# ---------------------------------------------------------------- A. resolution
SKIP: {
    skip 'system temp dir is inside a git repository; walk-up leg not isolable', 2
        if $in_repo;

    my $dir = run($proj, \%CLEAR, 'state-dir');
    $dir =~ s{\\}{/}g;
    my $want = "$proj/.ccpraxis-local-data/.subagent-guard";
    $want =~ s{\\}{/}g;

    is($dir, $want,
       'state-dir anchors to the project found by walking up from cwd');

    my $guess = $INSTALL_GUESS;
    $guess =~ s{\\}{/}g;
    unlike($dir, qr/^\Q$guess\E/,
           'state-dir never resolves under the install root the old guess produced');
}

# BP_PROJECT_ROOT is consulted before the git/walk-up legs.
{
    my $other = abs_path(tempdir(CLEANUP => 1));
    my $dir = run($ORIG, { %CLEAR, BP_PROJECT_ROOT => $other }, 'state-dir');
    $dir =~ s{\\}{/}g;
    my $want = "$other/.ccpraxis-local-data/.subagent-guard";
    $want =~ s{\\}{/}g;
    is($dir, $want, 'BP_PROJECT_ROOT wins over the git and walk-up legs');
}

# ------------------------------------------------- B. the round-trip that failed
SKIP: {
    skip 'system temp dir is inside a git repository; walk-up leg not isolable', 2
        if $in_repo;

    # The driver's call, verbatim in shape: no --root, because the skill's own
    # documented invocation has none.
    my $until = time + 300;
    my $out = run($proj, \%CLEAR,
                  'pause', '--watcher-pid', $$, '--until', $until,
                  '--watching', 'a fixture', '--reason', 'round-trip check');
    like($out, qr/paused/, 'pause with no --root succeeds');

    # The gate's call, verbatim in shape: --root "$CLAUDE_PROJECT_DIR".
    my $st = run($ORIG, \%CLEAR, 'status', '--root', $proj);
    like($st, qr/"state"\s*:\s*"paused"/,
         'the gate reading --root <project> sees the pause the driver wrote');
}

# ------------------------------------------------------ C. the roots that win
{
    # An explicit --root beats every other leg, including a conflicting env.
    my $explicit = abs_path(tempdir(CLEANUP => 1));
    my $dir = run($proj, { CLAUDE_PROJECT_DIR => $ORIG, BP_PROJECT_ROOT => $ORIG },
                  'state-dir', '--root', $explicit);
    $dir =~ s{\\}{/}g;
    my $want = "$explicit/.ccpraxis-local-data/.subagent-guard";
    $want =~ s{\\}{/}g;
    is($dir, $want, 'an explicit --root wins over CLAUDE_PROJECT_DIR and BP_PROJECT_ROOT');

    # CLAUDE_PROJECT_DIR stays ahead of the ladder: in a hook it is
    # authoritative, and it is exactly what the reader passes.
    my $hookroot = abs_path(tempdir(CLEANUP => 1));
    my $d2 = run($proj, { CLAUDE_PROJECT_DIR => $hookroot, BP_PROJECT_ROOT => undef },
                 'state-dir');
    $d2 =~ s{\\}{/}g;
    my $want2 = "$hookroot/.ccpraxis-local-data/.subagent-guard";
    $want2 =~ s{\\}{/}g;
    is($d2, $want2, 'CLAUDE_PROJECT_DIR still wins over the git and walk-up legs');
}

done_testing();
