#!/usr/bin/env perl
# platform: any
# 10-unreapable-running — bp-lifecycle.pl reconcile gains repair 3
# (orphaned `running`) and the criterion-7 escalation self-withdrawal sweep.
#
# Spec: .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/10-unreapable-running-spec.md
#
# Written BLIND to bp-lifecycle.pl's implementation (test-writer role): every
# assertion below is derived from the spec's §2 interface contracts, §4
# observable behaviours and §5 acceptance criteria, never from reading the
# script. At authoring time neither repair exists, so every "repair applies"
# assertion (AC1, AC2, AC3a/b, AC7a-f) is expected to FAIL on missing
# behaviour. The "must not touch live work" assertions (AC4a-e) are expected
# to ALREADY PASS today, because today's reconciler does nothing at all in
# those shapes — they exist to prove the new predicate doesn't regress that.
#
# Fixture idiom (make_blueprint/run_lifecycle/blueprint_md/ledger_md) copied
# byte-for-byte in spirit from lifecycle-reconcile.t so both files share one
# convention; extended with pidfile/solo-claim/escalation helpers this
# package's new surface needs.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;

my $DIR       = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }));
my $SCRIPTS   = "$DIR/../../scripts";
my $LIFECYCLE = "$SCRIPTS/bp-lifecycle.pl";
my $ORCH      = "$SCRIPTS/bp-orchestrator.pl";

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');
ok(-f $ORCH, 'bp-orchestrator.pl exists (required read-only for AC2)') or BAIL_OUT('nothing to test');

# AC2's construction: require the orchestrator read-only (idiom of
# write-guard-sites.t:29) so its own launch predicate can be called without
# modifying or running it. `unless (caller)` at its own EOF keeps this safe.
require $ORCH;

my $J = JSON::PP->new->canonical->pretty;

# Fix-batch / H2 (redteam): repairs 3/4 refuse when a blueprint carries pid
# artefacts (marker/pidfile/registry pid) and $ENV{IS_SANDBOX} is unset, since
# a host-side reconcile cannot trust kill(0,$pid) against a container pid.
# Every pid artefact this file's fixtures construct (marker=>, write_pidfile,
# a registry row's pid) is standing in for something that, in production,
# only ever exists because sandbox-only tooling wrote it -- so IS_SANDBOX=1
# for the whole run here represents that context honestly. One dedicated
# block below deliberately clears it to prove the gate itself (added, not
# weakening any existing assertion).
$ENV{IS_SANDBOX} = 1;

# --------------------------------------------------------------- fixtures ---
# (identical in shape to lifecycle-reconcile.t's own helpers)

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub blueprint_md {
    my (%o) = @_;
    my $status = $o{status} // 'running';
    my $rows   = '';
    for my $p (@{ $o{packages} || [] }) {
        $rows .= "| $p->{pkg} | thing | — | sonnet | $p->{table} |\n";
    }
    return <<"MD";
# Test Blueprint

```
blueprint: $o{name}
created: 2026-01-01
last_updated: 2026-01-01T00:00Z
status: $status        # drafting | audited | running | done | archived
```

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
$rows
## Harvest log

## Incidents

MD
}

sub ledger_md {
    my (%o) = @_;
    return <<"MD";
---
package: $o{pkg}
blueprint: $o{blueprint}
status: $o{status}
last_updated: 2026-01-01T00:00Z
---

# Package $o{pkg}

## Next action

None.
MD
}

# Variant carrying a real write_set:, needed for AC2's launchability proof
# (ready_packages consults write_sets_overlap, which needs a defined value).
sub ledger_md_ws {
    my (%o) = @_;
    return <<"MD";
---
package: $o{pkg}
blueprint: $o{blueprint}
status: $o{status}
write_set: $o{pkg}/
last_updated: 2026-01-01T00:00Z
---

# Package $o{pkg}

## Next action

None.
MD
}

sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/blueprints/$name";
    make_path("$dir/packages");
    my @pkgs = @{ $o{packages} || [] };
    write_file("$dir/blueprint.md", blueprint_md(name => $name, status => $o{status} // 'running',
                                                 packages => \@pkgs));
    for my $p (@pkgs) {
        write_file("$dir/packages/$p->{pkg}.md",
                   ledger_md(pkg => $p->{pkg}, blueprint => $name, status => $p->{ledger}));
    }
    if (exists $o{marker}) {
        make_path("$dir/runs");
        write_file("$dir/runs/.orchestrator", $o{marker});
    }
    if ($o{registry}) {
        make_path("$dir/runs");
        write_file("$dir/runs/registry.json", $J->encode($o{registry}));
    }
    return $dir;
}

sub run_lifecycle {
    my (@args) = @_;
    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
    # Capture through a REAL temp file, never an in-memory scalar handle
    # (project CLAUDE.md — Git-for-Windows perl fails that with "Bad file
    # descriptor"). Run exactly once per call site.
    open(my $saved, '>&', \*STDOUT) or die "dup: $!";
    open(STDOUT, '>', $tmp) or die "redirect: $!";
    my $rc = system($^X, $LIFECYCLE, @args, '--json');
    open(STDOUT, '>&', $saved);
    close $saved;
    my $out = slurp($tmp) // '';
    unlink $tmp;
    my $data = eval { JSON::PP->new->decode($out) };
    return ($rc >> 8, $data, $out);
}

# --------------------------------------------------------- new-surface helpers ---

sub write_pidfile {
    my ($dir, $pkg, $content) = @_;
    make_path("$dir/runs");
    write_file("$dir/runs/$pkg.pid", $content);
}

sub write_solo_current {
    my ($root, $bp, $pkg) = @_;
    write_file("$root/.drive-solo/current.json",
        $J->encode({ blueprint => $bp, package => $pkg, recorded_at => 1_800_000_000 }));
}

sub esc_record {
    my (%o) = @_;
    return {
        package    => $o{package},
        blueprint  => $o{blueprint},
        kind       => $o{kind},
        question   => $o{question}   // 'q',
        context    => $o{context}    // { ledger => "packages/$o{package}.md" },
        created_at => $o{created_at} // 10,
        category   => $o{category}   // 'implementation',
    };
}

sub write_escalation {
    my ($path, $rec) = @_;
    write_file($path, $J->encode($rec));
}

sub find_action {
    my ($data, $kind) = @_;
    return (grep { $_->{kind} eq $kind } @{ $data->{actions} || [] })[0];
}

# Extract (frontmatter-block, body-after) for a ledger file's text.
sub fm_and_body {
    my ($txt) = @_;
    return ($txt =~ /\A(---\s*\n.*?\n---\s*\n?)(.*)\z/s) ? ($1, $2) : (undef, $txt);
}

my $ISO_RE = qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

# ============================================================================
# AC1 (DC1, B1) — the headline repair: dead marker, ledger running, registry
# has no row at all -> orphan_running, applied:1, ledger frontmatter flips to
# pending.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac1', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my $before = slurp("$dir/packages/01-a.md");
    my (undef, $body_before) = fm_and_body($before);

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac1', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC1: exit 0');
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC1: an orphan_running action is present') or diag(explain($data));
    if ($act) {
        is($act->{applied}, 1, 'AC1: applied:1');
        is_deeply($act->{packages}, ['01-a'], 'AC1: packages lists the one repaired package');
    }
    my $after = slurp("$dir/packages/01-a.md");
    like($after, qr/^status:\s*pending\s*$/m, 'AC1: ledger frontmatter now reads status: pending');
    my ($fm_after, $body_after) = fm_and_body($after);
    # $ISO_RE carries its own ^/$ anchors (no /m), so nesting it inside an
    # /m-flagged pattern can never match at a non-zero offset -- extract the
    # value and match it against $ISO_RE standalone instead.
    my ($lu_after) = $fm_after =~ /^last_updated:\s*(\S+)\s*$/m;
    like($lu_after // '', $ISO_RE, 'AC1: last_updated rewritten to a current UTC ISO-8601 Z stamp')
        or diag($fm_after);
    is($body_after, $body_before, 'AC1: everything after the frontmatter block is byte-identical');
}

# ============================================================================
# AC2 (DC2) — after the repair the package is actually LAUNCHABLE: proved via
# the orchestrator's own BpOrch::ready_packages/_load_state, not by reading
# the word back. [UNVERIFIED-BY-EXECUTION per spec §0]: attempted exactly as
# spec'd in "AC2's construction, spelled out" (spec line ~460).
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $name = 'ac2';
    my $pkg  = '01-a';
    my $dir  = "$root/blueprints/$name";
    make_path("$dir/packages");
    write_file("$dir/blueprint.md", blueprint_md(name => $name, status => 'running',
        packages => [ { pkg => $pkg, table => 'running' } ]));
    write_file("$dir/packages/$pkg.md", ledger_md_ws(pkg => $pkg, blueprint => $name, status => 'running'));

    my ($meta_before, $status_before) = BpOrch::_load_state($dir, "$dir/runs");
    my @ready_before = BpOrch::ready_packages($meta_before, $status_before, []);
    ok(!(grep { $_ eq $pkg } @ready_before),
       'AC2: BEFORE the repair, the orchestrator\'s own predicate does NOT consider the package ready');

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', $name, '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC2: exit 0');

    my ($meta_after, $status_after) = BpOrch::_load_state($dir, "$dir/runs");
    my @ready_after = BpOrch::ready_packages($meta_after, $status_after, []);
    ok((grep { $_ eq $pkg } @ready_after),
       'AC2: AFTER the repair, BpOrch::ready_packages DOES contain the package — it is actually launchable, not merely reworded');
}
# AC2b — fallback / additional witness: the raw word is the literal `pending`
# with no decoration (no comment, no trailing text), since _load_state reads
# the RAW frontmatter value. Recorded per spec as run regardless of AC2's
# outcome (it is cheap and independently informative).
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac2b', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    run_lifecycle('reconcile', '--blueprint', 'ac2b', '--data-dir', $root, '--no-archive');
    my $after = slurp("$dir/packages/01-a.md");
    like($after, qr/^status: pending$/m,
         'AC2b: the written word is the literal "pending" with no decoration');
}

# ============================================================================
# AC3a (DC3, B1) — shape one: no registry row at all for the package (the
# registry has OTHER rows, and separately: no registry.json file at all).
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac3a', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
        registry => { packages => { other => { pid => 999 } } },
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac3a', '--data-dir', $root, '--no-archive');
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC3a: orphan_running fires when the registry has rows, just none for this package');
    like($act->{detail}, qr/\(no registry row\)/, 'AC3a: detail names the shape "(no registry row)"')
        if $act;
}
{
    # The other half of shape one: no registry.json file present at all.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac3a-null', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    ok(!-e "$dir/runs/registry.json", 'AC3a-null: sanity — no registry.json exists in this fixture');
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac3a-null', '--data-dir', $root, '--no-archive');
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC3a-null: orphan_running also fires with no registry.json file at all');
}

# ============================================================================
# AC3b (DC3, B2) — shape two: a registry row exists but carries no `pid` key.
# The row's other fields (attempt) survive untouched.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac3b', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
        registry => { packages => { '01-a' => { attempt => 2 } } },
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac3b', '--data-dir', $root, '--no-archive');
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC3b: orphan_running fires when the row exists but has no pid key');
    like($act->{detail}, qr/\(registry row has no pid\)/, 'AC3b: detail names the shape "(registry row has no pid)"')
        if $act;
    my $reg = eval { JSON::PP->new->decode(slurp("$dir/runs/registry.json")) };
    is($reg->{packages}{'01-a'}{attempt}, 2, 'AC3b: the row\'s attempt field survives, byte-for-byte in value')
        if $reg;
}

# ============================================================================
# AC4 (DC4) — THE SAFETY GUARD. Five fixtures, each a shape that LOOKS like
# the bug and legitimately is not: the repair must not fire, and (except
# AC4b, which the earlier existing skip already governs) the ledger bytes
# must be completely unchanged. These are the highest-priority assertions in
# this file per the spec's own §3.
# ============================================================================

# AC4a — fleet shape: registry row WITH a live pid ($$, our own — the
# established convention, write-guard-sites.t:183), marker dead. P2 must
# fail: a checkable, alive pid means this is not this bug.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac4a', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
        registry => { packages => { '01-a' => { pid => $$ } } },
    );
    my $before = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac4a', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC4a: exit 0');
    ok(!find_action($data->[0], 'orphan_running'),
       'AC4a (safety): a registry row with a LIVE pid must never be treated as orphaned, whatever the marker says');
    is(slurp("$dir/packages/01-a.md"), $before, 'AC4a (safety): ledger bytes completely unchanged');
}

# AC4b — the mid-launch window itself (§3.1): marker ALIVE ($$), ledger
# running, no registry row. Structurally excluded by the pre-existing early
# return (V1) — the repair block must never even be reached.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac4b', status => 'running', marker => "$$\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my $before = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac4b', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC4b: exit 0');
    my @kinds = map { $_->{kind} } @{ $data->[0]{actions} };
    is_deeply(\@kinds, ['skipped'],
       'AC4b (safety): a LIVE marker means the ONLY action is "skipped" — the repair block is never reached at all');
    is(slurp("$dir/packages/01-a.md"), $before, 'AC4b (safety): ledger bytes completely unchanged');
}

# AC4c — a live coordinator surviving a dead orchestrator (§3.3): no
# registry row, dead marker, but runs/<pkg>.pid holds a live pid. P3 must
# refuse even though the marker and registry both look orphaned.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac4c', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    write_pidfile($dir, '01-a', "$$\n");
    my $before = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac4c', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC4c: exit 0');
    ok(!find_action($data->[0], 'orphan_running'),
       'AC4c (safety): a live runs/<pkg>.pid coordinator must refuse the repair even with no marker and no registry row');
    is(slurp("$dir/packages/01-a.md"), $before, 'AC4c (safety): ledger bytes completely unchanged');
}

# AC4d/AC4e — the live drive-solo package (§3.2), paired in one block so the
# guard is shown SELECTIVE (only the claimed package is protected), not
# universally inert.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac4de', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' },
                      { pkg => '02-b', ledger => 'running', table => 'running' } ],
    );

    # AC4d: current.json claims THIS package -> must not be touched.
    write_solo_current($root, 'ac4de', '01-a');
    my $before_a = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac4de', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC4d/AC4e: exit 0');
    my $act = find_action($data->[0], 'orphan_running');
    if ($act) {
        ok(!(grep { $_ eq '01-a' } @{ $act->{packages} }),
           'AC4d (safety): the package a live solo driver claims is NEVER named in orphan_running.packages');
    } else {
        pass('AC4d (safety): no orphan_running action at all (the only qualifying package is solo-claimed)');
    }
    is(slurp("$dir/packages/01-a.md"), $before_a, 'AC4d (safety): the solo-claimed package\'s ledger bytes are completely unchanged');

    # AC4e (control, same run): 02-b is NOT the claimed package -> repair applies to it.
    ok($act, 'AC4e (control): orphan_running DOES fire for the un-claimed sibling in the very same run') or diag(explain($data));
    if ($act) {
        ok((grep { $_ eq '02-b' } @{ $act->{packages} }),
           'AC4e (control): the un-claimed package IS named in orphan_running.packages — the guard is selective, not universal');
    }
    my $after_b = slurp("$dir/packages/02-b.md");
    like($after_b, qr/^status:\s*pending\s*$/m, 'AC4e (control): the un-claimed package\'s ledger actually flips to pending');
}

# ============================================================================
# AC5 (DC5, B9) — --dry-run over an AC1-shaped fixture: reports applied:0,
# detail begins "would repair", and the ledger is left byte-identical.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac5', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my $before = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac5', '--data-dir', $root, '--no-archive', '--dry-run');
    is($rc, 0, 'AC5: --dry-run exits 0');
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC5: --dry-run still REPORTS the orphan_running action');
    if ($act) {
        is($act->{applied}, 0, 'AC5: applied:0 under --dry-run');
        like($act->{detail}, qr/^would repair/, 'AC5: detail begins "would repair"');
    }
    is(slurp("$dir/packages/01-a.md"), $before, 'AC5: --dry-run leaves the ledger byte-identical');
}

# ============================================================================
# AC6a (DC6, B20) — the existing stale_marker repair is unaffected when it
# co-occurs with a new orphan_running repair in the same blueprint.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac6a', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac6a', '--data-dir', $root, '--no-archive');
    my $sm = find_action($data->[0], 'stale_marker');
    ok($sm, 'AC6a: stale_marker action still fires') or diag(explain($data));
    is($sm->{applied}, 1, 'AC6a: stale_marker still applied:1') if $sm;
    ok(!-e "$dir/runs/.orchestrator", 'AC6a: the stale marker is still removed');
    ok(find_action($data->[0], 'orphan_running'), 'AC6a: orphan_running fires in the SAME run');
}

# ============================================================================
# AC6b (DC6, B20) — the existing stale_pid repair (a TERMINAL package's
# leftover registry pid) is unaffected when it co-occurs with orphan_running
# for a DIFFERENT package.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac6b', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'done',    table => 'done' },
                      { pkg => '02-b', ledger => 'running', table => 'running' } ],
        registry => { packages => { '01-a' => { pid => 2_000_000_000, attempt => 1 } } },
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac6b', '--data-dir', $root, '--no-archive');
    ok(find_action($data->[0], 'stale_pid'), 'AC6b: stale_pid still fires for the terminal package') or diag(explain($data));
    my $act = find_action($data->[0], 'orphan_running');
    ok($act, 'AC6b: orphan_running fires in the SAME run, for the other package');
    is_deeply($act->{packages}, ['02-b'], 'AC6b: orphan_running names only the running, non-terminal package') if $act;
    my $reg = eval { JSON::PP->new->decode(slurp("$dir/runs/registry.json")) };
    ok(!exists $reg->{packages}{'01-a'}{pid}, 'AC6b: the terminal package\'s stray pid is still cleared') if $reg;
}

# ============================================================================
# AC6c (DC6, out-of-scope guard) — a pure orphan_running repair (no terminal
# package present) leaves runs/registry.json completely byte-identical: the
# new repair writes ONLY the ledger.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac6c', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
        registry => { packages => { other => { pid => 12345, attempt => 3 } } },
    );
    my $before_reg = slurp("$dir/runs/registry.json");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac6c', '--data-dir', $root, '--no-archive');
    ok(find_action($data->[0], 'orphan_running'), 'AC6c: orphan_running fires') or diag(explain($data));
    is(slurp("$dir/runs/registry.json"), $before_reg,
       'AC6c: registry.json is completely byte-identical after a pure orphan_running repair — the LEDGER, and only the ledger, is written');
}

# ============================================================================
# AC7a (DC7, B13/B14) — construct the heal: file an awaiting-ledger
# escalation for a package with no ledger (premise still holds -> untouched);
# then create the ledger (premise gone -> withdrawn). Both halves asserted.
# ============================================================================
my ($ac7_root, $ac7_dir, $ac7_esc_path, $ac7_esc_before);
{
    $ac7_root = tempdir(CLEANUP => 1);
    $ac7_dir  = make_blueprint($ac7_root, 'ac7', status => 'running', packages => []);
    make_path("$ac7_dir/runs/escalations");
    $ac7_esc_path = "$ac7_dir/runs/escalations/07-x--1a2b3c.json";
    write_escalation($ac7_esc_path, esc_record(
        package => '07-x', blueprint => 'ac7', kind => 'awaiting-ledger',
        question => "Package '07-x' is listed in blueprint.md's package-status table but has no ledger file.",
    ));
    $ac7_esc_before = slurp($ac7_esc_path);

    # Half 1: no ledger yet -> premise still holds -> byte-identical, no action.
    my ($rc1, $data1) = run_lifecycle('reconcile', '--blueprint', 'ac7', '--data-dir', $ac7_root, '--no-archive');
    is($rc1, 0, 'AC7a half 1: exit 0');
    ok(!find_action($data1->[0], 'escalation_withdrawn'),
       'AC7a half 1: no escalation_withdrawn while the ledger genuinely does not exist');
    is(slurp($ac7_esc_path), $ac7_esc_before, 'AC7a half 1: the record is byte-identical');

    # Now file a second, NOT-self-withdrawable record for a package whose
    # ledger DOES exist, to satisfy AC7c in the same run (see below).
    write_file("$ac7_dir/packages/08-y.md", ledger_md(pkg => '08-y', blueprint => 'ac7', status => 'pending'));
    my $ac7c_path = "$ac7_dir/runs/escalations/08-y--deadbeef.json";
    write_escalation($ac7c_path, esc_record(
        package => '08-y', blueprint => 'ac7', kind => 'stuck-package',
        question => 'stuck',
    ));
    my $ac7c_before = slurp($ac7c_path);

    # Half 2: create the ledger for 07-x -> premise gone -> withdrawn.
    write_file("$ac7_dir/packages/07-x.md", ledger_md(pkg => '07-x', blueprint => 'ac7', status => 'pending'));
    my ($rc2, $data2) = run_lifecycle('reconcile', '--blueprint', 'ac7', '--data-dir', $ac7_root, '--no-archive');
    is($rc2, 0, 'AC7a half 2: exit 0');
    my $act = find_action($data2->[0], 'escalation_withdrawn');
    ok($act, 'AC7a half 2: escalation_withdrawn fires once the ledger exists and parses') or diag(explain($data2));
    is($act->{applied}, 1, 'AC7a half 2: applied:1') if $act;

    # AC7c: the SAME run must leave the stuck-package record for 08-y alone.
    is(slurp($ac7c_path), $ac7c_before, 'AC7c: a non-nominated kind (stuck-package) is byte-identical in the SAME run');
    ok(!(grep { $_ eq '08-y--deadbeef.json' } @{ $act->{records} // [] }),
       'AC7c: the stuck-package record is absent from the withdrawal action\'s records list') if $act;
}

# ============================================================================
# AC7b (DC7, B14) — withdrawal is a state, not a deletion: the file still
# exists, decodes, keeps every original key/value, and gains a well-formed
# withdrawn_at / non-empty withdrawn_reason.
# ============================================================================
{
    ok(-f $ac7_esc_path, 'AC7b: the escalation FILE still exists after withdrawal');
    my $before = eval { JSON::PP->new->decode($ac7_esc_before) };
    my $after  = eval { JSON::PP->new->decode(slurp($ac7_esc_path)) };
    ok(defined $after, 'AC7b: the withdrawn record still decodes as JSON') or diag(slurp($ac7_esc_path));
    if (defined $before && defined $after) {
        for my $k (qw(package blueprint kind question context created_at category)) {
            is_deeply($after->{$k}, $before->{$k}, "AC7b: original key '$k' is present with its original value");
        }
        like($after->{withdrawn_at} // '', $ISO_RE, 'AC7b: withdrawn_at is a well-formed ISO-8601 Z stamp');
        ok(defined $after->{withdrawn_reason} && length($after->{withdrawn_reason}),
           'AC7b: withdrawn_reason is a non-empty string');
    }
}

# ============================================================================
# AC7d (DC7, B16) — idempotent: reconciling a THIRD time over the now-healed
# fixture emits no further escalation_withdrawn action and leaves the record
# byte-identical to its just-withdrawn state.
# ============================================================================
{
    my $post_withdrawal = slurp($ac7_esc_path);
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7', '--data-dir', $ac7_root, '--no-archive');
    is($rc, 0, 'AC7d: exit 0');
    ok(!find_action($data->[0], 'escalation_withdrawn'),
       'AC7d: a second reconcile over an already-withdrawn record emits no escalation_withdrawn action');
    is(slurp($ac7_esc_path), $post_withdrawal, 'AC7d: the record is byte-identical to its post-withdrawal state');
}

# ============================================================================
# AC7e (DC5/DC7, B17) — --dry-run reports escalation_withdrawn applied:0 and
# leaves the record byte-identical.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7e', status => 'running', packages => []);
    make_path("$dir/runs/escalations");
    my $path = "$dir/runs/escalations/09-z--cafebabe.json";
    write_escalation($path, esc_record(package => '09-z', blueprint => 'ac7e', kind => 'awaiting-ledger'));
    write_file("$dir/packages/09-z.md", ledger_md(pkg => '09-z', blueprint => 'ac7e', status => 'pending'));
    my $before = slurp($path);

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7e', '--data-dir', $root, '--no-archive', '--dry-run');
    is($rc, 0, 'AC7e: --dry-run exits 0');
    my $act = find_action($data->[0], 'escalation_withdrawn');
    ok($act, 'AC7e: --dry-run still REPORTS escalation_withdrawn');
    is($act->{applied}, 0, 'AC7e: applied:0 under --dry-run') if $act;
    is(slurp($path), $before, 'AC7e: --dry-run leaves the record byte-identical');
}

# ============================================================================
# AC7f (DC7, B18) — malformed / hostile records are skipped silently: no
# action, no error, exit 0, byte-identical. Three shapes in one blueprint.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7f', status => 'running', packages => []);
    make_path("$dir/runs/escalations");

    my $not_json = "$dir/runs/escalations/10-p--badjson.json";
    write_file($not_json, "not json");

    my $an_array = "$dir/runs/escalations/11-q--arrayshape.json";
    write_file($an_array, $J->encode([1, 2, 3]));

    my $hostile = "$dir/runs/escalations/evil--traversal.json";
    write_file($hostile, $J->encode({ package => '../evil', kind => 'awaiting-ledger' }));

    my %before = map { $_ => slurp($_) } ($not_json, $an_array, $hostile);

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7f', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC7f: exit 0 — a hostile/malformed record never errors the whole reconcile');
    ok(!find_action($data->[0], 'escalation_withdrawn'),
       'AC7f: none of the three malformed/hostile records produce an escalation_withdrawn action');
    ok(!(@{ $data->[0]{errors} || [] }), 'AC7f: no error is reported for any of the three');
    for my $f ($not_json, $an_array, $hostile) {
        is(slurp($f), $before{$f}, "AC7f: $f is byte-identical after reconcile");
    }
    ok(!-e "$dir/packages/evil.md" && !-e "$dir/../evil.md",
       'AC7f: the path-traversal package name never caused anything to be read/written outside packages/');
    # LOW L6 (redteam): the actual traversal target of package => '../evil'
    # read from packages/ is "$dir/packages/../evil.md" == "$dir/evil.md" --
    # assert on it directly rather than only the two paths above, neither of
    # which is the real target.
    ok(!-e "$dir/evil.md",
       'AC7f: the actual traversal target ($dir/evil.md, via packages/../evil) was never created');
}

# ============================================================================
# Supplementary — B11: an unparseable ledger frontmatter causes guarded_write
# to refuse silently (re-read-under-lock closes the race); no action, no
# error, exit 0. Strengthens the "genuinely tested" safety bar the spec's §3
# asks for, at negligible cost.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'b11', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    # Corrupt the frontmatter block so it no longer parses as ---\n...\n---.
    write_file("$dir/packages/01-a.md", "---\npackage: 01-a\nstatus: running\nno closing fence at all\n");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'b11', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'B11: exit 0 even with an unparseable ledger');
    ok(!find_action($data->[0], 'orphan_running'), 'B11: no orphan_running action for an unparseable ledger');
    ok(!(@{ $data->[0]{errors} || [] }), 'B11: no error reported — a refused guarded_write is not an error');
}

# ============================================================================
# H2 (redteam) — added coverage: with pid artefacts present and IS_SANDBOX
# UNSET, repairs 3 and 4 refuse entirely (report "skipped", change nothing)
# rather than trust kill(0,$pid) against a namespace that may not be the one
# that wrote the pid. Every other block in this file runs with IS_SANDBOX=1
# (set at the top); this block deliberately clears it to prove the guard.
# ============================================================================
{
    local $ENV{IS_SANDBOX};
    delete $ENV{IS_SANDBOX};

    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'h2', status => 'running', marker => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my $before = slurp("$dir/packages/01-a.md");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'h2', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'H2: exit 0');
    ok(!find_action($data->[0], 'orphan_running'),
       'H2: orphan_running never fires with a pid artefact present and IS_SANDBOX unset');
    ok(find_action($data->[0], 'skipped'),
       'H2: a "skipped" action is reported instead, explaining the refusal') or diag(explain($data));
    is(slurp("$dir/packages/01-a.md"), $before,
       'H2: the ledger bytes are completely unchanged when the namespace gate refuses');
}
{
    # Control, same shape but a package WITHOUT any pid artefact at all
    # (no marker, no pidfile, no registry row): the gate must not fire for a
    # blueprint that carries nothing container-written to mis-judge, even
    # with IS_SANDBOX unset -- proving the guard is selective, not a blanket
    # "reconcile does nothing on the host" regression.
    local $ENV{IS_SANDBOX};
    delete $ENV{IS_SANDBOX};

    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'h2-control', status => 'running',
        packages => [ { pkg => '01-a', ledger => 'running', table => 'running' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'h2-control', '--data-dir', $root, '--no-archive');
    is($rc, 0, 'H2 control: exit 0');
    ok(find_action($data->[0], 'orphan_running'),
       'H2 control: with NO pid artefact present at all, the repair still fires even with IS_SANDBOX unset')
       or diag(explain($data));
}

done_testing();
