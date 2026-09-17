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
# ROUTING BY MARKER (blueprint test-platform-split, package 06-route-by-marker).
# classify_file() below is the sole routing predicate: marker gate first (an
# illegal/absent marker is refused, package 03), then the pre-existing serial
# heuristic (still wins -- ten of the fifteen podman-starting tests are marked
# `any`, and routing those into ANOTHER container would be podman-in-podman),
# then the declared marker value. A file classify_file routes to 'container'
# only actually reaches the container lane (scripts/run-tests-container.pl,
# package 05, required into its own namespace below) when the
# CCPRAXIS_CONTAINER_LANE_ENABLED env var is set truthy -- an explicit,
# lane-AVAILABILITY opt-in, off by default, never a routing switch: with it
# off, every file classify_file would have routed to 'container' simply runs
# on the host instead, exactly as it did before this package existed. This is
# deliberately NOT a new CLI flag (out of scope per the package spec) -- see
# run_sweep()'s own comment at the gate for the full rationale.
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
#
# --fast's meaning is UNCHANGED by the routing above: it skips tests that
# start real containers (a property of a file's own content, the serial
# heuristic), never the container LANE (an execution-environment choice,
# orthogonal to that contract). --fast still empties only the host-serial
# set; it never touches the container set.
use strict;
use warnings;
use File::Basename qw(basename dirname);
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

# NOT FindBin: $Bin is computed ONCE per process, at the first `use FindBin`
# anywhere -- if a caller (e.g. plugins/butler/tests/t/lane-routing.t, which
# also `use`s FindBin) has already triggered that computation against ITS
# OWN $0 before `require`ing this file, this file's own `use FindBin qw($Bin)`
# would silently reuse the caller's cached value instead of recomputing,
# producing a wrong, doubled path the moment this file is required rather
# than run directly. Separators normalised BEFORE dirname (__FILE__ may carry
# backslashes on Windows) -- same shape as run-tests-container.pl's own
# project_root computation and turn-cap-consistency.t's C9 rule.
my $ROOT_ABS = do {
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $here = Cwd::abs_path($self) // $self;
    abs_path(dirname($here) . '/..');
};

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

# RunTestsContainerLane -- package 05's run-tests-container.pl, required into
# an ISOLATED namespace rather than main:: (blueprint test-platform-split,
# package 06-route-by-marker, spec section 2.3). Neither file declares its own
# `package`, so a plain `require` of one into the other's main:: would let a
# same-named sub silently overwrite the other's definition with no
# compile-time warning -- both files define `sub _usage` today (different
# bodies), and a future rename of run_sweep() to the more obvious `main` would
# collide with this file's own `sub main`. Every sub/`our`-variable
# run-tests-container.pl defines lands in RunTestsContainerLane:: instead:
# RunTestsContainerLane::podman_bin(), ::image_present(...),
# ::build_run_argv(...), ::run_one_in_container(...),
# $RunTestsContainerLane::IMAGE, $RunTestsContainerLane::ACTIVE_CONTAINER_NAME,
# etc. Requiring it here runs its own top-level statements (the
# MSYS2_ARG_CONV_EXCL assignment, the %SIG{INT,TERM,HUP} handler install, the
# END block) but never its main() (guarded by its own "unless caller()") --
# harmless while $ACTIVE_CONTAINER_NAME is undef, which is true for the whole
# life of any invocation that never routes a file into the container lane.
#
# FIX-BATCH C1/A1 (CRITICAL, step 7): the require above used to leave
# $ENV{MSYS2_ARG_CONV_EXCL} = '*' set for the rest of THIS process's life the
# moment run-tests-container.pl's own top-level statement ran -- and every
# one of the ~350 test children run_one()'s backticks spawn inherits this
# process's %ENV. That is the exact shell-wide condition both CLAUDE.md files
# forbid by name: disabling MSYS2 argv conversion while bare /c/... paths are
# still passed elsewhere resolves the leading slash against the current
# drive (576 stray drive-root entries on 2026-06-12). The opt-out and package
# 05's own hand-translation (_winify_path) are one technique, never
# alternatives, and only the container-batch code below actually needs the
# opt-out -- so it is scoped here (snapshotted and restored immediately
# around the require) and again, LOCALLY, inside _run_container_batch()
# itself (the only place package 05's git/podman calls that pair with it
# actually run).
my $__msys2_before_container_require =
    exists $ENV{MSYS2_ARG_CONV_EXCL} ? $ENV{MSYS2_ARG_CONV_EXCL} : undef;
package RunTestsContainerLane;
require File::Spec->catfile($ROOT_ABS, qw(scripts run-tests-container.pl));
package main;
if (defined $__msys2_before_container_require) {
    $ENV{MSYS2_ARG_CONV_EXCL} = $__msys2_before_container_require;
} else {
    delete $ENV{MSYS2_ARG_CONV_EXCL};
}

sub _usage { return <<'USAGE' }
usage: perl scripts/run-tests.pl [--fast] [--jobs N] [--nice] [--state=failed] [PATH-OR-GLOB ...]
  --fast          skip host-serial tests that start real containers (a
                  property of a file's own content). This does NOT touch the
                  container LANE below -- if that is enabled, its files still
                  run there regardless of --fast.
  --jobs N        parallelism for non-container tests (default: cores - 2)
  --nice          low-impact mode: cap parallelism at max(2, cores/4), leaving
                  the machine usable for whoever else is on it. Does not touch
                  OS scheduling priority (spawned git/podman children aren't
                  covered by that). Env var CCPRAXIS_TEST_JOBS=N sets the same
                  kind of ambient low-impact default without a per-run flag.
  --state=failed  re-run only the files recorded failing by the previous run

Precedence for parallelism (most to least specific):
  --jobs N  >  --nice  >  CCPRAXIS_TEST_JOBS env var  >  default (cores - 2)

Container lane (opt-in, off by default -- a lane-AVAILABILITY switch, never a
routing switch; see classify_file()'s own header comment):
  CCPRAXIS_CONTAINER_LANE_ENABLED=1|true|yes|on   run any/linux-marked,
                  non-serial-classified files inside the existing
                  claude-sandbox:latest container instead of on this host.
                  Any other value (unset, "", "0", "false", "no", "off", ...)
                  means OFF -- those files simply run on the host instead,
                  exactly as before this env var existed. Only the whole
                  working tree that was last committed is reflected in the
                  container (package 05's own limitation), so an ordinary
                  sweep tests HEAD, not uncommitted edits, for every file
                  this sends there.
USAGE

# --- state file (--state=failed) --------------------------------------------
# Path: .ccpraxis-local-data/test-state/last-failures.txt, relative to $ROOT_ABS.
# CCPRAXIS_TEST_STATE_DIR, if set and non-empty, replaces just the directory
# component -- test-isolation hook only, not a documented user flag.
sub _state_dir {
    return $ENV{CCPRAXIS_TEST_STATE_DIR}
        if defined $ENV{CCPRAXIS_TEST_STATE_DIR} && length $ENV{CCPRAXIS_TEST_STATE_DIR};
    return File::Spec->catdir($ROOT_ABS, '.ccpraxis-local-data', 'test-state');
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
    # FIX-BATCH M3 (step 7): the container-lane opt-in is a property of the
    # invocation a human/agent made, not of the process tree it spawns.
    # Without this, a nested `perl scripts/run-tests.pl` invoked BY one of
    # the swept files below (five host-lane tests do exactly this, via
    # RunnerStateHarness::spawn_runner) would inherit the outer sweep's own
    # opt-in and start a REAL container from inside a test, with no ceiling
    # on how many. `local` + `delete` scopes the removal to this call only.
    local $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED};
    delete $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED};
    my $out = `perl "$f" 2>&1`;
    my $rc  = $? >> 8;
    $out = '' unless defined $out;
    my $notok = () = $out =~ /^not ok/mg;
    return { file => $f, rc => $rc, notok => $notok, secs => time - $t0, out => $out };
}

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

# classify_file($abs_path) -> \%decision | undef -- the SOLE routing
# predicate (blueprint test-platform-split, package 06-route-by-marker, spec
# section 2.1). Pure with respect to everything except reading the one file
# given; never dies; mirrors the pre-existing `open ... or next` silent-skip
# for an unreadable file by returning undef. Exactly four `lane` values:
# refused, host-serial, host-parallel, container. Takes exactly one
# parameter and reads neither %ENV nor @ARGV, by construction -- its per-file
# verdict cannot be overridden by any flag, environment variable or argument
# (Decision 18: the lane-AVAILABILITY gate lives in run_sweep()'s wiring,
# never here).
sub classify_file {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;   # unchanged silent-skip precedent
    my $src = do { local $/; <$fh> };
    close $fh;

    my $marker = TestPlatform::parse_marker($src);
    if ($marker->{outcome} ne 'legal') {
        return { lane => 'refused', marker => $marker, serial => undef };
    }

    # PRECEDENCE (pinned, spec section 0.1): the serial heuristic outranks
    # the marker value. A file that starts real podman containers must never
    # be sent into ANOTHER container, and must never run concurrently with
    # other podman-touching work, regardless of what platform it declares
    # needing.
    my $serial = ($src =~ /TestSandbox|podman_run_capture|podman_bin|probe_image/) ? 1 : 0;
    if ($serial) {
        return { lane => 'host-serial', marker => $marker, serial => 1 };
    }
    if ($marker->{value} eq 'windows') {
        return { lane => 'host-parallel', marker => $marker, serial => 0 };
    }
    # 'any' or 'linux', not serial-classified.
    return { lane => 'container', marker => $marker, serial => 0 };
}

# _container_infra_result($abs_file, $reason) -> \%result -- rc => 1,
# notok => 0 deliberately (nothing ran; no TAP was ever produced). No
# fallback to the host, ever: an unavailable container lane marks every file
# it was supposed to run as red, with a message naming why, rather than
# silently running them on the host or aborting the whole sweep.
sub _container_infra_result {
    my ($abs_file, $reason) = @_;
    my $rel = _relpath($abs_file);
    return {
        file => $abs_file, rc => 1, notok => 0, secs => 0,
        out  => "CONTAINER LANE UNAVAILABLE: $rel -- $reason. This file needs the "
              . "container lane (platform: any|linux) and was not run anywhere -- an "
              . "unavailable lane never silently falls back to the host.\n",
        container_infra => 1,
    };
}

# _run_container_batch(@abs_files) -> @results -- orchestration, one
# container per sweep. Reproduces run-tests-container.pl::main()'s own flow
# using only the low-level, namespaced primitives -- never calling
# RunTestsContainerLane::main, both because that sub parses a CLI argv shape
# this call site does not have, and because bypassing it keeps this package
# out of run-tests-container.pl's write set entirely.
sub _run_container_batch {
    my (@abs_files) = @_;                      # ABSOLUTE paths -- same convention every
    return () unless @abs_files;               # other lane's @results uses (section 2.4.1)

    # FIX-BATCH C1/A1: re-apply the MSYS2 argv-conversion opt-out ONLY for the
    # dynamic scope of this call. Package 05's git/podman calls inside
    # materialize_tree() are written expecting it, paired with their own
    # _winify_path hand-translation (run-tests-container.pl's header) -- the
    # opt-out and the translation are one technique. `local` means it never
    # escapes back into the caller once this sub returns, whether that
    # caller is a throwaway forked batch child (the normal run_sweep() path)
    # or this file's own direct in-process calls (the oracle's Part B/C).
    no warnings 'once';   # RunTestsContainerLane::WINDOWS_FAMILY is only ever
                           # read here, in this file's compilation unit
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $RunTestsContainerLane::WINDOWS_FAMILY;

    my $podman = RunTestsContainerLane::podman_bin();
    return map { _container_infra_result($_, 'no docker/podman CLI found on PATH') } @abs_files
        unless $podman;

    unless (RunTestsContainerLane::image_present($podman, $RunTestsContainerLane::IMAGE)) {
        return map { _container_infra_result($_,
            "image '$RunTestsContainerLane::IMAGE' is not present locally -- run the "
          . "interactive sandbox launcher once (plugins/sandbox/scripts/launcher.pl) to build it"
        ) } @abs_files;
    }

    RunTestsContainerLane::sweep_orphan_containers($podman);         # obligation (c)

    my $name = RunTestsContainerLane::new_container_name();
    {   # fix-batch A4's exact-name reclaim, mirrored from package 05's own main() step 5
        my ($ps_rc, $ps_out) =
            RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_ps_argv($podman));
        if ($ps_rc == 0 && defined $ps_out && $ps_out =~ /^\Q$name\E\s*$/m) {
            RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_rm_argv($podman, $name));
        }
    }

    my ($run_rc, undef) =
        RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_run_argv($podman, $name));
    return map { _container_infra_result($_, "podman run failed (rc=$run_rc)") } @abs_files
        if $run_rc != 0;

    {
        # SHOULD-FIX-1 (review, step 7): these two fully-qualified globals
        # are written here but only ever READ inside run-tests-container.pl's
        # own compilation unit, so this file's compiler flags them "used
        # only once" on every single invocation -- cosmetic, but this is the
        # repo's most-invoked script.
        no warnings 'once';
        $RunTestsContainerLane::ACTIVE_CONTAINER_NAME = $name;
        $RunTestsContainerLane::ACTIVE_PODMAN_BIN     = $podman;     # arms obligations (a)/(b)
    }

    my ($git_rc, $extract_rc) =
        RunTestsContainerLane::materialize_tree($podman, $name, 'HEAD', $ROOT_ABS);
    if ($git_rc != 0 || $extract_rc != 0) {
        RunTestsContainerLane::_cleanup_active_container();
        return map { _container_infra_result($_,
            "materialize_tree failed (git_rc=$git_rc, extract_rc=$extract_rc)") } @abs_files;
    }

    my @results;
    for my $abs (@abs_files) {
        my $rel = _relpath($abs);              # existing sub, reused verbatim
        my $r = RunTestsContainerLane::run_one_in_container($podman, $name, $rel);
        $r->{file} = $abs;                     # see section 2.4.1 -- overwrite the relpath
        push @results, $r;
    }

    RunTestsContainerLane::_cleanup_active_container();   # obligation (a)
    return @results;
}

# run_sweep(@argv) -> $exit_code -- everything that used to be this script's
# top-level executable flow, wrapped in one sub so merely `require`ing this
# file (as plugins/butler/tests/t/lane-routing.t must, to reach classify_file
# et al. directly) never runs a real sweep as a side effect of loading the
# file. Every `exit N;` below is a real, unchanged process exit, not a
# `return` -- converting them was judged a larger diff than any done
# criterion requires, and nothing in this package's own test plan ever calls
# run_sweep() (doing so would either run a real ~1000s sweep in-process or
# hit a bare exit() that kills the caller).
sub run_sweep {
    my @argv = @_;
    local @ARGV = @argv;

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
            @m = bsd_glob("$ROOT_ABS/$t")        unless @m;
            @m = bsd_glob("$ROOT_ABS/$t/tests/t/*.t") unless @m;
            push @files, grep { /\.t$/ && -f $_ } @m;
        }
    } else {
        push @files, bsd_glob("$ROOT_ABS/plugins/*/tests/t/*.t");
    }
    @files = sort @files;
    unless (@files) { print STDERR "no test files matched\n"; exit 2 }

    # MARKER GATE, SERIAL HEURISTIC, THEN MARKER VALUE -- classify_file() is
    # the sole routing predicate (spec section 2.1/2.6). A refused file never
    # spawned a process; it is synthesised as a red result below so it flows
    # through the existing report/state/exit-code machinery unchanged.
    my (@host_serial, @host_parallel, @container, @refused);
    for my $f (@files) {
        my $d = classify_file($f);
        unless (defined $d) { next }   # unreadable -- unchanged silent-skip precedent
        if    ($d->{lane} eq 'refused')       { push @refused,      { file => $f, marker => $d->{marker} } }
        elsif ($d->{lane} eq 'host-serial')   { push @host_serial,  $f }
        elsif ($d->{lane} eq 'host-parallel') { push @host_parallel,$f }
        else                                  { push @container,    $f }
    }
    @host_serial = () if $fast;   # UNCHANGED semantics -- @container is NEVER
                                   # emptied by --fast (spec section 2.8).

    # LANE-AVAILABILITY CAPABILITY GATE (Decision 18: a lane-availability
    # switch, never a routing switch -- classify_file() itself is pure of any
    # %ENV/@ARGV, so its per-file verdict can never be overridden by this or
    # any other flag). This decides only whether the container LANE is
    # reachable at all THIS run. Off by default: the container lane must be
    # reachable by an explicit opt-in, never by default (Decision 17),
    # because package 05's container lane only ever materializes a git ref
    # (default HEAD) -- routing to it by default would make an ordinary
    # sweep silently test the last commit instead of the working tree for
    # roughly two thirds of the suite. When the gate is off, every file
    # classify_file routed to 'container' simply runs on the host instead,
    # exactly as it did before this package existed (a non-serial any/linux
    # file was, and again is, just part of the parallel host set).
    # Deliberately an env var, not a new CLI flag (spec section 7's
    # "out of scope" list already forbids a routing-configuring flag; this
    # is a lane-availability switch, a different thing per Decision 18, and
    # the ledger wins where the two texts disagree -- see the oracle's own
    # header comment for the full adjudication).
    # FIX-BATCH M4 (step 7): a bare Perl truthiness test treated "false",
    # "no" and "off" as ON -- only "" and "0" are falsy to Perl, and none of
    # those three spellings are. An operator writing
    # CCPRAXIS_CONTAINER_LANE_ENABLED=false to explicitly OPT OUT landed
    # squarely in the lane instead. Recognize the operator's INTENT: only
    # 1/true/yes/on (case-insensitively) enable it; every other value,
    # including unset, "", "0", "false", "no" and "off", is OFF.
    my $lane_on = defined $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED}
               && $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED} =~ /^(?:1|true|yes|on)$/i;
    unless ($lane_on) {
        push @host_parallel, @container;
        @container = ();
    }

    $jobs = _resolve_jobs(
        explicit_jobs => $jobs,
        nice          => $nice,
        env_jobs      => $ENV{CCPRAXIS_TEST_JOBS},
        cores         => _cores(),
    );
    $jobs = scalar(@host_parallel) if $jobs > @host_parallel && @host_parallel;
    $jobs = 1 if $jobs < 1;

    my $start = time;
    my @results;

    # --- parallel phase ----------------------------------------------------
    # fork/waitpid with a result file per child: the MSYS2 perl on this host
    # has a real fork, but no shared memory, so children report through the
    # filesystem. The container-lane batch (when the capability gate above
    # left @container non-empty) runs as ONE additional forked child in the
    # SAME wave as the host-parallel workers -- it does not consume one of
    # the $jobs worker slots, and it is one of the things the waitpid loop
    # below drains before the serial phase starts, which is what makes the
    # container-lane batch and @host_serial never overlap in wall-clock
    # without any new synchronization (spec section 0.4/2.6).
    if (@host_parallel || @container) {
        require File::Temp;
        my $dir = File::Temp::tempdir(CLEANUP => 1);
        my (%pid_of, @queue);
        @queue = @host_parallel;
        my $i = 0;
        my %slot;
        my %is_batch;
        my %batch_files;   # id => \@container files that batch owned (H1: lets
                            # the reap loop synthesize infra results for every
                            # file in a batch whose child died/wrote nothing,
                            # instead of silently losing them from @results).

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

        if (@container) {
            my $id = $i++;               # same counter host-parallel children use
            my $pid = fork();
            if (!defined $pid) {
                # FIX-BATCH H2 (step 7): fork() returns undef on failure, and
                # this spawn used to test "$pid == 0" with no defined check --
                # undef == 0 is TRUE, so the code below ran the whole batch
                # INLINE in the sweep's own process and then called exit(0)
                # mid-sweep, before the report/state-write/serial phase ever
                # ran. The host-parallel spawn above already gets this right;
                # this one didn't. Never fall through to the child branch:
                # record an infra failure for every file this batch was going
                # to run and keep going.
                push @results, _container_infra_result($_,
                    'fork() failed for the container-lane batch child') for @container;
            } elsif ($pid == 0) {
                # FIX-BATCH H1 (step 7): a die anywhere inside
                # _run_container_batch (podman_bin, materialize_tree,
                # build_test_exec_argv's allow-list refusal, etc.) used to
                # kill this child with NO result file ever written, silently
                # erasing every file in the batch from @results while the
                # sweep printed "all green" and exited 0. Turn a die into the
                # same infra-failure shape the sub already uses for its own
                # "podman unavailable" cases instead of losing the batch.
                my @batch = eval { _run_container_batch(@container) };
                if ($@) {
                    my $err = $@;
                    $err =~ s/\s+\z//;
                    @batch = map { _container_infra_result($_, "container batch died: $err") } @container;
                }
                open my $o, '>', "$dir/$id" or exit 1;
                print {$o} join("\x1d", map {
                    join("\x1f", $_->{rc}, $_->{notok}, $_->{secs}, $_->{file}) . "\x1e" . $_->{out}
                } @batch);
                close $o;
                exit 0;
            } else {
                $slot{$pid} = $id;
                $is_batch{$id} = 1;          # tells the reap loop to split, not treat as one record
                $batch_files{$id} = [@container];
            }
        }

        $spawn->() for 1 .. $jobs;
        while (%slot) {
            my $pid = waitpid(-1, 0);
            last if $pid <= 0;
            my $id = delete $slot{$pid};
            my $handled = 0;
            if (defined $id && open my $in, '<', "$dir/$id") {
                my $raw = do { local $/; <$in> };
                close $in;
                if ($is_batch{$id}) {
                    my @chunks = grep { length } split /\x1d/, (defined $raw ? $raw : '');
                    if (@chunks) {
                        for my $chunk (@chunks) {
                            my ($head, $out) = split /\x1e/, $chunk, 2;
                            my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
                            push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                                             secs => $secs // 0, out => $out // '' };
                        }
                        $handled = 1;
                    }
                } else {
                    my ($head, $out) = split /\x1e/, (defined $raw ? $raw : ''), 2;
                    my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
                    push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                                     secs => $secs // 0, out => $out // '' };
                    $handled = 1;
                }
            }
            if (!$handled && defined $id && $is_batch{$id}) {
                # FIX-BATCH H1 (step 7): the batch child either never wrote
                # $dir/$id at all (killed before opening it) or wrote an
                # empty/unparseable file (e.g. it died between open() and the
                # first print). Either way, never let a dead batch child
                # silently erase every file it owned from @results.
                push @results, _container_infra_result($_,
                    'container-lane batch child produced no result for this file')
                    for @{ $batch_files{$id} // [] };
            }
            $spawn->();
        }
    }

    # --- serial phase ----------------------------------------------------------
    push @results, run_one($_) for @host_serial;

    # --- refused phase -----------------------------------------------------------
    push @results, _refusal_result($_) for @refused;

    # --- report ----------------------------------------------------------------
    my $wall = time - $start;
    my @red  = grep { $_->{rc} != 0 } @results;

    # NIT-1 (review, promoted for step 7): the container-lane batch's file
    # count used to be invisible in this breakdown (folded into the leading
    # %d files total but nowhere else), which makes the still-deferred
    # criterion-5 measurement (how many files actually went to the lane)
    # harder to read off than it needs to be. @container is already empty
    # here whenever the lane is off (folded into @host_parallel above), so
    # this is always accurate, never a phantom nonzero count.
    printf "\n%d files  %ds wall  (%d parallel at -j%d, %d serial, %d container)\n",
        scalar(@results), $wall, scalar(@host_parallel), $jobs, scalar(@host_serial), scalar(@container);

    if (@red) {
        print "\nRED:\n";
        for my $r (sort { $a->{file} cmp $b->{file} } @red) {
            printf "  %-52s exit=%-3d notok=%d%s\n", basename($r->{file}), $r->{rc}, $r->{notok},
                ($r->{refused}          ? '   <- refused: platform marker missing/invalid'
                 : $r->{container_infra} ? '   <- container lane unavailable, never run (see message)'
                 : $r->{notok} == 0      ? '   <- died, no failing assertion'
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
}

exit run_sweep(@ARGV) unless caller();
