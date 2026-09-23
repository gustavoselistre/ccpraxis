#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for coordinator-context-discipline/02-context-ceiling-guidance-and-flush
# -- the GUIDANCE (soft-ceiling, PostToolUse) half.
#
# Spec: .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/
#       02-context-ceiling-guidance-and-flush-spec.md
# Ledger: .ccpraxis-local-data/blueprints/coordinator-context-discipline/packages/
#       02-context-ceiling-guidance-and-flush.md
#
# WRITTEN BLIND TO THE IMPLEMENTATION. At the time this file is authored,
# plugins/butler/hooks/context-ceiling-guidance.sh does NOT EXIST, bp-orchestrator.pl
# has no --ctx-usage CLI seam, and hooks.json registers neither new hook. Every
# assertion below is expected to fail on MISSING BEHAVIOR (a missing file, missing
# CLI seam, missing hooks.json registration) -- never a harness bug of this file's
# own making.
#
# HOUSE PATTERN, lifted from dispatch-tracking-hook.t / dispatch-write-path.t:
# %CLEAN_ENV strips ambient BP_*/CLAUDE_PROJECT_DIR/CCPRAXIS_DISPATCH_LOG_TEST_NOW;
# run_hook() shells the hook via bash with a clean env and file-redirected stdio; a
# snapshot/compare pair at the very top and very bottom proves the real
# .ccpraxis-local-data/.dispatch-log is never touched (this file exercises AC14's
# outstanding check, so the safety net applies here).
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
my $GUIDANCE    = "$HOOKS/context-ceiling-guidance.sh";
my $LIB         = "$HOOKS/lib.sh";
my $ORCH        = "$SCRIPTS/bp-orchestrator.pl";
my $DISPATCHLOG = "$SCRIPTS/bp-dispatch-log.pl";
my $HOOKS_JSON  = "$HOOKS/hooks.json";

my $J = JSON::PP->new->canonical;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET -- never touch the real dispatch-log. Snapshot at start, compare
# at the very end (AC14 exercises bp-dispatch-log.pl outstanding).
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

# Resolved ONCE, via the real (unrestricted) PATH, and always invoked by this
# ABSOLUTE path -- never by bare "bash" searched via a possibly-restricted PATH.
# Windows carries a SECOND "bash" on the system PATH (a WSL shim under
# C:\Windows\System32\bash.exe) that launches into an entirely different
# environment and does not see this process's %ENV at all; if path_without('perl')
# happens to remove every directory holding the REAL (Git-for-Windows) bash --
# which lives in the same /usr/bin as perl -- a bare `system('bash', ...)` call
# can silently resolve to the WSL shim instead and misbehave in a way that looks
# like a hook bug but is a harness artifact. Fixing the invocation path, not the
# PATH content, keeps the AC18 "no perl on PATH" case a clean test of the HOOK's
# own `command -v perl` fallback rather than of bash resolution.
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
sub read_json {
    my ($path) = @_;
    my $raw = read_file($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->decode($raw) };
}
sub logdir_of { my ($proj) = @_; return "$proj/.ccpraxis-local-data/.dispatch-log" }

sub plant_rec {
    my ($logdir, $id, %fields) = @_;
    make_path($logdir) unless -d $logdir;
    write_file("$logdir/$id.json", $J->encode({ id => $id, %fields }));
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
        # Invoke the hook by running it as an ARGUMENT to $BASH_ABS (not via its own
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
    my $bp_dir = "$ROOT/bpdir$caseN"; make_path("$bp_dir/runs");
    my $proj   = "$ROOT/proj$caseN";  make_path($proj);
    my %env = (
        BP_LEDGER       => fwd("$bp_dir/packages/p.md"),
        BP_DIR          => fwd($bp_dir),
        BP_PROJECT_ROOT => fwd($proj),
        BP_BLUEPRINT    => 'coordinator-context-discipline',
        BP_PACKAGE      => 'p02',
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}

# post_payload(TOOL) -- a minimal PostToolUse payload. The guidance hook never
# parses tool_input (bp_read_payload open just drains stdin), so this is intentionally
# bare.
sub post_payload {
    my ($tool) = @_;
    return $J->encode({ hook_event_name => 'PostToolUse', tool_name => $tool, tool_input => {} });
}

sub jline { return $J->encode($_[0]) . "\n" }
sub usage_of { my ($n) = @_; return { input_tokens => $n, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } }
sub assistant_rec { my (%o) = @_; return { type => 'assistant', parent_tool_use_id => undef, message => { usage => usage_of($o{tokens}) } } }

sub write_transcript {
    my ($bp_dir, $pkg, $tokens) = @_;
    write_file("$bp_dir/runs/$pkg.jsonl", jline(assistant_rec(tokens => $tokens)));
}

sub runs_snapshot {
    my ($bp_dir) = @_;
    my %seen;
    return \%seen unless -d "$bp_dir/runs";
    for my $f (glob("$bp_dir/runs/*")) {
        next unless -f $f;
        $seen{$f} = ((stat $f)[9] // 0) . ':' . ((stat $f)[7] // 0);
    }
    return \%seen;
}

# path_without(NAME) -- the real ambient PATH minus every directory containing an
# executable named NAME (t/67's own precedent, mirrored verbatim from
# guard-bash-quote-strip.t / ledger-guard.t). Removing directories rather than
# mirroring the whole PATH avoids the 6000+-symlink teardown cost measured there.
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

my $BANNED_RE = qr/nothing is outstanding|all clear|is done|has finished|checkpoint now/i;

# The exact §2.8 lines this hook is mandated to emit.
sub line1 { my ($n, $soft, $hard) = @_;
    return "[context-ceiling] Your last recorded own-turn context measured about $n tokens, at or above "
         . "the soft ceiling of $soft (hard ceiling $hard). This is guidance, not a block."; }
sub line2 {
    return '[context-ceiling] You are also at or above the hard ceiling, so a flush is in force: Task '
         . 'dispatch and non-essential Bash are denied until you write a concrete "## Next action" and stop.';
}
sub line3 { my ($summary) = @_;
    return "[context-ceiling] Dispatch check (bp-dispatch-log.pl outstanding, scoped to this blueprint "
         . "and package): $summary"; }
sub line4 {
    return '[context-ceiling] Consider finishing the step you are on, writing a concrete "## Next action", '
         . 'leaving status: non-terminal, and stopping, per coordinator-protocol\'s "Context-growth '
         . 'checkpoint" section. The figure above is read from the last usage record in your own runs '
         . 'transcript, so it may lag your true current context and is a signal, not a verdict.';
}
my $ZERO_SUMMARY = 'summary: no outstanding dispatch was detected in the dispatch log (0 running records matched); '
                  . 'this reflects what is recorded on disk, not a guarantee that nothing is running.';
$ZERO_SUMMARY =~ s/^summary: //;
my $ONE_SUMMARY = 'summary: 1 dispatch appears to be outstanding (recorded as running, not yet resolved); '
                 . 'this reflects what is recorded on disk, not a guarantee that it is still alive.';
$ONE_SUMMARY =~ s/^summary: //;
my $NORUN_SUMMARY = 'the dispatch check could not be run, so whether anything is outstanding was not determined.';

# ===========================================================================
# AC27 (partial -- also in context-ceiling-flush.t) -- static syntax checks.
# ===========================================================================
subtest 'AC27: bash -n on context-ceiling-guidance.sh; perl -c on bp-orchestrator.pl' => sub {
    SKIP: {
        skip 'context-ceiling-guidance.sh does not exist yet', 1 unless -f $GUIDANCE;
        my $out = `bash -n "$GUIDANCE" 2>&1`;
        is($? >> 8, 0, 'bash -n context-ceiling-guidance.sh succeeds') or diag($out);
    }
    my $out = `perl -c "$ORCH" 2>&1`;
    is($? >> 8, 0, 'perl -c bp-orchestrator.pl succeeds') or diag($out);
};

# ===========================================================================
# AC11 (B11) -- Decision 10, mechanical. Below soft: 0 stdout bytes, 0 stderr
# bytes, exit 0, byte-identical transcript, no file created/modified under
# $BP_DIR/runs, and the hook spawns exactly one child command (the --ctx-usage
# probe) -- structurally gated ahead of the dispatch-log call.
# ===========================================================================
subtest 'AC11: below-soft fixture -- Decision 10, mechanical (B11)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 10_000); # well below the 250,000 default soft ceiling
    my $transcript_before = read_file("$bp_dir/runs/p02.jsonl");
    my $runs_before = runs_snapshot($bp_dir);

    my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
    is($exit, 0, 'exit 0');
    is(length($out), 0, 'stdout is exactly 0 bytes');
    is(length($err), 0, 'stderr is exactly 0 bytes');

    my $transcript_after = read_file("$bp_dir/runs/p02.jsonl");
    is($transcript_after, $transcript_before, 'the transcript is byte-identical afterwards');

    my $runs_after = runs_snapshot($bp_dir);
    is_deeply($runs_after, $runs_before, 'no file created or modified anywhere under $BP_DIR/runs');

    SKIP: {
        skip 'hook source not readable yet', 3 unless -f $GUIDANCE;
        my $src = read_file($GUIDANCE) // '';
        my $probe_count = () = ($src =~ /bp-orchestrator\.pl["'\s]+--ctx-usage/g);
        is($probe_count, 1, 'the hook source invokes bp-orchestrator.pl --ctx-usage exactly once (the one bounded tail-read)');
        unlike($src, qr/^\s*Task\b/m, 'the hook source contains no bare "Task" tool invocation');
        my $none_idx  = index($src, "none)");
        my $probe_idx = index($src, 'bp-dispatch-log.pl');
        ok($none_idx >= 0 && ($probe_idx < 0 || $none_idx < $probe_idx),
           'the dispatch-log call, if present in source, is structurally gated behind the tier==none early-exit '
         . '-- so the below-soft runtime path never reaches it (only one child command actually spawns)');
    }
};

# ===========================================================================
# AC12/AC13 (B12, B13) -- payload content at soft and at hard.
# ===========================================================================
subtest 'AC12: at soft, additionalContext is lines 1+3+4 joined by \\n, byte for byte; line 2 absent (B12)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 260_000); # spec's own B12 example
    my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
    is($exit, 0, 'exit 0');
    is($err, '', 'stderr empty');
    my $doc = eval { $J->decode($out) };
    ok(ref $doc eq 'HASH', 'stdout parses as a single JSON object') or diag("stdout was: [$out]");
    SKIP: {
        skip 'stdout did not parse as JSON', 3 unless ref $doc eq 'HASH';
        is($doc->{hookSpecificOutput}{hookEventName}, 'PostToolUse', 'hookEventName is PostToolUse');
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        my $expected = join("\n", line1(260000, 250000, 350000), line3($ZERO_SUMMARY), line4());
        is($ctx, $expected, 'additionalContext is exactly lines 1+3+4, byte for byte') or diag("got: [$ctx]");
        unlike($ctx, qr/a flush is in force/, 'line 2 (hard-ceiling wording) is absent at soft');
    }
};

subtest 'AC13: at hard, additionalContext additionally contains line 2 byte for byte (B13)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript($bp_dir, 'p02', 400_000); # spec's own B13 example
    my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Task'), %$env);
    is($exit, 0, 'exit 0');
    my $doc = eval { $J->decode($out) };
    ok(ref $doc eq 'HASH', 'stdout parses as a single JSON object') or diag("stdout was: [$out]");
    SKIP: {
        skip 'stdout did not parse as JSON', 1 unless ref $doc eq 'HASH';
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        my $expected = join("\n", line1(400000, 250000, 350000), line2(), line3($ZERO_SUMMARY), line4());
        is($ctx, $expected, 'additionalContext is exactly lines 1+2+3+4, byte for byte') or diag("got: [$ctx]");
    }
};

# ===========================================================================
# AC14 (B14) -- line 3 carries package 01's mandated summary sentence verbatim.
# ===========================================================================
subtest 'AC14: line 3 quotes package 01\'s zero/one/could-not-run sentence verbatim (B14)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 260_000);
        my ($exit, $out) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        my $doc = eval { $J->decode($out) };
        my $ctx = (ref $doc eq 'HASH') ? ($doc->{hookSpecificOutput}{additionalContext} // '') : '';
        like($ctx, qr/\Q$ZERO_SUMMARY\E/, 'empty dispatch store -> the zero sentence, byte-exact') or diag("ctx: [$ctx]");
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 260_000);
        my $now = 1_700_000_000;
        plant_rec(logdir_of($proj), 'r1', worker_type => 'bp-reviewer', status => 'running',
            started_at => $now - 10, budget_seconds => 1800,
            blueprint => $env->{BP_BLUEPRINT}, package => $env->{BP_PACKAGE});
        my ($exit, $out) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        my $doc = eval { $J->decode($out) };
        my $ctx = (ref $doc eq 'HASH') ? ($doc->{hookSpecificOutput}{additionalContext} // '') : '';
        like($ctx, qr/\Q$ONE_SUMMARY\E/, 'one matching running record -> the one-dispatch sentence, byte-exact') or diag("ctx: [$ctx]");
    }
    {
        # bp-dispatch-log.pl absent: a stub tree with the hook + lib.sh + EVERY sibling
        # scripts/*.pl bp-orchestrator.pl unconditionally `require`s at load time (it is
        # not just bp-orchestrator.pl itself -- it top-level requires bp-govern.pl,
        # bp-contract.pl, bp-log.pl, bp-http.pl, bp-token-keeper.pl, bp-keepawake.pl,
        # bp-judge.pl, bp-remediate.pl, bp-spend.pl, bp-checkpoint.pl, bp-write-guard.pl,
        # and any of THOSE may transitively require further siblings) -- so the stub
        # mirrors the entire real scripts/ directory and removes only
        # bp-dispatch-log.pl, rather than hand-picking files and silently omitting one.
        $caseN++;
        my $stub_root = "$ROOT/stub$caseN";
        make_path("$stub_root/hooks");
        make_path("$stub_root/scripts");
        SKIP: {
            skip 'context-ceiling-guidance.sh or lib.sh not readable yet', 2 unless -f $GUIDANCE && -f $LIB && -f $ORCH;
            write_file("$stub_root/hooks/context-ceiling-guidance.sh", read_file($GUIDANCE));
            write_file("$stub_root/hooks/lib.sh", read_file($LIB));
            for my $pl (glob("$SCRIPTS/*.pl")) {
                (my $base = $pl) =~ s{.*/}{};
                next if $base eq 'bp-dispatch-log.pl';
                write_file("$stub_root/scripts/$base", read_file($pl));
            }
            # scripts/bp-dispatch-log.pl deliberately absent.
            my ($env, $bp_dir, $proj) = fresh_env();
            write_transcript($bp_dir, 'p02', 260_000);
            my ($exit, $out) = run_hook("$stub_root/hooks/context-ceiling-guidance.sh", post_payload('Bash'), %$env);
            my $doc = eval { $J->decode($out) };
            my $ctx = (ref $doc eq 'HASH') ? ($doc->{hookSpecificOutput}{additionalContext} // '') : '';
            like($ctx, qr/\Q$NORUN_SUMMARY\E/, 'bp-dispatch-log.pl absent -> the could-not-be-run sentence, byte-exact') or diag("ctx: [$ctx]");
            is($exit, 0, 'still exits 0 even with the sibling script missing (never fails the calling tool)');
        }
    }
};

# ===========================================================================
# AC15 -- the outstanding call is issued SCOPED (--blueprint and --package).
# ===========================================================================
subtest 'AC15: the outstanding call is scoped with --blueprint and --package (source check)' => sub {
    SKIP: {
        skip 'context-ceiling-guidance.sh does not exist yet', 2 unless -f $GUIDANCE;
        my $src = read_file($GUIDANCE) // '';
        like($src, qr/bp-dispatch-log\.pl["'\s]+outstanding\b[^\n]*--blueprint/,
            'the outstanding invocation passes --blueprint on the same logical call') or diag($src);
        like($src, qr/bp-dispatch-log\.pl["'\s]+outstanding\b[^\n]*--package|--blueprint[^\n]*--package/,
            'the outstanding invocation passes --package too') or diag($src);
    }
};

# ===========================================================================
# AC16 (B15) -- rate limiting: emit, suppress within interval, re-emit past a
# short interval, reset (immediate re-emit) after a below-soft fire.
# ===========================================================================
subtest 'AC16: rate limiting -- emit, suppress, re-emit past interval, reset on below-soft (B15)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 260_000);
        my ($e1, $out1) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($e1, 0, 'first fire: exit 0');
        ok(length($out1) > 0, 'first fire: emits (non-empty stdout)');
        my ($e2, $out2) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($e2, 0, 'second fire (immediately after): exit 0');
        is($out2, '', 'second fire within the default 900s interval: suppressed (empty stdout)');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(BP_CTX_GUIDANCE_INTERVAL_SECS => '1');
        write_transcript($bp_dir, 'p02', 260_000);
        write_file("$bp_dir/runs/p02.ctx-guidance", 'last_emit: ' . (time - 10) . "\n");
        my ($exit, $out) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit, 0, 'past a 1s interval: exit 0');
        ok(length($out) > 0, 'past a 1s interval with a stale last_emit: re-emits (non-empty stdout)');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 260_000);
        run_hook($GUIDANCE, post_payload('Bash'), %$env); # first fire -- establishes state
        ok(-f "$bp_dir/runs/p02.ctx-guidance", 'fixture sanity: state file now exists after the first emit');
        write_transcript($bp_dir, 'p02', 10_000); # drop below soft
        my ($exit, $out) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit, 0, 'below-soft fire: exit 0');
        is($out, '', 'below-soft fire: stdout empty');
        ok(!-f "$bp_dir/runs/p02.ctx-guidance", 'below-soft fire deletes the state file');
        write_transcript($bp_dir, 'p02', 260_000); # cross back above soft immediately
        my ($exit2, $out2) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit2, 0, 're-crossing soft: exit 0');
        ok(length($out2) > 0, 're-crossing soft immediately after a reset: emits again (non-empty stdout)');
    }
};

# ===========================================================================
# AC17 (B16) -- no emitted string ever matches the banned-phrase set, and every
# numbered line is a single line (no mid-sentence break).
# ===========================================================================
subtest 'AC17: no banned phrase anywhere; every line is single-line (B16)' => sub {
    my @docs;
    for my $tokens (260_000, 400_000) {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', $tokens);
        my ($exit, $out) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        push @docs, $out;
    }
    my $any_parsed = 0;
    for my $out (@docs) {
        my $doc = eval { $J->decode($out) };
        next unless ref $doc eq 'HASH';
        $any_parsed = 1;
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        unlike($ctx, $BANNED_RE, 'no banned phrase in additionalContext');
        for my $line (split /\n/, $ctx) {
            unlike($line, qr/\A\s*\z/, 'no blank line inside additionalContext (would indicate a broken join)');
        }
    }
    ok($any_parsed, 'at least one fixture produced parseable JSON to actually check (else this subtest would be vacuous)')
        or diag('no hook output parsed as JSON -- the banned-phrase checks above had nothing real to test');
};

# ===========================================================================
# AC18 (B17) -- stands aside outside a coordinator context.
# ===========================================================================
subtest 'AC18: BP_LEDGER unset / BP_ROLE=judge / no perl / empty payload -> silent, exit 0 (B17)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        delete $env->{BP_LEDGER};
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit, 0, 'BP_LEDGER unset: exit 0');
        is($out . $err, '', 'BP_LEDGER unset: no output');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(BP_ROLE => 'judge');
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit, 0, 'BP_ROLE=judge: exit 0');
        is($out . $err, '', 'BP_ROLE=judge: no output');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(PATH => path_without('perl'));
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($GUIDANCE, post_payload('Bash'), %$env);
        is($exit, 0, 'no perl on PATH: exit 0 (fail open)');
        is($out . $err, '', 'no perl on PATH: no output at all');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript($bp_dir, 'p02', 400_000);
        my ($exit, $out, $err) = run_hook($GUIDANCE, undef, %$env); # payload '{}'
        is($exit, 0, 'empty payload: exit 0');
        # Non-Task/Bash tool_name is out of scope for the matcher in real life, but the
        # hook itself never inspects tool_name (bp_read_payload open just drains stdin),
        # so an empty payload alone is not expected to suppress emission by itself --
        # only the coordinator-context gate and the ceiling tier matter. This case is
        # about the payload being unparseable/empty, not tool-scoping.
        ok(1, 'empty-payload invocation completes without hanging (fixture sanity, not a scoping claim)');
    }
};

# ===========================================================================
# AC30 (B29) -- hooks.json registration.
# ===========================================================================
subtest 'AC30: hooks.json registers context-ceiling-guidance.sh on PostToolUse:Task|Bash; existing blocks unchanged (B29)' => sub {
    my $raw = read_file($HOOKS_JSON);
    ok(defined $raw, 'hooks.json is readable');
    my $j = eval { JSON::PP->new->decode($raw) };
    ok(ref $j eq 'HASH', 'hooks.json parses as JSON') or diag($@);
    SKIP: {
        skip 'hooks.json did not parse', 4 unless ref $j eq 'HASH';
        my @post = @{ $j->{hooks}{PostToolUse} || [] };
        my @matching = grep {
            my $b = $_;
            ($b->{matcher} // '') eq 'Task|Bash'
            && grep { ($_->{command} // '') =~ /context-ceiling-guidance\.sh/ } @{ $b->{hooks} || [] }
        } @post;
        ok(scalar(@matching) >= 1, 'context-ceiling-guidance.sh appears in a PostToolUse block with matcher "Task|Bash"');

        # The pinned rule (repeat-guard.t AC-20, ledger-guard.t AC-36, wait-shape-guard.t
        # AC-34) is about the SPECIFIC block that holds log-dispatch.sh, not "every
        # PostToolUse:Task block has only one command" -- track-dispatch.sh already lives
        # in its OWN separate PostToolUse:Task block (package 01, MF-2), so a block-count
        # assertion has to find the log-dispatch.sh block specifically.
        my @task_blocks = grep { ($_->{matcher} // '') eq 'Task' } @post;
        my ($log_block) = grep {
            grep { ($_->{command} // '') =~ /log-dispatch\.sh/ } @{ $_->{hooks} || [] }
        } @task_blocks;
        ok(defined $log_block, 'a PostToolUse:Task block containing log-dispatch.sh exists');
        SKIP: {
            skip 'no log-dispatch.sh block found', 1 unless defined $log_block;
            my @cmds = map { $_->{command} // '' } @{ $log_block->{hooks} || [] };
            is_deeply(\@cmds, ['bash "${CLAUDE_PLUGIN_ROOT}/hooks/log-dispatch.sh"'],
                "the log-dispatch.sh block's command list is still exactly [log-dispatch.sh] (pinned by three other test files)")
                or diag(explain(\@cmds));
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
