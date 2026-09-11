package Almanac::Lock;
# Almanac::Lock — a bounded, blocking exclusive lock over a sidecar
# `<record>.lock`, plus the rename-retrying atomic write that goes with it.
#
# WHY THIS EXISTS. almanac's records are read-modify-written by more than one
# agent at a time. A compare-and-swap can only REFUSE the loser; the operator's
# requirement is that both writers land their change, in some order. That needs
# serialization, which needs a real OS-level lock.
#
# flock WORKS on this host. `plugins/butler/scripts/bp-blueprint.pl:425` has
# taken flock(LOCK_EX) on a sidecar lock file for every blueprint mutation in
# this repo since it was written, and a direct measurement on 2026-09-11 (two
# concurrent processes, one sidecar lock file, both host perls) showed the
# waiter blocking for the holder's full remaining hold and then acquiring.
#
# FIVE RULES THIS MODULE IS BUILT ON, each of which cost somebody real time:
#
#  1. CORE PERL ONLY. almanac runs from any project through $CLAUDE_PLUGIN_ROOT,
#     including projects where butler is disabled. Importing anything from
#     another plugin — BpResumption.pm above all — would break it there. The
#     six modules below are the whole dependency list, and all six ship with
#     every perl this repo runs on.
#
#  2. PERL'S flock HAS NO TIMEOUT, and `alarm`/SIGALRM does NOT interrupt a
#     blocking flock on Windows perl. So acquisition is LOCK_EX|LOCK_NB polling
#     against an ABSOLUTE deadline computed once. There is no alarm anywhere in
#     this file, deliberately, and a test asserts that by scanning it.
#
#  3. A LOCK FILE IS NEVER REMOVED, on any code path. flock has no stale locks:
#     the kernel releases on fd close, including on process death, so a lock
#     FILE on disk is not a held lock and there is nothing to reap. Removing one
#     is a race — a fresh open() at the same path gets a NEW inode, which is a
#     DIFFERENT lock, so two processes end up holding "the lock" at once.
#     almanac-lock-serialization.t demonstrates exactly that outcome. The cost
#     is permanent sidecars; that is the cheaper side of the trade.
#
#  4. HOLDER IDENTITY LIVES IN A SEPARATE FILE, `<record>.lock.holder`, never
#     in the lock file — the lock file is opened truncating ('>'), so a WAITER
#     would wipe the holder's identity before it ever blocked.
#
#  5. rename() OVER A PATH ANOTHER PROCESS HOLDS OPEN FAILS on Windows. Every
#     atomic write therefore needs a bounded retry rather than a "write failed"
#     report. The retryable errno set is an ALLOWLIST (see %RETRYABLE_ERRNO): a
#     denylist would spend the whole deadline turning a permanent failure into a
#     slow permanent failure.
#
# NEITHER rename_with_retry NOR write_atomic ACQUIRES ANYTHING. They assume the
# caller already holds the lock. Do not add an acquire to them.
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
use Errno ();
use JSON::PP ();
use Sys::Hostname ();

our $VERSION = '1.0';

# Tunables, as package variables so a test can read them and a caller can
# override per call. AC-20 pins the relationship between the two deadlines:
# DEFAULT_RENAME_TIMEOUT_MS * 2 < DEFAULT_TIMEOUT_MS, so a holder that is
# legitimately retrying a rename can never time out its own waiters.
our $DEFAULT_TIMEOUT_MS        = 10_000;
our $DEFAULT_POLL_MS           = 25;
our $DEFAULT_RENAME_TIMEOUT_MS = 2_000;
our $DEFAULT_RENAME_POLL_MS    = 20;

# Resolved NUMERICALLY at load time, never imported by name: a symbol Errno
# does not define on this platform (ETXTBSY is the usual one) would be a
# compile failure rather than a missing retry.
#
#   EACCES  — MSVCRT-flavoured perl's report of a Windows sharing violation
#   EBUSY   — the MSYS/Cygwin perl's report of the same thing
#   EPERM   — observed on some Windows perl builds for the same class
#   ETXTBSY — the Linux/container form of the same class
#
# EVERYTHING ELSE IS FATAL ON THE FIRST ATTEMPT — ENOENT, EXDEV, ENOSPC, EROFS,
# EISDIR, ENOTDIR, ENAMETOOLONG. Waiting does not bring back a temp file that is
# gone, and a cross-device rename means the design is wrong rather than busy.
our %RETRYABLE_ERRNO = map { $_ => 1 } grep { defined }
    ( eval { Errno::EACCES() }, eval { Errno::EBUSY() },
      eval { Errno::EPERM()  }, eval { Errno::ETXTBSY() } );

# Process-level registry of lock paths this process currently holds. flock
# locks are per open-file-description, so a second acquire on the same path
# from the same process would CONFLICT WITH THE FIRST and stall for the entire
# deadline. That is refused immediately instead — see acquire().
my %HELD;

# --- pure path derivation ---------------------------------------------------
# Both take the RECORD path (…/<id>.md), never a lock path. The only
# normalisation is backslash-to-forward-slash, so a Windows-style and a
# POSIX-style spelling of the same file derive the same lock path (and so the
# reentrancy registry keys agree). `<t>.lock.holder` is deliberately a suffix
# of `<t>.lock` so one grep covers both.
sub lock_path_for {
    my ($t) = @_;
    $t = '' unless defined $t;
    $t =~ s{\\}{/}g;
    return "$t.lock";
}
sub holder_path_for {
    my ($t) = @_;
    $t = '' unless defined $t;
    $t =~ s{\\}{/}g;
    return "$t.lock.holder";
}

sub _iso {
    my ($epoch) = @_;
    my @t = gmtime(defined $epoch ? $epoch : time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _is_nonneg_int { return defined($_[0]) && $_[0] =~ /\A\d+\z/ }
sub _is_pos_int    { return defined($_[0]) && $_[0] =~ /\A\d+\z/ && $_[0] > 0 }

# Precedence: explicit %opt > environment > package default. A value that is
# not a non-negative integer is IGNORED SILENTLY — an env typo must not break
# every write in the store.
sub _resolve_timeout_ms {
    my (%opt) = @_;
    return $opt{timeout_ms} + 0 if _is_nonneg_int($opt{timeout_ms});
    return $ENV{ALMANAC_LOCK_TIMEOUT_MS} + 0 if _is_nonneg_int($ENV{ALMANAC_LOCK_TIMEOUT_MS});
    return $DEFAULT_TIMEOUT_MS;
}
sub _resolve_poll_ms {
    my (%opt) = @_;
    return $opt{poll_ms} + 0 if _is_pos_int($opt{poll_ms});
    return $ENV{ALMANAC_LOCK_POLL_MS} + 0 if _is_pos_int($ENV{ALMANAC_LOCK_POLL_MS});
    return $DEFAULT_POLL_MS;
}

# --- the holder-identity file ----------------------------------------------
# Written AFTER flock succeeds and BEFORE acquire returns, as ONE line of
# canonical JSON in a single print — a single short line minimises the
# torn-read window for a reader that is not (and must not be) holding the lock.
#
# `host` is load-bearing: across a bind mount it is what tells you whether the
# holder is the host or a container.
#
# release() does NOT touch this file. A holder record therefore names "whoever
# most recently acquired", which may be a process that has since finished, and
# every message built from it says exactly that rather than over-claiming.
sub _write_holder {
    my ($holder_path, $target, $verb) = @_;
    my $now  = time;
    my $host = eval { Sys::Hostname::hostname() };
    $host = 'unknown' unless defined $host && length $host;
    my %rec = (
        pid               => $$,
        host              => $host,
        script            => $0,
        verb              => ((defined $verb && length $verb) ? $verb : undef),
        target            => $target,
        acquired_at       => _iso($now),
        acquired_at_epoch => $now,
    );
    if (open(my $h, '>', $holder_path)) {
        print {$h} JSON::PP->new->canonical->encode(\%rec);
        close $h;
    }
    return \%rec;
}

# read_holder($record_path) -> \%record | undef
#
# Reads `<record>.lock.holder` — NEVER `<record>.lock`. Returns undef on any of:
# absent, empty, torn mid-write, invalid JSON, or not a JSON object. It never
# dies and it NEVER TAKES A LOCK: a waiter that has just timed out must be able
# to name the holder without contending all over again.
sub read_holder {
    my ($target) = @_;
    my $p = holder_path_for($target);
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $raw && length $raw;
    my $rec = eval { JSON::PP->new->decode($raw) };
    return undef unless ref $rec eq 'HASH';
    return $rec;
}

sub _holder_line {
    my ($holder, $holder_path) = @_;
    return "  holder: unknown (no readable holder record at $holder_path)\n"
        unless ref $holder eq 'HASH';
    my $pid    = defined $holder->{pid}         ? $holder->{pid}         : '?';
    my $host   = defined $holder->{host}        ? $holder->{host}        : '?';
    my $script = defined $holder->{script}      ? $holder->{script}      : '?';
    my $at     = defined $holder->{acquired_at} ? $holder->{acquired_at} : '?';
    return "  holder: the holder record names pid $pid on host $host, script $script,\n"
         . "          recorded at $at (read from $holder_path)\n";
}

sub _err {
    my (%a) = @_;
    my $holder = exists $a{holder} ? $a{holder} : read_holder($a{target});
    my %e = (
        kind        => $a{kind},
        target      => $a{target},
        lock_path   => lock_path_for($a{target}),
        holder_path => holder_path_for($a{target}),
        waited_ms   => $a{waited_ms},
        timeout_ms  => $a{timeout_ms},
        holder      => $holder,
    );
    $e{errno} = $a{errno} if defined $a{errno};
    my $verb = (defined $a{verb} && length $a{verb}) ? $a{verb} : '(none given)';

    if ($a{kind} eq 'timeout') {
        $e{message} =
            "almanac lock: could not acquire the exclusive lock on this record within "
          . "$a{timeout_ms}ms.\n"
          . "  verb:   $verb\n"
          . "  record: $e{target}\n"
          . "  waited: $a{waited_ms}ms (budget $a{timeout_ms}ms)\n"
          . "  lock:   $e{lock_path}\n"
          . _holder_line($holder, $e{holder_path})
          . "  Nothing was written.\n";
    }
    elsif ($a{kind} eq 'reentrant') {
        $e{message} =
            "almanac lock: this process already holds the lock on this record, and flock "
          . "locks are per open file description, so a second acquire would block against "
          . "the first until the deadline expired. Refusing immediately instead.\n"
          . "  verb:   $verb\n"
          . "  record: $e{target}\n"
          . "  lock:   $e{lock_path}\n"
          . "  Nothing was written.\n";
    }
    else {
        my $errno = defined $a{errno} ? $a{errno} : 'unknown error';
        $e{message} =
            "almanac lock: could not open the lock file for this record: $errno\n"
          . "  verb:   $verb\n"
          . "  record: $e{target}\n"
          . "  lock:   $e{lock_path}\n"
          . "  The parent directory must exist before a lock is taken — this module does "
          . "not create it.\n"
          . "  Nothing was written.\n";
    }
    return \%e;
}

# --- the bounded-acquire loop ----------------------------------------------
# The whole of the deadline discipline, in one place, shared by acquire() and
# resume(). Five properties, each of which a test relies on:
#
#  1. The deadline is ABSOLUTE and computed once by the caller — never
#     accumulated from per-iteration sleep durations. On Windows a requested
#     25ms sleep routinely takes 30-40ms; summing 400 of those drifts by
#     seconds. An absolute deadline does not drift.
#  2. THE FIRST ATTEMPT PRECEDES ANY SLEEP, so an uncontended acquire costs one
#     syscall and zero sleep.
#  3. The final sleep is CLAMPED to the remaining budget, so the call overshoots
#     by at most one scheduler quantum rather than by a whole poll interval.
#  4. timeout_ms => 0 is well-defined: exactly one non-blocking attempt.
#  5. No alarm. See rule 2 in this file's header.
sub _poll_for_lock {
    my ($fh, $deadline, $poll_s) = @_;
    while (1) {
        return 1 if flock($fh, LOCK_EX | LOCK_NB);
        my $now = Time::HiRes::time();
        return 0 if $now >= $deadline;
        my $remain = $deadline - $now;
        Time::HiRes::sleep($remain < $poll_s ? $remain : $poll_s);
    }
}

sub _elapsed_ms { return int((Time::HiRes::time() - $_[0]) * 1000 + 0.5) }

# acquire($record_path, %opt) -> ($lock, undef) | (undef, \%err)
#
# ALWAYS returns a two-element list. Never dies, never blocks past its deadline.
# %opt: timeout_ms, poll_ms, verb.
#
# The caller owns directory creation: if the parent directory does not exist
# this returns kind => 'io' naming the path rather than creating it.
sub acquire {
    my ($class, $target, %opt) = @_;
    my $lock_path   = lock_path_for($target);
    my $holder_path = holder_path_for($target);
    my $timeout_ms  = _resolve_timeout_ms(%opt);
    my $poll_ms     = _resolve_poll_ms(%opt);
    my $t0          = Time::HiRes::time();

    return (undef, _err(kind => 'reentrant', target => $target, verb => $opt{verb},
                        waited_ms => _elapsed_ms($t0), timeout_ms => $timeout_ms))
        if $HELD{$lock_path};

    # The truncating open is deliberate and is why holder identity lives
    # elsewhere: a WAITER reaching this line wipes the file before it blocks.
    open(my $fh, '>', $lock_path)
        or return (undef, _err(kind => 'io', target => $target, verb => $opt{verb},
                               waited_ms => _elapsed_ms($t0), timeout_ms => $timeout_ms,
                               errno => "$!"));

    my $got = _poll_for_lock($fh, $t0 + $timeout_ms / 1000, $poll_ms / 1000);
    my $waited_ms = _elapsed_ms($t0);

    unless ($got) {
        close $fh;
        return (undef, _err(kind => 'timeout', target => $target, verb => $opt{verb},
                            waited_ms => $waited_ms, timeout_ms => $timeout_ms));
    }

    _write_holder($holder_path, $target, $opt{verb});
    $HELD{$lock_path} = 1;
    my $self = bless {
        fh          => $fh,
        path        => $target,
        lock_path   => $lock_path,
        holder_path => $holder_path,
        verb        => $opt{verb},
        held        => 1,
        waited_ms   => $waited_ms,
    }, (ref($class) || $class || __PACKAGE__);
    return ($self, undef);
}

sub path        { return $_[0]{path} }
sub lock_path   { return $_[0]{lock_path} }
sub holder_path { return $_[0]{holder_path} }
sub held        { return $_[0]{held} ? 1 : 0 }
sub waited_ms   { return $_[0]{waited_ms} }

# release() -> 1, always. Idempotent. NEVER REMOVES A FILE — not the lock file
# and not the holder file. See rule 3 in this file's header.
sub release {
    my ($self) = @_;
    return 1 unless $self->{held};
    if ($self->{fh}) {
        flock($self->{fh}, LOCK_UN);
        close $self->{fh};
    }
    delete $self->{fh};
    $self->{held} = 0;
    delete $HELD{ $self->{lock_path} };
    return 1;
}

# suspend()/resume() — TEST SEAM ONLY, and there is exactly one sanctioned
# caller: almanac-bug.pl's _race_test_hook, behind its ALMANAC_RACE_TEST_HOOK
# env guard. Once the lock wraps load->write, the only writer that can still
# land inside that window is one that BYPASSED the lock, and simulating exactly
# that is what the seam is for. No product code path may use these; a test
# asserts it by grep.
#
# suspend() drops the kernel lock but KEEPS THE FD OPEN, so the lock path stays
# registered against this process and resume() re-acquires on the same fd.
sub suspend {
    my ($self) = @_;
    return 1 unless $self->{held} && $self->{fh};
    flock($self->{fh}, LOCK_UN);
    $self->{held} = 0;
    return 1;
}

# resume(%opt) -> (1, undef) | (0, \%err). Same algorithm, same deadline
# discipline and same error shape as acquire.
sub resume {
    my ($self, %opt) = @_;
    return (1, undef) if $self->{held};
    my $timeout_ms = _resolve_timeout_ms(%opt);
    my $poll_ms    = _resolve_poll_ms(%opt);
    my $t0         = Time::HiRes::time();
    unless ($self->{fh}) {
        return (0, _err(kind => 'io', target => $self->{path}, verb => $self->{verb},
                        waited_ms => 0, timeout_ms => $timeout_ms,
                        errno => 'the lock was already released; there is no descriptor to resume'));
    }
    my $got = _poll_for_lock($self->{fh}, $t0 + $timeout_ms / 1000, $poll_ms / 1000);
    my $waited_ms = _elapsed_ms($t0);
    unless ($got) {
        return (0, _err(kind => 'timeout', target => $self->{path}, verb => $self->{verb},
                        waited_ms => $waited_ms, timeout_ms => $timeout_ms));
    }
    $self->{held} = 1;
    $HELD{ $self->{lock_path} } = 1;
    return (1, undef);
}

# A die between acquire and release still releases. Guarded because during
# global destruction the filehandle may already be gone.
sub DESTROY {
    my ($self) = @_;
    return unless ref $self;
    eval { $self->release; 1 };
    return;
}

# --- rename-retrying atomic write ------------------------------------------
# rename_with_retry($from, $to, %opt) -> (1, undef) | (0, \%err)
#
# %opt: rename_timeout_ms (2000), rename_poll_ms (20), on_rename (code ref).
#
# on_rename is a documented dependency-injection point, NOT a back door. It
# exists because the deadline behaviour and the errno classification cannot be
# provoked on demand by any real holder: you cannot ask Defender to hold a file
# for exactly 2.5s, and you cannot ask it to fail with ENOSPC. The real-holder
# path is asserted separately, with a native Windows process. NO PRODUCT CODE
# PATH PASSES on_rename, and a test asserts that by grep.
#
# 20ms poll: the blocker is an opaque native process (an on-access scanner, an
# editor, a node process reading the file) whose hold is tens to hundreds of
# milliseconds, so a 20ms probe lands within one scheduler quantum of its
# release. 2000ms deadline: long enough to outlast a scan of a small file with
# ~4x headroom, short enough to keep the holder's worst case ~5x under the lock
# deadline. A rename still failing after 2s is no longer usefully called
# transient, and reporting it beats blocking longer.
sub rename_with_retry {
    my ($from, $to, %opt) = @_;
    my $timeout_ms = _is_nonneg_int($opt{rename_timeout_ms})
                   ? $opt{rename_timeout_ms} + 0 : $DEFAULT_RENAME_TIMEOUT_MS;
    my $poll_ms    = _is_pos_int($opt{rename_poll_ms})
                   ? $opt{rename_poll_ms} + 0 : $DEFAULT_RENAME_POLL_MS;
    my $on_rename  = (ref $opt{on_rename} eq 'CODE')
                   ? $opt{on_rename} : sub { return rename($_[0], $_[1]) };

    my $poll_s   = $poll_ms / 1000;
    my $t0       = Time::HiRes::time();
    my $deadline = $t0 + $timeout_ms / 1000;
    my $attempts = 0;
    my ($errno_num, $errno_str) = (0, 'no error recorded');

    while (1) {
        $attempts++;
        $! = 0;
        return (1, undef) if $on_rename->($from, $to);
        $errno_num = $! + 0;
        $errno_str = "$!";
        # ALLOWLIST, never a denylist: anything not known to be transient is
        # fatal here and now, with the errno named.
        unless ($RETRYABLE_ERRNO{$errno_num}) {
            return (0, _rename_err('rename_fatal', $from, $to, $errno_num, $errno_str,
                                   $attempts, _elapsed_ms($t0), $timeout_ms));
        }
        my $now = Time::HiRes::time();
        last if $now >= $deadline;
        my $remain = $deadline - $now;
        Time::HiRes::sleep($remain < $poll_s ? $remain : $poll_s);
    }
    return (0, _rename_err('rename_timeout', $from, $to, $errno_num, $errno_str,
                           $attempts, _elapsed_ms($t0), $timeout_ms));
}

sub _rename_err {
    my ($kind, $from, $to, $errno_num, $errno_str, $attempts, $waited_ms, $timeout_ms) = @_;
    my $message = $kind eq 'rename_timeout'
        ? "rename still failing after ${waited_ms}ms and $attempts attempts: errno $errno_num "
        . "($errno_str). Something else is holding $to open; the retry deadline of "
        . "${timeout_ms}ms is exhausted."
        : "rename failed and is not retryable: errno $errno_num ($errno_str). Retrying would "
        . "turn a permanent failure into a slow one, so it failed on attempt $attempts.";
    return {
        kind      => $kind,
        message   => $message,
        from      => $from,
        to        => $to,
        errno     => $errno_str,
        errno_num => $errno_num,
        attempts  => $attempts,
        waited_ms => $waited_ms,
    };
}

# write_atomic($path, $bytes, %opt) -> (1, undef) | (0, \%err)
#
# Writes beside the target as "$path.tmp.$$" (same directory, so the rename is
# never cross-device) and renames with the bounded retry above. It ACQUIRES
# NOTHING — the caller holds the lock.
#
# It also removes nothing, ever: this module contains no file removal at all,
# by design (see rule 3 in the header), so a failed write leaves its temp file
# beside the target as evidence. A caller that manages its own temp file —
# AlmanacBug::_write_atomic does — should keep doing so and call
# rename_with_retry directly.
sub write_atomic {
    my ($path, $bytes, %opt) = @_;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>:raw', $tmp)
        or return (0, { kind => 'io', message => "could not open $tmp for writing: $!",
                        from => $tmp, to => $path, errno => "$!", errno_num => $! + 0,
                        attempts => 0, waited_ms => 0 });
    my $printed = print {$fh} (defined $bytes ? $bytes : '');
    my $closed  = close $fh;
    unless ($printed && $closed) {
        return (0, { kind => 'io', message => "could not write $tmp: $!",
                     from => $tmp, to => $path, errno => "$!", errno_num => $! + 0,
                     attempts => 0, waited_ms => 0 });
    }
    return rename_with_retry($tmp, $path, %opt);
}

1;
