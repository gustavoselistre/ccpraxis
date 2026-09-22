#!/usr/bin/env perl
# platform: windows
# 143 — g03, PILLARS 2 and 4: the gate
# FIRES for a registered reporter and does NOT fire for a non-reporter, both
# directions exercised end to end; and the refusal names the REPORTER's own
# remedy, never the driver's.
#
# Spec: specs/g03-spec.md §1.4 (Decision 4 -> DC3), §2.2
# (gate-drive-loop.sh reporter branch), §3 behaviors 2-8, §4 AC2/AC3/AC4/AC8.
#
# AC8, quoted directly, is the governing discipline for this whole file: "an
# oracle that only greps gate-drive-loop.sh's source for the string
# 'reporter' passes trivially and proves nothing; explicitly forbidden, per
# the task's own g02 precedent." Every assertion below invokes mark-wakeup.sh
# and gate-drive-loop.sh as REAL subprocesses with constructed JSON payloads
# on stdin and reads the REAL exit code -- never a source grep as the oracle
# for behavior (source is only inspected in section H, to pin the vocabulary
# of the message, never as a substitute for exercising it).
#
# NON-VACUITY. Every BLOCK assertion is paired with an exit-code check AND
# (where the fixture claims content) a content check, per the dispatch
# prompt's instruction that a gate oracle is especially exposed to "passing
# because the hook exited early and printed nothing".
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives bp-continuity.pl /
# bp-runstate.pl / gate-continuity.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";
my $RS    = "$Bin/../../scripts/bp-runstate.pl";

ok(-f $MARK, 'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $GATE, 'A2: gate-drive-loop.sh exists') or BAIL_OUT('hook missing');
ok(-f $RS,   'A3: bp-runstate.pl exists') or BAIL_OUT('state machine missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub run_mark {
    my ($payload, $rdir) = @_;
    my $out = `CCPRAXIS_REPORTER_ACTIVE_DIR='$rdir' bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub run_gate {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_REPORTER_ACTIVE_DIR='$opt{rdir}' " if defined $opt{rdir};
    $env .= "CCPRAXIS_REPORTER_STOP_OK=1 "               if $opt{reporter_stop_ok};
    $env .= "CCPRAXIS_DRIVE_STOP_OK=1 "                  if $opt{drive_stop_ok};
    $env .= "CCPRAXIS_REPORTER_TTL_H=$opt{ttl_h} "       if defined $opt{ttl_h};
    # PACKAGE 02 — force the probe (Signal A). $RDATA is the project's own
    # .ccpraxis-local-data (spec §2.1: "already the .ccpraxis-local-data dir").
    $env .= "BP_PROBE_PROC_DIR='$opt{probe_dir}' "       if defined $opt{probe_dir};
    $env .= "BP_PROBE_SELF_PID='$opt{probe_self_pid}' "  if defined $opt{probe_self_pid};
    $env .= "BP_PROBE_CLK_TCK=100 "                       if defined $opt{probe_dir};
    my $out = `${env}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# ---------------------------------------------------------------------------
# PACKAGE 02 fixture helpers — the probe (Signal A) and the finish marker
# (Signal B), duplicated locally per spec 02-gates-use-the-probe-spec.md §2.1.
# ---------------------------------------------------------------------------
sub _pw_cmdline {
    my ($procdir, $pid, @argv) = @_;
    make_path("$procdir/$pid");
    open my $fh, '>', "$procdir/$pid/cmdline" or die "write cmdline($pid): $!";
    binmode $fh;
    print {$fh} join("\0", @argv) . "\0";
    close $fh;
}
sub _pw_stat {
    my ($procdir, $pid, $ticks) = @_;
    make_path("$procdir/$pid");
    open my $fh, '>', "$procdir/$pid/stat" or die "write stat($pid): $!";
    print {$fh} "$pid (perl) S 1 " . join(' ', (0) x 17) . " $ticks\n";
    close $fh;
}
sub proc_dir_none { return tempdir(CLEANUP => 1) }
sub proc_dir_cannot_tell {
    my $r = tempdir(CLEANUP => 1);
    my $f = "$r/not-a-directory-file";
    open my $fh, '>', $f or die $!; print {$fh} 'x'; close $fh;
    return $f;
}
sub proc_dir_live {
    my ($data_dir, %opt) = @_;
    my $procdir  = tempdir(CLEANUP => 1);
    my $self_pid = 900001;
    my $pid      = 900002;
    my $ticks    = 1_000_000;
    _pw_stat($procdir, $self_pid, $ticks);
    _pw_cmdline($procdir, $pid, 'bp-watch.pl', '--arm', '--max-seconds',
                ($opt{max_seconds} // 9999), '--data', $data_dir);
    _pw_stat($procdir, $pid, $ticks);
    return ($procdir, $self_pid);
}
sub touch_finish_marker { my ($root) = @_; my $ds = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds); open my $fh, '>', "$ds/.run-finished" or die $!; close $fh;
    return "$ds/.run-finished" }

# Built with a real JSON encoder (not string interpolation) so $cmd's
# embedded quotes are escaped exactly as the real harness escapes them --
# see reporter-registration.t's own header note; the same fixture defect
# (unescaped quotes producing a malformed document) applied here too.
sub reporter_arm_payload {
    my ($cwd, $sid) = @_;
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --blueprint bp-x }
            . q{--pid-file bp-x/runs/.orchestrator --max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

# fix-batch B1 (red-team HIGH-1): the SAME arm command, but via the .sh-shim
# spelling package 04-bp-on-path put on PATH. Before the fix, mark-wakeup.sh's
# WARMED detector at hooks/mark-wakeup.sh:403 only matched a literal `.pl`
# extension, so this spelling silently never registered a reporter session.
sub reporter_arm_payload_sh {
    my ($cwd, $sid) = @_;
    my $cmd = q{bp-watch.sh --arm --blueprint bp-x }
            . q{--pid-file bp-x/runs/.orchestrator --max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

sub stop_payload { my ($cwd, $sid) = @_; return qq({"session_id":"$sid","cwd":"$cwd"}); }

# Register a reporter session THROUGH the real mark-wakeup.sh subprocess
# (AC8's own requirement), returning the project root and RDIR to reuse.
sub registered_reporter {
    my ($sid) = @_;
    $sid //= 'sess-stop-under-test';
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my ($mrc) = run_mark(reporter_arm_payload($root, $sid), $rdir);
    return ($root, $rdir, $sid, $mrc);
}

sub pause_reporter {
    my ($root, $pid, $until, %opt) = @_;
    my $reason = $opt{reason} // 'bp-watch.pl armed';
    return system(qq{perl "$RS" pause --surface reporter --watcher-pid $pid --until $until }
                . qq{--reason "$reason" --root "$root" >/dev/null 2>&1});
}

sub runstate_reporter_path {
    my ($root) = @_;
    return "$root/.ccpraxis-local-data/.subagent-guard/run-state.reporter.json";
}

# ===========================================================================
# B. AC2 (-> DC2): a registered reporter with NO bp-runstate.pl call at all
#    (state file absent -> inert) is REFUSED on Stop. Exit code asserted, not
#    merely stderr content.
# ===========================================================================
{
    my ($root, $rdir, $sid, $mrc) = registered_reporter('sess-b');
    is($mrc, 0, 'B0 setup: registration call itself never blocks');

    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 2, 'B1 CANONICAL (-> AC2): a registered reporter session, with NOTHING declared '
             . 'to bp-runstate.pl --surface reporter, is REFUSED on Stop -- exit 2, not a '
             . 'warning');
}

{   # fix-batch B1 (red-team HIGH-1): SAME as B, but registered via the
    # .sh-shim spelling -- proves the WARMED detector's broadened regex
    # (bp-watch(\.(pl|sh))?\b) recognizes it identically to the .pl form.
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $sid  = 'sess-b1-sh';
    my ($mrc) = run_mark(reporter_arm_payload_sh($root, $sid), $rdir);
    is($mrc, 0, 'B1sh setup: .sh-spelled registration call itself never blocks');

    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 2, 'B1sh: a reporter session registered via the .sh-shim spelling is REFUSED on '
             . 'Stop identically to the .pl form -- the on-PATH spelling is not silently '
             . 'invisible to the detector');
}

# ===========================================================================
# C. THE OTHER DIRECTION (Pillar 2's "both directions"): an UNREGISTERED
#    session (never called mark-wakeup.sh with the arm shape at all) is NOT
#    gated by the reporter branch -- it must fall through cleanly. Same
#    project shape as B, only the registration step is omitted.
#
#    NON-VACUITY NOTE: this assertion currently passes VACUOUSLY (the gate
#    has no reporter branch at all yet, pre-implementation, so of course an
#    unregistered session is not blocked). It stops being vacuous the moment
#    a reporter branch exists: an implementation that gates on the wrong
#    signal (e.g. "any Stop with a --root that has a .subagent-guard dir")
#    would wrongly fire here too, and this is the assertion that catches it.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);   # RDIR exists but has no marker in it
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-c-unregistered'), rdir => $rdir);
    is($rc, 0, 'C1 CANONICAL (Pillar 2, other direction): a session that never registered as '
             . 'a reporter is NOT gated -- the reporter branch must be provably inert for '
             . 'ordinary/non-reporter sessions, not merely permissive by coincidence');
}

# ===========================================================================
# D. AC3 (-> DC2/DC4): after a REAL `pause --surface reporter` call with a
#    live pid and a future deadline, the SAME session's next Stop is ALLOWED.
#
#    NON-VACUITY NOTE: D0 (the setup pause call) is EXPECTED to fail today —
#    bp-runstate.pl has no --surface flag yet (exit 3, "unknown option"),
#    which is exactly what file 144 pins directly. D1 therefore currently
#    passes VACUOUSLY (no reporter branch exists yet to block anything). Once
#    both land, D0 turns green for real and D1 becomes the meaningful
#    assertion: a wrong implementation that ignores the verified pause and
#    blocks anyway would flip D1 to rc==2 and fail it.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-d');
    # MIGRATED (§4.8): D0's setup ("a real `pause --surface reporter` call
    # succeeds") no longer applies -- there is no --surface reporter record
    # left to write (D3/AC23: bp-runstate.pl is not read by either gate at
    # all). The fixture is now a synthetic armed-watcher /proc entry instead.
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    ok(-d $procdir, 'D0 (migrated): the fixture\'s synthetic armed-watcher /proc entry is built');

    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir,
                               probe_dir => $procdir, probe_self_pid => $self_pid);
    # MIGRATED (§4.8): D1 (declared live pause -> ALLOWED) becomes probe 0 ->
    # ALLOWED.
    is($rc, 0, 'D1 (migrated, -> AC1 reporter): the SAME registered session, with the probe '
             . 'forced to LIVE (0), is ALLOWED to stop');
}

# ===========================================================================
# E. AC3 continued -- staleness reversion, MIGRATED onto the probe: a watcher
# that is no longer live reproduces the refusal on the NEXT Stop.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-e');
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    my ($rc0) = run_gate(stop_payload($root, $sid), rdir => $rdir,
                          probe_dir => $procdir, probe_self_pid => $self_pid);
    is($rc0, 0, 'E0 (migrated): allowed while the probe says LIVE (same shape as D)');

    # MIGRATED (§4.8): E1 (watcher dead -> REFUSED again) becomes probe 1 ->
    # REFUSED again. No record to edit any more; simply re-probe with an
    # empty /proc fixture (the watcher gone).
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => proc_dir_none());
    is($rc, 2, 'E1 (migrated, -> AC2 reporter): once the probe says NONE (the watcher gone), '
             . 'the SAME session\'s next Stop is REFUSED again');
}

# ===========================================================================
# F. AC4 (-> DC3): the refusal names the REPORTER's own remedy, never the
#    driver's. Reusing B's exact refused fixture.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-f');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 2, 'F0 setup: refused, same shape as B');

    unlike($out, qr/bp-drive-next\.pl/,
       'F1 CANONICAL (-> AC4): the refusal text NEVER references bp-drive-next.pl -- that '
     . 'is a driver-only concept');
    unlike($out, qr/dispatch the worker/i,
       'F2: the refusal text does NOT tell a reporter to "dispatch the worker" -- the '
     . 'driver\'s own remedy verb, meaningless in a reporter\'s vocabulary');
    unlike($out, qr/consult the director/i,
       'F3: the refusal text does NOT tell a reporter to "consult the director" either');
    # MIGRATED (§4.8): F4/F5 ("the refusal gives the --surface reporter
    # pause/finish commands") -> "the refusal gives bp-watch.pl --arm and the
    # .run-finished path" (ledger: "THE REPORTER DENIAL TEXT IS THIS
    # PACKAGE'S"; Decision 13).
    like($out, qr/bp-watch\.pl --arm/,
       'F4 (migrated): the refusal DOES give the bp-watch.pl --arm remedy');
    like($out, qr/\.run-finished/,
       'F5 (migrated): the refusal DOES give the absolute .run-finished path');
    unlike($out, qr/bp-runstate\.pl/,
       'AC23 (reporter): the refusal never mentions bp-runstate.pl');
}

# ===========================================================================
# G. TTL reap (spec §3 behavior 6) — a marker older than the TTL is removed
#    on the next Stop and the session is treated as unregistered from then on.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-g');
    my $marker = "$rdir/$sid";
  SKIP: {
        skip 'no marker written (registration not yet built)', 2 unless -f $marker;
        # Age the marker file well past the 1-hour TTL used for this fixture.
        my $old = time() - (2 * 3600);
        utime($old, $old, $marker) or diag("utime failed: $!");
        my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, ttl_h => 1);
        is($rc, 0, 'G1 CANONICAL (spec §3 behavior 6): a marker older than '
                 . 'CCPRAXIS_REPORTER_TTL_H is treated as unregistered -- Stop is ALLOWED');
        ok(!-f $marker, 'G2: ...and the stale marker is REMOVED (TTL reap), mirroring the '
                       . 'driver\'s own marker reap discipline exactly');
    }
}

# ===========================================================================
# H. The escape hatches are INDEPENDENT of the driver's own. Silencing one
#    surface's hatch must never silence the other's (spec §3 behavior 8).
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h1');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, drive_stop_ok => 1);
    is($rc, 2, 'H1 CANONICAL: CCPRAXIS_DRIVE_STOP_OK=1 alone does NOT silence the reporter '
             . 'refusal -- the two escape hatches are independent env vars');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h2');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, reporter_stop_ok => 1);
    is($rc, 0, 'H2: CCPRAXIS_REPORTER_STOP_OK=1 DOES allow the stop -- H1'."'".'s block is '
             . 'attributable to using the wrong hatch, not to the reporter hatch being broken');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h3');
    open my $fh, '>', "$root/.ccpraxis-local-data/.reporter-stop-ok" or die $!;
    close $fh;
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 0, 'H3: the one-shot .reporter-stop-ok file allows the stop');
    ok(!-f "$root/.ccpraxis-local-data/.reporter-stop-ok",
       'H4: ...and is CONSUMED — an operator override applies once, never permanently');
}

# ===========================================================================
# I. AC7's second half: a Stop event for a session with NO
#    ${CCPRAXIS_REPORTER_ACTIVE_DIR} directory at all exits 0 having made NO
#    filesystem writes (a naive implementation that unconditionally creates
#    the directory is caught by the mtime/existence check, not merely by
#    the exit code).
#
#    NON-VACUITY NOTE: I1 passes vacuously pre-implementation (nothing blocks
#    anything yet). I2 is NOT vacuous even today: it already catches a wrong
#    implementation that unconditionally `mkdir -p`s the active-dir before
#    checking existence, regardless of whether the block logic itself has
#    landed.
# ===========================================================================
{
    my $root  = new_project();
    my $rdir  = tempdir(CLEANUP => 1);
    my $ghost = "$rdir/does-not-exist-yet";   # deliberately never created
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-i'), rdir => $ghost);
    is($rc, 0, 'I1: a Stop event with NO reporter-active directory at all is ALLOWED');
    ok(!-e $ghost,
       'I2 CANONICAL: ...and the directory is NOT created as a side effect -- a naive '
     . '"mkdir -p $RDIR" placed before the existence check would fail this specifically');
}

# =================== PACKAGE 02 — PROBE-BASED ACCEPTANCE CRITERIA ===========

# AC1/AC2/AC3 — the verdict mapping, reporter branch, all three forced outcomes.
{
    my ($root, $rdir, $sid) = registered_reporter('sess-ac1');
    my ($procdir, $self_pid) = proc_dir_live("$root/.ccpraxis-local-data");
    my ($rc) = run_gate(stop_payload($root, $sid), rdir => $rdir,
                         probe_dir => $procdir, probe_self_pid => $self_pid);
    is($rc, 0, 'AC1 (reporter): probe forced to LIVE (0) ALLOWS the stop');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-ac2');
    my ($rc) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => proc_dir_none());
    is($rc, 2, 'AC2 (reporter): probe forced to NONE (1) with no marker DENIES');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-ac3');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir,
                               probe_dir => proc_dir_cannot_tell());
    is($rc, 0, 'AC3 (reporter): probe forced to CANNOT-TELL (2) ALLOWS, asserted separately');
    like($out, qr/(?i:cannot.?tell|indeterminate|fail.?open)/,
        'AC3b (reporter): stderr names the verdict as indeterminate');
}

# AC7/AC8 — the finish marker ends a reporter run unconditionally and is
# consumed in the same step.
{
    my ($root, $rdir, $sid) = registered_reporter('sess-ac7');
    touch_finish_marker($root);
    my ($rc) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => proc_dir_none());
    is($rc, 0, 'AC7 (reporter): .run-finished ends the run regardless of the probe\'s answer');
    ok(!-f "$root/.ccpraxis-local-data/.drive-solo/.run-finished",
       'AC8 (reporter): ...and the marker no longer exists afterwards');
    ok(-f "$root/.ccpraxis-local-data/.drive-solo/.run-finished.consumed",
       'AC8b (reporter): ...and .run-finished.consumed now exists');
}

# AC19/AC20 — Decision 23's attempt suite, reporter surface.
{
    my ($root, $rdir, $sid) = registered_reporter('sess-ac19');
    my $probe_none = proc_dir_none();

    my ($rc_a) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => $probe_none);
    is($rc_a, 2, 'AC19 (reporter) precondition: registered, probe NONE, no marker -> DENIED');

    my $prc = pause_reporter($root, $$, time() + 600);
    my ($rc_b) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => proc_dir_none());
    is($rc_b, 2, 'AC19b (reporter): a `pause --surface reporter` call (even a granted one, or '
              . 'a no-op if --surface is gone) still DENIED -- no longer read at all');

    make_path("$root/.ccpraxis-local-data/.subagent-guard");
    open my $f1, '>', "$root/.ccpraxis-local-data/.subagent-guard/run-state.reporter.json" or die $!;
    print {$f1} '{"state":"finished"}';
    close $f1;
    my ($rc_c) = run_gate(stop_payload($root, $sid), rdir => $rdir, probe_dir => proc_dir_none());
    is($rc_c, 2, 'AC19c (reporter): a hand-written run-state.reporter.json claiming '
              . '"finished" still DENIED');

    ok(!-f "$root/.ccpraxis-local-data/.drive-solo/.run-finished",
       'AC19 (reporter): after the attempt suite, .run-finished still does not exist');

    touch_finish_marker($root);
    my ($rc_control) = run_gate(stop_payload($root, $sid), rdir => $rdir,
                                 probe_dir => proc_dir_none());
    is($rc_control, 0, 'AC20 (reporter): the operator\'s own touch, on the SAME fixture, IS '
                      . 'allowed');
}

done_testing();
