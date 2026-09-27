#!/usr/bin/env perl
# platform: any
# Immutable oracle for the CRUD surface of the project tasklist script
# (blueprint almanac-records, package 07): create/list/show/status/edit in
# project scope only, the five-status set (DC-STAT), blocked_on grammar and
# check_refs() (DC-REF), and module-shape rules (no session predecessor, no
# global scope). Ordering verbs live in the sibling ordering suite; focus
# lives in the sibling focus suite. See specs/07-tasklist-spec.md.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file -- every assertion below is expected to
# fail for exactly that reason right now, not for a fixture defect of this
# file's own making.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec ();
use Cwd ();
use Encode ();
use JSON::PP ();
use Scalar::Util qw(refaddr);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TASK_PL = "$S/almanac-task.pl";

# ---------------------------------------------------------------------------
# no real user state: every spawn and every in-process call below inherits
# this file-scoped, per-file tempdir HOME/USERPROFILE/ALMANAC_HOME; the two
# ambient env vars a store might otherwise consult are deleted.
# ---------------------------------------------------------------------------
my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}              = $FILE_HOME;
local $ENV{USERPROFILE}       = $FILE_HOME;
local $ENV{ALMANAC_HOME}      = $FILE_HOME;
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

sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

# run_cli(@args) -> { rc, out, err } -- real process, temp-file captures
# (never an in-memory STDOUT reopen -- CLAUDE.md's Windows landmine list).
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$TASK_PL" $argstr > "$outpath" 2> "$errpath"});
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

sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub err_kind { return field2($_[0], 'kind') }

# read_frontmatter($path) -> (\@keys, \%kv)
sub read_frontmatter {
    my ($path) = @_;
    my @lines = read_all_lines($path);
    my (@keys, %kv);
    my $in = 0;
    for my $l (@lines) {
        if ($l =~ /\A---/) {
            last if $in;
            $in = 1;
            next;
        }
        if ($in && $l =~ /\A([A-Za-z0-9_]+):\s?(.*?)\r?\n?\z/) {
            push @keys, $1;
            $kv{$1} = $2;
        }
    }
    return (\@keys, \%kv);
}

sub decode_json_or_undef {
    my ($text) = @_;
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub task_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

sub task_dir_for {
    my ($root) = @_;
    return norm_path($root) . '/.ccpraxis-local-data/almanac/task';
}

# ---------------------------------------------------------------------------
# live-store sanity + isolation guard (house convention, spec S4.4) -- before
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
        $out{$t} = -d $dir ? [ sort(task_files_in($dir)) ] : undef;
    }
    return \%out;
}
my $live_listing_before = live_almanac_listing();

ok(-f $TASK_PL, 'almanac-task.pl exists at plugins/almanac/scripts/almanac-task.pl')
    or diag('almanac-task.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

do $TASK_PL if -f $TASK_PL;

# =============================================================================
# C9 -- module-shape rules, by grep. Run whether or not the script loaded.
# =============================================================================
{
    if (-f $TASK_PL) {
        my @lines = read_all_lines($TASK_PL);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        my (@exit_hits, @unverified_hits, @sidhash_hits, @transcript_hits, @dashdash_line);
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            push @exit_hits, "$TASK_PL:$lineno: $line"
                if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/)
                && (!defined($caller_line) || $lineno < $caller_line);
            push @unverified_hits, "$TASK_PL:$lineno: $line" if $line =~ /unverified/;
            push @sidhash_hits, "$TASK_PL:$lineno: $line" if $line =~ /\{session_id\}|\{'session_id'\}/;
            push @transcript_hits, "$TASK_PL:$lineno: $line" if $line =~ /transcript/;
            push @dashdash_line, "$TASK_PL:$lineno: $line" if $line =~ /^\s*---\s*$/;
        }
        ok(defined $caller_line, 'C9: the file contains an `unless (caller)` main guard line')
            or diag('no `unless (caller)` found');
        unless (ok(@exit_hits == 0, 'C9: no `exit` statement occurs before the `unless (caller)` line')) {
            diag($_) for @exit_hits;
        }
        unless (ok(@unverified_hits == 0, "C9: the file never contains the literal 'unverified'")) { diag($_) for @unverified_hits }
        unless (ok(@sidhash_hits == 0, 'C9: the file never accesses {session_id} / {\'session_id\'} as a hash key'))
            { diag($_) for @sidhash_hits }
        unless (ok(@transcript_hits == 0, "C9: the file never mentions 'transcript'")) { diag($_) for @transcript_hits }
        unless (ok(@dashdash_line == 0, 'C9: the file contains no line matching /^---/ (no frontmatter parsing of its own)'))
            { diag($_) for @dashdash_line }

        my @global_flag_hits = grep { /--global/ } @lines;
        ok(@global_flag_hits == 0, "C9: the file never mentions the literal '--global'");

        my @package_hits = grep { /^\s*package\s+Almanac::Task\s*;/ } @lines;
        ok(@package_hits >= 1, 'C9: the file declares `package Almanac::Task;`');
    } else {
        fail("C9: $_") for (
            'the file contains an `unless (caller)` main guard line',
            'no `exit` statement occurs before the `unless (caller)` line',
            "the file never contains the literal 'unverified'",
            'the file never accesses {session_id} / {\'session_id\'} as a hash key',
            "the file never mentions 'transcript'",
            'the file contains no line matching /^---/ (no frontmatter parsing of its own)',
            "the file never mentions the literal '--global'",
            'the file declares `package Almanac::Task;`',
        );
    }
}

# =============================================================================
# C1 -- §3.1 items 1-4: create/read.
# =============================================================================
{
    my $ROOT1 = tempdir(CLEANUP => 1);
    $ROOT1 =~ s{\\}{/}g;
    my $DIR1 = task_dir_for($ROOT1);

    # item 1: add --title on a fresh project.
    my $r = run_cli('add', '--title', 'First task', '--root', $ROOT1);
    is($r->{rc}, 0, 'C1/item1: add --title on a project with no task store exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'status'), 'pending', 'C1/item1: result block carries status: pending');
    is(field0($r->{out}, 'changed'), 'yes', 'C1/item1: result block carries changed: yes');
    my $id1 = field0($r->{out}, 'id');
    ok(defined $id1 && length $id1, 'C1/item1: result block carries a non-empty id:');

    my @files1 = task_files_in($DIR1);
    is(scalar(@files1), 1, 'C1/item1: exactly one file was written under <root>/.ccpraxis-local-data/almanac/task/');
    is($files1[0], "$id1.md", "C1/item1: the file's stem equals the result block's id") if @files1;

    my $path1 = "$DIR1/$id1.md";
    my ($keys1, $kv1) = read_frontmatter($path1);
    is($kv1->{status} // '', 'pending', 'C1/item1: frontmatter status is pending');
    like($kv1->{created} // '', qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'C1/item1: created matches the ISO-8601 UTC pattern');
    ok(!exists $kv1->{blocked_on}, 'C1/item1: no blocked_on field is present');

    # item 1 (cont.): a second add lands last in order.
    my $r2 = run_cli('add', '--title', 'Second task', '--root', $ROOT1);
    is($r2->{rc}, 0, 'C1/item1: a second add exits 0') or diag("stderr: $r2->{err}");
    my $rlist = run_cli('list', '--json', '--root', $ROOT1);
    my $decoded1 = decode_json_or_undef($rlist->{out});
    is(ref($decoded1) eq 'ARRAY' ? $decoded1->[-1]{id} : undef, field0($r2->{out}, 'id'),
       'C1/item1: the newly added task is last in list order');

    # item 2: missing/blank/CR-LF title.
    my $rmiss = run_cli('add', '--root', $ROOT1);
    is($rmiss->{rc}, 2, 'C1/item2: add with no --title at all exits 2') or diag("stderr: $rmiss->{err}");
    is(err_kind($rmiss->{err}), 'usage', 'C1/item2: ...kind: usage');
    is(field2($rmiss->{err}, 'detail'), 'missing_title', 'C1/item2: ...detail: missing_title');

    my $rbare = run_cli('add', '--root', $ROOT1, '--title');
    is($rbare->{rc}, 2, 'C1/item2: add --title with no following value exits 2') or diag("stderr: $rbare->{err}");
    is(field2($rbare->{err}, 'detail'), 'missing_title', 'C1/item2: ...detail: missing_title (bare --title)');

    my $rws = run_cli('add', '--title', '   ', '--root', $ROOT1);
    is($rws->{rc}, 2, 'C1/item2: add --title <whitespace-only> exits 2') or diag("stderr: $rws->{err}");
    is(err_kind($rws->{err}), 'usage', 'C1/item2: ...kind: usage');
    is(field2($rws->{err}, 'detail'), 'bad_title', 'C1/item2: ...detail: bad_title (whitespace-only)');

    my $rcrlf = run_cli('add', '--title', "line1\r\nline2", '--root', $ROOT1);
    is($rcrlf->{rc}, 2, 'C1/item2: add --title containing CR/LF exits 2') or diag("stderr: $rcrlf->{err}");
    is(field2($rcrlf->{err}, 'detail'), 'bad_title', 'C1/item2: ...detail: bad_title (CR/LF)');

    my @files_before_bad = task_files_in($DIR1);
    is(scalar(@files_before_bad), 2, 'C1/item2: none of the four refused adds created a file (still exactly two)');

    # item 3: --id collision, and a bad id.
    my $r3a = run_cli('add', '--title', 'Fixed id task', '--id', 'task-c1-x', '--root', $ROOT1);
    is($r3a->{rc}, 0, 'C1/item3 fixture: add --id task-c1-x succeeds') or diag("stderr: $r3a->{err}");
    my $r3b = run_cli('add', '--title', 'Dup id task', '--id', 'task-c1-x', '--root', $ROOT1);
    is($r3b->{rc}, 2, 'C1/item3: add --id <existing> exits 2') or diag("stderr: $r3b->{err}");
    is(err_kind($r3b->{err}), 'exists', 'C1/item3: ...kind: exists');
    my $r3c = run_cli('add', '--title', 'Bad id task', '--id', 'a/b', '--root', $ROOT1);
    is($r3c->{rc}, 2, 'C1/item3: add --id a/b exits 2');
    is(err_kind($r3c->{err}), 'bad_id', 'C1/item3: ...kind: bad_id');

    # item 4: show on a missing id.
    my $r4 = run_cli('show', 'no-such-task', '--root', $ROOT1);
    is($r4->{rc}, 2, 'C1/item4: show <unknown id> exits 2');
    is(err_kind($r4->{err}), 'not_found', 'C1/item4: ...kind: not_found');
    is($r4->{out}, '', 'C1/item4: STDOUT is empty');
}

# =============================================================================
# C2 -- §3.2 item 5: every one of the five statuses is accepted from pending.
# =============================================================================
{
    my @STATUSES = qw(pending doing blocked done obsoleted);
    for my $target (qw(doing blocked done obsoleted)) {
        my $ROOT = tempdir(CLEANUP => 1);
        $ROOT =~ s{\\}{/}g;
        my $rec = eval { Almanac::Task::add(root => $ROOT, title => "target $target") };
        ok(defined $rec, "C2 fixture: a fresh pending task exists to move to $target") or diag("error: $@");
        my ($after, $changed) = eval { Almanac::Task::set_status($rec->{id}, $target, root => $ROOT) } if defined $rec;
        ok(!$@, "C2: set_status(..., '$target') from pending does not die") or diag("error: $@");
        is(ref($after) eq 'HASH' ? $after->{fields}{status} : undef, $target,
           "C2: in-process set_status accepts '$target' from pending");
        is($changed, 1, "C2: set_status(..., '$target') reports changed");
    }

    # one CLI status call, for non-vacuity of the module claim above.
    my $ROOTC = tempdir(CLEANUP => 1);
    $ROOTC =~ s{\\}{/}g;
    my $rc0 = run_cli('add', '--title', 'CLI status target', '--root', $ROOTC);
    my $idc = field0($rc0->{out}, 'id');
    ok(defined $idc, 'C2 (CLI) fixture: add succeeds') or diag("stderr: $rc0->{err}");
    my $rc1 = run_cli('status', $idc, 'doing', '--root', $ROOTC);
    is($rc1->{rc}, 0, 'C2 (CLI): status ID doing exits 0') or diag("stderr: $rc1->{err}");
    is(field0($rc1->{out}, 'changed'), 'yes', 'C2 (CLI): result block carries changed: yes');
    is(field0($rc1->{out}, 'status'), 'doing', 'C2 (CLI): result block carries status: doing');
}

# =============================================================================
# C3 -- §3.2 item 7: undefined status refused, both surfaces, bytes unchanged.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $DIR = task_dir_for($ROOT);
    my $r0 = run_cli('add', '--title', 'Bad status target', '--root', $ROOT);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'C3 fixture: add succeeds') or diag("stderr: $r0->{err}");
    my $path = "$DIR/$id.md";
    my $before = slurp_raw($path);

    for my $bad ('Done', 'cancelled') {
        my $r = run_cli('status', $id, $bad, '--root', $ROOT);
        is($r->{rc}, 2, "C3: CLI status ID '$bad' exits 2") or diag("stderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "C3: ...kind: usage ('$bad')");
        is(field2($r->{err}, 'detail'), 'bad_status', "C3: ...detail: bad_status ('$bad')");
        my $after = slurp_raw($path);
        is($after, $before, "C3: the record's raw bytes are unchanged after the refused status '$bad'");
    }

    for my $bad ('open', '') {
        my $result = eval { Almanac::Task::set_status($id, $bad, root => $ROOT) };
        my $err = $@;
        ok(!defined($result) && $err, "C3: in-process set_status('$bad') dies rather than returning");
        my $kind = (ref($err) =~ /::Error$/) ? $err->{kind} : undef;
        my $detail = (ref($err) =~ /::Error$/) ? $err->{detail} : undef;
        is($kind, 'usage', "C3: ...dies with kind: usage ('$bad')");
        is($detail, 'bad_status', "C3: ...detail: bad_status ('$bad')");
    }
    my $final = slurp_raw($path);
    is($final, $before, 'C3: the record is still byte-identical after all refused in-process attempts too');
}

# =============================================================================
# C4 -- §3.2 items 6, 8, 9: no-op, edit --status refused, stale expect-rev.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $DIR = task_dir_for($ROOT);
    my $r0 = run_cli('add', '--title', 'No-op status target', '--root', $ROOT);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'C4 fixture: add succeeds') or diag("stderr: $r0->{err}");
    my $path = "$DIR/$id.md";

    # item 6: same-status no-op.
    my $before6 = slurp_raw($path);
    my $r6 = run_cli('status', $id, 'pending', '--root', $ROOT);
    is($r6->{rc}, 0, 'C4/item6: status ID <current status> exits 0') or diag("stderr: $r6->{err}");
    is(field0($r6->{out}, 'changed'), 'no', 'C4/item6: result block carries changed: no');
    my $after6 = slurp_raw($path);
    is($after6, $before6, 'C4/item6: the file bytes are unchanged by the no-op status call');

    # item 8: edit has no --status flag.
    my $r8 = run_cli('edit', $id, '--status', 'doing', '--root', $ROOT);
    is($r8->{rc}, 2, 'C4/item8: edit --status exits 2') or diag("stderr: $r8->{err}");
    is(err_kind($r8->{err}), 'usage', 'C4/item8: ...kind: usage');
    is(field2($r8->{err}, 'detail'), 'unknown_flag', 'C4/item8: ...detail: unknown_flag');

    # item 9: stale --expect-rev on status and on edit.
    my ($cur) = eval { Almanac::Task::open_tasklist(root => $ROOT)->read($id) };
    my $stale_rev = (ref($cur) eq 'HASH') ? $cur->{rev} : 'deadbeef' x 8;
    my $bump = run_cli('status', $id, 'doing', '--root', $ROOT);
    is($bump->{rc}, 0, 'C4/item9 fixture: an intervening status change succeeds, staling the earlier rev')
        or diag("stderr: $bump->{err}");

    my $before9 = slurp_raw($path);
    my $r9a = run_cli('status', $id, 'blocked', '--expect-rev', $stale_rev, '--root', $ROOT);
    is($r9a->{rc}, 2, 'C4/item9: status --expect-rev <stale> exits 2') or diag("stderr: $r9a->{err}");
    is(err_kind($r9a->{err}), 'conflict', 'C4/item9: ...kind: conflict (status)');
    my $after9a = slurp_raw($path);
    is($after9a, $before9, 'C4/item9: file bytes unchanged after the refused status conflict');

    my $r9b = run_cli('edit', $id, '--title', 'Conflicting edit', '--expect-rev', $stale_rev, '--root', $ROOT);
    is($r9b->{rc}, 2, 'C4/item9: edit --expect-rev <stale> exits 2') or diag("stderr: $r9b->{err}");
    is(err_kind($r9b->{err}), 'conflict', 'C4/item9: ...kind: conflict (edit)');
    my $after9b = slurp_raw($path);
    is($after9b, $before9, 'C4/item9: file bytes unchanged after the refused edit conflict');
}

# =============================================================================
# C5 -- §3.3 item 10: blocked_on accepts an unknown decision id.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $DIR = task_dir_for($ROOT);
    my $r = run_cli('add', '--title', 'Blocked task', '--blocked-on', 'D-unknown', '--root', $ROOT);
    is($r->{rc}, 0, 'C5: add --blocked-on D-unknown exits 0 (existence is never checked here)')
        or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    ok(defined $id, 'C5: result block carries an id');

    my ($keys, $kv) = read_frontmatter("$DIR/$id.md");
    is($kv->{blocked_on} // '', 'D-unknown', 'C5: the field is on disk exactly as given');

    my $rjson = run_cli('list', '--json', '--root', $ROOT);
    my $decoded = decode_json_or_undef($rjson->{out});
    my ($el) = ref($decoded) eq 'ARRAY' ? grep { $_->{id} eq $id } @$decoded : ();
    is(ref($el) eq 'HASH' ? $el->{blocked_on} : undef, 'D-unknown', 'C5: list --json reports the same value');
}

# =============================================================================
# C6 -- §3.3 items 11-13: blocked_on grammar, clear, nothing_to_change.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $DIR = task_dir_for($ROOT);

    # item 11: non-grammatical --blocked-on values.
    for my $bad ('a/b', '..x', '-x') {
        my $r = run_cli('add', '--title', 'Grammar target', '--blocked-on', $bad, '--root', $ROOT);
        is($r->{rc}, 2, "C6/item11: add --blocked-on '$bad' exits 2") or diag("stderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "C6/item11: ...kind: usage ('$bad')");
        is(field2($r->{err}, 'detail'), 'bad_blocked_on', "C6/item11: ...detail: bad_blocked_on ('$bad')");
    }
    my $rempty = run_cli('add', '--title', 'Grammar target', '--blocked-on', '--root', $ROOT);
    is($rempty->{rc}, 2, 'C6/item11: add --blocked-on with no following value exits 2 (missing_flag_value)')
        or diag("stderr: $rempty->{err}");
    is(field2($rempty->{err}, 'detail'), 'missing_flag_value', 'C6/item11: ...detail: missing_flag_value');
    my @files_c6 = task_files_in($DIR);
    is(scalar(@files_c6), 0, 'C6/item11: none of the four refused adds created a file');

    # item 12: --clear-blocked-on removes the field; on a task without it, no-op.
    my $r0 = run_cli('add', '--title', 'Clearable', '--blocked-on', 'D-x', '--root', $ROOT);
    my $id0 = field0($r0->{out}, 'id');
    ok(defined $id0, 'C6/item12 fixture: add --blocked-on succeeds') or diag("stderr: $r0->{err}");
    my $rclear = run_cli('edit', $id0, '--clear-blocked-on', '--root', $ROOT);
    is($rclear->{rc}, 0, 'C6/item12: edit --clear-blocked-on exits 0') or diag("stderr: $rclear->{err}");
    is(field0($rclear->{out}, 'changed'), 'yes', 'C6/item12: changed: yes when the field was present');
    my ($k12, $kv12) = read_frontmatter("$DIR/$id0.md");
    ok(!exists $kv12->{blocked_on}, 'C6/item12: the field is absent from the file after clearing');
    my $rlist12 = run_cli('list', '--root', $ROOT);
    like($rlist12->{out}, qr/\Q$id0\E\n\s+position:\s\d+\n\s+status:\s\S+\n\s+blocked_on:\s-$/m,
         'C6/item12: list default shows blocked_on: - for the cleared task');

    my $rclear2 = run_cli('edit', $id0, '--clear-blocked-on', '--root', $ROOT);
    is($rclear2->{rc}, 0, 'C6/item12: clearing an already-unblocked task exits 0') or diag("stderr: $rclear2->{err}");
    is(field0($rclear2->{out}, 'changed'), 'no', 'C6/item12: ...changed: no when the field was already absent');

    my $rboth = run_cli('edit', $id0, '--blocked-on', 'D-y', '--clear-blocked-on', '--root', $ROOT);
    is($rboth->{rc}, 2, 'C6/item12: --blocked-on and --clear-blocked-on together exit 2') or diag("stderr: $rboth->{err}");
    is(field2($rboth->{err}, 'detail'), 'blocked_on_conflict', 'C6/item12: ...detail: blocked_on_conflict');

    # item 13: edit with no change flag.
    my $before13 = slurp_raw("$DIR/$id0.md");
    my $rnothing = run_cli('edit', $id0, '--root', $ROOT);
    is($rnothing->{rc}, 2, 'C6/item13: edit with no change flag exits 2') or diag("stderr: $rnothing->{err}");
    is(err_kind($rnothing->{err}), 'usage', 'C6/item13: ...kind: usage');
    is(field2($rnothing->{err}, 'detail'), 'nothing_to_change', 'C6/item13: ...detail: nothing_to_change');
    my $after13 = slurp_raw("$DIR/$id0.md");
    is($after13, $before13, 'C6/item13: file bytes unchanged');
}

# =============================================================================
# C7 -- §3.3 item 14: check_refs() report shape, ok vs dangling.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    eval {
        require Almanac::Store;
        my $dstore = Almanac::Store->open(scope => 'project', type => 'decision', root => $ROOT);
        $dstore->create(id => 'D-known', fields => { title => 'known decision' }, order => ['title']);
    };
    ok(!$@, 'C7 fixture: a decision store with one record D-known is created directly via Almanac::Store')
        or diag("error: $@");

    my ($t1, $t2, $t3);
    eval {
        $t1 = Almanac::Task::add(root => $ROOT, title => 'T1', blocked_on => 'D-known');
        $t2 = Almanac::Task::add(root => $ROOT, title => 'T2', blocked_on => 'D-unknown');
        $t3 = Almanac::Task::add(root => $ROOT, title => 'T3');
    };
    ok(!$@ && defined($t1) && defined($t2) && defined($t3), 'C7 fixture: three tasks (T1 blocked/known, T2 blocked/unknown, T3 unblocked) exist')
        or diag("error: $@");

    my $report = eval { Almanac::Task::check_refs(root => $ROOT) };
    ok(!$@, 'C7: check_refs(root => R) does not die') or diag("error: $@");
    ok(ref($report) eq 'HASH', 'C7: check_refs returns a hashref') or diag('not a hashref');
    if (ref($report) eq 'HASH') {
        is_deeply([sort keys %$report], [sort qw(type project)], 'C7: the report has exactly the keys type/project');
        is($report->{type}, 'task', 'C7: type is the string task');
        my $proj = $report->{project};
        if (ref($proj) eq 'HASH') {
            is_deeply([sort keys %$proj], [sort qw(available reason refs dangling)],
                'C7: project has exactly available/reason/refs/dangling');
            is($proj->{available}, 1, 'C7: available == 1');
            is($proj->{reason}, 'ok', 'C7: reason == ok');
            my $refs = $proj->{refs};
            is(ref($refs) eq 'ARRAY' ? scalar(@$refs) : -1, 2, 'C7: refs has exactly two entries (T1, T2 -- T3 is absent)');
            if (ref($refs) eq 'ARRAY') {
                my ($e1) = grep { $_->{task} eq $t1->{id} } @$refs;
                my ($e2) = grep { $_->{task} eq $t2->{id} } @$refs;
                ok(defined $e1, 'C7: T1 has a refs entry');
                ok(defined $e2, 'C7: T2 has a refs entry');
                is($e1->{field}, 'blocked_on', 'C7: T1 entry field is blocked_on') if defined $e1;
                is($e1->{target}, 'D-known', 'C7: T1 entry target is D-known') if defined $e1;
                is($e1->{status}, 'ok', 'C7: T1 entry status is ok') if defined $e1;
                is($e2->{target}, 'D-unknown', 'C7: T2 entry target is D-unknown') if defined $e2;
                is($e2->{status}, 'dangling', 'C7: T2 entry status is dangling') if defined $e2;

                my $dangling = $proj->{dangling};
                is(ref($dangling) eq 'ARRAY' ? scalar(@$dangling) : -1, 1, 'C7: dangling has exactly one entry');
                if (ref($dangling) eq 'ARRAY' && defined $e2) {
                    is(refaddr($dangling->[0]), refaddr($e2), 'C7: dangling holds the SAME hashref as refs\' dangling entry (refaddr)');
                }
            }
        } else {
            fail("C7: project key '$_'") for qw(available reason refs dangling);
        }
    }
}

# =============================================================================
# C8 -- check_refs on a root with no task store: available 1, empty arrays.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $report = eval { Almanac::Task::check_refs(root => $ROOT) };
    ok(!$@, 'C8: check_refs on a root with no task store does not die') or diag("error: $@");
    if (ref($report) eq 'HASH' && ref($report->{project}) eq 'HASH') {
        is($report->{project}{available}, 1, 'C8: available == 1 on a store-less root');
        is_deeply($report->{project}{refs}, [], 'C8: refs is empty');
        is_deeply($report->{project}{dangling}, [], 'C8: dangling is empty');
    } else {
        fail('C8: available == 1 on a store-less root');
        fail('C8: refs is empty');
        fail('C8: dangling is empty');
    }
}

# =============================================================================
# C11 -- regression (fix-batch review S3): `edit ID --title` with no
# following value must be refused (missing_flag_value), never silently
# rewrite the title to the literal string "1" (the bare-flag placeholder).
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;
    my $DIR = task_dir_for($ROOT);
    my $r0 = run_cli('add', '--title', 'Original title', '--root', $ROOT);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'C11 fixture: add succeeds') or diag("stderr: $r0->{err}");

    my $before = slurp_raw("$DIR/$id.md");
    my $r = run_cli('edit', $id, '--title', '--root', $ROOT);
    is($r->{rc}, 2, 'C11: edit ID --title with no following value exits 2')
        or diag("stdout: $r->{out} stderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'C11: ...kind: usage');
    is(field2($r->{err}, 'detail'), 'missing_flag_value', 'C11: ...detail: missing_flag_value');

    my $after = slurp_raw("$DIR/$id.md");
    is($after, $before, 'C11: the record file bytes are unchanged after the refused edit');

    my ($keys, $kv) = read_frontmatter("$DIR/$id.md");
    is($kv->{title} // '', 'Original title', 'C11: the title on disk is still the original, never the literal 1');
}

# =============================================================================
# C10 -- isolation guard (spec S4.4), at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "C10: the live bug-reports store's report count is unchanged by this suite ($live_before before, $live_after after)");

    my $live_listing_after = live_almanac_listing();
    is_deeply($live_listing_after, $live_listing_before,
       'C10: the repo\'s own .ccpraxis-local-data/almanac/{task,task-focus,decision} listings are unchanged '
     . '(absent stays absent, present stays byte-identical in listing)');
}

done_testing();
