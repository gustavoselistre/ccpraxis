#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for coordinator-context-discipline/02-context-ceiling-guidance-and-flush
# -- the FLUSH (hard-ceiling, PreToolUse) half.
#
# Spec: .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/
#       02-context-ceiling-guidance-and-flush-spec.md
# Ledger: .ccpraxis-local-data/blueprints/coordinator-context-discipline/packages/
#       02-context-ceiling-guidance-and-flush.md
#
# WRITTEN BLIND TO THE IMPLEMENTATION. At the time this file is authored,
# plugins/butler/hooks/context-ceiling-flush.sh does NOT EXIST, bp-orchestrator.pl
# has no --ctx-usage CLI seam, and hooks.json registers no new PreToolUse block for
# it. Every assertion below is expected to fail on MISSING BEHAVIOR -- never a
# harness bug of this file's own making.
#
# HOUSE PATTERN -- see context-ceiling-guidance.t's header for the full rationale
# of every scaffolding choice mirrored here (run_hook, %CLEAN_ENV, $BASH_ABS,
# path_without, the real-dispatch-log safety net).
#
# Runs standalone: perl this file
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use POSIX qw(WIFEXITED WEXITSTATUS);

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $FLUSH       = "$HOOKS/context-ceiling-flush.sh";
my $LIB         = "$HOOKS/lib.sh";
my $ORCH        = "$SCRIPTS/bp-orchestrator.pl";
my $HOOKS_JSON  = "$HOOKS/hooks.json";

my $J = JSON::PP->new->canonical;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET -- never touch the real dispatch-log (the allow-list permits a
# bp-dispatch-log.pl outstanding call, so this file could reach it).
# ===========================================================================
(my $REAL_LOGDIR = "$Bin/../../../../.ccpraxis-local-data/.dispatch-log") =~ s{\\}{/}g;
sub real_logdir_snapshot {
    return {} unless -d $REAL_LOGDIR;
    my %seen;
    for my $f (glob("$REAL_LOGDIR/*.json")) { $seen{$f} = (stat $f)[9] // 0; $seen{$f} .= ':' . ((stat $f)[7] // 0) }
    return \%seen;
}
my $REAL_SNAPSHOT_BEFORE = real_logdir_snapshot();

# ===========================================================================
# Scaffolding
# ===========================================================================
my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
    grep { !/^BP_/ && $_ ne 'CLAUDE_PROJECT_DIR' && $_ ne 'CCPRAXIS_DISPATCH_LOG_TEST_NOW' }
    keys %ENV;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $ROOT = tempdir(CLEANUP => 1);
my $caseN = 0;

# See context-ceiling-guidance.t's header for why this is resolved once, via the
# unrestricted PATH, and always invoked absolutely.
my $BASH_ABS = do {
    local $ENV{PATH} = $CLEAN_ENV{PATH};
    chomp(my $p = `command -v bash 2>/dev/null`);
    ($p && -x $p) ? $p : 'bash';
};

sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return $c;
}

# run_hook(HOOKPATH, PAYLOAD_JSON_OR_UNDEF, %env) -> ($exit, $stdout, $stderr)
sub run_hook {
    my ($hookpath, $payload, %env) = @_;
    my $wall = delete $env{__wall} // 20;
    $caseN++;
    my $ti = "$ROOT/run$caseN";
    make_path($ti);
    my ($pf, $out_f, $err_f) = ("$ti/payload.json", "$ti/out", "$ti/err");
    write_file($pf, defined $payload ? $payload : '{}');
    local %ENV = (%CLEAN_ENV, %env,
        HOOKPATH => fwd($hookpath), PFILE => fwd($pf),
        OUTFILE  => fwd($out_f),    ERRFILE => fwd($err_f));
    my $exit = -1;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        # Invoke the hook by passing it as an ARGUMENT to $BASH_ABS (not via its own
        # shebang) -- a shebang-exec depends on PATH resolving the interpreter named on
        # the #! line, which fails under path_without('perl') on this host (that strips
        # /usr/bin, home of both perl AND bash/env). Passing $hookpath as bash's own
        # argument sidesteps the OS exec/PATH step entirely; the hook process itself
        # still sees the caller's %ENV (including the stripped PATH), so its own
        # internal `command -v perl` fallback is exercised exactly as intended.
        open(local *CHSTDIN,  '<', $pf)     or die "open $pf: $!";
        open(local *CHSTDOUT, '>', $out_f)  or die "open $out_f: $!";
        open(local *CHSTDERR, '>', $err_f)  or die "open $err_f: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDIN,  '<&', \*CHSTDIN)  or exit 126;
            open(STDOUT, '>&', \*CHSTDOUT) or exit 126;
            open(STDERR, '>&', \*CHSTDERR) or exit 126;
            exec($BASH_ABS, $hookpath) or exit 127;
        }
        waitpid($pid, 0);
        $exit = ($? == -1) ? -1 : WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1; };
    return ($exit, read_file($out_f) // '', read_file($err_f) // '');
}

sub fresh_env {
    my (%extra) = @_;
    $caseN++;
    my $bp_dir = "$ROOT/bpdir$caseN"; make_path("$bp_dir/runs"); make_path("$bp_dir/packages");
    my $proj   = "$ROOT/proj$caseN";  make_path($proj);
    my $ledger = "$bp_dir/packages/p.md";
    write_file($ledger, "---\npackage: p02\n---\n# p02\n\n## Next action\n\n<what to do next>\n\n## Escalation\n\n<...>\n");
    my %env = (
        BP_LEDGER       => fwd($ledger),
        BP_DIR          => fwd($bp_dir),
        BP_PROJECT_ROOT => fwd($proj),
        BP_BLUEPRINT    => 'coordinator-context-discipline',
        BP_PACKAGE      => 'p02',
        %extra,
    );
    return (\%env, $bp_dir, $proj, $ledger);
}

sub jline { return $J->encode($_[0]) . "\n" }
sub usage_of { my ($n) = @_; return { input_tokens => $n, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } }
sub assistant_rec { my (%o) = @_; return { type => 'assistant', parent_tool_use_id => undef, message => { usage => usage_of($o{tokens}) } } }
sub write_transcript {
    my ($bp_dir, $pkg, $tokens) = @_;
    write_file("$bp_dir/runs/$pkg.jsonl", jline(assistant_rec(tokens => $tokens)));
}

sub pre_task_payload { return $J->encode({ hook_event_name => 'PreToolUse', tool_name => 'Task', tool_input => {} }) }
sub pre_bash_payload { my ($cmd) = @_; return $J->encode({ hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $cmd } }) }

sub flush_state_path { my ($bp_dir, $pkg) = @_; return "$bp_dir/runs/$pkg.ctx-flush" }
sub overrun_log_path { my ($bp_dir, $pkg) = @_; return "$bp_dir/runs/$pkg.ctx-flush-overrun.log" }
sub read_turns {
    my ($bp_dir, $pkg) = @_;
    my $c = read_file(flush_state_path($bp_dir, $pkg));
    return undef unless defined $c;
    my ($t) = $c =~ /^turns:\s*(\d+)/m;
    return $t;
}
sub overrun_lines {
    my ($bp_dir, $pkg) = @_;
    my $c = read_file(overrun_log_path($bp_dir, $pkg));
    return wantarray ? () : 0 unless defined $c;
    my @lines = grep { /\S/ } split /\n/, $c;
    return wantarray ? @lines : scalar(@lines);
}

sub path_without {
    my ($name) = @_;
    my @keep;
    for my $dir (split /:/, ($CLEAN_ENV{PATH} // '')) {
        next unless length $dir;
        next if -x "$dir/$name" || -x "$dir/$name.exe";
        push @keep, $dir;
    }
    return join ':', @keep;
}
sub path_without_any {
    my (@names) = @_;
    my @keep;
    for my $dir (split /:/, ($CLEAN_ENV{PATH} // '')) {
        next unless length $dir;
        next if grep { -x "$dir/$_" || -x "$dir/$_.exe" } @names;
        push @keep, $dir;
    }
    return join ':', @keep;
}

# The exact §2.9 denial lines.
sub deny_line1 { my ($n, $hard) = @_;
    return "BLOCKED: a context-ceiling flush is in force. Your last recorded own-turn context measured "
         . "about $n tokens, at or above the hard ceiling of $hard."; }
sub deny_line2 {
    return 'Permitted while the flush is in force: Read, Edit and Grep (this hook does not gate them at all), '
         . 'plus a Bash command consisting only of bp-ledger.pl set-status|set-next-action|tick-step|'
         . 'append-attempt|add-output|validate invocations, or a bp-dispatch-log.pl outstanding check.';
}
sub deny_line3 { my ($b, $p) = @_;
    return "Remedy: run bp-dispatch-log.pl outstanding --blueprint $b --package $p and record what it reports, "
         . 'write a concrete "## Next action" with bp-ledger.pl set-next-action, leave status: non-terminal, '
         . 'then stop.'; }
sub deny_line4_task { my ($k, $cap) = @_; return "This is flush turn $k of $cap. Tool: Task"; }
sub deny_line4_cmd  { my ($k, $cap, $cmd) = @_; return "This is flush turn $k of $cap. Command: $cmd"; }
sub deny_line4_overrun { my ($k, $cap) = @_;
    return "This is flush turn $k, past the permitted $cap. The overrun has been recorded to "
         . 'runs/<pkg>.ctx-flush-overrun.log. If you cannot complete the flush, set status: blocked with a '
         . 'filled "## Escalation" naming what is preventing it, then stop.'; }

# ===========================================================================
# AC27 (partial -- also in context-ceiling-guidance.t) -- static syntax checks.
# ===========================================================================
subtest 'AC27: bash -n on context-ceiling-flush.sh; perl -c on bp-orchestrator.pl' => sub {
    SKIP: {
        skip 'context-ceiling-flush.sh does not exist yet', 1 unless -f $FLUSH;
        my $out = `bash -n "$FLUSH" 2>&1`;
        is($? >> 8, 0, 'bash -n context-ceiling-flush.sh succeeds') or diag($out);
    }
    my $out = `perl -c "$ORCH" 2>&1`;
    is($? >> 8, 0, 'perl -c bp-orchestrator.pl succeeds') or diag($out);
};

# ===========================================================================
# AC19 (B18, B24) -- below hard (including above soft), Task and Bash both
# allow; an existing ctx-flush state is deleted.
# ===========================================================================
subtest 'AC19: below hard, everything allowed; an existing ctx-flush state is deleted (B18, B24)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 300_000); # above soft(250000), below hard(350000)
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 3\n");
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 0, 'Task below hard: exit 0');
        is($out . $err, '', 'Task below hard: no output');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'the pre-existing ctx-flush state is deleted');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 300_000);
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 3\n");
        my ($exit, $out, $err) = run_hook($FLUSH, pre_bash_payload('rm -rf /tmp/x'), %$env);
        is($exit, 0, 'arbitrary Bash below hard: exit 0');
        is($out . $err, '', 'arbitrary Bash below hard: no output');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'the pre-existing ctx-flush state is deleted for the Bash case too');
    }
};

# ===========================================================================
# AC20 (B19) -- at hard, Task is denied.
# ===========================================================================
subtest 'AC20: at hard, Task is denied with all four §2.9 lines and Tool: Task; turns:1 (B19)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 400_000);
    my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
    is($exit, 2, 'exit 2');
    is($out, '', 'stdout empty (PreToolUse stdout is a protocol channel)');
    my $expected = join("\n", deny_line1(400000, 350000), deny_line2(),
        deny_line3($env->{BP_BLUEPRINT}, $env->{BP_PACKAGE}), deny_line4_task(1, 5));
    like($err, qr/\Q$expected\E/, 'stderr carries the four §2.9 lines byte for byte, Tool: Task') or diag("err: [$err]");
    is(read_turns($bp_dir, 'p02'), 1, "runs/<pkg>.ctx-flush now reads turns: 1");
};

# ===========================================================================
# AC21 (B20) -- at hard, each non-flush Bash command is denied, including
# command-substitution and &&-smuggling cases.
# ===========================================================================
subtest 'AC21: at hard, every B20 non-flush command is denied with Command: <CMD> (B20)' => sub {
    my @cmds = (
        'wc -l runs/p.jsonl',
        'git status',
        'perl bp-ledger.pl rotate --ledger x',
        'bp-dispatch-log.pl list',
        'echo $(bp-ledger.pl validate --ledger x)',
        'bp-ledger.pl validate --ledger x && npm test',
    );
    for my $cmd (@cmds) {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($FLUSH, pre_bash_payload($cmd), %$env);
        is($exit, 2, "'$cmd': exit 2");
        like($err, qr/\QCommand: $cmd\E/, "'$cmd': stderr's final line quotes the command") or diag("err: [$err]");
    }
};

# ===========================================================================
# AC22 (B21) -- at hard, each flush-procedure Bash command is allowed AND
# still increments turns.
# ===========================================================================
subtest 'AC22: at hard, every B21 flush command is allowed silently and still increments turns (B21, DC4)' => sub {
    my @cmds = (
        'perl /p/scripts/bp-ledger.pl set-next-action --ledger L --body "x"',
        'bp-ledger.pl set-status --ledger L --status blocked',
        'bp-ledger.pl tick-step --ledger L --step 2',
        'bp-ledger.pl append-attempt --ledger L --text t',
        'bp-ledger.pl add-output --ledger L --text t',
        'bp-ledger.pl validate --ledger L',
        'perl /p/scripts/bp-dispatch-log.pl outstanding --blueprint b --package p',
        'bp-ledger.pl set-next-action --ledger L --body "x" && bp-ledger.pl set-status --ledger L --status parked',
    );
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 400_000);
    my $expect_turn = 0;
    for my $cmd (@cmds) {
        $expect_turn++;
        my ($exit, $out, $err) = run_hook($FLUSH, pre_bash_payload($cmd), %$env);
        is($exit, 0, "'$cmd': exit 0") or diag("err: [$err]");
        is($out . $err, '', "'$cmd': no output");
        is(read_turns($bp_dir, 'p02'), $expect_turn, "'$cmd': turns incremented to $expect_turn");
    }
};

# ===========================================================================
# AC23 (B22) -- the cap is 5; the 6th fire is the overrun; fires 7-8 keep the
# overrun wording and the log stays at one line.
# ===========================================================================
subtest 'AC23: 6-fire overrun sequence -- fires 1-5 say "of 5", fire 6+ carry the overrun line once (B22)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 400_000);
    for my $k (1 .. 5) {
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 2, "fire $k: exit 2");
        like($err, qr/\QThis is flush turn $k of 5.\E/, "fire $k: 'of 5' wording");
        is(scalar(overrun_lines($bp_dir, 'p02')), 0, "fire $k: overrun log still has zero lines");
    }
    {
        my ($exit, $err) = (run_hook($FLUSH, pre_task_payload(), %$env))[0, 2];
        is($exit, 2, 'fire 6: exit 2');
        like($err, qr/\QThis is flush turn 6, past the permitted 5.\E/, 'fire 6: overrun wording');
        my @lines = overrun_lines($bp_dir, 'p02');
        is(scalar(@lines), 1, 'fire 6: overrun log gains exactly one line');
        like($lines[0] // '', qr/package=p02 turns=6 cap=5 context_tokens=400000 next_action_written=(true|false|unknown)/,
            'fire 6: the overrun log line matches the specified shape') if @lines;
    }
    for my $k (7, 8) {
        my ($exit, $err) = (run_hook($FLUSH, pre_task_payload(), %$env))[0, 2];
        is($exit, 2, "fire $k: exit 2");
        like($err, qr/past the permitted 5/, "fire $k: still carries overrun wording");
        is(scalar(overrun_lines($bp_dir, 'p02')), 1, "fire $k: overrun log stays at exactly one line");
    }
};

# ===========================================================================
# AC24 (B23) -- next_action_written reflects the ledger: true/false/unknown.
# Uses the state-preseed shortcut (turns:5 planted directly) so each case is
# exactly ONE hook fire (the one that pushes turns to 6, the overrun fire).
# ===========================================================================
subtest 'AC24: next_action_written is true/false/unknown per the ledger (B23)' => sub {
    {
        my ($env, $bp_dir, $proj, $ledger) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        write_file($ledger, "---\npackage: p02\n---\n# p02\n\n## Next action\n\nDispatch the implementer for step 4.\n\n## Escalation\n\n<...>\n");
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 5\n");
        run_hook($FLUSH, pre_task_payload(), %$env);
        my @lines = overrun_lines($bp_dir, 'p02');
        like($lines[0] // '', qr/next_action_written=true/, 'a filled ## Next action body -> true') if @lines;
        ok(scalar(@lines), 'fixture sanity: an overrun line was written') or diag('no overrun line');
    }
    {
        my ($env, $bp_dir, $proj, $ledger) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        write_file($ledger, "---\npackage: p02\n---\n# p02\n\n## Next action\n\n<...>\n\n## Escalation\n\n<...>\n");
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 5\n");
        run_hook($FLUSH, pre_task_payload(), %$env);
        my @lines = overrun_lines($bp_dir, 'p02');
        like($lines[0] // '', qr/next_action_written=false/, 'a template-placeholder ## Next action body -> false') if @lines;
    }
    {
        my ($env, $bp_dir, $proj, $ledger) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        write_file($ledger, "---\npackage: p02\n---\n# p02\n\n## Next action\n\n\n\n## Escalation\n\n<...>\n");
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 5\n");
        run_hook($FLUSH, pre_task_payload(), %$env);
        my @lines = overrun_lines($bp_dir, 'p02');
        like($lines[0] // '', qr/next_action_written=false/, 'an empty ## Next action body -> false') if @lines;
    }
    {
        my ($env, $bp_dir, $proj, $ledger) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        unlink $ledger;
        write_file(flush_state_path($bp_dir, 'p02'), "started_at: 1\nturns: 5\n");
        run_hook($FLUSH, pre_task_payload(), %$env);
        my @lines = overrun_lines($bp_dir, 'p02');
        like($lines[0] // '', qr/next_action_written=unknown/, 'a nonexistent $BP_LEDGER -> unknown') if @lines;
    }
};

# ===========================================================================
# AC25 (B25) -- fail-open when the hook cannot measure.
# ===========================================================================
subtest 'AC25: fails open on no-perl / unreadable transcript / tier:unknown / no-JSON-parser (B25)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env(PATH => path_without('perl'));
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 0, 'no perl on PATH: exit 0 (fail open)');
        is($out . $err, '', 'no perl on PATH: no output at all');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'no perl on PATH: no state file written');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        # transcript deliberately absent -> the probe reports tier:unknown -> fail-open.
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 0, 'missing/unreadable transcript (tier: unknown): exit 0');
        is($out . $err, '', 'missing transcript: no output');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'missing transcript: no state file written');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(PATH => path_without_any('perl', 'jq'));
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($FLUSH, pre_bash_payload('git status'), %$env);
        is($exit, 0, 'no JSON parser at all, non-Task payload: exit 0 (fail open)');
        is($out . $err, '', 'no JSON parser, non-Task payload: no output at all');
    }
    {
        # A malformed (invalid) JSON payload that nonetheless CONTAINS the literal
        # substring "tool_name":"Task" is matched only by the parser-free fallback --
        # and per spec MUST still be denied at hard (both jq and perl remain
        # available here; only the payload itself is malformed).
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        my $malformed = '{"hook_event_name":"PreToolUse","tool_name":"Task","tool_input": {unterminated';
        my ($exit, $out, $err) = run_hook($FLUSH, $malformed, %$env);
        is($exit, 2, 'malformed-but-literal-Task payload at hard: STILL denied (exit 2)');
        like($err, qr/Tool: Task/, 'the denial names Tool: Task, proving the literal fallback matched') or diag("err: [$err]");
    }
};

# ===========================================================================
# AC26 (B26) -- stands aside outside a coordinator context.
# ===========================================================================
subtest 'AC26: BP_LEDGER unset / BP_ROLE=judge at 400000 tokens -> silent, exit 0 (B26)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        delete $env->{BP_LEDGER};
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 0, 'BP_LEDGER unset: exit 0');
        is($out . $err, '', 'BP_LEDGER unset: no output');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'BP_LEDGER unset: no state file written');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(BP_ROLE => 'judge');
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($FLUSH, pre_task_payload(), %$env);
        is($exit, 0, 'BP_ROLE=judge: exit 0');
        is($out . $err, '', 'BP_ROLE=judge: no output');
        ok(!-f flush_state_path($bp_dir, 'p02'), 'BP_ROLE=judge: no state file written');
    }
};

# ===========================================================================
# hooks.json registration -- the flush hook is registered on PreToolUse with
# matcher "Task|Bash"; the existing PreToolUse:Bash block's command list is
# unchanged (spec §2.10).
# ===========================================================================
subtest 'hooks.json registers context-ceiling-flush.sh on PreToolUse:Task|Bash; existing Bash block unchanged' => sub {
    my $raw = read_file($HOOKS_JSON);
    ok(defined $raw, 'hooks.json is readable');
    my $j = eval { JSON::PP->new->decode($raw) };
    ok(ref $j eq 'HASH', 'hooks.json parses as JSON') or diag($@);
    SKIP: {
        skip 'hooks.json did not parse', 3 unless ref $j eq 'HASH';
        my @pre = @{ $j->{hooks}{PreToolUse} || [] };
        my @matching = grep {
            my $b = $_;
            ($b->{matcher} // '') eq 'Task|Bash'
            && grep { ($_->{command} // '') =~ /context-ceiling-flush\.sh/ } @{ $b->{hooks} || [] }
        } @pre;
        ok(scalar(@matching) >= 1, 'context-ceiling-flush.sh appears in a PreToolUse block with matcher "Task|Bash"');

        my ($bash_block) = grep { ($_->{matcher} // '') eq 'Bash' } @pre;
        ok(defined $bash_block, 'the existing PreToolUse:Bash block still exists');
        SKIP: {
            skip 'no PreToolUse:Bash block found', 1 unless defined $bash_block;
            my @cmds = map { $_->{command} // '' } @{ $bash_block->{hooks} || [] };
            ok((grep { /guard-bash\.sh/ } @cmds) && (grep { /guard-git-mutations\.sh/ } @cmds),
                'the pre-existing PreToolUse:Bash block still contains its known guards (guard-bash.sh, guard-git-mutations.sh) -- unmodified')
                or diag(explain(\@cmds));
            unlike("@cmds", qr/context-ceiling-flush\.sh/,
                'context-ceiling-flush.sh is NOT appended into the existing PreToolUse:Bash block -- it gets its own new block');
        }
    }
};

# ===========================================================================
# FINAL SAFETY CHECK. Must be the last thing this file does before done_testing().
# ===========================================================================
subtest 'the real .ccpraxis-local-data/.dispatch-log is untouched' => sub {
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole suite');
};

done_testing();
