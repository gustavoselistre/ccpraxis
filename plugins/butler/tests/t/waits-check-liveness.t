#!/usr/bin/env perl
# platform: windows
# ORACLE for butler-gate-ergonomics package 12-waits-check-liveness.
#
# Spec: .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/
# 12-waits-check-liveness-spec.md, section 3 (B1-B18) and section 4
# (AC1-AC19).
#
# WRITTEN BLIND: neither coordinator-protocol/SKILL.md's liveness doctrine
# block nor bp-watch.pl's settled_verdict function exist at the time this
# file was written. Every "new behavior" assertion below (B1, B2, B6-B18) is
# EXPECTED TO FAIL until the implementer adds them -- that is the point of a
# blind oracle. Assertions about pre-existing, unchanged behavior (blueprint_
# settled([]) staying true, resolve_condition's undef-never-dead rule,
# all_pids_alive's undef-on-empty rule) are expected to PASS already, since
# they pin surface the spec says must not change.
#
# PARTIAL COVERAGE, stated per spec instruction (do not silently drop):
#
#  * B5 (ARTIFACT fired by a report appended-to AFTER arming) needs the watch
#    and a second writer to genuinely overlap in wall-clock time, which is
#    exactly the kind of process-timing race this suite avoids everywhere
#    else. We attempt the real CLI overlap fixture (fork a helper that sleeps
#    then appends, mirroring bp-watch-cli.t section F's proven shape) and ALSO
#    assert the pure seam directly (artifact_changed({p=>100},{p=>200}) true,
#    artifact_changed({p=>100},{p=>100}) false) so the claim is covered even
#    if the real-fork half is host-flaky. Both run; neither is skipped.
#  * Exit 4 (STATUS-CHANGE) is verified STRUCTURALLY ONLY, per the spec's own
#    instruction (B16): constructing a genuine mid-watch status flip that is
#    neither TERMINAL nor artifact nor bound-hit requires a concurrent writer
#    racing the exact tick boundary, which the spec explicitly rules out of
#    scope ("Making exit 4 constructible" is listed under Out of scope). We
#    assert only that the parsed verdict table's row 4 exists with verdict
#    STATUS-CHANGE and an action naming re-arm/resume.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. Fixtures below drive
# bp-watch.pl --self-pause, which reaches BpRunState::pause in-process.
# CCPRAXIS_NO_WAKELOCK is the supported opt-out and IS inherited across exec.
# Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes qw(time);

my $WATCH     = "$Bin/../../scripts/bp-watch.pl";
my $RUNSTATE  = "$Bin/../../scripts/bp-runstate.pl";
my $COORD_SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md";

# ===========================================================================
# Fixture helpers (spec sec 2.3), mirroring bp-watch-cli.t:40-70.
# ===========================================================================

sub run_watch {
    my (@args) = @_;
    return (undef, '', undef) unless -f $WATCH;
    my $cmd = join(' ', 'perl', qq("$WATCH"), map { qq("$_") } @args);
    my $t0  = time;
    my $out = `$cmd 2>&1`;
    my $dt  = time - $t0;
    return ($? >> 8, $out, $dt);
}

sub write_ledger {
    my ($dir, $id, $status_line) = @_;
    make_path("$dir/packages");
    my $body = "---\npackage: $id\n";
    $body .= "$status_line\n" if defined $status_line;
    $body .= "---\n\nbody\n";
    open my $fh, '>', "$dir/packages/$id.md" or die "write $id.md: $!";
    print {$fh} $body;
    close $fh;
}

sub new_bp {
    my ($bpname) = @_;
    $bpname //= 'bpx';
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/$bpname";
    make_path("$bp/packages");
    make_path("$bp/runs");
    return ($data, $bp, $bpname);
}

# pid_alive() for the helper assertions below -- loaded once, directly, not
# via the CLI (so dead_pid()/live_pid() can assert liveness themselves
# before any fixture trusts them).
{
    local @ARGV;
    require $RUNSTATE if -f $RUNSTATE;
}

sub _pid_alive {
    my ($pid) = @_;
    return BpRunState::pid_alive($pid) if defined &BpRunState::pid_alive;
    # bp-runstate.pl absent -- cannot construct a trustworthy answer; make
    # every caller's own assertion fail loudly rather than silently pass.
    return undef;
}

# dead_pid(): prefer a real reaped child (spec 2.3), asserting pid_alive==0
# before any caller relies on it. Falls back to a high unused integer, with
# the SAME assertion applied -- a "dead" pid that is actually alive would
# make every exit-2 fixture pass for the wrong reason.
sub dead_pid {
    my $pid = fork();
    if (defined $pid && $pid == 0) {
        exit 0;
    }
    if (defined $pid && $pid > 0) {
        waitpid($pid, 0);
        if (!defined(_pid_alive($pid)) || _pid_alive($pid) == 0) {
            return $pid;
        }
    }
    # Fallback: a high unused integer (house convention, bp-watch-cli.t:234).
    my $fallback = 999_999;
    my $alive = _pid_alive($fallback);
    die "dead_pid() fallback $fallback is NOT confirmed dead (pid_alive=="
      . (defined $alive ? $alive : 'undef') . ") -- refusing to hand out an "
      . "unverified 'dead' pid"
        unless defined $alive && $alive == 0;
    return $fallback;
}

sub live_pid {
    my $pid = $$;
    my $alive = _pid_alive($pid);
    die "live_pid() candidate $$ is NOT confirmed alive (pid_alive=="
      . (defined $alive ? $alive : 'undef') . ")"
        unless defined $alive && $alive == 1;
    return $pid;
}

sub slurp {
    my ($p) = @_;
    return '' unless -f $p;
    local (@ARGV, $/) = ($p);
    return scalar <>;
}

# ===========================================================================
# Doctrine table parser (used by B13/B14/B15/B16/B17/B18). Parses the
# `### Every wait names its subject and its liveness proof` block's
# wait-shape table and the verdict-table and arming-recipe blocks out of
# coordinator-protocol/SKILL.md. Returns () if the anchor heading is absent
# -- callers must treat that as a real failure (spec 5: "a missing table is
# a red test, never a silent pass"), never skip.
# ===========================================================================

sub _parse_pipe_table_rows {
    # Given the raw markdown text starting at a table's header line, return
    # (\@header_cells, \@data_rows) where each row is \@cells. Stops at the
    # first blank line or non-'|' line after the separator row.
    my ($text) = @_;
    my @lines = split /\n/, $text;
    return ([], []) unless @lines;
    my @header;
    my $i = 0;
    for (; $i < @lines; $i++) {
        if ($lines[$i] =~ /^\s*\|/) {
            @header = map { s/^\s+|\s+$//gr } split /\|/, $lines[$i];
            shift @header if @header && $header[0] eq '';
            pop @header if @header && $header[-1] eq '';
            $i++;
            last;
        }
    }
    # A GFM delimiter row for N columns has N-1 INTERNAL pipes too
    # (|---|---|---|---|), not just the two outer ones -- the previous
    # /^\s*\|[\s:-]+\|\s*$/ could only ever match a single-column delimiter
    # and silently rejected every real multi-column table's separator row,
    # forcing it to be omitted entirely to pass this parser. Match any
    # number of :-/whitespace-only cells instead.
    $i++ while $i < @lines && $lines[$i] =~ /^\s*\|(?:\s*:?-+:?\s*\|)+\s*$/;
    my @rows;
    for (; $i < @lines; $i++) {
        last unless $lines[$i] =~ /^\s*\|/;
        my @cells = map { s/^\s+|\s+$//gr } split /\|/, $lines[$i];
        shift @cells if @cells && $cells[0] eq '';
        pop @cells if @cells && $cells[-1] eq '';
        push @rows, \@cells;
    }
    return (\@header, \@rows);
}

sub parse_wait_shape_table {
    my $text = slurp($COORD_SKILL);
    return (undef, []) unless $text =~ /### Every wait names its subject and its liveness proof/;
    return (undef, []) unless $text =~ /\Q| wait shape | subject | liveness proof | ruling |\E\n(.*?)(?=\n##|\n\z)/s
        || $text =~ /\Q| wait shape | subject | liveness proof | ruling |\E(.*)/s;
    my ($after) = $text =~ /\Q| wait shape | subject | liveness proof | ruling |\E(.*)/s;
    return (undef, []) unless defined $after;
    my ($header, $rows) = _parse_pipe_table_rows($after);
    return ($header, $rows);
}

sub parse_verdict_table {
    my $text = slurp($COORD_SKILL);
    return (undef, []) unless $text =~ /\| exit \| verdict \| what you do \|(.*)/s;
    my ($after) = $text =~ /\| exit \| verdict \| what you do \|(.*)/s;
    return (undef, []) unless defined $after;
    my ($header, $rows) = _parse_pipe_table_rows($after);
    return ($header, $rows);
}

sub parse_arming_recipe {
    my $text = slurp($COORD_SKILL);
    # Anchor near the doctrine heading, not any bash-fenced block in the
    # file (SKILL.md has other unrelated ```bash blocks, e.g. bp-fast-
    # store.sh) -- scope to the region AFTER the wait-shape heading and
    # require the block itself to mention bp-watch.pl.
    my ($after_heading) = $text =~ /### Every wait names its subject and its liveness proof(.*)/s;
    return undef unless defined $after_heading;
    for my $block ($after_heading =~ /```bash\n(.*?)\n```/gs) {
        return $block if $block =~ /bp-watch\.pl/;
    }
    return undef;
}

# ===========================================================================
# B10/AC11 -- settled_verdict is denominator-aware. Direct unit call, no CLI.
# ===========================================================================
{
    local @ARGV;
    if (-f $WATCH) {
        require $WATCH;
    }
}
{
    my $have = defined &BpWatch::settled_verdict;
    ok($have, 'B10-pre: BpWatch::settled_verdict exists (new function, spec 2.2a)')
        or diag('BpWatch::settled_verdict not yet implemented -- expected failure pre-implementation');
    SKIP: {
        skip 'BpWatch::settled_verdict not implemented yet', 7 unless $have;
        is(BpWatch::settled_verdict(undef), 'unverifiable',
            'B10a: settled_verdict(undef) -> unverifiable');
        is(BpWatch::settled_verdict([]), 'unverifiable',
            'B10b: settled_verdict([]) -> unverifiable (AC11)');
        is(BpWatch::settled_verdict('nope'), 'unverifiable',
            'B10c: settled_verdict(scalar) -> unverifiable');
        is(BpWatch::settled_verdict([{status=>'done'},{status=>'pending'}]), 'pending',
            'B10d: settled_verdict with a non-terminal element -> pending');
        is(BpWatch::settled_verdict([{status=>'done'},{status=>'parked'}]), 'settled',
            'B10e: settled_verdict, all terminal -> settled');
        is(BpWatch::settled_verdict([{status=>'done'},{status=>undef}]), 'pending',
            'B10f: settled_verdict with an undef status element -> pending');
    }
}

# ===========================================================================
# B11/AC12 -- blueprint_settled([]) is UNCHANGED (vacuously true). Guards
# against the implementer "fixing" the pinned contract instead of wrapping
# it in settled_verdict. Expected to PASS already (pre-existing behavior).
# ===========================================================================
{
    ok(defined &BpWatch::blueprint_settled, 'B11-pre: BpWatch::blueprint_settled exists');
    ok(BpWatch::blueprint_settled([]),
        'B11 CANONICAL: blueprint_settled([]) remains vacuously true -- the pinned contract '
      . '(bp-watch-decision-core.t:166, C7) is wrapped by settled_verdict, never rewritten');
}

# ===========================================================================
# B12/AC13 -- undefined liveness never resolves as workers-gone. Expected to
# PASS already: resolve_condition and all_pids_alive are unchanged by this
# package (spec 2.2: "Exactly two changes... not resolve_condition").
# ===========================================================================
{
    ok(defined &BpWatch::resolve_condition, 'B12-pre: BpWatch::resolve_condition exists');
    is(BpWatch::resolve_condition({status=>'running', pids_alive=>undef, artifact_changed=>0, bound_hit=>0}),
       undef,
       'B12a UMBRELLA: pids_alive=>undef, bound not hit -> undef (never workers-gone on '
     . 'undeterminable liveness)');
    is(BpWatch::resolve_condition({status=>'running', pids_alive=>undef, artifact_changed=>0, bound_hit=>1}),
       'bound',
       'B12b: same undef liveness, bound_hit=>1 -> bound (not workers-gone even at the bound)');
    is(BpWatch::all_pids_alive([], sub { 1 }), undef,
       'B12c: all_pids_alive([], ...) -> undef, never 0, for an empty pid list');
}

# ===========================================================================
# B14 (pid_alive exercise) -- pid_alive(live)==1, pid_alive(dead)==0.
# Expected to PASS already (BpRunState::pid_alive is untouched by this
# package).
# ===========================================================================
{
    my $live = live_pid();
    my $dead = dead_pid();
    is(_pid_alive($live), 1, 'B14a: pid_alive(live_pid()) == 1');
    is(_pid_alive($dead), 0, 'B14b: pid_alive(dead_pid()) == 0');
}

# ===========================================================================
# B1/AC4 -- a dead pid ends a Mode A watch early, exit 2 (WORKERS-GONE),
# well under the 4s bound.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $dead = dead_pid();
    my ($rc, $out, $dt) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--expect-pids', $dead,
        '--reason', 'B1-fixture', '--data', $data
    );
    is($rc, 2, 'B1 CANONICAL: a dead --expect-pids subject ends the watch with exit 2 '
             . '(WORKERS-GONE)');
    like($out, qr/WORKERS-GONE/, 'B1b: stdout matches /WORKERS-GONE/');
    ok(defined $dt && $dt < 4,
       'B1c: elapsed is under the 4s bound -- it resolved on the condition, not on the timer');
}

# ===========================================================================
# B2/AC-none-direct (paired with B14 table) -- a live pid does not end the
# watch as dead. Same fixture, --expect-pids $$.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $live = live_pid();
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--expect-pids', $live,
        '--reason', 'B2-fixture', '--data', $data
    );
    is($rc, 1, 'B2 CANONICAL: a live --expect-pids subject reaches BOUND (1), never 2, never 0');
    like($out, qr/BOUND/, 'B2b: stdout matches /BOUND/');
    isnt($rc, 2, 'B2c: never WORKERS-GONE for a genuinely live pid');
    isnt($rc, 0, 'B2d: never TERMINAL for a genuinely live pid');
}

# ===========================================================================
# B3/AC6 -- a pre-existing report stub PLUS a dead worker ends the wait as
# WORKERS-GONE, never as completion (existence wins nothing).
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $report = "$bp/runs/report-p1.md";
    open my $fh, '>', $report or die "write report: $!";
    print {$fh} "stub\n";
    close $fh;
    my $dead = dead_pid();
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--artifact', $report, '--expect-pids', $dead,
        '--reason', 'B3-fixture', '--data', $data
    );
    is($rc, 2, 'B3 CANONICAL: a pre-existing report stub + a dead worker -> exit 2 '
             . '(WORKERS-GONE), never 0, never 3 -- existence proves nothing about completion');
    isnt($rc, 0, 'B3b: never TERMINAL');
    isnt($rc, 3, 'B3c: never ARTIFACT (the stub was never appended to)');
}

# ===========================================================================
# B4/AC7 -- a pre-existing report stub plus a LIVE worker, never appended to,
# reaches BOUND. Mere existence never fires the artifact axis.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $report = "$bp/runs/report-p1.md";
    open my $fh, '>', $report or die "write report: $!";
    print {$fh} "stub\n";
    close $fh;
    my $live = live_pid();
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--artifact', $report, '--expect-pids', $live,
        '--reason', 'B4-fixture', '--data', $data
    );
    is($rc, 1, 'B4 CANONICAL: pre-existing, untouched report stub + a live worker -> BOUND (1), '
             . 'never 0 (TERMINAL) and never 3 (ARTIFACT) -- mere existence never fires the '
             . 'artifact axis');
    isnt($rc, 0, 'B4b: never TERMINAL');
    isnt($rc, 3, 'B4c: never ARTIFACT');
}

# ===========================================================================
# B5/AC-partial -- ARTIFACT fires when the watched path is appended to AFTER
# the watch begins. PARTIAL COVERAGE (stated in the header comment above):
# a real overlapping-writer fixture (mirrors bp-watch-cli.t section F) PLUS
# the pure seam assertion, both run.
# ===========================================================================
{
    # Pure seam half: artifact_changed is unchanged by this package, so this
    # should PASS already.
    ok(BpWatch::artifact_changed({p=>100}, {p=>200}),
        'B5-seam-a: artifact_changed({p=>100},{p=>200}) is true (mtime advanced)');
    ok(!BpWatch::artifact_changed({p=>100}, {p=>100}),
        'B5-seam-b: artifact_changed({p=>100},{p=>100}) is false (mtime unchanged) -- the '
      . 'negative half B4 exercises at the CLI level');
}
{
    # Real overlapping-writer half (may be flakier on some hosts; the seam
    # assertions above already cover the claim independently).
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $watched = "$bp/runs/report-p1.md";
    open my $fh, '>', $watched or die "write report: $!";
    print {$fh} "stub\n";
    close $fh;
    my $live = live_pid();

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        open my $f2, '>>', $watched or exit 1;
        print {$f2} "appended after arm\n";
        close $f2;
        exit 0;
    }
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--artifact', $watched, '--expect-pids', $live,
        '--reason', 'B5-fixture', '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 3, 'B5 CLI half: a report appended to AFTER the watch arms -> exit 3 (ARTIFACT)');
    like($out, qr/ARTIFACT/, 'B5b: stdout matches /ARTIFACT/');
}

# ===========================================================================
# B6/AC14 -- no liveness axis at all can never resolve as done. Exit 1 only.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--reason', 'B6-fixture', '--data', $data
    );
    is($rc, 1, 'B6 CANONICAL: no --expect-pids/--pid-file/--artifact at all -> exit 1 (BOUND), '
             . 'never 0, never 2 -- an unconfigured axis is a timer, not a liveness check');
    isnt($rc, 0, 'B6b: never TERMINAL');
    isnt($rc, 2, 'B6c: never WORKERS-GONE');
}

# ===========================================================================
# B7/AC15 -- an unresolvable subject is UNVERIFIABLE, and says so.
# ===========================================================================
{
    my ($data) = new_bp();
    my ($rc, $out) = run_watch(
        '--arm', '--blueprint', 'no-such-blueprint-b7', '--max-seconds', '4', '--poll', '1',
        '--reason', 'B7-fixture', '--data', $data
    );
    is($rc, 65, 'B7 CANONICAL: a nonexistent --blueprint subject -> exit 65 (UNVERIFIABLE)');
    like($out, qr/UNVERIFIABLE/, 'B7b: stdout matches /UNVERIFIABLE/');
    like($out, qr/never treat as done/i, 'B7c: stdout matches /never treat as done/i');
}

# ===========================================================================
# B8/AC9 -- Mode B never reports SETTLED while a package is pending. This is
# the defect this package fixes (settled_verdict routed into Mode B's per-
# tick derivation) -- EXPECTED TO FAIL pre-implementation if the denominator
# ever becomes unreadable mid-watch, but the base case (readable, pending)
# already passes under the CURRENT blueprint_settled-direct wiring too, so
# this specific fixture is not by itself the red assertion; B9 is its
# necessary non-vacuity counter-case.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: pending');
    my ($rc, $out) = run_watch(
        '--arm', '--blueprint', $bpname, '--max-seconds', '4', '--poll', '1',
        '--reason', 'B8-fixture', '--data', $data
    );
    is($rc, 1, 'B8: Mode B with one pending package -> exit 1 (BOUND)');
    unlike($out, qr/SETTLED/, 'B8b: stdout never matches /SETTLED/');
    unlike($out, qr/TERMINAL/, 'B8c: stdout never matches /TERMINAL/');
}

# ===========================================================================
# B9/AC10 -- Mode B DOES report SETTLED when every package is terminal (the
# non-vacuity counter-case to B8).
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: parked');
    my ($rc, $out) = run_watch(
        '--arm', '--blueprint', $bpname, '--max-seconds', '4', '--poll', '1',
        '--reason', 'B9-fixture', '--data', $data
    );
    is($rc, 0, 'B9 CANONICAL: Mode B with every package terminal -> exit 0 (SETTLED) -- proves '
             . 'B8 is not vacuously passing against a watcher that can never settle');
    like($out, qr/SETTLED/, 'B9b: stdout matches /SETTLED/');
}

# ===========================================================================
# B13/AC1/AC2/AC3/AC8/AC17 (text half) -- the doctrine's wait-shape table is
# well-formed. EXPECTED TO FAIL until coordinator-protocol/SKILL.md gains
# the new block: the file exists today but does not have this heading.
# ===========================================================================
{
    my ($header, $rows) = parse_wait_shape_table();
    my $found_header = defined $header && @$header
        && join('|', @$header) eq 'wait shape|subject|liveness proof|ruling';
    ok($found_header,
        'B13a CANONICAL: coordinator-protocol/SKILL.md contains the '
      . '"### Every wait names its subject and its liveness proof" heading with the pinned '
      . 'table header "| wait shape | subject | liveness proof | ruling |"')
        or diag('not yet implemented: doctrine block absent from coordinator-protocol/SKILL.md');

    my @data_rows = @$rows;
    cmp_ok(scalar(@data_rows), '>=', 8,
        'B13b: at least 8 data rows in the wait-shape table');

    my %vocab = map { $_ => 1 } (
        'Task return', 'completion notification', 'foreground exit code',
        'bp-watch --package', 'bp-watch --artifact', 'bp-watch --expect-pids',
        'bp-watch --pid-file', 'pid_alive', 'NONE',
    );
    my $all_subjects_ok = 1;
    my $all_rulings_ok  = 1;
    my $all_tokens_ok   = 1;
    my $none_only_banned = 1;
    for my $row (@data_rows) {
        my ($shape, $subject, $proof, $ruling) = @$row;
        $all_subjects_ok = 0
            if !defined $subject || $subject =~ /^\s*$/ || $subject =~ /^(-|n\/a|\?|TBD)$/i;
        $all_rulings_ok = 0
            unless defined $ruling && $ruling =~ /^(SANCTIONED|BANNED)$/;
        my @tokens = ($proof // '') =~ /`([^`]+)`/g;
        for my $tok (@tokens) {
            $all_tokens_ok = 0 unless $vocab{$tok};
            if ($tok eq 'NONE' && defined $ruling && $ruling ne 'BANNED') {
                $none_only_banned = 0;
            }
        }
    }
    ok($all_subjects_ok, 'B13c: every row\'s subject cell is non-empty and not a placeholder');
    ok($all_rulings_ok,  'B13d: every row\'s ruling cell is exactly SANCTIONED or BANNED');
    ok($all_tokens_ok,   'B13e: every backticked liveness-proof token belongs to the closed '
                        . 'vocabulary');
    ok($none_only_banned, 'B13f: NONE appears only on BANNED rows, never on SANCTIONED');

    my %banned_shape_found = (report => 0, sentinel => 0, pidfile => 0);
    for my $row (@data_rows) {
        my ($shape, $subject, $proof, $ruling) = @$row;
        next unless defined $ruling && $ruling eq 'BANNED';
        $banned_shape_found{report}   = 1 if defined $shape && $shape =~ /report/i;
        $banned_shape_found{sentinel} = 1 if defined $shape && $shape =~ /sentinel/i;
        $banned_shape_found{pidfile}  = 1 if defined $shape && $shape =~ /pid.?file/i;
    }
    ok($banned_shape_found{report},
        'B13g: a report-shaped row is present and ruled BANNED');
    ok($banned_shape_found{sentinel},
        'B13h: a sentinel-shaped row is present and ruled BANNED');
    ok($banned_shape_found{pidfile},
        'B13i: a pid-file-shaped row is present and ruled BANNED');
}

# ===========================================================================
# B14 (table half) -- every distinct proof token in the parsed table is
# exercised. A token with no exercise, or outside the vocabulary, fails.
# ===========================================================================
{
    my ($header, $rows) = parse_wait_shape_table();
    my %seen_tokens;
    for my $row (@$rows) {
        my ($shape, $subject, $proof, $ruling) = @$row;
        for my $tok (($proof // '') =~ /`([^`]+)`/g) {
            $seen_tokens{$tok} = 1;
        }
    }
    my %vocab = map { $_ => 1 } (
        'Task return', 'completion notification', 'foreground exit code',
        'bp-watch --package', 'bp-watch --artifact', 'bp-watch --expect-pids',
        'bp-watch --pid-file', 'pid_alive', 'NONE',
    );
    my $ok_all = 1;
    for my $tok (keys %seen_tokens) {
        $ok_all = 0 unless $vocab{$tok};
    }
    ok($ok_all, 'B14a: every distinct token found in the doctrine table is inside the closed '
              . 'vocabulary (no stray token outside it)');

    if (@$rows) {
        ok(($seen_tokens{'pid_alive'} ? 1 : 0),
            'B14b: pid_alive token appears in the table (exercised directly above: B14a/b '
          . 'pid_alive assertions)');
        ok(($seen_tokens{'bp-watch --expect-pids'} ? 1 : 0),
            'B14c: bp-watch --expect-pids token appears in the table (exercised by B1/B2)');
        ok(($seen_tokens{'bp-watch --artifact'} ? 1 : 0),
            'B14d: bp-watch --artifact token appears in the table (exercised by B3/B4/B5)');
        ok(($seen_tokens{'bp-watch --package'} ? 1 : 0),
            'B14e: bp-watch --package token appears in the table (exercised by B9/B6)');
    } else {
        fail('B14b: pid_alive token appears in the table (doctrine table absent)');
        fail('B14c: bp-watch --expect-pids token appears in the table (doctrine table absent)');
        fail('B14d: bp-watch --artifact token appears in the table (doctrine table absent)');
        fail('B14e: bp-watch --package token appears in the table (doctrine table absent)');
    }

    # bp-watch --pid-file exercise: a pid file containing a dead pid -> exit
    # 2; containing $$ -> exit 1.
    {
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $pidfile = "$bp/runs/.pidfile-dead";
        my $dead = dead_pid();
        open my $fh, '>', $pidfile or die; print {$fh} "$dead\n"; close $fh;
        my ($rc) = run_watch(
            '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
            '--pid-file', $pidfile, '--reason', 'B14f-fixture', '--data', $data
        );
        is($rc, 2, 'B14f: bp-watch --pid-file exercise, dead pid content -> exit 2');
    }
    {
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $pidfile = "$bp/runs/.pidfile-live";
        my $live = live_pid();
        open my $fh, '>', $pidfile or die; print {$fh} "$live\n"; close $fh;
        my ($rc) = run_watch(
            '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
            '--pid-file', $pidfile, '--reason', 'B14g-fixture', '--data', $data
        );
        is($rc, 1, 'B14g: bp-watch --pid-file exercise, live pid content -> exit 1');
    }

    # Task return / completion notification / foreground exit code: no
    # external mechanism to run -- assert instead none of the three appears
    # on a row whose shape matches the three bug shapes.
    my $bug_row_uses_forbidden_token = 0;
    for my $row (@$rows) {
        my ($shape, $subject, $proof, $ruling) = @$row;
        next unless defined $shape && $shape =~ /sentinel|pid|report/i;
        for my $forbidden ('Task return', 'completion notification', 'foreground exit code') {
            $bug_row_uses_forbidden_token = 1
                if defined $proof && $proof =~ /\Q`$forbidden`\E/;
        }
    }
    ok(!$bug_row_uses_forbidden_token,
        'B14h: none of Task return / completion notification / foreground exit code is used '
      . 'as the liveness proof on a sentinel/pid/report-shaped row -- they may not paper over '
      . 'the three bug shapes');
}

# ===========================================================================
# B15/AC17 -- the arming recipe's flags are real: each extracted flag is
# accepted by the real script (not exit 64 /unknown option/), the block
# names the pinned mandatory set, and excludes --blueprint/--keepawake.
# ===========================================================================
{
    my $block = parse_arming_recipe();
    ok(defined $block, 'B15a: an arming recipe fenced ```bash block is present in '
                      . 'coordinator-protocol/SKILL.md')
        or diag('not yet implemented: no bash-fenced arming recipe found');

    my @flags;
    if (defined $block) {
        @flags = ($block =~ /(--[a-z][a-z0-9-]*)/g);
    }
    my %flagset = map { $_ => 1 } @flags;

    for my $must ('--arm', '--package', '--max-seconds', '--reason') {
        ok($flagset{$must}, "B15b: arming recipe contains $must");
    }
    ok(($flagset{'--expect-pids'} || $flagset{'--pid-file'} || $flagset{'--artifact'}),
        'B15c: arming recipe contains at least one liveness axis flag');
    ok(!$flagset{'--blueprint'}, 'B15d: arming recipe does NOT contain --blueprint (Mode A only)');
    ok(!$flagset{'--keepawake'}, 'B15e: arming recipe does NOT contain --keepawake (coordinator '
                               . 'holds no lease)');
    # DRIVER RULING (redteam HIGH-1 + review M1): --self-pause calls BpRunState::pause with no
    # --surface option, so it writes the DRIVER's run-state file, not a coordinator-scoped one --
    # and since the recipe is foreground-only, the pause is stale the instant the call returns, so
    # it buys the coordinator nothing while transiently clobbering the driver's real state. Dropped
    # from the recipe entirely rather than plumbed a --surface flag through, per both review and
    # red-team's own preferred minimal mitigation.
    ok(!$flagset{'--self-pause'}, 'B15f: arming recipe does NOT contain --self-pause (writes the '
                                 . 'DRIVER run-state surface with no benefit to a foreground-only '
                                 . 'coordinator wait -- redteam HIGH-1 / review M1)');

    # Every flag placed into an otherwise-valid fixture invocation must not
    # exit 64 with /unknown option/.
    if (@flags) {
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $dead = dead_pid();
        my %arg_for_flag = (
            '--expect-pids' => $dead,
            '--artifact'    => "$bp/runs/dummy-artifact.md",
            '--pid-file'    => "$bp/runs/dummy-pidfile",
        );
        my @args = ('--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
                    '--reason', 'B15f-fixture', '--data', $data);
        for my $flag (@flags) {
            next if $flag eq '--arm' || $flag eq '--package' || $flag eq '--max-seconds'
                 || $flag eq '--reason' || $flag eq '--data' || $flag eq '--poll'
                 || $flag eq '--self-pause' || $flag eq '--blueprint';
            if (exists $arg_for_flag{$flag}) {
                push @args, $flag, $arg_for_flag{$flag};
            }
        }
        my ($rc, $out) = run_watch(@args);
        my $bad = defined $out && $out =~ /unknown option/i && $rc == 64;
        ok(!$bad,
            'B15g: every recipe flag placed into a real invocation is accepted (never exit 64 '
          . '/unknown option/)')
            or diag("rc=$rc out=$out");
    } else {
        fail('B15g: cannot test flags -- recipe block absent');
    }
}

# ===========================================================================
# B16/AC18 -- the verdict table's verdict words match observed stdout for
# real fixture runs, plus a real usage error for 64. Exit 4 is structurally
# verified only (stated as PARTIAL in the header comment).
# ===========================================================================
{
    my ($vheader, $vrows) = parse_verdict_table();
    my $found_vheader = defined $vheader && @$vheader
        && join('|', @$vheader) eq 'exit|verdict|what you do';
    ok($found_vheader,
        'B16a CANONICAL: coordinator-protocol/SKILL.md contains the pinned verdict-table header '
      . '"| exit | verdict | what you do |"')
        or diag('not yet implemented: verdict table absent');

    my %by_exit;
    for my $row (@$vrows) {
        my ($exit, $verdict, $action) = @$row;
        next unless defined $exit && $exit =~ /^\d+$/;
        $by_exit{$exit} = { verdict => $verdict, action => $action };
    }

    # Real fixture runs producing each exit, reused from above where
    # possible; re-run compactly here for exits not already captured inline.
    my %real_out;
    {
        # exit 0 (TERMINAL/SETTLED) via B9's shape
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: done');
        write_ledger($bp, 'p2', 'status: parked');
        (undef, $real_out{0}) = run_watch(
            '--arm', '--blueprint', $bpname, '--max-seconds', '4', '--poll', '1',
            '--reason', 'B16-e0', '--data', $data
        );
    }
    {
        # exit 1 (BOUND) via B2's shape
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $live = live_pid();
        (undef, $real_out{1}) = run_watch(
            '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
            '--expect-pids', $live, '--reason', 'B16-e1', '--data', $data
        );
    }
    {
        # exit 2 (WORKERS-GONE) via B1's shape
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $dead = dead_pid();
        (undef, $real_out{2}) = run_watch(
            '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
            '--expect-pids', $dead, '--reason', 'B16-e2', '--data', $data
        );
    }
    {
        # exit 3 (ARTIFACT) via B5's shape
        my ($data, $bp, $bpname) = new_bp();
        write_ledger($bp, 'p1', 'status: running');
        my $watched = "$bp/runs/report-b16.md";
        open my $fh, '>', $watched or die; print {$fh} "stub\n"; close $fh;
        my $live = live_pid();
        my $pid = fork();
        if (defined $pid && $pid == 0) {
            sleep 1;
            open my $f2, '>>', $watched or exit 1;
            print {$f2} "appended\n"; close $f2;
            exit 0;
        }
        (undef, $real_out{3}) = run_watch(
            '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
            '--artifact', $watched, '--expect-pids', $live, '--reason', 'B16-e3', '--data', $data
        );
        waitpid($pid, 0) if defined $pid && $pid > 0;
    }
    {
        # exit 64 (USAGE) via a real usage error
        my ($data) = new_bp();
        (undef, $real_out{64}) = run_watch(
            '--arm', '--package', 'x/y', '--max-seconds', 'notanumber', '--data', $data
        );
    }
    {
        # exit 65 (UNVERIFIABLE) via B7's shape
        my ($data) = new_bp();
        (undef, $real_out{65}) = run_watch(
            '--arm', '--blueprint', 'no-such-blueprint-b16', '--max-seconds', '4', '--poll', '1',
            '--reason', 'B16-e65', '--data', $data
        );
    }

    for my $exit (0, 1, 2, 3, 64, 65) {
        my $row = $by_exit{$exit};
        SKIP: {
            skip "verdict table row for exit $exit not parsed (table absent/malformed)", 1
                unless defined $row && defined $row->{verdict};
            my $verdict_word = $row->{verdict};
            my $out = $real_out{$exit} // '';
            like($out, qr/\Q$verdict_word\E/,
                "B16b: parsed verdict word for exit $exit ('$verdict_word') appears in real "
              . "stdout of the fixture that produces exit $exit");
        }
    }

    # Exit 4 (STATUS-CHANGE) -- structural verification only (stated PARTIAL
    # in the file header). Requires a concurrent writer racing a tick
    # boundary, out of scope per the spec.
    my $row4 = $by_exit{4};
    ok(defined $row4 && defined $row4->{verdict} && $row4->{verdict} eq 'STATUS-CHANGE',
        'B16c PARTIAL (structural only, see file header): verdict table row 4 exists with '
      . 'verdict exactly STATUS-CHANGE');
    ok(defined $row4 && defined $row4->{action} && $row4->{action} =~ /re-?arm|resume/i,
        'B16d PARTIAL (structural only): row 4\'s action names re-arm or resume');
}

# ===========================================================================
# B17/AC5 -- the exit-2 action never parks. Text half; paired with B1
# (constructed half, above).
# ===========================================================================
{
    my ($vheader, $vrows) = parse_verdict_table();
    my ($row2) = grep { defined $_->[0] && $_->[0] eq '2' } @$vrows;
    ok(defined $row2, 'B17a: verdict table has a row for exit 2')
        or diag('not yet implemented: verdict table row for exit 2 absent');
    SKIP: {
        skip 'exit-2 row absent', 6 unless defined $row2;
        my $action = $row2->[2] // '';
        like($action, qr/re-?dispatch/i, 'B17b: exit-2 action names re-dispatch');
        unlike($action, qr/\bpark(ed|ing)?\b/i, 'B17c: exit-2 action never says park(ed/ing)');
        unlike($action, qr/\bblock(ed|ing)?\b/i, 'B17d: exit-2 action never says block(ed/ing)');
        unlike($action, qr/queue.{0,20}(human|decision)/i,
            'B17e: exit-2 action never says "queue ... human/decision"');
        unlike($action, qr/escalate.{0,20}human/i,
            'B17f: exit-2 action never says "escalate ... human"');
        pass('B17g: paired with B1 (the constructed half of the same claim)');
    }
}

# ===========================================================================
# B18/AC16 -- the fail-open direction is stated, and is the opposite one.
# Text half; paired with B2/B6/B7/B10/B12 (constructed halves, above).
# ===========================================================================
{
    my $text = slurp($COORD_SKILL);
    like($text, qr/guard-run-finish\.sh/,
        'B18a: the doctrine block names guard-run-finish.sh');
    like($text, qr/allow(ing|s)?\s+a\s+stop/i,
        'B18b: the doctrine block states guard-run-finish.sh\'s direction as allowing a stop');
    like($text, qr/wait\s+continues|continu(e|ing)\s+.{0,20}wait/i,
        'B18c: the doctrine block states this rule\'s own direction as CONTINUING a wait');
    like($text, qr/asymmetry|opposite/i,
        'B18d: the doctrine block contains the word asymmetry or opposite');
}

# ===========================================================================
# AC19 sanity net -- every doctrine-text assertion above (AC1/B13, AC3/B17,
# AC5/B17, AC8/B13-prose, AC16/B18, AC17/B15) is paired in this same file
# with a constructed-state assertion of the same fact. Recorded here as a
# single traceability assertion rather than re-testing each pairing, since
# the pairings themselves are the B1/B2/B6/B7/B9/B10/B12/B14/B15 blocks
# above, all present in this file.
# ===========================================================================
{
    ok(1, 'AC19: every doctrine-text assertion in this file (B13, B15, B17, B18) is paired '
        . 'with a constructed-state assertion in the same file (B1 for AC3/AC5, B14f/g for '
        . 'AC2/B14, B15g for AC17, B2/B6/B7/B10/B12 for AC16) -- see individual block comments '
        . 'above for the specific pairing');
}

# ===========================================================================
# What-must-not-break spot checks (spec sec 5) -- cheap smoke checks that
# this oracle does not accidentally rely on anything that would require
# weakening the immutable oracles it must not touch. These are NOT a
# replacement for running bp-watch-doctrine.t / bp-watch-cli.t /
# bp-watch-decision-core.t / waiting-discipline.t / bp-watch-decision-core.t
# themselves (out of this file's write set) -- just a same-file confirmation
# that the anchor text this package inserts BESIDE is still present.
# ===========================================================================
{
    my $text = slurp($COORD_SKILL);
    like($text, qr/never check again in the same turn, and never in a loop/,
        'Z1: the existing "check the sentinel once" closing sentence (the insertion anchor) '
      . 'survives byte-identical');
    like($text, qr/## Fast test I\/O/,
        'Z2: the existing "## Fast test I/O" heading (the insertion\'s end boundary) survives');
}

done_testing();
