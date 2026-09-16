#!/usr/bin/env perl
# platform: windows
# 149 -- g01-explicit-continuity-arming, THE TOGGLE SURFACE:
# `bp-continuity.pl arm|disarm|status`.
#
# Spec: specs/g01-explicit-continuity-arming-spec.md SS2.1/SS2.2 (CLI contract),
# SS3 behaviors 1-8, SS4 AC-1..AC-4, AC-8. Written BLIND to
# plugins/butler/scripts/bp-continuity.pl (does not exist yet) and to
# plugins/butler/hooks/gate-continuity.sh/lib.sh's continuity additions --
# every expectation below is transcribed from the spec's literal CLI contract
# table (SS2.2), not inferred from any implementation.
#
# NEVER points at real state: CCPRAXIS_CONTINUITY_ACTIVE_DIR is always a
# File::Temp tempdir in every fixture in this file; nothing here ever reads
# or writes $HOME/.claude/ccpraxis/.continuity-active.
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
use Cwd ();

my $SCRIPT = "$Bin/../../scripts/bp-continuity.pl";

ok(-f $SCRIPT, 'A1: bp-continuity.pl exists') or BAIL_OUT('script missing -- nothing else here can run');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_cli(\@args, \%env_extra) -> ($stdout, $rc)
# Every call scopes CCPRAXIS_CONTINUITY_ACTIVE_DIR to a fresh tempdir unless
# the caller supplies one explicitly via env_extra, so no fixture can ever
# collide with another, or with real state. A value of undef in %env_extra
# means "truly UNSET this var for the child", done via local %ENV + delete
# rather than `VAR=` on a shell command line -- an empty string is a defined,
# zero-length value and is NOT the same thing as an absent env var to a perl
# script reading $ENV{...}, and this suite must distinguish them precisely
# (see section E: "neither --session nor $CLAUDE_SESSION_ID present").
sub run_cli {
    my ($args, $env_extra) = @_;
    $env_extra //= {};
    local %ENV = %ENV;
    for my $k (sort keys %$env_extra) {
        my $v = $env_extra->{$k};
        if (!defined $v) { delete $ENV{$k} }
        else              { $ENV{$k} = $v }
    }
    my $argstr = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @$args;
    my $out = `perl "$SCRIPT" $argstr 2>&1`;
    my $rc = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}

sub new_registry { return tempdir(CLEANUP => 1); }

sub kv {
    my ($out, $key) = @_;
    return $1 if $out =~ /^\Q$key\E:\s*(.*)$/m;
    return undef;
}

sub marker_path { my ($reg, $sid) = @_; return "$reg/$sid"; }

# ===========================================================================
# B. AC-1: arm --session S --by agent (no BP_LEDGER) creates <registry>/S with
#    mtime ~ now, exits 0, STATUS: armed.
# ===========================================================================
{
    my $reg = new_registry();
    my $before = time();
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'sess-b', '--by', 'agent'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef },
    );
    my $after = time();
    is($rc, 0, 'B1 CANONICAL (-> AC-1): arm --by agent, no BP_LEDGER, exits 0');
    is(kv($out, 'STATUS'), 'armed', 'B2: STATUS: armed on stdout');
    is(kv($out, 'SESSION'), 'sess-b', 'B3: SESSION: sess-b echoed back');
    ok(-f marker_path($reg, 'sess-b'),
       'B4 CANONICAL: a marker file <registry>/sess-b was actually created on disk');
    my @st = stat(marker_path($reg, 'sess-b'));
    ok(@st, 'B5 setup: marker is stat-able');
    my $mtime = $st[9];
    ok($mtime >= $before - 2 && $mtime <= $after + 2,
       'B6 CANONICAL (-> AC-1): marker mtime is approximately now, not some fixed/stale value');
}

# ===========================================================================
# C. AC-2: arm --by operator behaves identically except ARMED_BY: operator in
#    BOTH the arm output and status's output -- same mechanism, only --by
#    differs.
# ===========================================================================
{
    my $reg = new_registry();
    my ($aout, $arc) = run_cli(
        ['arm', '--session', 'sess-c', '--by', 'operator'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef },
    );
    is($arc, 0, 'C1: arm --by operator exits 0');
    is(kv($aout, 'STATUS'), 'armed', 'C2: STATUS: armed');
    is(kv($aout, 'ARMED_BY'), 'operator',
       'C3 CANONICAL (-> AC-2): ARMED_BY: operator on the arm call itself');

    my ($sout, $src) = run_cli(
        ['status', '--session', 'sess-c'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg },
    );
    is($src, 0, 'C4: status exits 0 for an armed session');
    is(kv($sout, 'STATUS'), 'armed', 'C5: status reports STATUS: armed');
    is(kv($sout, 'ARMED_BY'), 'operator',
       'C6 CANONICAL (-> AC-2): status ALSO reports ARMED_BY: operator -- the same fact, read '
     . 'back from the marker, not merely echoed by the arm call that wrote it');
    ok(defined(kv($sout, 'SINCE')) && length(kv($sout, 'SINCE')),
       'C7: status includes a non-empty SINCE field when armed (spec SS2.2/AC-7)');
}

# ===========================================================================
# D. AC-3: arm with BP_LEDGER set exits 1, STATUS: error, and writes NO marker
#    -- the coordinator refusal is enforced, not merely documented.
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'sess-d'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => '/fake/ledger/path.md' },
    );
    is($rc, 1, 'D1 CANONICAL (-> AC-3): arm with BP_LEDGER set exits 1');
    is(kv($out, 'STATUS'), 'error', 'D2: STATUS: error');
    ok(!-f marker_path($reg, 'sess-d'),
       'D3 CANONICAL (-> AC-3): NO marker file was written for the refused arm -- a coordinator '
     . 'is refused at the source, not merely told so while still being armed');
}

# ===========================================================================
# E/F/G REPLACED (2026-09-10). All three pinned the same premise -- that `arm`
# RESOLVES a session id from --session or the environment -- and that premise is
# what failed in the field. A Bash tool call is never told which session Claude
# Code considers live: ${CLAUDE_SESSION_ID} is a template substitution baked
# into a skill body at render time (not an env var; the old
# $ENV{CLAUDE_SESSION_ID} fallback these blocks tested could never fire), while
# the gate consuming the marker uses the session_id from its own hook payload
# and exits SILENTLY when the two disagree. An operator armed, was told
# "armed", and was never gated.
#
# So `arm` no longer resolves anything. It writes a TICKET carrying a nonce and
# prints the nonce, which lands in the arming session's transcript; the Stop
# hook -- which IS handed the live id -- binds the ticket to the session whose
# transcript actually carries that nonce. See t/184 for the binding itself.
# What survives here is the direct `--session` path, which is what the gate's
# own claim step and manual repair use.
#
# E. no --session: a TICKET is written and NOTHING is armed yet.
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(
        ['arm'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef,
          CLAUDE_SESSION_ID => undef, CLAUDE_CODE_SESSION_ID => undef },
    );
    is($rc, 0, 'E1 (was AC-4/behavior 4): arm with no id is the NORMAL path now, not an error');
    is(kv($out, 'STATUS'), 'arming', 'E2: STATUS: arming -- not yet bound to a session');
    like(kv($out, 'NONCE') // '', qr/\Accpx-sess-/,
         'E3: it prints a nonce, which is how the session that ran it is identified later');
    ok(-d "$reg/pending", 'E4: a pending ticket directory exists');
    opendir(my $ph, "$reg/pending") or die $!;
    my @tickets = grep { !/^\.\.?$/ } readdir $ph;
    closedir $ph;
    is(scalar(@tickets), 1, 'E5: exactly one ticket was written');
    is($tickets[0], kv($out, 'NONCE'), 'E6: named by the nonce it printed');

    opendir(my $dh, $reg) or die $!;
    my @markers = grep { !/^\.\.?$/ && $_ ne 'pending' && $_ ne 'beacons' } readdir $dh;
    closedir $dh;
    is(scalar(@markers), 0,
       'E7 CANONICAL: NO marker exists under any name -- arming a guessed id is exactly '
     . 'what produced "armed, enforcing nothing", so nothing is armed until the gate '
     . 'confirms which session this is');
}

# ===========================================================================
# F. an env session id is NOT a source of identity any more. It may key a
#    beacon (a stable process-scoped handle for status/disarm to resolve
#    through), but it can never by itself decide what gets armed.
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(
        ['arm'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef,
          CLAUDE_SESSION_ID => q{sess-f-envsid},
          CLAUDE_CODE_SESSION_ID => q{sess-f-code-envsid} },
    );
    is($rc, 0, 'F1: arm still succeeds with env ids present');
    is(kv($out, 'STATUS'), 'arming', 'F2: and still only ARMS NOTHING YET');
    ok(!-f marker_path($reg, 'sess-f-envsid'),
       'F3 CANONICAL: no marker under $CLAUDE_SESSION_ID -- it is a template token, '
     . 'not an identity');
    ok(!-f marker_path($reg, 'sess-f-code-envsid'),
       'F4 CANONICAL: nor under $CLAUDE_CODE_SESSION_ID -- one unverified process value '
     . 'is not evidence of which session is live either');
}

# ===========================================================================
# G. --session is the DIRECT path: it arms exactly that id, immediately, and
#    touches nothing else. This is what the gate's claim step and hand repair
#    use, and it is the only way to arm without a turn boundary.
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'sess-g-explicit'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef,
          CLAUDE_SESSION_ID => q{sess-g-env-should-be-ignored},
          CLAUDE_CODE_SESSION_ID => q{sess-g-code-env} },
    );
    is($rc, 0, 'G1: arm --session succeeds');
    is(kv($out, 'STATUS'), 'armed', 'G2: and arms immediately, no ticket, no waiting');
    is(kv($out, 'SESSION'), 'sess-g-explicit', 'G3: reporting the id it was given');
    ok(-f marker_path($reg, 'sess-g-explicit'), 'G4: marker written under the --session id');
    ok(!-f marker_path($reg, 'sess-g-env-should-be-ignored'),
       'G5: and nothing under either env id -- an explicit instruction is not a hint');
    ok(!-f marker_path($reg, 'sess-g-code-env'), 'G6: neither of them');
    ok(!-d "$reg/pending" || do {
           opendir(my $p, "$reg/pending") or die $!;
           my @t = grep { !/^\.\.?$/ } readdir $p;
           closedir $p;
           !@t;
       }, 'G7: the direct path writes no ticket');
}

# ===========================================================================
# H. AC-5 (behavior 5): disarm on an armed session removes the marker AND all
#    three companion files (.wakeup-pending, .stop-blocks, .stop-ok,
#    pre-planted) in one call, exits 0, STATUS: disarmed.
# ===========================================================================
{
    my $reg = new_registry();
    run_cli(['arm', '--session', 'sess-h'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef });
    ok(-f marker_path($reg, 'sess-h'), 'H0 setup: armed first');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        open my $fh, '>', marker_path($reg, 'sess-h') . $suffix or die $!;
        close $fh;
    }
    my ($out, $rc) = run_cli(['disarm', '--session', 'sess-h'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg });
    is($rc, 0, 'H1 CANONICAL (-> AC-5): disarm on an armed session exits 0');
    is(kv($out, 'STATUS'), 'disarmed', 'H2: STATUS: disarmed');
    ok(!-f marker_path($reg, 'sess-h'), 'H3 CANONICAL: primary marker removed');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        ok(!-f marker_path($reg, 'sess-h') . $suffix,
           "H4 CANONICAL: companion file '$suffix' removed by the SAME disarm call");
    }
}

# ===========================================================================
# I. AC behavior 6: disarm on a session with NO marker -> STATUS: not_armed,
#    exit 2 (not an error).
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(['disarm', '--session', 'sess-i-never-armed'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg });
    is($rc, 2, 'I1 CANONICAL (-> behavior 6): disarm with no marker exits 2, distinct from '
             . 'both success (0) and error (1)');
    is(kv($out, 'STATUS'), 'not_armed', 'I2: STATUS: not_armed, not STATUS: error');
}

# ===========================================================================
# J. AC behavior 7 (status unarmed): status on a session with no marker ->
#    STATUS: unarmed, exit 0, and carries NO ARMED_BY/SINCE.
# ===========================================================================
{
    my $reg = new_registry();
    my ($out, $rc) = run_cli(['status', '--session', 'sess-j-never-armed'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg });
    is($rc, 0, 'J1 CANONICAL: status on an unarmed session exits 0');
    is(kv($out, 'STATUS'), 'unarmed', 'J2: STATUS: unarmed');
    ok(!defined(kv($out, 'ARMED_BY')), 'J3: no ARMED_BY line for an unarmed session');
}

# ===========================================================================
# K. AC behavior 8: re-arming an already-armed session is IDEMPOTENT -- it
#    refreshes mtime and content (ARMED_BY, SINCE) rather than erroring.
# ===========================================================================
{
    my $reg = new_registry();
    run_cli(['arm', '--session', 'sess-k', '--by', 'agent'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef });
    my $old_time = time() - 3600;
    utime($old_time, $old_time, marker_path($reg, 'sess-k')) or diag("utime failed: $!");

    my ($out, $rc) = run_cli(['arm', '--session', 'sess-k', '--by', 'operator'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef });
    is($rc, 0, 'K1 CANONICAL (-> behavior 8): re-arming an already-armed session does NOT error');
    is(kv($out, 'STATUS'), 'armed', 'K2: STATUS: armed on the re-arm too');
    is(kv($out, 'ARMED_BY'), 'operator',
       'K3 CANONICAL: re-arm with a DIFFERENT --by value overwrites the marker content -- '
     . 'proves this is a real overwrite, not a no-op that happens to print success');
    my @st = stat(marker_path($reg, 'sess-k'));
    ok($st[9] > $old_time + 1000,
       'K4 CANONICAL: re-arming refreshes the marker mtime (extends the TTL) -- an '
     . 'implementation that skips re-arming an already-armed session would leave the old '
     . 'backdated mtime in place and fail this specifically');
}

# ===========================================================================
# L. A session id containing a literal '.' is refused by arm/disarm/status
#    alike (spec SS2.3's marker-refusal rule, edge case list).
# ===========================================================================
{
    my $reg = new_registry();
    my ($aout, $arc) = run_cli(['arm', '--session', 'sess.with.dot'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef });
    is($arc, 1, 'L1 CANONICAL: arm refuses a session id containing a literal dot -- exit 1');
    is(kv($aout, 'STATUS'), 'error', 'L2: STATUS: error for the dotted id');
    opendir(my $dh, $reg) or die $!;
    my @entries = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
    is(scalar(@entries), 0, 'L3: no marker written under any filename for the dotted id');

    my ($dout, $drc) = run_cli(['disarm', '--session', 'sess.with.dot'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg });
    is($drc, 1, 'L4: disarm ALSO refuses the dotted id with exit 1, not exit 2 (not_armed)');
    is(kv($dout, 'STATUS'), 'error', 'L5: STATUS: error, distinguishing "invalid id" from '
                                    . '"valid id, simply not armed"');
}

# ===========================================================================
# N. fix-batch F3: a session id containing a literal backslash is refused by
#    arm/disarm alike, matching scripts/statusline.pl's own read-side sid
#    check. On this Windows/Git-for-Windows host both bash coreutils and this
#    host's Perl treat '\' inside a path string as a directory separator, so
#    an unrefused backslash id would resolve NESTED under the registry root
#    -- permanently invisible to the top-level-only reap sweep (red-team
#    MEDIUM-1). Proven here at the CLI boundary: no marker of any kind
#    appears anywhere under the registry, nested or not.
# ===========================================================================
{
    my $reg = new_registry();
    my ($aout, $arc) = run_cli(
        ['arm', '--session', 'evilsub\\evilfile', '--by', 'agent'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef },
    );
    is($arc, 1, 'N1 CANONICAL (-> fix-batch F3): arm refuses a session id containing a literal '
              . 'backslash -- exit 1');
    is(kv($aout, 'STATUS'), 'error', 'N2: STATUS: error for the backslash id');
    ok(!-e "$reg/evilsub", 'N3 CANONICAL: no subdirectory was created under the registry at all '
                         . '-- the id was refused before any filesystem write was attempted, not '
                         . 'merely refused to CREATE THE PARENT (which would still leave a '
                         . 'reap-invisible nested marker if a parent happened to pre-exist)');

    my ($dout, $drc) = run_cli(
        ['disarm', '--session', 'evilsub\\evilfile'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg },
    );
    is($drc, 1, 'N4 CANONICAL: disarm ALSO refuses the backslash id with exit 1 (invalid id), '
              . 'not exit 2 (not_armed)');
    is(kv($dout, 'STATUS'), 'error', 'N5: STATUS: error');
}

# ===========================================================================
# O. fix-batch F1: with CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME AND $USERPROFILE
#    ALL unset, arm/disarm/status must FAIL LOUDLY (STATUS: error, exit 1)
#    rather than silently resolve under $PWD or '.' -- the exact divergence
#    the three components previously had (lib.sh fell back to $PWD,
#    bp-continuity.pl to $USERPROFILE-then-'.', statusline.pl to '.').
#    Run from a scratch cwd so a REVERT of this fix (which would silently
#    write under './.claude/ccpraxis/.continuity-active') cannot pollute
#    this repo's own working directory.
# ===========================================================================
{
    my $scratch_cwd = tempdir(CLEANUP => 1);
    my $orig_cwd = Cwd::getcwd();
    chdir($scratch_cwd) or die "chdir $scratch_cwd: $!";
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'sess-o-unresolvable', '--by', 'agent'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef, HOME => undef, USERPROFILE => undef, BP_LEDGER => undef },
    );
    chdir($orig_cwd) or die "chdir back to $orig_cwd: $!";
    is($rc, 1, 'O1 CANONICAL (-> fix-batch F1): arm with CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME '
             . 'AND $USERPROFILE all unset exits 1 -- refuses to guess -- rather than silently '
             . 'writing under $PWD or \'.\'');
    is(kv($out, 'STATUS'), 'error', 'O2: STATUS: error');
    like(kv($out, 'ERROR') // '', qr/HOME|USERPROFILE/,
       'O3 CANONICAL: the error names the unresolved variables, not a generic message -- proves '
     . 'this is the path-resolution refusal, not some other unrelated exit-1 path');
    ok(!-e "$scratch_cwd/.claude", 'O4 CANONICAL: no .claude directory was created under the '
                                  . 'scratch cwd -- confirms no $PWD-relative fallback happened');
}

# ===========================================================================
# P. fix-batch F1 continued: with CCPRAXIS_CONTINUITY_ACTIVE_DIR unset and
#    $HOME unset but $USERPROFILE set (a fixture tempdir, never the real
#    user profile), arm resolves under
#    $USERPROFILE/.claude/ccpraxis/.continuity-active -- proving the
#    documented fallback ORDER (override, HOME, USERPROFILE) is followed,
#    not merely that unset-both fails.
# ===========================================================================
{
    my $userprofile = tempdir(CLEANUP => 1);
    my ($out, $rc) = run_cli(
        ['arm', '--session', 'sess-p-userprofile', '--by', 'agent'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef, HOME => undef,
          USERPROFILE => $userprofile, BP_LEDGER => undef },
    );
    is($rc, 0, 'P1 CANONICAL (-> fix-batch F1): arm succeeds with only $USERPROFILE set');
    is(kv($out, 'STATUS'), 'armed', 'P2: STATUS: armed');
    ok(-f "$userprofile/.claude/ccpraxis/.continuity-active/sess-p-userprofile",
       'P3 CANONICAL: the marker was written under $USERPROFILE-derived path, matching lib.sh'."'"
     . 's documented fallback order exactly');
}

# ===========================================================================
# M. Non-vacuity guard for the harness itself: an entirely unrelated,
#    never-armed session id must never spuriously report armed.
# ===========================================================================
{
    my $reg = new_registry();
    run_cli(['arm', '--session', 'sess-m-other'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, BP_LEDGER => undef });
    my ($out, $rc) = run_cli(['status', '--session', 'sess-m-unrelated'], { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg });
    is($rc, 0, 'M1: status exits 0');
    is(kv($out, 'STATUS'), 'unarmed',
       'M2 CANONICAL: a DIFFERENT session id in the same registry, never armed itself, does '
     . 'NOT report armed just because some OTHER session in the same dir is armed -- proves '
     . 'per-session lookup, not "is the directory non-empty"');
}

done_testing();
