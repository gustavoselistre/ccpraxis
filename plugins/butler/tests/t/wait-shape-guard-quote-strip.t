#!/usr/bin/env perl
# platform: any
# 169 -- oracle for t09-guard-hooks-stripping's
# wait-shape-guard.sh changes (spec .ccpraxis-local-data/blueprints/
# tui-operator-feedback/specs/t09-guard-hooks-stripping-spec.md SS2.2/SS2.3/SS3/SS4).
# Companion to wait-shape-guard.t (that file's own oracle, NOT edited here -- this
# package's write set is tests/t/ only). 67 already pins the pure matchers' existing
# behavior on raw strings; this file adds ONLY the two things t09 changes: bp_ws_main's
# new stripped-match-text computation (AC10) and the AC11 "the three pure helpers stay
# pure/unchanged" guarantee, re-verified independently here rather than assumed.
#
# WRITTEN BLIND TO THE IMPLEMENTATION.
#
# jq AVAILABILITY. bp_ws_main fails OPEN (exit 0, D7) the instant `command -v jq` is
# missing -- so every SUBPROCESS assertion (AC10) requires jq and is SKIPped on this
# jq-less Windows host, matching 67's own jq-gated SKIP convention for its hook-behavior
# groups. The PURE-HELPER assertions (AC11) need no jq at all (67's own D1 rationale)
# and run unconditionally.
#
# TECHNIQUE NOTE (guard evasion). Subprocess fixtures reach the hook only as JSON
# payload TEXT in a temp file, invoked via `bash "$HOOK" < payload`. Pure-helper calls
# source the file (arg0 'h', per 67's own mandated D1 form) and invoke the function
# directly -- never as literal text in a Bash tool_input.command this session issues.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $HOOK = "$HOOKS/wait-shape-guard.sh";

ok(-f $HOOK, 'wait-shape-guard.sh exists at plugins/butler/hooks/wait-shape-guard.sh')
    or BAIL_OUT('subject hook missing');

my $HAVE_JQ = `bash -c 'command -v jq' 2>/dev/null` =~ /\S/;
my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

sub write_file { my ($p, $b) = @_; open my $w, '>', $p or die; binmode $w; print $w $b; close $w }
sub read_file  { my ($p) = @_; open my $r, '<', $p or return ''; binmode $r; local $/; my $c = <$r>; close $r; return defined $c ? $c : '' }

sub mk_bp {
    my $d = "$ROOT/bp"; my $p = "$ROOT/proj";
    unless (-d $d) {
        mkdir $d or die; mkdir "$d/$_" or die for qw(packages reports specs runs);
        mkdir $p or die;
    }
    return (fwd($d), fwd($p));
}

sub run_hook {
    my ($payload, %env) = @_;
    my $n  = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    my $of = "$ROOT/stdout.$n.txt";
    my $ef = "$ROOT/stderr.$n.txt";
    write_file($pf, $payload);
    my ($bp, $proj) = mk_bp();
    local %ENV = (%CLEAN_ENV, %env,
                  HOOKPATH => fwd($HOOK), PFILE => fwd($pf), OFILE => fwd($of), EFILE => fwd($ef));
    system('bash', '-c', 'timeout 20 bash "$HOOKPATH" < "$PFILE" > "$OFILE" 2> "$EFILE"');
    my $rc = $? >> 8;
    return ($rc, read_file($ef), read_file($of));
}

sub pl_bash {
    my ($cmd) = @_;
    return $J->encode({ tool_name => 'Bash', session_id => 'sess1', cwd => '/project', tool_input => { command => $cmd } });
}

sub env_for {
    my ($bp, $proj) = @_;
    return (BP_DIR => $bp, BP_PROJECT_ROOT => $proj, BP_LEDGER => "$bp/packages/fixture.md", BP_PACKAGE => 'p');
}

# --- pure-helper invocation (67's own mandated D1 form). ---------------------------
sub ws_call {
    my ($fn, @args) = @_;
    my $ef = "$ROOT/wserr." . (++$pn) . ".txt";
    local %ENV = (%CLEAN_ENV, GUARDSH => fwd($HOOK), EFILE => fwd($ef));
    open(my $f, '-|', 'bash', '-c',
         qq{{ source "\$GUARDSH"; $fn "\$@"; } < /dev/null 2>"\$EFILE"}, 'h', @args)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o = '' unless defined $o;
    $o =~ s/\s+\z//;
    return $o;
}
sub is_wait_loop { return ws_call('bp_ws_is_wait_loop', $_[0]) }

# =====================================================================================
# AC1/AC3/AC11 -- REMOVED (package 16 batch-B fix round). AC1 and AC3 pinned literal
# bash source (the ACCIDENT/ADVERSARY/D7 rationale comment and the BP_WS_*_RE matcher
# strings) that no longer exists: wait-shape-guard.sh is now an exec shim into
# BpHook::Guards::WaitShapeGuard (reason SRC, same as guards-remake-wait-shape.t's own
# header note for the sibling old file wait-shape-guard.t). AC11 tested a pure
# bp_ws_is_wait_loop bash FUNCTION called directly, bypassing bp_ws_main entirely, to
# prove the split between the unstripped pure helper and the stripped-aware main body
# -- that split does not exist in the new architecture (there is no separately
# callable pure helper any more, only one run() entry point), so the whole mechanism
# AC11 exercised is gone (reason DEL). The behavior AC11 protected either side of
# (quote-stripping happens only in the enforcement path, not underneath it) is
# re-expressed by WS-1 (a real wait-loop denies) and WS-2 (a quoted mention of the
# same shape allows) in guards-remake-wait-shape.t. AC10 below (subprocess, jq-gated)
# is untouched -- it already exercises the real behavior through the actual hook.
# =====================================================================================

SKIP: {
    skip 'jq is not installed on this host; wait-shape-guard.sh fails OPEN (D7) without it, so no denial is observable', 2
        unless $HAVE_JQ;

    # =================================================================================
    # AC10 (DC3, observable behaviors 6/7) -- a command whose only wait-loop text sits
    # inside a quoted echo/documentation string is ALLOWED; a real wait-loop is still
    # DENIED with the unchanged R1-prefixed message.
    # =================================================================================
    my ($bp, $proj) = mk_bp();
    my %env = env_for($bp, $proj);
    {
        my $cmd = q{echo 'anti-pattern example: while ! test -f x; do sleep 5; done'};
        my ($rc, $err) = run_hook(pl_bash($cmd), %env);
        is($rc, 0, 'AC10: a quoted documentation mention of the wait-loop shape is ALLOWED') or diag("stderr: $err");
    }
    {
        my $cmd = q{while ! test -f x; do sleep 5; done};
        my ($rc, $err) = run_hook(pl_bash($cmd), %env);
        is($rc, 2, 'AC10: a real wait-loop is still DENIED, R1-prefixed, byte-identical to today') or diag("stderr: $err");
        like($err, qr/wait-loop/, 'AC10: denial message carries the R1 "wait-loop" label');
    }
}

done_testing();
