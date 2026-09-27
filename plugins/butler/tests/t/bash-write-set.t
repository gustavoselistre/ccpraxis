#!/usr/bin/env perl
# platform: any
# Oracle for blueprint never-halt, package 02-bash-write-set
# (specs/02-bash-write-set-spec.md sec 4, AC-1..AC-35), as amended by
# Decision 32 (blueprint.md): Q1 bp-ui-prober is covered; Q2 scope is
# whatever BpHook::WriteGuards::resolve() yields as write-scoped -- a
# driver-bound subagent OR a coordinator context with a write-capable
# active worker, never role-listed; Q3 the mkdir-ancestor allowance stays;
# Q4 Decision 5 stands (_gb_w never judges a target outside the repo root;
# GB-h (b) is the only rule that ever denies an outside-root target, and
# only outside bypassPermissions/dontAsk).
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above, Decisions 5/14/31/32 (blueprint.md) and the already-shipped
# interfaces it documents as reused (BpHook::WriteGuards::resolve(),
# BpHook::Guards::GuardBash::hyg_targets(), GuardHarness). Neither
# BpHook::WriteGuards::may_write nor GuardBash's _gb_w rule EXISTS YET at
# the time this file is written -- every direct call to may_write is
# wrapped in eval (house pattern) so a missing sub reports "not ok",
# never a harness crash; every Bash-guard call goes through
# GuardHarness::run_module, which itself never dies on a missing/failing
# rule (it fails open, rc 0), so those calls need no eval of their own.
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
use Cwd ();
use Time::HiRes ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $J = JSON::PP->new->utf8->canonical;
(my $DIRNAME   = dirname(__FILE__)) =~ s{\\}{/}g;
(my $BUTLER_DIR = Cwd::abs_path("$DIRNAME/../..") // "$DIRNAME/../..") =~ s{\\}{/}g;
my $WRITEGUARDS_PM = "$BUTLER_DIR/scripts/BpHook/WriteGuards.pm";
my $GUARDBASH_PM   = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBash.pm";

my $IS_WINFAM = ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;

# ---------------------------------------------------------------------------
# byte / JSON IO helpers (house idiom).
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

sub deny_lines { my ($err) = @_; return grep { length } split /\n/, (defined $err ? $err : '') }

sub strip_comments { my ($s) = @_; $s =~ s/#[^\n]*//g; return $s }

# ---------------------------------------------------------------------------
# Ledger body builder (mirrors guards-per-subagent.t's ledger_body/write_ledger).
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

# =============================================================================
# Fixture builder. A tempdir OUTSIDE this repo (Cwd::tempdir under the real
# system temp), never nested under plugins/butler/tests/t/ -- this keeps
# GB-h's own git-toplevel walk-up (CLAUDE_PROJECT_DIR/BP_PROJECT_ROOT are
# deliberately left UNSET below, per the spec's own fixture rule) from ever
# landing on this repo's REAL .git, which would smuggle real-repo identity
# into a supposedly hermetic fixture. Left unresolved, GB-h's own ctx->{R}
# stays undef, so GB-h's (b) outside-sandbox write rule never fires on an
# in-repo-relative-to-the-FIXTURE target -- exactly the separation Decision
# 31 Q3 / spec sec 2.2 "Resolution context" describes: _gb_w judges against
# WriteGuards' OWN root, never GB-h's.
# =============================================================================
sub build_fixture {
    my (%o) = @_;
    my $members = $o{members} // 2;
    my $base    = tempdir(CLEANUP => 1);
    (my $B = $base) =~ s{\\}{/}g;
    my $R       = "$B/repo";
    my $D       = "$R/.ccpraxis-local-data";
    my $TMPFIX  = "$B/tmpfix";
    my $HOMEFIX = "$B/homefix";
    my $OUTSIDE = "$B/outside";

    make_path("$R/src/a", "$R/src/b", "$R/docs", "$R/t/a", "$R/t/b", "$R/.git",
              $TMPFIX, $HOMEFIX, $OUTSIDE);
    make_path("$D/blueprints/bpx/packages", "$D/blueprints/bpx/reports",
              "$D/blueprints/bpx/specs", "$D/blueprints/other",
              "$D/.drive-solo/bindings");

    write_ledger($D, package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    write_ledger($D, package => 'p2-b', write_set => 'src/b/',           test_paths => 't/b/')
        if $members >= 2;

    my @members_list = ({ blueprint => 'bpx', package => 'p1-a' });
    push @members_list, { blueprint => 'bpx', package => 'p2-b' } if $members >= 2;
    write_json("$D/.drive-solo/inflight.json",
        { packages => [ map { { %$_, ledger => 'ignored', since => 1 } } @members_list ], updated_at => 1 });

    my $sid       = 'bws-' . ($o{sidsuffix} // 'main');
    my $state_dir = GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');

    my $X = "$R-transcripts";
    make_path("$X/$sid/subagents");

    return { R => $R, D => $D, X => $X, sid => $sid, state_dir => $state_dir,
             TMPFIX => $TMPFIX, HOMEFIX => $HOMEFIX, OUTSIDE => $OUTSIDE };
}

sub bind_agent {
    my ($fx, $agent_id, $blueprint, $package) = @_;
    my $tuid = "toolu_$agent_id";
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-$agent_id.meta.json", { toolUseId => $tuid });
    write_json("$fx->{D}/.drive-solo/bindings/$tuid.json", { blueprint => $blueprint, package => $package });
}

sub shape_a { my ($fx) = @_; return "$fx->{X}/$fx->{sid}.jsonl" }

# ---------------------------------------------------------------------------
# payload builders (Bash and Edit/Write shapes, per worker-bash-hygiene.t /
# guards-per-subagent.t conventions).
# ---------------------------------------------------------------------------
sub bash_payload {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    $ti->{run_in_background} = $o{run_in_background} if exists $o{run_in_background};
    my $p = { tool_name => 'Bash', tool_input => $ti };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}        if exists $o{agent_id};
    $p->{agent_type}      = $o{agent_type}      if exists $o{agent_type};
    $p->{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    $p->{cwd}             = $o{cwd}             if exists $o{cwd};
    $p->{permission_mode} = $o{permission_mode} if exists $o{permission_mode};
    return $p;
}
sub edit_payload {
    my (%o) = @_;
    my $p = { tool_name => ($o{tool_name} // 'Write'), tool_input => { file_path => $o{file_path} } };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}        if exists $o{agent_id};
    $p->{agent_type}      = $o{agent_type}      if exists $o{agent_type};
    $p->{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    $p->{cwd}             = $o{cwd}             if exists $o{cwd};
    return $p;
}

# Fix-batch (Decision 33 / review S1): default a bound subagent payload's
# agent_type to 'butler:bp-implementer' HERE, in the fixture, rather than
# relying on GuardBash rewriting a blank agent_type for wording purposes.
# A caller that wants a truly absent agent_type must pass agent_type => undef
# explicitly (exists() still sees the key, so the default below is skipped).
sub sub_bash {
    my ($fx, $agent_id, %o) = @_;
    my $no_cwd = delete $o{no_cwd};
    my %args = (session_id => $fx->{sid}, agent_id => $agent_id, transcript_path => shape_a($fx));
    $args{cwd} = $fx->{R} unless $no_cwd;
    $args{agent_type} = 'butler:bp-implementer' unless exists $o{agent_type};
    %args = (%args, %o);
    return bash_payload(%args);
}
sub sub_edit {
    my ($fx, $agent_id, %o) = @_;
    my %args = (session_id => $fx->{sid}, agent_id => $agent_id, transcript_path => shape_a($fx), cwd => $fx->{R});
    $args{agent_type} = 'butler:bp-implementer' unless exists $o{agent_type};
    %args = (%args, %o);
    return edit_payload(%args);
}
sub drv_bash {
    my ($fx, %o) = @_;
    my %args = (session_id => $fx->{sid}, cwd => $fx->{R});
    %args = (%args, %o);
    return bash_payload(%args);
}

sub env_for {
    my ($fx, %extra) = @_;
    return {
        BUTLER_STATE_DIR   => $fx->{state_dir},
        CCPRAXIS_DATA_DIR  => $fx->{D},
        TMP  => $fx->{TMPFIX}, TEMP => $fx->{TMPFIX}, TMPDIR => $fx->{TMPFIX},
        HOME => $fx->{HOMEFIX}, USERPROFILE => $fx->{HOMEFIX},
        LOCALAPPDATA       => undef,
        CLAUDE_PROJECT_DIR => undef,
        BP_PROJECT_ROOT    => undef,
        BP_LEDGER          => undef,
        %extra,
    };
}

sub run_bash { my ($p, %o) = @_; return GuardHarness::run_module('Guards::GuardBash', $p, env => ($o{env} // {})) }
sub run_edit { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['writes']) }

# ---------------------------------------------------------------------------
# Direct in-process resolve()/may_write() seam (guards-per-subagent.t's
# wg_resolve, generalised). may_write does not exist yet -- every call site
# below wraps it in eval.
# ---------------------------------------------------------------------------
my $WG_REQUIRE_OK = eval { require "BpHook/WriteGuards.pm"; 1 };

sub wg_resolve_inprocess {
    my ($payload, %o) = @_;
    my $env = $o{env} // {};
    local %ENV = %ENV;
    for my $k (keys %$env) { if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} } }
    BpHook::load_payload(ref($payload) eq 'HASH' ? $J->encode($payload) : $payload);
    my $p = BpHook::payload();
    return undef unless $WG_REQUIRE_OK;
    return eval { BpHook::WriteGuards::resolve($p) };
}

# =============================================================================
# Fixtures.
# =============================================================================
my $FX = build_fixture(members => 2, sidsuffix => 'main');
bind_agent($FX, 'aaaa1', 'bpx', 'p1-a');
bind_agent($FX, 'bbbb2', 'bpx', 'p2-b');
# no meta.json for 'ccc02' -> unbound, 2 in flight -> resolve() kind 'refused'.

my $FX1 = build_fixture(members => 1, sidsuffix => 'sole');
# no meta.json for 'solex' -> unbound, 1 in flight -> resolve() kind 'sole'.

my $INSTEAD_BASH_LINE = 'Instead (Bash): put scratch output and mutation copies under the temp dir or '
                      . 'the session scratchpad; repo files outside your scope are not yours to change.';

# =============================================================================
# AC-1
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/a/f.pm"), env => $env)->{rc}, 0,
        'AC-1: implementer echo > write_set file (src/a/f.pm) exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/docs/a.md"), env => $env)->{rc}, 0,
        'AC-1: implementer echo > write_set file (docs/a.md) exits 0');
}

# =============================================================================
# AC-2
# =============================================================================
{
    my $env = env_for($FX);
    my $bash_r = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env);
    is($bash_r->{rc}, 2, 'AC-2: implementer echo > out-of-set file (src/b/f.pm) exits 2');
    my @lines = deny_lines($bash_r->{err});
    is($lines[0], "BLOCKED: src/b/f.pm is outside this package's write set (package p1-a).",
        'AC-2: stderr line 1 names src/b/f.pm and package p1-a');
    like($lines[1] // '', qr/write_set: src\/a\/:docs\/a\.md/, 'AC-2: stderr line 2 contains the write_set');
    is($lines[3] // '', $INSTEAD_BASH_LINE, 'AC-2: stderr line 4 is the sec 2.3 "Instead (Bash)" line');
    like($lines[4] // '', qr/^Command: /, 'AC-2: stderr line 5 starts "Command: "');
    for my $l (@lines) { cmp_ok(length($l), '<=', 160, 'AC-2: every stderr line is at most 160 chars') }

    my $edit_r = run_edit(sub_edit($FX, 'aaaa1', file_path => "$FX->{R}/src/b/f.pm"), env => $env);
    is($edit_r->{rc}, 2, 'AC-2: control -- the Edit path also denies src/b/f.pm for this agent');
    my @edit_lines = deny_lines($edit_r->{err});
    is_deeply([ @lines[0 .. 2] ], \@edit_lines, 'AC-2: Bash stderr lines 1-3 equal the Edit path\'s stderr verbatim');
}

# =============================================================================
# AC-3
# =============================================================================
{
    my $env = env_for($FX);
    for my $op ('>>', '2>', '&>', '>|') {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x $op $FX->{R}/src/a/f.pm"), env => $env)->{rc}, 0,
            "AC-3: '$op' into src/a/ exits 0");
        my $r = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x $op $FX->{R}/src/b/f.pm"), env => $env);
        is($r->{rc}, 2, "AC-3: '$op' into src/b/ exits 2");
        is((deny_lines($r->{err}))[0], "BLOCKED: src/b/f.pm is outside this package's write set (package p1-a).",
            "AC-3: '$op' deny line 1 matches AC-2");
    }
}

# =============================================================================
# AC-4 (Decision 11(5))
# =============================================================================
{
    my $env = env_for($FX);
    my $r = run_bash(sub_bash($FX, 'aaaa1', cmd => 'echo x > out.txt'), env => $env);
    is($r->{rc}, 2, 'AC-4: echo x > out.txt at cwd R exits 2 (REL out.txt is outside write_set)');
    like($r->{err}, qr/\bout\.txt\b/, 'AC-4: deny names out.txt');
}

# =============================================================================
# AC-5
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "sed -i 's/a/b/' $FX->{R}/src/a/f.pm"), env => $env)->{rc}, 0,
        'AC-5: sed -i on src/a/f.pm exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "sed -i 's/a/b/' $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-5: sed -i on src/b/f.pm exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "sed -i -e 's/a/b/' $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-5: sed -i -e on src/b/f.pm exits 2');
}

# =============================================================================
# AC-6
# =============================================================================
{
    my $env = env_for($FX);
    for my $cmd ("perl -i -pe 's/a/b/' $FX->{R}/src/a/f.pm", "perl -pi -e 's/a/b/' $FX->{R}/src/a/f.pm") {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env)->{rc}, 0, "AC-6: '$cmd' exits 0");
    }
    for my $cmd ("perl -i -pe 's/a/b/' $FX->{R}/src/b/f.pm", "perl -pi -e 's/a/b/' $FX->{R}/src/b/f.pm") {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env)->{rc}, 2, "AC-6: '$cmd' exits 2");
    }
}

# =============================================================================
# AC-7
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "cp $FX->{TMPFIX}/x $FX->{R}/src/a/x"), env => $env)->{rc}, 0,
        'AC-7: cp TMP -> src/a/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "cp $FX->{R}/src/b/x $FX->{TMPFIX}/x"), env => $env)->{rc}, 0,
        'AC-7: cp src/b/x -> TMP exits 0 (source only read)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "cp $FX->{TMPFIX}/x $FX->{R}/src/b/x"), env => $env)->{rc}, 2,
        'AC-7: cp TMP -> src/b/x exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "cp -t $FX->{R}/src/b $FX->{TMPFIX}/x"), env => $env)->{rc}, 2,
        'AC-7: cp -t src/b TMP exits 2');
}

# =============================================================================
# AC-8
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mv $FX->{TMPFIX}/x $FX->{R}/src/a/x"), env => $env)->{rc}, 0,
        'AC-8: mv TMP -> src/a/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mv $FX->{TMPFIX}/x $FX->{R}/src/b/x"), env => $env)->{rc}, 2,
        'AC-8: mv TMP -> src/b/x exits 2 (dest)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mv $FX->{R}/src/b/x $FX->{TMPFIX}/x"), env => $env)->{rc}, 2,
        'AC-8: mv src/b/x -> TMP exits 2 (source)');
}

# =============================================================================
# AC-9
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "rm $FX->{R}/src/a/x"), env => $env)->{rc}, 0, 'AC-9: rm src/a/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "rm -f $FX->{TMPFIX}/x"), env => $env)->{rc}, 0, 'AC-9: rm -f TMP/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "rm $FX->{R}/src/b/x"), env => $env)->{rc}, 2, 'AC-9: rm src/b/x exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "rm -rf $FX->{R}/src/b"), env => $env)->{rc}, 2, 'AC-9: rm -rf src/b exits 2');
}

# =============================================================================
# AC-10
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x | tee $FX->{R}/src/a/x"), env => $env)->{rc}, 0,
        'AC-10: tee src/a/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x | tee $FX->{TMPFIX}/x"), env => $env)->{rc}, 0,
        'AC-10: tee TMP/x exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x | tee -a $FX->{R}/src/b/x"), env => $env)->{rc}, 2,
        'AC-10: tee -a src/b/x exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x | tee $FX->{TMPFIX}/y $FX->{R}/src/b/x"), env => $env)->{rc}, 2,
        'AC-10: tee TMP/y src/b/x exits 2 (second target out of set)');
}

# =============================================================================
# AC-11
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "touch $FX->{R}/src/b/x"), env => $env)->{rc}, 2, 'AC-11: touch src/b/x exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "truncate -s 0 $FX->{R}/src/b/x"), env => $env)->{rc}, 2,
        'AC-11: truncate -s 0 src/b/x exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "touch $FX->{R}/src/a/x"), env => $env)->{rc}, 0, 'AC-11: touch src/a/x exits 0');
}

# =============================================================================
# AC-12 (Q3: mkdir-ancestor allowance)
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir -p $FX->{R}/src/a/new"), env => $env)->{rc}, 0,
        'AC-12/Q3: mkdir -p src/a/new exits 0 (already in write_set)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir -p $FX->{R}/src"), env => $env)->{rc}, 0,
        'AC-12/Q3: mkdir -p src exits 0 (ancestor of src/a/ write_set pattern)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir $FX->{R}/t"), env => $env)->{rc}, 0,
        'AC-12/Q3: mkdir t exits 0 (ancestor of t/a/ test_paths pattern)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir -p $FX->{R}/src/c"), env => $env)->{rc}, 2,
        'AC-12/Q3: mkdir -p src/c exits 2 (not an ancestor of any in-scope pattern)');
}

# =============================================================================
# M1 (02-review.md) -- the mkdir-ancestor allowance must judge only the mkdir
# itself; it must never memoise a path as allowed for a LATER delete/move in
# the SAME command. `mkdir -p X && rm -rf X` is judged as `rm -rf X`, exactly
# as if the mkdir prefix were absent.
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "rm -rf $FX->{R}/t"), env => $env)->{rc}, 2,
        'M1: bare rm -rf t exits 2 (control)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir -p $FX->{R}/t && rm -rf $FX->{R}/t"), env => $env)->{rc}, 2,
        'M1: mkdir -p t && rm -rf t still exits 2 (mkdir allowance is not memoised for the later rm)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => 'rm -rf src'), env => $env)->{rc}, 2,
        'M1: bare rm -rf src exits 2 (control)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => 'mkdir -p src; rm -rf src'), env => $env)->{rc}, 2,
        'M1: mkdir -p src; rm -rf src still exits 2 (mkdir allowance is not memoised for the later rm)');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "mkdir -p $FX->{R}/src"), env => $env)->{rc}, 0,
        'M1: a plain mkdir -p of an allowed ancestor, alone, stays allowed');
}

# =============================================================================
# AC-13
# =============================================================================
{
    my $env = env_for($FX);
    my %o = (agent_type => 'butler:bp-test-writer');
    is(run_bash(sub_bash($FX, 'aaaa1', %o, cmd => "echo x > $FX->{R}/t/a/x.t"), env => $env)->{rc}, 0,
        'AC-13: test-writer echo > t/a/x.t exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', %o, cmd => "sed -i s/a/b/ $FX->{R}/t/a/x.t"), env => $env)->{rc}, 0,
        'AC-13: test-writer sed -i on t/a/x.t exits 0');
    my $r1 = run_bash(sub_bash($FX, 'aaaa1', %o, cmd => "echo x > $FX->{R}/src/a/f.pm"), env => $env);
    is($r1->{rc}, 2, 'AC-13: test-writer echo > src/a/f.pm exits 2');
    like((deny_lines($r1->{err}))[0], qr/^BLOCKED: bp-test-writer may only write under the package's test paths \(t\/a\/\)/,
        'AC-13: deny line 1 matches _deny_writer_scope');
    my $r2 = run_bash(sub_bash($FX, 'aaaa1', %o, cmd => "sed -i s/a/b/ $FX->{R}/src/a/f.pm"), env => $env);
    is($r2->{rc}, 2, 'AC-13: test-writer sed -i on src/a/f.pm exits 2');
}

# =============================================================================
# AC-14
# =============================================================================
{
    my $env = env_for($FX);
    my $r1 = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/t/a/x.t"), env => $env);
    is($r1->{rc}, 2, 'AC-14: implementer echo > t/a/x.t exits 2');
    like((deny_lines($r1->{err}))[0], qr/^BLOCKED: bp-implementer may not modify test files/,
        'AC-14: deny line 1 matches _deny_test_modify');
    my $r2 = run_bash(sub_bash($FX, 'aaaa1', cmd => "perl -pi -e 1 $FX->{R}/t/a/x.t"), env => $env);
    is($r2->{rc}, 2, 'AC-14: implementer perl -pi -e 1 on t/a/x.t exits 2');

    # Fix-batch (Decision 33 / review S1): with agent_type now explicitly
    # 'butler:bp-implementer' in both payloads (sub_bash's new default), the
    # Bash denial's lines must equal the Edit denial's lines byte-for-byte
    # for the same agent and path -- no test-fixture-only wording clone.
    my $edit14 = run_edit(sub_edit($FX, 'aaaa1', file_path => "$FX->{R}/t/a/x.t"), env => $env);
    is($edit14->{rc}, 2, 'AC-14/S1: control -- Edit also denies t/a/x.t for this agent');
    is_deeply([ deny_lines($r1->{err}) ], [ deny_lines($edit14->{err}) ],
        'AC-14/S1: Bash denial lines equal Edit denial lines byte-for-byte for the same agent and path');
}

# =============================================================================
# AC-15
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{D}/blueprints/bpx/reports/02-x.md"), env => $env)->{rc}, 0,
        'AC-15: writing the blueprint reports/ dir exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{D}/blueprints/bpx/specs/02-x.md"), env => $env)->{rc}, 0,
        'AC-15: writing the blueprint specs/ dir exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{D}/blueprints/bpx/packages/p1-a.md"), env => $env)->{rc}, 0,
        'AC-15: writing its own ledger exits 0');
    my $rsib = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{D}/blueprints/bpx/packages/p2-b.md"), env => $env);
    is($rsib->{rc}, 2, 'AC-15: writing the sibling ledger exits 2');
    like($rsib->{err}, qr/sibling package p2-b/, 'AC-15: deny line 1 contains "sibling package p2-b"');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{D}/blueprints/other/x.md"), env => $env)->{rc}, 2,
        'AC-15: writing another blueprint dir exits 2');
}

# =============================================================================
# AC-16
# =============================================================================
{
    my $env = env_for($FX);
    my $slug = 'proj';
    my $scratch = "$FX->{TMPFIX}/claude/$slug/$FX->{sid}/scratchpad/x";
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $scratch"), env => $env)->{rc}, 0,
        'AC-16: writing the session scratchpad exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{TMPFIX}/x"), env => $env)->{rc}, 0,
        'AC-16: writing directly under TMP exits 0');
    SKIP: {
        skip 'AC-16: 8.3 short-name spelling is a Windows-only concern', 1 unless $IS_WINFAM;
        my $have_cygpath = do { my $v = `cygpath --version 2>/dev/null`; (defined $v && length $v) ? 1 : 0 };
        skip 'AC-16: cygpath is not available on this host', 1 unless $have_cygpath;
        my $short = `cygpath -s -m "$FX->{TMPFIX}" 2>/dev/null`;
        skip 'AC-16: could not obtain an 8.3 form for TMP on this host', 1 unless defined $short && length $short;
        chomp $short;
        (my $short_fwd = $short) =~ s{\\}{/}g;
        skip 'AC-16: the 8.3 short form equals the long form on this host (short names disabled?)', 1
            if lc($short_fwd) eq lc($FX->{TMPFIX});
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $short_fwd/x83"), env => $env)->{rc}, 0,
            'AC-16: writing under an 8.3 TMP spelling exits 0');
    }
}

# =============================================================================
# AC-17 -- AC-15/AC-16 paths give the same verdict via Edit.
# =============================================================================
{
    my $env = env_for($FX);
    for my $abs ("$FX->{D}/blueprints/bpx/reports/02-x.md", "$FX->{D}/blueprints/bpx/specs/02-x.md",
                 "$FX->{D}/blueprints/bpx/packages/p1-a.md", "$FX->{D}/blueprints/bpx/packages/p2-b.md",
                 "$FX->{D}/blueprints/other/x.md", "$FX->{TMPFIX}/x") {
        my $bash_rc = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $abs"), env => $env)->{rc};
        my $edit_rc = run_edit(sub_edit($FX, 'aaaa1', file_path => $abs), env => $env)->{rc};
        is($bash_rc == 0 ? 0 : 2, $edit_rc == 0 ? 0 : 2, "AC-17: $abs -- Bash and Edit agree (allow vs deny)");
    }
}

# =============================================================================
# AC-18 -- as amended by Decision 33 (blueprint.md, consolidating 02-review.md
# M2 and 02-redteam.md M1): the agent-type denylist is DROPPED. _gb_w applies
# exactly when WriteGuards::resolve() yields a context in which the Edit
# guard would confine this agent -- for EVERY bound agent type, and for a
# coordinator context with or without an active-worker marker. So (c)-(e)
# and (g) below no longer assert an unconditional rc 0: they assert Bash's
# rc equals Edit's rc for the same path, built as a table per Decision 33.
# (a), (b), (f) and (h) are genuinely out of WriteGuards::resolve()'s scope
# (refused/sole/driver/unarmed) and are unchanged.
# =============================================================================
{
    my $cmd = "echo x > $FX->{R}/src/b/f.pm";

    # (a) unbound subagent, sole (1 in flight)
    my $env1 = env_for($FX1);
    my $ra = run_bash(sub_bash($FX1, 'solex', cmd => "echo x > $FX1->{R}/src/b/f.pm"), env => $env1);
    is($ra->{rc}, 0, 'AC-18(a): unbound subagent, sole, gives rc 0');
    unlike($ra->{err}, qr/outside this package's write set/, 'AC-18(a): no write-set deny text');

    # (b) unbound subagent, 2 in flight (refused)
    my $env2 = env_for($FX);
    my $rb = run_bash(sub_bash($FX, 'ccc02', cmd => $cmd), env => $env2);
    is($rb->{rc}, 0, 'AC-18(b): unbound subagent, 2 in flight, gives rc 0 (refused kind is not write-scoped)');
    unlike($rb->{err}, qr/outside this package's write set/, 'AC-18(b): no write-set deny text');

    # (c)-(e) -- amended: a bound agent of EVERY type (the former denylist
    # entries, plus a judge type and the Task built-ins Explore/Plan, plus a
    # blank agent_type) gets EXACTLY the Edit verdict for the same in-repo
    # path, no exceptions. Table asked for by Decision 33.
    my @AGENT_TYPE_TABLE = (
        'general-purpose', 'bp-reviewer', 'bp-redteam', 'bp-architect',
        'bp-resolve-judge',   # a judge type
        'Explore', 'Plan',
        undef,                # blank agent_type
    );
    for my $at (@AGENT_TYPE_TABLE) {
        my $label = defined($at) ? $at : '(blank)';
        my %at_opt = defined($at) ? (agent_type => $at) : (agent_type => undef);
        my $bash_r = run_bash(sub_bash($FX, 'aaaa1', %at_opt, cmd => $cmd), env => $env2);
        my $edit_r = run_edit(sub_edit($FX, 'aaaa1', %at_opt, file_path => "$FX->{R}/src/b/f.pm"), env => $env2);
        is($bash_r->{rc}, $edit_r->{rc}, "AC-18($label): Bash exit code equals Edit exit code for src/b/f.pm");
        is($edit_r->{rc}, 2, "AC-18($label): control -- Edit denies a bound agent writing out-of-set (Decision 33)");
    }

    # (f) driver main session, target inside R -> GB-h (b) does not fire either
    my $rf = run_bash(drv_bash($FX, cmd => $cmd), env => $env2);
    is($rf->{rc}, 0, 'AC-18(f): driver main session gives rc 0 for a target inside R');
    unlike($rf->{err}, qr/outside this package's write set/, 'AC-18(f): no write-set deny text');

    # (g) -- amended: a coordinator context WITHOUT an active-worker marker
    # also gets exactly the Edit verdict (Edit still confines the coordinator
    # to write_set via coord_no_worker; Decision 33 drops _gb_w's abstention
    # for this case too).
    my $env_coord = env_for($FX,
        BP_LEDGER       => "$FX->{D}/coord-ledger.md",
        BP_DIR          => "$FX->{D}/blueprints/bpx",
        BP_PROJECT_ROOT => $FX->{R},
        BP_PACKAGE      => 'p1-a',
        BP_WRITE_SET    => 'src/a/:docs/a.md',
        BP_TEST_PATHS   => 't/a/',
    );
    my $rg      = run_bash(bash_payload(cwd => $FX->{R}, cmd => $cmd), env => $env_coord);
    my $edit_rg = run_edit(edit_payload(cwd => $FX->{R}, file_path => "$FX->{R}/src/b/f.pm"), env => $env_coord);
    is($rg->{rc}, $edit_rg->{rc}, 'AC-18(g): coordinator, no active-worker marker -- Bash exit code equals Edit exit code');
    is($edit_rg->{rc}, 2, 'AC-18(g): control -- Edit confines a no-marker coordinator to write_set (coord_no_worker)');

    # (h) unarmed session
    my $rh = run_bash(bash_payload(session_id => 'never-armed-sid', cwd => $FX->{R}, cmd => $cmd), env => $env2);
    is($rh->{rc}, 0, 'AC-18(h): unarmed session gives rc 0');
    unlike($rh->{err}, qr/outside this package's write set/, 'AC-18(h): no write-set deny text');
}

# =============================================================================
# Decision 32 Q2 -- coordinator contexts ARE covered when resolve() yields a
# write-capable worker (active-worker marker names a writer type). This is
# the amendment over the spec's own Q2 default ("no").
# =============================================================================
{
    my $bp_dir = "$FX->{D}/blueprints/bpx";
    make_path("$bp_dir/runs");
    write_bytes("$bp_dir/runs/p1-a.active-worker", 'bp-implementer');
    my $env_coord = env_for($FX,
        BP_LEDGER       => "$FX->{D}/coord-ledger.md",
        BP_DIR          => $bp_dir,
        BP_PROJECT_ROOT => $FX->{R},
        BP_PACKAGE      => 'p1-a',
        BP_WRITE_SET    => 'src/a/:docs/a.md',
        BP_TEST_PATHS   => 't/a/',
    );
    my $rok = run_bash(bash_payload(cwd => $FX->{R}, cmd => "echo x > $FX->{R}/src/a/f.pm"), env => $env_coord);
    is($rok->{rc}, 0, 'Decision32/Q2: coordinator, active worker bp-implementer, in-set write exits 0');
    my $rdeny = run_bash(bash_payload(cwd => $FX->{R}, cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env_coord);
    is($rdeny->{rc}, 2, 'Decision32/Q2: coordinator, active worker bp-implementer, out-of-set write exits 2');
    like($rdeny->{err}, qr/outside this package's write set/,
        'Decision32/Q2: coordinator deny uses the same write-set language as a bound subagent');
    unlink("$bp_dir/runs/p1-a.active-worker");
}

# =============================================================================
# AC-19 -- shared table (done criterion 6). Every row is judged for every
# caller through BOTH BpHook::WriteGuards::may_write() directly and the Edit
# path (WriteGuards::run($p,'writes')); the two must always agree.
# =============================================================================
{
    my @ROWS = (
        ['src/a/f.pm',      sub { "$FX->{R}/src/a/f.pm" }],
        ['src/a/ (dir)',    sub { "$FX->{R}/src/a/" }],
        ['docs/a.md',       sub { "$FX->{R}/docs/a.md" }],
        ['src/b/f.pm',      sub { "$FX->{R}/src/b/f.pm" }],
        ['t/a/x.t',         sub { "$FX->{R}/t/a/x.t" }],
        ['x/tests/t/y.t',   sub { "$FX->{R}/x/tests/t/y.t" }],
        ['out.txt',         sub { "$FX->{R}/out.txt" }],
        ['reports',         sub { "$FX->{D}/blueprints/bpx/reports/r.md" }],
        ['specs',           sub { "$FX->{D}/blueprints/bpx/specs/s.md" }],
        ['own-ledger',      sub { "$FX->{D}/blueprints/bpx/packages/p1-a.md" }],
        ['sibling-ledger',  sub { "$FX->{D}/blueprints/bpx/packages/p2-b.md" }],
        ['other-blueprint', sub { "$FX->{D}/blueprints/other/o.md" }],
        ['drive-solo',      sub { "$FX->{D}/.drive-solo/x" }],
        ['tmp',             sub { "$FX->{TMPFIX}/x" }],
        ['scratchpad',      sub { "$FX->{TMPFIX}/claude/slug1/$FX->{sid}/scratchpad/x" }],
        ['outside',         sub { "$FX->{OUTSIDE}/x" }],
        ['dotdot-collapse', sub { "$FX->{R}/src/../src/b/f.pm" }],
        ['8dot3-segment',   sub { "$FX->{R}/src/ABCDEF~1/x" }],
    );
    push @ROWS, ['case-insensitive (win)', sub { "$FX->{R}/SRC/A/F.PM" }] if $IS_WINFAM;

    my @CALLERS = (
        ['implementer', 'bp-implementer'],
        ['test-writer', 'butler:bp-test-writer'],
        ['ui-prober',   'bp-ui-prober'],
        ['worker-less', 'bp-reviewer'],
    );

    for my $c (@CALLERS) {
        my ($cname, $atype) = @$c;
        for my $row (@ROWS) {
            my ($rname, $mk) = @$row;
            my $abs = $mk->();
            local $BpHook::WriteGuards::CASE_INSENSITIVE = ($rname =~ /^case-insensitive/) ? 1 : undef;
            my $p_edit = sub_edit($FX, 'aaaa1', agent_type => $atype, file_path => $abs);
            my $env = env_for($FX);
            my $R_res = wg_resolve_inprocess($p_edit, env => $env);
            my $v = eval { BpHook::WriteGuards::may_write($R_res, $abs, $p_edit) };
            my $rr = run_edit($p_edit, env => $env);
            ok(ref($v) eq 'HASH' && exists $v->{allow}, "AC-19($cname, $rname): may_write returns a verdict hashref");
            SKIP: {
                skip 'AC-19: may_write is not returning a verdict yet', 2 unless ref($v) eq 'HASH' && exists $v->{allow};
                if ($v->{allow}) {
                    is($rr->{rc}, 0, "AC-19($cname, $rname): may_write allow matches Edit rc 0");
                    is($rr->{err}, '', "AC-19($cname, $rname): matches Edit's empty stderr");
                }
                else {
                    is($rr->{rc}, 2, "AC-19($cname, $rname): may_write deny matches Edit rc 2");
                    is($rr->{err}, join("\n", @{ $v->{lines} // [] }) . "\n",
                        "AC-19($cname, $rname): may_write lines match Edit stderr byte-for-byte");
                }
            }
        }
    }
}

# =============================================================================
# AC-20 -- may_write prints nothing and returns the sec 2.1 structures.
# =============================================================================
{
    my ($ofh, $opath) = tempfile(); close $ofh;
    my ($efh, $epath) = tempfile(); close $efh;
    open(my $so, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $se, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $opath) or die "redirect STDOUT: $!";
    open(STDERR, '>', $epath) or die "redirect STDERR: $!";

    my $abs = "$FX->{R}/src/b/f.pm";
    my $env = env_for($FX);
    my $p_edit = sub_edit($FX, 'aaaa1', file_path => $abs);
    my $R_res = wg_resolve_inprocess($p_edit, env => $env);
    my $v = eval { BpHook::WriteGuards::may_write($R_res, $abs, $p_edit) };

    open(STDOUT, '>&', $so) or die "restore STDOUT: $!";
    open(STDERR, '>&', $se) or die "restore STDERR: $!";
    close $so; close $se;

    is(-s $opath, 0, 'AC-20: may_write writes 0 bytes to STDOUT');
    is(-s $epath, 0, 'AC-20: may_write writes 0 bytes to STDERR');
    unlink $opath, $epath;

    ok(ref($v) eq 'HASH', 'AC-20: may_write returns a hashref for a denied row');
    SKIP: {
        skip 'AC-20: may_write is not implemented yet', 2 unless ref($v) eq 'HASH';
        is($v->{allow}, 0, 'AC-20: denied row has allow=0');
        ok((ref($v->{lines}) eq 'ARRAY' && @{ $v->{lines} } && !(grep { !defined $_ } @{ $v->{lines} })),
            'AC-20: lines is an ARRAY ref of defined strings');
    }
}

# =============================================================================
# AC-21 -- source pins.
# =============================================================================
{
    my $wg_src = strip_comments(read_bytes($WRITEGUARDS_PM) // '');
    my $gb_src = strip_comments(read_bytes($GUARDBASH_PM) // '');

    like($wg_src, qr/\bsub\s+may_write\b/, 'AC-21: WriteGuards.pm defines may_write');
    my ($writes_body) = $wg_src =~ /\bsub\s+_writes\s*\{(.*?)\n\}\n/s;
    $writes_body = '' unless defined $writes_body;
    like($writes_body, qr/\bmay_write\(/, "AC-21: _writes's body calls may_write(");
    unlike($writes_body, qr/_writes_step7\(/, "AC-21: _writes's body no longer calls _writes_step7(");

    like($gb_src, qr/WriteGuards::may_write\(/, 'AC-21: GuardBash.pm calls WriteGuards::may_write(');
    like($gb_src, qr/\bhyg_targets\(/, 'AC-21: GuardBash.pm calls hyg_targets(');
    like($gb_src, qr/\\&_gb_h\s*,\s*\\&_gb_w\s*,\s*\\&_gb_d/, 'AC-21: rule list order is \&_gb_h, \&_gb_w, \&_gb_d');
}

# =============================================================================
# AC-23 -- bypassPermissions/dontAsk parity for AC-1, AC-2, AC-4, AC-13, AC-14.
# =============================================================================
{
    for my $pm (undef, 'bypassPermissions', 'dontAsk') {
        my $env = env_for($FX);
        my $label = defined($pm) ? $pm : 'default';
        is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => $pm, cmd => "echo x > $FX->{R}/src/a/f.pm"), env => $env)->{rc}, 0,
            "AC-23($label): AC-1 in-set write still exits 0");
        is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => $pm, cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
            "AC-23($label): AC-2 out-of-set write still exits 2");
        is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => $pm, cmd => 'echo x > out.txt'), env => $env)->{rc}, 2,
            "AC-23($label): AC-4 repo-root redirect still exits 2");
        is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => $pm, agent_type => 'butler:bp-test-writer',
            cmd => "echo x > $FX->{R}/src/a/f.pm"), env => $env)->{rc}, 2,
            "AC-23($label): AC-13 test-writer writing write_set still exits 2");
        is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => $pm, cmd => "echo x > $FX->{R}/t/a/x.t"), env => $env)->{rc}, 2,
            "AC-23($label): AC-14 implementer writing a test file still exits 2");
    }
}

# =============================================================================
# AC-24 -- GB-h's protected-root ordering wins over the write-set message.
# =============================================================================
{
    my $env = env_for($FX);
    my $r1 = run_bash(sub_bash($FX, 'aaaa1', cmd => 'rm -rf .git'), env => $env);
    is($r1->{rc}, 2, 'AC-24: rm -rf .git exits 2');
    like((deny_lines($r1->{err}))[0], qr/^BLOCKED: rm of a protected path/, 'AC-24: rm -rf .git gives GB-h\'s message');

    my $r2 = run_bash(sub_bash($FX, 'aaaa1', cmd => "rm -rf $FX->{D}"), env => $env);
    is($r2->{rc}, 2, 'AC-24: rm -rf <D> exits 2');
    like((deny_lines($r2->{err}))[0], qr/^BLOCKED: rm of a protected path/, 'AC-24: rm -rf <D> gives GB-h\'s message');

    # This one needs GB-h's own ctx->{R} to know the literal repo root, so
    # CLAUDE_PROJECT_DIR is set to R for this sub-case only.
    my $env_root = env_for($FX, CLAUDE_PROJECT_DIR => $FX->{R});
    my $r3 = run_bash(sub_bash($FX, 'aaaa1', cmd => "mv $FX->{R} /x"), env => $env_root);
    is($r3->{rc}, 2, 'AC-24: mv <R> /x exits 2');
    like((deny_lines($r3->{err}))[0], qr/^BLOCKED: mv of a protected path/, 'AC-24: mv <R> /x gives GB-h\'s message');
}

# =============================================================================
# AC-25 -- out-of-scope guard: unresolvable targets are allowed.
# =============================================================================
{
    my $env = env_for($FX);
    for my $cmd ('echo x > "$OUT"', 'echo x > $(mktemp)', "rm $FX->{R}/src/b/*.pm",
                 qq(cp x "\$D/src/b/y"), 'tee ${F}') {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env)->{rc}, 0, "AC-25: '$cmd' exits 0 (unresolvable)");
    }
}

# =============================================================================
# AC-26 -- payload with no cwd.
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', no_cwd => 1, cmd => 'echo x > rel.txt'), env => $env)->{rc}, 0,
        'AC-26: no cwd, relative target, exits 0 (unresolvable)');
    is(run_bash(sub_bash($FX, 'aaaa1', no_cwd => 1, cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-26: no cwd, absolute out-of-set target, still exits 2');
}

# =============================================================================
# AC-27 -- cd clears cwd under bypass; GB-h's cd message otherwise.
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => 'bypassPermissions',
        cmd => 'cd src/b && echo x > f.pm'), env => $env)->{rc}, 0,
        'AC-27: bypass, cd src/b && relative target, exits 0 (cwd cleared, unresolvable)');
    is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => 'bypassPermissions',
        cmd => "cd src && echo x > $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-27: bypass, cd src && absolute out-of-set target, exits 2');
    my $r3 = run_bash(sub_bash($FX, 'aaaa1', cmd => 'cd src && echo x > f.pm'), env => $env);
    is($r3->{rc}, 2, 'AC-27: without bypass, cd src && ... exits 2');
    like((deny_lines($r3->{err}))[0], qr/changes the working directory/, 'AC-27: without bypass, GB-h\'s cd message wins');
}

# =============================================================================
# AC-28 -- lexical collapse.
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/a/../b/f.pm"), env => $env)->{rc}, 2,
        'AC-28: src/a/../b/f.pm collapses to src/b/f.pm, exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/b/../a/f.pm"), env => $env)->{rc}, 0,
        'AC-28: src/b/../a/f.pm collapses to src/a/f.pm, exits 0');
    is(run_bash(sub_bash($FX, 'aaaa1', permission_mode => 'bypassPermissions',
        cmd => 'echo x > ../outside.txt'), env => $env)->{rc}, 0,
        'AC-28: with bypass, a target resolving outside R exits 0 (not judged by _gb_w)');
}

# =============================================================================
# AC-29 -- Windows-only path spellings.
# =============================================================================
SKIP: {
    skip 'AC-29: Windows path-spelling forms are a Windows-only concern', 1 unless $IS_WINFAM;
    my $env = env_for($FX);
    (my $rdrive = $FX->{R}) =~ s{^([A-Za-z]):}{/\l$1};
    (my $rback  = $FX->{R}) =~ s{/}{\\}g;
    for my $form ($FX->{R}, $rdrive, qq("$rback\\src\\b\\f.pm")) {
        next if $form eq $FX->{R}; # placeholder skip of the base form itself below
    }
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $rdrive/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-29: /c/... form of src/b/f.pm exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env)->{rc}, 2,
        'AC-29: C:/... form of src/b/f.pm exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => qq(echo x > "$rback\\src\\b\\f.pm")), env => $env)->{rc}, 2,
        'AC-29: quoted backslash form of src/b/f.pm exits 2');
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $rdrive/src/a/f.pm"), env => $env)->{rc}, 0,
        'AC-29: /c/... form of src/a/f.pm exits 0');
    local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/SRC/A/F.PM"), env => $env)->{rc}, 0,
        'AC-29: SRC/A/F.PM exits 0 under case-insensitive matching');
}

# =============================================================================
# AC-30 -- never-target forms.
# =============================================================================
{
    my $env = env_for($FX);
    write_bytes("$FX->{R}/t/a/x.t", "1;\n");
    for my $cmd ("perl $FX->{R}/t/a/x.t > /dev/null 2>&1", 'echo x >&2', 'echo x 2>/dev/null',
                 "cat $FX->{R}/src/a/f.pm > /dev/tty") {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env)->{rc}, 0, "AC-30: '$cmd' exits 0");
    }
}

# =============================================================================
# AC-31 -- false-denial set.
# =============================================================================
{
    my $env = env_for($FX);
    write_bytes("$FX->{R}/t/a/x.t", "1;\n");
    my @cmds = (
        "perl -c $FX->{R}/src/a/f.pm",
        'perl scripts/run-tests.pl --fast',
        "perl $FX->{R}/t/a/x.t > $FX->{TMPFIX}/out.txt 2>&1",
        "git diff > $FX->{TMPFIX}/d.txt",
        "grep -rn foo $FX->{R}/src > $FX->{TMPFIX}/g.txt",
        "cp $FX->{R}/src/b/f.pm $FX->{TMPFIX}/f.bak",
        "sed -n 1,5p $FX->{R}/src/b/f.pm",
        "perl -ne 'print' $FX->{R}/src/b/f.pm",
        "ls $FX->{R}/src > $FX->{TMPFIX}/l",
        "mkdir -p $FX->{TMPFIX}/w",
        "BP_VALIDATE_LEDGER=$FX->{D}/blueprints/bpx/packages/p1-a.md perl $FX->{R}/t/a/x.t > $FX->{TMPFIX}/o.txt",
        "echo x >> $FX->{R}/docs/a.md",
    );
    for my $cmd (@cmds) {
        is(run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env)->{rc}, 0, "AC-31: '$cmd' exits 0");
    }
    # heredoc body naming src/b/f.pm is never a target
    my $heredoc = "cat > $FX->{TMPFIX}/s.pl <<'EOF'\nopen(F,'$FX->{R}/src/b/f.pm');\nEOF\n";
    is(run_bash(sub_bash($FX, 'aaaa1', cmd => $heredoc), env => $env)->{rc}, 0,
        'AC-31: heredoc body naming src/b/f.pm exits 0');
}

# =============================================================================
# AC-32 -- fail-open.
# =============================================================================
{
    my $env = env_for($FX);
    no strict 'refs';
    no warnings 'redefine';
    local *BpHook::WriteGuards::may_write = sub { die "AC-32: forced die\n" };
    my $r = run_bash(sub_bash($FX, 'aaaa1', cmd => "echo x > $FX->{R}/src/b/f.pm"), env => $env);
    is($r->{rc}, 0, 'AC-32: a may_write die fails open (rc 0)');
    # GB-a/GB-c only fire under BP_LEDGER (coordinator context) -- give this
    # one probe that context so the "normal verdict" being checked is a real
    # deny, not a guard that never runs here.
    my $env_ledger = env_for($FX, BP_LEDGER => "$FX->{D}/coord-ledger.md");
    my $rg = run_bash(bash_payload(cwd => $FX->{R}, cmd => 'git -C x commit -m y'), env => $env_ledger);
    is($rg->{rc}, 2, 'AC-32: git -C x commit -m y still gives its normal GB-a/GB-c verdict');
}

# =============================================================================
# AC-33 -- deadline handling.
# =============================================================================
{
    my @touches5000 = map { "$FX->{R}/src/a/f$_" } (1 .. 5000);
    my $bigcmd = 'touch ' . join(' ', @touches5000);

    my $env_fast = env_for($FX, BP_GUARD_DEADLINE_SECONDS => '0.001');
    my $r1 = run_bash(sub_bash($FX, 'aaaa1', cmd => $bigcmd), env => $env_fast);
    is($r1->{rc}, 2, 'AC-33: a 0.001s deadline denies the 5000-operand command (fails closed)');
    is((deny_lines($r1->{err}))[0],
        'BLOCKED: this Bash command is over 256 KiB, too large to parse safely for the hygiene checks.',
        'AC-33: deadline deny uses the over-size remedy line');

    # Decision 34: the "no artificial deadline" allow assertion is itself an
    # implicit timing assertion -- a 5000-operand command can legitimately
    # cross GB-h's real 5s deadline under the runner's parallel load and be
    # denied, which is correct fail-closed behaviour, not a bug. So this half
    # of AC-33 uses a separate, smaller (1000-operand) command that finishes
    # well inside the deadline's load headroom, while the deadline-deny half
    # above keeps 5000 operands per Decision 34.
    my @touches1000 = map { "$FX->{R}/src/a/h$_" } (1 .. 1000);
    my $smallcmd = 'touch ' . join(' ', @touches1000);
    my $env_normal = env_for($FX);
    my $t0 = Time::HiRes::time();
    my $r2 = run_bash(sub_bash($FX, 'aaaa1', cmd => $smallcmd), env => $env_normal);
    my $elapsed = Time::HiRes::time() - $t0;
    cmp_ok($elapsed, '<', 12, 'AC-33: without an artificial deadline, a verdict is reached in under 12s');
    is($r2->{rc}, 0, 'AC-33: without an artificial deadline, an all-in-write_set command exits 0');
}

# =============================================================================
# S2 (02-review.md) -- the hyg_targets cache must not survive, with an
# already-expired deadline, from one _gb_w call to the next call of the SAME
# command in the SAME process. Call 1 forces the cache to fill under an
# artificial 0.001s deadline (so its cached deadline_at is already in the
# past by the time call 2 would read it); call 2, immediately after, with no
# artificial deadline, must NOT reuse that stale expired entry.
# =============================================================================
{
    # Decision 34: the proof only needs the SAME command to hit the SAME
    # cache entry across both calls -- it does not need 5000 operands to
    # force the cache to fill, since call 1's artificially tiny 0.001s
    # deadline expires against any non-trivial operand count. Using 1000
    # operands in BOTH calls keeps the proof valid (cache is filled with an
    # already-expired deadline_at by call 1; call 2 must not reuse it) while
    # staying well inside GB-h's real 5s deadline under the runner's
    # parallel load, unlike the original 5000-operand shape.
    my @touches = map { "$FX->{R}/src/a/g$_" } (1 .. 1000);
    my $cachecmd = 'touch ' . join(' ', @touches);

    my $env_expired = env_for($FX, BP_GUARD_DEADLINE_SECONDS => '0.001');
    my $r1 = run_bash(sub_bash($FX, 'aaaa1', cmd => $cachecmd), env => $env_expired);
    is($r1->{rc}, 2,
        'S2: call 1, artificial 0.001s deadline, fails closed (fills the cache with an already-expired deadline_at)');

    my $env_fresh = env_for($FX);
    my $r2 = run_bash(sub_bash($FX, 'aaaa1', cmd => $cachecmd), env => $env_fresh);
    is($r2->{rc}, 0,
        'S2: call 2, same command, no artificial deadline, does not reuse the stale expired cache entry');
}

# =============================================================================
# S3 (02-review.md) -- out-of-root targets are decided lexically, without a
# per-target filesystem stat walk. Under bypassPermissions (GB-h (b) off),
# rm -f of 5000 TMP-relative targets must allow. Per Decision 28's ruling
# (blueprint.md #28), the growth-rate check is a RATIO plus an absolute
# backstop, never a tight absolute bound (contention inflates timings).
# =============================================================================
{
    my $env = env_for($FX);
    my %elapsed;
    for my $n (1000, 5000) {
        my @targets = map { "$FX->{TMPFIX}/s3-$n/f$_" } (1 .. $n);
        my $cmd = 'rm -f ' . join(' ', @targets);
        my $t0 = Time::HiRes::time();
        my $r = run_bash(sub_bash($FX, 'aaaa1', permission_mode => 'bypassPermissions', cmd => $cmd), env => $env);
        $elapsed{$n} = Time::HiRes::time() - $t0;
        cmp_ok($elapsed{$n}, '<', 12, "S3: $n out-of-root targets resolves in under 12s (absolute backstop)");
        # Decision 34: the "exits 0 (allow)" assertion is itself an implicit
        # timing assertion -- 5000 out-of-root targets can legitimately cross
        # GB-h's real 5s deadline under the runner's parallel load and be
        # denied, which is correct fail-closed behaviour, not a bug. So it
        # runs only at n=1000, well inside the deadline's load headroom.
        # n=5000 is kept solely to supply the growth-ratio's second data
        # point below (Decision 28/34).
        is($r->{rc}, 0, "S3: rm -f of $n out-of-root temp targets under bypassPermissions exits 0 (allow)")
            if $n <= 1000;
    }
    my $ratio = $elapsed{5000} / ($elapsed{1000} || 0.0001);
    cmp_ok($ratio, '<', 15,
        'S3: elapsed time for 5x the targets grows less than 15x (rules out a per-target stat-walk blow-up)');
}

# =============================================================================
# AC-34 -- interlock ordering: _gb_w precedes _gb_d.
# =============================================================================
{
    my $env = env_for($FX);
    write_bytes("$FX->{R}/t/a/x.t", "1;\n");
    my $cmd = "BP_VALIDATE_LEDGER=$FX->{D}/blueprints/bpx/packages/p1-a.md perl $FX->{R}/t/a/x.t > out.txt";
    my $r = run_bash(sub_bash($FX, 'aaaa1', cmd => $cmd), env => $env);
    is($r->{rc}, 2, 'AC-34: an interlocked test run whose redirect lands in the repo root still exits 2');
    like((deny_lines($r->{err}))[0], qr/out\.txt is outside this package's write set/,
        'AC-34: deny line 1 is the write-set line, proving _gb_w ran before _gb_d');
}

# =============================================================================
# AC-35 -- bp-ui-prober (Decision 32 Q1).
# =============================================================================
{
    my $env = env_for($FX);
    is(run_bash(sub_bash($FX, 'aaaa1', agent_type => 'bp-ui-prober', cmd => "echo x > $FX->{R}/t/a/p.png"), env => $env)->{rc}, 0,
        'AC-35: ui-prober writing a test_paths file exits 0');
    my $r = run_bash(sub_bash($FX, 'aaaa1', agent_type => 'bp-ui-prober', cmd => "echo x > $FX->{R}/src/a/p.png"), env => $env);
    is($r->{rc}, 2, 'AC-35: ui-prober writing a write_set file exits 2');
    like((deny_lines($r->{err}))[0], qr/^BLOCKED: bp-ui-prober may only write under the package's test paths/,
        'AC-35: deny line 1 matches _deny_writer_scope for bp-ui-prober');
}

# =============================================================================
# S4 (02-review.md) -- the driver main session must never load WriteGuards.pm
# for a Bash call. Checked via %INC in a genuinely SEPARATE perl process:
# GuardHarness::run_module runs every call in THIS process, so %INC here
# would already be "polluted" by every earlier require in this very file
# (AC-19/AC-21 etc. already load WriteGuards.pm), and could never prove
# absence for a later call. A fresh child process is the only honest oracle.
# =============================================================================
{
    my $env = env_for($FX);
    my $result_path = "$FX->{TMPFIX}/s4-result.txt";
    my $child_pl    = "$FX->{TMPFIX}/s4-child.pl";
    my $child_tmpl  = <<'PERL';
use strict; use warnings;
unshift @INC, '__BUTLER_DIR__/scripts';
require '__BUTLER_DIR__/scripts/BpHook.pm';
BpHook::load_payload($ENV{S4_PAYLOAD});
my $p = BpHook::payload();
eval { require 'BpHook/Guards/GuardBash.pm'; BpHook::Guards::GuardBash::run($p); };
open(my $rf, '>', '__RESULT_PATH__') or die $!;
print {$rf} ( (exists $INC{'BpHook/WriteGuards.pm'}) ? '1' : '0' );
close $rf;
PERL
    (my $child_src = $child_tmpl) =~ s/__BUTLER_DIR__/$BUTLER_DIR/g;
    $child_src =~ s/__RESULT_PATH__/$result_path/g;
    write_bytes($child_pl, $child_src);

    my $payload = drv_bash($FX, cmd => "echo x > $FX->{R}/src/a/f.pm");
    {
        local %ENV = %ENV;
        for my $k (keys %$env) { if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} } }
        $ENV{S4_PAYLOAD} = $J->encode($payload);
        system($^X, $child_pl);
    }
    my $result = read_bytes($result_path);
    is($result, '0',
        'S4: a driver-context Bash call, in a fresh child process, never loads WriteGuards.pm (%INC)');
}

done_testing();
