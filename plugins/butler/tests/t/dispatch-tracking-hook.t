#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for coordinator-context-discipline/01-deterministic-dispatch-tracking.
#
# Spec: .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/
#       01-deterministic-dispatch-tracking-spec.md
# Ledger: .ccpraxis-local-data/blueprints/coordinator-context-discipline/packages/
#       01-deterministic-dispatch-tracking.md
#
# WRITTEN BLIND TO THE IMPLEMENTATION. At the time this file is authored:
#   - track-dispatch.sh has no dual-mode branch on hook_event_name, stamps no
#     dispatch_key, and has no run_in_background detection.
#   - bp-dispatch-log.pl has no --dispatch-key option, no resolve_plan sub, no
#     `resolve` or `outstanding` CLI verb.
#   - hooks.json registers track-dispatch.sh on PreToolUse:Task only.
#   - coordinator-protocol/SKILL.md has no subsection documenting the signal.
# Every assertion below that depends on new behavior is expected to fail on
# MISSING BEHAVIOR (an unimplemented verb/branch/field/doc string), never on a
# harness bug of this file's own making.
#
# HOUSE PATTERN, lifted verbatim from dispatch-write-path.t / dispatch-log-
# hardening.t / bp-dispatch-log.t: %CLEAN_ENV strips ambient BP_*/
# CLAUDE_PROJECT_DIR/CCPRAXIS_DISPATCH_LOG_TEST_NOW; run_hook() shells
# track-dispatch.sh via bash with a clean env and file-redirected stdio;
# run_cli() shells bp-dispatch-log.pl via `perl SCRIPT ARGS...`; SC()/has_sub()
# guard every not-yet-defined BpDispatchLog:: call so a missing sub degrades to
# a clean `not ok`, never a die that aborts the rest of the file; a snapshot/
# compare pair at the very top and very bottom proves the real
# .ccpraxis-local-data/.dispatch-log is never touched (AC30).
#
# Runs standalone: perl this file
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Cwd qw(getcwd);
use POSIX qw(WIFEXITED WEXITSTATUS);

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $SKILLS  = "$Bin/../../skills")  =~ s{\\}{/}g;
my $TRACK       = "$HOOKS/track-dispatch.sh";
my $DISPATCHLOG = "$SCRIPTS/bp-dispatch-log.pl";
my $SKILL_MD    = "$SKILLS/coordinator-protocol/SKILL.md";

my $J = JSON::PP->new->canonical;

plan skip_all => 'track-dispatch.sh not found'  unless -f $TRACK;
plan skip_all => 'bp-dispatch-log.pl not found' unless -f $DISPATCHLOG;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET (AC30) -- never touch the real dispatch-log. Snapshot at start,
# compare at the very end.
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
sub json_record_files {
    my ($logdir) = @_;
    my @f = -d $logdir ? sort grep { $_ !~ /history\.jsonl\z/ } glob("$logdir/*.json") : ();
    return wantarray ? @f : scalar(@f);
}
sub logdir_of  { my ($proj) = @_; return "$proj/.ccpraxis-local-data/.dispatch-log" }
sub history_of { my ($proj) = @_; return logdir_of($proj) . '/history.jsonl' }
sub history_lines {
    my ($proj) = @_;
    my $raw = read_file(history_of($proj));
    my @lines = defined $raw ? (grep { length } split /\n/, $raw) : ();
    return wantarray ? @lines : scalar(@lines);
}

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
        system('bash', '-c', '"$HOOKPATH" < "$PFILE" > "$OUTFILE" 2> "$ERRFILE"');
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
        BP_PACKAGE      => 'p01',
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}

# payload(EVENT, SUBAGENT_TYPE_OR_UNDEF, %extra) -- %extra becomes extra
# tool_input keys; a value of \1 / \0 encodes a JSON boolean literal.
sub payload {
    my ($event, $subagent_type, %extra) = @_;
    my %top = (hook_event_name => $event, tool_name => 'Task');
    if (defined $subagent_type || %extra) {
        $top{tool_input} = { (defined $subagent_type ? (subagent_type => $subagent_type) : ()), %extra };
    }
    return $J->encode(\%top);
}
sub pre_payload  { my ($t, %e) = @_; return payload('PreToolUse',  $t, %e) }
sub post_payload { my ($t, %e) = @_; return payload('PostToolUse', $t, %e) }

# run_cli(NOW_OK, @ARGS) -> ($exit, $stdout, $stderr) -- house pattern from
# dispatch-log-hardening.t. NOW_OK=1 sets CCPRAXIS_DISPATCH_LOG_TEST_NOW=1.
sub run_cli {
    my ($now_ok, @args) = @_;
    $caseN++;
    my $tmp = "$ROOT/cli$caseN"; make_path($tmp);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($DISPATCHLOG), map { $q->($_) } @args);
    my $envprefix = $now_ok ? 'CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 ' : '';
    local %ENV = %CLEAN_ENV;
    system(qq{$envprefix$cmd > "$out_f" 2> "$err_f"});
    my $rc = ($? == -1) ? undef : ($? >> 8);
    return ($rc, read_file($out_f) // '', read_file($err_f) // '');
}

# spec_dispatch_key(DESC) -- independent PURE reference implementation of the
# §2.1 algorithm, derived from the spec text alone (never from the
# implementation). Used as the oracle for AC2/AC3.
sub spec_dispatch_key {
    my ($d) = @_;
    $d = defined $d ? $d : '';
    $d = lc($d);
    $d =~ s/[^a-z0-9]/-/g;
    $d =~ s/-+/-/g;
    $d =~ s/^-+//;
    $d =~ s/-+\z//;
    $d = substr($d, 0, 48);
    $d =~ s/-+\z//;
    return $d;
}

sub has_sub { my ($fq) = @_; no strict 'refs'; return defined &{$fq}; }
sub SC {
    my ($fq, @args) = @_;
    return undef unless has_sub($fq);
    no strict 'refs';
    return &{$fq}(@args);
}

my $BANNED_RE = qr/nothing is outstanding|all clear|is done|has finished|checkpoint now/i;

# ===========================================================================
# Sanity-check the reference algorithm against the spec's own pinned table
# BEFORE using it as an oracle for anything else.
# ===========================================================================
subtest 'harness: spec_dispatch_key oracle matches the §2.1 pinned table' => sub {
    is(spec_dispatch_key('review package 01'), 'review-package-01', 'row 1');
    is(spec_dispatch_key('Review Package 01'), 'review-package-01', 'row 2 (case)');
    is(spec_dispatch_key('  spaced   out  '),  'spaced-out',        'row 3 (whitespace collapse+trim)');
    is(spec_dispatch_key('red-team 01'),       'red-team-01',       'row 4 (existing hyphen preserved)');
    is(spec_dispatch_key('!!!'),               '',                  'row 5 (all-punctuation -> empty)');
    is(spec_dispatch_key(undef),               '',                  'row 6 (absent -> empty)');
    is(spec_dispatch_key('a' x 60),            'a' x 48,            'row 7 (truncate to 48)');
    is(spec_dispatch_key('ab-' x 20),          ('ab-' x 15) . 'ab', 'row 8 (truncate then re-strip trailing -)');
    is(length(spec_dispatch_key('ab-' x 20)), 47, 'row 8: exactly 47 chars per the pinned table');
};

# ===========================================================================
# AC1 (B1) -- start half unchanged: a real PreToolUse:Task payload writes
# exactly one status:"running" record; stdout empty; exit 0.
# ===========================================================================
subtest 'AC1: PreToolUse:Task writes exactly one running record, silently, exit 0 (B1)' => sub {
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit, $out, $err) = run_hook($TRACK, pre_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'exit 0');
    is($out, '', 'stdout empty');
    my @files = json_record_files($logdir);
    is(scalar(@files), 1, 'exactly one record file');
    SKIP: {
        skip 'no record to inspect', 3 unless @files == 1;
        my $rec = read_json($files[0]);
        ok(ref $rec eq 'HASH', 'record decodes as JSON object');
        is($rec->{status}, 'running', 'status:running');
        is($rec->{worker_type}, 'bp-implementer', 'worker_type normalized');
        like($files[0], qr/hk-/, 'id is hk--prefixed') if ref $rec eq 'HASH';
    }
};

# ===========================================================================
# AC2 (B2) -- start half stamps dispatch_key; absent/unusable description
# means the field is ABSENT, never null or empty.
# ===========================================================================
subtest 'AC2: start half stamps dispatch_key from description; absent when unusable (B2)' => sub {
    {
        my ($env, undef, $proj) = fresh_env();
        my ($exit) = run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'Review Package 01'), %$env);
        is($exit, 0, 'exit 0 with a usable description');
        my @files = json_record_files(logdir_of($proj));
        is(scalar(@files), 1, 'one record written');
        SKIP: {
            skip 'no record to inspect', 1 unless @files == 1;
            my $rec = read_json($files[0]);
            is(ref $rec eq 'HASH' ? $rec->{dispatch_key} : undef, 'review-package-01',
                'dispatch_key:"review-package-01"');
        }
    }
    {
        my ($env, undef, $proj) = fresh_env();
        run_hook($TRACK, pre_payload('butler:bp-reviewer', description => '!!!'), %$env);
        my @files = json_record_files(logdir_of($proj));
        SKIP: {
            skip 'no record to inspect', 1 unless @files == 1;
            my $rec = read_json($files[0]);
            ok(ref $rec eq 'HASH' && !exists $rec->{dispatch_key}, 'description "!!!" -> dispatch_key ABSENT (never null/empty)');
        }
    }
    {
        my ($env, undef, $proj) = fresh_env();
        run_hook($TRACK, pre_payload('butler:bp-reviewer'), %$env); # no description key at all
        my @files = json_record_files(logdir_of($proj));
        SKIP: {
            skip 'no record to inspect', 1 unless @files == 1;
            my $rec = read_json($files[0]);
            ok(ref $rec eq 'HASH' && !exists $rec->{dispatch_key}, 'description absent entirely -> dispatch_key ABSENT');
        }
    }
};

# ===========================================================================
# AC3 -- every §2.1 pinned-example row, verified through the hook.
# ===========================================================================
subtest 'AC3: every §2.1 pinned-example row maps description -> dispatch_key' => sub {
    my @rows = (
        ['review package 01', undef],
        ['Review Package 01', undef],
        ['  spaced   out  ',  undef],
        ['red-team 01',       undef],
        ['!!!',               undef],
        [undef,               undef],
        ['a' x 60,            undef],
        ['ab-' x 20,          undef],
    );
    for my $row (@rows) {
        my ($desc, undef) = @$row;
        my $expect = spec_dispatch_key($desc);
        my ($env, undef, $proj) = fresh_env();
        my %extra = defined $desc ? (description => $desc) : ();
        run_hook($TRACK, pre_payload('butler:bp-reviewer', %extra), %$env);
        my @files = json_record_files(logdir_of($proj));
        my $label = defined $desc ? (length($desc) > 24 ? substr($desc, 0, 24) . '...' : $desc) : '<absent>';
        SKIP: {
            skip "no record to inspect for '$label'", 1 unless @files == 1;
            my $rec = read_json($files[0]);
            if (length $expect) {
                is(ref $rec eq 'HASH' ? $rec->{dispatch_key} : undef, $expect, "description '$label' -> dispatch_key '$expect'");
            } else {
                ok(ref $rec eq 'HASH' && !exists $rec->{dispatch_key}, "description '$label' -> dispatch_key absent");
            }
        }
    }
};

# ===========================================================================
# AC4 (B3) -- two dispatches, same type/package, DIFFERENT descriptions ->
# two distinct records (dedup gains the dispatch_key comparison).
# ===========================================================================
subtest 'AC4: differing descriptions, same worker_type/package -> two records (B3)' => sub {
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'review a'), %$env);
    run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'review b'), %$env);
    is(scalar(json_record_files($logdir)), 2, 'two distinct records, not collapsed by dedup');
};

# ===========================================================================
# AC5 -- identical description twice still dedups to one record (L1, pinned
# as an explicit regression anchor, NOT a new behavior).
# ===========================================================================
subtest 'AC5: identical description twice still dedups to one record (L1, unchanged)' => sub {
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'same one'), %$env);
    run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'same one'), %$env);
    is(scalar(json_record_files($logdir)), 1, 'still one record -- the 120s dedup window is unchanged');
};

# ===========================================================================
# AC6 (B4) -- completion happy path: PostToolUse flips the matching record to
# done, sets ended_at/duration_seconds, appends one history.jsonl line.
# ===========================================================================
subtest 'AC6: PostToolUse:Task resolves the matching record to done (B4)' => sub {
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($e1) = run_hook($TRACK, pre_payload('butler:bp-reviewer', description => 'Review Package 01'), %$env);
    is($e1, 0, 'setup: PreToolUse exit 0');
    my @files = json_record_files($logdir);
    is(scalar(@files), 1, 'setup: one running record exists');
    SKIP: {
        skip 'no running record to resolve', 6 unless @files == 1;
        my ($e2, $out2, $err2) = run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'Review Package 01'), %$env);
        is($e2, 0, 'PostToolUse exit 0');
        is($out2, '', 'PostToolUse stdout empty');
        is($err2, '', 'PostToolUse stderr empty');
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'done', 'record flips to status:done');
        ok(ref $rec eq 'HASH' && defined $rec->{ended_at}, 'ended_at is set');
        ok(ref $rec eq 'HASH' && defined $rec->{duration_seconds} && $rec->{duration_seconds} =~ /^-?\d+(?:\.\d+)?\z/,
            'duration_seconds is a number');
        is(scalar(history_lines($proj)), 1, 'exactly one history.jsonl line appended');
    }
};

# ===========================================================================
# AC7 -- a full Pre+Post round trip through the hook ALONE ends with
# outstanding_count: 0, with no bp-dispatch-log.pl call from the test.
# ===========================================================================
subtest 'AC7: hook-only Pre+Post round trip ends outstanding_count: 0' => sub {
    my ($env, undef, $proj) = fresh_env();
    run_hook($TRACK, pre_payload('butler:bp-reviewer',  description => 'round trip'), %$env);
    run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'round trip'), %$env);
    my ($rc, $out, $err) = run_cli(0, 'outstanding', '--root', fwd($proj));
    like($out, qr/^outstanding_count: 0$/m, 'outstanding_count: 0 after the round trip')
        or diag("stdout was: [$out] stderr was: [$err]");
};

# ===========================================================================
# AC8 (B6) -- a backgrounded PostToolUse:Task is not treated as complete and
# does not fabricate a new record either.
# ===========================================================================
subtest 'AC8: a backgrounded PostToolUse:Task resolves nothing and records nothing (B6)' => sub {
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit, $out, $err) = run_hook($TRACK,
        post_payload('butler:bp-reviewer', description => 'bg-dispatch', run_in_background => \1), %$env);
    is($exit, 0, 'exit 0');
    is($out, '', 'stdout empty');
    is($err, '', 'stderr empty');
    is(scalar(json_record_files($logdir)), 0, 'no record created for a backgrounded PostToolUse');
};

# ===========================================================================
# AC9 (B5, B7) -- completion outside a coordinator context (or a non-bp-*
# type, or an empty payload) writes nothing anywhere and prints nothing.
# ===========================================================================
subtest 'AC9: completion is silent and inert on every out-of-scope path (B5, B7)' => sub {
    my $cwd_before = getcwd();

    {
        my ($env, undef, $proj) = fresh_env();
        delete $env->{BP_LEDGER};
        my ($exit, $out, $err) = run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'x'), %$env);
        is($exit, 0, 'BP_LEDGER unset -> exit 0');
        is($out . $err, '', 'BP_LEDGER unset -> no output');
        ok(!-d logdir_of($proj), 'BP_LEDGER unset -> no store created');
    }
    {
        my ($env, undef, $proj) = fresh_env(BP_ROLE => 'judge');
        my ($exit, $out, $err) = run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'x'), %$env);
        is($exit, 0, 'BP_ROLE=judge -> exit 0');
        is($out . $err, '', 'BP_ROLE=judge -> no output');
        ok(!-d logdir_of($proj), 'BP_ROLE=judge -> no store created');
    }
    {
        my ($env, undef, $proj) = fresh_env(BP_DISPATCH_LOG_OFF => '1');
        my ($exit, $out, $err) = run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'x'), %$env);
        is($exit, 0, 'BP_DISPATCH_LOG_OFF=1 -> exit 0');
        is($out . $err, '', 'BP_DISPATCH_LOG_OFF=1 -> no output');
        ok(!-d logdir_of($proj), 'BP_DISPATCH_LOG_OFF=1 -> no store created');
    }
    {
        my ($env, undef, $proj) = fresh_env();
        my ($exit, $out, $err) = run_hook($TRACK, post_payload('butler:not-a-bp-worker', description => 'x'), %$env);
        is($exit, 0, 'non-bp-* subagent_type -> exit 0');
        is($out . $err, '', 'non-bp-* subagent_type -> no output');
        ok(!-d logdir_of($proj) || json_record_files(logdir_of($proj)) == 0, 'non-bp-* subagent_type -> no record');
    }
    {
        my ($env, undef, $proj) = fresh_env(BP_PROJECT_ROOT => '.');
        $caseN++;
        my $cwd_lab = "$ROOT/cwdlab$caseN"; make_path($cwd_lab);
        my $old_cwd = getcwd();
        chdir $cwd_lab or die "chdir $cwd_lab: $!";
        my ($exit, $out, $err) = run_hook($TRACK, post_payload('butler:bp-reviewer', description => 'x'), %$env);
        chdir $old_cwd or die "chdir back: $!";
        is($exit, 0, 'relative BP_PROJECT_ROOT -> exit 0');
        is($out . $err, '', 'relative BP_PROJECT_ROOT -> no output');
        ok(!-d "$cwd_lab/.ccpraxis-local-data",
            'relative BP_PROJECT_ROOT -> nothing created under a controlled, otherwise-empty cwd');
    }
    {
        my ($env, undef, $proj) = fresh_env();
        my ($exit, $out, $err) = run_hook($TRACK, undef, %$env); # empty payload '{}'
        is($exit, 0, 'empty payload -> exit 0');
        is($out . $err, '', 'empty payload -> no output');
        ok(!-d logdir_of($proj), 'empty payload -> no store created');
    }
};

# ===========================================================================
# AC10 -- static syntax checks.
# ===========================================================================
subtest 'AC10: static syntax checks' => sub {
    my $bashn = `bash -n "$TRACK" 2>&1`;
    is($? >> 8, 0, 'bash -n track-dispatch.sh succeeds') or diag($bashn);
    my $perlc = `perl -c "$DISPATCHLOG" 2>&1`;
    is($? >> 8, 0, 'perl -c bp-dispatch-log.pl succeeds') or diag($perlc);
};

# ===========================================================================
# AC11 (B9) -- outstanding on an empty store.
# ===========================================================================
subtest 'AC11: outstanding on an empty store (B9)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out, $err) = run_cli(0, 'outstanding', '--root', fwd($root));
    is($rc, 0, 'exit 0');
    like($out, qr/^outstanding_count: 0$/m, 'outstanding_count: 0');
    unlike($out, qr/^outstanding:/m, 'zero outstanding: lines');
    ok(index($out, 'summary: no outstanding dispatch was detected in the dispatch log (0 running records matched); '
        . 'this reflects what is recorded on disk, not a guarantee that nothing is running.') >= 0,
        'zero summary is byte-exact') or diag($out);
};

# ===========================================================================
# AC12 (B9) -- outstanding with one running record.
# ===========================================================================
subtest 'AC12: outstanding with one running record (B9)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $logdir = logdir_of($root);
    my $now = 1_700_000_000;
    plant_rec($logdir, 'r1', worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 10, budget_seconds => 1800);
    my ($rc, $out, $err) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
    is($rc, 1, 'exit 1');
    like($out, qr/^outstanding_count: 1$/m, 'outstanding_count: 1');
    like($out, qr/^outstanding: id=r1 worker_type=bp-reviewer blueprint=- package=- dispatch_key=- elapsed_seconds=10 stale=false$/m,
        'exactly one outstanding: line naming r1') or diag($out);
    ok(index($out, 'summary: 1 dispatch appears to be outstanding (recorded as running, not yet resolved); '
        . 'this reflects what is recorded on disk, not a guarantee that it is still alive.') >= 0,
        'one-sentence summary is byte-exact') or diag($out);
};

# ===========================================================================
# AC13 (B10) -- two same worker_type running records stay two.
# ===========================================================================
subtest 'AC13: two same-worker_type outstanding dispatches stay two (B10)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $logdir = logdir_of($root);
    my $now = 1_700_000_000;
    plant_rec($logdir, 'ra', worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 10, dispatch_key => 'review-a', package => 'pkg');
    plant_rec($logdir, 'rb', worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 20, dispatch_key => 'review-b', package => 'pkg');
    my ($rc, $out, $err) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
    is($rc, 1, 'exit 1');
    like($out, qr/^outstanding_count: 2$/m, 'outstanding_count: 2');
    my @lines = grep { /^outstanding:/ } split /\n/, $out;
    is(scalar(@lines), 2, 'exactly two outstanding: lines') or diag($out);
    my @ids = map { /id=(\S+)/ ? $1 : () } @lines;
    my @keys = map { /dispatch_key=(\S+)/ ? $1 : () } @lines;
    is_deeply([sort @ids], ['ra', 'rb'], 'distinct ids');
    is_deeply([sort @keys], ['review-a', 'review-b'], 'distinct dispatch_keys');
    ok(index($out, "summary: 2 dispatches appear to be outstanding (recorded as running, not yet resolved); "
        . "this reflects what is recorded on disk, not a guarantee that they are still alive.") >= 0,
        'plural summary is byte-exact') or diag($out);
};

# ===========================================================================
# AC14 -- live + stale + unevaluable counts sum to outstanding_count.
# ===========================================================================
subtest 'AC14: live_count + stale_count + unevaluable_count == outstanding_count' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $logdir = logdir_of($root);
    my $now = 1_700_000_000;
    plant_rec($logdir, 'live',   worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 10,    budget_seconds => 1800);
    plant_rec($logdir, 'stale',  worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 99999, budget_seconds => 1800);
    plant_rec($logdir, 'uneval', worker_type => 'bp-reviewer', status => 'running',
        started_at => 'garbage');
    my ($rc, $out, $err) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
    like($out, qr/^outstanding_count: 3$/m, 'outstanding_count: 3');
    my ($oc)  = $out =~ /^outstanding_count: (\S+)$/m;
    my ($lc)  = $out =~ /^live_count: (\S+)$/m;
    my ($sc)  = $out =~ /^stale_count: (\S+)$/m;
    my ($uc)  = $out =~ /^unevaluable_count: (\S+)$/m;
    ok(defined $oc && defined $lc && defined $sc && defined $uc, 'all four count lines present') or diag($out);
    SKIP: {
        skip 'count lines missing', 1 unless defined $lc && defined $sc && defined $uc && defined $oc
            && $lc =~ /^\d+\z/ && $sc =~ /^\d+\z/ && $uc =~ /^\d+\z/ && $oc =~ /^\d+\z/;
        is($lc + $sc + $uc, $oc, 'live+stale+unevaluable == outstanding_count');
    }
    my @lines = grep { /^outstanding:/ } split /\n/, $out;
    is(scalar(@lines), 3, 'all three records appear as outstanding: lines') or diag($out);
};

# ===========================================================================
# AC15 -- the staleness note: present byte-exact when stale_count > 0, absent
# otherwise.
# ===========================================================================
subtest 'AC15: staleness note is present byte-exact iff stale_count > 0' => sub {
    {
        my $root = tempdir(CLEANUP => 1);
        my $now = 1_700_000_000;
        plant_rec(logdir_of($root), 'stale1', worker_type => 'bp-reviewer', status => 'running',
            started_at => $now - 99999, budget_seconds => 1800);
        my ($rc, $out) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
        ok(index($out, 'note: 1 of them are past 4x their own budget, which may mean the dispatch died without '
            . 'its completion being observed; the record stays outstanding rather than clearing on age.') >= 0,
            'note line present and byte-exact with one stale record') or diag($out);
    }
    {
        my $root = tempdir(CLEANUP => 1);
        my $now = 1_700_000_000;
        plant_rec(logdir_of($root), 'live1', worker_type => 'bp-reviewer', status => 'running',
            started_at => $now - 10, budget_seconds => 1800);
        my ($rc, $out) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
        unlike($out, qr/^note:/m, 'note line absent with zero stale records') or diag($out);
    }
};

# ===========================================================================
# AC16 (B8) -- a record running 10x its budget is still counted, still
# listed, exit still 1.
# ===========================================================================
subtest 'AC16: a record 10x over its budget is still counted (B8)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $now = 1_700_000_000;
    plant_rec(logdir_of($root), 'ancient', worker_type => 'bp-reviewer', status => 'running',
        started_at => $now - 1000, budget_seconds => 100);
    my ($rc, $out) = run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now);
    is($rc, 1, 'exit 1');
    like($out, qr/^outstanding_count: 1$/m, 'outstanding_count: 1, no drop from age');
    like($out, qr/^outstanding: id=ancient .*elapsed_seconds=1000 stale=true$/m, 'still listed, flagged stale') or diag($out);
};

# ===========================================================================
# AC17 (B14) -- every summary:/note: string matches the §2.6 literals
# byte-exact, is single-line, and never matches the banned phrases.
# ===========================================================================
subtest 'AC17: every summary/note string is byte-exact, single-line, never a false all-clear (B14)' => sub {
    my $now = 1_700_000_000;
    my %cases;
    {
        my $root = tempdir(CLEANUP => 1);
        $cases{zero} = (run_cli(0, 'outstanding', '--root', fwd($root)))[1];
    }
    {
        my $root = tempdir(CLEANUP => 1);
        plant_rec(logdir_of($root), 'one', worker_type => 'bp-reviewer', status => 'running', started_at => $now - 5);
        $cases{one} = (run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now))[1];
    }
    {
        my $root = tempdir(CLEANUP => 1);
        plant_rec(logdir_of($root), 'a', worker_type => 'bp-reviewer', status => 'running', started_at => $now - 5);
        plant_rec(logdir_of($root), 'b', worker_type => 'bp-reviewer', status => 'running', started_at => $now - 5);
        $cases{plural} = (run_cli(1, 'outstanding', '--root', fwd($root), '--now', $now))[1];
    }
    {
        my $root = tempdir(CLEANUP => 1);
        write_file(logdir_of($root), 'not a directory'); # opendir must fail
        $cases{unreadable} = (run_cli(0, 'outstanding', '--root', fwd($root)))[1];
    }

    my %expect = (
        zero   => 'summary: no outstanding dispatch was detected in the dispatch log (0 running records matched); '
                . 'this reflects what is recorded on disk, not a guarantee that nothing is running.',
        one    => 'summary: 1 dispatch appears to be outstanding (recorded as running, not yet resolved); '
                . 'this reflects what is recorded on disk, not a guarantee that it is still alive.',
        plural => 'summary: 2 dispatches appear to be outstanding (recorded as running, not yet resolved); '
                . 'this reflects what is recorded on disk, not a guarantee that they are still alive.',
        unreadable => 'summary: the dispatch log could not be read, so whether anything is outstanding was not determined.',
    );
    for my $k (qw(zero one plural unreadable)) {
        ok(index($cases{$k}, $expect{$k}) >= 0, "$k: mandated summary present byte-exact") or diag($cases{$k});
        unlike($cases{$k}, $BANNED_RE, "$k: no banned phrase anywhere in stdout");
        for my $line (grep { /^summary:|^note:/ } split /\n/, $cases{$k}) {
            unlike($line, qr/\n/, "$k: '$line' has no embedded newline");
        }
    }
};

# ===========================================================================
# AC18 (B15) -- an unreadable store degrades to unknown, never zero.
# ===========================================================================
subtest 'AC18: unreadable store -> outstanding_count: unknown, exit 4 (B15)' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path($root);
    write_file(logdir_of($root), 'this is a plain file, not a directory');
    my ($rc, $out, $err) = run_cli(0, 'outstanding', '--root', fwd($root));
    is($rc, 4, 'exit 4');
    like($out, qr/^outstanding_count: unknown$/m, 'outstanding_count: unknown') or diag($out);
    ok(index($out, 'summary: the dispatch log could not be read, so whether anything is outstanding was not determined.') >= 0,
        'fourth (unreadable) summary present byte-exact');
};

# ===========================================================================
# Load bp-dispatch-log.pl as a library for the pure resolve_plan tests (AC19).
# ===========================================================================
my $LIB_LOAD_ERROR = '';
my $LIB_LOADED = do {
    local $@;
    eval { require $DISPATCHLOG };
    $LIB_LOAD_ERROR = $@;
    !$@;
};
ok($LIB_LOADED, 'harness: bp-dispatch-log.pl requires cleanly as a library') or diag($LIB_LOAD_ERROR);

# ===========================================================================
# AC19 (§2.4) -- resolve_plan as a pure function.
# ===========================================================================
subtest 'AC19: BpDispatchLog::resolve_plan is a pure, total function (§2.4)' => sub {
    my $got1 = SC('BpDispatchLog::resolve_plan',
        [ { id => 'keyed',   rec => { status => 'running', worker_type => 'bp-reviewer', dispatch_key => 'review-a', started_at => 100 } },
          { id => 'keyless', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 50 } } ],
        { worker_type => 'bp-reviewer', dispatch_key => 'review-a' });
    is($got1, 'keyed', 'tier1 exact dispatch_key match wins over a keyless candidate');

    # Amended post-redteam HIGH-2: tier2 is gated on the CALLER supplying no
    # dispatch_key at all, not merely on tier1 being empty. A caller that DID
    # supply a dispatch_key and found no tier1 match must get undef, never a
    # keyless steal -- otherwise a keyed completion (fired automatically by
    # every PostToolUse:Task) could silently close an unrelated dispatch's
    # keyless record. See AC21's CLI-level cases for the same rule.
    my $got2 = SC('BpDispatchLog::resolve_plan',
        [ { id => 'keyless', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 50 } } ],
        { worker_type => 'bp-reviewer', dispatch_key => 'review-a' });
    is($got2, undef, 'a keyed criteria with only a keyless candidate present -> undef, never a steal');

    my $got2b = SC('BpDispatchLog::resolve_plan',
        [ { id => 'keyless', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 50 } } ],
        { worker_type => 'bp-reviewer' });
    is($got2b, 'keyless', 'tier2 fallback closes the keyless record when the CALLER supplies no dispatch_key at all');

    my $got3 = SC('BpDispatchLog::resolve_plan',
        [ { id => 'other', rec => { status => 'running', worker_type => 'bp-reviewer', dispatch_key => 'different' } } ],
        { worker_type => 'bp-reviewer', dispatch_key => 'review-a' });
    is($got3, undef, 'a differently-keyed candidate matches neither tier -> undef');

    my $got4 = SC('BpDispatchLog::resolve_plan',
        [ { id => 'newer', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 200 } },
          { id => 'older', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 100 } } ],
        { worker_type => 'bp-reviewer' });
    is($got4, 'older', 'FIFO: the oldest started_at within a tier wins');

    my $got5 = SC('BpDispatchLog::resolve_plan', [], { worker_type => 'bp-reviewer' });
    is($got5, undef, 'empty @entries -> undef');

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        SC('BpDispatchLog::resolve_plan',
            [ 'not-a-hash-entry',
              { id => 'no-rec' },
              { id => 'no-status', rec => { worker_type => 'bp-reviewer' } },
              { id => 'bad-started', rec => { status => 'running', worker_type => 'bp-reviewer', started_at => 'x' } },
              undef ],
            { worker_type => 'bp-reviewer' });
    }
    is(scalar(@warnings), 0, 'no warnings on a non-hash entry, missing status, non-numeric started_at, or undef entry')
        or diag(join("\n", @warnings));
};

# ===========================================================================
# AC20 (B11) -- resolve with a non-matching key: NO-MATCH, exit 5, untouched.
# ===========================================================================
subtest 'AC20: resolve with a non-matching dispatch-key -> NO-MATCH, exit 5 (B11)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $logdir = logdir_of($root);
    plant_rec($logdir, 'rec1', worker_type => 'bp-reviewer', status => 'running',
        started_at => 1000, dispatch_key => 'review-a');
    my ($rc, $out, $err) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done',
        '--dispatch-key', 'review-b', '--root', fwd($root), '--now', 2000);
    is($rc, 5, 'exit 5');
    like($out, qr/^NO-MATCH: no running record matched worker_type=bp-reviewer package=- dispatch_key=review-b$/m,
        'NO-MATCH line byte-exact') or diag("out=[$out] err=[$err]");
    my $rec = read_json("$logdir/rec1.json");
    is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'running', 'the record is untouched');
};

# ===========================================================================
# AC21 (B12) -- tier ordering: keyed wins when present; keyless fallback used
# only when no keyed candidate exists.
# ===========================================================================
subtest 'AC21: tier ordering -- keyed wins, keyless is the fallback (B12)' => sub {
    {
        my $root = tempdir(CLEANUP => 1);
        my $logdir = logdir_of($root);
        plant_rec($logdir, 'keyed',   worker_type => 'bp-reviewer', status => 'running', started_at => 1000, dispatch_key => 'review-a');
        plant_rec($logdir, 'keyless', worker_type => 'bp-reviewer', status => 'running', started_at => 1000);
        my ($rc, $out) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done',
            '--dispatch-key', 'review-a', '--root', fwd($root), '--now', 2000);
        is($rc, 0, 'exit 0');
        like($out, qr/^resolved keyed \(worker_type=bp-reviewer status=done duration_seconds=\d+\)$/m,
            'the keyed record specifically is resolved') or diag($out);
        is(read_json("$logdir/keyless.json")->{status}, 'running', 'the keyless record is untouched');
    }
    {
        # A resolve call that DOES supply --dispatch-key and finds no tier1
        # match must NEVER fall through to tier2 -- that would let a keyed
        # completion (fired automatically by every PostToolUse:Task) steal-
        # close an unrelated keyless dispatch's record (redteam HIGH-2,
        # spec §2.4/B12 amended post-review).
        my $root = tempdir(CLEANUP => 1);
        my $logdir = logdir_of($root);
        plant_rec($logdir, 'keyless', worker_type => 'bp-reviewer', status => 'running', started_at => 1000);
        my ($rc, $out) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done',
            '--dispatch-key', 'review-a', '--root', fwd($root), '--now', 2000);
        is($rc, 5, 'a keyed resolve with only a keyless candidate present is NO-MATCH, not a steal');
        like($out, qr/^NO-MATCH:/m, 'NO-MATCH line printed') or diag($out);
        is(read_json("$logdir/keyless.json")->{status}, 'running', 'the keyless record is untouched');
    }
    {
        # The TRUE tier2 fallback: a resolve call that supplies NO
        # --dispatch-key at all (the manual start/finish bracket path has no
        # key to give) still finds a keyless record.
        my $root = tempdir(CLEANUP => 1);
        my $logdir = logdir_of($root);
        plant_rec($logdir, 'keyless', worker_type => 'bp-reviewer', status => 'running', started_at => 1000);
        my ($rc, $out) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done',
            '--root', fwd($root), '--now', 2000);
        is($rc, 0, 'exit 0');
        like($out, qr/^resolved keyless \(worker_type=bp-reviewer status=done duration_seconds=\d+\)$/m,
            'a keyless resolve call falls back to the keyless record') or diag($out);
    }
};

# ===========================================================================
# AC22 (B13) -- FIFO within a tier.
# ===========================================================================
subtest 'AC22: FIFO within a tier (B13)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $logdir = logdir_of($root);
    plant_rec($logdir, 'young', worker_type => 'bp-reviewer', status => 'running', started_at => 200);
    plant_rec($logdir, 'old',   worker_type => 'bp-reviewer', status => 'running', started_at => 100);

    my ($rc1, $out1) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', 500);
    is($rc1, 0, 'first resolve exits 0');
    like($out1, qr/^resolved old \(worker_type=bp-reviewer status=done duration_seconds=\d+\)$/m, 'the started_at:100 record closes first') or diag($out1);

    my ($rc2, $out2) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', 500);
    is($rc2, 0, 'second resolve exits 0');
    like($out2, qr/^resolved young \(worker_type=bp-reviewer status=done duration_seconds=\d+\)$/m, 'the remaining record closes second') or diag($out2);

    my ($rc3, $out3) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', 500);
    is($rc3, 5, 'a third resolve NO-MATCHes, exit 5');
};

# ===========================================================================
# AC23 (B17) -- resolve refuses a selected record with a malformed field.
# ===========================================================================
subtest 'AC23: resolve refuses to re-persist a malformed selected record (B17)' => sub {
    # Only 'role' is exercised here. blueprint/package/dispatch_key are all
    # SELECTION criteria in resolve_plan (post-MF-1, matched unconditionally
    # -- eq_or_both_undef, no `exists` gate); role is not a selection
    # criterion at all (only worker_type/blueprint/package/dispatch_key
    # participate in candidate filtering), so a record with a malformed role
    # is still SELECTED by a plain --worker-type match and can be refused at
    # the mutation/re-persist step -- this is B17/H2d's actual scenario.
    #
    # blueprint/package/dispatch_key cases are excluded because, under
    # strict unconditional matching, a resolve call that omits --blueprint/
    # --package/--dispatch-key has an undef criterion for that field, and a
    # record whose stored value is malformed (hence *defined*, non-empty)
    # can never satisfy eq_or_both_undef against an undef criterion -- it is
    # never a candidate, so resolve_plan never selects it in the first
    # place, and "select then refuse" is structurally unreachable for these
    # three fields. (This is the same reasoning that already removed the
    # dispatch_key case here.) Malformed --blueprint/--package/--dispatch-key
    # as *CLI arguments* (a different code path -- option-parse-time
    # validation, before any record selection) are already covered
    # elsewhere: --dispatch-key by AC25 in this file; --blueprint/--package
    # by dispatch-log-hardening.t and dispatch-record-attribution.t.
    my @cases = (
        ['role', 'overlord', qr/role/],
    );
    for my $c (@cases) {
        my ($field, $bad, $namere) = @$c;
        my $root = tempdir(CLEANUP => 1);
        my $logdir = logdir_of($root);
        plant_rec($logdir, 'bad', worker_type => 'bp-reviewer', status => 'running', started_at => 1000, $field => $bad);
        my ($rc, $out, $err) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done',
            '--root', fwd($root), '--now', 2000);
        is($rc, 2, "malformed $field -> exit 2");
        like($err, $namere, "malformed $field -> stderr names the field") or diag($err);
        my $rec = read_json("$logdir/bad.json");
        is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'running', "malformed $field -> record NOT rewritten");
    }
};

# ===========================================================================
# AC24 -- resolve --status interrupted appends no history line; --status done
# appends one; an unusable started_at closes with no duration/history line.
# ===========================================================================
subtest 'AC24: resolve status/history-append rules' => sub {
    {
        my $root = tempdir(CLEANUP => 1);
        plant_rec(logdir_of($root), 'r1', worker_type => 'bp-reviewer', status => 'running', started_at => 1000);
        my ($rc) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'interrupted', '--root', fwd($root), '--now', 2000);
        is($rc, 0, 'interrupted: exit 0');
        is(scalar(history_lines($root)), 0, 'interrupted: no history.jsonl line');
    }
    {
        my $root = tempdir(CLEANUP => 1);
        plant_rec(logdir_of($root), 'r1', worker_type => 'bp-reviewer', status => 'running', started_at => 1000);
        my ($rc) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', 2000);
        is($rc, 0, 'done: exit 0');
        is(scalar(history_lines($root)), 1, 'done: exactly one history.jsonl line');
    }
    {
        my $root = tempdir(CLEANUP => 1);
        plant_rec(logdir_of($root), 'r1', worker_type => 'bp-reviewer', status => 'running', started_at => 'garbage');
        my ($rc, $out) = run_cli(1, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', 2000);
        is($rc, 0, 'unusable started_at: still closes, exit 0');
        my $rec = read_json(logdir_of($root) . '/r1.json');
        ok(ref $rec eq 'HASH' && $rec->{status} eq 'done', 'record closed');
        ok(ref $rec eq 'HASH' && !exists $rec->{duration_seconds}, 'no duration_seconds fabricated');
        is(scalar(history_lines($root)), 0, 'no history.jsonl line for an unusable started_at');
    }
};

# ===========================================================================
# AC25 (§2.3) -- CLI option-guard widening, strictly.
# ===========================================================================
subtest 'AC25: --dispatch-key CLI option guards (§2.3)' => sub {
    for my $cmd (qw(list finish prune elapsed)) {
        my @extra = $cmd eq 'finish'  ? ('--id', 'x', '--status', 'done')
                  : $cmd eq 'elapsed' ? ('--id', 'x')
                  : ();
        my ($rc) = run_cli(0, $cmd, '--dispatch-key', 'review-a', @extra, '--root', fwd(tempdir(CLEANUP => 1)));
        is($rc, 2, "--dispatch-key on $cmd is exit 2");
    }
    for my $bad ('../x', 'UPPER') {
        my ($rc) = run_cli(0, 'start', '--id', 'x', '--worker-type', 'bp-reviewer',
            '--dispatch-key', $bad, '--root', fwd(tempdir(CLEANUP => 1)));
        is($rc, 2, "--dispatch-key '$bad' is exit 2 on start");
    }
    {
        my ($rc) = run_cli(0, 'finish', '--id', 'x', '--status', 'done', '--blueprint', 'b',
            '--root', fwd(tempdir(CLEANUP => 1)));
        is($rc, 2, '--blueprint on finish remains exit 2');
    }
    {
        my ($rc) = run_cli(0, 'finish', '--id', 'x', '--status', 'done', '--package', 'p',
            '--root', fwd(tempdir(CLEANUP => 1)));
        is($rc, 2, '--package on finish remains exit 2');
    }
    {
        my ($rc) = run_cli(0, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--role', 'worker',
            '--root', fwd(tempdir(CLEANUP => 1)));
        is($rc, 2, '--role on resolve is exit 2 (role stays start-only)');
    }
};

# ===========================================================================
# AC26 -- --now on resolve/outstanding without the test-only gate is exit 2.
# ===========================================================================
subtest 'AC26: --now without CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 is exit 2 on the new verbs' => sub {
    my ($rc1) = run_cli(0, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--now', '123',
        '--root', fwd(tempdir(CLEANUP => 1)));
    is($rc1, 2, '--now on resolve without the gate is exit 2');
    my ($rc2) = run_cli(0, 'outstanding', '--now', '123', '--root', fwd(tempdir(CLEANUP => 1)));
    is($rc2, 2, '--now on outstanding without the gate is exit 2');
};

# ===========================================================================
# AC27 (B16) -- start/elapsed/list/finish/prune are byte-identical.
# ===========================================================================
subtest 'AC27: existing verbs unchanged end to end (B16)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my ($rc1, $out1) = run_cli(0, 'start', '--id', 'idx1', '--worker-type', 'bp-reviewer', '--root', fwd($root));
    is($rc1, 0, 'start: exit 0');
    like($out1, qr/^started idx1 \(worker_type=bp-reviewer budget_seconds=\d+\)$/m, 'start: stdout shape unchanged');

    my ($rc2, $out2) = run_cli(0, 'elapsed', '--id', 'idx1', '--root', fwd($root));
    is($rc2, 0, 'elapsed: exit 0');
    like($out2, qr/^id: idx1$/m, 'elapsed: stdout shape unchanged');

    my ($rc3, $out3) = run_cli(0, 'list', '--root', fwd($root));
    is($rc3, 0, 'list: exit 0');
    like($out3, qr/^id: idx1 worker_type: bp-reviewer /m, 'list: stdout shape unchanged');

    my ($rc4, $out4) = run_cli(0, 'finish', '--id', 'idx1', '--status', 'done', '--root', fwd($root));
    is($rc4, 0, 'finish: exit 0');
    like($out4, qr/^finished idx1 \(status=done duration_seconds=/m, 'finish: stdout shape unchanged');

    my ($rc5, $out5) = run_cli(0, 'prune', '--root', fwd($root));
    is($rc5, 0, 'prune: exit 0');
    like($out5, qr/^scanned: \d+$/m, 'prune: stdout shape unchanged');

    my ($rc6) = run_cli(0, 'finish', '--id', 'idx1', '--status', 'done', '--package', 'x', '--root', fwd($root));
    is($rc6, 2, 'finish --package x remains a usage error (exit 2)');

    my ($rc7) = run_cli(0, 'list', '--now', '1', '--root', fwd($root));
    is($rc7, 2, '--now without the gate remains a usage error on an existing verb too');
};

# ===========================================================================
# AC28 (B18) -- DEL (package 16 batch B/E2, code REG): this subtest's premise
# was a hooks.json with the old separate log-dispatch hook and track-dispatch.sh in TWO separate
# PostToolUse:Task blocks. Package 14's guards-remake merged log-dispatch,
# track-worker-solo and untrack-worker-solo into ONE TrackDispatch guard
# (hooks/track-dispatch.sh); package 16 batch B then flattened hooks.json to
# exactly one PostToolUse:Task block naming that single successor. There is
# no separate old-hook block left to stay separate from, so this
# subtest's own "NOT_MATCH" / two-block assertions no longer describe
# anything -- the registration itself (one PreToolUse:Task, one
# PostToolUse:Task, one SubagentStop entry, all naming track-dispatch.sh) is
# re-expressed byte-exactly by hooks-json-route-registration.t's @EXPECT
# table and h01-settings-registration.t's B3d, both package 16's own concern
# per guards-remake-track-dispatch.t's NOT-RE-EXPRESSED table (code REG).
# ===========================================================================

# ===========================================================================
# AC29 -- coordinator-protocol/SKILL.md documents the signal.
# ===========================================================================
subtest 'AC29: coordinator-protocol/SKILL.md documents what the signal can/cannot claim' => sub {
    my $raw = read_file($SKILL_MD) // '';
    my $idx = index($raw, 'bp-dispatch-log.pl outstanding');
    ok($idx >= 0, 'SKILL.md contains the literal "bp-dispatch-log.pl outstanding"');
    SKIP: {
        skip 'no new subsection found yet to scope the hedge/banned-phrase checks against', 6 if $idx < 0;
        my $start = rindex($raw, "\n## ", $idx); $start = 0 if $start < 0;
        my $next  = index($raw, "\n## ", $idx);
        my $end   = $next >= 0 ? $next : length($raw);
        my $section = substr($raw, $start, $end - $start);
        ok($section =~ /\bhedged\b/ || $section =~ /\bappears\b/, 'the new subsection uses "hedged" or "appears"');
        for my $bad ('nothing is outstanding', 'all clear', 'is done', 'has finished', 'checkpoint now') {
            unlike($section, qr/\Q$bad\E/i, "the new subsection does not contain banned phrase '$bad'");
        }
    }
};

# ===========================================================================
# AC30 -- FINAL SAFETY CHECK. Must be the last thing this file does before
# done_testing().
# ===========================================================================
subtest 'AC30: the real .ccpraxis-local-data/.dispatch-log is untouched' => sub {
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole suite');
};

done_testing();
