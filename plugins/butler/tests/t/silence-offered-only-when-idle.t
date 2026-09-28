#!/usr/bin/env perl
# platform: any
# ORACLE for package 38-silence-cannot-bypass-live-work (blueprint
# hook-continuity-remake), gate/command/prose half: AC-12..AC-22 of
# specs/38-silence-cannot-bypass-live-work-spec.md, under Decisions 127-129.
#
# Decision 128: while the session has running work, the Stop gate's message
# does not list silence at all (the RUNNING text); silence is offered only
# when nothing runs (the IDLE text); `butler-continuity silence` run anyway
# while work runs explains and points at hold (exit 1, stderr), and silence
# is framed everywhere as a sparingly used escape hatch.
#
# Decision 129: running work is the UNION of the Stop payload's
# background_tasks and the holder's own live tracked set, because a
# SendMessage-resumed agent may be absent from background_tasks. The D129
# cases below run a REAL holder on a resumed, growing agent and send a Stop
# whose background_tasks does not list it.
#
# Derived from the spec, never from StopGate.pm / BpHook.pm /
# butler-continuity.pl. Gate runs are real subprocesses of
# `bash plugins/butler/hooks/stop-gate.sh` with the payload on stdin (as
# stop-gate-single.t does); commands are real subprocesses bound through
# tickets written with BpHook::write_ticket (as continuity-command-verbs.t
# does). Every state root is a fresh File::Temp dir; HOME/USERPROFILE are
# decoys; every wait is bounded.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec ();
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK     = "$BUTLER/hooks/stop-gate.sh";
my $S        = "$BUTLER/scripts";
my $CMD      = "$S/butler-continuity.pl";
my $HOLDSHIM = "$BUTLER/bin/butler-hold";

require "$S/BpHook.pm";

# ---------------------------------------------------------------------------
# process bookkeeping
# ---------------------------------------------------------------------------
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

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

# ---------------------------------------------------------------------------
# isolation guard (AC-22) and decoys
# ---------------------------------------------------------------------------
my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
{
    my $rh = (defined $ENV{HOME} && length $ENV{HOME}) ? $ENV{HOME}
           : (defined $ENV{USERPROFILE} && length $ENV{USERPROFILE}) ? $ENV{USERPROFILE}
           : undef;
    if (defined $rh) {
        (my $rhn = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE        = "$rhn/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
}
my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $FAKE_HOME = "$TMPROOT/decoy-home") =~ s{\\}{/}g;
(my $PROJECT   = "$TMPROOT/project")    =~ s{\\}{/}g;
(my $LEGACY    = "$TMPROOT/legacy")     =~ s{\\}{/}g;
make_path($FAKE_HOME, "$PROJECT/.ccpraxis-local-data");
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;
delete $ENV{BUTLER_STATE_DIR};

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;

my $HAVE_PROC_CMDLINE = -r '/proc/self/cmdline' ? 1 : 0;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub lines_of {
    my ($text) = @_;
    my @l = split /\n/, $text;
    pop @l while @l && $l[-1] eq '';
    return @l;
}

sub write_file {
    my ($path, $text, $mtime) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

sub append_file {
    my ($path, $text) = @_;
    open my $fh, '>>:raw', $path or die "append $path: $!";
    print {$fh} $text;
    close $fh;
}

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub fresh_root { my $t = tempdir(DIR => $TMPROOT, CLEANUP => 1); (my $r = "$t/state") =~ s{\\}{/}g; return $r }
sub cont_dir   { my ($root) = @_; return "$root/continuity" }
sub snap_path  { my ($root, $sid) = @_; return cont_dir($root) . "/running/$sid" }
sub silence_path { my ($root, $sid) = @_; return cont_dir($root) . "/silence/$sid" }

my $sidn = 0;
sub next_sid { return sprintf('sg38-%04x-%s', ++$sidn, substr(sha1_hex($$ . time() . rand()), 0, 8)) }

sub transcript_for { my ($sid) = @_; return "$PROJECT/$sid.jsonl" }

# with_root(root, sub) -- runs an in-process BpHook call against root only.
sub with_root {
    my ($root, $code) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
    $ENV{BUTLER_STATE_DIR} = $root;
    return $code->();
}

sub arm_session {
    my ($root, $sid) = @_;
    return with_root($root, sub { BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') });
}

sub payload_json {
    my ($sid, %extra) = @_;
    my $tp = transcript_for($sid);
    write_file($tp, '') unless -f $tp;
    my %p = (session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
             transcript_path => $tp, cwd => $PROJECT);
    %p = (%p, %extra);
    delete $p{background_tasks} if exists $extra{background_tasks} && !defined $extra{background_tasks};
    return JSON::PP->new->utf8->canonical->encode(\%p);
}

# run_gate(root, payload_json) -> {rc, out, err}
sub run_gate {
    my ($root, $payload_json) = @_;
    my ($pfh, $ppath) = tempfile(DIR => $TMPROOT); print {$pfh} $payload_json; close $pfh;
    my (undef, $opath) = tempfile(DIR => $TMPROOT);
    my (undef, $epath) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}     = $root;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        open(STDIN,  '<', $ppath) or _exit(126);
        open(STDOUT, '>', $opath) or _exit(126);
        open(STDERR, '>', $epath) or _exit(126);
        { no warnings 'exec'; exec($REAL_BASH_ABS, $HOOK); }
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my $rc = wait_bounded($pid, 15);
    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $ppath, $opath, $epath;
    return { rc => $rc, out => $out, err => $err };
}

sub wait_bounded {
    my ($pid, $timeout) = @_;
    my $deadline = time() + $timeout;
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
    return $rc;
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu38s%05x', ++$TUID_N) }

sub write_ticket {
    my ($root, $sid, $name, $argv, %o) = @_;
    return with_root($root, sub {
        BpHook::write_ticket({ session_id => $sid, tool_use_id => next_tuid(),
                               transcript_path => transcript_for($sid), cwd => $PROJECT },
                             $name, $argv, operator => 0, background => ($o{background} ? 1 : 0));
    });
}

# run_cmd(root, sid, @args) -> (out, err, rc): ticket-bound butler-continuity.
sub run_cmd {
    my ($root, $sid, @args) = @_;
    write_ticket($root, $sid, 'butler-continuity', \@args);
    my (undef, $opath) = tempfile(DIR => $TMPROOT);
    my (undef, $epath) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}               = $root;
        $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $LEGACY;
        $ENV{CLAUDE_PROJECT_DIR}             = $PROJECT;
        $ENV{CCPRAXIS_NO_WAKELOCK}           = 1;
        open(STDOUT, '>', $opath) or _exit(126);
        open(STDERR, '>', $epath) or _exit(126);
        { no warnings 'exec'; exec($^X, $CMD, @args); }
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my $rc = wait_bounded($pid, 30);
    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $opath, $epath;
    return ($out, $err, $rc);
}

sub silence_log_count {
    my ($root, $sid) = @_;
    my $p = cont_dir($root) . '/reasons.log';
    return 0 unless -f $p;
    my $n = 0;
    for my $l (split /\n/, slurp($p)) {
        my @f = split /\t/, $l;
        $n++ if ($f[1] // '') eq $sid && ($f[3] // '') eq 'silence';
    }
    return $n;
}

sub read_json_file {
    my ($p) = @_;
    my $raw = slurp($p);
    return undef unless length $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub snapshot_ids {
    my ($root, $sid) = @_;
    my $j = read_json_file(snap_path($root, $sid));
    return undef unless ref $j eq 'HASH' && ref $j->{work} eq 'ARRAY';
    return [ map { ref $_ eq 'HASH' ? $_->{id} : undef } @{ $j->{work} } ];
}

sub token_of { my ($err) = @_; my ($t) = ($err =~ /Stop token: ([0-9a-f]{8})$/m); return $t }

# ---------------------------------------------------------------------------
# expected texts, exactly as the spec gives them
# ---------------------------------------------------------------------------
sub idle_text {
    my ($t) = @_;
    return <<"TXT";
Continuity is on for this session and no holder is running. Stop token: $t
Waiting on a subagent or background task? Hold it, as a background Bash tool call:
  butler-hold --token $t <id> [<id> ...]
All work done? Turn continuity off, as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token $t
Escape hatch, only when a stop is truly necessary, e.g. to talk with an operator who is present:
  butler-continuity silence --reason '<why this stop>' --token $t
TXT
}

sub ids_parts {
    my (@ids) = @_;
    my @first = @ids > 8 ? @ids[0 .. 7] : @ids;
    my $more  = @ids > 8 ? ', and ' . (@ids - 8) . ' more' : '';
    return (join(', ', @first) . $more, join(' ', @first));
}

sub running_text {
    my ($t, @ids) = @_;
    my ($l1, $l3) = ids_parts(@ids);
    return <<"TXT";
Continuity is on for this session and work is still running: $l1. Stop token: $t
Hold it, as a background Bash tool call; the holder wakes this session when the work finishes:
  butler-hold --token $t $l3
If that work is no longer needed and everything is done, turn continuity off, as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token $t
TXT
}

sub refusal_text {
    my (@ids) = @_;
    my ($l1, $l3) = ids_parts(@ids);
    return <<"TXT";
butler-continuity: not silenced: work is still running in this session ($l1), as of the last stop.
A silence would end the turn with nothing waiting on that work. Hold it instead, as a background Bash tool call; the holder wakes this session when it finishes:
  butler-hold $l3
If that work is no longer needed and everything is done: butler-continuity off --reason '<what is done>'
TXT
}

sub bg { my ($id, $type, $status) = @_; return { id => $id, type => $type, status => $status // 'running', description => "task $id" } }

# write_holder(root, sid, pid, fp, items) -- a holder record written directly.
sub write_holder {
    my ($root, $sid, %o) = @_;
    my $rec = { session_id => $sid, token => 'deadbeef', pid => $o{pid}, fp => $o{fp},
                items => $o{items}, started_at => int(time() - 10), deadline => int(time() + 1800) };
    write_file(cont_dir($root) . "/holder/$sid.json", JSON::PP->new->utf8->canonical->encode($rec));
}

sub own_fp {
    open(my $fh, '<:raw', "/proc/$$/cmdline") or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return sha1_hex(defined $c ? $c : '');
}

# spawn_sleeper/kill_sleeper: a genuinely dead-but-was-real pid for the D130
# "dead holder" fixtures, the same pattern stop-gate-single.t uses for its
# holder-rule tests (S5-S9).
my $SLEEPER_SEQ = 0;
sub spawn_sleeper {
    my $tag = sprintf('%d-%d-%d', $$, ++$SLEEPER_SEQ, int(rand(1_000_000)));
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', File::Spec->devnull);
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        exec($^X, '-e', "select(undef,undef,undef,120) # sleeper-tag:$tag") or _exit(127);
    }
    push @KILL_PIDS, $pid;
    return $pid;
}

sub kill_sleeper {
    my ($pid) = @_;
    return unless $pid;
    kill('TERM', $pid) if kill(0, $pid);
    my $deadline = time() + 5;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        last if $w == $pid;
        sleep(0.05);
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
}

# ===========================================================================
# AC-12 (DC2) -- one running subagent -> RUNNING text, no silence, snapshot.
# ===========================================================================
my ($AC12_ROOT, $AC12_SID);
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $res = run_gate($root, payload_json($sid, background_tasks => [bg('a1', 'subagent')]));
    is($res->{rc}, 2, 'AC-12: armed Stop with a running subagent -> exit 2');
    my $t = token_of($res->{err});
    ok(defined $t, 'AC-12: a Stop token was minted') or diag("stderr:\n$res->{err}");
    is($res->{err}, running_text($t // 'xxxxxxxx', 'a1'), 'AC-12: stderr is exactly the RUNNING text for a1');
    is(scalar(lines_of($res->{err})), 5, 'AC-12: exactly 5 lines');
    unlike($res->{err}, qr/silence/, 'AC-12: the RUNNING text contains no "silence"');
    ok(-f snap_path($root, $sid), 'AC-12: running/<sid> exists');
    my $j = read_json_file(snap_path($root, $sid));
    is(ref $j eq 'HASH' ? $j->{session_id} : undef, $sid, 'AC-12: the snapshot names this session');
    like(ref $j eq 'HASH' ? ($j->{at} // '') : '', qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/, 'AC-12: the snapshot carries an ISO "at"');
    is_deeply(ref $j eq 'HASH' ? $j->{work} : undef, [{ id => 'a1', type => 'subagent' }], 'AC-12: the snapshot work is [{a1, subagent}]');
    my $api = with_root($root, sub { my $r = eval { BpHook::running_snapshot($sid) }; $r });
    is_deeply($api, [{ id => 'a1', type => 'subagent' }], 'AC-12: BpHook::running_snapshot(sid) returns the same entry');
    ($AC12_ROOT, $AC12_SID) = ($root, $sid);
}

# ===========================================================================
# AC-13 (DC2) -- a running shell entry is running work too.
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $res = run_gate($root, payload_json($sid, background_tasks => [bg('bq1', 'shell')]));
    is($res->{rc}, 2, 'AC-13: exit 2');
    my $t = token_of($res->{err});
    is($res->{err}, running_text($t // 'xxxxxxxx', 'bq1'), 'AC-13: exactly the RUNNING text naming bq1');
    unlike($res->{err}, qr/silence/, 'AC-13: no "silence"');
    is_deeply(snapshot_ids($root, $sid), ['bq1'], 'AC-13: running/<sid> holds bq1');
}

# ===========================================================================
# AC-14 (DC2) -- no running work -> IDLE text, no snapshot.
# ===========================================================================
{
    my @cases = (
        ['empty array'            => []],
        ['absent'                 => undef],
        ['only completed/failed'  => [bg('c1', 'subagent', 'completed'), bg('f1', 'shell', 'failed')]],
        ['only invalid ids'       => [bg('a b', 'subagent'), bg('x' x 65, 'shell')]],
    );
    for my $c (@cases) {
        my ($label, $tasks) = @$c;
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my $res = run_gate($root, payload_json($sid, background_tasks => $tasks));
        is($res->{rc}, 2, "AC-14 [$label]: exit 2");
        my $t = token_of($res->{err});
        is($res->{err}, idle_text($t // 'xxxxxxxx'), "AC-14 [$label]: exactly the IDLE text");
        ok(!-e snap_path($root, $sid), "AC-14 [$label]: no running/<sid>");
    }
}

# ===========================================================================
# AC-15 (DC2) -- ten running entries: the first 8 plus ", and 2 more".
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my @ids = map { "r$_" } 1 .. 10;
    my $res = run_gate($root, payload_json($sid, background_tasks => [map { bg($_, 'subagent') } @ids]));
    is($res->{rc}, 2, 'AC-15: exit 2');
    my $t = token_of($res->{err}) // 'xxxxxxxx';
    my @l = lines_of($res->{err});
    is(scalar(@l), 5, 'AC-15: exactly 5 lines');
    is($l[0] // '', "Continuity is on for this session and work is still running: r1, r2, r3, r4, r5, r6, r7, r8, and 2 more. Stop token: $t",
        'AC-15: line 1 lists r1..r8 then ", and 2 more"');
    is($l[2] // '', "  butler-hold --token $t r1 r2 r3 r4 r5 r6 r7 r8", 'AC-15: line 3 holds the first eight ids');
    is($res->{err}, running_text($t, @ids), 'AC-15: the whole text is the RUNNING template');
}

# ===========================================================================
# AC-16 (DC2) -- a live holder (this process, fingerprinted) excludes shell
# entries; a running subagent is still listed.
# ===========================================================================
SKIP: {
    skip 'AC-16: /proc/<pid>/cmdline is unavailable on this host, so no holder can read as alive', 7
        unless $HAVE_PROC_CMDLINE && defined own_fp();
    {
        # Decision 131: a live own holder with non-empty items is itself a
        # background task, so the Stop is allowed regardless of what
        # background_tasks says -- even when background_tasks names a
        # running subagent (a2) the holder itself is not tracking.
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        write_holder($root, $sid, pid => $$, fp => own_fp(), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => [bg('bq2', 'shell'), bg('a2', 'subagent')]));
        is($res->{rc}, 0, 'AC-16: live holder, zz not running, background_tasks names a2 -> exit 0 (Decision 131)');
        is($res->{err}, '', 'AC-16: stderr empty');
        ok(!-e snap_path($root, $sid), 'AC-16: ...and no snapshot');
    }
    {
        # Decision 131: a live own holder with non-empty items is itself a
        # background task, so the Stop is allowed regardless of what
        # background_tasks says -- here, only an unrelated running shell.
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        write_holder($root, $sid, pid => $$, fp => own_fp(), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => [bg('bq2', 'shell')]));
        is($res->{rc}, 0, 'AC-16: live holder with only a running shell -> exit 0 (Decision 131)');
        is($res->{err}, '', 'AC-16: stderr empty');
        ok(!-e snap_path($root, $sid), 'AC-16: ...and no snapshot');
    }
    {
        # the same shape, but the holder is DEAD: holder_live is false, zz
        # does not count, and (per AC-13) a running shell is running work on
        # its own merits once the holder's item-list filtering does not
        # apply -> RUNNING text naming bq2 (unchanged by Decision 131, which
        # only governs the live-holder case).
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my $dead = spawn_sleeper(); kill_sleeper($dead);
        write_holder($root, $sid, pid => $dead, fp => sha1_hex('dead-holder'), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => [bg('bq2', 'shell')]));
        is($res->{rc}, 2, 'AC-16: dead holder with only a running shell -> exit 2');
        my $t = token_of($res->{err});
        is($res->{err}, running_text($t // 'xxxxxxxx', 'bq2'), 'AC-16: ...with the RUNNING text naming bq2');
        is_deeply(snapshot_ids($root, $sid), ['bq2'], 'AC-16: ...and running/<sid> holds bq2');
        ok(1, 'AC-16: ran with /proc available');
    }
    {
        # dead-holder variant preserving the original (pre-Decision-131)
        # intent of the first case above: with the holder dead, no
        # live-holder exclusion applies, so BOTH the running shell (bq2)
        # and the running subagent (a2) are listed -- the RUNNING text
        # still lists a running subagent, unaffected by Decision 131 (which
        # governs only the live-holder branch).
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my $dead = spawn_sleeper(); kill_sleeper($dead);
        write_holder($root, $sid, pid => $dead, fp => sha1_hex('dead-holder'), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => [bg('bq2', 'shell'), bg('a2', 'subagent')]));
        is($res->{rc}, 2, 'AC-16: dead holder, zz not running, background_tasks names bq2 and a2 -> exit 2');
        my $t = token_of($res->{err});
        is($res->{err}, running_text($t // 'xxxxxxxx', 'bq2', 'a2'), 'AC-16: ...with the RUNNING text naming both bq2 and a2');
        is_deeply(snapshot_ids($root, $sid), ['bq2', 'a2'], 'AC-16: ...and running/<sid> holds bq2 and a2');
        ok(1, 'AC-16: dead-holder variant ran with /proc available');
    }
}

# ===========================================================================
# AC-17 (DC2) -- a later Stop with nothing running, and `off`, remove the
# snapshot.
# ===========================================================================
{
    ok(-f snap_path($AC12_ROOT, $AC12_SID), 'AC-17: precondition -- AC-12 left a running/<sid> to remove');
    my $res = run_gate($AC12_ROOT, payload_json($AC12_SID, background_tasks => []));
    is($res->{rc}, 2, 'AC-17: the next armed Stop with nothing running is denied (IDLE)');
    ok(!-e snap_path($AC12_ROOT, $AC12_SID), 'AC-17: ...and running/<sid> is gone');
}
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    run_gate($root, payload_json($sid, background_tasks => [bg('a1', 'subagent')]));
    ok(-f snap_path($root, $sid), 'AC-17: precondition -- a RUNNING deny wrote running/<sid>');
    my ($out, $err, $rc) = run_cmd($root, $sid, 'off', '--reason', 'work all done');
    is($rc, 0, 'AC-17: off --reason exits 0') or diag("stderr: $err");
    ok(!-e snap_path($root, $sid), 'AC-17: running/<sid> is gone after off');
}

# ===========================================================================
# Behaviour 10 -- any armed interactive Stop, including one a live holder
# allows, removes an older snapshot before deciding.
# ===========================================================================
SKIP: {
    skip 'B10: /proc/<pid>/cmdline is unavailable on this host', 2 unless $HAVE_PROC_CMDLINE && defined own_fp();
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    write_file(snap_path($root, $sid), JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, at => iso_of(time() - 60), work => [{ id => 'old1', type => 'subagent' }] }));
    write_holder($root, $sid, pid => $$, fp => own_fp(), items => ['B']);
    my $res = run_gate($root, payload_json($sid, background_tasks => [bg('B', 'subagent')]));
    is($res->{rc}, 0, 'B10: a live holder with its held id running allows the Stop');
    ok(!-e snap_path($root, $sid), 'B10: the older running/<sid> is removed even on an allowed Stop');
}

# ===========================================================================
# AC-18 (DC2) -- silence while the snapshot exists: explained, refused, and
# nothing written; the next Stop with work running is denied again.
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $r1 = run_gate($root, payload_json($sid, background_tasks => [bg('a1', 'subagent')]));
    is($r1->{rc}, 2, 'AC-18: precondition -- a RUNNING deny');
    my $before = silence_log_count($root, $sid);
    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 1, 'AC-18: silence while work runs exits 1');
    is($err, refusal_text('a1'), 'AC-18: stderr is exactly the section 2.4 text for a1');
    ok(!-e silence_path($root, $sid), 'AC-18: no silence/<sid> file');
    is(silence_log_count($root, $sid), $before, 'AC-18: reasons.log has no new silence line');
    my $r2 = run_gate($root, payload_json($sid, background_tasks => [bg('a1', 'subagent')]));
    is($r2->{rc}, 2, 'AC-18: the following Stop with running work is denied again');
    my $t = token_of($r2->{err});
    is($r2->{err}, running_text($t // 'xxxxxxxx', 'a1'), 'AC-18: ...with the RUNNING text');
}
{
    # the 2.4 text follows the same 8-id rule
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my @ids = map { "w$_" } 1 .. 11;
    run_gate($root, payload_json($sid, background_tasks => [map { bg($_, 'shell') } @ids]));
    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 1, 'AC-18 (8-id rule): exit 1');
    is($err, refusal_text(@ids), 'AC-18 (8-id rule): w1..w8 then ", and 3 more"; the hold line carries the first eight');
    ok(!-e silence_path($root, $sid), 'AC-18 (8-id rule): no silence file');
}

# ===========================================================================
# AC-19 (DC2, DC4) -- with no snapshot, silence behaves as today.
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $r1 = run_gate($root, payload_json($sid, background_tasks => []));
    is($r1->{err}, idle_text(token_of($r1->{err}) // 'xxxxxxxx'), 'AC-19: precondition -- an IDLE deny');
    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 0, 'AC-19: silence exits 0') or diag("stderr: $err");
    my $s8 = substr($sid, 0, 8);
    like($out . $err, qr/^continuity silenced for one stop of session \Q$s8\E; reason logged\.$/m, "AC-19: today's line is printed");
    my $r2 = run_gate($root, payload_json($sid, background_tasks => []));
    is($r2->{rc}, 0, 'AC-19: the next Stop is allowed');
}

# ===========================================================================
# AC-20 (DC2) -- a silence set earlier is honoured even while work runs.
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    with_root($root, sub { BpHook::set_silence($sid, reason => 'talking with the operator') });
    ok(-e silence_path($root, $sid), 'AC-20: precondition -- the silence is set');
    my $res = run_gate($root, payload_json($sid, background_tasks => [bg('a1', 'subagent')]));
    is($res->{rc}, 0, 'AC-20: the Stop with a running entry exits 0');
    is(with_root($root, sub { BpHook::take_silence($sid) }), 0, 'AC-20: the silence was consumed');
    ok(!-e snap_path($root, $sid), 'AC-20: an allowed Stop leaves no running/<sid>');
}

# ===========================================================================
# Decision 129/130 -- running work is the union of background_tasks and the
# holder's own live tracked set, and (Decision 130, M1/S3) a LIVE holder
# (pid+fp alive) with a non-empty items record is trusted outright at G8,
# whether or not background_tasks lists the ids -- the fixed holder already
# prunes finished items itself. The 60s activity-file freshness window in
# running_work is what decides instead once the holder is DEAD. A real
# holder holds a SendMessage-resumed agent (stopped notification, then only
# a resume marker, transcript still growing); the Stop payload's
# background_tasks does not list it.
# ===========================================================================
{
    my $root = fresh_root();
    my $sid  = next_sid();
    my $A    = 'a603b4f5e83faa92b';
    arm_session($root, $sid);
    my $tp = transcript_for($sid);
    my $json = JSON::PP->new->utf8->canonical;
    write_file($tp,
        $json->encode({ type => 'queue-operation', operation => 'enqueue',
            content => "<task-notification>\n<task-id>$A</task-id>\n<status>stopped</status>\n"
                     . "<summary>1 background agent didn't finish before the previous session ended.</summary>\n</task-notification>" }) . "\n"
      . $json->encode({ type => 'user', message => { role => 'user', content => [ { type => 'tool_result', tool_use_id => 'toolu_r',
            content => [ { type => 'text', text => qq({"success":true,"message":"Resuming agent a603b4f","resumedAgentId":"$A"}) } ] } ] },
            toolUseResult => { success => JSON::PP::true(), message => 'Resuming agent a603b4f', resumedAgentId => $A } }) . "\n");
    my $agent = write_file("$PROJECT/$sid/subagents/agent-$A.jsonl", qq({"agentId":"$A"}\n));
    write_file("$PROJECT/$sid/subagents/agent-$A.meta.json", qq({"agentType":"general-purpose"}\n));

    write_ticket($root, $sid, 'butler-hold', [$A], background => 1);
    my (undef, $hout) = tempfile(DIR => $TMPROOT);
    my (undef, $herr) = tempfile(DIR => $TMPROOT);
    my $hpid = fork();
    die "fork: $!" unless defined $hpid;
    if ($hpid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}         = $root;
        $ENV{BUTLER_HOLD_TEST_MODE}    = 1;
        $ENV{BUTLER_HOLD_TEST_TICK}    = 0.2;
        $ENV{BUTLER_HOLD_TEST_SECONDS} = 60;
        $ENV{CCPRAXIS_NO_WAKELOCK}     = 1;
        open(STDOUT, '>', $hout) or _exit(126);
        open(STDERR, '>', $herr) or _exit(126);
        { no warnings 'exec'; exec('bash', $HOLDSHIM, $A); }
        _exit(127);
    }
    push @KILL_PIDS, $hpid;

    my $rec;
    my $dl = time() + 10;
    while (time() < $dl) {
        $rec = with_root($root, sub { BpHook::holder($sid) });
        last if ref $rec eq 'HASH';
        sleep(0.02);
    }
    ok(ref $rec eq 'HASH', 'D129: precondition -- the real holder became');

    # 1.5 s of growth: more than enough ticks for a holder to prune the id.
    my $t0 = time();
    while (time() - $t0 < 1.5) { append_file($agent, qq({"agentId":"$A","step":1}\n)); sleep(0.1) }
    my $alive = (waitpid($hpid, WNOHANG) == 0) ? 1 : 0;
    ok($alive, 'D129: the holder is still holding the resumed, growing agent') or diag("holder stdout:\n" . slurp($hout));

    # D130 (M1): the holder is LIVE and its items are non-empty, so G8
    # trusts it outright and the Stop is ALLOWED -- even though
    # background_tasks omits the resumed agent entirely. This is the fix for
    # the deny loop review M1 found: a live holder of a resumed agent must
    # never be denied. No running/<sid> snapshot is written on an allow.
    append_file($agent, qq({"agentId":"$A","step":2}\n));
    my $res = run_gate($root, payload_json($sid, background_tasks => []));
    is($res->{rc}, 0, 'D130: Stop with a LIVE holder of the resumed agent -> exit 0 (allowed)')
        or diag("stderr:\n$res->{err}");
    is($res->{err}, '', 'D130: stderr is empty on the allowed Stop');
    ok(!-e snap_path($root, $sid), 'D130: no running/<sid> is written on an allowed Stop');

    # Now kill the real holder. With the holder DEAD, G8 no longer trusts
    # it, so the gate falls through to running_work's 60s freshness window
    # on the held item's own activity file -- which still denies with the
    # RUNNING text, and silence is still refused.
    kill('TERM', $hpid) if kill(0, $hpid);
    wait_bounded($hpid, 10);
    ok(!kill(0, $hpid), 'D129 (dead variant): the holder process is dead');

    append_file($agent, qq({"agentId":"$A","step":3}\n));   # keeps the file fresh (< 60s old)
    my $res2 = run_gate($root, payload_json($sid, background_tasks => []));
    is($res2->{rc}, 2, 'D129 (dead holder): Stop with the resumed agent absent from background_tasks -> exit 2');
    unlike($res2->{err}, qr/silence/, 'D129 (dead holder): silence is not offered');
    my $t = token_of($res2->{err});
    is($res2->{err}, running_text($t // 'xxxxxxxx', $A), 'D129 (dead holder): the RUNNING text names the resumed agent');
    is_deeply(snapshot_ids($root, $sid), [$A], 'D129 (dead holder): running/<sid> holds the resumed agent');

    append_file($agent, qq({"agentId":"$A","step":4}\n));
    my $res3 = run_gate($root, payload_json($sid, background_tasks => [bg('a3', 'subagent')]));
    is($res3->{rc}, 2, 'D129 (dead holder, union): a listed running subagent plus the held resumed agent -> exit 2');
    my $t3 = token_of($res3->{err}) // 'xxxxxxxx';
    my @accept = (running_text($t3, 'a3', $A), running_text($t3, $A, 'a3'));
    ok((grep { $_ eq $res3->{err} } @accept) ? 1 : 0, 'D129 (dead holder, union): the RUNNING text names both, each once')
        or diag("stderr:\n$res3->{err}");
    unlike($res3->{err}, qr/silence/, 'D129 (dead holder, union): no "silence"');

    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 1, 'D129 (dead holder): silence while the snapshot names the resumed agent exits 1');
    ok(!-e silence_path($root, $sid), 'D129 (dead holder): no silence file');

    # the holder was already reaped above (the dead-variant transition);
    # nothing further to wait for here.
    unlink $hout, $herr;
}

# ===========================================================================
# D130 (S1) -- `butler-continuity silence` refuses whenever this session has
# live running work AT INVOCATION TIME, not only after a Stop recorded a
# RUNNING snapshot. A live holder holding a non-empty items record, with no
# Stop having run yet at all (so running/<sid> was never written), still
# gets the section 2.4 refusal. With no holder and nothing fresh, silence
# before any Stop succeeds exactly as today.
# ===========================================================================
SKIP: {
    skip 'D130 (S1): /proc/<pid>/cmdline is unavailable on this host, so no holder can read as alive', 4
        unless $HAVE_PROC_CMDLINE && defined own_fp();
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    write_holder($root, $sid, pid => $$, fp => own_fp(), items => ['zz']);
    ok(!-e snap_path($root, $sid), 'D130 (S1): precondition -- no Stop has run, so no running/<sid> snapshot exists');
    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 1, 'D130 (S1): silence before any Stop, with a live holder holding work, exits 1')
        or diag("stdout: $out\nstderr: $err");
    like($err, qr/\bzz\b/, 'D130 (S1): stderr names zz');
    like($err, qr/already held|is held|held\b/i, 'D130 (S1): stderr says the work is already held');
    like($err, qr/turn (can|may) (simply )?end/i, 'D130 (S1): stderr says the turn can simply end');
    unlike($err, qr/butler-hold\b.*\bzz\b/s, 'D130 (S1): stderr does not tell the agent to hold zz (it is already held)');
    ok(!-e silence_path($root, $sid), 'D130 (S1): no silence/<sid> file is written');
}
{
    my $root = fresh_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    ok(!-e snap_path($root, $sid), 'D130 (S1, no work): precondition -- no snapshot exists');
    my ($out, $err, $rc) = run_cmd($root, $sid, 'silence', '--reason', 'two words');
    is($rc, 0, 'D130 (S1, no work): silence before any Stop, with no holder and nothing fresh, exits 0')
        or diag("stderr: $err");
    ok(-e silence_path($root, $sid), 'D130 (S1, no work): the silence file was written');
}

# ===========================================================================
# D130 (M1/S3) -- while the holder process is ALIVE, a non-empty items
# record makes it count as live for G8 even when the held item's OWN
# activity file is stale (older than the 60s freshness window): the fix
# trusts the holder's own live bookkeeping, not activity-file freshness.
# With the holder DEAD, the 60s freshness window decides in its place.
# ===========================================================================
SKIP: {
    skip 'D130 (M1/S3): /proc/<pid>/cmdline is unavailable on this host', 7
        unless $HAVE_PROC_CMDLINE && defined own_fp();
    {
        # (a) live holder (this process), stale activity file -> still allowed.
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        write_file("$PROJECT/$sid/subagents/agent-zz.jsonl", qq({"agentId":"zz"}\n), time() - 600);
        write_holder($root, $sid, pid => $$, fp => own_fp(), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => []));
        is($res->{rc}, 0, 'D130a: live holder + stale-file held item -> exit 0 (allowed)')
            or diag("stderr:\n$res->{err}");
        ok(!-e snap_path($root, $sid), 'D130a: no running/<sid> is written on an allowed Stop');
    }
    {
        # (b) the holder is dead: the same stale file, via the 60s freshness
        # window, no longer counts as running -> IDLE text.
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        write_file("$PROJECT/$sid/subagents/agent-zz.jsonl", qq({"agentId":"zz"}\n), time() - 600);
        my $dead = spawn_sleeper(); kill_sleeper($dead);
        write_holder($root, $sid, pid => $dead, fp => sha1_hex('dead-holder'), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => []));
        my $t = token_of($res->{err});
        is($res->{err}, idle_text($t // 'xxxxxxxx'), 'D130b: dead holder + stale file -> IDLE text (nothing counts as running)');
        ok(!-e snap_path($root, $sid), 'D130b: no running/<sid>');
    }
    {
        # (c) the holder is dead, but the activity file is FRESH -> the 60s
        # window counts it as running -> RUNNING text.
        my $root = fresh_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        write_file("$PROJECT/$sid/subagents/agent-zz.jsonl", qq({"agentId":"zz"}\n), time());
        my $dead = spawn_sleeper(); kill_sleeper($dead);
        write_holder($root, $sid, pid => $dead, fp => sha1_hex('dead-holder'), items => ['zz']);
        my $res = run_gate($root, payload_json($sid, background_tasks => []));
        is($res->{rc}, 2, 'D130c: dead holder + fresh file -> exit 2');
        my $t = token_of($res->{err});
        is($res->{err}, running_text($t // 'xxxxxxxx', 'zz'), 'D130c: ...with the RUNNING text naming zz');
        is_deeply(snapshot_ids($root, $sid), ['zz'], 'D130c: running/<sid> holds zz');
    }
}

# ===========================================================================
# AC-21 (DC2) -- prose, by exact substring.
# ===========================================================================
sub block_of {
    my ($path) = @_;
    my @l = split /\n/, slurp($path);
    my ($b, $e);
    for my $i (0 .. $#l) {
        (my $n = $l[$i]) =~ s/\s+\z//;
        $b = $i if !defined $b && $n eq '<!-- continuity:begin -->';
        $e = $i if defined $b && !defined $e && $i > $b && $n eq '<!-- continuity:end -->';
    }
    return undef unless defined $b && defined $e;
    return [ @l[$b + 1 .. $e - 1] ];
}
{
    my $cont = block_of("$BUTLER/skills/continuity/SKILL.md");
    my $want = join("\n",
        q{- **Silence** (`butler-continuity silence --reason '<why this stop>'`) is an escape hatch: use it},
        q{  sparingly, only when a stop is truly necessary, e.g. to talk with an operator who is present or to},
        q{  wait for the operator's answer. It lets one stop through; the gate applies again next stop. It is},
        q{  not offered while work is running, and refuses then: hold the work instead.});
    ok(defined $cont && index(join("\n", map { s/\r\z//r } @$cont), $want) >= 0,
        'AC-21: the continuity SKILL block contains the four Silence lines of section 2.6');

    my $rep = block_of("$BUTLER/skills/reporter/SKILL.md");
    my @content = grep { /\S/ } map { s/\r\z//r } @{ $rep // [] };
    is($content[-1] // '',
        q{operator when a stop is truly necessary and nothing is running: `butler-continuity silence --reason '<why this stop>'` (an escape hatch; use it sparingly); when no live run is left to watch: `butler-continuity off --reason '<what is done>'`.},
        'AC-21: the last content line of the reporter block is section 2.6\'s line');
    like($content[-2] // '', qr/To wait for the\z/, 'AC-21: the reporter line before it still ends with "To wait for the"');

    my $src = slurp($CMD);
    my ($usage) = $src =~ /(\$USAGE\s*=.*?;)\s*$/ms;
    ok(defined $usage && index($usage, q{silence --reason '<why>' [--token T] (escape hatch: use sparingly)}) >= 0,
        'AC-21: $USAGE carries "silence --reason \'<why>\' [--token T] (escape hatch: use sparingly)"');

    my $doc = slurp("$BUTLER/docs/hook-architecture.md");
    $doc =~ s/\r\n/\n/g;
    my ($section) = $doc =~ /^## Stop gate denial text\n(.*?)(?=^## |\z)/ms;
    my @blocks;
    if (defined $section) {
        my @l = split /\n/, $section;
        my $cur;
        for my $line (@l) {
            if ($line =~ /^```/) {
                if (defined $cur) { push @blocks, join('', map { "$_\n" } @$cur); undef $cur }
                else              { $cur = [] }
                next;
            }
            push @$cur, $line if defined $cur;
        }
    }
    (my $idle_doc = idle_text('<token>'))                         =~ s/\r//g;
    (my $run_doc  = running_text('<token>', '<ids>'))            =~ s/\r//g;
    # the doc template keeps the placeholders literally: <ids><more> on line 1, <ids> on line 3
    $run_doc =~ s/still running: <ids>\./still running: <ids><more>./;
    is($blocks[0] // '', $idle_doc, 'AC-21: the first fenced block under "Stop gate denial text" is the IDLE template');
    ok((grep { $_ eq $run_doc } @blocks[1 .. $#blocks]) ? 1 : 0,
        'AC-21: a later fenced block is the RUNNING template') or diag("expected:\n$run_doc");
    ok(defined $section && index($section,
        "When the payload's `background_tasks` lists running work (`running_work`), silence is not offered:") >= 0,
        'AC-21: the RUNNING block is introduced by the sentence of section 2.7');
}

# ===========================================================================
# D130 (S2) -- the continuity skill names a persistent process nobody is
# waiting on (a dev server, a `tail -f`, a watcher) as NOT work to hold, and
# says the right move -- when nothing else is pending -- is `off` with a
# reason. It also says silence refuses while work is running. Loose
# regexes: this is prose the implementer is free to word, not the pinned
# section 2.6 template (already checked exactly above).
# ===========================================================================
{
    my $cont = block_of("$BUTLER/skills/continuity/SKILL.md");
    my $text = defined $cont ? join("\n", map { s/\r\z//r } @$cont) : '';
    ok(length($text), 'D130 (S2): precondition -- the continuity SKILL block was found');
    like($text, qr/\b(?:dev(?:elopment)?\s+server|long[- ]lived\s+(?:background\s+)?(?:process|shell)|watcher|tail\s+-f)\b/i,
        'D130 (S2): the skill names a persistent process nobody is waiting on (e.g. a dev server)');
    like($text, qr/not\s+work\s+to\s+(?:be\s+)?hold|nothing\s+(?:is\s+)?(?:to\s+wait\s+on|waiting\s+on\s+it)|nobody(?:'s| is)\s+waiting/i,
        'D130 (S2): ...and says such a process is not work to hold');
    like($text, qr/\boff\b[^.\n]*\breason\b/i,
        'D130 (S2): ...and points at `off` with a reason as the right move once nothing else is pending');
    like($text, qr/refuses?\s+while\s+work\s+is\s+running|not\s+offered\s+while\s+work\s+is\s+running/i,
        'D130 (S2): ...and says silence refuses/is not offered while work is running');
}

# ===========================================================================
# AC-22 (DC2) -- isolation.
# ===========================================================================
SKIP: {
    skip 'AC-22: no real HOME/USERPROFILE to guard', 2 unless defined $REAL_BSTATE;
    is(-d $REAL_BSTATE ? 1 : 0, $REAL_BSTATE_EXISTS, 'AC-22: the real ~/.claude/butler-state existence is unchanged');
    is($REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef, $REAL_BSTATE_MTIME,
        'AC-22: the real ~/.claude/butler-state mtime is unchanged');
}

done_testing();
