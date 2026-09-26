#!/usr/bin/env perl
# platform: any
# TEST-WRITER ORACLE for blueprint hook-continuity-remake, package
# 35-subagent-git-index-guard. No separate spec file: the ledger's Scope
# and Done criteria
# (.ccpraxis-local-data/blueprints/hook-continuity-remake/packages/
#  35-subagent-git-index-guard.md) plus Decision 117
# (.ccpraxis-local-data/blueprints/hook-continuity-remake/blueprint.md) ARE
# the spec for this file.
#
# Decision 117: for a subagent caller (payload carries agent_id), deny every
# git verb that mutates the index, refs or history, or talks to a remote:
# add, rm, mv, commit, update-index, apply (with --cached or --index),
# merge, rebase, cherry-pick, revert, am, tag, branch (with a mutating
# flag), push, pull, fetch, notes, stash -- plus the pre-existing
# checkout/switch/restore/reset/clean deny, which already applies to
# everyone. Read-only verbs (status, diff, log, show, grep, ls-files,
# rev-parse, hash-object, blame, cat-file, merge-base, describe) stay
# allowed for subagents. A driver payload (no agent_id) is UNCHANGED --
# every verdict below for the driver is the CURRENT code's verdict, recorded
# as-is, not a guess about the fix.
#
# WRITTEN BLIND TO THE IMPLEMENTATION of the subagent deny itself: this file
# never reads GuardGitMutations.pm's source for the new behaviour it is
# specifying. It DOES read the module's source once, at the very end, for
# DC4's static "no new spawn" check -- the same kind of check the existing
# oracle (guards-remake-git-mutations.t SH-2) already performs, reused here
# rather than invented.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

# ---------------------------------------------------------------------------
# payload(%o) -- a Bash tool_input payload. %o: cmd, session_id, agent_id.
# Mirrors guards-remake-git-mutations.t's own builder. Passing agent_id is
# how a subagent caller is distinguished from the driver, per
# BpHook::agent_id($p) (plugins/butler/scripts/BpHook.pm:296) and per how
# GuardBash/WriteGuards/TrackDispatch already detect subagent context
# elsewhere in this codebase: "the payload carries agent_id".
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    my $p = { tool_name => 'Bash', tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    return $p;
}

sub ggm {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardGitMutations', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# assembled per the existing oracle's own idiom (guards-remake-git-mutations.t
# line ~120), so this file's own literal text cannot trip a live copy of the
# guard reading it back as a shell command.
my $V = 'st' . 'ash';

# ===========================================================================
# DC1 -- subagent payload (agent_id set): every Decision-117 mutating verb
# is denied (exit 2, one clear deny line), including through git -C, -c, an
# env-var prefix, &&/; chains and a subshell. git rm --cached and git add -N
# are denied. Read-only verbs stay allowed.
# ===========================================================================

{
    my $sid = 'dc1-sub';
    my $aid = 'a1';

    # -- every listed mutating verb, bare form -------------------------------
    my @mutating = (
        ['git add file.txt'                          => 'add'],
        ['git rm file.txt'                            => 'rm'],
        ['git mv a.txt b.txt'                         => 'mv'],
        ['git commit -m wip'                          => 'commit'],
        ['git update-index --add file.txt'            => 'update-index'],
        ['git apply --cached patch.diff'              => 'apply --cached'],
        ['git apply --index patch.diff'               => 'apply --index'],
        ['git merge other-branch'                     => 'merge'],
        ['git rebase main'                            => 'rebase'],
        ['git cherry-pick abc123'                     => 'cherry-pick'],
        ['git revert abc123'                          => 'revert'],
        ['git am patch.mbox'                          => 'am'],
        ['git tag v1'                                 => 'tag v1 (create; Decision 118: not a listing form)'],
        ['git tag -d v1'                               => 'tag -d v1 (Decision 118: not a listing form)'],
        ['git branch -d old'                          => 'branch -d (mutating flag)'],
        ['git branch -D old'                          => 'branch -D (mutating flag)'],
        ['git branch -m old new'                      => 'branch -m (mutating flag)'],
        ['git push origin main'                       => 'push'],
        ['git pull'                                   => 'pull'],
        ['git fetch'                                  => 'fetch'],
        ['git notes add -m note'                      => 'notes'],
        ["git $V"                                     => 'stash'],
        ['git rm --cached file.txt'                   => 'rm --cached'],
        ['git add -N file.txt'                        => 'add -N'],
    );
    for my $c (@mutating) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, bare '$label' -> deny")
            or diag("cmd: $cmd");
    }

    # -- one clear deny line, and the deny text names the driver as owner ---
    {
        my $res = ggm(payload(cmd => 'git commit -m wip', session_id => $sid, agent_id => $aid));
        is($res->{rc}, 2, 'DC1 setup: subagent git commit denies');
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, 'DC1: subagent deny is at most 2 lines (budget)');
        like($res->{err}, qr/\bdriver\b/i,
             'DC1: the subagent deny text says the driver owns git');
    }

    # -- through git -C <dir> --------------------------------------------------
    for my $c (
        ['git -C /tmp/repo commit -m wip'   => 'commit'],
        ['git -C /tmp/repo push origin main' => 'push'],
        ['git -C /tmp/repo add file.txt'     => 'add'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, git -C <dir> $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- through git -c k=v ------------------------------------------------
    for my $c (
        ['git -c user.name=x commit -m wip'         => 'commit'],
        ['git -c core.pager=cat push origin main'   => 'push'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, git -c k=v $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- through an env-var prefix -------------------------------------------
    for my $c (
        ['GIT_AUTHOR_NAME=x git commit -m wip' => 'commit'],
        ['FOO=bar git push origin main'         => 'push'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, env-prefixed $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- through && / ; chains -----------------------------------------------
    for my $c (
        ['echo hi && git commit -m wip'   => '&& commit'],
        ['echo hi; git push origin main'  => '; push'],
        ['git status && git add file.txt' => 'read-only && mutating (add)'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, chained $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- through a subshell ---------------------------------------------------
    for my $c (
        ['(git commit -m wip)'          => 'commit'],
        ['(cd /tmp && git push origin main)' => 'push'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, subshell $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- read-only verbs stay allowed for a subagent -------------------------
    for my $cmd (
        'git status', 'git diff', 'git log', 'git show HEAD',
        'git grep foo', 'git ls-files', 'git rev-parse HEAD',
        'git hash-object file.txt', 'git blame file.txt',
        'git cat-file -p HEAD', 'git merge-base main HEAD',
        'git describe',
    ) {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1: subagent, read-only '$cmd' -> allow")
            or diag("cmd: $cmd");
    }

    # -- the qualifiers themselves must matter: bare apply differs from its
    # qualified (--cached/--index) forms already exercised above. Coordinator
    # ruling (message during this package's run): plain "git apply" touches
    # only the working tree, so it stays allowed.
    is(ggm(payload(cmd => 'git apply patch.diff', session_id => $sid, agent_id => $aid))->{rc}, 0,
       'DC1: subagent, bare git apply (no --cached/--index) -> allow')
        or diag('cmd: git apply patch.diff');

    # -- git branch, per the coordinator's ruling on Decision 117's
    # "mutating flag" qualifier: no arguments, or only listing options, is
    # read-only (allow); a name argument (ref creation) or a mutating flag
    # (delete/move/copy/force/set-upstream) is denied.
    for my $cmd (
        'git branch', 'git branch -a', 'git branch -r', 'git branch -l',
        'git branch --list', 'git branch -v', 'git branch --show-current',
        'git branch --contains HEAD', 'git branch --merged',
    ) {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1: subagent, git branch listing form '$cmd' -> allow")
            or diag("cmd: $cmd");
    }
    for my $c (
        ['git branch mynew'               => 'branch <name> (ref creation)'],
        ['git branch -d old'               => '-d'],
        ['git branch -D old'               => '-D'],
        ['git branch --delete old'         => '--delete'],
        ['git branch -m old new'           => '-m'],
        ['git branch -M old new'           => '-M'],
        ['git branch --move old new'       => '--move'],
        ['git branch -c old new'           => '-c'],
        ['git branch -C old new'           => '-C'],
        ['git branch --copy old new'       => '--copy'],
        ['git branch -f old'               => '-f'],
        ['git branch --force old'          => '--force'],
        ['git branch -u origin/main'       => '-u/--set-upstream-to'],
        ['git branch --set-upstream-to=origin/main' => '--set-upstream-to'],
        ['git branch --unset-upstream'     => '--unset-upstream'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, git branch mutating form ($label) -> deny")
            or diag("cmd: $cmd");
    }

    # -- the pre-existing everyone-deny (checkout/switch/restore/reset/clean)
    # still applies to a subagent payload too.
    for my $cmd ('git checkout main', 'git switch main', 'git restore .',
                 'git reset --hard', 'git clean -fd') {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1: subagent, pre-existing mutation verb '$cmd' -> deny")
            or diag("cmd: $cmd");
    }

    # -- tag/notes, per Decision 118 (amends 117): allowed ONLY in listing
    # form -- tag bare, tag -l/--list; notes list/show. Every other tag or
    # notes form is denied.
    for my $cmd ('git tag', 'git tag -l', 'git tag --list',
                 'git notes list', 'git notes show') {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1 (Decision 118): subagent, listing form '$cmd' -> allow")
            or diag("cmd: $cmd");
    }
    for my $cmd ('git tag --contains HEAD', 'git notes remove abc123',
                 'git notes edit -m x') {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1 (Decision 118): subagent, non-listing tag/notes form '$cmd' -> deny")
            or diag("cmd: $cmd");
    }

    # -- allowed despite verb-prefix overlap (S1 fix): merge-file, merge-tree,
    # commit-tree write objects/the working file only, never refs or the
    # index; merge-base is read-only.
    for my $cmd ('git merge-file a b c', 'git merge-tree base ours theirs',
                 'git commit-tree HEAD^{tree}', 'git merge-base main HEAD') {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1 (Decision 118): subagent, verb-prefix overlap '$cmd' -> allow")
            or diag("cmd: $cmd");
    }

    # -- every Decision 118 addition, subagent deny -------------------------
    for my $c (
        ['git apply -3 patch.diff'              => 'apply -3'],
        ['git apply --3way patch.diff'          => 'apply --3way'],
        ['git stage file.txt'                   => 'stage (alias of add)'],
        ['git bisect start'                     => 'bisect start'],
        ['git bisect reset'                     => 'bisect reset'],
        ['git bisect good'                      => 'bisect good'],
        ['git bisect bad'                       => 'bisect bad'],
        ['git worktree add ../x'                => 'worktree add'],
        ['git worktree remove x'                => 'worktree remove'],
        ['git worktree move a b'                => 'worktree move'],
        ['git worktree prune'                   => 'worktree prune'],
        ['git worktree lock x'                  => 'worktree lock'],
        ['git worktree unlock x'                => 'worktree unlock'],
        ['git submodule add url path'           => 'submodule add'],
        ['git submodule update'                 => 'submodule update'],
        ['git submodule init'                   => 'submodule init'],
        ['git submodule sync'                   => 'submodule sync'],
        ['git submodule deinit x'               => 'submodule deinit'],
        ['git submodule set-url x url'          => 'submodule set-url'],
        ['git remote add origin url'            => 'remote add'],
        ['git remote remove origin'             => 'remote remove'],
        ['git remote rename a b'                => 'remote rename'],
        ['git remote set-url origin url'        => 'remote set-url'],
        ['git remote set-head origin -a'        => 'remote set-head'],
        ['git remote update'                    => 'remote update'],
        ['git remote prune origin'              => 'remote prune'],
        ['git config user.name x'               => 'config <key> <value> (write)'],
        ['git config --unset user.name'         => 'config --unset'],
        ['git config --unset-all user.name'     => 'config --unset-all'],
        ['git config --add user.name x'         => 'config --add'],
        ['git config --replace-all user.name x' => 'config --replace-all'],
        ['git config --rename-section a b'      => 'config --rename-section'],
        ['git config --remove-section a'        => 'config --remove-section'],
        ['git config -e'                        => 'config -e'],
        ['git config --edit'                    => 'config --edit'],
        ['git read-tree HEAD'                   => 'read-tree'],
        ['git update-ref refs/heads/x HEAD'     => 'update-ref'],
        ['git symbolic-ref -d HEAD'             => 'symbolic-ref -d'],
        ['git symbolic-ref HEAD refs/heads/main' => 'symbolic-ref (two operands, write)'],
        ['git reflog expire --all'              => 'reflog expire'],
        ['git reflog delete refs/stash@{0}'     => 'reflog delete'],
        ['git gc'                                => 'gc'],
        ['git prune'                             => 'prune'],
        ['git repack'                            => 'repack'],
        ['git filter-branch --tree-filter x'    => 'filter-branch'],
        ['git replace abc123 def456'            => 'replace'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1 (Decision 118): subagent, $label -> deny")
            or diag("cmd: $cmd");
    }

    # -- every Decision 118 named read-form exception, subagent allow -------
    for my $c (
        ['git worktree list'                    => 'worktree list'],
        ['git submodule status'                 => 'submodule status'],
        ['git remote'                            => 'remote (bare)'],
        ['git remote -v'                         => 'remote -v'],
        ['git remote show origin'               => 'remote show'],
        ['git remote get-url origin'            => 'remote get-url'],
        ['git config --get user.name'           => 'config --get'],
        ['git config --get-all user.name'       => 'config --get-all'],
        ['git config --list'                    => 'config --list'],
        ['git config -l'                         => 'config -l'],
        ['git config --show-origin --get user.name' => 'config --show-origin'],
        ['git symbolic-ref HEAD'                => 'symbolic-ref (one operand, read)'],
        ['git reflog'                            => 'reflog (bare)'],
        ['git reflog show'                       => 'reflog show'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1 (Decision 118): subagent, read-form exception ($label) -> allow")
            or diag("cmd: $cmd");
    }

    # -- M1 (review): a SECOND git invocation chained after an allowed one is
    # still judged -- not just the leftmost match on the line.
    for my $c (
        ['git branch -a; git branch -m a b'          => 'branch (list) ; branch -m (mutating)'],
        ['git apply --check p && git apply --index p' => 'apply --check (read) && apply --index (mutating)'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 2,
           "DC1 (M1): subagent, chained second invocation ($label) -> deny")
            or diag("cmd: $cmd");
    }

    # -- M2 (review): branch listing forms with a redirect, -vv/--all/etc,
    # --sort=/--format=/--contains=, and --list with a pattern all stay
    # allowed.
    for my $cmd (
        'git branch --show-current 2>/dev/null',
        'git branch -vv',
        'git branch --all',
        'git branch --remotes',
        q{git branch --sort=-committerdate},
        q{git branch --format=%(refname)},
        'git branch --contains=HEAD',
        q{git branch --list 'feat*'},
    ) {
        is(ggm(payload(cmd => $cmd, session_id => $sid, agent_id => $aid))->{rc}, 0,
           "DC1 (M2): subagent, branch listing form '$cmd' -> allow")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# DC2 -- driver payload (no agent_id): every verb behaves EXACTLY as before.
# Every expected value below is the CURRENT (pre-fix) code's real verdict,
# recorded by running it, not guessed: today, GuardGitMutations.pm denies
# only stash and checkout/switch/restore/reset/clean, for every caller, and
# allows everything else -- so a driver payload (agent_id absent) must keep
# getting exactly that split after the fix.
# ===========================================================================
{
    my $sid = 'dc2-driver';

    # -- verbs that deny TODAY, and must still deny (unchanged) --------------
    for my $cmd ("git $V", 'git checkout main', 'git switch main',
                 'git restore .', 'git reset --hard', 'git clean -fd') {
        is(ggm(payload(cmd => $cmd, session_id => $sid))->{rc}, 2,
           "DC2: driver, '$cmd' -> deny (today's verdict, unchanged)")
            or diag("cmd: $cmd");
    }

    # -- every Decision-117 subagent-only verb ALLOWS today for the driver,
    # and must keep allowing (the driver's own behaviour is unchanged) -----
    for my $cmd (
        'git add file.txt', 'git rm file.txt', 'git mv a.txt b.txt',
        'git commit -m wip', 'git update-index --add file.txt',
        'git apply --cached patch.diff', 'git apply --index patch.diff',
        'git merge other-branch', 'git rebase main', 'git cherry-pick abc123',
        'git revert abc123', 'git am patch.mbox', 'git tag', 'git tag v1',
        'git tag -d v1', 'git branch -d old', 'git branch -D old',
        'git branch -m old new', 'git push origin main', 'git pull',
        'git fetch', 'git notes add -m note', 'git rm --cached file.txt',
        'git add -N file.txt', 'git apply patch.diff', 'git branch',
        'git branch -a', 'git branch -r', 'git branch -l', 'git branch --list',
        'git branch -v', 'git branch --show-current', 'git branch --contains HEAD',
        'git branch --merged', 'git branch mynew', 'git branch -d old',
        'git branch -D old', 'git branch --delete old', 'git branch -m old new',
        'git branch -M old new', 'git branch --move old new', 'git branch -c old new',
        'git branch -C old new', 'git branch --copy old new', 'git branch -f old',
        'git branch --force old', 'git branch -u origin/main',
        'git branch --set-upstream-to=origin/main', 'git branch --unset-upstream',
    ) {
        is(ggm(payload(cmd => $cmd, session_id => $sid))->{rc}, 0,
           "DC2: driver, '$cmd' -> allow (today's verdict, unchanged)")
            or diag("cmd: $cmd");
    }

    # -- read-only verbs allow today and must keep allowing -------------------
    for my $cmd ('git status', 'git diff', 'git log', 'git show HEAD') {
        is(ggm(payload(cmd => $cmd, session_id => $sid))->{rc}, 0,
           "DC2: driver, read-only '$cmd' -> allow (today's verdict, unchanged)")
            or diag("cmd: $cmd");
    }

    # -- every Decision-118 addition also ALLOWS today for the driver (the
    # committed HEAD regex, confirmed by "git show HEAD:...", matches only
    # stash and checkout/switch/restore/reset/clean; none of these new verbs
    # or forms are matched by it), and must keep allowing (driver unchanged).
    for my $cmd (
        'git apply -3 patch.diff', 'git apply --3way patch.diff',
        'git stage file.txt', 'git bisect start', 'git bisect reset',
        'git bisect good', 'git bisect bad',
        'git worktree add ../x', 'git worktree remove x', 'git worktree move a b',
        'git worktree prune', 'git worktree lock x', 'git worktree unlock x',
        'git worktree list',
        'git submodule add url path', 'git submodule update', 'git submodule init',
        'git submodule sync', 'git submodule deinit x', 'git submodule set-url x url',
        'git submodule status',
        'git remote add origin url', 'git remote remove origin', 'git remote rename a b',
        'git remote set-url origin url', 'git remote set-head origin -a',
        'git remote update', 'git remote prune origin',
        'git remote', 'git remote -v', 'git remote show origin', 'git remote get-url origin',
        'git config user.name x', 'git config --unset user.name',
        'git config --unset-all user.name', 'git config --add user.name x',
        'git config --replace-all user.name x', 'git config --rename-section a b',
        'git config --remove-section a', 'git config -e', 'git config --edit',
        'git config --get user.name', 'git config --get-all user.name',
        'git config --list', 'git config -l', 'git config --show-origin --get user.name',
        'git read-tree HEAD', 'git update-ref refs/heads/x HEAD',
        'git symbolic-ref -d HEAD', 'git symbolic-ref HEAD refs/heads/main',
        'git symbolic-ref HEAD',
        'git reflog expire --all', 'git reflog delete refs/stash@{0}',
        'git reflog', 'git reflog show',
        'git gc', 'git prune', 'git repack',
        'git filter-branch --tree-filter x', 'git replace abc123 def456',
        'git tag -l', 'git tag --list', 'git tag --contains HEAD',
        'git notes list', 'git notes show', 'git notes remove abc123', 'git notes edit -m x',
        'git merge-file a b c', 'git merge-tree base ours theirs',
        'git commit-tree HEAD^{tree}',
        'git branch -a; git branch -m a b',
        'git apply --check p && git apply --index p',
        'git branch --show-current 2>/dev/null', 'git branch -vv', 'git branch --all',
        'git branch --remotes', 'git branch --sort=-committerdate',
        'git branch --format=%(refname)', 'git branch --contains=HEAD',
        q{git branch --list 'feat*'},
    ) {
        is(ggm(payload(cmd => $cmd, session_id => $sid))->{rc}, 0,
           "DC2 (Decision 118): driver, '$cmd' -> allow (today's committed verdict, unchanged)")
            or diag("cmd: $cmd");
    }

    # -- and the exact deny text for the driver is unchanged too -------------
    my $res = ggm(payload(cmd => 'git checkout main', session_id => $sid));
    is($res->{rc}, 2, 'DC2 setup: driver git checkout main denies');
    is($res->{err},
       "BLOCKED: git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work; change files only via Edit/Write.\nCommand: git checkout main\n",
       'DC2: driver deny text is the pre-existing text, byte for byte, unchanged');
}

# ===========================================================================
# DC4 -- the deny adds no process spawn on the Bash hook path: a static
# source check, the same technique the existing oracle
# (guards-remake-git-mutations.t SH-2) already uses, applied here directly
# since this file's write set is test-only and cannot touch the module.
# ===========================================================================
{
    my $module = "$BUTLER_DIR/scripts/BpHook/Guards/GuardGitMutations.pm";
    ok(-f $module, 'DC4 precondition: GuardGitMutations.pm exists on disk');
  SKIP: {
        skip 'DC4: module missing', 1 unless -f $module;
        open(my $fh, '<:raw', $module) or die "cannot read $module: $!";
        local $/;
        my $src = <$fh>;
        close $fh;
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'DC4: the module source still never spawns a process '
             . '(no system/exec/backtick/qx/pipe-open) after adding the subagent deny');
    }
}

$? = 0;
done_testing();
