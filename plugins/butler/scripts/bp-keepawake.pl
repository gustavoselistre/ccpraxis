#!/usr/bin/env perl
# bp-keepawake.pl — the wake-lock, shared by every long-running butler driver.
#
# WHY THIS FILE EXISTS AS A FILE.
#
# The keep-awake mechanism was implemented in bp-drive-next.pl, for the SOLO
# driver — the path where a human is sitting in the session and would notice a
# suspended host. The FLEET orchestrator, which runs headless coordinators for
# hours with nobody watching, held no wake-lock at all. The lock existed on the
# path that needs it least and was absent from the one that needs it most.
#
# That is not hypothetical. 3c661a0 records a host suspending mid-run: a
# watchdog armed for 1800s reported 7962s elapsed (2h13m). It fixed solo only.
#
# The obvious fix — copy the six helpers into bp-orchestrator.pl — is the same
# mistake this repo has already paid for twice: match_any lives in two files and
# needed t/108 to guard the copies, and the token floor lived in three places
# (one of them an invisible default), which is exactly how the keeper silently
# ran a 1-hour floor for hours after the gate had moved to ten minutes. So the
# wake-lock gets ONE definition and both drivers call it.
#
# WHAT IT ACTUATES. The sandbox plugin's keep-awake.ps1, rather than
# re-deriving the P/Invoke. Both plugins ship from the same tree, so the relative
# path holds in the clone, in the live install, and under the container's
# marketplace mount.
#
# THIS BLOCK USED TO REPEAT THE HELPER'S CLAIM that ES_DISPLAY_REQUIRED is
# load-bearing on Modern Standby. MEASURED FALSE 2026-09-17 and dropped from the
# helper: the machine entered connected standby with that request held and
# refreshing, for "Reason: Idle Timeout", which no ES_* flag addresses. The
# reasoning now lives in ONE place -- keep-awake.ps1's header -- rather than
# being restated here, because a claim copied into a second file is a claim that
# gets corrected in only one of them. Read it there.
#
# WE PASS -PidFile, AND THE REASON MATTERS — the opposite choice leaked 2.7 GB.
#
# The original comment here said we deliberately did NOT pass it, because "it
# would write its own Windows pid over ours". That is exactly backwards, and it
# was measured on 2026-08-13: 52 orphaned keep-awake PowerShells, ~52 MB each,
# holding 2.7 GB and 52 simultaneous ES_CONTINUOUS wake-locks.
#
# On Git-for-Windows perl, fork() is EMULATED with threads and returns a
# PSEUDO-process id (447298, say) that is meaningful only inside the perl
# process that created it. Every `bp-drive-next.pl next` is a FRESH perl
# process, so its `kill(0, $pid)` against a pseudo-pid written by some earlier
# process always fails. The idempotency check therefore never fired: each
# invocation concluded "no live lock" and spawned another one, and the release
# path could not kill the old one either, for the same reason. The mechanism
# leaked one PowerShell per invocation, forever.
#
# The helper's own $PID is a REAL Windows pid, valid across processes, and
# keep-awake.ps1 removes the file on exit — so a stale file means a dead helper
# and correctly triggers a respawn. That is the identity we need. Ours never was.
#
# Degrades honestly: no Windows, no helper, or a failed fork means no lock and a
# logged warning — never a false claim of holding one. That failure mode is the
# whole reason 3c661a0 exists (the production spawn/kill defaults were empty
# subs, so the director REPORTED managing a lock while holding none).

package BpKeepAwake;
use strict;
use warnings;
use File::Basename qw(dirname);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Errno ();
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# STARTING_GRACE_SECONDS — how long a pid file with no pid in it counts as "a
# helper is coming up" rather than "nothing is here".
#
# THE HOLE THIS CLOSES, MEASURED 2026-09-15: fifteen live keep-awake.ps1
# helpers from a single registry, and the machine kept awake by all of them.
# spawn() returns as soon as the fork+exec is away, but keep-awake.ps1 does not
# write its own pid until PowerShell has started — of the order of a second, and
# more on a loaded box. Every apply() inside that window saw no pid file at all,
# concluded "no lock here", and spawned another. The idempotence check was
# perfect and simply had nothing to look at yet.
#
# So spawning now CLAIMS the pid file first, and an unfilled claim is read as
# "starting". 30s is far beyond any plausible PowerShell start and far short of
# the 900s lease, so a helper that truly failed to come up is still replaced
# long before its absence could matter.
our $STARTING_GRACE_SECONDS = 30;

# Read it through this rather than as $BpKeepAwake::STARTING_GRACE_SECONDS from
# another file. This is `require`d at RUNTIME, so a fully-qualified read
# elsewhere compiles before the `our` exists and perl warns "used only once:
# possible typo" — a warning that is indistinguishable from a real typo, which
# is the whole reason not to leave it standing.
sub starting_grace_seconds { return $STARTING_GRACE_SECONDS }

# should_be_on($phase) -> 0|1
# active / pause-pending -> hold the lock; settled -> release it.
# A timed pause still holds it: the whole point is to be awake when it ends.
sub should_be_on {
    my ($phase) = @_;
    return (defined $phase && ($phase eq 'active' || $phase eq 'pause-pending')) ? 1 : 0;
}

sub helper_path { return "$DIR/../../sandbox/scripts/keep-awake.ps1" }

# POSIX -> forward-slash Windows form ("/c/x" -> "C:/x").
#
# Hand-translated on purpose. powershell.exe accepts this form whether or not
# MSYS2 path conversion is active, so the result is correct under EITHER
# conversion state — the technique CLAUDE.md prefers, because it cannot be
# broken by a caller's environment. Do NOT "simplify" this by setting
# MSYS2_ARG_CONV_EXCL instead: the opt-out and the translation are one
# technique, and splitting them is how paths end up created at the drive root.
sub winify {
    my ($p) = @_;
    $p = Cwd::abs_path($p) // $p;
    $p =~ s{\\}{/}g;
    $p =~ s{^/([a-zA-Z])/}{\u$1:/};
    return $p;
}

# winify for a path that does NOT exist yet (an output file). abs_path returns
# undef for a missing leaf, which would leave a POSIX "/c/..." string to hand a
# native binary — and Windows resolves a leading "/" against the current drive,
# creating it at the DRIVE ROOT. That is the 576-stray incident in CLAUDE.md, so
# resolve the parent directory (which does exist) and re-attach the basename.
sub winify_out {
    my ($p) = @_;
    $p =~ s{\\}{/}g;
    my ($dir, $leaf) = $p =~ m{^(.*)/([^/]+)$} ? ($1, $2) : ('.', $p);
    my $abs = Cwd::abs_path($dir);
    return winify($p) unless defined $abs;   # parent missing too: best effort
    $abs =~ s{\\}{/}g;
    $abs =~ s{^/([a-zA-Z])/}{\u$1:/};
    return "$abs/$leaf";
}

# Detect whether powershell.exe is resolvable.
#
# BY SEARCHING PATH, NOT BY RUNNING IT. The previous form answered this question
# by actually spawning `powershell.exe -Command "exit 0"` -- so the act of asking
# cost a powershell.exe plus the conhost.exe Windows attaches to it. Combined
# with the ordering bug in apply() (probe before idempotence check), that is what
# buried the operator's machine in processes on 2026-08-13 and forced a restart.
#
# Resolvability is a property of PATH, and PATH can be read. Nothing needs to be
# executed to answer it.
#
# Memoized: within one process the answer cannot change, and this is called from
# a path that runs on every director tick.
my $_PS_AVAILABLE;
sub ps_available {
    # Windows-only concern; in the Linux sandbox this is a documented no-op.
    return 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return $_PS_AVAILABLE if defined $_PS_AVAILABLE;

    # PATHEXT is irrelevant here -- we look for an explicit .exe. Split on the
    # host separator: MSYS perl reports a ';'-joined PATH on Windows, but a
    # ':'-joined one is possible under some shells, so accept either.
    my $path = $ENV{PATH} // '';
    my @dirs = split /;/, $path;
    @dirs = split /:/, $path if @dirs <= 1;
    for my $d (@dirs) {
        next unless length $d;
        $d =~ s{\\}{/}g;
        $d =~ s{/+$}{};
        if (-x "$d/powershell.exe" || -e "$d/powershell.exe") {
            return $_PS_AVAILABLE = 1;
        }
    }
    return $_PS_AVAILABLE = 0;
}

# spawn($pid_file) -> pid | undef. DIES if the helper is missing or fork fails.
sub spawn {
    my ($pid_f) = @_;
    return undef unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    # A TEST MUST NEVER SPAWN A REAL, IMMORTAL OS WAKE-LOCK.
    #
    # Measured 2026-08-14, on the operator's machine, mid-session: 67 live
    # powershell.exe, 53 of them keep-awake.ps1 helpers whose -PidFile pointed
    # into TEST fixture directories (bp/, bp2/, bp-orphan/, bp-done/ under a
    # File::Temp root). bp-orchestrator.pl:2250 calls apply() with only a `log`
    # seam -- no `spawn` seam -- so the REAL spawn runs, and t/orchestrator-decision-core.t
    # drives that path. Every run of the butler suite leaked several helpers that
    # then slept forever. Running the suite repeatedly is what filled the machine.
    #
    # This is the same rule CLAUDE.md already states for launcher.pl ("never let
    # a test spawn it unguarded"), one level over: the wake-lock helper is an OS
    # process that outlives the test that made it.
    #
    # $0 is the script perl is running, and every test here is a .t run directly
    # (there is no prove on this host). Tests that legitimately exercise spawning
    # inject their own seam and never reach this sub, so nothing is lost -- and a
    # test that DID reach the real spawn was, by definition, leaking.
    return undef if $ENV{CCPRAXIS_NO_WAKELOCK};
    return undef if defined $0 && $0 =~ /\.t\z/;

    my $ps1 = helper_path();
    unless (-f $ps1) { die "keep-awake helper missing: $ps1\n" }
    require POSIX;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        # -LeaseSeconds: butler's callers (the orchestrator's per-tick apply(),
        # and drive-solo's) REFRESH the pid file on every tick that finds a live
        # lock, so this path is safe to lease -- and leasing it means an orphan
        # from a crashed driver, a forced restart or a WSL VM kill self-expires
        # within the lease instead of holding the display awake until reboot.
        #
        # The lease is opt-in precisely because launcher.pl's dashboard holder
        # does NOT refresh; it passes no lease and keeps hold-until-killed.
        exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-File', winify($ps1),
             '-PidFile', winify_out($pid_f),
             '-LeaseSeconds', '900')
            or POSIX::_exit(127);
    }
    # The parent writes NOTHING. Writing perl's fork return value here is the
    # leak described in the header: it is a pseudo-pid no other process can
    # validate, so every later invocation respawns. The helper writes its own
    # real Windows pid into $pid_f a moment from now, and removes it on exit.
    return $pid;
}

sub kill_pid {
    my ($pid) = @_;
    return unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    kill('KILL', $pid);
    waitpid($pid, 0);
}

# _pid_alive($pid) -> 0|1
#
# perl's kill(0,$pid) is NOT a usable liveness test on Windows for a process
# perl did not create. Git-for-Windows perl can signal its own children and
# pseudo-processes; against an unrelated native pid — which is exactly what the
# keep-awake helper is — it reports "dead" for a perfectly healthy process.
#
# That was the second half of the 2026-08-13 leak, and it hid behind the first:
# fixing the recorded pid alone changed nothing, because the CHECK was broken
# too. Measured directly — with a real, running helper pid in the file, two
# further invocations still spawned two more locks.
#
# So on Windows, ask Windows. tasklist costs one process per invocation, which
# at this cadence (once per director tick) is nothing next to leaking a 52 MB
# PowerShell forever.
sub _pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 1 if kill(0, $pid);                 # own child / pseudo-process
    # MSYS2 path conversion rewrites the SWITCHES: `/FI` arrives at tasklist as
    # `C:/Program Files/Git/FI` and it exits with "Invalid argument/option".
    # Measured, not guessed. Scope the opt-out to this one call (CLAUDE.md's
    # sanctioned form) — safe here because we pass no paths at all, so there is
    # nothing for the conversion to have been protecting.
    #
    # NO stderr redirect on purpose either: Git-for-Windows perl runs backticks
    # through sh, where `2>NUL` creates a literal file named NUL that Explorer
    # cannot delete (house rule), and `2>/dev/null` would be wrong if backticks
    # ever went through cmd.exe instead. tasklist's stderr is harmless.
    my $out = do {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        `tasklist /FI "PID eq $pid" /NH`;
    };
    return 0 unless defined $out;
    return ($out =~ /\b\Q$pid\E\b/) ? 1 : 0;
}

# Public aliases for the two helpers above.
#
# BpContinuityLease needs exactly these facts — "is this recorded pid alive"
# and "what pid is recorded" — and both are already solved HERE, correctly, for
# the one platform that gets them wrong (see _pid_alive's header on why
# kill(0,$pid) lies about a native Windows process). Reaching into the
# underscore names from another package would be worse than either copying or
# exporting; copying is what this repo has paid for three times already. So they
# get a supported spelling instead.
sub pid_alive { return _pid_alive(@_) }
sub read_pid  { return _read_pid(@_)  }

sub _read_pid {
    my ($pid_f) = @_;
    open my $fh, '<', $pid_f or return undef;
    my $t = do { local $/; <$fh> };
    close $fh;
    return ($t && $t =~ /^(\d+)/) ? $1 : undef;
}

# apply($phase, $dir, \%opts) — idempotent. $dir is where keepawake.pid lives.
#
# %opts seams (all optional; production defaults actuate for real):
#   spawn / kill_pid / powershell_available — injectable for tests
#   log — coderef ->($message), so each driver logs to its own place
sub apply {
    my ($phase, $dir, $opts) = @_;
    $opts //= {};
    my $spawn = $opts->{spawn}                // \&spawn;
    my $killp = $opts->{kill_pid}             // \&kill_pid;
    my $ps_ok = $opts->{powershell_available} // \&ps_available;
    my $log   = $opts->{log}                  // sub { };
    my $pid_f = "$dir/keepawake.pid";

    if (should_be_on($phase)) {
        # ORDER IS LOAD-BEARING: idempotence FIRST, availability probe second.
        #
        # It used to be the other way round, and that cost the operator a forced
        # machine restart on 2026-08-13 -- "a zillion powershell processes and
        # conhost processes", terminals unusable. ps_available() is not a cheap
        # predicate: it SPAWNS `powershell.exe -Command "exit 0"`, and Windows
        # gives every one of those its own conhost.exe. Probing before the
        # idempotence check meant the steady state -- lock already alive, nothing
        # to do -- still paid two process creations per call, and _pid_alive's
        # tasklist adds two more. The Stop hook calls the director on EVERY turn
        # end, so "per call" is not rare.
        #
        # Reordering makes the common path spawn nothing at all: if a live lock
        # exists we return before asking whether powershell is even present. The
        # probe now runs only when we are actually about to spawn, which is the
        # only moment its answer can change what we do.
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            if (_pid_alive($pid)) {
                # REFRESH THE LEASE. The pid file is a heartbeat as well as an
                # identity: keep-awake.ps1 polls its mtime and exits once it goes
                # stale (-LeaseSeconds, default 900). Touching it here -- on the
                # very tick that finds a live lock and leaves it alone -- is what
                # says "a run still wants this".
                #
                # Without this the lease would be a bug, not a safety net: it
                # would reap perfectly healthy locks mid-run. With it, the ONLY
                # locks that expire are the ones nobody is refreshing, which is
                # exactly the orphan case -- a driver that crashed, a forced
                # restart, a WSL VM kill. Before the lease, such a lock held
                # ES_DISPLAY_REQUIRED and kept the machine awake until reboot.
                my $now = time;
                utime($now, $now, $pid_f);
                return;
            }

            # An EMPTY pid file is a claim this code made just before spawning,
            # and the helper has not yet written itself into it. That is a lock
            # STARTING, not a lock missing — see $STARTING_GRACE_SECONDS for the
            # fifteen-helper storm that reading it the other way caused.
            #
            # -z, not !defined $pid: a file with unparseable CONTENT is corrupt,
            # not starting. Nothing is coming to fix it, so it is replaced now
            # rather than after a grace period spent waiting for nobody.
            if (-z $pid_f) {
                my $age = time - ((stat($pid_f))[9] // 0);
                return if $age < $STARTING_GRACE_SECONDS;
                $log->("WARN keepawake claim never filled after ${age}s; respawning");
            }

            # Either a recorded pid that is dead, or a claim that expired. Clear
            # it so the atomic claim below can be taken.
            unlink $pid_f;
        }
        return unless $ps_ok->();

        # CLAIM THE FILE ATOMICALLY, THEN SPAWN. O_EXCL is what makes "is a
        # helper already coming up?" and "I am the one starting it" a single
        # indivisible step, so the window between spawning and the helper
        # writing its own pid can no longer be read by anyone else as "nothing
        # here". That window is where the fifteen helpers came from.
        #
        # It does NOT make the whole function atomic, and it is not claimed to:
        # two callers that both find a DEAD pid recorded can both unlink it just
        # above and then both take a fresh claim in turn. Closing that would need
        # a lock around the read-decide-write as a whole. It is left open because
        # the caller-side rule removes it — only the refresher ever asks for a
        # hold, and it is single-instance by flock — and because the outcome
        # there is two helpers, not fifteen, with the loser's lease expiring.
        my $claim;
        unless (sysopen($claim, $pid_f, O_WRONLY | O_CREAT | O_EXCL)) {
            # EEXIST is the ordinary outcome of losing that race, and it is not
            # a problem — stay silent. Anything else (an unwritable registry, a
            # full disk) means no wake-lock will EVER be taken here, which is
            # exactly the kind of failure that must not be invisible.
            $log->("WARN keepawake cannot claim $pid_f: $!") unless $!{EEXIST};
            return;
        }
        close $claim;

        my $started = eval { $spawn->($pid_f) };
        $log->("WARN keepawake spawn failed: $@") if $@;

        # A CLAIM NOBODY WILL FILL MUST NOT SURVIVE THE CALL THAT MADE IT.
        # spawn() returns undef when it declined — inside a .t, or under
        # CCPRAXIS_NO_WAKELOCK — and it dies when the fork or the helper file
        # fails. Either way nothing is coming, so leaving the claim would both
        # suppress the next 30s of attempts and, worse, fabricate the appearance
        # of a lease: t/runstate-pause-holds-lease.t pins exactly that ("a pause
        # never fabricates a lease from a test process"), and it caught this.
        unlink $pid_f if !defined $started && -e $pid_f && -z $pid_f;
    } else {
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            # NOT liveness-checked before the kill, deliberately, and this was
            # reconsidered on 2026-08-14 rather than assumed.
            #
            # A stale pid file is the normal residue of a hard kill (the helper
            # removes its own file on exit), and Windows reuses pids -- so the
            # recorded number can belong to an unrelated process. That argues for
            # checking liveness first. Two things outweigh it. Perl cannot signal
            # a native Windows process it did not create -- the same asymmetry
            # _pid_alive exists to work around -- so an unconditional kill against
            # a reused pid is very nearly a no-op here. And _pid_alive costs a
            # tasklist spawn, which is exactly the process pressure the rest of
            # this file was just fixed to stop paying.
            #
            # t/111 and t/17 both pin "release kills the recorded pid" with a
            # synthetic pid; adding the check silently broke both. Changing that
            # contract needs to be a decision, not a side effect of a perf fix.
            if (defined $pid) {
                eval { $killp->($pid) };
                $log->("WARN keepawake kill failed: $@") if $@;
            }
            unlink $pid_f;
        }
    }
}

package main;
1;
