#!/usr/bin/env perl
# platform: any
# The run-finish guard's outstanding-work scan counted every `pending` package in
# every non-archived blueprint on disk. A drafted package sits at `pending` from
# birth and only leaves it when somebody drives it, so AUTHORING a blueprint made
# disarming permanently impossible -- the more planning existed, the more locked
# every session became.
#
# Measured 2026-09-18: 43 packages across six blueprints reported as outstanding
# with no run live, no coordinator dispatched, the bug queue empty and the suite
# green. The session could not stop and sat in a hold loop. Idling is not the
# safe side of this guard: it abandons nothing but never ends, which the guard's
# own header names as the worse failure.
#
# The question the guard wants answered is "would stopping ABANDON work that is
# in flight". A blueprint nobody has launched cannot have any. Execution always
# leaves a trace under runs/ -- registry.json from bp-launch.sh, a .orchestrator
# marker while one is alive, or a coordinator's own <pkg>.jsonl transcript.
#
# BOTH DIRECTIONS ARE ASSERTED. A guard that stops blocking is worse than one
# that blocks too much: its false negative lets an agent end an unattended run,
# which is the incident it exists to prevent.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

(my $HOOK = "$Bin/../../hooks/guard-run-finish.sh") =~ s{\\}{/}g;
ok(-f $HOOK, 'the guard is present') or BAIL_OUT("no hook at $HOOK");

my $ROOT = tempdir(CLEANUP => 1);
my $J = JSON::PP->new->canonical;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $n = 0;

# Build a project tree with one blueprint. %o:
#   status   => blueprint.md status: value
#   pkgs     => { name => status }
#   launched => 'registry' | 'orchestrator' | 'jsonl' | undef
sub project {
    my (%o) = @_;
    my $proj = "$ROOT/proj" . (++$n);
    my $bp   = "$proj/.ccpraxis-local-data/blueprints/demo-bp";
    for my $d ($proj, "$proj/.ccpraxis-local-data", "$proj/.ccpraxis-local-data/blueprints",
               $bp, "$bp/packages", "$bp/runs") {
        mkdir $d or die "mkdir $d: $!";
    }
    open my $b, '>', "$bp/blueprint.md" or die;
    print {$b} "# demo\n\n```\nblueprint: demo-bp\nstatus: " . ($o{status} // 'drafting') . "\n```\n";
    close $b;

    for my $p (keys %{ $o{pkgs} || {} }) {
        open my $h, '>', "$bp/packages/$p.md" or die;
        print {$h} "---\npackage: $p\nblueprint: demo-bp\nstatus: $o{pkgs}{$p}\n---\n\n# $p\n";
        close $h;
    }

    my $l = $o{launched} // '';
    if    ($l eq 'registry')     { open my $r,'>',"$bp/runs/registry.json" or die; print {$r} "{}"; close $r }
    elsif ($l eq 'orchestrator') { open my $r,'>',"$bp/runs/.orchestrator" or die; print {$r} "1"; close $r }
    elsif ($l eq 'jsonl')        { open my $r,'>',"$bp/runs/01-thing.jsonl" or die; print {$r} "{}\n"; close $r }

    return $proj;
}

# Fire the guard at a disarm command with BP_PROJECT_ROOT pointed at the tree.
sub verdict {
    my ($proj, $cmd) = @_;
    $cmd //= 'perl bp-continuity.pl disarm';
    # The guard also reads the operator's last message from the transcript named
    # on the payload, and FAILS OPEN when it cannot parse one. Without a
    # transcript every BLOCK case below would exit 0 for that reason instead of
    # the one under test -- passing vacuously in the direction that matters.
    # Supply one whose newest user turn carries no stop instruction, so the
    # verdict is UNAUTHORISED and the outstanding-work scan is what decides.
    my $tr = "$proj/transcript.jsonl";
    unless (-e $tr) {
        open my $t, '>', $tr or die "open $tr: $!";
        print {$t} $J->encode({ type => 'user', message => {
            role => 'user', content => 'please carry on with the next package' } }), "\n";
        close $t;
    }

    my $pf = "$ROOT/payload." . (++$n) . ".json";
    open my $w, '>', $pf or die;
    print {$w} $J->encode({ tool_name => 'Bash', cwd => $proj,
                            transcript_path => fwd($tr),
                            tool_input => { command => $cmd } });
    close $w;
    # The guard stands down entirely unless a run is being watched -- a
    # drive-solo marker or an ARMED continuity session. Without this the
    # outstanding-work scan is never reached and every case below would pass
    # vacuously at exit 0, including the ones asserting a BLOCK. Redirect the
    # continuity dir at the fixture and put a marker in it.
    my $cdir = "$proj/.continuity-active";
    unless (-d $cdir) {
        mkdir $cdir or die "mkdir $cdir: $!";
        open my $m, '>', "$cdir/session-fixture" or die;
        print {$m} "armed\n";
        close $m;
    }
    # The never-launched filter applies ONLY when no drive is live -- a
    # drive-solo run need not write registry.json, so a live drive must keep the
    # old behaviour. These cases are about the no-drive path, so point the drive
    # registry at an EMPTY dir rather than letting the ambient environment decide
    # (leaving it unset let a real marker leak in and flipped three results).
    my $ddir = "$proj/.drive-empty";
    mkdir $ddir unless -d $ddir;
    local %ENV = (%ENV, BP_PROJECT_ROOT => fwd($proj),
                  CCPRAXIS_CONTINUITY_ACTIVE_DIR => fwd($cdir),
                  CCPRAXIS_DRIVE_ACTIVE_DIR => fwd($ddir),
                  GPATH => fwd($HOOK), PFILE => fwd($pf));
    system('bash', '-c', '"$GPATH" < "$PFILE" >/dev/null 2>&1');
    return $? >> 8;
}

# ---- THE BUG: a never-launched blueprint does not block a stop ---------------
{
    my $p = project(status => 'drafting',
                    pkgs   => { '01-a' => 'pending', '02-b' => 'pending' });
    is(verdict($p), 0,
       'a drafted, never-launched blueprint full of pending packages does NOT block a stop');
}
{
    # An AUDITED blueprint nobody has driven is the same case: audited means
    # drivable, not driven.
    my $p = project(status => 'audited', pkgs => { '01-a' => 'pending' });
    is(verdict($p), 0, 'an audited but never-launched blueprint does not block either');
}
{
    # The shape that actually trapped the session: a stale `running` left behind
    # with no registry row and nothing that could ever reap it (report 9a76).
    my $p = project(status => 'audited', pkgs => { '03-store' => 'running' });
    is(verdict($p), 0,
       'a stale `running` in a blueprint with no runs/ evidence does not block a stop');
}

# ---- THE DIRECTION THAT MATTERS: a live run still blocks --------------------
for my $ev (qw(registry orchestrator jsonl)) {
    my $p = project(status => 'audited', pkgs => { '01-a' => 'pending' }, launched => $ev);
    is(verdict($p), 2, "a launched blueprint ($ev evidence) with a pending package still BLOCKS");
}
{
    my $p = project(status => 'audited', pkgs => { '01-a' => 'running' }, launched => 'registry');
    is(verdict($p), 2, 'a launched blueprint with a RUNNING package still blocks');
}

# ---- a launched blueprint whose work is finished lets the stop through -------
{
    my $p = project(status => 'audited', launched => 'registry',
                    pkgs => { '01-a' => 'done', '02-b' => 'blocked', '03-c' => 'parked' });
    is(verdict($p), 0,
       'done/blocked/parked are all terminal -- a finished run may stop');
}
{
    my $p = project(status => 'audited', launched => 'registry',
                    pkgs => { '01-a' => 'done', '02-b' => 'pending' });
    is(verdict($p), 2, 'one pending package among terminal ones is still outstanding');
}

# ---- archived is still skipped, as before -----------------------------------
{
    my $p = project(status => 'archived', pkgs => { '01-a' => 'pending' }, launched => 'registry');
    is(verdict($p), 0, 'an archived blueprint is skipped even when launched');
}

# ---- the guard still only gates the finish verbs ----------------------------
{
    my $p = project(status => 'audited', pkgs => { '01-a' => 'pending' }, launched => 'registry');
    is(verdict($p, 'ls -la'), 0, 'an unrelated command is untouched even with work outstanding');
    is(verdict($p, 'perl bp-runstate.pl finish'), 2, 'the other finish verb is gated too');
}

done_testing();
