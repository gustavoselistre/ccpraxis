#!/usr/bin/env perl
# platform: any
# Immutable oracle for the CRUD surface of the almanac store module (blueprint
# almanac-records, package 03-store): open()'s directory/creation contract,
# ids/reserved-field grammar, the error shape and its machine block, the
# not-found-exits-2 path, project-root resolution from a subdirectory, the
# ignore-list a listing must honour, and the module-shape rules (imports, no
# exit/alarm, no Almanac::Record::write_file call). Concurrency and ordering
# ACs live in the sibling concurrency/ordering files; scope-capability ACs
# live in the sibling scope file. See specs/03-store-spec.md.
#
# STEP-2 GATE ADDITION (binding, not in the spec text): the store deliberately
# does not call Almanac::Record::write_file and owns its own temp-write/rename
# so DC7 has a kill point between them (spec S2.9). The gate's condition for
# accepting that duplication is a pinned equivalence: for the same record
# shape, the bytes this module actually writes to disk must be byte-identical
# to what Almanac::Record::write_file would write. See the dedicated block
# below -- it is an acceptance criterion, not a note.
#
# HOUSE PATTERN for a not-yet-built module: every direct call into the store
# module is wrapped in eval{} so "Undefined subroutine"/"Can't locate" is a
# caught, reported failure for THIS assertion rather than an abort of the
# whole file -- every assertion below is expected to fail for exactly that
# reason right now, not for a fixture defect of this file's own making.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Spec ();
use Cwd ();
use Digest::SHA qw(sha256_hex);

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

sub norm_path {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
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

# err_kind/err_field: $@ after `eval { $code->() }` is a blessed
# Almanac::Store::Error on a sanctioned die, or a plain string (e.g.
# "Undefined subroutine") when the module/sub does not exist at all. Every
# assertion below must survive the latter without dying itself.
sub err_kind  { my ($e) = @_; return (ref($e) =~ /::Error$/) ? $e->{kind}  : undef }
sub err_field { my ($e, $f) = @_; return (ref($e) =~ /::Error$/) ? $e->{$f} : undef }

# machine_block_field($message, $key) -> $value | undef
# Exactly the grammar spec S2.5 hands the test-writer: never match prose.
sub machine_block_field {
    my ($msg, $key) = @_;
    return undef unless defined $msg;
    return $1 if $msg =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub has_almanac_error_block {
    my ($msg) = @_;
    return 0 unless defined $msg;
    return $msg =~ /^almanac-error:$/m ? 1 : 0;
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

ok(-f $STORE_PM, 'Almanac::Store module file exists at plugins/almanac/scripts/Almanac/Store.pm')
    or diag('Almanac/Store.pm is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

my $LOAD_ERR;
eval { require Almanac::Store; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::Store requires cleanly')
    or diag("load error: $LOAD_ERR");

# =============================================================================
# MR -- module-shape rules, by grep. Run whether or not the module loaded, so
# a compile-breaking edit is still reported precisely.
# =============================================================================
{
    if (-f $STORE_PM) {
        my @lines = read_all_lines($STORE_PM);
        my $src = join('', @lines);

        my (@exit_hits, @alarm_hits, @stderr_hits, @warn_hits, @writefile_hits);
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            push @exit_hits,      "$STORE_PM:" . ($i + 1) . ": $line" if $line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/;
            push @alarm_hits,     "$STORE_PM:" . ($i + 1) . ": $line" if $line =~ /\balarm\s*\(/;
            push @stderr_hits,    "$STORE_PM:" . ($i + 1) . ": $line" if $line =~ /print\s+STDERR/;
            push @warn_hits,      "$STORE_PM:" . ($i + 1) . ": $line" if $line =~ /\bwarn\s*(\(|["'])/;
            push @writefile_hits, "$STORE_PM:" . ($i + 1) . ": $line" if $line =~ /Almanac::Record::write_file/;
        }
        unless (ok(@exit_hits == 0, 'AC-46: Store.pm contains no exit()')) { diag($_) for @exit_hits }
        unless (ok(@alarm_hits == 0, 'AC-46: Store.pm contains no alarm()')) { diag($_) for @alarm_hits }
        unless (ok(@stderr_hits == 0, 'AC-46: Store.pm contains no print STDERR')) { diag($_) for @stderr_hits }
        unless (ok(@warn_hits == 0, 'AC-46: Store.pm contains no warn')) { diag($_) for @warn_hits }
        unless (ok(@writefile_hits == 0, 'AC-46: Store.pm never calls Almanac::Record::write_file')) { diag($_) for @writefile_hits }

        # AC-47 -- import allowlist.
        my @uses = grep { /^\s*(use|require)\s+/ } @lines;
        my @allowed = (
            qr/^\s*use\s+strict\b/,        qr/^\s*use\s+warnings\b/,
            qr/^\s*use\s+Cwd\b/,           qr/^\s*use\s+File::Path\b/,
            qr/^\s*use\s+File::Spec\b/,    qr/^\s*use\s+Digest::SHA\b/,
            qr/^\s*use\s+JSON::PP\b/,      qr/^\s*use\s+Time::HiRes\b/,
            qr/^\s*use\s+Sys::Hostname\b/, qr/^\s*use\s+Almanac::Lock\b/,
            qr/^\s*use\s+Almanac::Record\b/, qr/^\s*use\s+overload\b/,
        );
        my @bad_imports = grep { my $l = $_; !grep { $l =~ $_ } @allowed } @uses;
        unless (ok(@bad_imports == 0, 'AC-47: Store.pm imports only from the S2.0 allowlist')) {
            diag($_) for @bad_imports;
        }
        my @forbidden = grep { /butler|BpResumption|use lib|FindBin|BpContinuityLease/ } @uses;
        ok(@forbidden == 0, 'AC-47: Store.pm never mentions another plugin (butler/BpResumption/BpContinuityLease/use lib/FindBin)');
    } else {
        fail("AC-46: $_") for ('no exit()', 'no alarm()', 'no print STDERR', 'no warn', 'never calls Almanac::Record::write_file');
        fail('AC-47: Store.pm imports only from the S2.0 allowlist');
        fail('AC-47: Store.pm never mentions another plugin');
    }
}

# =============================================================================
# `checks:` -- AC-48: perl -c on Store.pm with -I plugins/almanac/scripts and
# no other -I.
# =============================================================================
{
    my $cmd = qq{perl -I "$S" -c "$STORE_PM" 2>&1};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC-48: perl -c Store.pm succeeds with -I plugins/almanac/scripts and no other -I')
        or diag("output: $out");
}

# =============================================================================
# Common fixture: one project-scope store, root overridden to a tempdir (no
# cwd walk involved for any block below except the dedicated DC8 block).
# =============================================================================
my $ROOT = tempdir(CLEANUP => 1);
$ROOT =~ s{\\}{/}g;
my $EXPECT_DIR = norm_path($ROOT) . '/.ccpraxis-local-data/almanac/note';

sub open_store {
    my (%opt) = @_;
    return eval { Almanac::Store->open(scope => 'project', type => 'note', root => $ROOT, %opt) };
}

# =============================================================================
# B1 support -- open() dir shape, no directory created.
# =============================================================================
{
    my $store = open_store();
    my $err = $@;
    ok(defined $store, 'B1: open(project, root=>tmp) succeeds') or diag("error: $err");
    if (defined $store) {
        is(eval { $store->dir }, $EXPECT_DIR, 'B1: dir is <root>/.ccpraxis-local-data/almanac/<type>, canonicalized, no trailing slash');
        ok(!-d $EXPECT_DIR, 'B1: open() creates no directory');
    } else {
        fail('B1: dir is <root>/.ccpraxis-local-data/almanac/<type>, canonicalized, no trailing slash');
        fail('B1: open() creates no directory');
    }
}

# =============================================================================
# AC-36 -- create/read round-trip: pipes, angle brackets, a `---` line; rev
# equals sha256_hex of the file's bytes.
# =============================================================================
my ($store, $created_ac36, $ac36_path);
{
    $store = open_store();
    ok(defined $store, 'AC-36 fixture: store handle opens') or diag("error: $@");

    my $body = join("\n", 'a | b | c', '<tag attr="x">', '---', 'plain line') . "\n";
    $created_ac36 = eval { $store->create(id => 'rec-ac36', fields => { title => 'AC36' }, order => ['title'], body => $body) };
    my $create_err = $@;
    ok(defined $created_ac36, 'AC-36: create() succeeds with a body containing pipes/angle-brackets/---') or diag("error: $create_err");

    if (defined $created_ac36) {
        $ac36_path = eval { $created_ac36->{path} };
        ok(defined $ac36_path && -f $ac36_path, 'AC-36: the record file exists on disk');
        my $bytes = defined $ac36_path ? slurp_raw($ac36_path) : undef;
        is($created_ac36->{rev}, (defined $bytes ? sha256_hex($bytes) : undef),
           'AC-36: rev equals sha256_hex of the on-disk bytes');

        my $reread = eval { $store->read('rec-ac36') };
        ok(defined $reread, 'AC-36: read() round-trips the just-created record') or diag("error: $@");
        is(eval { $reread->{body} }, $body, 'AC-36: body comes back byte-identical (decoded characters)');
    } else {
        fail('AC-36: the record file exists on disk');
        fail('AC-36: rev equals sha256_hex of the on-disk bytes');
        fail('AC-36: read() round-trips the just-created record');
        fail('AC-36: body comes back byte-identical (decoded characters)');
    }
}

# =============================================================================
# AC-37 -- field order on disk: id, rank, writer, then caller fields; a no-op
# update (restamping writer only) leaves every other byte identical.
# =============================================================================
{
    my $rec = eval { $store->create(id => 'rec-ac37', fields => { zeta => '1', alpha => '2' }, order => ['zeta', 'alpha'], rank => 'V', body => 'x') };
    ok(defined $rec, 'AC-37 fixture: create() with a rank and two caller fields succeeds') or diag("error: $@");
    if (defined $rec) {
        my $path = $rec->{path};
        my @lines = read_all_lines($path);
        # THE LOOP USED TO BREAK BEFORE IT COLLECTED ANYTHING. Fixed 2026-09-17
        # under a narrow driver authorisation. It was:
        #
        #     for my $l (@lines) {
        #         last if $l =~ /\A---/;                          # <- fires on line 1
        #         push @keys, $1 if $l =~ /\A([A-Za-z0-9_]+):/;
        #     }
        #
        # The FIRST line of a record is the opening `---` delimiter, so the
        # `last` fired immediately and @keys was ALWAYS empty -- for any file,
        # correct or not. The assertion below could only ever fail, and it told
        # you nothing about key order when it did.
        #
        # Now: skip the opening delimiter, stop at the CLOSING one. The state
        # flag is what distinguishes them; a bare /\A---/ cannot.
        my @keys;
        my $in_frontmatter = 0;
        for my $l (@lines) {
            if ($l =~ /\A---/) {
                last if $in_frontmatter;    # closing delimiter: frontmatter done
                $in_frontmatter = 1;        # opening delimiter: start collecting
                next;
            }
            push @keys, $1 if $l =~ /\A([A-Za-z0-9_]+):/;
        }
        is_deeply(\@keys, ['id', 'rank', 'writer', 'zeta', 'alpha'],
            'AC-37: on-disk key order is id, rank, writer, then caller fields in the record\'s own order');

        my $before = slurp_raw($path);
        my $updated = eval { $store->update('rec-ac37', expect => $rec, set => {}) };
        ok(defined $updated, 'AC-37: a no-op update (set=>{}) succeeds') or diag("error: $@");
        my $after = slurp_raw($path);
        # THIS ASSERTION CONTRADICTED THE SPEC IT WAS WRITTEN FROM. Fixed
        # 2026-09-17 under a narrow driver authorisation. It read:
        #
        #     isnt($before, $after, 'the file bytes DID change (writer was restamped)')
        #
        # which assumes writer_id() differs between the create() above and this
        # same-process update(). Spec section 2.6 says the opposite in as many
        # words: writer_id() is "computed once at module load" and is "stable
        # within a process". So a no-op update from ONE process is necessarily
        # byte-identical, and the old assertion could only pass if the module
        # broke its own stability guarantee.
        #
        # Inverted to assert what the spec actually promises. The neighbouring
        # assertion below -- every byte other than the writer line is unchanged
        # -- keeps its meaning either way, and together they pin both halves:
        # nothing moves, INCLUDING the writer, within a process.
        is($before, $after,
           'AC-37: a same-process no-op update is byte-identical -- writer_id() is stable within a '
         . 'process (spec 2.6), so there is nothing to restamp')
            if defined $before && defined $after;
        if (defined $before && defined $after) {
            # Compare everything except the writer line: strip the writer line
            # from both and require the remainder to be byte-identical.
            (my $b2 = $before) =~ s/^writer:.*$//m;
            (my $a2 = $after)  =~ s/^writer:.*$//m;
            is($a2, $b2, 'AC-37: every byte other than the writer line is unchanged by a no-op update');
        } else {
            fail('AC-37: every byte other than the writer line is unchanged by a no-op update');
        }
    } else {
        fail('AC-37: on-disk key order is id, rank, writer, then caller fields in the record\'s own order');
        fail('AC-37: a no-op update (set=>{}) succeeds');
        fail('AC-37: every byte other than the writer line is unchanged by a no-op update');
    }
}

# =============================================================================
# AC-38 -- bad_id fires BEFORE any file, directory or lock file is created.
# =============================================================================
{
    my $root38 = tempdir(CLEANUP => 1);
    $root38 =~ s{\\}{/}g;
    my $store38 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root38) };
    ok(defined $store38, 'AC-38 fixture: a fresh store handle opens') or diag("error: $@");

    my @bad_ids = ('a/b', '..', '.hidden', '', ('x' x 200), "a\\b");
    for my $bad (@bad_ids) {
        my $label = length($bad) > 20 ? '<200-char id>' : (length($bad) ? $bad : '<empty string>');
        my $rec = eval { $store38->create(id => $bad, fields => { t => '1' }, order => ['t']) } if defined $store38;
        my $err = $@;
        is(err_kind($err), 'bad_id', "AC-38: create(id => '$label') dies bad_id") or diag("got: " . (ref($err) ? "$err" : $err));
    }
    my $dir38 = norm_path($root38) . '/.ccpraxis-local-data/almanac/note';
    ok(!-d $dir38, 'AC-38: no directory was created by any of the bad_id attempts');
}

# =============================================================================
# AC-39 -- reserved_field fires for set/unset of id, rank, writer; nothing is
# written.
# =============================================================================
{
    my $rec = eval { $store->create(id => 'rec-ac39', fields => { t => '1' }, order => ['t']) };
    ok(defined $rec, 'AC-39 fixture: create() succeeds') or diag("error: $@");
    if (defined $rec) {
        my $before = slurp_raw($rec->{path});
        for my $field (qw(id rank writer)) {
            my $r1 = eval { $store->update('rec-ac39', expect => $rec, set => { $field => 'x' }) };
            is(err_kind($@), 'reserved_field', "AC-39: update(set => {$field => ...}) dies reserved_field")
                or diag("got: " . (ref($@) ? "$@" : $@));
            my $r2 = eval { $store->update('rec-ac39', expect => $rec, unset => [$field]) };
            is(err_kind($@), 'reserved_field', "AC-39: update(unset => ['$field']) dies reserved_field")
                or diag("got: " . (ref($@) ? "$@" : $@));
        }
        my $after = slurp_raw($rec->{path});
        is($after, $before, 'AC-39: none of the reserved-field attempts wrote anything');
    } else {
        fail("AC-39: update(set => {$_ => ...}) dies reserved_field") for qw(id rank writer);
        fail("AC-39: update(unset => ['$_']) dies reserved_field") for qw(id rank writer);
        fail('AC-39: none of the reserved-field attempts wrote anything');
    }
}

# =============================================================================
# AC-40 -- exists fires on a duplicate create; the existing file is
# byte-unchanged.
# =============================================================================
{
    my $rec = eval { $store->create(id => 'rec-ac40', fields => { t => 'orig' }, order => ['t']) };
    ok(defined $rec, 'AC-40 fixture: create() succeeds') or diag("error: $@");
    if (defined $rec) {
        my $before = slurp_raw($rec->{path});
        my $dup = eval { $store->create(id => 'rec-ac40', fields => { t => 'new' }, order => ['t']) };
        is(err_kind($@), 'exists', 'AC-40: a duplicate create() dies exists') or diag("got: " . (ref($@) ? "$@" : $@));
        my $after = slurp_raw($rec->{path});
        is($after, $before, 'AC-40: the existing file is byte-unchanged after the refused duplicate create');
    } else {
        fail('AC-40: a duplicate create() dies exists');
        fail('AC-40: the existing file is byte-unchanged after the refused duplicate create');
    }
}

# =============================================================================
# AC-41 -- id_mismatch when the frontmatter id disagrees with the filename.
# =============================================================================
{
    my $rec = eval { $store->create(id => 'rec-ac41', fields => { t => '1' }, order => ['t']) };
    ok(defined $rec, 'AC-41 fixture: create() succeeds') or diag("error: $@");
    if (defined $rec) {
        my $path = $rec->{path};
        my $bytes = slurp_raw($path);
        (my $tampered = $bytes) =~ s/^id: rec-ac41$/id: someone-else/m;
        open(my $fh, '>:raw', $path) or die "fixture: cannot rewrite $path: $!";
        print {$fh} $tampered;
        close $fh;
        my $reread = eval { $store->read('rec-ac41') };
        is(err_kind($@), 'id_mismatch', 'AC-41: read() dies id_mismatch when frontmatter id disagrees with filename')
            or diag("got: " . (ref($@) ? "$@" : $@));
        is(err_field($@, 'found'), 'someone-else', 'AC-41: the block carries found: <the frontmatter id>');
    } else {
        fail('AC-41: read() dies id_mismatch when frontmatter id disagrees with filename');
        fail('AC-41: the block carries found: <the frontmatter id>');
    }
}

# =============================================================================
# AC-42 -- malformed from read() and list() carries `problems` as a
# structured array (arrayref of hashrefs with kind/line/message), never a
# string.
# =============================================================================
{
    my $root42 = tempdir(CLEANUP => 1);
    $root42 =~ s{\\}{/}g;
    my $store42 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root42) };
    ok(defined $store42, 'AC-42 fixture: a fresh store handle opens') or diag("error: $@");
    my $good = eval { $store42->create(id => 'good', fields => { t => '1' }, order => ['t']) } if defined $store42;
    ok(defined $good, 'AC-42 fixture: one healthy record is created') or diag("error: $@");
    my $dir42 = eval { $store42->dir } if defined $store42;
    if (defined $dir42) {
        open(my $fh, '>', "$dir42/bad.md") or die "fixture: cannot write $dir42/bad.md: $!";
        print {$fh} "not frontmatter at all\n";
        close $fh;
    }

    my $r1 = eval { $store42->read('bad') } if defined $store42;
    is(err_kind($@), 'malformed', 'AC-42: read() on the malformed file dies malformed') or diag("got: " . (ref($@) ? "$@" : $@));
    my $problems1 = err_field($@, 'problems');
    ok(ref($problems1) eq 'ARRAY' && @$problems1 && ref($problems1->[0]) eq 'HASH'
       && exists $problems1->[0]{kind} && exists $problems1->[0]{line} && exists $problems1->[0]{message},
       'AC-42: read()\'s problems is an arrayref of hashrefs with kind/line/message');

    my $r2 = eval { $store42->list() } if defined $store42;
    is(err_kind($@), 'malformed', 'AC-42: list() on a store with one malformed record dies malformed (B19: no healthy subset)')
        or diag("got: " . (ref($@) ? "$@" : $@));
    my $problems2 = err_field($@, 'problems');
    ok(ref($problems2) eq 'ARRAY' && @$problems2 && ref($problems2->[0]) eq 'HASH',
       'AC-42: list()\'s problems is likewise a structured array');
}

# =============================================================================
# AC-43 / B18 -- ids()/list() ignore every sidecar and non-record file.
# =============================================================================
{
    my $root43 = tempdir(CLEANUP => 1);
    $root43 =~ s{\\}{/}g;
    my $store43 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root43) };
    ok(defined $store43, 'AC-43 fixture: a fresh store handle opens') or diag("error: $@");
    my $rec43 = eval { $store43->create(id => 'keep-me', fields => { t => '1' }, order => ['t']) } if defined $store43;
    ok(defined $rec43, 'AC-43 fixture: one real record is created') or diag("error: $@");
    my $dir43 = eval { $store43->dir } if defined $store43;
    if (defined $dir43) {
        for my $extra ('.store.lock', '.store.lock.holder', 'keep-me.md.lock', 'keep-me.md.lock.holder',
                        'keep-me.md.tmp.9-abcd', '.reorder-journal.json', 'notes.txt') {
            open(my $fh, '>', "$dir43/$extra") or die "fixture: cannot write $dir43/$extra: $!";
            print {$fh} "irrelevant\n";
            close $fh;
        }
    }

    my $ids43 = eval { $store43->ids() } if defined $store43;
    is_deeply($ids43, ['keep-me'], 'AC-43: ids() returns only the <id>.md record, ignoring every sidecar/journal/stray file')
        or diag('got: ' . (defined $ids43 ? join(',', @$ids43) : 'undef') . " / error: " . (ref($@) ? "$@" : $@));

    my $list43 = eval { $store43->list() } if defined $store43;
    if (ref($list43) eq 'ARRAY') {
        is(scalar(@$list43), 1, 'AC-43: list() likewise returns exactly one record');
        is($list43->[0]{id}, 'keep-me', 'AC-43: ...and it is the real record');
    } else {
        fail('AC-43: list() likewise returns exactly one record');
        fail('AC-43: ...and it is the real record');
    }
}

# =============================================================================
# AC-44 -- delete leaves .lock/.lock.holder on disk; grep: no unlink of a
# .lock or .lock.holder path anywhere in Store.pm.
# =============================================================================
{
    my $rec = eval { $store->create(id => 'rec-ac44', fields => { t => '1' }, order => ['t']) };
    ok(defined $rec, 'AC-44 fixture: create() succeeds') or diag("error: $@");
    if (defined $rec) {
        my $path = $rec->{path};
        # Force a lock/holder pair to exist by acquiring and releasing once,
        # via Almanac::Lock directly -- independent of Store's own locking so
        # this fixture step does not depend on the module under test.
        my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'ac44-fixture');
        ok(defined $lock, 'AC-44 fixture: a lock/holder pair can be created directly via Almanac::Lock')
            or diag('lock error: ' . (ref($lock_err) ? $lock_err->{message} : $lock_err));
        $lock->release if defined $lock;
        ok(-f "$path.lock" && -f "$path.lock.holder", 'AC-44 fixture: the lock and holder sidecars exist before delete');

        my $deleted = eval { $store->delete('rec-ac44', expect => $rec) };
        ok($deleted, 'AC-44: delete() succeeds') or diag("error: $@");
        ok(!-f $path, 'AC-44: the record file is gone');
        ok(-f "$path.lock" && -f "$path.lock.holder", 'AC-44: the .lock and .lock.holder sidecars REMAIN on disk after delete');
    } else {
        fail($_) for ('AC-44 fixture: a lock/holder pair can be created directly via Almanac::Lock',
                       'AC-44 fixture: the lock and holder sidecars exist before delete',
                       'AC-44: delete() succeeds', 'AC-44: the record file is gone',
                       'AC-44: the .lock and .lock.holder sidecars REMAIN on disk after delete');
    }

    if (-f $STORE_PM) {
        my @lines = read_all_lines($STORE_PM);
        my @hits;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            push @hits, "$STORE_PM:" . ($i + 1) . ": $l" if $l =~ /\bunlink\b/ && $l =~ /\.lock(\.holder)?\b/;
        }
        unless (ok(@hits == 0, 'AC-44: grep -- Store.pm contains no unlink of a path ending .lock or .lock.holder')) {
            diag($_) for @hits;
        }
    } else {
        fail('AC-44: grep -- Store.pm contains no unlink of a path ending .lock or .lock.holder');
    }
}

# =============================================================================
# AC-45 -- every error kind: exit_code == 2, stringifies to its message, and
# the message ends with a well-formed machine block whose first line is
# "almanac-error:" and whose kind: line matches the raised kind.
# =============================================================================
{
    my @errs;
    my $missing_rec = eval { $store->read('does-not-exist') };
    push @errs, ['not_found', $@];

    my $rec = eval { $store->create(id => 'rec-ac45', fields => { t => '1' }, order => ['t']) };
    my $dup = eval { $store->create(id => 'rec-ac45', fields => { t => '2' }, order => ['t']) };
    push @errs, ['exists', $@];

    my $bad = eval { $store->create(id => 'a/b', fields => { t => '1' }, order => ['t']) };
    push @errs, ['bad_id', $@];

    if (defined $rec) {
        my $resv = eval { $store->update('rec-ac45', expect => $rec, set => { id => 'x' }) };
        push @errs, ['reserved_field', $@];
    }

    for my $pair (@errs) {
        my ($kind, $err) = @$pair;
        ok(ref($err) =~ /::Error$/, "AC-45 [$kind]: die payload is a blessed Error object") or next;
        is($err->{exit_code}, 2, "AC-45 [$kind]: exit_code == 2");
        is("$err", $err->{message}, "AC-45 [$kind]: stringification equals the message field");
        ok(has_almanac_error_block($err->{message}), "AC-45 [$kind]: message contains the almanac-error: block header");
        is(machine_block_field($err->{message}, 'kind'), $kind, "AC-45 [$kind]: the machine block's kind: line matches");
        like($err->{message}, qr/\n\z/, "AC-45 [$kind]: message ends with a newline");
    }
}

# =============================================================================
# AC-25 -- update/delete/insert_before/insert_after naming an absent id each
# die not_found with exit_code == 2; and a real child process surfacing one
# through Almanac::Record::fatal exits 2 (not 0, not 1).
# =============================================================================
{
    my $fake_expect = { rev => 'deadbeef', fields => {} };
    my %attempts = (
        update         => sub { $store->update('nope', expect => $fake_expect, set => { a => 1 }) },
        delete         => sub { $store->delete('nope', expect => $fake_expect) },
        insert_before  => sub { $store->insert_before('nope', fields => { a => 1 }, order => ['a']) },
        insert_after   => sub { $store->insert_after('nope', fields => { a => 1 }, order => ['a']) },
    );
    for my $verb (sort keys %attempts) {
        eval { $attempts{$verb}->() };
        is(err_kind($@), 'not_found', "AC-25: $verb() naming a missing id dies not_found")
            or diag("got: " . (ref($@) ? "$@" : $@));
        is(err_field($@, 'exit_code'), 2, "AC-25: $verb()'s not_found carries exit_code == 2");
    }

    # End-to-end: a real child process surfaces not_found through
    # Almanac::Record::fatal and exits 2 (not 0, not 1, no no-op).
    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $child = "$WORKDIR/ac25-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'AC25CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($scripts_dir, $root) = @ARGV;
local @INC = ($scripts_dir, @INC);
eval { require Almanac::Store; require Almanac::Record; 1 } or do {
    print "MODULE-LOAD-FAILED: $@\n";
    exit 3;
};
my $store = Almanac::Store->open(scope => 'project', type => 'note', root => $root);
my $rec = eval { $store->update('never-existed', expect => { rev => 'x', fields => {} }, set => { a => 1 }) };
if (my $err = $@) {
    Almanac::Record::fatal($err);
}
print "UNEXPECTED-SUCCESS\n";
exit 0;
AC25CHILD
    close $fh;
    my $out = `perl "$child" "$S" "$ROOT" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 2, 'AC-25: end-to-end -- a real child surfacing not_found through Almanac::Record::fatal exits 2')
        or diag("output: $out");
    like($out, qr/not_found/, 'AC-25: end-to-end -- the child\'s output names the not_found kind');
}

# =============================================================================
# AC-29 (DC8) -- project-root resolution from the root and from a nested
# subdirectory resolve to the string-identical dir, with CLAUDE_PROJECT_DIR
# deleted, asserted with real child processes that chdir first; a record
# created from one is read from the other and vice versa.
# =============================================================================
{
    my $PROJ = tempdir(CLEANUP => 1);
    $PROJ =~ s{\\}{/}g;
    mkdir("$PROJ/.ccpraxis-local-data") or die "fixture: mkdir marker: $!";
    require File::Path;
    File::Path::make_path("$PROJ/a/b/c");
    my $SUBDIR = "$PROJ/a/b/c";

    my $child29 = "$PROJ/../ac29-child.pl";
    # Keep the child OUTSIDE the project tree it is walking, so it is never
    # mistaken for part of the fixture.
    open(my $fh, '>', $child29) or die "fixture: cannot write $child29: $!";
    print {$fh} <<'AC29CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($scripts_dir, $chdir_to, $mode, $id, $outfile) = @ARGV;
delete $ENV{CLAUDE_PROJECT_DIR};
chdir($chdir_to) or die "child: cannot chdir to $chdir_to: $!";
local @INC = ($scripts_dir, @INC);
require Almanac::Store;
my $store = eval { Almanac::Store->open(scope => 'project', type => 'note') };
if (!defined $store) {
    open(my $of, '>', $outfile) or exit 1;
    print {$of} "ERROR: $@\n";
    close $of;
    exit 0;
}
my $dir = $store->dir;
if ($mode eq 'create') {
    # `origin` USED TO STORE $chdir_to, A REAL FILESYSTEM PATH. Fixed 2026-09-17
    # under a narrow driver authorisation. The parent asserts
    # qr/ORIGIN=from-root/ and qr/ORIGIN=from-subdir/ -- marker strings, which
    # are the RECORD IDs this child is invoked with, not directories. A path can
    # never match either, so both assertions were unfailable-in-principle and
    # unpassable-in-fact.
    #
    # Storing $id makes the round-trip say what AC-29 is actually about: a
    # record written from one working directory is READ BACK from another, and
    # it is the same record. $chdir_to is already proven by the DIR= line the
    # parent checks separately, and that check passes today.
    my $rec = eval { $store->create(id => $id, fields => { origin => $id }, order => ['origin']) };
    open(my $of, '>', $outfile) or exit 1;
    print {$of} "DIR=$dir\n";
    print {$of} (defined $rec ? "CREATE_OK\n" : "CREATE_ERR: $@\n");
    close $of;
} else {
    my $rec = eval { $store->read($id) };
    open(my $of, '>', $outfile) or exit 1;
    print {$of} "DIR=$dir\n";
    print {$of} (defined $rec ? "ORIGIN=" . $rec->{fields}{origin} . "\n" : "READ_ERR: $@\n");
    close $of;
}
exit 0;
AC29CHILD
    close $fh;

    my $out_a = "$PROJ/../ac29-out-a.txt";
    my $out_b = "$PROJ/../ac29-out-b.txt";
    system(qq{perl "$child29" "$S" "$PROJ" create from-root "$out_a"});
    system(qq{perl "$child29" "$S" "$SUBDIR" read from-root "$out_b"});

    my $result_a = slurp_raw($out_a) // '';
    my $result_b = slurp_raw($out_b) // '';
    my ($dir_a) = $result_a =~ /^DIR=(.*)$/m;
    my ($dir_b) = $result_b =~ /^DIR=(.*)$/m;
    ok(defined $dir_a && defined $dir_b && length($dir_a) && $dir_a eq $dir_b,
       'AC-29: dir resolved from the project root and from a/b/c are string-identical')
        or diag("root result: $result_a\nsubdir result: $result_b");
    like($result_a, qr/CREATE_OK/, 'AC-29: create() from the project root succeeds');
    like($result_b, qr/ORIGIN=from-root/, 'AC-29: read() from the subdirectory sees the record created at the root');

    # And the reverse direction: create from the subdirectory, read from root.
    my $out_c = "$PROJ/../ac29-out-c.txt";
    my $out_d = "$PROJ/../ac29-out-d.txt";
    system(qq{perl "$child29" "$S" "$SUBDIR" create from-subdir "$out_c"});
    system(qq{perl "$child29" "$S" "$PROJ" read from-subdir "$out_d"});
    my $result_c = slurp_raw($out_c) // '';
    my $result_d = slurp_raw($out_d) // '';
    like($result_c, qr/CREATE_OK/, 'AC-29: create() from a/b/c succeeds');
    like($result_d, qr/ORIGIN=from-subdir/, 'AC-29: read() from the project root sees the record created from a/b/c');
}

# =============================================================================
# STEP-2 GATE ADDITION -- Store's write path and Almanac::Record::write_file
# must produce BYTE-IDENTICAL output for the same record. Not a spec AC
# number; the ledger's step-2 gate names it as a binding condition, so it is
# treated as one here.
# =============================================================================
{
    require Almanac::Record;
    my $rec = eval { $store->create(id => 'rec-equiv', fields => { alpha => 'one', beta => 'two' }, order => ['alpha', 'beta'], rank => 'F', body => "a body\nwith two lines\n") };
    ok(defined $rec, 'equivalence fixture: create() via the store succeeds') or diag("error: $@");
    if (defined $rec) {
        my $store_bytes = slurp_raw($rec->{path});
        ok(defined $store_bytes, 'equivalence fixture: the store-written file is readable');

        my $direct_path = "$ROOT/direct-equiv.md";
        my $direct_hash = { id => $rec->{id}, fields => $rec->{fields}, order => $rec->{order}, body => $rec->{body} };
        eval { Almanac::Record::write_file($direct_path, $direct_hash) };
        ok(!$@, 'equivalence fixture: Almanac::Record::write_file succeeds on the same record shape') or diag("error: $@");
        my $direct_bytes = slurp_raw($direct_path);

        is($direct_bytes, $store_bytes,
           'STEP-2 GATE: Store\'s write path and Almanac::Record::write_file produce byte-identical output for the same record');
    } else {
        fail('equivalence fixture: the store-written file is readable');
        fail('equivalence fixture: Almanac::Record::write_file succeeds on the same record shape');
        fail('STEP-2 GATE: Store\'s write path and Almanac::Record::write_file produce byte-identical output for the same record');
    }
}

# =============================================================================
# FIXBATCH (redteam MEDIUM-3) -- a structural refusal from
# Almanac::Record::serialize (a field name that is not a legal frontmatter
# key) is wrapped and re-raised in STORE'S OWN error shape, not left to
# propagate as a bare Almanac::Record::Error (which would bypass S2.5's
# machine-block contract for every caller checking `ref $@ eq
# 'Almanac::Store::Error'`).
# =============================================================================
{
    my $bad = eval { $store->create(id => 'rec-fb-refused', fields => { 'bad-key' => 'x' }, order => ['bad-key']) };
    ok(!defined $bad, 'FIXBATCH: create() with an illegal field name fails') or diag('unexpectedly succeeded');
    ok(ref($@) eq 'Almanac::Store::Error', 'FIXBATCH: ...and the die payload is Store\'s OWN error class, not Record\'s')
        or diag('got: ' . (ref($@) || '(not a ref)'));
    is(err_kind($@), 'refused', 'FIXBATCH: ...with kind refused') or diag('got: ' . (ref($@) ? "$@" : $@));
    is(err_field($@, 'exit_code'), 2, 'FIXBATCH: ...and exit_code == 2');
    ok(has_almanac_error_block($@->{message}), 'FIXBATCH: ...and the message carries Store\'s machine block')
        if ref($@) eq 'Almanac::Store::Error';
}

# =============================================================================
# FIXBATCH (redteam MEDIUM-6) -- a Windows reserved device name (NUL, CON,
# AUX, PRN, COMn, LPTn -- case-insensitive) is refused as bad_id, the same
# as any other grammar violation, rather than being accepted and producing
# a file that native Windows tooling cannot see or delete.
# =============================================================================
{
    for my $bad_id (qw(NUL nul Nul CON PRN AUX COM1 LPT1)) {
        my $r = eval { $store->create(id => $bad_id, fields => { t => '1' }, order => ['t']) };
        is(err_kind($@), 'bad_id', "FIXBATCH: create(id => '$bad_id') (a Windows reserved device name) dies bad_id")
            or diag('got: ' . (ref($@) ? "$@" : $@));
    }
}

# =============================================================================
# FIXBATCH (redteam MEDIUM-7) -- a reference passed as a field value or a
# body is refused (usage) rather than being stringified into the record
# file (which would silently destroy the caller's data and leak a heap
# address to disk).
# =============================================================================
{
    my $r1 = eval { $store->create(id => 'rec-fb-refval1', fields => { payload => ['a', 'b'] }, order => ['payload']) };
    is(err_kind($@), 'usage', 'FIXBATCH: create() with an arrayref field value dies usage') or diag('got: ' . (ref($@) ? "$@" : $@));

    my $r2 = eval { $store->create(id => 'rec-fb-refval2', fields => { t => '1' }, order => ['t'], body => { not => 'a scalar' }) };
    is(err_kind($@), 'usage', 'FIXBATCH: create() with a hashref body dies usage') or diag('got: ' . (ref($@) ? "$@" : $@));

    my $base = eval { $store->create(id => 'rec-fb-refval3', fields => { t => '1' }, order => ['t']) };
    ok(defined $base, 'FIXBATCH fixture: a base record for the update-side ref checks exists') or diag('error: ' . ($@ // ''));
    if (defined $base) {
        my $r3 = eval { $store->update('rec-fb-refval3', expect => $base, set => { t => { nope => 1 } }) };
        is(err_kind($@), 'usage', 'FIXBATCH: update() with a hashref set-value dies usage') or diag('got: ' . (ref($@) ? "$@" : $@));
    } else {
        fail('FIXBATCH: update() with a hashref set-value dies usage');
    }
}

# =============================================================================
# FIXBATCH (review SHOULD-10) -- expect => { rev => undef, fields => {} }
# (a key present with an undef value) fails the usage gate rather than
# passing it and warning "Use of uninitialized value" at the CAS (S2.0/
# AC-46 forbid Store.pm from ever writing to STDERR).
# =============================================================================
{
    my $base = eval { $store->create(id => 'rec-fb-undefrev', fields => { t => '1' }, order => ['t']) };
    ok(defined $base, 'FIXBATCH fixture: a base record for the undef-rev check exists') or diag('error: ' . ($@ // ''));
    if (defined $base) {
        my $u = eval { $store->update('rec-fb-undefrev', expect => { rev => undef, fields => {} }, set => { t => '2' }) };
        is(err_kind($@), 'usage', 'FIXBATCH: update() with expect => { rev => undef, ... } dies usage, not conflict')
            or diag('got: ' . (ref($@) ? "$@" : $@));
        my $d = eval { $store->delete('rec-fb-undefrev', expect => { rev => undef, fields => {} }) };
        is(err_kind($@), 'usage', 'FIXBATCH: delete() with expect => { rev => undef, ... } dies usage, not conflict')
            or diag('got: ' . (ref($@) ? "$@" : $@));
    } else {
        fail('FIXBATCH: update() with expect => { rev => undef, ... } dies usage, not conflict');
        fail('FIXBATCH: delete() with expect => { rev => undef, ... } dies usage, not conflict');
    }
}

# =============================================================================
# FIXBATCH (redteam MEDIUM-5) -- $ENV{ALMANAC_SURFACE} may only TIGHTEN a
# detected surface (host -> container), which is the only direction
# testable without an actual container marker on disk; the loosening
# refusal (container -> host, unreachable here since this host carries
# neither marker) is verified by code inspection, per the fix-batch report.
# =============================================================================
{
    ok(!-e '/run/.containerenv' && !-e '/.dockerenv',
       'FIXBATCH fixture: this host carries no container marker (a precondition for this check)');
    local $ENV{ALMANAC_SURFACE} = 'container';
    my $s = eval { Almanac::Store::surface() };
    is($s, 'container', 'FIXBATCH: ALMANAC_SURFACE=container tightens a detected host surface to container')
        or diag('error: ' . ($@ // '') . ' got: ' . (defined $s ? $s : '(undef)'));
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
