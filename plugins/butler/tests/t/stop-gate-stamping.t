#!/usr/bin/env perl
# platform: any
# F6 (review M2, package 16-cutover fix-batch): timestamp-authorship.t was
# deleted wholesale at a315ef2 although the last_updated stamping behaviour
# it covered survives in BpHook::StopGate's _stamp_ledger. Re-expressed here,
# against the REAL plugins/butler/hooks/stop-gate.sh wrapper (never the
# retired gate-stop.sh), the assertions that stop-gate-coordinator-ledger.t's
# C1/C13 do NOT already cover:
#   - AC-08: exactly one line differs, and the line count is unchanged.
#   - AC-09/AC-10: idempotent -- a second run creates no duplicate
#     last_updated: key, and only ONE line still differs run-to-run.
#   - AC-12: no last_updated: key in the frontmatter at all -> the ledger is
#     left byte-identical (fail open, no key inserted).
#   - AC-13/AC-14: a write failure (the lock file "<ledger>.lock" occupied by
#     a directory, so _with_lock's open() fails and _stamp_ledger_locked
#     never runs) leaves the ledger byte-identical, the stop still allowed,
#     and no *.stop-gate-stamp.tmp.* litter in the ledger's directory.
#   - AC-18: dispatch-fleet/SKILL.md still names iso_now/"no clock" for
#     last_updated -- pinned here since nothing else pins it after the
#     deletion (per fix-batch F6; the alternative, dropping the AC with code
#     PIN, does not apply because the text is still present verbatim).
#
# Conventions per specs/06-stop-gate-spec.md sec 4: BEGIN sets
# CCPRAXIS_NO_WAKELOCK=1; every case gets a fresh BUTLER_STATE_DIR; the real
# wrapper is run via a forked child with stdin/stdout/stderr redirected to
# real files (never an in-memory scalar reopen); ambient BP_*/CCPRAXIS_*/
# CLAUDE_* are scrubbed per run. Mirrors stop-gate-coordinator-ledger.t's own
# mk_bp/env_for/run_gate helpers so a maintainer reading both files recognises
# the same rig.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use File::Glob qw(bsd_glob);
use JSON::PP ();
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK = "$BUTLER/hooks/stop-gate.sh";
(my $SKILLS = "$BUTLER/skills") =~ s{\\}{/}g;
my $DISPATCH_FLEET = "$SKILLS/dispatch-fleet/SKILL.md";

ok(-f $HOOK, "sanity: the real stop-gate.sh exists at $HOOK") or BAIL_OUT("missing $HOOK");
ok(-f $DISPATCH_FLEET, "sanity: dispatch-fleet/SKILL.md exists at $DISPATCH_FLEET") or BAIL_OUT('missing SKILL.md');

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;

my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub read_lines {
    my ($p) = @_;
    my @l = split /\n/, slurp($p);
    return \@l;
}

sub diff_indices {
    my ($b, $a) = @_;
    my @diffs;
    my $n = @$b > @$a ? scalar(@$b) : scalar(@$a);
    for my $i (0 .. $n - 1) {
        my $bl = $i < @$b ? $b->[$i] : undef;
        my $al = $i < @$a ? $a->[$i] : undef;
        push @diffs, $i if (!defined($bl) || !defined($al) || $bl ne $al);
    }
    return \@diffs;
}

sub count_last_updated {
    my ($p) = @_;
    my @lines = @{ read_lines($p) };
    my $infm = 0; my $n = 0;
    for my $l (@lines) {
        if ($l =~ /^---\s*$/) { $infm++; next }
        last if $infm >= 2;
        $n++ if $infm == 1 && $l =~ /^last_updated:/;
    }
    return $n;
}

sub fresh_state_root { my $t = tempdir(CLEANUP => 1); (my $r = "$t/state") =~ s{\\}{/}g; return $r }

sub payload_json {
    my ($sid, %extra) = @_;
    my %p = (session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
              background_tasks => []);
    %p = (%p, %extra);
    return JSON::PP->new->utf8->canonical->encode(\%p);
}

my $sidn = 0;
sub next_sid { return sprintf('sgs-%04x', ++$sidn) }

sub run_gate {
    my ($payload_json, %env) = @_;
    my ($pfh, $ppath) = tempfile(); print {$pfh} $payload_json; close $pfh;
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', $ppath) or _exit(126);
        open(STDOUT, '>', $opath) or _exit(126);
        open(STDERR, '>', $epath) or _exit(126);
        exec($REAL_BASH_ABS, $HOOK);
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my $deadline = time() + 15;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.02);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $ppath, $opath, $epath;
    return { rc => $rc, out => $out, err => $err };
}

# mk_bp(status, next, %sig) -- same fixture shape as
# stop-gate-coordinator-ledger.t's own mk_bp. %sig: no_last_updated (drop the
# key entirely), lock_is_dir (pre-occupy "<ledger>.lock" with a directory, so
# _with_lock's open() fails and the stamp never runs).
my $bpn = 0;
sub mk_bp {
    my ($status, $next, %sig) = @_;
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    $bpn++;
    make_path("$dirn/runs", "$dirn/packages");
    my $last_updated_line = $sig{no_last_updated} ? '' : "last_updated: 2026-06-24T00:00:00Z\n";
    open my $l, '>:raw', "$dirn/packages/p.md" or die $!;
    print {$l} "---\npackage: p\nstatus: $status\n${last_updated_line}---\n# p\n\n## Next action\n\n$next\n";
    close $l;
    if ($sig{lock_is_dir}) {
        mkdir "$dirn/packages/p.md.lock" or die "mkdir lock dir: $!";
    }
    return ($dirn, "$dirn/packages/p.md");
}

sub env_for {
    my ($dir, $led, %extra) = @_;
    my $root = fresh_state_root();
    return (BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir,
            BUTLER_STATE_DIR => $root, %extra);
}

# ===========================================================================
# AC-08 -- exactly one line differs before/after an allowed run, and the
# line count is unchanged (no insertion, no deletion). A terminal, fresh,
# concrete-Next-action ledger takes the ledger-rule allow path (spec 2.4
# step 3), which stamps.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('blocked', 'Pick up the failing edge case.');
    my $before = read_lines($led);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0, 'AC-08 setup: exit 0 so a stamp can be diffed') or diag($res->{err});
    my $after = read_lines($led);
    my $diffs = diff_indices($before, $after);
    is(scalar(@$diffs), 1, 'AC-08: exactly one line differs between before and after');
    SKIP: {
        skip 'no single differing line to inspect', 1 unless @$diffs == 1;
        like($after->[$diffs->[0]], qr/^last_updated:/, 'AC-08: the one differing line is last_updated:');
    }
    is(scalar(@$before), scalar(@$after), 'AC-08: line count is unchanged');
}

# ===========================================================================
# AC-09/AC-10 -- idempotent: a second allowed run still changes only the
# last_updated: line (never inserts a duplicate key), across a 1s gap so
# iso_now()'s one-second resolution cannot make the two stamps equal for a
# timing reason unrelated to correctness.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('done', 'n/a');
    my $res1 = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res1->{rc}, 0, 'AC-09 (B13): first run exits 0') or diag($res1->{err});
    my $after1 = read_lines($led);
    sleep 1;
    my $res2 = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res2->{rc}, 0, 'AC-09 (B13): second run exits 0') or diag($res2->{err});
    my $after2 = read_lines($led);
    my $diffs = diff_indices($after1, $after2);
    is(scalar(@$diffs), 1, 'AC-09 (B13): only one line differs between run-1 and run-2');
    SKIP: {
        skip 'no single differing line to inspect', 1 unless @$diffs == 1;
        like($after2->[$diffs->[0]], qr/^last_updated:/, 'AC-09 (B13): the differing line is last_updated:');
    }
    is(count_last_updated($led), 1, 'AC-10: exactly one last_updated: key after two runs (no duplication)');
}

# ===========================================================================
# AC-12 -- no last_updated: key at all in the frontmatter: the stop is still
# allowed (fail open) and the ledger is left byte-identical (the key is
# never inserted).
# ===========================================================================
{
    my ($dir, $led) = mk_bp('parked', 'x', no_last_updated => 1);
    my $before = slurp($led);
    ok($before !~ /^last_updated:/m, 'AC-12 setup: the fixture really has no last_updated: key');
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0, 'AC-12: missing last_updated: key -> still exit 0 (allow)');
    is(slurp($led), $before, 'AC-12: ...and the ledger is byte-identical (key never inserted)');
    is($res->{err}, '', 'AC-12: nothing on stderr (spec 2.6: "nothing printed" on any stamp failure)');
}

# ===========================================================================
# AC-13/AC-14 -- a stamp write failure ("<ledger>.lock" occupied by a
# directory, so _with_lock's open(">>", ...) fails and _stamp_ledger_locked
# never runs) leaves the ledger byte-identical, the stop still allowed, and
# no *.stop-gate-stamp.tmp.* litter behind in the ledger's own directory.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('parked', 'x', lock_is_dir => 1);
    ok(-d "$led.lock", 'AC-13 setup: the ledger.lock path is really a directory (write path will fail to open it)');
    my $before = slurp($led);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0, 'AC-13: a stamp write failure -> still exit 0 (fail open)') or diag($res->{err});
    is(slurp($led), $before, 'AC-13: ...and the ledger is byte-identical');
    is($res->{err}, '', 'AC-13: nothing on stderr');
    my @litter = bsd_glob("$dir/packages/*.stop-gate-stamp.tmp.*");
    is(scalar(@litter), 0, 'AC-14: no *.stop-gate-stamp.tmp.* litter left in the ledger\'s directory');
}

# ===========================================================================
# AC-18 -- dispatch-fleet/SKILL.md still pins iso_now/"no clock" wording for
# last_updated. Nothing re-pins this after timestamp-authorship.t's deletion
# (fix-batch F6): asserted directly here rather than dropped, because the
# text itself is still present verbatim (per review M2).
# ===========================================================================
{
    my $content = slurp($DISPATCH_FLEET);
    like($content, qr/refresh `last_updated` with `iso_now`/,
        'AC-18: dispatch-fleet/SKILL.md names iso_now for last_updated');
    like($content, qr/you have no clock/,
        'AC-18: dispatch-fleet/SKILL.md warns the agent it has no clock');
}

done_testing();
