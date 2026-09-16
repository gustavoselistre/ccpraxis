#!/usr/bin/env perl
# run-tests.pl -- the repo-wide test runner. Parallel where that is safe,
# serial where it is not.
#
# WHY THIS EXISTS. A full sweep was ~70 minutes of CPU across 243 files, run
# one at a time, and a suite nobody wants to run is a suite that stops getting
# run. Measured on this host: 4190s of CPU, 915s wall at six-way parallelism.
# The work is dominated by PROCESS CREATION -- a bare statusline spawn costs
# ~292ms here -- not by CPU, so parallelism buys more than the core count
# suggests.
#
# `prove` is not an option: the Git-for-Windows perl ships no TAP::Harness
# (see the repo CLAUDE.md). This runs each .t as its own process and judges it
# by exit code plus `not ok` count, which is the same rule the project already
# applies by hand.
#
# CONTAINER TESTS RUN SERIALLY, and that is not a limitation to remove later.
# They start real podman containers against ONE podman machine, so running them
# concurrently makes them contend for the same resource -- slower in wall-clock
# AND flakier, which is the documented failure signature of this suite
# (EXIT=124/255 with no failing assertion). They are detected by what they
# import rather than by a tag, so a new one is classified correctly without
# anybody remembering to mark it.
#
# Usage:
#   perl scripts/run-tests.pl                    # everything
#   perl scripts/run-tests.pl --fast             # skip the container tests
#   perl scripts/run-tests.pl --jobs 8           # override parallelism
#   perl scripts/run-tests.pl --nice             # low-impact: cap workers, see below
#   perl scripts/run-tests.pl plugins/sandbox    # limit to a plugin or a glob
#   perl scripts/run-tests.pl --state=failed     # re-run only last run's red files
#
# --nice / CCPRAXIS_TEST_JOBS -- a low-impact mode, added because the default
# below (cores-2) is a throughput-maximising choice that is wrong for the
# common case of an agent kicking off a sweep while the operator is still
# using the machine. Named "--nice" after the Unix tool it rhymes with in
# INTENT (be a considerate background citizen) -- it does NOT touch OS
# scheduling priority the way `nice(1)` does; that would need to cover every
# spawned git/podman child too, which is a separate, larger change.
#
# --nice caps parallelism at max(2, cores/4): a quarter of the machine,
# floored at 2 rather than letting it round down to 1 on a 4-core host --
# 1 worker turns a sweep serial and "unbearably long" rather than merely
# slower. On this repo's reference 8-core host that is 2 workers, the same
# total CPU-seconds spread over roughly four times the wall-clock, leaving
# the operator three quarters of the machine.
#
# CCPRAXIS_TEST_JOBS=N is the same idea as an ambient default: set once in an
# agent's environment so every sweep it kicks off is gentle without having to
# remember a flag per invocation.
#
# Precedence (most to least specific): explicit `--jobs N` > `--nice` >
# `CCPRAXIS_TEST_JOBS` env var > the plain cores-2 default. The plain default
# is UNCHANGED -- this adds a choice, it does not remove the fast path for
# someone who is actively waiting on the result.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw(:sys_wait_h);
# bsd_glob(), NOT the builtin glob() -- the builtin word-splits its PATTERN
# argument on whitespace (csh-style), so an explicit target whose own path
# contains a space (e.g. a real checkout under "C:\Users\Andre\Personal
# Files") silently matches nothing and the whole invocation exits "no test
# files matched" without ever naming the file. Same defect, same fix, as
# scripts/backfill-test-platform.pl (package 02) -- fix-batch
# 03-enforce-marker step 7, finding A2.
use File::Glob qw(bsd_glob);

my $ROOT     = "$Bin/..";
my $ROOT_ABS = abs_path($ROOT) // $ROOT;

# TestPlatform is package 01's sole decision point for a file's platform
# marker; loaded by literal path (not `use lib` + `use TestPlatform`) because
# this is a top-level script, not a package, and $ROOT_ABS is only known at
# runtime, not at BEGIN time.
require File::Spec->catfile($ROOT_ABS, qw(plugins butler tests lib TestPlatform.pm));

# NO TEST RUN MAY ACTUATE A REAL OS WAKE-LOCK.
#
# bp-keepawake.pl and BpContinuityLease.pm each refuse when $0 ends in ".t", and
# that covers a test calling them in-process. It does NOT cover the common case:
# a test that shells out to `perl bp-continuity.pl arm`, whose child sees $0 as a
# .pl and happily fork+execs a detached refresher and a real keep-awake.ps1 with
# its -PidFile pointing into a File::Temp directory. That is how 53 orphaned
# helpers once filled this machine and forced a restart.
#
# Every test file that drives those scripts sets this itself (enforced by
# plugins/butler/tests/t/test-wakelock-hygiene.t, which is what makes a direct
# `perl some.t` safe too). Setting it here as well means a SWEEP is safe even
# for a file nobody has classified yet — the guarantee should not depend on
# whoever adds the next test having read the rule.
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my ($fast, $jobs, $nice, $state_mode, @targets) = (0, 0, 0, 0);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--fast')            { $fast = 1 }
    elsif ($a eq '--nice')            { $nice = 1 }
    elsif ($a eq '--jobs')            { $jobs = shift(@ARGV) || 0 }
    elsif ($a =~ /^--jobs=(\d+)$/)    { $jobs = $1 }
    elsif ($a eq '--state=failed')    { $state_mode = 1 }
    elsif ($a =~ /^--state=/)         {
        print STDERR "error: unsupported value for $a (only --state=failed is recognized)\n";
        exit 2;
    }
    elsif ($a eq '--help' || $a eq '-h') { print _usage(); exit 0 }
    else                              { push @targets, $a }
}
if ($state_mode && @targets) {
    print STDERR "error: --state=failed cannot be combined with a path/glob target\n";
    exit 2;
}
sub _usage { return <<'USAGE' }
usage: perl scripts/run-tests.pl [--fast] [--jobs N] [--nice] [--state=failed] [PATH-OR-GLOB ...]
  --fast          skip tests that start real containers
  --jobs N        parallelism for non-container tests (default: cores - 2)
  --nice          low-impact mode: cap parallelism at max(2, cores/4), leaving
                  the machine usable for whoever else is on it. Does not touch
                  OS scheduling priority (spawned git/podman children aren't
                  covered by that). Env var CCPRAXIS_TEST_JOBS=N sets the same
                  kind of ambient low-impact default without a per-run flag.
  --state=failed  re-run only the files recorded failing by the previous run

Precedence for parallelism (most to least specific):
  --jobs N  >  --nice  >  CCPRAXIS_TEST_JOBS env var  >  default (cores - 2)
USAGE

# --- state file (--state=failed) --------------------------------------------
# Path: .ccpraxis-local-data/test-state/last-failures.txt, relative to $ROOT.
# CCPRAXIS_TEST_STATE_DIR, if set and non-empty, replaces just the directory
# component -- test-isolation hook only, not a documented user flag.
sub _state_dir {
    return $ENV{CCPRAXIS_TEST_STATE_DIR}
        if defined $ENV{CCPRAXIS_TEST_STATE_DIR} && length $ENV{CCPRAXIS_TEST_STATE_DIR};
    return File::Spec->catdir($ROOT, '.ccpraxis-local-data', 'test-state');
}
sub _state_file_path { return File::Spec->catfile(_state_dir(), 'last-failures.txt') }

sub _read_state_file {
    my $path = _state_file_path();
    return () unless -f $path;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $raw = <$fh>;
    close $fh;
    return () unless defined $raw && length $raw;
    return split /\n/, $raw;
}

# _to_abs($relpath) -- reconstructs a real path from a relpath recorded in the
# state file, anchored on $ROOT_ABS so it works whether the recorded entry is
# a real repo file (plugins/foo/tests/t/bar.t) or a fixture path outside the
# repo tree entirely (../../../tmp/xxx/tests/t/bar.t, in the test suite).
sub _to_abs { my ($rel) = @_; return File::Spec->rel2abs($rel, $ROOT_ABS) }

# _relpath($abs) -- the inverse: a forward-slash path relative to $ROOT_ABS,
# used both to write the state file and to decide what "this invocation
# actually ran" (%ran) means for the merge in the report phase below.
# Deliberately does NOT re-resolve $abs through abs_path(): on this host's
# perl, /tmp is a mount point whose realpath differs from its own name, and
# resolving it here would disagree with how fixture paths are constructed
# and compared elsewhere (RunnerStateHarness::relpath_from_root does the
# same plain abs2rel, no realpath, for exactly this reason).
sub _relpath {
    my ($abs) = @_;
    my $rel = File::Spec->abs2rel($abs, $ROOT_ABS);
    $rel =~ s{\\}{/}g;
    # A refusal message exists so a human can FIND the file. $ROOT_ABS on this
    # host is always MSYS-style (/c/Development/ccpraxis); an explicit target
    # given/produced in Windows drive-letter style (C:/Users/...) has no
    # common ancestor abs2rel can express cleanly, so the "relative" result
    # still embeds the raw "C:/..." segment after a run of "../" hops
    # (reproduced live: "../../../../C:/Users/..."). That is longer AND
    # harder to follow than either a clean relative or a clean absolute path
    # -- worse than doing nothing. Fall back to the absolute path whenever
    # the computed "relative" form still looks like a second drive-letter
    # path spliced onto a climb; this never fires for a real in-tree file
    # (fix-batch 03-enforce-marker step 7, finding A3).
    return $abs if $rel =~ m{^(?:\.\./)*[A-Za-z]:[/\\]};
    return $rel;
}

sub _write_state_atomic {
    my ($lines) = @_;
    my $dir = _state_dir();
    make_path($dir) unless -d $dir;
    my $final_path = _state_file_path();
    my $tmp_path   = "$final_path.tmp.$$";
    open my $fh, '>:raw', $tmp_path or die "cannot write $tmp_path: $!";
    print {$fh} "$_\n" for @$lines;
    close $fh;
    unless (rename($tmp_path, $final_path)) {
        unlink $final_path;
        rename($tmp_path, $final_path)
            or warn "run-tests.pl: cannot rename $tmp_path to $final_path: $!";
    }
}

# --- collect ---------------------------------------------------------------
my @files;
if ($state_mode) {
    my @recorded = _read_state_file();
    my @live     = grep { -f _to_abs($_) } @recorded;
    for my $gone (grep { !-f _to_abs($_) } @recorded) {
        print STDERR "state: $gone no longer exists, skipping\n";
    }
    unless (@live) {
        print "no recorded failures -- nothing to run\n";
        exit 0;
    }
    @files = map { _to_abs($_) } @live;
} elsif (@targets) {
    for my $t (@targets) {
        my @m = bsd_glob($t);
        @m = bsd_glob("$t/tests/t/*.t")  if !@m || -d $t;
        @m = bsd_glob("$ROOT/$t")        unless @m;
        @m = bsd_glob("$ROOT/$t/tests/t/*.t") unless @m;
        push @files, grep { /\.t$/ && -f $_ } @m;
    }
} else {
    push @files, bsd_glob("$ROOT/plugins/*/tests/t/*.t");
}
@files = sort @files;
unless (@files) { print STDERR "no test files matched\n"; exit 2 }

# MARKER GATE, then CLASSIFY BY WHAT THE FILE IMPORTS, not by a tag someone
# has to remember. The marker gate runs FIRST and unconditionally (no --fast
# exemption, no opt-out): a file whose platform declaration is not `legal`
# is refused rather than guessed into a lane, per Decision 2/4 (blueprint
# test-platform-split, package 03-enforce-marker). Refusal is per-file, not
# a whole-run abort, so the rest of the sweep still runs and reports, and
# --state=failed still has something to retry.
my (@serial, @parallel, @refused);
for my $f (@files) {
    open my $fh, '<', $f or next;      # UNCHANGED: unreadable file silently
                                        # skipped, exactly as before this gate existed.
    # KNOWN, ACCEPTED TRADEOFF (not changed by fix-batch 03-enforce-marker
    # step 7): this is a full-file slurp, not TestPlatform::read_prefix's
    # bounded 4096-byte read, even though parse_marker() only ever looks at
    # the first 4096 bytes internally. It predates the marker gate -- the
    # pre-existing container heuristic below needs the WHOLE file text (its
    # pattern can appear anywhere) -- and the spec deliberately pins reusing
    # this one read for both checks rather than adding a second, bounded
    # read. Measured cost: ~500x slower than read_prefix on a 200MB fixture
    # (0.2s vs 0.0004s), scaling linearly with file size; immeasurable
    # against a real ~1000s sweep of normal-sized .t files, but a real cost
    # against a pathologically large file landing in plugins/*/tests/t/.
    # Flagged for whoever next touches this collection/classify loop; fixing
    # it here would be a behavioural change to the runner's hot path beyond
    # this batch's scope.
    my $src = do { local $/; <$fh> };
    close $fh;

    my $marker = TestPlatform::parse_marker($src);
    if ($marker->{outcome} ne 'legal') {
        push @refused, { file => $f, marker => $marker };
        next;   # never guess a lane for a file whose declared need is unknown
    }

    if ($src =~ /TestSandbox|podman_run_capture|podman_bin|probe_image/) { push @serial, $f }
    else                                                                { push @parallel, $f }
}
@serial = () if $fast;   # UNCHANGED: --fast never touches @refused

$jobs = _resolve_jobs(
    explicit_jobs => $jobs,
    nice          => $nice,
    env_jobs      => $ENV{CCPRAXIS_TEST_JOBS},
    cores         => _cores(),
);
$jobs = scalar(@parallel) if $jobs > @parallel && @parallel;
$jobs = 1 if $jobs < 1;

sub _cores {
    return $ENV{NUMBER_OF_PROCESSORS} if $ENV{NUMBER_OF_PROCESSORS} && $ENV{NUMBER_OF_PROCESSORS} =~ /^\d+$/;
    if (open my $c, '<', '/proc/cpuinfo') {
        my $n = grep { /^processor\s*:/ } <$c>;
        close $c;
        return $n if $n;
    }
    return 4;
}

# _resolve_jobs(%args) -> $jobs
# Pure by construction (every input is a parameter, nothing read from %ENV or
# @ARGV directly) so the precedence chain is unit-testable without spawning
# the runner. Precedence, most to least specific:
#   explicit_jobs (--jobs N)  >  nice (--nice)  >  env_jobs (CCPRAXIS_TEST_JOBS)
#   >  the plain cores-2 default (unchanged from before --nice existed).
sub _resolve_jobs {
    my (%a) = @_;
    my $cores = $a{cores} || 4;

    return $a{explicit_jobs} if $a{explicit_jobs};

    if ($a{nice}) {
        my $n = int($cores / 4);
        $n = 2 if $n < 2;
        return $n;
    }

    if (defined $a{env_jobs} && $a{env_jobs} =~ /^\d+$/ && $a{env_jobs} > 0) {
        return $a{env_jobs};
    }

    return $cores > 3 ? $cores - 2 : 1;
}

# run_one($file) -> \%result. The judgement rule the project already uses by
# hand: non-zero exit is red, and the `not ok` count says whether it was a
# failed assertion or the process dying (EXIT != 0 with NOTOK == 0 is the
# signature of a timeout or a kill, not a broken expectation).
sub run_one {
    my ($f) = @_;
    my $t0  = time;
    my $out = `perl "$f" 2>&1`;
    my $rc  = $? >> 8;
    $out = '' unless defined $out;
    my $notok = () = $out =~ /^not ok/mg;
    return { file => $f, rc => $rc, notok => $notok, secs => time - $t0, out => $out };
}

my $start = time;
my @results;

# --- parallel phase --------------------------------------------------------
# fork/waitpid with a result file per child: the MSYS2 perl on this host has a
# real fork, but no shared memory, so children report through the filesystem.
if (@parallel) {
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my (%pid_of, @queue);
    @queue = @parallel;
    my $i = 0;
    my %slot;

    my $spawn = sub {
        my $f = shift @queue or return 0;
        my $id = $i++;
        my $pid = fork();
        if (!defined $pid) { unshift @queue, $f; return 0 }
        if ($pid == 0) {
            my $r = run_one($f);
            open my $o, '>', "$dir/$id" or exit 1;
            print {$o} join("\x1f", $r->{rc}, $r->{notok}, $r->{secs}, $r->{file}), "\x1e", $r->{out};
            close $o;
            exit 0;
        }
        $slot{$pid} = $id;
        return 1;
    };

    $spawn->() for 1 .. $jobs;
    while (%slot) {
        my $pid = waitpid(-1, 0);
        last if $pid <= 0;
        my $id = delete $slot{$pid};
        if (defined $id && open my $in, '<', "$dir/$id") {
            my $raw = do { local $/; <$in> };
            close $in;
            my ($head, $out) = split /\x1e/, (defined $raw ? $raw : ''), 2;
            my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
            push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                             secs => $secs // 0, out => $out // '' };
        }
        $spawn->();
    }
}

# --- serial phase ----------------------------------------------------------
push @results, run_one($_) for @serial;

# --- refused phase -----------------------------------------------------------
# A refused file never spawned a process; it is synthesised as a red result so
# it flows through the existing report/state/exit-code machinery unchanged.
push @results, _refusal_result($_) for @refused;

# _marker_fix_message($file, $marker) -- the exact, pinned refusal text per
# outcome/reason (blueprint test-platform-split, package 03-enforce-marker,
# spec section 1.4). Both surfaces (this script and
# plugins/butler/tests/t/test-platform-hygiene.t) decide SOLELY through
# TestPlatform::parse_marker; this sub only turns its outcome/reason into the
# words a human fixes the file from -- never a second regex over marker
# syntax.
# _escape_marker_text($text) -- renders C0 control characters and DEL
# inertly (a readable "\xHH" escape, not silent stripping) before marker text
# reaches a terminal or the state file. Without this, a malformed marker line
# containing a raw \r or an ANSI escape reaches the printed "not ok" line
# verbatim -- a .t file can then visually spoof or overwrite its own refusal
# line during a live sweep (confirmed live by the red-team: an embedded \r
# repaints the terminal line; a raw ESC carries a full ANSI sequence through).
# This is the ONLY place marker text is rendered for output -- both callers
# below (unrecognized-value/malformed-marker-line's raw[0], and
# conflicting-markers' joined list) route through it. Escaping, not
# stripping, so the message still tells the human what is actually in their
# file (fix-batch 03-enforce-marker step 7, finding A1).
sub _escape_marker_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord($1))/ge;
    return $text;
}

sub _marker_fix_message {
    my ($file, $marker) = @_;
    my $rel = _relpath($file);
    my $body;
    if ($marker->{outcome} eq 'absent') {
        $body = 'no platform marker found. Fix: add "# platform: windows|linux|any" near the top '
              . 'of the file (within the first 4096 bytes).';
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'unrecognized-value') {
        my $raw = _escape_marker_text($marker->{raw}[0] // '');
        $body = qq{unrecognized platform value "$raw". Fix: change it to one of: windows, linux, any.};
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'conflicting-markers') {
        my $joined = join(', ', map { _escape_marker_text($_) } @{ $marker->{raw} // [] });
        $body = "conflicting platform markers found ($joined). Fix: keep exactly one "
              . '"# platform: ..." line with a single legal value.';
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'malformed-marker-line') {
        my $raw = _escape_marker_text($marker->{raw}[0] // '');
        $body = qq{malformed platform marker line ("$raw"). Fix: use exactly "# platform: windows|linux|any" }
              . '(lowercase keyword "platform", one legal value, no trailing text).';
    } else {
        # Defensive fallback for any future fourth reason value -- must never
        # fire against today's TestPlatform.pm.
        $body = 'platform marker is not legal. Fix: use exactly "# platform: windows|linux|any".';
    }
    return "PLATFORM MARKER REFUSED: $rel -- $body";
}

sub _refusal_result {
    my ($entry) = @_;
    my $msg = _marker_fix_message($entry->{file}, $entry->{marker});
    return { file => $entry->{file}, rc => 1, notok => 1, secs => 0,
             out => "not ok 1 - $msg\n", refused => 1 };
}

# --- report ----------------------------------------------------------------
my $wall = time - $start;
my @red  = grep { $_->{rc} != 0 } @results;

printf "\n%d files  %ds wall  (%d parallel at -j%d, %d serial)\n",
    scalar(@results), $wall, scalar(@parallel), $jobs, scalar(@serial);

if (@red) {
    print "\nRED:\n";
    for my $r (sort { $a->{file} cmp $b->{file} } @red) {
        printf "  %-52s exit=%-3d notok=%d%s\n", basename($r->{file}), $r->{rc}, $r->{notok},
            ($r->{notok} == 0 ? '   <- died, no failing assertion'
                              : $r->{refused} ? '   <- refused: platform marker missing/invalid'
                                               : '');
        for my $line (grep { /^not ok/ } split /\n/, $r->{out}) {
            print "      $line\n";
        }
    }
} else {
    print "all green\n";
}

my @slow = (sort { $b->{secs} <=> $a->{secs} } @results)[0 .. ($#results < 4 ? $#results : 4)];
print "\nslowest:\n";
printf "  %5ds  %s\n", $_->{secs}, basename($_->{file}) for grep { defined } @slow;

# --- state write (merge, never replace) -------------------------------------
# %ran is the boundary: "did this invocation actually execute it" -- true
# whether a file was excluded by --fast, by a path/glob target, or
# (transitively) never reached because of --state=failed scope. Anything not
# in %ran is carried forward from the prior state file, provided it still
# exists on disk; a vanished old entry is dropped unconditionally.
my %ran = map { _relpath($_->{file}) => 1 } @results;
my %red = map { _relpath($_->{file}) => 1 } @red;

my @old     = _read_state_file();
my @carried = grep { !$ran{$_} && -f _to_abs($_) } @old;
my %seen;
my @final = sort grep { !$seen{$_}++ } (@carried, keys %red);

_write_state_atomic(\@final);

if (@final) {
    print "\nstate: " . scalar(@final) . " failing recorded to .ccpraxis-local-data/test-state/last-failures.txt\n";
} else {
    print "\nstate: all green, .ccpraxis-local-data/test-state/last-failures.txt cleared\n";
}

exit scalar(@red);
