#!/usr/bin/env perl
# platform: any
# Immutable oracle for the ordering surface of the project tasklist script
# (blueprint almanac-records, package 07): add/insert-at/insert-before/
# insert-after/move-first/move-last/reorder, exact resulting sequences
# including empty-list and boundary cases (DC-ORD), no stored position field,
# and two-real-process concurrent inserts never colliding (DC-CONC). CRUD and
# focus live in the sibling suites. See specs/07-tasklist-spec.md section 3.4
# and section 4.4's size budget (kept: no fixture exceeds 10 tasks/inserts).
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
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use JSON::PP ();
use Time::HiRes ();

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
sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
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
sub decode_json_or_undef {
    my ($text) = @_;
    return eval { JSON::PP->new->decode($text) };
}
sub task_dir_for { return norm_path($_[0]) . '/.ccpraxis-local-data/almanac/task' }

# order_of(\@records) -> \@ids
sub order_of {
    my ($list) = @_;
    return [] unless ref($list) eq 'ARRAY';
    return [ map { $_->{id} } @$list ];
}

# list_ids($root) -> \@ids | undef, via the in-process module.
sub list_ids {
    my ($root) = @_;
    my $list = eval { Almanac::Task::list_tasks(root => $root) };
    return undef if $@;
    return order_of($list);
}

sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

# run_barrier_pair -- same discipline as almanac-store-concurrency.t's helper
# of the same name: shell-backgrounded, never wait/waitpid'd, a ready/go/done
# sentinel file barrier.
sub run_barrier_pair {
    my ($workdir, $child_pl, $argv1, $argv2) = @_;
    my %argv_by_n = (1 => $argv1, 2 => $argv2);
    for my $n (1, 2) {
        my @argv = ($workdir, $n, @{ $argv_by_n{$n} });
        my $argstr = join(' ', map { qq{"$_"} } @argv);
        system(qq{perl "$child_pl" $argstr > "$workdir/spawn-log.$n" 2>&1 &});
    }
    my %pids;
    for my $n (1, 2) {
        my $ready = "$workdir/ready.$n";
        unless (bounded_wait_for_file($ready, 30)) {
            fail("barrier: child $n never signalled ready within 30s");
            diag("spawn-log.$n: " . (slurp_text("$workdir/spawn-log.$n") // '(missing)'));
            return undef;
        }
        chomp(my $pid = slurp_text($ready) // '');
        $pids{$n} = $pid;
    }
    open(my $gf, '>', "$workdir/go") or die "cannot write go sentinel: $!";
    close $gf;
    my %done;
    for my $n (1, 2) {
        my $donefile = "$workdir/done.$n";
        unless (bounded_wait_for_file($donefile, 60)) {
            fail("barrier: child $n never signalled done within 60s");
            diag("spawn-log.$n: " . (slurp_text("$workdir/spawn-log.$n") // '(missing)'));
            return undef;
        }
        $done{$n} = slurp_text($donefile) // '';
    }
    return { pids => \%pids, done => \%done };
}

sub write_barrier_child {
    my ($path) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} <<'BARRIERCHILD';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes ();
use JSON::PP ();
$| = 1;
my ($workdir, $n, $task_pl, $root, $verb, $ref_id) = @ARGV;
do $task_pl;
if ($@) {
    open(my $ef, '>', "$workdir/stderr.$n"); print {$ef} "LOAD-ERROR: $@"; close $ef;
}
open(my $rf, '>', "$workdir/ready.$n") or die "child $n: cannot write ready: $!";
print {$rf} $$;
close $rf;

my $barrier_deadline = time() + 30;
while (!-e "$workdir/go") {
    if (time() > $barrier_deadline) {
        open(my $df, '>', "$workdir/done.$n"); print {$df} "RC=124\nREASON=TIMEOUT-WAITING-FOR-GO\n"; close $df;
        exit 124;
    }
    Time::HiRes::sleep(0.01);
}

my $result = eval {
    if ($verb eq 'add') {
        return Almanac::Task::add(root => $root, title => "barrier child $n");
    } elsif ($verb eq 'insert_after') {
        return Almanac::Task::insert_after($ref_id, root => $root, title => "barrier child $n");
    }
    die "unknown verb $verb";
};

if (my $err = $@) {
    open(my $ef, '>', "$workdir/stderr.$n"); print {$ef} "$err"; close $ef;
    open(my $df, '>', "$workdir/done.$n"); print {$df} "RC=2\n"; close $df;
    exit 2;
} else {
    open(my $rfile, '>', "$workdir/result.$n"); print {$rfile} JSON::PP::encode_json($result); close $rfile;
    open(my $df, '>', "$workdir/done.$n"); print {$df} "RC=0\n"; close $df;
    exit 0;
}
BARRIERCHILD
    close $fh;
}

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
ok($live_before > 0, "sanity: live store has reports to protect ($live_before found)");

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

do $TASK_PL if -f $TASK_PL;

# fixture(\@titles) -> ($root, \%id_of) -- builds a fresh project store with
# one task per title, IN ORDER, via the module's add() (= insert_last).
# id_of{A} etc. lets each block refer to tasks by their short letter names.
sub fixture_list {
    my (@titles) = @_;
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my %id_of;
    for my $t (@titles) {
        my $rec = eval { Almanac::Task::add(root => $root, title => "Task $t") };
        $id_of{$t} = (ref($rec) eq 'HASH') ? $rec->{id} : undef;
    }
    return ($root, \%id_of);
}

# =============================================================================
# O1 -- empty-list edge cases across every ordering verb.
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    # add on empty -> [X].
    my $rec = eval { Almanac::Task::add(root => $ROOT, title => 'Only task') };
    ok(defined $rec, 'O1: add() on an empty list succeeds') or diag("error: $@");
    is_deeply(list_ids($ROOT), [ defined $rec ? $rec->{id} : () ], 'O1: add() on an empty list -> [X]');

    # separately: insert-at 1 on an empty list (CLI), fresh root.
    my $ROOT2 = tempdir(CLEANUP => 1);
    $ROOT2 =~ s{\\}{/}g;
    my $r1 = run_cli('insert-at', '1', '--title', 'Only via CLI', '--root', $ROOT2);
    is($r1->{rc}, 0, 'O1 (CLI): insert-at 1 on an empty list exits 0') or diag("stderr: $r1->{err}");
    my $idx1 = field0($r1->{out}, 'id');
    is_deeply(list_ids($ROOT2), [ $idx1 ], 'O1 (CLI): insert-at 1 on an empty list -> the only task')
        if defined $idx1;

    # On an EMPTY list, only 1 is valid -- N=2 and N=0 must both be refused.
    my $ROOT2b = tempdir(CLEANUP => 1);
    $ROOT2b =~ s{\\}{/}g;
    for my $bad ('2', '0') {
        my $rb = run_cli('insert-at', $bad, '--title', 'Bad', '--root', $ROOT2b);
        is($rb->{rc}, 2, "O1: insert-at $bad on an EMPTY list exits 2") or diag("stderr: $rb->{err}");
        is(err_kind($rb->{err}), 'usage', "O1: ...kind: usage ($bad)");
        is(field2($rb->{err}, 'detail'), 'bad_position', "O1: ...detail: bad_position ($bad)");
        is(scalar(@{ list_ids($ROOT2b) // [] }), 0, "O1: the store is still empty after the refused insert-at $bad");
    }

    my $ROOT3 = tempdir(CLEANUP => 1);
    $ROOT3 =~ s{\\}{/}g;
    my $rib = eval { Almanac::Task::insert_before('NOPE', root => $ROOT3, title => 'x') };
    my $errb = $@;
    ok(!defined($rib) && $errb, 'O1: insert_before(NOPE) on an empty list dies');
    is(ref($errb) =~ /::Error$/ ? $errb->{kind} : undef, 'not_found', 'O1: ...with kind: not_found (insert_before)');

    my $ria = eval { Almanac::Task::insert_after('NOPE', root => $ROOT3, title => 'x') };
    my $erra = $@;
    ok(!defined($ria) && $erra, 'O1: insert_after(NOPE) on an empty list dies');
    is(ref($erra) =~ /::Error$/ ? $erra->{kind} : undef, 'not_found', 'O1: ...with kind: not_found (insert_after)');

    my ($mf, $mf_changed) = eval { Almanac::Task::move_first('NOPE', root => $ROOT3) };
    my $errm = $@;
    ok(!defined($mf) && $errm, 'O1: move_first(NOPE) on an empty list dies');
    is(ref($errm) =~ /::Error$/ ? $errm->{kind} : undef, 'not_found', 'O1: ...with kind: not_found (move_first)');

    my $reordered = eval { Almanac::Task::reorder([], root => $ROOT3) };
    ok(!$@, 'O1: reorder([]) on an empty list does not die') or diag("error: $@");
    is_deeply($reordered, [], 'O1: reorder([]) on an empty list returns []');

    my $rjson = run_cli('list', '--json', '--root', $ROOT3);
    is($rjson->{rc}, 0, 'O1 (CLI): list --json on an empty list exits 0') or diag("stderr: $rjson->{err}");
    is_deeply(decode_json_or_undef($rjson->{out}), [], 'O1 (CLI): list --json on an empty list -> []');
}

# =============================================================================
# O2 -- insert-at on [A,B,C] for N=1,2,3,4 (valid) and N=5,-1,x,1.5 (invalid).
# =============================================================================
{
    for my $case (
        [1, ['X', 'A', 'B', 'C']],
        [2, ['A', 'X', 'B', 'C']],
        [3, ['A', 'B', 'X', 'C']],
        [4, ['A', 'B', 'C', 'X']],
    ) {
        my ($n, $expected_letters) = @$case;
        my ($root, $id_of) = fixture_list('A', 'B', 'C');
        my $rec = eval { Almanac::Task::insert_at($n, root => $root, title => 'Task X') };
        ok(defined $rec, "O2: insert-at $n on [A,B,C] succeeds") or diag("error: $@");
        $id_of->{X} = (ref($rec) eq 'HASH') ? $rec->{id} : undef;
        my @expected_ids = map { $id_of->{$_} } @$expected_letters;
        is_deeply(list_ids($root), \@expected_ids, "O2: insert-at $n on [A,B,C] -> exact sequence " . join(',', @$expected_letters));
    }

    for my $bad ('5', '-1', 'x', '1.5') {
        my ($root, $id_of) = fixture_list('A', 'B', 'C');
        my $rec = eval { Almanac::Task::insert_at($bad, root => $root, title => 'Task X') };
        my $err = $@;
        ok(!defined($rec) && $err, "O2: insert-at '$bad' on [A,B,C] dies");
        is(ref($err) =~ /::Error$/ ? $err->{kind} : undef, 'usage', "O2: ...kind: usage ('$bad')");
        is(ref($err) =~ /::Error$/ ? $err->{detail} : undef, 'bad_position', "O2: ...detail: bad_position ('$bad')");
        is_deeply(list_ids($root), [ $id_of->{A}, $id_of->{B}, $id_of->{C} ], "O2: sequence unchanged after refused insert-at '$bad'");
    }
}

# =============================================================================
# O3 -- insert-before/insert-after on [A,B,C].
# =============================================================================
{
    my @cases = (
        ['insert_before', 'A', ['X', 'A', 'B', 'C']],
        ['insert_before', 'C', ['A', 'B', 'X', 'C']],
        ['insert_after',  'A', ['A', 'X', 'B', 'C']],
        ['insert_after',  'C', ['A', 'B', 'C', 'X']],
    );
    for my $case (@cases) {
        my ($verb, $ref_letter, $expected_letters) = @$case;
        my ($root, $id_of) = fixture_list('A', 'B', 'C');
        my $code = Almanac::Task->can($verb);
        my $rec2 = defined($code) ? eval { $code->($id_of->{$ref_letter}, root => $root, title => 'Task X') } : undef;
        ok(defined $code, "O3: Almanac::Task->can('$verb')")
            or diag("Almanac::Task::$verb is not defined yet");
        ok(defined $rec2, "O3: $verb($ref_letter) on [A,B,C] succeeds") or diag("error: $@");
        $id_of->{X} = (ref($rec2) eq 'HASH') ? $rec2->{id} : undef;
        my @expected_ids = map { $id_of->{$_} } @$expected_letters;
        is_deeply(list_ids($root), \@expected_ids, "O3: $verb($ref_letter) on [A,B,C] -> exact sequence " . join(',', @$expected_letters));
    }
}

# =============================================================================
# O4 -- move-first / move-last.
# =============================================================================
{
    my ($root1, $id_of1) = fixture_list('A', 'B', 'C');
    my ($rec1, $ch1) = eval { Almanac::Task::move_first($id_of1->{C}, root => $root1) };
    ok(!$@, 'O4: move_first(C) on [A,B,C] does not die') or diag("error: $@");
    is($ch1, 1, 'O4: move_first(C) reports changed');
    is_deeply(list_ids($root1), [ $id_of1->{C}, $id_of1->{A}, $id_of1->{B} ], 'O4: move-first C -> [C,A,B]');

    my ($rec2, $ch2) = eval { Almanac::Task::move_first($id_of1->{C}, root => $root1) };
    ok(!$@, 'O4: move_first of the current first does not die') or diag("error: $@");
    is($ch2, 0, 'O4: move-first of the current first -> changed 0');
    is_deeply(list_ids($root1), [ $id_of1->{C}, $id_of1->{A}, $id_of1->{B} ], 'O4: order unchanged by the no-op move-first');

    my ($root3, $id_of3) = fixture_list('A', 'B', 'C');
    my ($rec3, $ch3) = eval { Almanac::Task::move_last($id_of3->{A}, root => $root3) };
    ok(!$@, 'O4: move_last(A) does not die') or diag("error: $@");
    is($ch3, 1, 'O4: move_last(A) reports changed');
    is_deeply(list_ids($root3), [ $id_of3->{B}, $id_of3->{C}, $id_of3->{A} ], 'O4: move-last A -> [B,C,A]');

    my ($rec4, $ch4) = eval { Almanac::Task::move_last($id_of3->{A}, root => $root3) };
    ok(!$@, 'O4: move_last of the current last does not die') or diag("error: $@");
    is($ch4, 0, 'O4: move-last of the current last -> changed 0');

    my ($root5, $id_of5) = fixture_list('A');
    my ($rec5a, $ch5a) = eval { Almanac::Task::move_first($id_of5->{A}, root => $root5) };
    is($ch5a, 0, 'O4: move_first on a one-task list -> changed 0') or diag("error: $@");
    my ($rec5b, $ch5b) = eval { Almanac::Task::move_last($id_of5->{A}, root => $root5) };
    is($ch5b, 0, 'O4: move_last on a one-task list -> changed 0') or diag("error: $@");

    my ($root6, $id_of6) = fixture_list('A', 'B');
    my $rmiss = eval { Almanac::Task::move_first('no-such-id', root => $root6) };
    my $errmiss = $@;
    ok(!defined($rmiss) && $errmiss, 'O4: move_first(<missing id>) dies');
    is(ref($errmiss) =~ /::Error$/ ? $errmiss->{kind} : undef, 'not_found', 'O4: ...kind: not_found');

    # one CLI move-first call, non-vacuity of the module claim above.
    my $ROOTC = tempdir(CLEANUP => 1);
    $ROOTC =~ s{\\}{/}g;
    my $ra = run_cli('add', '--title', 'CLI move A', '--root', $ROOTC);
    my $rb = run_cli('add', '--title', 'CLI move B', '--root', $ROOTC);
    my $idb = field0($rb->{out}, 'id');
    ok(defined $idb, 'O4 (CLI) fixture: two tasks exist') or diag("stderr: $rb->{err}");
    my $rmf = run_cli('move-first', $idb, '--root', $ROOTC);
    is($rmf->{rc}, 0, 'O4 (CLI): move-first exits 0') or diag("stderr: $rmf->{err}");
    is(field0($rmf->{out}, 'changed'), 'yes', 'O4 (CLI): move-first B (currently last) -> changed: yes');
}

# =============================================================================
# O5 -- reorder.
# =============================================================================
{
    my ($root, $id_of) = fixture_list('A', 'B', 'C');
    my @before_fields;
    for my $letter (qw(A B C)) {
        my $rec = eval { Almanac::Task::open_tasklist(root => $root)->read($id_of->{$letter}) };
        push @before_fields, { id => $id_of->{$letter}, title => ref($rec) eq 'HASH' ? $rec->{fields}{title} : undef,
                                status => ref($rec) eq 'HASH' ? $rec->{fields}{status} : undef };
    }

    my $reordered = eval { Almanac::Task::reorder([$id_of->{C}, $id_of->{A}, $id_of->{B}], root => $root) };
    ok(!$@, 'O5: reorder([C,A,B]) does not die') or diag("error: $@");
    is_deeply(order_of($reordered), [ $id_of->{C}, $id_of->{A}, $id_of->{B} ], 'O5: reorder([C,A,B]) -> exact order');
    is_deeply(list_ids($root), [ $id_of->{C}, $id_of->{A}, $id_of->{B} ], 'O5: list_tasks() reflects the new order');

    for my $before (@before_fields) {
        my $rec = eval { Almanac::Task::open_tasklist(root => $root)->read($before->{id}) };
        is(ref($rec) eq 'HASH' ? $rec->{fields}{title} : undef, $before->{title}, 'O5: title unchanged for ' . $before->{id});
        is(ref($rec) eq 'HASH' ? $rec->{fields}{status} : undef, $before->{status}, 'O5: status unchanged for ' . $before->{id});
    }

    # CLI once: missing / unknown / duplicate id -> reorder_mismatch, order unchanged.
    my $ROOTC = tempdir(CLEANUP => 1);
    $ROOTC =~ s{\\}{/}g;
    my ($rootc_ignore, $id_ofc) = ('', {});
    my $ra = run_cli('add', '--title', 'CLI reorder A', '--root', $ROOTC);
    my $rb = run_cli('add', '--title', 'CLI reorder B', '--root', $ROOTC);
    my ($ida, $idb) = (field0($ra->{out}, 'id'), field0($rb->{out}, 'id'));
    ok(defined($ida) && defined($idb), 'O5 (CLI) fixture: two tasks exist') or diag("stderr: $ra->{err} / $rb->{err}");

    my $r_missing = run_cli('reorder', $ida, '--root', $ROOTC); # missing idb
    is($r_missing->{rc}, 2, 'O5 (CLI): reorder missing an id exits 2') or diag("stderr: $r_missing->{err}");
    is(err_kind($r_missing->{err}), 'reorder_mismatch', 'O5 (CLI): ...kind: reorder_mismatch (missing)');

    my $r_extra = run_cli('reorder', $ida, $idb, 'unknown-id', '--root', $ROOTC);
    is($r_extra->{rc}, 2, 'O5 (CLI): reorder with an extra unknown id exits 2') or diag("stderr: $r_extra->{err}");
    is(err_kind($r_extra->{err}), 'reorder_mismatch', 'O5 (CLI): ...kind: reorder_mismatch (unknown extra)');

    my $r_dup = run_cli('reorder', $ida, $ida, $idb, '--root', $ROOTC);
    is($r_dup->{rc}, 2, 'O5 (CLI): reorder with a repeated id exits 2') or diag("stderr: $r_dup->{err}");
    is(err_kind($r_dup->{err}), 'reorder_mismatch', 'O5 (CLI): ...kind: reorder_mismatch (duplicate)');

    is_deeply(list_ids($ROOTC), [$ida, $idb], 'O5 (CLI): the order is unchanged after all three refused reorders');

    # no ids on a non-empty list -> reorder_mismatch (contrast with O1's empty-list case).
    my $r_none = run_cli('reorder', '--root', $ROOTC);
    is($r_none->{rc}, 2, 'O5 (CLI): reorder with no ids on a NON-EMPTY list exits 2') or diag("stderr: $r_none->{err}");
    is(err_kind($r_none->{err}), 'reorder_mismatch', 'O5 (CLI): ...kind: reorder_mismatch (no ids, non-empty)');
}

# =============================================================================
# O6 -- no stored position field; list --json position values are 1..n.
# =============================================================================
{
    my ($root, $id_of) = fixture_list('A', 'B', 'C');
    my $dir = task_dir_for($root);
    my @files;
    if (opendir(my $dh, $dir)) {
        @files = grep { /\.md\z/ } readdir($dh);
        closedir $dh;
    }
    ok(scalar(@files) == 3, 'O6 fixture: three task files exist on disk') or diag('found: ' . join(',', @files));
    for my $f (@files) {
        my @lines = read_all_lines("$dir/$f");
        my @position_lines = grep { /\Aposition:/ } @lines;
        is(scalar(@position_lines), 0, "O6: $f contains no 'position:' field");
    }

    my $rjson = run_cli('list', '--json', '--root', $root);
    is($rjson->{rc}, 0, 'O6 (CLI): list --json exits 0') or diag("stderr: $rjson->{err}");
    my $decoded = decode_json_or_undef($rjson->{out});
    if (ref($decoded) eq 'ARRAY') {
        my @positions = map { $_->{position} } @$decoded;
        is_deeply(\@positions, [1, 2, 3], 'O6 (CLI): list --json position values are 1..n in order');
    } else {
        fail('O6 (CLI): list --json position values are 1..n in order');
    }
}

# =============================================================================
# O7 -- two real processes, ready/go/done file barrier: (a) both add() on an
# empty list; (b) both insert_after('A') on [A,B].
# =============================================================================
{
    # (a) both add().
    my $ROOTA = tempdir(CLEANUP => 1);
    $ROOTA =~ s{\\}{/}g;
    my $WORKA = tempdir(CLEANUP => 1);
    $WORKA =~ s{\\}{/}g;
    my $childA = "$WORKA/barrier-child.pl";
    write_barrier_child($childA);

    my $resultA = run_barrier_pair(
        $WORKA, $childA,
        [$TASK_PL, $ROOTA, 'add', ''],
        [$TASK_PL, $ROOTA, 'add', ''],
    );
    if ($resultA) {
        my ($rc1) = $resultA->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $resultA->{done}{2} =~ /^RC=(-?\d+)/m;
        is($rc1, 0, 'O7a: child 1 (add on empty list) exits 0')
            or diag("stderr.1: " . (slurp_text("$WORKA/stderr.1") // '(none)'));
        is($rc2, 0, 'O7a: child 2 (add on empty list) exits 0')
            or diag("stderr.2: " . (slurp_text("$WORKA/stderr.2") // '(none)'));

        my $ids = list_ids($ROOTA);
        is(ref($ids) eq 'ARRAY' ? scalar(@$ids) : -1, 2, 'O7a: exactly two records exist afterwards');
        my ($rankA, $rankB);
        if (ref($ids) eq 'ARRAY' && @$ids == 2) {
            my $store = eval { Almanac::Task::open_tasklist(root => $ROOTA) };
            $rankA = defined($store) ? eval { $store->read($ids->[0])->{rank} } : undef;
            $rankB = defined($store) ? eval { $store->read($ids->[1])->{rank} } : undef;
        }
        ok(defined($rankA) && defined($rankB) && $rankA ne $rankB,
           'O7a: the two new records have two distinct ranks')
            or diag('rankA=' . ($rankA // 'undef') . ' rankB=' . ($rankB // 'undef'));
    } else {
        fail($_) for ('O7a: child 1 (add on empty list) exits 0', 'O7a: child 2 (add on empty list) exits 0',
                       'O7a: exactly two records exist afterwards', 'O7a: the two new records have two distinct ranks');
    }

    # (b) both insert_after('A') on [A,B].
    my ($ROOTB, $id_ofB) = fixture_list('A', 'B');
    my $WORKB = tempdir(CLEANUP => 1);
    $WORKB =~ s{\\}{/}g;
    my $childB = "$WORKB/barrier-child.pl";
    write_barrier_child($childB);

    my $resultB = run_barrier_pair(
        $WORKB, $childB,
        [$TASK_PL, $ROOTB, 'insert_after', $id_ofB->{A}],
        [$TASK_PL, $ROOTB, 'insert_after', $id_ofB->{A}],
    );
    if ($resultB) {
        my ($rc1) = $resultB->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $resultB->{done}{2} =~ /^RC=(-?\d+)/m;
        is($rc1, 0, 'O7b: child 1 (insert_after A) exits 0')
            or diag("stderr.1: " . (slurp_text("$WORKB/stderr.1") // '(none)'));
        is($rc2, 0, 'O7b: child 2 (insert_after A) exits 0')
            or diag("stderr.2: " . (slurp_text("$WORKB/stderr.2") // '(none)'));

        my $ids = list_ids($ROOTB);
        is(ref($ids) eq 'ARRAY' ? scalar(@$ids) : -1, 4, 'O7b: exactly four records exist afterwards (2 original + 2 new)');
        if (ref($ids) eq 'ARRAY' && @$ids == 4) {
            my $pos_a = 0; $pos_a++ while $pos_a < @$ids && $ids->[$pos_a] ne $id_ofB->{A}; $pos_a++;
            my $pos_b = 0; $pos_b++ while $pos_b < @$ids && $ids->[$pos_b] ne $id_ofB->{B}; $pos_b++;
            my @between = @$ids[$pos_a .. $pos_b - 2];
            is(scalar(@between), 2, 'O7b: exactly two ids sit strictly between A and B');
            ok((grep { $_ eq $id_ofB->{A} } @between) == 0 && (grep { $_ eq $id_ofB->{B} } @between) == 0,
               'O7b: neither A nor B itself is among the between-ids');

            my $store = eval { Almanac::Task::open_tasklist(root => $ROOTB) };
            my @ranks = map { defined($store) ? eval { $store->read($_)->{rank} } : undef } @between;
            ok((@ranks == 2 && defined($ranks[0]) && defined($ranks[1]) && $ranks[0] ne $ranks[1]),
               'O7b: the two new records have two distinct ranks')
                or diag('ranks: ' . join(',', map { $_ // 'undef' } @ranks));
        } else {
            fail('O7b: exactly two ids sit strictly between A and B');
            fail('O7b: neither A nor B itself is among the between-ids');
            fail('O7b: the two new records have two distinct ranks');
        }
    } else {
        fail($_) for ('O7b: child 1 (insert_after A) exits 0', 'O7b: child 2 (insert_after A) exits 0',
                       'O7b: exactly four records exist afterwards (2 original + 2 new)',
                       'O7b: exactly two ids sit strictly between A and B',
                       'O7b: neither A nor B itself is among the between-ids',
                       'O7b: the two new records have two distinct ranks');
    }
}

# =============================================================================
# O9 -- regression (fix-batch review, package 07 -- S1/S2): an id taken from
# a DECODED record field (utf8::is_utf8 true, even though the characters are
# pure ASCII) must still work with move_first()/insert_after() when the
# store root's path has a non-ASCII component. The root's non-ASCII
# component is built explicitly by this test (not relying on the host TEMP
# path happening to already contain one) so the assertion holds on every
# host, per review S2.
# =============================================================================
{
    my $BASE = tempdir(CLEANUP => 1);
    $BASE =~ s{\\}{/}g;
    my $ROOT = "$BASE/proj\x{e9}"; # proj + e-acute, built explicitly here
    make_path($ROOT) or die "fixture: cannot create $ROOT: $!";
    ok(-d $ROOT, 'O9 fixture: the non-ASCII root directory exists');

    my %id_of;
    for my $t (qw(A B C)) {
        my $rec = eval { Almanac::Task::add(root => $ROOT, title => "Task $t") };
        ok(!$@ && defined($rec), "O9 fixture: add(Task $t) under the non-ASCII root succeeds") or diag("error: $@");
        $id_of{$t} = (ref($rec) eq 'HASH') ? $rec->{id} : undef;
    }

    my $list = eval { Almanac::Task::list_tasks(root => $ROOT) };
    ok(!$@ && ref($list) eq 'ARRAY' && @$list == 3,
       'O9 fixture: list_tasks() under the non-ASCII root returns three records') or diag("error: $@");

    my ($rec_c) = ref($list) eq 'ARRAY' ? grep { $_->{id} eq $id_of{C} } @$list : ();
    ok(defined($rec_c) && ref($rec_c) eq 'HASH' && utf8::is_utf8($rec_c->{fields}{id}),
       'O9 fixture: the field-derived id is a utf8-flagged character string (the bug precondition)');
    my $field_id_c = (ref($rec_c) eq 'HASH') ? $rec_c->{fields}{id} : undef;

    my ($mrec, $mchanged) = eval { Almanac::Task::move_first($field_id_c, root => $ROOT) };
    ok(!$@, 'O9 (S1): move_first() with a field-derived id under a non-ASCII root does not die')
        or diag("error: $@");
    SKIP: {
        skip 'move_first died -- see the diag above', 2 if $@;
        is($mchanged, 1, 'O9 (S1): move_first(C) under a non-ASCII root reports changed');
        is_deeply(list_ids($ROOT), [ $id_of{C}, $id_of{A}, $id_of{B} ],
            'O9 (S1): move_first(C) under a non-ASCII root -> [C,A,B]');
    }

    my $list2 = eval { Almanac::Task::list_tasks(root => $ROOT) };
    my ($rec_a) = ref($list2) eq 'ARRAY' ? grep { $_->{id} eq $id_of{A} } @$list2 : ();
    my $field_id_a = (ref($rec_a) eq 'HASH') ? $rec_a->{fields}{id} : undef;

    my $rec_x = eval { Almanac::Task::insert_after($field_id_a, root => $ROOT, title => 'Task X') };
    ok(!$@ && defined($rec_x),
       'O9 (S1/S2): insert_after() with a field-derived id under a non-ASCII root does not die')
        or diag("error: $@");
}

# =============================================================================
# O10 -- regression (fix-batch review S6): insert-at N anchors on the wrong
# neighbour when slot N holds an unranked (out-of-band) record. Given
# [A(ranked), U(unranked)], insert-at 2 must land [A, X, U] -- after
# list[N-2]=A -- never [X, A, U] (at the front of the ranked block).
# =============================================================================
{
    my $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    my $recA = eval { Almanac::Task::add(root => $ROOT, title => 'Task A') };
    ok(!$@ && defined($recA), 'O10 fixture: add(Task A) succeeds') or diag("error: $@");
    my $idA = (ref($recA) eq 'HASH') ? $recA->{id} : undef;

    # U is created directly via Almanac::Store with NO rank field at all --
    # the out-of-band case the spec's section 5 describes -- so it sorts
    # last (unranked-after-ranked) without going through any ordering verb.
    my $recU;
    eval {
        require Almanac::Store;
        my $store = Almanac::Store->open(scope => 'project', type => 'task', root => $ROOT);
        $recU = $store->create(
            id     => 'task-unranked-u',
            fields => { title => 'Task U', status => 'pending', created => '2020-01-01T00:00:00Z' },
            order  => [qw(title status created)],
        );
    };
    ok(!$@ && defined($recU), 'O10 fixture: an out-of-band record U with no rank field is created directly via Store')
        or diag("error: $@");
    my $idU = (ref($recU) eq 'HASH') ? $recU->{id} : undef;

    is_deeply(list_ids($ROOT), [ $idA, $idU ],
        'O10 fixture: the store lists [A, U] before the insert (U sorts last, unranked)');

    my $recX = eval { Almanac::Task::insert_at(2, root => $ROOT, title => 'Task X') };
    ok(!$@ && defined($recX), 'O10: insert-at 2 on [A(ranked),U(unranked)] succeeds') or diag("error: $@");
    my $idX = (ref($recX) eq 'HASH') ? $recX->{id} : undef;

    is_deeply(list_ids($ROOT), [ $idA, $idX, $idU ],
        'O10: insert-at 2 on [A(ranked),U(unranked)] lands [A,X,U], after list[N-2]=A, never at the front');
}

# =============================================================================
# O11 -- regression (fix-batch review S4): the no-op move (already
# first/last) must leave the record's raw file bytes byte-identical, not
# merely report `changed 0`.
# =============================================================================
{
    my ($root, $id_of) = fixture_list('A', 'B', 'C');
    my $dir = task_dir_for($root);

    my $path_first   = "$dir/$id_of->{A}.md";
    my $before_first = slurp_raw($path_first);
    my (undef, $ch1) = eval { Almanac::Task::move_first($id_of->{A}, root => $root) };
    ok(!$@, 'O11 fixture: move_first(A) (already first) does not die') or diag("error: $@");
    is($ch1, 0, 'O11 fixture: move_first(A) (already first) reports changed 0');
    my $after_first = slurp_raw($path_first);
    is($after_first, $before_first, 'O11 (S4): move_first of the current first leaves the record file bytes unchanged');

    my $path_last   = "$dir/$id_of->{C}.md";
    my $before_last = slurp_raw($path_last);
    my (undef, $ch2) = eval { Almanac::Task::move_last($id_of->{C}, root => $root) };
    ok(!$@, 'O11 fixture: move_last(C) (already last) does not die') or diag("error: $@");
    is($ch2, 0, 'O11 fixture: move_last(C) (already last) reports changed 0');
    my $after_last = slurp_raw($path_last);
    is($after_last, $before_last, 'O11 (S4): move_last of the current last leaves the record file bytes unchanged');
}

# =============================================================================
# O12 -- regression (fix-batch review S5): reorder() must preserve
# blocked_on and body, not just title/status -- fixture_list()'s tasks have
# neither field, so O5 above never exercises this half of the spec's claim.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;

    my $recA = eval { Almanac::Task::add(root => $root, title => 'Task A', blocked_on => 'D-x', body => "body of A\n") };
    ok(!$@ && defined($recA), 'O12 fixture: add(A) with blocked_on and a body succeeds') or diag("error: $@");
    my $idA = (ref($recA) eq 'HASH') ? $recA->{id} : undef;
    my $recB = eval { Almanac::Task::add(root => $root, title => 'Task B') };
    my $idB  = (ref($recB) eq 'HASH') ? $recB->{id} : undef;
    my $recC = eval { Almanac::Task::add(root => $root, title => 'Task C') };
    my $idC  = (ref($recC) eq 'HASH') ? $recC->{id} : undef;

    my $before_a = eval { Almanac::Task::open_tasklist(root => $root)->read($idA) };
    ok(!$@ && ref($before_a) eq 'HASH', 'O12 fixture: A can be read before reorder') or diag("error: $@");

    my $reordered = eval { Almanac::Task::reorder([$idC, $idA, $idB], root => $root) };
    ok(!$@, 'O12: reorder([C,A,B]) does not die') or diag("error: $@");

    my $after_a = eval { Almanac::Task::open_tasklist(root => $root)->read($idA) };
    ok(!$@ && ref($after_a) eq 'HASH', 'O12 fixture: A can be read after reorder') or diag("error: $@");

    is(ref($after_a) eq 'HASH' ? $after_a->{fields}{blocked_on} : undef,
       ref($before_a) eq 'HASH' ? $before_a->{fields}{blocked_on} : undef,
       'O12 (S5): blocked_on for A is unchanged by reorder');
    is(ref($after_a) eq 'HASH' ? $after_a->{body} : undef,
       ref($before_a) eq 'HASH' ? $before_a->{body} : undef,
       'O12 (S5): body for A is unchanged by reorder');
}

# =============================================================================
# O8 -- isolation guard (spec S4.4), at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "O8: the live bug-reports store's report count is unchanged by this suite ($live_before before, $live_after after)");

    my $live_listing_after = live_almanac_listing();
    is_deeply($live_listing_after, $live_listing_before,
       'O8: the repo\'s own .ccpraxis-local-data/almanac/{task,task-focus,decision} listings are unchanged');
}

done_testing();
