#!/usr/bin/env perl
# platform: any
# Oracle for package 16-cutover batch A (blueprint hook-continuity-remake),
# specs/16-cutover-spec.md A-4, A-5 (sec 2.6, sec 4 "Batch A"). Proves the
# GuardBlueprintWrite 8.3-alias and case rule (Decision 69 A2 carried):
# (A-4) `BLUEPR~1.MD` denies (exit 2, the 8.3 line) with $CASE_INSENSITIVE
# 0 and 1; `Blueprint.MD` under a blueprints dir denies with 1, allows with
# 0; `.../BLUEPR~1/b/PACKAG~1/01-x.md` with no override file denies with
# the ledger-create message; `/plugins/p/Templates/blueprint.md` allows
# with 1; the lowercase long forms behave exactly as
# guards-remake-blueprint-write.t already pins (left unedited); (A-5)
# through the wrapper, a payload naming only `BLUEPR~1.MD` reaches perl
# (denied), and a payload with none of blueprint/Blueprint/BLUEPR spawns 0
# perl.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above and the existing message-text constants already pinned in
# guards-remake-blueprint-write.t (14-guards-remake batch 3), never from
# reading GuardBlueprintWrite.pm or guard-blueprint-write.sh. The
# $CASE_INSENSITIVE auto rule, the BLUEPR~/PACKAG~ 8.3 segment regexes and
# the "$cmp" derivation are the spec's own literal contract (2.6), not an
# implementation detail inferred by reading code.
#
# The 8.3/case rule and $CASE_INSENSITIVE DO NOT EXIST YET at the time this
# file is written -- every case below is expected to fail on MISSING
# BEHAVIOUR, never a harness crash: GuardHarness::run_module() mirrors
# BpHook::main()'s own require-and-call contract, so a module that does not
# yet special-case an 8.3 alias simply falls through to whatever today's
# plain-path rule already does with that literal string (today: allow, an
# 8.3 name is not "blueprint.md") -- a legible red, not a crash.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub mk_root {
    my $t = tempdir(CLEANUP => 1);
    (my $root = $t) =~ s{\\}{/}g;
    make_path("$root/.ccpraxis-local-data/.subagent-guard");
    make_path("$root/.ccpraxis-local-data/bug-reports");
    return $root;
}

# ---------------------------------------------------------------------------
# payload(%o) -- same shape as guards-remake-blueprint-write.t's payload().
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $tool = $o{tool} // 'Write';
    my $ti = {};
    $ti->{file_path}     = $o{file_path}     if exists $o{file_path};
    $ti->{notebook_path} = $o{notebook_path} if exists $o{notebook_path};
    $ti->{command}       = $o{cmd}           if exists $o{cmd};
    my $p = { tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    return $p;
}

sub bw {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardBlueprintWrite', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

my $EIGHT_THREE_LINE_RE = qr/uses a Windows short \(8\.3\) name; write it by its long name\./;
my $BLUEPRINT_L1 = qr/^BLUEPRINT-GUARD: BLOCKED -- direct \S+ refused: /;
my $LEDGER_L1_PREFIX = 'LEDGER-CREATE-GUARD: BLOCKED -- direct ';

my $GBW_REQUIRE_OK = eval { require BpHook::Guards::GuardBlueprintWrite; 1 };
# Not fatal if this fails to require standalone -- GuardHarness::run_module()
# does its own require-by-relative-path per call and fails open (rc 0) if the
# module is missing, which is itself a legible red for A-4/A-5 below. This is
# only used to set/localize $CASE_INSENSITIVE directly.
diag("note: direct require of BpHook::Guards::GuardBlueprintWrite failed ($@); "
   . "\$CASE_INSENSITIVE cases below will exercise whatever GuardHarness's own "
   . "require-by-relative-path sees")
    unless $GBW_REQUIRE_OK;

# ---------------------------------------------------------------------------
# with_case_insensitive($value, $code) -- localizes the package var (however
# it resolves) around one test block, so each A-4 case pins an explicit 0/1
# rather than depending on host auto-detection ($^O on this host is
# MSWin32, which the spec's auto rule already reads as case-insensitive).
# ---------------------------------------------------------------------------
sub with_case_insensitive {
    my ($value, $code) = @_;
    no strict 'refs';
    local ${"BpHook::Guards::GuardBlueprintWrite::CASE_INSENSITIVE"} = $value;
    $code->();
}

# ===========================================================================
# A-4: 8.3-alias and case rule.
# ===========================================================================

# -- BLUEPR~1.MD denied (exit 2, 8.3 line) with CASE_INSENSITIVE 0 and 1 --
for my $ci (0, 1) {
    with_case_insensitive($ci, sub {
        my $root = mk_root();
        my $fp = "$root/.ccpraxis-local-data/BLUEPR~1/x/blueprint.md";
        # The 8.3 alias itself is the basename under test (spec 2.6: "the raw
        # basename matches /\ABLUEPR~[0-9]+\.MD\z/i (every host)"). Use the
        # canonical spelling BLUEPR~1.MD as the file's basename.
        my $fp83 = "$root/.ccpraxis-local-data/blueprints/x/BLUEPR~1.MD";
        my $res = bw(payload(tool => 'Write', session_id => "a4-8dot3-ci$ci", file_path => $fp83));
        is($res->{rc}, 2, "A-4: BLUEPR~1.MD denies with CASE_INSENSITIVE=$ci");
        like($res->{err}, $EIGHT_THREE_LINE_RE, "A-4: BLUEPR~1.MD -- 8.3 line, CASE_INSENSITIVE=$ci");
    });
}

# -- Blueprint.MD under a blueprints dir: denied with 1, allowed with 0 --
{
    my $root = mk_root();
    my $fp = "$root/.ccpraxis-local-data/blueprints/x/Blueprint.MD";

    with_case_insensitive(1, sub {
        my $res = bw(payload(tool => 'Write', session_id => 'a4-casevariant-ci1', file_path => $fp));
        is($res->{rc}, 2, 'A-4: Blueprint.MD under blueprints/ denies with CASE_INSENSITIVE=1');
        like($res->{err}, $BLUEPRINT_L1, 'A-4: Blueprint.MD (CI=1) -- BLUEPRINT-GUARD line 1');
    });
    with_case_insensitive(0, sub {
        my $res = bw(payload(tool => 'Write', session_id => 'a4-casevariant-ci0', file_path => $fp));
        is($res->{rc}, 0, 'A-4: Blueprint.MD under blueprints/ allows with CASE_INSENSITIVE=0');
    });
}

# -- BLUEPR~1/b/PACKAG~1/01-x.md with no override file: denied, ledger-create message --
{
    my $root = mk_root();
    my $fp = "$root/.ccpraxis-local-data/BLUEPR~1/b/PACKAG~1/01-x.md";
    with_case_insensitive(1, sub {
        my $res = bw(payload(tool => 'Write', session_id => 'a4-8dot3-ledger', file_path => $fp));
        is($res->{rc}, 2, 'A-4: BLUEPR~1/b/PACKAG~1/01-x.md with no override file denies');
        like($res->{err}, qr/^\Q$LEDGER_L1_PREFIX\E/, 'A-4: 8.3-path ledger denial uses the LEDGER-CREATE-GUARD line 1');
    });
}

# -- /plugins/p/Templates/blueprint.md allowed with CASE_INSENSITIVE=1 --
{
    my $root = mk_root();
    my $fp = "$root/plugins/p/Templates/blueprint.md";
    with_case_insensitive(1, sub {
        my $res = bw(payload(tool => 'Write', session_id => 'a4-template-mixedcase', file_path => $fp));
        is($res->{rc}, 0, 'A-4: /plugins/p/Templates/blueprint.md allows with CASE_INSENSITIVE=1 (template exemption on $cmp)');
    });
}

# -- lowercase long forms: pin against guards-remake-blueprint-write.t's own
# fixtures, run through THIS file's bw() to prove the rewrite (whatever it
# is) has not disturbed the pre-existing behaviour. guards-remake-
# blueprint-write.t itself is NOT edited or re-run here -- this is a
# same-idiom regression check, not a re-expression of that file's oracle.
{
    my $root = mk_root();

    my $res_bp = bw(payload(tool => 'Write', session_id => 'a4-lc-blueprint',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md"));
    is($res_bp->{rc}, 2, 'A-4 (lowercase regression): plain blueprint.md still denies');
    like($res_bp->{err}, $BLUEPRINT_L1, 'A-4 (lowercase regression): plain blueprint.md still gets BLUEPRINT-GUARD line 1');

    my $res_ledger = bw(payload(tool => 'Write', session_id => 'a4-lc-ledger',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/packages/01-a.md"));
    is($res_ledger->{rc}, 2, 'A-4 (lowercase regression): plain packages/01-a.md still denies');
    like($res_ledger->{err}, qr/^\Q$LEDGER_L1_PREFIX\E/, 'A-4 (lowercase regression): plain packages/01-a.md still gets LEDGER-CREATE-GUARD line 1');

    my $res_tmpl = bw(payload(tool => 'Write', session_id => 'a4-lc-template',
        file_path => "$root/plugins/blueprint/templates/blueprint.md"));
    is($res_tmpl->{rc}, 0, 'A-4 (lowercase regression): plugins/*/templates/blueprint.md (lowercase) still allows');

    my $res_read = bw(payload(tool => 'Read', session_id => 'a4-lc-read',
        file_path => "$root/.ccpraxis-local-data/blueprints/x/blueprint.md"));
    is($res_read->{rc}, 0, 'A-4 (lowercase regression): Read of blueprint.md still allows');
}

# ===========================================================================
# A-5: through the wrapper, BLUEPR~1.MD reaches perl (denied); a payload
# with none of blueprint/Blueprint/BLUEPR spawns 0 perl.
# ===========================================================================
{
    my $root = mk_root();

    my $res_83 = GuardHarness::run_shim('guard-blueprint-write.sh',
        { tool_name => 'Write', session_id => 'a5-shim-83dot3',
          tool_input => { file_path => "$root/.ccpraxis-local-data/blueprints/x/BLUEPR~1.MD" } });
    is($res_83->{rc}, 2, 'A-5: a BLUEPR~1.MD payload reaches perl and denies');
    is(GuardHarness::count_lines($res_83->{shim_log}, 'perl'), 1,
       'A-5: exactly 1 perl launch for the BLUEPR~1.MD payload');

    my $res_none = GuardHarness::run_shim('guard-blueprint-write.sh',
        { tool_name => 'Write', session_id => 'a5-shim-none',
          tool_input => { file_path => "$root/notes/readme.md" } });
    is($res_none->{rc}, 0, 'A-5: a payload naming none of blueprint/Blueprint/BLUEPR allows');
    is(GuardHarness::count_lines($res_none->{shim_log}, 'perl'), 0,
       'A-5: 0 perl launches for a payload naming none of blueprint/Blueprint/BLUEPR');
}

$? = 0;
done_testing();
