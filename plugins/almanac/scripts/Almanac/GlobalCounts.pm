package Almanac::GlobalCounts;
# Almanac::GlobalCounts -- the single global-counts snapshot file (blueprint
# almanac-records, package 19-global-counts-snapshot). See specs/19-global-
# counts-snapshot-spec.md sections 2.3, 3, 4.
#
# Decision 7 (as amended): global counts are VISIBLE in a sandbox, global
# records are not ACCESSIBLE there. One file, one host path, written
# atomically through Almanac::Lock; a sandbox bind-mounts that single file
# read-only (MountSpec.pm, out of this module's scope).
#
# CORE PERL plus Almanac::Store, Almanac::Lock, JSON::PP. No import from
# another plugin (spec 2.3).
use strict;
use warnings;
use File::Path ();
use JSON::PP ();
use Time::HiRes ();
use Almanac::Store ();
use Almanac::Lock ();

our $VERSION = '1.0';

our $FILE_NAME      = 'almanac-global-counts.json';
our $CONTAINER_PATH = '/root/.claude/almanac-global-counts.json';

# ---------------------------------------------------------------------------
# snapshot_path(%opt) -> $path        (%opt: home)
#
# Deliberately the SAME home resolution Almanac::Store uses for the global
# stores (Almanac::Store::_resolve_home) -- the snapshot must describe the
# vault under the same home a global mutation just wrote to.
# ---------------------------------------------------------------------------
sub snapshot_path {
    my (%opt) = @_;
    my $home = Almanac::Store::_resolve_home(home => $opt{home});
    return "$home/.claude/$FILE_NAME";
}

# ---------------------------------------------------------------------------
# compute(%opt) -> \%counts     (%opt: home); dies (a Store error) on failure
# ---------------------------------------------------------------------------
sub compute {
    my (%opt) = @_;

    my $todo_store = Almanac::Store->open(scope => 'global', type => 'todo', home => $opt{home});
    my $todo_list  = $todo_store->list();
    my ($open, $done, $total) = (0, 0, 0);
    for my $rec (@$todo_list) {
        $total++;
        my $st = $rec->{fields}{status};
        if    (defined $st && $st eq 'open') { $open++ }
        elsif (defined $st && $st eq 'done') { $done++ }
        else {
            die Almanac::Store::Error->new(kind => 'bad_status', id => $rec->{id}, path => $rec->{path});
        }
    }

    my $note_store = Almanac::Store->open(scope => 'global', type => 'note', home => $opt{home});
    my $note_list  = $note_store->list();

    return {
        todo => { open => $open, done => $done, total => $total },
        note => { total => scalar(@$note_list) },
    };
}

# ---------------------------------------------------------------------------
# serialize(\%counts, $gen_at) -> $bytes -- exactly the section-2.2 shape.
# ---------------------------------------------------------------------------
sub serialize {
    my ($counts, $gen_at) = @_;
    my %doc = (
        generated_at => $gen_at,
        note         => { total => 0 + $counts->{note}{total} },
        schema       => 1,
        todo         => {
            done  => 0 + $counts->{todo}{done},
            open  => 0 + $counts->{todo}{open},
            total => 0 + $counts->{todo}{total},
        },
    );
    return JSON::PP->new->canonical(1)->encode(\%doc) . "\n";
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _is_nonneg_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return 0 unless "$v" =~ /\A\d+\z/;
    return 1;
}

# ---------------------------------------------------------------------------
# read_snapshot($path) -> \%snap | undef -- never dies, never writes, takes
# no lock. The reference implementation of the reader contract package 10
# reproduces in statusline.pl (Decision 18: it cannot require this module).
# PACKAGE-10 CONTRACT NOTE: the container-side reader (a per-render,
# short-lived process) does NOT retry -- see the bounded-retry note below
# for why that is deliberate, not an omission.
#
# Bounded-retry note (AC7, tightened per review MUST-FIX M1): the target is
# replaced only by rename (Almanac::Lock::rename_with_retry / write_atomic),
# which is atomic on POSIX but, measured on this host's Cygwin-flavoured
# perl under heavy concurrent rename traffic, has a real (sub-millisecond,
# but repeatable) window where -f is true yet a following stat() or open()
# momentarily fails -- the directory entry is between "old gone" and "new
# linked". A single-shot read would regress a caller from "saw a valid
# snapshot" to undef purely from that window, which is exactly what AC7
# forbids.
#
# The retry is therefore scoped to ONLY that case: this process has already
# read a VALID snapshot at this exact path at least once before (tracked in
# %SEEN_VALID, keyed by path). A first read of an absent path, a 0-byte
# stub, or a decoded-but-invalid file (every DC-f "no counters" case: no
# container has been created yet, or podman's auto-created 0-byte mount
# stub) returns undef on the FIRST attempt, with no sleep at all -- this is
# the common case for a per-render statusline read (spec 2.7's cost budget:
# one open, one bounded read, no loop), and retrying it would add up to
# 200ms of busy-polling to every such render for no benefit, since nothing
# is mid-transition. Once a path has produced one valid snapshot, later
# transient failures at that SAME path are retried for a short, bounded
# window (deadline 0.2s, 2ms polls) before giving up -- still no lock, no
# subprocess, no unbounded block.
my %SEEN_VALID;

sub read_snapshot {
    my ($path) = @_;
    return undef unless defined $path && length $path;

    my $snap = _read_snapshot_once($path);
    if (defined $snap) {
        $SEEN_VALID{$path} = 1;
        return $snap;
    }
    return undef unless $SEEN_VALID{$path};

    my $deadline = Time::HiRes::time() + 0.2;
    while (Time::HiRes::time() < $deadline) {
        Time::HiRes::sleep(0.002);
        $snap = _read_snapshot_once($path);
        if (defined $snap) {
            $SEEN_VALID{$path} = 1;
            return $snap;
        }
    }
    return undef;
}

sub _read_snapshot_once {
    my ($path) = @_;
    return undef unless -f $path;

    my @st = stat($path);
    return undef unless @st;
    my $size = $st[7];
    return undef unless defined $size && $size >= 1 && $size <= 4096;

    open(my $fh, '<:raw', $path) or return undef;
    # Bounded read (spec 2.7: "a bounded read of at most 4096 bytes"),
    # regardless of what the stat above reported -- the target can be
    # swapped by rename between stat and open (review S4), so the stat is
    # only a cheap early exit, never the size bound actually relied on.
    my $bytes = '';
    my $n = read($fh, $bytes, 4097);
    close $fh;
    return undef unless defined $n && $n >= 1 && $n <= 4096;

    my $decoded = eval { JSON::PP->new->decode($bytes) };
    return undef unless ref($decoded) eq 'HASH';

    return undef unless defined $decoded->{schema} && "$decoded->{schema}" eq '1';
    return undef unless defined $decoded->{generated_at}
        && $decoded->{generated_at} =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/;

    my $todo = $decoded->{todo};
    return undef unless ref($todo) eq 'HASH';
    for my $k (qw(open done total)) {
        return undef unless _is_nonneg_int($todo->{$k});
    }

    my $note = $decoded->{note};
    return undef unless ref($note) eq 'HASH';
    return undef unless _is_nonneg_int($note->{total});

    return $decoded;
}

# ---------------------------------------------------------------------------
# refresh(%opt) -> \%result     (%opt: home, timeout_ms); never dies/prints/
# exits. See spec 2.3's six-step algorithm.
# ---------------------------------------------------------------------------
sub refresh {
    my (%opt) = @_;
    my $path = snapshot_path(%opt);

    if (Almanac::Store::surface(%opt) eq 'container') {
        return { ok => 0, reason => 'container', path => $path };
    }

    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    unless (-d $dir) {
        my $made = eval { File::Path::make_path($dir); 1 };
        unless ($made && -d $dir) {
            return { ok => 0, reason => 'io', path => $path };
        }
    }

    my ($lock, $lock_err) = Almanac::Lock->acquire($path, timeout_ms => $opt{timeout_ms}, verb => 'refresh');
    unless ($lock) {
        my $kind = (ref($lock_err) eq 'HASH' && defined $lock_err->{kind}) ? $lock_err->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }

    my $counts = eval { compute(%opt) };
    if (my $err = $@) {
        $lock->release;
        my $kind = (ref($err) && defined $err->{kind}) ? $err->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }

    my $gen_at = _now_iso();
    my $bytes  = serialize($counts, $gen_at);

    my ($wok, $werr) = Almanac::Lock::write_atomic($path, $bytes);
    $lock->release;
    unless ($wok) {
        my $kind = (ref($werr) eq 'HASH' && defined $werr->{kind}) ? $werr->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }

    return { ok => 1, path => $path, counts => $counts, generated_at => $gen_at };
}

1;
