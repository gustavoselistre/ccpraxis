#!/usr/bin/env perl
# 150-continuity-gate.t -- g01-explicit-continuity-arming, THE STOP GATE:
# gate-continuity.sh plus its reap, and the mark-wakeup.sh extension that
# feeds it.
#
# Spec: specs/g01-explicit-continuity-arming-spec.md SS2.3 (registry/reap),
# SS2.4 (mark-wakeup.sh extension), SS2.5 (gate-continuity.sh pseudocode),
# SS3 behaviors 9-15, SS4 AC-5/AC-6/AC-9/AC-10/AC-11. Written BLIND to
# plugins/butler/hooks/gate-continuity.sh (does not exist) and to lib.sh's
# continuity additions -- every expectation is transcribed from the spec's
# pseudocode and acceptance criteria, not inferred from any implementation.
#
# THE ASSERTION THIS PACKAGE MOST NEEDS is section E below (AC-5 / criterion
# 2 / criterion 6's "stale/abandoned arm reaped without its owner returning"):
# a marker owned by a session id that NEVER appears again in this file is
# reaped by a DIFFERENT session's Stop. This is the ledger's own cited defect
# (lib.sh:398-409 -- three markers 55h old survived three consecutive stops
# because the per-session TTL check only ran for the session whose id
# matched, and a dead session never returns to reap its own).
#
# AC-6 (criterion 3): no fixture in this file ever stubs or requires
# bp-drive-next.pl or branches on BP_LEDGER's presence to decide GATE
# behavior (BP_LEDGER is asserted only as the top-of-file short-circuit,
# section D, which is the opposite of a director consult) -- proving this is
# the new, director-free gate, not a re-arming of gate-drive-loop.sh.
#
# NEVER points at real state: CCPRAXIS_CONTINUITY_ACTIVE_DIR and
# CCPRAXIS_DATA_DIR are always fresh File::Temp tempdirs.
#
# Every hook payload below is built with JSON::PP->new->canonical->encode,
# never string interpolation -- see 142-reporter-registration.t's own header
# note on why a hand-interpolated payload is a malformed-fixture hazard.
#
# Runs standalone: perl plugins/butler/tests/t/150-continuity-gate.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP;

# Fixtures build wake-up markers through the SAME module the gate verifies with.
# They used to hand-roll the line, and when the contract gained a process
# identity they silently became "unverifiable" markers testing the wrong thing.
require "$Bin/../../scripts/BpResumption.pm";

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-continuity.sh";

ok(-f $MARK,  'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $GATE,  'A2: gate-continuity.sh exists') or BAIL_OUT('new gate missing -- nothing else here can run');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub run_mark {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$opt{cdir}' " if defined $opt{cdir};
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$opt{ddir}' "      if defined $opt{ddir};
    my $out = `${env}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub run_gate {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$opt{cdir}' " if defined $opt{cdir};
    $env .= "CCPRAXIS_CONTINUITY_STOP_OK=1 "                if $opt{stop_ok};
    $env .= "CCPRAXIS_CONTINUITY_TTL_H=$opt{ttl_h} "        if defined $opt{ttl_h};
    $env .= "BP_LEDGER='$opt{bp_ledger}' "                  if defined $opt{bp_ledger};
    my $out = `${env}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub stop_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({ session_id => $sid, cwd => $cwd });
}

sub task_dispatch_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Task',
        tool_input => { description => 'do something', prompt => 'go' },
    });
}

sub backgrounded_bash_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => 'sleep 300', run_in_background => JSON::PP::true },
    });
}

sub marker_path { my ($cdir, $sid) = @_; return "$cdir/$sid"; }

# Plant a marker directly (bypassing arm/mark-wakeup), for fixtures that need
# precise control over mtime/content -- mirrors 143-reporter-stop-gate.t's
# own direct-plant technique for TTL/staleness fixtures.
sub plant_marker {
    my ($cdir, $sid, %opt) = @_;
    make_path($cdir);
    my $path = marker_path($cdir, $sid);
    open my $fh, '>', $path or die "plant $path: $!";
    print {$fh} ($opt{content} // "agent 2026-01-01T00:00:00Z\n");
    close $fh;
    if (defined $opt{age_hours}) {
        my $t = time() - int($opt{age_hours} * 3600);
        utime($t, $t, $path) or diag("utime failed: $!");
    }
    return $path;
}

# ===========================================================================
# B. Behavior 11 / AC-9: an armed session's Stop, immediately after a Task
#    dispatch recorded via the EXTENDED mark-wakeup.sh, is ALLOWED --
#    .wakeup-pending consumed.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-b');

    my ($mrc, $mout) = run_mark(task_dispatch_payload($root, 'sess-b'), cdir => $cdir);
    is($mrc, 0, 'B0 setup: mark-wakeup.sh never blocks on a Task dispatch');
    # B1 INVERTED. It used to assert that a dispatch WRITES the continuity
    # wake-up marker. Once the gate began requiring a `bounded` deadline, a
    # marker written here could never permit a stop again -- so the assertion
    # was pinning a no-op, and the write had become actively harmful: it was
    # truncating, so a dispatch made after taking a bounded hold destroyed that
    # hold's deadline. The documented workflow is exactly that order. The write
    # is gone and this now guards its return.
    ok(!-f marker_path($cdir, 'sess-b') . '.wakeup-pending',
       'B1 CANONICAL: a Task dispatch writes NO continuity wake-up marker -- a dispatch '
     . 'records that something started, never that anything will come back');

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-b'), cdir => $cdir);
    # B2 AMENDED (operator request, 2026-09-10): a bare dispatch marker no
    # longer permits the stop on its own. AC-9 read "a dispatch happened, so a
    # wake-up is scheduled", and that inference is unsound in one specific way:
    # a dispatch is not a promise to come back. A subagent that runs forever, or
    # a background command with no timeout, writes exactly this marker and then
    # never returns -- leaving the session idle with nothing left to re-invoke
    # it, which is the very outcome the gate exists to prevent. The marker's TTL
    # cannot rescue it either: the TTL only decides whether a LATER stop is
    # allowed, and there is no later stop.
    #
    # A wake-up now has to be BOUNDED -- see the D block for the shape that
    # permits it, and `bp-continuity.pl hold`, which writes it and then delivers
    # it from the same process.
    isnt($rc, 0, 'B2 AMENDED (was AC-9/behavior 10): a Stop after a bare Task dispatch is '
               . 'BLOCKED -- a dispatch records that something STARTED, never that anything '
               . 'will come back');
    ok(!-f marker_path($cdir, 'sess-b') . '.wakeup-pending',
       'B3 CANONICAL: the wake-up-pending file is CONSUMED (removed) either way, so a stale '
     . 'marker can never be spent twice');
}

# ===========================================================================
# C. Behavior 11 / AC-9 continued, backgrounded Bash variant.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-c');

    my ($mrc) = run_mark(backgrounded_bash_payload($root, 'sess-c'), cdir => $cdir);
    is($mrc, 0, 'C0 setup: mark-wakeup.sh never blocks on a backgrounded Bash call');
    ok(!-f marker_path($cdir, 'sess-c') . '.wakeup-pending',
       'C1 CANONICAL: nor does a backgrounded Bash call -- backgrounding a command with '
     . 'no timeout is the unbounded case, not a scheduled wake-up');

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-c'), cdir => $cdir);
    # C2 AMENDED alongside B2: backgrounding a Bash call is the case that makes
    # the old rule's unsoundness concrete. `run_in_background` on a command with
    # no timeout -- a tail -f, a server, a poll loop -- writes this marker and
    # may never exit. The gate cannot read the command, so it cannot tell that
    # one from a ten-second build; the only sound rule is to require a wait that
    # states its own deadline.
    isnt($rc, 0, 'C2 AMENDED (was AC-9): a Stop after a bare backgrounded Bash call is BLOCKED '
               . '-- backgrounding a command with no timeout is exactly the unbounded case');
}

# ===========================================================================
# C2. Negative pairing for B/C: a FOREGROUND Bash call must NOT write the
#     wake-up-pending file -- the same false-positive discipline
#     mark-wakeup.sh already applies for the drive-solo path.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-c2');
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-c2', cwd => $root, tool_name => 'Bash',
        tool_input => { command => 'ls', run_in_background => JSON::PP::false },
    });
    my ($mrc) = run_mark($payload, cdir => $cdir);
    is($mrc, 0, 'C2a setup: mark-wakeup.sh never blocks on a foreground Bash call');
    ok(!-f marker_path($cdir, 'sess-c2') . '.wakeup-pending',
       'C2b CANONICAL: a FOREGROUND Bash call (run_in_background:false) does NOT write the '
     . 'continuity wake-up-pending file -- proves the trigger is the boolean, not merely '
     . '"any Bash call"');
}

# ===========================================================================
# B2. THE CLOBBER, in the order the docs actually prescribe.
#
# SKILL.md says to take a bounded wait "alongside whatever you dispatched", and
# the gate's own block text says the same. Both orders must therefore work. They
# did not: mark-wakeup.sh wrote `<epoch> <ToolName>` over the SAME file with a
# truncating `>`, so taking a hold and then dispatching destroyed the hold's
# deadline and the next Stop blocked -- while dispatch-then-hold survived by
# luck of ordering, with nothing anywhere stating the dependency.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-b2');

    # A live bounded hold, as `bp-continuity.pl hold` writes it. Field 4 is the
    # PID of the process promising to return; $$ is this test, which is alive,
    # so the gate's liveness check passes and B2 stays a test of the CLOBBER
    # rather than an accidental test of liveness.
    my $wp = marker_path($cdir, 'sess-b2') . '.wakeup-pending';
    open my $fh, '>', $wp or die "fixture: $!";
    print {$fh} BpResumption::marker_line(deadline => time() + 600, pid => $$);
    close $fh;

    # ...then a dispatch, which is what used to overwrite it.
    my ($mrc) = run_mark(task_dispatch_payload($root, 'sess-b2'), cdir => $cdir);
    is($mrc, 0, 'B2-0 setup: the dispatch hook still exits 0');

    ok(-f $wp, 'B2-1: the bounded marker still exists after a dispatch');
    open my $rh, '<', $wp or die $!;
    my $line = <$rh>;
    close $rh;
    like($line, qr/\bbounded\b/,
         'B2-2 CANONICAL: and is still BOUNDED -- a dispatch no longer truncates a live hold');

    my ($rc) = run_gate(stop_payload($root, 'sess-b2'), cdir => $cdir);
    is($rc, 0, 'B2-3 CANONICAL: so the stop is permitted, in the order the docs prescribe');
}

# ===========================================================================
# D. AC-6/AC-10 AMENDED: an armed Stop with no wake-up is blocked, and STAYS
#    blocked. The gate no longer yields after N refusals.
#
#    THE BOUND WAS PROTECTING AGAINST A GAP THAT IS NOW CLOSED. It existed
#    because the only honest way to satisfy this gate was to have real work in
#    flight: an agent with nothing to schedule, and no way to say so, could be
#    wedged -- and a gate that will not yield is worse than a stalled run. There
#    are now three remedies and one of them is always true: `hold` (something
#    will return), `await-operator` (a human was asked), `disarm` (the work is
#    finished). Each is one command.
#
#    Yielding now costs more than it saves: it converts a loud refusal into a
#    silent one, ending the session armed, unwatched, with nothing scheduled --
#    the exact outcome this gate exists to prevent, arriving at the one moment
#    nobody is looking for it. Operator's call, 2026-09-10.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-d');

    my ($rc1, $out1) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc1, 2, 'D1 CANONICAL (-> behavior 9/AC-6): 1st Stop with no wake-up pending is '
              . 'BLOCKED -- exit 2');

    # The message must name every remedy it has, because an agent that cannot
    # find one is the case the removed bound used to rescue.
    like($out1, qr/\bhold\b/,           'D1a: the block text offers hold');
    # D1b AMENDED: the message no longer offers a way to end the turn for a
    # question. An armed session IS unattended work, so "I asked a human" is not
    # an exit -- it is a reason to queue and keep going. What the message must
    # still do is say where the question goes.
    like($out1, qr/\bask\b/,            'D1b: ...and points questions at the queue');
    unlike($out1, qr/await-operator/,   'D1b: and no longer offers halting-to-ask as an exit');

    like($out1, qr/disarm/i,            'D1c: ...and disarm');
    like($out1, qr/--seconds/,          'D1d: with a runnable hold invocation, not just a verb name');

    # No `/../` in anything it tells the reader to run. The path used to be
    # printed unresolved, twice, in one message.
    unlike($out1, qr{/\.\./},
       'D1e: no unresolved `/../` in the remedies -- the path is resolved before printing');

    my ($rc2) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc2, 2, 'D2: 2nd consecutive Stop also blocked');
    my ($rc3) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc3, 2, 'D3: 3rd consecutive Stop also blocked');
    my ($rc4) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc4, 2, 'D4 AMENDED (was AC-10/behavior 13): the 4th is blocked TOO -- the gate '
              . 'does not yield on its own any more');
    my ($rc5) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc5, 2, 'D5: and the 5th, and so on. It blocks until a remedy is actually run');

    # Non-vacuity: it is not simply refusing everything. A remedy still works.
    my ($rc6) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir, stop_ok => 1);
    is($rc6, 0, 'D6 CANONICAL: and a session that RUNS one of the remedies is permitted -- '
              . 'the gate is unyielding, not immovable');
}

# ===========================================================================
# E. *** THE ASSERTION THIS PACKAGE MOST NEEDS *** -- AC-5 / criterion 2 /
#    criterion 6: a stale marker owned by session X, mtime forced to
#    now-(TTL+1)h, with NO marker for session Y (the one invoking the gate),
#    is REMOVED (with its companions) by session Y's Stop -- and does NOT
#    block Y. Session X's id NEVER appears anywhere else in this file: it is
#    constructed once here and never returns, by design, to prove the reap
#    does not depend on the owner coming back.
# ===========================================================================
{
    my $root_x = new_project();       # X's own (abandoned) project, never revisited
    my $cdir   = tempdir(CLEANUP => 1);
    my $ttl_h  = 12;
    plant_marker($cdir, 'sess-X-abandoned-forever', age_hours => $ttl_h + 1);
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        open my $fh, '>', marker_path($cdir, 'sess-X-abandoned-forever') . $suffix or die $!;
        close $fh;
    }
    ok(-f marker_path($cdir, 'sess-X-abandoned-forever'), 'E0a setup: X'."'".'s marker exists, aged past TTL');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        ok(-f marker_path($cdir, 'sess-X-abandoned-forever') . $suffix, "E0b setup: X's $suffix companion exists");
    }
    ok(!-f marker_path($cdir, 'sess-Y-the-reaper'), 'E0c setup: Y has never been armed');

    my $root_y = new_project();       # a DIFFERENT project -- Y's Stop, not X's
    my ($rc, $out) = run_gate(stop_payload($root_y, 'sess-Y-the-reaper'), cdir => $cdir, ttl_h => $ttl_h);

    is($rc, 0, 'E1 CANONICAL (-> AC-5): session Y'."'".'s Stop is NOT blocked -- Y was never '
             . 'armed, so the gate must be a pure no-op for Y regardless of what it reaps');
    ok(!-f marker_path($cdir, 'sess-X-abandoned-forever'),
       'E2 *** THE CANONICAL ASSERTION *** (-> criterion 2/6, closes lib.sh:398-409): X'."'".'s '
     . 'primary marker is GONE after Y'."'".'s Stop -- X never returned; Y'."'".'s Stop is what '
     . 'reaped it. An implementation whose reap only runs for the session whose id matches a '
     . 'marker (the exact historical defect) leaves this file un-removed and fails here.');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        ok(!-f marker_path($cdir, 'sess-X-abandoned-forever') . $suffix,
           "E3 CANONICAL: X's $suffix companion is ALSO removed by the same sweep");
    }
}

# ===========================================================================
# F. Behavior 12 negative pairing / AC-6: an UNARMED session's Stop is a
#    pure no-op beyond the cheap pre-check -- no marker, no companions, no
#    side effects for a session that was never armed at all (own project,
#    own registry, nothing planted).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);   # exists but empty -- no markers at all
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-f-never-armed'), cdir => $cdir);
    is($rc, 0, 'F1 CANONICAL (-> behavior 11): an unarmed session'."'".'s Stop exits 0 with no '
             . 'side effects');
    ok(!-f marker_path($cdir, 'sess-f-never-armed'),
       'F2: no marker was created for the never-armed session as a side effect');
}

# ===========================================================================
# G. BP_LEDGER short-circuit (spec SS2.5 top-of-file, edge case list): a
#    coordinator's Stop exits 0 UNCONDITIONALLY, even with a live, blocking
#    marker for that exact session id present. This is the ONLY place
#    BP_LEDGER is read in this whole file (AC-6's own discipline).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-g-coordinator');   # would otherwise block (fresh, no wake-up)
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-g-coordinator'),
                               cdir => $cdir, bp_ledger => '/fake/ledger.md');
    is($rc, 0, 'G1 CANONICAL (-> edge cases SS5): BP_LEDGER set exits 0 unconditionally, '
             . 'before the marker is even consulted -- defense in depth alongside arm'."'".'s '
             . 'own refusal');
}

# ===========================================================================
# H. CCPRAXIS_CONTINUITY_STOP_OK=1 session-wide hatch (behavior 15) -- every
#    Stop of that session allowed unconditionally, marker untouched.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-h');
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-h'), cdir => $cdir, stop_ok => 1);
    is($rc, 0, 'H1 CANONICAL (-> behavior 15): CCPRAXIS_CONTINUITY_STOP_OK=1 allows the stop '
             . 'even with a fresh, otherwise-blocking marker');
}

# ===========================================================================
# I. One-shot .stop-ok escape hatch (behavior 14) -- consumed on use, session
#    remains armed afterward (marker itself still present).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-i');
    open my $fh, '>', marker_path($cdir, 'sess-i') . '.stop-ok' or die $!;
    close $fh;

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-i'), cdir => $cdir);
    is($rc, 0, 'I1 CANONICAL (-> behavior 14): the one-shot .stop-ok file allows the stop');
    ok(!-f marker_path($cdir, 'sess-i') . '.stop-ok',
       'I2 CANONICAL: ...and is CONSUMED -- an operator override applies once');
    ok(-f marker_path($cdir, 'sess-i'),
       'I3: the session REMAINS armed afterward -- the primary marker survives the one-shot '
     . 'hatch, unlike a full disarm');
}

# ===========================================================================
# J. TTL reap of the CALLING session's OWN marker (belt-to-braces per SS2.5's
#    per-marker check, distinct from E's cross-session sweep): a session
#    whose OWN marker has aged past the TTL is allowed, and its own marker is
#    removed too.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    my $ttl_h = 12;
    plant_marker($cdir, 'sess-j-self-stale', age_hours => $ttl_h + 1);

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-j-self-stale'), cdir => $cdir, ttl_h => $ttl_h);
    is($rc, 0, 'J1 CANONICAL (-> SS2.5 per-marker TTL): a session whose own marker is older '
             . 'than the TTL is ALLOWED to stop');
    ok(!-f marker_path($cdir, 'sess-j-self-stale'),
       'J2: ...and its own now-expired marker is removed too');
}

# ===========================================================================
# K. fix-batch F1: with CCPRAXIS_CONTINUITY_ACTIVE_DIR unset AND $HOME/
#    $USERPROFILE also unset for the gate's own process, bp_continuity_active_dir
#    (lib.sh) cannot resolve a directory at all. The gate must FAIL SAFE --
#    exit 0, no crash, no block -- rather than either guessing $PWD (the
#    pre-fix behavior) or dying. This is the READ-side half of F1's rule:
#    unresolvable degrades to "nothing armed", never a hard failure.
# ===========================================================================
{
    my $root = new_project();
    local %ENV = %ENV;
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    my $payload = stop_payload($root, 'sess-k-unresolvable');
    my $out = `bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    is($rc, 0, 'K1 CANONICAL (-> fix-batch F1): gate-continuity.sh with no resolvable registry '
             . 'directory anywhere (CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME, $USERPROFILE all '
             . 'unset) exits 0 -- fails safe, never blocks, never crashes');
}

# ===========================================================================
# K2. fix-batch F1, DISCRIMINATING probe: K1 alone cannot distinguish "truly
#    unresolvable" from "silently resolved under $PWD, which happened to be
#    empty" -- both exit 0. Call bp_continuity_active_dir DIRECTLY (source
#    lib.sh) with the same env and assert it returns 1 with EMPTY stdout --
#    proves the function itself refuses to guess $PWD, not merely that the
#    gate's overall behavior happens to still be harmless.
# ===========================================================================
{
    local %ENV = %ENV;
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    my ($pfh, $ppath) = tempfile(SUFFIX => '.sh');
    print {$pfh} <<"PROBE_EOF";
set -u
source '$HOOKS/lib.sh' 2>/dev/null || exit 3
out=\$(bp_continuity_active_dir)
rc=\$?
printf 'RC=%s OUT=[%s]\\n' "\$rc" "\$out"
PROBE_EOF
    close $pfh;
    my $out = `bash "$ppath" 2>&1`;
    unlink $ppath;
    like($out, qr/RC=1 OUT=\[\]/,
       'K2 CANONICAL (-> fix-batch F1): bp_continuity_active_dir itself returns 1 with EMPTY '
     . 'stdout when CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME and $USERPROFILE are all unset -- an '
     . 'implementation that falls back to $PWD (the pre-fix behavior) would print a non-empty '
     . 'path and return 0 here, passing K1 by accident while still failing this');
}

# ===========================================================================
# Z. A STALE WAKE-UP MARKER MUST NOT PERMIT A STOP.
#     (bug report 20260829-225523-88e7)
#
# The marker records that something was DISPATCHED. It never recorded WHEN, so
# it did not distinguish "a background task is running" from "a background task
# ran, finished, and was reported on three turns ago". The gate consumed
# whichever marker happened to be on disk, and an armed session ended a turn
# having just written "next: promote, then re-run the sync" -- exactly the
# failure this gate exists to prevent. The operator had to ask why it stopped.
#
# A wake-up scheduled long ago has either fired or died; a shell hook cannot
# tell which, and both mean it is no longer pending. So it expires.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-z');

    my $wp = marker_path($cdir, 'sess-z') . '.wakeup-pending';

    # A marker stamped well in the past: the shape left behind by a background
    # task that completed several turns earlier.
    open my $fh, '>', $wp or die "fixture: $!";
    print {$fh} (time - 86400) . " Bash\n";
    close $fh;
    ok(-f $wp, 'Z0 fixture: a stale wake-up marker exists');

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-z'), cdir => $cdir);
    isnt($rc, 0, 'Z1: a STALE wake-up marker does NOT permit the stop -- the gate still blocks');
    ok(!-f $wp, 'Z2: ...and the stale marker is removed, so it cannot be spent twice');

    # And the permitting case still works, so Z1 is not just "the gate always
    # blocks". It has to be a BOUNDED marker now -- fresh is necessary and no
    # longer sufficient. Field 2/3 are what `bp-continuity.pl hold` writes:
    # the literal "bounded" and the epoch it guarantees a return by.
    my $root2 = new_project();
    my $cdir2 = tempdir(CLEANUP => 1);
    plant_marker($cdir2, 'sess-z2');
    my $wp2 = marker_path($cdir2, 'sess-z2') . '.wakeup-pending';
    open my $fh2, '>', $wp2 or die "fixture: $!";
    print {$fh2} BpResumption::marker_line(deadline => time() + 300, pid => $$);
    close $fh2;
    my ($rc2) = run_gate(stop_payload($root2, 'sess-z2'), cdir => $cdir2);
    is($rc2, 0, 'Z3 non-vacuity: a fresh BOUNDED wake-up marker permits the stop');

    # ...and the counter-check that boundedness is what did it: same freshness,
    # no deadline, blocked.
    my $root_ub = new_project();
    my $cdir_ub = tempdir(CLEANUP => 1);
    plant_marker($cdir_ub, 'sess-unbounded');
    my $wp_ub = marker_path($cdir_ub, 'sess-unbounded') . '.wakeup-pending';
    open my $fh_ub, '>', $wp_ub or die "fixture: $!";
    print {$fh_ub} time . " Bash\n";
    close $fh_ub;
    my ($rc_ub) = run_gate(stop_payload($root_ub, 'sess-unbounded'), cdir => $cdir_ub);
    isnt($rc_ub, 0, 'Z4: an equally fresh UNBOUNDED marker does not permit it -- boundedness '
                  . 'is doing the work, not recency');

    # A bounded marker whose deadline has already passed is not a wake-up
    # either: nothing is going to return.
    my $root_ex = new_project();
    my $cdir_ex = tempdir(CLEANUP => 1);
    plant_marker($cdir_ex, 'sess-expired');
    my $wp_ex = marker_path($cdir_ex, 'sess-expired') . '.wakeup-pending';
    open my $fh_ex, '>', $wp_ex or die "fixture: $!";
    print {$fh_ex} BpResumption::marker_line(deadline => time() - 5, pid => $$);
    close $fh_ex;
    my ($rc_ex) = run_gate(stop_payload($root_ex, 'sess-expired'), cdir => $cdir_ex);
    isnt($rc_ex, 0, 'Z5: a bounded marker whose deadline has passed does not permit the stop');

    # An unstamped marker (written before the timestamp field existed) still
    # falls back to mtime for the FRESHNESS half of the check -- but freshness
    # is no longer sufficient, so it is now blocked as unbounded. That is the
    # safe direction for a legacy marker: the gate cannot know what wrote it or
    # whether anything will return, and blocking costs one bounded hold while
    # allowing costs a session that never wakes.
    my $root3 = new_project();
    my $cdir3 = tempdir(CLEANUP => 1);
    plant_marker($cdir3, 'sess-z3');
    my $wp3 = marker_path($cdir3, 'sess-z3') . '.wakeup-pending';
    open my $fh3, '>', $wp3 or die "fixture: $!"; close $fh3;   # empty, no stamp
    my ($rc3) = run_gate(stop_payload($root3, 'sess-z3'), cdir => $cdir3);
    isnt($rc3, 0, 'Z6 upgrade path AMENDED: an unstamped legacy marker is treated as UNBOUNDED '
                . 'and does not permit the stop -- freshness alone stopped being sufficient');
}

# ===========================================================================
# W. THE PROMISE MUST BE ALIVE (H4a).
#
# A deadline in a file is an assertion, not a guarantee. `hold` sleeps to that
# deadline in a real process and it is that process EXITING that re-invokes the
# session -- so if it has been killed (operator interrupt, container restart,
# OOM), the wake-up died with it and nothing distinguishes that from a live wait
# except asking the kernel. Permitting a stop on a dead process's promise is the
# original failure with a better alibi.
# ===========================================================================
{
    # A pid that is certainly not running: fork a child and reap it, so the id
    # existed and is now gone. Far more honest than picking a large integer.
    my $dead = fork();
    if (defined $dead && $dead == 0) { exit 0 }
    waitpid($dead, 0) if defined $dead && $dead > 0;

    SKIP: {
        skip 'fork unavailable', 3 unless defined $dead && $dead > 0;

        my $root = new_project();
        my $cdir = tempdir(CLEANUP => 1);
        plant_marker($cdir, 'sess-w');
        my $wp = marker_path($cdir, 'sess-w') . '.wakeup-pending';
        open my $fh, '>', $wp or die "fixture: $!";
        print {$fh} BpResumption::marker_line(deadline => time() + 600, pid => $dead,
                                              fingerprint => 'proc:1');
        close $fh;

        my ($rc) = run_gate(stop_payload($root, 'sess-w'), cdir => $cdir);
        isnt($rc, 0, 'W1 CANONICAL: a bounded marker whose PROCESS is dead does not permit '
                   . 'the stop -- nothing is going to return');

        # Counter-check: identical marker, live pid, permitted. Without this W1
        # would pass just as well if the gate had started refusing everything.
        my $root2 = new_project();
        my $cdir2 = tempdir(CLEANUP => 1);
        plant_marker($cdir2, 'sess-w2');
        my $wp2 = marker_path($cdir2, 'sess-w2') . '.wakeup-pending';
        open my $fh2, '>', $wp2 or die "fixture: $!";
        print {$fh2} BpResumption::marker_line(deadline => time() + 600, pid => $$);
        close $fh2;
        my ($rc2) = run_gate(stop_payload($root2, 'sess-w2'), cdir => $cdir2);
        is($rc2, 0, 'W2: the same marker with a LIVE pid does permit it');

        # A marker predating the pid field is unverifiable, so it is refused --
        # the same direction every other unknown takes here.
        my $root3 = new_project();
        my $cdir3 = tempdir(CLEANUP => 1);
        plant_marker($cdir3, 'sess-w3');
        my $wp3 = marker_path($cdir3, 'sess-w3') . '.wakeup-pending';
        open my $fh3, '>', $wp3 or die "fixture: $!";
        print {$fh3} time . ' bounded ' . (time + 600) . "\n";
        close $fh3;
        my ($rc3) = run_gate(stop_payload($root3, 'sess-w3'), cdir => $cdir3);
        isnt($rc3, 0, 'W3: a bounded marker with NO pid is treated as unverifiable, not trusted');
    }
}

# ===========================================================================
# V. A LIVE HOLD SURVIVES BEING WOKEN EARLY.
#
# The marker used to be consumed on every stop, which was right when it was a
# bare "something was dispatched" flag: there was no way to tell whether it was
# still pending, so spending it once was the only safe reading.
#
# A bounded marker is different -- it names a deadline and a live process, so
# its validity is re-derived on every check. Consuming it broke a CONTINUING
# promise: a hold sleeps for minutes, and if the session wakes for any other
# reason in the meantime (a background task finishing, a notification), that
# turn's stop spends the marker and the NEXT stop is blocked while the hold is
# still alive and still going to fire.
#
# Observed live: blocked while an 890s hold was sleeping, having been woken
# early by an unrelated task completing.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-v');
    my $wp = marker_path($cdir, 'sess-v') . '.wakeup-pending';
    open my $fh, '>', $wp or die "fixture: $!";
    print {$fh} BpResumption::marker_line(deadline => time() + 600, pid => $$);
    close $fh;

    my ($rc1) = run_gate(stop_payload($root, 'sess-v'), cdir => $cdir);
    is($rc1, 0, 'V1: the first stop is permitted by the live hold');
    ok(-f $wp, 'V2 CANONICAL: and the marker SURVIVES -- the promise has not been spent, '
             . 'the process is still sleeping toward the same deadline');

    my ($rc2) = run_gate(stop_payload($root, 'sess-v'), cdir => $cdir);
    is($rc2, 0, 'V3 CANONICAL: so a second stop is permitted too. Waking early for an '
              . 'unrelated reason must not invalidate a hold that is still running');

    # ...and the "cannot be spent twice" property still holds where it matters:
    # a marker that CANNOT justify a stop is removed, so it cannot be re-read.
    my $root2 = new_project();
    my $cdir2 = tempdir(CLEANUP => 1);
    plant_marker($cdir2, 'sess-v2');
    my $wp2 = marker_path($cdir2, 'sess-v2') . '.wakeup-pending';
    open my $fh2, '>', $wp2 or die "fixture: $!";
    print {$fh2} BpResumption::marker_line(deadline => time() - 5, pid => $$);
    close $fh2;
    my ($rc3) = run_gate(stop_payload($root2, 'sess-v2'), cdir => $cdir2);
    isnt($rc3, 0, 'V4: an expired hold does not permit the stop');
    ok(!-f $wp2, 'V5: and IS removed -- a dead promise cannot be re-read later');
}

# ===========================================================================
# R. THE REMEDY IS RUNNABLE, whatever the hook's PATH happens to be.
#
# A hook does not run in the agent's shell. The agent's Bash calls are
# profile-initialised and re-read the user's PATH; this hook inherits whatever
# PATH the long-running Claude Code process started with, which can predate a
# newly added bin directory by an entire session. Observed exactly that: the
# first block message after adding the shim printed the fallback, while
# `bp-continuity.sh` resolved in every shell the agent had.
#
# So a PATH miss says nothing about whether the short form would work for the
# READER, and the fallback has to be good rather than merely correct.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-r');

    # With no shim reachable on PATH, the message must still name something
    # directly runnable -- and not make the reader assemble it.
    local $ENV{PATH} = '/usr/bin:/bin';
    my (undef, $out) = run_gate(stop_payload($root, 'sess-r'), cdir => $cdir);

    like($out, qr/hold --seconds \d+/,
         'R1: the hold remedy is a complete, runnable invocation');
    unlike($out, qr{/\.\./},
         'R2 CANONICAL: no unresolved `/../` reaches the reader');
    like($out, qr{(?:^|\s)(?:\S*bp-continuity\.sh|bp-continuity|perl \S+bp-continuity\.pl) hold}m,
         'R3: and it resolves to a shim, a shim path, or perl + the script -- never a bare '
       . 'verb the reader has to work out how to invoke');

    # Every remedy in the message uses the SAME spelling. A message that named
    # the command three different ways would teach the reader that the spelling
    # is guesswork.
    # Command lines only. The message's prose is indented 5 columns and its
    # runnable lines 9, and the prose legitimately contains the verbs ("Take the
    # hold alongside it"), so an indent-blind match reads sentences as commands.
    my @spellings = ($out =~ /^ {8,}(\S+) (?:hold|await-operator|disarm)\b/mg);
    my %uniq = map { $_ => 1 } @spellings;
    cmp_ok(scalar(keys %uniq), '<=', 1,
       'R4: all three remedies are spelled with one consistent command form');
}

done_testing();
