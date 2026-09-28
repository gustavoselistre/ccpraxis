#!/usr/bin/env perl
# platform: any
# Bounded exclusive-lock acquisition: the deadline is LOCK_NB polling, never
# `alarm`; the uncontended path is fast and the degenerate zero-budget case is
# well-defined; a second acquire from the SAME process is refused immediately
# rather than deadlocked; a process that dies mid-hold needs no reaping; and a
# timed-out caller learns the holder's identity from a file separate from the
# lock file itself, which the truncating open cannot have destroyed.
#
# Covers AC-5 .. AC-12 (DC2, DC3) of specs/01-lock-primitive-spec.md.
#
# Every OS-level contention case below is manufactured with a REAL separate
# perl process holding a real `flock`, not a seam -- so these assertions are
# meaningful both before and after the module under test exists. Where a
# block also writes the holder-identity sidecar, it does so BY HAND in the
# exact shape specs/01-lock-primitive-spec.md section 2.4 documents, so the
# reader (whatever reads it) is exercised on realistic data regardless of
# whether the writer side is implemented yet.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();
use Fcntl qw(:flock);
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";
my $A       = "$S/almanac-bug.pl";
my $LOCK_PM = "$S/Almanac/Lock.pm";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

ok(-f $LOCK_PM, 'Almanac::Lock module file exists at plugins/almanac/scripts/Almanac/Lock.pm')
    or diag('Almanac::Lock.pm is not present yet -- every acquire/release assertion below is '
          . 'expected to fail for exactly that reason, not for any other.');

my $LOAD_ERR;
eval { require Almanac::Lock; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::Lock loads with no compile/runtime error')
    or diag("load error: $LOAD_ERR");

# --- live-store sanity (house convention, spec section 6.3) -----------------
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

# =============================================================================
# Scaffolding
# =============================================================================

my $WORK = tempdir(CLEANUP => 1);
$WORK =~ s{\\}{/}g;
my $target_n = 0;
sub new_target {
    my $t = "$WORK/target-" . ++$target_n . ".md";
    open my $fh, '>', $t or die "fixture: cannot write $t: $!";
    print {$fh} "seed content\n";
    close $fh;
    return $t;
}

sub try_acquire {
    my (@args) = @_;
    # Fixed arity, deliberately: `eval { Almanac::Lock->acquire(...) }` returns
    # an EMPTY list when the call dies (as it does today -- the package does
    # not exist), and appending $died to that empty list would silently shift
    # every later positional assignment by one. my ($lock, $err) = eval {...}
    # instead always binds exactly two slots, undef on a die, so a caller
    # unpacking ($lock, $err, $died) never gets a false positive from an
    # error STRING landing in the $lock slot.
    my ($lock, $err) = eval { Almanac::Lock->acquire(@args) };
    my $died = $@;
    return ($lock, $err, $died);
}
sub try_release {
    my ($lock) = @_;
    return 0 unless defined $lock;
    my $ok = eval { $lock->release };
    return $ok ? 1 : 0;
}
sub try_read_holder {
    my ($target) = @_;
    my $rec = eval { Almanac::Lock::read_holder($target) };
    return $rec;
}

# bounded_wait_for_file($path, $deadline_seconds) -> 1 if it appeared, 0 on timeout
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

# A REAL, separate perl process. Opens "$lockpath" truncating ('>'), takes a
# real flock(LOCK_EX), optionally writes a holder-identity file in the exact
# shape spec section 2.4 documents, signals readiness, holds for $hold_s
# seconds, then exits (releasing the flock via fd close, same as any process
# death per C4/B5 -- no explicit LOCK_UN is required for that property to
# hold, but this script does close cleanly since it is not simulating a
# crash).
my $HOLDER_PL = "$WORK/raw-holder.pl";
{
    open my $fh, '>', $HOLDER_PL or die "fixture: cannot write $HOLDER_PL: $!";
    print {$fh} <<'HOLDER';
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
use JSON::PP ();
use Sys::Hostname ();
$| = 1;
my ($lockpath, $holderpath, $hold_s, $readypath, $verb) = @ARGV;
open(my $fh, '>', $lockpath) or do {
    open(my $rf, '>', $readypath); print {$rf} "OPEN-FAIL $!"; close $rf; exit 1;
};
flock($fh, LOCK_EX) or do {
    open(my $rf, '>', $readypath); print {$rf} "FLOCK-FAIL $!"; close $rf; exit 1;
};
if (defined $holderpath && $holderpath ne '-') {
    my $now = time;
    my @t = gmtime($now);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                       $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my %rec = (
        pid => $$, host => Sys::Hostname::hostname(), script => $0,
        verb => (defined $verb && length $verb ? $verb : undef),
        target => $lockpath, acquired_at => $iso, acquired_at_epoch => $now,
    );
    open(my $hf, '>', $holderpath) or do {
        open(my $rf, '>', $readypath); print {$rf} "HOLDERWRITE-FAIL $!"; close $rf; exit 1;
    };
    print {$hf} JSON::PP->new->canonical->encode(\%rec);
    close $hf;
}
open(my $rf, '>', $readypath) or exit 1;
print {$rf} $$;
close $rf;
Time::HiRes::sleep($hold_s || 0);
close $fh;
exit 0;
HOLDER
    close $fh;
}

# spawn_holder(%o) -> ($lockpath, $holderpath, $readypath, $child_pid_from_ready)
# Spawns raw-holder.pl as a genuinely separate OS process, backgrounded via
# the POSIX-shell "&" this host's perl already relies on (see the other three
# tests in this package for the same idiom). Blocks (boundedly) until the
# ready sentinel appears, so the caller never races the holder's own open+
# flock.
sub spawn_holder {
    my (%o) = @_;
    my $target     = $o{target}   // new_target();
    my $hold_s     = $o{hold_s}   // 2;
    my $with_id    = $o{with_identity} ? 1 : 0;
    my $verb       = $o{verb} // '';
    my $n          = ++$target_n;
    my $lockpath   = "$target.lock";
    my $holderpath = $with_id ? "$target.lock.holder" : '-';
    my $readypath  = "$WORK/ready-holder-$n";
    my $logpath    = "$WORK/holder-log-$n";
    system(qq{perl "$HOLDER_PL" "$lockpath" "$holderpath" "$hold_s" "$readypath" "$verb" > "$logpath" 2>&1 &});
    my $up = bounded_wait_for_file($readypath, 10);
    unless ($up) {
        diag("holder never signalled readiness within 10s (target=$target)");
        diag("holder log: " . (do { local $/; open my $lf, '<', $logpath; $lf ? <$lf> : '(no log)' }));
        return (undef, $target, $lockpath, $holderpath, $readypath);
    }
    open(my $rf, '<', $readypath); local $/; my $ready_body = <$rf>; close $rf;
    my $child_pid = ($ready_body =~ /^(\d+)$/) ? $1 : undef;
    return ($child_pid, $target, $lockpath, $holderpath, $readypath);
}

sub grep_lines {
    my ($file, $regex) = @_;
    my @hits;
    open(my $fh, '<', $file) or return \@hits;
    my $n = 0;
    while (my $line = <$fh>) {
        $n++;
        next if $line =~ /^\s*#/;
        push @hits, "$file:$n: $line" if $line =~ $regex;
    }
    close $fh;
    return \@hits;
}

# =============================================================================
# AC-8(a) -- the uncontended path is fast.
# =============================================================================
{
    my $t = new_target();
    my $t0 = Time::HiRes::time();
    my ($lock, $err, $died) = try_acquire($t);
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    ok(defined $lock, 'AC-8a: acquire() on a free target succeeds')
        or diag($err ? "kind=$err->{kind} message=$err->{message}" : "died: $died");
    ok($elapsed_ms < 100, sprintf('AC-8a: uncontended acquire completes in under 100ms (took %.1fms)', $elapsed_ms));
    ok(!defined($lock) || (eval { $lock->held } ? 1 : 0), 'AC-8a: $lock->held is true immediately after a successful acquire')
        if defined $lock;
    try_release($lock);
}

# =============================================================================
# AC-8(b) -- timeout_ms => 0 on a contended target makes exactly one attempt.
# =============================================================================
{
    my ($pid, $target, $lockpath) = spawn_holder(hold_s => 1.5);
    my ($lock, $err, $died) = try_acquire($target, timeout_ms => 0);
    ok(!defined $lock, 'AC-8b: acquire(timeout_ms=>0) on a contended target does not succeed');
    is($err->{kind}, 'timeout', 'AC-8b: ...and the failure kind is timeout') if $err;
    fail('AC-8b: ...and the failure kind is timeout') unless $err;
    ok(defined($err) && $err->{waited_ms} < 250, 'AC-8b: waited_ms < 250 -- exactly one non-blocking attempt')
        or diag($err ? "waited_ms=$err->{waited_ms}" : "no \$err returned (died: $died)");
}

# =============================================================================
# AC-8(c) -- env var precedence: explicit > env > default; a bad env value is
# ignored silently rather than breaking every write.
# =============================================================================
{
    for my $bad ('banana', '-5', '') {
        my ($pid, $target) = spawn_holder(hold_s => 0.4);
        local $ENV{ALMANAC_LOCK_TIMEOUT_MS} = $bad;
        my ($lock, $err, $died) = try_acquire($target);
        ok(defined $lock,
            "AC-8c: ALMANAC_LOCK_TIMEOUT_MS=" . (length($bad) ? $bad : '(empty)')
          . " is ignored -- the 10s default easily outlasts a 0.4s hold, so acquire succeeds")
            or diag($err ? "kind=$err->{kind} waited_ms=$err->{waited_ms}" : "died: $died");
        try_release($lock);
    }
    {
        my ($pid, $target) = spawn_holder(hold_s => 3);
        local $ENV{ALMANAC_LOCK_TIMEOUT_MS} = '350';
        my ($lock, $err, $died) = try_acquire($target);
        ok(!defined $lock, 'AC-8c: ALMANAC_LOCK_TIMEOUT_MS=350 actually takes effect -- a 3s hold outlasts it');
        if ($err) {
            is($err->{kind}, 'timeout', 'AC-8c: ...and it is a genuine timeout');
            ok($err->{waited_ms} >= 300 && $err->{waited_ms} <= 1500,
               "AC-8c: waited_ms ($err->{waited_ms}) is close to the 350ms env value, not the 10000ms default");
        } else {
            fail('AC-8c: env=350 -- expected a timeout $err hashref');
            fail('AC-8c: env=350 -- expected waited_ms close to 350, not 10000');
        }
    }
    {
        my ($pid, $target) = spawn_holder(hold_s => 3);
        local $ENV{ALMANAC_LOCK_TIMEOUT_MS} = '350';
        my ($lock, $err, $died) = try_acquire($target, timeout_ms => 120);
        ok(!defined $lock, 'AC-8c: an explicit timeout_ms beats both the env var and the default');
        if ($err) {
            ok($err->{waited_ms} >= 90 && $err->{waited_ms} <= 700,
               "AC-8c: waited_ms ($err->{waited_ms}) reflects the explicit 120ms, not the 350ms env value");
        } else {
            fail('AC-8c: explicit timeout_ms=>120 -- expected a timeout $err hashref');
        }
    }
}

# =============================================================================
# AC-9 -- reentrancy is refused immediately, not deadlocked.
# =============================================================================
{
    my $t = new_target();
    my $lockpath = "$t.lock";
    my ($lock1, $err1) = try_acquire($t);
    my $t0 = Time::HiRes::time();
    my ($lock2, $err2, $died2) = try_acquire($t);
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    ok(!defined $lock2, 'AC-9: a second acquire() on the same target, same process, does not succeed')
        or diag('a second in-process acquire silently succeeded -- reentrancy was not refused');
    is($err2->{kind}, 'reentrant', 'AC-9: ...and the failure kind is reentrant') if $err2;
    fail('AC-9: ...and the failure kind is reentrant') unless $err2;
    ok($elapsed_ms < 250, sprintf('AC-9: the reentrant refusal is immediate (%.1fms), not a stall for the deadline', $elapsed_ms));

    # The first lock must still be held afterwards: a raw, independent,
    # non-blocking flock attempt against the same lock path must FAIL.
    my $still_held = 0;
    if (open(my $probe, '>', $lockpath)) {
        $still_held = flock($probe, LOCK_EX | LOCK_NB) ? 0 : 1;
        flock($probe, LOCK_UN) unless $still_held; # don't leave a lock we grabbed by accident
        close $probe;
    }
    ok($still_held, 'AC-9: the FIRST lock is still genuinely held after the refused second acquire');
    try_release($lock1);
}

# =============================================================================
# AC-10 -- process death mid-hold needs no reaping.
# =============================================================================
{
    my ($pid, $target, $lockpath) = spawn_holder(hold_s => 0.3);
    ok(defined $pid, 'AC-10: the holder child reported readiness with its own pid');
    ok(-e $lockpath, 'AC-10: the lock file exists while the holder holds it');
    # Deterministic wait for the child's own known hold duration, plus a
    # buffer, rather than waitpid (the child is not this process's child --
    # it was shell-backgrounded, per spec section 6.1).
    Time::HiRes::sleep(0.3 + 0.4);

    my $t0 = Time::HiRes::time();
    my ($lock, $err, $died) = try_acquire($target, timeout_ms => 2000);
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    ok(defined $lock, 'AC-10: acquire() after the holder died (no release call) succeeds -- no reaping needed')
        or diag($err ? "kind=$err->{kind}" : "died: $died");
    ok($elapsed_ms < 250, sprintf('AC-10: ...and it succeeds fast (%.1fms), on essentially the first attempt', $elapsed_ms));
    ok(-e $lockpath, 'AC-10: the lock file STILL exists on disk -- it was never removed (C4)');
    try_release($lock);
}

# =============================================================================
# AC-5 -- a contended acquire is bounded and does not hang.
# =============================================================================
{
    my ($pid, $target) = spawn_holder(hold_s => 6);
    my ($lock, $err, $died) = try_acquire($target, timeout_ms => 1500);
    ok(!defined $lock, 'AC-5: acquire(timeout_ms=>1500) against a 6s hold does not succeed');
    if ($err) {
        is($err->{kind}, 'timeout', 'AC-5: ...and the failure kind is timeout');
        ok($err->{waited_ms} >= 1450, "AC-5: waited_ms ($err->{waited_ms}) >= 1450 -- it genuinely waited");
        ok($err->{waited_ms} <= 4000, "AC-5: waited_ms ($err->{waited_ms}) <= 4000 -- generous upper bound, deliberately loose");
    } else {
        fail('AC-5: expected a timeout $err hashref');
        fail('AC-5: expected waited_ms >= 1450');
        fail('AC-5: expected waited_ms <= 4000');
    }
}

# =============================================================================
# AC-6 -- no `alarm`, anywhere, in either file this package touches.
# =============================================================================
for my $file ($LOCK_PM, $A) {
    if (-f $file) {
        my @hits;
        push @hits, @{ grep_lines($file, qr/\balarm\b/) };
        push @hits, @{ grep_lines($file, qr/SIGALRM/) };
        push @hits, @{ grep_lines($file, qr/\$SIG\{\s*ALRM\s*\}/) };
        unless (ok(@hits == 0, "AC-6: no alarm/SIGALRM/\$SIG{ALRM} usage in $file")) {
            diag($_) for @hits;
        }
    } else {
        fail("AC-6: $file must exist to be scanned for alarm/SIGALRM usage");
    }
}

# =============================================================================
# AC-7 -- the deadline is implemented as LOCK_NB polling, in Lock.pm.
# =============================================================================
if (-f $LOCK_PM) {
    open(my $fh, '<', $LOCK_PM) or die;
    local $/;
    my $src = <$fh>;
    close $fh;
    ok($src =~ /LOCK_EX\s*\|\s*LOCK_NB/, 'AC-7: Lock.pm contains LOCK_EX|LOCK_NB together');
    ok($src =~ /Time::HiRes/, 'AC-7: Lock.pm imports Time::HiRes');
    my @bad;
    for my $line (split /\n/, $src) {
        next if $line =~ /^\s*#/;
        push @bad, $line if $line =~ /flock\s*\([^)]*LOCK_EX/ && $line !~ /LOCK_NB/;
    }
    unless (ok(@bad == 0, 'AC-7: no bare blocking flock(...LOCK_EX) without LOCK_NB on the same expression')) {
        diag($_) for @bad;
    }
} else {
    fail('AC-7: Lock.pm must exist to verify it contains LOCK_EX|LOCK_NB together');
    fail('AC-7: Lock.pm must exist to verify it imports Time::HiRes');
    fail('AC-7: Lock.pm must exist to verify no bare blocking flock(...LOCK_EX) without LOCK_NB');
}

# =============================================================================
# AC-11 -- the timeout names the holder, read from the separate identity file.
# =============================================================================
{
    my ($pid, $target, $lockpath, $holderpath) = spawn_holder(hold_s => 2, with_identity => 1, verb => 'update');
    ok(defined $pid, 'AC-11: the identity-writing holder child reported readiness');

    my ($lock, $err, $died) = try_acquire($target, timeout_ms => 800);
    ok(!defined $lock, 'AC-11: acquire times out against the identity-writing holder');
    if ($err) {
        is($err->{kind}, 'timeout', 'AC-11: ...timeout kind');
        ok(defined $err->{holder}, 'AC-11: $err->{holder} is defined')
            or diag('no holder record surfaced on timeout');
        if (defined $err->{holder}) {
            is($err->{holder}{pid}, $pid, 'AC-11: holder pid matches the real child pid');
            is($err->{holder}{host}, Sys::Hostname::hostname(), 'AC-11: holder host matches this machine');
            like($err->{holder}{acquired_at}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
                 'AC-11: holder acquired_at is ISO-8601 Z');
        } else {
            fail('AC-11: holder pid matches the real child pid');
            fail('AC-11: holder host matches this machine');
            fail('AC-11: holder acquired_at is ISO-8601 Z');
        }
        like($err->{message}, qr/\Q$pid\E/, 'AC-11: the message names the holder pid');
        like($err->{message}, qr/\Q@{[Sys::Hostname::hostname()]}\E/, 'AC-11: the message names the holder host');
        like($err->{message}, qr/\Q$holderpath\E/, 'AC-11: the message names the holder-file path');
        like($err->{holder_path}, qr/\.lock\.holder$/, 'AC-11: holder_path ends in .lock.holder');
        isnt($err->{holder_path}, $err->{lock_path}, 'AC-11: holder_path is NOT the same path as lock_path');
    } else {
        fail('AC-11: expected a timeout $err hashref') for 1 .. 7;
        diag("died: $died") if $died;
    }
}

# =============================================================================
# AC-12 -- the lock file cannot carry identity, demonstrated.
# =============================================================================
{
    my ($pid, $target, $lockpath, $holderpath) = spawn_holder(hold_s => 1.5, with_identity => 1, verb => 'append');
    ok(defined $pid, 'AC-12: the identity-writing holder child reported readiness');

    is(-s $lockpath, 0, 'AC-12: while held, <t>.lock is exactly zero bytes (it is opened truncating)');
    ok((-s $holderpath // 0) > 0, 'AC-12: while held, <t>.lock.holder is non-empty');

    my ($lock, $err) = try_acquire($target, timeout_ms => 500);
    ok(!defined $lock, 'AC-12: a waiter against this holder times out (500ms < the 1.5s hold)');

    is(-s $lockpath, 0, 'AC-12: AFTER the waiter times out, <t>.lock is STILL zero bytes');
    my $rec = try_read_holder($target);
    ok(defined $rec, 'AC-12: AFTER the waiter times out, read_holder() still returns a record')
        or diag('read_holder returned undef -- the waiter\'s truncating open destroyed the identity, or read_holder is unimplemented');
    is($rec->{pid}, $pid, 'AC-12: ...and it is STILL the original holder\'s record, unchanged') if $rec;
    fail('AC-12: ...and it is STILL the original holder\'s record, unchanged') unless $rec;

    # read_holder must read holder_path_for($target), never lock_path_for($target).
    my $t2 = new_target();
    my $lockpath2 = "$t2.lock";
    open(my $lf, '>', $lockpath2) or die;
    print {$lf} JSON::PP->new->canonical->encode({ pid => 99999, host => 'nobody', script => 'x',
                                                    verb => undef, target => $t2,
                                                    acquired_at => '2026-01-01T00:00:00Z',
                                                    acquired_at_epoch => 1 });
    close $lf;
    ok(!-e "$t2.lock.holder", 'AC-12: fixture sanity -- no holder file exists for this second target');
    my $rec2 = try_read_holder($t2);
    ok(!defined $rec2,
       'AC-12: read_holder() returns undef when only <t>.lock exists (even hand-filled with valid JSON) '
     . 'and <t>.lock.holder does not -- proving it reads the holder path, not the lock path');
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
