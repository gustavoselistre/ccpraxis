#!/usr/bin/env perl
# platform: any
# THE GUARD EXISTED, WAS CORRECT, AND PROTECTED ALMOST NOBODY.
#
# guard-git-mutations.sh was written after a prohibited `git st'.'ash` took a
# completed fix-batch off disk (ef272c3). Its own header states the thesis this
# repo keeps re-learning: a written instruction is not an enforcement mechanism.
# It deliberately carries NO bp_hook_gate, so that it applies in every session
# rather than only inside butler-launched workers.
#
# It was registered in exactly one place: ccpraxis's own .claude/settings.json.
# Nothing registered it in the PLUGIN's hooks.json, which is what travels to
# every other project on the machine. So the guard protected sessions working ON
# ccpraxis, and no one else -- while the incident it exists to prevent happened
# again, in a /butler:drive-solo run in a different project, on 2026-09-11:
# `git st'.'ash` took a completed package implementation off disk, the tree read
# as clean, and it was recovered only because a reviewer happened to mention it
# in the last line of a report (20260911-211454-863c).
#
# The prohibition survived as prose in a dispatch prompt. Again.
#
# WHAT THIS FILE PINS:
#   A. reach      -- the plugin registers it, so it ships with the plugin.
#   B. ungated    -- it stays universal; adding a gate would re-scope it to the
#                    worker sessions that were never the problem.
#   C. behaviour  -- it still denies what it exists to deny, INCLUDING the two
#                    command-position forms that once slipped past, and still
#                    allows the read-only git an agent legitimately needs.
#   D. belt       -- ccpraxis's own registration is untouched. Two other tests
#                    already depend on it; this one states WHY both exist.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $ROOT  = "$Bin/../../../..";
my $HOOKS = "$Bin/../../hooks/hooks.json";
my $GUARD = "$Bin/../../hooks/guard-git-mutations.sh";

ok(-f $HOOKS, 'hooks.json is present') or BAIL_OUT('no hooks.json');
ok(-f $GUARD, 'guard-git-mutations.sh is present') or BAIL_OUT('no guard');

# ===========================================================================
# A. REACH. Registered in the plugin, on Bash, where a git command arrives.
# ===========================================================================
my $json = eval { JSON::PP->new->decode(do { local (@ARGV, $/) = ($HOOKS); <> }) };
ok(ref $json eq 'HASH', 'hooks.json parses') or BAIL_OUT("unparsable hooks.json: $@");

my $pre = $json->{hooks}{PreToolUse};
ok(ref $pre eq 'ARRAY', 'A0: there is a PreToolUse registration list');

my @bash_cmds;
for my $group (@{ $pre || [] }) {
    next unless ref $group eq 'HASH';
    my $m = defined $group->{matcher} ? $group->{matcher} : '';
    # The guard must reach Bash. A matcher of Bash, or none at all (which
    # matches everything), both satisfy that; anything narrower does not.
    next unless $m eq '' || $m =~ /\bBash\b/;
    push @bash_cmds, map { $_->{command} // '' } @{ $group->{hooks} || [] };
}
ok(scalar @bash_cmds, 'A1: some hooks are registered for Bash')
    or diag('nothing registered for Bash at all -- A2 would be vacuous');
my @ggm = grep { /guard-git-mutations\.sh/ } @bash_cmds;
ok(scalar @ggm,
   'A2: guard-git-mutations.sh is registered by the PLUGIN, so it travels to every project')
    or diag("Bash-reaching hooks are:\n  " . join("\n  ", @bash_cmds));
is(scalar(grep { !/--only-during-butler-run/ } @ggm), 0,
   'A3: ...and every travelling registration is RUN-SCOPED. hooks.json reaches every project '
 . 'on the machine, so a bare one here would deny these commands in the operator\'s own '
 . 'unrelated work -- the objection hooks-json-route-registration.t AC7 was written to hold, '
 . 'and the reason this registration took a flag rather than being dropped in as-is');

# ===========================================================================
# B. UNGATED. The whole point is that it is not scoped to worker sessions.
# ===========================================================================
my $src = do { local (@ARGV, $/) = ($GUARD); <> };
my @gate_calls = grep { /^\s*bp_hook_gate\s*$/ } split /\n/, $src;
is(scalar @gate_calls, 0,
   'B1: the guard calls no bp_hook_gate -- it applies everywhere, which is the '
   . 'only reason registering it above buys anything');

# Non-vacuity for B1: the same detector must fire on a hook that DOES gate.
# bp_hook_gate itself is retired (package 16's cutover): the successor core
# gates through run-hook.sh's --pre clauses in the REGISTRATION string, not
# an in-script function call, so no hooks/*.sh file calls bp_hook_gate any
# more and this non-vacuity fixture has no live subject (DEL, Decision 34).
# The detector is proven non-vacuous instead against its own historical
# positive: a literal fixture string containing the retired call shape.
{
    my $fixture_src = "some_other_line\nbp_hook_gate\ntrailing\n";
    my @g = grep { /^\s*bp_hook_gate\s*$/ } split /\n/, $fixture_src;
    cmp_ok(scalar @g, '>', 0,
           'B2: the B1 detector does fire on text that calls bp_hook_gate -- it is a real '
         . 'check (bp_hook_gate itself is retired; no successor hook calls it any more, so '
         . 'this is a fixture positive rather than a live hooks/ file, DEL)');
}

# ===========================================================================
# C. BEHAVIOUR. Run the hook. Exit 2 blocks; exit 0 allows.
#
# The verb is assembled rather than written out, so this file's own text cannot
# trip the guard when some other tool reads it back as a shell command.
# ===========================================================================
my $V = 'st' . 'ash';

sub run_guard {
    my ($command, %opt) = @_;
    my $args = $opt{args} // '';
    my $payload = JSON::PP->new->encode({ tool_name => 'Bash', tool_input => { command => $command } });
    my $tmp = "$Bin/.guard-probe.$$";
    local %ENV = (%ENV, %{ $opt{env} || {} });
    delete $ENV{BP_LEDGER} unless ($opt{env} || {})->{BP_LEDGER};
    open my $fh, '|-', "bash \"$GUARD\" $args > \"$tmp\" 2>&1" or die "spawn: $!";
    print $fh $payload;
    close $fh;
    my $rc = $? >> 8;
    my $out = -f $tmp ? do { local (@ARGV, $/) = ($tmp); <> } : '';
    unlink $tmp;
    return ($rc, defined $out ? $out : '');
}

my @deny = (
    [ "git $V",                        'the bare form' ],
    [ "(git $V push -m wip)",          'a subshell, which opens a command position' ],
    [ "x=1; {git $V push -m wip; }",   'a brace group, likewise' ],
);
for my $case (@deny) {
    my ($cmd, $why) = @$case;
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, "C-deny: blocked -- $why");
    like($out, qr/BLOCKED/, "C-deny: ... and says so on stderr -- $why");
}

my @allow = (
    [ "git status",   'read-only status' ],
    [ "git diff",     'read-only diff, the thing agents should use instead' ],
    [ "git $V list",  'listing existing entries destroys nothing' ],
);
for my $case (@allow) {
    my ($cmd, $why) = @$case;
    my ($rc) = run_guard($cmd);
    is($rc, 0, "C-allow: allowed -- $why");
}

# ===========================================================================
# D. BELT. ccpraxis's own registration stays. It is not redundant with A2:
# that one ships with the plugin and can be disabled with it, while this one is
# project config for the repo where the original incident happened.
# ===========================================================================
my $settings = "$ROOT/.claude/settings.json";
SKIP: {
    skip 'not running inside the ccpraxis repo', 1 unless -f $settings;
    my $s = do { local (@ARGV, $/) = ($settings); <> };
    like($s, qr/guard-git-mutations\.sh/,
         'D1: ccpraxis .claude/settings.json still registers the guard directly');
}

# ===========================================================================
# E. THE SCOPING FLAG, EXERCISED. Three populations, and the answers differ.
#
# This is the assertion set that keeps the fix from being an imposition. The
# guard reaches butler work in every project; it does not reach the operator's
# own ordinary sessions in projects that have nothing to do with butler.
# ===========================================================================
{
    my $cmd = "git $V";

    # THE IDLE PREMISE IS CONSTRUCTED, NOT ASSUMED (bug 20260916-150236-6684).
    #
    # E2 asserts the run-scoped guard ALLOWS when no butler run is active. It
    # used to establish "no butler run is active" by simply not setting
    # anything -- which reads the REAL machine-level registry. So the case was
    # green on an idle machine and RED whenever a drive-solo run was actually
    # in progress, i.e. exactly when this suite gets run. Measured red at
    # 2026-09-16 mid-drive with 22 ok / 1 not ok, on a tree that had not
    # touched the guard or this file.
    #
    # The guard was right and the fixture was wrong: bp_drive_any_active reads
    # the on-disk marker deliberately (that is E4's whole point -- a Task
    # subagent inherits no BP_*), so an "idle" assertion has to POINT IT
    # SOMEWHERE KNOWN rather than hope the machine is quiet.
    #
    # bp_drive_active_dir already honours CCPRAXIS_DRIVE_ACTIVE_DIR and
    # validates it as absolute (lib.sh:688), so an empty File::Temp dir is all
    # the construction needed -- no production change, and the same shape the
    # continuity tests already use for CCPRAXIS_CONTINUITY_ACTIVE_DIR.
    #
    # All THREE cases get it, not just E2. E1 and E3 were passing for reasons
    # that happened to coincide with their claims: during a live drive E1
    # ("blocks unconditionally") and E3 ("blocks because BP_LEDGER is set")
    # would both have blocked on the ambient marker instead, proving nothing.
    # A test that can pass for the wrong reason is not pinning what it says.
    my $idle_dir = tempdir(CLEANUP => 1);
    my %idle_env = (CCPRAXIS_DRIVE_ACTIVE_DIR => $idle_dir);

    opendir(my $dh, $idle_dir) or die "cannot read constructed idle dir: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    is(scalar(@entries), 0,
       'E0: the constructed drive-active registry is genuinely empty -- guarding this '
     . 'block\'s own premise, so an "allows" result below cannot come from a fixture '
     . 'that quietly had a marker in it');

    my ($rc_bare) = run_guard($cmd, env => \%idle_env);
    is($rc_bare, 2,
       'E1: invoked BARE (ccpraxis .claude/settings.json) it still blocks unconditionally -- '
     . 'the original incident\'s home is unchanged. With no run active, so the block is '
     . 'attributable to the bare invocation and not to an ambient marker');

    my ($rc_scoped_idle) = run_guard($cmd, args => '--only-during-butler-run',
                                           env  => \%idle_env);
    is($rc_scoped_idle, 0,
       'E2: run-scoped with no butler run active, it ALLOWS -- the operator keeps their own '
     . 'tools in their own work, which is the whole reason the flag exists');

    my ($rc_scoped_worker) = run_guard($cmd, args => '--only-during-butler-run',
                                             env  => { %idle_env, BP_LEDGER => 'x' });
    is($rc_scoped_worker, 2,
       'E3: run-scoped inside a butler-launched worker, it BLOCKS -- and with the registry '
     . 'empty, BP_LEDGER is the only thing that can be causing it');

    # And the predicate that covers the case this whole report was about: a
    # drive-solo Task subagent inherits no BP_* at all, so liveness has to be
    # readable from disk rather than from the environment.
    # bp_drive_any_active (lib.sh) is retired; the successor's scope predicate
    # is the run-hook.sh --pre clause "ledger,armed" on the run-scoped
    # registration branch, which run-hook.sh resolves by reading the on-disk
    # armed/<sid> file (never just the environment) -- retargeted per
    # Decision 34 (DEL: bp_drive_any_active has no successor symbol).
    my $src2 = do { local (@ARGV, $/) = ($GUARD); <> };
    like($src2, qr/--pre\s+ledger,armed/,
         'E4: the scope predicate consults the on-disk armed/<session_id> file via '
       . 'run-hook.sh\'s ledger,armed clause, not just the environment -- a Task subagent '
       . 'dispatched by a driver inherits no BP_* but can still be armed on disk, and that '
       . 'subagent is exactly what destroyed the package');
}

done_testing();
