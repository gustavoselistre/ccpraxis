#!/usr/bin/env perl
# platform: windows
# 06-drive-solo-marker-retirement — a driver's stop discipline is not the
# problem this package fixes; ending a genuinely settled run IS.
#
# THE INCIDENT. Hours after the operator said stop, and after
# bp-drive-next.pl had itself returned `done`, this session's own driver
# marker (plugins/butler/hooks/lib.sh: bp_drive_active_dir /
# bp_drive_marker / bp_drive_any_active) was still present under the
# machine-level registry, so bp_drive_any_active stayed true and
# gate-drive-loop.sh treated every pending package in every OTHER
# blueprint as outstanding work. There was no verb to retire it early.
#
# THIS PACKAGE adds exactly one: bp_drive_retire(SID) in lib.sh, a
# session-triggered sentinel command observed by mark-wakeup.sh
# (bp_drive_retire_sentinel), the two existing TTL-shaped `rm -f "$MARK"`
# sites in gate-drive-loop.sh re-pointed at the shared primitive, and a
# SKILL.md doc update. Full contract: specs/06-drive-solo-marker-
# retirement-spec.md.
#
# NONE OF bp_drive_retire, bp_drive_retire_sentinel, mark-wakeup.sh's
# RETIRE block, or gate-drive-loop.sh's re-pointed deletion sites exist
# yet. Every assertion below must fail for THAT reason — missing
# function / missing behavior — never a fixture bug of this file's own
# making.
#
# Runs standalone: perl this file
# (`prove` does not exist on the Git-for-Windows host.) No container, no
# network, no launcher spawn; every fixture lives under File::Temp.

use strict;
use warnings;

# Same landmine drive-loop-gate.t documents: this file drives
# gate-drive-loop.sh / mark-wakeup.sh as real subprocesses, where
# bp-keepawake.pl's `$0 =~ /\.t\z/` guard cannot reach. CCPRAXIS_NO_WAKELOCK
# is the supported opt-out and IS inherited across exec.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);

my $HOOKS = "$Bin/../../hooks";
my $LIB   = "$HOOKS/lib.sh";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";
my $SKILL = "$Bin/../../skills/drive-solo/SKILL.md";

ok(-f $LIB,   'sanity: lib.sh exists');
ok(-f $MARK,  'sanity: mark-wakeup.sh exists');
ok(-f $GATE,  'sanity: gate-drive-loop.sh exists');
ok(-f $SKILL, 'sanity: drive-solo/SKILL.md exists');

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# run_lib SCRIPT, %opt(env=>{...}) -> (rc, stdout, stderr). Sources lib.sh
# for real (never reimplements bp_drive_active_dir/bp_drive_marker/
# bp_drive_any_active/bp_drive_retire/bp_drive_retire_sentinel), runs SCRIPT
# under the same set -u / nullglob trap the hooks themselves run under
# (lib.sh:1031-1036), and captures stdout/stderr SEPARATELY so AC4's
# "stdout AND stderr always empty" contract can be checked precisely.
sub run_lib {
    my ($script, %opt) = @_;
    my $envstr = '';
    for my $k (sort keys %{ $opt{env} || {} }) {
        my $v = $opt{env}{$k};
        $envstr .= "$k='$v' ";
    }
    my (undef, $efile) = tempfile();
    my $cmd = qq{${envstr}bash -c "set -u; shopt -s nullglob; source \\"$LIB\\"; $script" 2>"$efile"};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    open my $rfh, '<', $efile or die "read stderr capture: $!";
    local $/;
    my $err = <$rfh>;
    close $rfh;
    unlink $efile;
    $err = '' unless defined $err;
    return ($rc, $out, $err);
}

# run_hook SCRIPT, PAYLOAD, %opt(env=>{...}) -> (rc, combined stdout+stderr).
# Mirrors drive-loop-gate.t's run_hook: payload on stdin, env vars prefixed.
sub run_hook {
    my ($script, $payload, %opt) = @_;
    my $envstr = '';
    for my $k (sort keys %{ $opt{env} || {} }) {
        my $v = $opt{env}{$k};
        $envstr .= "$k='$v' ";
    }
    my $out = `$envstr bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

my $SID = 'sess-retire-under-test';

# new_registry(%opt) -> ($active_dir_absolute_tempdir). Optionally seeds
# marker files. CCPRAXIS_DRIVE_ACTIVE_DIR is the ONLY override seam per the
# spec's explicit prohibition on inventing a second one.
sub new_registry {
    my (%opt) = @_;
    my $dir = tempdir(CLEANUP => 1);
    for my $sid (@{ $opt{markers} || [] }) {
        open my $fh, '>', "$dir/$sid" or die "write marker $sid: $!";
        print {$fh} ($opt{content}{$sid} // "$dir/data\n");
        close $fh;
    }
    return $dir;
}

# new_project(%opt) -> ($root, $data_dir, $ds, $active_dir). A full
# drive-solo project tree PLUS a machine-level registry, marker pointing at
# this project's data dir, mirroring drive-loop-gate.t's fixture shape.
sub new_project {
    my (%opt) = @_;
    my $root  = tempdir(CLEANUP => 1);
    my $data  = "$root/.ccpraxis-local-data";
    my $ds    = "$data/.drive-solo";
    make_path($ds);
    if ($opt{order} // 1) {
        open my $fh, '>', "$ds/order.json" or die $!;
        print {$fh} '{"order":["x"],"recorded_at":1}';
        close $fh;
    }
    if ($opt{parks}) {
        open my $fh, '>', "$ds/parks.json" or die $!;
        print {$fh} '{"parks":[{"blueprint":"x","reason":"stale"}]}';
        close $fh;
    }
    my $active = tempdir(CLEANUP => 1);
    unless ($opt{unarmed}) {
        open my $m, '>', "$active/$SID" or die $!;
        print {$m} "$data\n";
        close $m;
    }
    return ($root, $data, $ds, $active);
}

sub slurp {
    my ($f) = @_;
    return undef unless -f $f;
    open my $fh, '<', $f or die "slurp $f: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub payload_bash {
    my ($cmd, %opt) = @_;
    my $sid = exists $opt{sid} ? $opt{sid} : $SID;
    my $sid_json = defined $sid ? qq("session_id":"$sid",) : '';
    my $cwd = $opt{cwd} // '/tmp';
    return qq({${sid_json}"cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"$cmd"}});
}

sub payload_stop {
    my ($cwd, $sid) = @_;
    $sid //= $SID;
    return qq({"session_id":"$sid","cwd":"$cwd"});
}

# The canonical sentinel text, per spec §3.2 — deliberately DUPLICATED here
# (not read from bp_drive_retire_sentinel, which does not exist yet) so this
# file has an independent oracle for what the implementation must produce.
my $SENTINEL = 'echo butler-drive-solo-retire';

# ===========================================================================
# AC1 (B1) — retire removes exactly one marker; sibling untouched; registry
# dir survives.
# ===========================================================================
{
    my $active = new_registry(markers => ['SID_A', 'SID_B']);
    my $sib_before = slurp("$active/SID_B");

    my ($rc, $out, $err) = run_lib(
        q{bp_drive_retire SID_A},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC1: bp_drive_retire SID_A returns rc 0');
    ok(!-e "$active/SID_A", 'AC1: SID_A marker is gone');
    ok(-f "$active/SID_B", 'AC1: SID_B marker still exists (sibling untouched)');
    is(slurp("$active/SID_B"), $sib_before, 'AC1: SID_B content is byte-unchanged');
    ok(-d $active, 'AC1: the registry directory itself still exists');
}

# ===========================================================================
# AC2 (B2) — idempotent: absent marker -> rc 0, nothing created; two calls
# in a row on a real marker -> rc 0 both times, and no directory is
# fabricated when the registry itself does not pre-exist.
# ===========================================================================
{
    my $active = new_registry();
    my ($rc) = run_lib(
        q{bp_drive_retire SID_C},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC2: bp_drive_retire on an absent marker returns rc 0');
    ok(!-e "$active/SID_C", 'AC2: no file was created for the absent marker');

    my $active2 = new_registry(markers => ['SID_D']);
    my ($rc1) = run_lib(
        q{bp_drive_retire SID_D},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active2 },
    );
    is($rc1, 0, 'AC2: first retire call on a real marker returns rc 0');
    my ($rc2) = run_lib(
        q{bp_drive_retire SID_D},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active2 },
    );
    is($rc2, 0, 'AC2: second retire call (marker already gone) also returns rc 0');
    ok(!-e "$active2/SID_D", 'AC2: marker stays gone after the second call');
}

# ===========================================================================
# AC3 (B3) — malformed session ids and an unresolvable registry refuse,
# rc 1, and remove/create nothing.
# ===========================================================================
{
    my $active = new_registry(markers => ['a-real-sid']);
    for my $case (
        ['empty string'      => ''],
        ['contains /'        => 'a/b'],
        ['path traversal'    => '../../etc/passwd'],
        ['bare ..'           => '..'],
    ) {
        my ($label, $sid) = @$case;
        my $q = $sid;
        $q =~ s/'/'\\''/g;
        my ($rc) = run_lib(
            qq{bp_drive_retire '$q'},
            env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
        );
        is($rc, 1, "AC3: bp_drive_retire rejects malformed session id ($label) with rc 1");
    }
    ok(-f "$active/a-real-sid", 'AC3: an unrelated real marker survives every malformed-id call');

    # unresolvable registry: a RELATIVE CCPRAXIS_DRIVE_ACTIVE_DIR is refused
    # by bp_drive_active_dir itself (lib.sh:876-880).
    my ($rc2) = run_lib(
        q{bp_drive_retire real-sid},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => 'relative/not/absolute' },
    );
    is($rc2, 1, 'AC3: an unresolvable (relative) registry path yields rc 1');
}

# ===========================================================================
# AC4 (B1-B3) — bp_drive_retire writes NOTHING to stdout or stderr, on
# success, on the idempotent/absent path, or on any refusal path.
# ===========================================================================
{
    my $active = new_registry(markers => ['SID_E']);
    my ($rc, $out, $err) = run_lib(
        q{bp_drive_retire SID_E},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($out, '', 'AC4: success path — stdout is empty');
    is($err, '', 'AC4: success path — stderr is empty');

    my (undef, $out2, $err2) = run_lib(
        q{bp_drive_retire SID_NEVER_EXISTED},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($out2, '', 'AC4: absent-marker path — stdout is empty');
    is($err2, '', 'AC4: absent-marker path — stderr is empty');

    my (undef, $out3, $err3) = run_lib(
        q{bp_drive_retire '../../etc/passwd'},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($out3, '', 'AC4: refusal path — stdout is empty');
    is($err3, '', 'AC4: refusal path — stderr is empty');
}

# ===========================================================================
# AC5 (B8) — REVISED, DRIVER AMENDMENT (2026-09-23), CRITICAL-1 (S9.1).
# bp_drive_retire RENAMES, never removes. The canonical path (bp_drive_marker)
# is gone afterwards, but the content survives at "<canonical>.retired" in
# the SAME directory -- so bp_drive_any_active's own unmodified reap loop
# keeps counting it exactly as before, and the machine-wide liveness signal
# it reports does NOT change the instant one session retires. Marker is
# FRESHLY created so no TTL could be doing the work either before or after.
# ===========================================================================
{
    my $active = new_registry(markers => ['SID_LIVE']);
    my ($rc_before) = run_lib(
        q{bp_drive_any_active},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_before, 0,
       'AC5: bp_drive_any_active reports ACTIVE (rc 0) before retirement, with a fresh marker');

    my $before_content = slurp("$active/SID_LIVE");

    my ($rc_retire) = run_lib(
        q{bp_drive_retire SID_LIVE},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_retire, 0, 'AC5: bp_drive_retire SID_LIVE itself returns rc 0');

    ok(!-e "$active/SID_LIVE", 'AC5: the canonical marker path is gone after retirement');
    ok(-f "$active/SID_LIVE.retired",
       'AC5: ...and a ".retired" sibling now exists in the SAME directory');
    is(slurp("$active/SID_LIVE.retired"), $before_content,
       'AC5: ...with byte-identical content to the pre-retirement marker');

    my ($rc_after) = run_lib(
        q{bp_drive_any_active},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_after, 0,
       'AC5 (REVISED): the REAL bp_drive_any_active STILL reports rc 0 immediately after '
     . 'retirement -- unchanged from before retirement, sourced from lib.sh, called directly, '
     . 'never reimplemented -- retirement alone never flips the aggregate liveness signal '
     . '(CRITICAL-1)');

    # Also confirm through bp_drive_marker directly (the CANONICAL path it
    # resolves to is gone, even though the renamed-aside sibling remains).
    my ($rc_m, $marker_path) = run_lib(
        q{bp_drive_marker SID_LIVE},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_m, 0, 'AC5: bp_drive_marker itself still resolves a path (id remains well-formed)');
    chomp $marker_path;
    ok(!-e $marker_path, 'AC5: ...and that resolved CANONICAL path no longer exists on disk');
}

# ===========================================================================
# AC15 (B14) — NEW, DRIVER AMENDMENT (2026-09-23), the actual CRITICAL-1
# regression test: a SECOND session is completely unaffected by another
# session's retirement, both through bp_drive_any_active directly and
# through gate-drive-loop.sh's own Stop evaluation for that other session.
# ===========================================================================
{
    my $active = new_registry(markers => ['SID_A', 'SID_B']);

    my ($rc_a) = run_lib(
        q{bp_drive_retire SID_A},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_a, 0, 'AC15: bp_drive_retire SID_A returns rc 0');
    ok(!-e "$active/SID_A", 'AC15: SID_A canonical marker is gone');
    ok(-f "$active/SID_B", 'AC15: SID_B marker untouched, still at its canonical path');

    my ($rc_active_after) = run_lib(
        q{bp_drive_any_active},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_active_after, 0,
       'AC15: bp_drive_any_active still reports rc 0 (SID_B alone keeps it active) -- '
     . 'unaffected by SID_A\'s retirement');

    # Control run: SID_B's own gate-drive-loop.sh Stop evaluation, in a
    # project where SID_A was NEVER retired, for comparison.
    my ($root_ctrl, undef, undef) = new_project(order => 1);
    my $ctrl_active = new_registry(markers => ['SID_B']);
    open my $cm, '>', "$ctrl_active/SID_B" or die $!;
    print {$cm} "$root_ctrl/.ccpraxis-local-data\n";
    close $cm;
    my ($rc_ctrl, $out_ctrl) = run_hook(
        $GATE, payload_stop($root_ctrl, 'SID_B'),
        env => {
            CCPRAXIS_DRIVE_ACTIVE_DIR => $ctrl_active,
            BP_PROBE_PROC_DIR         => tempdir(CLEANUP => 1),
        },
    );

    # Actual run: same shape, but SID_A's marker was retired in the shared
    # $active registry above before this Stop for SID_B is evaluated.
    my ($root_real, undef, undef) = new_project(order => 1);
    open my $rm, '>', "$active/SID_B" or die $!;
    print {$rm} "$root_real/.ccpraxis-local-data\n";
    close $rm;
    my ($rc_real, $out_real) = run_hook(
        $GATE, payload_stop($root_real, 'SID_B'),
        env => {
            CCPRAXIS_DRIVE_ACTIVE_DIR => $active,
            BP_PROBE_PROC_DIR         => tempdir(CLEANUP => 1),
        },
    );

    is($rc_real, $rc_ctrl,
       'AC15: gate-drive-loop.sh Stop exit code for SID_B is IDENTICAL whether or not '
     . 'SID_A was retired first');
    is((($out_real // '') =~ qr/BLOCKED/) ? 1 : 0,
       (($out_ctrl // '') =~ qr/BLOCKED/) ? 1 : 0,
       'AC15: ...and the presence/absence of a BLOCKED line for SID_B is IDENTICAL too '
     . '-- retiring SID_A changes nothing observable about SID_B (closes CRITICAL-1)');
}

# ===========================================================================
# AC16 (B15) — NEW, DRIVER AMENDMENT (2026-09-23): a retired marker still
# reaps normally once genuinely TTL-stale, through bp_drive_any_active's own
# UNMODIFIED reap loop -- proving the renamed-aside sibling is not special-
# cased or permanently immortal.
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project(order => 1);

    my ($rc_retire) = run_lib(
        qq{bp_drive_retire '$SID'},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_retire, 0, 'AC16: bp_drive_retire returns rc 0');
    ok(-f "$active/$SID.retired", 'AC16: the renamed-aside sibling exists');

    # Age the retired sibling past CCPRAXIS_DRIVE_TTL_H -- same TTL shape
    # AC12/B11 already exercises for a non-retired marker.
    my $old = time() - (13 * 3600);
    utime($old, $old, "$active/$SID.retired") or die "utime: $!";

    my ($rc_active) = run_lib(
        q{bp_drive_any_active},
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_active, 1,
       'AC16: bp_drive_any_active reports rc 1 -- the retired-and-now-TTL-stale sibling reaps '
     . 'identically to a non-retired stale marker, via the same unmodified reap loop');
    ok(!-e "$active/$SID.retired", 'AC16: ...and the reap loop removed the stale sibling');
}

# ===========================================================================
# AC6 (B4, B7) — mark-wakeup.sh, driven as a subprocess with a Bash payload
# whose command is EXACTLY the sentinel, exits 0, removes that session's
# marker, and prints the exact stderr message. B7: surrounding whitespace
# (space/tab/CR/LF) is tolerated.
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project();
    ok(-f "$active/$SID", 'AC6 precondition: marker exists before the sentinel fires');

    my ($rc, $out) = run_hook(
        $MARK, payload_bash($SENTINEL),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC6: mark-wakeup.sh exits 0 on the exact sentinel command');
    ok(!-e "$active/$SID", 'AC6: this session\'s marker is gone after the sentinel fires');
    like($out, qr/butler drive-solo: driver marker retired/,
         'AC6: stderr contains the documented retirement message');
}
{
    # B7: whitespace-padded sentinel (space, tab, CR, LF) retires exactly
    # as the bare form does. DRIVER AMENDMENT S9.2 (MEDIUM-3): the padding is
    # built with proper JSON string escapes (\t, \r, \n as literal two-byte
    # backslash sequences), not a raw, JSON-invalid control byte -- no real
    # Claude Code payload emits a raw control byte inside a JSON string, so a
    # fixture that did was exercising a shape this hook never actually sees.
    my ($root, $data, $ds, $active) = new_project();
    my $padded = '  \t' . $SENTINEL . '\r\n';
    my ($rc) = run_hook(
        $MARK, payload_bash($padded),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC6/B7: mark-wakeup.sh exits 0 on a whitespace-padded sentinel');
    ok(!-e "$active/$SID", 'AC6/B7: the marker is retired despite surrounding whitespace');
}
{
    # DRIVER AMENDMENT S9.2 (MEDIUM-3 regression guard): a pretty-printed,
    # valid, multi-line JSON payload carrying the sentinel must still retire.
    # This pins that the RETIRE block parses $PAYLOAD with the SAME
    # bp_json_get grammar the rest of the file uses (whitespace-tolerant,
    # real JSON), not a divergent hand-rolled parser -- so a future "fix"
    # cannot reintroduce the deleted sanitizing re-parse.
    my ($root, $data, $ds, $active) = new_project();
    my $pretty = qq({\n  "session_id": "$SID",\n  "cwd": "$root",\n)
               . qq(  "tool_name": "Bash",\n  "tool_input": {\n)
               . qq(    "command": "$SENTINEL"\n  }\n});
    my ($rc) = run_hook(
        $MARK, $pretty,
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'MEDIUM-3 regression: mark-wakeup.sh exits 0 on a pretty-printed JSON payload');
    ok(!-e "$active/$SID",
       'MEDIUM-3 regression: the marker is retired despite pretty-printing/multi-line JSON');
}
{
    # AC6/AC9 non-vacuity pairing: retiring a session must never touch a
    # SIBLING session's marker.
    my $active = new_registry(markers => ['other-session']);
    my ($root, $data, $ds) = new_project(); # unused root, just for .drive-solo shape
    open my $m, '>', "$active/$SID" or die $!;
    print {$m} "$data\n";
    close $m;
    run_hook($MARK, payload_bash($SENTINEL), env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active });
    ok(-f "$active/other-session",
       'AC6: retiring SID never touches a sibling session\'s marker');
}

# ===========================================================================
# AC7 (B6) — every near-miss leaves the marker INTACT and exits 0. Six
# distinct shapes, each independently asserted, sitting in the SAME file as
# AC6/AC9's positive assertions (non-vacuity requirement, spec §5).
# ===========================================================================
{
    my @cases = (
        ['substring inside a grep'   => qq(grep -r butler-drive-solo-retire plugins/)],
        ['sentinel plus more'        => qq($SENTINEL && ls)],
        ['commented out'             => qq(# $SENTINEL)],
        ['wrong case'                => qq(echo BUTLER-DRIVE-SOLO-RETIRE)],
        ['unrelated command'         => qq(git status)],
    );
    for my $case (@cases) {
        my ($label, $cmd) = @$case;
        my ($root, $data, $ds, $active) = new_project();
        ok(-f "$active/$SID", "AC7 precondition ($label): marker exists");
        my ($rc) = run_hook(
            $MARK, payload_bash($cmd),
            env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
        );
        is($rc, 0, "AC7 ($label): mark-wakeup.sh still exits 0");
        ok(-f "$active/$SID", "AC7 ($label): the marker is left INTACT (near-miss must NOT retire)");
    }

    # Sixth near-miss: tool_name is Task, not Bash, carrying the sentinel
    # text somewhere in the payload.
    my ($root, $data, $ds, $active) = new_project();
    my $payload = qq({"session_id":"$SID","cwd":"$root","tool_name":"Task",)
                . qq("tool_input":{"description":"$SENTINEL"}});
    my ($rc) = run_hook($MARK, $payload, env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active });
    is($rc, 0, 'AC7 (Task tool_name carrying the sentinel text): exits 0');
    ok(-f "$active/$SID",
       'AC7 (Task tool_name carrying the sentinel text): marker left INTACT '
     . '-- only tool_name Bash can trigger retirement');
}

# ===========================================================================
# AC8 (B5) — degraded inputs never kill the hook.
# ===========================================================================
{
    # missing session_id -> exit 0, silent, nothing removed.
    my ($root, $data, $ds, $active) = new_project();
    my $payload = qq({"cwd":"$root","tool_name":"Bash","tool_input":{"command":"$SENTINEL"}});
    my ($rc, $out) = run_hook($MARK, $payload, env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active });
    is($rc, 0, 'AC8: sentinel with MISSING session_id exits 0');
    ok(-f "$active/$SID", 'AC8: ...and this session\'s own marker is untouched');
    is($out, '', 'AC8: ...and no stderr message is printed for a missing session_id');
}
{
    # empty session_id -> exit 0, silent, nothing removed.
    my ($root, $data, $ds, $active) = new_project();
    my ($rc, $out) = run_hook(
        $MARK, payload_bash($SENTINEL, sid => ''),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC8: sentinel with EMPTY session_id exits 0');
    ok(-f "$active/$SID", 'AC8: ...and this session\'s own marker is untouched');
    is($out, '', 'AC8: ...and no stderr message is printed for an empty session_id');
}
{
    # malformed session_id -> exit 0, silent, nothing removed.
    my ($root, $data, $ds, $active) = new_project();
    my ($rc, $out) = run_hook(
        $MARK, payload_bash($SENTINEL, sid => 'a/b'),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC8: sentinel with MALFORMED session_id (a/b) exits 0');
    ok(-f "$active/$SID", 'AC8: ...and this session\'s own marker is untouched');
    is($out, '', 'AC8: ...and no stderr message is printed for a malformed session_id');
}
{
    # unresolvable registry (HOME and USERPROFILE both unset, no override)
    # with a VALID session id -> exit 0, explicit stderr, no session id
    # echoed into it.
    my ($root, $data, $ds) = new_project();
    my $out = `env -u HOME -u USERPROFILE -u CCPRAXIS_DRIVE_ACTIVE_DIR bash "$MARK" <<'PAYLOAD_EOF' 2>&1
{"session_id":"$SID","cwd":"$root","tool_name":"Bash","tool_input":{"command":"$SENTINEL"}}
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC8: sentinel with an UNRESOLVABLE registry (no HOME/USERPROFILE/override) exits 0');
    like($out, qr/registry path unresolved/,
         'AC8: ...and stderr says "registry path unresolved"');
    like($out, qr/NOT retired/, 'AC8: ...and stderr says "NOT retired"');
    unlike($out, qr/\Q$SID\E/, 'AC8: ...and no session id is echoed into that message');
}

# ===========================================================================
# AC9 (B9) — the operator-stops-early shape retires through the SAME
# mark-wakeup.sh sentinel path and the SAME bp_drive_retire function as
# AC6, proven by identical post-state, then a subsequent gate-drive-loop.sh
# Stop for the same session exits 0 with no BLOCKED line. Fixture: order
# recorded, fresh marker, NO .run-finished, NO .run-finished.consumed,
# nothing representing a director `done`.
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project(order => 1);
    ok(-f "$ds/order.json", 'AC9 precondition: order.json is present (a run is in progress)');
    ok(!-e "$ds/.run-finished", 'AC9 precondition: no .run-finished exists');
    ok(!-e "$ds/.run-finished.consumed", 'AC9 precondition: no .run-finished.consumed exists');
    ok(-f "$active/$SID", 'AC9 precondition: a fresh marker exists for this session');

    my ($rc_retire, $retire_out) = run_hook(
        $MARK, payload_bash($SENTINEL),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc_retire, 0, 'AC9: mark-wakeup.sh exits 0 on the sentinel (same code path as AC6)');
    ok(!-e "$active/$SID", 'AC9: the marker is gone -- IDENTICAL post-state to AC6');
    like($retire_out, qr/butler drive-solo: driver marker retired/,
         'AC9: IDENTICAL stderr message to AC6 -- same function, same caller');

    # A subsequent Stop for the SAME session, with no watcher armed, must now
    # exit 0 (the marker is gone, so gate-drive-loop.sh's bp_drive_any_active
    # pre-check / MARK lookup falls through to "not driving").
    my ($rc_gate, $gate_out) = run_hook(
        $GATE, payload_stop($root),
        env => {
            CCPRAXIS_DRIVE_ACTIVE_DIR => $active,
            BP_PROBE_PROC_DIR         => tempdir(CLEANUP => 1),
        },
    );
    is($rc_gate, 0, 'AC9: a subsequent Stop for the retired session exits 0');
    unlike($gate_out, qr/BLOCKED/, 'AC9: ...and prints no BLOCKED line');
}

# ===========================================================================
# AC10 (B10) — the .run-finished branch keeps its D-E restraint: exit 0,
# stderr mentions the operator's .run-finished marker, and the driver
# marker for SID STILL EXISTS afterwards (regression guard).
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project(order => 1);
    open my $fh, '>', "$ds/.run-finished" or die $!;
    close $fh;
    ok(!-e "$ds/.stop-ok", 'AC10 precondition: no .stop-ok');
    ok(!-e "$ds/.wakeup-pending", 'AC10 precondition: no .wakeup-pending');
    ok(-f "$active/$SID", 'AC10 precondition: fresh marker exists');

    my ($rc, $out) = run_hook(
        $GATE, payload_stop($root),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC10: .run-finished allows the stop');
    like($out, qr/\.run-finished/, 'AC10: stderr mentions the operator\'s .run-finished marker');
    ok(-f "$active/$SID",
       'AC10: the driver marker for SID STILL EXISTS afterwards -- the AC9/package-02 '
     . 'restraint at gate-drive-loop.sh:479-490 is preserved, not accidentally regressed');
}

# ===========================================================================
# AC11 — source-level guard on gate-drive-loop.sh.
# ===========================================================================
{
    my $src = slurp($GATE);
    ok(defined $src && length $src, 'AC11 precondition: gate-drive-loop.sh source is readable');

    # Blank full-line comments before scanning for an actual INVOCATION --
    # the file's own prose (documenting Decision 23's removal) mentions the
    # string "bp-drive-next" in comments, and a naive full-text search would
    # be punished for that documentation. Same technique drive-loop-gate.t's
    # G8 uses.
    my $code_only = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
    unlike($code_only, qr/bp-drive-next/,
           'AC11: gate-drive-loop.sh contains NO CODE invocation of bp-drive-next '
         . '(Decision 23\'s door stays closed) -- comment-only mentions documenting '
         . 'its removal are not invocations');

    my ($finish_branch) = $src =~ /if\s+_bp_finish_signal\s*"\$DS"\s*;\s*then(.*?)\nfi/s;
    $finish_branch = '' unless defined $finish_branch;
    unlike($finish_branch, qr/bp_drive_retire/,
           'AC11: no bp_drive_retire call inside the _bp_finish_signal branch (D-E untouched)');

    my $rm_mark_count = () = $src =~ /rm -f "\$MARK"/g;
    is($rm_mark_count, 0,
       'AC11: the literal string  rm -f "$MARK"  no longer appears ANYWHERE in the file '
     . '-- both TTL sites now call bp_drive_retire instead');

    my $retire_call_count = () = $src =~ /\bbp_drive_retire\b/g;
    is($retire_call_count, 2,
       'AC11: bp_drive_retire is called from exactly the two TTL/stale-data sites '
     . '(gate-drive-loop.sh:355 and :362 as originally numbered)');
}

# ===========================================================================
# AC12 (B11) — the TTL reap still reaps, now through the shared primitive.
# Same observable result as before this package (regression guard).
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project(order => 1);
    # Age the marker past CCPRAXIS_DRIVE_TTL_H.
    my $old = time() - (13 * 3600);
    utime($old, $old, "$active/$SID") or die "utime: $!";

    my ($rc, $out) = run_hook(
        $GATE, payload_stop($root),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active },
    );
    is($rc, 0, 'AC12: a Stop for a session whose marker is past the TTL is allowed');
    ok(!-e "$active/$SID", 'AC12: ...and the over-TTL marker is gone (reaped)');
    unlike($out, qr/BLOCKED/, 'AC12: ...and no BLOCKED line is printed');
}

# ===========================================================================
# AC13 (B12) — director state (.ccpraxis-local-data/.drive-solo/'s own
# order.json / parks.json) is untouched by retirement: byte-identical
# before/after, directory listing unchanged.
# ===========================================================================
{
    my ($root, $data, $ds, $active) = new_project(order => 1, parks => 1);
    my $order_before = slurp("$ds/order.json");
    my $parks_before = slurp("$ds/parks.json");
    opendir(my $dh, $ds) or die $!;
    my @listing_before = sort grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;

    run_hook($MARK, payload_bash($SENTINEL), env => { CCPRAXIS_DRIVE_ACTIVE_DIR => $active });

    is(slurp("$ds/order.json"), $order_before, 'AC13: order.json is byte-identical after retirement');
    is(slurp("$ds/parks.json"), $parks_before, 'AC13: parks.json is byte-identical after retirement');
    opendir(my $dh2, $ds) or die $!;
    my @listing_after = sort grep { !/^\.\.?$/ } readdir($dh2);
    closedir $dh2;
    is_deeply(\@listing_after, \@listing_before,
              'AC13: the .drive-solo/ directory listing is unchanged -- nothing added, '
            . 'nothing removed');
}

# ===========================================================================
# AC14 (B13) — bp_drive_retire_sentinel's output is the documented, matched
# sentinel; SKILL.md carries it verbatim; the done row mentions retirement;
# the existing "no verb that ends a run" doctrine is still present
# (regression guard).
# ===========================================================================
{
    my ($rc, $out, $err) = run_lib(q{bp_drive_retire_sentinel});
    is($rc, 0, 'AC14: bp_drive_retire_sentinel returns rc 0');
    is($out, $SENTINEL, 'AC14: bp_drive_retire_sentinel prints the exact sentinel, no trailing newline');
    is($err, '', 'AC14: bp_drive_retire_sentinel writes nothing to stderr');

    my $skill = slurp($SKILL);
    ok(defined $skill && length $skill, 'AC14 precondition: SKILL.md is readable');
    like($skill, qr/\Q$SENTINEL\E/,
         'AC14: the exact sentinel string appears verbatim in drive-solo/SKILL.md');

    my ($done_row) = $skill =~ /(\|\s*`done`\s*\|.*?\|.*?\n)/;
    $done_row = '' unless defined $done_row;
    like($done_row, qr/retir/i, 'AC14: the `done` row mentions retirement');

    like($skill, qr/There is no verb that ends a run/,
         'AC14: SKILL.md still contains the existing "There is no verb that ends a run" '
       . 'statement (regression guard -- this package must not contradict or remove it)');
}

done_testing();
