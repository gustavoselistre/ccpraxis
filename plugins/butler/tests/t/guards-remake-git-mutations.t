#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 2 (blueprint
# hook-continuity-remake), GG-1..GG-8 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.2/4.3/4.5: the guard-git-mutations
# successor (GuardGitMutations), running on the package-03 hook core.
#
# hooks/next/guards/guard-git-mutations.sh and BpHook/Guards/GuardGitMutations.pm
# DO NOT EXIST YET. Every in-process call goes through GuardHarness::run_module
# (batch 1's harness, plugins/butler/tests/lib/GuardHarness.pm), which mirrors
# BpHook::main()'s own require-and-call contract, so a missing module fails
# open (rc 0) exactly as the real wrapper would -- legibly, never a crash in
# this file. Every [wrapper]/[shim] case spawns the real bash file at that
# path and gets a plain "No such file or directory" until the implementer
# writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text above
# and the CASES (not the source bash) of the six old test files it names --
# never from reading guard-git-mutations.sh itself.
#
# NOT RE-EXPRESSED (per spec sec 4.5 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                   | code
#   ------------------------------------------------------------- | ----
#   git-mutation-guard-reach.t A (hooks.json Bash reach)           | REG
#   git-mutation-guard-reach.t D (ccpraxis .claude/settings.json)  | REG
#   git-mutation-guard-reach.t B (no bp_hook_gate call in source)  | SRC
#   guard-git-mutations-heredoc-strip.t AC1 (header rationale text)| SRC
#   guard-git-mutations-heredoc-strip.t AC2 (bp_strip_shell_noise  | LIB
#     SHA-1 pin against bp-lib.sh, a file this package never edits) |
#   guard-git-mutations-heredoc-strip.t AC4 (git_scan_target's bash| SRC
#     source pinned as a literal substring)                        |
#   guard-git-mutations-heredoc-strip.t AC17 (bp_strip_shell_noise | OTHER
#     unreachable because scripts/bp-lib.sh is missing from a copied |  (Guards::Shell is a
#     hooks/ sibling tree)                                          |   real perl module,
#                                                                    |   always require'd in-
#                                                                    |   process by this
#                                                                    |   harness; there is no
#                                                                    |   "sibling script
#                                                                    |   missing" failure mode
#                                                                    |   to reproduce)
#   guard-git-mutations-quote-mask.t / -heredoc-strip.t / -prose-  | JQ
#     not-invocation.t: no case in any of the three actually reads  |  (n/a; noted for
#     jq -- nothing to exclude on that code, listed for completeness)|  completeness only)
#   hook-payload-read-bound.t (bp_read_payload bound)              | LIB
#   read-payload-idempotent.t (bp_read_payload re-entrancy)        | LIB
#
# GG-1's corpus below is deliberately EXHAUSTIVE of every case (not a sample)
# in git-mutation-guard-reach.t section C, guard-git-mutations-quote-mask.t,
# guard-git-mutations-heredoc-strip.t (minus AC1/AC2/AC4/AC17 above) and
# guard-prose-not-invocation.t, run in BARE mode (no --only-during-butler-run,
# unarmed, BP_LEDGER unset) -- exactly the scope the bare registration serves
# today, per spec sec 3.2's "the bare registration applies to everyone
# (unchanged)".
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Spec ();
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front. R9-RM4 (review M4):
# GuardHarness.pm itself now isolates the environment unconditionally at
# "use GuardHarness;" above (deletes BP_*/CCPRAXIS_*/CLAUDE_*, deletes any
# inherited BUTLER_STATE_DIR, pins a decoy HOME/USERPROFILE), so this block
# is redundant, not load-bearing. The PRIOR claim here that "every
# individual block wraps its own env changes in local %ENV = %ENV" was
# false (no such wrap exists anywhere in this file) and is removed.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Bash tool_input payload. %o: cmd, session_id, agent_id,
# transcript_path, cwd. Mirrors guards-remake-bash.t's own builder.
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    my $p = { tool_name => 'Bash', tool_input => $ti };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    $p->{cwd}              = $o{cwd}              if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# ggm($payload, %opts) -- GuardHarness::run_module for Guards::GuardGitMutations.
# %opts: env => {}, args => [] (e.g. ['--only-during-butler-run']).
# ---------------------------------------------------------------------------
sub ggm {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardGitMutations', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# assembled, per git-mutation-guard-reach.t:100's own idiom, so this file's
# own literal text cannot trip a live copy of the guard reading it back as a
# shell command.
my $V = 'st' . 'ash';

# ===========================================================================
# SH-1/SH-2 -- static shape.
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/next/guards/guard-git-mutations.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/GuardGitMutations.pm";
    ok(-f $wrapper, 'SH-1 precondition: guard-git-mutations.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 3 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on guard-git-mutations.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::GuardGitMutations/,
             'SH-1: the wrapper names the Guards::GuardGitMutations module');
        # This successor has TWO registrations (spec sec 3.2/4.5): a bare one
        # that always applies, and one gated by --only-during-butler-run. GG-6
        # and GG-7 below pin the OBSERVABLE two-registration contract (0 perl
        # launches on the not-applies shape of each) end to end; this check
        # only requires that the wrapper's own source recognises the flag at
        # all, since a wrapper that never mentions it could not branch on it.
        like($src, qr/--only-during-butler-run/,
             'SH-1: the wrapper source recognises the --only-during-butler-run flag');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/GuardGitMutations.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on GuardGitMutations.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# GG-1 -- every command in the three strip/mask files and
# git-mutation-guard-reach.t section C yields its old verdict, run BARE (no
# --only-during-butler-run flag, unarmed, BP_LEDGER unset -- the scope the
# bare registration serves unconditionally).
# ===========================================================================
{
    my $pad = 'echo "' . ('x' x 8200) . '" && git ' . $V;

    my @corpus = (
        # -- git-mutation-guard-reach.t section C -----------------------------
        ["git $V",                                2, 'reach C: bare stash mutation'],
        ["(git $V push -m wip)",                   2, 'reach C: subshell command position'],
        ["x=1; {git $V push -m wip; }",             2, 'reach C: brace-group command position'],
        ['git status',                              0, 'reach C: read-only status'],
        ['git diff',                                 0, 'reach C: read-only diff'],
        ["git $V list",                             0, 'reach C: stash list'],

        # -- guard-git-mutations-quote-mask.t ---------------------------------
        [q{perl bp-blueprint.pl add-decision --file f --id 20 --text "a prohibited git stash destroyed a completed fix-batch"},
                                                      0, 'quote-mask AC-16: --text merely quoting "git stash" in prose'],
        [q{git commit -m "stop reaching for git stash"},
                                                      0, 'quote-mask AC-16 sibling: commit message mentions git stash'],
        [q{git commit -F -},                         0, 'quote-mask AC-19: git commit -F -'],
        [q{git diff},                                0, 'quote-mask AC-19: git diff'],
        [q{git status},                              0, 'quote-mask AC-19: git status'],
        [q{git stash list},                          0, 'quote-mask AC-19: git stash list'],
        [q{git stash show},                          0, 'quote-mask AC-19: git stash show'],
        [q{git stash},                                2, 'quote-mask AC-17: git stash'],
        [q{git stash push -u},                       2, 'quote-mask AC-17: git stash push -u'],
        [q{foo && git stash},                        2, 'quote-mask AC-17: foo && git stash'],
        [q{git checkout main},                       2, 'quote-mask AC-17: git checkout main'],
        [q{git reset --hard},                        2, 'quote-mask AC-17: git reset --hard'],
        [q{git clean -fd},                           2, 'quote-mask AC-17: git clean -fd'],
        [q{git restore .},                           2, 'quote-mask AC-17: git restore .'],
        [q{git switch -c x},                         2, 'quote-mask AC-17: git switch -c x'],
        [q{bash -c "git stash"},                     2, 'quote-mask AC-18: bash -c "git stash" (shell in command position)'],
        [q{sh -c 'git reset --hard'},                2, q{quote-mask AC-18: sh -c 'git reset --hard' (shell in command position)}],
        ['echo `git stash`',                          2, 'quote-mask AC-18: unquoted backtick body naming "git stash"'],
        ['echo $(git reset --hard)',                  2, 'quote-mask AC-18: unquoted $(...) body naming "git reset --hard"'],
        [q{git stash "},                              2, 'quote-mask AC-20: unbalanced quoting containing a real mutation'],
        [$pad,                                        2, 'quote-mask AC-20: >8192-character command containing a real mutation'],
        [qq{# don't panic\ngit $V\n# that's it},       2, 'quote-mask ORACLE-GAP: apostrophe-comment / stash'],
        [qq{# it's a checkpoint\ngit checkout -- .\n# we're done},
                                                       2, 'quote-mask ORACLE-GAP: apostrophe-comment / checkout'],
        [qq{# we'll reset later\ngit reset --hard HEAD\n# don't repeat},
                                                       2, 'quote-mask ORACLE-GAP: apostrophe-comment / reset'],
        [qq{# don't wait\ngit clean -fd\n# that's it}, 2, 'quote-mask ORACLE-GAP: apostrophe-comment / clean'],
        [qq{cat <<EOF > n.md\nit's fine\nEOF\ngit $V\ncat <<EOF >> n.md\nthat's all\nEOF},
                                                       2, 'quote-mask ORACLE-GAP: heredoc-wrapped apostrophes'],
        [q{echo don\'t ; git stash ; echo ok\'},      2, q{quote-mask ORACLE-GAP: backslash-escaped single-quote around stash}],
        [q{: \" ; git clean -fd ; : \"},              2, 'quote-mask ORACLE-GAP: backslash-escaped double-quote around clean'],
        [q{echo $'\'' ; git stash ; echo $'\''},      2, q{quote-mask ORACLE-GAP: ANSI-C $'...' quoting around stash}],
        [q{git commit -m "a\"b" && git stash && echo "z\"w"},
                                                       2, 'quote-mask ORACLE-GAP(reviewer B1): escaped-quote / stash / escaped-quote chain'],
        [q{git commit -F -},                          0, 'quote-mask ORACLE-GAP control: plain git commit -F -'],
        [qq{git add plugins/butler/tests/t/guards-remake-git-mutations-corpus.t\ngit commit -m "add oracle-gap coverage for BLOCKER-1"},
                                                       0, 'quote-mask ORACLE-GAP control: legitimate multi-line add+commit'],
        [q{perl bp-blueprint.pl add-decision --file f --id 21 --text "never run git stash on a dirty tree"},
                                                       0, 'quote-mask ORACLE-GAP control: prose-only mention of a prohibited verb'],
        [q{git stash list},                            0, 'quote-mask ORACLE-GAP control: explicitly-allowed read-only "git stash list"'],
        [q{git 'stash'},                                2, 'quote-mask AC-33: quoted single-word subcommand, plain'],
        [q{git "stash"},                                2, 'quote-mask AC-33: quoted single-word subcommand, double-quoted'],
        [q{git 'reset' --hard},                         2, 'quote-mask AC-33: quoted single-word subcommand with trailing flag'],
        [q{git "checkout" main},                        2, 'quote-mask AC-33: quoted single-word subcommand, double-quoted, with arg'],
        [q{foo && git 'stash'},                         2, 'quote-mask AC-33: quoted single-word subcommand after &&'],
        [q{perl bp-blueprint.pl add-decision --file f --id 22 --text "stash"},
                                                        0, 'quote-mask AC-33 control: non-verb-adjacent quoted mention'],
        [q{echo "stash" "reset"},                       0, 'quote-mask AC-33 control: prints the words, never invokes git'],
        [q{'git' stash},                                0, q{quote-mask AC-33 control: 'git' itself quoted}],
        [q{"git" stash},                                0, q{quote-mask AC-33 control: "git" itself quoted}],
        [q{echo 'git' 'stash'},                         0, q{quote-mask AC-33 control: echo 'git' 'stash' merely prints the words}],
        ['',                                            0, 'quote-mask AC-32 companion: empty tool_input.command'],

        # -- guard-git-mutations-heredoc-strip.t (AC1/AC2/AC4/AC17 excluded) --
        [qq{cat <<EOF > report.md\n... this describes why git stash is forbidden and git reset --hard destroyed a fix-batch ...\nEOF\nperl file-report.pl report.md},
                                                        0, 'heredoc-strip AC12: heredoc body merely mentioning forbidden verbs, no git invocation'],
        [qq{git stash ; cat <<EOF\nfoo\nEOF},           2, 'heredoc-strip AC13: real "git stash" with an unrelated heredoc elsewhere'],
        [qq{echo \$(git reset --hard) ; cat <<EOF\nfoo\nEOF},
                                                        2, 'heredoc-strip AC16: bare $(...) carrier AND a heredoc marker together'],
        [q{bash -c "git stash"},                        2, 'heredoc-strip AC15 (regression re-pin): bash -c "git stash"'],
        [q{sh -c 'git reset --hard'},                   2, q{heredoc-strip AC15 (regression re-pin): sh -c 'git reset --hard'}],
        ['echo `git stash`',                             2, 'heredoc-strip AC15 (regression re-pin): echo `git stash`'],
        ['echo $(git reset --hard)',                     2, 'heredoc-strip AC15 (regression re-pin): echo $(git reset --hard)'],
        ['',                                             0, 'heredoc-strip companion: empty tool_input.command'],

        # -- guard-prose-not-invocation.t --------------------------------------
        ['perl bp-blueprint.pl add-decision --file f --id 20 \\' . "\n"
            . '  --text "the first line of a report about the guard' . "\n"
            . "names git $V in prose here\"",
                                                         0, 'prose AC-1: continuation-bearing --text prose naming the mutation'],
        [qq{cat > report.md <<'PLAINDELIM'\n## Summary\nmentions git $V here in prose\n## Severity\nminor, no working tree changes\nPLAINDELIM},
                                                         0, 'prose AC-2: single-quoted heredoc delimiter, "#"-bearing, prose mention'],
        [qq{cat > report.md <<"PLAINDELIM"\n## Summary\nmentions git $V here in prose\n## Severity\nminor, no working tree changes\nPLAINDELIM},
                                                         0, 'prose AC-3: double-quoted heredoc delimiter, "#"-bearing, prose mention'],
        [qq{git commit -m "a\\"b" && git $V && echo "z\\"w"},
                                                         2, 'prose AC-4: escaped-double-quote / mutation / escaped-double-quote chain'],
        [qq{echo don\\'t ; git $V ; echo ok\\'},        2, 'prose AC-5: escaped-single-quote around the mutation'],
        [qq{echo \$'\\'' ; git $V ; echo \$'\\''},      2, q{prose AC-6: ANSI-C $'...' quoting around the mutation}],
        [qq{# don't panic\ngit $V\n# that's it},         2, 'prose AC-7: apostrophe-bearing comments around the mutation'],
        [qq{cat <<EOF > n.md\nit's fine\nEOF\ngit $V\ncat <<EOF >> n.md\nthat's all\nEOF},
                                                         2, 'prose AC-8: apostrophes in two unquoted-delimiter heredoc bodies'],
        [qq{cat <<'EOF' > n.md\nit's fine\nEOF\n# don't\ngit $V\ncat <<'EOF' >> n.md\nthat's all\nEOF},
                                                         2, 'prose AC-9: N2-admitted quoted-delimiter heredocs plus an apostrophe comment'],
        [qq{cat > f <<'EOF!'\ntext\nEOF!\ngit $V},        2, 'prose AC-10: odd-punctuation heredoc delimiter'],
        [qq{cat > f <<'EOF!'\ntext #x\nEOF!\ngit $V},     2, 'prose AC-11: odd-punctuation heredoc delimiter with a # inside'],
        [qq{cat > f <<'EOF!'\r\ntext\r\nEOF!\r\ngit $V},  2, 'prose AC-12: CRLF line endings in a heredoc command'],
        [qq{cat > f <<'EOF!'\r\ntext #x\r\nEOF!\r\ngit $V},
                                                         2, 'prose AC-13: CRLF heredoc with a # inside'],
        [qq{cat <<'EOF' ;#x\nit's fine\nEOF\ngit $V},     2, 'prose AC-14: a comment desyncing the heredoc start'],
        [qq{cat <<'EOF' "a\nb" #x\nEOF\ngit $V},          2, 'prose AC-15: a delayed heredoc-start desync past the terminator'],
        [qq{cat <<EOF\n## \$(git $V)\nEOF},                2, 'prose AC-16: unquoted heredoc delimiter with a live $(...) mutation'],
        [qq{cat <<<"# git $V"},                           2, 'prose AC-17: a herestring naming the mutation'],
        [qq{echo foo\\nbar && git $V},                    2, 'prose AC-18: a non-continuation backslash (literal \\n, two characters)'],
        [qq{echo foo#bar && git $V},                      2, 'prose AC-19: a # with no heredoc marker at all'],
        ['perl x.pl --id 20 \\' . "\n" . "  --text \"prose naming git $V\" && git $V",
                                                          2, 'prose AC-20: continuation-bearing command that also invokes a real mutation'],
        ['foo \\' . "\n" . "  && git '" . $V . "'",       2, 'prose AC-21: quoted single-word verb-adjacent mutation survives N1 admission'],
        [qq{cat > f <<'EOF'\n## heading\nEOF\ngit $V},     2, 'prose AC-22: quoted-delimiter heredoc, real mutation after the terminator'],
        ['bash -c \\' . "\n" . '  "git ' . $V . '"',       2, 'prose AC-23: bash -c wrapper with a continuation added'],
        [qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\ngit $V},
                                                          2, 'prose fx_A: quoted heredoc delimiter with an embedded space, trailing real mutation'],
        [qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\n\$(git $V)},
                                                          2, 'prose fx_N: same shape, $(...)-carried trailing mutation'],
        [qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\n# note\ngit $V},
                                                          2, 'prose gx_C1: embedded-space delimiter plus a real comment before the mutation'],
        [qq{ev\\\nal " git $V"},                          2, 'prose sx_S1: line-continuation-split "eval" wrapping the mutation'],
        [qq{xarg\\\ns -I{} " git $V"},                    2, 'prose sx_S3: line-continuation-split "xargs" wrapping the mutation'],
    );
    is(scalar(@corpus), 87, 'GG-1 setup: the mined corpus has exactly the expected number of cases');   # shape-lint: intentional -- counts a corpus THIS test builds a few lines above, asserted so the loop that follows can never pass vacuously over an empty list; not the shape of a shared artifact.
    for my $c (@corpus) {
        my ($cmd, $rc, $label) = @$c;
        my $res = ggm(payload(cmd => $cmd));
        is($res->{rc}, $rc, "GG-1: $label") or diag("cmd: " . (defined $cmd ? $cmd : '<undef>'));
    }
}

# ===========================================================================
# GG-2 -- deny lines are exactly 3.2's two texts plus "Command: <cmd>".
# ===========================================================================
{
    my $res_stash = ggm(payload(cmd => 'git stash'));
    is($res_stash->{rc}, 2, 'GG-2 setup: git stash denies');
    is($res_stash->{err},
       "BLOCKED: git stash is forbidden: it silently removes uncommitted work; use 'git diff' to inspect ('git stash list/show' are allowed).\nCommand: git stash\n",
       'GG-2: the exact git-stash deny text and "Command: <cmd>" line');

    my $res_mutation = ggm(payload(cmd => 'git checkout main'));
    is($res_mutation->{rc}, 2, 'GG-2 setup: git checkout main denies');
    is($res_mutation->{err},
       "BLOCKED: git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work; change files only via Edit/Write.\nCommand: git checkout main\n",
       'GG-2: the exact mutation-verb deny text and "Command: <cmd>" line');
}

# ===========================================================================
# GG-3 -- bare args deny in an unarmed session with BP_LEDGER unset.
# ===========================================================================
{
    my $res = ggm(payload(cmd => 'git checkout main', session_id => 'gg3-unarmed'));
    is($res->{rc}, 2, 'GG-3: bare invocation denies in an unarmed session with BP_LEDGER unset');
}

# ===========================================================================
# GG-4 -- --only-during-butler-run: the four populations.
# ===========================================================================
{
    my $flag = ['--only-during-butler-run'];

    is(ggm(payload(cmd => 'git stash', session_id => 'gg4-unarmed'), args => $flag)->{rc}, 0,
       'GG-4: flagged, unarmed, BP_LEDGER unset -> allow');

    is(ggm(payload(cmd => 'git stash', session_id => 'gg4-ledger'), args => $flag,
           env => { BP_LEDGER => '/x/ledger.md' })->{rc}, 2,
       'GG-4: flagged, BP_LEDGER set -> deny');

    my $base = GuardHarness::fresh_state();
    my $sid  = 'gg4-armed';
    ok(GuardHarness::arm($sid, 'manual'), 'GG-4 setup: session armed (role manual, as continuity on writes)');
    is(ggm(payload(cmd => 'git stash', session_id => $sid), args => $flag)->{rc}, 2,
       'GG-4: flagged, session armed (manual role) -> deny');

    is(ggm(payload(cmd => 'git stash', session_id => $sid, agent_id => 'a1'), args => $flag)->{rc}, 2,
       'GG-4: flagged, a subagent payload (agent_id set) in that armed session -> deny');
}

# ===========================================================================
# GG-5 -- Decision 3: session isolation. With the flag, session B armed and
# session A unarmed -> A allows.
# ===========================================================================
{
    my $base = GuardHarness::fresh_state();
    my $sidA = 'gg5-a';
    my $sidB = 'gg5-b';
    ok(GuardHarness::arm($sidB, 'manual'), 'GG-5 setup: session B armed');

    is(ggm(payload(cmd => 'git stash', session_id => $sidA), args => ['--only-during-butler-run'])->{rc}, 0,
       "GG-5: session A (never armed) allows despite session B being armed -- another session's arm state never crosses");
}

# ===========================================================================
# GG-6 [wrapper] -- with the flag, an unarmed session (BP_LEDGER unset) exits
# in bash (0 perl, SH-3); without the flag the same payload reaches perl and
# denies (SH-4).
# ===========================================================================
{
    my $sid = 'gg6-unarmed';
    my $res_flagged = GuardHarness::run_shim('guard-git-mutations.sh',
        payload(cmd => 'git stash', session_id => $sid), args => ['--only-during-butler-run']);
    is($res_flagged->{rc}, 0, 'GG-6/SH-3: flagged, unarmed, no ledger -> exit 0');
    is($res_flagged->{out}, '', 'GG-6/SH-3: empty stdout');
    is($res_flagged->{err}, '', 'GG-6/SH-3: empty stderr');
    is(GuardHarness::count_lines($res_flagged->{shim_log}, 'perl'), 0,
       'GG-6/SH-3: 0 perl launches (the wrapper exits in bash before ever reaching perl)');

    my $res_bare = GuardHarness::run_shim('guard-git-mutations.sh',
        payload(cmd => 'git stash', session_id => $sid), args => []);
    is($res_bare->{rc}, 2, 'GG-6/SH-4: the identical payload without the flag reaches perl and denies');
    is(GuardHarness::count_lines($res_bare->{shim_log}, 'perl'), 1,
       'GG-6/SH-4: exactly 1 perl launch');
}

# ===========================================================================
# GG-7 [wrapper] -- a payload without the substring "git" exits in bash
# (0 perl, SH-3), bare mode.
# ===========================================================================
{
    my $res = GuardHarness::run_shim('guard-git-mutations.sh',
        payload(cmd => 'ls -la', session_id => 'gg7-sid'), args => []);
    is($res->{rc}, 0, 'GG-7/SH-3: a payload without the substring "git" -> exit 0');
    is($res->{out}, '', 'GG-7/SH-3: empty stdout');
    is($res->{err}, '', 'GG-7/SH-3: empty stderr');
    is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0,
       'GG-7/SH-3: 0 perl launches');
    is(GuardHarness::count_lines($res->{shim_log}, 'jq'), 0,
       'GG-7/SH-3: 0 jq launches');
}

# ===========================================================================
# GG-8 -- the remaining shared ACs (SH-3/SH-4's process-budget halves are
# already pinned end to end by GG-6 and GG-7 above, for both registrations).
# ===========================================================================

# SH-5 -- run() leaves BpHook::parse_count() unchanged, deny and allow.
{
    my $res_deny  = ggm(payload(cmd => 'git checkout main'));
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
    my $res_allow = ggm(payload(cmd => 'git diff'));
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- budget (2 lines) and forbidden vocabulary on every deny collected.
{
    my @denies = (
        ggm(payload(cmd => 'git stash')),
        ggm(payload(cmd => 'git checkout main')),
        ggm(payload(cmd => 'git reset --hard')),
        ggm(payload(cmd => 'git clean -fd')),
    );
    is(scalar(@denies), 4, 'SH-6 setup: four deny fixtures collected');
    for my $i (0 .. $#denies) {
        my $res = $denies[$i];
        is($res->{rc}, 2, "SH-6: fixture $i is really a deny") or next;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, "SH-6: fixture $i has at most the guard-git-mutations budget of 2 lines");
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, "SH-6: fixture $i line length <= 160");
            unlike($l, qr/\.run-finished|stop-ok|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   "SH-6: fixture $i line names no retired mechanism");
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i,
                   "SH-6: fixture $i line names no disable-a-guard hatch");
        }
        is($res->{out}, '', "SH-6: fixture $i stdout is empty");
    }
}

# SH-7 -- bad JSON, truncated payload, {} -> exit 0, no output.
{
    for my $c (
        ['not json at all'                          => 'malformed JSON'],
        ['{"tool_input":{"command":"git checkout'    => 'truncated JSON'],
        ['{}'                                        => 'empty object'],
    ) {
        my ($raw, $label) = @$c;
        my %e = ($label eq 'truncated JSON') ? (BP_PAYLOAD_TRUNCATED => 1) : ();
        my $res = ggm($raw, env => \%e);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a real
# EXISTING successor (stop-gate.sh, package 06), not GuardGitMutations. Proves
# a red result above is guard-git-mutations's absence, not a harness defect.
# Repeats batch 1's own self-check independently, since this file must stand
# on its own when the runner parallelises files.
# ===========================================================================
{
    my $stopgate = "$BUTLER_DIR/hooks/next/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_wrapper = GuardHarness::run_wrapper($stopgate,
        { session_id => 'ggselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_wrapper->{rc}, 0, 'self-check: run_wrapper against the real stop-gate.sh (unarmed) allows');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'ggselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('ggselfcheck-3', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'ggselfcheck-3', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1,
       'self-check: ...with exactly 1 perl launch');

    ok(GuardHarness::arm('ggselfcheck-run-module-armed', 'manual'),
       'self-check/run_module setup: a distinct session armed');
    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'ggselfcheck-run-module-armed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its '
     . 'run(), rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'ggselfcheck-run-module-unarmed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and '
     . 'never-armed session -> allows');
}

# ===========================================================================
# R9 -- regression round (review.md/redteam.md, fix-batch-first). Every
# assertion below is a NEW regression against the CURRENT implementation;
# see the per-id comment for what it targets. GG-1's own $V trick (assembled
# so this file's own literal text cannot trip a live copy of the guard) is
# reused throughout.
# ===========================================================================

# ---------------------------------------------------------------------------
# R9-TH2 (redteam H2): "git -C <dir> <verb>" and "git -c k=v <verb>" get
# past the mutation-verb regex, whose flag group only allows flag tokens
# that begin with "-" -- the ARGUMENT of -C/-c does not.
# ---------------------------------------------------------------------------
{
    my $R = 'rese' . 't';
    for my $c (
        ["git -C /c/x checkout -- f.txt" => 'git -C <dir> checkout'],
        ["git -c core.x=y $R --hard"     => 'git -c k=v reset --hard'],
        ["git -C x $V"                   => 'git -C <dir> stash'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd))->{rc}, 2, "R9-TH2: $label -> deny") or diag("cmd: $cmd");
    }
    is(ggm(payload(cmd => 'git -C /c/x status'))->{rc}, 0, 'R9-TH2: git -C <dir> status (read-only) -> allow');
}

# ---------------------------------------------------------------------------
# R9-TM2 (redteam M2): bash -lc/eval/heredoc-into-a-shell hiding a covered
# mutation verb. NOTE: this module's SHELLWORD_WORD_RE already matches a
# bare "bash"/"eval" WORD (not a "-c" flag at all) in command position, so
# these three forms already deny here today -- re-pinned as a regression
# guard so a future change cannot silently regress them, not because they
# are currently broken (see the handback report: these are GREEN now).
# ---------------------------------------------------------------------------
{
    my $R = 'rese' . 't';
    for my $c (
        ["bash -lc 'git $R --hard'"          => q{bash -lc 'git reset --hard'}],
        ["eval 'git checkout main'"           => q{eval 'git checkout main'}],
        ["bash <<'HD'\ngit $R --hard\nHD"     => 'heredoc fed to bash containing git reset --hard'],
    ) {
        my ($cmd, $label) = @$c;
        is(ggm(payload(cmd => $cmd))->{rc}, 2, "R9-TM2: $label -> deny") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# R9-TM3 (redteam M3): the stash list/show exemption is checked against the
# WHOLE scan, not the matched occurrence, so "look, then pop" passes.
# ---------------------------------------------------------------------------
{
    is(ggm(payload(cmd => "git $V list && git $V pop"))->{rc}, 2,
       'R9-TM3: git stash list && git stash pop -> deny (the pop is a real mutation)');
    is(ggm(payload(cmd => "git $V show; git $V drop"))->{rc}, 2,
       'R9-TM3: git stash show; git stash drop -> deny');
}

# ---------------------------------------------------------------------------
# R9-TM8: two ALLOW shapes the driver reproduced live against the old hook,
# re-pinned as a regression guard (both are GREEN now -- see the handback
# report):
#   - "git commit -F - <<'EOF'" whose heredoc BODY merely mentions a
#     destructive verb in prose (no live carrier reaching the scan).
#   - a double-quoted --text argument mentioning a destructive verb, with
#     no shell carrier and no real git invocation.
# ---------------------------------------------------------------------------
{
    my $R = 'rese' . 't';
    my $body = "this mentions git $R --hard in a commit body";
    my $cmd1 = "git commit -F - <<'HD'\n$body\nHD";
    is(ggm(payload(cmd => $cmd1))->{rc}, 0,
       q{R9-TM8: git commit -F - <<'EOF' with a body mentioning a destructive verb -> allow});

    my $cmd2 = qq{perl bp-ledger.pl append-attempt --text "never run git $R --hard on a dirty tree"};
    is(ggm(payload(cmd => $cmd2))->{rc}, 0,
       'R9-TM8: a double-quoted --text argument mentioning a destructive verb -> allow');
}

$? = 0;
done_testing();
