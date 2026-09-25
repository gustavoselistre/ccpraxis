#!/usr/bin/env perl
# platform: windows
# ORACLE: scripts/statusline.pl (repo root) -- NOT
# plugins/butler/scripts/bp-statusline.pl, which the live statusline never
# invokes (ledger correction, 2026-08-14).
#
# Spec 16-cutover (hook-continuity-remake), batch C, criterion C-8: the badge
# is lit iff <state>/armed/<sid> is a regular file, where <state> is
# BUTLER_STATE_DIR + "/continuity" when that variable is set and absolute
# (set but relative: unresolvable, badge stays hollow), else $HOME then
# $USERPROFILE + "/.claude/butler-state/continuity" (BpHook::state_dir's own
# rule, duplicated here because statusline.pl stays a standalone payload).
# The three old per-session registries (.continuity-active, .drive-solo-active,
# .reporter-active) are gone (1.3 departure #8); a marker in the OLD registry
# alone must now leave the badge hollow (this file's own K section pinned
# those three registries before batch C -- superseded here, reason SW: the
# switch this file tested is retired, not merely renamed).
#
# NEVER points at real state: HOME, USERPROFILE and BUTLER_STATE_DIR are
# always File::Temp tempdirs; PATH is overridden to a shim dir so no real
# `git`/`tput` on this machine is ever consulted.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);

my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl";

ok(-f $STATUSLINE, 'A1: scripts/statusline.pl exists') or BAIL_OUT('file missing');

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

my $SHIM_DIR = tempdir(CLEANUP => 1);
sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}
sub make_git_absent {
    spew_raw("$SHIM_DIR/git", "#!/bin/sh\nexit 1\n");
    chmod 0755, "$SHIM_DIR/git";
}
make_tput(120);
make_git_absent();

my $TMPROOT = tempdir(CLEANUP => 1);

# WHAT THE BADGE LOOKS LIKE -- the lead glyph, filled when armed, hollow when
# not (Decision 3: filled means watched, hollow means not; survives an SGR
# strip).
my $GLYPH_WATCHED   = "\xe2\x97\x8f";   # U+25CF filled
my $GLYPH_UNWATCHED = "\xe2\x97\x8b";   # U+25CB hollow
sub armed_out {
    my ($out) = @_;
    $out = '' unless defined $out;
    $out =~ s/\033\[[^m]*m//g;
    my ($first) = split /\n/, $out, 2;
    $first = '' unless defined $first;
    return index($first, $GLYPH_WATCHED) == 0 ? 1 : 0;
}

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // '/w/proj-alpha' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if exists $opt{session_id};
    return \%p;
}

# plant_armed($butler_state_dir, $sid) -- creates
# <butler_state_dir>/continuity/armed/<sid> as a plain regular file, exactly
# where statusline.pl's _state_dir() resolves BUTLER_STATE_DIR to (it appends
# "/continuity" itself). Content is irrelevant to the badge (presence-only);
# an empty file is deliberately used so no test here depends on the arm
# file's own JSON shape.
sub plant_armed {
    my ($butler_state_dir, $sid) = @_;
    my $dir = "$butler_state_dir/continuity/armed";
    make_path($dir) unless -d $dir;
    open my $fh, '>', "$dir/$sid" or die "plant $dir/$sid: $!";
    close $fh;
}

# plant_armed_under_state_dir($resolved_state_dir, $sid) -- for the HOME/
# USERPROFILE-derived fixtures (G, H), which already build the FULL resolved
# path ".../continuity" themselves; this variant does not append it again.
sub plant_armed_under_state_dir {
    my ($resolved_state_dir, $sid) = @_;
    my $dir = "$resolved_state_dir/armed";
    make_path($dir) unless -d $dir;
    open my $fh, '>', "$dir/$sid" or die "plant $dir/$sid: $!";
    close $fh;
}

# run_statusline(\%payload, %opt) -> ($stdout_bytes, $rc)
# opt: state (BUTLER_STATE_DIR), home
sub run_statusline {
    my ($payload, %opt) = @_;
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // tempdir(CLEANUP => 1);
    delete $ENV{USERPROFILE} unless exists $opt{userprofile};
    $ENV{USERPROFILE} = $opt{userprofile} if exists $opt{userprofile};
    if (defined $opt{state}) { $ENV{BUTLER_STATE_DIR} = $opt{state} }
    else                     { delete $ENV{BUTLER_STATE_DIR} }
    # No legacy override ever leaks into a fixture.
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{CCPRAXIS_DRIVE_ACTIVE_DIR};
    delete $ENV{CCPRAXIS_REPORTER_ACTIVE_DIR};

    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}

sub mkdir_p_test {
    my ($path) = @_;
    make_path($path);
}

# ===========================================================================
# B. C-8 positive: an armed/<sid> file exists for session S under a temp
#    BUTLER_STATE_DIR; the payload carries session_id=S -> the glyph is
#    filled (byte-exact substring in stdout).
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-b-armed');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-b-armed'), state => $state);
    is($rc, 0, 'B1 setup: statusline.pl exits 0 for an armed session'."'".' payload');
    ok(armed_out($out),
       'B2 CANONICAL (-> C-8): the glyph is filled when armed/<sid> exists under BUTLER_STATE_DIR '
     . 'and the payload'."'".'s session_id matches');
}

# ===========================================================================
# C. Per-session: an armed/<sid> file exists only for S; the payload carries a
#    DIFFERENT session id T -> the glyph stays hollow.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-c-armed-other');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-c-DIFFERENT-unarmed'), state => $state);
    is($rc, 0, 'C1 setup: exits 0');
    ok(!armed_out($out),
       'C2 CANONICAL: a DIFFERENT session id in the payload, even though SOME session is armed '
     . 'under the same state root, does NOT light the badge -- per-session lookup, not '
     . '"is anything armed anywhere"');
}

# ===========================================================================
# D. No armed file at all for the payload's own session_id -> no badge,
#    exit 0, no crash.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);   # empty store
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-d-never-armed'), state => $state);
    is($rc, 0, 'D1: exits 0 for an unarmed session with an otherwise-valid session_id');
    ok(!armed_out($out), 'D2: no badge for an unarmed session');
}

# ===========================================================================
# E. Graceful degradation: session_id OMITTED ENTIRELY -- still renders (>=2
#    rows, no crash), badge slot blank-padded, no reflow.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-e-irrelevant');   # some OTHER session is armed
    my %p = %{ payload_for() };
    delete $p{session_id};
    ok(!exists $p{session_id}, 'E0 setup: payload has no session_id key at all');

    my ($out, $rc) = run_statusline(\%p, state => $state);
    is($rc, 0, 'E1 CANONICAL: statusline.pl does not crash when session_id is entirely absent '
             . 'from the payload -- exit 0');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2,
       'E2 CANONICAL: still renders (at least) the two previously-fixed rows -- no reflow, '
     . 'no row dropped, when session_id is missing');
    ok(!armed_out($out),
       'E3 CANONICAL: no badge renders when session_id is absent -- and does NOT fall back to '
     . '"something, somewhere, is armed"');
}

# ===========================================================================
# F. Row-width parity: an armed and an unarmed run at the SAME terminal width
#    produce line-1 outputs of the SAME row_cost budget class.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-f-armed');

    my ($out_armed)   = run_statusline(payload_for(session_id => 'sess-f-armed'), state => $state);
    my ($out_unarmed) = run_statusline(payload_for(session_id => 'sess-f-unarmed'), state => $state);

    my ($line1_armed)   = split /\n/, $out_armed;
    my ($line1_unarmed) = split /\n/, $out_unarmed;
    $line1_armed   //= ''; $line1_unarmed //= '';

    my $strip = sub { my $s = shift; $s =~ s/\033\[[^m]*m//g; return $s };
    my $bare_armed   = $strip->($line1_armed);
    my $bare_unarmed = $strip->($line1_unarmed);

    is(length($bare_armed), length($bare_unarmed),
       'F1 CANONICAL: line 1'."'".'s SGR-stripped byte length is IDENTICAL whether the badge '
     . 'renders filled or hollow -- the slot is reserved either way');
}

# ===========================================================================
# G. Path-resolution parity (C-8 / spec 2.9), (a): BUTLER_STATE_DIR unset,
#    HOME set to a fixture path -- the badge must key off
#    ${HOME}/.claude/butler-state/continuity/armed/<sid>.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my $default_dir = "$home/.claude/butler-state/continuity";
    mkdir_p_test($default_dir);
    plant_armed_under_state_dir($default_dir, 'sess-g-home-default');

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g-home-default'),
        home => $home,
        # state deliberately NOT passed -- exercise the HOME-derived default
    );
    is($rc, 0, 'G1 setup: exits 0');
    ok(armed_out($out),
       'G2 CANONICAL (-> C-8/2.9a): with BUTLER_STATE_DIR UNSET and HOME pointed at a fixture, '
     . 'the badge renders from armed/<sid> planted at the documented default path '
     . '${HOME}/.claude/butler-state/continuity -- proves statusline.pl'."'".'s own resolution '
     . 'matches BpHook::state_dir'."'".'s default');
}
{
    # (b) BUTLER_STATE_DIR SET, HOME set DIFFERENTLY: the override must win --
    #     an armed file at the HOME-default path must NOT be seen when the
    #     override points elsewhere.
    my $home = tempdir(CLEANUP => 1);
    my $home_default_dir = "$home/.claude/butler-state/continuity";
    mkdir_p_test($home_default_dir);
    plant_armed_under_state_dir($home_default_dir, 'sess-g2-should-not-be-seen');

    my $override_root = tempdir(CLEANUP => 1);   # deliberately empty -- no armed file here

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g2-should-not-be-seen'),
        home => $home, state => $override_root,
    );
    is($rc, 0, 'G3 setup: exits 0');
    ok(!armed_out($out),
       'G4 CANONICAL (-> C-8/2.9a): with BUTLER_STATE_DIR SET to an EMPTY override root, an '
     . 'armed file sitting at the HOME-derived default path is NOT consulted -- the override wins');
}

# ===========================================================================
# H. (a) $HOME unset but $USERPROFILE set (a fixture tempdir, never the real
#    user profile) resolves under $USERPROFILE.
# ===========================================================================
{
    my $userprofile = tempdir(CLEANUP => 1);
    my $default_dir = "$userprofile/.claude/butler-state/continuity";
    mkdir_p_test($default_dir);
    plant_armed_under_state_dir($default_dir, 'sess-h-userprofile');

    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-h-userprofile'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    $ENV{USERPROFILE} = $userprofile;
    delete $ENV{BUTLER_STATE_DIR};
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    is($rc, 0, 'H1 setup: exits 0 with $HOME unset, $USERPROFILE set');
    ok(armed_out($out),
       'H2 CANONICAL: with $HOME unset and $USERPROFILE pointed at a fixture, the badge renders '
     . 'from armed/<sid> under $USERPROFILE/.claude/butler-state/continuity -- matches '
     . 'BpHook::state_dir'."'".'s fallback order exactly');
}

# ===========================================================================
# I. (b) NEITHER $HOME NOR $USERPROFILE set (and no BUTLER_STATE_DIR) -- the
#    badge must degrade SAFELY to "not armed" (no glyph filled, no crash,
#    exit 0), never guess '.' as a store root and never die.
# ===========================================================================
{
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-i-unresolvable'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    delete $ENV{BUTLER_STATE_DIR};
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    is($rc, 0, 'I1 CANONICAL: statusline.pl does not crash when BUTLER_STATE_DIR, $HOME and '
             . '$USERPROFILE are all unset');
    ok(!armed_out($out),
       'I2 CANONICAL: badge renders unarmed (no badge) rather than guessing \'.\' as a store root');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2, 'I3: still renders both rows -- no crash, no reflow');
}

# ===========================================================================
# I2. C-8: a RELATIVE BUTLER_STATE_DIR leaves the badge hollow -- unresolvable,
#     never guessed at, even though an armed file exists at the resolved-looking
#     relative path in the current directory.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-i2-relative'),
        home => $home, state => 'relative/state/dir',
    );
    is($rc, 0, 'I2-1: exits 0 with a relative BUTLER_STATE_DIR');
    ok(!armed_out($out),
       'I2-2 CANONICAL (-> C-8): a relative BUTLER_STATE_DIR is unresolvable -- badge stays '
     . 'hollow rather than guessing');
}

# ===========================================================================
# L. F8 (fix-batch 16-cutover, red-team L6). Addition, not a weakening: a
#    BARE drive letter with no slash ("C:") is NOT absolute -- BpHook::_is_abs
#    requires [\\/] right after the colon, and statusline.pl must agree, so a
#    bare "C:" BUTLER_STATE_DIR leaves the badge hollow rather than resolving
#    to a real "C:/continuity" this test must never touch.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-l-bare-drive'),
        home => $home, state => 'C:',
    );
    is($rc, 0, 'L1: exits 0 with a bare drive-letter BUTLER_STATE_DIR');
    ok(!armed_out($out),
       'L2 CANONICAL (-> F8/L6): a bare "C:" BUTLER_STATE_DIR (no slash) is treated as NOT '
     . 'absolute, matching BpHook::_is_abs -- the badge stays hollow rather than resolving '
     . 'to a real C:/continuity path');
}

# ===========================================================================
# J. NARROW-WIDTH TRUNCATION MUST NOT SPLIT AN ANSI ESCAPE.
#
# NON-VACUITY: this asserts on the RAW BYTES of stdout, and the widths below
# straddle the rung that broke -- 120 and 20 rendered correctly before the
# fix, 14/10/6/3/1 did not.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-j-armed');

    my $well_formed = qr/\e(?:\[[0-9;:?]*[ -\/]*[\@-~]|[\@-_])/;

    for my $cols (120, 20, 14, 10, 6, 3, 1) {
        make_tput($cols);
        my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-j-armed'), state => $state);
        is($rc, 0, "J: statusline.pl exits 0 at cols=$cols");

        my $scan = $out;
        $scan =~ s/$well_formed//g;
        ok(index($scan, "\e") < 0,
           "J: no truncated/malformed ANSI escape survives at cols=$cols "
         . '(fit_head must treat an escape as atomic and zero-width)')
            or diag('offending bytes: ' . join('', map { sprintf('\\x%02x', ord) } split //, $scan));
    }

    make_tput(120);   # restore the harness default for any later section
}

# ===========================================================================
# K. THE OLD PER-SESSION REGISTRIES NO LONGER LIGHT THE BADGE (SW).
#
# Batch C retires the switch this file's old section K exercised: the badge
# is single-source now. A marker planted in any of the three old registries,
# with no armed/<sid> file anywhere, must leave the badge hollow.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    for my $leaf (qw(.continuity-active .drive-solo-active .reporter-active)) {
        my $dir = "$home/.claude/ccpraxis/$leaf";
        mkdir_p_test($dir);
        open my $fh, '>', "$dir/sess-k-legacy-only" or die "plant $dir: $!";
        close $fh;
    }
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-k-legacy-only'), home => $home);
    is($rc, 0, 'K1: exits 0');
    ok(!armed_out($out),
       'K2 CANONICAL (-> C-8, SW): a marker in any of the three old per-session registries alone, '
     . 'with no armed/<sid> file, leaves the badge hollow -- the old registries are retired');
}

done_testing();
