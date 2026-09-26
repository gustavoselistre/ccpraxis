#!/usr/bin/env perl
# platform: any
# Oracle for blueprint hook-continuity-remake, package 18 (spec
# specs/18-almanac-insert-perf-spec.md, ACs a-l; Decision 135). Asserts that
# Almanac::Store's four insert verbs (insert_first, insert_last,
# insert_before, insert_after) stop paying an O(n) full-record read for every
# call by using a per-handle rank cache instead of list(), while never
# serving a stale rank. Uses tempdir stores only -- never the live store --
# and spawns at most one child process (test h), bounded by alarm(). No
# wall-clock assertion anywhere; every AC here is either a RECORD_READS delta
# bound or a list()-order assertion.
#
# WINDOWS NOTE (Decision 135): Perl's stat ctime on this host is the file's
# CREATION time, not a change time, so no assertion here treats ctime as
# evidence that a file changed. Tests f/i use size and mtime instead (f
# explicitly forces both back to their pre-update values via utime() and
# checks that restoration, never ctime).
#
# HOUSE PATTERN for a not-yet-built feature: every direct call into
# Almanac::Store (including the rank_between/rank_valid helpers) that can die
# is wrapped in eval{} so a die from missing behaviour is a caught, reported
# failure for THIS assertion, never an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $STORE_PM  = "$S/Almanac/Store.pm";
my $RECORD_PM = "$S/Almanac/Record.pm";

# ---------------------------------------------------------------------------
# live-store sanity (house convention, shared with the sibling Store test
# files) -- run before anything else touches a real filesystem.
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

ok(-f $STORE_PM, 'Almanac::Store module file exists')
    or diag('Almanac/Store.pm is not present -- every assertion below is expected to fail for exactly that reason.');
my $HAVE_STORE = eval { require Almanac::Store; 1 };
ok($HAVE_STORE, 'Almanac::Store requires cleanly') or diag("load error: $@");
ok(-f $RECORD_PM, 'Almanac::Record module file exists');
my $HAVE_RECORD = eval { require Almanac::Record; 1 };
ok($HAVE_RECORD, 'Almanac::Record requires cleanly') or diag("load error: $@");

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub err_kind  { my ($e) = @_; return (ref($e) =~ /::Error$/) ? $e->{kind}  : undef }
sub err_field { my ($e, $f) = @_; return (ref($e) =~ /::Error$/) ? $e->{$f} : undef }

sub new_root {
    my $r = tempdir(CLEANUP => 1);
    $r =~ s{\\}{/}g;
    return $r;
}

sub open_store {
    my ($root) = @_;
    return eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root) };
}

# reads_now() -- the counter, tolerant of not existing yet (AC-a's own
# subject). Every delta computed with this never dies even before
# $RECORD_READS is declared.
sub reads_now {
    no strict 'refs';
    no warnings 'uninitialized';
    return defined($Almanac::Store::RECORD_READS) ? $Almanac::Store::RECORD_READS + 0 : 0;
}

# build_between_of_length($lo, $hi, $len) -> $r | undef
#
# A rank strictly between $lo and $hi, of EXACTLY $len characters, used by
# test f. rank_between($lo,$hi) already returns something strictly between
# the two (by construction, at the first digit position where they diverge
# by >=2); padding it on the right with '1' characters preserves both
# inequalities because byte-wise string comparison already resolved at that
# earlier, unpadded position, and never revisits it. Returns undef (a
# reported precondition failure, not a silent skip) if $len is shorter than
# the natural midpoint or if the padded result is somehow not rank_valid.
sub build_between_of_length {
    my ($lo, $hi, $len) = @_;
    my $mid = eval { Almanac::Store::rank_between($lo, $hi) };
    return undef unless defined $mid;
    return undef if length($mid) > $len;
    my $r = $mid . ('1' x ($len - length($mid)));
    return undef unless Almanac::Store::rank_valid($r);
    return undef unless $lo lt $r && $r lt $hi;
    return $r;
}

# =============================================================================
# a. The counter exists and is wired.
# =============================================================================
{
    ok(defined($Almanac::Store::RECORD_READS) && $Almanac::Store::RECORD_READS =~ /\A\d+\z/,
       'a: $Almanac::Store::RECORD_READS is defined and numeric after require')
        or diag('RECORD_READS TEST SEAM value: ' . (defined($Almanac::Store::RECORD_READS) ? $Almanac::Store::RECORD_READS : '(undef)'));

    my $root  = new_root();
    my $store = open_store($root);
    ok(defined $store, 'a fixture: store handle opens') or diag("error: $@");

    if (defined $store) {
        my $rec1 = eval { $store->create(id => 'r1') };
        ok(defined $rec1, 'a fixture: one record created') or diag("error: $@");

        my $before1 = reads_now();
        my $got     = eval { $store->read('r1') };
        my $after1  = reads_now();
        ok(defined $got, 'a fixture: read(r1) succeeds') or diag("error: $@");
        is($after1 - $before1, 1, 'a: read() raises $RECORD_READS by exactly 1');

        my $more_ok = 1;
        for my $i (2 .. 5) {
            my $r = eval { $store->create(id => "r$i") };
            $more_ok = 0 unless defined $r;
        }
        ok($more_ok, 'a fixture: four more records created (K=5 total)');

        my $before2 = reads_now();
        my $list    = eval { $store->list() };
        my $after2  = reads_now();
        ok(ref($list) eq 'ARRAY' && @$list == 5, 'a fixture: list() over K=5 records succeeds') or diag("error: $@");
        is($after2 - $before2, 5, 'a: list() over K=5 records raises $RECORD_READS by exactly K (behaviour 7)');
    } else {
        fail('a: read() raises $RECORD_READS by exactly 1');
        fail('a: list() over K=5 records raises $RECORD_READS by exactly K (behaviour 7)');
    }
}

# =============================================================================
# b. Cold scan is counted.
# =============================================================================
{
    my $root  = new_root();
    my $seeder = open_store($root);
    ok(defined $seeder, 'b fixture: seeding handle opens') or diag("error: $@");

    my $M = 20;
    my $seed_ok = 1;
    if (defined $seeder) {
        for my $i (1 .. $M) {
            my $r = eval { $seeder->insert_last(id => "seed$i") };
            $seed_ok = 0 unless defined $r;
        }
    } else {
        $seed_ok = 0;
    }
    ok($seed_ok, "b fixture: $M pre-created ranked records via insert_last through a different handle");

    my $fresh = open_store($root);
    ok(defined $fresh, 'b fixture: a fresh handle opens on the same root') or diag("error: $@");

    if (defined $fresh) {
        my $before = reads_now();
        my $r      = eval { $fresh->insert_last(id => 'coldnew') };
        my $after  = reads_now();
        ok(defined $r, 'b fixture: the first insert_last through the fresh handle succeeds') or diag("error: $@");
        cmp_ok($after - $before, '>=', $M,
            "b: the first insert_last through a fresh handle raises \$RECORD_READS by at least M=$M (a cold cache)");
    } else {
        fail("b: the first insert_last through a fresh handle raises \$RECORD_READS by at least M=$M (a cold cache)");
    }
}

# =============================================================================
# c. Linear insert_after against an unranked anchor (the AC-16 shape).
# =============================================================================
for my $N (100, 200) {
    my $root  = new_root();
    my $store = open_store($root);
    ok(defined $store, "c fixture N=$N: store handle opens") or diag("error: $@");
    next unless defined $store;

    my $anchor = eval { $store->create(id => 'anchor') };
    ok(defined $anchor, "c fixture N=$N: the unranked anchor record exists") or diag("error: $@");
    next unless defined $anchor;

    my $before  = reads_now();
    my @ids;
    my $all_ok = 1;
    for my $i (1 .. $N) {
        my $r = eval { $store->insert_after('anchor', id => "ins$i") };
        unless (defined $r) { $all_ok = 0; last; }
        push @ids, "ins$i";
    }
    my $after = reads_now();
    ok($all_ok && @ids == $N, "c: N=$N sequential insert_after(anchor) calls all succeed")
        or diag('succeeded so far: ' . scalar(@ids) . " of $N; error: " . ($@ // ''));

    my $delta = $after - $before;
    cmp_ok($delta, '<=', 3 * $N + 3,
        "c: N=$N total \$RECORD_READS delta is at most 3N+3 (got $delta, bound " . (3 * $N + 3) . ')');

    my $list = eval { $store->list() };
    if (ref($list) eq 'ARRAY') {
        my @after_anchor = grep { $_->{id} ne 'anchor' } @$list;
        my @expect        = reverse @ids;
        is_deeply([ map { $_->{id} } @after_anchor ], \@expect,
            "c: N=$N list() id order is the exact reverse of insertion order after the anchor");
    } else {
        fail("c: N=$N list() id order is the exact reverse of insertion order after the anchor");
    }
}

# =============================================================================
# d. Linear for every verb.
# =============================================================================
{
    my %expect_of = (
        insert_last   => sub { my (@ins) = @_; return ('seed', @ins) },
        insert_first  => sub { my (@ins) = @_; return (reverse(@ins), 'seed') },
        insert_after  => sub { my (@ins) = @_; return ('seed', @ins) },
        insert_before => sub { my (@ins) = @_; return (reverse(@ins), 'seed') },
    );
    my $N = 100;

    for my $verb (qw(insert_last insert_first insert_after insert_before)) {
        my $root  = new_root();
        my $store = open_store($root);
        ok(defined $store, "d fixture ($verb): store handle opens") or diag("error: $@");
        next unless defined $store;

        my $seed = eval { $store->insert_last(id => 'seed') };
        ok(defined $seed, "d fixture ($verb): one ranked seed record exists") or diag("error: $@");
        next unless defined $seed;

        my @ids;
        my $ref     = 'seed';
        my $all_ok  = 1;
        my $before  = reads_now();
        for my $i (1 .. $N) {
            my $id = "ins$i";
            my $r;
            if    ($verb eq 'insert_last')   { $r = eval { $store->insert_last(id => $id) } }
            elsif ($verb eq 'insert_first')  { $r = eval { $store->insert_first(id => $id) } }
            elsif ($verb eq 'insert_after')  { $r = eval { $store->insert_after($ref, id => $id) }; $ref = $id }
            else                             { $r = eval { $store->insert_before($ref, id => $id) }; $ref = $id }
            unless (defined $r) { $all_ok = 0; last; }
            push @ids, $id;
        }
        my $after = reads_now();
        ok($all_ok && @ids == $N, "d ($verb): $N calls all succeed")
            or diag('succeeded so far: ' . scalar(@ids) . " of $N; error: " . ($@ // ''));

        my $delta = $after - $before;
        cmp_ok($delta, '<=', 3 * $N + 3, "d ($verb): \$RECORD_READS delta is at most 3N+3 (got $delta)");

        my $list = eval { $store->list() };
        if (ref($list) eq 'ARRAY') {
            my @expect = $expect_of{$verb}->(@ids);
            is_deeply([ map { $_->{id} } @$list ], \@expect, "d ($verb): final list() id order is exactly the expected one");
        } else {
            fail("d ($verb): final list() id order is exactly the expected one");
        }
    }
}

# =============================================================================
# e. Warm-cache single insert is O(1) reads.
# =============================================================================
{
    my $root  = new_root();
    my $store = open_store($root);
    ok(defined $store, 'e fixture: store handle opens') or diag("error: $@");

    if (defined $store) {
        my $warm_ok = 1;
        my $last_id;
        for my $i (1 .. 200) {
            my $r = eval { $store->insert_last(id => "w$i") };
            unless (defined $r) { $warm_ok = 0; last; }
            $last_id = "w$i";
        }
        ok($warm_ok, 'e fixture: 200 records inserted through this handle, warming its cache');

        if ($warm_ok) {
            my $before = reads_now();
            my $r      = eval { $store->insert_after($last_id, id => 'warmnew') };
            my $after  = reads_now();
            ok(defined $r, 'e fixture: the warm insert_after succeeds') or diag("error: $@");
            cmp_ok($after - $before, '<=', 3,
                'e: one more insert_after on a warm 200-record handle raises $RECORD_READS by at most 3');
        } else {
            fail('e: one more insert_after on a warm 200-record handle raises $RECORD_READS by at most 3');
        }
    } else {
        fail('e: one more insert_after on a warm 200-record handle raises $RECORD_READS by at most 3');
    }
}

# =============================================================================
# f. Another handle's same-size rank change is seen (behaviour 4, the seal is
#    load-bearing). See the file header for why ctime plays no part here.
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'f fixture: handle A opens') or diag("error: $@");

    my ($x1, $x2, $x3);
    if (defined $A) {
        $x1 = eval { $A->insert_last(id => 'x1') };
        $x2 = eval { $A->insert_last(id => 'x2') };
        $x3 = eval { $A->insert_last(id => 'x3') };
    }
    ok(defined $x1 && defined $x2 && defined $x3, 'f fixture: x1 x2 x3 created via A, warming A\'s cache')
        or diag("error: $@");

    my $R;
    my $X3;
    if (defined $x1 && defined $x2 && defined $x3) {
        $X3 = $x3->{rank};
        my $Supper  = eval { Almanac::Store::rank_between($X3, undef) };
        my $Bbound  = eval { defined $Supper ? Almanac::Store::rank_between($X3, $Supper) : undef };
        ok(defined $Supper && defined $Bbound, 'f fixture: the stale-mint bound is computable') or diag("error: $@");

        if (defined $Bbound) {
            my $L = length($x1->{rank});
            $R = build_between_of_length($X3, $Bbound, $L);
        }
        ok(defined $R
            && Almanac::Store::rank_valid($R)
            && length($R) == length($x1->{rank})
            && $X3 lt $R
            && $R lt (defined $Supper ? Almanac::Store::rank_between($X3, $Supper) : ''),
            'f precondition: R is a valid same-length rank with X3 < R < rank_between(X3,S)')
            or diag('X3=' . (defined $X3 ? $X3 : '?') . ' R=' . (defined $R ? $R : '(undef)'));
    } else {
        fail('f precondition: R is a valid same-length rank with X3 < R < rank_between(X3,S)');
    }

    if (defined $R) {
        my $B = open_store($root);
        ok(defined $B, 'f fixture: handle B opens on the same root') or diag("error: $@");

        my $x1_via_B = eval { $B->read('x1') } if defined $B;
        ok(defined $x1_via_B, 'f fixture: B reads x1') or diag("error: $@");

        my $x1_path = eval { $A->dir } . '/x1.md';
        my @st_before = stat($x1_path);
        ok(scalar(@st_before) > 0, 'f fixture: x1.md stat succeeds before B\'s update');

        my $upd = eval {
            $B->update('x1', expect => { rev => $x1_via_B->{rev}, fields => $x1_via_B->{fields} }, rank => $R)
        } if defined $x1_via_B;
        ok(defined $upd, 'f fixture: B updates x1 to rank R') or diag("error: $@");

        if (defined $upd && @st_before) {
            utime($st_before[8], $st_before[9], $x1_path);
            my @st_after = stat($x1_path);
            is($st_after[7], $st_before[7], 'f precondition: x1.md size is unchanged by B\'s update');
            is($st_after[9], $st_before[9], 'f precondition: x1.md mtime equals its pre-update mtime (restored)');
        } else {
            fail('f precondition: x1.md size is unchanged by B\'s update');
            fail('f precondition: x1.md mtime equals its pre-update mtime (restored)');
        }

        # On this Cygwin perl, rename() always gives the renamed file a new
        # inode, so the stat signature ALONE already differs after B's
        # update (dev/size/mtime restored to match, but ino changed) --
        # meaning a mutant that checks only the stat signature (never the
        # seal) still passes every assertion above. To make the seal digest
        # the deciding check, force-feed A's cached signature to match the
        # file's CURRENT (post-restore) signature, built exactly as
        # _rank_scan builds it, so only the seal digest can still tell the
        # cache apart from B's rewritten x1.md.
        my $cache_entry = eval { $A->{_rank_cache}{x1} };
        ok(defined $cache_entry, 'f fixture: A\'s rank cache holds x1 before the seal-only tamper')
            or diag("error: $@");

        if (defined $cache_entry) {
            my @st_now  = stat($x1_path);
            my $sig_now = @st_now
                ? join(',', $st_now[0], $st_now[1], $st_now[7], $st_now[9], $st_now[10])
                : '';
            $cache_entry->{sig} = $sig_now;
        }

        my $y = eval { $A->insert_after('x3', id => 'y') };
        ok(defined $y, 'f: A inserts y after x3') or diag("error: $@");

        my $list = eval { $A->list() };
        if (ref($list) eq 'ARRAY') {
            is_deeply([ map { $_->{id} } @$list ], [qw(x2 x3 y x1)],
                'f: final list() order is x2 x3 y x1 (another handle\'s same-size rank change is seen, '
                . 'caught by the seal alone despite the tampered stat signature)');
        } else {
            fail('f: final list() order is x2 x3 y x1 (another handle\'s same-size rank change is seen, '
                . 'caught by the seal alone despite the tampered stat signature)');
        }

    } else {
        fail('f: final list() order is x2 x3 y x1 (another handle\'s same-size rank change is seen, '
            . 'caught by the seal alone despite the tampered stat signature)');
    }
}

# =============================================================================
# g. Another handle's reorder is seen.
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'g fixture: handle A opens') or diag("error: $@");

    my ($r1, $r2, $r3);
    if (defined $A) {
        $r1 = eval { $A->insert_last(id => 'r1') };
        $r2 = eval { $A->insert_last(id => 'r2') };
        $r3 = eval { $A->insert_last(id => 'r3') };
    }
    ok(defined $r1 && defined $r2 && defined $r3, 'g fixture: r1 r2 r3 created via A, warming A\'s cache')
        or diag("error: $@");

    if (defined $r1 && defined $r2 && defined $r3) {
        my $B = open_store($root);
        ok(defined $B, 'g fixture: handle B opens on the same root') or diag("error: $@");

        my $reord = eval { $B->reorder([qw(r3 r2 r1)]) } if defined $B;
        ok(defined $reord, 'g fixture: B reorders to r3 r2 r1') or diag("error: $@");

        my $z = eval { $A->insert_after('r3', id => 'z') };
        ok(defined $z, 'g: A inserts z after r3') or diag("error: $@");

        my $list = eval { $A->list() };
        if (ref($list) eq 'ARRAY') {
            is_deeply([ map { $_->{id} } @$list ], [qw(r3 z r2 r1)],
                'g: final order is r3 z r2 r1 (another handle\'s reorder is seen)');
        } else {
            fail('g: final order is r3 z r2 r1 (another handle\'s reorder is seen)');
        }
    } else {
        fail('g: final order is r3 z r2 r1 (another handle\'s reorder is seen)');
    }
}

# =============================================================================
# h. A real other process is seen. Same shape as g, but the reorder runs in
#    one child process, bounded by alarm() (this is a test file, not
#    Store.pm -- the alarm()-forbidding rule is Store.pm's, not this file's).
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'h fixture: handle A opens') or diag("error: $@");

    my ($hr1, $hr2, $hr3);
    if (defined $A) {
        $hr1 = eval { $A->insert_last(id => 'hr1') };
        $hr2 = eval { $A->insert_last(id => 'hr2') };
        $hr3 = eval { $A->insert_last(id => 'hr3') };
    }
    ok(defined $hr1 && defined $hr2 && defined $hr3, 'h fixture: hr1 hr2 hr3 created via A, warming A\'s cache')
        or diag("error: $@");

    if (defined $hr1 && defined $hr2 && defined $hr3) {
        my $child_code =
            'use strict; use warnings; require Almanac::Store; '
          . 'my ($root, @ids) = @ARGV; '
          . 'my $s = Almanac::Store->open(scope => "project", type => "note", root => $root); '
          . '$s->reorder(\@ids); exit 0;';

        my $rc;
        my $timeout_err;
        {
            local $SIG{ALRM} = sub { die "h: child process timed out\n" };
            alarm(60);
            eval {
                system($^X, '-I', $S, '-e', $child_code, $root, 'hr3', 'hr2', 'hr1');
                $rc = $? >> 8;
            };
            $timeout_err = $@;
            alarm(0);
        }
        diag("h: child process error: $timeout_err") if $timeout_err;
        is($rc, 0, 'h fixture: the child process reorder (hr3 hr2 hr1) exits 0');

        my $z = eval { $A->insert_after('hr3', id => 'hz') };
        ok(defined $z, 'h: A inserts hz after hr3') or diag("error: $@");

        my $list = eval { $A->list() };
        if (ref($list) eq 'ARRAY') {
            is_deeply([ map { $_->{id} } @$list ], [qw(hr3 hz hr2 hr1)],
                'h: final order is hr3 hz hr2 hr1 (a real other process is seen)');
        } else {
            fail('h: final order is hr3 hz hr2 hr1 (a real other process is seen)');
        }
    } else {
        fail('h: final order is hr3 hz hr2 hr1 (a real other process is seen)');
    }
}

# =============================================================================
# i. Out-of-band size-changing edit is seen (behaviour 5).
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'i fixture: handle A opens') or diag("error: $@");

    my ($o1, $o2, $o3);
    if (defined $A) {
        $o1 = eval { $A->insert_last(id => 'o1') };
        $o2 = eval { $A->insert_last(id => 'o2') };
        $o3 = eval { $A->insert_last(id => 'o3') };
    }
    ok(defined $o1 && defined $o2 && defined $o3, 'i fixture: o1 o2 o3 created via A, warming A\'s cache')
        or diag("error: $@");

    if (defined $o1 && defined $o2 && defined $o3) {
        my $O3      = $o3->{rank};
        my $upper   = eval { Almanac::Store::rank_between($O3, undef) };
        my $newrank = eval { defined $upper ? Almanac::Store::rank_between($O3, $upper) : undef };
        ok(defined $newrank, 'i fixture: a rank strictly between o3 and the space above it is computable')
            or diag("error: $@");

        if (defined $newrank) {
            my $o1_path = eval { $A->dir } . '/o1.md';
            my $bytes = eval {
                Almanac::Record::serialize({
                    fields => { id => 'o1', rank => $newrank, writer => $o1->{fields}{writer} },
                    order  => [qw(id rank writer)],
                    body   => "a deliberately much longer body than the original, so the on-disk size changes materially.\n" x 5,
                    path   => $o1_path,
                })
            };
            ok(defined $bytes, 'i fixture: the replacement o1.md bytes serialize') or diag("error: $@");

            if (defined $bytes) {
                open(my $fh, '>:raw', $o1_path) or die "i fixture: cannot write $o1_path: $!";
                print {$fh} $bytes;
                close $fh;
                # Deliberately do NOT touch o1.md.seal: this is an out-of-band
                # (not-via-Store) edit, per behaviour 5.

                my $w = eval { $A->insert_after('o3', id => 'w') };
                ok(defined $w, 'i: A inserts w after o3') or diag("error: $@");

                my $list = eval { $A->list() };
                if (ref($list) eq 'ARRAY') {
                    is_deeply([ map { $_->{id} } @$list ], [qw(o2 o3 w o1)],
                        'i: final order is o2 o3 w o1 (an out-of-band size-changing edit is seen)');
                } else {
                    fail('i: final order is o2 o3 w o1 (an out-of-band size-changing edit is seen)');
                }
            } else {
                fail('i: final order is o2 o3 w o1 (an out-of-band size-changing edit is seen)');
            }
        } else {
            fail('i: final order is o2 o3 w o1 (an out-of-band size-changing edit is seen)');
        }
    } else {
        fail('i: final order is o2 o3 w o1 (an out-of-band size-changing edit is seen)');
    }
}

# =============================================================================
# j. Out-of-band corruption dies malformed (behaviour 8).
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'j fixture: handle A opens') or diag("error: $@");

    my ($c1, $c2);
    if (defined $A) {
        $c1 = eval { $A->insert_last(id => 'c1') };
        $c2 = eval { $A->insert_last(id => 'c2') };
    }
    ok(defined $c1 && defined $c2, 'j fixture: c1 c2 created via A, warming A\'s cache') or diag("error: $@");

    if (defined $c1 && defined $c2) {
        my $c1_path = eval { $A->dir } . '/c1.md';
        my $junk = "this file has no frontmatter delimiter at all, so Almanac::Record::check fails on it, "
                 . "and it is deliberately much longer than the original record so its size differs too.\n" x 3;
        open(my $fh, '>:raw', $c1_path) or die "j fixture: cannot write $c1_path: $!";
        print {$fh} $junk;
        close $fh;
        # Deliberately do NOT touch c1.md.seal.

        my $r = eval { $A->insert_last(id => 'c3') };
        my $err = $@;
        ok(!defined $r, 'j: A\'s next insert_last dies rather than succeeding');
        is(err_kind($err), 'malformed', 'j: the die has kind malformed (out-of-band corruption is never served from cache)');
        is(err_field($err, 'id'), 'c1', 'j: the malformed error names c1, the corrupted record');
    } else {
        fail('j: A\'s next insert_last dies rather than succeeding');
        fail('j: the die has kind malformed (out-of-band corruption is never served from cache)');
        fail('j: the malformed error names c1, the corrupted record');
    }
}

# =============================================================================
# k. Unsealed records are never served from cache (behaviour 6).
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'k fixture: handle A opens') or diag("error: $@");

    my @orig_ids;
    my $seed_ok = defined($A) ? 1 : 0;
    if (defined $A) {
        for my $i (1 .. 10) {
            my $r = eval { $A->insert_last(id => "u$i") };
            unless (defined $r) { $seed_ok = 0; last; }
            push @orig_ids, "u$i";
        }
    }
    ok($seed_ok, 'k fixture: 10 records created via insert_last');

    if ($seed_ok) {
        my $dir = eval { $A->dir };
        opendir(my $dh, $dir) or die "k fixture: cannot open $dir: $!";
        my @seals = grep { /\.md\.seal\z/ } readdir($dh);
        closedir $dh;
        unlink("$dir/$_") for @seals;
        ok(scalar(@seals) >= 10, 'k fixture: at least 10 .seal files existed and were deleted')
            or diag('found ' . scalar(@seals) . ' seal files');

        my @new_ids;
        my @deltas;
        my $insert_ok = 1;
        for my $i (1 .. 5) {
            my $before = reads_now();
            my $r      = eval { $A->insert_last(id => "new$i") };
            my $after  = reads_now();
            unless (defined $r) { $insert_ok = 0; last; }
            push @new_ids, "new$i";
            push @deltas, $after - $before;
        }
        ok($insert_ok, 'k: 5 insert_last calls through one handle all succeed')
            or diag('error: ' . ($@ // ''));

        if ($insert_ok) {
            my $min_ok = 1;
            $min_ok = 0 if grep { $_ < 10 } @deltas;
            ok($min_ok, 'k: each call\'s $RECORD_READS delta is at least 10 (unsealed originals are re-read every call)')
                or diag('deltas: ' . join(',', @deltas));
        } else {
            fail('k: each call\'s $RECORD_READS delta is at least 10 (unsealed originals are re-read every call)');
        }

        my $list = eval { $A->list() };
        if (ref($list) eq 'ARRAY') {
            is_deeply([ map { $_->{id} } @$list ], [ @orig_ids, @new_ids ],
                'k: final order is the 10 originals then the 5 new records, in insertion order');
        } else {
            fail('k: final order is the 10 originals then the 5 new records, in insertion order');
        }
    } else {
        fail('k: each call\'s $RECORD_READS delta is at least 10 (unsealed originals are re-read every call)');
        fail('k: final order is the 10 originals then the 5 new records, in insertion order');
    }
}

# =============================================================================
# l. No new lock.
# =============================================================================
{
    my $root = new_root();
    my $A    = open_store($root);
    ok(defined $A, 'l fixture: handle A opens') or diag("error: $@");

    if (defined $A) {
        my $ok = 1;
        for my $i (1 .. 5) {
            my $r = eval { $A->insert_last(id => "lk$i") };
            unless (defined $r) { $ok = 0; last; }
        }
        ok($ok, 'l fixture: 5 insert_last calls succeed on a journal-free store') or diag('error: ' . ($@ // ''));

        my $dir = eval { $A->dir };
        ok(!-e "$dir/.store.lock.holder",
            'l: no .store.lock.holder exists after a series of inserts (inserts never took the store lock)');
    } else {
        fail('l: no .store.lock.holder exists after a series of inserts (inserts never took the store lock)');
    }
}

done_testing();
