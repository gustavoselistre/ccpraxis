#!/usr/bin/env perl
# platform: any
# Oracle for package 09-guard-prose-false-positive
# (blueprint butler-gate-ergonomics), spec
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/09-guard-prose-false-positive-spec.md
#
# guard-git-mutations.sh's case-0 raw escalation (:176-182 on the tree this
# spec was authored against) denies ANY command containing a backslash or a
# '#' ANYWHERE, regardless of whether it sits inside a quoted mention or a
# heredoc body that merely NAMES a forbidden verb in prose. Bug
# 20260916-200412-3dd6: the guard blocked a bug report ABOUT itself, twice in
# five minutes -- a '\' line continuation in a bp-blueprint.pl --text call,
# and a heredoc report whose every markdown '##' heading is a '#'.
#
# WRITTEN BLIND TO THE FIX (spec §2.1/§2.4, unimplemented as of this write).
# Group A (AC-1/2/3) is the fix itself and is EXPECTED TO FAIL against the
# unmodified hook -- both live reproductions are wrongly DENIED today; this
# file asserts they must be ALLOWED. Every other group pins behaviour the
# UNMODIFIED hook already gets right (today, ANY backslash or '#' anywhere
# forces the raw fallback, so these already deny, trivially) and it MUST KEEP
# denying once the narrow relaxation (N1/N2, guards G1/G2) lands -- three
# prior fix attempts each regressed exactly one of these shapes, which is why
# groups B..E exist and are exactly as important as group A.
#
# Harness mirrors guard-git-mutations-quote-mask.t:29-53 (payload-file +
# bash -c invocation, every ambient BP_* stripped, bare invocation with no
# --only-during-butler-run) per spec §4's harness contract. The stash verb is
# assembled as git-mutation-guard-reach.t:100 does, so this file's own text
# cannot trip the guard when some other tool reads it back as a shell command.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-git-mutations.sh";

ok(-f $GUARD, 'guard-git-mutations.sh is present') or BAIL_OUT('no guard');

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# Strip ALL ambient BP_* -- this test may itself run inside a coordinator/judge
# session that exports them, and the guard is deliberately ungated.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard {
    my ($cmd) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, GPATH => fwd($GUARD), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

sub deny_ok {
    my ($cmd, $name) = @_;
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, $name) or diag("hook output: $out\ncommand was:\n$cmd");
}
sub allow_ok {
    my ($cmd, $name) = @_;
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, $name) or diag("hook output: $out\ncommand was:\n$cmd");
}
sub bscount { my $c = () = $_[0] =~ /\\/g; return $c; }

my $V = 'st' . 'ash';   # assembled per spec §4 harness contract / reach.t:100

# ===========================================================================
# Group A — the fix itself (-> C1). EXPECTED TO FAIL against the unmodified
# hook: both live reproductions are wrongly DENIED today.
# ===========================================================================

# AC-1: live reproduction 1, verbatim in shape -- a backslash-newline
# continuation, continued onto a --text argument whose double-quoted value
# spans two lines and names "git $V" in prose.
{
    my $cmd = 'perl bp-blueprint.pl add-decision --file f --id 20 \\' . "\n"
            . '  --text "the first line of a report about the guard' . "\n"
            . 'names git ' . $V . ' in prose here"';
    like($cmd, qr/\\\n/, 'AC-1 premise (AC-28): a backslash is immediately followed by a newline');
    is(bscount($cmd), 1, 'AC-1 premise (AC-28): no other backslash in the command');
    allow_ok($cmd, "AC-1: live reproduction 1 (continuation-bearing --text prose naming git $V) is ALLOWED");
}

# AC-2: live reproduction 2, verbatim in shape -- a '#'-bearing command whose
# heredoc delimiter is SINGLE-quoted, body names "git $V" in a markdown '##'
# heading. Body has no backslash, no '<<', no '$(', no backtick, no line
# equal to the delimiter, LF-only line endings, no real bash comment.
my $delim = 'PLAINDELIM';
{
    my $cmd = "cat > report.md <<'$delim'" . "\n"
            . '## Summary' . "\n"
            . 'mentions git ' . $V . ' here in prose' . "\n"
            . '## Severity' . "\n"
            . 'minor, no working tree changes' . "\n"
            . $delim;
    like($cmd, qr/#/, 'AC-2 premise (AC-28): the command contains a #');
    like($cmd, qr/<<'\Q$delim\E'/, 'AC-2 premise (AC-28): the heredoc delimiter is single-quoted');
    unlike($cmd, qr/\\/, 'AC-2 premise (AC-28): the command contains no backslash');
    allow_ok($cmd, "AC-2: live reproduction 2, single-quoted heredoc delimiter, body naming git $V is ALLOWED");
}

# AC-3: AC-2 with a DOUBLE-quoted delimiter instead.
{
    my $cmd = qq{cat > report.md <<"$delim"} . "\n"
            . '## Summary' . "\n"
            . 'mentions git ' . $V . ' here in prose' . "\n"
            . '## Severity' . "\n"
            . 'minor, no working tree changes' . "\n"
            . $delim;
    like($cmd, qr/#/, 'AC-3 premise (AC-28): the command contains a #');
    like($cmd, qr/<<"\Q$delim\E"/, 'AC-3 premise (AC-28): the heredoc delimiter is double-quoted');
    unlike($cmd, qr/\\/, 'AC-3 premise (AC-28): the command contains no backslash');
    allow_ok($cmd, "AC-3: AC-2 with a double-quoted heredoc delimiter is ALLOWED");
}

# ===========================================================================
# Group B — the three masking shapes still DENY (-> C3). Re-derived from the
# hook header at :136-147, not from any summary of it.
# ===========================================================================

# AC-4: failure mode 1, escaped double quote. Trailing clause is load-bearing.
{
    my $cmd = 'git commit -m "a\\"b" && git ' . $V . ' && echo "z\\"w"';
    deny_ok($cmd, 'AC-4: escaped-double-quote / mutation / escaped-double-quote chain is DENIED');
}

# AC-5: failure mode 1, escaped single quote.
{
    my $cmd = 'echo don\\\'t ; git ' . $V . ' ; echo ok\\\'';
    deny_ok($cmd, 'AC-5: escaped-single-quote around the mutation is DENIED');
}

# AC-6: failure mode 1, ANSI-C $'...'. The sharpest case: bp_strip_shell_noise
# does NOT model $'...' and would blank the real mutation.
{
    my $cmd = qq{echo \$'\\'' ; git $V ; echo \$'\\''};
    deny_ok($cmd, 'AC-6: ANSI-C $\'...\' quoting around the mutation is DENIED');
}

# AC-7: failure mode 2, comment with apostrophes.
{
    my $cmd = qq{# don't panic\ngit $V\n# that's it};
    deny_ok($cmd, 'AC-7: apostrophe-bearing comments around the mutation are DENIED');
}

# AC-8: failure mode 3, apostrophes in two heredoc bodies around an unquoted
# mutation (no '#' anywhere -- reaches today's existing heredoc branch).
{
    my $cmd = qq{cat <<EOF > n.md\nit's fine\nEOF\ngit $V\ncat <<EOF >> n.md\nthat's all\nEOF};
    deny_ok($cmd, 'AC-8: apostrophes in two unquoted-delimiter heredoc bodies around the mutation are DENIED');
}

# AC-9: failure modes 2 and 3 composed, newly admitted by N2 -- delimiters
# quoted and a "# don't" comment line added before the mutation. Must still
# deny: this command reaches the heredoc branch only because of N2.
{
    my $cmd = qq{cat <<'EOF' > n.md\nit's fine\nEOF\n# don't\ngit $V\ncat <<'EOF' >> n.md\nthat's all\nEOF};
    deny_ok($cmd, 'AC-9: N2-admitted quoted-delimiter heredocs plus an apostrophe comment around the mutation are DENIED');
}

# ===========================================================================
# Group C — the two stripper-desync shapes still DENY (-> C4). Re-derived
# from the hook header at :196-208.
# ===========================================================================

# AC-10: odd-punctuation delimiter (existing :226 guard).
{
    my $cmd = qq{cat > f <<'EOF!'\ntext\nEOF!\ngit $V};
    deny_ok($cmd, 'AC-10: odd-punctuation heredoc delimiter is DENIED (existing guard)');
}

# AC-11: same, newly admitted by N2 -- proves the :226 guard still runs first.
{
    my $cmd = qq{cat > f <<'EOF!'\ntext #x\nEOF!\ngit $V};
    deny_ok($cmd, 'AC-11: odd-punctuation heredoc delimiter with a # inside is DENIED (guard runs before N2)');
}

# AC-12: CRLF (existing :219 guard).
{
    my $cmd = qq{cat > f <<'EOF!'\r\ntext\r\nEOF!\r\ngit $V};
    like($cmd, qr/\r/, 'AC-12 premise (AC-28): the command contains \r');
    deny_ok($cmd, 'AC-12: CRLF line endings in a heredoc command are DENIED (existing guard)');
}

# AC-13: CRLF, newly admitted by N2.
{
    my $cmd = qq{cat > f <<'EOF!'\r\ntext #x\r\nEOF!\r\ngit $V};
    like($cmd, qr/\r/, 'AC-13 premise (AC-28): the command contains \r');
    deny_ok($cmd, 'AC-13: CRLF heredoc with a # inside is DENIED (guard runs before N2)');
}

# ===========================================================================
# Group D — the two false negatives this design would otherwise introduce
# (-> C2, C4). Must be pinned as DENIED (guards G1/G2 close them), not merely
# mentioned.
# ===========================================================================

# AC-14: a comment eats the heredoc start. Without G2 the stripper never
# enters the heredoc, the apostrophe opens a quote state that blanks
# everything to the end, and the real trailing mutation vanishes.
{
    my $cmd = qq{cat <<'EOF' ;#x\nit's fine\nEOF\ngit $V};
    deny_ok($cmd, 'AC-14: a comment desyncing the heredoc start is DENIED (G2)');
}

# AC-15: a comment eats a delayed heredoc start, past the real terminator.
{
    my $cmd = qq{cat <<'EOF' "a\nb" #x\nEOF\ngit $V};
    deny_ok($cmd, 'AC-15: a delayed heredoc-start desync past the terminator is DENIED (G2)');
}

# AC-16: an UNQUOTED delimiter makes the body live code -- bash expands it,
# so $(git $V) inside actually executes. G1 is what keeps this on raw.
{
    my $cmd = qq{cat <<EOF\n## \$(git $V)\nEOF};
    deny_ok($cmd, 'AC-16: unquoted heredoc delimiter with a live $(...) mutation is DENIED (G1)');
}

# AC-17: a herestring (G1's |$/non-quote arm).
{
    my $cmd = qq{cat <<<"# git $V"};
    deny_ok($cmd, 'AC-17: a <<< herestring naming the mutation is DENIED (G1)');
}

# ===========================================================================
# Group E — no existing DENY becomes an ALLOW (-> C2). Regression pins,
# exactly as important as group A.
# ===========================================================================

# AC-18: a backslash that is NOT a continuation (literal \n, two characters).
{
    my $cmd = qq{echo foo\\nbar && git $V};
    deny_ok($cmd, 'AC-18: a non-continuation backslash (scout UNKNOWN shape 1) stays DENIED');
}

# AC-19: a '#' with no heredoc marker at all.
{
    my $cmd = qq{echo foo#bar && git $V};
    deny_ok($cmd, "AC-19: a # with no heredoc (UNKNOWN shape 2) stays DENIED");
}

# AC-20: a continuation-bearing command that ALSO invokes a real mutation.
{
    my $cmd = 'perl x.pl --id 20 \\' . "\n"
            . '  --text "prose naming git ' . $V . '" && git ' . $V;
    like($cmd, qr/\\\n/, 'AC-20 premise (AC-28): a backslash is immediately followed by a newline');
    is(bscount($cmd), 1, 'AC-20 premise (AC-28): no other backslash in the command');
    deny_ok($cmd, 'AC-20: continuation-bearing command with a real trailing mutation stays DENIED');
}

# AC-21: the AC-33 quoted-single-word carve-out survives the N1 path.
{
    my $cmd = 'foo \\' . "\n" . "  && git '" . $V . "'";
    like($cmd, qr/\\\n/, 'AC-21 premise (AC-28): a backslash is immediately followed by a newline');
    is(bscount($cmd), 1, 'AC-21 premise (AC-28): no other backslash in the command');
    deny_ok($cmd, 'AC-21: quoted single-word verb-adjacent mutation survives N1 admission, stays DENIED');
}

# AC-22: AC-2's mandatory complement -- a #-bearing quoted-delimiter heredoc
# with a real mutation OUTSIDE the heredoc body, AFTER the terminator.
{
    my $cmd = qq{cat > f <<'EOF'\n## heading\nEOF\ngit $V};
    like($cmd, qr/#/, 'AC-22 premise (AC-28): the command contains a #');
    like($cmd, qr/<<'EOF'/, 'AC-22 premise (AC-28): the heredoc delimiter is quoted');
    unlike($cmd, qr/\\/, 'AC-22 premise (AC-28): the command contains no backslash');
    deny_ok($cmd, 'AC-22: quoted-delimiter heredoc with a REAL mutation after the terminator stays DENIED');
}

# AC-23: bash -c "git $V" with a continuation added -- N1 admits it to the
# walk, but the shellword fallback must still fire and re-widen the anchor.
{
    my $cmd = 'bash -c \\' . "\n" . '  "git ' . $V . '"';
    like($cmd, qr/\\\n/, 'AC-23 premise (AC-28): a backslash is immediately followed by a newline');
    is(bscount($cmd), 1, 'AC-23 premise (AC-28): no other backslash in the command');
    deny_ok($cmd, 'AC-23: bash -c wrapper with a continuation added stays DENIED (shellword fallback)');
}

# NOTE on AC-24 (whole-suite regression): this is a validation step, not an
# assertion inside this file, per spec §4 Group E. Run separately:
#   perl plugins/butler/tests/t/git-mutation-guard-reach.t
#   perl plugins/butler/tests/t/guard-git-mutations-quote-mask.t
# and confirm exit 0, zero "not ok" lines, planned counts >= 24 and >= 46.

# ===========================================================================
# Group F — the header says what the residual now is (-> C6).
# ===========================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    # Normalise runs of whitespace (incl. newlines and comment-gutter
    # indentation) to a single space before matching multi-line header prose,
    # so these assertions aren't brittle to how the implementer wraps a
    # paragraph across '#' comment lines -- they must detect CONTENT, not a
    # specific line-wrap.
    (my $norm = $src) =~ s/\s+/ /g;

    unlike($norm, qr/the backslash\/'#'-comment-adjacent raw/,
           "AC-25a: the hook source no longer contains the old residual clause "
         . "(backslash/'#'-comment-adjacent raw)");
    unlike($norm, qr/Only the heredoc-only .*? trigger gains a narrower, safer path/,
           'AC-25b: the hook source no longer contains the old residual clause '
         . '(heredoc-only ... narrower, safer path)');

    # AC-26a/b/c pinned narrative header prose ("WHAT IS NARROWED", "RESIDUAL
    # LEFT UNFIXED, KNOWINGLY...", the git \<newline>stash residual) that
    # lived in the pre-package-14 monolithic guard-git-mutations.sh. Package
    # 14's guards-remake rewrote that file as a thin run-hook.sh dispatcher
    # (logic moved to BpHook/Guards/GuardGitMutations.pm, outside this
    # package's write set), so no hooks/*.sh header carries implementation
    # narrative any more -- there is no successor location for this prose to
    # retarget to. Removed per Decision 34 (DEL: subject file's content was
    # replaced by package 14, before this package's batch B flatten).
}

{
    my $rc = system('bash', '-n', $GUARD);
    is($rc, 0, 'AC-27: bash -n plugins/butler/hooks/guard-git-mutations.sh exits 0');
}

# ===========================================================================
# Group G — step-6 red-team regression fixtures (HIGH-1, HIGH-2). Pinned so
# this exact regression class does not resurface.
# ===========================================================================

# fx_A: a quoted heredoc delimiter containing an embedded space (the :291
# odd-punctuation guard's character class used to exclude quotes/whitespace,
# so this desynced bp_strip_shell_noise's delimiter scan into a bogus quote
# state and blanked the real trailing mutation). HIGH-1.
{
    my $cmd = qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\ngit $V};
    deny_ok($cmd, 'fx_A: quoted heredoc delimiter with an embedded space, trailing real mutation stays DENIED');
}

# fx_N: same shape, but the trailing mutation is carried via $(...) after the
# terminator -- defeats the carrier re-check too. HIGH-1.
{
    my $cmd = qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\n\$(git $V)};
    deny_ok($cmd, 'fx_N: quoted heredoc delimiter with embedded space, $(...)-carried trailing mutation stays DENIED');
}

# gx_C1: fx_A plus a genuine '#' comment line before the mutation.
# HIGH-1/MEDIUM-4: G2's mask-agreement check only proves the '#' changed
# nothing RELATIVE TO the '#'-free parse -- if that parse is itself desynced
# (as in fx_A before the fix), G2 can still agree while blanking a real
# mutation.
{
    my $cmd = qq{cat > r.md <<'END OF REPORT'\n## Summary\nEND OF REPORT\n# note\ngit $V};
    deny_ok($cmd, 'gx_C1: quoted heredoc delimiter with embedded space plus a real comment before the mutation stays DENIED');
}

# sx_S1: a line continuation splits the shell keyword ITSELF ("eval"), so the
# masked walk never sees a whole "eval" word and the pre-fix shellword
# re-check (run on the still-split string) let it through. HIGH-2.
{
    my $cmd = qq{ev\\\nal " git $V"};
    deny_ok($cmd, 'sx_S1: line-continuation-split "eval" wrapping the mutation stays DENIED');
}

# sx_S3: same shape, "xargs".
{
    my $cmd = qq{xarg\\\ns -I{} " git $V"};
    deny_ok($cmd, 'sx_S3: line-continuation-split "xargs" wrapping the mutation stays DENIED');
}

done_testing();
