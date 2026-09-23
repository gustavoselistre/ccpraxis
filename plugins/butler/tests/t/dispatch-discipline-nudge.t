#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for coordinator-context-discipline/03-dispatch-discipline-enforcement.
#
# Spec: .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/
#       03-dispatch-discipline-enforcement-spec.md
# Ledger: .ccpraxis-local-data/blueprints/coordinator-context-discipline/packages/
#       03-dispatch-discipline-enforcement.md
#
# WRITTEN BLIND TO THE IMPLEMENTATION. At the time this file is authored:
#   - bp-dispatch-log.pl has no `ratio` CLI verb, no ratio_thresholds/
#     scan_transcript_counts/ratio_verdict/dispatch_totals subs, no %RATIO_DEFAULT/
#     %RATIO_ENV/$RATIO_MAX_LINES/$RATIO_MAX_LINE_BYTES, and no --transcript option.
#   - plugins/butler/hooks/dispatch-discipline-nudge.sh does NOT EXIST.
#   - hooks.json registers no PostToolUse:Bash|Read|Edit|Grep block.
#   - coordinator-protocol/SKILL.md has no bullet after the :605 sentence naming
#     "prose alone is not the enforcement".
# Every assertion below that depends on new behavior is expected to fail on MISSING
# BEHAVIOR (a missing sub/verb/option/file/registration/bullet) -- never a harness
# bug of this file's own making.
#
# HOUSE PATTERN, lifted from context-ceiling-guidance.t / context-ceiling-flush.t
# (dd39431, package 02) and dispatch-tracking-hook.t (package 01): %CLEAN_ENV strips
# ambient BP_*/CLAUDE_PROJECT_DIR/CCPRAXIS_DISPATCH_LOG_TEST_NOW (this already covers
# BP_DISPATCH_RATIO_*/BP_DISPATCH_NUDGE_INTERVAL_SECS, both BP_-prefixed); run_hook()
# invokes the hook by fork+exec($BASH_ABS, $hookpath) -- NEVER shebang-exec via
# system($BASH_ABS, '-c', ...), which the two package-02 files fixed this session
# under path_without() PATH-stripping fixtures; a snapshot/compare pair on the real
# .ccpraxis-local-data/.dispatch-log sits at the very top and very bottom of this
# file (dispatch-write-path.t:97-108's safety net -- the `ratio` verb reads the
# dispatch-log store, so this file can reach it).
#
# ONE SHARED FIXTURE GENERATOR (gen_transcript/gen_batch/mk_tool_use/mk_coord_rec/
# mk_worker_rec below): every named fixture (F-PATH, F-EARLY, F-PROP, F-VOL,
# F-FLOOR, F-EDGE, F-WORKER) is built by calling it, never by hand-deriving JSONL.
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
my $NUDGE       = "$HOOKS/dispatch-discipline-nudge.sh";
my $LIB         = "$HOOKS/lib.sh";
my $DISPATCHLOG = "$SCRIPTS/bp-dispatch-log.pl";
my $WRITEGUARD  = "$SCRIPTS/bp-write-guard.pl";
my $HOOKS_JSON  = "$HOOKS/hooks.json";
my $SKILL       = "$Bin/../../skills/coordinator-protocol/SKILL.md";

my $J = JSON::PP->new->canonical->utf8;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET -- never touch the real dispatch-log. Snapshot at start, compare
# at the very end (AC28).
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
# The !/^BP_/ filter above already strips BP_DISPATCH_RATIO_MIN_CALLS,
# BP_DISPATCH_RATIO_MIN and BP_DISPATCH_NUDGE_INTERVAL_SECS -- all BP_-prefixed.

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $ROOT = tempdir(CLEANUP => 1);
my $caseN = 0;

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
        # Invoke the hook as an ARGUMENT to $BASH_ABS, never via its own shebang --
        # a shebang-exec depends on PATH resolving the interpreter, which fails
        # under path_without('perl') fixtures (see package 02's own note).
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

# run_cli(['\%extra_env',] @args) -> ($exit, $stdout, $stderr) -- invokes
# bp-dispatch-log.pl in a subprocess with a clean env.
sub run_cli {
    my (@args) = @_;
    my %extra_env;
    if (ref $args[0] eq 'HASH') { %extra_env = %{ shift @args }; }
    $caseN++;
    my $tmp = "$ROOT/cli$caseN"; make_path($tmp);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($DISPATCHLOG), map { $q->($_) } @args);
    local %ENV = (%CLEAN_ENV, %extra_env);
    system(qq{$cmd > "$out_f" 2> "$err_f"});
    my $rc = ($? == -1) ? undef : ($? >> 8);
    return ($rc, read_file($out_f) // '', read_file($err_f) // '');
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
        BP_PACKAGE      => 'p03',
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}

sub post_payload {
    my ($tool) = @_;
    return $J->encode({ hook_event_name => 'PostToolUse', tool_name => $tool, tool_input => {} });
}

sub state_path { my ($bp_dir, $pkg) = @_; return "$bp_dir/runs/$pkg.dispatch-discipline" }
sub read_last_check {
    my ($bp_dir, $pkg) = @_;
    my $c = read_file(state_path($bp_dir, $pkg));
    return undef unless defined $c;
    my ($n) = $c =~ /^last_check:\s*(-?\d+)/m;
    return $n;
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

sub logdir_of { my ($proj) = @_; return "$proj/.ccpraxis-local-data/.dispatch-log" }
sub plant_dispatch_rec {
    my ($logdir, $id, %fields) = @_;
    make_path($logdir) unless -d $logdir;
    write_file("$logdir/$id.json", $J->encode({ id => $id, %fields }));
}

# ---------------------------------------------------------------------------
# stub_hook_tree(%opt) -- a self-contained hooks/+scripts/ tree so a probe
# script can be removed/faked between two hook fires without touching the
# real repo tree. Returns the stub hook path, or undef if the real sources
# aren't readable yet (pre-implementation).
#   no_dispatchlog    => bp-dispatch-log.pl deliberately absent
#   fake_dispatchlog  => literal perl source to write in its place
# ---------------------------------------------------------------------------
sub stub_hook_tree {
    my (%opt) = @_;
    $caseN++;
    my $stub = "$ROOT/stub$caseN";
    make_path("$stub/hooks");
    make_path("$stub/scripts");
    return undef unless -f $NUDGE && -f $LIB && -f $DISPATCHLOG && -f $WRITEGUARD;
    write_file("$stub/hooks/dispatch-discipline-nudge.sh", read_file($NUDGE));
    write_file("$stub/hooks/lib.sh", read_file($LIB));
    if ($opt{no_dispatchlog}) {
        # deliberately absent
    } elsif (defined $opt{fake_dispatchlog}) {
        write_file("$stub/scripts/bp-dispatch-log.pl", $opt{fake_dispatchlog});
    } else {
        write_file("$stub/scripts/bp-dispatch-log.pl", read_file($DISPATCHLOG));
        write_file("$stub/scripts/bp-write-guard.pl", read_file($WRITEGUARD));
    }
    return "$stub/hooks/dispatch-discipline-nudge.sh";
}

# ===========================================================================
# THE ONE SHARED TRANSCRIPT GENERATOR. Every named fixture calls this --
# never hand-derived JSONL per test.
# ===========================================================================
my $TOOLUSE_SEQ = 0;
sub next_tuid { return 'toolu_' . (++$TOOLUSE_SEQ) }

# mk_tool_use(NAME, %o) -> block hashref.
#   command => STRING   sets tool_input.command (never inspected by the
#                       counter -- D-E -- present only for fixture realism)
#   id => VALUE          an explicit id; id => undef means "no id key at all"
#                       (id-less block, counted by position); omitted means
#                       "auto-generate a unique id"
sub mk_tool_use {
    my ($name, %o) = @_;
    my $b = { type => 'tool_use', name => $name, input => {} };
    $b->{input}{command} = $o{command} if defined $o{command};
    if (!exists $o{id})       { $b->{id} = next_tuid() }
    elsif (defined $o{id})    { $b->{id} = $o{id} }
    # else: $o{id} exists and is undef -- no id key at all.
    return $b;
}
sub mk_coord_rec  { my (@blocks) = @_; return { type => 'assistant', message => { content => [@blocks] } } }
sub mk_worker_rec { my ($parent, @blocks) = @_; return { type => 'assistant', parent_tool_use_id => $parent, message => { content => [@blocks] } } }

# mk_coord_rec_null(@blocks) -- fixbatch item 2 (review M-2), additive.
# The real bp-launch.sh stream-json stream emits `parent_tool_use_id` as
# explicit JSON null on every coordinator record (811/811 measured by
# review) -- `absent` never occurs. mk_coord_rec above omits the key
# entirely, which happens to still pass under `next if defined ...`, but
# exercises a record shape that cannot occur in production. This sibling
# builds the shape that actually occurs: the key present, its Perl value
# undef, which JSON::PP encodes as JSON `null`.
sub mk_coord_rec_null { my (@blocks) = @_; return { type => 'assistant', parent_tool_use_id => undef, message => { content => [@blocks] } } }

sub jline { return $J->encode($_[0]) . "\n" }
sub write_transcript_file {
    my ($path, $recs) = @_;
    write_file($path, join('', map { jline($_) } @$recs));
}

# gen_batch(KIND, NAME, COUNT, %opts) -> LIST of records, one block per record.
sub gen_batch {
    my ($kind, $name, $count, %o) = @_;
    my @out;
    if ($kind eq 'coord') {
        for my $i (1 .. $count) {
            my $cmd = (defined $o{cd_count} && $i <= $o{cd_count}) ? 'cd /somewhere' : 'echo hi';
            push @out, mk_coord_rec(mk_tool_use($name, command => $cmd));
        }
    }
    elsif ($kind eq 'worker') {
        my $parent = $o{parent} // next_tuid();
        for my $i (1 .. $count) {
            push @out, mk_worker_rec($parent, mk_tool_use($name));
        }
    }
    return @out;
}

# gen_transcript( [KIND,NAME,COUNT,%opts], ... ) -> \@records
sub gen_transcript {
    my (@batches) = @_;
    my @recs;
    for my $b (@batches) {
        my ($kind, $name, $count, %o) = @$b;
        push @recs, gen_batch($kind, $name, $count, %o);
    }
    return \@recs;
}

# ---------------------------------------------------------------------------
# NAMED FIXTURES (spec §4 table). Shapes, not bytes, are the contract.
# ---------------------------------------------------------------------------
sub fixture_path_recs   { return @{ gen_transcript(['coord', 'Bash', 704, cd_count => 473], ['coord', 'Task', 3], ['worker', 'Bash', 1561 - 707]) } }
sub fixture_early_recs  { return @{ gen_transcript(['coord', 'Bash', 200], ['coord', 'Task', 3]) } }
sub fixture_prop_recs   { return @{ gen_transcript(['coord', 'Bash', 45], ['coord', 'Read', 45], ['coord', 'Edit', 45], ['coord', 'Grep', 45], ['coord', 'Task', 6]) } }
sub fixture_vol_recs    { return @{ gen_transcript(['coord', 'Bash', 300], ['coord', 'Task', 10]) } }
sub fixture_floor_recs  { return @{ gen_transcript(['coord', 'Bash', 199]) } }
sub fixture_edge_recs   { return @{ gen_transcript(['coord', 'Bash', 200], ['coord', 'Task', 5]) } }
sub fixture_edge_minus1_recs { return @{ gen_transcript(['coord', 'Bash', 199], ['coord', 'Task', 5]) } }
sub fixture_worker_recs { return @{ gen_transcript(['coord', 'Bash', 3], ['worker', 'Bash', 500]) } }

# fixbatch item 2 (review M-1/M-2), additive: an F-PROP-shaped transcript
# whose dispatch blocks are tagged 'Agent', never 'Task' -- the direct
# regression guard for M-1 (the real dispatch tool is serialized as "Agent"
# in every stream-json transcript bp-launch.sh writes; "Task" never
# appears). Before this fixture existed, no fixture in this file exercised
# the 'Agent' name at all, which is how M-1 shipped green.
sub fixture_prop_agent_recs { return @{ gen_transcript(['coord', 'Bash', 45], ['coord', 'Read', 45], ['coord', 'Edit', 45], ['coord', 'Grep', 45], ['coord', 'Agent', 6]) } }

# ===========================================================================
# Mandated strings (spec §2.6, §2.7, §2.9) -- the literal bytes.
# ===========================================================================
my $BANNED_RE = qr/nothing is outstanding|all clear|is done|has finished|checkpoint now/i;
my $EMDASH = "\x{2014}";

sub imbalance_summary {
    my ($s, $d, $r, $m) = @_;
    return "$s of the coordinator's own direct tool calls (Bash, Read, Edit, Grep) are recorded in "
         . "this transcript against $d dispatch(es), a ratio of about $r own calls per dispatch, at "
         . "or above the $m this check is set to notice; this is a pattern observed in what the "
         . "stream recorded, not a judgment that any of that work belonged to a worker.";
}
sub proportional_summary {
    my ($s, $d) = @_;
    return "$s own direct tool calls against $d dispatch(es) were observed, below the ratio this "
         . "check is set to notice; this reflects what the transcript records, not a guarantee that "
         . "every step was dispatched.";
}
my $UNKNOWN_SUMMARY = 'the transcript could not be read, so the ratio of own tool calls to dispatches was not determined.';
sub dispatch_note_readable {
    my ($t) = @_;
    return "$t dispatch records scoped to this blueprint and package are recorded in the dispatch "
         . "log (running or closed); this reflects what is recorded on disk, not a guarantee that "
         . "each one ran to completion.";
}
my $DISPATCH_NOTE_UNREADABLE = 'the dispatch log could not be read, so how many dispatches are recorded on disk was not determined.';

sub hook_line1 {
    my ($s, $b, $r, $e, $g, $d, $ratio, $m) = @_;
    return "[dispatch-discipline] Since this package's last cold launch, your own transcript records "
         . "about $s direct tool calls of your own (Bash $b, Read $r, Edit $e, Grep $g) against $d "
         . "dispatch(es) $EMDASH a ratio of about $ratio own calls per dispatch, at or above the $m "
         . "this check is set to notice. This is an observation, not a verdict, and nothing is blocked.";
}
sub hook_line2 {
    my ($dnote) = @_;
    return "[dispatch-discipline] Dispatch check (bp-dispatch-log.pl, scoped to this blueprint and package): $dnote";
}
sub hook_line3 {
    return '[dispatch-discipline] A ratio this shape can mean substantive package work is being done '
         . 'here instead of dispatched, which coordinator-protocol\'s "Worker dispatch contract" asks '
         . 'you to hand to a worker; it can equally mean a legitimate investigation or validation '
         . 'pass, and this mechanism cannot tell those apart. If a step is in progress, consider '
         . 'whether it belongs to a worker.';
}
sub hook_line4 {
    return '[dispatch-discipline] The counts are read from your own runs transcript, cover only Bash, '
         . 'Read, Edit and Grep, and stop at a scan bound, so they may undercount and are a signal '
         . 'rather than a measurement of everything you did.';
}

# ===========================================================================
# Load bp-dispatch-log.pl as a library for the pure/reader function tests.
# ===========================================================================
my $DL_LOADED = do { local $@; eval { require $DISPATCHLOG }; !$@ };
ok($DL_LOADED, 'bp-dispatch-log.pl requires cleanly as (at least) package BpDispatchLog') or diag($@);

sub has_sub { my ($fq) = @_; no strict 'refs'; return defined &{$fq}; }
sub SC {
    my ($fq, @args) = @_;
    return undef unless has_sub($fq);
    no strict 'refs';
    my $r = eval { &{$fq}(@args) };
    if ($@) { diag("call to $fq died (guarded): $@"); return undef; }
    return $r;
}

# ===========================================================================
# AC1 (B1)
# ===========================================================================
subtest 'AC1: ratio_thresholds() defaults to min_calls=200, min_ratio=40 with no env set (B1)' => sub {
    local %ENV = %CLEAN_ENV;
    my $t = SC('BpDispatchLog::ratio_thresholds');
    ok(ref $t eq 'HASH', 'ratio_thresholds returns a hashref') or diag('missing or wrong shape (expected pre-impl)');
    SKIP: {
        skip 'ratio_thresholds missing/wrong-shape', 2 unless ref $t eq 'HASH';
        is($t->{min_calls}, 200, 'min_calls defaults to 200');
        is($t->{min_ratio}, 40, 'min_ratio defaults to 40');
    }
};

# ===========================================================================
# AC2 (B2)
# ===========================================================================
subtest 'AC2: each env var moves only its own threshold (B2)' => sub {
    {
        local %ENV = (%CLEAN_ENV, BP_DISPATCH_RATIO_MIN_CALLS => '10');
        my $t = SC('BpDispatchLog::ratio_thresholds');
        SKIP: {
            skip 'ratio_thresholds missing', 2 unless ref $t eq 'HASH';
            is($t->{min_calls}, 10, 'BP_DISPATCH_RATIO_MIN_CALLS=10 -> min_calls==10');
            is($t->{min_ratio}, 40, 'min_ratio unaffected, still 40');
        }
    }
    {
        local %ENV = (%CLEAN_ENV, BP_DISPATCH_RATIO_MIN => '2');
        my $t = SC('BpDispatchLog::ratio_thresholds');
        SKIP: {
            skip 'ratio_thresholds missing', 2 unless ref $t eq 'HASH';
            is($t->{min_ratio}, 2, 'BP_DISPATCH_RATIO_MIN=2 -> min_ratio==2');
            is($t->{min_calls}, 200, 'min_calls unaffected, still 200');
        }
    }
};

# ===========================================================================
# AC3 (B3)
# ===========================================================================
subtest 'AC3: malformed env falls back to the default (never 0) and warns on stderr (B3)' => sub {
    for my $bad (qw(abc 0 -5 1.5), '') {
        for my $pair (['BP_DISPATCH_RATIO_MIN_CALLS', 'min_calls', 200, 'min_ratio', 40],
                      ['BP_DISPATCH_RATIO_MIN',       'min_ratio', 40,  'min_calls', 200]) {
            my ($envvar, $key, $default, $other_key, $other_default) = @$pair;
            my @warnings;
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            local %ENV = (%CLEAN_ENV, $envvar => $bad);
            my $t = SC('BpDispatchLog::ratio_thresholds');
            SKIP: {
                skip 'ratio_thresholds missing', 2 unless ref $t eq 'HASH';
                is($t->{$key}, $default, "$envvar='$bad' -> $key falls back to $default (never 0)");
                is($t->{$other_key}, $other_default, "$envvar='$bad': the other key ($other_key) is unaffected");
            }
            ok((grep { /\Q$envvar\E/ } @warnings), "$envvar='$bad': a warning on stderr names the env var")
                or diag(explain(\@warnings));
        }
    }
};

# ===========================================================================
# AC4 (B4) -- THE criterion proving the coordinator/worker separation is real.
# ===========================================================================
subtest 'AC4: scan_transcript_counts on F-WORKER excludes every worker-owned call (B4)' => sub {
    my $path = "$ROOT/scan_worker.jsonl";
    write_transcript_file($path, [fixture_worker_recs()]);
    my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
    ok(ref $c eq 'HASH', 'scan_transcript_counts returns a hashref') or diag('missing/undef (expected pre-impl)');
    SKIP: {
        skip 'scan_transcript_counts missing', 3 unless ref $c eq 'HASH';
        is($c->{self}, 3, 'self == 3 -- none of the 500 worker Bash blocks counted');
        is($c->{bash}, 3, 'bash == 3');
        is($c->{tasks}, 0, 'tasks == 0');
    }
};

# ===========================================================================
# ADDITIVE (fixbatch item 2 / review M-2) -- AC4 re-run against the record
# shape bp-launch.sh actually emits: parent_tool_use_id present with an
# explicit JSON null on every coordinator record, never absent. Kept
# separate from AC4 so AC4's own (still-valid) assertions are untouched.
# ===========================================================================
subtest 'fixbatch additive: scan_transcript_counts excludes worker calls when the coordinator record carries an explicit parent_tool_use_id: null (review M-2)' => sub {
    my $path = "$ROOT/scan_worker_null.jsonl";
    my @recs = (
        mk_coord_rec_null(mk_tool_use('Bash'), mk_tool_use('Bash'), mk_tool_use('Bash')),
        (map { mk_worker_rec('toolu_parent', mk_tool_use('Bash')) } 1 .. 500),
    );
    write_transcript_file($path, \@recs);
    my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
    ok(ref $c eq 'HASH', 'scan_transcript_counts returns a hashref') or diag('missing/undef (expected pre-impl)');
    SKIP: {
        skip 'scan_transcript_counts missing', 2 unless ref $c eq 'HASH';
        is($c->{self}, 3, 'self == 3 -- an explicit parent_tool_use_id: null coordinator record is still recognized as coordinator-owned');
        is($c->{bash}, 3, 'bash == 3 -- none of the 500 worker Bash blocks counted');
    }
};

# ===========================================================================
# AC5 (B5)
# ===========================================================================
subtest 'AC5: per-type counts are exact; only the four named tools total (B5)' => sub {
    my $path = "$ROOT/scan_mixed.jsonl";
    my @rec = ( mk_coord_rec(
        mk_tool_use('Bash'), mk_tool_use('Read'), mk_tool_use('Edit'), mk_tool_use('Grep'),
        mk_tool_use('Task'), mk_tool_use('Write'), mk_tool_use('MultiEdit'), mk_tool_use('Glob'),
    ) );
    write_transcript_file($path, \@rec);
    my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
    SKIP: {
        skip 'scan_transcript_counts missing', 6 unless ref $c eq 'HASH';
        is($c->{bash}, 1, 'bash==1'); is($c->{read}, 1, 'read==1');
        is($c->{edit}, 1, 'edit==1'); is($c->{grep}, 1, 'grep==1');
        is($c->{self}, 4, 'self==4 (Write/MultiEdit/Glob uncounted)');
        is($c->{tasks}, 1, 'tasks==1');
    }
};

# ===========================================================================
# AC6 (B6)
# ===========================================================================
subtest 'AC6: dedup by tool_use id; id-less blocks counted once each by position (B6)' => sub {
    {
        my $path = "$ROOT/scan_dedup_same.jsonl";
        my $line = jline(mk_coord_rec(mk_tool_use('Bash', id => 'toolu_dup')));
        write_file($path, $line x 3);
        my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
        SKIP: { skip 'missing', 1 unless ref $c eq 'HASH'; is($c->{self}, 1, 'same id repeated 3x -> self==1'); }
    }
    {
        my $path = "$ROOT/scan_dedup_diff.jsonl";
        write_transcript_file($path, [ mk_coord_rec(mk_tool_use('Bash', id => 'a'), mk_tool_use('Bash', id => 'b')) ]);
        my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
        SKIP: { skip 'missing', 1 unless ref $c eq 'HASH'; is($c->{self}, 2, 'two distinct ids -> self==2'); }
    }
    {
        my $path = "$ROOT/scan_dedup_noid.jsonl";
        write_transcript_file($path, [ mk_coord_rec(mk_tool_use('Bash', id => undef), mk_tool_use('Bash', id => undef)) ]);
        my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
        SKIP: { skip 'missing', 1 unless ref $c eq 'HASH'; is($c->{self}, 2, 'two id-less blocks counted once each by position -> self==2'); }
    }
};

# ===========================================================================
# AC7 (B7)
# ===========================================================================
subtest 'AC7: bounded scan sets truncated and stops; an over-long line is skipped undecoded (B7)' => sub {
    {
        my $path = "$ROOT/scan_bounded.jsonl";
        write_transcript_file($path, [ map { mk_coord_rec(mk_tool_use('Bash')) } (1 .. 50) ]);
        my $c = SC('BpDispatchLog::scan_transcript_counts', $path, 10);
        SKIP: {
            skip 'missing', 2 unless ref $c eq 'HASH';
            is($c->{truncated}, 1, 'truncated==1 with max_lines=10 on a 50-line transcript');
            is($c->{bash}, 10, 'only the first 10 examined lines are counted');
        }
    }
    {
        my $path = "$ROOT/scan_longline.jsonl";
        my $huge = 'x' x (1024 * 1024 + 10);
        my $badline = qq({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"huge1","input":{"pad":"$huge"}}]}}) . "\n";
        my $goodline = jline(mk_coord_rec(mk_tool_use('Bash', id => 'ok1')));
        write_file($path, $badline . $goodline);
        my $c = SC('BpDispatchLog::scan_transcript_counts', $path);
        SKIP: {
            skip 'missing', 2 unless ref $c eq 'HASH';
            is($c->{bash}, 1, 'the over-long line contributes nothing; only the second line counts');
            is($c->{truncated}, 0, 'not truncated (well under the line cap)');
        }
    }
};

# ===========================================================================
# AC8 (B8)
# ===========================================================================
subtest 'AC8: undef/empty/nonexistent -> undef, never zero; an existing empty file -> all-zero hash (B8)' => sub {
    for my $bad (undef, '', "$ROOT/does-not-exist-$$.jsonl") {
        SKIP: {
            skip 'scan_transcript_counts missing', 1 unless has_sub('BpDispatchLog::scan_transcript_counts');
            my $c = SC('BpDispatchLog::scan_transcript_counts', $bad);
            ok(!defined $c, 'scan_transcript_counts(' . (defined $bad ? "'$bad'" : 'undef') . ') is undef, not a zeroed hash');
        }
    }
    my $empty = "$ROOT/scan_empty.jsonl";
    write_file($empty, '');
    my $c = SC('BpDispatchLog::scan_transcript_counts', $empty);
    SKIP: {
        skip 'missing', 1 unless ref $c eq 'HASH';
        is_deeply($c, { bash => 0, read => 0, edit => 0, grep => 0, self => 0, tasks => 0, lines => 0, truncated => 0 },
            'an existing empty file returns an all-zero counts hash, not undef');
    }
};

# ===========================================================================
# AC9 (B9)
# ===========================================================================
subtest 'AC9: garbage/truncated/wrong-shaped lines never die; surrounding counts are intact (B9)' => sub {
    my $path = "$ROOT/scan_garbage.jsonl";
    my @lines = (
        jline(mk_coord_rec(mk_tool_use('Bash', id => 'clean1'))),
        qq(garbage not json "name":"Bash" more garbage\n),
        qq({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"trunc1"\n),
        qq({"type":"assistant","message":{"content":"whatever"},"name":"Bash"}\n),
        qq({"type":"assistant","message":{"content":["Bash-ish-scalar"]},"name":"Bash"}\n),
        qq({"type":"assistant","message":{"content":[{"type":"tool_use","name":{"nested":"y"}}]},"name":"Bash"}\n),
        jline(mk_coord_rec(mk_tool_use('Bash', id => 'clean2'))),
    );
    write_file($path, join('', @lines));
    my $c = eval { SC('BpDispatchLog::scan_transcript_counts', $path) };
    ok(!$@, 'scan_transcript_counts does not die on any garbage/edge-shaped line') or diag($@);
    SKIP: {
        skip 'scan_transcript_counts missing', 3 unless ref $c eq 'HASH';
        is($c->{self}, 2, 'only the two clean lines count -> self==2');
        is($c->{bash}, 2, 'bash==2');
        is($c->{lines}, 7, 'all 7 lines were examined');
    }
};

# ===========================================================================
# AC10 (B10)
# ===========================================================================
subtest 'AC10: ratio_verdict is exact at both boundaries and uses the larger denominator (B10)' => sub {
    my $thresh = { min_calls => 200, min_ratio => 40 };
    my @rows = (
        [{ self => 200, tasks => 3 }, undef, 3,  3, '66.7',  'imbalance',    'self=200,tasks=3,recorded=undef'],
        [{ self => 200, tasks => 3 }, 10,    10, 10, '20.0', 'proportional', 'self=200,tasks=3,recorded=10 (the larger denominator wins)'],
        [{ self => 200, tasks => 5 }, undef, 5,  5, '40.0',  'imbalance',    'self=200,tasks=5 (exact boundary fires)'],
        [{ self => 199, tasks => 0 }, undef, 0,  1, '199.0', 'proportional', 'self=199,tasks=0 (below the floor)'],
        [{ self => 240, tasks => 0 }, undef, 0,  1, '240.0', 'imbalance',    'self=240,tasks=0 (no division by zero)'],
    );
    for my $r (@rows) {
        my ($counts, $recorded, $den, $eff, $ratio_str, $verdict, $label) = @$r;
        my $v = SC('BpDispatchLog::ratio_verdict', $counts, $recorded, $thresh);
        SKIP: {
            skip 'ratio_verdict missing', 4 unless ref $v eq 'HASH';
            is($v->{verdict}, $verdict, "$label: verdict");
            is($v->{denominator}, $den, "$label: denominator");
            is($v->{effective}, $eff, "$label: effective");
            is(sprintf('%.1f', $v->{ratio}), $ratio_str, "$label: ratio");
        }
    }
    my $v2 = SC('BpDispatchLog::ratio_verdict', 'not a hashref', undef, $thresh);
    SKIP: { skip 'ratio_verdict missing', 1 unless ref $v2 eq 'HASH'; is($v2->{verdict}, 'unknown', 'a non-hashref counts arg -> verdict unknown'); }
};

# ===========================================================================
# AC11 (B11)
# ===========================================================================
subtest 'AC11: dispatch_totals counts every status, scoped, and handles absent/unreadable stores (B11)' => sub {
    {
        my $root = tempdir(CLEANUP => 1);
        my $logdir = logdir_of($root);
        plant_dispatch_rec($logdir, 'r1', blueprint => 'b', package => 'p', status => 'running');
        plant_dispatch_rec($logdir, 'r2', blueprint => 'b', package => 'p', status => 'running');
        plant_dispatch_rec($logdir, 'r3', blueprint => 'b', package => 'p', status => 'done');
        plant_dispatch_rec($logdir, 'r4', blueprint => 'b', package => 'p', status => 'done');
        plant_dispatch_rec($logdir, 'r5', blueprint => 'b', package => 'p', status => 'done');
        plant_dispatch_rec($logdir, 'q1', blueprint => 'b', package => 'q', status => 'running');
        plant_dispatch_rec($logdir, 'q2', blueprint => 'b', package => 'q', status => 'done');
        plant_dispatch_rec($logdir, 'q3', blueprint => 'b', package => 'q', status => 'done');
        plant_dispatch_rec($logdir, 'nopkg', blueprint => 'b', status => 'done'); # missing package field

        my $t = SC('BpDispatchLog::dispatch_totals', $root, { blueprint => 'b', package => 'p' });
        SKIP: {
            skip 'dispatch_totals missing', 3 unless ref $t eq 'HASH';
            is($t->{total}, 5, 'scoped total==5');
            is($t->{running}, 2, 'scoped running==2');
            is($t->{closed}, 3, 'scoped closed==3');
        }
        my $t_all = SC('BpDispatchLog::dispatch_totals', $root, {});
        SKIP: { skip 'dispatch_totals missing', 1 unless ref $t_all eq 'HASH'; is($t_all->{total}, 9, 'no criteria -> total==9'); }
        my $t_pkg = SC('BpDispatchLog::dispatch_totals', $root, { package => 'p' });
        SKIP: {
            skip 'dispatch_totals missing', 1 unless ref $t_pkg eq 'HASH';
            is($t_pkg->{total}, 5, 'a record missing package never matches a supplied package criterion (nopkg excluded)');
        }
    }
    {
        my $root = tempdir(CLEANUP => 1); # store dir never created
        my $absent_dir = logdir_of($root);
        my $t = SC('BpDispatchLog::dispatch_totals', $root, {});
        SKIP: {
            skip 'dispatch_totals missing', 3 unless ref $t eq 'HASH';
            is($t->{readable}, 1, 'absent store -> readable=>1');
            is($t->{total}, 0, 'absent store -> total==0');
            ok(!-d $absent_dir, 'a query never creates the store directory');
        }
    }
    {
        my $root = tempdir(CLEANUP => 1);
        write_file(logdir_of($root), 'a plain file, not a directory');
        my $t = SC('BpDispatchLog::dispatch_totals', $root, {});
        SKIP: {
            skip 'dispatch_totals missing', 2 unless ref $t eq 'HASH';
            is($t->{readable}, 0, 'unreadable store -> readable=>0');
            ok(!defined $t->{total}, 'unreadable store -> total is undef');
        }
    }
};

# ===========================================================================
# AC12 (B12)
# ===========================================================================
subtest 'AC12: ratio on F-PATH prints verdict: imbalance with the pathological numbers (B12)' => sub {
    my $transcript = "$ROOT/f_path.jsonl";
    write_transcript_file($transcript, [fixture_path_recs()]);
    my $root = tempdir(CLEANUP => 1); # empty store
    my ($rc, $out, $err) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
    is($rc, 0, 'exit 0');
    like($out, qr/^self_tool_calls: 704$/m, 'self_tool_calls: 704');
    like($out, qr/^dispatches_transcript: 3$/m, 'dispatches_transcript: 3');
    like($out, qr/^dispatches: 3$/m, 'dispatches: 3');
    like($out, qr/^ratio: 234\.7$/m, 'ratio: 234.7');
    like($out, qr/^verdict: imbalance$/m, 'verdict: imbalance');
    my $expected_summary = imbalance_summary(704, 3, '234.7', 40);
    ok(index($out, "summary: $expected_summary") >= 0, 'the imbalance summary is present byte for byte') or diag($out);
};

# ===========================================================================
# AC13 (B13)
# ===========================================================================
subtest 'AC13: ratio on F-PROP, F-VOL and F-FLOOR each prints verdict: proportional (B13)' => sub {
    my @cases = (
        ['F-PROP',  [fixture_prop_recs()],  180, 6,  '30.0'],
        ['F-VOL',   [fixture_vol_recs()],   300, 10, '30.0'],
        ['F-FLOOR', [fixture_floor_recs()], 199, 0,  '199.0'],
    );
    for my $c (@cases) {
        my ($label, $recs, $self, $disp, $ratio) = @$c;
        my $transcript = "$ROOT/f_" . lc($label =~ s/-/_/gr) . ".jsonl";
        write_transcript_file($transcript, $recs);
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out, $err) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
        is($rc, 0, "$label: exit 0");
        like($out, qr/^self_tool_calls: $self$/m, "$label: self_tool_calls: $self");
        like($out, qr/^verdict: proportional$/m, "$label: verdict: proportional");
        my $expected_summary = proportional_summary($self, $disp);
        ok(index($out, "summary: $expected_summary") >= 0, "$label: the proportional summary is present byte for byte") or diag($out);
    }
};

# ===========================================================================
# ADDITIVE (fixbatch item 2 / review M-1, M-2) -- 'Agent'-tagged dispatch
# blocks direct regression guard. Never present in the original 29
# assertions; kept separate from AC13 rather than folded into it so the
# original assertions stay byte-for-byte untouched.
# ===========================================================================
subtest "fixbatch additive: ratio on an 'Agent'-tagged F-PROP-shaped transcript prints verdict: proportional (review M-1/M-2)" => sub {
    my $transcript = "$ROOT/f_prop_agent.jsonl";
    write_transcript_file($transcript, [fixture_prop_agent_recs()]);
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out, $err) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
    is($rc, 0, 'exit 0');
    like($out, qr/^self_tool_calls: 180$/m, 'self_tool_calls: 180');
    like($out, qr/^dispatches_transcript: 6$/m, "dispatches_transcript: 6 -- 'Agent' blocks are counted as dispatches, not 'Task' alone");
    like($out, qr/^dispatches: 6$/m, 'dispatches: 6');
    like($out, qr/^ratio: 30\.0$/m, 'ratio: 30.0');
    like($out, qr/^verdict: proportional$/m, 'verdict: proportional -- NOT imbalance, which is what M-1 shipped as')
        or diag($out);
    my $expected_summary = proportional_summary(180, 6);
    ok(index($out, "summary: $expected_summary") >= 0, 'the proportional summary is present byte for byte') or diag($out);
};

# ===========================================================================
# AC14 (B14)
# ===========================================================================
subtest 'AC14: ratio on F-EARLY fires early -- imbalance at ~28% of the measured session (B14)' => sub {
    my $transcript = "$ROOT/f_early.jsonl";
    write_transcript_file($transcript, [fixture_early_recs()]);
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
    is($rc, 0, 'exit 0');
    like($out, qr/^verdict: imbalance$/m, 'verdict: imbalance');
    like($out, qr/^ratio: 66\.7$/m, 'ratio: 66.7');
};

# ===========================================================================
# AC15 (B10, B13)
# ===========================================================================
subtest 'AC15: ratio on F-EDGE fires exactly at the boundary; one call fewer does not (B10, B13)' => sub {
    {
        my $transcript = "$ROOT/f_edge.jsonl";
        write_transcript_file($transcript, [fixture_edge_recs()]);
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
        is($rc, 0, 'exit 0');
        like($out, qr/^verdict: imbalance$/m, 'F-EDGE (200 self, 5 Task): imbalance -- the >= boundary fires');
    }
    {
        my $transcript = "$ROOT/f_edge_minus1.jsonl";
        write_transcript_file($transcript, [fixture_edge_minus1_recs()]);
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
        is($rc, 0, 'exit 0');
        like($out, qr/^verdict: proportional$/m, 'one call fewer (199 self, 5 Task): proportional');
    }
};

# ===========================================================================
# AC16 (B15)
# ===========================================================================
subtest 'AC16: ratio degrades to unknown, never to zero; an unreadable store degrades dispatches_recorded (B15)' => sub {
    {
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out, $err) = run_cli('ratio', '--transcript', "$ROOT/does-not-exist.jsonl", '--root', fwd($root));
        is($rc, 0, 'missing transcript: exit 0');
        for my $k (qw(self_tool_calls self_bash_calls self_read_calls self_edit_calls self_grep_calls dispatches_transcript ratio scan_truncated)) {
            like($out, qr/^\Q$k\E: unknown$/m, "missing transcript: $k: unknown");
        }
        like($out, qr/^verdict: unknown$/m, 'missing transcript: verdict: unknown');
        ok(index($out, "summary: $UNKNOWN_SUMMARY") >= 0, 'missing transcript: the unknown summary is byte-exact') or diag($out);
        like($out, qr/^min_calls: 200$/m, 'min_calls still printed');
        like($out, qr/^min_ratio: 40$/m, 'min_ratio still printed');
    }
    {
        my $dir_as_transcript = tempdir(CLEANUP => 1);
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out) = run_cli('ratio', '--transcript', fwd($dir_as_transcript), '--root', fwd($root));
        is($rc, 0, '--transcript naming a directory: exit 0');
        like($out, qr/^verdict: unknown$/m, '--transcript naming a directory: verdict: unknown');
    }
    {
        my $transcript = "$ROOT/f_prop_for_unreadable_store.jsonl";
        write_transcript_file($transcript, [fixture_prop_recs()]);
        my $root = tempdir(CLEANUP => 1);
        write_file(logdir_of($root), 'a plain file, not a directory');
        my ($rc, $out) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
        is($rc, 0, 'unreadable store: exit 0');
        like($out, qr/^dispatches_recorded: unknown$/m, 'unreadable store: dispatches_recorded: unknown');
        ok(index($out, "dispatch_note: $DISPATCH_NOTE_UNREADABLE") >= 0, 'unreadable store: could-not-be-read dispatch_note, byte-exact') or diag($out);
        like($out, qr/^verdict: proportional$/m, 'unreadable store: verdict is still computed from the transcript alone');
    }
};

# ===========================================================================
# AC17 (B16)
# ===========================================================================
subtest 'AC17: ratio usage surface -- missing/empty --transcript, --transcript elsewhere, --role, never on stdout (B16)' => sub {
    {
        my ($rc, $out, $err) = run_cli('ratio');
        is($rc, 2, 'no --transcript: exit 2');
        like($err, qr/^bp-dispatch-log: usage error:/m, 'no --transcript: usage error on stderr');
        is($out, '', 'no --transcript: stdout empty');
    }
    {
        my ($rc, $out, $err) = run_cli('ratio', '--transcript', '');
        is($rc, 2, 'empty --transcript: exit 2');
        like($err, qr/^bp-dispatch-log: usage error:/m, 'empty --transcript: usage error on stderr');
        is($out, '', 'empty --transcript: stdout empty');
    }
    for my $othercmd (qw(start list finish prune elapsed resolve outstanding)) {
        my ($rc, $out, $err) = run_cli($othercmd, '--transcript', '/some/path');
        is($rc, 2, "--transcript on $othercmd: exit 2");
    }
    {
        my ($rc, $out, $err) = run_cli('ratio', '--transcript', "$ROOT/x.jsonl", '--role', 'coordinator');
        is($rc, 2, '--role on ratio: exit 2');
    }
    {
        my $marker = 'marker-XYZ99182-should-never-appear';
        my $transcript = "$ROOT/$marker.jsonl";
        write_transcript_file($transcript, [fixture_prop_recs()]);
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out) = run_cli('ratio', '--transcript', $transcript, '--root', fwd($root));
        unlike($out, qr/\Q$marker\E/, 'the --transcript value never appears on stdout');
    }
};

# ===========================================================================
# AC18 (B17)
# ===========================================================================
subtest "AC18: outstanding's 5 count lines unchanged; a smoke pass over every other verb (B17)" => sub {
    my $now = 1_700_000_000;
    {
        my $root = tempdir(CLEANUP => 1);
        plant_dispatch_rec(logdir_of($root), 'r1', worker_type => 'bp-reviewer', status => 'running', started_at => $now - 10, budget_seconds => 1800);
        my ($rc, $out) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'outstanding', '--root', fwd($root), '--now', $now);
        is($rc, 1, 'outstanding: exit 1');
        for my $k (qw(outstanding_count live_count stale_count unevaluable_count unreadable_count)) {
            like($out, qr/^$k: /m, "outstanding: $k line present");
        }
        ok(index($out, 'summary: 1 dispatch appears to be outstanding (recorded as running, not yet resolved); '
            . 'this reflects what is recorded on disk, not a guarantee that it is still alive.') >= 0,
            'outstanding: the one-dispatch summary, byte-exact');
    }
    {
        my $root = tempdir(CLEANUP => 1);
        my ($rc, $out) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'start', '--id', 'sk1', '--worker-type', 'bp-reviewer', '--root', fwd($root), '--now', $now);
        is($rc, 0, 'start: exit 0');
        like($out, qr/^started sk1 \(worker_type=bp-reviewer budget_seconds=1800\)$/m, 'start: unchanged output shape');

        my ($rc2, $out2) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'elapsed', '--id', 'sk1', '--root', fwd($root), '--now', $now + 5);
        is($rc2, 0, 'elapsed: exit 0');
        like($out2, qr/^elapsed_seconds: 5$/m, 'elapsed: unchanged output shape');

        my ($rc3, $out3) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'list', '--root', fwd($root), '--now', $now + 5);
        is($rc3, 0, 'list: exit 0');
        like($out3, qr/^id: sk1 worker_type: bp-reviewer/m, 'list: unchanged output shape');

        my ($rc4, $out4) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'finish', '--id', 'sk1', '--status', 'done', '--root', fwd($root), '--now', $now + 10);
        is($rc4, 0, 'finish: exit 0');
        like($out4, qr/^finished sk1 \(status=done duration_seconds=10\)$/m, 'finish: unchanged output shape');

        my ($rc5, $out5) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'prune', '--root', fwd($root), '--now', $now + 10);
        is($rc5, 0, 'prune: exit 0');
        like($out5, qr/^scanned: /m, 'prune: unchanged output shape');

        my ($rc6, $out6) = run_cli({ CCPRAXIS_DISPATCH_LOG_TEST_NOW => '1' }, 'resolve', '--worker-type', 'bp-reviewer', '--status', 'done', '--root', fwd($root), '--now', $now + 11);
        is($rc6, 5, 'resolve on an all-closed store: exit 5, NO-MATCH');
        like($out6, qr/^NO-MATCH:/m, 'resolve: unchanged output shape');
    }
};

# ===========================================================================
# AC19 (B18)
# ===========================================================================
subtest 'AC19: the hook emits on F-PATH -- additionalContext is the four §2.7 lines, byte for byte (B18)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
    my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
    is($exit, 0, 'exit 0');
    is($err, '', 'stderr empty');
    my $doc = eval { $J->decode($out) };
    ok(ref $doc eq 'HASH', 'stdout parses as a single JSON object') or diag("stdout was: [$out]");
    SKIP: {
        skip 'stdout did not parse as JSON (hook missing/not implemented)', 2 unless ref $doc eq 'HASH';
        is($doc->{hookSpecificOutput}{hookEventName}, 'PostToolUse', 'hookEventName is PostToolUse');
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        my $dnote = dispatch_note_readable(0); # empty store
        my $expected = join("\n",
            hook_line1(704, 704, 0, 0, 0, 3, '234.7', 40),
            hook_line2($dnote),
            hook_line3(),
            hook_line4(),
        );
        is($ctx, $expected, 'additionalContext is exactly lines 1-4, byte for byte') or diag("got: [$ctx]");
    }
    ok(defined read_last_check($bp_dir, 'p03'), 'runs/p03.dispatch-discipline now carries last_check:');
};

# ===========================================================================
# AC20 (B19)
# ===========================================================================
subtest 'AC20: the hook is silent on F-PROP; only the state file is touched under runs/ (B19)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_prop_recs()]);
    plant_dispatch_rec(logdir_of($proj), 'r1', blueprint => $env->{BP_BLUEPRINT}, package => $env->{BP_PACKAGE}, status => 'running');
    for (2 .. 6) { plant_dispatch_rec(logdir_of($proj), "r$_", blueprint => $env->{BP_BLUEPRINT}, package => $env->{BP_PACKAGE}, status => 'done'); }
    my $transcript_before = read_file("$bp_dir/runs/p03.jsonl");
    my $runs_before = runs_snapshot($bp_dir);

    my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
    is($exit, 0, 'exit 0');
    is(length($out), 0, 'stdout is exactly 0 bytes');
    is(length($err), 0, 'stderr is exactly 0 bytes');
    is(read_file("$bp_dir/runs/p03.jsonl"), $transcript_before, 'the transcript is byte-identical afterwards');

    my $runs_after = runs_snapshot($bp_dir);
    my @new_files = sort grep { !exists $runs_before->{$_} } keys %$runs_after;
    is_deeply(\@new_files, [fwd(state_path($bp_dir, 'p03'))], 'the only file created under $BP_DIR/runs is the state file')
        or diag(explain(\@new_files));

    SKIP: {
        skip 'hook source not readable yet', 1 unless -f $NUDGE;
        my $src = read_file($NUDGE) // '';
        unlike($src, qr/tool_input\.command/, 'the hook source never reads tool_input.command (D-E)');
    }
};

# ===========================================================================
# AC21 (B20)
# ===========================================================================
subtest 'AC21: rate limiting -- the gate precedes the probe (B20)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        my ($e1, $out1) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($e1, 0, 'first fire: exit 0');
        ok(length($out1) > 0, 'first fire: emits (non-empty stdout)');
        my $lc1 = read_last_check($bp_dir, 'p03');
        ok(defined $lc1, 'first fire: last_check recorded');

        my ($e2, $out2, $err2) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($e2, 0, 'second fire (immediately after): exit 0');
        is($out2, '', 'second fire within the default interval: suppressed (empty stdout)');
        is($err2, '', 'second fire within the default interval: no stderr');
        is(read_last_check($bp_dir, 'p03'), $lc1, 'second fire: last_check unchanged');
    }
    {
        # the gate precedes the probe: make bp-dispatch-log.pl unrunnable BETWEEN
        # the two fires and confirm the second (suppressed) fire never touches it.
        my $stub = stub_hook_tree();
        SKIP: {
            skip 'hook/lib/bp-dispatch-log.pl not readable yet', 5 unless defined $stub;
            my ($env, $bp_dir, $proj) = fresh_env();
            write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
            my ($e1, $out1) = run_hook($stub, post_payload('Bash'), %$env);
            is($e1, 0, 'stub, first fire: exit 0');
            ok(length($out1) > 0, 'stub, first fire: emits');
            my $lc1 = read_last_check($bp_dir, 'p03');
            (my $stub_root = $stub) =~ s{/hooks/[^/]+\z}{};
            unlink("$stub_root/scripts/bp-dispatch-log.pl");
            my ($e2, $out2, $err2) = run_hook($stub, post_payload('Bash'), %$env);
            is($e2, 0, 'stub, second fire with the script removed: exit 0');
            is($out2 . $err2, '', 'stub, second fire with the script removed: no output at all (the probe never ran)');
            is(read_last_check($bp_dir, 'p03'), $lc1, 'stub, second fire: last_check unchanged (the gate ran first)');
        }
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(BP_DISPATCH_NUDGE_INTERVAL_SECS => '1');
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        write_file(state_path($bp_dir, 'p03'), 'last_check: ' . (time - 10) . "\n");
        my ($exit, $out) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'past a 1s interval: exit 0');
        ok(length($out) > 0, 'past a 1s interval with a stale last_check: re-probes and emits again');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        write_file(state_path($bp_dir, 'p03'), 'last_check: ' . (time + 100_000) . "\n"); # future
        my ($exit, $out) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'a future last_check: exit 0');
        ok(length($out) > 0, 'a future last_check does NOT suppress -- the hook fails toward speaking');
    }
};

# ===========================================================================
# AC22 (B21)
# ===========================================================================
subtest 'AC22: the nudge never asserts; every emitted line is single-line; hedge words present (B21)' => sub {
    my ($env, $bp_dir, $proj) = fresh_env();
    write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
    my ($exit, $out) = run_hook($NUDGE, post_payload('Bash'), %$env);
    my $doc = eval { $J->decode($out) };
    ok(ref $doc eq 'HASH', 'fixture sanity: at least one real emission was captured') or diag("stdout was: [$out]");
    SKIP: {
        skip 'no JSON emitted yet (hook missing/not implemented)', 5 unless ref $doc eq 'HASH';
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        unlike($ctx, $BANNED_RE, 'no banned phrase anywhere in additionalContext');
        my @lines = split /\n/, $ctx;
        is(scalar(@lines), 4, 'exactly four lines');
        my $blank = grep { /\A\s*\z/ } @lines;
        is($blank, 0, 'no blank line (would indicate a broken join)');
        like($ctx, qr/not a verdict/, 'contains "not a verdict"');
        like($ctx, qr/cannot tell those apart/, 'contains "cannot tell those apart"');
    }
};

# ===========================================================================
# AC23 (B22)
# ===========================================================================
subtest 'AC23: fail-open / stand-aside conditions -- 0 bytes stdout, exit 0; pre-probe cases write no state file (B22)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        delete $env->{BP_LEDGER};
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'BP_LEDGER unset: exit 0');
        is($out . $err, '', 'BP_LEDGER unset: no output');
        ok(!-f state_path($bp_dir, 'p03'), 'BP_LEDGER unset: no state file written');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(BP_ROLE => 'judge');
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'BP_ROLE=judge: exit 0');
        is($out . $err, '', 'BP_ROLE=judge: no output');
        ok(!-f state_path($bp_dir, 'p03'), 'BP_ROLE=judge: no state file written');
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env(PATH => path_without('perl'));
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'no perl on PATH: exit 0 (fail open)');
        is($out . $err, '', 'no perl on PATH: no output at all');
        ok(!-f state_path($bp_dir, 'p03'), 'no perl on PATH: no state file written');
    }
    for my $bad_pkg ('', '*/*', '.', '..') {
        my ($env, $bp_dir, $proj) = fresh_env(BP_PACKAGE => $bad_pkg);
        my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, "BP_PACKAGE='$bad_pkg': exit 0");
        is($out . $err, '', "BP_PACKAGE='$bad_pkg': no output");
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        # transcript deliberately absent
        my ($exit, $out, $err) = run_hook($NUDGE, post_payload('Bash'), %$env);
        is($exit, 0, 'missing transcript: exit 0');
        is($out . $err, '', 'missing transcript: no output');
        ok(!-f state_path($bp_dir, 'p03'), 'missing transcript: no state file written');
    }
    {
        my $stub = stub_hook_tree(no_dispatchlog => 1);
        SKIP: {
            skip 'hook/lib not readable yet', 3 unless defined $stub;
            my ($env, $bp_dir, $proj) = fresh_env();
            write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
            my ($exit, $out, $err) = run_hook($stub, post_payload('Bash'), %$env);
            is($exit, 0, 'missing bp-dispatch-log.pl: exit 0');
            is($out . $err, '', 'missing bp-dispatch-log.pl: no output');
            ok(!-f state_path($bp_dir, 'p03'), 'missing bp-dispatch-log.pl: no state file written');
        }
    }
    for my $case (
        ['a probe printing verdict: unknown', "#!/usr/bin/env perl\nprint \"verdict: unknown\\n\";\n"],
        ['a probe printing nothing',          "#!/usr/bin/env perl\n"],
        ['a probe printing garbage',          "#!/usr/bin/env perl\nprint \"asdkjhasd not key value\\n\";\n"],
    ) {
        my ($label, $fake) = @$case;
        my $stub = stub_hook_tree(fake_dispatchlog => $fake);
        SKIP: {
            skip 'hook/lib not readable yet', 2 unless defined $stub;
            my ($env, $bp_dir, $proj) = fresh_env();
            write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
            my ($exit, $out, $err) = run_hook($stub, post_payload('Bash'), %$env);
            is($exit, 0, "$label: exit 0");
            is($out . $err, '', "$label: no output");
        }
    }
};

# ===========================================================================
# AC24 (B23)
# ===========================================================================
subtest 'AC24: line 2 quotes the probe dispatch_note verbatim; --blueprint and --package are passed (B23)' => sub {
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        plant_dispatch_rec(logdir_of($proj), 'a1', blueprint => $env->{BP_BLUEPRINT}, package => $env->{BP_PACKAGE}, status => 'running');
        plant_dispatch_rec(logdir_of($proj), 'a2', blueprint => $env->{BP_BLUEPRINT}, package => $env->{BP_PACKAGE}, status => 'done');
        my ($exit, $out) = run_hook($NUDGE, post_payload('Bash'), %$env);
        my $doc = eval { $J->decode($out) };
        my $ctx = (ref $doc eq 'HASH') ? ($doc->{hookSpecificOutput}{additionalContext} // '') : '';
        my $dnote = dispatch_note_readable(2);
        like($ctx, qr/\Q$dnote\E$/m, 'line 2 ends with the store-readable dispatch_note carrying 2') or diag("ctx: [$ctx]");
    }
    {
        my ($env, $bp_dir, $proj) = fresh_env();
        write_transcript_file("$bp_dir/runs/p03.jsonl", [fixture_path_recs()]);
        write_file(logdir_of($proj), 'a plain file, not a directory');
        my ($exit, $out) = run_hook($NUDGE, post_payload('Bash'), %$env);
        my $doc = eval { $J->decode($out) };
        my $ctx = (ref $doc eq 'HASH') ? ($doc->{hookSpecificOutput}{additionalContext} // '') : '';
        like($ctx, qr/\Q$DISPATCH_NOTE_UNREADABLE\E$/m, 'line 2 ends with the could-not-be-read sentence when the store is unreadable') or diag("ctx: [$ctx]");
    }
    SKIP: {
        skip 'hook source not readable yet', 2 unless -f $NUDGE;
        my $src = read_file($NUDGE) // '';
        like($src, qr/ratio\b[^\n]*--blueprint/, 'the hook source passes --blueprint on the probe invocation') or diag($src);
        like($src, qr/ratio\b[^\n]*--package|--blueprint[^\n]*--package/, 'the hook source passes --package too') or diag($src);
    }
};

# ===========================================================================
# AC25 -- static syntax checks.
# ===========================================================================
subtest 'AC25: bash -n on dispatch-discipline-nudge.sh; perl -c on bp-dispatch-log.pl' => sub {
    SKIP: {
        skip 'dispatch-discipline-nudge.sh does not exist yet', 1 unless -f $NUDGE;
        my $out = `bash -n "$NUDGE" 2>&1`;
        is($? >> 8, 0, 'bash -n dispatch-discipline-nudge.sh succeeds') or diag($out);
    }
    my $out = `perl -c "$DISPATCHLOG" 2>&1`;
    is($? >> 8, 0, 'perl -c bp-dispatch-log.pl succeeds') or diag($out);
};

# ===========================================================================
# AC26 (B24) -- hooks.json registration.
# ===========================================================================
subtest 'AC26: hooks.json registers the new PostToolUse:Bash|Read|Edit|Grep block; existing blocks unchanged (B24)' => sub {
    my $raw = read_file($HOOKS_JSON);
    ok(defined $raw, 'hooks.json is readable');
    my $j = eval { JSON::PP->new->decode($raw) };
    ok(ref $j eq 'HASH', 'hooks.json parses as JSON') or diag($@);
    SKIP: {
        skip 'hooks.json did not parse', 6 unless ref $j eq 'HASH';
        my @post = @{ $j->{hooks}{PostToolUse} || [] };
        my @matching = grep {
            my $b = $_;
            ($b->{matcher} // '') eq 'Bash|Read|Edit|Grep'
            && grep { ($_->{command} // '') =~ /dispatch-discipline-nudge\.sh/ } @{ $b->{hooks} || [] }
        } @post;
        ok(scalar(@matching) >= 1, 'dispatch-discipline-nudge.sh appears in a PostToolUse block with matcher "Bash|Read|Edit|Grep"');

        my @task_blocks = grep { ($_->{matcher} // '') eq 'Task' } @post;
        my ($log_block) = grep { grep { ($_->{command} // '') =~ /log-dispatch\.sh/ } @{ $_->{hooks} || [] } } @task_blocks;
        ok(defined $log_block, 'a PostToolUse:Task block containing log-dispatch.sh exists');
        SKIP: {
            skip 'no log-dispatch.sh block found', 1 unless defined $log_block;
            my @cmds = map { $_->{command} // '' } @{ $log_block->{hooks} || [] };
            is_deeply(\@cmds, ['bash "${CLAUDE_PLUGIN_ROOT}/hooks/log-dispatch.sh"'],
                "the log-dispatch.sh block's command list is still exactly [log-dispatch.sh] (pinned by three other test files)")
                or diag(explain(\@cmds));
        }
        my ($track_block) = grep { grep { ($_->{command} // '') =~ /track-dispatch\.sh/ } @{ $_->{hooks} || [] } } @task_blocks;
        ok(defined $track_block, 'the PostToolUse:Task block containing track-dispatch.sh still exists, unmodified');
        my ($agent_block) = grep { ($_->{matcher} // '') eq 'Task|Agent' } @post;
        ok(defined $agent_block, 'the PostToolUse:Task|Agent block still exists, unmodified');
        my ($ctxguide_block) = grep { ($_->{matcher} // '') eq 'Task|Bash' } @post;
        ok(defined $ctxguide_block, 'the PostToolUse:Task|Bash (context-ceiling-guidance.sh) block still exists, unmodified');
    }
};

# ===========================================================================
# AC27 (B25) -- SKILL.md treatment.
# ===========================================================================
subtest 'AC27: SKILL.md -- :605 kept byte-identical, a following bullet carries the mandated literals (B25)' => sub {
    my $LINE605 = q{- You may make small glue edits inside your write set yourself (wiring an export, a one-line fix during validation). Anything resembling a step belongs to a worker.};
    my $src = read_file($SKILL);
    ok(defined $src, 'SKILL.md is readable');
    SKIP: {
        skip 'SKILL.md not readable', 1 unless defined $src;
        my $idx = index($src, $LINE605);
        ok($idx >= 0, 'the :605 sentence is present byte-identically') or diag('not found verbatim');
        SKIP: {
            skip 'the :605 sentence was not found', 12 unless $idx >= 0;
            # Bound the window to just the NEW bullet(s) immediately following :605 --
            # stop at the first blank line (a list item never contains one; the list
            # itself ends on one), so this never sweeps into an unrelated later
            # section (e.g. "### Turn caps ...", which contains its own bare "40").
            my $window = substr($src, $idx + length($LINE605), 4000);
            my $cut = index($window, "\n\n");
            my $after = ($cut >= 0) ? substr($window, 0, $cut) : $window;
            for my $needle ('prose alone is not the enforcement', 'dispatch-discipline-nudge.sh', 'bp-dispatch-log.pl ratio',
                             '704', 'BP_DISPATCH_RATIO_MIN_CALLS', 'BP_DISPATCH_RATIO_MIN', '%RATIO_DEFAULT') {
                like($after, qr/\Q$needle\E/, "the following text contains '$needle'");
            }
            like($after, qr/1,561|1561/, 'the following text contains 1,561 or 1561');
            unlike($after, $BANNED_RE, 'no banned assertion string in the following text');
            unlike($after, qr/carry over/, 'no "carry over" (Decision 1 reserves it)');
            unlike($after, qr/(?<!\d)200(?!\d)/, 'no bare literal 200 (the canonical source is named instead)');
            unlike($after, qr/(?<!\d)40(?!\d)/, 'no bare literal 40 (the canonical source is named instead)');
        }
    }
};

# ===========================================================================
# FINAL SAFETY CHECK (AC28). Must be the last thing this file does before
# done_testing().
# ===========================================================================
subtest 'AC28: the real .ccpraxis-local-data/.dispatch-log is untouched' => sub {
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole suite');
};

done_testing();
