#!/usr/bin/env perl
# platform: any
# Immutable oracle for the almanac store module's ORDERING half (blueprint
# almanac-records, package 03-store): the base-62 rank algebra (rank_between,
# rank_valid, rank_jitter), the precision argument over 1000 sequential
# insertions, a scripted multi-step insert sequence, and reorder()'s
# store-wide-lock discipline including the DC5 mismatch refusal. CRUD and
# real-process concurrency ACs live in the sibling files. See
# specs/03-store-spec.md section 2.10/2.11.
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

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $STORE_PM = "$S/Almanac/Store.pm";

sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}
sub err_kind { my ($e) = @_; return (ref($e) =~ /::Error$/) ? $e->{kind} : undef }

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

ok(-f $STORE_PM, 'Almanac::Store module file exists') or diag('Almanac/Store.pm is not present yet -- every assertion below is expected to fail for exactly that reason.');
my $HAVE_STORE = eval { require Almanac::Store; 1 };
ok($HAVE_STORE, 'Almanac::Store requires cleanly') or diag("load error: $@");

sub open_test_store {
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my $store = eval { Almanac::Store->open(scope => 'project', type => 'todo', root => $root) };
    return ($root, $store, $@);
}

# =============================================================================
# AC-10 -- the three pinned constants.
# =============================================================================
{
    my $v = eval { Almanac::Store::rank_between(undef, undef) };
    is($v, 'V', "AC-10: rank_between(undef,undef) eq 'V'") or diag('error: ' . ($@ // ''));
    my $f = eval { Almanac::Store::rank_between(undef, 'V') };
    is($f, 'F', "AC-10: rank_between(undef,'V') eq 'F'") or diag('error: ' . ($@ // ''));
    my $k = eval { Almanac::Store::rank_between('V', undef) };
    is($k, 'k', "AC-10: rank_between('V',undef) eq 'k'") or diag('error: ' . ($@ // ''));
}

# =============================================================================
# AC-11/AC-12/AC-14 -- 200 pseudo-random pairs drawn from a growing corpus of
# generated ranks: betweenness, validity, no trailing '0', and suffix safety
# under an appended jitter.
# =============================================================================
{
    my @pool;
    my $grow_ok = 0;
    if ($HAVE_STORE) {
        $grow_ok = eval {
            @pool = (Almanac::Store::rank_between(undef, undef));
            for (1 .. 210) {
                my $pos = int(rand(scalar(@pool) + 1));
                my $lo  = $pos > 0        ? $pool[$pos - 1] : undef;
                my $hi  = $pos <= $#pool  ? $pool[$pos]     : undef;
                my $new = Almanac::Store::rank_between($lo, $hi);
                die "corpus generation returned an undef/invalid rank\n" unless defined $new;
                splice(@pool, $pos, 0, $new);
            }
            1;
        };
    }
    unless ($grow_ok && @pool >= 211) {
        # Fallback corpus so the pair-sampling loop below still runs its
        # full intended count -- every assertion drawn from it is still
        # expected to fail against the real rank algebra right now.
        @pool = map { sprintf('rank%04d', $_) } (1 .. 211);
    }
    diag('AC-11 corpus: ' . scalar(@pool) . ' ranks generated (grow_ok=' . ($grow_ok ? 1 : 0) . ')');

    for my $trial (1 .. 200) {
        my $i = int(rand(scalar(@pool) - 1));
        my $j = $i + 1 + int(rand(scalar(@pool) - $i - 1));
        my ($a, $b) = ($pool[$i], $pool[$j]);
        next unless $a lt $b;

        my $key = eval { Almanac::Store::rank_between($a, $b) };
        my $kerr = $@;
        ok(defined($key) && $a lt $key && $key lt $b,
           "AC-11: rank_between() trial $trial returns a key strictly between its inputs (byte comparison)")
            or diag("a=$a b=$b key=" . (defined $key ? $key : '(undef)') . " error=$kerr");

        my $valid = defined($key) ? eval { Almanac::Store::rank_valid($key) } : undef;
        ok($valid, "AC-11: ...and rank_valid() accepts it, trial $trial");

        ok(defined($key) && $key !~ /0\z/, "AC-12: rank_between() trial $trial does not return a rank ending in '0'");

        my $jit = $HAVE_STORE ? eval { Almanac::Store::rank_jitter() } : undef;
        $jit = 'zzzz' unless defined $jit && length $jit == 4;
        if (defined $key) {
            my $withjit = $key . $jit;
            ok($a lt $withjit && $withjit lt $b,
               "AC-14: appending a 4-char jitter to trial $trial's rank preserves both strict inequalities");
        } else {
            fail("AC-14: appending a 4-char jitter to trial $trial's rank preserves both strict inequalities");
        }
    }

    # AC-12 also covers the pinned constants.
    for my $pinned (['V', undef, undef], ['F', undef, 'V'], ['k', 'V', undef]) {
        my ($expect_val, $a, $b) = @$pinned;
        my $key = eval { Almanac::Store::rank_between($a, $b) };
        ok(defined($key) && $key !~ /0\z/, "AC-12: the pinned constant for ($a," . ($b // 'undef') . ") does not end in '0'");
    }
}

# =============================================================================
# AC-13 -- rank_between($a,$b) with $a ge $b dies usage; with an R1-violating
# rank dies bad_rank.
# =============================================================================
{
    for my $pair (['B', 'A'], ['A', 'A']) {
        my ($a, $b) = @$pair;
        my $r = eval { Almanac::Store::rank_between($a, $b) };
        is(err_kind($@), 'usage', "AC-13: rank_between('$a','$b') with a ge b dies usage")
            or diag('got: ' . (ref($@) ? "$@" : $@));
    }
    for my $bad ('1z0', '', 'a-b') {
        my $label = length($bad) ? $bad : '<empty string>';
        my $r1 = eval { Almanac::Store::rank_between($bad, undef) };
        is(err_kind($@), 'bad_rank', "AC-13: rank_between('$label', undef) with an R1-violating rank dies bad_rank")
            or diag('got: ' . (ref($@) ? "$@" : $@));
    }
}

# =============================================================================
# AC-15 -- grep: Store.pm contains no srand.
# =============================================================================
{
    if (-f $STORE_PM) {
        my @lines = read_all_lines($STORE_PM);
        my @hits;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            push @hits, "$STORE_PM:" . ($i + 1) . ": $l" if $l =~ /\bsrand\b/;
        }
        unless (ok(@hits == 0, 'AC-15: Store.pm contains no srand')) { diag($_) for @hits }
    } else {
        fail('AC-15: Store.pm contains no srand');
    }
}

# =============================================================================
# AC-16/AC-17/AC-18 -- 1000 sequential insert_after($anchor) calls: all
# succeed, all ranks distinct, list order is the reverse of insertion order
# after the anchor, and the longest rank is <= 300 characters.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-16 fixture: store handle opens') or diag("error: $err");
    my $anchor = eval { $store->create(id => 'anchor', fields => { title => 'anchor' }, order => ['title']) } if defined $store;
    ok(defined $anchor, 'AC-16 fixture: the anchor record exists') or diag('error: ' . ($@ // ''));

    my $N = 1000;
    my @inserted_ids;
    my $all_ok = defined($anchor) ? 1 : 0;
    if (defined $anchor) {
        for my $i (1 .. $N) {
            my $r = eval { $store->insert_after('anchor', id => "ins-$i", fields => { title => "t$i" }, order => ['title']) };
            unless (defined $r) { $all_ok = 0; last; }
            push @inserted_ids, $r;
        }
    }
    ok($all_ok && scalar(@inserted_ids) == $N, "AC-16: $N sequential insert_after(anchor) calls all succeed (no die, no timeout)")
        or diag('succeeded so far: ' . scalar(@inserted_ids) . ' of ' . $N . '; error: ' . ($@ // ''));

    if ($all_ok && @inserted_ids == $N) {
        my %by_rank;
        my $dup_ranks = 0;
        for my $r (@inserted_ids) { $dup_ranks++ if $by_rank{$r->{rank}}++ }
        is($dup_ranks, 0, "AC-17: all $N minted ranks are distinct");

        my $list = eval { $store->list() };
        if (ref($list) eq 'ARRAY') {
            my @after_anchor = grep { $_->{id} ne 'anchor' } @$list;
            my @expect_ids = reverse map { "ins-$_" } (1 .. $N);
            is_deeply([map { $_->{id} } @after_anchor], \@expect_ids,
                "AC-17: list()'s id order is exactly the reverse of insertion order after the anchor");
        } else {
            fail("AC-17: list()'s id order is exactly the reverse of insertion order after the anchor");
        }

        my $max_len = 0;
        $max_len = length($_->{rank}) > $max_len ? length($_->{rank}) : $max_len for @inserted_ids;
        diag("AC-18: measured maximum rank length over $N insertions: $max_len characters");
        ok($max_len <= 300, "AC-18: the longest rank is <= 300 characters");
    } else {
        fail("AC-17: all $N minted ranks are distinct");
        fail("AC-17: list()'s id order is exactly the reverse of insertion order after the anchor");
        fail("AC-18: the longest rank is <= 300 characters");
    }
}

# =============================================================================
# AC-19 -- a scripted 12-step insert_first/insert_last/insert_before/
# insert_after sequence produces exactly the intended list order, with all
# ranks distinct and R1-valid.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-19 fixture: store handle opens') or diag("error: $err");

    my @script = (
        ['insert_last',  undef,     's1'],
        ['insert_last',  undef,     's2'],
        ['insert_first', undef,     's0'],
        ['insert_before', 's1',     'sA'],
        ['insert_after',  's1',     'sB'],
        ['insert_last',  undef,     's3'],
        ['insert_first', undef,     'sNeg1'],
        ['insert_before', 's2',     'sC'],
        ['insert_after',  's0',     'sD'],
        ['insert_last',  undef,     's4'],
        ['insert_before', 'sNeg1',  'sFront'],
        ['insert_after',  's4',     'sTail'],
    );
    my @expect_order = qw(sFront sNeg1 s0 sD sA s1 sB sC s2 s3 s4 sTail);

    my $all_ok = defined($store) ? 1 : 0;
    my %minted;
    if (defined $store) {
        for my $step (@script) {
            my ($verb, $ref_id, $id) = @$step;
            my $r = eval {
                if ($verb eq 'insert_first' || $verb eq 'insert_last') {
                    return $store->$verb(id => $id, fields => { title => $id }, order => ['title']);
                }
                return $store->$verb($ref_id, id => $id, fields => { title => $id }, order => ['title']);
            };
            unless (defined $r) { $all_ok = 0; diag("AC-19 step '$verb' for '$id' failed: $@"); last; }
            $minted{$id} = $r->{rank};
        }
    }
    ok($all_ok, 'AC-19: all 12 scripted insert calls succeed');

    if ($all_ok) {
        my $list = eval { $store->list() };
        if (ref($list) eq 'ARRAY') {
            is_deeply([map { $_->{id} } @$list], \@expect_order,
                'AC-19: list() order matches the intended 12-step sequence exactly');
        } else {
            fail('AC-19: list() order matches the intended 12-step sequence exactly');
        }

        my @ranks = values %minted;
        my %seen;
        my $dups = grep { $seen{$_}++ } @ranks;
        is($dups, 0, 'AC-19: every minted rank is distinct');

        my $all_valid = 1;
        for my $rk (@ranks) {
            $all_valid = 0 unless eval { Almanac::Store::rank_valid($rk) };
        }
        ok($all_valid, 'AC-19: every minted rank satisfies R1 (rank_valid)');
    } else {
        fail('AC-19: list() order matches the intended 12-step sequence exactly');
        fail('AC-19: every minted rank is distinct');
        fail('AC-19: every minted rank satisfies R1 (rank_valid)');
    }
}

# =============================================================================
# AC-20 -- grep: Almanac::Lock->acquire is called on the store-lock target
# ('/.store') in exactly two subs, reorder and the recovery sub; no other
# operation references that path.
# =============================================================================
{
    if (-f $STORE_PM) {
        my $src = slurp_raw($STORE_PM) // '';
        my %touching;
        while ($src =~ /^sub\s+(\w+)\s*\{(.*?)^\}/msg) {
            my ($name, $body) = ($1, $2);
            next unless $body =~ /\bacquire\s*\(/;
            next unless $body =~ /\.store\b/;
            $touching{$name} = 1;
        }
        my @names = sort keys %touching;
        is(scalar(@names), 2, 'AC-20: exactly two subs combine Almanac::Lock->acquire with the store-lock (\'/.store\') target')
            or diag('subs found: ' . join(', ', @names));
        ok((grep { /reorder/i } @names), 'AC-20: ...one of them is the reorder sub')
            if @names;
        ok((grep { /recover/i } @names), 'AC-20: ...the other is the recovery sub')
            if @names;
        fail('AC-20: ...one of them is the reorder sub') unless @names;
        fail('AC-20: ...the other is the recovery sub') unless @names;
    } else {
        fail('AC-20: exactly two subs combine Almanac::Lock->acquire with the store-lock (\'/.store\') target');
        fail('AC-20: ...one of them is the reorder sub');
        fail('AC-20: ...the other is the recovery sub');
    }
}

# =============================================================================
# AC-21 -- reorder(\@perm) reorders list to @perm; afterwards the journal
# file does not exist and .store.lock DOES exist (never removed).
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-21 fixture: store handle opens') or diag("error: $err");
    my @ids = qw(r1 r2 r3 r4 r5);
    my $ok_create = defined($store) ? 1 : 0;
    if (defined $store) {
        for my $id (@ids) {
            my $r = eval { $store->insert_last(id => $id, fields => { title => $id }, order => ['title']) };
            $ok_create = 0 unless defined $r;
        }
    }
    ok($ok_create, 'AC-21 fixture: five ranked records exist');

    my @perm = reverse @ids;
    my $reordered = eval { $store->reorder(\@perm) } if defined $store;
    ok(defined $reordered, 'AC-21: reorder(\@perm) succeeds') or diag('error: ' . ($@ // ''));

    my $list = eval { $store->list() } if defined $store;
    if (ref($list) eq 'ARRAY') {
        is_deeply([map { $_->{id} } @$list], \@perm, 'AC-21: list() now returns exactly the requested permutation');
    } else {
        fail('AC-21: list() now returns exactly the requested permutation');
    }

    my $dir = eval { $store->dir } if defined $store;
    if (defined $dir) {
        ok(!-f "$dir/.reorder-journal.json", 'AC-21: the journal file does not exist after a successful reorder');
        ok(-f "$dir/.store.lock", 'AC-21: .store.lock DOES exist afterwards (never removed)');
        # ...and is not held: a fresh non-blocking flock against it succeeds.
        if (open(my $probe, '>>', "$dir/.store.lock")) {
            require Fcntl;
            my $got = flock($probe, Fcntl::LOCK_EX() | Fcntl::LOCK_NB()) ? 1 : 0;
            flock($probe, Fcntl::LOCK_UN()) if $got;
            close $probe;
            ok($got, 'AC-21: .store.lock is not held after reorder completes');
        } else {
            fail('AC-21: .store.lock is not held after reorder completes');
        }
    } else {
        fail('AC-21: the journal file does not exist after a successful reorder');
        fail('AC-21: .store.lock DOES exist afterwards (never removed)');
        fail('AC-21: .store.lock is not held after reorder completes');
    }
}

# =============================================================================
# AC-22 -- reorder with a list that omits an existing id or names an unknown
# one dies reorder_mismatch; every record's rank is unchanged; no journal
# remains.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'AC-22 fixture: store handle opens') or diag("error: $err");
    my @ids = qw(m1 m2 m3);
    my $ok_create = defined($store) ? 1 : 0;
    my %pre_ranks;
    if (defined $store) {
        for my $id (@ids) {
            my $r = eval { $store->insert_last(id => $id, fields => { title => $id }, order => ['title']) };
            $ok_create = 0 unless defined $r;
            $pre_ranks{$id} = defined $r ? $r->{rank} : undef;
        }
    }
    ok($ok_create, 'AC-22 fixture: three ranked records exist');

    for my $bad_perm (['m1', 'm2'], ['m1', 'm2', 'm3', 'unknown-id']) {
        my $r = eval { $store->reorder($bad_perm) } if defined $store;
        is(err_kind($@), 'reorder_mismatch', 'AC-22: reorder(' . join(',', @$bad_perm) . ') dies reorder_mismatch')
            or diag('got: ' . (ref($@) ? "$@" : $@));
    }

    my $ranks_unchanged = defined($store) ? 1 : 0;
    if (defined $store) {
        for my $id (@ids) {
            my $r = eval { $store->read($id) };
            $ranks_unchanged = 0 unless defined $r && defined $pre_ranks{$id} && $r->{rank} eq $pre_ranks{$id};
        }
    }
    ok($ranks_unchanged, 'AC-22: every record\'s rank is unchanged after both refused reorders');

    my $dir = eval { $store->dir } if defined $store;
    ok(defined $dir && !-f "$dir/.reorder-journal.json", 'AC-22: no journal remains after a refused reorder')
        if defined $dir;
    fail('AC-22: no journal remains after a refused reorder') unless defined $dir;
}

# =============================================================================
# FIXBATCH-1 (review CRITICAL-1) -- insert_last lands the new record after
# the true maximum RANKED record, even when an unranked record exists (and
# therefore sits last in list()'s own display order). Before the fix,
# $list->[-1]{rank} was undef whenever any unranked record existed, and
# rank_between(undef,undef) minted a rank near the MIDDLE of the rank
# space instead of after the maximum.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'FIXBATCH-1 fixture: store handle opens') or diag("error: $err");
    my $a1 = eval { $store->insert_last(id => 'fb1-a1', fields => { t => '1' }, order => ['t']) } if defined $store;
    my $a2 = eval { $store->insert_last(id => 'fb1-a2', fields => { t => '2' }, order => ['t']) } if defined $store;
    my $u  = eval { $store->create(id => 'fb1-unranked', fields => { t => 'u' }, order => ['t']) } if defined $store;
    ok(defined($a1) && defined($a2) && defined($u), 'FIXBATCH-1 fixture: two ranked records and one unranked record exist')
        or diag('error: ' . ($@ // ''));

    my $a3 = eval { $store->insert_last(id => 'fb1-a3', fields => { t => '3' }, order => ['t']) } if defined $store;
    ok(defined $a3, 'FIXBATCH-1: insert_last succeeds with an unranked record already present') or diag('error: ' . ($@ // ''));

    my $list = eval { $store->list() } if defined $store;
    if (ref($list) eq 'ARRAY') {
        my @ranked_ids = map { $_->{id} } grep { defined $_->{rank} } @$list;
        is_deeply(\@ranked_ids, ['fb1-a1', 'fb1-a2', 'fb1-a3'],
            'FIXBATCH-1: insert_last lands after the true maximum RANKED record, not mid-list');
    } else {
        fail('FIXBATCH-1: insert_last lands after the true maximum RANKED record, not mid-list');
    }
}

# =============================================================================
# FIXBATCH-2 (review MUST-2 / redteam HIGH-4) -- insert_before and
# insert_after against an UNRANKED reference no longer contradict each
# other: a before-call against a given unranked ref sorts strictly ahead
# of a LATER after-call against the same ref (previously it was the
# reverse: after1 < before1). AC-16/AC-17 above remain the binding oracle
# for the front-stacking convention itself; this block pins the
# before-vs-after consistency specifically.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'FIXBATCH-2 fixture: store handle opens') or diag("error: $err");
    my $anchor = eval { $store->create(id => 'fb2-anchor', fields => { t => 'a' }, order => ['t']) } if defined $store;
    ok(defined $anchor, 'FIXBATCH-2 fixture: an unranked anchor record exists') or diag('error: ' . ($@ // ''));

    my $after1  = eval { $store->insert_after('fb2-anchor',  id => 'fb2-after1',  fields => { t => '1' }, order => ['t']) } if defined $anchor;
    my $before1 = eval { $store->insert_before('fb2-anchor', id => 'fb2-before1', fields => { t => '2' }, order => ['t']) } if defined $anchor;
    ok(defined($after1) && defined($before1), 'FIXBATCH-2: insert_after and insert_before against an unranked ref both succeed')
        or diag('error: ' . ($@ // ''));

    if (defined($after1) && defined($before1)) {
        ok($before1->{rank} lt $after1->{rank},
           'FIXBATCH-2: a later insert_before sorts strictly ahead of an earlier insert_after against the same unranked ref')
            or diag('after1 rank=' . $after1->{rank} . ' before1 rank=' . $before1->{rank});
    } else {
        fail('FIXBATCH-2: a later insert_before sorts strictly ahead of an earlier insert_after against the same unranked ref');
    }
}

# =============================================================================
# FIXBATCH-3 (review MUST-3) -- reorder(\@ids) with a DUPLICATE id (same
# cardinality mismatch, set matches) dies reorder_mismatch instead of
# silently discarding the caller's intent.
# =============================================================================
{
    my ($root, $store, $err) = open_test_store();
    ok(defined $store, 'FIXBATCH-3 fixture: store handle opens') or diag("error: $err");
    my $ok_create = defined($store) ? 1 : 0;
    if (defined $store) {
        for my $id (qw(fb3-p fb3-q)) {
            my $r = eval { $store->insert_last(id => $id, fields => { t => '1' }, order => ['t']) };
            $ok_create = 0 unless defined $r;
        }
    }
    ok($ok_create, 'FIXBATCH-3 fixture: two ranked records exist');

    my $r = eval { $store->reorder(['fb3-p', 'fb3-q', 'fb3-q']) } if defined $store;
    is(err_kind($@), 'reorder_mismatch', 'FIXBATCH-3: reorder([p,q,q]) (a duplicate id) dies reorder_mismatch')
        or diag('got: ' . (ref($@) ? "$@" : $@));

    my $list = eval { $store->list() } if defined $store;
    if (ref($list) eq 'ARRAY') {
        is_deeply([sort map { $_->{id} } @$list], ['fb3-p', 'fb3-q'],
            'FIXBATCH-3: the store still holds exactly the original two records after the refused reorder');
    } else {
        fail('FIXBATCH-3: the store still holds exactly the original two records after the refused reorder');
    }
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
