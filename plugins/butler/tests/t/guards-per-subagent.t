#!/usr/bin/env perl
# platform: any
# Oracle for package 13-guards-per-subagent (blueprint hook-continuity-remake),
# specs/13-guards-per-subagent-spec.md AC-1..AC-28. plugins/butler/hooks/next/
# guard-writes.sh, plugins/butler/hooks/next/ledger-guard.sh and
# plugins/butler/scripts/BpHook/WriteGuards.pm DO NOT EXIST YET at the time
# this file is written -- every in-process case goes through
# GuardHarness::run_module()/a local resolve()-only twin, which mirrors
# BpHook::main()'s own require-and-call contract, so a missing module fails
# open (rc 0) exactly as the real wrapper would -- legibly, never a crash in
# this file. Every [W]/[S] case spawns the real bash file at that path and
# gets a plain "No such file or directory" until the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text above
# and the already-shipped BpHook.pm (03), BpHook::BindDispatch (12) and
# BpHook::Guards::Common (14) interfaces it documents as reused, never from
# reading any hooks/*.sh source.
#
# NOT RE-EXPRESSED (spec sec 4.1, verbatim, Decision 26 exemptions; codes
# per package 14's spec sec 4.2 -- OVR/LIB/SRC/D3/OTHER):
#
# driver-guard-reach.t
#   assertion                                                          | status
#   ------------------------------------------------------------------ | ------
#   lib.sh is present                                                  | LIB
#   guard-writes.sh is present, ledger-guard.sh is present              | re-expressed: AC-20
#   guard-blueprint-write.sh is present                                | OTHER (guards-remake-blueprint-write.t, SH-1)
#   bp-drive-next.pl is present                                        | OTHER (director; drive-next.t)
#   AC-7 (rc0, BP_DATA_DIR, BP_PROJECT_ROOT, BP_BLUEPRINT, BP_DIR,      | re-expressed: AC-8
#     BP_PACKAGE, write_set, test_paths byte-identical, non-empty)     |
#   AC-31/B14 (BP_LEDGER unset afterwards; child sees BP_DIR etc unset) | re-expressed: AC-16
#   AC-8 (empty write_set -> rc1, guard-writes exits 0)                | re-expressed: AC-15 F6
#   AC-10 body shape of bp_hook_gate (3 unlike, exactly three checks)  | LIB
#   AC-10 behaviour (all three unset -> exit 0, exits the script)      | re-expressed: AC-12, W4
#   AC-1/B1(5), AC-2/B2(2), AC-3/B3(3), AC-5/B5(2)                     | re-expressed: AC-8
#   AC-4/B4(2: under <data>/ and under /tmp/)                          | re-expressed: AC-8; %TEMP% forms: AC-25, AC-26
#   AC-6/B9(3)                                                        | re-expressed: AC-17
#   AC-9/B8 (guard-bash, driver git commit)                            | OTHER (guards-remake-bash.t)
#   AC-11/B7(3)                                                       | re-expressed: AC-12
#   AC-12/B11 F1,F2,F3,F4,F5,F6,F7,F8,F11,F11b (rc/no stderr, 20)      | re-expressed: AC-15
#   AC-12/B11 F9(2), F12(4), F13(2)                                    | re-expressed: AC-15
#   AC-12/B11 F14(2)                                                   | re-expressed: AC-15 F1 (same mechanism)
#   AC-13 F1,F2,F5,F9 (4)                                              | re-expressed: AC-19
#   AC-14 (bp_driver_context defined once, in lib.sh)                  | LIB
#   AC-15 per guard: exactly one bp_driver_context call; regex count;  | LIB
#     bp_drive_any_active present                                     |
#   AC-15 per guard: no bp_drive_active_dir/.drive-solo-active/        | re-expressed: AC-20
#     current.json re-derivation                                      |
#   AC-16, AC-17 (hook table and control)                              | SRC (also listed by package 14)
#   AC-18, AC-19 (blueprint.md denied regardless of driver state)      | OTHER (guards-remake-blueprint-write.t, BW-6)
#   AC-20 (guard-blueprint-write source pin)                           | SRC
#   AC-21,22,23,24,26 (hatch file/env, TTL, advert)                    | OVR (.driver-guards-off,
#                                                                      |   CCPRAXIS_DRIVER_GUARDS_OFF(_TTL_MIN); Decision 68)
#   AC-25 (hatch present, blueprint guard still denies)                | OVR (same hatch; Decision 68)
#   AC-32 (test-writer/implementer solo marker, 4)                     | re-expressed: AC-7
#   AC-32 (stale marker gives driver rules, 2)                         | re-expressed: AC-8
#   AC-27,28,29,30 (director current.json pointer, --help, STATE)      | OTHER (bp-drive-next.pl; package 16 retires it)
#   RT-1 (write to the hatch file denied)                              | re-expressed: AC-10
#   RT-2, RT-3 (V6 widen and blank)                                    | re-expressed: AC-18
#   RT-4 (write to current.json denied)                                | re-expressed: AC-10
#   RT-5 (ambient BP_DRIVER_SESSION on the worker path; no crash)      | re-expressed: AC-12
#   RT-6 (future-dated hatch)                                          | OVR (hatch; Decision 68)
#   RT-7 (empty-scope done removes current.json)                      | OTHER (director; Decision 68)
#
# driver-context-session-scope.t
#   assertion                                                          | status
#   ------------------------------------------------------------------ | ------
#   both guards exist                                                  | re-expressed: AC-20
#   driver, inside the write set: allowed                              | re-expressed: AC-8
#   driver or its subagent, outside the write set: blocked             | re-expressed: AC-8, AC-5
#   another session in the same project: not held                     | re-expressed: AC-11
#   a payload with no session_id keeps any-drive-active (blocked)     | D3 (Decision 3: unattributable payload is
#                                                                      |   never guarded; AC-11 asserts the opposite)
#   the driver may not write a test file, and is told why             | re-expressed: AC-8
#   a bp-test-writer subagent may write its test file                 | re-expressed: AC-7
#   a read-only role gains nothing from agent_type                    | re-expressed: AC-7 (bp-reviewer)
#   drive-letter root form (setup, inside allowed, outside blocked)    | re-expressed: AC-14
#   ledger-guard: driver writing a corrupt ledger is blocked          | re-expressed: AC-17
#   ledger-guard: another session is not affected                    | re-expressed: AC-11
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname basename);
use File::Temp qw(tempfile);
use File::Path qw(make_path remove_tree);
use File::Spec ();
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation up front (GuardHarness itself isolates at "use", this is
# just belt-and-suspenders for readers, per the house idiom).
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $J = JSON::PP->new->utf8->canonical;
(my $BUTLER_DIR = Cwd::abs_path(dirname(__FILE__) . '/../..')) =~ s{\\}{/}g;
my $GUARD_WRITES_SH  = "$BUTLER_DIR/hooks/next/guard-writes.sh";
my $LEDGER_GUARD_SH  = "$BUTLER_DIR/hooks/next/ledger-guard.sh";
my $WRITEGUARDS_PM   = "$BUTLER_DIR/scripts/BpHook/WriteGuards.pm";

# =============================================================================
# Hermetic scratch root: under THIS FILE's own directory, never /tmp, never
# the real %TEMP%, removed at END (spec sec 4 fixture rule). Deliberately NOT
# a File::Temp tempdir(), because the whole point of AC-25..AC-28 is that the
# guard's temp allowance excludes the project root -- if R itself lived under
# the host's real temp dir, every "outside the project root" assertion here
# would be meaningless.
# =============================================================================
(my $TEST_DIR = Cwd::abs_path(dirname(__FILE__))) =~ s{\\}{/}g;
my $SCRATCH_ROOT = "$TEST_DIR/.scratch-guards-per-subagent-$$";
make_path($SCRATCH_ROOT);
my $SCRATCH_SEQ = 0;
END { remove_tree($SCRATCH_ROOT, { safe => 1 }) if defined $SCRATCH_ROOT && -d $SCRATCH_ROOT }

sub scratch_dir {
    my ($name) = @_;
    $name = defined($name) ? $name : 'x';
    my $d = "$SCRATCH_ROOT/" . $name . '-' . (++$SCRATCH_SEQ);
    make_path($d);
    return $d;
}

# ---------------------------------------------------------------------------
# byte / JSON IO helpers
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub write_json { my ($path, $data) = @_; write_bytes($path, $J->encode($data) . "\n") }

# ---------------------------------------------------------------------------
# Ledger body builder (spec sec 4 fixture, all five sections present).
# ---------------------------------------------------------------------------
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
# fixture(%opts) -- the normative fixture (spec sec 4). Returns a hashref:
# { R, D, X, sid }. opts{members} => 2 (default) or 1: how many packages
# inflight.json lists (both fixture packages exist on disk regardless).
# ---------------------------------------------------------------------------
sub fixture {
    my (%o) = @_;
    my $members = $o{members} // 2;
    my $sid     = $o{sid} // 'sess-drv';
    my $base    = $o{base} // scratch_dir('proj');
    my $R = $base;
    my $D = "$R/.ccpraxis-local-data";
    make_path("$D/blueprints/bpx/packages");
    write_ledger($D, package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    write_ledger($D, package => 'p2-b', write_set => 'src/b/',           test_paths => 't/b/');

    my @all_members = ({ blueprint => 'bpx', package => 'p1-a' }, { blueprint => 'bpx', package => 'p2-b' });
    my @use = ($members == 1) ? ($all_members[0]) : @all_members;
    make_path("$D/.drive-solo");
    write_json("$D/.drive-solo/inflight.json", { packages => [ map { { %$_, ledger => 'ignored', since => 1 } } @use ], updated_at => 1 });

    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');

    my $X = "$R-transcripts";
    make_path("$X/$sid/subagents");
    write_json("$X/$sid/subagents/agent-aaaa1.meta.json", { toolUseId => 'toolu_A' });
    write_json("$X/$sid/subagents/agent-bbbb2.meta.json", { toolUseId => 'toolu_B' });
    make_path("$D/.drive-solo/bindings");
    write_json("$D/.drive-solo/bindings/toolu_A.json", { blueprint => 'bpx', package => 'p1-a' });
    write_json("$D/.drive-solo/bindings/toolu_B.json", { blueprint => 'bpx', package => 'p2-b' });

    return { R => $R, D => $D, X => $X, sid => $sid };
}

# ---------------------------------------------------------------------------
# payload builders
# ---------------------------------------------------------------------------
sub driver_payload {
    my (%o) = @_;
    my $p = {
        hook_event_name => ($o{event} // 'PreToolUse'),
        tool_name       => ($o{tool_name} // 'Write'),
        tool_input      => {},
    };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    for my $k (qw(file_path notebook_path content old_string new_string edits replace_all)) {
        $p->{tool_input}{$k} = $o{$k} if exists $o{$k};
    }
    return $p;
}
sub subagent_payload {
    my (%o) = @_;
    my $p = driver_payload(%o);
    $p->{agent_id}        = $o{agent_id}        if exists $o{agent_id};
    $p->{agent_type}      = $o{agent_type}      if exists $o{agent_type};
    $p->{agent_type}    //= 'general-purpose' unless exists $o{agent_type};
    $p->{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    return $p;
}
# Default (Shape A) transcript_path for a subagent of $fx: dirname(T) . "/<sid>/subagents"
# so T = "$fx->{X}/$fx->{sid}.jsonl".
sub shape_a_transcript { my ($fx) = @_; return "$fx->{X}/$fx->{sid}.jsonl" }

# ---------------------------------------------------------------------------
# env builder -- every call sets TMPDIR/TEMP/TMP/LOCALAPPDATA explicitly
# (deleted unless the AC sets them); BP_PROJECT_ROOT/CLAUDE_PROJECT_DIR unset
# except in coordinator cases (spec sec 4 fixture rule).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# run() twins: writes-mode / ledger-mode / direct resolve().
# ---------------------------------------------------------------------------
sub wg_writes { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['writes']) }
sub wg_ledger { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['ledger']) }

my $REQUIRE_OK = eval { require "BpHook/WriteGuards.pm"; 1 };

sub wg_resolve {
    my ($payload, %o) = @_;
    my $env = $o{env} // {};
    local %ENV = %ENV;
    for my $k (keys %$env) { if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} } }
    GuardHarness::load_payload_for_resolve($payload) if defined &GuardHarness::load_payload_for_resolve;
    BpHook::load_payload(ref($payload) eq 'HASH' ? $J->encode($payload) : $payload);
    my $p = BpHook::payload();
    return undef unless $REQUIRE_OK;
    return eval { BpHook::WriteGuards::resolve($p) };
}

sub deny_lines { my ($err) = @_; return grep { length } split /\n/, (defined $err ? $err : '') }

# =============================================================================
# AC-1: two in flight, subagent aaaa1 bound to A.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $ok = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    my $r1 = wg_writes($ok, env => env_for($fx->{D}));
    is($r1->{rc}, 0, 'AC-1: bound-to-A subagent writing src/a/x.pl gives rc 0');
    is($r1->{err}, '', 'AC-1: rc0 case has empty stderr');

    my $bad = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    my $r2 = wg_writes($bad, env => env_for($fx->{D}));
    is($r2->{rc}, 2, 'AC-1: bound-to-A subagent writing src/b/x.pl gives rc 2');
    like($r2->{err}, qr/outside this package's write set/, 'AC-1: deny mentions "outside this package\'s write set"');
    like($r2->{err}, qr/p1-a/, 'AC-1: deny names p1-a');
    like($r2->{err}, qr/src\/b\/x\.pl/, 'AC-1: deny names src/b/x.pl');
    my @lines = deny_lines($r2->{err});
    cmp_ok(scalar(@lines), '<=', 3, 'AC-1: deny is at most 3 lines');
}

# =============================================================================
# AC-2: mirror -- bbbb2 bound B.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $ok = subagent_payload(agent_id => 'bbbb2', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    my $r1 = wg_writes($ok, env => env_for($fx->{D}));
    is($r1->{rc}, 0, 'AC-2: bound-to-B subagent writing src/b/x.pl gives rc 0');

    my $bad = subagent_payload(agent_id => 'bbbb2', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    my $r2 = wg_writes($bad, env => env_for($fx->{D}));
    is($r2->{rc}, 2, 'AC-2: bound-to-B subagent writing src/a/x.pl gives rc 2');
    like($r2->{err}, qr/p2-b/, 'AC-2: deny names p2-b');

    SKIP: {
        skip 'AC-2: BpHook::WriteGuards not requireable yet', 3 unless $REQUIRE_OK;
        my $res = wg_resolve($bad, env => env_for($fx->{D}));
        is(ref($res) eq 'HASH' ? $res->{mode} : undef, 'subagent', 'AC-2: resolve mode is subagent');
        is(ref($res) eq 'HASH' ? $res->{kind} : undef, 'bound', 'AC-2: resolve kind is bound');
        is(ref($res) eq 'HASH' && ref($res->{packages}) eq 'ARRAY' && @{ $res->{packages} } == 1
            ? $res->{packages}[0]{package} : undef, 'p2-b', 'AC-2: resolve packages is exactly [p2-b]');
    }
}

# =============================================================================
# AC-3: transcript shapes B and A(backslashed) resolve identically to AC-1.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $shape_b = "$fx->{X}/$fx->{sid}/subagents/agent-aaaa1.jsonl";
    my $ok_b = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => $shape_b, cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    is(wg_writes($ok_b, env => env_for($fx->{D}))->{rc}, 0, 'AC-3: Shape B, in-set path gives rc 0');
    my $bad_b = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => $shape_b, cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    is(wg_writes($bad_b, env => env_for($fx->{D}))->{rc}, 2, 'AC-3: Shape B, out-of-set path gives rc 2');

    (my $shape_a_bs = shape_a_transcript($fx)) =~ tr{/}{\\};
    my $ok_a = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => $shape_a_bs, cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    is(wg_writes($ok_a, env => env_for($fx->{D}))->{rc}, 0, 'AC-3: Shape A backslashed, in-set path gives rc 0');
    my $bad_a = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => $shape_a_bs, cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    is(wg_writes($bad_a, env => env_for($fx->{D}))->{rc}, 2, 'AC-3: Shape A backslashed, out-of-set path gives rc 2');
}

# =============================================================================
# AC-4: unresolvable subagent, 2 in flight -> refused; /tmp always allowed.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $refusal = "No package binding for this subagent; with 2 packages in flight its edits are refused.";

    my %cases;
    $cases{a_no_meta} = subagent_payload(agent_id => 'ccc01', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ccc02.meta.json", { other => 'x' });
    $cases{b_no_tooluseid} = subagent_payload(agent_id => 'ccc02', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    write_bytes("$fx->{X}/$fx->{sid}/subagents/agent-ccc03.meta.json", 'not json');
    $cases{c_not_json} = subagent_payload(agent_id => 'ccc03', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ccc04.meta.json", { toolUseId => 'toolu_ccc04' });
    $cases{d_no_binding} = subagent_payload(agent_id => 'ccc04', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    $cases{g_bad_agent_id} = subagent_payload(agent_id => '../x', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    for my $name (sort keys %cases) {
        my $r = wg_writes($cases{$name}, env => env_for($fx->{D}));
        is($r->{rc}, 2, "AC-4($name): rc 2");
        is($r->{err}, $refusal . "\n", "AC-4($name): exact refusal text");
    }

    SKIP: {
        skip 'AC-4: BpHook::WriteGuards not requireable yet', 1 unless $REQUIRE_OK;
        my $res = wg_resolve($cases{a_no_meta}, env => env_for($fx->{D}));
        is(ref($res) eq 'HASH' ? $res->{kind} : undef, 'refused', 'AC-4: resolve kind is refused');
    }

    my $tmp_probe = subagent_payload(agent_id => 'ccc01', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => '/tmp/gps-probe.txt');
    is(wg_writes($tmp_probe, env => env_for($fx->{D}))->{rc}, 0, 'AC-4: /tmp write still allows for a refused subagent');
}

# =============================================================================
# AC-4 addendum (Decision 69 A3, red-team H4): a subagent whose BINDING FILE
# EXISTS but names a package that is not usable now (no ledger; a terminal
# status) is REFUSED unconditionally -- never falls back to another
# in-flight package's scope ("sole"), and never to no-guard-at-all (resolve
# undef), regardless of how many OTHER packages are in flight. Only a
# subagent with NO binding at all (AC-4 a/b/c/d/g above) takes that
# fallback. The refusal for a bound-but-unusable package names the bound
# package and is distinct from the generic (no-binding) refusal text.
# =============================================================================
for my $members (2, 1) {
    my $fx = fixture(members => $members);
    my $generic_refusal = "No package binding for this subagent; with $members packages in flight its edits are refused.";

    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ddd05.meta.json", { toolUseId => 'toolu_ddd05' });
    write_json("$fx->{D}/.drive-solo/bindings/toolu_ddd05.json", { blueprint => 'bpx', package => 'p9-x' });
    my $bound_no_ledger = subagent_payload(agent_id => 'ddd05', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    write_ledger($fx->{D}, package => 'p9-done', status => 'done', write_set => 'src/a/', test_paths => 't/a/');
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ddd06.meta.json", { toolUseId => 'toolu_ddd06' });
    write_json("$fx->{D}/.drive-solo/bindings/toolu_ddd06.json", { blueprint => 'bpx', package => 'p9-done' });
    my $bound_done = subagent_payload(agent_id => 'ddd06', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    # the parked-bound-package case the fix-batch explicitly asks for
    write_ledger($fx->{D}, package => 'p9-parked', status => 'parked', write_set => 'src/a/', test_paths => 't/a/');
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-ddd07.meta.json", { toolUseId => 'toolu_ddd07' });
    write_json("$fx->{D}/.drive-solo/bindings/toolu_ddd07.json", { blueprint => 'bpx', package => 'p9-parked' });
    my $bound_parked = subagent_payload(agent_id => 'ddd07', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");

    for my $case ([ bound_no_ledger => $bound_no_ledger, 'p9-x' ],
                  [ bound_done      => $bound_done,      'p9-done' ],
                  [ bound_parked    => $bound_parked,    'p9-parked' ]) {
        my ($label, $payload, $bound_pkg) = @$case;
        my $r = wg_writes($payload, env => env_for($fx->{D}));
        is($r->{rc}, 2, "AC-4addendum($label, members=$members): rc 2 -- never falls back, even with $members member(s) in flight");
        my @lines = deny_lines($r->{err});
        cmp_ok(scalar(@lines), '<=', 3, "AC-4addendum($label, members=$members): deny is at most 3 lines");
        like($r->{err}, qr/\Q$bound_pkg\E/, "AC-4addendum($label, members=$members): deny names the bound package '$bound_pkg'");
        isnt($r->{err}, $generic_refusal . "\n",
            "AC-4addendum($label, members=$members): deny text differs from the generic no-binding refusal");

        my $tmp = subagent_payload(agent_id => $payload->{agent_id}, session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => '/tmp/gps-probe-addendum.txt');
        is(wg_writes($tmp, env => env_for($fx->{D}))->{rc}, 0,
            "AC-4addendum($label, members=$members): /tmp write still allows");
    }
}

# =============================================================================
# AC-4 addendum (Decision 69 A3, red-team H4): usable() and the ledger-mode
# V2 frontmatter check must agree on a first line of "---" followed by
# trailing whitespace -- accepted by BOTH, never by only one. A subagent
# bound to such a ledger is usable (not refused), and the same content is
# not V2-denied as unparseable frontmatter.
# =============================================================================
{
    my $fx = fixture(members => 1);
    write_bytes("$fx->{D}/blueprints/bpx/packages/p1-a.md",
        "--- \npackage: p1-a\nblueprint: bpx\nstatus: running\nwrite_set: src/a/\ntest_paths: t/a/\n"
      . "last_updated: 2025-01-01T00:00:00Z\n---\n\n## Next action\n\nx\n\n## Decisions & attempt log\n\nx\n\n"
      . "## Pipeline\n\nx\n\n## Outputs\n\nx\n\n## Escalation\n\nx\n");
    my $sub_ok = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    is(wg_writes($sub_ok, env => env_for($fx->{D}))->{rc}, 0,
        'AC-4addendum(usable/V2 "--- " alignment): a bound subagent\'s in-set write gives rc 0 (usable, not refused)');
    my $sub_bad = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
    my $rbad = wg_writes($sub_bad, env => env_for($fx->{D}));
    is($rbad->{rc}, 2, 'AC-4addendum(usable/V2 "--- " alignment): out-of-set write still gives rc 2 (sole, not refused/undef)');
    like($rbad->{err}, qr/p1-a/, 'AC-4addendum(usable/V2 "--- " alignment): deny names p1-a, not a fallback refusal');

    my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
        file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md",
        content => "--- \npackage: p1-a\nblueprint: bpx\nstatus: running\nwrite_set: src/a/\ntest_paths: t/a/\n"
                 . "last_updated: 2025-01-01T00:00:00Z\n---\n\n## Next action\n\nx\n\n## Decisions & attempt log\n\nx\n\n"
                 . "## Pipeline\n\nx\n\n## Outputs\n\nx\n\n## Escalation\n\nx\n"), env => env_for($fx->{D}));
    is($r->{rc}, 0, 'AC-4addendum(usable/V2 "--- " alignment): ledger-mode V2 also accepts "--- " as valid frontmatter');
}

# =============================================================================
# AC-5: unresolvable subagent, 1 member -> sole; switch-off equivalence.
# =============================================================================
{
    for my $conc (undef, '0', '1') {
        my $fx = fixture(members => 1);
        my $unres = subagent_payload(agent_id => 'ccc09', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
        my $env = env_for($fx->{D}, BUTLER_CONCURRENCY => $conc);
        my $label = defined($conc) ? "conc=$conc" : 'conc=unset';
        is(wg_writes($unres, env => $env)->{rc}, 0, "AC-5($label): sole member, in-set path gives rc 0");
        my $unres_bad = subagent_payload(agent_id => 'ccc09', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
        my $rbad = wg_writes($unres_bad, env => $env);
        is($rbad->{rc}, 2, "AC-5($label): sole member, out-of-set path gives rc 2");
        like($rbad->{err}, qr/p1-a/, "AC-5($label): deny names p1-a");
    }
    SKIP: {
        skip 'AC-5: BpHook::WriteGuards not requireable yet', 1 unless $REQUIRE_OK;
        my $fx = fixture(members => 1);
        my $unres = subagent_payload(agent_id => 'ccc09', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
        my $res = wg_resolve($unres, env => env_for($fx->{D}));
        is(ref($res) eq 'HASH' ? $res->{kind} : undef, 'sole', 'AC-5: resolve kind is sole');
    }
}

# =============================================================================
# AC-6: subagent bound A -- only its blueprint dir, no data-dir allowance.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $sub = sub {
        my ($fp) = @_;
        return subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => $fp);
    };
    is(wg_writes($sub->("$fx->{D}/blueprints/bpx/reports/r.md"), env => env_for($fx->{D}))->{rc}, 0,
        'AC-6: writing the bound package\'s blueprint dir gives rc 0');
    is(wg_writes($sub->("$fx->{D}/.drive-solo/inflight.json"), env => env_for($fx->{D}))->{rc}, 2,
        'AC-6: writing .drive-solo/inflight.json gives rc 2');
    is(wg_writes($sub->("$fx->{D}/notes/n.md"), env => env_for($fx->{D}))->{rc}, 2,
        'AC-6: writing the data dir outside any blueprint dir gives rc 2 (no data-dir allowance)');
    is(wg_writes($sub->("$fx->{D}/blueprints/other/x.md"), env => env_for($fx->{D}))->{rc}, 2,
        'AC-6: writing a different blueprint dir gives rc 2');
}

# =============================================================================
# AC-7: roles, subagent bound A.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $sub = sub {
        my (%o) = @_;
        return subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, %o);
    };

    my $r1 = wg_writes($sub->(agent_type => 'butler:bp-test-writer', file_path => "$fx->{R}/t/a/x.t"), env => env_for($fx->{D}));
    is($r1->{rc}, 0, 'AC-7(test-writer): writing its own test path gives rc 0');
    my $r2 = wg_writes($sub->(agent_type => 'butler:bp-test-writer', file_path => "$fx->{R}/src/a/x.pl"), env => env_for($fx->{D}));
    is($r2->{rc}, 2, 'AC-7(test-writer): writing outside test_paths gives rc 2');
    like($r2->{err}, qr/may only write under the package's test paths/, 'AC-7(test-writer): deny text');
    my $r3 = wg_writes($sub->(agent_type => 'butler:bp-test-writer', file_path => "$fx->{R}/t/b/x.t"), env => env_for($fx->{D}));
    is($r3->{rc}, 2, 'AC-7(test-writer): writing another package\'s test path gives rc 2');

    my $r4 = wg_writes($sub->(agent_type => 'bp-implementer', file_path => "$fx->{R}/t/a/x.t"), env => env_for($fx->{D}));
    is($r4->{rc}, 2, 'AC-7(implementer): writing a test file gives rc 2');
    like($r4->{err}, qr/bp-implementer may not modify test files/, 'AC-7(implementer): deny names bp-implementer');
    like($r4->{err}, qr/oracle/, 'AC-7(implementer): deny mentions oracle');
    like($r4->{err}, qr/'t\/a\/'/, 'AC-7(implementer): deny quotes the matched pattern');
    my $r5 = wg_writes($sub->(agent_type => 'bp-implementer', file_path => "$fx->{R}/src/a/x.pl"), env => env_for($fx->{D}));
    is($r5->{rc}, 0, 'AC-7(implementer): writing its write_set gives rc 0');

    my $r6 = wg_writes($sub->(agent_type => 'bp-ui-prober', file_path => "$fx->{R}/t/a/x.t"), env => env_for($fx->{D}));
    is($r6->{rc}, 0, 'AC-7(ui-prober): writing a test path gives rc 0');
    my $r7 = wg_writes($sub->(agent_type => 'bp-ui-prober', file_path => "$fx->{R}/src/a/x.pl"), env => env_for($fx->{D}));
    is($r7->{rc}, 2, 'AC-7(ui-prober): writing implementation gives rc 2');

    my $r8 = wg_writes($sub->(agent_type => 'butler:bp-reviewer', file_path => "$fx->{R}/t/a/x.t"), env => env_for($fx->{D}));
    is($r8->{rc}, 2, 'AC-7(reviewer, non-writer): writing a test file gives rc 2');

    my $r9 = wg_writes($sub->(agent_type => 'general-purpose', file_path => "$fx->{R}/docs/a.md"), env => env_for($fx->{D}));
    is($r9->{rc}, 0, 'AC-7(general-purpose): writing docs/a.md (write_set) gives rc 0');
}

# =============================================================================
# AC-8: driver main thread, 1 member; leftover stale .active-worker unread.
# =============================================================================
{
    my $fx = fixture(members => 1);
    write_bytes("$fx->{D}/.drive-solo/.active-worker", 'bp-implementer');
    my $env = env_for($fx->{D});
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    my $r1 = wg_writes($drv->("$fx->{R}/t/a/oracle.t"), env => $env);
    is($r1->{rc}, 2, 'AC-8: driver writing t/a/oracle.t gives rc 2');
    like($r1->{err}, qr/the driver may not modify test files/, 'AC-8: deny names "the driver"');
    like($r1->{err}, qr/oracle/, 'AC-8: deny mentions oracle');
    like($r1->{err}, qr/p1-a/, 'AC-8: deny names p1-a');
    like($r1->{err}, qr/t\/a\//, 'AC-8: deny names t/a/');

    my $r2 = wg_writes($drv->("$fx->{R}/src/a/x.pl"), env => $env);
    is($r2->{rc}, 0, 'AC-8: driver writing src/a/x.pl gives rc 0');
    is($r2->{err}, '', 'AC-8: that rc0 case has empty stderr');

    my $r3 = wg_writes($drv->("$fx->{R}/other/x.txt"), env => $env);
    is($r3->{rc}, 2, 'AC-8: driver writing other/x.txt gives rc 2');
    like($r3->{err}, qr/outside this package's write set/, 'AC-8: deny mentions "outside this package\'s write set"');
    like($r3->{err}, qr/p1-a/, 'AC-8: deny names p1-a (write-set case)');

    my $r4 = wg_writes($drv->("$fx->{D}/blueprints/bpx/reports/x.md"), env => $env);
    is($r4->{rc}, 0, 'AC-8: driver writing the data dir (reports) gives rc 0');

    my $r5 = wg_writes($drv->('/tmp/gps-probe.txt'), env => $env);
    is($r5->{rc}, 0, 'AC-8: driver writing /tmp gives rc 0');

    my $sibling = scratch_dir('sibling');
    my $r6 = wg_writes($drv->("$sibling/x.txt"), env => $env);
    is($r6->{rc}, 2, 'AC-8: driver writing a sibling of R gives rc 2');
    like($r6->{err}, qr/outside the project root/, 'AC-8: deny mentions "outside the project root"');

    SKIP: {
        skip 'AC-8: BpHook::WriteGuards not requireable yet', 3 unless $REQUIRE_OK;
        my $res = wg_resolve($drv->("$fx->{R}/src/a/x.pl"), env => $env);
        is(ref($res) eq 'HASH' ? $res->{kind} : undef, 'single', 'AC-8: resolve kind is single');
        my $p0 = (ref($res) eq 'HASH' && ref($res->{packages}) eq 'ARRAY') ? $res->{packages}[0] : undef;
        is(ref($p0) eq 'HASH' ? $p0->{write_set} : undef, 'src/a/:docs/a.md', 'AC-8: resolve packages[0].write_set byte-identical to the ledger');
        is(ref($p0) eq 'HASH' ? $p0->{test_paths} : undef, 't/a/', 'AC-8: resolve packages[0].test_paths byte-identical to the ledger');
    }
}

# =============================================================================
# AC-9: driver main thread, two members (union); six members (list capped).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $env = env_for($fx->{D});
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    is(wg_writes($drv->("$fx->{R}/src/a/x.pl"), env => $env)->{rc}, 0, 'AC-9: driver, union, src/a/x.pl gives rc 0');
    is(wg_writes($drv->("$fx->{R}/src/b/x.pl"), env => $env)->{rc}, 0, 'AC-9: driver, union, src/b/x.pl gives rc 0');

    my $rout = wg_writes($drv->("$fx->{R}/other/x.txt"), env => $env);
    is($rout->{rc}, 2, 'AC-9: driver, out of union, gives rc 2');
    like($rout->{err}, qr/bpx\/p1-a/, 'AC-9: deny names bpx/p1-a');
    like($rout->{err}, qr/bpx\/p2-b/, 'AC-9: deny names bpx/p2-b');
    cmp_ok(scalar(deny_lines($rout->{err})), '<=', 3, 'AC-9: union deny is at most 3 lines');
    # Decision 69 A7 (review M2): T5's exact wording (spec sec 3.2), never the
    # T4 single-package phrasing "outside this package's write set".
    like($rout->{err}, qr/outside the write set of every package in flight/,
        'AC-9: union deny uses T5\'s exact phrase "outside the write set of every package in flight"');
    unlike($rout->{err}, qr/outside this package's write set/,
        'AC-9: union deny never uses the single-package T4 phrasing');

    my $rta = wg_writes($drv->("$fx->{R}/t/a/x.t"), env => $env);
    is($rta->{rc}, 2, 'AC-9: driver writing t/a/x.t gives rc 2');
    like($rta->{err}, qr/the driver may not modify test files/, 'AC-9: t/a/x.t deny names "the driver"');
    my $rtb = wg_writes($drv->("$fx->{R}/t/b/x.t"), env => $env);
    is($rtb->{rc}, 2, 'AC-9: driver writing t/b/x.t gives rc 2');
    like($rtb->{err}, qr/the driver may not modify test files/, 'AC-9: t/b/x.t deny names "the driver"');

    # six members
    my $fx6 = fixture(members => 1, base => scratch_dir('six'));
    for my $i (3 .. 6) {
        write_ledger($fx6->{D}, package => "p$i-x", write_set => "src/p$i/", test_paths => "t/p$i/");
    }
    write_json("$fx6->{D}/.drive-solo/inflight.json", { packages => [
        map { { blueprint => 'bpx', package => $_, ledger => 'ignored', since => 1 } }
            ('p1-a', 'p2-b', 'p3-x', 'p4-x', 'p5-x', 'p6-x')
    ], updated_at => 1 });
    my $env6 = env_for($fx6->{D});
    my $r6 = wg_writes(driver_payload(session_id => $fx6->{sid}, cwd => $fx6->{R}, file_path => "$fx6->{R}/other/x.txt"), env => $env6);
    is($r6->{rc}, 2, 'AC-9: six members, out-of-set gives rc 2');
    my @lines6 = deny_lines($r6->{err});
    # Decision 69 A7 (review M2): spec sec 3.2's T5 is exactly 2 lines -- the
    # BLOCKED line (with the capped, inline member list) and the one-sentence
    # instruction. Sec 3.8 caps guard-writes at <= 3 lines overall; T5 never
    # needs the third. The list shows at most 4 entries then "...and <k> more".
    is(scalar(@lines6), 2, 'AC-9: six-member deny has exactly 2 lines (T5: BLOCKED line + instruction line)')
        or diag("got:\n$r6->{err}");
    like($r6->{err}, qr/outside the write set of every package in flight/,
        'AC-9: six-member deny uses T5\'s exact phrase');
    like($r6->{err}, qr/\.\.\.and 2 more/, 'AC-9: six-member deny says "...and 2 more"');
    like($r6->{err}, qr/The driver's own edits must fall inside one in-flight package's write set\./,
        'AC-9: six-member deny\'s second line is T5\'s exact instruction sentence');
    for my $l (@lines6) { cmp_ok(length($l), '<=', 160, 'AC-9: six-member deny line is at most 160 chars') }
}

# =============================================================================
# AC-10: driver control plane -- .drive-solo/* denied, D/notes allowed.
# =============================================================================
{
    my $fx = fixture(members => 1);
    my $env = env_for($fx->{D});
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    is(wg_writes($drv->("$fx->{D}/.drive-solo/.driver-guards-off"), env => $env)->{rc}, 2,
        'AC-10: writing .driver-guards-off gives rc 2');
    is(wg_writes($drv->("$fx->{D}/.drive-solo/current.json"), env => $env)->{rc}, 2,
        'AC-10: writing current.json gives rc 2');
    is(wg_writes($drv->("$fx->{D}/.drive-solo/inflight.json"), env => $env)->{rc}, 2,
        'AC-10: writing inflight.json gives rc 2');
    is(wg_writes($drv->("$fx->{D}/.drive-solo/bindings/toolu_A.json"), env => $env)->{rc}, 2,
        'AC-10: writing a binding file gives rc 2');
    is(wg_writes($drv->("$fx->{D}/notes/n.md"), env => $env)->{rc}, 0,
        'AC-10: writing the data dir outside .drive-solo gives rc 0');
}

# =============================================================================
# AC-11: another session is never guarded.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $env = env_for($fx->{D});
    # Decision 69 B1 (review M3): DC1c ("even while this project has packages
    # in flight and bindings") is only exercised when a driving session IS
    # armed in the SAME state root as the "another session" case. Every
    # fresh_state() below is followed by re-arming 'sess-drv' as driver, and
    # each case is followed by a CONTROL proving sess-drv itself still denies
    # in that same state root -- so a regression to "any armed driver in this
    # project guards every session" (the Decision 3 bug) would flip the
    # control from 2 to something else, or the control would catch a
    # do-nothing fixture. Both make the main assertion non-vacuous.
    my $control = sub {
        my ($label) = @_;
        my $pctrl = driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
        is(wg_writes($pctrl, env => $env)->{rc}, 2,
            "AC-11($label): control -- sess-drv itself still denies other/x.txt in the same state root");
    };

    for my $case ([undef, 'sess-other-a'], ['reporter', 'sess-other-b'], ['manual', 'sess-other-c']) {
        my ($role, $sid) = @$case;
        GuardHarness::fresh_state();
        GuardHarness::arm('sess-drv', 'driver');
        GuardHarness::arm($sid, $role) if defined $role;
        my $p = driver_payload(session_id => $sid, cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
        my $r = wg_writes($p, env => $env);
        my $label = defined($role) ? $role : 'never-armed';
        is($r->{rc}, 0, "AC-11($label): another session's write gives rc 0");
        is($r->{err}, '', "AC-11($label): stderr empty");
        $control->($label);
    }

    # another session, but with agent_id -- meta.json lives under X/sess-other/...
    GuardHarness::fresh_state();
    GuardHarness::arm('sess-drv', 'driver');
    my $sid_sub = 'sess-other-sub';
    make_path("$fx->{X}/$sid_sub/subagents");
    write_json("$fx->{X}/$sid_sub/subagents/agent-aaaa1.meta.json", { toolUseId => 'toolu_A' });
    my $psub = subagent_payload(agent_id => 'aaaa1', session_id => $sid_sub,
        transcript_path => "$fx->{X}/$sid_sub.jsonl", cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
    is(wg_writes($psub, env => $env)->{rc}, 0, 'AC-11(other, subagent shape): rc 0');
    $control->('other, subagent shape');

    # ledger mode, another session, corrupt content
    GuardHarness::fresh_state();
    GuardHarness::arm('sess-drv', 'driver');
    my $sid_l = 'sess-other-ledger';
    my $pled = driver_payload(session_id => $sid_l, cwd => $fx->{R},
        tool_name => 'Write', file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md", content => 'not a valid ledger at all');
    is(wg_ledger($pled, env => $env)->{rc}, 0, 'AC-11(other, ledger mode): corrupt write still gives rc 0');
    $control->('other, ledger mode');

    # no session_id at all, both modes
    GuardHarness::fresh_state();
    GuardHarness::arm('sess-drv', 'driver');
    my $pnosid = driver_payload(cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
    is(wg_writes($pnosid, env => $env)->{rc}, 0, 'AC-11(no session_id, writes): rc 0');
    my $pnosid_l = driver_payload(cwd => $fx->{R}, tool_name => 'Write',
        file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md", content => 'not a valid ledger at all');
    is(wg_ledger($pnosid_l, env => $env)->{rc}, 0, 'AC-11(no session_id, ledger): rc 0');
    $control->('no session_id');

    # [W]
    GuardHarness::fresh_state();
    my $pw = driver_payload(session_id => 'sess-other-w', cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt");
    my $rw = GuardHarness::run_wrapper($GUARD_WRITES_SH, $pw, env => $env);
    is($rw->{rc}, 0, 'AC-11 [W]: the unarmed case through the guard-writes wrapper gives rc 0');
}

# =============================================================================
# AC-12: coordinator path.
# =============================================================================
{
    my $fx = fixture(members => 1); # R/D not otherwise used by the coordinator path here
    my $R = scratch_dir('coord-proj');
    make_path("$R/.ccpraxis-local-data/blueprints/bpx/packages");
    make_path("$R/.ccpraxis-local-data/runs");
    # BP_DIR is a STRICT SUBDIRECTORY of the data dir here (never coincides with
    # "$R/.ccpraxis-local-data/runs/"), unlike AC-13's BP_DIR=data-dir fixture --
    # Decision 69 A1 / review B1: the marker lives at "$BP_DIR/runs/", never at
    # "<data>/runs/". Getting this wrong is exactly the defect B1 found.
    my $BP_DIR = "$R/.ccpraxis-local-data/blueprints/bpx";
    make_path("$BP_DIR/runs");
    my %coord_env = (
        CCPRAXIS_DATA_DIR  => undef,
        TMPDIR => undef, TEMP => undef, TMP => undef, LOCALAPPDATA => undef,
        BP_LEDGER      => "$BP_DIR/packages/p1-a.md",
        BP_DIR         => $BP_DIR,
        BP_PROJECT_ROOT=> $R,
        CLAUDE_PROJECT_DIR => $R,
        BP_PACKAGE     => 'p1-a',
        BP_WRITE_SET   => 'src/:docs/api.md',
        BP_TEST_PATHS  => 't/',
    );
    my $p = sub { my ($fp) = @_; return driver_payload(cwd => $R, file_path => $fp) };

    is(wg_writes($p->("$R/src/x.pl"), env => \%coord_env)->{rc}, 0, 'AC-12: coordinator, src/x.pl gives rc 0');
    is(wg_writes($p->("$R/other/x.txt"), env => \%coord_env)->{rc}, 2, 'AC-12: coordinator, other/x.txt gives rc 2');

    # Decision 69 A1 (review B1 / red-team H1): the marker is read from
    # "$BP_DIR/runs/<pkg>.active-worker" -- lib.sh:320 marker_path() and
    # TrackDispatch.pm:463 are the production writer/reader. NOT from
    # "<data>/runs/" (see the negative case right below).
    write_bytes("$BP_DIR/runs/p1-a.active-worker", 'bp-implementer');
    is(wg_writes($p->("$R/t/x.t"), env => \%coord_env)->{rc}, 2, 'AC-12(A1): coordinator+implementer-marker at $BP_DIR/runs, t/x.t gives rc 2');
    unlink("$BP_DIR/runs/p1-a.active-worker");
    is(wg_writes($p->("$R/t/x.t"), env => \%coord_env)->{rc}, 0, 'AC-12: coordinator, no marker, t/x.t gives rc 0 (may still write tests)');

    # Negative: a marker at the OLD, wrong location ("<data>/runs/", i.e.
    # "<root>/.ccpraxis-local-data/runs/") must NOT be read. worker resolves to
    # '', so t/x.t still gives rc 0 -- proving the module does not fall back to
    # the wrong path and silently "work anyway".
    make_path("$R/.ccpraxis-local-data/runs");
    write_bytes("$R/.ccpraxis-local-data/runs/p1-a.active-worker", 'bp-implementer');
    is(wg_writes($p->("$R/t/x.t"), env => \%coord_env)->{rc}, 0,
        'AC-12(A1): a marker at the OLD wrong path ("<data>/runs/") is not read; worker stays \'\' and t/x.t gives rc 0');
    unlink("$R/.ccpraxis-local-data/runs/p1-a.active-worker");

    my %env_ambient = (%coord_env, BP_DRIVER_SESSION => '1');
    my $ramb = wg_writes($p->("$R/other/x.txt"), env => \%env_ambient);
    is($ramb->{rc}, 2, 'AC-12: ambient BP_DRIVER_SESSION does not change the coordinator verdict');
    unlike($ramb->{err}, qr/unbound variable/, 'AC-12: no "unbound variable" leaks into stderr');

    my %env_no_dir = (%coord_env, BP_DIR => undef);
    is(wg_writes($p->("$R/other/x.txt"), env => \%env_no_dir)->{rc}, 0, 'AC-12: empty BP_DIR gives rc 0');
    my %env_no_root = (%coord_env, BP_PROJECT_ROOT => undef);
    is(wg_writes($p->("$R/other/x.txt"), env => \%env_no_root)->{rc}, 0, 'AC-12: empty BP_PROJECT_ROOT gives rc 0');

    GuardHarness::fresh_state();
    GuardHarness::arm('coord-armed-sid', 'driver');
    my $p_armed = driver_payload(session_id => 'coord-armed-sid', cwd => $R, file_path => "$R/other/x.txt");
    is(wg_writes($p_armed, env => \%coord_env)->{rc}, 2, 'AC-12: an armed-as-driver session on the coordinator path still denies');

    is(wg_writes($p->("$BP_DIR/reports/x.md"), env => \%coord_env)->{rc}, 0, 'AC-12: BP_DIR/reports/x.md gives rc 0');
}

# =============================================================================
# AC-13: write-set matching (2.7), through the coordinator env.
# =============================================================================
{
    my $R = scratch_dir('match-proj');
    make_path("$R/.ccpraxis-local-data/runs");
    write_bytes("$R/.ccpraxis-local-data/runs/pM.active-worker", 'bp-implementer');
    my %env = (
        CCPRAXIS_DATA_DIR => undef, TMPDIR => undef, TEMP => undef, TMP => undef, LOCALAPPDATA => undef,
        BP_LEDGER => "$R/somepkg.md", BP_DIR => "$R/.ccpraxis-local-data", BP_PROJECT_ROOT => $R,
        BP_PACKAGE => 'pM',
        BP_TEST_PATHS => 'plugins/butler/',
        BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl',
    );
    my $p = sub { my ($fp) = @_; return driver_payload(cwd => $R, file_path => $fp) };

    is(wg_writes($p->("$R/plugins/butler/scripts/bp-blueprint.pl"), env => \%env)->{rc}, 0,
        'AC-13: write_set exact file gives rc 0');
    my $rtest = wg_writes($p->("$R/plugins/butler/tests/t/42-x.t"), env => \%env);
    is($rtest->{rc}, 2, 'AC-13: test_paths file with implementer gives rc 2');
    like($rtest->{err}, qr/may not modify test files/, 'AC-13: deny mentions "may not modify test files"');
    like($rtest->{err}, qr/plugins\/butler\//, 'AC-13: deny names plugins/butler/');

    my %env_tie = (%env, BP_WRITE_SET => 'plugins/butler/tests/t/', BP_TEST_PATHS => 'plugins/butler/tests/t/');
    is(wg_writes($p->("$R/plugins/butler/tests/t/x.t"), env => \%env_tie)->{rc}, 2, 'AC-13: a tie gives rc 2 (test wins)');

    my %env_ws_specific = (%env, BP_WRITE_SET => 'plugins/butler/tests/t/42-x.t', BP_TEST_PATHS => 'plugins/butler/');
    is(wg_writes($p->("$R/plugins/butler/tests/t/42-x.t"), env => \%env_ws_specific)->{rc}, 2,
        'AC-13: a more specific write_set does not take a real test file away from test_paths');

    write_bytes("$R/.ccpraxis-local-data/runs/pM.active-worker", 'bp-test-writer');
    is(wg_writes($p->("$R/plugins/butler/scripts/bp-blueprint.pl"), env => \%env)->{rc}, 2,
        'AC-13: a test-writer writing the write_set-only file gives rc 2');
    unlink("$R/.ccpraxis-local-data/runs/pM.active-worker");

    my %env_star = (%env, BP_WRITE_SET => 'src/*.pl');
    is(wg_writes($p->("$R/src/a/b.pl"), env => \%env_star)->{rc}, 0, 'AC-13: src/*.pl matches src/a/b.pl (* crosses /)');

    my %env_q = (%env, BP_WRITE_SET => 'src/?.pl');
    is(wg_writes($p->("$R/src/x.pl"), env => \%env_q)->{rc}, 0, 'AC-13: src/?.pl matches src/x.pl');
    is(wg_writes($p->("$R/src/xy.pl"), env => \%env_q)->{rc}, 2, 'AC-13: src/?.pl does not match src/xy.pl');

    my %env_br = (%env, BP_WRITE_SET => 'src/[ab].pl');
    is(wg_writes($p->("$R/src/a.pl"), env => \%env_br)->{rc}, 0, 'AC-13: src/[ab].pl matches src/a.pl');

    my %env_pfx = (%env, BP_WRITE_SET => 'src*/');
    is(wg_writes($p->("$R/srcx/y"), env => \%env_pfx)->{rc}, 2, 'AC-13: prefix "src*/" does not match srcx/y');

    my %env_empty_elem = (%env, BP_WRITE_SET => 'a.pm::b.t');
    is(wg_writes($p->("$R/b.t"), env => \%env_empty_elem)->{rc}, 0, 'AC-13: an empty field between "::" is skipped, b.t still matches');

    my %env_ws_note = (%env, BP_WRITE_SET => 'a.pm:b.t -- note');
    my $rnote = wg_writes($p->("$R/b.t"), env => \%env_ws_note);
    is($rnote->{rc}, 2, 'AC-13: a field containing whitespace gives rc 2 (T4)');
    like($rnote->{err}, qr/pattern\(s\) after splitting on ":"/, 'AC-13: T4 mentions the split-on-":" phrasing');
    like($rnote->{err}, qr/contains whitespace/, 'AC-13: T4 flags the whitespace field');
}

# =============================================================================
# AC-14: path forms.
# =============================================================================
{
    my $fx = fixture(members => 1);
    my $env = env_for($fx->{D});
    my $R = $fx->{R};
    (my $R_posix = $R) =~ s{^([A-Za-z]):/}{'/' . lc($1) . '/'}e;
    my $has_drive_forms = ($R =~ m{^[A-Za-z]:/}) ? 1 : 0;

    my $verdict = sub {
        my ($fp, %o) = @_;
        my %p = (session_id => $fx->{sid}, file_path => $fp);
        $p{cwd} = $o{cwd} if exists $o{cwd};
        return wg_writes(driver_payload(%p), env => $env)->{rc};
    };
    my $base_in  = $verdict->("$R/src/a/x.pl", cwd => $R);
    my $base_out = $verdict->("$R/other/x.txt", cwd => $R);

  SKIP: {
        skip 'AC-14: root has no drive-letter form to convert', 4 unless $has_drive_forms;
        is($verdict->("$R_posix/src/a/x.pl", cwd => $R), $base_in, 'AC-14(a posix root): in-set verdict matches forward-slash form');
        is($verdict->("$R_posix/other/x.txt", cwd => $R), $base_out, 'AC-14(a posix root): out-of-set verdict matches forward-slash form');
        (my $R_other_case = $R) =~ s{^([A-Za-z]):}{ (uc($1) eq $1 ? lc($1) : uc($1)) . ':' }e;
        is($verdict->("$R_other_case/src/a/x.pl", cwd => $R), $base_in, 'AC-14(b other-case drive): in-set verdict matches');
        is($verdict->("$R_other_case/other/x.txt", cwd => $R), $base_out, 'AC-14(b other-case drive): out-of-set verdict matches');
    }

    (my $R_bs = $R) =~ tr{/}{\\};
    is($verdict->("$R_bs\\src\\a\\x.pl", cwd => $R), $base_in, 'AC-14(c backslashed): in-set verdict matches');
    is($verdict->("$R_bs\\other\\x.txt", cwd => $R), $base_out, 'AC-14(c backslashed): out-of-set verdict matches');

    is($verdict->('src/a/x.pl', cwd => $R), $base_in, 'AC-14(d relative + cwd): in-set verdict matches');
    is($verdict->('other/x.txt', cwd => $R), $base_out, 'AC-14(d relative + cwd): out-of-set verdict matches');

    is($verdict->("$R/src/a/../a/x.pl", cwd => $R), $base_in, 'AC-14(e lexical ..): in-set verdict matches');

    {
        my $saved = Cwd::getcwd();
        chdir($R) or die "cannot chdir to $R: $!";
        my $rc_in  = wg_writes(driver_payload(session_id => $fx->{sid}, file_path => 'src/a/x.pl'), env => $env)->{rc};
        my $rc_out = wg_writes(driver_payload(session_id => $fx->{sid}, file_path => 'other/x.txt'), env => $env)->{rc};
        chdir($saved) if defined $saved;
        is($rc_in, $base_in, 'AC-14(f relative, no cwd key): in-set verdict matches');
        is($rc_out, $base_out, 'AC-14(f relative, no cwd key): out-of-set verdict matches');
    }

    # A fixture whose root contains a directory named "André".
    my $char_e9 = "Andr\x{e9}-root";
    my $bytes_e9 = do { my $c = $char_e9; utf8::encode($c); $c };
    my $base_e9 = scratch_dir('unicode-base');
    my $R2 = "$base_e9/$bytes_e9";
    my $fx2 = fixture(members => 1, base => $R2);
    my $R2c = $fx2->{R}; utf8::decode($R2c);   # payloads carry the JSON character form (cf. AC-26)
    my $fp_ok  = "$R2c/src/a/x.pl";
    my $fp_bad = "$R2c/other/x.txt";
    is(wg_writes(driver_payload(session_id => $fx2->{sid}, cwd => $R2c, file_path => $fp_ok), env => env_for($fx2->{D}))->{rc}, 0,
        'AC-14(Andre root): in-set path gives rc 0');
    is(wg_writes(driver_payload(session_id => $fx2->{sid}, cwd => $R2c, file_path => $fp_bad), env => env_for($fx2->{D}))->{rc}, 2,
        'AC-14(Andre root): out-of-set path gives rc 2');
}

# =============================================================================
# AC-15: fault matrix, driver main thread, target t/a/oracle.t.
# =============================================================================
{
    my $target = sub { my ($fx) = @_; return "$fx->{R}/t/a/oracle.t" };
    my $run = sub {
        my ($fx, $label) = @_;
        my $r = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $target->($fx)), env => env_for($fx->{D}));
        is($r->{rc}, 0, "AC-15($label): rc 0");
        is($r->{err}, '', "AC-15($label): stderr empty");
        return $r;
    };

    { my $fx = fixture(members => 1); unlink("$fx->{D}/.drive-solo/inflight.json"); $run->($fx, 'F1 no inflight/current'); }
    { my $fx = fixture(members => 1);
      write_bytes("$fx->{D}/.drive-solo/inflight.json", '{{{not json');
      write_bytes("$fx->{D}/.drive-solo/current.json", '{{{not json');
      $run->($fx, 'F2 both malformed'); }
    { my $fx = fixture(members => 1); remove_tree("$fx->{D}/blueprints/bpx"); $run->($fx, 'F3 no blueprint dir'); }
    { my $fx = fixture(members => 1); unlink("$fx->{D}/blueprints/bpx/packages/p1-a.md"); $run->($fx, 'F4 no ledger file'); }
    { my $fx = fixture(members => 1); write_bytes("$fx->{D}/blueprints/bpx/packages/p1-a.md", "not frontmatter\n---\n"); $run->($fx, 'F5 first line not ---'); }
    { my $fx = fixture(members => 1); write_ledger($fx->{D}, package => 'p1-a', write_set => '', test_paths => 't/a/');
      $run->($fx, 'F6 empty write_set');
      SKIP: { skip 'AC-15 F6: BpHook::WriteGuards not requireable yet', 1 unless $REQUIRE_OK;
        is(wg_resolve(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $target->($fx)), env => env_for($fx->{D})), undef,
            'AC-15 F6: resolve() is undef'); } }
    { my $fx = fixture(members => 1); write_ledger($fx->{D}, package => 'p1-a', status => 'done', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
      $run->($fx, 'F7 status done'); }
    { my $fx = fixture(members => 1);
      write_bytes("$fx->{D}/blueprints/bpx/packages/p1-a.md", "---\npackage: p1-a\nblueprint: bpx\nwrite_set: src/a/\ntest_paths: t/a/\nlast_updated: 2025-01-01T00:00:00Z\n---\n\n## Next action\n\nx\n\n## Decisions & attempt log\n\nx\n\n## Pipeline\n\nx\n\n## Outputs\n\nx\n\n## Escalation\n\nx\n");
      $run->($fx, 'F8 no status key'); }
    { my $fx = fixture(members => 1);
      write_json("$fx->{D}/.drive-solo/inflight.json", { packages => [{ blueprint => '../../etc', package => 'p1-a', ledger => 'x', since => 1 }], updated_at => 1 });
      $run->($fx, 'F11 bad blueprint name'); }
    { my $fx = fixture(members => 1);
      write_json("$fx->{D}/.drive-solo/inflight.json", { packages => [{ blueprint => 'bpx', package => 'a/b', ledger => 'x', since => 1 }], updated_at => 1 });
      $run->($fx, 'F11b bad package name'); }
    { my $fx = fixture(members => 1);
      GuardHarness::fresh_state(); # a fresh, unarmed state root
      my $r = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $target->($fx)), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-15(F9 unarmed session): rc 0');
      is($r->{err}, '', 'AC-15(F9 unarmed session): stderr empty'); }
    { my $fx = fixture(members => 1);
      my $r = wg_writes('', env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-15(F12 empty payload): rc 0');
      is($r->{err}, '', 'AC-15(F12 empty payload): stderr empty');
      my $r2 = wg_writes('not json at all', env => env_for($fx->{D}));
      is($r2->{rc}, 0, 'AC-15(F12 non-JSON payload): rc 0');
      is($r2->{err}, '', 'AC-15(F12 non-JSON payload): stderr empty'); }
    { my $fx = fixture(members => 1);
      my $lonely = scratch_dir('lonely-cwd');
      # Pin the project to $lonely: a cwd inside this repo would otherwise resolve to the REAL repo.
      my $env = env_for($fx->{D}, CCPRAXIS_DATA_DIR => undef, CLAUDE_PROJECT_DIR => $lonely);
      my $r = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $lonely, file_path => "$lonely/t/a/oracle.t"), env => $env);
      is($r->{rc}, 0, 'AC-15(F13 no data dir): rc 0');
      is($r->{err}, '', 'AC-15(F13 no data dir): stderr empty'); }
}

# =============================================================================
# AC-16: no leak into %ENV.
# =============================================================================
{
    my $fx = fixture(members => 1);
    my $env = env_for($fx->{D});
    my %before = %ENV;
    wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/t/a/oracle.t"), env => $env);
    is_deeply({ %ENV }, \%before, 'AC-16: %ENV unchanged after a deny');
    wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl"), env => $env);
    is_deeply({ %ENV }, \%before, 'AC-16: %ENV unchanged after an allow');
}

# =============================================================================
# AC-17: ledger validators, driver main thread, one member, p1-a.md.
# =============================================================================
{
    my $target = sub { my ($fx) = @_; return "$fx->{D}/blueprints/bpx/packages/p1-a.md" };
    my $ledger_write = sub {
        my ($fx, %o) = @_;
        return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => ($o{tool_name} // 'Write'),
            file_path => $target->($fx), (exists $o{content} ? (content => $o{content}) : ()),
            (exists $o{old_string} ? (old_string => $o{old_string}) : ()),
            (exists $o{new_string} ? (new_string => $o{new_string}) : ()),
            (exists $o{edits} ? (edits => $o{edits}) : ()));
    };

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/')), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-17: a valid Write gives rc 0'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, content => "no frontmatter at all here\n"), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: no frontmatter gives rc 2');
      like($r->{err}, qr/LEDGER-GUARD: BLOCKED/, 'AC-17: text starts with LEDGER-GUARD: BLOCKED');
      like($r->{err}, qr/frontmatter/, 'AC-17: text mentions frontmatter'); }

    { my $fx = fixture(members => 1);
      my $body = ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
      my @l = split /\n/, $body, -1;
      $l[11] = "bad\x00line";
      my $r = wg_ledger($ledger_write->($fx, content => join("\n", @l)), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: a NUL byte gives rc 2');
      like($r->{err}, qr/control byte/, 'AC-17: text mentions control byte');
      like($r->{err}, qr/0x00/, 'AC-17: text names 0x00');
      like($r->{err}, qr/line 12/, 'AC-17: text names line 12'); }

    { my $fx = fixture(members => 1);
      my $content = "---\nblueprint: bpx\nstatus: running\nwrite_set: a/\ntest_paths: t/\nlast_updated: 2025-01-01T00:00:00Z\n---\n\n"
                  . "## Next action\n\nx\n\n## Decisions & attempt log\n\nx\n\n## Pipeline\n\nx\n\n## Outputs\n\nx\n\n## Escalation\n\nx\n";
      my $r = wg_ledger($ledger_write->($fx, content => $content), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: a missing "package" key gives rc 2');
      like($r->{err}, qr/frontmatter key/, 'AC-17: text mentions frontmatter key');
      like($r->{err}, qr/\bpackage\b/, 'AC-17: text names the missing key "package"'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, content => ledger_body(package => 'p1-a', status => 'frobnicated', write_set => 'src/a/:docs/a.md', test_paths => 't/a/')), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: an unrecognised status gives rc 2');
      like($r->{err}, qr/"frobnicated"/, 'AC-17: text quotes "frobnicated"');
      for my $s (qw(pending running converging reviewing done blocked parked dropped)) {
          like($r->{err}, qr/\Q$s\E/, "AC-17: text lists status $s");
      } }

    { my $fx = fixture(members => 1);
      my $body = ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
      $body =~ s/## Pipeline\n\n- \[x\] 1\n\n//;
      my $r = wg_ledger($ledger_write->($fx, content => $body), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: a dropped ## Pipeline heading gives rc 2');
      like($r->{err}, qr/## Pipeline/, 'AC-17: text names "## Pipeline"'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, tool_name => 'Edit', old_string => '', new_string => 'x'), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: an Edit with an empty old_string gives rc 2');
      like($r->{err}, qr/cannot reconstruct/, 'AC-17: text mentions "cannot reconstruct"');
      like($r->{err}, qr/empty old_string/, 'AC-17: text mentions "empty old_string"'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, tool_name => 'NotebookEdit'), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: NotebookEdit gives rc 2');
      like($r->{err}, qr/NotebookEdit/, 'AC-17: text mentions NotebookEdit'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger($ledger_write->($fx, tool_name => 'Edit', old_string => 'text not present anywhere xyz', new_string => 'y'), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-17: an Edit whose old_string is absent from the file gives rc 0'); }

    { my $fx = fixture(members => 1);
      unlink("$fx->{D}/blueprints/bpx/packages/p1-a.md");
      my $r = wg_ledger($ledger_write->($fx, tool_name => 'Edit', old_string => 'x', new_string => 'y'), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-17: an Edit on a missing target gives rc 0'); }

    { my $fx = fixture(members => 1);
      my $edits = [ { old_string => 'keep going', new_string => 'keep going still' },
                    { old_string => "## Outputs\n\nnone", new_string => 'gone' } ];
      my $r = wg_ledger($ledger_write->($fx, tool_name => 'MultiEdit', edits => $edits), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: a MultiEdit whose second edit removes ## Outputs gives rc 2'); }

    { my $fx = fixture(members => 1);
      my @t = gmtime(time() + 600);
      my $future = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
      my $r = wg_ledger($ledger_write->($fx, content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/', last_updated => $future)), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-17: a last_updated 10 minutes in the future gives rc 2'); }

    for my $case ([ 'no frontmatter' => "no frontmatter\n" ]) {
        my ($label, $content) = @$case;
        my $fx = fixture(members => 1);
        my $r = wg_ledger($ledger_write->($fx, content => $content), env => env_for($fx->{D}));
        cmp_ok(scalar(deny_lines($r->{err})), '<=', 1, "AC-17($label): every deny is at most one line") if $r->{rc} == 2;
        for my $l (deny_lines($r->{err})) { cmp_ok(length($l), '<=', 160, "AC-17($label): deny line at most 160 chars") }
    }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
          file_path => "$fx->{D}/blueprints/bpx/reports/x.md", content => "junk\x00content"), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-17: reports/x.md in the same bp dir with junk content gives rc 0 (out of scope gate)'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
          file_path => "$fx->{D}/blueprints/bpx/packages/x.txt", content => "junk"), env => env_for($fx->{D}));
      is($r->{rc}, 0, 'AC-17: packages/x.txt (wrong extension) gives rc 0'); }
}

# =============================================================================
# AC-18: V6 -- write_set/test_paths widen/blank denied for the session's own
# package; another package or the coordinator path are exempt.
# =============================================================================
{
    { my $fx = fixture(members => 1);
      my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
          file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md",
          content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md:other/', test_paths => 't/a/')), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-18: driver widening write_set gives rc 2');
      like($r->{err}, qr/write_set/, 'AC-18: deny mentions write_set'); }

    { my $fx = fixture(members => 1);
      my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
          file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md",
          content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => '')), env => env_for($fx->{D}));
      is($r->{rc}, 2, 'AC-18: driver blanking test_paths gives rc 2'); }

    { my $fx = fixture(members => 2);
      my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
          cwd => $fx->{R}, tool_name => 'Write', file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md",
          content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md:other/', test_paths => 't/a/'));
      is(wg_ledger($sub, env => env_for($fx->{D}))->{rc}, 2, 'AC-18: bound subagent widening its own package\'s write_set gives rc 2'); }

    { my $fx = fixture(members => 2);
      my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
          cwd => $fx->{R}, tool_name => 'Write', file_path => "$fx->{D}/blueprints/bpx/packages/p1-a.md",
          content => ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => ''));
      is(wg_ledger($sub, env => env_for($fx->{D}))->{rc}, 2, 'AC-18: bound subagent blanking its own package\'s test_paths gives rc 2'); }

    { my $fx = fixture(members => 2);
      my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
          cwd => $fx->{R}, tool_name => 'Write', file_path => "$fx->{D}/blueprints/bpx/packages/p2-b.md",
          content => ledger_body(package => 'p2-b', write_set => 'src/b/:other/', test_paths => 't/b/'));
      is(wg_ledger($sub, env => env_for($fx->{D}))->{rc}, 2, 'AC-18: subagent bound to A widening package B\'s write_set is denied (sibling ledger, Decision 70), rc 2'); }

    { my $R = scratch_dir('v6-coord-proj');
      make_path("$R/.ccpraxis-local-data/blueprints/bpx/packages");
      write_ledger("$R/.ccpraxis-local-data", package => 'p1-a', write_set => 'src/a/', test_paths => 't/a/');
      my %env = (CCPRAXIS_DATA_DIR => undef, TMPDIR => undef, TEMP => undef, TMP => undef, LOCALAPPDATA => undef,
          BP_LEDGER => "$R/.ccpraxis-local-data/blueprints/bpx/packages/p1-a.md",
          BP_DIR => "$R/.ccpraxis-local-data/blueprints/bpx", BP_PROJECT_ROOT => $R, BP_PACKAGE => 'p1-a');
      my $p = driver_payload(cwd => $R, tool_name => 'Write',
          file_path => "$R/.ccpraxis-local-data/blueprints/bpx/packages/p1-a.md",
          content => ledger_body(package => 'p1-a', write_set => 'src/a/:other/', test_paths => 't/a/'));
      is(wg_ledger($p, env => \%env)->{rc}, 0, 'AC-18: the coordinator path widening its own BP_LEDGER file gives rc 0 (V6 is not a coordinator rule)'); }
}

# =============================================================================
# AC-19: ledger fail direction.
# =============================================================================
{
    my $R = scratch_dir('failgate-coord-proj');
    make_path("$R/.ccpraxis-local-data/blueprints/bpx/packages");
    write_ledger("$R/.ccpraxis-local-data", package => 'p1-a', write_set => 'src/a/', test_paths => 't/a/');
    my %coord_env = (CCPRAXIS_DATA_DIR => undef, TMPDIR => undef, TEMP => undef, TMP => undef, LOCALAPPDATA => undef,
        BP_LEDGER => "$R/.ccpraxis-local-data/blueprints/bpx/packages/p1-a.md",
        BP_DIR => "$R/.ccpraxis-local-data/blueprints/bpx", BP_PROJECT_ROOT => $R, BP_PACKAGE => 'p1-a');

    my $rc = GuardHarness::run_module('WriteGuards', 'not json', env => \%coord_env, args => ['writes']);
    is($rc->{rc}, 2, 'AC-19: coordinator, writes mode, malformed payload gives rc 2');
    cmp_ok(scalar(deny_lines($rc->{err})), '<=', 1, 'AC-19: writes-mode malformed-payload deny is one line');
    my $rl = GuardHarness::run_module('WriteGuards', 'not json', env => \%coord_env, args => ['ledger']);
    is($rl->{rc}, 2, 'AC-19: coordinator, ledger mode, malformed payload gives rc 2');
    cmp_ok(scalar(deny_lines($rl->{err})), '<=', 1, 'AC-19: ledger-mode malformed-payload deny is one line');

    my $fx = fixture(members => 1);
    my $rd = wg_writes('not json', env => env_for($fx->{D}));
    is($rd->{rc}, 0, 'AC-19: the driver with the same malformed payload gives rc 0 (writes mode)');
    my $rd2 = wg_ledger('not json', env => env_for($fx->{D}));
    is($rd2->{rc}, 0, 'AC-19: the driver with the same malformed payload gives rc 0 (ledger mode)');

    my $target = sub { my ($fx) = @_; return "$fx->{D}/blueprints/bpx/packages/p1-a.md" };
    my $corrupt_ledger_write = sub {
        my ($fx) = @_;
        return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
            file_path => $target->($fx), content => "no frontmatter at all\n");
    };
    { my $fx = fixture(members => 1); unlink("$fx->{D}/.drive-solo/inflight.json");
      is(wg_ledger($corrupt_ledger_write->($fx), env => env_for($fx->{D}))->{rc}, 0, 'AC-19(F1): corrupt ledger + no inflight/current gives rc 0'); }
    { my $fx = fixture(members => 1);
      write_bytes("$fx->{D}/.drive-solo/inflight.json", '{{{not json');
      write_bytes("$fx->{D}/.drive-solo/current.json", '{{{not json');
      is(wg_ledger($corrupt_ledger_write->($fx), env => env_for($fx->{D}))->{rc}, 0, 'AC-19(F2): corrupt ledger + malformed inflight/current gives rc 0'); }
    { my $fx = fixture(members => 1); write_bytes("$fx->{D}/blueprints/bpx/packages/p1-a.md", "not frontmatter\n---\n");
      is(wg_ledger($corrupt_ledger_write->($fx), env => env_for($fx->{D}))->{rc}, 0, 'AC-19(F5): corrupt ledger + broken existing ledger gives rc 0'); }
    { my $fx = fixture(members => 1);
      GuardHarness::fresh_state();
      is(wg_ledger($corrupt_ledger_write->($fx), env => env_for($fx->{D}))->{rc}, 0, 'AC-19(F9): corrupt ledger + unarmed session gives rc 0'); }
}

# =============================================================================
# AC-20: [file] wrapper shape and module purity.
# =============================================================================
{
    my $gw_exists = -f $GUARD_WRITES_SH;
    my $lg_exists = -f $LEDGER_GUARD_SH;
    ok($gw_exists, 'AC-20: guard-writes.sh exists');
    ok($lg_exists, 'AC-20: ledger-guard.sh exists');

  SKIP: {
        skip 'AC-20: guard-writes.sh missing', 2 unless $gw_exists;
        my $rc = system("bash -n " . quotemeta($GUARD_WRITES_SH) . " >/dev/null 2>&1");
        is($rc, 0, 'AC-20: bash -n guard-writes.sh exits 0');
        my @lines = grep { length } split /\n/, (read_bytes($GUARD_WRITES_SH) // '');
        is($lines[-1] // '', 'exec bash "$d/run-hook.sh" WriteGuards --pre ledger,driver -- writes "$@"',
            'AC-20: guard-writes.sh last line matches sec 2.1 byte for byte');
    }
  SKIP: {
        skip 'AC-20: ledger-guard.sh missing', 2 unless $lg_exists;
        my $rc = system("bash -n " . quotemeta($LEDGER_GUARD_SH) . " >/dev/null 2>&1");
        is($rc, 0, 'AC-20: bash -n ledger-guard.sh exits 0');
        my @lines = grep { length } split /\n/, (read_bytes($LEDGER_GUARD_SH) // '');
        is($lines[-1] // '', 'exec bash "$d/run-hook.sh" WriteGuards --pre text:packages --pre ledger,driver -- ledger "$@"',
            'AC-20: ledger-guard.sh last line matches sec 2.1 byte for byte');
    }

    ok($REQUIRE_OK, 'AC-20 precondition: BpHook::WriteGuards can be required')
        or diag("require failed: $@ (package 13 has not written WriteGuards.pm yet)");
  SKIP: {
        skip 'AC-20: BpHook::WriteGuards not requireable yet', 3 unless $REQUIRE_OK;
        ok(defined &BpHook::WriteGuards::run, 'AC-20: BpHook::WriteGuards defines run');
        ok(defined &BpHook::WriteGuards::resolve, 'AC-20: BpHook::WriteGuards defines resolve');

        my $src = read_bytes($WRITEGUARDS_PM) // '';
        (my $stripped = $src) =~ s/^\s*#.*$//mg;
        for my $forbidden (
            'system(', 'exec(', 'exec ', "`", 'qx', 'fork', 'cygpath', 'current.json',
            '.drive-solo-active', 'BP_DRIVER_ROLE', 'BP_DRIVER_SESSION', 'CCPRAXIS_DRIVER_GUARDS_OFF',
            'CLAUDE_CODE_SESSION_ID', 'bp_driver_context', 'BUTLER_CONCURRENCY',
        ) {
            unlike($stripped, qr/\Q$forbidden\E/, "AC-20: source (comments stripped) never mentions '$forbidden'");
        }
        unlike($stripped, qr/open\s*\([^)]*['"]\s*\|/, 'AC-20: source never opens a pipe');
    }
}

# =============================================================================
# AC-21: [S] process budget (Decision 33).
# =============================================================================
{
    GuardHarness::fresh_state();
    my $p_unarmed = driver_payload(session_id => 'ac21-unarmed', file_path => scratch_dir('ac21a') . '/x.pl');
    my $ra = GuardHarness::run_shim($GUARD_WRITES_SH, $p_unarmed, env => {});
    is($ra->{rc}, 0, 'AC-21(a): unarmed session through guard-writes wrapper gives rc 0');
    is(GuardHarness::count_lines($ra->{shim_log}, 'perl'), 0, 'AC-21(a): 0 perl launches');
    is(GuardHarness::count_lines($ra->{shim_log}, 'jq'), 0, 'AC-21(a): 0 jq launches');

    GuardHarness::fresh_state();
    GuardHarness::arm('ac21-b', 'driver');
    my $p_nopkgs = driver_payload(session_id => 'ac21-b', file_path => scratch_dir('ac21b') . '/x.txt');
    my $rb = GuardHarness::run_shim($LEDGER_GUARD_SH, $p_nopkgs, env => {});
    is($rb->{rc}, 0, 'AC-21(b): armed driver, no "packages" substring, through ledger-guard wrapper gives rc 0');
    is(GuardHarness::count_lines($rb->{shim_log}, 'perl'), 0, 'AC-21(b): 0 perl launches');

    my $fx = fixture(members => 2);
    my $c_payload = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    my $rc_ = GuardHarness::run_shim($GUARD_WRITES_SH, $c_payload, env => env_for($fx->{D}));
    is($rc_->{rc}, 2, 'AC-21(c): the AC-1 deny through guard-writes wrapper gives rc 2');
    cmp_ok(GuardHarness::count_lines($rc_->{shim_log}, 'perl'), '<=', 1, 'AC-21(c): at most 1 perl launch');
    is(GuardHarness::count_lines($rc_->{shim_log}, 'jq'), 0, 'AC-21(c): 0 jq launches');

    my $fx2 = fixture(members => 1);
    my $d_payload = driver_payload(session_id => $fx2->{sid}, cwd => $fx2->{R}, tool_name => 'Write',
        file_path => "$fx2->{D}/blueprints/bpx/packages/p1-a.md", content => "no frontmatter at all\n");
    my $rd_ = GuardHarness::run_shim($LEDGER_GUARD_SH, $d_payload, env => env_for($fx2->{D}));
    is($rd_->{rc}, 2, 'AC-21(d): the AC-17 frontmatter deny through ledger-guard wrapper gives rc 2');
    cmp_ok(GuardHarness::count_lines($rd_->{shim_log}, 'perl'), '<=', 1, 'AC-21(d): at most 1 perl launch');
    is(GuardHarness::count_lines($rd_->{shim_log}, 'jq'), 0, 'AC-21(d): 0 jq launches');

    my $rc_mod = wg_writes($c_payload, env => env_for($fx->{D}));
    is($rc_mod->{parse_delta}, 0, 'AC-21(e): AC-1-deny run_module has parse_delta 0');
    my $rd_mod = wg_ledger($d_payload, env => env_for($fx2->{D}));
    is($rd_mod->{parse_delta}, 0, 'AC-21(e): AC-17-deny run_module has parse_delta 0');
}

# =============================================================================
# AC-22: [W] end-to-end through the real wrappers.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $bad = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    my $expected_in_process = wg_writes($bad, env => env_for($fx->{D}));
    my $rw = GuardHarness::run_wrapper($GUARD_WRITES_SH, $bad, env => env_for($fx->{D}));
    is($rw->{rc}, 2, 'AC-22: writes-mode deny through the wrapper gives rc 2');
    is($rw->{err}, $expected_in_process->{err}, 'AC-22: writes-mode wrapper stderr matches in-process');

    my $fx2 = fixture(members => 1);
    my $ledger_bad = driver_payload(session_id => $fx2->{sid}, cwd => $fx2->{R}, tool_name => 'Write',
        file_path => "$fx2->{D}/blueprints/bpx/packages/p1-a.md", content => "no frontmatter at all\n");
    my $expected_ledger = wg_ledger($ledger_bad, env => env_for($fx2->{D}));
    my $rl = GuardHarness::run_wrapper($LEDGER_GUARD_SH, $ledger_bad, env => env_for($fx2->{D}));
    is($rl->{rc}, 2, 'AC-22: ledger-mode deny through the wrapper gives rc 2');
    is($rl->{err}, $expected_ledger->{err}, 'AC-22: ledger-mode wrapper stderr matches in-process');

    my $re = GuardHarness::run_wrapper($GUARD_WRITES_SH, '', env => {});
    is($re->{rc}, 0, 'AC-22: an empty payload through the wrapper gives rc 0');

    my $fx3 = fixture(members => 1);
    my $rbash = GuardHarness::run_wrapper($GUARD_WRITES_SH,
        driver_payload(session_id => $fx3->{sid}, cwd => $fx3->{R}, tool_name => 'Bash'), env => env_for($fx3->{D}));
    is($rbash->{rc}, 0, 'AC-22: tool_name Bash through the wrapper gives rc 0');

    my $fx4 = fixture(members => 1);
    my $bs_target = do { (my $t = "$fx4->{D}/blueprints/bpx/packages/p1-a.md") =~ tr{/}{\\}; $t };
    my $rbs = GuardHarness::run_wrapper($LEDGER_GUARD_SH,
        driver_payload(session_id => $fx4->{sid}, cwd => $fx4->{R}, tool_name => 'Write', file_path => $bs_target, content => "no frontmatter\n"),
        env => env_for($fx4->{D}));
    is($rbs->{rc}, 2, 'AC-22: a backslash ledger path still reaches the validator through the wrapper (rc 2)');
}

# =============================================================================
# AC-23: not registered anywhere.
# =============================================================================
{
    my $hooks_json = "$BUTLER_DIR/hooks/hooks.json";
    my $settings_json = "$BUTLER_DIR/../../.claude/settings.json";
    ok(-f $hooks_json, 'AC-23 precondition: hooks.json exists');
    ok(-f $settings_json, 'AC-23 precondition: .claude/settings.json exists');
    for my $needle (qw(next/guard-writes next/ledger-guard WriteGuards)) {
        unlike(read_bytes($hooks_json) // '', qr/\Q$needle\E/, "AC-23: hooks.json does not mention $needle");
        unlike(read_bytes($settings_json) // '', qr/\Q$needle\E/, "AC-23: .claude/settings.json does not mention $needle");
    }
}

# =============================================================================
# AC-24: this file's OWN LEADING COMMENT BLOCK carries the sec 4.1 table
# verbatim. Decision 69 B2 (review M4): this must not read the real,
# untracked package ledger (Decision 26's "listed in the ledger" is a
# coordinator/review obligation, not a unit-test assertion -- dropped
# entirely; a fresh clone or a sandbox without this blueprint must not turn
# this file permanently red). It also must not be tautological: the needles
# are assembled at runtime from split fragments (never a single contiguous
# literal token in THIS FILE'S OWN SOURCE), so deleting the header table
# actually makes the assertion fail instead of matching this very `for` loop.
# Only the leading "#"-comment block (up to the first non-comment line) is
# scanned, per spec sec 4's own header-check rule.
# =============================================================================
{
    my $self_src = read_bytes(Cwd::abs_path(__FILE__)) // '';
    my ($header) = ($self_src =~ /\A((?:#[^\n]*\n)+)/);
    $header //= '';
    like($header, qr/NOT RE-EXPRESSED/, 'AC-24: leading comment block carries the "NOT RE-EXPRESSED" table');
    like($header, qr/driver-guard-reach\.t/, 'AC-24: leading comment block names driver-guard-reach.t');
    like($header, qr/driver-context-session-scope\.t/, 'AC-24: leading comment block names driver-context-session-scope.t');
    my $needle = sub { return join('', @_) };
    for my $pair (
        [ $needle->('lib.s', 'h is present'),               'lib.sh is present' ],
        [ $needle->('AC-21,22,2', '3,24,26'),                'AC-21,22,23,24,26' ],
        [ $needle->('.driver-guard', 's-off'),               '.driver-guards-off' ],
        [ $needle->('CCPRAXIS_DRIVER_G', 'UARDS_OFF'),       'CCPRAXIS_DRIVER_GUARDS_OFF' ],
        [ $needle->('RT-6 (future-da', 'ted hatch)'),        'RT-6 (future-dated hatch)' ],
    ) {
        my ($assembled, $label) = @$pair;
        like($header, qr/\Q$assembled\E/, "AC-24: leading comment block contains the row text '$label'");
    }
}

# =============================================================================
# AC-25: temp, TEMP in Windows/backslash form (Decision 68 i).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $tt_base = scratch_dir('tt25');
    (my $tt_bs = $tt_base) =~ tr{/}{\\};
    if ($tt_bs !~ m{^[A-Za-z]:\\}) { $tt_bs =~ tr{/}{\\} }
    my $target_bs = "$tt_bs\\claude\\s.txt";

    my $env = env_for($fx->{D}, TEMP => $tt_bs);
    my $drv = driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $target_bs);
    is(wg_writes($drv, env => $env)->{rc}, 0, 'AC-25: TEMP set (backslash), driver writing under it gives rc 0');
    my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => $target_bs);
    is(wg_writes($sub, env => $env)->{rc}, 0, 'AC-25: TEMP set (backslash), bound subagent writing under it gives rc 0');

    my $env_tmp = env_for($fx->{D}, TMP => $tt_bs);
    is(wg_writes($drv, env => $env_tmp)->{rc}, 0, 'AC-25: TMP set instead of TEMP, driver writing under it gives rc 0');

    my $sibling = scratch_dir('sibling25');
    my $env_none = env_for($fx->{D});
    my $rnone = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$sibling/x.txt"), env => $env_none);
    is($rnone->{rc}, 2, 'AC-25: with no temp variables set, a sibling-of-R path gives rc 2');
    like($rnone->{err}, qr/outside the project root/, 'AC-25: deny mentions "outside the project root"');
}

# =============================================================================
# AC-26: temp, LOCALAPPDATA long form with a non-ASCII segment (Decision 68 ii).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $char_e9 = "Andr\x{e9}Local";
    my $bytes_e9 = do { my $c = $char_e9; utf8::encode($c); $c };
    my $base = scratch_dir('la26');
    my $la_dir = "$base/$bytes_e9";
    make_path("$la_dir/Temp");

    my $env = env_for($fx->{D}, LOCALAPPDATA => $la_dir);
    my $target_char = "$base/$char_e9/Temp/claude/s.txt"; # payload carries the JSON character form
    my $drv = driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $target_char);
    is(wg_writes($drv, env => $env)->{rc}, 0, 'AC-26: LOCALAPPDATA long form, driver writing under Temp gives rc 0');
    my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => $target_char);
    is(wg_writes($sub, env => $env)->{rc}, 0, 'AC-26: LOCALAPPDATA long form, bound subagent writing under Temp gives rc 0');

    my $other_char = "$base/$char_e9/Other/s.txt";
    my $rother = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $other_char), env => $env);
    is($rother->{rc}, 2, 'AC-26: a write not under Temp (Other/) gives rc 2');
}

# =============================================================================
# AC-27: degenerate temp candidates ignored (Decision 68 iii).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $sibling = scratch_dir('sibling27');
    my $has_drive_forms = ($fx->{R} =~ m{^[A-Za-z]:/}) ? 1 : 0;

    my @candidates = ('/', '', 'tmp');
    push @candidates, 'C:\\' if $has_drive_forms;
    for my $cand (@candidates) {
        my $env = env_for($fx->{D}, TEMP => $cand);
        my $r = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$sibling/x.txt"), env => $env);
        my $label = length($cand) ? $cand : '(empty)';
        is($r->{rc}, 2, "AC-27: TEMP='$label' is ignored as a degenerate candidate, rc 2");
        like($r->{err}, qr/outside the project root/, "AC-27: TEMP='$label' deny mentions the project root");
    }
}

# =============================================================================
# AC-28: the project inside a temp dir is not opened up (Decision 68 iv).
# =============================================================================
{
    my $fx = fixture(members => 2);
    (my $parent_of_r = $fx->{R}) =~ s{/[^/]+\z}{};
    my $env = env_for($fx->{D}, TEMP => $parent_of_r);

    my $drv_out = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt"), env => $env);
    is($drv_out->{rc}, 2, 'AC-28: driver writing R/other/x.txt (R under TEMP) still gives rc 2');
    # Decision 69 A7 (review M2): this fixture has 2 members in flight, so the
    # driver's own deny is the T5 union phrasing, never T4's single-package one.
    like($drv_out->{err}, qr/outside the write set of every package in flight/,
        'AC-28: deny mentions "outside the write set of every package in flight" (T5, union)');

    my $sub_data = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{D}/notes/n.md");
    is(wg_writes($sub_data, env => $env)->{rc}, 2, 'AC-28: bound subagent writing the data dir (not its blueprint dir) still gives rc 2');

    my $drv_in = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl"), env => $env);
    is($drv_in->{rc}, 0, 'AC-28: driver writing R/src/a/x.pl (in write set) gives rc 0');

    my $sibling = "$parent_of_r/" . basename(scratch_dir('sibling28'));
    my $rsib = wg_writes(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$sibling/x.txt"), env => $env);
    is($rsib->{rc}, 0, 'AC-28: a sibling of R under the same TEMP parent gives rc 0 (temp)');
}

# =============================================================================
# AC-29 (Decision 69 A2, red-team H2/H3): case folding and 8.3 short-name
# denial. $BpHook::WriteGuards::CASE_INSENSITIVE is forced to 1 for the pure
# ASCII-case-alias cases, so this file's verdicts do not depend on the host
# this happens to run on (spec addendum sec A). The 8.3 short-name denial
# ("BLOCKED: <path> uses a Windows short (8.3) name; write it by its long
# name.") applies on every host unconditionally and is tested WITHOUT
# forcing the switch.
# =============================================================================
SKIP: {
    skip 'AC-29: BpHook::WriteGuards not requireable yet', 1 unless $REQUIRE_OK;

    # -- group 1: oracle overwrite through a case / 8.3 alias, when write_set
    # covers the test's directory by prefix and test_paths names it exactly
    # (the package-16 shape red-team H2 found live in this very blueprint).
    {
        my $fx = fixture(members => 1);
        write_ledger($fx->{D}, package => 'p1-a',
            write_set => 'plugins/butler/tests/t/:plugins/butler/hooks/',
            test_paths => 'plugins/butler/tests/t/h01-settings-registration.t');
        my $canon_path = "$fx->{R}/plugins/butler/tests/t/h01-settings-registration.t";
        write_bytes($canon_path, "ORACLE\n");
        my $sub = sub {
            my ($fp) = @_;
            return subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
                transcript_path => shape_a_transcript($fx), cwd => $fx->{R},
                agent_type => 'butler:bp-implementer', file_path => $fp);
        };

        is(wg_writes($sub->($canon_path), env => env_for($fx->{D}))->{rc}, 2,
            'AC-29(H2 baseline): implementer writing the exact oracle path gives rc 2');

        {
            local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;
            my $case_alias = "$fx->{R}/plugins/butler/tests/t/H01-Settings-Registration.t";
            my $r = wg_writes($sub->($case_alias), env => env_for($fx->{D}));
            is($r->{rc}, 2, 'AC-29(H2, CASE_INSENSITIVE=1): a pure-case alias of the oracle path still gives rc 2');
            my $r2 = wg_writes($sub->($canon_path), env => env_for($fx->{D}));
            is($r2->{rc}, 2, 'AC-29(H2, CASE_INSENSITIVE=1): the canonical lower-case form still gives rc 2 unaffected');
        }

        {
            my $short_alias = "$fx->{R}/plugins/butler/tests/t/H01-SE~1.T";
            my $r = wg_writes($sub->($short_alias), env => env_for($fx->{D}));
            is($r->{rc}, 2, 'AC-29(H2, 8.3 alias): an 8.3 short-name alias of the oracle path gives rc 2, unconditionally');
            like($r->{err}, qr/short \(8\.3\) name/, 'AC-29(H2, 8.3 alias): deny mentions the short (8.3) name text');
            like($r->{err}, qr/long name/, 'AC-29(H2, 8.3 alias): deny tells the author to use the long name');
        }
    }

    # -- group 2: the .drive-solo/ carve-out through a case / 8.3 alias.
    {
        my $fx = fixture(members => 1);
        my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

        is(wg_writes($drv->("$fx->{D}/.drive-solo/inflight.json"), env => env_for($fx->{D}))->{rc}, 2,
            'AC-29(H3 baseline): the canonical .drive-solo/inflight.json still gives rc 2');

        {
            local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;
            my $r = wg_writes($drv->("$fx->{D}/.Drive-Solo/inflight.json"), env => env_for($fx->{D}));
            is($r->{rc}, 2, 'AC-29(H3, CASE_INSENSITIVE=1): a pure-case alias .Drive-Solo/ still gives rc 2');
            my $r2 = wg_writes($drv->("$fx->{D}/.drive-solo/inflight.json"), env => env_for($fx->{D}));
            is($r2->{rc}, 2, 'AC-29(H3, CASE_INSENSITIVE=1): the canonical form is still denied, unaffected');
        }

        my $r3 = wg_writes($drv->("$fx->{D}/DRIVE-~1/bindings/toolu_A.json"), env => env_for($fx->{D}));
        is($r3->{rc}, 2, 'AC-29(H3, 8.3 alias): DRIVE-~1/ (8.3 alias of .drive-solo) gives rc 2, unconditionally');
        like($r3->{err}, qr/short \(8\.3\) name/, 'AC-29(H3, 8.3 alias): deny mentions the short (8.3) name text');
    }

    # -- group 3: ledger scope gate / V6 through a case or 8.3 alias.
    {
        my $fx = fixture(members => 1);
        my $target = "$fx->{D}/blueprints/bpx/packages/p1-a.md";
        my $widened = ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md:other/', test_paths => 't/a/');
        my $ledger_write = sub {
            my ($fp, %o) = @_;
            return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
                file_path => $fp, content => ($o{content} // $widened));
        };

        is(wg_ledger($ledger_write->($target), env => env_for($fx->{D}))->{rc}, 2,
            'AC-29(H3 ledger baseline): the canonical p1-a.md path still gives rc 2 (V6)');

        {
            local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;
            my $case_path = "$fx->{D}/blueprints/bpx/packages/P1-A.md";
            my $r = wg_ledger($ledger_write->($case_path), env => env_for($fx->{D}));
            is($r->{rc}, 2, 'AC-29(V6, CASE_INSENSITIVE=1): P1-A.md (case alias) widening write_set gives rc 2 (V6)');

            my $ext_path = "$fx->{D}/blueprints/bpx/packages/p1-a.MD";
            my $r2 = wg_ledger($ledger_write->($ext_path, content => "junk garbage, no frontmatter\n"), env => env_for($fx->{D}));
            is($r2->{rc}, 2, 'AC-29(ledger scope gate, CASE_INSENSITIVE=1): p1-a.MD (extension case alias) reaches the validator and gives rc 2');

            my $r3 = wg_ledger($ledger_write->($target), env => env_for($fx->{D}));
            is($r3->{rc}, 2, 'AC-29(V6, CASE_INSENSITIVE=1): the canonical form is still denied, unaffected');
        }

        my $short_path = "$fx->{D}/BLUEPR~2/bpx/packages/p1-a.md";
        my $r4 = wg_ledger($ledger_write->($short_path), env => env_for($fx->{D}));
        is($r4->{rc}, 2, 'AC-29(H3 ledger, 8.3 alias): BLUEPR~2/... (8.3 alias of blueprints/) gives rc 2, unconditionally');
    }
}

# =============================================================================
# AC-30 (Decision 69 A4, red-team M1): an uncompilable glob (bracket
# expression) in ANY member's write_set/test_paths never makes the guard die
# -- it matches nothing, exactly like bash's [[ == ]], and every OTHER rule
# for every OTHER path stays intact (the out-of-set write is still rc 2, and
# a real test file is still rc 2). Planted in a SIBLING member's ledger (as
# a subagent bound to a DIFFERENT package could do) and in test_paths too.
# =============================================================================
{
    my $fx = fixture(members => 2);
    write_ledger($fx->{D}, package => 'p2-b', write_set => 'src/b/:[z-a]', test_paths => 't/b/:[z-a]');
    my $env = env_for($fx->{D});
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    my $rout = wg_writes($drv->("$fx->{R}/other/x.txt"), env => $env);
    is($rout->{rc}, 2, 'AC-30(A4): a malformed bracket expression in a sibling member does not fail the guard open (out-of-set write still rc 2)');

    my $rtest = wg_writes($drv->("$fx->{R}/t/a/oracle.t"), env => $env);
    is($rtest->{rc}, 2, 'AC-30(A4): the malformed sibling does not fail open for a real test file either (still rc 2)');
    like($rtest->{err}, qr/may not modify test files/, 'AC-30(A4): the test-file deny text is still intact');

    # the sibling's own in-set write (unaffected by its own malformed test_paths entry)
    my $rb = wg_writes($drv->("$fx->{R}/src/b/x.pl"), env => $env);
    is($rb->{rc}, 0, 'AC-30(A4): the malformed-pattern member itself is still classified correctly for its valid entries');
}

# =============================================================================
# AC-31 (Decision 69 A5, red-team M4): the driver's data-dir allowance
# excludes .drive-solo/, .subagent-guard/, claude-home/ and bug-reports/ --
# each denied -- while a plain top-level file/dir (OPERATOR-BATCH.md) and a
# blueprint's own reports/ dir stay allowed.
# =============================================================================
{
    my $fx = fixture(members => 1);
    my $env = env_for($fx->{D});
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    for my $excluded (qw(.drive-solo .subagent-guard claude-home bug-reports)) {
        my $r = wg_writes($drv->("$fx->{D}/$excluded/x"), env => $env);
        is($r->{rc}, 2, "AC-31(A5): driver writing $excluded/x under the data dir gives rc 2");
    }
    is(wg_writes($drv->("$fx->{D}/OPERATOR-BATCH.md"), env => $env)->{rc}, 0,
        'AC-31(A5): driver writing the data dir\'s own OPERATOR-BATCH.md gives rc 0');
    is(wg_writes($drv->("$fx->{D}/blueprints/bpx/reports/x.md"), env => $env)->{rc}, 0,
        'AC-31(A5): driver writing a blueprint\'s reports/ dir gives rc 0');
}

# =============================================================================
# AC-32 (Decision 69 A6, review M1 / red-team L2): ledger Edit/MultiEdit
# splicing works on UTF-8 BYTES throughout -- old_string, new_string and the
# file's content are all UTF-8-encoded, never Latin-1-truncated, so an Edit
# whose old_string spans a line containing e-acute is matched correctly
# against the file's real UTF-8 bytes.
# =============================================================================
{
    my $fx = fixture(members => 1);
    my $char_e9 = "Andr\x{e9}";
    my $body = ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    $body =~ s/- note/- $char_e9 note/;
    my $bytes = $body;
    utf8::encode($bytes);
    write_bytes("$fx->{D}/blueprints/bpx/packages/p1-a.md", $bytes);
    my $target = "$fx->{D}/blueprints/bpx/packages/p1-a.md";
    my $edit = sub {
        my (%o) = @_;
        return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Edit', file_path => $target,
            old_string => $o{old_string}, new_string => $o{new_string});
    };

    my $r1 = wg_ledger($edit->(
        old_string => "- $char_e9 note\n\n## Pipeline",
        new_string => "- $char_e9 note\n\nSection Pipeline",
    ), env => env_for($fx->{D}));
    is($r1->{rc}, 2, 'AC-32(A6): an Edit whose old_string spans an e-acute line and drops "## Pipeline" gives rc 2 (V5)');

    my $r2 = wg_ledger($edit->(
        old_string => "write_set: src/a/:docs/a.md\ntest_paths: t/a/\nlast_updated: 2025-01-01T00:00:00Z\n---\n\n"
                    . "## Next action\n\nkeep going\n\n## Decisions & attempt log\n\n- $char_e9 note",
        new_string => "write_set: src/a/:docs/a.md:other/\ntest_paths: t/a/\nlast_updated: 2025-01-01T00:00:00Z\n---\n\n"
                    . "## Next action\n\nkeep going\n\n## Decisions & attempt log\n\n- $char_e9 note",
    ), env => env_for($fx->{D}));
    is($r2->{rc}, 2, 'AC-32(A6): an Edit whose old_string spans an e-acute line and widens write_set gives rc 2 (V6)');

    my $r3 = wg_ledger($edit->(
        old_string => "- $char_e9 note",
        new_string => "- $char_e9 note, updated",
    ), env => env_for($fx->{D}));
    is($r3->{rc}, 0, 'AC-32(A6): a legitimate e-acute-only edit to an attempt-log line gives rc 0');
}

# =============================================================================
# AC-33 (Decision 69 A9, red-team M2): a trailing "/" on CCPRAXIS_DATA_DIR is
# stripped before use -- neither a false allow (the .drive-solo carve-out
# still holds) nor a false deny (an in-write-set path is not pushed "outside
# the project root", and a bound subagent's own blueprint dir still allows).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $env = env_for("$fx->{D}/");
    my $drv = sub { my ($fp) = @_; return driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => $fp) };

    my $r1 = wg_writes($drv->("$fx->{D}/.drive-solo/inflight.json"), env => $env);
    is($r1->{rc}, 2, 'AC-33(A9): trailing "/" on CCPRAXIS_DATA_DIR does not disable the .drive-solo carve-out');

    my $r2 = wg_writes($drv->("$fx->{R}/src/a/x.pl"), env => $env);
    is($r2->{rc}, 0, 'AC-33(A9): trailing "/" on CCPRAXIS_DATA_DIR does not falsely deny an in-write-set path');
    is($r2->{err}, '', 'AC-33(A9): that rc0 case has empty stderr');

    my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{D}/blueprints/bpx/reports/r.md");
    is(wg_writes($sub, env => $env)->{rc}, 0, 'AC-33(A9): trailing "/" on CCPRAXIS_DATA_DIR does not falsely deny a bound subagent\'s own blueprint dir');
}

# =============================================================================
# AC-34 (Decision 69 B3): writes-mode coverage beyond tool_name Write -- Edit,
# MultiEdit and NotebookEdit (via notebook_path) are all checked exactly as
# Write is. "A binding stands even when its package is no longer in
# inflight.json, as long as its ledger is usable" (spec sec 2.4). Overlapping
# write sets between two in-flight members: a test_paths match in one member
# wins over a write_set match in another, for the driver's union.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $sub = sub {
        my (%o) = @_;
        return subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid},
            transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, %o);
    };

    for my $tool (qw(Edit MultiEdit)) {
        my $ok = wg_writes($sub->(tool_name => $tool, file_path => "$fx->{R}/src/a/x.pl"), env => env_for($fx->{D}));
        is($ok->{rc}, 0, "AC-34(B3): tool_name $tool, in-set path gives rc 0");
        my $bad = wg_writes($sub->(tool_name => $tool, file_path => "$fx->{R}/src/b/x.pl"), env => env_for($fx->{D}));
        is($bad->{rc}, 2, "AC-34(B3): tool_name $tool, out-of-set path gives rc 2");
    }

    my $nb_ok = wg_writes($sub->(tool_name => 'NotebookEdit', notebook_path => "$fx->{R}/src/a/nb.ipynb"), env => env_for($fx->{D}));
    is($nb_ok->{rc}, 0, 'AC-34(B3): NotebookEdit, in-set notebook_path gives rc 0');
    my $nb_bad = wg_writes($sub->(tool_name => 'NotebookEdit', notebook_path => "$fx->{R}/src/b/nb.ipynb"), env => env_for($fx->{D}));
    is($nb_bad->{rc}, 2, 'AC-34(B3): NotebookEdit, out-of-set notebook_path gives rc 2');
}

{
    # W2: hook_event_name other than PreToolUse always allows, even for an
    # otherwise-denied write.
    my $fx = fixture(members => 1);
    my $p = driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/other/x.txt", event => 'PostToolUse');
    my $r = wg_writes($p, env => env_for($fx->{D}));
    is($r->{rc}, 0, 'AC-34(B3, W2): hook_event_name PostToolUse allows an otherwise-denied write');
    is($r->{err}, '', 'AC-34(B3, W2): rc0 case has empty stderr');
}

{
    # "binding stands": toolu_B's binding names p2-b, which is then dropped
    # from inflight.json (but its ledger stays usable) -- the binding still
    # governs bbbb2's writes.
    my $fx = fixture(members => 2);
    write_json("$fx->{D}/.drive-solo/inflight.json",
        { packages => [ { blueprint => 'bpx', package => 'p1-a', ledger => 'ignored', since => 1 } ], updated_at => 2 });
    my $sub = subagent_payload(agent_id => 'bbbb2', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{R}/src/b/x.pl");
    is(wg_writes($sub, env => env_for($fx->{D}))->{rc}, 0,
        'AC-34(B3, binding stands): bbbb2 (bound to p2-b) still writes src/b/x.pl after p2-b drops out of inflight.json');
    my $sub_bad = subagent_payload(agent_id => 'bbbb2', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, file_path => "$fx->{R}/src/a/x.pl");
    is(wg_writes($sub_bad, env => env_for($fx->{D}))->{rc}, 2,
        'AC-34(B3, binding stands): bbbb2 is still confined to p2-b\'s write_set, not p1-a\'s');
}

{
    # overlapping write sets: p2-b's write_set is widened to also cover
    # p1-a's test_paths directory (t/a/). For the driver's union, a
    # test_paths match in ANY member still wins over a write_set match in
    # another.
    my $fx = fixture(members => 2);
    write_ledger($fx->{D}, package => 'p2-b', write_set => 'src/b/:t/a/', test_paths => 't/b/');
    my $drv = driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, file_path => "$fx->{R}/t/a/x.t");
    my $r = wg_writes($drv, env => env_for($fx->{D}));
    is($r->{rc}, 2, 'AC-34(B3, overlap): a test_paths match in one member wins over a write_set match in another, for the driver');
    like($r->{err}, qr/may not modify test files/, 'AC-34(B3, overlap): the deny is the test-file deny, not a plain write-set allow');
}

# =============================================================================
# AC-35 (Decision 70, fix-batch.md sec D A10, red-team rt13.pl M1 -- repro
# lines 36/37/43 of rt13-after.txt): among packages/*.md in a blueprint dir,
# a bound subagent may write only ITS OWN package's ledger -- any sibling
# package ledger is denied, in writes mode and ledger mode alike, with a
# message naming both packages. For the driver main thread, V6 (the
# scope-freeze of write_set/test_paths) applies to EVERY in-flight member's
# ledger, not just one.
# =============================================================================
{
    # (a) subagent bound to p1-a rewriting the SIBLING ledger p2-b.md is
    # denied in both modes, for three different sibling-ledger contents.
    my %variants = (
        malformed_glob => sub {
            return ledger_body(package => 'p2-b', write_set => 'src/b/:[z-a]', test_paths => 't/b/');
        },
        blanked_test_paths_widened_write_set => sub {
            return ledger_body(package => 'p2-b', write_set => 'src/b/:src/', test_paths => '');
        },
        harmless_attempt_log_append => sub {
            my $b = ledger_body(package => 'p2-b', write_set => 'src/b/', test_paths => 't/b/');
            $b =~ s/- note\n/- note\n- another attempt, no scope change\n/;
            return $b;
        },
    );

    for my $variant_name (sort keys %variants) {
        my $fx = fixture(members => 2);
        my $sib_path = "$fx->{D}/blueprints/bpx/packages/p2-b.md";
        my $content  = $variants{$variant_name}->();
        my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
            cwd => $fx->{R}, tool_name => 'Write', file_path => $sib_path, content => $content);

        my $rw = wg_writes($sub, env => env_for($fx->{D}));
        is($rw->{rc}, 2, "AC-35(a, $variant_name): writes mode, sibling ledger rewrite gives rc 2");
        like($rw->{err}, qr/p1-a/, "AC-35(a, $variant_name): writes-mode deny names p1-a");
        like($rw->{err}, qr/p2-b/, "AC-35(a, $variant_name): writes-mode deny names p2-b");

        my $rl = wg_ledger($sub, env => env_for($fx->{D}));
        is($rl->{rc}, 2, "AC-35(a, $variant_name): ledger mode, sibling ledger rewrite gives rc 2");
        like($rl->{err}, qr/p1-a/, "AC-35(a, $variant_name): ledger-mode deny names p1-a");
        like($rl->{err}, qr/p2-b/, "AC-35(a, $variant_name): ledger-mode deny names p2-b");
    }
}

{
    # (b) the same subagent appending to its OWN ledger's attempt log stays
    # rc 0 in both modes; writing its own blueprint reports/ file stays rc 0.
    my $fx = fixture(members => 2);
    my $own_path = "$fx->{D}/blueprints/bpx/packages/p1-a.md";
    my $own_body = ledger_body(package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    $own_body =~ s/- note\n/- note\n- own attempt, no scope change\n/;
    my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, tool_name => 'Write', file_path => $own_path, content => $own_body);

    is(wg_writes($sub, env => env_for($fx->{D}))->{rc}, 0, 'AC-35(b): writes mode, own ledger attempt-log append gives rc 0');
    is(wg_ledger($sub, env => env_for($fx->{D}))->{rc}, 0, 'AC-35(b): ledger mode, own ledger attempt-log append gives rc 0');

    my $report = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, tool_name => 'Write', file_path => "$fx->{D}/blueprints/bpx/reports/r.md", content => 'x');
    is(wg_writes($report, env => env_for($fx->{D}))->{rc}, 0, 'AC-35(b): writes mode, own blueprint reports/ file gives rc 0');
}

{
    # (c) the driver main thread, two in flight: widening p2-b's write_set
    # is denied -- V6 now covers EVERY in-flight member's ledger, not just
    # the one the driver happens to be touching for its own sake. Changing
    # only p2-b's status stays allowed.
    my $fx = fixture(members => 2);
    my $b_path = "$fx->{D}/blueprints/bpx/packages/p2-b.md";
    my $widened = ledger_body(package => 'p2-b', write_set => 'src/b/:other/', test_paths => 't/b/');
    my $r = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
        file_path => $b_path, content => $widened), env => env_for($fx->{D}));
    is($r->{rc}, 2, 'AC-35(c): driver widening p2-b\'s write_set gives rc 2 (V6 on every in-flight member)');
    like($r->{err}, qr/write_set/, 'AC-35(c): deny mentions write_set');

    my $status_only = ledger_body(package => 'p2-b', write_set => 'src/b/', test_paths => 't/b/', status => 'done');
    my $r2 = wg_ledger(driver_payload(session_id => $fx->{sid}, cwd => $fx->{R}, tool_name => 'Write',
        file_path => $b_path, content => $status_only), env => env_for($fx->{D}));
    is($r2->{rc}, 0, 'AC-35(c): driver changing only p2-b\'s status gives rc 0');
}

SKIP: {
    skip 'AC-35: BpHook::WriteGuards not requireable yet', 1 unless $REQUIRE_OK;
    # (d) repeat (a)(ii) [blanked test_paths, widened write_set] under
    # CASE_INSENSITIVE=1 with the sibling ledger path spelled P2-B.md.
    local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;
    my $fx = fixture(members => 2);
    my $sib_path = "$fx->{D}/blueprints/bpx/packages/P2-B.md";
    my $content  = ledger_body(package => 'p2-b', write_set => 'src/b/:src/', test_paths => '');
    my $sub = subagent_payload(agent_id => 'aaaa1', session_id => $fx->{sid}, transcript_path => shape_a_transcript($fx),
        cwd => $fx->{R}, tool_name => 'Write', file_path => $sib_path, content => $content);

    my $rw = wg_writes($sub, env => env_for($fx->{D}));
    is($rw->{rc}, 2, 'AC-35(d, CASE_INSENSITIVE=1): writes mode, sibling ledger spelled P2-B.md gives rc 2');
    my $rl = wg_ledger($sub, env => env_for($fx->{D}));
    is($rl->{rc}, 2, 'AC-35(d, CASE_INSENSITIVE=1): ledger mode, sibling ledger spelled P2-B.md gives rc 2');
}

done_testing();
