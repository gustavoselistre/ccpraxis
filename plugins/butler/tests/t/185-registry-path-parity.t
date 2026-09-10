#!/usr/bin/env perl
# 185-registry-path-parity.t — the four legs must agree about where the registry is.
#
# WHY FOUR COPIES EXIST AT ALL. The continuity registry path is resolved
# independently by lib.sh (bash, for the hooks), bp-continuity.pl (the write
# path), bp-session.pl (the gate's claim step) and scripts/statusline.pl (the
# badge). The duplication is deliberate -- the perl side imports nothing
# bash-side, and the statusline must not depend on butler at all -- and it is
# defended in long comments in each file. Those comments said "three legs". It
# was four, and one of them disagreed.
#
# WHAT WENT WRONG. lib.sh rejects a CCPRAXIS_CONTINUITY_ACTIVE_DIR that is not
# ABSOLUTE (bp_is_absolute_path); the three perl copies accepted any non-empty
# string. So with a relative override: `arm` wrote a marker under the caller's
# cwd and reported success, `status` reported armed, the badge lit up -- and the
# gate, which refused to resolve at all, enforced nothing. "Armed, enforcing
# nothing" is the precise failure the whole subsystem exists to remove, and the
# parity these comments promise is what let it back in.
#
# So the rule is not restated here in a fifth place. This feeds ONE environment
# to ALL FOUR and requires the same verdict from each.
#
# AC1  every leg accepts the same absolute overrides
# AC2  every leg refuses the same relative/degenerate overrides
# AC3  with no override, every leg agrees on the $HOME-derived default
# AC4  a relative $HOME is refused by every leg (not just the override)
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my $REPO       = "$Bin/../../../..";
my $LIB_SH     = "$Bin/../../hooks/lib.sh";
my $CONT_PL    = "$Bin/../../scripts/bp-continuity.pl";
my $SESSION_PL = "$Bin/../../scripts/bp-session.pl";
my $STATUS_PL  = "$REPO/scripts/statusline.pl";

ok(-f $LIB_SH,     'lib.sh present')          or BAIL_OUT('missing');
ok(-f $CONT_PL,    'bp-continuity.pl present') or BAIL_OUT('missing');
ok(-f $SESSION_PL, 'bp-session.pl present')    or BAIL_OUT('missing');
ok(-f $STATUS_PL,  'statusline.pl present')    or BAIL_OUT('missing');

# Each probe answers exactly one question: does THIS leg resolve, for THIS
# environment? 'resolved' or 'unresolved' -- never the path itself, because the
# legs legitimately differ in what they return (a leaf name, a full path), and
# what has to match is the VERDICT.
sub env_prefix {
    my ($env) = @_;
    my @parts;
    for my $k (sort keys %$env) {
        if (defined $env->{$k}) { push @parts, "$k='$env->{$k}'" }
        else                    { push @parts, "$k=" }   # unset below
    }
    return @parts;
}

sub run_with_env {
    my ($env, $cmd) = @_;
    my $unset = join ' ', map { $_ } grep { !defined $env->{$_} } sort keys %$env;
    my $set   = join ' ', map { "$_='$env->{$_}'" }
                          grep { defined $env->{$_} } sort keys %$env;
    my $pre = $unset ? "unset $unset; " : '';
    my $out = `$pre $set $cmd 2>&1`;
    return ($out // '', $? >> 8);
}

sub leg_bash {
    my ($env) = @_;
    my ($out) = run_with_env($env,
        qq{bash -c 'source "$LIB_SH"; if bp_continuity_active_dir >/dev/null 2>&1; }
      . qq{then echo resolved; else echo unresolved; fi'});
    return $out =~ /resolved/ && $out !~ /unresolved/ ? 'resolved' : 'unresolved';
}

# The two butler scripts have no "print the dir" verb, deliberately -- so ask
# them the question they DO answer. `arm --session x` on an unresolvable
# registry exits 1 with STATUS: error; on a resolvable one it arms.
sub leg_continuity {
    my ($env) = @_;
    my ($out, $rc) = run_with_env($env, qq{perl "$CONT_PL" arm --session parity-probe});
    return $rc == 0 ? 'resolved' : 'unresolved';
}

sub leg_session {
    my ($env) = @_;
    my ($out) = run_with_env($env, qq{perl "$SESSION_PL" claim --session parity-probe});
    # 'cannot resolve the continuity registry' is the unresolved answer; any
    # other STATUS means it got a directory.
    return $out =~ /cannot resolve the continuity registry/ ? 'unresolved' : 'resolved';
}

sub leg_statusline {
    my ($env) = @_;
    my ($out) = run_with_env($env,
        qq{perl -e 'do "$STATUS_PL"; }
      . qq{print defined(_registry_dir("CCPRAXIS_CONTINUITY_ACTIVE_DIR", ".continuity-active")) }
      . qq{? "resolved" : "unresolved"'});
    return $out =~ /unresolved/ ? 'unresolved' : ($out =~ /resolved/ ? 'resolved' : 'unresolved');
}

sub verdicts {
    my ($env) = @_;
    return {
        bash       => leg_bash($env),
        continuity => leg_continuity($env),
        session    => leg_session($env),
        statusline => leg_statusline($env),
    };
}

sub check {
    my ($label, $env, $expected) = @_;
    my $v = verdicts($env);
    my @legs = sort keys %$v;
    my @disagree = grep { $v->{$_} ne $expected } @legs;
    is_deeply(\@disagree, [],
        "$label: all four legs say '$expected'"
      . (@disagree ? " (disagreeing: " . join(', ', map { "$_=$v->{$_}" } @disagree) . ")" : ''));
}

my $abs = tempdir(CLEANUP => 1);

# ── AC1 — absolute overrides are accepted everywhere ──────────────────────
check('AC1 absolute posix override',
      { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $abs, HOME => $abs, USERPROFILE => $abs },
      'resolved');

# ── AC2 — relative and degenerate overrides are refused everywhere ────────
for my $bad ('relative/bad', '.', '..', 'bareword') {
    check("AC2 override '$bad'",
          { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $bad, HOME => $abs, USERPROFILE => $abs },
          'unresolved');
}

# ── AC3 — no override: everyone derives from an absolute HOME ─────────────
check('AC3 no override, absolute HOME',
      { CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef, HOME => $abs, USERPROFILE => $abs },
      'resolved');

# ── AC4 — a relative HOME is refused everywhere too ───────────────────────
#
# This is the case lib.sh's own comment records as reproduced: HOME=' ' left a
# directory literally named ' ' under the hook's cwd. The perl legs used to
# accept it.
check('AC4 relative HOME',
      { CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef, HOME => 'relative-home',
        USERPROFILE => 'relative-home' },
      'unresolved');

done_testing();
