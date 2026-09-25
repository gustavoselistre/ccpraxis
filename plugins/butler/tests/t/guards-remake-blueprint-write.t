#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 3 (blueprint
# hook-continuity-remake), BW-1..BW-7 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.3/4.3/4.6: the guard-blueprint-write
# successor (GuardBlueprintWrite, which absorbs guard-ledger-create),
# running on the package-03 hook core.
#
# hooks/guard-blueprint-write.sh and
# BpHook/Guards/GuardBlueprintWrite.pm DO NOT EXIST YET. Every in-process
# call goes through GuardHarness::run_module() (batch 1's harness,
# plugins/butler/tests/lib/GuardHarness.pm), which mirrors BpHook::main()'s
# own require-and-call contract, so a missing module fails open (rc 0)
# exactly as the real wrapper would -- legibly, never a crash in this file.
# Every [wrapper]/[shim] case spawns the real bash file at that path and
# gets a plain "No such file or directory" until the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above, never from reading guard-blueprint-write.sh or guard-ledger-create.sh.
#
# NOT RE-EXPRESSED (per spec sec 4.6 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                    | code
#   -------------------------------------------------------------- | ----
#   blueprint-write-api.t, everything but G9's two hook verdicts   | OTHER (bp-blueprint.pl CLI)
#   blueprint-set-title.t, everything but AC10's hook verdict      | OTHER (bp-blueprint.pl CLI)
#   blueprint-write-api.t G9's hooks.json registration checks      | REG
#   guard-ledger-create.t B-39 (jq availability plumbing)          | JQ
#   guard-ledger-create.t B-40 (source-text pin)                   | SRC
#   guard-ledger-create.t AC-16 literals 5-9 and the ordering check| MSG (20-line denial/escape
#                                                                      recipe retired by the budget)
#   driver-guard-reach.t AC-20 (source-text pin)                   | SRC
#   driver-guard-reach.t AC-21..24, AC-26 (package 13's guard-writes| OTHER
#     hatch, not this successor)                                    |
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front. R9-RM4 (review M4):
# GuardHarness.pm itself now isolates the environment unconditionally at
# "use GuardHarness;" above (deletes BP_*/CCPRAXIS_*/CLAUDE_*, deletes any
# inherited BUTLER_STATE_DIR, pins a decoy HOME/USERPROFILE), so this block
# is redundant, not load-bearing. The PRIOR claim here that "every
# individual block wraps its own env changes in local %ENV = %ENV" was
# false (no such wrap exists anywhere in this file) and is removed.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_bytes {
    my ($p, $bytes) = @_;
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Write/Edit/MultiEdit/NotebookEdit/Bash/Read tool_input
# payload. %o: tool (default 'Write'), file_path, notebook_path, cwd,
# session_id, agent_id, cmd (for Bash).
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $tool = $o{tool} // 'Write';
    my $ti = {};
    $ti->{file_path}     = $o{file_path}     if exists $o{file_path};
    $ti->{notebook_path} = $o{notebook_path}  if exists $o{notebook_path};
    $ti->{command}       = $o{cmd}            if exists $o{cmd};
    my $p = { tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# bw($payload, %opts) -- GuardHarness::run_module for
# Guards::GuardBlueprintWrite.
# ---------------------------------------------------------------------------
sub bw {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardBlueprintWrite', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# mk_root() -- a fresh tempdir laid out as a project root, with
# .ccpraxis-local-data/{.subagent-guard,bug-reports} present. Returns the
# root path, forward-slashed.
# ---------------------------------------------------------------------------
sub mk_root {
    my $t = tempdir(CLEANUP => 1);
    (my $root = $t) =~ s{\\}{/}g;
    make_path("$root/.ccpraxis-local-data/.subagent-guard");
    make_path("$root/.ccpraxis-local-data/bug-reports");
    return $root;
}

sub override_path { my ($root) = @_; return "$root/.ccpraxis-local-data/.subagent-guard/ledger-write-override" }
sub bug_report_path { my ($root, $id) = @_; return "$root/.ccpraxis-local-data/bug-reports/$id.md" }

my $BLUEPRINT_L1 = qr/^BLUEPRINT-GUARD: BLOCKED -- direct \S+ refused: /;
my $BLUEPRINT_L2 = "Change blueprint.md only through plugins/butler/scripts/bp-blueprint.pl (add-package, set-deps, add-decision, set-field) via Bash, then retry.\n";
my $LEDGER_L1_PREFIX = 'LEDGER-CREATE-GUARD: BLOCKED -- direct ';
my $LEDGER_L2_CREATE = "Create a package ledger only with bp-ledger.pl create, which validates model:/effort: and refuses a ledger its own validate verb would reject.\n";
my $LEDGER_L2_CONSUME = "A valid ledger-write-override was found but could not be consumed; remove it by hand and retry through bp-ledger.pl create.\n";

# ===========================================================================
# SH-1/SH-2 -- static shape.
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/guard-blueprint-write.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBlueprintWrite.pm";
    ok(-f $wrapper, 'SH-1 precondition: guard-blueprint-write.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on guard-blueprint-write.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::GuardBlueprintWrite/,
             'SH-1: the wrapper names the Guards::GuardBlueprintWrite module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/GuardBlueprintWrite.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on GuardBlueprintWrite.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# BW-1 -- direct writes to blueprint.md deny, in every path spelling; the
# path appears exactly once in the message.
# ===========================================================================
{
    my $root = mk_root();
    my $abs  = "$root/.ccpraxis-local-data/blueprints/x/blueprint.md";

    for my $c (
        [ $abs, 'BW-1: POSIX absolute path' ],
        [ "C:/dev/proj/.ccpraxis-local-data/blueprints/x/blueprint.md", 'BW-1: C:/ drive-letter form' ],
        [ 'C:\dev\proj\.ccpraxis-local-data\blueprints\x\blueprint.md', 'BW-1: C:\ backslash form' ],
    ) {
        my ($fp, $label) = @$c;
        for my $tool (qw(Write Edit MultiEdit NotebookEdit)) {
            my %po = (tool => $tool, session_id => 'bw1-sid');
            if ($tool eq 'NotebookEdit') { $po{notebook_path} = $fp } else { $po{file_path} = $fp }
            my $res = bw(payload(%po));
            is($res->{rc}, 2, "$label, tool $tool -> deny");
            like($res->{err}, $BLUEPRINT_L1, "$label, tool $tool -> BLUEPRINT-GUARD line 1");
            like($res->{err}, qr/Change blueprint\.md only through/, "$label, tool $tool -> line 2 present");
            my @path_hits = ($res->{err} =~ /blueprint\.md/g);
            ok(scalar(@path_hits) >= 1, "$label, tool $tool -> path text present");
            my @full_lines = split /\n/, $res->{err};
            is(scalar(grep { /BLOCKED -- direct/ } @full_lines), 1,
               "$label, tool $tool -> the BLOCKED line appears exactly once (never doubled)");
        }
    }

    # relative form: fp relative, cwd supplies the base.
    my $res_rel = bw(payload(tool => 'Write', file_path => '.ccpraxis-local-data/blueprints/x/blueprint.md',
                              cwd => $root, session_id => 'bw1-rel'));
    is($res_rel->{rc}, 2, 'BW-1: relative path resolved against cwd -> deny');
    like($res_rel->{err}, $BLUEPRINT_L1, 'BW-1: relative form -> BLUEPRINT-GUARD line 1');
}

# ===========================================================================
# BW-2 -- the template exemption.
# ===========================================================================
{
    my $root = mk_root();

    my $res_template = bw(payload(tool => 'Write', session_id => 'bw2-a',
        file_path => "$root/plugins/blueprint/templates/blueprint.md"));
    is($res_template->{rc}, 0, 'BW-2: plugins/*/templates/blueprint.md allows');

    my $res_other = bw(payload(tool => 'Write', session_id => 'bw2-b',
        file_path => "$root/templates/blueprint.md"));
    is($res_other->{rc}, 2, 'BW-2: templates/blueprint.md (no plugins/*/ segment) still denies');
}

# ===========================================================================
# BW-3 -- Bash and Read allow.
# ===========================================================================
{
    my $root = mk_root();

    my $res_bash1 = bw(payload(tool => 'Bash', session_id => 'bw3-a',
        cmd => 'perl plugins/butler/scripts/bp-blueprint.pl add-package --file x --slug y'));
    is($res_bash1->{rc}, 0, 'BW-3: a Bash call running bp-blueprint.pl allows');

    my $res_bash2 = bw(payload(tool => 'Bash', session_id => 'bw3-b',
        cmd => "perl plugins/butler/scripts/bp-ledger.pl create --file $root/.ccpraxis-local-data/blueprints/x/packages/01-a.md"));
    is($res_bash2->{rc}, 0, 'BW-3: a Bash call running bp-ledger.pl create allows');

    my $res_read = bw(payload(tool => 'Read', session_id => 'bw3-c',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md"));
    is($res_read->{rc}, 0, 'BW-3: Read of blueprint.md allows (guard applies only to write tools)');
}

# ===========================================================================
# BW-4 -- ledger paths under blueprints/*/packages/*.md deny with L; siblings
# allow; case-fold and suffix/trailing-dot normalisation still deny.
# ===========================================================================
{
    my $root = mk_root();

    my $res_new = bw(payload(tool => 'Write', session_id => 'bw4-a',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md"));
    is($res_new->{rc}, 2, 'BW-4: a new ledger path denies');
    like($res_new->{err}, qr/^\Q$LEDGER_L1_PREFIX\E/, 'BW-4: LEDGER-CREATE-GUARD line 1');
    is($res_new->{err}, $LEDGER_L1_PREFIX . "Write refused: " . "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md\n" . $LEDGER_L2_CREATE,
       'BW-4: exact L text for a new ledger path')
        or diag("got: $res_new->{err}");

    my $res_existing = bw(payload(tool => 'Edit', session_id => 'bw4-b',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md"));
    is($res_existing->{rc}, 2, 'BW-4: an existing ledger path (Edit) denies the same way');

    my $res_notes = bw(payload(tool => 'Write', session_id => 'bw4-c',
        file_path => "$root/notes/packages/readme.md"));
    is($res_notes->{rc}, 0, 'BW-4: notes/packages/readme.md (no blueprints/ segment) allows');

    my $res_tmpl = bw(payload(tool => 'Write', session_id => 'bw4-d',
        file_path => "$root/plugins/blueprint/templates/package-ledger.md"));
    is($res_tmpl->{rc}, 0, 'BW-4: plugins/blueprint/templates/package-ledger.md allows');

    my $res_upper = bw(payload(tool => 'Write', session_id => 'bw4-e',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/PACKAGES/01-A.MD"));
    is($res_upper->{rc}, 2, 'BW-4: uppercase PACKAGES/01-A.MD still denies (case-folded before matching)');

    my $res_ads = bw(payload(tool => 'Write', session_id => 'bw4-f',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md::\$DATA"));
    is($res_ads->{rc}, 2, 'BW-4: a trailing ::$DATA alternate-data-stream suffix still denies');

    my $res_dot = bw(payload(tool => 'Write', session_id => 'bw4-g',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md.  "));
    is($res_dot->{rc}, 2, 'BW-4: a trailing run of dots/spaces still denies');
}

# ===========================================================================
# BW-5 -- the ledger-write-override escape (kept working, never advertised).
# ===========================================================================
{
    my $ledger_fp;
    my $good_id = '20260101-000000-abcd';

    # -- valid report id, plain shape: allows once, consumes, repeat denies --
    {
        my $root = mk_root();
        $ledger_fp = "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md";
        write_bytes(bug_report_path($root, $good_id), "# a real bug report\n");
        write_bytes(override_path($root), "$good_id\n");

        my $res1 = bw(payload(tool => 'Write', session_id => 'bw5-a', cwd => $root, file_path => $ledger_fp),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res1->{rc}, 0, 'BW-5: a real report id allows once');
        ok(!-e override_path($root), 'BW-5: the override file is consumed (unlinked) after the allow');

        my $res2 = bw(payload(tool => 'Write', session_id => 'bw5-b', cwd => $root, file_path => $ledger_fp),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res2->{rc}, 2, 'BW-5: the repeat call (override now gone) denies');
    }

    # -- the B-35 whitespace/CR/extra-line shapes --
    for my $shape (
        [ "$good_id\r\n", 'CRLF-terminated id' ],
        [ "  $good_id  \n", 'surrounding whitespace' ],
        [ "$good_id\nextra trailing line\n", 'a real id plus an extra trailing line' ],
    ) {
        my ($content, $label) = @$shape;
        my $root = mk_root();
        my $fp = "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md";
        write_bytes(bug_report_path($root, $good_id), "# a real bug report\n");
        write_bytes(override_path($root), $content);

        my $res = bw(payload(tool => 'Write', session_id => 'bw5-shape', cwd => $root, file_path => $fp),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res->{rc}, 0, "BW-5 (B-35 shape: $label): allows once");
    }

    # -- AC-14 bad cases: deny L, file left byte-identical --
    for my $bad (
        [ '', 'empty first line' ],
        [ "has/a/slash\n", 'contains a forward slash' ],
        [ "has\\a\\backslash\n", 'contains a backslash' ],
        [ "../escape\n", 'contains ..' ],
        [ "nonexistent-report-id-0000\n", 'bug-report file does not exist' ],
    ) {
        my ($content, $label) = @$bad;
        my $root = mk_root();
        my $fp = "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md";
        write_bytes(bug_report_path($root, $good_id), "# a real bug report\n");
        write_bytes(override_path($root), $content);

        my $res = bw(payload(tool => 'Write', session_id => 'bw5-bad', cwd => $root, file_path => $fp),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res->{rc}, 2, "BW-5 (AC-14 bad case: $label): denies");
        is($res->{err}, $LEDGER_L1_PREFIX . "Write refused: $fp\n" . $LEDGER_L2_CREATE,
           "BW-5 (AC-14 bad case: $label): exact L text");
        ok(-e override_path($root), "BW-5 (AC-14 bad case: $label): override file untouched (still exists)");
        is(read_bytes(override_path($root)), $content,
           "BW-5 (AC-14 bad case: $label): override file byte-identical");
    }

    # -- a directory-shaped report: deny L, file unchanged --
    {
        my $root = mk_root();
        my $fp = "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md";
        make_path(bug_report_path($root, $good_id));  # a DIRECTORY at the report path
        my $content = "$good_id\n";
        write_bytes(override_path($root), $content);

        my $res = bw(payload(tool => 'Write', session_id => 'bw5-dir', cwd => $root, file_path => $fp),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res->{rc}, 2, 'BW-5: a directory-shaped report path denies');
        ok(-e override_path($root), 'BW-5: override file untouched (directory-shaped report)');
        is(read_bytes(override_path($root)), $content, 'BW-5: override file byte-identical (directory-shaped report)');
    }

    # -- a Bash call or a non-ledger write leaves the override unconsumed --
    {
        my $root = mk_root();
        my $content = "$good_id\n";
        write_bytes(bug_report_path($root, $good_id), "# a real bug report\n");
        write_bytes(override_path($root), $content);

        my $res_bash = bw(payload(tool => 'Bash', session_id => 'bw5-bash', cwd => $root, cmd => 'echo hi'),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res_bash->{rc}, 0, 'BW-5: a Bash call allows (not this guard\'s tool set)');
        is(read_bytes(override_path($root)), $content, 'BW-5: a Bash call leaves the override file unconsumed');

        my $res_nonledger = bw(payload(tool => 'Write', session_id => 'bw5-nl', cwd => $root,
            file_path => "$root/notes.md"),
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res_nonledger->{rc}, 0, 'BW-5: a non-ledger write allows');
        is(read_bytes(override_path($root)), $content, 'BW-5: a non-ledger write leaves the override file unconsumed');
    }

    # -- BP_LEDGER_GUARD_FAIL_CONSUME=1: denies with C, file remains --
    {
        my $root = mk_root();
        my $fp = "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md";
        my $content = "$good_id\n";
        write_bytes(bug_report_path($root, $good_id), "# a real bug report\n");
        write_bytes(override_path($root), $content);

        my $res = bw(payload(tool => 'Write', session_id => 'bw5-failconsume', cwd => $root, file_path => $fp),
            env => { CLAUDE_PROJECT_DIR => $root, BP_LEDGER_GUARD_FAIL_CONSUME => '1' });
        is($res->{rc}, 2, 'BW-5: BP_LEDGER_GUARD_FAIL_CONSUME=1 denies (unlink skipped, O still exists)');
        is($res->{err}, $LEDGER_L1_PREFIX . "Write refused: $fp\n" . $LEDGER_L2_CONSUME,
           'BW-5: exact C text');
        ok(-e override_path($root), 'BW-5: FAIL_CONSUME leaves the override file present');
        is(read_bytes(override_path($root)), $content, 'BW-5: FAIL_CONSUME leaves it byte-identical');
    }
}

# ===========================================================================
# BW-6 -- universal: BW-1's blueprint.md deny holds regardless of session
# state (every BP_* unset, session armed as driver, and a subagent payload).
# ===========================================================================
{
    my $root = mk_root();
    my $fp = "$root/.ccpraxis-local-data/blueprints/x/blueprint.md";

    my $res_noenv = bw(payload(tool => 'Write', session_id => 'bw6-noenv', file_path => $fp));
    is($res_noenv->{rc}, 2, 'BW-6: with every BP_* unset, the blueprint.md deny still holds');

    my $base = GuardHarness::fresh_state();
    my $sid = 'bw6-driver';
    ok(GuardHarness::arm($sid, 'driver'), 'BW-6 setup: session armed as driver');
    my $res_driver = bw(payload(tool => 'Write', session_id => $sid, file_path => $fp));
    is($res_driver->{rc}, 2, 'BW-6: an armed-driver session still gets the blueprint.md deny');

    my $res_subagent = bw(payload(tool => 'Write', session_id => $sid, agent_id => 'a1', file_path => $fp));
    is($res_subagent->{rc}, 2, 'BW-6: a subagent payload (agent_id set) still gets the blueprint.md deny');
}

# ===========================================================================
# BW-7 -- the remaining shared ACs.
# ===========================================================================

# SH-5 -- run() leaves BpHook::parse_count() unchanged, deny and allow.
{
    my $root = mk_root();
    my $res_deny = bw(payload(tool => 'Write', session_id => 'bw7-deny',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md"));
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
    my $res_allow = bw(payload(tool => 'Read', session_id => 'bw7-allow',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md"));
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- budget (2 lines) and forbidden vocabulary on every deny collected.
{
    my $root = mk_root();
    my @denies = (
        bw(payload(tool => 'Write', session_id => 'sh6-a', file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md")),
        bw(payload(tool => 'Write', session_id => 'sh6-b', file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md")),
    );
    is(scalar(@denies), 2, 'SH-6 setup: two deny fixtures collected');
    for my $i (0 .. $#denies) {
        my $res = $denies[$i];
        is($res->{rc}, 2, "SH-6: fixture $i is really a deny") or next;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, "SH-6: fixture $i has at most the guard-blueprint-write budget of 2 lines");
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, "SH-6: fixture $i line length <= 160");
            unlike($l, qr/\.run-finished|stop-ok|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   "SH-6: fixture $i line names no retired mechanism");
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i,
                   "SH-6: fixture $i line names no disable-a-guard hatch");
        }
        is($res->{out}, '', "SH-6: fixture $i stdout is empty");
    }
}

# SH-7 -- bad JSON, truncated payload, {} -> exit 0, no output.
{
    for my $c (
        ['not json at all'                          => 'malformed JSON'],
        ['{"tool_input":{"file_path":"blueprint'    => 'truncated JSON'],
        ['{}'                                        => 'empty object'],
    ) {
        my ($raw, $label) = @$c;
        my %e = ($label eq 'truncated JSON') ? (BP_PAYLOAD_TRUNCATED => 1) : ();
        my $res = bw($raw, env => \%e);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# [wrapper]/[shim] cases: SH-3 (not-applies) and SH-4 (applies).
# ===========================================================================
{
    my $root = mk_root();
    my $sid = 'bw-shim-not-applies';

    # SH-3: a Write payload whose raw text does not contain "blueprint" ->
    # the --pre text:blueprint clause exits in bash, 0 perl.
    my $res_shim = GuardHarness::run_shim('guard-blueprint-write.sh',
        { tool_name => 'Write', tool_input => { file_path => "$root/notes/readme.md" }, session_id => $sid });
    is($res_shim->{rc}, 0, 'SH-3: a payload without the substring "blueprint" -> exit 0');
    is($res_shim->{out}, '', 'SH-3: empty stdout');
    is($res_shim->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the wrapper exits in bash before ever reaching perl)');

    # SH-4: a Write payload to blueprint.md (raw text contains "blueprint")
    # reaches perl and denies.
    my $res_applies = GuardHarness::run_shim('guard-blueprint-write.sh',
        { tool_name => 'Write', session_id => 'bw-shim-applies',
          tool_input => { file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md" } });
    is($res_applies->{rc}, 2, 'SH-4: a blueprint.md write reaches perl and denies');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1,
       'SH-4: exactly 1 perl launch');
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a real
# EXISTING successor (stop-gate.sh, package 06), not GuardBlueprintWrite.
# Proves a red result above is guard-blueprint-write's absence, not a
# harness defect. Repeats batch 1's own self-check independently, since
# this file must stand on its own when the runner parallelises files.
# ===========================================================================
{
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_wrapper = GuardHarness::run_wrapper($stopgate,
        { session_id => 'bwselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_wrapper->{rc}, 0, 'self-check: run_wrapper against the real stop-gate.sh (unarmed) allows');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'bwselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('bwselfcheck-3', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'bwselfcheck-3', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1,
       'self-check: ...with exactly 1 perl launch');

    ok(GuardHarness::arm('bwselfcheck-run-module-armed', 'manual'),
       'self-check/run_module setup: a distinct session armed');
    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'bwselfcheck-run-module-armed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its '
     . 'run(), rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'bwselfcheck-run-module-unarmed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and '
     . 'never-armed session -> allows');
}

$? = 0;
done_testing();
