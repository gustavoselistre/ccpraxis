#!/usr/bin/env perl
# platform: any
#
# Batch C (spec 16-cutover, criterion C-7; 1.3 departure #7): the wake-lock
# refresher's SCRIPT ENTRY moves from the old continuity CLI into
# BpContinuityLease.pm itself, because the old continuity CLI is on the deletion
# list (batch E1) and _spawn_daemon needs somewhere else to exec. Spec 2.9:
# the module ends with `__PACKAGE__->_script_main(@ARGV) unless caller; 1;`;
# invoked as `perl BpContinuityLease.pm lease --daemon` it runs
# `daemon_loop(legacy_dir(), ...)` and exits 0; any other argv prints a
# one-line usage to stderr and exits 1.
#
# Covers, in order:
#   1. `lease --daemon` against an empty store exits 0 quickly, and actually
#      reached daemon_loop (proven by the lease.lock it leaves behind) rather
#      than the module merely falling off the end of the file with no main
#      call at all.
#   2. an unrecognised verb exits 1 with exactly one stderr line.
#   3. _spawn_daemon's own source names this module and not the old continuity CLI
#      (the file it execs is deleted in E1).
#   4. `require`-ing the module, the way every other test in this suite
#      already does to reach its functions, executes none of the above: no
#      child process, no output, no file written to the registry.
#
# NO REAL DAEMON IS EVER LEFT RUNNING. The empty-store case is chosen
# precisely because daemon_loop's own first loop check (`last unless
# any_active($dir)`) makes it return at once (spec 5.1: "C-7 relies on the
# empty store making daemon_loop return at once, and on
# CCPRAXIS_NO_WAKELOCK=1"). Every child this file spawns is bounded by a hard
# kill on timeout so a real hang cannot leave a process behind or freeze the
# suite.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(sleep time);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $MODULE = "$S/BpContinuityLease.pm";

ok(-f $MODULE, "sanity: $MODULE exists")
    or BAIL_OUT("module missing: $MODULE");

# ---------------------------------------------------------------------------
# Hermetic scratch. Everything this file touches lives under one tempdir,
# removed at END by File::Temp's own CLEANUP; nothing under the real
# ~/.claude/butler-state or this repo's .ccpraxis-local-data is ever named.
my $SCRATCH = tempdir(CLEANUP => 1);

# fresh_env_dirs() -> ($active_dir, $state_dir, $home_dir), all empty temp
# dirs under $SCRATCH: the "empty store" the criterion asks for.
sub fresh_env_dirs {
    my $active = tempdir(DIR => $SCRATCH, CLEANUP => 1);
    my $state  = tempdir(DIR => $SCRATCH, CLEANUP => 1);
    my $home   = tempdir(DIR => $SCRATCH, CLEANUP => 1);
    return ($active, $state, $home);
}

sub slurp {
    my ($p) = @_;
    return '' unless -f $p;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub dir_entries {
    my ($d) = @_;
    return () unless -d $d;
    opendir my $dh, $d or return ();
    my @e = grep { $_ ne q{.} && $_ ne q{..} } readdir $dh;
    closedir $dh;
    return sort @e;
}

# run_proc(\@cmd, $timeout) -> ($rc, $stdout, $stderr, $elapsed)
#
# Spawns a REAL child process (fork+exec, STDIN from /dev/null), bounded by
# a hard SIGKILL if it outlives $timeout, so a hung child cannot freeze this
# file or leak past it. Same shape as continuity-command-verbs.t's
# run_oc_bounded, generalised to an external command instead of an in-process
# call, because this criterion is about the actual `perl BpContinuityLease.pm
# ...` invocation, not a function call.
my $SEQ = 0;
sub run_proc {
    my ($cmd, $timeout) = @_;
    $SEQ++;
    my $outf = File::Spec->catfile($SCRATCH, "out.$$.$SEQ");
    my $errf = File::Spec->catfile($SCRATCH, "err.$$.$SEQ");

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        require POSIX;
        open(STDIN, '<', File::Spec->devnull) or POSIX::_exit(98);
        open(STDOUT, '>', $outf) or POSIX::_exit(98);
        open(STDERR, '>', $errf) or POSIX::_exit(98);
        exec(@$cmd) or POSIX::_exit(127);   # exec itself failed to start
    }

    my $start    = time();
    my $deadline = $start + $timeout;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    my $elapsed = time() - $start;
    my $out = slurp($outf);
    my $err = slurp($errf);
    unlink $outf, $errf;
    return ($rc, $out, $err, $elapsed);
}

# ===========================================================================
# 1. `lease --daemon` against an empty store: exits 0 within 10s, and really
#    reached daemon_loop.
# ===========================================================================
{
    my ($active, $state, $home) = fresh_env_dirs();
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $active;
    local $ENV{BUTLER_STATE_DIR}                = $state;
    local $ENV{HOME}                            = $home;
    local $ENV{USERPROFILE}                     = $home;
    local $ENV{CCPRAXIS_NO_WAKELOCK}            = 1;

    my ($rc, $out, $err, $elapsed) =
        run_proc([$^X, $MODULE, 'lease', '--daemon'], 10);

    is($rc, 0, 'C-7: `lease --daemon` against an empty store exits 0')
        or diag("stdout: $out\nstderr: $err");
    cmp_ok($elapsed, '<=', 10,
        'C-7: ...and returns within the 10s bound (never left running)');
    ok(-f File::Spec->catfile($active, 'lease.lock'),
        'C-7: daemon_loop actually ran (it leaves lease.lock behind even for '
      . 'an instantly-empty store) -- proves the invocation reaches '
      . 'daemon_loop rather than the module silently doing nothing');
}

# ===========================================================================
# 2. An unrecognised verb exits 1 with exactly one stderr line.
# ===========================================================================
{
    my ($active, $state, $home) = fresh_env_dirs();
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $active;
    local $ENV{BUTLER_STATE_DIR}                = $state;
    local $ENV{HOME}                            = $home;
    local $ENV{USERPROFILE}                     = $home;
    local $ENV{CCPRAXIS_NO_WAKELOCK}            = 1;

    my ($rc, $out, $err, $elapsed) = run_proc([$^X, $MODULE, 'bogus'], 10);

    is($rc, 1, 'C-7: `perl BpContinuityLease.pm bogus` exits 1')
        or diag("stdout: $out\nstderr: $err");
    my @err_lines = split /\n/, $err;
    is(scalar(@err_lines), 1, 'C-7: ...with exactly one stderr line')
        or diag('stderr was: ' . (defined $err ? "[$err]" : '<undef>'));
}

# ===========================================================================
# 3. _spawn_daemon's own source names this module, never the old continuity CLI.
# ===========================================================================
{
    open my $fh, '<', $MODULE or die "can't read $MODULE: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    my ($spawn_body) = $src =~ /\bsub\s+_spawn_daemon\b(.*?)\n\}\n/s;
    ok(defined $spawn_body, 'sanity: found the _spawn_daemon sub body')
        or BAIL_OUT('could not locate _spawn_daemon in BpContinuityLease.pm; '
                  . 'this test needs updating for a rename');

    unlike($spawn_body, qr/bp-continuity/,
        'C-7: _spawn_daemon no longer names the old continuity CLI (deleted in E1)');
    like($spawn_body, qr/BpContinuityLease\.pm/,
        'C-7: _spawn_daemon names BpContinuityLease.pm as the child script');
}

# ===========================================================================
# 4. `require`-ing the module runs none of the above: no child, no output,
#    no file written to the registry.
# ===========================================================================
{
    my ($active, $state, $home) = fresh_env_dirs();
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $active;
    local $ENV{BUTLER_STATE_DIR}                = $state;
    local $ENV{HOME}                            = $home;
    local $ENV{USERPROFILE}                     = $home;
    local $ENV{CCPRAXIS_NO_WAKELOCK}            = 1;

    my @before_active = dir_entries($active);
    my @before_state  = dir_entries($state);
    is(scalar(@before_active), 0, 'sanity: the active dir starts empty');
    is(scalar(@before_state),  0, 'sanity: the state dir starts empty');

    my ($rc, $out, $err, $elapsed) =
        run_proc([$^X, '-e', "require '$MODULE'; exit 0;"], 10);

    is($rc, 0, 'C-7: `require`-ing the module exits 0 (loads cleanly)')
        or diag("stdout: $out\nstderr: $err");
    is($out, q{}, 'C-7: ...and prints nothing to stdout');
    is($err, q{}, 'C-7: ...and prints nothing to stderr');
    cmp_ok($elapsed, '<=', 5,
        'C-7: ...and returns immediately (it did not block in a daemon loop)');

    my @after_active = dir_entries($active);
    my @after_state  = dir_entries($state);
    is_deeply(\@after_active, [],
        'C-7: ...and wrote nothing into the active/registry dir (no child spawned)');
    is_deeply(\@after_state, [],
        'C-7: ...and wrote nothing into the state dir either');
}

done_testing();
