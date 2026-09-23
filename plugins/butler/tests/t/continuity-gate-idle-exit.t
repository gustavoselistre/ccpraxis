#!/usr/bin/env perl
# platform: any
# Report 20260918-134732-acfd.
#
# The continuity Stop gate offered exactly two exits -- hold ("I am still
# working") and disarm ("I am finished") -- and assumed one is always reachable.
# When the work IS finished and disarm is refused by guard-run-finish.sh,
# neither is true and neither is available, so the session can only re-arm a
# bounded hold, at one full turn per expiry, until whatever blocks disarm
# resolves itself. Measured 2026-09-18: about fifteen consecutive turns whose
# entire content was re-arming a 900s hold and reporting "Holding", with zero
# open bug reports, zero dispatches and zero background processes. The exit
# condition was a 12-hour TTL elapsing on a stale marker -- not an event any
# party could cause.
#
# The third exit is "there is no work". It does NOT disarm: the arm stands and
# the next turn is gated exactly as before.
#
# THE PROPERTY THAT MATTERS MOST is the one asserted last here: the gate must
# still BLOCK when work exists. An escape hatch that opens on a false "finished"
# would be worse than the trap, because the trap only wasted tokens.
use strict;
use warnings;

# A test must never actuate a real wake-lock (test-wakelock-hygiene.t).
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

(my $GATE = "$Bin/../../hooks/gate-continuity.sh") =~ s{\\}{/}g;
(my $LIB  = "$Bin/../../hooks/lib.sh")             =~ s{\\}{/}g;
ok(-f $GATE, 'the continuity gate is present') or BAIL_OUT("no gate at $GATE");

my $ROOT = tempdir(CLEANUP => 1);
my $J = JSON::PP->new->canonical;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# --- the shared predicate, exercised directly --------------------------------
# One rule, two callers: guard-run-finish.sh and the gate now consult the SAME
# function, because their disagreement is what built the trap.
sub outstanding {
    my ($proj, $run_live) = @_;
    my $out = `bash -c '. "$LIB" 2>/dev/null; BP_PROJECT_ROOT="$proj" bp_outstanding_work $run_live' 2>/dev/null`;
    return defined $out ? $out : '';
}

my $n = 0;
sub project {
    my (%o) = @_;
    my $proj = "$ROOT/p" . (++$n);
    my $bp   = "$proj/.ccpraxis-local-data/blueprints/demo";
    for my $d ($proj, "$proj/.ccpraxis-local-data", "$proj/.ccpraxis-local-data/blueprints",
               $bp, "$bp/packages", "$bp/runs") { mkdir $d or die "mkdir $d: $!" }
    open my $b, '>', "$bp/blueprint.md" or die;
    print {$b} "# d\n\n```\nblueprint: demo\nstatus: " . ($o{status} // 'audited') . "\n```\n";
    close $b;
    for my $p (keys %{ $o{pkgs} || {} }) {
        open my $h, '>', "$bp/packages/$p.md" or die;
        print {$h} "---\npackage: $p\nblueprint: demo\nstatus: $o{pkgs}{$p}\n---\n\n# $p\n";
        close $h;
    }
    # Launch evidence, so the never-launched filter is not what decides here.
    # It must be a REAL launch: an empty registry is a file, not a run, and an
    # earlier version of this fixture wrote `{}` and therefore tested nothing
    # once the rule was corrected.
    open my $r, '>', "$bp/runs/registry.json" or die;
    print {$r} $J->encode({ packages => { seed => { attempt => 1, session_id => 'fixture-sid' } } });
    close $r;
    return $proj;
}

# ---- FINISHED: every package terminal -> nothing outstanding ----------------
{
    my $p = project(pkgs => { '01-a' => 'done', '02-b' => 'blocked', '03-c' => 'parked' });
    is(outstanding($p, 0), '', 'all packages terminal -> no outstanding work, so a turn may end');
    is(outstanding($p, 1), '', '...and a live drive does not invent work that is not there');
}

# ---- NOT FINISHED: the gate must keep blocking ------------------------------
# The direction that matters. A false "finished" is worse than the trap.
{
    my $p = project(pkgs => { '01-a' => 'done', '02-b' => 'pending' });
    like(outstanding($p, 0), qr/02-b \(pending\)/,
         'one pending package is still outstanding -- the gate keeps blocking');
}
{
    my $p = project(pkgs => { '01-a' => 'running' });
    like(outstanding($p, 0), qr/01-a \(running\)/, 'a running package is outstanding');
}

# ---- A REGISTRY IS NOT A LAUNCH -------------------------------------------
# bp-answer-decision.pl writes registry.json to record a package RESET, so a
# blueprint nobody has ever run acquires one the moment somebody repairs a stale
# status. Measured 2026-09-18: resetting one package in a parked, never-driven
# blueprint made all 17 of its pending packages count as work in flight and
# blocked every stop in an unrelated session. attempt 0 with a null session id
# is the file saying it never ran.
{
    my $p = project(pkgs => { '01-a' => 'pending' });
    my $reg = "$p/.ccpraxis-local-data/blueprints/demo/runs/registry.json";
    open my $r, '>', $reg or die;
    print {$r} $J->encode({ packages => { '01-a' => {
        attempt => 0, session_id => undef, status => 'pending' } } });
    close $r;
    is(outstanding($p, 0), '',
       'a registry whose only row is attempt 0 / session_id null is NOT a launch');
}
{
    my $p = project(pkgs => { '01-a' => 'pending' });
    my $reg = "$p/.ccpraxis-local-data/blueprints/demo/runs/registry.json";
    open my $r, '>', $reg or die;
    print {$r} $J->encode({ packages => { '01-a' => {
        attempt => 1, session_id => undef, status => 'running' } } });
    close $r;
    like(outstanding($p, 0), qr/01-a \(pending\)/,
         'a real attempt IS a launch -- work still counts');
}
{
    my $p = project(pkgs => { '01-a' => 'pending' });
    my $reg = "$p/.ccpraxis-local-data/blueprints/demo/runs/registry.json";
    open my $r, '>', $reg or die;
    print {$r} $J->encode({ packages => { '01-a' => {
        attempt => 0, session_id => 'abc-123', status => 'pending' } } });
    close $r;
    like(outstanding($p, 0), qr/01-a \(pending\)/,
         'a recorded session id IS a launch');
}
{
    # Cannot tell -> assume launched. Ignorance must never erase work.
    my $p = project(pkgs => { '01-a' => 'pending' });
    my $reg = "$p/.ccpraxis-local-data/blueprints/demo/runs/registry.json";
    open my $r, '>', $reg or die; print {$r} 'not json at all'; close $r;
    like(outstanding($p, 0), qr/01-a \(pending\)/,
         'an undecodable registry counts as launched -- ignorance keeps work visible');
}

# ---- archived is not work ---------------------------------------------------
{
    my $p = project(status => 'archived', pkgs => { '01-a' => 'pending' });
    is(outstanding($p, 0), '', 'an archived blueprint contributes nothing');
}

# ---- IGNORANCE KEEPS THE GATE SHUT -----------------------------------------
# It must never go quiet because it could not tell. A gate that opens on
# uncertainty is an escape hatch, not a gate.
{
    my $missing = "$ROOT/does-not-exist-at-all";
    my $out = outstanding($missing, 0);
    # No blueprints dir at all is genuinely "nothing to abandon" -- that case is
    # allowed. What must NOT happen is a crash or a hang.
    ok(defined $out, 'a project with no blueprint dir answers rather than dying');
}

# ---- the gate SOURCES the shared helper, so the two cannot drift ------------
{
    my $gate = do { open my $h, '<', $GATE or die; local $/; <$h> };
    like($gate, qr/bp_outstanding_work/,
         'the gate consults the shared predicate rather than a second copy of the scan');
    like($gate, qr/STAYS ARMED/,
         'and says plainly that allowing the stop is not disarming');
    my $guard = do { open my $h, '<', "$Bin/../../hooks/guard-run-finish.sh" or die; local $/; <$h> };
    like($guard, qr/bp_outstanding_work/,
         'guard-run-finish.sh consults the same one -- one rule, two callers');
    unlike($guard, qr/my \@bps = grep/,
         'and no longer carries its own inline copy of the scan');

    # ALL THREE GATES, not two. Fixing gate-continuity.sh and guard-run-finish.sh
    # and stopping there left the trap fully intact: guard-subagent-stall.sh has
    # the identical two-exit shape (finish | pause), and kept firing after the
    # other two were fixed, which is exactly what the operator saw. A gate that
    # can strand a finished session is a property of the SET, so the set is what
    # this asserts.
    my $stall = do { open my $h, '<', "$Bin/../../hooks/guard-subagent-stall.sh" or die; local $/; <$h> };
    like($stall, qr/bp_outstanding_work/,
         'guard-subagent-stall.sh consults it too -- all three gates, or the trap survives');
}

# ---- every gate that can strand a session shares ONE definition of finished --
# Named individually so a future gate added without it fails here rather than in
# a session that cannot stop.
{
    for my $h (qw(gate-continuity.sh guard-run-finish.sh guard-subagent-stall.sh)) {
        my $src = do { open my $f, '<', "$Bin/../../hooks/$h" or die "$h: $!"; local $/; <$f> };
        like($src, qr/bp_outstanding_work/, "$h uses the shared predicate");
    }
}

done_testing();
