#!/usr/bin/env perl
# platform: any
# Oracle for blueprint hook-continuity-remake, package 24-interlock-scope
# (Decision 85/92). Derived from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 24-interlock-scope-spec.md sections 2-5 and the package ledger's done
# criteria. The new write_sets_overlap()/binding-resolution behaviour under
# test does not exist yet in the guard module at write time: every AC below
# that exercises it is expected to fail for that reason (missing overlap
# scoping, not a harness defect) until the implementer lands it. Existing
# GuardBash.pm/Common.pm/BindDispatch.pm/TrackDispatch.pm source was read
# only for the fixture SHAPES the spec itself names explicitly (worker
# marker JSON, binding JSON, ledger frontmatter, VALIDATION_RE alternatives,
# quote-stripping rules already pinned by the prior package's own oracle) --
# never to derive the new overlap-scoping logic, which the spec's sections
# 2-3 already specify completely on their own.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
my $GUARDBASH_MODULE = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBash.pm";
my $LEDGER_SCRIPT    = "$BUTLER_DIR/scripts/bp-ledger.pl";

# ---------------------------------------------------------------------------
# fixture packages (spec sec 4, "Fixture packages").
# ---------------------------------------------------------------------------
my %PKG = (
    A => { bp => 'fx-bp', pkg => 'pa-alpha', ws => 'plugins/fx/alpha/:plugins/fx/tests/t/alpha.t' },
    B => { bp => 'fx-bp', pkg => 'pb-beta',  ws => 'plugins/fx/beta.pm' },
    C => { bp => 'fx-bp', pkg => 'pc-gamma', ws => 'plugins/fx/alpha/x.pm' },
);
my $DEFAULT_CMD = 'perl plugins/fx/tests/t/alpha.t';

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sub tempdir_n {
    my $t = tempdir(CLEANUP => 1);
    (my $n = $t) =~ s{\\}{/}g;
    return $n;
}

sub payload {
    my (%o) = @_;
    my $p = { tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

sub gb {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash', $p, env => \%env);
}

# write_worker_marker($data_n, $tuid, %f) -- the GB-11 write_worker_marker
# shape (spec sec 4 fixture shape, bullet 1).
sub write_worker_marker {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/workers");
    my $rec = {
        at            => ($f{at} // time()),
        session_id    => $f{session_id},
        subagent_type => $f{subagent_type},
        tool_use_id   => $tuid,
    };
    my $path = "$data_n/.drive-solo/workers/$tuid";
    open(my $fh, '>:raw', $path) or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
    if (exists $f{mtime}) { utime($f{mtime}, $f{mtime}, $path) }
    return $path;
}

# write_binding($data_n, $tuid, %f) -- the bindings/<tuid>.json shape (spec
# sec 4 fixture shape, bullet 2; sec 1's BindDispatch::_bind record).
sub write_binding {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/bindings");
    my $rec = {
        at            => ($f{at} // time()),
        blueprint     => $f{blueprint},
        package       => $f{package},
        session_id    => $f{session_id},
        source        => 'bind-dispatch',
        subagent_type => ($f{subagent_type} // 'bp-test-writer'),
        tool_use_id   => $tuid,
    };
    open(my $fh, '>:raw', "$data_n/.drive-solo/bindings/$tuid.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
}

# write_binding_raw($data_n, $tuid, $bytes) -- a deliberately malformed
# bindings file (AC-6b).
sub write_binding_raw {
    my ($data_n, $tuid, $bytes) = @_;
    make_path("$data_n/.drive-solo/bindings");
    open(my $fh, '>:raw', "$data_n/.drive-solo/bindings/$tuid.json") or die $!;
    print {$fh} $bytes;
    close $fh;
}

# write_ledger($data_n, $bp, $pkg, $ws_line) -- the ledger frontmatter shape
# (spec sec 4 fixture shape, bullet 3). $ws_line undef omits the
# "write_set:" key entirely (AC-6e); '' writes an empty value (AC-6f).
sub write_ledger {
    my ($data_n, $bp, $pkg, $ws_line) = @_;
    make_path("$data_n/blueprints/$bp/packages");
    my $wsline = defined($ws_line) ? "write_set: $ws_line\n" : '';
    my $content = "---\npackage: $pkg\nblueprint: $bp\nstatus: running\n${wsline}---\n\n# x\n";
    open(my $fh, '>:raw', "$data_n/blueprints/$bp/packages/$pkg.md") or die $!;
    print {$fh} $content;
    close $fh;
}

# write_meta_json($transcript_path, $sid, $aid, $tuid) -- the caller
# identity file (spec sec 4 fixture shape, bullet 4).
sub write_meta_json {
    my ($transcript_path, $sid, $aid, $tuid) = @_;
    my $dir = dirname($transcript_path) . "/$sid/subagents";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/agent-$aid.meta.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode({ toolUseId => $tuid });
    close $fh;
}

# write_coordinator_marker($bp_dir, $pkg, $content) -- unchanged from
# guards-remake-bash.t's own helper of the same name, needed for AC-12 (the
# coordinator branch, which this package leaves alone except for the new
# _validation_shaped rules).
sub write_coordinator_marker {
    my ($bp_dir, $pkg, $content) = @_;
    make_path("$bp_dir/runs");
    open(my $fh, '>:raw', "$bp_dir/runs/$pkg.active-worker") or die $!;
    print {$fh} $content;
    close $fh;
}

sub setup_pkg_ledger {
    my ($data_n, $key) = @_;
    my $p = $PKG{$key};
    write_ledger($data_n, $p->{bp}, $p->{pkg}, $p->{ws});
}

sub deny_lines {
    my ($err) = @_;
    my @lines = split /\n/, $err;
    pop @lines while @lines && $lines[-1] eq '';
    return @lines;
}

# ===========================================================================
# AC-1 (DC1) -- caller bound to A; live bp-test-writer worker bound to B
# (disjoint) -> rc 0.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac1-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-1 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');

    my $caller_tuid = 'AC1CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC1WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC1AID', $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC1AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-1: caller in A, disjoint live writer in B -> allow');
}

# ===========================================================================
# AC-2 (DC1) -- caller bound to A; live bp-implementer worker bound to C
# (overlapping) -> rc 2, naming the overlapping package/blueprint, budget-
# checked.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac2-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-2 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');

    my $caller_tuid = 'AC2CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC2WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC2AID', $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC2AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-2: caller in A, overlapping live writer in C -> deny');
    like($res->{err}, qr/BLOCKED \(validation interlock\)/, 'AC-2: message carries the validation-interlock label');
    like($res->{err}, qr/pc-gamma/, 'AC-2: message names the overlapping package pc-gamma');
    like($res->{err}, qr/fx-bp/,    'AC-2: message names the blueprint fx-bp');
    my @lines = deny_lines($res->{err});
    cmp_ok(scalar(@lines), '<=', 2, 'AC-2: stderr is at most 2 non-empty lines');
    for my $l (@lines) {
        cmp_ok(length($l), '<=', 160, 'AC-2: each stderr line is at most 160 chars');
    }
}

# ===========================================================================
# AC-3 (DC1) -- caller bound to A; workers bound to B and C, B's record
# sorting first by name -- a disjoint record does not end the scan.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac3-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-3 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');
    setup_pkg_ledger($data_n, 'C');

    my $caller_tuid = 'AC3CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    # Names deliberately chosen so B's worker sorts before C's worker.
    my $worker_b_tuid = 'AAA3WORKERB';
    write_worker_marker($data_n, $worker_b_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_b_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $worker_c_tuid = 'ZZZ3WORKERC';
    write_worker_marker($data_n, $worker_c_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_c_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    ok(($worker_b_tuid lt $worker_c_tuid), 'AC-3 setup: worker B tuid sorts before worker C tuid');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC3AID', $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC3AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-3: scan continues past the disjoint B record to the overlapping C record -> deny');
    like($res->{err}, qr/pc-gamma/, 'AC-3: message names pc-gamma, not pb-beta');
    unlike($res->{err}, qr/pb-beta/, 'AC-3: message does not name the disjoint pb-beta');
}

# ===========================================================================
# AC-4 (DC1) -- caller bound to A; live writer bound to A itself (a
# different tuid) -- a non-empty write set always overlaps itself.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac4-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-4 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');

    my $caller_tuid = 'AC4CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC4WORKERA';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC4AID', $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC4AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-4: a different worker bound to the caller\'s own package A -> deny');
    like($res->{err}, qr/pa-alpha/, 'AC-4: message names pa-alpha (self-overlap)');
}

# ===========================================================================
# AC-5 (DC1, non-regression) -- caller bound to A; the overlapping worker C
# is (a) not a writer, (b) stale, or (c) a different session -> rc 0 in
# each case.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac5a-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-5a setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');
    my $caller_tuid = 'AC5ACALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = 'AC5AWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-scout');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-scout');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC5AAID', $caller_tuid);
    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC5AAID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-5a: overlapping worker is bp-scout (not a writer) -> allow');
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac5b-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-5b setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');
    my $caller_tuid = 'AC5BCALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = 'AC5BWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer',
        mtime => time() - (180 * 60 + 60));
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC5BAID', $caller_tuid);
    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC5BAID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-5b: overlapping worker marker is stale (older than 180min+60s) -> allow');
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac5c-sid';
    my $other_sid = 'ac5c-other-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-5c setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');
    my $caller_tuid = 'AC5CCALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = 'AC5CWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $other_sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $other_sid, subagent_type => 'bp-implementer');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC5CAID', $caller_tuid);
    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC5CAID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-5c: overlapping worker carries a different session_id -> allow');
}

# ===========================================================================
# AC-6 (DC2) -- caller's tuid resolves but its own binding is unresolvable,
# in six variants, with a live disjoint writer bound to B present in every
# variant -> rc 2, fallback text (not naming pb-beta).
# ===========================================================================
sub ac6_case {
    my (%o) = @_;
    my $data_n = tempdir_n();
    my $sid = "ac6-$o{label}-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "AC-6 ($o{label}) setup: session armed driver");

    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = "AC6WORKER-$o{label}";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $caller_tuid = "AC6CALLER-$o{label}";
    if ($o{binding_bad_json}) {
        write_binding_raw($data_n, $caller_tuid, 'not json {{{');
    }
    elsif ($o{binding_bad_pkg}) {
        write_binding($data_n, $caller_tuid, blueprint => 'fx-bp', package => '../x', session_id => $sid);
    }
    elsif ($o{ledger_missing}) {
        write_binding($data_n, $caller_tuid, blueprint => 'fx-bp', package => 'pa-alpha', session_id => $sid);
        # deliberately no ledger written for fx-bp/pa-alpha
    }
    elsif ($o{ledger_no_wsline}) {
        write_binding($data_n, $caller_tuid, blueprint => 'fx-bp', package => 'pa-alpha', session_id => $sid);
        write_ledger($data_n, 'fx-bp', 'pa-alpha', undef);
    }
    elsif ($o{ledger_empty_ws}) {
        write_binding($data_n, $caller_tuid, blueprint => 'fx-bp', package => 'pa-alpha', session_id => $sid);
        write_ledger($data_n, 'fx-bp', 'pa-alpha', '');
    }
    # else: $o{binding_missing} -- write nothing at all for the caller's tuid.

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, "AID-$o{label}", $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => "AID-$o{label}", transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, "AC-6 ($o{label}): unresolvable own binding -> deny (fallback)");
    like($res->{err}, qr/a write-capable worker \(/, "AC-6 ($o{label}): first line is the fallback text");
    unlike($res->{err}, qr/pb-beta/, "AC-6 ($o{label}): does not name pb-beta (not the overlap message)");
}
ac6_case(label => 'a-no-bindings-file',        binding_missing  => 1);
ac6_case(label => 'b-bindings-not-json',       binding_bad_json => 1);
ac6_case(label => 'c-package-dotdot',          binding_bad_pkg  => 1);
ac6_case(label => 'd-ledger-missing',          ledger_missing   => 1);
ac6_case(label => 'e-ledger-no-write-set-key', ledger_no_wsline => 1);
ac6_case(label => 'f-ledger-empty-write-set',  ledger_empty_ws  => 1);

# ===========================================================================
# AC-7 (DC2) -- caller bound to A; live writer with no binding file at all
# -> rc 2, fallback text.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac7-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-7 setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');

    my $caller_tuid = 'AC7CALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC7WORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    # deliberately no bindings/AC7WORKER.json

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC7AID', $caller_tuid);

    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC7AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-7: live writer with no binding file -> deny (fallback, conservative)');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-7: first line is the fallback text');
}

# ===========================================================================
# AC-8 (DC2) -- driver main thread (agent_id absent): (i) a live writer
# bound to B, driver itself has no binding, (ii) the writer has no binding
# at all either -> rc 2, fallback text, in both.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac8i-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-8i setup: session armed driver');
    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = 'AC8IWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $res = gb(payload(cmd => $DEFAULT_CMD, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-8i: driver main thread, live writer bound to B, driver has no binding -> deny');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-8i: fallback text');
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac8ii-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-8ii setup: session armed driver');
    my $worker_tuid = 'AC8IIWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    # no binding for the worker at all

    my $res = gb(payload(cmd => $DEFAULT_CMD, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-8ii: driver main thread, live writer with no binding at all -> deny');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-8ii: fallback text');
}

# ===========================================================================
# AC-9 (DC2, non-regression) -- subagent with an agent_id but no meta.json;
# a live writer bound to C -> rc 0 (today's fail-open, pinned).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac9-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-9 setup: session armed driver');
    setup_pkg_ledger($data_n, 'C');
    my $worker_tuid = 'AC9WORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    # deliberately never call write_meta_json: no agent-AC9AID.meta.json exists.
    my $res = gb(
        payload(cmd => $DEFAULT_CMD, session_id => $sid, agent_id => 'AC9AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-9: agent_id present but meta.json absent -> allow (fail open, cannot tell apart)');
}

# ===========================================================================
# AC-10/AC-11 (DC3) -- a perl syntax-check flag is never validation-shaped,
# for either caller, with paired non-vacuity controls. Shared setup: a live
# writer bound to C (overlapping A), and both a driver caller and a
# subagent caller bound to A.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac10-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-10/11 setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');

    my $worker_tuid = 'AC10WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $sub_caller_tuid = 'AC10SUBCALLER';
    write_binding($data_n, $sub_caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC10AID', $sub_caller_tuid);

    for my $cmd (
        'perl -c plugins/fx/tests/t/alpha.t',
        'perl -wc plugins/fx/tests/t/alpha.t',
        'perl -Ilib -c plugins/fx/tests/t/alpha.t',
        'perl -c scripts/run-tests.pl',
    ) {
        my $res_driver = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res_driver->{rc}, 0, "AC-10: driver, '$cmd' -> allow despite an overlapping live writer");

        my $res_sub = gb(
            payload(cmd => $cmd, session_id => $sid, agent_id => 'AC10AID', transcript_path => $transcript),
            CCPRAXIS_DATA_DIR => $data_n,
        );
        is($res_sub->{rc}, 0, "AC-10: subagent bound to A, '$cmd' -> allow despite an overlapping live writer");
    }

    for my $cmd (
        'perl plugins/fx/tests/t/alpha.t',
        'perl -c a.t && perl plugins/fx/tests/t/alpha.t',
        'perl -Mcarp plugins/fx/tests/t/alpha.t',
    ) {
        my $res_driver = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res_driver->{rc}, 2, "AC-11 (non-vacuity control): driver, '$cmd' -> deny");
    }
}

# ===========================================================================
# AC-12 (DC3) -- the coordinator branch: a syntax check is exempt there too.
# ===========================================================================
{
    my $tmp = tempdir_n();
    my $bp_dir = "$tmp/bp";
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    is(gb(payload(cmd => 'perl -c t/x.t'), %env)->{rc}, 0,
        'AC-12: coordinator branch, perl -c t/x.t -> allow with a fresh writer marker');
    is(gb(payload(cmd => 'perl t/x.t'), %env)->{rc}, 2,
        'AC-12: coordinator branch, perl t/x.t (no -c) -> deny with a fresh writer marker');
}

# ===========================================================================
# AC-13/AC-14 (DC4) -- the quoted-open-paren rule. A driver main thread with
# a live writer bound to B (any binding suffices to reach a fallback deny
# whenever the command IS validation-shaped; the point of this block is
# whether _validation_shaped(cmd) fires at all).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac1314-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-13/14 setup: session armed driver');
    my $worker_tuid = 'AC1314WORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');

    for my $cmd (
        q{perl plugins/butler/scripts/bp-ledger.pl append-attempt --ledger L --text "validated (perl scripts/run-tests.pl --fast) exit 0"},
        q{perl plugins/butler/scripts/bp-ledger.pl append-attempt --ledger L --text 'validated (perl scripts/run-tests.pl --fast) exit 0'},
        q{perl plugins/butler/scripts/bp-ledger.pl append-attempt --ledger L --text 'see $(perl scripts/run-tests.pl)'},
    ) {
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-13: quoted paren/\$( in a ledger note text -> allow (cmd: $cmd)");
    }

    for my $c (
        [q{(perl scripts/run-tests.pl)}                        => 'unquoted subshell'],
        [q{echo "$(perl scripts/run-tests.pl)"}                => 'double-quoted command substitution'],
        ["echo \"\x60perl t/x.t\x60\""                          => 'backtick inside double quotes'],
        ["cat <<EOF\n\$(perl t/x.t)\nEOF"                       => 'unquoted heredoc with command substitution'],
        [q{bash -c 'perl t/x.t'}                                => 'shell -c invocation'],
        [q{perl t/x.t --note "(y)"}                              => 'plain validation command with a quoted paren elsewhere'],
    ) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-14 (control): $label -> deny") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-15 (DC1) -- overlap parity between GuardBash::write_sets_overlap() and
# bp-ledger.pl's own _widen_ws_prefixes/_widen_prefix_related.
# ===========================================================================
{
    ok(-f $LEDGER_SCRIPT, "AC-15 setup: $LEDGER_SCRIPT exists on disk");
    my $ledger_abs = Cwd::abs_path($LEDGER_SCRIPT) // $LEDGER_SCRIPT;
    my $ledger_ok = eval { require $ledger_abs; 1 };
    ok($ledger_ok, 'AC-15 setup: bp-ledger.pl is require-able (guarded by "unless (caller)")')
        or diag("require failed: $@");

    ok((defined &main::_widen_ws_prefixes),    'AC-15 setup: main::_widen_ws_prefixes exists');
    ok((defined &main::_widen_prefix_related), 'AC-15 setup: main::_widen_prefix_related exists');

    my $has_overlap_fn = defined &BpHook::Guards::GuardBash::write_sets_overlap;
    ok($has_overlap_fn, 'AC-15 setup: BpHook::Guards::GuardBash::write_sets_overlap exists')
        or diag('not yet implemented -- every parity case below fails for that reason');

    my $ci = ($^O =~ /^(?:msys|MSWin32|cygwin|darwin)$/) ? 1 : 0;

    my @cases = (
        [ ['src/a.pl'],              ['src/a.pl'],       1,       'identical paths' ],
        [ ['src/'],                  ['src/a.pl'],       1,       'trailing-slash dir vs file under it' ],
        [ ['src'],                   ['src/a.pl'],       1,       'dir (no slash) vs file under it' ],
        [ ['src/a'],                 ['src/ab.pl'],      0,       'sibling-looking prefix, not a real ancestor' ],
        [ ['src/*.pl'],              ['src/x/y.pm'],     1,       'glob cut then ancestor match' ],
        [ ['*'],                     ['any/x'],          1,       'wildcard-only entry matches anything' ],
        [ ['plugins/b/scripts/x.pm'],['plugins/b/tests/t/y.t'], 0, 'disjoint siblings under a shared dir' ],
        [ ['a/x', 'b/y'],            ['c/z', 'b/y'],     1,       'multi-entry lists, one shared pair' ],
        [ ['a/x'],                   [],                 0,       'empty other side' ],
        [ ['docs/*'],                ['docs'],           1,       'glob cut collapses to the bare dir' ],
        [ ['src//'],                 ['src/a'],          1,       'doubled trailing slash still strips' ],
        [ [''],                      ['x'],              0,       'an empty entry is ignored, not a wildcard' ],
        [ ['Src/A.pl'],              ['src/a.pl'],       $ci,     'case fold, OS-dependent' ],
    );

    for my $c (@cases) {
        my ($a, $b, $expected, $label) = @$c;
        my $got = $has_overlap_fn
            ? eval { BpHook::Guards::GuardBash::write_sets_overlap($a, $b) }
            : undef;
        is($got, $expected, "AC-15 ($label): write_sets_overlap matches the literal expectation");

        my $ref = eval {
            my @pa = main::_widen_ws_prefixes($a);
            my @pb = main::_widen_ws_prefixes($b);
            my $r = 0;
            OUTER: for my $x (@pa) {
                for my $y (@pb) {
                    if (main::_widen_prefix_related($x, $y)) { $r = 1; last OUTER; }
                }
            }
            $r;
        };
        is($got, $ref, "AC-15 ($label): write_sets_overlap matches bp-ledger.pl's own reference semantics");
    }
}

# ===========================================================================
# AC-16 (M-1, review 24-interlock-scope-review.md) -- the perl -c exemption
# must not fire when $rest carries a command substitution, backtick or
# process substitution: the shell still executes those operands even though
# the outer "perl -c ..." itself never runs the script. Pure-function calls,
# exactly like AC-15's use of write_sets_overlap() -- no fixture/filesystem
# needed, since _validation_shaped() takes only the command string.
# Confirmed against the committed code before this addition: all three
# below return 0 (bug); expected (fixed) value is 1.
# ===========================================================================
{
    my $has_fn = defined &BpHook::Guards::GuardBash::_validation_shaped;
    ok($has_fn, 'AC-16 setup: BpHook::Guards::GuardBash::_validation_shaped exists');

    for my $c (
        [q{perl -c $(perl plugins/fx/tests/t/alpha.t)}   => 'command substitution operand'],
        [q{perl -c x.pl `perl plugins/fx/tests/t/alpha.t`} => 'backtick operand'],
        [q{perl -c <(perl plugins/fx/tests/t/alpha.t)}   => 'process substitution operand'],
    ) {
        my ($cmd, $label) = @$c;
        my $got = $has_fn ? BpHook::Guards::GuardBash::_validation_shaped($cmd) : undef;
        ok($got, "AC-16 ($label): perl -c with a nested real test run is still validation-shaped (cmd: $cmd)");
    }

    # Non-vacuity controls: a plain "perl -c" with no nested substitution is
    # still exempt, for both a .t and a .pm operand.
    for my $c (
        [q{perl -c plugins/fx/tests/t/alpha.t} => 'plain -c on a .t file'],
        [q{perl -c x.pm}                       => 'plain -c on a .pm file'],
    ) {
        my ($cmd, $label) = @$c;
        my $got = $has_fn ? BpHook::Guards::GuardBash::_validation_shaped($cmd) : undef;
        is($got ? 1 : 0, 0, "AC-16 (control, $label): plain perl -c stays exempt (cmd: $cmd)");
    }
}

# ===========================================================================
# AC-18 (M-2, review 24-interlock-scope-review.md) -- an interpreter eval
# (perl/node/... with -e/-E/-c) that hides a real test run inside system()/
# exec() must be validation-shaped even though the outer command has no bare
# "perl SOMETHING.t" text of its own once strip_noise blanks the quoted
# body. Pure-function calls against _validation_shaped(), same style as
# AC-16/AC-15.
# ===========================================================================
{
    my $has_fn = defined &BpHook::Guards::GuardBash::_validation_shaped;

    for my $c (
        [q{perl -e 'system("perl t/x.t")'}      => q{system() inside single-quoted -e}],
        [q{perl -e "system(q(perl t/x.t))"}     => q{system() inside double-quoted -e}],
    ) {
        my ($cmd, $label) = @$c;
        my $got = $has_fn ? BpHook::Guards::GuardBash::_validation_shaped($cmd) : undef;
        ok($got, "AC-18: $label -> validation-shaped (cmd: $cmd)");
    }

    # Non-vacuity control: a ledger note whose quoted --text merely mentions
    # the runner, with no interpreter eval anywhere in the command, is still
    # not validation-shaped.
    {
        my $cmd = q{perl plugins/butler/scripts/bp-ledger.pl append-attempt --ledger L --text "see perl scripts/run-tests.pl for details"};
        my $got = $has_fn ? BpHook::Guards::GuardBash::_validation_shaped($cmd) : undef;
        is($got ? 1 : 0, 0, "AC-18 (control): a quoted mention of the runner, no eval -> not validation-shaped (cmd: $cmd)");
    }
}

# ===========================================================================
# AC-19 (S-1, review 24-interlock-scope-review.md) -- write-set scoping is
# an approximation of what a run READS, not what it writes. A subagent
# whose own binding is disjoint from every live writer is still DENIED for
# a full-sweep invocation of the runner script (no path operand, --fast,
# or several plugins), because the sweep reads the whole tree including the
# live writer's half-written files; the same subagent is still allowed for
# a single test file inside its own write set. Caller bound to A, live
# disjoint writer bound to B (same shape as AC-1).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac19-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-19 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');

    my $caller_tuid = 'AC19CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC19WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC19AID', $caller_tuid);

    for my $cmd (
        'perl scripts/run-tests.pl --fast',
        'perl scripts/run-tests.pl',
        'perl scripts/run-tests.pl plugins/fx plugins/other',
    ) {
        my $res = gb(
            payload(cmd => $cmd, session_id => $sid, agent_id => 'AC19AID', transcript_path => $transcript),
            CCPRAXIS_DATA_DIR => $data_n,
        );
        is($res->{rc}, 2, "AC-19: disjoint caller, full-sweep '$cmd' -> deny (sweep reads everything)");
    }

    # Non-vacuity control: a single test file inside the caller's own write
    # set keeps ordinary write-set scoping (disjoint -> allow).
    {
        my $cmd = 'perl scripts/run-tests.pl plugins/fx/tests/t/alpha.t';
        my $res = gb(
            payload(cmd => $cmd, session_id => $sid, agent_id => 'AC19AID', transcript_path => $transcript),
            CCPRAXIS_DATA_DIR => $data_n,
        );
        is($res->{rc}, 0, "AC-19 (control): disjoint caller, single test file in its own write set '$cmd' -> allow");
    }
}

# ===========================================================================
# AC-20 (S-3, review 24-interlock-scope-review.md) -- strip_noise must not
# run unbounded on an oversize command. GB-a already caps the same walk at
# BP_GUARD_MAX_STRIP_BYTES (_match_text_and_reason, default 8000); the
# validation interlock's own probe (_validation_shaped) currently ignores
# that cap and calls strip_noise regardless of length. Observable via a
# command that is validation-shaped only when matched RAW (the pre-change,
# conservative direction for oversize/paren-bearing text): a quoted ledger
# note hiding "(perl scripts/run-tests.pl --fast)" is allowed (0) once
# strip_noise blanks the quoted body, but denied (2) if the oversize command
# instead gets matched raw because the cap kicked in.
# ===========================================================================
{
    my $has_fn = defined &BpHook::Guards::GuardBash::_validation_shaped;
    my $pad = 'x' x 100;
    my $cmd = qq{perl plugins/butler/scripts/bp-ledger.pl append-attempt --ledger L --text "$pad validated (perl scripts/run-tests.pl --fast) exit 0"};
    cmp_ok(length($cmd), '>', 50, 'AC-20 setup: the probe command is longer than the small cap used below');

    my $got_capped = $has_fn
        ? do { local $ENV{BP_GUARD_MAX_STRIP_BYTES} = '50'; BpHook::Guards::GuardBash::_validation_shaped($cmd) }
        : undef;
    ok($got_capped, 'AC-20: oversize relative to BP_GUARD_MAX_STRIP_BYTES=50 -> matched raw -> validation-shaped');

    # Non-vacuity control: the identical command, under a cap comfortably
    # larger than its own length, still gets stripped normally and stays
    # allowed (not validation-shaped) -- pins that the cap change is scoped
    # to oversize commands only.
    my $got_uncapped = $has_fn
        ? do { local $ENV{BP_GUARD_MAX_STRIP_BYTES} = '9000'; BpHook::Guards::GuardBash::_validation_shaped($cmd) }
        : undef;
    is($got_uncapped ? 1 : 0, 0, 'AC-20 (control): comfortably under the cap -> strip_noise runs -> not validation-shaped');
}

# ===========================================================================
# AC-17 (checks: perl-compile) -- GuardBash.pm compiles cleanly.
# ===========================================================================
{
    ok(-f $GUARDBASH_MODULE, "AC-17 setup: $GUARDBASH_MODULE exists on disk");
    my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $GUARDBASH_MODULE);
    is($rc, 0, 'AC-17: perl -c on GuardBash.pm passes');
}

done_testing();
