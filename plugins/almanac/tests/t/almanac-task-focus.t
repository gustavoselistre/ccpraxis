#!/usr/bin/env perl
# platform: any
# Immutable oracle for the focus surface of the project tasklist script
# (blueprint almanac-records, package 07): focus/focused/unfocus keyed to the
# live session id (never a pid/time/placeholder), stable across a `--resume`
# as measured in harness-facts (d) d1 (DC-RES), and "focusing a second
# tasklist replaces, never doubles" (DC-ONE). CRUD and ordering verbs live in
# the sibling suites. Every CLI call below sets or deletes
# CLAUDE_CODE_SESSION_ID EXPLICITLY, per spec section 4.3's binding rule. See
# specs/07-tasklist-spec.md section 3.6.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI is
# wrapped in run_cli_sess() so "Can't open perl script" is a caught, reported
# failure for THIS assertion rather than an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TASK_PL = "$S/almanac-task.pl";

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub norm_path {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs = Encode::decode('UTF-8', $abs) unless utf8::is_utf8($abs);
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}

# run_cli_sess($session_or_undef, @args) -> { rc, out, err }
#
# $session_or_undef: a string sets CLAUDE_CODE_SESSION_ID to exactly that
# value for THIS spawn only; undef explicitly UNSETS it for this spawn
# (via `env -u`, never relying on the ambient deletion above to document
# intent at the call site, per spec section 4.3).
sub run_cli_sess {
    my ($sess, @args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    my $prefix = defined($sess) ? qq{CLAUDE_CODE_SESSION_ID="$sess" } : q{env -u CLAUDE_CODE_SESSION_ID };
    system(qq{${prefix}perl "$TASK_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub field0_val {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(.*)$/m;
    return undef;
}
sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub err_kind { return field2($_[0], 'kind') }
sub decode_json_or_undef {
    my ($text) = @_;
    return eval { JSON::PP->new->decode($text) };
}

sub task_focus_dir_for { return norm_path($_[0]) . '/.ccpraxis-local-data/almanac/task-focus' }

sub md_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

# a fixture UUID-shaped session id, as the spec's example (0409cb25-...).
my $UUID_RE = qr/^[0-9a-f]{8}$/;
sub fixture_session { my ($n) = @_; return sprintf('0000cb2%d-aaaa-bbbb-cccc-%012d', $n, $n) }

# ---------------------------------------------------------------------------
# live-store sanity + isolation guard (spec S4.4) -- before
# ---------------------------------------------------------------------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}
my $live_before = count_reports_in($LIVE_STORE);
# Decision 120(c): presence in the real gitignored live store is never REQUIRED -- only that this suite leaves its count unchanged (checked below).

sub live_almanac_listing {
    my %out;
    for my $t (qw(task task-focus decision)) {
        my $dir = "$REPO/.ccpraxis-local-data/almanac/$t";
        if (-d $dir) {
            opendir(my $dh, $dir) or next;
            $out{$t} = [ sort grep { /\.md\z/ && -f "$dir/$_" } readdir($dh) ];
            closedir $dh;
        } else {
            $out{$t} = undef;
        }
    }
    return \%out;
}
my $live_listing_before = live_almanac_listing();

ok(-f $TASK_PL, 'almanac-task.pl exists at plugins/almanac/scripts/almanac-task.pl')
    or diag('almanac-task.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

# =============================================================================
# F1 -- three separate processes, the harness-facts (d) d1 shape: process 1
# focuses with env S1; process 2 (no --session, env S1) sees it; process 3
# (env deleted, --session S1) sees the same -- proving the identity survives
# a process boundary regardless of which surface (env vs flag) carries it.
# =============================================================================
{
    my $S1 = fixture_session(1);
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    my $r1 = run_cli_sess($S1, 'focus', '--root', $ROOT);
    is($r1->{rc}, 0, 'F1: process 1 -- focus --root R with env S1 exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'F1: process 1 -- changed: yes');
    is(field0($r1->{out}, 'session'), $S1, 'F1: process 1 -- result block session: matches S1');

    my $r2 = run_cli_sess($S1, 'focused', '--root', $ROOT); # env S1, no --session
    is($r2->{rc}, 0, 'F1: process 2 (separate spawn, env S1, no --session) -- focused exits 0') or diag("stderr: $r2->{err}");
    is(field0_val($r2->{out}, 'tasklist'), norm_path($ROOT), 'F1: process 2 -- tasklist equals norm_path(R)');

    my $r3 = run_cli_sess(undef, 'focused', '--root', $ROOT, '--session', $S1); # env deleted, --session S1
    is($r3->{rc}, 0, 'F1: process 3 (env deleted, --session S1) -- focused exits 0') or diag("stderr: $r3->{err}");
    is(field0_val($r3->{out}, 'tasklist'), norm_path($ROOT), 'F1: process 3 -- tasklist equals norm_path(R), same as process 2');
}

# =============================================================================
# F2 -- the focus record lives at exactly
# R/.ccpraxis-local-data/almanac/task-focus/S1.md, and is the only .md there.
# =============================================================================
{
    my $S1 = fixture_session(2);
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $r = run_cli_sess($S1, 'focus', '--root', $ROOT);
    is($r->{rc}, 0, 'F2 fixture: focus exits 0') or diag("stderr: $r->{err}");

    my $dir = task_focus_dir_for($ROOT);
    ok(-f "$dir/$S1.md", "F2: the record file is exactly <root>/.ccpraxis-local-data/almanac/task-focus/$S1.md");
    my @files = md_files_in($dir);
    is(scalar(@files), 1, 'F2: it is the only .md file in that directory');
    is($files[0] // '', "$S1.md", 'F2: ...and its name is the session id, not a pid/time') if @files;
}

# =============================================================================
# F3 -- a different session sees no focus.
# =============================================================================
{
    my $S1 = fixture_session(3);
    my $S2 = fixture_session(30);
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    run_cli_sess($S1, 'focus', '--root', $ROOT);

    my $r = run_cli_sess($S2, 'focused', '--root', $ROOT);
    is($r->{rc}, 0, 'F3: focused with a DIFFERENT session exits 0') or diag("stderr: $r->{err}");
    is(field0_val($r->{out}, 'tasklist'), '-', 'F3: tasklist: -');

    my $rjson = run_cli_sess($S2, 'focused', '--root', $ROOT, '--json');
    is($rjson->{rc}, 0, 'F3: focused --json with a different session exits 0') or diag("stderr: $rjson->{err}");
    my $decoded = decode_json_or_undef($rjson->{out});
    ok(ref($decoded) eq 'HASH', 'F3: --json output decodes to a hash') or diag("raw: $rjson->{out}");
    if (ref($decoded) eq 'HASH') {
        is($decoded->{session}, $S2, 'F3: --json session equals S2');
        is($decoded->{tasklist}, undef, 'F3: --json tasklist is null/undef');
        ok(exists $decoded->{tasklist}, 'F3: --json still carries a tasklist key (explicitly null, not omitted)');
    }
}

# =============================================================================
# F4 -- --session beats the env var.
# =============================================================================
{
    my $S1 = fixture_session(4);
    my $S2 = fixture_session(40);
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    my $r = run_cli_sess($S1, 'focus', '--root', $ROOT, '--session', $S2);
    is($r->{rc}, 0, 'F4: focus --session S2 with env S1 exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'session'), $S2, 'F4: the result block reports session: S2, not S1');

    my $r_s2 = run_cli_sess(undef, 'focused', '--root', $ROOT, '--session', $S2);
    is(field0_val($r_s2->{out}, 'tasklist'), norm_path($ROOT), 'F4: focused --session S2 sees the new focus');

    my $r_s1 = run_cli_sess($S1, 'focused', '--root', $ROOT);
    is(field0_val($r_s1->{out}, 'tasklist'), '-', 'F4: focused via env S1 alone (never used as the acting session) sees no focus');
}

# =============================================================================
# F5 -- no session identity at all; a session value failing the grammar.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $r = run_cli_sess(undef, 'focus', '--root', $ROOT);
    is($r->{rc}, 2, 'F5: focus with no env and no --session exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'F5: ...kind: usage');
    is(field2($r->{err}, 'detail'), 'no_session', 'F5: ...detail: no_session');
    ok(!-d task_focus_dir_for($ROOT), 'F5: the task-focus directory was never created');

    my $rbad = run_cli_sess(undef, 'focus', '--root', $ROOT, '--session', '../x');
    is($rbad->{rc}, 2, 'F5: --session ../x exits 2') or diag("stderr: $rbad->{err}");
    is(err_kind($rbad->{err}), 'usage', 'F5: ...kind: usage (bad_session)');
    is(field2($rbad->{err}, 'detail'), 'bad_session', 'F5: ...detail: bad_session');
    ok(!-d task_focus_dir_for($ROOT), 'F5: the task-focus directory is still absent after the bad --session attempt');
}

# =============================================================================
# F6 -- focusing a second tasklist REPLACES, never doubles (DC-ONE).
# =============================================================================
{
    my $S1 = fixture_session(6);
    my $PROJECT = tempdir(CLEANUP => 1);
    $PROJECT =~ s{\\}{/}g;
    my $R1 = tempdir(CLEANUP => 1);
    $R1 =~ s{\\}{/}g;
    my $R2 = tempdir(CLEANUP => 1);
    $R2 =~ s{\\}{/}g;

    my $r1 = run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $R1);
    is($r1->{rc}, 0, 'F6: focus --tasklist R1 exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'F6: first focus -- changed: yes');

    my $r2 = run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $R2);
    is($r2->{rc}, 0, 'F6: focus --tasklist R2 (re-focus) exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'yes', 'F6: re-focus onto a DIFFERENT tasklist -- changed: yes');

    my $dir1 = task_focus_dir_for($PROJECT);
    my @files1 = md_files_in($dir1);
    is(scalar(@files1), 1, 'F6: exactly one .md exists in the PROJECT\'s task-focus directory (never two)');

    my $r_focused = run_cli_sess($S1, 'focused', '--root', $PROJECT);
    is(field0_val($r_focused->{out}, 'tasklist'), norm_path($R2), 'F6: focused now reports R2');

    ok(!-d task_focus_dir_for($R2), 'F6: R2 itself has no task-focus directory (nothing written under the focused tasklist)');

    my $r3 = run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $R2);
    is($r3->{rc}, 0, 'F6: re-focusing the SAME tasklist again exits 0') or diag("stderr: $r3->{err}");
    is(field0($r3->{out}, 'changed'), 'no', 'F6: ...changed: no (idempotent)');
}

# =============================================================================
# F7 -- two sessions in one project focus independently.
# =============================================================================
{
    my $S1 = fixture_session(7);
    my $S2 = fixture_session(70);
    my $PROJECT = tempdir(CLEANUP => 1);
    $PROJECT =~ s{\\}{/}g;
    my $R1 = tempdir(CLEANUP => 1);
    $R1 =~ s{\\}{/}g;
    my $R2 = tempdir(CLEANUP => 1);
    $R2 =~ s{\\}{/}g;

    run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $R1);
    run_cli_sess($S2, 'focus', '--root', $PROJECT, '--tasklist', $R2);

    my $rf1 = run_cli_sess($S1, 'focused', '--root', $PROJECT);
    is(field0_val($rf1->{out}, 'tasklist'), norm_path($R1), 'F7: S1\'s focused reports R1');
    my $rf2 = run_cli_sess($S2, 'focused', '--root', $PROJECT);
    is(field0_val($rf2->{out}, 'tasklist'), norm_path($R2), 'F7: S2\'s focused reports R2 (independent of S1)');

    my $dir = task_focus_dir_for($PROJECT);
    my @files = sort(md_files_in($dir));
    is_deeply(\@files, [sort ("$S1.md", "$S2.md")], 'F7: the project\'s task-focus directory holds exactly one record per session');
}

# =============================================================================
# F8 -- unfocus.
# =============================================================================
{
    my $S1 = fixture_session(8);
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    run_cli_sess($S1, 'focus', '--root', $ROOT);

    my $r1 = run_cli_sess($S1, 'unfocus', '--root', $ROOT);
    is($r1->{rc}, 0, 'F8: unfocus exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'F8: first unfocus -- changed: yes');

    my $rf = run_cli_sess($S1, 'focused', '--root', $ROOT);
    is(field0_val($rf->{out}, 'tasklist'), '-', 'F8: focused now reports -');

    my $r2 = run_cli_sess($S1, 'unfocus', '--root', $ROOT);
    is($r2->{rc}, 0, 'F8: a second unfocus exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'no', 'F8: second unfocus -- changed: no');
}

# =============================================================================
# F9 -- --tasklist naming a path that is not an existing directory.
# =============================================================================
{
    my $S1 = fixture_session(9);
    my $PROJECT = tempdir(CLEANUP => 1);
    $PROJECT =~ s{\\}{/}g;
    my $R1 = tempdir(CLEANUP => 1);
    $R1 =~ s{\\}{/}g;
    run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $R1);

    my $ghost = "$PROJECT/does-not-exist-ghost-dir";
    ok(!-d $ghost, 'F9 fixture: the ghost path genuinely does not exist');
    my $r = run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $ghost);
    is($r->{rc}, 2, 'F9: --tasklist <nonexistent> exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'F9: ...kind: usage');
    is(field2($r->{err}, 'detail'), 'bad_tasklist', 'F9: ...detail: bad_tasklist');

    my $rf = run_cli_sess($S1, 'focused', '--root', $PROJECT);
    is(field0_val($rf->{out}, 'tasklist'), norm_path($R1), 'F9: the prior focus (R1) is unchanged after the refused attempt');
}

# =============================================================================
# F10 -- a --tasklist path containing non-ASCII round-trips exactly.
# =============================================================================
{
    my $S1 = fixture_session(10);
    my $PROJECT = tempdir(CLEANUP => 1);
    $PROJECT =~ s{\\}{/}g;
    my $name = "proj\x{e9}"; # proj + e-acute
    my $subdir = "$PROJECT/$name";
    make_path($subdir) or die "fixture: cannot create $subdir: $!";
    ok(-d $subdir, 'F10 fixture: the non-ASCII subdirectory exists');

    my $r = run_cli_sess($S1, 'focus', '--root', $PROJECT, '--tasklist', $subdir);
    is($r->{rc}, 0, 'F10: focus --tasklist <non-ASCII dir> exits 0') or diag("stderr: $r->{err}");

    my $rf = run_cli_sess($S1, 'focused', '--root', $PROJECT);
    is($rf->{rc}, 0, 'F10: focused exits 0') or diag("stderr: $rf->{err}");
    is(field0_val($rf->{out}, 'tasklist'), norm_path($subdir),
       'F10: focused prints exactly this test\'s own norm_path() of the non-ASCII directory');
}

# =============================================================================
# F11 -- isolation guard (spec S4.4), at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "F11: the live bug-reports store's report count is unchanged by this suite ($live_before before, $live_after after)");

    my $live_listing_after = live_almanac_listing();
    is_deeply($live_listing_after, $live_listing_before,
       'F11: the repo\'s own .ccpraxis-local-data/almanac/{task,task-focus,decision} listings are unchanged');
}

done_testing();
