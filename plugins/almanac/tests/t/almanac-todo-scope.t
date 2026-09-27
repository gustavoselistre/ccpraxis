#!/usr/bin/env perl
# platform: any
# Immutable oracle for the scope-selection surface of almanac-todo.pl
# (blueprint almanac-records, package 04-todos): every verb working
# identically under --global on a host surface, the two scopes never
# colliding, Decision 7's inherited container refusal (each of the seven
# verbs, individually, not once with a comment), the --project --global
# conflict and its no-fallback guarantee, the container-detection
# containment grep, and count()'s treatment of an unavailable global scope
# (both the raw shape and count --json). CRUD, body round-trip and the
# rest of count()'s shape live in the sibling almanac-todo-crud.t. See
# specs/04-todos-spec.md.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd ();
use Encode ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TODO_PL = "$S/almanac-todo.pl";

# ---------------------------------------------------------------------------
# scaffolding (duplicated from almanac-todo-crud.t deliberately -- each test
# file in this plugin is self-contained, per house convention)
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
    # Cwd::abs_path returns raw UTF-8 bytes with the Perl utf8 flag OFF on
    # this platform (unlike slurp_text/field0's PerlIO-decoded strings,
    # which carry the flag even for pure-ASCII content). Concatenating a
    # flagged string with this unflagged one upgrades the unflagged side via
    # implicit Latin-1, splitting a multi-byte UTF-8 sequence (e.g. "e"
    # with a diacritic) into two wrong codepoints -- silently breaking
    # -f/open against a real on-disk path whenever CWD's own path contains
    # non-ASCII (the CLAUDE.md-documented Windows non-ASCII-path landmine).
    # Decode once, here, to match every other value this file compares it to.
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

# run_cli(@args) -> { rc, out, err }. Honours whatever %ENV is currently in
# effect (e.g. a `local $ENV{ALMANAC_SURFACE} = 'container'` around the
# call), since system() forks a fresh process that inherits it.
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$TODO_PL" $argstr > "$outpath" 2> "$errpath"});
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

sub decode_json_or_undef {
    my ($text) = @_;
    # Force scalar context on the eval so a die (e.g. an empty/malformed
    # string) returns undef, never an empty LIST -- a `return eval {...}`
    # evaluated in the caller's list context (show_json's own `return
    # (decode_json_or_undef(...), $r)`) collapses to () on die, which
    # silently drops a position from every caller's list assignment. That
    # is exactly the shape of trap this file's self-audit exists to catch:
    # a caller like `my ($after) = show_json(...)` would then bind $after
    # to $r (the run_cli result hashref) instead of undef, and every
    # ref($after) eq 'HASH' check downstream would pass on the WRONG value.
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub show_json {
    my ($id, @extra) = @_;
    my $r = run_cli('show', $id, '--json', @extra);
    return (decode_json_or_undef($r->{out}), $r);
}

sub extract_todo_blocks {
    my ($text) = @_;
    my @out;
    while ($text =~ /^todo:\s(\S+)\n {2}status:\s(\S+)\n {2}created:\s(\S+)\n {2}tags:\s(\S+)\n {2}title:\s(.*)$/mg) {
        push @out, { id => $1, status => $2, created => $3, tags => $4, title => $5 };
    }
    return @out;
}

# ---------------------------------------------------------------------------
# live-store sanity (house convention) -- before
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

ok(-f $TODO_PL, 'almanac-todo.pl exists at plugins/almanac/scripts/almanac-todo.pl')
    or diag('almanac-todo.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

do $TODO_PL if -f $TODO_PL;

ok(!-e '/run/.containerenv' && !-e '/.dockerenv',
   'sanity: this host carries no real container marker (a precondition for the ALMANAC_SURFACE overrides below)');

# =============================================================================
# AC-23 -- AC-1, AC-6, AC-10, AC-11, AC-12's verbs work identically under
# --global --home <tempdir> on a host surface.
# =============================================================================
{
    my $HOME23 = tempdir(CLEANUP => 1);
    $HOME23 =~ s{\\}{/}g;
    my $DIR23 = norm_path($HOME23) . '/.claude/claude-code-vault/almanac/todo';

    # AC-1 shape: create --global writes exactly one file under the
    # Decision-2 global directory, exits 0, correct result block.
    my $r1 = run_cli('create', '--title', 'Global first todo', '--global', '--home', $HOME23);
    is($r1->{rc}, 0, 'AC-23 (create): create --global --home exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'scope'), 'global', 'AC-23 (create): result block carries scope: global');
    is(field0($r1->{out}, 'status'), 'open', 'AC-23 (create): result block carries status: open');
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-23 (create): result block carries changed: yes');
    my $gid = field0($r1->{out}, 'id');
    ok(defined $gid, 'AC-23 (create): result block carries a non-empty id:');
    my @files = -d $DIR23 ? do { opendir(my $dh, $DIR23); my @f = grep { /\.md\z/ } readdir($dh); closedir $dh; @f } : ();
    is(scalar(@files), 1, 'AC-23 (create): exactly one file under <home>/.claude/claude-code-vault/almanac/todo/');

    # AC-6 shape: edit --global.
    my $redit = run_cli('edit', $gid, '--title', 'Global Edited', '--set', 'colour=blue', '--unset', 'tags', '--global', '--home', $HOME23);
    is($redit->{rc}, 0, 'AC-23 (edit): edit --global exits 0') or diag("stderr: $redit->{err}");
    is(field0($redit->{out}, 'changed'), 'yes', 'AC-23 (edit): changed: yes');
    my ($j1) = show_json($gid, '--global', '--home', $HOME23);
    is(ref($j1) eq 'HASH' ? $j1->{fields}{title} : undef, 'Global Edited', 'AC-23 (edit): the new title is present via show --global --json');

    # AC-10 shape: complete --global, then a no-op second complete.
    my $rc1 = run_cli('complete', $gid, '--global', '--home', $HOME23);
    is($rc1->{rc}, 0, 'AC-23 (complete): complete --global exits 0') or diag("stderr: $rc1->{err}");
    is(field0($rc1->{out}, 'changed'), 'yes', 'AC-23 (complete): first complete changed: yes');
    my $rc2 = run_cli('complete', $gid, '--global', '--home', $HOME23);
    is(field0($rc2->{out}, 'changed'), 'no', 'AC-23 (complete): second complete changed: no (idempotent path)');

    # AC-11 shape: reopen --global, then a no-op second reopen.
    my $ro1 = run_cli('reopen', $gid, '--global', '--home', $HOME23);
    is($ro1->{rc}, 0, 'AC-23 (reopen): reopen --global exits 0') or diag("stderr: $ro1->{err}");
    is(field0($ro1->{out}, 'changed'), 'yes', 'AC-23 (reopen): first reopen changed: yes');
    my $ro2 = run_cli('reopen', $gid, '--global', '--home', $HOME23);
    is(field0($ro2->{out}, 'changed'), 'no', 'AC-23 (reopen): second reopen changed: no (idempotent path)');

    # AC-12 shape: delete --global; file gone; show --global then not_found;
    # <id>.md.lock remains.
    my $path23 = "$DIR23/$gid.md";
    my $rdel = run_cli('delete', $gid, '--global', '--home', $HOME23);
    is($rdel->{rc}, 0, 'AC-23 (delete): delete --global exits 0') or diag("stderr: $rdel->{err}");
    ok(!-f $path23, 'AC-23 (delete): the global record file is gone');
    my $rshow_after = run_cli('show', $gid, '--global', '--home', $HOME23);
    is($rshow_after->{rc}, 2, 'AC-23 (delete): show --global on the deleted id exits 2');
    is(err_kind($rshow_after->{err}), 'not_found', 'AC-23 (delete): ...with kind: not_found');
    ok(-f "$path23.lock", 'AC-23 (delete): <id>.md.lock remains on disk after the global delete');
}

# =============================================================================
# AC-24 -- a project todo and a global todo with the same title are two
# distinct files in the two Decision-2 directories; neither list shows the
# other's id.
# =============================================================================
{
    my $ROOT24 = tempdir(CLEANUP => 1); $ROOT24 =~ s{\\}{/}g;
    my $HOME24 = tempdir(CLEANUP => 1); $HOME24 =~ s{\\}{/}g;
    my $PDIR24 = norm_path($ROOT24) . '/.ccpraxis-local-data/almanac/todo';
    my $GDIR24 = norm_path($HOME24) . '/.claude/claude-code-vault/almanac/todo';

    my $rp = run_cli('create', '--title', 'Same Title Both Scopes', '--root', $ROOT24);
    my $rg = run_cli('create', '--title', 'Same Title Both Scopes', '--global', '--home', $HOME24);
    is($rp->{rc}, 0, 'AC-24 fixture: project create succeeds') or diag("stderr: $rp->{err}");
    is($rg->{rc}, 0, 'AC-24 fixture: global create succeeds') or diag("stderr: $rg->{err}");
    my $pid = field0($rp->{out}, 'id');
    my $gid = field0($rg->{out}, 'id');
    ok(defined($pid) && defined($gid) && $pid ne $gid, 'AC-24: the project and global records have distinct ids')
        or diag('pid=' . ($pid // '(undef)') . ' gid=' . ($gid // '(undef)'));

    ok(-f "$PDIR24/" . ($pid // '(none)') . '.md', 'AC-24: the project record file exists under the project Decision-2 dir')
        if defined $pid;
    ok(-f "$GDIR24/" . ($gid // '(none)') . '.md', 'AC-24: the global record file exists under the global Decision-2 dir')
        if defined $gid;
    ok(!-f "$GDIR24/" . ($pid // '(none)') . '.md', 'AC-24: the project id is NOT present under the global dir') if defined $pid;
    ok(!-f "$PDIR24/" . ($gid // '(none)') . '.md', 'AC-24: the global id is NOT present under the project dir') if defined $gid;

    my $rlist_p = run_cli('list', '--root', $ROOT24);
    my $rlist_g = run_cli('list', '--global', '--home', $HOME24);
    my @pblocks = extract_todo_blocks($rlist_p->{out});
    my @gblocks = extract_todo_blocks($rlist_g->{out});
    ok(defined($pid) && (grep { $_->{id} eq $pid } @pblocks), 'AC-24: project list shows the project id')
        if defined $pid;
    ok(defined($gid) && !(grep { $_->{id} eq $gid } @pblocks), 'AC-24: project list does NOT show the global id')
        if defined $gid;
    ok(defined($gid) && (grep { $_->{id} eq $gid } @gblocks), 'AC-24: global list shows the global id')
        if defined $gid;
    ok(defined($pid) && !(grep { $_->{id} eq $pid } @gblocks), 'AC-24: global list does NOT show the project id')
        if defined $pid;
}

# =============================================================================
# AC-25 -- with ALMANAC_SURFACE=container, each of the seven verbs invoked
# with --global exits 2, prints nothing on STDOUT, and its STDERR machine
# block carries kind: scope_unavailable, scope: global, surface: container,
# readable: 0, writable: 0, reason: vault_not_mounted. Per verb, seven
# times -- not once with a comment.
# =============================================================================
{
    my $HOME25 = tempdir(CLEANUP => 1);
    $HOME25 =~ s{\\}{/}g;
    local $ENV{ALMANAC_SURFACE} = 'container';

    my %verb_args = (
        list     => ['list', '--global', '--home', $HOME25],
        create   => ['create', '--title', 'nope', '--global', '--home', $HOME25],
        show     => ['show', 'whatever-id', '--global', '--home', $HOME25],
        edit     => ['edit', 'whatever-id', '--title', 'x', '--global', '--home', $HOME25],
        complete => ['complete', 'whatever-id', '--global', '--home', $HOME25],
        reopen   => ['reopen', 'whatever-id', '--global', '--home', $HOME25],
        delete   => ['delete', 'whatever-id', '--global', '--home', $HOME25],
    );
    for my $verb (sort keys %verb_args) {
        my $r = run_cli(@{ $verb_args{$verb} });
        is($r->{rc}, 2, "AC-25 [$verb]: --global under ALMANAC_SURFACE=container exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-25 [$verb]: STDOUT is empty");
        is(err_kind($r->{err}), 'scope_unavailable', "AC-25 [$verb]: STDERR machine block carries kind: scope_unavailable")
            or diag("stderr: $r->{err}");
        is(field2($r->{err}, 'scope'), 'global', "AC-25 [$verb]: ...scope: global");
        is(field2($r->{err}, 'surface'), 'container', "AC-25 [$verb]: ...surface: container");
        is(field2($r->{err}, 'readable'), '0', "AC-25 [$verb]: ...readable: 0");
        is(field2($r->{err}, 'writable'), '0', "AC-25 [$verb]: ...writable: 0");
        is(field2($r->{err}, 'reason'), 'vault_not_mounted', "AC-25 [$verb]: ...reason: vault_not_mounted");
    }
}

# =============================================================================
# AC-26 -- with ALMANAC_SURFACE=container, `list --global` prints ZERO bytes
# on STDOUT and does not exit 0 -- the empty-list outcome is asserted
# against directly, not merely inferred from AC-25's generic sweep.
# =============================================================================
{
    my $HOME26 = tempdir(CLEANUP => 1);
    $HOME26 =~ s{\\}{/}g;
    local $ENV{ALMANAC_SURFACE} = 'container';
    my $r = run_cli('list', '--global', '--home', $HOME26);
    is(length($r->{out}), 0, 'AC-26: list --global under container prints exactly zero bytes on STDOUT');
    isnt($r->{rc}, 0, 'AC-26: list --global under container does NOT exit 0');
    is($r->{rc}, 2, 'AC-26: ...specifically exits 2');
}

# =============================================================================
# AC-27 -- with ALMANAC_SURFACE=container, project-scope create/list/show/
# edit/complete/reopen/delete all still exit 0 and behave as on the host.
# =============================================================================
{
    my $ROOT27 = tempdir(CLEANUP => 1);
    $ROOT27 =~ s{\\}{/}g;
    local $ENV{ALMANAC_SURFACE} = 'container';

    my $rc0 = run_cli('create', '--title', 'Project under container', '--root', $ROOT27);
    is($rc0->{rc}, 0, 'AC-27: create (project scope) under container exits 0') or diag("stderr: $rc0->{err}");
    my $id27 = field0($rc0->{out}, 'id');
    ok(defined $id27, 'AC-27: create returns an id');

    my $rlist = run_cli('list', '--root', $ROOT27);
    is($rlist->{rc}, 0, 'AC-27: list (project scope) under container exits 0') or diag("stderr: $rlist->{err}");

    my $rshow = run_cli('show', $id27, '--root', $ROOT27);
    is($rshow->{rc}, 0, 'AC-27: show (project scope) under container exits 0') or diag("stderr: $rshow->{err}");

    my $redit = run_cli('edit', $id27, '--title', 'Edited under container', '--root', $ROOT27);
    is($redit->{rc}, 0, 'AC-27: edit (project scope) under container exits 0') or diag("stderr: $redit->{err}");

    my $rcomplete = run_cli('complete', $id27, '--root', $ROOT27);
    is($rcomplete->{rc}, 0, 'AC-27: complete (project scope) under container exits 0') or diag("stderr: $rcomplete->{err}");

    my $rreopen = run_cli('reopen', $id27, '--root', $ROOT27);
    is($rreopen->{rc}, 0, 'AC-27: reopen (project scope) under container exits 0') or diag("stderr: $rreopen->{err}");

    my $rdelete = run_cli('delete', $id27, '--root', $ROOT27);
    is($rdelete->{rc}, 0, 'AC-27: delete (project scope) under container exits 0') or diag("stderr: $rdelete->{err}");
}

# =============================================================================
# AC-28 -- --project --global together exits 2 with detail: scope_conflict;
# no verb ever falls back from global to project. Asserted by the global
# directory being untouched and the project directory gaining nothing after
# a refused global create.
# =============================================================================
{
    my $ROOT28 = tempdir(CLEANUP => 1); $ROOT28 =~ s{\\}{/}g;
    my $HOME28 = tempdir(CLEANUP => 1); $HOME28 =~ s{\\}{/}g;
    my $PDIR28 = norm_path($ROOT28) . '/.ccpraxis-local-data/almanac/todo';
    my $GDIR28 = norm_path($HOME28) . '/.claude/claude-code-vault/almanac/todo';

    my $r = run_cli('create', '--title', 'Conflict', '--project', '--global', '--root', $ROOT28, '--home', $HOME28);
    is($r->{rc}, 2, 'AC-28: create --project --global together exits 2');
    is(err_kind($r->{err}), 'usage', 'AC-28: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'scope_conflict', 'AC-28: ...and detail: scope_conflict');

    ok(!-d $GDIR28 || do { opendir(my $dh, $GDIR28); my @f = grep { /\.md\z/ } readdir($dh); closedir $dh; scalar(@f) == 0 },
       'AC-28: the global directory gained no file from the refused conflicting create');
    ok(!-d $PDIR28 || do { opendir(my $dh, $PDIR28); my @f = grep { /\.md\z/ } readdir($dh); closedir $dh; scalar(@f) == 0 },
       'AC-28: the project directory gained no file either -- no silent fallback in either direction');
}

# =============================================================================
# AC-29 -- grep: the file contains none of the literals /run/.containerenv,
# /.dockerenv, ALMANAC_SURFACE, and no `-e` test against any container
# marker -- the Decision-7 decision point stays inside
# Almanac::Store::surface(), never re-implemented here.
# =============================================================================
{
    if (-f $TODO_PL) {
        my @lines = read_all_lines($TODO_PL);
        my (@containerenv_hits, @dockerenv_hits, @surface_hits, @dash_e_hits);
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            my $lineno = $i + 1;
            push @containerenv_hits, "$TODO_PL:$lineno: $l" if $l =~ m{/run/\.containerenv};
            push @dockerenv_hits,    "$TODO_PL:$lineno: $l" if $l =~ m{/\.dockerenv};
            push @surface_hits,      "$TODO_PL:$lineno: $l" if $l =~ /ALMANAC_SURFACE/;
            push @dash_e_hits,       "$TODO_PL:$lineno: $l" if $l =~ /-e\s+['"]?\/(run|\.)/;
        }
        unless (ok(@containerenv_hits == 0, "AC-29: the file never mentions '/run/.containerenv'")) { diag($_) for @containerenv_hits }
        unless (ok(@dockerenv_hits == 0, "AC-29: the file never mentions '/.dockerenv'")) { diag($_) for @dockerenv_hits }
        unless (ok(@surface_hits == 0, "AC-29: the file never mentions the string 'ALMANAC_SURFACE'")) { diag($_) for @surface_hits }
        unless (ok(@dash_e_hits == 0, 'AC-29: the file contains no -e test against a container-marker-shaped path')) { diag($_) for @dash_e_hits }
    } else {
        fail("AC-29: $_") for (
            "the file never mentions '/run/.containerenv'",
            "the file never mentions '/.dockerenv'",
            "the file never mentions the string 'ALMANAC_SURFACE'",
            'the file contains no -e test against a container-marker-shaped path',
        );
    }
}

# =============================================================================
# AC-33 -- with ALMANAC_SURFACE=container, count() returns
# global => {available=>0, reason=>'vault_not_mounted'} with open/done/total
# ABSENT (not zeroed), while project is fully counted.
# =============================================================================
{
    my $R33 = tempdir(CLEANUP => 1); $R33 =~ s{\\}{/}g;
    my $H33 = tempdir(CLEANUP => 1); $H33 =~ s{\\}{/}g;
    for (1 .. 2) {
        run_cli('create', '--title', "p33-$_", '--root', $R33);
    }

    my $c;
    {
        local $ENV{ALMANAC_SURFACE} = 'container';
        $c = eval { Almanac::Todo::count(root => $R33, home => $H33) };
    }
    ok(defined $c, 'AC-33: count() under ALMANAC_SURFACE=container returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        is($c->{global}{available}, 0, 'AC-33: global available == 0');
        is($c->{global}{reason}, 'vault_not_mounted', 'AC-33: global reason == vault_not_mounted');
        ok(!exists($c->{global}{open}) && !exists($c->{global}{done}) && !exists($c->{global}{total}),
           'AC-33: global open/done/total keys are ABSENT (exists is false, not "equal to 0")');
        is($c->{project}{available}, 1, 'AC-33: project is still fully available');
        is($c->{project}{open}, 2, 'AC-33: project open == 2');
        is($c->{project}{total}, 2, 'AC-33: project total == 2');
    }
}

# =============================================================================
# AC-37 -- count --json decodes to a structure is_deeply-equal to
# Almanac::Todo::count()'s return for the same fixture, and the `count`
# verb exits 0 EVEN when the global scope is unavailable.
# =============================================================================
{
    my $R37 = tempdir(CLEANUP => 1); $R37 =~ s{\\}{/}g;
    my $H37 = tempdir(CLEANUP => 1); $H37 =~ s{\\}{/}g;
    run_cli('create', '--title', 'p37', '--root', $R37);

    my ($direct, $via_cli);
    {
        local $ENV{ALMANAC_SURFACE} = 'container';
        $direct = eval { Almanac::Todo::count(root => $R37, home => $H37) };
        $via_cli = run_cli('count', '--json', '--root', $R37, '--home', $H37);
    }
    ok(ref($direct) eq 'HASH', 'AC-37 fixture: the direct count() call under container returns a hashref') or diag('error: ' . ($@ // '(none)'));
    is($via_cli->{rc}, 0, 'AC-37: the count verb exits 0 even when the global scope is unavailable')
        or diag("stderr: $via_cli->{err}");
    my $decoded = decode_json_or_undef($via_cli->{out});
    # Guarded so this can never pass vacuously as is_deeply(undef, undef):
    # both sides must independently be real hashrefs before the deep
    # comparison is meaningful.
    if (ref($direct) eq 'HASH' && ref($decoded) eq 'HASH') {
        is_deeply($decoded, $direct, 'AC-37: count --json decodes to a structure identical to Almanac::Todo::count()\'s own return');
    } else {
        fail('AC-37: count --json decodes to a structure identical to Almanac::Todo::count()\'s own return');
        diag('direct: ' . (ref($direct) eq 'HASH' ? JSON::PP->new->canonical->encode($direct) : '(not a hashref)')
           . "\nvia cli raw: $via_cli->{out}");
    }
}

# =============================================================================
# `count`, default form -- absent counts render as absent lines (never 0,
# never -). Supplementary, direct assertion against the default-form
# output the container global scope actually produces: split STDOUT into
# per-scope chunks at each `scope:` header and confirm the global chunk
# carries no open:/done:/total: line at all.
# =============================================================================
{
    my $R37b = tempdir(CLEANUP => 1); $R37b =~ s{\\}{/}g;
    my $H37b = tempdir(CLEANUP => 1); $H37b =~ s{\\}{/}g;
    local $ENV{ALMANAC_SURFACE} = 'container';
    my $r = run_cli('count', '--root', $R37b, '--home', $H37b);
    is($r->{rc}, 0, 'count default form: exits 0 under container') or diag("stderr: $r->{err}");

    my @chunks = split /(?=^scope:)/m, $r->{out};
    my ($global_chunk) = grep { /^scope:\s*global\s*$/m } @chunks;
    ok(defined $global_chunk, 'count default form: a scope: global header block is present') or diag("output:\n$r->{out}");
    if (defined $global_chunk) {
        unlike($global_chunk, qr/^\s{2}open:/m, 'count default form: no open: line under the unavailable global scope block');
        unlike($global_chunk, qr/^\s{2}done:/m, 'count default form: no done: line under the unavailable global scope block');
        unlike($global_chunk, qr/^\s{2}total:/m, 'count default form: no total: line under the unavailable global scope block');
        like($global_chunk, qr/^\s{2}reason:\s*vault_not_mounted\s*$/m, 'count default form: reason: vault_not_mounted is present');
    }
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "AC-44: live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
