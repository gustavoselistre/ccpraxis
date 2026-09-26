#!/usr/bin/env perl
# platform: any
# ORACLE for hook-continuity-remake package 09 (move the operator question
# queue to almanac pending decisions): the butler-continuity ask/questions/
# answer verbs, the AskUserQuestion guard's filing behaviour, the wake-lock
# status line (Decision 83), and the statusline ?N counter (Decision 108).
# Q1-Q21 and S1-S8 of
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 09-question-queue-spec.md sections 2.3-2.7 and 3-4. Written blind to any
# implementation inside this package's write set: derived only from that
# spec text, plus the already-implemented shared interfaces it names
# explicitly (BpHook, BpContinuityLease -- package 03; the almanac decision
# store -- almanac-records package 08; GuardHarness -- package 14 batch 1).
#
# HERMETICITY (spec sec 4.0, binding). Every in-process store call below
# passes an explicit root. Every CLI child chdirs into a temp project, a
# subdirectory of one, or a checked "outside" dir via the ':cwd' pseudo-key
# (never the process cwd, which is this repo). Every hook call carries a temp
# payload cwd, or deliberately none per spec sec 2.5 (never falls back to the
# process cwd itself). Q15/Q21 compare a before/after snapshot of THIS repo's
# real .subagent-guard/ and almanac/decision/ stores as the final proof that
# nothing here ever touched them.
#
# Runs standalone: perl this file
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use File::Find ();
use JSON::PP ();
use POSIX qw(WNOHANG);
use Cwd ();
use Encode ();

use lib "$Bin/../lib";
use GuardHarness;

(my $BUTLER_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $CMD = "$BUTLER_SCRIPTS/butler-continuity.pl";
my $GAO_PM = "$BUTLER_SCRIPTS/BpHook/Guards/GuardAskOperator.pm";
(my $ALM_SCRIPTS = "$Bin/../../../almanac/scripts") =~ s{\\}{/}g;
my $DECISION_PL = "$ALM_SCRIPTS/almanac-decision.pl";
(my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl") =~ s{\\}{/}g;
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $SKILL_MD = "$Bin/../../skills/continuity/SKILL.md";

require "$BUTLER_SCRIPTS/BpHook.pm";
require "$BUTLER_SCRIPTS/BpContinuityLease.pm";
{
    local $@;
    do $DECISION_PL if -f $DECISION_PL;
    diag("almanac-decision.pl failed to load: $@") if $@;
}

# ---------------------------------------------------------------------------
# Ambient isolation for THIS file's own CLI/statusline spawns. GuardHarness
# runs its own isolate_env() at "use" time above (for its run_module/
# run_shim calls, which localize %ENV per call); this is the separate,
# persistent baseline for the plain CLI/statusline subprocess helpers below.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
my $FILE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FILE_HOME = "$FILE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FILE_HOME);
$ENV{HOME}         = $FILE_HOME;
$ENV{USERPROFILE}  = $FILE_HOME;
$ENV{ALMANAC_HOME} = $FILE_HOME;
delete $ENV{BUTLER_STATE_DIR};

my $TMPROOT = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# scaffolding: files, projects, snapshots
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

sub norm_root {
    my ($p) = @_;
    (my $r = $p) =~ s{\\}{/}g;
    $r =~ s{/\z}{};
    return $r;
}

sub mk_project {
    my $t = tempdir(CLEANUP => 1);
    my $root = norm_root($t);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

# outside_dir() -- a fresh tempdir checked to have NO ancestor holding
# .ccpraxis-local-data or .git (spec sec 4.0's mandatory check). Returns
# undef if the check fails, so every call site skips rather than risking a
# write into a real project.
sub outside_dir {
    my $t = tempdir(CLEANUP => 1);
    my $d = norm_root(Cwd::abs_path($t));
    my $probe = $d;
    while (1) {
        return undef if -d "$probe/.ccpraxis-local-data" || -e "$probe/.git";
        my $idx = rindex($probe, '/');
        last if $idx <= 0;
        my $parent = substr($probe, 0, $idx);
        last if $parent eq $probe || $parent eq '';
        $probe = $parent;
    }
    return $d;
}

sub snapshot_dir {
    my ($dir) = @_;
    my %seen;
    return { exists => 0, entries => \%seen } unless -d $dir;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; next }
            my @st = stat $full;
            (my $rel = $full) =~ s{\\}{/}g;
            $seen{$rel} = ($st[9] // 0) . ':' . ($st[7] // 0);
        }
        closedir $dh;
    }
    return { exists => 1, entries => \%seen };
}
sub real_state_snapshot {
    return {
        guard    => snapshot_dir("$REPO_ROOT/.ccpraxis-local-data/.subagent-guard"),
        decision => snapshot_dir("$REPO_ROOT/.ccpraxis-local-data/almanac/decision"),
    };
}
my $REAL_BEFORE = real_state_snapshot();

# ---------------------------------------------------------------------------
# AD(name, @args) / AD_list(name, @args) -- call Almanac::Decision::<name>
# without ever crashing this file when the sub doesn't behave as hoped.
# ---------------------------------------------------------------------------
sub AD_list {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"Almanac::Decision::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? @ret : ();
}
sub AD {
    my ($name, @args) = @_;
    my ($first) = AD_list($name, @args);
    return $first;
}

# ---------------------------------------------------------------------------
# butler-continuity CLI spawn, supporting the ':cwd' pseudo-key (spec sec
# 2.8(a) item 1's exact idiom: the child chdirs to it before exec, and it is
# never exported as a real environment variable).
# ---------------------------------------------------------------------------
sub spawn_cli {
    my ($env_over, @argv) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my %eo = %$env_over;
        my $cwd = delete $eo{':cwd'};
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME} = $FILE_HOME; $ENV{USERPROFILE} = $FILE_HOME; $ENV{ALMANAC_HOME} = $FILE_HOME;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        for my $k (keys %eo) {
            if (defined $eo{$k}) { $ENV{$k} = $eo{$k} } else { delete $ENV{$k} }
        }
        if (defined $cwd) {
            chdir($cwd) or POSIX::_exit(125);
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $CMD, @argv);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}
sub wait_cli {
    my ($pid, $outfile, $errfile, %o) = @_;
    my $deadline = time() + ($o{timeout} // 20);
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        select(undef, undef, undef, 0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1; }
    my $out = slurp($outfile); my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return (defined($out) ? $out : '', defined($err) ? $err : '', $rc);
}
sub run_cli {
    my ($env_over, @argv) = @_;
    my ($pid, $o, $e) = spawn_cli($env_over, @argv);
    return wait_cli($pid, $o, $e);
}

# ---------------------------------------------------------------------------
# state-dir + ticket helpers for the 'status' verb (Q19), mirroring
# continuity-command-verbs.t's own fresh_state_dir()/write_ticket_argv().
# ---------------------------------------------------------------------------
my $CURRENT_STATE_BASE;
sub use_state_dir { my ($d) = @_; $ENV{BUTLER_STATE_DIR} = $d; $CURRENT_STATE_BASE = $d; return $d }
sub fresh_state_dir {
    my $t = tempdir(CLEANUP => 1);
    return use_state_dir(norm_root("$t/state"));
}
my $TUID_N = 0;
sub next_tuid { return sprintf('tuq%06x', ++$TUID_N) }
sub write_ticket_argv {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path} // "$TMPROOT/transcripts/$sid.jsonl",
        cwd             => $o{cwd} // mk_project(),
    };
    my $ok = BpHook::write_ticket($p, 'butler-continuity', $argv, operator => 0, background => 0);
    return ($ok, $tuid);
}

# ---------------------------------------------------------------------------
# hook payload + GuardHarness wrapper (spec sec 2.5)
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $tool = $o{tool} // 'AskUserQuestion';
    my $ti = {};
    if (exists $o{questions}) {
        $ti->{questions} = [ map { defined $_ ? { question => $_ } : {} } @{ $o{questions} } ];
    }
    my $p = { tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    return $p;
}
sub ao {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardAskOperator', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# statusline invocation (mirrors continuity-statusline-badge.t's own
# run_statusline() convention: a real subprocess, output via backtick, ANSI
# stripped before matching). Always run from an OUTSIDE scratch dir, never
# this repo's own working directory, even though the block under test reads
# only the payload's workspace.current_dir and never the process cwd.
# ---------------------------------------------------------------------------
sub strip_ansi { my ($s) = @_; $s =~ s/\033\[[^m]*m//g; return $s }

sub sl_payload {
    my (%opt) = @_;
    return {
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    };
}

sub run_statusline_q {
    my ($payload_h, %opt) = @_;
    my ($infh, $inpath) = tempfile();
    binmode $infh, ':raw';
    print {$infh} JSON::PP->new->utf8->encode($payload_h);
    close $infh;

    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{HOME} = $FILE_HOME; $ENV{USERPROFILE} = $FILE_HOME;
    for my $k (keys %{ $opt{env} // {} }) {
        if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
    }
    my $scratch = tempdir(CLEANUP => 1);   # never the repo's own cwd
    my $qinpath  = quotemeta($inpath);
    my $qstatus  = quotemeta($STATUSLINE);
    my $qscratch = quotemeta($scratch);
    my $out = `cd $qscratch && timeout 20 perl $qstatus < $qinpath 2>/dev/null`;
    my $rc = $? >> 8;
    unlink $inpath;
    return (strip_ansi(defined($out) ? $out : ''), $rc);
}

# ===========================================================================
# Q1 -- ask filing a pending decision, from a project subdirectory, no
# CLAUDE_PROJECT_DIR.
# ===========================================================================
{
    my $P = mk_project();
    my $sub = "$P/sub/dir";
    make_path($sub);
    my ($out, $err, $rc) = run_cli({ ':cwd' => $sub }, 'ask', '--text', 'first q');
    is($rc, 0, 'Q1: ask --text from a project subdirectory, no CLAUDE_PROJECT_DIR, exits 0') or diag("stderr: $err");
    like($out, qr/^queued pending decision (\S+) \(1 waiting\) in .+$/, 'Q1: stdout matches the pinned shape');
    my ($id) = $out =~ /^queued pending decision (\S+) /;
    my $list = AD('list_decisions', root => $P);
    my ($rec) = (ref $list eq 'ARRAY' && defined $id) ? grep { $_->{id} eq $id } @$list : ();
    ok(defined $rec, 'Q1: the printed id is filed in P');
    is(ref $rec eq 'HASH' ? $rec->{fields}{title} : undef, 'first q', 'Q1: title is "first q"');
    is(ref $rec eq 'HASH' ? $rec->{fields}{status} : undef, 'unanswered', 'Q1: status is unanswered');
}

# ===========================================================================
# Q2 -- run from a checked outside cwd with CLAUDE_PROJECT_DIR=P: filed in P,
# the outside dir gains no .ccpraxis-local-data.
# ===========================================================================
{
    my $P = mk_project();
    my $OUTSIDE = outside_dir();
    SKIP: {
        skip 'Q2: could not construct a clean outside dir on this host (an ancestor already holds '
           . '.git or .ccpraxis-local-data)', 3
            unless defined $OUTSIDE;
        my ($out, $err, $rc) = run_cli({ ':cwd' => $OUTSIDE, CLAUDE_PROJECT_DIR => $P }, 'ask', '--text', 'q2?');
        is($rc, 0, 'Q2: ask from an outside cwd with CLAUDE_PROJECT_DIR set exits 0') or diag("stderr: $err");
        my $list = AD('list_decisions', root => $P);
        ok((ref $list eq 'ARRAY' && (grep { $_->{fields}{title} eq 'q2?' } @$list)), 'Q2: filed in P');
        ok(!-d "$OUTSIDE/.ccpraxis-local-data", 'Q2: the outside dir gains no .ccpraxis-local-data');
    }
}

# ===========================================================================
# Q3 -- an embedded newline flattens to a single space; a non-ASCII title
# round-trips exactly.
# ===========================================================================
{
    my $P = mk_project();
    my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'ask', '--text', "line one\nline two");
    is($rc, 0, 'Q3: ask with an embedded newline exits 0') or diag("stderr: $err");
    my $list = AD('list_decisions', root => $P);
    ok((ref $list eq 'ARRAY' && (grep { defined $_->{fields}{title} && $_->{fields}{title} eq 'line one line two' } @$list)),
       'Q3: the newline is flattened to a single space in the title');

    my $accented = "caf\x{e9} decis\x{e3}o?";
    my $accented_bytes = Encode::encode('UTF-8', $accented);
    run_cli({ ':cwd' => $P }, 'ask', '--text', $accented_bytes);
    my $list2 = AD('list_decisions', root => $P);
    ok((ref $list2 eq 'ARRAY'
        && (grep { defined $_->{fields}{title} && $_->{fields}{title} eq $accented } @$list2)),
       'Q3: a non-ASCII title round-trips character-for-character');
}

# ===========================================================================
# Q4 -- a missing, empty or whitespace-only --text refuses; the count is
# unchanged.
# ===========================================================================
{
    my $P = mk_project();
    for my $case ([[], 'missing --text'], [['--text', ''], 'empty --text'], [['--text', '   '], 'whitespace-only --text']) {
        my ($extra, $label) = @$case;
        my $before = AD('list_decisions', root => $P);
        my $before_n = (ref $before eq 'ARRAY') ? scalar(@$before) : 0;
        my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'ask', @$extra);
        is($rc, 1, "Q4: $label exits 1");
        like($err, qr/^butler-continuity: ask needs --text/, "Q4: $label refuses with the pinned prefix");
        my $after = AD('list_decisions', root => $P);
        my $after_n = (ref $after eq 'ARRAY') ? scalar(@$after) : 0;
        is($after_n, $before_n, "Q4: $label leaves the count unchanged");
    }
}

# ===========================================================================
# Q5 -- no questions.md anywhere the file used.
# ===========================================================================
{
    my $P = mk_project();
    run_cli({ ':cwd' => $P }, 'ask', '--text', 'q5a');
    run_cli({ ':cwd' => $P }, 'ask', '--text', "q5b\nq5b line2");
    ok(!-e "$P/.ccpraxis-local-data/.subagent-guard/questions.md", 'Q5: ask never writes questions.md');
}

# ===========================================================================
# Q6 -- questions lists the unanswered decisions, then "<N> waiting in <P>";
# an empty project prints only "0 waiting in ...".
# ===========================================================================
{
    my $P = mk_project();
    run_cli({ ':cwd' => $P }, 'ask', '--text', 'alpha?');
    run_cli({ ':cwd' => $P }, 'ask', '--text', 'beta?');
    my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'questions');
    is($rc, 0, 'Q6: questions exits 0') or diag("stderr: $err");
    my @lines = split /\n/, $out;
    my $last = pop @lines // '';
    like($last, qr/^2 waiting in .+$/, 'Q6: the last line is "2 waiting in <project>"');
    is(scalar(@lines), 2, 'Q6: two question lines precede the summary');
    for my $l (@lines) {
        like($l, qr/^- \S+ \[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] .+$/, 'Q6: line shape "- <id> [<created>] <title>"');
    }
    my @titles = sort map { /\] (.*)\z/ ? $1 : '' } @lines;
    is_deeply(\@titles, ['alpha?', 'beta?'], 'Q6: the exact filed texts are listed');

    my $EMPTY = mk_project();
    my ($out2, $err2, $rc2) = run_cli({ ':cwd' => $EMPTY }, 'questions');
    is($rc2, 0, 'Q6: an empty project also exits 0') or diag("stderr: $err2");
    like($out2, qr/^0 waiting in /, 'Q6: an empty project prints "0 waiting in ..."');
    is(scalar(split /\n/, $out2), 1, 'Q6: an empty project prints only that one line');
}

# ===========================================================================
# Q7 -- answer marks a question answered and clears it from the listing.
# ===========================================================================
{
    my $P = mk_project();
    my ($out1, $err1) = run_cli({ ':cwd' => $P }, 'ask', '--text', 'to answer?');
    my ($id) = $out1 =~ /^queued pending decision (\S+) /;
    ok(defined $id, 'Q7 fixture: ask filed a question') or diag("stdout: $out1 stderr: $err1");
    run_cli({ ':cwd' => $P }, 'ask', '--text', 'stays open?');

    SKIP: {
        skip 'Q7: no id to answer (ask did not file)', 5 unless defined $id;
        my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'answer', '--id', $id, '--answer', 'use v2');
        is($rc, 0, 'Q7: answer exits 0') or diag("stderr: $err");
        is($out, "answered $id: to answer?\n", 'Q7: stdout is the pinned answered line');

        my $list = AD('list_decisions', root => $P);
        my ($rec) = (ref $list eq 'ARRAY') ? grep { $_->{id} eq $id } @$list : ();
        is(ref $rec eq 'HASH' ? $rec->{fields}{status} : undef, 'answered', 'Q7: the store shows it answered');
        is(ref $rec eq 'HASH' ? $rec->{fields}{answer} : undef, 'use v2', 'Q7: with the given answer text');

        my ($qout, $qerr, $qrc) = run_cli({ ':cwd' => $P }, 'questions');
        unlike($qout, qr/\Q$id\E/, 'Q7: questions no longer lists the answered id (1 waiting)');
    }
}

# ===========================================================================
# Q8 -- answer's remaining branches: idempotent repeat, a different answer,
# an unknown id, and missing flags -- each refuses cleanly, nothing changes.
# ===========================================================================
{
    my $P = mk_project();
    my ($out1) = run_cli({ ':cwd' => $P }, 'ask', '--text', 'q8?');
    my ($id) = $out1 =~ /^queued pending decision (\S+) /;
    ok(defined $id, 'Q8 fixture: ask filed a question');

    SKIP: {
        skip 'Q8: no id to answer', 8 unless defined $id;
        run_cli({ ':cwd' => $P }, 'answer', '--id', $id, '--answer', 'go with A');

        my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'answer', '--id', $id, '--answer', 'go with A');
        is($rc, 0, 'Q8: repeating the same answer exits 0');
        is($out, "$id already answered; nothing changed\n", 'Q8: pinned no-op line');

        my ($out2, $err2, $rc2) = run_cli({ ':cwd' => $P }, 'answer', '--id', $id, '--answer', 'go with B');
        is($rc2, 1, 'Q8: a DIFFERENT answer exits 1');
        is($err2, "butler-continuity: decision $id is already answered.\n", 'Q8: pinned refusal line');

        my ($out3, $err3, $rc3) = run_cli({ ':cwd' => $P }, 'answer', '--id', 'no-such-id-q8', '--answer', 'x');
        is($rc3, 1, 'Q8: an unknown id exits 1');
        like($err3, qr/^butler-continuity: no pending decision no-such-id-q8 in .+\.\n?\z/, 'Q8: pinned not_found line');

        my ($out4, $err4, $rc4) = run_cli({ ':cwd' => $P }, 'answer', '--id', $id);
        is($rc4, 1, 'Q8: missing --answer exits 1');
        like($err4, qr/^butler-continuity: answer needs --id <id> --answer /, 'Q8: pinned usage line (missing --answer)');

        my $rec = AD('read_decision', $id, root => $P);
        is(ref $rec eq 'HASH' ? $rec->{fields}{answer} : undef, 'go with A', 'Q8: the store answer is unchanged by any refusal');
    }
}

# ===========================================================================
# Q9 -- a seeded legacy file: questions lists its texts, and it is renamed.
# ===========================================================================
{
    my $P = mk_project();
    my $legacy_dir = "$P/.ccpraxis-local-data/.subagent-guard";
    make_path($legacy_dir);
    write_raw("$legacy_dir/questions.md", "- [2020-01-01T00:00:00Z] legacy one?\n- legacy two?\n");

    my ($out, $err, $rc) = run_cli({ ':cwd' => $P }, 'questions');
    is($rc, 0, 'Q9: questions exits 0 after a seeded legacy file') or diag("stderr: $err");
    like($out, qr/legacy one\?/, 'Q9: the first legacy text is listed');
    like($out, qr/legacy two\?/, 'Q9: the second legacy text is listed');
    ok(!-e "$legacy_dir/questions.md", 'Q9: questions.md is gone');
    ok(-f "$legacy_dir/questions.md.migrated", 'Q9: questions.md.migrated exists');
}

# ===========================================================================
# Q10/Q13 -- an armed session's AskUserQuestion is denied, files one joined
# decision in the payload-cwd project, stdout carries no "continue":false;
# the question later appears in "questions" output from that project.
# ===========================================================================
my ($Q10_PROJECT, $Q10_TITLE);
{
    my $P = mk_project();
    GuardHarness::fresh_state();
    my $sid = 'q10-armed';
    ok(GuardHarness::arm($sid, 'manual'), 'Q10 setup: session armed');
    my $res = ao(payload(session_id => $sid, cwd => $P, questions => ['Which DB?', "Deploy t\x{e9}st?"]),
        env => { CLAUDE_PROJECT_DIR => $P });
    is($res->{rc}, 2, 'Q10: an armed session denies') or diag("stderr: $res->{err}");
    my @lines = split /\n/, $res->{err};
    pop @lines while @lines && $lines[-1] eq '';
    is(scalar(@lines), 4, 'Q10: stderr has 4 lines');
    like($lines[1] // '', qr/^The question is filed as pending decision \S+\.$/, 'Q10: line 2 names the filed decision');
    unlike($res->{out}, qr/"continue":false/, 'Q10: stdout carries no "continue":false');

    $Q10_PROJECT = $P;
    $Q10_TITLE   = "Which DB? | Deploy t\x{e9}st?";
    my $list = AD('list_decisions', root => $P);
    ok((ref $list eq 'ARRAY'
        && (grep { defined $_->{fields}{title} && $_->{fields}{title} eq $Q10_TITLE } @$list)),
       'Q10: the two questions are joined by " | " into one filed title');
}
{
    SKIP: {
        skip 'Q13: Q10 did not produce a project to re-check', 1 unless defined $Q10_PROJECT;
        my ($out, $err, $rc) = run_cli({ ':cwd' => $Q10_PROJECT }, 'questions');
        # slurp() reads ':raw' bytes; $Q10_TITLE is a decoded character
        # string (it holds \x{e9}, not the two UTF-8 bytes that encode it).
        # Decode the child's stdout the same way before comparing, so both
        # sides are characters -- consistent with how AD()/list_decisions
        # already hands back decoded characters everywhere else in this file.
        my $out_text = eval { Encode::decode('UTF-8', $out) };
        $out_text = $out unless defined $out_text;
        like($out_text, qr/\Q$Q10_TITLE\E/, 'Q13: Q10\'s question appears in "questions" output from P with its exact title');
    }
}

# ===========================================================================
# Q11 -- BP_LEDGER set (coordinator), unarmed: denies, and files.
# ===========================================================================
{
    my $P = mk_project();
    GuardHarness::fresh_state();
    my $sid = 'q11-coord';
    my $res = ao(payload(session_id => $sid, cwd => $P, questions => ['Proceed?']),
        env => { CLAUDE_PROJECT_DIR => $P, BP_LEDGER => '/x/ledger.md' });
    is($res->{rc}, 2, 'Q11: BP_LEDGER set, unarmed, denies');
    my $list = AD('list_decisions', root => $P);
    ok((ref $list eq 'ARRAY' && (grep { $_->{fields}{title} eq 'Proceed?' } @$list)), 'Q11: the question is filed');
}

# ===========================================================================
# Q12 -- session A unarmed, session B armed (same project/state dir): A
# allows with empty stdout/stderr, count unchanged.
# ===========================================================================
{
    my $P = mk_project();
    my $state = GuardHarness::fresh_state();
    my $sidA = 'q12-unarmed';
    my $sidB = 'q12-armed';
    ok(GuardHarness::arm($sidB, 'manual'), 'Q12 setup: session B armed');
    my $before = AD('list_decisions', root => $P);
    my $before_n = (ref $before eq 'ARRAY') ? scalar(@$before) : 0;

    my $res = ao(payload(session_id => $sidA, cwd => $P, questions => ['Anybody home?']),
        env => { CLAUDE_PROJECT_DIR => $P, BUTLER_STATE_DIR => $state });
    is($res->{rc}, 0, 'Q12: session A (unarmed) allows despite session B being armed');
    is($res->{out}, '', 'Q12: empty stdout');
    is($res->{err}, '', 'Q12: empty stderr');

    my $after = AD('list_decisions', root => $P);
    my $after_n = (ref $after eq 'ARRAY') ? scalar(@$after) : 0;
    is($after_n, $before_n, 'Q12: the decision count is unchanged');
}

# ===========================================================================
# Q14 -- armed, with P/.ccpraxis-local-data/almanac blocked by a regular
# file: still denies with "could not be filed", no crash text.
# ===========================================================================
{
    my $P = mk_project();
    GuardHarness::fresh_state();
    my $sid = 'q14-blocked-almanac';
    ok(GuardHarness::arm($sid, 'manual'), 'Q14 setup: session armed');
    write_raw("$P/.ccpraxis-local-data/almanac", "not a directory\n");

    my $res = ao(payload(session_id => $sid, cwd => $P, questions => ['Blocked?']),
        env => { CLAUDE_PROJECT_DIR => $P });
    is($res->{rc}, 2, 'Q14: armed, with almanac/ blocked by a regular file, still denies');
    like($res->{err}, qr/could not be filed; note it in your report instead\.$/m, 'Q14: the could-not-be-filed line appears');
    unlike($res->{err}, qr/\bat\b.*\bline\b\s+\d+/, 'Q14: no Perl crash text (no "at <file> line N")');
}

# ===========================================================================
# Q15 -- armed, no payload cwd, CLAUDE_PROJECT_DIR unset, hook run with the
# test's own cwd: still denies, and the real store is untouched immediately.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $sid = 'q15-no-cwd';
    ok(GuardHarness::arm($sid, 'manual'), 'Q15 setup: session armed');
    my $res = ao(payload(session_id => $sid, questions => ['No cwd at all?']), env => {});
    is($res->{rc}, 2, 'Q15: armed, no payload cwd, CLAUDE_PROJECT_DIR unset, denies');
    like($res->{err}, qr/could not be filed; note it in your report instead\.$/m, 'Q15: the could-not-be-filed line appears');
    is_deeply(real_state_snapshot(), $REAL_BEFORE,
       'Q15: the real repo store is unchanged immediately after this call (no fallback to the process cwd)');
}

# ===========================================================================
# Q16 -- "questions.md" appears in exactly one source file across the
# scanned trees.
# ===========================================================================
{
    my @dirs;
    for my $plugin_dir (sort glob("$REPO_ROOT/plugins/*")) {
        for my $sub (qw(scripts hooks bin)) {
            push @dirs, "$plugin_dir/$sub" if -d "$plugin_dir/$sub";
        }
    }
    push @dirs, "$REPO_ROOT/scripts" if -d "$REPO_ROOT/scripts";
    my @hits;
    for my $d (@dirs) {
        File::Find::find({ no_chdir => 1, wanted => sub {
            return unless -f $_ && /\.(?:pl|pm|sh)\z/;
            my $c = slurp($_);
            return unless defined $c && $c =~ /questions\.md/;
            my $rel = File::Spec->abs2rel($_, $REPO_ROOT);
            $rel =~ s{\\}{/}g;
            push @hits, $rel;
        } }, $d);
    }
    is_deeply([ sort @hits ], [ 'plugins/almanac/scripts/Almanac/LegacyQueue.pm' ],
       'Q16: "questions.md" appears in exactly one scanned source file');
}

# ===========================================================================
# Q17 -- neither butler-continuity.pl nor GuardAskOperator.pm mentions the
# retired resolution machinery; both mention Almanac::Decision::.
# ===========================================================================
{
    my $cc_src  = -f $CMD    ? (slurp($CMD)    // '') : '';
    my $gao_src = -f $GAO_PM ? (slurp($GAO_PM) // '') : '';
    for my $pair ([ 'butler-continuity.pl', $cc_src ], [ 'GuardAskOperator.pm', $gao_src ]) {
        my ($label, $src) = @$pair;
        for my $forbidden ('Almanac::Store', '.ccpraxis-local-data/almanac', '.subagent-guard', 'BP_PROJECT_ROOT') {
            unlike($src, qr/\Q$forbidden\E/, "Q17: $label never mentions $forbidden");
        }
        like($src, qr/Almanac::Decision::/, "Q17: $label mentions Almanac::Decision::");
    }
}

# ===========================================================================
# Q18 -- the continuity block of SKILL.md names all three verbs, within the
# 40-non-blank-line budget.
# ===========================================================================
{
    my $src = -f $SKILL_MD ? (slurp($SKILL_MD) // '') : '';
    my @lines = split /\n/, $src;
    my ($bi, $ei);
    for my $i (0 .. $#lines) {
        $bi = $i if !defined($bi) && $lines[$i] =~ /^<!--\s*continuity:begin\s*-->\s*$/;
        $ei = $i if $lines[$i] =~ /^<!--\s*continuity:end\s*-->\s*$/;
    }
    ok(defined($bi) && defined($ei) && $bi < $ei, 'Q18: the continuity block markers are present')
        or diag('markers not found in ' . $SKILL_MD);
    SKIP: {
        skip 'Q18: block markers not found', 4 unless defined($bi) && defined($ei) && $bi < $ei;
        my @block = @lines[$bi + 1 .. $ei - 1];
        my $block_text = join("\n", @block);
        my $nonblank = grep { !/^\s*$/ } @block;
        cmp_ok($nonblank, '<=', 40, 'Q18: the continuity block has at most 40 non-blank lines');
        like($block_text, qr/butler-continuity ask --text/, 'Q18: the block names ask --text');
        like($block_text, qr/butler-continuity questions/, 'Q18: the block names questions');
        like($block_text, qr/butler-continuity answer --id/, 'Q18: the block names answer --id');
    }
}

# ===========================================================================
# Q19 -- Windows-only: status judges the wake-lock by keepawake.pid's
# heartbeat age (Decision 83), whatever the pid.
# ===========================================================================
{
    SKIP: {
        skip 'Q19: Windows-only wake-lock heartbeat check (Decision 83)', 2 unless $^O eq 'MSWin32';
        fresh_state_dir();
        my $LDIR = tempdir(CLEANUP => 1);
        my $ldir = norm_root($LDIR);
        write_raw("$ldir/keepawake.pid", "987654\n");
        my $P = mk_project();
        my $sid = 'q19-sid';
        write_ticket_argv($sid, ['status'], cwd => $P);

        my %env19 = (
            BUTLER_STATE_DIR               => $CURRENT_STATE_BASE,
            CCPRAXIS_NO_WAKELOCK           => '',
            CCPRAXIS_CONTINUITY_ACTIVE_DIR => $ldir,
            ':cwd'                         => $P,
        );
        my ($out, $err, $rc) = run_cli(\%env19, 'status');
        is($rc, 0, 'Q19 fixture: status exits 0') or diag("stderr: $err");
        like($out, qr/^wake-lock: held$/m, 'Q19: a fresh keepawake.pid reports wake-lock: held, whatever the pid');

        utime(time() - 3600, time() - 3600, "$ldir/keepawake.pid");
        write_ticket_argv($sid, ['status'], cwd => $P);
        my ($out2, $err2, $rc2) = run_cli(\%env19, 'status');
        like($out2, qr/^wake-lock: released$/m, 'Q19: an hour-old keepawake.pid reports wake-lock: released');
    }
}

# ===========================================================================
# Q20 -- butler-continuity.pl's source no longer calls kill(0, ...).
# ===========================================================================
{
    my $src = -f $CMD ? (slurp($CMD) // '') : '';
    unlike($src, qr/\bkill\s*\(\s*0\b|\bkill\s+0\b/, 'Q20: butler-continuity.pl source has no kill(0 or kill 0');
}

# ===========================================================================
# S1-S8 -- the statusline ?N counter (Decision 108, spec sec 2.7).
# ===========================================================================
# hook-continuity-remake package 10 (Decision 116) replaced the "?N" glyph
# with U+2691 followed by N. S1, S3, S5 and S6 assert that flag form, compared
# as UTF-8 bytes (the statusline output is read raw); the counts they pin are
# unchanged. Decision 121 repointed S2 and S4's negative checks to the same
# flag form, so they can fail again.
my $FLAG_BYTES = Encode::encode('UTF-8', chr(0x2691));

# S1 -- 3 records (2 unanswered, 1 answered): ?2, not followed by a digit.
{
    my $P = mk_project();
    AD_list('file', root => $P, title => 'S1 unanswered A');
    AD_list('file', root => $P, title => 'S1 unanswered B');
    my $rec3 = AD('file', root => $P, title => 'S1 answered');
    AD_list('answer', $rec3->{id}, root => $P, answer => 'ok') if ref $rec3 eq 'HASH';

    my ($out, $rc) = run_statusline_q(sl_payload(current_dir => $P));
    is($rc, 0, 'S1: statusline exits 0') or diag($out);
    like($out, qr/\Q$FLAG_BYTES\E2(?!\d)/, 'S1: shows U+2691 2 for the two unanswered decisions, not followed by a digit');
}

# S2 -- 0 unanswered (only answered, or no store at all): no ?N.
{
    my $P = mk_project();
    my $rec = AD('file', root => $P, title => 'S2 answered only');
    AD_list('answer', $rec->{id}, root => $P, answer => 'done') if ref $rec eq 'HASH';
    my ($out, $rc) = run_statusline_q(sl_payload(current_dir => $P));
    unlike($out, qr/\Q$FLAG_BYTES\E\d/, 'S2: 0 unanswered (only an answered record) shows no U+2691 N');

    my $P2 = mk_project();
    my ($out2, $rc2) = run_statusline_q(sl_payload(current_dir => $P2));
    unlike($out2, qr/\Q$FLAG_BYTES\E\d/, 'S2: no decision dir at all shows no U+2691 N');
}

# S3 -- same resolution as ask: a subdirectory (no CLAUDE_PROJECT_DIR) walks
# up; an outside dir with CLAUDE_PROJECT_DIR set counts that project.
{
    my $P = mk_project();
    AD_list('file', root => $P, title => 'S3 one');
    my $sub = "$P/sub/dir";
    make_path($sub);
    my ($out, $rc) = run_statusline_q(sl_payload(current_dir => $sub));
    like($out, qr/\Q$FLAG_BYTES\E1(?!\d)/, 'S3: a subdirectory current_dir with no CLAUDE_PROJECT_DIR counts the walked-up project');

    my $OUTSIDE = outside_dir();
    SKIP: {
        skip 'S3: no clean outside dir available on this host', 1 unless defined $OUTSIDE;
        my ($out2, $rc2) = run_statusline_q(sl_payload(current_dir => $OUTSIDE), env => { CLAUDE_PROJECT_DIR => $P });
        like($out2, qr/\Q$FLAG_BYTES\E1(?!\d)/, 'S3: an outside current_dir with CLAUDE_PROJECT_DIR set counts that project');
    }
}

# S4 -- a legacy questions.md with no store: no ?N, never read/rewritten.
{
    my $P = mk_project();
    make_path("$P/.ccpraxis-local-data/.subagent-guard");
    my $legacy_content = "- [2020-01-01T00:00:00Z] legacy a?\n- legacy b?\n";
    write_raw("$P/.ccpraxis-local-data/.subagent-guard/questions.md", $legacy_content);
    my ($out, $rc) = run_statusline_q(sl_payload(current_dir => $P));
    unlike($out, qr/\Q$FLAG_BYTES\E\d/, 'S4: a legacy questions.md with no store shows no U+2691 N');
    is(slurp("$P/.ccpraxis-local-data/.subagent-guard/questions.md"), $legacy_content,
       'S4: the legacy file is byte-identical afterwards (read-only)');
    ok(!-d "$P/.ccpraxis-local-data/almanac", 'S4: no almanac/ dir was created');
}

# S5 -- exact parse: an "answered" record whose BODY says "status:
# unanswered" is not counted; stray/malformed entries are ignored.
{
    my $P = mk_project();
    my $dec_dir = "$P/.ccpraxis-local-data/almanac/decision";
    make_path($dec_dir);
    write_raw("$dec_dir/x.md.tmp", "---\nstatus: unanswered\n---\n");
    write_raw("$dec_dir/.store.lock", "1\n");
    write_raw("$dec_dir/notes.txt", "hello\n");
    make_path("$dec_dir/d.md");
    write_raw("$dec_dir/no-delim.md", "status: unanswered\ntitle: x\n---\n");
    write_raw("$dec_dir/tricky.md", "---\ntitle: sneaky\nstatus: answered\n---\nstatus: unanswered\n");
    write_raw("$dec_dir/real.md", "---\ntitle: real one\nstatus: unanswered\ncreated: 2020-01-01T00:00:00Z\n---\n");

    my ($out, $rc) = run_statusline_q(sl_payload(current_dir => $P));
    like($out, qr/\Q$FLAG_BYTES\E1(?!\d)/, 'S5: exactly the one genuine unanswered frontmatter record is counted');
}

# S6 -- 300 records (1 unanswered): completes within a 20s timeout, ?1.
{
    my $P = mk_project();
    my @ids;
    for my $i (1 .. 300) {
        my $rec = AD('file', root => $P, title => "S6 record $i");
        push @ids, $rec->{id} if ref $rec eq 'HASH';
    }
    for my $i (1 .. $#ids) { AD_list('answer', $ids[$i], root => $P, answer => 'ok') }

    my ($out, $rc);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "S6 timeout\n" };
        alarm(20);
        ($out, $rc) = run_statusline_q(sl_payload(current_dir => $P));
        alarm(0);
        1;
    };
    ok($ok, 'S6: statusline completed within a 20s timeout over 300 records') or diag($@);
    SKIP: {
        skip 'S6: did not complete', 2 unless $ok;
        is($rc, 0, 'S6: exit 0');
        like($out, qr/\Q$FLAG_BYTES\E1(?!\d)/, 'S6: shows U+2691 1 for the one unanswered record');
    }
}

# S7 -- exactly one begin/end marker pair, no spawn/require/use/write inside.
{
    my $src = -f $STATUSLINE ? (slurp($STATUSLINE) // '') : '';
    my @begins = ($src =~ /pending-decisions:begin/g);
    my @ends   = ($src =~ /pending-decisions:end/g);
    is(scalar(@begins), 1, 'S7: exactly one pending-decisions:begin marker');
    is(scalar(@ends), 1, 'S7: exactly one pending-decisions:end marker');
    if ($src =~ /\Q# -- pending-decisions:begin --\E(.*?)\Q# -- pending-decisions:end --\E/s) {
        my $block = $1;
        unlike($block, qr/\bcmd_out\s*\(|\bspawn_detached\s*\(|\bsystem\s*\(|\bexec\s*\(|`|\bqx\b|\brequire\b|\buse\s+\w|open\s*\([^)]*\|/,
               'S7: the block contains no spawn/require/use/pipe-open');
        unlike($block, qr/open\s*\([^)]*(?:['"]>{1,2}['"]|['"]\+<['"])/,
               'S7: the block contains no write-mode open');
    } else {
        fail('S7: could not locate the pending-decisions block text between the two markers');
    }
    my @use_lines = ($src =~ /^\s*use\s+([A-Za-z0-9:_]+)/mg);
    my %allowed = map { $_ => 1 } qw(strict warnings JSON::PP Time::Piece File::Basename POSIX Encode constant Carp List::Util Scalar::Util);
    my @bad = grep { !$allowed{$_} } @use_lines;
    is_deeply(\@bad, [], 'S7: no use outside the AC-S3 allow-list');
}

# S8 -- perl -c with no -I still passes (replicates AC-S4).
{
    my $rc = system($^X, '-c', $STATUSLINE);
    is($rc, 0, 'S8: perl -c scripts/statusline.pl exits 0 with no -I (replicates AC-S4)');
}

# ===========================================================================
# Q21 -- hermeticity: the real repo's store is unchanged by this whole file.
# ===========================================================================
{
    is_deeply(real_state_snapshot(), $REAL_BEFORE,
       'Q21: the real repo\'s .ccpraxis-local-data/.subagent-guard/ and almanac/decision/ are unchanged');
}

done_testing();
