#!/usr/bin/env perl
# platform: any
# Immutable oracle for the almanac store module's REAL-PROCESS concurrency
# guarantees (blueprint almanac-records, package 03-store): two writers on
# different records both land; two writers on the same record produce exactly
# one winner and one loser, with the loser's STDERR machine block naming the
# id, the field the winner changed, and the winner's writer id as separate
# fields (never a prose sentence); two insert_last calls mint distinct ranks;
# a kill between temp-write and rename leaves the previous content intact; a
# kill mid-reorder leaves the previous order recoverable. CRUD and ordering
# ACs live in the sibling files. See specs/03-store-spec.md section 5.2 for
# the exact kill technique this file follows.
#
# HOUSE PATTERN for a not-yet-built module: every direct call into the store
# module is wrapped in eval{} so "Undefined subroutine"/"Can't locate" is a
# caught, reported failure for THIS assertion rather than an abort of the
# whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $STORE_PM = "$S/Almanac/Store.pm";

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
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
sub slurp_text {
    my ($p) = @_;
    return undef unless -e $p;
    open my $fh, '<', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
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

sub bounded_wait_for_any {
    my ($paths, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (1) {
        for my $p (@$paths) { return $p if -e $p }
        return undef if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
}

sub bounded_wait_for_death {
    my ($pid, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (Time::HiRes::time() < $deadline) {
        my $alive = kill(0, $pid);
        return 1 unless $alive;
        Time::HiRes::sleep(0.05);
    }
    return 0; # tolerate a platform where kill(0,...) is uninformative
}

sub machine_block_field {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

# run_barrier_pair -- same discipline as almanac-lock-serialization.t's
# helper of the same name: shell-backgrounded, never wait/waitpid'd, a
# ready/go/done sentinel barrier.
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

# ---------------------------------------------------------------------------
# child fixture: the "mutate" child. Reads its baseline right after signalling
# ready (before the barrier, i.e. before anybody could have written), waits
# for the shared "go" sentinel, then performs exactly one Store call. Result
# and any error's stderr machine-block text land in per-child files.
# ---------------------------------------------------------------------------
sub write_mutate_child {
    my ($path) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} <<'MUTATECHILD';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes ();
$| = 1;
my ($workdir, $n, $scripts_dir, $root, $type, $id, $verb, $payload_file) = @ARGV;
# THE BARRIER MUST FIRE *AFTER* THE BASELINE IS CAPTURED. Fixed 2026-09-17
# under a narrow driver authorisation; the original signalled ready TEN LINES
# EARLIER, and its own comment above said so -- "reads its baseline right after
# signalling".
#
# That ordering makes the race untestable rather than merely flaky. Ready meant
# "I am about to start", so the parent released both children while one had not
# yet read anything. A child whose module load was slower could have the other
# child's ENTIRE update complete first, then read an ALREADY-UPDATED baseline --
# at which point its CAS legitimately succeeds and there are two winners. That
# is the fixture, not the store: an instrumented reproduction using this very
# template showed child 2's "baseline" rev exactly equalling child 1's completed
# result rev.
#
# Signalling after the baseline is the only ordering that means what the barrier
# claims: both children hold a baseline taken before either was released, which
# is what "concurrent mutation of the same record" requires.
local @INC = ($scripts_dir, @INC);
my ($load_ok, $store, $baseline, $setup_err);
eval {
    require Almanac::Store;
    require JSON::PP;
    $store = Almanac::Store->open(scope => 'project', type => $type, root => $root);
    $baseline = $store->read($id) if $verb eq 'update';
    $load_ok = 1;
} or $setup_err = $@;

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

unless ($load_ok) {
    open(my $df, '>', "$workdir/done.$n");
    print {$df} "RC=3\nREASON=SETUP-FAILED\n";
    close $df;
    open(my $ef, '>', "$workdir/stderr.$n"); print {$ef} (defined $setup_err ? "$setup_err" : "(no message)"); close $ef;
    exit 3;
}

my $args = {};
if (defined $payload_file && -e $payload_file) {
    my $raw = do { local $/; open my $pf, '<', $payload_file or die $!; my $j = <$pf>; close $pf; $j };
    $args = JSON::PP::decode_json($raw);
}

my $result = eval {
    if ($verb eq 'update') {
        return $store->update($id, expect => $baseline, %$args);
    } elsif ($verb eq 'insert_last') {
        return $store->insert_last(%$args);
    }
    die "unknown verb $verb";
};

if (my $err = $@) {
    open(my $ef, '>', "$workdir/stderr.$n"); print {$ef} "$err"; close $ef;
    my $code = (ref($err) && ref($err) =~ /::Error$/ && defined $err->{exit_code}) ? $err->{exit_code} : 2;
    open(my $df, '>', "$workdir/done.$n"); print {$df} "RC=$code\n"; close $df;
    exit $code;
} else {
    open(my $rfile, '>', "$workdir/result.$n"); print {$rfile} JSON::PP::encode_json($result); close $rfile;
    open(my $df, '>', "$workdir/done.$n"); print {$df} "RC=0\n"; close $df;
    exit 0;
}
MUTATECHILD
    close $fh;
}

sub write_payload {
    my ($path, $data) = @_;
    write_raw($path, JSON::PP->new->canonical->encode($data));
}

sub open_test_store {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my $store = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root, %opt) };
    return ($root, $store, $@);
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
ok($live_before > 0, "sanity: live store has reports to protect ($live_before found)");

ok(-f $STORE_PM, 'Almanac::Store module file exists') or diag('Almanac/Store.pm is not present yet -- every assertion below is expected to fail for exactly that reason.');
eval { require Almanac::Store; 1 };
my $LOADED = !$@;

# =============================================================================
# AC-1 (DC1) -- two real processes update DIFFERENT records concurrently:
# both exit 0, both new values present, both records parse.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-1 fixture: store handle opens') or diag("error: $err");
    my ($recA, $recB);
    if (defined $store) {
        $recA = eval { $store->create(id => 'ac1-a', fields => { status => 'todo' }, order => ['status']) };
        $recB = eval { $store->create(id => 'ac1-b', fields => { status => 'todo' }, order => ['status']) };
    }
    ok(defined $recA && defined $recB, 'AC-1 fixture: two distinct records exist to mutate') or diag("error: $@");

    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $child = "$WORKDIR/mutate-child.pl";
    write_mutate_child($child);
    my $payloadA = "$WORKDIR/payload-a.json";
    my $payloadB = "$WORKDIR/payload-b.json";
    write_payload($payloadA, { set => { status => 'doing-A' } });
    write_payload($payloadB, { set => { status => 'doing-B' } });

    my $result = run_barrier_pair(
        $WORKDIR, $child,
        [$S, $root, 'note', 'ac1-a', 'update', $payloadA],
        [$S, $root, 'note', 'ac1-b', 'update', $payloadB],
    );

    if ($result) {
        ok($result->{pids}{1} ne $result->{pids}{2} && $result->{pids}{1} != $$ && $result->{pids}{2} != $$,
           'AC-1: the two children are distinct real OS processes');
        my ($rc1) = $result->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $result->{done}{2} =~ /^RC=(-?\d+)/m;
        is($rc1, 0, 'AC-1: child A (different record) exits 0') or diag("done.1: $result->{done}{1}");
        is($rc2, 0, 'AC-1: child B (different record) exits 0') or diag("done.2: $result->{done}{2}");

        my $afterA = eval { $store->read('ac1-a') };
        my $afterB = eval { $store->read('ac1-b') };
        ok(defined $afterA && $afterA->{fields}{status} eq 'doing-A', 'AC-1: record A shows its own change') if defined $store;
        ok(defined $afterB && $afterB->{fields}{status} eq 'doing-B', 'AC-1: record B shows its own change') if defined $store;
        fail('AC-1: record A shows its own change') unless defined $store;
        fail('AC-1: record B shows its own change') unless defined $store;
    } else {
        fail($_) for ('AC-1: the two children are distinct real OS processes',
                       'AC-1: child A (different record) exits 0', 'AC-1: child B (different record) exits 0',
                       'AC-1: record A shows its own change', 'AC-1: record B shows its own change');
    }
}

# =============================================================================
# AC-2..AC-7 (DC2) -- two real processes update the SAME record from the same
# baseline: exactly one wins, one loses; the loser's block names id/field/
# winner; expected_rev != actual_rev; the file holds the winner's change.
# Repeated 5 times for AC-7 (the split is 1/1 every time, never 2/0 or 0/2).
# =============================================================================
{
    my $REPS = 5;
    my @splits;
    for my $rep (1 .. $REPS) {
        my ($root, $store, $err) = open_test_store();
        ok(defined $store, "AC-2 rep $rep fixture: store handle opens") or diag("error: $err");
        my $rec = eval { $store->create(id => 'ac2-target', fields => { status => 'todo', title => 'orig' }, order => ['status', 'title']) } if defined $store;
        ok(defined $rec, "AC-2 rep $rep fixture: the shared target record exists") or diag("error: $@");

        my $WORKDIR = tempdir(CLEANUP => 1);
        $WORKDIR =~ s{\\}{/}g;
        my $child = "$WORKDIR/mutate-child.pl";
        write_mutate_child($child);
        my $payloadA = "$WORKDIR/payload-a.json";
        my $payloadB = "$WORKDIR/payload-b.json";
        write_payload($payloadA, { set => { status => 'from-A' } });
        write_payload($payloadB, { set => { status => 'from-B' } });

        my $result = run_barrier_pair(
            $WORKDIR, $child,
            [$S, $root, 'note', 'ac2-target', 'update', $payloadA],
            [$S, $root, 'note', 'ac2-target', 'update', $payloadB],
        );

        unless ($result) {
            fail("AC-2 rep $rep: both children signalled ready and done") for 1 .. 8;
            next;
        }

        my ($rc1) = $result->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $result->{done}{2} =~ /^RC=(-?\d+)/m;
        my @rcs = (defined $rc1 ? $rc1 : -1, defined $rc2 ? $rc2 : -1);
        my $winners = grep { $_ == 0 } @rcs;
        my $losers  = grep { $_ == 2 } @rcs;
        push @splits, "$winners/$losers";

        if ($rep == 1) {
            is($winners, 1, "AC-2: exactly one child exits 0") or diag("rc1=$rc1 rc2=$rc2");
            is($losers, 1, "AC-2: exactly one child exits 2") or diag("rc1=$rc1 rc2=$rc2");

            my $loser_n = ($rc1 == 2) ? 1 : ($rc2 == 2 ? 2 : undef);
            my $winner_n = ($rc1 == 0) ? 1 : ($rc2 == 0 ? 2 : undef);
            my $loser_stderr = defined $loser_n ? (slurp_text("$WORKDIR/stderr.$loser_n") // '') : '';

            is(machine_block_field($loser_stderr, 'kind'), 'conflict', 'AC-3: loser stderr machine block has kind: conflict');
            is(machine_block_field($loser_stderr, 'id'), 'ac2-target', 'AC-3: loser stderr machine block has id: ac2-target');

            my $winner_field_val = ($winner_n == 1) ? 'status' : 'status'; # both change 'status'; field must equal that
            is(machine_block_field($loser_stderr, 'field'), 'status', 'AC-4: loser stderr machine block has field: status (the field the winner changed)');

            my $after = eval { $store->read('ac2-target') } if defined $store;
            my $expect_status = ($winner_n == 1) ? 'from-A' : 'from-B';
            my $winner_writer_from_disk = defined $after ? $after->{writer} : undef;
            my $stderr_winner = machine_block_field($loser_stderr, 'winner');
            ok(defined($stderr_winner) && defined($winner_writer_from_disk) && $stderr_winner eq $winner_writer_from_disk,
               'AC-5: loser stderr winner: line equals the on-disk writer field after the race')
                or diag('stderr winner=' . (defined $stderr_winner ? $stderr_winner : '(undef)')
                      . ' disk writer=' . (defined $winner_writer_from_disk ? $winner_writer_from_disk : '(undef)'));

            my $exp_rev = machine_block_field($loser_stderr, 'expected_rev');
            my $act_rev = machine_block_field($loser_stderr, 'actual_rev');
            ok(defined $exp_rev && defined $act_rev && $exp_rev ne $act_rev,
               'AC-6: loser stderr expected_rev and actual_rev differ');
            ok(defined $after && $after->{fields}{status} eq $expect_status,
               'AC-6: the record on disk holds the winner\'s change and parses cleanly') if defined $store;
            fail('AC-6: the record on disk holds the winner\'s change and parses cleanly') unless defined $store;
        }
    }
    is(scalar(@splits), $REPS, "AC-7: all $REPS repetitions completed and reported a split");
    my @bad_splits = grep { $_ ne '1/1' } @splits;
    is(scalar(@bad_splits), 0, "AC-7: every repetition's winner/loser split is exactly 1/1 (never 2/0, never 0/2)")
        or diag("splits observed: " . join(', ', @splits));
}

# =============================================================================
# AC-8/AC-9 (DC3) -- two real processes each call insert_last on one store:
# both exit 0, ids() returns exactly two ids, two distinct valid ranks, and
# list() returns a total order containing both exactly once.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-8 fixture: store handle opens') or diag("error: $err");

    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $child = "$WORKDIR/mutate-child.pl";
    write_mutate_child($child);
    my $payloadA = "$WORKDIR/payload-a.json";
    my $payloadB = "$WORKDIR/payload-b.json";
    write_payload($payloadA, { id => 'ac8-a', fields => { title => 'A' }, order => ['title'] });
    write_payload($payloadB, { id => 'ac8-b', fields => { title => 'B' }, order => ['title'] });

    my $result = run_barrier_pair(
        $WORKDIR, $child,
        [$S, $root, 'note', 'IGNORED', 'insert_last', $payloadA],
        [$S, $root, 'note', 'IGNORED', 'insert_last', $payloadB],
    );

    if ($result) {
        my ($rc1) = $result->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $result->{done}{2} =~ /^RC=(-?\d+)/m;
        is($rc1, 0, 'AC-8: child 1 (insert_last) exits 0') or diag("done.1: $result->{done}{1}");
        is($rc2, 0, 'AC-8: child 2 (insert_last) exits 0') or diag("done.2: $result->{done}{2}");

        my $ids = eval { $store->ids() } if defined $store;
        is(ref($ids) eq 'ARRAY' ? scalar(@$ids) : -1, 2, 'AC-8: ids() returns exactly two ids') or diag('error: ' . ($@ // ''));

        my $recA = eval { $store->read('ac8-a') } if defined $store;
        my $recB = eval { $store->read('ac8-b') } if defined $store;
        my ($rankA, $rankB) = (defined $recA ? $recA->{rank} : undef, defined $recB ? $recB->{rank} : undef);
        ok(defined $rankA && defined $rankB && $rankA ne $rankB, 'AC-8: the two records\' ranks are distinct strings')
            or diag('rankA=' . ($rankA // 'undef') . ' rankB=' . ($rankB // 'undef'));

        my $valid_a = eval { Almanac::Store::rank_valid($rankA) } if defined $rankA;
        my $valid_b = eval { Almanac::Store::rank_valid($rankB) } if defined $rankB;
        ok($valid_a, 'AC-9: rank A satisfies rank_valid');
        ok($valid_b, 'AC-9: rank B satisfies rank_valid');

        my $list = eval { $store->list() } if defined $store;
        if (ref($list) eq 'ARRAY') {
            my @ids_in_list = map { $_->{id} } @$list;
            is_deeply([sort @ids_in_list], ['ac8-a', 'ac8-b'], 'AC-9: list() returns a total order containing both records exactly once');
        } else {
            fail('AC-9: list() returns a total order containing both records exactly once');
        }
    } else {
        fail($_) for ('AC-8: child 1 (insert_last) exits 0', 'AC-8: child 2 (insert_last) exits 0',
                       'AC-8: ids() returns exactly two ids', 'AC-8: the two records\' ranks are distinct strings',
                       'AC-9: rank A satisfies rank_valid', 'AC-9: rank B satisfies rank_valid',
                       'AC-9: list() returns a total order containing both records exactly once');
    }
}

# =============================================================================
# AC-26/AC-27 (DC7) -- a process killed via $ON_BEFORE_RENAME between the
# temp write and the rename, during an update: the record file is
# byte-identical to its pre-call content afterwards; the store stays usable.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-26 fixture: store handle opens') or diag("error: $err");
    my $rec = eval { $store->create(id => 'ac26-target', fields => { status => 'todo' }, order => ['status']) } if defined $store;
    ok(defined $rec, 'AC-26 fixture: the target record exists') or diag("error: $@");
    my $pre_bytes = defined $rec ? slurp_raw($rec->{path}) : undef;

    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $killchild = "$WORKDIR/kill-mid-write.pl";
    open(my $fh, '>', $killchild) or die "fixture: cannot write $killchild: $!";
    print {$fh} <<'KILLWRITE';
#!/usr/bin/env perl
use strict;
use warnings;
use POSIX ();
use Time::HiRes ();
$| = 1;
my ($workdir, $scripts_dir, $root, $type, $id) = @ARGV;
open(my $pf, '>', "$workdir/pid.1") or die $!; print {$pf} $$; close $pf;
local @INC = ($scripts_dir, @INC);
eval {
    require Almanac::Store;
    $Almanac::Store::ON_BEFORE_RENAME = sub {
        my ($path, $tmp, $verb) = @_;
        open(my $s, '>', "$workdir/crashed.1"); print {$s} "$tmp\n"; close $s;
        kill('KILL', $$);
        Time::HiRes::sleep(0.25);
        POSIX::_exit(137);
    };
    my $store = Almanac::Store->open(scope => 'project', type => $type, root => $root);
    my $baseline = $store->read($id);
    $store->update($id, expect => $baseline, set => { status => 'SHOULD-NEVER-LAND' });
    1;
} or do {
    # setup/require failed BEFORE the seam could ever fire -- a DIFFERENT
    # sentinel file than crashed.1, so the parent never mistakes "nothing
    # ran" for "the seam fired". Written promptly so the parent's bounded
    # wait does not hang for the full deadline while the module is missing.
    open(my $s, '>', "$workdir/setup-failed.1"); print {$s} "SETUP-FAILED: $@\n"; close $s;
    exit 3;
};
open(my $df, '>', "$workdir/done.1"); print {$df} "UNEXPECTED-COMPLETION\n"; close $df;
KILLWRITE
    close $fh;

    system(qq{perl "$killchild" "$WORKDIR" "$S" "$root" "note" "ac26-target" > "$WORKDIR/log.1" 2>&1 &});
    my $which26 = bounded_wait_for_any(["$WORKDIR/crashed.1", "$WORKDIR/setup-failed.1"], 15);
    ok(defined($which26) && $which26 =~ /crashed\.1$/,
       'AC-26: the child signalled the mid-write kill sentinel (the seam actually fired, not a setup failure)')
        or diag('observed: ' . (defined $which26 ? $which26 : '(neither sentinel appeared within 15s)')
              . '; setup-failed: ' . (slurp_text("$WORKDIR/setup-failed.1") // '(none)')
              . '; log: ' . (slurp_text("$WORKDIR/log.1") // '(missing)'));
    my $pid = bounded_wait_for_file("$WORKDIR/pid.1", 5) ? (slurp_text("$WORKDIR/pid.1") // '') : '';
    bounded_wait_for_death($pid, 10) if length $pid;

    my $post_bytes = defined $rec ? slurp_raw($rec->{path}) : undef;
    ok(defined($pre_bytes) && defined($post_bytes) && $post_bytes eq $pre_bytes,
       'AC-26: the record file is byte-identical to its pre-call content after the mid-write kill')
        or diag('pre defined=' . (defined $pre_bytes ? 'yes' : 'no') . ' post defined=' . (defined $post_bytes ? 'yes' : 'no'));

    # AC-27: the store is still usable afterwards.
    my $reread = eval { $store->read('ac26-target') } if defined $store;
    ok(defined $reread, 'AC-27: read() still succeeds after the mid-write kill') or diag('error: ' . ($@ // ''));
    my $list_ok = eval { $store->list(); 1 } if defined $store;
    ok($list_ok, 'AC-27: list() still succeeds after the mid-write kill') or diag('error: ' . ($@ // ''));

    my $fresh = eval { $store->update('ac26-target', expect => $reread, set => { status => 'fresh-writer-ok' }) } if defined $reread;
    ok(defined $fresh, 'AC-27: a fresh process\'s update succeeds after the mid-write kill') or diag('error: ' . ($@ // ''));

    my $ids = eval { $store->ids() } if defined $store;
    my @tmp_visible = (ref($ids) eq 'ARRAY') ? grep { /\.tmp\./ } @$ids : ();
    is(scalar(@tmp_visible), 0, 'AC-27: any <id>.md.tmp.* debris is invisible to ids()');
}

# =============================================================================
# AC-28 (DC7 / MR) -- grep: Store.pm never assigns $ON_BEFORE_RENAME outside
# its own `our` declaration, and never mentions on_rename.
# =============================================================================
{
    if (-f $STORE_PM) {
        open(my $fh, '<', $STORE_PM) or die;
        my @lines = <$fh>;
        close $fh;
        my @assigns;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            next if $l =~ /^\s*our\s+\$ON_BEFORE_RENAME\s*;/;
            push @assigns, "$STORE_PM:" . ($i + 1) . ": $l" if $l =~ /\$ON_BEFORE_RENAME\s*=/;
        }
        unless (ok(@assigns == 0, 'AC-28: Store.pm never assigns $ON_BEFORE_RENAME outside its own `our` declaration')) {
            diag($_) for @assigns;
        }
        my $di_word = 'on_' . 'rename';
        my @onrename_hits = grep { /\Q$di_word\E/i } @lines;
        is(scalar(@onrename_hits), 0, 'AC-28: Store.pm never mentions on_rename anywhere');
    } else {
        fail('AC-28: Store.pm never assigns $ON_BEFORE_RENAME outside its own `our` declaration');
        fail('AC-28: Store.pm never mentions on_rename anywhere');
    }
}

# =============================================================================
# AC-23 (DC5) -- a child killed mid-reorder (seam fires on the 2nd record
# write) leaves the journal on disk and a mixed on-disk order; the next
# list() restores the original order exactly and removes the journal; a
# second list() is a no-op and returns the same order.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-23 fixture: store handle opens') or diag("error: $err");
    my @ids_created;
    my $ok_create = 0;
    if (defined $store) {
        $ok_create = 1;
        for my $i (1 .. 4) {
            my $r = eval { $store->create(id => "ac23-$i", fields => { title => "t$i" }, order => ['title'], rank => sprintf('%02x', $i * 10) . 'V') };
            $ok_create = 0 unless defined $r;
            push @ids_created, "ac23-$i";
        }
    }
    ok($ok_create, 'AC-23 fixture: four ranked records exist') or diag("error: $@");

    my $pre_snapshot = {};
    for my $id (@ids_created) {
        my $r = eval { $store->read($id) } if defined $store;
        $pre_snapshot->{$id} = defined $r ? $r->{rank} : undef;
    }

    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $ids_file = "$WORKDIR/reorder-ids.json";
    write_raw($ids_file, JSON::PP->new->canonical->encode([reverse @ids_created]));

    my $killchild = "$WORKDIR/kill-mid-reorder.pl";
    open(my $fh, '>', $killchild) or die "fixture: cannot write $killchild: $!";
    print {$fh} <<'KILLREORDER';
#!/usr/bin/env perl
use strict;
use warnings;
use POSIX ();
use Time::HiRes ();
use JSON::PP ();
$| = 1;
my ($workdir, $scripts_dir, $root, $type, $ids_file) = @ARGV;
open(my $pf, '>', "$workdir/pid.1") or die $!; print {$pf} $$; close $pf;
local @INC = ($scripts_dir, @INC);
eval {
    require Almanac::Store;
    my $count = 0;
    $Almanac::Store::ON_BEFORE_RENAME = sub {
        my ($path, $tmp, $verb) = @_;
        $count++;
        return unless $count == 2;
        open(my $s, '>', "$workdir/crashed.1"); print {$s} "$tmp\n"; close $s;
        kill('KILL', $$);
        Time::HiRes::sleep(0.25);
        POSIX::_exit(137);
    };
    my $store = Almanac::Store->open(scope => 'project', type => $type, root => $root);
    my $raw = do { local $/; open my $f, '<', $ids_file or die $!; <$f> };
    my $ids = JSON::PP::decode_json($raw);
    $store->reorder($ids);
    1;
} or do {
    open(my $s, '>', "$workdir/setup-failed.1"); print {$s} "SETUP-FAILED: $@\n"; close $s;
    exit 3;
};
open(my $df, '>', "$workdir/done.1"); print {$df} "UNEXPECTED-COMPLETION\n"; close $df;
KILLREORDER
    close $fh;

    system(qq{perl "$killchild" "$WORKDIR" "$S" "$root" "note" "$ids_file" > "$WORKDIR/log.1" 2>&1 &});
    my $which23 = bounded_wait_for_any(["$WORKDIR/crashed.1", "$WORKDIR/setup-failed.1"], 15);
    ok(defined($which23) && $which23 =~ /crashed\.1$/,
       'AC-23: the child signalled the mid-reorder kill sentinel (the seam actually fired, not a setup failure)')
        or diag('observed: ' . (defined $which23 ? $which23 : '(neither sentinel appeared within 15s)')
              . '; setup-failed: ' . (slurp_text("$WORKDIR/setup-failed.1") // '(none)')
              . '; log: ' . (slurp_text("$WORKDIR/log.1") // '(missing)'));
    my $pid = bounded_wait_for_file("$WORKDIR/pid.1", 5) ? (slurp_text("$WORKDIR/pid.1") // '') : '';
    bounded_wait_for_death($pid, 10) if length $pid;

    my $dir = eval { $store->dir } if defined $store;
    my $journal_path = defined $dir ? "$dir/.reorder-journal.json" : undef;
    ok(defined $journal_path && -f $journal_path, 'AC-23: the journal file exists after the mid-reorder kill');

    my $changed = 0;
    for my $id (@ids_created) {
        my $r = eval { $store->read($id) } if defined $store;
        my $now_rank = defined $r ? $r->{rank} : undef;
        $changed++ if defined $now_rank && defined $pre_snapshot->{$id} && $now_rank ne $pre_snapshot->{$id};
    }
    ok($changed > 0 && $changed < scalar(@ids_created), 'AC-23: the on-disk order is mixed (at least one but not all ranks changed)')
        or diag("changed=$changed of " . scalar(@ids_created));

    # The recovering list() call happens in THIS process, which never set
    # $ON_BEFORE_RENAME -- module-level state is per-process.
    my $list1 = eval { $store->list() } if defined $store;
    if (ref($list1) eq 'ARRAY') {
        my @order1 = map { $_->{id} } @$list1;
        is_deeply(\@order1, \@ids_created, 'AC-23: the next list() restores the ORIGINAL (previous) order exactly');
    } else {
        fail('AC-23: the next list() restores the ORIGINAL (previous) order exactly');
    }
    ok(!-f $journal_path, 'AC-23: ...and removes the journal') if defined $journal_path;

    my $list2 = eval { $store->list() } if defined $store;
    if (ref($list1) eq 'ARRAY' && ref($list2) eq 'ARRAY') {
        is_deeply([map { $_->{id} } @$list2], [map { $_->{id} } @$list1], 'AC-23: a second list() is a no-op and returns the same order');
    } else {
        fail('AC-23: a second list() is a no-op and returns the same order');
    }
}

# =============================================================================
# AC-24 (DC5) -- recover() returns 0 and takes no lock when no journal
# exists, asserted by the .store.lock.holder file being absent/unchanged
# after a list() on a journal-free store.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-24 fixture: store handle opens') or diag("error: $err");
    eval { $store->create(id => 'ac24-only', fields => { t => '1' }, order => ['t']) } if defined $store;

    my $dir = eval { $store->dir } if defined $store;
    my $holder_path = defined $dir ? "$dir/.store.lock.holder" : undef;
    ok(defined $holder_path && !-e $holder_path, 'AC-24 fixture: no store-lock holder file exists before list()');

    my $rv = eval { $store->recover() } if defined $store;
    is($rv, 0, 'AC-24: recover() returns 0 when no journal exists') or diag('error: ' . ($@ // ''));

    eval { $store->list() } if defined $store;
    ok(!-e $holder_path, 'AC-24: the store-lock holder file is still absent after list() on a journal-free store (no lock was taken)')
        if defined $holder_path;
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
