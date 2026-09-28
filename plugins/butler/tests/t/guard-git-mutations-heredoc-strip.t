#!/usr/bin/env perl
# platform: any
# 170 -- oracle for t09-guard-hooks-stripping's
# guard-git-mutations.sh changes (spec .ccpraxis-local-data/blueprints/
# tui-operator-feedback/specs/t09-guard-hooks-stripping-spec.md SS0/SS2.4/SS3/SS4).
#
# WRITTEN BLIND TO THE IMPLEMENTATION -- from the spec only. guard-git-mutations.sh
# does not yet call bp_strip_shell_noise at the time this file is authored; every AC
# below that depends on the new heredoc-only branch is expected to FAIL against the
# pre-fix tree (the live false positive, AC12, is denied instead of allowed today),
# and every regression-lock AC is expected to PASS unchanged both before and after
# (that is the evidence a real invocation is still blocked).
#
# guard-git-mutations-quote-mask.t is a FOREIGN, already-closed package's oracle
# (a02) and is treated here as READ-ONLY reference, never edited. This file adds NEW
# coverage the t09 spec specifically calls for: the heredoc-only live instance (AC12),
# the carrier+heredoc composition (AC16), an explicit re-pin of the AC-18/AC15 shellword
# family (per the t09 test-writer brief: "pin the shellword case bash -c \"<mutation>\"
# explicitly"), the bp_strip_shell_noise-unavailable degrade (AC17), and two structural
# ACs (AC2: bp_strip_shell_noise byte-identical; AC4: the three-state walk and anchor
# selection byte-identical) via literal substring pins captured from the PRE-FIX tree.
#
# TECHNIQUE NOTE (guard evasion). guard-git-mutations.sh is UNGATED and denies any Bash
# tool_input.command matching its own patterns -- including THIS SESSION's own Bash
# calls. Every fixture below reaches the hook only as JSON payload TEXT written to a
# temp file by the Write tool (never as literal text in a Bash tool_input.command this
# session issues), and the hook is invoked as a subprocess via `bash "$GPATH" < "$PFILE"`
# -- exactly 106's own technique, verified safe by 106 already running green in this
# session's history.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use File::Copy qw(copy);

(my $HOOKS = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-git-mutations.sh";
my $BPLIB  = "$SCRIPTS/bp-lib.sh";

ok(-f $GUARD, 'guard-git-mutations.sh exists') or BAIL_OUT('subject hook missing');
ok(-f $BPLIB, 'scripts/bp-lib.sh exists (bp_strip_shell_noise lives here)') or BAIL_OUT('bp-lib.sh missing');

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard_at {
    my ($guard_path, $cmd, %extra_env) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, %extra_env, GPATH => fwd($guard_path), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}
sub run_guard { my ($cmd) = @_; return run_guard_at($GUARD, $cmd) }

# =====================================================================================
# AC12 (DC4, observable behavior 8 -- THE LIVE INSTANCE)
# =====================================================================================
{
    my $cmd = qq{cat <<EOF > report.md\n... this describes why git stash is forbidden and git reset --hard destroyed a fix-batch ...\nEOF\nperl file-report.pl report.md};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'AC12: heredoc body merely MENTIONING forbidden verbs, no git invocation anywhere, is ALLOWED (the live instance)')
        or diag("hook output: $out; command was:\n$cmd");
}

# =====================================================================================
# AC13 (DC3, observable behavior 9) -- a real mutation textually adjacent to an
# UNRELATED heredoc elsewhere in the same command must still DENY.
# =====================================================================================
{
    my $cmd = qq{git stash ; cat <<EOF\nfoo\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC13: real "git stash" with an unrelated heredoc elsewhere in the command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
    like($out, qr/\Qgit stash\E/, 'AC13: denial "Command:" text shows the full RAW command (git stash present verbatim)');
}

# =====================================================================================
# AC16 (DC3, observable behavior 9/carrier composition) -- BOTH a bare carrier
# ($(...)) AND a heredoc marker in the same command: the carrier re-check must
# escalate the new heredoc branch to fully-raw, per spec SS2.4's own trace.
# =====================================================================================
{
    my $cmd = qq{echo \$(git reset --hard) ; cat <<EOF\nfoo\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC16: a command with BOTH a bare $(...) carrier and a heredoc marker is DENIED via carrier re-check escalation')
        or diag("hook output: $out; command was:\n$cmd");
}

# =====================================================================================
# AC15 (DC3, observable behavior 11 -- regression lock, AC-18 family) -- explicit
# re-pin per the test-writer brief: these must NOT regress. Redundant with 106's own
# AC-18 block by design -- verified independently here rather than assumed.
# =====================================================================================
for my $row (
    [ 'bash -c "git stash"'          => q{bash -c "git stash"} ],
    [ q{sh -c 'git reset --hard'}    => q{sh -c 'git reset --hard'} ],
    [ 'echo `git stash`'             => q{echo `git stash`} ],
    [ 'echo $(git reset --hard)'     => q{echo $(git reset --hard)} ],
) {
    my ($label, $cmd) = @$row;
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, "AC15 (pinned): $label is still DENIED after the heredoc-only fix")
        or diag("hook output: $out");
}

# =====================================================================================
# AC17/AC1/AC2/AC4 -- REMOVED (package 16 batch-B fix round). All four pinned literal
# bash source that no longer exists: guard-git-mutations.sh is now an exec shim into
# BpHook::Guards::GuardGitMutations (plugins/butler/scripts/BpHook/Guards/
# GuardGitMutations.pm), which uses BpHook::Guards::Shell::strip_noise -- a real perl
# module always require'd in-process, so AC17's "bp-lib.sh unreachable from a sibling
# hooks/ tree" failure mode cannot occur any more (the old shared bash guard library
# AC17 copied into its fixture is itself on the deletion list). guards-remake-git-mutations.t
# already documents this exact non-re-expression with reason codes, in its own header:
#   AC1  -> SRC   (header rationale text, no longer at that site)
#   AC2  -> LIB   (bp_strip_shell_noise SHA-1 pin against bp-lib.sh, a file this
#                  package never edits)
#   AC4  -> SRC   (git_scan_target's bash source, pinned as a literal substring)
#   AC17 -> OTHER (Guards::Shell is a real perl module, always require'd in-process
#                  by GuardHarness; there is no "sibling script missing" failure mode
#                  to reproduce)
# The underlying behaviors (heredoc-only mentions allow, real invocations with a
# heredoc elsewhere still deny, shellword/carrier escalation, quote-mask corpus) are
# re-expressed behaviorally in guards-remake-git-mutations.t's GG-1 corpus, which is
# explicitly built from "git-mutation-guard-reach.t section C, guard-git-mutations-
# quote-mask.t, guard-git-mutations-heredoc-strip.t (minus AC1/AC2/AC4/AC17...) and
# guard-prose-not-invocation.t". No behavior assertion is weakened.
# =====================================================================================
# Companion (edge case, spec SS5) -- empty tool_input.command still exits 0. Must stay
# green; not this package's concern but a fast regression check that the new branch
# did not disturb the very first guard in the function.
# =====================================================================================
{
    my ($rc, $out) = run_guard('');
    is($rc, 0, 'companion: empty tool_input.command is still ALLOWED, unaffected by this package');
}

done_testing();
