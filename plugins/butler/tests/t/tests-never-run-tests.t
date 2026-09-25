#!/usr/bin/env perl
# platform: any
#
# Decision 11 (hook-continuity-remake package 17): a test file that spawns
# ANOTHER repo .t file as a "stays green, unmodified" floor is redundant --
# scripts/run-tests.pl's sweep already runs that sibling file on its own.
# Worse, it is expensive: dispatch-write-path.t and row-budget-and-preview.t
# were measured re-running siblings for 157/195s and 67/72s of their own
# standalone wall time (reports/evidence/test-profile-20260923/).
#
# This file scans every plugins/*/tests/t/*.t (the same glob() expression
# test-naming-hygiene.t and scripts/run-tests.pl use) and fails on any of:
#
#   - system(...) / exec(...) spawning a repo .t
#   - backticks or qx(...)/qx{...} spawning a repo .t
#   - a piped open() ('-|' list form, or a 2-arg string ending/leading '|')
#     spawning a repo .t
#   - IPC::Open3's open3(...) or IPC::Open2's open2(...) spawning a repo .t
#   - a path assembled from $Bin (the test's own directory -- i.e. a SIBLING
#     test file) or from a literal repo .t name, then fed into any of the
#     above through a tracked scalar variable
#
# It ALLOWS:
#   - a .t fixture the test generates and runs from its OWN tempdir (a path
#     built from something matching /tmp|temp/i, e.g. "$tmpdir/generated.t")
#   - a .t name that is only DATA: inside a comment, a diag(), a string
#     compared with is()/like(), a hash key, a heredoc body that is never
#     executed, or a spawn-shaped KEYWORD sitting inside a regex/string
#     literal rather than real call syntax
#   - any file on the explicit allowlist below, each entry carrying a reason
#
# Heuristic, not a parser: it works on textual patterns, same spirit as
# test-naming-hygiene.t's header-citation scan. Its own fixture cases below
# are the mechanism of record proving each spawn form is caught and each
# data-only form is not -- not a substitute for the real-tree scan that
# follows them.

use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use FindBin qw($Bin);

my $ROOT = "$Bin/../../../..";

# ---------------------------------------------------------------------------
# The allowlist. Package 16 deleted its two seeded entries
# (reporter-gate-regression.t, arming-binds-or-reports.t) in batch B.
# ---------------------------------------------------------------------------
my %ALLOWLIST = (
    'sweep-coverage-honesty.t'   => "exercises scripts/run-tests.pl's own skip reporting against real "
        . 'files; the targets are the subject under test, not a stays-green floor '
        . '(follow-up: generated fixtures)',
);

# ---------------------------------------------------------------------------
# compute_heredoc_skip_lines(@lines) -- 0-indexed line array in, a hash of
# 0-indexed line numbers to SKIP out (heredoc body + terminator lines). A
# heredoc body is DATA per the spec's own carve-out ("a heredoc body that is
# not executed") -- it is never scanned for spawn forms or var assignments.
#
# Lint pass 6 (package 17, B1): a candidate opener whose terminator is never
# found (a SHELL heredoc inside backticks, whose real terminator line is
# something like "PAYLOAD_EOF`;"; or a marker string like "'# <<< END ...'"
# or "<<'EOT'" sitting inside a string literal) is NOT a real Perl heredoc --
# only commit the skip range once the terminator line actually shows up
# before EOF. Without this, one false opener anywhere in the file marks
# EVERY remaining line as heredoc body, hiding real spawns for the rest of
# the file (measured: 47 files, up to 2047 lines skipped in one).
# ---------------------------------------------------------------------------
sub compute_heredoc_skip_lines {
    my (@lines) = @_;
    my %skip;
    my $i = 0;
    while ($i < @lines) {
        if ($lines[$i] =~ /<<~?\s*(['"]?)(\w+)\1/) {
            my $term = $2;
            my $j = $i + 1;
            my @candidate;
            while ($j < @lines && $lines[$j] !~ /^\s*\Q$term\E\s*;?\s*$/) {
                push @candidate, $j;
                $j++;
            }
            if ($j < @lines) {
                # terminator found before EOF: commit the skip range,
                # including the terminator line itself.
                $skip{$_} = 1 for @candidate;
                $skip{$j} = 1;
                $i = $j + 1;
                next;
            }
            # no terminator found anywhere before EOF -- this was not a real
            # heredoc opener. Do not swallow the rest of the file; resume
            # scanning right after the (false) opener line.
            $i++;
            next;
        }
        $i++;
    }
    return %skip;
}

# ---------------------------------------------------------------------------
# all_call_args($text, $funcname) -- every balanced-paren argument list of
# a bareword call to $funcname on one line (single-line calls only; this
# lint is heuristic, not a parser -- see header).
# ---------------------------------------------------------------------------
sub all_call_args {
    my ($text, $name) = @_;
    my @out;
    while ($text =~ /\b\Q$name\E\s*\(/g) {
        my $start = pos($text);
        my $depth = 1;
        my $i = $start;
        while ($i < length($text) && $depth > 0) {
            my $c = substr($text, $i, 1);
            $depth++ if $c eq '(';
            $depth-- if $c eq ')';
            $i++;
        }
        push @out, substr($text, $start, $i - $start - 1) if $depth == 0;
        pos($text) = $i;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# classify_rhs($rhs, \%risky) -- does an assignment's right-hand side build
# a path to a SIBLING repo .t file?
#
#   ANY variable-prefixed path ($Bin/, $ROOT/, $T_DIR/, or similar -- the
#   interpolated variable's OWN NAME is what matters, not the whole RHS) is
#   risky UNLESS that variable's name itself matches /tmp|temp/i (Decision
#   11's "own tempdir" carve-out, e.g. "$tmpdir/generated.t" is a fixture the
#   test builds and runs itself). $Bin (FindBin's OWN test directory), $ROOT
#   and similar only ever resolve into plugins/*/tests/t/, so a spawn built
#   from one of them spawns a sibling by construction -- but the same
#   variables are also routinely used to resolve sibling .pl/.sh helpers
#   (e.g. exec($^X, "$Bin/../scripts/bp-ledger.pl")), so a literal .t must
#   follow in the same string; extract it as the target. The dynamic
#   "$Bin/$name"-style helper (row-budget-and-preview.t's own run_test_file)
#   is caught separately by find_helper_call_violations() below, which
#   requires a literal .t at the CALL SITE instead of at this assignment.
#
#   a bare literal path/basename ending .t, alone on the RHS -> risky, with
#   that literal as the target.
#
#   a straight copy of an already-risky scalar -> propagate.
# ---------------------------------------------------------------------------
sub classify_rhs {
    my ($rhs, $risky) = @_;
    if ($rhs =~ /\$(\w+)\/([A-Za-z0-9._\/-]*?\.t)\b/) {
        my ($varname, $target) = ($1, $2);
        return (0, undef) if $varname =~ /tmp|temp/i;
        return (1, $target);
    }
    if ($rhs =~ /^\s*(['"])((?:[\w.\/-]*\/)?[a-z][a-z0-9-]*\.t)\1\s*$/) {
        return (0, undef) if $rhs =~ /tmp|temp/i;
        return (1, $2);
    }
    if ($rhs =~ /^\$(\w+)\s*$/ && exists $risky->{$1}) {
        return (1, $risky->{$1});
    }
    # Lint pass 5 (package 17): an INTERMEDIATE scalar whose RHS merely
    # INTERPOLATES an already-risky variable somewhere inside a larger
    # string (not a straight copy) -- spend-session-attribution.t's own
    # "my $cmd = qq(\"$PERL\" \"$oracle\" 2>&1);" hop, where $oracle is the
    # risky loop variable and $cmd is what actually reaches the backtick
    # two lines later. Any risky variable name appearing as a real
    # interpolation ($name, word-bounded) anywhere in the RHS propagates.
    for my $rv (sort keys %$risky) {
        return (1, $risky->{$rv}) if $rhs =~ /\$\Q$rv\E\b/;
    }
    return (0, undef);
}

# ---------------------------------------------------------------------------
# find_loop_risky_vars($content) -- Lint pass 4 (package 17): a spawn that
# reaches a sibling .t through a LOOP VARIABLE, not a plain scalar
# assignment. The two real misses (row-budget-and-preview.t AC49,
# blueprints-panel-tree.t AC11 -- both an 8-name qw() list) have the shape:
#
#   for my $name (qw(one.t two.t ... eight.t)) {
#       my $path = File::Spec->rel2abs("$Bin/$name");
#       ...
#       my ($rc, $out) = run_test_file($name);   # run_test_file backticks $path
#   }
#
# i.e. the LOOP VARIABLE is what's risky, not any single assignment target --
# classify_rhs()'s existing "$Bin/<literal>.t" match never fires because
# $name is a variable, not a literal, at that call site. This returns a
# var-name => representative-target hash, meant to SEED scan_source()'s and
# find_helper_call_violations()'s own %risky/%risky_vars maps before their
# per-line passes run, so the existing propagation/spawn-detection machinery
# (classify_rhs's "straight copy" branch, find_target()'s "$var already
# risky" fallback) picks the loop variable up for free everywhere it is
# used -- direct interpolation ("$Bin/$name" in a backtick), a straight
# scalar copy, or an argument to a risky helper sub.
#
# Several list shapes are recognised, per Decision 11 pass 4/5/6's own
# examples:
#   - a qw(...) literal directly in the for(each)? header (both real misses;
#     also handles a MULTI-LINE qw(...), since a character class matches
#     newlines with no /s needed)
#   - a `my @SIBLINGS = (...)` array (qw() or quoted-string list) assigned
#     earlier, then iterated by name: `for my $t (@SIBLINGS) { ... }`
#   - a list of already-risky SCALAR variables (`for my $t ($ORACLE1,
#     $ORACLE2)`), or of ARRAYREFS pairing an already-risky scalar with a
#     label (`for my $t ([$T64, 'x.t'], [$T65, 'y.t'])`, destructured in the
#     body) -- see the two blocks below this function's header comment.
#
# If no list item ends in ".t", the loop body is checked for a ".t" SUFFIX
# being appended to the loop var itself (`"$var.t"` or `$var . '.t'`) --
# the "names without the .t suffix, joined with .t" variant -- and if found,
# the representative target is the first item with ".t" appended.
# ---------------------------------------------------------------------------
sub extract_qw_or_list_items {
    my ($text) = @_;
    $text =~ s/^\s+|\s+$//gs;
    $text =~ s/^\((.*)\)$/$1/s if $text =~ /^\(.*\)$/s;
    my @items;
    if ($text =~ /^\s*qw\s*\(([^)]*)\)\s*$/s) {
        push @items, split /\s+/, $1;
    } else {
        while ($text =~ /(['"])([\w.\/-]+)\1/gs) {
            push @items, $2;
        }
    }
    return grep { length } @items;
}

# _line_of_pos($content, $pos) -- 1-indexed line number containing byte
# offset $pos, used to turn a loop-var sighting into a LINE RANGE rather
# than a file-wide flat hash entry (see find_loop_risky_vars's own header:
# a var name as common as "name" is reassigned non-riskily elsewhere in the
# same real file, and a flat seed gets deleted by that unrelated line long
# before the actual loop body is reached).
sub _line_of_pos {
    my ($content, $pos) = @_;
    return 1 + (substr($content, 0, $pos) =~ tr/\n//);
}

# prescan_risky_scalars($content) -- a FULL top-to-bottom pass over the file
# applying classify_rhs's own scalar-assignment tracking (the same
# incremental step scan_source() runs per-line), used ONLY to seed the
# "for my $var ($SCALAR1, $SCALAR2, ...)" loop-list case below: unlike the
# qw()/@ARRAY list shapes, this list's items are themselves scalar
# VARIABLES ($ORACLE1, $ORACLE2), whose riskiness comes from an ordinary
# `my $ORACLE1 = "$Bin/lane-routing.t";`-style assignment earlier in the
# file -- exactly what classify_rhs already recognises. This is a
# best-effort prescan (it does not re-derive scan_source's own line-ranged
# %risky, so a scalar reassigned non-riskily AFTER this prescan but BEFORE
# the loop would be missed) -- acceptable for a heuristic lint whose real
# targets assign the oracle scalars once, near the top of the file, exactly
# as spend-session-attribution.t itself does.
sub prescan_risky_scalars {
    my ($content) = @_;
    my @lines = split /\n/, $content;
    my %heredoc_skip = compute_heredoc_skip_lines(@lines);
    my %risky;
    for my $idx (0 .. $#lines) {
        next if $heredoc_skip{$idx};
        my $line = $lines[$idx];
        next if $line =~ /^\s*#/;
        if ($line =~ /^\s*(?:my\s+|our\s+|local\s+)?\$(\w+)\s*=\s*(.+?);\s*$/) {
            my ($var, $rhs) = ($1, $2);
            my ($is_risky, $target) = classify_rhs($rhs, \%risky);
            if ($is_risky) { $risky{$var} = $target; }
            else           { delete $risky{$var}; }
        }
    }
    return %risky;
}

sub _record_loop_var {
    my ($ranges, $var, $items, $content, $brace_pos) = @_;
    return unless @$items;
    my ($target) = grep { /\.t$/ } @$items;
    my $body = find_sub_body($content, $brace_pos);
    if (!defined $target) {
        if ($body =~ /"\$\Q$var\E\.t"/ || $body =~ /\$\Q$var\E\s*\.\s*(['"])\.t\1/) {
            $target = $items->[0] . '.t';
        }
    }
    return unless defined $target;
    my $start_line = _line_of_pos($content, $brace_pos);
    my $end_line   = _line_of_pos($content, $brace_pos + length($body) - 1);
    push @$ranges, { var => $var, target => $target, start => $start_line, end => $end_line };
}

# find_loop_risky_vars($content) -- returns a LIST of
# { var, target, start, end } hashrefs (1-indexed inclusive line ranges),
# one per risky loop found. Callers apply an entry's var=>target ONLY while
# scanning a line within [start, end] -- never as a file-wide seed.
sub find_loop_risky_vars {
    my ($content) = @_;
    my @ranges;

    # my @ARR = (...); a literal-item array declaration (the @SIBLINGS shape).
    my %arrays;
    while ($content =~ /\bmy\s+\@(\w+)\s*=\s*(.*?);/gs) {
        my ($arrname, $listtext) = ($1, $2);
        my @items = extract_qw_or_list_items($listtext);
        $arrays{$arrname} = [ @items ] if @items;
    }

    # for(each)? my $var (qw(...)) { ... } -- the direct-literal-list shape.
    #
    # Lint pass 6 (package 17, M1 fallout): $+[0] must be captured RIGHT
    # AFTER this while()'s own match succeeds, before any other regex runs
    # -- @+/@- reflect the MOST RECENT match in the whole dynamic scope, not
    # per-variable, so calling extract_qw_or_list_items() (which runs its
    # own regexes on $listtext) first and reading $+[0] afterward silently
    # captures THAT match's position instead of this while()'s. This is
    # what made ledger-timestamps.t's C9 loop (the pass-6 arrayref-list
    # shape below) invisible: brace_pos landed inside the small $listtext
    # instead of at the real loop's opening brace, so find_sub_body() built
    # a body of the wrong size from the wrong start.
    while ($content =~ /\bfor(?:each)?\s+my\s+\$(\w+)\s*\(\s*(qw\s*\([^)]*\))\s*\)\s*\{/gs) {
        my ($var, $listtext) = ($1, $2);
        my $brace_pos = $+[0] - 1;
        _record_loop_var(\@ranges, $var, [ extract_qw_or_list_items($listtext) ], $content, $brace_pos);
    }

    # for(each)? my $var (@ARR) { ... } -- the earlier-declared-array shape.
    while ($content =~ /\bfor(?:each)?\s+my\s+\$(\w+)\s*\(\s*\@(\w+)\s*\)\s*\{/gs) {
        my ($var, $arrname) = ($1, $2);
        next unless exists $arrays{$arrname};
        _record_loop_var(\@ranges, $var, $arrays{$arrname}, $content, $+[0] - 1);
    }

    # for(each)? my $var ($SCALAR1, $SCALAR2, ...) { ... } -- Lint pass 5
    # (package 17): the list itself is made of already-risky SCALAR
    # VARIABLES, not a qw()/@ARRAY literal-name list -- spend-session-
    # attribution.t:991's own "for my $oracle ($ORACLE1, $ORACLE2) { ... }",
    # where $ORACLE1/$ORACLE2 were each assigned a repo test path near the
    # top of the file.
    my %prescan_risky = prescan_risky_scalars($content);
    while ($content =~ /\bfor(?:each)?\s+my\s+\$(\w+)\s*\(\s*((?:\$\w+\s*,\s*)+\$\w+)\s*\)\s*\{/gs) {
        my ($var, $listtext) = ($1, $2);
        # capture brace_pos BEFORE the /\$(\w+)/g match below runs -- see
        # the pass-6 note on the qw() block above; @+/@- belong to the most
        # recent match in scope, not to this while()'s pattern specifically.
        my $brace_pos = $+[0] - 1;
        my @names = ($listtext =~ /\$(\w+)/g);
        my ($target) = grep { defined } map { $prescan_risky{$_} } @names;
        next unless defined $target;
        my $body = find_sub_body($content, $brace_pos);
        my $start_line = _line_of_pos($content, $brace_pos);
        my $end_line   = _line_of_pos($content, $brace_pos + length($body) - 1);
        push @ranges, { var => $var, target => $target, start => $start_line, end => $end_line };
    }

    # for(each)? my $var ([$SCALAR1, 'label.t'], [$SCALAR2, 'label2.t'], ...)
    # { ... } -- Lint pass 6 (package 17, M1): ledger-timestamps.t:596-613's
    # own "for my $t ([$T64, 'ledger-guard.t'], [$T65, 'ledger-api.t'])
    # { my ($path, $name) = @$t; ... `perl "$path"` ... }" shape. The loop
    # VAR never holds the risky path directly -- it holds an ARRAYREF, only
    # destructured into a named scalar inside the body via
    # "my ($path, $name) = @$t;". If the list mentions a prescan-risky
    # scalar ANYWHERE, including inside "[...]", every scalar destructured
    # from the loop variable in that loop body is treated as risky, keyed to
    # that risky scalar's own target -- not the loop var itself, since the
    # loop var is never interpolated directly into a spawn.
    while ($content =~ /\bfor(?:each)?\s+my\s+\$(\w+)\s*\(\s*((?:\[[^\]]*\]\s*,?\s*)+)\)\s*\{/gs) {
        my ($var, $listtext) = ($1, $2);
        # capture brace_pos BEFORE the /\$(\w+)/g match below runs -- see
        # the pass-6 note on the qw() block above.
        my $brace_pos = $+[0] - 1;
        my @refd = ($listtext =~ /\$(\w+)/g);
        my ($target) = grep { defined } map { $prescan_risky{$_} } @refd;
        next unless defined $target;
        my $body = find_sub_body($content, $brace_pos);
        next unless $body =~ /\bmy\s*\(([^)]*)\)\s*=\s*\@\$\Q$var\E\s*;/;
        my @destructured = ($1 =~ /\$(\w+)/g);
        next unless @destructured;
        my $start_line = _line_of_pos($content, $brace_pos);
        my $end_line   = _line_of_pos($content, $brace_pos + length($body) - 1);
        for my $dname (@destructured) {
            push @ranges, { var => $dname, target => $target, start => $start_line, end => $end_line };
        }
    }

    return @ranges;
}

# ---------------------------------------------------------------------------
# find_helper_call_violations($content) -- the cross-function case: a LOCAL
# sub whose OWN body spawns (system/exec/backtick/qx/open3/open2/piped-open),
# using an argument the CALLER supplies, rather than a hardcoded command. The
# helper's body carries no literal .t itself -- the .t only appears at its
# CALL SITE, either as a literal (judge-starvation.t's run_capture('perl',
# "$Bin/judge-decision-core.t"), where run_capture does
# "open(my $ph, '-|', @cmd)") or via a variable the caller assigned from a
# $Bin/$ROOT/$T_DIR/-style literal .t path earlier in the same file
# (lane-property-not-mention.t's "my $lane_routing =
# \"$ROOT/plugins/butler/tests/t/lane-routing.t\"; ...
# _run_perl_file($lane_routing);", where _run_perl_file does
# "exec($^X, $file, @args)"). Unlike find_sub_body's original design, no
# $Bin requirement on the SUB BODY itself -- run_capture and _run_perl_file
# both spawn via a caller-supplied variable, never referencing $Bin at all;
# $Bin only has to appear on the CALLER's side, tracked the same way
# scan_source tracks it for direct spawns.
# ---------------------------------------------------------------------------
sub find_sub_body {
    my ($content, $brace_pos) = @_;
    my $depth = 1;
    my $i = $brace_pos + 1;
    my $len = length($content);
    while ($i < $len && $depth > 0) {
        my $c = substr($content, $i, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        $i++;
    }
    return substr($content, $brace_pos, $i - $brace_pos);
}

sub find_risky_helper_subs {
    my ($content) = @_;
    my %risky_subs;
    while ($content =~ /^[ \t]*sub\s+(\w+)\s*(?:\([^)]*\))?\s*\{/mg) {
        my $name = $1;
        my $brace_pos = pos($content) - 1;
        my $body = find_sub_body($content, $brace_pos);
        next unless body_has_unguarded_spawn($body);
        $risky_subs{$name} = 1;
    }
    return %risky_subs;
}

sub find_helper_call_violations {
    my ($content) = @_;
    my %risky_subs = find_risky_helper_subs($content);
    return () unless %risky_subs;
    my @lines = split /\n/, $content;
    my %heredoc_skip = compute_heredoc_skip_lines(@lines);
    my @loop_ranges = find_loop_risky_vars($content);
    my %risky_vars;
    my @violations;
    for my $idx (0 .. $#lines) {
        next if $heredoc_skip{$idx};
        my $line = $lines[$idx];
        next if $line =~ /^\s*#/;
        my $lineno = $idx + 1;

        for my $lr (@loop_ranges) {
            $risky_vars{ $lr->{var} } = $lr->{target}
                if $lineno >= $lr->{start} && $lineno <= $lr->{end};
        }

        if ($line =~ /^\s*(?:my\s+|our\s+|local\s+)?\$(\w+)\s*=\s*(.+?);\s*$/) {
            my ($var, $rhs) = ($1, $2);
            my ($is_risky, $target) = classify_rhs($rhs, \%risky_vars);
            if ($is_risky) { $risky_vars{$var} = $target; }
            else           { delete $risky_vars{$var}; }
        }

        for my $name (sort keys %risky_subs) {
            for my $args (all_call_args($line, $name)) {
                my $target = find_target($args, \%risky_vars);
                push @violations, { line => $lineno, form => 'helper-mediated', target => $target }
                    if defined $target;
            }
        }
    }
    return @violations;
}

# ---------------------------------------------------------------------------
# spawn_has_dash_c_before_target($argtext) -- does this spawn's argument text
# carry perl's own '-c' (syntax-check-only, never executes the file) BEFORE
# the .t target it is checking? Decision 11's third pass (package 17): a
# perl -c compile check on a sibling/self .t is not a re-run of it, so this
# guards BOTH forms seen in the real tree:
#   direct:  system($^X, '-c', "$Bin/self.t")       (literal .t after '-c')
#   helper:  system($^X, '-c', $file)                ($file after '-c',
#            resolved to a literal .t only at the helper's CALL SITE --
#            body_has_unguarded_spawn() below applies this same check to a
#            candidate helper sub's OWN body, before it is ever marked risky)
# Order matters: '-e'/other flags, or no flag at all, must NOT match -- only
# an exact quoted '-c' immediately preceding the target.
#
# Lint pass 6 (package 17, M2): the guard is NOT tied to the program being
# perl -- any quoted '-c' followed by a var/literal .t was exempted, so
# system('bash', '-c', "perl $Bin/x.t") (the tree's most common spawn idiom,
# 31 files) went unflagged. '-c' only means "syntax check, don't execute"
# for perl itself; bash/sh's own '-c' means "run this command string". Fix:
# the token immediately before '-c' must be the perl program ($^X, '$^X',
# 'perl', or $PERL), as the FIRST arg in the list, and nothing but the
# target may follow '-c' (an extra trailing arg after the target, e.g.
# system($^X, '-c', $x, "$Bin/x.t"), is not exempt either).
# ---------------------------------------------------------------------------
sub spawn_has_dash_c_before_target {
    my ($argtext) = @_;
    my $perl_tok = qr/(?:\$\^X|\$PERL|(['"])perl\1)/;
    return 1 if $argtext =~ /^\s*$perl_tok\s*,\s*(['"])-c\2\s*,\s*(?:\$\w+|(['"])[^'"]*\.t\3)\s*$/;
    return 0;
}

# ---------------------------------------------------------------------------
# body_has_unguarded_spawn($body) -- same spawn-shape detection as
# scan_source()'s per-line pass, applied to a candidate helper sub's body,
# with the dash-c guard subtracted first. A sub whose only spawn construct
# is a perl -c compile check (e.g. lane-routing.t's _perl_dash_c, or the
# backup-{closeout,export,preflight,vault,wrapper}.t family's _compile_check,
# both of which do system($^X, '-c', $file) / exec($^X, '-c', $file) on a
# CALLER-supplied path) is not risky -- it never executes the sibling it is
# handed, only compiles it.
# ---------------------------------------------------------------------------
sub body_has_unguarded_spawn {
    my ($body) = @_;
    for my $line (split /\n/, $body) {
        next if $line =~ /^\s*#/;
        my @spawns;
        for my $tick (find_real_backtick_spans($line)) { push @spawns, $tick; }
        if ($line =~ /\bqx\s*\{([^}]*)\}/) { push @spawns, $1; }
        for my $args (all_call_args($line, 'qx'))     { push @spawns, $args; }
        for my $args (all_call_args($line, 'system'))  { push @spawns, $args; }
        for my $args (all_call_args($line, 'exec'))    { push @spawns, $args; }
        for my $args (all_call_args($line, 'open3'))   { push @spawns, $args; }
        for my $args (all_call_args($line, 'open2'))   { push @spawns, $args; }
        for my $args (all_call_args($line, 'open')) {
            push @spawns, $args
                if $args =~ /(['"])-\|\1/ || $args =~ /(['"])[^'"]*\|\s*\1/ || $args =~ /(['"])\|[^'"]*\1/;
        }
        for my $cmdtext (@spawns) {
            return 1 unless spawn_has_dash_c_before_target($cmdtext);
        }
    }
    return 0;
}

# ---------------------------------------------------------------------------
# find_target($cmdtext, \%risky) -- does a spawn's argument text carry a
# literal repo .t reference, or a variable already marked risky? Returns the
# target string, or undef ("this call is not a sibling-rerun").
# ---------------------------------------------------------------------------
sub find_target {
    my ($text, $risky) = @_;
    # A bare (optionally quoted, optionally path-prefixed) sibling .t name
    # ANYWHERE in the spawn's argument text -- quotes are not required
    # around it (backtick/qx contents, and 2-arg piped open()'s trailing
    # "cmd |" form, embed it inline rather than as its own quoted token).
    if ($text =~ /\b((?:[\w.\/-]*\/)?[a-z][a-z0-9-]*\.t)\b/) {
        return $1;
    }
    while ($text =~ /\$(\w+)\b/g) {
        return $risky->{$1} if exists $risky->{$1};
    }
    return undef;
}

# ---------------------------------------------------------------------------
# find_real_backtick_spans($line) -- every genuine qx()-operator backtick
# span on a line, i.e. a pair of backticks NOT nested inside a '...',
# "..." or q{}/qq{}(){}[] string literal. A backtick character inside one of
# those forms is DATA -- prose describing a command, not a real qx()
# operator -- per Decision 11's own carve-out (fleet-event-source.t and
# keepawake-probe.t's "pass('... `perl x.t` ...')"). A single left-to-right
# walk: q{}/qq{}/q()/qq()/q[]/qq[] spans and '...'/"..." spans are SKIPPED
# WHOLESALE when scanning for the next backtick outside any span; but once a
# real backtick span has started, we stop tracking quotes altogether and
# just look for its closing backtick -- a quote INSIDE a genuine backtick
# command (e.g. `perl "$path" 2>&1`) is real shell syntax, not a nested
# string literal, and must not truncate the span early.
# ---------------------------------------------------------------------------
sub find_real_backtick_spans {
    my ($line) = @_;
    my @out;
    my $len = length($line);
    my $i = 0;
    my $start;
    while ($i < $len) {
        if (defined $start) {
            if (substr($line, $i, 1) eq '`') {
                push @out, substr($line, $start + 1, $i - $start - 1);
                undef $start;
            }
            $i++;
            next;
        }
        if (substr($line, $i) =~ /^(qq?)\s*([{(\[])/) {
            my $open  = $2;
            my $close = { '{' => '}', '(' => ')', '[' => ']' }->{$open};
            my $delim_pos = index($line, $open, $i);
            my $close_pos = index($line, $close, $delim_pos + 1);
            $i = ($close_pos >= 0) ? $close_pos + 1 : $len;
            next;
        }
        my $c = substr($line, $i, 1);
        if ($c eq "'" || $c eq '"') {
            my $close_pos = index($line, $c, $i + 1);
            $i = ($close_pos >= 0) ? $close_pos + 1 : $len;
            next;
        }
        if ($c eq '`') { $start = $i; }
        $i++;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# scan_source($content) -- the driver. Returns a list of violation hashrefs:
# { line => N, form => 'system'|'exec'|'backtick'|'qx'|'piped-open'|
#   'open3'|'open2', target => STRING }.
# ---------------------------------------------------------------------------
sub scan_source {
    my ($content) = @_;
    my @lines = split /\n/, $content;
    my %heredoc_skip = compute_heredoc_skip_lines(@lines);
    my @loop_ranges = find_loop_risky_vars($content);
    my %risky;
    my @violations;

    for my $idx (0 .. $#lines) {
        next if $heredoc_skip{$idx};
        my $line = $lines[$idx];
        next if $line =~ /^\s*#/;
        my $lineno = $idx + 1;

        for my $lr (@loop_ranges) {
            $risky{ $lr->{var} } = $lr->{target}
                if $lineno >= $lr->{start} && $lineno <= $lr->{end};
        }

        # 1. track scalar assignments that build a sibling-.t path.
        if ($line =~ /^\s*(?:my\s+|our\s+|local\s+)?\$(\w+)\s*=\s*(.+?);\s*$/) {
            my ($var, $rhs) = ($1, $2);
            my ($is_risky, $target) = classify_rhs($rhs, \%risky);
            if ($is_risky) { $risky{$var} = $target; }
            else           { delete $risky{$var}; }
        }

        # 2. gather every spawn-shaped call on this line.
        my @spawns;
        for my $tick (find_real_backtick_spans($line)) { push @spawns, ['backtick', $tick]; }
        if ($line =~ /\bqx\s*\{([^}]*)\}/) { push @spawns, ['qx', $1]; }
        for my $args (all_call_args($line, 'qx'))     { push @spawns, ['qx', $args]; }
        for my $args (all_call_args($line, 'system'))  { push @spawns, ['system', $args]; }
        for my $args (all_call_args($line, 'exec'))    { push @spawns, ['exec', $args]; }
        for my $args (all_call_args($line, 'open3'))   { push @spawns, ['open3', $args]; }
        for my $args (all_call_args($line, 'open2'))   { push @spawns, ['open2', $args]; }
        for my $args (all_call_args($line, 'open')) {
            push @spawns, ['piped-open', $args]
                if $args =~ /(['"])-\|\1/ || $args =~ /(['"])[^'"]*\|\s*\1/ || $args =~ /(['"])\|[^'"]*\1/;
        }

        for my $spawn (@spawns) {
            my ($form, $cmdtext) = @$spawn;
            next if spawn_has_dash_c_before_target($cmdtext);
            my $target = find_target($cmdtext, \%risky);
            push @violations, { line => $lineno, form => $form, target => $target }
                if defined $target;
        }
    }
    return @violations;
}

# ===========================================================================
# Fixture cases -- inline sample sources, never files on disk. Each spawn
# form proven caught; each data-only form proven ignored.
# ===========================================================================

my @POSITIVE_CASES = (
    [ 'system(...) with a literal sibling .t',
      qq{my \$out = system('perl', 'plugins/butler/tests/t/some-sibling.t');\n},
      'system' ],
    [ 'exec(...) with \$^X and a literal sibling .t',
      qq{exec(\$^X, 'plugins/sandbox/tests/t/some-sibling.t') or die;\n},
      'exec' ],
    [ 'backticks with \$^X and a literal sibling .t',
      qq{my \$out = `\$^X plugins/butler/tests/t/some-sibling.t 2>&1`;\n},
      'backtick' ],
    [ 'qx(...) with a literal sibling .t',
      qq{my \$out = qx(perl plugins/butler/tests/t/some-sibling.t 2>&1);\n},
      'qx' ],
    [ 'qx{...} with a literal sibling .t',
      qq{my \$out = qx{perl plugins/butler/tests/t/some-sibling.t 2>&1};\n},
      'qx' ],
    [ "piped open() list form ('-|') with a literal sibling .t",
      qq{open(my \$fh, '-|', 'perl', 'plugins/butler/tests/t/some-sibling.t') or die;\n},
      'piped-open' ],
    [ "piped open() 2-arg string form ('cmd |') with a literal sibling .t",
      qq{open(my \$fh, 'perl plugins/butler/tests/t/some-sibling.t |') or die;\n},
      'piped-open' ],
    [ 'IPC::Open3 open3(...) with a literal sibling .t',
      qq{use IPC::Open3;\nmy \$pid = open3(\$in, \$out, \$err, 'perl', 'plugins/butler/tests/t/some-sibling.t');\n},
      'open3' ],
    [ 'IPC::Open2 open2(...) with a literal sibling .t',
      qq{use IPC::Open2;\nmy \$pid = open2(\$out, \$in, 'perl', 'plugins/butler/tests/t/some-sibling.t');\n},
      'open2' ],
    [ 'a $Bin-built variable fed into a later backtick (dispatch-write-path.t\'s own shape)',
      qq{my \$f175 = "\$Bin/some-sibling.t";\nmy \$out = `perl "\$f175" 2>&1`;\n},
      'backtick' ],
    [ 'a plain scalar copy of an already-risky variable',
      qq{my \$f175 = "\$Bin/some-sibling.t";\nmy \$copy = \$f175;\nmy \$out = `perl "\$copy" 2>&1`;\n},
      'backtick' ],
    [ 'system(...) with a non-"-c" flag (\'-e\') before a literal sibling .t still flags (the guard is exact)',
      qq{my \$out = system(\$^X, '-e', 'x', 'plugins/butler/tests/t/some-sibling.t');\n},
      'system' ],
    [ 'a plain perl invocation with no flag at all before a literal sibling .t still flags',
      qq{my \$out = `perl plugins/butler/tests/t/some-sibling.t`;\n},
      'backtick' ],
);

for my $case (@POSITIVE_CASES) {
    my ($label, $src, $expect_form) = @$case;
    my @v = scan_source($src);
    ok(@v >= 1, "catches: $label") or diag("no violation found in:\n$src");
    if (@v) {
        ok((grep { $_->{form} eq $expect_form } @v) > 0,
            "catches: $label (tagged form '$expect_form')")
            or diag('forms seen: ' . join(',', map { $_->{form} } @v));
    } else {
        fail("catches: $label (tagged form '$expect_form')");
    }
}

# --- the cross-function ("helper-mediated") case, row-budget-and-preview.t's
# own run_test_file shape: the .t literal lives at the CALL SITE, not in the
# helper's body. ---------------------------------------------------------
{
    my $helper_src = <<'SRC';
sub run_test_file {
    my ($rel) = @_;
    my $path = File::Spec->rel2abs("$Bin/$rel");
    my $out = `perl "$path" 2>&1`;
    return $out;
}
run_test_file('some-sibling.t');
SRC
    my @v = find_helper_call_violations($helper_src);
    ok(@v >= 1, 'catches: a helper sub that resolves $Bin/$name then spawns it, called with a literal sibling .t'
        . " (row-budget-and-preview.t's own run_test_file shape)")
        or diag("no violation found in:\n$helper_src");
    ok((grep { $_->{target} eq 'some-sibling.t' } @v) > 0, 'helper-mediated violation names the call-site literal');
}

{
    my $safe_helper_src = <<'SRC';
sub read_fixture {
    my ($rel) = @_;
    my $path = File::Spec->rel2abs("$Bin/$rel");
    open(my $fh, '<', $path) or die;
    local $/; my $text = <$fh>;
    return $text;
}
read_fixture('some-sibling.t');
SRC
    my @v = find_helper_call_violations($safe_helper_src);
    is(scalar(@v), 0,
        'ignores: a $Bin-resolving helper that only reads/opens for reading, never spawns');
}

{
    my $non_dot_t_call_src = <<'SRC';
sub run_script {
    my ($rel) = @_;
    my $path = File::Spec->rel2abs("$Bin/$rel");
    my $out = `perl "$path" 2>&1`;
    return $out;
}
run_script('helper.pl');
SRC
    my @v = find_helper_call_violations($non_dot_t_call_src);
    is(scalar(@v), 0,
        'ignores: a $Bin-resolving spawn helper called with a non-.t (.pl) literal');
}

# --- perl -c guard, DIRECT form (backup-{closeout,export,preflight,vault,
# wrapper}.t's own shape, minus the intervening helper): system($^X, '-c',
# ...) on a literal sibling/self .t is a syntax check, never an execution. --
{
    my $dash_c_direct_src = qq{my \$rc = system(\$^X, '-c', "\$Bin/some-sibling.t");\n};
    my @v = scan_source($dash_c_direct_src);
    is(scalar(@v), 0,
        "ignores: system(\$^X, '-c', ...) on a literal sibling .t (perl -c never executes the file)")
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- perl -c guard, HELPER form (lane-routing.t's own _perl_dash_c($SELF),
# and backup-{closeout,export,preflight,vault,wrapper}.t's own
# _compile_check($file, $label)): the '-c' lives in the SUB'S BODY, applied
# to a caller-supplied parameter; the literal .t only appears at the call
# site. The sub must not be marked risky in the first place. -------------
{
    my $dash_c_helper_src = <<'SRC';
sub _perl_dash_c {
    my ($file) = @_;
    my $pid = fork();
    if ($pid == 0) {
        exec($^X, '-c', $file) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    return $? >> 8;
}
my $SELF = "$Bin/some-sibling.t";
_perl_dash_c($SELF);
SRC
    my @v = find_helper_call_violations($dash_c_helper_src);
    is(scalar(@v), 0,
        "ignores: a helper sub whose body does exec(\$^X, '-c', \$file) on a caller-supplied path "
      . "(lane-routing.t's own _perl_dash_c shape)")
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- Lint pass 6 (package 17, M2): the '-c' exemption must be tied to the
# PERL program, not to any '-c' whatsoever -- system('bash', '-c', ...) /
# sh -c is a real shell command, never a syntax-only compile check, and must
# still be flagged as a sibling re-run when a real .t reaches it. -----------
{
    my $bash_dash_c_direct_src =
        qq{my \$out = system('bash', '-c', "perl \$Bin/some-sibling.t");\n};
    my @v = scan_source($bash_dash_c_direct_src);
    ok(@v >= 1, "catches: system('bash', '-c', ...) spawning a sibling .t "
        . "(the '-c' exemption must not apply to a non-perl program)")
        or diag("no violation found in:\n$bash_dash_c_direct_src");
}

{
    my $bash_dash_c_cmd_hop_src = <<'SRC';
my $cmd = "perl $Bin/lane-routing.t";
system('bash', '-c', $cmd);
SRC
    my @v = scan_source($bash_dash_c_cmd_hop_src);
    ok(@v >= 1, "catches: system('bash', '-c', \$cmd) where \$cmd was built from a real sibling .t "
        . "one line earlier")
        or diag("no violation found in:\n$bash_dash_c_cmd_hop_src");
}

{
    my $bash_dash_c_piped_open_src =
        qq{open(my \$ph, '-|', 'bash', '-c', "timeout 60 perl \$Bin/some-sibling.t") or die;\n};
    my @v = scan_source($bash_dash_c_piped_open_src);
    ok(@v >= 1, "catches: a piped open() list form spawning bash -c with a sibling .t inside "
        . 'the command string')
        or diag("no violation found in:\n$bash_dash_c_piped_open_src");
}

{
    my $bash_dash_c_helper_src = <<'SRC';
sub run_via_shell {
    my ($cmd) = @_;
    system('bash', '-c', $cmd);
}
my $cmd = "perl $Bin/lane-routing.t";
run_via_shell($cmd);
SRC
    my @v = find_helper_call_violations($bash_dash_c_helper_src);
    ok(@v >= 1, "catches: a helper sub whose body does system('bash', '-c', \$cmd) on a caller-"
        . 'supplied command string built from a real sibling .t')
        or diag("no violation found in:\n$bash_dash_c_helper_src");
}

# --- Lint pass 6 (package 17, M2): the exemption also must not extend past
# the target -- an extra argument AFTER the target means '-c' is not really
# guarding a single compile-check invocation. --------------------------------
{
    my $dash_c_trailing_arg_src =
        qq{my \$rc = system(\$^X, '-c', \$x, "\$Bin/some-sibling.t");\n};
    my @v = scan_source($dash_c_trailing_arg_src);
    ok(@v >= 1, "catches: system(\$^X, '-c', \$x, ...) -- an extra argument after the target is "
        . 'not a bare compile check')
        or diag("no violation found in:\n$dash_c_trailing_arg_src");
}

# --- real-world MISS #1 (judge-starvation.t:680): a generic piped-open
# helper (no $Bin in its own body -- $Bin only appears at the CALL SITE)
# called with a literal "$Bin/<name>.t" argument. ------------------------
{
    my $run_capture_src = <<'SRC';
sub run_capture {
    my (@cmd) = @_;
    open(my $ph, '-|', @cmd) or return (undef, -1);
    local $/;
    my $out = <$ph>;
    close $ph;
    my $rc = $? >> 8;
    return ($out, $rc);
}
my ($out10, $rc10) = run_capture('perl', "$Bin/judge-decision-core.t");
SRC
    my @v = find_helper_call_violations($run_capture_src);
    ok(@v >= 1, 'catches: a generic piped-open helper (no $Bin in its own body) called with a literal '
        . '"$Bin/<name>.t" argument (judge-starvation.t:680\'s own run_capture shape)')
        or diag("no violation found in:\n$run_capture_src");
    ok((grep { $_->{target} =~ /judge-decision-core\.t$/ } @v) > 0,
        'helper-mediated violation names the call-site literal (judge-decision-core.t)');
}

# --- real-world MISS #2 (lane-property-not-mention.t:250-253): a scalar
# assigned from a "$ROOT/plugins/.../<name>.t" literal, then passed by
# variable to a local sub whose body spawns via fork+exec. -----------------
{
    my $run_perl_file_src = <<'SRC';
sub _run_perl_file {
    my ($file, @args) = @_;
    my $pid = fork();
    if ($pid == 0) {
        exec($^X, $file, @args) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    return $? >> 8;
}
my $lane_routing = "$ROOT/plugins/butler/tests/t/lane-routing.t";
my ($rc, $out) = _run_perl_file($lane_routing);
SRC
    my @v = find_helper_call_violations($run_perl_file_src);
    ok(@v >= 1, 'catches: a scalar assigned from a "$ROOT/plugins/.../<name>.t" literal, then passed by '
        . 'variable into a spawning local sub (lane-property-not-mention.t:250-253\'s own _run_perl_file shape)')
        or diag("no violation found in:\n$run_perl_file_src");
    ok((grep { $_->{target} =~ /lane-routing\.t$/ } @v) > 0,
        'helper-mediated violation names the tracked variable\'s target (lane-routing.t)');
}

# --- real-world MISS #3 (row-budget-and-preview.t AC49, blueprints-panel-
# tree.t AC11): a `for my $name (qw(... 8 literal .t names ...))` loop whose
# BODY builds "$Bin/$name" and passes $name into run_test_file(), a helper
# whose own body backticks the resolved path. The literal .t names are the
# loop's LIST, never a plain scalar assignment -- classify_rhs()'s existing
# machinery never sees them; find_loop_risky_vars() is what has to. ---------
{
    my $loop_helper_src = <<'SRC';
sub run_test_file {
    my ($rel) = @_;
    my $path = File::Spec->rel2abs("$Bin/$rel");
    my $out = `perl "$path" 2>&1`;
    return $out;
}
for my $name (qw(paused-reason-and-triage.t blueprints-table.t no-rendered-colons.t
                  run-panel-truth.t layout-flex-stability.t wrap-on-overflow.t
                  wrap-width-regressions.t providers-panel.t)) {
    my $path = File::Spec->rel2abs("$Bin/$name");
    ok(-f $path, "precondition: $path exists");
    my ($rc, $out) = run_test_file($name);
}
SRC
    my @v = find_helper_call_violations($loop_helper_src);
    ok(@v >= 1, 'catches: a for-my-$var-(qw(... 8 literal .t names ...)) loop passing the loop var into a '
        . "risky helper (row-budget-and-preview.t AC49 / blueprints-panel-tree.t AC11's own shape)")
        or diag("no violation found in:\n$loop_helper_src");
    ok((grep { defined($_->{target}) && $_->{target} =~ /\.t$/ } @v) > 0,
        'loop-mediated violation names a .t target');
}

# --- same loop shape, but the spawn is DIRECT in the loop body (no
# intervening helper sub) -- the "for my $t (qw(a.t b.t)) { \`perl "$Bin/$t"\`
# }" shape named in Decision 11 pass 4's own example. ------------------------
{
    my $direct_loop_src = <<'SRC';
for my $t (qw(some-sibling.t other-sibling.t)) {
    my $out = `perl "$Bin/$t" 2>&1`;
}
SRC
    my @v = scan_source($direct_loop_src);
    ok(@v >= 1, 'catches: a direct backtick spawn inside a for-my-$t-(qw(...)) loop, via "$Bin/$t" interpolation')
        or diag("no violation found in:\n$direct_loop_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, 'direct loop-mediated violation is tagged backtick');
}

# --- the @SIBLINGS array variant: a `my @SIBLINGS = (...)` literal-item
# array declared earlier, iterated by name later. ---------------------------
{
    my $siblings_array_src = <<'SRC';
my @SIBLINGS = (qw(some-sibling.t other-sibling.t));
for my $t (@SIBLINGS) {
    my $out = `perl "$Bin/$t" 2>&1`;
}
SRC
    my @v = scan_source($siblings_array_src);
    ok(@v >= 1, 'catches: an earlier my @SIBLINGS = (...) literal-item array, iterated by a for-my-$t-(@SIBLINGS) loop')
        or diag("no violation found in:\n$siblings_array_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, '@SIBLINGS-array loop-mediated violation is tagged backtick');
}

# --- the "names without the .t suffix, joined with .t" variant: the qw()
# list carries bare names, and the loop body appends ".t" itself. -----------
{
    my $joined_suffix_src = <<'SRC';
for my $base (qw(some-sibling other-sibling)) {
    my $out = `perl "$Bin/$base.t" 2>&1`;
}
SRC
    my @v = scan_source($joined_suffix_src);
    ok(@v >= 1, 'catches: a qw() list of bare names (no .t suffix), joined with ".t" in the loop body')
        or diag("no violation found in:\n$joined_suffix_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, 'joined-suffix loop-mediated violation is tagged backtick');
}

# --- real-world MISS #4 (spend-session-attribution.t:991-1003): a loop
# whose LIST is made of already-risky SCALAR VARIABLES ($ORACLE1, $ORACLE2),
# not a qw()/@ARRAY literal-name list, spawning the loop var DIRECTLY. -----
{
    my $scalar_list_loop_src = <<'SRC';
my $ORACLE1 = "$Bin/oracle-one.t";
my $ORACLE2 = "$Bin/oracle-two.t";
for my $oracle ($ORACLE1, $ORACLE2) {
    my $out = `perl "$oracle" 2>&1`;
}
SRC
    my @v = scan_source($scalar_list_loop_src);
    ok(@v >= 1, 'catches: a for-my-$var-($SCALAR1, $SCALAR2) loop over already-risky scalar variables, '
        . "spawning the loop var directly (spend-session-attribution.t's own oracle-list shape)")
        or diag("no violation found in:\n$scalar_list_loop_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, 'scalar-list loop-mediated violation is tagged backtick');
}

# --- real-world MISS #5 (spend-session-attribution.t:991-1003, exact shape):
# the scalar-list loop above, but the spawn reaches the loop var only
# THROUGH AN INTERMEDIATE SCALAR ($cmd) whose own RHS is a qq()-interpolated
# string containing the loop var, not a straight copy of it. ---------------
{
    my $cmd_hop_loop_src = <<'SRC';
my $ORACLE1 = "$Bin/oracle-one.t";
my $ORACLE2 = "$Bin/oracle-two.t";
for my $oracle ($ORACLE1, $ORACLE2) {
    my $cmd = qq("$PERL" "$oracle" 2>&1);
    my $out = `$cmd`;
}
SRC
    my @v = scan_source($cmd_hop_loop_src);
    ok(@v >= 1, 'catches: the scalar-list loop reaching a spawn through an intermediate $cmd scalar built with '
        . "qq() interpolation of the loop var (spend-session-attribution.t:991-1003's exact shape)")
        or diag("no violation found in:\n$cmd_hop_loop_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, '$cmd-hop loop-mediated violation is tagged backtick');
}

# --- real-world MISS #6 (ledger-timestamps.t:596-613, exact shape): a loop
# over ARRAYREFS pairing an already-risky scalar with a label, destructured
# in the body via "my ($path, $name) = @$t;" before the spawn. --------------
{
    my $arrayref_loop_src = <<'SRC';
my $T64 = "$Bin/ledger-guard.t";
my $T65 = "$Bin/ledger-api.t";
for my $t ([$T64, 'ledger-guard.t'], [$T65, 'ledger-api.t']) {
    my ($path, $name) = @$t;
    my $out = `perl "$path" 2>&1`;
}
SRC
    my @v = scan_source($arrayref_loop_src);
    ok(@v >= 1, 'catches: a for-my-$t-([$SCALAR1, \'label.t\'], [$SCALAR2, \'label2.t\']) loop, '
        . "destructured via my (\$path, \$name) = \@\$t (ledger-timestamps.t:596-613's exact shape)")
        or diag("no violation found in:\n$arrayref_loop_src");
    ok((grep { $_->{form} eq 'backtick' } @v) > 0, 'arrayref-loop-mediated violation is tagged backtick');
}

# --- negative: the same arrayref-pair loop, but the body only does
# ok(-f $path) -- an existence check, no spawn anywhere -- must NOT flag.
{
    my $arrayref_loop_data_only_src = <<'SRC';
my $T64 = "$Bin/ledger-guard.t";
my $T65 = "$Bin/ledger-api.t";
for my $t ([$T64, 'ledger-guard.t'], [$T65, 'ledger-api.t']) {
    my ($path, $name) = @$t;
    ok(-f $path, "precondition: $name exists at $path");
}
SRC
    my @v = scan_source($arrayref_loop_data_only_src);
    is(scalar(@v), 0,
        'ignores: the same for-my-$t-([$SCALAR, \'label.t\'], ...) loop used only as data '
      . '(ok(-f $path) precondition), no spawn anywhere')
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- negative: the same scalar-list loop, but the body only does
# ok(-f $oracle) -- an existence check, no spawn anywhere -- must NOT flag.
{
    my $scalar_list_data_only_src = <<'SRC';
my $ORACLE1 = "$Bin/oracle-one.t";
my $ORACLE2 = "$Bin/oracle-two.t";
for my $oracle ($ORACLE1, $ORACLE2) {
    ok(-f $oracle, "precondition: $oracle exists");
}
SRC
    my @v = scan_source($scalar_list_data_only_src);
    is(scalar(@v), 0,
        'ignores: the same for-my-$var-($SCALAR1, $SCALAR2) loop used only as data (ok(-f $oracle) precondition), '
      . 'no spawn anywhere')
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- negative: a loop over literal .t names used ONLY as data (an
# existence check), with no spawn anywhere in the body -- must NOT flag.
# This is the control proving the new detection is keyed on a REACHING
# spawn, not merely on "a loop iterates literal .t names". ------------------
{
    my $data_only_loop_src = <<'SRC';
for my $name (qw(paused-reason-and-triage.t blueprints-table.t no-rendered-colons.t
                  run-panel-truth.t layout-flex-stability.t wrap-on-overflow.t
                  wrap-width-regressions.t providers-panel.t)) {
    my $path = File::Spec->rel2abs("$Bin/$name");
    ok(-f $path, "precondition: $path exists");
}
SRC
    my @v_direct = scan_source($data_only_loop_src);
    my @v_helper = find_helper_call_violations($data_only_loop_src);
    is(scalar(@v_direct) + scalar(@v_helper), 0,
        'ignores: a loop over literal .t names used only as data (ok(-f ...) precondition), no spawn anywhere')
        or diag('violations found: '
            . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v_direct, @v_helper));
}

# --- real-world FALSE POSITIVE #1 and #2 (fleet-event-source.t:508-509,
# keepawake-probe.t:312): a backtick character inside an ordinary
# single-quoted pass() string is DATA, not a qx() operator. ----------------
{
    my $prose_backtick_src =
        q{pass('C9: no-regression is recorded via the validation commands `perl plugins/sandbox/tests/t/panel-semantics.t` '} . "\n"
      . q{    . 'and `perl plugins/sandbox/tests/t/activity-history.t` (see report), not reimplemented in this file');} . "\n";
    my @v = scan_source($prose_backtick_src);
    is(scalar(@v), 0,
        'ignores: backtick characters inside an ordinary single-quoted pass() string '
      . '(fleet-event-source.t:508-509\'s own no-regression note)')
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- real-world FALSE POSITIVE #3 (green-baseline.t:541,550): a spawn
# target whose basename is NOT a real repo test file (a fixture the test
# builds under its own project tree, pkgP/oracle.t) is not a sibling rerun.
# This carve-out only applies to the REAL-TREE scan below, which filters by
# basename against the actual glob() -- scan_source() itself still reports
# the raw match here, proving the mechanism operates at the filter step, not
# by silently ignoring anything ending "oracle.t". --------------------------
{
    my $fixture_oracle_src = qq{my \$tree_out = `cd "\$dest" 2>/dev/null; timeout 15 "\$^X" pkgP/oracle.t 2>&1`;\n};
    my @v = scan_source($fixture_oracle_src);
    ok(@v >= 1, 'sanity: scan_source() itself still reports a raw pkgP/oracle.t backtick match '
      . '(the basename-is-a-real-test filter lives in the real-tree scan, not here)');
    ok((grep { ($_->{target} // '') =~ /oracle\.t$/ } @v) > 0, 'sanity: the raw match names oracle.t');
}

# --- Lint pass 6 (package 17, B1): a SHELL heredoc opener nested inside a
# backtick command (`bash -c "cat <<'PAYLOAD_EOF' ... PAYLOAD_EOF\";`) looks
# like a Perl heredoc opener to compute_heredoc_skip_lines(), but its real
# terminator line ('PAYLOAD_EOF";' followed by a closing backtick) never
# matches the Perl-heredoc terminator pattern. Before the fix, the false
# opener swallowed every line to EOF as heredoc body, hiding a real sibling
# spawn a few lines later. -------------------------------------------------
{
    my $unterminated_heredoc_src = <<'SRC';
my $out = `bash -c "cat <<'PAYLOAD_EOF'
some content here
PAYLOAD_EOF"`;
my $out2 = `perl plugins/butler/tests/t/some-sibling.t`;
SRC
    my @v = scan_source($unterminated_heredoc_src);
    ok(@v >= 1, 'catches: a real sibling spawn AFTER a shell heredoc opener whose terminator is '
        . 'never found (the false opener must not swallow the rest of the file to EOF)')
        or diag("no violation found in:\n$unterminated_heredoc_src");
    ok((grep { ($_->{target} // '') =~ /some-sibling\.t$/ } @v) > 0,
        'the post-heredoc spawn names the real sibling target');
}

my @NEGATIVE_CASES = (
    [ 'a .t name inside a diag()',
      qq{diag("see plugins/butler/tests/t/some-sibling.t for details");\n} ],
    [ 'a .t name compared with is()',
      qq{is(\$name, 'plugins/butler/tests/t/some-sibling.t', 'name matches');\n} ],
    [ 'a .t name used only as a hash key',
      qq{\$seen{'plugins/butler/tests/t/some-sibling.t'} = 1;\n} ],
    [ 'a .t name inside a plain comment',
      qq{# see plugins/butler/tests/t/some-sibling.t for the matrix\n} ],
    [ 'a .t name inside a heredoc body that is never executed',
      qq{my \$doc = <<'EOF';\nRun: perl plugins/butler/tests/t/some-sibling.t\nEOF\n} ],
    [ 'a spawn-shaped keyword sitting inside a regex literal, not real call syntax'
      . ' (resources-panel.t\'s own _gather_resources guard)',
      qq{my \$qr = qr/\\bopen2\\s*\\(/;\nunlike(\$body, \$qr, 'no open2 in body');\n} ],
    [ 'a path built in its own tempdir, then run (Decision 11\'s own-fixture carve-out)',
      qq{my \$tmpdir = File::Temp::tempdir(CLEANUP => 1);\nmy \$fixture = "\$tmpdir/generated.t";\nopen(my \$fh, '>', \$fixture) or die;\nclose \$fh;\nmy \$out = `perl "\$fixture" 2>&1`;\n} ],
    [ 'a piped open() that spawns bash with no .t reference at all',
      qq{open(my \$fh, '-|', 'bash', '-c', 'echo hi') or die;\n} ],
);

for my $case (@NEGATIVE_CASES) {
    my ($label, $src) = @$case;
    my @v = scan_source($src);
    is(scalar(@v), 0, "ignores: $label")
        or diag('violations found: ' . join('; ', map { "$_->{form}:" . ($_->{target} // '?') } @v));
}

# --- the allowlist mechanism itself ----------------------------------------
ok(!exists $ALLOWLIST{'reporter-gate-regression.t'}, 'allowlist no longer names reporter-gate-regression.t (deleted by package 16 batch B)');
ok(!exists $ALLOWLIST{'arming-binds-or-reports.t'}, 'allowlist no longer names arming-binds-or-reports.t (deleted by package 16 batch B)');

ok(exists $ALLOWLIST{'sweep-coverage-honesty.t'}, 'allowlist seeded: sweep-coverage-honesty.t (own skip-reporting subject, not a stays-green floor)');
like($ALLOWLIST{'sweep-coverage-honesty.t'}, qr/not a stays-green floor/, 'allowlist entry carries its reason');

ok(!exists $ALLOWLIST{'dispatch-write-path.t'}, 'sanity: dispatch-write-path.t is NOT pre-allowlisted');
ok(!exists $ALLOWLIST{'row-budget-and-preview.t'}, 'sanity: row-budget-and-preview.t is NOT pre-allowlisted');

# ===========================================================================
# The real tree. Same glob() as test-naming-hygiene.t / scripts/run-tests.pl.
# ===========================================================================
my @files = sort glob("$ROOT/plugins/*/tests/t/*.t");

ok(scalar(@files) > 0, 'collected at least one file via glob("plugins/*/tests/t/*.t")')
    or BAIL_OUT('no test files collected -- glob expression is broken, nothing else in this file can be trusted');

# A spawn target is only a real "sibling rerun" when its BASENAME is a real
# repo test file that actually exists under plugins/*/tests/t/ -- this is
# what excludes green-baseline.t's pkgP/oracle.t, a fixture the test builds
# under its OWN materialized-tree path, whose basename ("oracle.t") is not
# among the files this same glob() just collected. This filter applies ONLY
# here, at the real-tree scan -- never inside scan_source()/
# find_helper_call_violations() themselves, whose fixture cases above use
# made-up basenames ("some-sibling.t") that are never meant to exist on disk.
my %real_basename = map { basename($_) => 1 } @files;

my %flagged; # basename => [violations]
for my $f (@files) {
    my $b = basename($f);
    next if exists $ALLOWLIST{$b};
    open my $fh, '<', $f or do { diag("cannot read $f: $!"); next; };
    local $/;
    my $content = <$fh>;
    close $fh;
    my @v = grep { defined $_->{target} && $real_basename{ basename($_->{target}) } }
            (scan_source($content), find_helper_call_violations($content));
    $flagged{$b} = [ $f, @v ] if @v;
}

unless (ok(scalar(keys %flagged) == 0,
    'no plugins/*/tests/t/*.t spawns a repo sibling .t as a "stays green" floor (Decision 11 / AC-1)')) {
    for my $b (sort keys %flagged) {
        my ($path, @v) = @{ $flagged{$b} };
        diag("$b:");
        diag("    line $_->{line}: $_->{form} -> " . ($_->{target} // '?')) for @v;
    }
}

# No real-tree "X is still flagged" assertions: package 17 removes those re-runs, so such a pin
# would go red exactly when the work is done. That the scanner CATCHES each real-world shape
# (dispatch-write-path's backticks, row-budget's helper, judge-starvation's run_capture list-open,
# lane-property's variable-into-helper) is proven by the inline fixture cases above.

for my $fp (qw(fleet-event-source.t keepawake-probe.t green-baseline.t)) {
    ok(!exists $flagged{$fp}, "does not flag $fp (heuristic false positive, driver-confirmed)");
}

# --- package 17's third pass: the perl -c compile-check family is a syntax
# check, never an execution, so none of these six may be flagged. --------
for my $dc (qw(
    backup-closeout.t backup-export.t backup-preflight.t backup-vault.t
    backup-wrapper.t lane-routing.t
)) {
    ok(!exists $flagged{$dc}, "does not flag $dc (perl -c compile check on self, not a re-run)");
}

# sweep-coverage-honesty.t is allowlisted, not fixed -- it never reaches the
# scan at all (the allowlist skip above), so it cannot appear in %flagged.
ok(!exists $flagged{'sweep-coverage-honesty.t'},
    'does not flag sweep-coverage-honesty.t (allowlisted: own skip-reporting subject, not a stays-green floor)');

# --- the real-tree scan flags EXACTLY the 13 files named in the ledger's
# newest attempt entry -- Lint v2's flagged set, minus nothing, plus nothing.
my @EXPECT_FLAGGED = sort qw(
    dispatch-write-path.t row-budget-and-preview.t ledger-guard.t
    wait-shape-guard.t runstate-agent-aggregation.t spend-drive-solo-session.t
    suspend-visibility.t almanac-record-format.t dispatch-record-attribution.t
    idle-footprint.t blueprints-panel-tree.t judge-starvation.t
    lane-property-not-mention.t
);
# Not an assertion: package 17 exists to make %flagged EMPTY (the real-tree scan above), so pinning
# today's offender list would go red exactly when the work is finished. The list the package started
# from is kept for the record and reported when anything is still flagged.
diag('still flagged (package 17 started from: ' . join(', ', @EXPECT_FLAGGED) . '): '
     . join(', ', sort keys %flagged)) if %flagged;

done_testing();
