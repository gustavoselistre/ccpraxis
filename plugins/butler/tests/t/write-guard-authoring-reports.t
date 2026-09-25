#!/usr/bin/env perl
# platform: any
# Oracle for package 26-unbound-authoring-agents (blueprint
# hook-continuity-remake), Decision 100 of blueprint.md.
#
# Decision 98 (package 26, half one, covered by
# bind-dispatch-authoring-exempt.t) lets BindDispatch dispatch an
# allowlisted authoring/reviewing subagent_type (blueprint:bp-auditor,
# butler:bp-feedback-verifier, Explore, claude-code-guide) with no Ledger
# line and no binding file, regardless of how many packages are in flight.
#
# Decision 100 is the other half: BpHook::WriteGuards' resolve() derives an
# UNBOUND subagent's write scope purely from inflight membership -- with 2+
# packages in flight and no binding, that is kind=refused, allow_dirs=(),
# so an exempt agent that Decision 98 just let through cannot write even its
# own report. Extension: a subagent whose worker record,
# .drive-solo/workers/<tool_use_id> (BpHook::Guards::TrackDispatch's own
# record shape -- { at, session_id, subagent_type, tool_use_id }, written at
# the bare tool_use_id, no ".json" suffix), names a subagent_type on
# BindDispatch's allowlist may write ONLY under
# .ccpraxis-local-data/blueprints/<bp>/reports/, for ANY blueprint name --
# and nothing else. Decision 100 also requires the allowlist to be SHARED,
# not copied: WriteGuards must consult BindDispatch's own list, not carry a
# second literal copy that could drift.
#
# THIS EXTENSION IS NOT BUILT YET at the time this file is written:
# WriteGuards.pm has no worker-record lookup and no reports/-only allowance,
# and BindDispatch.pm has no PUBLIC accessor for its (private, lexical)
# %EXEMPT_TYPE allowlist. So every ALLOW case below is expected to fail
# today (an exempt-but-unbound subagent still gets kind=refused, rc 2, the
# same as any other unbound subagent with 2+ packages in flight) and every
# DENY case is expected to pass today (today's refusal already denies
# everything for an unbound subagent, which is a superset of "denied
# outside reports/").
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from Decision 100's text
# and the already-shipped interfaces it names or that this package's own
# scope requires reading to build a correct fixture -- BpHook::BindDispatch
# (12, explicitly named by Decision 100: "WriteGuards reads it from
# BindDispatch"), BpHook::WriteGuards's existing resolve()/run() contract
# (13/16, "Exposed for tests", read only for its PRE-existing kinds
# bound/refused/refused_bound/sole/single/union -- never for how the new
# reports-allowance will be wired in, which does not exist), and
# BpHook::Guards::TrackDispatch's worker-record writer (used only to learn
# the on-disk shape of ".drive-solo/workers/<tool_use_id>" that Decision 100
# itself names, never read for guard logic). guard-writes.sh,
# ledger-guard.sh and any reports-allowance code inside WriteGuards.pm were
# never opened.
#
# THE NAME CHOSEN FOR THE SHARED-ALLOWLIST ACCESSOR: Decision 100 requires
# "the allowlist WriteGuards uses is the one BindDispatch exposes" but does
# not name the accessor. BindDispatch.pm (12/16) already has an established,
# unbroken convention: every private predicate/helper it exposes to
# WriteGuards is a same-named public wrapper with the leading underscore
# dropped (_member_ok -> member_ok, _resolve_data_dir -> resolve_data_dir,
# _inflight_members -> inflight_members; WriteGuards.pm already calls all
# three as BpHook::BindDispatch::<name>). The private predicate that already
# exists for this exact allowlist is "_is_exempt_type($v)". Following that
# unbroken convention, this oracle pins the public wrapper's name as
# "is_exempt_type($v)". If a fresh implementer instead adds a same-shaped
# accessor under a different name, IDENTITY_TEST below (which checks
# `defined &BpHook::BindDispatch::is_exempt_type` before trusting it, and
# falls back to Decision 98's literal 4-string list otherwise) still lets
# every ALLOW/DENY behavioural assertion pass -- only the one "exposes a
# public accessor named is_exempt_type" assertion would need renaming, never
# the coverage.
#
# NOT RE-EXPRESSED (already covered by bind-dispatch-authoring-exempt.t,
# which is this package's OTHER new oracle and is not this file's job):
#   assertion                                                   | status
#   ------------------------------------------------------------ | ------
#   a dispatch with an allowlisted subagent_type and no Ledger  | OTHER
#     line is allowed, no binding file is written                |  (bind-dispatch-authoring-exempt.t)
#   a non-allowlisted type keeps today's Ledger-line rule        | OTHER (ditto)
#   the allowlist is pinned exactly (near-miss variants denied   | OTHER (ditto,
#     at the BIND step)                                          |  re-expressed here only at the WRITE step)
#
# AMENDED per Decision 101 (blueprint.md), after the package 26 review
# (reports/26-unbound-authoring-agents-review.md) found 2 blockers/3 majors
# in the FIRST version of this oracle and the implementation it exercised:
#   B2: this file's own fixture used an UNMEASURED transcript_path shape,
#       "<X>/<sid>/<sid>.jsonl" -- every one of the 135 captured real
#       payloads (and guards-per-subagent.t's own measured Shape A) is
#       "<X>/<sid>.jsonl". Fixed below; the code-side widening that shape
#       required is reverted separately (implementer's write set).
#   M1: the allowlist must be asserted through BindDispatch::exempt_types(),
#       so a 5th entry breaks a test (it was previously invisible: a private
#       lexical %EXEMPT_TYPE, enumerable only through is_exempt_type()'s
#       per-string answer, never as a whole list).
#   M2: with exactly 1 package in flight an exempt-but-unbound subagent must
#       STILL be reports-only -- resolve()'s kind='sole' branch (today) gives
#       it the sole package's full write_set instead, which is the "auditor
#       gets Write access to project code" escalation the review flagged.
#   M3/B1: the original oracle only ever hand-planted the worker record,
#       which is exactly why it never noticed that TrackDispatch's
#       _driver_pre (the record's only real producer) skips writing one for
#       an exempt type at all (Common::is_writer() only recognises
#       bp-implementer/bp-test-writer/bp-ui-prober). Added: an end-to-end
#       case that drives a real PreToolUse Task dispatch through
#       BpHook::Guards::TrackDispatch, with NO hand-planted record, plus a
#       companion assertion that GuardBash's validation interlock does not
#       mistake that same worker record for a live writer (it already does
#       not -- GuardBash's own is_writer() filter is what the review credits
#       -- so that half is a regression pin, not a new failure).
#   minor: WriteGuards must also require the worker record's session_id to
#       equal the caller's own session_id; a record for a different session
#       must grant nothing.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use File::Path qw(make_path remove_tree);
use File::Find ();
use File::Spec ();
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation up front (per the house idiom; GuardHarness itself
# isolates at "use").
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $J = JSON::PP->new->utf8->canonical;
(my $BUTLER_DIR = Cwd::abs_path(dirname(__FILE__) . '/../..')) =~ s{\\}{/}g;

# =============================================================================
# Hermetic scratch root, never /tmp, never the real %TEMP% (spec-house rule,
# shared verbatim with guards-per-subagent.t: several ACs in this suite
# unset TMPDIR/TEMP/TMP/LOCALAPPDATA to prove the guard's temp-allowance
# does not depend on them, and several others probe writes to a real "/tmp"
# path -- a scratch root that itself lived under the host's real temp dir
# would make some of those assertions accidentally vacuous). So this stays
# under THIS FILE's own directory rather than File::Temp::tempdir()'s
# default location, in-repo, on purpose -- which is exactly why cleanup must
# be unconditional rather than relying on the OS to reap a real temp dir.
#
# _force_remove_tree($dir) -- same fix scripts/run-tests.pl's
# _force_remove_tree got: `remove_tree(..., { safe => 1 })` silently SKIPS
# any file it finds read-only, so a run that makes anything read-only (or
# dies partway, before every fixture finishes writing) can leave residue in
# the working tree forever, invisible to this file's own exit code. Clearing
# every read-only bit first (finddepth, so files are cleared before their
# parent dir) and dropping `safe => 1` means the only thing that can still
# block removal is something genuinely outside this process's control.
# =============================================================================
(my $TEST_DIR = Cwd::abs_path(dirname(__FILE__))) =~ s{\\}{/}g;
my $SCRATCH_ROOT = "$TEST_DIR/.scratch-write-guard-authoring-reports-$$";
make_path($SCRATCH_ROOT);
my $SCRATCH_SEQ = 0;

sub _force_remove_tree {
    my ($dir) = @_;
    return unless defined $dir && length $dir && -e $dir;
    eval {
        File::Find::finddepth(sub {
            chmod(0777, $File::Find::name) if -e $File::Find::name;
        }, $dir);
    };
    chmod(0777, $dir) if -e $dir;
    eval { remove_tree($dir) };
}

# END runs on both normal exit and a die (die() unwinds the call stack, then
# runs pending END blocks before the process actually exits) -- wrapped in
# its own eval so a cleanup failure can never mask, or be masked by, the
# real exit status this file is reporting.
END { local $@; eval { _force_remove_tree($SCRATCH_ROOT) } if defined $SCRATCH_ROOT; }

sub scratch_dir {
    my ($name) = @_;
    $name = defined($name) ? $name : 'x';
    my $d = "$SCRATCH_ROOT/" . $name . '-' . (++$SCRATCH_SEQ);
    make_path($d);
    return $d;
}

# ---------------------------------------------------------------------------
# byte / JSON IO helpers (same shape as guards-per-subagent.t's).
# ---------------------------------------------------------------------------
sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub write_json { my ($path, $data) = @_; write_bytes($path, $J->encode($data) . "\n") }

sub ledger_body {
    my (%o) = @_;
    my $pkg    = $o{package};
    my $bp     = $o{blueprint} // 'bpx';
    my $status = $o{status} // 'running';
    my $ws     = $o{write_set} // '';
    my $tp     = $o{test_paths} // '';
    my $lu     = $o{last_updated} // '2025-01-01T00:00:00Z';
    return "---\npackage: $pkg\nblueprint: $bp\nstatus: $status\n"
         . "write_set: $ws\ntest_paths: $tp\nlast_updated: $lu\n---\n\n"
         . "## Next action\n\nkeep going\n\n"
         . "## Decisions & attempt log\n\n- note\n\n"
         . "## Pipeline\n\n- [x] 1\n\n"
         . "## Outputs\n\nnone\n\n"
         . "## Escalation\n\nnone\n";
}
sub write_ledger {
    my ($d, %o) = @_;
    my $bp  = $o{blueprint} // 'bpx';
    my $pkg = $o{package};
    write_bytes("$d/blueprints/$bp/packages/$pkg.md", ledger_body(%o));
}

# ---------------------------------------------------------------------------
# fixture(%opts) -- same normative shape as guards-per-subagent.t's.
# members => 2 (default) or 1: how many packages inflight.json lists (both
# fixture packages exist on disk regardless, exactly like guards-per-
# subagent.t's own fixture()). n_inflight==2 reaches resolve()'s
# kind=refused branch (Decision 100's original case); n_inflight==1 reaches
# kind=sole, which Decision 101 M2 says must ALSO stay reports-only for an
# exempt-but-unbound subagent.
# ---------------------------------------------------------------------------
sub fixture {
    my (%o) = @_;
    my $members = $o{members} // 2;
    my $sid  = $o{sid} // 'sess-drv';
    my $base = $o{base} // scratch_dir('proj');
    my $R = $base;
    my $D = "$R/.ccpraxis-local-data";
    make_path("$D/blueprints/bpx/packages");
    write_ledger($D, package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    write_ledger($D, package => 'p2-b', write_set => 'src/b/',           test_paths => 't/b/');

    my @all_members = ({ blueprint => 'bpx', package => 'p1-a' }, { blueprint => 'bpx', package => 'p2-b' });
    my @use = ($members == 1) ? ($all_members[0]) : @all_members;
    make_path("$D/.drive-solo");
    write_json("$D/.drive-solo/inflight.json", { packages => [ map { { %$_, ledger => 'ignored', since => 1 } } @use ], updated_at => 1 });
    make_path("$D/.drive-solo/bindings");
    make_path("$D/.drive-solo/workers");

    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');

    my $X = "$R-transcripts";
    make_path("$X/$sid/subagents");

    return { R => $R, D => $D, X => $X, sid => $sid };
}

# worker record ($fx->{D}/.drive-solo/workers/<tuid>, no ".json" suffix --
# BpHook::Guards::TrackDispatch::_driver_pre's own on-disk record shape).
# $session_id defaults to the fixture's own session -- pass an explicit
# value to build a MISMATCHED record (Decision 101 minor).
sub write_worker_record {
    my ($fx, $tuid, $subagent_type, $session_id) = @_;
    $session_id = $fx->{sid} unless defined $session_id;
    write_json("$fx->{D}/.drive-solo/workers/$tuid",
        { at => time(), session_id => $session_id, subagent_type => $subagent_type, tool_use_id => $tuid });
}

# an UNBOUND subagent (meta.json exists, no bindings/<tuid>.json) with a
# worker record naming $subagent_type -- the exact shape Decision 100
# describes. Reused across several file_path probes for one identity.
#
# transcript_path (Decision 101 B2): the MEASURED shape, "<X>/<sid>.jsonl"
# (guards-per-subagent.t's own Shape A, and every one of the 135 captured
# real payloads in reports/26-unbound-authoring-agents-review.md). The
# fixture's meta.json already lives at "$X/$sid/subagents/", which is
# exactly where Shape A's own resolution rule (dirname(T) . "/$sid/
# subagents") looks -- no code-side special case needed.
sub unbound_worker_payload {
    my ($fx, %o) = @_;
    my $agent_id = $o{agent_id};
    my $tuid     = $o{tuid};
    my $p = {
        hook_event_name => 'PreToolUse',
        tool_name       => ($o{tool_name} // 'Write'),
        tool_input      => { file_path => $o{file_path} },
        session_id      => $fx->{sid},
        cwd             => $fx->{R},
        agent_id        => $agent_id,
        agent_type      => 'general-purpose', # per resolve(): agent_type only matters for BOUND writer-role gating; irrelevant here
        transcript_path => "$fx->{X}/$fx->{sid}.jsonl",
    };
    return $p;
}

sub env_for {
    my ($D, %extra) = @_;
    return {
        CCPRAXIS_DATA_DIR  => $D,
        TMPDIR             => undef,
        TEMP               => undef,
        TMP                => undef,
        LOCALAPPDATA       => undef,
        BP_PROJECT_ROOT    => undef,
        CLAUDE_PROJECT_DIR => undef,
        %extra,
    };
}

sub wg_writes { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['writes']) }

# ---------------------------------------------------------------------------
# One meta.json + one worker record per (agent_id, tuid) pair, set up once
# per fixture; each case below then only varies file_path.
# ---------------------------------------------------------------------------
sub arm_unbound_agent {
    my ($fx, %o) = @_;
    my $agent_id = $o{agent_id} // 'eeee1';
    my $tuid     = $o{tuid}     // 'toolu_E1';
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-$agent_id.meta.json", { toolUseId => $tuid });
    write_worker_record($fx, $tuid, $o{subagent_type}, $o{record_session_id});
    return ($agent_id, $tuid);
}

sub probe {
    my ($fx, $agent_id, $tuid, $file_path) = @_;
    my $p = unbound_worker_payload($fx, agent_id => $agent_id, tuid => $tuid, file_path => $file_path);
    return wg_writes($p, env => env_for($fx->{D}));
}

# =============================================================================
# Decision 98's fixed allowlist, quoted verbatim from blueprint.md Decision
# 98/100 -- the same 4 strings BindDispatch.pm's %EXEMPT_TYPE already holds.
# =============================================================================
my @EXEMPT = ('blueprint:bp-auditor', 'butler:bp-feedback-verifier', 'Explore', 'claude-code-guide');

# Near-miss / unrelated types: never exempt, must still be refused (today's
# behaviour, unchanged).
my @NON_EXEMPT = ('blueprint:Bp-auditor', 'explore', 'claude-code-guide-extra', 'general-purpose', 'bp-implementer');

my $GENERIC_REFUSAL = "No package binding for this subagent; with 2 packages in flight its edits are refused.\n";

my $REQUIRE_OK = eval { require "BpHook/WriteGuards.pm"; 1 };
# BindDispatch.pm is required by WriteGuards.pm itself (own key, an absolute
# path) whenever $REQUIRE_OK -- require it again here, under its OWN %INC
# key, only if that did not already happen (avoids loading it twice under
# two different %INC keys, which redefines every one of its subs and prints
# "Subroutine ... redefined" warnings for no benefit).
eval { require "BpHook/BindDispatch.pm" }
    unless grep { m{(?:^|/)BpHook/BindDispatch\.pm\z} } keys %INC;

# =============================================================================
# Shared-allowlist accessor (Decision 100: "the allowlist is shared, not
# copied: WriteGuards reads it from BindDispatch"). See the file header for
# why this exact name is pinned, and how the fallback keeps every other
# assertion below meaningful even if a different name is chosen.
# =============================================================================
my $HAS_ACCESSOR = defined &BpHook::BindDispatch::is_exempt_type;
ok($HAS_ACCESSOR,
    'BindDispatch exposes a public is_exempt_type($subagent_type) accessor -- '
  . 'Decision 100: WriteGuards must read the allowlist from BindDispatch, not carry its own copy');

sub bd_says_exempt {
    my ($type) = @_;
    if ($HAS_ACCESSOR) {
        my $r = eval { BpHook::BindDispatch::is_exempt_type($type) };
        return (!$@ && $r) ? 1 : 0;
    }
    my %known = map { $_ => 1 } @EXEMPT;
    return $known{$type} ? 1 : 0;
}

# Sanity: bd_says_exempt() (whichever source it used) must agree with
# Decision 98/100's literal list -- this is the "equality with BindDispatch's
# list" half of the requirement, independent of whether the accessor exists.
for my $t (@EXEMPT)     { is(bd_says_exempt($t), 1, "bd_says_exempt('$t') is true (Decision 98/100 allowlist)") }
for my $t (@NON_EXEMPT) { is(bd_says_exempt($t), 0, "bd_says_exempt('$t') is false (not on the allowlist)") }

# =============================================================================
# Decision 101 M1: the allowlist must be readable as a WHOLE LIST, through a
# public BpHook::BindDispatch::exempt_types() accessor -- not only answerable
# one string at a time through is_exempt_type(). Without this, %EXEMPT_TYPE
# stays a private lexical no test can enumerate, so a 5th entry (e.g.
# 'butler:bp-reviewer') would keep every assertion above green.
# =============================================================================
my $HAS_EXEMPT_TYPES_FN = defined &BpHook::BindDispatch::exempt_types;
ok($HAS_EXEMPT_TYPES_FN,
    'BindDispatch exposes a public exempt_types() accessor returning the WHOLE allowlist (Decision 101 M1)');

# No SKIP: with the accessor missing, @got is deliberately left empty so
# is_deeply below fails for that exact reason (missing behaviour), rather
# than being silently excused.
my @got = $HAS_EXEMPT_TYPES_FN
    ? sort { $a cmp $b } eval { BpHook::BindDispatch::exempt_types() }
    : ();
# shape-lint: intentional -- Decision 101 M1 requires this exact list so
# that adding a 5th allowlisted type breaks this assertion on purpose; it is
# the pin, not an accident.
is_deeply(\@got, [ sort { $a cmp $b } @EXEMPT ],
    'exempt_types() returns exactly the Decision 98/100 4-entry allowlist -- a new entry must fail this');

# =============================================================================
# ALLOW: each allowlisted subagent_type, unbound, 2+ in flight -- may write
# under blueprints/<any bp>/reports/, including a blueprint that is not
# itself in flight (Decision 100: "for any blueprint").
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture();
    my ($aid, $tuid) = arm_unbound_agent($fx, subagent_type => $type);

    my $r1 = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/x.md");
    is($r1->{rc}, 0, "ALLOW($type): unbound, worker-record-exempt subagent writing bpx/reports/x.md gives rc 0");
    is($r1->{err}, '', "ALLOW($type): that rc0 case has empty stderr");

    my $r2 = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/an-unrelated-bp-never-in-flight/reports/z.md");
    is($r2->{rc}, 0, "ALLOW($type): reports/ allowance covers a blueprint with no in-flight package at all (\"for any blueprint\")");
}

# =============================================================================
# DENY (same exempt identity): a package ledger, blueprint.md, a repo source
# file inside an in-flight package's own write_set, and two reports/ paths
# reached only by a lexical '..' escape out of reports/ into a forbidden
# sibling. "May write ONLY under reports/, and nothing else" (Decision 100).
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture();
    my ($aid, $tuid) = arm_unbound_agent($fx, subagent_type => $type);

    my $r_ledger = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/packages/p1-a.md");
    is($r_ledger->{rc}, 2, "DENY($type): writing a package ledger (blueprints/bpx/packages/p1-a.md) gives rc 2");

    my $r_bpmd = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/blueprint.md");
    is($r_bpmd->{rc}, 2, "DENY($type): writing blueprint.md gives rc 2");

    my $r_src = probe($fx, $aid, $tuid, "$fx->{R}/src/a/x.pl");
    is($r_src->{rc}, 2, "DENY($type): writing a repo source file inside an in-flight package's write_set gives rc 2 (exempt grants ONLY reports/, nothing else)");

    # '..' escapes out of reports/ into the ledger and blueprint.md this
    # subagent must never reach -- both LOOK like a reports/ path in the
    # literal string, and both resolve outside it once lexically collapsed.
    my $r_trick1 = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/../packages/p1-a.md");
    is($r_trick1->{rc}, 2, "DENY($type): 'reports/../packages/p1-a.md' (lexically the package ledger) gives rc 2");

    my $r_trick2 = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/../blueprint.md");
    is($r_trick2->{rc}, 2, "DENY($type): 'reports/../blueprint.md' (lexically blueprint.md) gives rc 2");
}

# =============================================================================
# An unbound subagent of a NON-allowlisted subagent_type (a near-miss of an
# allowlisted string, or an ordinary role) is still denied everything, as
# today -- including under reports/. The worker record naming a
# non-allowlisted type changes nothing.
# =============================================================================
for my $type (@NON_EXEMPT) {
    my $fx = fixture();
    my ($aid, $tuid) = arm_unbound_agent($fx, subagent_type => $type);

    my $r1 = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/x.md");
    is($r1->{rc}, 2, "STILL-DENIED($type): unbound, non-allowlisted subagent writing bpx/reports/x.md gives rc 2");
    is($r1->{err}, $GENERIC_REFUSAL, "STILL-DENIED($type): exact refusal text, unchanged by Decision 100");

    my $r2 = probe($fx, $aid, $tuid, "$fx->{R}/src/a/x.pl");
    is($r2->{rc}, 2, "STILL-DENIED($type): unbound, non-allowlisted subagent writing src/a/x.pl gives rc 2");

    my $r3 = probe($fx, $aid, $tuid, '/tmp/write-guard-authoring-reports-probe.txt');
    is($r3->{rc}, 0, "STILL-DENIED($type): /tmp write still allows for a refused, non-allowlisted subagent (unchanged invariant)");
}

# =============================================================================
# An unbound subagent with NO worker record at all (Decision 100's extension
# never applies without one) is refused exactly as today, including under
# reports/ -- Decision 100 only widens scope for a subagent a worker record
# actually names as exempt, never for "no record" generally.
# =============================================================================
{
    my $fx = fixture();
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ffff1.meta.json", { toolUseId => 'toolu_F1' });
    # deliberately no .drive-solo/workers/toolu_F1 record at all
    my $r = probe($fx, 'ffff1', 'toolu_F1', "$fx->{D}/blueprints/bpx/reports/x.md");
    is($r->{rc}, 2, 'NO-WORKER-RECORD: unbound subagent with no worker record at all writing reports/x.md gives rc 2');
    is($r->{err}, $GENERIC_REFUSAL, 'NO-WORKER-RECORD: exact refusal text');
}

# =============================================================================
# Decision 101 M2: with exactly ONE package in flight, an exempt-but-unbound
# subagent is STILL reports-only -- it must never inherit the sole package's
# write_set/test_paths, which is what resolve()'s kind='sole' branch grants
# an ordinary unbound subagent today. Today (pre-fix) this subagent gets
# 'sole' regardless of reports_exempt, so writing the sole package's own
# write_set path wrongly succeeds -- the escalation the review named
# ("bp-auditor gets Write access to project code").
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture(members => 1);
    my ($aid, $tuid) = arm_unbound_agent($fx, subagent_type => $type);

    my $r_own = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/x.md");
    is($r_own->{rc}, 0, "M2($type, n=1): reports/ under the sole in-flight package's OWN blueprint is still allowed");

    my $r_other = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/an-unrelated-bp-never-in-flight/reports/z.md");
    is($r_other->{rc}, 0, "M2($type, n=1): reports/ under an unrelated blueprint is still allowed (\"for any blueprint\")");

    my $r_ws = probe($fx, $aid, $tuid, "$fx->{R}/src/a/x.pl");
    is($r_ws->{rc}, 2, "M2($type, n=1): the sole package's own write_set (src/a/x.pl) is DENIED -- exempt never inherits 'sole' scope");

    my $r_test = probe($fx, $aid, $tuid, "$fx->{R}/t/a/x.t");
    is($r_test->{rc}, 2, "M2($type, n=1): the sole package's own test_paths (t/a/x.t) is DENIED for the same reason");
}

# =============================================================================
# Decision 101 M3/B1: end to end, no hand-planted worker record. A real
# PreToolUse Task dispatch (subagent_type on the allowlist, main-thread
# driver, no agent_id -- BpHook::Guards::TrackDispatch's own driver-dispatch
# shape) is run through TrackDispatch itself; ONLY THEN does the dispatched
# subagent's own Write go through WriteGuards. Fails today: TrackDispatch's
# _driver_pre only writes a worker record when Common::is_writer() recognises
# the subagent_type (bp-implementer/bp-test-writer/bp-ui-prober); none of the
# 4 allowlisted types is one of those, so no record is ever written and the
# later Write is refused exactly like NO-WORKER-RECORD above.
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture();
    my $tuid = 'toolu_E2E1';
    my $agent_id = 'gggg1';

    my $dispatch = {
        hook_event_name => 'PreToolUse',
        tool_name       => 'Task',
        tool_use_id     => $tuid,
        session_id      => $fx->{sid},
        cwd             => $fx->{R},
        tool_input      => { subagent_type => $type, prompt => 'audit the newly authored blueprint' },
    };
    my $rc_dispatch = GuardHarness::run_module('Guards::TrackDispatch', $dispatch, env => env_for($fx->{D}));
    is($rc_dispatch->{rc}, 0, "E2E($type): TrackDispatch's own PreToolUse Task dispatch never denies");

    ok(-f "$fx->{D}/.drive-solo/workers/$tuid",
        "E2E($type): TrackDispatch writes a worker record for this exempt dispatch, unprompted by this oracle (Decision 101 B1)");

    write_json("$fx->{X}/$fx->{sid}/subagents/agent-$agent_id.meta.json", { toolUseId => $tuid });
    my $r = probe($fx, $agent_id, $tuid, "$fx->{D}/blueprints/bpx/reports/e2e.md");
    is($r->{rc}, 0, "E2E($type): the dispatched subagent's own Write to reports/e2e.md is allowed, with NO hand-planted worker record");
}

# =============================================================================
# Decision 101 (4, second half): GuardBash's own validation interlock must
# NOT treat an exempt worker record as a live writer -- it already does not
# (Common::is_writer() only recognises the three writer roles, and GuardBash
# skips any worker record it returns undef for), so this is a REGRESSION PIN,
# expected to pass today, not a new failure.
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture();
    my $tuid = 'toolu_GB1';
    write_worker_record($fx, $tuid, $type);

    my $p_bash = { tool_name => 'Bash', tool_input => { command => 'perl t/a/x.t' }, session_id => $fx->{sid} };
    my $res = GuardHarness::run_module('Guards::GuardBash', $p_bash, env => env_for($fx->{D}));
    is($res->{rc}, 0, "GUARDBASH($type): an exempt worker record is never treated as a live writer by the validation interlock");
}

# =============================================================================
# Decision 101 minor: a worker record whose session_id does not match the
# CALLER's own session_id grants nothing -- today WriteGuards' worker-record
# lookup never checks session_id at all, so this currently (wrongly) allows.
# =============================================================================
for my $type (@EXEMPT) {
    my $fx = fixture();
    my ($aid, $tuid) = arm_unbound_agent($fx, subagent_type => $type, record_session_id => 'sess-some-other-session');

    my $r = probe($fx, $aid, $tuid, "$fx->{D}/blueprints/bpx/reports/x.md");
    is($r->{rc}, 2, "SESSION-MISMATCH($type): a worker record for a DIFFERENT session_id grants no reports/ exemption");
    is($r->{err}, $GENERIC_REFUSAL, "SESSION-MISMATCH($type): exact refusal text, as if there were no worker record at all");
}

done_testing();
