#!/usr/bin/env perl
# bp-watch.pl — the general, condition-driven watcher for both interactive
# surfaces (/butler:reporter, /butler:drive-solo), armed ALONGSIDE each
# surface's existing mechanism, never replacing it.
#
# WHY THIS EXISTS
#
# Neither interactive surface can tell a healthy run from a dead one.
# Reporter blocks only on bp-wait-for-decision.pl, which wakes on a QUEUED
# decision -- the orchestrator dying, the container being reaped, a clean
# idle-exit with everything done, or a single package flipping to done never
# queue one, so none of them was ever noticed ({"status":"timeout"} returned
# twice against a dead orchestrator and zero coordinators, and would have
# forever). Drive-solo's bp-watchdog.pl is a single 30-minute timer whose
# progress scan walks the WHOLE blueprints tree with no subject-scoping
# argument at all, so a driver's own ledger edit reads as the worker's
# progress -- it reported VERDICT: PROGRESS three times during a real
# four-hour stall. bp-watch.pl closes both gaps: it exits on a named
# CONDITION (seconds, not up to thirty minutes), it is subject-scoped, and
# one arm covers a whole dispatch (--max-seconds sized to it, required, no
# default) instead of a universal timer requiring dozens of forgettable
# re-arms across one long run (2026-08-06 #11).
#
# THE FOUR INVARIANTS. Each was earned by a real shipped bug, and each is
# enforced here structurally, not by comment:
#
#   1. is_terminal_status() allowlists the TERMINAL set only
#      (done|dropped|blocked|parked). A first version allowlisted the LIVE
#      set instead, so free-text `converging` a coordinator actually wrote
#      into its frontmatter read as settled.
#   2. read_packages_dir() reads packages/*.md, NEVER runs/registry.json --
#      the registry only knows LAUNCHED packages. With 2 of 5 launched,
#      "all registry entries terminal" was reachable with three never run.
#   3. Liveness is PID-scoped via BpRunState::pid_alive (bp-runstate.pl,
#      kill(0)-then-tasklist), reused rather than reinvented. The shipped bug
#      was `ps -eo args | grep -c '[c]laude'`, which matched every bash
#      tool-call process through the shell-snapshot path -- the headline
#      death-detection feature could NEVER have fired.
#   4. artifact_snapshot()/artifact_changed() are scoped to the caller's
#      explicit @paths only, never a tree-wide mtime walk -- bp-watchdog.pl's
#      LIVE defect (snapshot(), bp-watchdog.pl:102-136), which let a driver's
#      own ledger writes manufacture false PROGRESS verdicts during a real
#      stall. bp-watchdog.pl is SUPERSEDED by this file for that role (see
#      its own header), not fixed in place.
#
# THE UMBRELLA RULE, stated once and inherited by all four: a watcher's
# errors must never resolve toward "finished"; uncertainty resolves to LIVE.
# resolve_condition() is where this is enforced in code: every axis that
# cannot positively confirm its condition (undef status, undef pids_alive
# because no PID axis is configured, artifact_changed false) is treated as
# absent evidence, never as a synonym for "confirmed" -- in particular,
# pids_alive => undef must never misread as pids_alive => 0 via bare Perl
# truthiness, which is exactly the trap the `defined` checks below exist to
# avoid.
#
# SHAPE. Mirrors bp-wait-for-decision.pl / bp-runstate.pl: a `package
# BpWatch;` block of pure, injectable-seam functions, `require`-able with
# zero real sleeping/filesystem writes to exercise the decision logic, and a
# `package main;` CLI behind `unless (caller)`.
#
# EXIT CODES ARE THE SIGNAL (unlike bp-watchdog.pl's always-0 convention) --
# a gate-drive-loop.sh-style consumer needs a cheap $?:
#   0  TERMINAL/SETTLED   subject (or whole blueprint, Mode B) reached the
#                         invariant-1 allowlist. Does not imply "never re-arm".
#   1  BOUND              --max-seconds elapsed, nothing resolved. Liveness
#                         is UNKNOWN -- never treat as dead or done.
#   2  WORKERS-GONE       any ONE configured pid confirmed dead, no terminal
#                         status observed. Likely crash; investigate.
#   3  ARTIFACT           a watched path's mtime advanced, or it appeared.
#   4  STATUS-CHANGE      ledger status changed to a NON-terminal value (a
#                         terminal value takes exit 0 instead).
#   64 USAGE ERROR
#   65 UNVERIFIABLE       data dir / blueprint / package not found, or a
#                         check itself failed. MUST be read as LIVE, never 0.
#
# --max-seconds is REQUIRED, no default -- bp-watchdog.pl's universal 1800s
# default is exactly the habit that produced dozens of forgettable 30-minute
# re-arms across one long dispatch. Sizing the bound to the actual dispatch
# is deliberate friction, not an oversight.
#
# --pid-file is RE-READ ON EVERY POLL TICK, never cached at arm time, so a
# marker that disappears (clean exit) or is replaced (a new orchestrator, a
# different pid) is picked up live.
#
# --keepawake (drive-solo only, opt-in) refreshes the EXISTING
# bp-keepawake.pl lease (the same .drive-solo/keepawake.pid bp-drive-next.pl
# already manages) once per poll tick -- it does not create a second lock.
# Closes the gap where that lease (900s) is refreshed only when the director
# runs, and the director is skipped whenever a wakeup is already pending, so
# a long watch window can outlive its own lease.

package BpWatch;
use strict;
use warnings;
use File::Basename ();
use Cwd ();

# The single allowlist. Everything else -- pending, running, reviewing,
# unknown free text a coordinator wrote -- is LIVE. INVARIANT 1. A POSITIVE
# allowlist, not a denylist of today's known-bad words (see t/133 B5).
my %TERMINAL = map { $_ => 1 } qw(done dropped blocked parked);

# MAJOR-4 (redteam-step6.md): the probe's common path (a candidate armed
# WITHOUT an explicit --max-seconds, which is the default and recommended
# shape) must not be structurally coupled to bp-runstate.pl -- package 03
# deletes that file, and main::DEFAULT_MAX_SECONDS()'s `require` would then
# raise inside the eval that calls it, silently turning every such candidate
# into a permanent 'undecidable' with no error surfaced anywhere (spec §3.8's
# laziness addresses COST only, not the structural dependency). Inlined here
# as a literal, matching bp-watch.pl's own currently-resolved value
# (BpRunState::MAX_PAUSE_SECONDS() - 100 == 50*60 - 100 == 2900) so the two
# cannot silently drift without a comment update on both sides. This is the
# value probe_scan actually uses; main::DEFAULT_MAX_SECONDS remains the
# derivation the CLI's own --arm path uses (and the one a caller-supplied
# opts->{default_max_seconds}, i.e. every test in this package, overrides).
use constant PROBE_DEFAULT_MAX_SECONDS => 2900;

sub is_terminal_status {
    my ($status) = @_;
    return 0 unless defined $status && length $status;
    return $TERMINAL{$status} ? 1 : 0;
}

# ledger_status($path) -- the exact frontmatter-only regex shape as
# bp-watchdog.pl:138-151's ledger_status(), reused in SHAPE (not by
# requiring that file, which is superseded doctrine, not a library this
# file should depend on).
sub _ledger_status {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $n = 0;
    my $status;
    while (my $line = <$fh>) {
        last if ++$n > 40;                # frontmatter only
        $line =~ s/\r?\n\z//;
        last if $n > 1 && $line =~ /^---\s*$/;
        if ($line =~ /^status:\s*(\S+)/) { $status = $1; last }
    }
    close $fh;
    return $status;
}

# read_packages_dir($blueprint_dir) -> \@[{id, status}]  IMPURE.
# INVARIANT 2: the denominator. Globs packages/*.md ONLY -- NEVER
# runs/registry.json, which knows only LAUNCHED packages. A ledger that
# fails to parse still produces an entry, with status => undef (unparseable
# reads as LIVE, never silently dropped from the denominator).
sub read_packages_dir {
    my ($bpdir) = @_;
    my $dir = defined $bpdir ? "$bpdir/packages" : undef;
    return [] unless defined $dir && -d $dir;
    opendir my $dh, $dir or return [];
    my @files = grep { /\.md$/ } readdir $dh;
    closedir $dh;
    my @out;
    for my $f (sort @files) {
        (my $id = $f) =~ s/\.md$//;
        push @out, { id => $id, status => _ledger_status("$dir/$f") };
    }
    return \@out;
}

# blueprint_settled(\@packages) -> bool. PURE. Empty list -> true
# (vacuous), same convention as bp-wait-for-decision::blueprint_terminal,
# but with the WIDER 4-value invariant-1 allowlist (a different question --
# see spec §3.7).
sub blueprint_settled {
    my ($packages) = @_;
    for my $p (@{ $packages || [] }) {
        return 0 unless is_terminal_status($p->{status});
    }
    return 1;
}

# settled_verdict(\@packages) -> 'settled' | 'pending' | 'unverifiable'.  PURE.
sub settled_verdict {
    my ($packages) = @_;
    return 'unverifiable' unless defined $packages && ref $packages eq 'ARRAY' && @$packages;
    return blueprint_settled($packages) ? 'settled' : 'pending';
}

# all_pids_alive(\@pids, $pid_alive_fn) -> 1 | 0 | undef.  PURE (given the
# injected callback). INVARIANT 3: reused liveness, never reimplemented --
# the caller MUST pass BpRunState::pid_alive (bp-runstate.pl:59-69) in
# production; this function defines no liveness primitive of its own.
# undef ("not applicable") iff the pid list is empty -- an empty list must
# never be read as "confirmed alive". 0 the MOMENT any one pid is dead.
sub all_pids_alive {
    my ($pids, $pid_alive_fn) = @_;
    return undef unless $pids && @$pids;
    for my $p (@$pids) {
        return 0 unless $pid_alive_fn->($p);
    }
    return 1;
}

# artifact_snapshot(\@paths) -> { path => mtime_or_undef, ... }  IMPURE.
# INVARIANT 4: scoped to exactly the paths handed in, never a tree-wide
# scan. A missing path -> undef, NEVER 0 (0 would collide with a real
# epoch-0 mtime and read as "always changed").
sub artifact_snapshot {
    my ($paths) = @_;
    my %snap;
    for my $p (@{ $paths || [] }) {
        my @st = stat($p);
        $snap{$p} = @st ? $st[9] : undef;
    }
    return \%snap;
}

# artifact_changed(\%before, \%after) -> bool.  PURE. True iff ANY path's
# mtime differs, including undef -> defined ("appeared").
sub artifact_changed {
    my ($before, $after) = @_;
    $before ||= {};
    $after  ||= {};
    for my $k (keys %$after) {
        my $b = $before->{$k};
        my $a = $after->{$k};
        next if !defined $b && !defined $a;
        return 1 if !defined $b || !defined $a;
        return 1 if $b != $a;
    }
    return 0;
}

# resolve_condition(\%signal) -> 'terminal' | 'workers-gone' | 'artifact'
#   | 'status-change' | 'bound' | undef
#
# THE UMBRELLA RULE (§0), enforced in code. \%signal:
#   status, prior_status, pids_alive (1|0|undef), artifact_changed (bool),
#   bound_hit (bool)
#
# Priority, evaluated in this exact order, first match wins:
#   1. status defined && is_terminal_status(status)     -> 'terminal'
#   2. pids_alive is DEFINED && == 0                     -> 'workers-gone'
#   3. artifact_changed                                  -> 'artifact'
#   4. status defined && prior_status defined && differ   -> 'status-change'
#   5. bound_hit                                          -> 'bound'
#   else                                                  -> undef (keep polling)
#
# pids_alive == undef must NEVER reach rule 2 -- bare Perl truthiness would
# treat undef as false and misfire there; the `defined` check is load-bearing.
sub resolve_condition {
    my ($sig) = @_;
    $sig ||= {};
    my $status       = $sig->{status};
    my $prior        = $sig->{prior_status};
    my $pids_alive   = $sig->{pids_alive};
    my $art_changed  = $sig->{artifact_changed};
    my $bound_hit    = $sig->{bound_hit};

    return 'terminal' if defined $status && is_terminal_status($status);
    return 'workers-gone' if defined $pids_alive && $pids_alive == 0;
    return 'artifact' if $art_changed;
    return 'status-change'
        if defined $status && defined $prior && $status ne $prior;
    return 'bound' if $bound_hit;
    return undef;
}

# format_change_line(\%prev, \%cur) -> $line | undef.  PURE. Compares
# status/pids_alive/artifact_changed_flag field by field; undef iff nothing
# differs -- criterion 4, "one line per state CHANGE, not per poll".
sub format_change_line {
    my ($prev, $cur) = @_;
    $prev ||= {};
    $cur  ||= {};
    my @diffs;
    for my $k (qw(status pids_alive artifact_changed_flag)) {
        my $p = $prev->{$k};
        my $c = $cur->{$k};
        my $pd = defined $p ? $p : '(undef)';
        my $cd = defined $c ? $c : '(undef)';
        push @diffs, "$k: $pd -> $cd" if $pd ne $cd;
    }
    return @diffs ? join('; ', @diffs) : undef;
}

## ===========================================================================
## `probe` verb -- package 01-live-watcher-probe (blueprint
## butler-gate-ergonomics). Answers "is a bounded watcher running for this
## project?" by reading live processes out of /proc. Pure seams below are
## driveable from a fixture tree with zero real processes; probe_scan is the
## sole IMPURE function (reads the filesystem only, spawns nothing). See
## .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/
## 01-live-watcher-probe-spec.md §2.3 for the full contract.
## ===========================================================================

# parse_proc_cmdline($raw) -> \@argv.  PURE.
# NUL-separated /proc cmdline -> argv. Trailing empty element (the file's
# own trailing NUL) is dropped. undef/empty -> [].
sub parse_proc_cmdline {
    my ($raw) = @_;
    return [] unless defined $raw && length $raw;
    my @parts = split /\0/, $raw, -1;
    pop @parts if @parts && $parts[-1] eq '';
    return \@parts;
}

# is_armed_watcher(\@argv) -> 0|1.  PURE.
# TRUE iff SOME element's basename is exactly bp-watch.pl AND SOME element is
# exactly '--arm'. Structurally excludes `bp-watch.pl probe` itself and every
# --help/usage invocation (neither carries --arm).
sub is_armed_watcher {
    my ($argv) = @_;
    my ($has_script, $has_arm) = (0, 0);
    for my $e (@{ $argv || [] }) {
        next unless defined $e;
        $has_script = 1 if $e =~ m{(?:^|[\\/])bp-watch\.pl$};
        $has_arm    = 1 if $e eq '--arm';
    }
    return ($has_script && $has_arm) ? 1 : 0;
}

# watcher_max_seconds(\@argv) -> ($secs, $err).  PURE.
sub watcher_max_seconds {
    my ($argv) = @_;
    my @a = @{ $argv || [] };
    for my $i (0 .. $#a) {
        next unless $a[$i] eq '--max-seconds';
        my $v = $a[$i + 1];
        if (defined $v && $v =~ /^\d+(?:\.\d+)?$/ && $v + 0 > 0) {
            return ($v + 0, undef);
        }
        return (undef, 'malformed');
    }
    return (undef, undef);
}

# watcher_subject(\@argv) -> $subject.  PURE.
# BLOCKER-2 (redteam-step6.md): a --package/--blueprint value containing
# whitespace (in particular a newline) must never reach the stdout line
# verbatim -- probe_format_lines' one-sprintf-per-watcher line format has no
# other delimiter protecting "subject=" from a value that itself LOOKS like a
# second, fully-attacker-controlled line (arbitrary pid, arbitrary started=).
# Any captured value containing whitespace is therefore treated the same as
# "could not be determined": '-'.  A record whose subject is '-' is written
# for traceability elsewhere but never matches anything (spec §2.5), so this
# is fail-safe, not merely fail-visible.
sub watcher_subject {
    my ($argv) = @_;
    my @a = @{ $argv || [] };
    my ($pkg, $bp);
    for my $i (0 .. $#a) {
        if    ($a[$i] eq '--package')   { $pkg = $a[$i + 1] }
        elsif ($a[$i] eq '--blueprint') { $bp  = $a[$i + 1] }
    }
    return '-' if defined $pkg && $pkg =~ /\s/;
    return '-' if defined $bp  && $bp  =~ /\s/;
    return '-' if defined $pkg && defined $bp;
    return "package:$pkg"   if defined $pkg && length $pkg;
    return "blueprint:$bp"  if defined $bp  && length $bp;
    return '-';
}

# proc_start_ticks($stat_text) -> $ticks | undef.  PURE.
# BpResumption::pid_fingerprint's /proc/<pid>/stat rule, verbatim: field 20
# (index 19) after the ")". This is technique REUSE, not a second, divergent
# liveness mechanism (AC10).
sub proc_start_ticks {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\)\s*(.*)$/s;
    my @f = split ' ', $1;
    return (defined $f[19] && $f[19] =~ /^\d+$/) ? $f[19] : undef;
}

# proc_ppid($stat_text) -> $ppid | undef.  PURE.
# Same file, field index 1 after the ")": the parent pid.
sub proc_ppid {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\)\s*(.*)$/s;
    my @f = split ' ', $1;
    return (defined $f[1] && $f[1] =~ /^\d+$/) ? $f[1] : undef;
}

# _normalize_dir_for_compare -- backslashes to '/', collapse '//', strip a
# trailing '/', map a leading drive letter to the posix-emulation spelling.
sub _normalize_dir_for_compare {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    my $n = $p;
    $n =~ s{\\}{/}g;
    $n =~ s{/{2,}}{/}g;
    $n =~ s{/\z}{} unless $n eq '/';
    $n =~ s{^([A-Za-z]):(/|$)}{'/' . lc($1) . $2}e;
    # Canonicalise through Cwd::abs_path when the path actually exists, so a
    # host-local mount/symlink alias (this MSYS host's own /tmp is one) does
    # not defeat comparison against the same directory reached a different
    # way (an explicit --data vs. a /proc/<pid>/cwd readlink). Falls back to
    # the textual form above for a path that no longer exists (already
    # exited watcher, synthetic fixture) or cannot be resolved.
    if (-d $n) {
        my $resolved = eval { Cwd::abs_path($n) };
        $n = $resolved if defined $resolved && length $resolved;
    }
    return $n;
}

# same_data_dir($a, $b) -> 0|1.  PURE apart from the realpath resolution
# above. Compared case-insensitively on the Windows/MSYS/Cygwin process
# family, case-sensitively elsewhere -- the ONLY platform conditional in
# this package (§5.5).
sub same_data_dir {
    my ($a, $b) = @_;
    my $na = _normalize_dir_for_compare($a);
    my $nb = _normalize_dir_for_compare($b);
    return 0 unless defined $na && defined $nb;
    return ($^O =~ /^(?:MSWin32|msys|cygwin)$/)
        ? (lc($na) eq lc($nb) ? 1 : 0)
        : ($na eq $nb ? 1 : 0);
}

# classify_candidate(\%cand) -> 'live' | 'expired' | 'foreign' | 'undecidable'
# PURE -- takes only precomputed fields, does no I/O of its own. Ordered
# rules (spec §3, behaviours 7/9/13/14/15). 'foreign' is checked FIRST: a
# candidate positively known to belong to a DIFFERENT project is a positive
# exclusion (9c), so its own stat/--max-seconds health is simply not this
# project's business -- an otherwise-malformed process belonging to another
# project must never pollute THIS project's verdict into cannot-tell. Once
# a candidate is confirmed to belong to THIS project (or its data dir could
# not be resolved at all), an unreadable/undef start-time (13) or a
# malformed --max-seconds (14) or an unresolvable data dir (15) is
# undecidable; otherwise age >= max_seconds is expired (7), else live.
#
# BLOCKER-1 (redteam-step6.md): a candidate's cmdline alone is a pure text
# test over /proc/<pid>/cmdline -- forgeable in one Bash call
# (`perl -e 'sleep 99999' bp-watch.pl --arm --max-seconds 99999`, argv
# containing those tokens as UNUSED trailing arguments to `perl -e`, never
# actually executing this file). So a candidate confirmed to belong to THIS
# project ('match') must ALSO be vouched for by the arm-time registry entry
# only the real --arm code path writes (see cmd_arm/probe_scan below) --
# same pid AND the same pid-reuse-safe start-ticks fingerprint
# (proc_start_ticks / BpResumption::pid_fingerprint's technique, reused
# rather than reinvented). No entry, or a mismatched fingerprint (pid
# reuse), is undecidable -- never live -- same posture as every other
# "cannot positively confirm" axis above it.
sub classify_candidate {
    my ($c) = @_;
    $c ||= {};
    return 'foreign'      if ($c->{data_status} // '') eq 'foreign';
    return 'undecidable' unless $c->{stat_ok};
    return 'undecidable' if defined $c->{max_seconds_error};
    return 'undecidable' if ($c->{data_status} // '') eq 'unresolvable';
    return 'undecidable' unless defined $c->{max_seconds};
    return 'undecidable' unless defined $c->{age};
    # BLOCKER-1's registry check gates 'live' only, not 'expired': a forged
    # candidate has nothing to gain from an EXPIRED classification (it
    # denies exactly like 'none'/'undecidable' would), so age math -- which
    # is not the axis a forger can abuse -- is allowed to decide first. Only
    # a candidate that would otherwise read 'live' (the exploitable branch,
    # BLOCKER-1's actual repro) is held to the registry requirement.
    return 'expired' if $c->{age} >= $c->{max_seconds};
    return 'undecidable' if ($c->{data_status} // '') eq 'match' && !$c->{registry_verified};
    return 'live';
}

# arm_registry_path($data_dir, $pid) -> $path.  PURE.
sub arm_registry_path {
    my ($data_dir, $pid) = @_;
    return "$data_dir/.watchers/arm-registry/$pid";
}

# arm_registry_verified($data_dir, $pid, $ticks) -> 0|1.  IMPURE (one file
# read). True iff a registry entry exists for $pid under $data_dir AND its
# recorded start-ticks equal $ticks (the candidate's CURRENT
# proc_start_ticks reading) -- the pid-reuse-safe check BLOCKER-1 requires.
sub arm_registry_verified {
    my ($data_dir, $pid, $ticks) = @_;
    return 0 unless defined $data_dir && defined $pid && defined $ticks;
    my $text = _probe_read_file(arm_registry_path($data_dir, $pid));
    return 0 unless defined $text;
    $text =~ s/\s+//g;
    return ($text =~ /^\d+$/ && $text == $ticks) ? 1 : 0;
}

# probe_verdict(\@classes) -> 'live' | 'none' | 'cannot-tell'.  PURE.
# 'live' wins over 'undecidable' (behaviour 4): a positive observation is
# never invalidated by an unrelated unknown.
sub probe_verdict {
    my ($classes) = @_;
    my @c = @{ $classes || [] };
    return 'live'        if grep { $_ eq 'live' }        @c;
    return 'cannot-tell' if grep { $_ eq 'undecidable' } @c;
    return 'none';
}

# probe_format_lines(\@watchers) -> \@lines.  PURE. §2.2 format, ascending
# pid, no trailing newlines.
# BLOCKER-2 belt-and-braces (redteam-step6.md's own suggested mitigation):
# even though watcher_subject already refuses to return a whitespace-bearing
# value, this is the last line of defense before the value is sprintf'd onto
# stdout -- refuse to emit ANY line whose subject would contain whitespace,
# falling back to '-' rather than ever emitting a forged second "line".
sub probe_format_lines {
    my ($watchers) = @_;
    my @w = sort { $a->{pid} <=> $b->{pid} } @{ $watchers || [] };
    my @lines;
    for my $w (@w) {
        my $subject = $w->{subject};
        $subject = '-' if !defined $subject || $subject =~ /\s/;
        push @lines, sprintf(
            '%d max=%d remaining=%d started=%d subject=%s data=%s',
            $w->{pid}, $w->{max}, $w->{remaining}, $w->{started},
            $subject, $w->{data_dir},
        );
    }
    return \@lines;
}

sub _probe_read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

# _probe_candidate_cwd($proc_dir, $pid) -> $dir | undef.  IMPURE.
# readlink first (the normal /proc/<pid>/cwd shape on this host's MSYS
# emulation and on real Linux), falling back to Cwd::abs_path for anything
# that presents cwd as a real directory entry rather than a symlink.
sub _probe_candidate_cwd {
    my ($proc_dir, $pid) = @_;
    my $link   = "$proc_dir/$pid/cwd";
    my $target = readlink($link);
    $target = Cwd::abs_path($link) unless defined $target;
    return (defined $target && -d $target) ? $target : undef;
}

# _probe_resolve_candidate_data_dir(\@argv, $proc_dir, $pid, $project_dir)
#   -> ($status, $resolved_dir)   $status: 'match' | 'foreign' | 'unresolvable'
# IMPURE. Mirrors bp-watch.pl's own two-rung ladder (§3.9): an explicit
# --data element (resolved against the candidate's cwd if relative), else
# the candidate's cwd walked up (<=12 levels) for a dir holding
# .ccpraxis-local-data. No CCPRAXIS_DATA_DIR rung -- cross-process
# environment is not reliably readable (§5.2), an accepted residual.
sub _probe_resolve_candidate_data_dir {
    my ($argv, $proc_dir, $pid, $project_dir) = @_;
    my @a = @{ $argv || [] };
    my $data_val;
    for my $i (0 .. $#a) {
        if ($a[$i] eq '--data') { $data_val = $a[$i + 1]; last }
    }

    my $resolved;
    if (defined $data_val && length $data_val) {
        if ($data_val =~ m{^(?:[A-Za-z]:[\\/]|[\\/])}) {
            $resolved = $data_val;
        }
        else {
            my $cwd = _probe_candidate_cwd($proc_dir, $pid);
            return ('unresolvable', undef) unless defined $cwd;
            $resolved = "$cwd/$data_val";
        }
    }
    else {
        my $cwd = _probe_candidate_cwd($proc_dir, $pid);
        return ('unresolvable', undef) unless defined $cwd;
        my $d = $cwd;
        my $found;
        for (1 .. 12) {
            if (-d "$d/.ccpraxis-local-data") { $found = "$d/.ccpraxis-local-data"; last }
            my $parent = File::Basename::dirname($d);
            last if $parent eq $d;
            $d = $parent;
        }
        return ('unresolvable', undef) unless defined $found;
        $resolved = $found;
    }

    return same_data_dir($resolved, $project_dir)
        ? ('match', $resolved)
        : ('foreign', $resolved);
}

# probe_scan(\%opts) -> \%result.  IMPURE (reads the filesystem only, spawns
# nothing). %opts: proc_dir, self_pid, clk_tck, project_data_dir (required),
# default_max_seconds, now, max_ancestor_hops. See spec §2.3/§3 for the full
# contract; every numbered failure path below cites its behaviour number.
sub probe_scan {
    my ($opts) = @_;
    $opts ||= {};
    my $proc_dir         = $opts->{proc_dir};
    my $self_pid         = $opts->{self_pid};
    my $clk_tck          = $opts->{clk_tck};
    my $project_data_dir = $opts->{project_data_dir};
    my $now              = defined $opts->{now} ? $opts->{now} : time();
    my $max_hops         = defined $opts->{max_ancestor_hops} ? $opts->{max_ancestor_hops} : 32;

    # behaviour 11: proc_dir missing/not-a-dir/opendir failure -> 2.
    unless (defined $proc_dir && -d $proc_dir) {
        return { verdict => 'cannot-tell', watchers => [],
                 reason  => 'proc dir not found or not a directory: '
                          . (defined $proc_dir ? $proc_dir : '(undef)') };
    }
    # behaviour 12: project data dir unresolved/not-a-dir -> 2.
    unless (defined $project_data_dir && -d $project_data_dir) {
        return { verdict => 'cannot-tell', watchers => [],
                 reason  => 'project data dir not found or not a directory: '
                          . (defined $project_data_dir ? $project_data_dir : '(undef)') };
    }
    # behaviour 16: clock ticks <= 0 or non-numeric -> 2, before scanning.
    unless (defined $clk_tck && $clk_tck =~ /^\d+(?:\.\d+)?$/ && $clk_tck > 0) {
        return { verdict => 'cannot-tell', watchers => [],
                 reason  => 'clock ticks unresolved (clk_tck='
                          . (defined $clk_tck ? $clk_tck : '(undef)') . ')' };
    }

    opendir(my $dh, $proc_dir) or return {
        verdict => 'cannot-tell', watchers => [],
        reason  => "cannot open proc dir: $proc_dir",
    };
    my @entries = readdir $dh;
    closedir $dh;

    # behaviour 6: self + ancestor chain excluded, walked via proc_ppid, NOT
    # getppid() (documented elsewhere in this repo as unreliable here).
    my %excluded;
    if (defined $self_pid && $self_pid =~ /^\d+$/) {
        $excluded{$self_pid} = 1;
        my %seen = ($self_pid => 1);
        my $cur  = $self_pid;
        for (1 .. $max_hops) {
            my $stat_text = _probe_read_file("$proc_dir/$cur/stat");
            last unless defined $stat_text;
            my $ppid = proc_ppid($stat_text);
            last unless defined $ppid;
            last if $ppid <= 1;
            last if $seen{$ppid};
            $excluded{$ppid} = 1;
            $seen{$ppid}     = 1;
            $cur = $ppid;
        }
    }

    # The self pid's own start-time tick counter is the age reference
    # ("now", in ticks): a fresh probe process starts essentially when the
    # scan runs, so (self_ticks - candidate_ticks)/clk_tck is age in seconds
    # with no dependency on any wall-clock/uptime file. Resolved lazily --
    # only the first candidate that actually needs it pays for the read.
    my ($self_ticks, $self_ticks_done);
    my $resolve_self_ticks = sub {
        return $self_ticks if $self_ticks_done;
        $self_ticks_done = 1;
        return undef unless defined $self_pid;
        my $stat_text = _probe_read_file("$proc_dir/$self_pid/stat");
        return undef unless defined $stat_text;
        $self_ticks = proc_start_ticks($stat_text);
        return $self_ticks;
    };

    # behaviour 8 / MAJOR-4: default resolved lazily -- only when some
    # candidate actually lacks --max-seconds. A caller-supplied
    # opts->{default_max_seconds} (every test in this package) is used
    # directly; otherwise PROBE_DEFAULT_MAX_SECONDS, a literal constant with
    # NO runtime dependency on bp-runstate.pl (see that constant's own
    # comment for why: package 03 deletes that file, and the probe's common
    # path must survive its removal, not degrade to a silent permanent
    # cannot-tell).
    my ($lazy_default_max, $default_resolved);
    my $resolve_default_max = sub {
        return $lazy_default_max if $default_resolved;
        $default_resolved = 1;
        $lazy_default_max = defined $opts->{default_max_seconds}
            ? $opts->{default_max_seconds}
            : PROBE_DEFAULT_MAX_SECONDS;
        return $lazy_default_max;
    };

    my (@classes, @watchers);
    for my $ent (@entries) {
        # behaviour 20: cheap reject first -- numeric readdir entries only.
        next unless $ent =~ /^\d+$/;
        next if $excluded{$ent};

        # behaviour 20: cmdline read before stat. behaviour 18: a pid that
        # vanishes mid-scan (cmdline unreadable) is skipped silently, never
        # undecidable -- a process exiting during a scan is the normal race.
        my $raw = _probe_read_file("$proc_dir/$ent/cmdline");
        next unless defined $raw;
        my $argv = parse_proc_cmdline($raw);
        # behaviour 5: --arm is required; this is what structurally excludes
        # `bp-watch.pl probe` itself and any non-arming invocation.
        next unless is_armed_watcher($argv);

        # --- matched behaviour 5: this pid is a real candidate now ---
        my $stat_text = _probe_read_file("$proc_dir/$ent/stat");
        my $ticks      = defined $stat_text ? proc_start_ticks($stat_text) : undef;
        my $stat_ok    = defined $ticks ? 1 : 0;

        my ($max_secs, $max_err) = watcher_max_seconds($argv);
        if (!defined $max_secs && !defined $max_err) {
            $max_secs = $resolve_default_max->();
        }

        my ($data_status, $resolved_dir) =
            _probe_resolve_candidate_data_dir($argv, $proc_dir, $ent, $project_data_dir);

        my $age;
        if ($stat_ok) {
            my $ref = $resolve_self_ticks->();
            if (defined $ref) {
                $age = ($ref - $ticks) / $clk_tck;
                $age = 0 if $age < 0;   # behaviour 7: negative age clamped to 0
            }
            else {
                $stat_ok = 0;           # reference unresolvable -> undecidable
            }
        }

        # BLOCKER-1: only checked (and only matters) for a candidate already
        # confirmed to belong to THIS project -- classify_candidate ignores
        # it for 'foreign'/'unresolvable'. $project_data_dir, not
        # $resolved_dir: a real arm always registers itself under the data
        # dir IT resolved, which for a 'match' candidate is the same
        # directory by definition (same_data_dir already confirmed it).
        my $registry_verified = ($stat_ok && $data_status eq 'match')
            ? arm_registry_verified($project_data_dir, $ent, $ticks)
            : 0;

        my $class = classify_candidate({
            stat_ok            => $stat_ok,
            max_seconds        => $max_secs,
            max_seconds_error  => $max_err,
            data_status        => $data_status,
            registry_verified  => $registry_verified,
            age                => $age,
        });
        push @classes, $class;

        if ($class eq 'live') {
            my $remaining = $max_secs - $age;
            $remaining = 0 if $remaining < 0;
            push @watchers, {
                pid      => $ent + 0,
                max      => int($max_secs),
                remaining => int($remaining),
                started  => int($now - $age),
                subject  => watcher_subject($argv),
                data_dir => $resolved_dir,
            };
        }
    }

    my $verdict = probe_verdict(\@classes);
    return { verdict => 'live', watchers => \@watchers, reason => undef }
        if $verdict eq 'live';
    return { verdict => 'none', watchers => [], reason => undef }
        if $verdict eq 'none';
    return { verdict => 'cannot-tell', watchers => [],
             reason  => 'one or more armed candidates could not be classified '
                      . '(unreadable stat, malformed --max-seconds, or an unresolvable data dir)' };
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use POSIX ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

sub usage {
    print STDERR <<'USAGE';
usage: bp-watch.pl --arm [--max-seconds N] (--package BP/PKGID | --blueprint BP)
                    [--pid-file PATH | --expect-pids P1,P2,...]
                    [--artifact PATH[:PATH...]] [--poll SECS] [--data DIR]
                    [--keepawake] [--self-pause [--reason TEXT]]
       bp-watch.pl probe [--data DIR]

--max-seconds defaults to 2900 (matching BpRunState::pause's own 50-minute
cap) when omitted. Passing a SHORTER --max-seconds requires --reason TEXT
saying why; a longer one needs none.

--max-seconds is REQUIRED, no default.

Exit codes:
  0 TERMINAL/SETTLED  1 BOUND  2 WORKERS-GONE  3 ARTIFACT  4 STATUS-CHANGE
  64 USAGE ERROR      65 UNVERIFIABLE (data/blueprint/package not found)

probe exit codes:
  0 LIVE (at least one live bounded watcher)  1 NONE  2 CANNOT-TELL
USAGE
}

# _resolve_probe_data_dir($data_opt) -> $dir.  Mirrors this file's own
# --data/CCPRAXIS_DATA_DIR/walk-up ladder (:450-457) plus the project-root
# rungs bp-drive-next.pl::_resolve_project_root documents -- never
# script-relative. behaviour 19: git rev-parse runs ONLY on this last rung,
# and only when neither --data nor CCPRAXIS_DATA_DIR was given.
sub _resolve_probe_data_dir {
    my ($data_opt) = @_;
    return $data_opt if defined $data_opt && length $data_opt;
    return $ENV{CCPRAXIS_DATA_DIR}
        if defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR};

    my $root = $ENV{BP_PROJECT_ROOT};
    if (!defined $root || !length $root) {
        my $out = `git rev-parse --show-toplevel 2>/dev/null`;
        if (defined $out) {
            my $ok = ($? == 0);
            $out =~ s/\r?\n\z//;
            $root = $out if $ok && length $out;
        }
    }
    if (!defined $root || !length $root) {
        my $d = '.';
        my $found;
        for (1 .. 12) {
            if (-d "$d/.ccpraxis-local-data") { $found = $d; last }
            $d = "$d/..";
        }
        $root = defined $found ? $found : '.';
    }
    return "$root/.ccpraxis-local-data";
}

# _cmd_probe(\@argv) -> $exit_code.  The thin CLI wrapper (spec §2.3): build
# %opts, call probe_scan INSIDE an eval (behaviour 17 -- any exception
# anywhere becomes 2, never a crash), print, return the exit code.
sub _cmd_probe {
    my ($rest) = @_;
    my @unknown;
    my $data_opt;
    my $data_missing_value = 0;
    while (@$rest) {
        my $a = shift @$rest;
        if ($a eq '--data') {
            # MINOR-5 (redteam-step6.md): a missing or empty --data value
            # must not silently fall through to the CCPRAXIS_DATA_DIR/
            # git-toplevel ladder and probe a DIFFERENT directory with a
            # confident answer -- spec §2.1's "malformed argument -> exit
            # 64" covers this shape too, not just an unrecognised flag.
            $data_opt = shift @$rest;
            $data_missing_value = 1 unless defined $data_opt && length $data_opt;
        }
        else { push @unknown, $a }
    }
    if (@unknown || $data_missing_value) {
        print STDERR "bp-watch: unknown option(s): @unknown\n" if @unknown;
        print STDERR "bp-watch: --data requires a non-empty DIR value\n" if $data_missing_value;
        usage();
        return 64;
    }

    my $result = eval {
        my $DATA = _resolve_probe_data_dir($data_opt);
        die "project data dir not found or not a directory: "
            . (defined $DATA ? $DATA : '(undef)') . "\n"
            unless defined $DATA && -d $DATA;

        my $proc_dir = $ENV{BP_PROBE_PROC_DIR};
        $proc_dir = '/proc' unless defined $proc_dir && length $proc_dir;

        my $self_pid = $ENV{BP_PROBE_SELF_PID};
        $self_pid = $$ unless defined $self_pid && length $self_pid;

        my $clk_tck = $ENV{BP_PROBE_CLK_TCK};
        unless (defined $clk_tck && length $clk_tck) {
            $clk_tck = eval { POSIX::sysconf(&POSIX::_SC_CLK_TCK) };
            $clk_tck = 100 unless defined $clk_tck && $clk_tck > 0;
        }

        my $r = BpWatch::probe_scan({
            proc_dir          => $proc_dir,
            self_pid          => $self_pid,
            clk_tck           => $clk_tck,
            project_data_dir  => $DATA,
            now               => time(),
            max_ancestor_hops => 32,
        });
        $r->{_data} = $DATA;
        return $r;
    };

    if (!$result || ref($result) ne 'HASH') {
        my $msg = defined $@ && length $@ ? $@ : 'unknown error';
        $msg =~ s/\s+\z//;
        print "CANNOT-TELL: internal error: $msg\n";
        return 2;
    }

    my $verdict = $result->{verdict} || 'cannot-tell';
    if ($verdict eq 'live') {
        my $lines = BpWatch::probe_format_lines($result->{watchers} || []);
        print "$_\n" for @$lines;
        return 0;
    }
    elsif ($verdict eq 'none') {
        my $data_shown = defined $result->{_data} ? $result->{_data} : '';
        print "NONE: no live bounded bp-watch.pl watcher for data=$data_shown\n";
        return 1;
    }
    else {
        my $reason = defined $result->{reason} && length $result->{reason}
            ? $result->{reason} : 'unspecified';
        print "CANNOT-TELL: $reason\n";
        return 2;
    }
}

# _split_artifact_paths($csv) -> @paths
# Splits on ':', but a single-letter segment immediately followed by
# another segment is a Windows drive letter ("C" + "/Users/...") and is
# glued back together -- ':' is both the spec's separator AND the character
# every Windows absolute path contains right after its drive letter, so a
# naive split would shred "C:/Users/x/p1.md" into "C" and "/Users/x/p1.md".
sub _split_artifact_paths {
    my ($csv) = @_;
    return () unless defined $csv && length $csv;
    my @segs = split /:/, $csv, -1;
    my @out;
    my $i = 0;
    while ($i < @segs) {
        my $seg = $segs[$i];
        if ($seg =~ /^[A-Za-z]$/ && $i + 1 < @segs) {
            $seg = "$seg:" . $segs[$i + 1];
            $i++;
        }
        push @out, $seg;
        $i++;
    }
    return @out;
}

sub _read_pidfile {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    return ($line =~ /(\d+)/) ? $1 : undef;
}

unless (caller) {
    # `probe` is recognised ONLY as $ARGV[0], dispatched before the existing
    # option loop runs (spec §2.1) -- a guarded early return that does not
    # reorder, rename or re-message anything the loop below does. Anywhere
    # else, "probe" remains an unrecognised token -> the existing "any
    # non-flag token is an unknown option" rule, exit 64, unchanged (AC14).
    if (@ARGV && $ARGV[0] eq 'probe') {
        shift @ARGV;
        exit _cmd_probe(\@ARGV);
    }

    my %opt = (poll => 5);
    my @unknown;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--arm')         { $opt{arm} = 1 }
        elsif ($a eq '--package')     { $opt{package}     = shift @ARGV }
        elsif ($a eq '--blueprint')   { $opt{blueprint}    = shift @ARGV }
        elsif ($a eq '--max-seconds') { $opt{max_seconds}  = shift @ARGV }
        elsif ($a eq '--pid-file')    { $opt{pid_file}     = shift @ARGV }
        elsif ($a eq '--expect-pids') { $opt{expect_pids}  = shift @ARGV }
        elsif ($a eq '--artifact')    { $opt{artifact}     = shift @ARGV }
        elsif ($a eq '--poll')        { $opt{poll}         = shift @ARGV }
        elsif ($a eq '--data')        { $opt{data}         = shift @ARGV }
        elsif ($a eq '--keepawake')   { $opt{keepawake}    = 1 }
        elsif ($a eq '--self-pause')  { $opt{self_pause}   = 1 }
        elsif ($a eq '--reason')      { $opt{reason}       = shift @ARGV }
        else                          { push @unknown, $a }
    }
    if (@unknown) {
        print STDERR "bp-watch: unknown option(s): @unknown\n";
        usage();
        exit 64;
    }

    # DEFAULT_MAX_SECONDS: what --max-seconds defaults to when omitted.
    # Derived from BpRunState::MAX_PAUSE_SECONDS (the same cap --self-pause
    # clamps to), minus headroom for this watch's own round trip -- not an
    # independent literal, so the two can't silently drift apart. Operator
    # ruling 2026-09-19: this REPLACES the old "REQUIRED, no default" rule,
    # which guarded against a different failure (bp-watchdog.pl's fixed
    # 30-minute RE-POLL TICK manufacturing false verdicts from unchanged
    # state -- this file's poll loop exits the moment its condition
    # resolves, so the bound is a ceiling, never a repeating tick). Forcing
    # a number on every call instead produced its own regression: guessed
    # low, re-armed often. A SHORTER override needs --reason TEXT (so a
    # hallucinated "this'll be fast" is at least visible); a longer one
    # needs none, since --self-pause clamps it to the same cap regardless.
    # require lives INSIDE the sub, not above it: bp-watch-cli.t's own A1d
    # test calls this via `require bp-watch.pl` from a caller() context,
    # which skips this whole unless(caller) body -- a require statement out
    # here would never run for that caller, leaving BpRunState unloaded.
    sub DEFAULT_MAX_SECONDS {
        require "$DIR/bp-runstate.pl";
        return BpRunState::MAX_PAUSE_SECONDS() - 100;
    }

    my $max_seconds;
    if (defined $opt{max_seconds} && length $opt{max_seconds}) {
        unless ($opt{max_seconds} =~ /^\d+(?:\.\d+)?$/ && $opt{max_seconds} > 0) {
            print STDERR "bp-watch: --max-seconds must be a positive number "
                        . "(got '$opt{max_seconds}')\n";
            usage();
            exit 64;
        }
        $max_seconds = $opt{max_seconds} + 0;
        if ($max_seconds < DEFAULT_MAX_SECONDS
                && !(defined $opt{reason} && length $opt{reason})) {
            print STDERR "bp-watch: --max-seconds $max_seconds is below the "
                        . DEFAULT_MAX_SECONDS . "s default and needs --reason TEXT saying why "
                        . "this dispatch specifically warrants a shorter bound -- a bare shorter "
                        . "number, with no stated reason, is refused rather than silently "
                        . "trusted (this guards against exactly the guessed-low-and-re-armed"
                        . "-repeatedly shape a real driver session built its own throwaway "
                        . "watcher for instead of using this flag).\n";
            usage();
            exit 64;
        }
    }
    else {
        $max_seconds = DEFAULT_MAX_SECONDS;
    }

    my $mode;
    my ($bpname, $pkgid);
    if (defined $opt{package} && defined $opt{blueprint}) {
        print STDERR "bp-watch: pass exactly one of --package or --blueprint, not both\n";
        exit 64;
    }
    elsif (defined $opt{package}) {
        $mode = 'package';
        ($bpname, $pkgid) = split m{/}, $opt{package}, 2;
        unless (defined $bpname && length $bpname && defined $pkgid && length $pkgid) {
            print STDERR "bp-watch: --package expects BLUEPRINT/PACKAGE-ID\n";
            exit 64;
        }
    }
    elsif (defined $opt{blueprint}) {
        $mode = 'blueprint';
        $bpname = $opt{blueprint};
    }
    else {
        print STDERR "bp-watch: one of --package BP/PKGID or --blueprint BP is required\n";
        exit 64;
    }

    if (defined $opt{poll}
        && !($opt{poll} =~ /^\d+(?:\.\d+)?$/ && $opt{poll} > 0)) {
        print STDERR "bp-watch: --poll must be a positive number if given "
                    . "(got '$opt{poll}')\n";
        usage();
        exit 64;
    }
    my $poll = defined $opt{poll} ? $opt{poll} + 0 : 5;

    my @expect_pids;
    if (defined $opt{expect_pids}) {
        # Every comma-separated entry MUST be a strictly positive integer.
        # "0" is not a real pid -- BpRunState::pid_alive treats pid 0 as
        # unconditionally dead, so silently accepting it turned a caller's
        # bug (a failed pgrep, a $?/$! mix-up) into an instant, false
        # WORKERS-GONE verdict. A malformed entry (whitespace, non-numeric,
        # 0, negative) is a USAGE error (64) here -- never silently dropped,
        # which would just as silently reduce liveness coverage below what
        # the caller asked for.
        my @raw = split /,/, $opt{expect_pids}, -1;
        my @bad;
        for my $p (@raw) {
            if ($p =~ /^[1-9]\d*$/) { push @expect_pids, $p }
            else                    { push @bad, $p }
        }
        if (@bad) {
            print STDERR "bp-watch: --expect-pids entries must be positive integers "
                        . "(bad: " . join(',', map { "'$_'" } @bad) . ")\n";
            usage();
            exit 64;
        }
    }

    my @art_paths = defined $opt{artifact} ? _split_artifact_paths($opt{artifact}) : ();

    # --- data dir resolution: matches bp-watchdog.pl:83-90 /
    #     bp-wait-for-decision.pl:396-404 verbatim, for consistency. ---
    my $DATA = $opt{data} || $ENV{CCPRAXIS_DATA_DIR} || '';
    if (!$DATA) {
        my $d = '.';
        for (1 .. 12) {
            if (-d "$d/.ccpraxis-local-data") { $DATA = "$d/.ccpraxis-local-data"; last }
            $d = "$d/..";
        }
    }
    unless ($DATA && -d $DATA) {
        print "UNVERIFIABLE: no .ccpraxis-local-data found -- liveness unknown, never treat as done\n";
        exit 65;
    }

    my $bpdir = "$DATA/blueprints/$bpname";
    unless (-d $bpdir) {
        print "UNVERIFIABLE: blueprint '$bpname' not found under $DATA/blueprints -- "
            . "liveness unknown, never treat as done\n";
        exit 65;
    }

    my %arm_pkg_ids;

    if ($mode eq 'package') {
        my $pkgs = BpWatch::read_packages_dir($bpdir);
        my ($entry) = grep { $_->{id} eq $pkgid } @$pkgs;
        unless ($entry) {
            print "UNVERIFIABLE: package '$pkgid' not found in $bpname/packages -- "
                . "liveness unknown, never treat as done\n";
            exit 65;
        }
    }
    else {
        # Mode B startup check (umbrella rule, driver ruling on B1/CRITICAL):
        # blueprint_settled([]) is vacuously true BY DESIGN for a genuinely
        # empty packages/ dir (spec §2.1, pinned by t/133 C6/C7) -- but a
        # MISSING or not-yet-populated packages/ dir is a different question:
        # the denominator itself is unreadable, not "confirmed zero". Both
        # shapes must be UNVERIFIABLE (65) here, checked once before the
        # first tick, mirroring Mode A's missing-package-entry check above --
        # never let an unreadable denominator be handed to blueprint_settled
        # as if it were a real, observed empty set.
        my $pkgdir = "$bpdir/packages";
        unless (-d $pkgdir) {
            print "UNVERIFIABLE: blueprint '$bpname' has no packages/ directory -- "
                . "liveness unknown, never treat as done\n";
            exit 65;
        }
        my $pkgs = BpWatch::read_packages_dir($bpdir);
        unless (@$pkgs) {
            print "UNVERIFIABLE: blueprint '$bpname' packages/ directory has no *.md entries "
                . "yet -- liveness unknown, never treat as done\n";
            exit 65;
        }
        # MEDIUM-2 (redteam, 12-waits-check-liveness fix-batch): capture the
        # arm-time denominator once, while the tree is known-good, so a later
        # PARTIAL unreadable-dir read (a strict subset of these ids) can be
        # told apart from a genuinely smaller, real package set.
        %arm_pkg_ids = map { $_->{id} => 1 } @$pkgs;
    }

    # INVARIANT 3: reused, not reimplemented. BpRunState::pid_alive is the
    # ONLY liveness primitive this file calls.
    require "$DIR/bp-runstate.pl";

    # BLOCKER-1 (redteam-step6.md): record THIS process's own pid-reuse-safe
    # fingerprint NOW, at the moment this file actually starts running
    # armed -- not merely when some argv happens to contain '--arm'. The
    # red-team repro (`perl -e 'sleep 99999' bp-watch.pl --arm
    # --max-seconds 99999`) never executes this file at all, so it can
    # never reach this line and can never make this registry vouch for its
    # pid. `probe`'s classify_candidate (above) now refuses to classify a
    # same-project candidate as 'live' without a matching entry here --
    # same pid AND the same start-ticks read off /proc/<pid>/stat field 20
    # (proc_start_ticks, reused verbatim -- the same technique
    # BpResumption::pid_fingerprint uses elsewhere in this codebase).
    #
    # BEST-EFFORT, NEVER FATAL: this must not stop a legitimate watch from
    # proceeding (the file's own FAIL OPEN posture). Worst case on failure
    # (no /proc, an unwritable data dir): this pid reads as undecidable
    # rather than live, which the Stop gates already treat as "cannot tell
    # -> allow" (Decision 3) -- the safe direction, not a new wedge.
    eval {
        my $reg_dir = "$DATA/.watchers/arm-registry";
        require File::Path;
        File::Path::make_path($reg_dir);
        my $stat_text;
        if (open my $sfh, '<', "/proc/$$/stat") {
            local $/;
            $stat_text = <$sfh>;
            close $sfh;
        }
        my $ticks = defined $stat_text ? BpWatch::proc_start_ticks($stat_text) : undef;
        if (defined $ticks && open(my $rfh, '>', "$reg_dir/$$")) {
            print {$rfh} "$ticks\n";
            close $rfh;
        }
        1;
    };

    # --self-pause: register THIS process (its own real pid, not a caller's
    # guess) as the guard-subagent-stall.sh watcher, via BpRunState::pause
    # in-process -- no subprocess, no second `ps` lookup. See that function's
    # own header for the incident this avoids (a hand-rolled watcher built
    # instead of using this flag) and the pause cap this doesn't duplicate.
    if ($opt{self_pause}) {
        my $watching = sprintf('%s %s (max %ss)', $mode, ($mode eq 'package' ? $opt{package} : $bpname), $max_seconds);
        # $DATA is the resolved .ccpraxis-local-data dir (respects --data /
        # CCPRAXIS_DATA_DIR / walk-up, same as everything else in this file);
        # BpRunState wants its PARENT (the project root) -- passing undef here
        # would instead auto-resolve via git-toplevel/cwd, silently targeting
        # the WRONG root whenever --data points somewhere else (a test
        # fixture, a non-default project layout). Must stay the same root
        # this watch itself is reading from, or a caller who disagrees with
        # the pause can never find where it actually landed.
        require File::Basename;
        my ($ok, $msg) = BpRunState::pause(File::Basename::dirname($DATA),
            watcher_pid => $$,
            until       => time + $max_seconds,
            watching    => $watching,
            reason      => ($opt{reason} // "bp-watch.pl self-armed, watching $watching"),
        );
        print STDERR "bp-watch: --self-pause: $msg\n";
        # Non-fatal on refusal (e.g. a race on the state file) -- the watch
        # itself is still valid and still worth running; a caller relying on
        # the pause should check this line, but a failed self-pause must
        # never stop a legitimate watch from proceeding.
    }

    my $art_before = @art_paths ? BpWatch::artifact_snapshot(\@art_paths) : {};

    my $t0 = time;
    my $prior_status;

    while (1) {
        my $elapsed   = time - $t0;
        my $bound_hit = ($elapsed >= $max_seconds) ? 1 : 0;

        my $status;
        if ($mode eq 'package') {
            my $pkgs = BpWatch::read_packages_dir($bpdir);
            my ($entry) = grep { $_->{id} eq $pkgid } @$pkgs;
            $status = $entry ? $entry->{status} : undef;
        }
        else {
            my $pkgs = BpWatch::read_packages_dir($bpdir);
            # MEDIUM-2: a tick whose observed id set is a STRICT SUBSET of the
            # arm-time set is a partial/unreadable read, not a real shrink --
            # treat it as unverifiable rather than handing it to
            # settled_verdict, which is only zero-aware, not denominator-aware.
            my %seen_ids = map { $_->{id} => 1 } @$pkgs;
            my $partial = (keys %seen_ids) < (keys %arm_pkg_ids)
                && !grep { !$arm_pkg_ids{$_} } keys %seen_ids;
            my $verdict = $partial ? 'unverifiable' : BpWatch::settled_verdict($pkgs);
            $status = ($verdict eq 'settled') ? 'done' : undef;
        }

        # --pid-file is RE-READ every tick (never cached at arm time).
        my @cur_pids;
        if (defined $opt{pid_file}) {
            my $p = _read_pidfile($opt{pid_file});
            @cur_pids = defined $p ? ($p) : ();
        }
        elsif (@expect_pids) {
            @cur_pids = @expect_pids;
        }
        my $pids_alive = BpWatch::all_pids_alive(\@cur_pids, \&BpRunState::pid_alive);

        my $art_changed = 0;
        if (@art_paths) {
            my $art_after = BpWatch::artifact_snapshot(\@art_paths);
            $art_changed = BpWatch::artifact_changed($art_before, $art_after) ? 1 : 0;
        }

        my $cond = BpWatch::resolve_condition({
            status           => $status,
            prior_status     => $prior_status,
            pids_alive       => $pids_alive,
            artifact_changed => $art_changed,
            bound_hit        => $bound_hit,
        });

        if (defined $cond) {
            if ($cond eq 'terminal') {
                if ($mode eq 'package') {
                    print "TERMINAL: package $bpname/$pkgid reached status '"
                        . (defined $status ? $status : '') . "'\n";
                }
                else {
                    print "TERMINAL (SETTLED): blueprint $bpname -- every package/*.md "
                        . "entry reached a terminal status\n";
                }
                exit 0;
            }
            elsif ($cond eq 'workers-gone') {
                print "WORKERS-GONE: a watched pid is confirmed dead and no terminal status "
                    . "was observed. Likely crash -- investigate before re-arming.\n";
                exit 2;
            }
            elsif ($cond eq 'artifact') {
                print "ARTIFACT: a watched path changed (@art_paths)\n";
                exit 3;
            }
            elsif ($cond eq 'status-change') {
                print "STATUS-CHANGE: $bpname/$pkgid status changed from '"
                    . (defined $prior_status ? $prior_status : '(none)') . "' to '"
                    . (defined $status ? $status : '') . "' (non-terminal)\n";
                exit 4;
            }
            elsif ($cond eq 'bound') {
                print "BOUND: --max-seconds elapsed with nothing resolved. Subject liveness "
                    . "is UNKNOWN -- never treat as dead or done.\n";
                exit 1;
            }
        }

        if ($opt{keepawake}) {
            # --keepawake REFRESHES the EXISTING bp-keepawake.pl lease (the
            # same .drive-solo/keepawake.pid bp-drive-next.pl already
            # manages) -- it must never become a second, independent
            # lock-holder. BpKeepAwake::apply() alone can't guarantee that:
            # with no pid file present (or a stale one), its own
            # idempotence check falls through to spawn() and creates a
            # FRESH wake-lock. Gate the call here: only refresh a lease that
            # is already held by a genuinely live pid; a missing/stale
            # lease is a no-op for this flag, never a spawn trigger. The
            # director (bp-drive-next.pl) remains the only thing that ever
            # creates the FIRST lease.
            my $lease_f      = "$DATA/.drive-solo/keepawake.pid";
            my $existing_pid = _read_pidfile($lease_f);
            if (defined $existing_pid && BpRunState::pid_alive($existing_pid)) {
                eval {
                    require "$DIR/bp-keepawake.pl";
                    BpKeepAwake::apply('active', "$DATA/.drive-solo", {});
                };
            }
        }

        $prior_status = $status if $mode eq 'package';

        # Clamp the sleep to what's left of --max-seconds -- a single sleep
        # must never carry the process past its own bound (AC2). A --poll
        # larger than --max-seconds previously meant the FIRST sleep alone
        # overshot the deadline (measured: --max-seconds 3 --poll 12 took
        # 12s, not ~3s) and sat on an already-fired condition for up to a
        # full oversized tick. 0.1s floor keeps the loop from busy-spinning
        # once the remaining budget is nearly exhausted.
        my $remaining = $max_seconds - (time - $t0);
        my $this_poll = $remaining < $poll ? ($remaining > 0.1 ? $remaining : 0.1) : $poll;
        select(undef, undef, undef, $this_poll);
    }
}

1;
