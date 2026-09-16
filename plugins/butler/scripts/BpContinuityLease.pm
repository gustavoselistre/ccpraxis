package BpContinuityLease;
# BpContinuityLease — hold the machine/container awake for as long as a session
# is ARMED FOR CONTINUITY, and release it when it is turned off.
#
# THE HOLE THIS FILLS.
#
# Every other long-running butler driver holds a wake-lock: bp-drive-next.pl and
# bp-orchestrator.pl both call BpKeepAwake::apply, and the fleet orchestrator
# also refreshes the busy-lease (/tmp/.butler-busy) that keeps a sandbox
# container from reaping itself and — through launcher.pl's dashboard probe —
# keeps the HOST awake behind it.
#
# `/butler:continuity on` held NEITHER. That is the exact inversion of
# bp-keepawake.pl's own founding complaint ("the lock existed on the path that
# needs it least and was absent from the one that needs it most"), one level
# further out: continuity arming exists PRECISELY for unattended work with no
# blueprint, no drive-solo and no reporter — i.e. for the sessions where nothing
# else is holding a lock, and nobody is sitting there to notice the host drop
# into connected standby or the container reap itself out from under the run.
#
# TWO SURFACES, ONE PER PLATFORM — and they are not alternatives.
#
#   Windows host      -> the wake-lock (BpKeepAwake -> keep-awake.ps1). There is
#                        no container to keep alive; the risk is S0 standby.
#   Linux (a sandbox) -> the busy-lease (/tmp/.butler-busy). There is no
#                        SetThreadExecutionState to call, and the risk is
#                        heartbeat.sh reaping the container. Touching the lease
#                        ALSO keeps the host awake, because launcher.pl's
#                        dashboard gates its own keep-awake on this very file's
#                        freshness (KeepAwake::should_stay_awake, BUSY_STALE 600s).
#
# So the same arm covers both worlds, and in the sandbox case it covers both
# ENDS of it — which is what "must work inside a sandbox and outside on the
# host" actually requires.
#
# There is a THIRD case, and it holds nothing: a Linux or macOS HOST. No
# SetThreadExecutionState, and no heartbeat.sh or dashboard reading
# /tmp/.butler-busy — so writing that file there would be a lease in name only,
# and state() would then report "held" off the file it had just created. That is
# the one thing bp-keepawake.pl's header forbids outright, so platform() names
# the case 'unsupported' and every branch returns honestly instead.
#
# HELD UNTIL TURNED OFF, not until the next lease expiry.
#
# Both mechanisms are deliberately LEASED rather than held-until-killed (see
# keep-awake.ps1's header for what an unleased orphan cost: ES_DISPLAY_REQUIRED
# held until reboot). A lease needs a refresher, and the refresher cannot be
# "whatever the agent happens to run next": a single turn can outlast the lease
# with no Stop hook and no `hold` tick in between, which is exactly the long
# unattended turn the lock exists to protect.
#
# So arming starts a detached refresher process (`bp-continuity.pl lease
# --daemon`) whose ONLY job is to re-assert both leases every tick for as long
# as any session is armed, and to release and exit once none is. Disarm does not
# have to kill it — it notices within a tick — but disarm re-syncs anyway so the
# release is immediate.
#
# WHY A SEPARATE PROCESS AND NOT A FORKED CHILD. On Git-for-Windows perl fork()
# is emulated with THREADS inside the same process, so a forked child dies the
# moment the parent perl exits — and the parent here is a one-shot Bash tool
# call. exec() from the pseudo-process starts a real, independent process that
# outlives it, which is the same mechanism keep-awake.ps1 already relies on.
# Verified end-to-end on this host: after `arm` returned, the daemon was still
# ticking and had brought the wake-lock up behind it.
#
# WHAT BOUNDS AN ABANDONED ARM. A session that dies without disarming leaves a
# marker behind, and the lease follows the marker: the refresher holds until
# nothing is armed, and the marker stops counting at the continuity TTL (12h by
# default, CCPRAXIS_CONTINUITY_TTL_H). So the worst case is a display held on for
# as long as the arm itself is still considered valid — and gate-continuity.sh
# usually reaps such a marker much sooner, on the next Stop of ANY session.
#
# That horizon is deliberate rather than merely inherited. A shorter one just
# for the lease would mean a session can be "armed but no longer protected",
# which is precisely the state this file exists to remove; the arm and the thing
# that keeps the arm workable expire together.
#
# ITS PID IS STILL NOT A LIVENESS TEST, THOUGH. MSYS perl's $$ is an MSYS pid,
# not a Windows one — measured: a live daemon recorded 16818 and tasklist knew
# no such task. So identity here is the pid FILE (a heartbeat, for cheap
# readers) plus an flock (for exclusion), and the recorded number is only ever
# something for a human to act on. See ensure_daemon and daemon_loop.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/bp-keepawake.pl";
require "$DIR/BpSession.pm";

# The refresher's cadence, and the pid-file heartbeat window derived from it.
# 60s is an order of magnitude inside both leases it refreshes (keep-awake.ps1's
# 900s, heartbeat.sh's 600s BUSY window), so a missed tick is never a dropped
# lock.
our $TICK_SECONDS = 60;

# STALE_TICKS — how many missed ticks make the daemon's pid file "dead" to a
# cheap mtime-only reader (gate-continuity.sh). Liveness by mtime rather than by
# pid is deliberate: bash cannot tell a live native Windows pid from a dead one
# (kill -0 lies there — see BpKeepAwake::_pid_alive), but a heartbeat file's age
# is the same fact on every platform and costs one stat.
our $STALE_TICKS = 5;
sub stale_ticks { return $STALE_TICKS }

# tick_seconds — the cadence, with an override for tests and for an operator
# debugging a holder.
#
# CLAMPED TO [1, $TICK_SECONDS]: the override may only make the refresher
# FASTER, never slower, and never zero. Both ends were found by red-teaming and
# both are real.
#
#   0 busy-spins. sleep(0) returns instantly, and with a live helper recorded
#     each iteration costs a tasklist — measured at 2.3s of system time in 3s of
#     wall clock, which is the 2026-08-13 process-storm signature exactly.
#
#   Too large decouples this from gate-continuity.sh, which must hardcode its
#     staleness window (300s = 60 * 5) because a hook cannot read a perl
#     constant. At tick=100000 the daemon asserts once and sleeps for a day
#     holding lease.lock, the gate calls its heartbeat stale on every Stop and
#     starts a replacement, and every replacement loses the flock and exits —
#     an unreplaceable zombie holding nothing. Capping at the default makes that
#     divergence unreachable instead of merely unlikely. The same skew arises
#     benignly whenever the agent's shell exports the var and the hook's
#     environment does not.
sub tick_seconds {
    my $t = $ENV{CCPRAXIS_CONTINUITY_LEASE_TICK};
    return $TICK_SECONDS unless defined $t && $t =~ /^\d+$/;
    return clamp_tick($t);
}

sub clamp_tick {
    my ($t) = @_;
    return $TICK_SECONDS unless defined $t && $t =~ /^\d+$/;
    return 1              if $t < 1;
    return $TICK_SECONDS  if $t > $TICK_SECONDS;
    return $t;
}

# The busy-lease freshness window. Must match heartbeat.sh's HB and
# launcher.pl's BUSY_STALE_SECS (both 600s) — it is the same file and the same
# question, asked from three sides.
our $BUSY_STALE_SECONDS = 600;

# $PLATFORM — a seam, not a setting. Every branch in this file is
# platform-selected, and a host can only ever run one of them; without a way to
# say "decide as if you were somewhere else", most of the logic would be
# verifiable only by running the suite on another OS, which is how branches
# drift apart. Tests set `local $BpContinuityLease::PLATFORM = 'posix'` (or
# 'windows', or 'unsupported'). Production never sets it; platform() answers.
our $PLATFORM;

# platform() -> 'windows' | 'posix' | 'unsupported'
#
#   windows      a Windows host. The wake-lock is the mechanism.
#   posix        INSIDE A CONTAINER. The busy-lease is the mechanism, and it is
#                read by heartbeat.sh and by launcher.pl's dashboard.
#   unsupported  a Linux or macOS HOST. Neither mechanism exists here: there is
#                no SetThreadExecutionState to call, and /tmp/.butler-busy is a
#                file nobody reads, so writing one would be a lease in name only.
#
# THE THIRD CASE IS NOT PEDANTRY. Without it, `sync` on a Linux host creates
# /tmp/.butler-busy and `state` then reports "held" off the file it just made —
# a lock reported as held that holds nothing, which is the single failure mode
# bp-keepawake.pl's header forbids outright. Saying "unsupported" is the honest
# answer, and it is also actionable: it tells an operator on such a host that
# arming does not keep their machine awake.
sub platform {
    return $PLATFORM if defined $PLATFORM;
    return 'windows' if $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 'posix'   if in_container();
    return 'unsupported';
}

sub is_windows { return platform() eq 'windows' ? 1 : 0 }

# in_container() — podman and docker both leave a marker at the filesystem root,
# and the sandbox image is built from one of them. Checked in that order and
# nothing else: an env var would be inherited by anything the container spawns
# on the host side, and a cgroup-path heuristic stopped being reliable with
# cgroup v2.
sub in_container {
    return 1 if -e '/run/.containerenv';   # podman
    return 1 if -e '/.dockerenv';          # docker
    return 0;
}

# The busy-lease path. Same default and same env override as the orchestrator's
# (bp-orchestrator.pl's BP_BUSY_PATH / '/tmp/.butler-busy') and the same file
# heartbeat.sh watches, ON PURPOSE: "a butler run is active" is one fact, and an
# armed continuity session is one of the things that makes it true.
sub busy_path { return $ENV{BP_BUSY_PATH} // '/tmp/.butler-busy' }

sub daemon_pid_file { my ($dir) = @_; return "$dir/lease.pid" }
sub wakelock_pid_file { my ($dir) = @_; return "$dir/keepawake.pid" }

# ttl_hours — mirrors bp_continuity_ttl_hours in hooks/lib.sh (12h, sanitised).
# A fourth leg of that rule, for the same reason the other three exist: this is
# perl, lib.sh is bash, and they must agree about when an arm has expired.
sub ttl_hours {
    my $h = $ENV{CCPRAXIS_CONTINUITY_TTL_H};
    return 12 unless defined $h && $h =~ /^\d+$/ && $h > 0;
    return $h;
}

# $FIND_TRANSCRIPT — a seam, not a setting, same shape as $PLATFORM above.
# Production never sets it; any_active() falls back to
# BpSession::find_transcript. Tests set
# `local $BpContinuityLease::FIND_TRANSCRIPT = sub { ... }` so the liveness
# filter can be exercised against fixture paths instead of the real
# ~/.claude/projects tree.
our $FIND_TRANSCRIPT;

# TRANSCRIPT_LIVENESS_SECONDS — how stale a resolved transcript may be before
# its session is treated as provably dead rather than merely quiet.
#
# Reuses BpSession::transcript_files' OWN precedent for this exact number: its
# default max_age is 3600, on the reasoning that a transcript untouched for an
# hour cannot be the one currently in use. The longest LEGITIMATE transcript
# silence here is bounded by the wake-up TTL (900s — a `hold` may not exceed
# it without refreshing), so 3600s leaves roughly 4x headroom over that while
# still being 12x tighter than the 12h marker TTL below. It is not the same
# question ensure_daemon's pid-file staleness asks (that is "is the refresher
# still ticking", answered every $TICK_SECONDS) and the two are not harmonised
# on purpose — different clocks, different owners.
our $TRANSCRIPT_LIVENESS_SECONDS = 3600;

# _marker_is_live($session_id) -> 1|0
#
# A READ-ONLY liveness filter, never a reaper: it only ever changes whether a
# marker counts toward "something is armed" in THIS process's answer, and
# never touches the marker file itself (see any_active's own header on why
# non-reaping is deliberate here). Resolution and the stat both fail SAFE —
# every undeterminable case answers "live" — mirroring vault-sync.pl's
# lock_holder_is_dead, which returns "not dead" on any errno it cannot
# interpret. Getting this backwards would turn a merely-quiet session into a
# released lock out from under a live one; getting the fail-open direction
# right just means the 12h TTL keeps doing the job it already did.
sub _marker_is_live {
    my ($session_id) = @_;
    my $find = $FIND_TRANSCRIPT // \&BpSession::find_transcript;
    my $path = eval { $find->($session_id) };
    return 1 if $@;              # the resolver itself blew up -- undeterminable
    return 1 unless defined $path && length $path;   # no transcript found

    my @st = stat($path);
    return 1 unless @st;         # stat failed -- undeterminable

    my $age = time() - $st[9];
    return 1 if $age < 0;        # future mtime: clock skew, not evidence of death
    return $age <= $TRANSCRIPT_LIVENESS_SECONDS ? 1 : 0;
}

# ---------------------------------------------------------------------------
# any_active($dir) -> 0|1
#
# Is ANY session on this machine currently armed? Registry-wide, not
# per-session, because the lease is a machine-level resource: two armed sessions
# share one wake-lock, and the last one to disarm is what releases it.
#
# Counts BOTH a bound primary marker and an unbound pending ticket. A ticket is
# an arm that has not yet learned which session it belongs to (see cmd_arm) —
# and the window before it binds is a full turn long, which is precisely a turn
# during which the machine must not sleep.
#
# DELIBERATELY NON-REAPING, unlike lib.sh's bp_continuity_any_active. That
# function is the reap point because it runs inside a Stop hook, where deleting
# an expired marker is part of the gate's own job. This one is read by a
# detached background process, and a background process quietly deleting other
# sessions' state is a much worse failure than one that merely stops holding a
# lock. Expiry is still honoured — a marker past the TTL does not count — so the
# lease releases at the right moment either way; the file is simply left for the
# next Stop hook to reap.
#
# A LIVENESS FILTER SITS ON TOP OF THE TTL, FOR THE SAME NON-REAPING REASON.
# A crashed session's marker is fresh by mtime — nothing touched it after the
# crash — so the 12h TTL alone holds the machine-global wake-lock for up to 12h
# past the crash, self-healing only when some UNRELATED session's Stop hook
# happens to sweep. _marker_is_live resolves the marker's basename (the
# session id) to its transcript via BpSession::find_transcript and skips the
# marker when that transcript is provably stale — never deletes it, exactly
# like the TTL check above. It is strictly additive: it can only make this
# function skip a marker the TTL would have counted, never count one the TTL
# already rejected, and every undeterminable case (no transcript, a failed
# stat, a future mtime) counts the marker as active, same as before this
# filter existed.
sub any_active {
    my ($dir) = @_;
    return 0 unless defined $dir && -d $dir;
    my $cutoff = time() - ttl_hours() * 3600;

    # Pending tickets are bounded by the SAME TTL as markers, not by the much
    # shorter wake-up TTL. A ticket binds at the next Stop, so a short bound
    # looks tempting — but a turn may legitimately run for hours before that
    # Stop arrives, and that is the exact turn this lease protects.
    if (opendir(my $pdh, "$dir/pending")) {
        while (defined(my $e = readdir $pdh)) {
            next if $e eq '.' || $e eq '..';
            my $f = "$dir/pending/$e";
            next unless -f $f;
            next if ((stat($f))[9] // 0) < $cutoff;
            closedir $pdh;
            return 1;
        }
        closedir $pdh;
    }

    # Primary markers are the dot-free basenames at the top level; everything
    # dotted is a companion (.wakeup-pending, .stop-blocks) or ours
    # (keepawake.pid, lease.pid). Same discrimination as lib.sh's sweep, which
    # is also why continuity_marker() refuses a dot in a session id.
    opendir(my $dh, $dir) or return 0;
    while (defined(my $e = readdir $dh)) {
        next if $e eq '.' || $e eq '..';
        next if index($e, '.') >= 0;
        my $f = "$dir/$e";
        next unless -f $f;
        next if ((stat($f))[9] // 0) < $cutoff;
        next unless _marker_is_live($e);
        closedir $dh;
        return 1;
    }
    closedir $dh;
    return 0;
}

# ---------------------------------------------------------------------------
# state($dir) -> 'held' | 'released'
#
# What is ACTUALLY asserted right now, read off the artifacts — not what the
# registry says ought to be. The distinction is the whole discipline of
# bp-keepawake.pl's header ("degrades honestly ... never a false claim of
# holding one"): a status line that reports the intent would say "held" on a
# machine whose helper died an hour ago, which is worse than saying nothing.
sub state {
    my ($dir, %opts) = @_;
    return 'released' unless defined $dir && length $dir;
    my $plat = platform();
    return 'unsupported' if $plat eq 'unsupported';

    if ($plat eq 'windows') {
        my $pf = wakelock_pid_file($dir);
        return 'released' unless -e $pf;
        # An empty pid file is BpKeepAwake's atomic claim and the helper has not
        # written itself into it yet. That is a lock COMING UP, and calling it
        # "released" would make `status` warn about a degradation that is about
        # to resolve itself a second later.
        if (-z $pf) {
            my $age = time - ((stat($pf))[9] // 0);
            return 'starting' if $age >= 0 && $age < BpKeepAwake::starting_grace_seconds();
            return 'released';
        }
        my $alive = $opts{pid_alive} // \&BpKeepAwake::pid_alive;
        my $pid = BpKeepAwake::read_pid($pf);
        return (defined $pid && $alive->($pid)) ? 'held' : 'released';
    }

    my $bp = $opts{busy_path} // busy_path();
    return 'released' unless -e $bp;
    my $age = time - ((stat($bp))[9] // 0);
    return ($age < $BUSY_STALE_SECONDS) ? 'held' : 'released';
}

# ---------------------------------------------------------------------------
# refresh($dir) -> 0|1   — THE CHEAP PATH. Stats and utimes only; it starts no
# process and kills none.
#
# Called from anywhere that is already awake and knows an arm is live: the Stop
# gate on every turn end, and every 60s slice of a `hold`. It re-asserts the
# heartbeat of whatever is already running; it never decides to start or stop
# anything. That separation is why the gate can refresh on every single Stop
# without paying the tasklist/powershell process cost that sync() can incur.
sub refresh {
    my ($dir, %opts) = @_;
    my $did = 0;
    my $now = time;

    my $plat = platform();
    return 0 if $plat eq q{unsupported};   # nothing here reads either lease

    if ($plat eq q{windows}) {
        # keep-awake.ps1 polls this file's mtime and exits once it goes stale.
        # Touching it is the whole of "a run still wants this". If it is absent
        # the helper is not running, and only sync() may start one.
        #
        # AN EMPTY FILE IS NOT TOUCHED. That is BpKeepAwake's atomic claim,
        # waiting for a helper that has not written its pid yet, and its age is
        # the only thing that can ever expire it ($STARTING_GRACE_SECONDS).
        # Refreshing it would freeze a claim whose helper died at birth into a
        # permanent "starting", and nothing would ever replace it.
        my $pf = wakelock_pid_file($dir);
        if (-s $pf) { utime($now, $now, $pf); $did = 1 }
    } else {
        $did = touch_busy($opts{busy_path} // busy_path()) ? 1 : $did;
    }
    return $did;
}

# touch_busy($path) — create-if-absent then bump mtime. Identical semantics to
# bp-orchestrator.pl's own touch_busy, against the same file.
sub touch_busy {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    unless (-e $path) {
        my $d = dirname($path);
        make_path($d) unless -d $d;
        open my $fh, '>', $path or return 0;
        close $fh;
    }
    my $now = time;
    utime($now, $now, $path);
    return 1;
}

# ---------------------------------------------------------------------------
# sync($dir, %opts) -> 'held' | 'released'   — THE DECIDING PATH.
#
# %opts:
#   active   — force the verdict (skips any_active); used by the CLI and tests
#   plus every seam BpKeepAwake::apply accepts (spawn/kill_pid/
#   powershell_available/log), passed straight through so tests never actuate.
#
# ONLY THE REFRESHER CALLS THIS WITH active => 1. Non-daemon callers go through
# converge() instead, which refreshes and delegates starting to the daemon. One
# process may start the wake-lock helper; everything else only ever re-asserts
# or releases. Measured 2026-09-15, before that rule existed: three `arm`s in
# the same instant plus a refresher left FIFTEEN live keep-awake.ps1 helpers and
# a pid file that survived disarm, because each caller independently decided the
# lock was missing while a helper was still starting. BpKeepAwake::apply now
# claims the pid file atomically, which closes the same race one level down —
# both are needed: the claim makes a double start impossible, and this rule
# means it is not attempted in the first place.
#
# NOTE WHAT RELEASE DOES **NOT** DO: it never unlinks the busy-lease. That file
# is SHARED with bp-orchestrator.pl, so deleting it on disarm would cancel a
# live fleet run's own lease and invite heartbeat.sh to reap the container out
# from under it. Letting it go stale is the orchestrator's own contract for
# "idle" and is the only safe release for a shared heartbeat: worst case the
# container stays protected for one BUSY window (600s) after disarm.
sub sync {
    my ($dir, %opts) = @_;
    return 'released' unless defined $dir && length $dir;
    my $active = exists $opts{active} ? ($opts{active} ? 1 : 0) : any_active($dir);

    my $plat = platform();
    return ($active ? q{held} : q{released}) if $plat eq q{unsupported};

    if ($plat eq q{windows}) {
        my %ka = map { $_ => $opts{$_} }
                 grep { exists $opts{$_} }
                 qw(spawn kill_pid powershell_available log);
        BpKeepAwake::apply($active ? 'active' : 'settled', $dir, \%ka);
    } elsif ($active) {
        touch_busy($opts{busy_path} // busy_path());
    }
    return $active ? 'held' : 'released';
}

# ---------------------------------------------------------------------------
# converge($dir, %opts) -> ($verdict, $holder)
#   $verdict : 'held' | 'released'  — what the lease was converged TOWARD.
#   $holder  : ensure_daemon's verdict, or 'idle' when nothing is armed.
#
# Both come back from ONE call on purpose. A caller that wanted the holder label
# and asked ensure_daemon again would do so in the second before a just-spawned
# daemon has written its pid file — and a second look at a missing pid file
# starts a second daemon. That is the same shape as the helper storm this file
# already documents, so the value is returned rather than re-derived.
#
# THE VERB EVERY NON-DAEMON CALLER USES — arm, disarm, the repair verb, the Stop
# gate. It says what the lease should be and gets it there, without ever being
# the thing that starts the wake-lock helper (see sync's header for the storm
# that rule exists to prevent).
#
# Armed:   re-assert whatever is already running (pure stat + utime), and make
#          sure a refresher exists. The refresher starts the helper on its first
#          tick, about a second later. In a sandbox the protection is immediate
#          either way, because there the lease IS the file we just touched.
# Unarmed: release directly. Releasing starts nothing and is idempotent, so any
#          caller may do it — and `off` should take effect now, not at whatever
#          point a background process next happens to look.
sub converge {
    my ($dir, %opts) = @_;
    return ('released', 'idle') unless defined $dir && length $dir;
    if (any_active($dir)) {
        refresh($dir, %opts);
        return ('held', ensure_daemon($dir, %opts));
    }
    sync($dir, %opts, active => 0);
    return ('released', 'idle');
}

# ---------------------------------------------------------------------------
# ensure_daemon($dir, %opts) -> 'running' | 'spawned' | 'idle' | 'refused'
#
# Idempotent. LIVENESS IS THE PID FILE'S MTIME, AND ONLY THAT — the recorded pid
# is written for a human to act on, never read back as a liveness test.
#
# Measured on this host, 2026-09-15: a daemon started through fork+exec from
# Git-for-Windows perl recorded $$ = 16818, and `tasklist /FI "PID eq 16818"`
# reported no such task while the process was demonstrably alive and ticking.
# MSYS perl's $$ is an MSYS pid, not a Windows one, so neither kill(0) nor
# tasklist can validate it — the same asymmetry BpKeepAwake::_pid_alive works
# around for the PowerShell helper, except there the helper writes its OWN real
# Windows pid and here there is no equivalent to write.
#
# Trusting that pid would have made every check say "dead" and spawn another
# daemon on every call — the precise shape of the 2026-08-13 leak. The heartbeat
# answers the question that actually matters ("is something still refreshing
# this?"), means the same thing on every platform, costs one stat, and is the
# same signal gate-continuity.sh reads from bash.
sub ensure_daemon {
    my ($dir, %opts) = @_;
    return 'refused' unless defined $dir && length $dir;

    # An explicit "hold nothing" wins over every other consideration. Note this
    # is the DECISION layer: the test guard that stops a real process ever being
    # started lives in _spawn_daemon, one level down, exactly as BpKeepAwake
    # puts its own in spawn() rather than in apply(). Guarding the decision as
    # well would make the decision itself untestable.
    return 'refused' if $ENV{CCPRAXIS_NO_WAKELOCK};

    # Nothing armed, nothing to refresh. Without this, the repair verb (`lease`)
    # and `status` would each start a daemon whose entire life is to notice it
    # has no reason to exist — harmless, but a process spawned per call on paths
    # that run routinely, and a 'spawned' that reads as if something is now
    # being held when nothing is.
    return 'idle' unless any_active($dir);

    my $pf = daemon_pid_file($dir);
    if (-e $pf) {
        my $age = time - ((stat($pf))[9] // 0);
        # A NEGATIVE age is a heartbeat stamped in the future — a clock jumped
        # backwards, or a registry on a filesystem with its own clock. It is not
        # evidence of life, and reading it as "very fresh" would let a DEAD
        # refresher look healthy for the whole skew, which is the failure with
        # no floor: no lease, nothing to notice, nothing to repair it. Treated
        # as stale instead, and a needless respawn costs nothing — the flock
        # turns it into an immediate, silent exit.
        return 'running' if $age >= 0 && $age < tick_seconds() * $STALE_TICKS;
    }

    # 'spawned' only if something really came back. _spawn_daemon returns undef
    # when its test guard fires, and reporting 'spawned' there would be the
    # false claim of holding a lock this whole file is written to avoid.
    my $spawn = $opts{spawn} // \&_spawn_daemon;
    my $pid = eval { $spawn->($dir) };
    return (!$@ && defined $pid) ? 'spawned' : 'refused';
}

# _spawn_daemon($dir) — detach a real, independent `lease --daemon` process.
#
# NOTHING IS PASSED ON THE COMMAND LINE ON PURPOSE. The registry directory is an
# absolute Windows path on the host ("C:/Users/.../.continuity-active"), and
# MSYS2 rewrites colon-bearing argv elements when a native binary is spawned —
# the class of corruption CLAUDE.md documents (mount specs becoming
# "HOST;CONTAINER", stray ";C" directories). The child resolves the directory
# through exactly the same env-based rule we did, so the argument is not needed
# and the hazard is simply not taken. Tests point both ends at a temp dir with
# CCPRAXIS_CONTINUITY_ACTIVE_DIR, which exec inherits.
sub _spawn_daemon {
    my ($dir) = @_;

    # A TEST MUST NEVER SPAWN AN IMMORTAL BACKGROUND HOLDER. Same rule, same
    # wording, same reason as BpKeepAwake::spawn: a leaked daemon outlives the
    # test that made it and keeps the machine awake forever. There is no prove
    # on this host, so every test is a .t run directly and $0 identifies it.
    # Tests that legitimately exercise the spawn DECISION inject their own seam
    # and never reach this sub.
    return undef if defined $0 && $0 =~ /\.t\z/;

    my $script = "$DIR/bp-continuity.pl";
    die "continuity script missing: $script\n" unless -f $script;
    require POSIX;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        # Leave the caller's process group where we can: a Bash tool call that
        # is interrupted must not take the wake-lock down with it. setsid is a
        # no-op concept on the Windows side, where exec() already yields an
        # independent process.
        eval { POSIX::setsid() } unless is_windows();
        exec($^X, $script, 'lease', '--daemon') or POSIX::_exit(127);
    }
    return $pid;
}

# ---------------------------------------------------------------------------
# daemon_loop($dir, %opts) — the refresher itself. Blocks.
#
# %opts: tick, max_iterations (tests), plus sync()'s seams.
sub daemon_loop {
    my ($dir, %opts) = @_;
    my $tick = defined $opts{tick} ? clamp_tick($opts{tick}) : tick_seconds();
    my $pf   = daemon_pid_file($dir);

    make_path($dir) unless -d $dir;

    # SINGLE-INSTANCE BY flock, NOT BY INSPECTING THE PID FILE.
    #
    # ensure_daemon's heartbeat check is a cheap filter, and it has a real race:
    # two arms in the same second both find no pid file and both spawn. A check
    # inside the daemon closes nothing on its own, because both daemons can run
    # it before either writes. An advisory lock held for the process's lifetime
    # is the only version of this that is actually exclusive — and the OS drops
    # it when the holder dies, so a crashed daemon leaves nothing to clean up.
    #
    # A separate file from the pid/heartbeat on purpose: the heartbeat's whole
    # job is to be rewritten and re-stat'd constantly, which is the last thing
    # you want under a lock others are testing.
    #
    # IT IS NEVER UNLINKED, and that is the right call rather than an oversight.
    # Removing it would race: on POSIX an unlink succeeds while another process
    # holds the lock on the same inode, so the next arrival creates a FRESH file,
    # locks that instead, and both refreshers then believe they are the only one.
    # The residue is one empty dot-named file per registry, which any_active
    # already ignores.
    # DEGRADES TO UNLOCKED RATHER THAN TO NOTHING. If the lock file cannot be
    # opened at all — an unwritable registry, a full disk, a mount where this
    # fails — returning early would leave the arm with NO refresher, and
    # ensure_daemon would start a fresh one that failed the same way on every
    # Stop, forever, silently. Running without exclusivity risks a second
    # refresher; running not at all risks a suspended host mid-run. The first is
    # the lesser failure, and BpKeepAwake's atomic claim still stops two
    # refreshers from becoming two wake-locks.
    my $lock;
    my $locked = 0;
    if (open $lock, '>>', "$dir/lease.lock") {
        unless (flock($lock, LOCK_EX | LOCK_NB)) {
            close $lock;
            return 'duplicate';
        }
        $locked = 1;
    }

    _write_pid($pf, $$);

    my $released = 0;
    my $release = sub {
        return if $released++;
        sync($dir, %opts, active => 0);
        unlink $pf;
    };
    local $SIG{TERM} = sub { $release->(); exit 0 };
    local $SIG{INT}  = sub { $release->(); exit 0 };

    # THERE IS NO PROCESS-START DEADLINE, AND THAT IS A CORRECTION.
    #
    # There was one: TTL + 1h from the moment the refresher started. It looked
    # like a harmless belt and was a guillotine. The Stop gate touches an armed
    # marker on every turn end, so a long-lived arm never expires — but the
    # daemon did, and at that instant it released the lock and exited. The only
    # thing that restarts it is the Stop gate, and this file's own header argues
    # a daemon was needed precisely BECAUSE a long unattended turn has no Stop.
    # So a session armed past the deadline, mid-turn, silently lost its
    # wake-lock and the host was free to suspend: the exact failure this module
    # exists to prevent, reintroduced on a timer.
    #
    # any_active is already the bound, and it is the RIGHT bound: it is derived
    # from the markers, so it expires when the arms do rather than when this
    # process happens to have started. A second cap derived from the same clock
    # and the same files could only either duplicate it or contradict it.
    my $iter = 0;

    while (1) {
        last unless any_active($dir);
        sync($dir, %opts, active => 1);
        my $now = time;
        utime($now, $now, $pf);          # the heartbeat cheap readers rely on
        $iter++;
        last if defined $opts{max_iterations} && $iter >= $opts{max_iterations};
        sleep $tick;
    }

    $release->();
    close $lock if $locked;
    return q{done};
}

sub _write_pid {
    my ($pf, $pid) = @_;
    open my $fh, '>', $pf or return 0;
    print {$fh} "$pid\n";
    close $fh;
    return 1;
}

1;
