#!/usr/bin/env perl
# platform: any
# Immutable oracle for the almanac store module's scope-capability surface
# (blueprint almanac-records, package 03-store, Decision 7 as amended): the
# readable/writable pair scope_capability() returns per scope x surface, the
# amendment path (the policy table is a data edit, not a redesign), the
# readable-implies-not-writable invariant, and the single-sub containment of
# the two container marker paths and the ALMANAC_SURFACE env var. CRUD,
# concurrency and ordering ACs live in the sibling files. See
# specs/03-store-spec.md section 2.3.
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
sub err_kind  { my ($e) = @_; return (ref($e) =~ /::Error$/) ? $e->{kind}  : undef }
sub err_field { my ($e, $f) = @_; return (ref($e) =~ /::Error$/) ? $e->{$f} : undef }
sub norm_path {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}
use Cwd ();

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
my $HAVE_STORE = eval { require Almanac::Store; 1 };
ok($HAVE_STORE, 'Almanac::Store requires cleanly') or diag("load error: $@");

# =============================================================================
# AC-30 (DC9) -- scope_capability returns readable/writable = 1/1 for
# project on both surfaces, 1/1 for global on host, and 0/0 for global on
# container with reason: vault_not_mounted.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;

    my @cases = (
        ['project', 'host',      1, 1, 'ok'],
        ['project', 'container', 1, 1, 'ok'],
        ['global',  'host',      1, 1, 'ok'],
        ['global',  'container', 0, 0, 'vault_not_mounted'],
    );
    for my $c (@cases) {
        my ($scope, $surface, $exp_r, $exp_w, $exp_reason) = @$c;
        my $cap = eval { Almanac::Store::scope_capability($scope, surface => $surface, root => $root, home => $home) };
        ok(defined $cap, "AC-30: scope_capability($scope, $surface) returns a hashref") or diag('error: ' . ($@ // ''));
        if (defined $cap) {
            is($cap->{readable}, $exp_r, "AC-30: $scope/$surface readable == $exp_r");
            is($cap->{writable}, $exp_w, "AC-30: $scope/$surface writable == $exp_w");
            is($cap->{reason}, $exp_reason, "AC-30: $scope/$surface reason == $exp_reason");
        } else {
            fail("AC-30: $scope/$surface readable == $exp_r");
            fail("AC-30: $scope/$surface writable == $exp_w");
            fail("AC-30: $scope/$surface reason == $exp_reason");
        }
    }
}

# =============================================================================
# AC-32 (DC9) -- writable can never be 1 while readable is 0: asserted over
# all four policy cells plus a deliberately inconsistent localized cell.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;

    for my $pair ([qw(project host)], [qw(project container)], [qw(global host)], [qw(global container)]) {
        my ($scope, $surface) = @$pair;
        my $cap = eval { Almanac::Store::scope_capability($scope, surface => $surface, root => $root, home => $home) };
        my $ok_invariant = (ref($cap) eq 'HASH') && (!$cap->{readable} ? !$cap->{writable} : 1);
        ok($ok_invariant, "AC-32: $scope/$surface never has writable=1 while readable=0")
            or diag('cap: ' . (ref($cap) eq 'HASH' ? "readable=$cap->{readable} writable=$cap->{writable}" : '(undef)'));
    }

    # Deliberately inconsistent localized cell: the table itself claims
    # readable=>0, writable=>1. The invariant must still hold on the RETURN
    # VALUE (forced to 0), per S2.3's "writable is forced to 0 whenever
    # readable is 0 (an invariant, asserted)".
    if ($HAVE_STORE) {
        local $Almanac::Store::SCOPE_POLICY{container}{global} = { readable => 0, writable => 1, reason => 'deliberately-inconsistent' };
        my $cap = eval { Almanac::Store::scope_capability('global', surface => 'container', home => $home) };
        ok((ref($cap) eq 'HASH') && !$cap->{readable} && !$cap->{writable},
           'AC-32: a deliberately inconsistent table cell (readable=>0,writable=>1) still returns writable=0')
            or diag('cap: ' . (ref($cap) eq 'HASH' ? "readable=$cap->{readable} writable=$cap->{writable}" : '(undef), error: ' . ($@ // '')));
    } else {
        fail('AC-32: a deliberately inconsistent table cell (readable=>0,writable=>1) still returns writable=0');
    }
}

# =============================================================================
# AC-31 (DC9) -- with %SCOPE_POLICY's container.global localized to
# readable=>1, writable=>0: open+read+list succeed and every mutation dies
# scope_unavailable with readable: 1, writable: 0. No product-code edit is
# needed to reach this branch.
#
# NOTE: the spec text says "all seven mutations", but S2.4/S2.7/B5 name
# EIGHT mutation verbs (create, update, delete, insert_first, insert_last,
# insert_before, insert_after, reorder). Treated as a spec wording defect
# (reported back, per this package's instructions) and tested against the
# more specific and internally-consistent enumeration in B5/S2.7 -- all
# eight are exercised below, not seven.
# =============================================================================
{
    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;

    my $host_store = eval { Almanac::Store->open(scope => 'global', type => 'todo', home => $home, surface => 'host') };
    ok(defined $host_store, 'AC-31 fixture: a host-surface global store opens (writable)') or diag('error: ' . ($@ // ''));
    my $seed = eval { $host_store->create(id => 'seed', fields => { title => 'orig' }, order => ['title']) } if defined $host_store;
    ok(defined $seed, 'AC-31 fixture: a seed record exists in the global store') or diag('error: ' . ($@ // ''));

    # FIXBATCH (redteam HIGH-3 / review SHOULD-6): stage a pending-reorder
    # journal BEFORE opening the read-only-scoped handle, so the
    # read-only list() below is actually exercised against a store that
    # HAS recovery work to do -- AC-31 previously passed vacuously here
    # because its fixture carried no journal, so a list()/recover() that
    # attempted a write was never actually reached.
    my $dir_for_journal = eval { $host_store->dir } if defined $host_store;
    my $journal_path    = defined $dir_for_journal ? "$dir_for_journal/.reorder-journal.json" : undef;
    my $store_lock_path = defined $dir_for_journal ? "$dir_for_journal/.store.lock" : undef;
    if (defined $journal_path) {
        require JSON::PP;
        open(my $jfh, '>:raw', $journal_path) or die "fixture: cannot write $journal_path: $!";
        print {$jfh} JSON::PP->new->canonical->encode({
            version => 1, writer => 'fixture', started_at => time(),
            entries => { seed => { prev_rank => undef, next_rank => undef } },
        });
        close $jfh;
    }
    ok(defined $journal_path && -f $journal_path, 'AC-31 fixture: a pending-reorder journal is staged before the read-only open()');
    ok(defined $store_lock_path && !-f $store_lock_path, 'AC-31 fixture: no .store.lock exists yet');

    # Referencing a fully-qualified package global (even one belonging to a
    # module that has not been `require`d) is always safe in Perl -- it
    # autovivifies an empty symbol-table entry rather than dying -- so this
    # runs unconditionally rather than being skipped when the module is
    # missing; every assertion below still fails for the right reason
    # (Almanac::Store->open has no such method) instead of being marked skip.
    local $Almanac::Store::SCOPE_POLICY{container}{global} = { readable => 1, writable => 0, reason => 'vault_read_only' };

    my $c_store = eval { Almanac::Store->open(scope => 'global', type => 'todo', home => $home, surface => 'container') };
    ok(defined $c_store, 'AC-31: open() succeeds under the localized read-only-global policy') or diag('error: ' . ($@ // ''));

    my $baseline = eval { $c_store->read('seed') } if defined $c_store;
    ok(defined $baseline, 'AC-31: read() succeeds under the localized policy') or diag('error: ' . ($@ // ''));
    my $list_ok = eval { $c_store->list(); 1 } if defined $c_store;
    ok($list_ok, 'AC-31: list() succeeds under the localized policy') or diag('error: ' . ($@ // ''));

    # FIXBATCH (redteam HIGH-3 / review SHOULD-6): list() on this
    # read-only-scoped handle must not have attempted recovery -- the
    # journal staged above is still exactly as it was, and no .store.lock
    # sidecar was ever created, even though a real journal was present.
    ok(defined($journal_path) && -f $journal_path,
       'AC-31: list() under the read-only policy did NOT consume/rewrite the pending journal');
    ok(defined($store_lock_path) && !-f $store_lock_path,
       'AC-31: list() under the read-only policy never created .store.lock (no write was attempted)');

    # And recover() called directly is likewise refused outright rather
    # than attempting (and presumably failing) an actual write.
    my $recover_rv = eval { $c_store->recover() } if defined $c_store;
    is($recover_rv, 0, 'AC-31: recover() on the read-only-scoped handle returns 0 rather than attempting a write')
        or diag('error: ' . ($@ // ''));
    ok(defined($journal_path) && -f $journal_path,
       'AC-31: ...and the journal is still untouched afterward');

    my @mutations = (
        ['create',        sub { $c_store->create(id => 'ac31-new', fields => { a => '1' }, order => ['a']) }],
        ['update',        sub { $c_store->update('seed', expect => $baseline, set => { title => 'changed' }) }],
        ['delete',        sub { $c_store->delete('seed', expect => $baseline) }],
        ['insert_first',  sub { $c_store->insert_first(id => 'ac31-if', fields => { a => '1' }, order => ['a']) }],
        ['insert_last',   sub { $c_store->insert_last(id => 'ac31-il', fields => { a => '1' }, order => ['a']) }],
        ['insert_before', sub { $c_store->insert_before('seed', id => 'ac31-ib', fields => { a => '1' }, order => ['a']) }],
        ['insert_after',  sub { $c_store->insert_after('seed', id => 'ac31-ia', fields => { a => '1' }, order => ['a']) }],
        ['reorder',       sub { $c_store->reorder(['seed']) }],
    );
    for my $pair (@mutations) {
        my ($name, $code) = @$pair;
        eval { $code->() } if defined $c_store;
        is(err_kind($@), 'scope_unavailable', "AC-31: $name dies scope_unavailable under the localized read-only-global policy")
            or diag('got: ' . (ref($@) ? "$@" : $@));
        is(err_field($@, 'readable'), 1, "AC-31: $name's error carries readable: 1");
        is(err_field($@, 'writable'), 0, "AC-31: $name's error carries writable: 0");
    }
}

# =============================================================================
# AC-33 (DC9) -- grep: /run/.containerenv, /.dockerenv and ALMANAC_SURFACE
# each appear in Store.pm only inside surface(); no other sub and no call
# site tests for a container.
# =============================================================================
{
    if (-f $STORE_PM) {
        my $src = slurp_raw($STORE_PM) // '';
        my ($surface_body) = $src =~ /^sub\s+surface\s*\{(.*?)^\}/ms;
        $surface_body = '' unless defined $surface_body;

        my $containerenv = '/run/.containerenv';
        my $dockerenv    = '/.dockerenv';
        my $env_var      = 'ALMANAC_SURFACE';

        for my $marker ($containerenv, $dockerenv, $env_var) {
            my $q = quotemeta $marker;
            my @in_body = ($surface_body =~ /$q/g);
            ok(scalar(@in_body) >= 1, "AC-33: '$marker' appears at least once inside sub surface()");

            (my $outside = $src) =~ s/^sub\s+surface\s*\{.*?^\}//ms;
            my @outside_hits = ($outside =~ /$q/g);
            is(scalar(@outside_hits), 0, "AC-33: '$marker' never appears anywhere OUTSIDE sub surface()")
                or diag("found " . scalar(@outside_hits) . " occurrence(s) outside surface()");
        }
    } else {
        fail("AC-33: '$_' appears at least once inside sub surface()") for ('/run/.containerenv', '/.dockerenv', 'ALMANAC_SURFACE');
        fail("AC-33: '$_' never appears anywhere OUTSIDE sub surface()") for ('/run/.containerenv', '/.dockerenv', 'ALMANAC_SURFACE');
    }
}

# =============================================================================
# AC-34 (DC9) -- open(scope=>global, surface=>container) dies
# scope_unavailable with exit_code == 2, and a real child process surfacing
# it exits 2 -- it does not return an empty store.
# =============================================================================
{
    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;
    my $store = eval { Almanac::Store->open(scope => 'global', type => 'todo', home => $home, surface => 'container') };
    ok(!defined $store, 'AC-34: open(global, container) does not return a store handle at all');
    is(err_kind($@), 'scope_unavailable', 'AC-34: ...it dies scope_unavailable') or diag('got: ' . (ref($@) ? "$@" : $@));
    is(err_field($@, 'exit_code'), 2, 'AC-34: ...with exit_code == 2');

    my $WORKDIR = tempdir(CLEANUP => 1); $WORKDIR =~ s{\\}{/}g;
    my $child = "$WORKDIR/ac34-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'AC34CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($scripts_dir, $home) = @ARGV;
local @INC = ($scripts_dir, @INC);
eval { require Almanac::Store; require Almanac::Record; 1 } or do {
    print "MODULE-LOAD-FAILED: $@\n";
    exit 3;
};
my $store = eval { Almanac::Store->open(scope => 'global', type => 'todo', home => $home, surface => 'container') };
if (my $err = $@) {
    Almanac::Record::fatal($err);
}
print "UNEXPECTED-SUCCESS: got a store handle\n";
exit 0;
AC34CHILD
    close $fh;
    my $out = `perl "$child" "$S" "$home" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 2, 'AC-34: end-to-end -- a real child process surfacing scope_unavailable via fatal() exits 2') or diag("output: $out");
    like($out, qr/scope_unavailable/, 'AC-34: ...and names scope_unavailable, not an empty store');
}

# =============================================================================
# AC-35 (DC9) -- store paths match Decision 2 exactly for both scopes, and
# the global root honours ALMANAC_HOME > HOME > USERPROFILE.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    my $store_p = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root) };
    my $expect_p = norm_path($root) . '/.ccpraxis-local-data/almanac/note';
    is(eval { $store_p->dir }, $expect_p, 'AC-35: project scope dir matches Decision 2 exactly') if defined $store_p;
    fail('AC-35: project scope dir matches Decision 2 exactly') unless defined $store_p;

    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;
    my $store_g = eval { Almanac::Store->open(scope => 'global', type => 'note', home => $home) };
    my $expect_g = norm_path($home) . '/.claude/claude-code-vault/almanac/note';
    is(eval { $store_g->dir }, $expect_g, 'AC-35: global scope dir matches Decision 2 exactly') if defined $store_g;
    fail('AC-35: global scope dir matches Decision 2 exactly') unless defined $store_g;

    # Precedence: ALMANAC_HOME > HOME > USERPROFILE, via three real child
    # processes so the environment precedence is exercised exactly as a
    # caller would see it, never mocked in-process.
    my $child = "$root/../ac35-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'AC35CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($scripts_dir) = @ARGV;
local @INC = ($scripts_dir, @INC);
require Almanac::Store;
my $store = eval { Almanac::Store->open(scope => 'global', type => 'note') };
print(defined $store ? $store->dir . "\n" : "ERROR: $@\n");
AC35CHILD
    close $fh;

    my $almanac_home = tempdir(CLEANUP => 1); $almanac_home =~ s{\\}{/}g;
    my $home_env      = tempdir(CLEANUP => 1); $home_env      =~ s{\\}{/}g;
    my $userprofile   = tempdir(CLEANUP => 1); $userprofile   =~ s{\\}{/}g;

    my $out1 = `ALMANAC_HOME="$almanac_home" HOME="$home_env" USERPROFILE="$userprofile" perl "$child" "$S" 2>&1`;
    chomp $out1;
    my $expect1 = norm_path($almanac_home) . '/.claude/claude-code-vault/almanac/note';
    is($out1, $expect1, 'AC-35: ALMANAC_HOME wins over HOME and USERPROFILE when all three are set');

    delete local $ENV{ALMANAC_HOME};
    my $out2 = `HOME="$home_env" USERPROFILE="$userprofile" perl "$child" "$S" 2>&1`;
    chomp $out2;
    my $expect2 = norm_path($home_env) . '/.claude/claude-code-vault/almanac/note';
    is($out2, $expect2, 'AC-35: HOME wins over USERPROFILE when ALMANAC_HOME is unset');
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
