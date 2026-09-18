#!/usr/bin/env perl
# platform: any
# Spec: 02-run-finish-guard-reads-invocations. guard-run-finish.sh's section 1
# ("is_run_ending") is today a bare glob over the RAW command string -- any
# text merely MENTIONING bp-runstate/bp-continuity + finish/disarm/off (inside
# a quoted arg, a --text value, a perl -pe replacement string) reads
# identically to an actual invocation. This package replaces section 1 with
# bp_rf_scan_target / bp_rf_is_run_ending, reusing guard-git-mutations.sh's
# quoted-span-masking TECHNIQUE (reimplemented in this file, never called
# from the sibling). It also shortens the denial's outstanding-work block to
# <=5 lines + a count + an "... and N more." trailer.
#
# Harness convention copied from the NEIGHBOURING test for the SAME hook,
# run-finish-guard.t (sections 2-4): hermetic File::Temp project root with
# fabricated ledgers and a fabricated transcript, driven end-to-end via a
# constructed JSON payload piped to the hook's stdin. Nothing here reads the
# real blueprints, the real registry or the real session.
# test-wakelock-hygiene.t R3: this file's denial text names `bp-continuity.pl
# hold` in prose (via the sibling file's own denial banner), so the opt-out
# is required by the same naming-not-calling rule as the neighbour.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $GUARD = "$Bin/../../hooks/guard-run-finish.sh";
ok(-f $GUARD, 'the guard exists on disk') or BAIL_OUT('guard-run-finish.sh missing');

# --- fixtures (copied from run-finish-guard.t's convention) ----------------

sub make_root {
    my (@statuses) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $pdir = File::Spec->catdir($root, '.ccpraxis-local-data', 'blueprints', 'bp-x', 'packages');
    make_path($pdir);
    my $i = 0;
    for my $st (@statuses) {
        $i++;
        my $f = File::Spec->catfile($pdir, sprintf('%02d-pkg.md', $i));
        open my $fh, '>', $f or die "fixture: $!";
        print {$fh} "---\npackage: %02d-pkg\nstatus: $st\n---\n\n# fixture\n";
        close $fh;
    }
    return $root;
}

my $J = JSON::PP->new->canonical;

# A transcript with an arbitrary sequence of user-authored messages; the LAST
# one is what section 4's authorisation scan reads.
sub make_transcript {
    my (@texts) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $f   = File::Spec->catfile($dir, 'transcript.jsonl');
    open my $fh, '>', $f or die "transcript: $!";
    print {$fh} $J->encode({ type => 'assistant', message => { role => 'assistant',
                             content => [ { type => 'text', text => 'working' } ] } }), "\n";
    for my $t (@texts) {
        print {$fh} $J->encode({ type => 'user', message => { role => 'user',
                                 content => [ { type => 'text', text => $t } ] } }), "\n";
    }
    close $fh;
    return $f;
}

# Run the guard with a constructed payload. Returns ($rc, $stderr).
sub run_guard {
    my (%o) = @_;
    my $payload = JSON::PP->new->encode({
        tool_name  => 'Bash',
        tool_input => { command => $o{command} },
        ($o{transcript} ? (transcript_path => $o{transcript}) : ()),
    });
    my $errf = File::Spec->catfile(tempdir(CLEANUP => 1), 'err');
    # THE IDLE PREMISE IS CONSTRUCTED, NOT ASSUMED -- see run-finish-guard.t's
    # own note on bug 20260916-150236-6684 / ff464b6. Without an explicit
    # continuity dir these cases read the REAL machine registry.
    my %env = (
        BP_PROJECT_ROOT                => $o{root} // '',
        CCPRAXIS_DRIVE_ACTIVE_DIR      => $o{drive_dir} // '',
        CCPRAXIS_CONTINUITY_ACTIVE_DIR => $o{cont_dir} // tempdir(CLEANUP => 1),
    );
    local %ENV = (%ENV, %env);
    delete $ENV{$_} for grep { !length $env{$_} } keys %env;
    open my $fh, '|-', "bash \"$GUARD\" 2> \"$errf\"" or die "spawn: $!";
    print {$fh} $payload;
    close $fh;
    my $rc  = $? >> 8;
    my $err = -f $errf ? do { local (@ARGV, $/) = ($errf); <> } : '';
    return ($rc, defined $err ? $err : '');
}

sub live_drive_dir {
    my $d = tempdir(CLEANUP => 1);
    open my $fh, '>', File::Spec->catfile($d, 'fixture-session-id') or die "marker: $!";
    print {$fh} "fixture\n";
    close $fh;
    return $d;
}

# Deny preconditions shared by AC1(active)/AC2/AC3/AC4/AC5: a pending package,
# a live drive marker, and (unless overridden) a transcript with NO stop
# instruction as the last user message -- mirrors run-finish-guard.t's "A"
# block exactly.
my $DENY_DD = live_drive_dir();

# =============================================================================
# AC1 (done criterion 1 -- false positives allowed). F1-F3 exact fixture text
# per spec section 4. None contain a backslash, '#', or '<<', so all three
# exercise the masked path specifically.
# =============================================================================

my $F1 = q{perl -0777 -i -pe "s/OLD NOTE/Reminder: the guard denies bp-continuity.pl off unless the operator said so/" .ccpraxis-local-data/RESUME.md};
my $F2 = q{perl plugins/butler/scripts/bp-continuity.pl ask --text "the guard's pattern is literally *bp-continuity*disarm* -- why did it fire on a status check"};
my $F3 = q{printf '%s' "False positive: guard-run-finish.sh blocked a command that merely mentioned bp-runstate.pl finish and bp-continuity.pl disarm in prose, with neither script actually invoked" >> .ccpraxis-local-data/bug-reports/20260918-060540-2113.md};

# AC1a: literal spec wording -- default/no upstream state -> exits 0, empty
# stderr. (Does not by itself discriminate old vs new code: fail-open already
# allows this either way. Included because the spec asks for it explicitly.)
for my $pair ([F1 => $F1], [F2 => $F2], [F3 => $F3]) {
    my ($name, $cmd) = @$pair;
    my ($rc, $err) = run_guard(command => $cmd);   # no root/drive/transcript at all
    is($rc, 0, "AC1a ($name): default/no upstream state -> exits 0");
    is($err, '', "AC1a ($name): ...with empty stderr");
}

# AC1b: THE REAL ORACLE. Same fixtures, but with every upstream deny
# precondition satisfied (pending package, live drive marker, no stop
# instruction) -- a command that only MENTIONS the tokens must still exit 0,
# because bp_rf_is_run_ending must resolve false via the masked scan. Today's
# bare glob matches these substrings regardless of quoting and WILL deny
# (rc=2): this is where the fix is proven.
for my $pair ([F1 => $F1], [F2 => $F2], [F3 => $F3]) {
    my ($name, $cmd) = @$pair;
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 0, "AC1b ($name): mention-only command is NOT blocked even with an active run and outstanding work");
    is($err, '', "AC1b ($name): ...and prints nothing to stderr");
}

# =============================================================================
# AC2 (done criterion 2 -- real invocations still denied, baseline). D1-D3
# exact fixture text.
# =============================================================================

my %AC2 = (D1 => 'bp-runstate.pl finish', D2 => 'bp-continuity.pl disarm', D3 => 'bp-continuity.pl off');
for my $name (sort keys %AC2) {
    my $cmd = $AC2{$name};
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 2, "AC2 ($name): direct invocation '$cmd' is DENIED");
    like($err, qr/BLOCKED \(butler run-finish guard\)/, "AC2 ($name): ...with the guard's own banner");
}

# =============================================================================
# AC3 (done criterion 2 -- the three adversarial shapes). D4-D6 exact fixture
# text, each exercising a different RF_RAW_KIND degrade path.
# =============================================================================

my %AC3 = (
    'D4 (shellword)' => 'bash -c "bp-runstate.pl finish"',
    'D5 (carrier)'   => 'result=`bp-runstate.pl finish`',
    'D6 (raw-fallback via unquoted #)' => 'curl http://example.com/x#section; bp-runstate.pl finish',
);
for my $name (sort keys %AC3) {
    my $cmd = $AC3{$name};
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 2, "AC3 ($name): adversarial-shape invocation '$cmd' is still DENIED");
}

# =============================================================================
# Fix-batch 01 (red-team Finding 1, CRITICAL): a single-word quoted verb/
# argument is the ACTUAL invocation, byte-identical to its unquoted form --
# `finish`, "finish" and 'finish' are the same argv entry in bash. The
# masking walk previously blanked EVERY quoted span (single-word or not) to
# X, so these real invocations went undetected. Now only MULTI-WORD quoted
# spans (containing internal whitespace -- prose, F1-F3) get masked; a
# single-word span is scanned literal/unquoted. D7-D10 below are new,
# byte-identical-to-D1/D2/D3 invocations that merely quote the verb.
# =============================================================================

my %FB1 = (
    D7  => 'bp-runstate.pl "finish"',
    D8  => q{bp-runstate.pl 'finish'},
    D9  => q{bp-continuity.pl 'disarm'},
    D10 => 'bp-continuity.pl "off"',
);
for my $name (sort keys %FB1) {
    my $cmd = $FB1{$name};
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 2, "FB1 ($name): quoted-verb invocation '$cmd' is DENIED (was a false negative pre-fix)");
    like($err, qr/BLOCKED \(butler run-finish guard\)/, "FB1 ($name): ...with the guard's own banner");
}

# =============================================================================
# Fix-batch 02 (red-team redteam-02 Finding A, MEDIUM): the single-word
# carve-out above had no positional constraint, so a single-word quoted span
# ANYWHERE in the command -- not just in verb position right after
# bp-runstate.pl/bp-continuity.pl -- unmasked to its literal content. That
# false-positived the guard's OWN documented escape hatch: a legitimate
# `bp-continuity.pl ask --text "off"` (an operator/agent queuing a one-word
# question) quoted a single guarded keyword as a --text VALUE, unrelated to
# the script-name position, and got wrongly DENIED as if it were the real
# `bp-continuity.pl off` invocation. Fixed by requiring the unmasked
# carve-out to sit immediately after one of the two script names; a
# single-word quote anywhere else (e.g. after --text) stays X-masked, same as
# a multi-word span and same as pre-fix-batch-01 behaviour for that position.
# These two must stay NOT DENIED (rc=0, no block) even with every other deny
# precondition satisfied.
# =============================================================================

my %FB2_ESCAPE_HATCH = (
    'text=off'    => 'bp-continuity.pl ask --text "off"',
    'text=disarm' => 'bp-continuity.pl ask --text "disarm"',
);
for my $name (sort keys %FB2_ESCAPE_HATCH) {
    my $cmd = $FB2_ESCAPE_HATCH{$name};
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 0, "FB2 ($name): escape-hatch invocation '$cmd' is NOT detected/denied (positional false-positive fix)");
    is($err, '', "FB2 ($name): ...with empty stderr");
}

# NOT FIXED, AND NOT CLAIMED FIXED: variable indirection through a quoted
# expansion (`V=finish; bp-runstate.pl "$V"`) is a genuine run-ending
# invocation at execution time -- the shell substitutes $V's literal value
# before bp-runstate.pl ever sees its argv -- but a STATIC TEXT SCAN over the
# command string cannot resolve a variable's runtime value from source text
# alone; "$V" is not the string "finish" until the shell evaluates it. This
# is accepted as a still-open gap alongside the perl -e interpreter-smuggling
# gap (Decision 14), not silently declined: the assertion below documents,
# rather than hides, that it stays UNDETECTED.
{
    my $cmd = 'V=finish; bp-runstate.pl "$V"';
    my ($rc, $err) = run_guard(command => $cmd, root => make_root('pending'),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 0, "FB1 (variable indirection, ACCEPTED GAP): '$cmd' is NOT detected -- a static scan cannot resolve \$V's runtime value");
}

# =============================================================================
# AC4 (done criterion 3 -- operator-said-stop untouched). D1 run end-to-end
# with all deny preconditions EXCEPT the transcript's last user message
# carries an explicit stop instruction -> exits 0. Proves section 4 still
# overrides the NEW section 1, unmodified.
# =============================================================================

{
    my ($rc, $err) = run_guard(command => $AC2{D1}, root => make_root('pending'),
                               transcript => make_transcript('please stop'),
                               drive_dir => $DENY_DD);
    is($rc, 0, 'AC4: an explicit operator stop instruction still authorises the stop under the new section 1');
}

# =============================================================================
# AC5 (done criterion 4 -- shortened denial). Two $OUTSTANDING sizes: >5
# non-blank lines and <=5.
# =============================================================================

sub outstanding_block {
    my ($err) = @_;
    if ($err =~ /STILL PENDING OR RUNNING \((\d+) total, showing up to 5[^\n]*\)\n(.*?)\nWHAT TO DO INSTEAD/s) {
        return ($1, $2);
    }
    return (undef, undef);
}

{
    # >5 case: 7 pending packages.
    my ($rc, $err) = run_guard(command => $AC2{D1}, root => make_root(('pending') x 7),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 2, 'AC5 (>5): still denied');
    my ($count, $block) = outstanding_block($err);
    is($count, 7, 'AC5 (>5): header reports the TRUE count (7), not the truncated one');
    my @item_lines = ($block // '') =~ /^bp-x\/\d{2}-pkg \(pending\)$/mg;
    is(scalar(@item_lines), 5, 'AC5 (>5): at most 5 outstanding-item lines are listed');
    like($block // '', qr/\.\.\. and 2 more\.$/m, 'AC5 (>5): a trailing "... and 2 more." line is present');
}

{
    # <=5 case: 3 pending packages.
    my ($rc, $err) = run_guard(command => $AC2{D1}, root => make_root(('pending') x 3),
                               transcript => make_transcript('continue with the sweep please'),
                               drive_dir => $DENY_DD);
    is($rc, 2, 'AC5 (<=5): still denied');
    my ($count, $block) = outstanding_block($err);
    is($count, 3, 'AC5 (<=5): header reports the true count (3)');
    my @item_lines = ($block // '') =~ /^bp-x\/\d{2}-pkg \(pending\)$/mg;
    is(scalar(@item_lines), 3, 'AC5 (<=5): every one of the <=5 lines is still shown');
    unlike($block // '', qr/\.\.\. and/, 'AC5 (<=5): no "... and N more." trailer when the count does not exceed 5');
}

done_testing();
