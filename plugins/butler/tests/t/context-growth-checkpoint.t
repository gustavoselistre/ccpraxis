#!/usr/bin/env perl
# platform: any
# Package 02-context-ceiling-guidance-and-flush (blueprint coordinator-context-discipline).
#
# MIGRATED from the fleet-cost-accounting/02-context-growth-checkpoint single-ceiling
# oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/
# 02-context-ceiling-guidance-and-flush-spec.md (AC1-AC10, AC31, AC32; Observable
# behaviors B1-B10, B30).
#
# WRITTEN BLIND TO THE IMPLEMENTATION. At the time this file is authored:
#   - BpOrch::_ctx_ceiling_env takes no tier argument and reads the single
#     BP_CONTEXT_CEILING_TOKENS var.
#   - BpOrch::_tunables_base() returns a single ctx_ceiling key, not
#     ctx_ceiling_soft/ctx_ceiling_hard.
#   - BpOrch::context_growth_ceiling_breached takes no third (tier) argument.
#   - BpOrch::context_ceiling_tier does not exist at all.
#   - bp-orchestrator.pl has no --ctx-usage CLI seam.
#   - coordinator-protocol/SKILL.md's "Context-growth checkpoint" section still
#     describes the old hand-rolled wc -l/tail -c recipe and the single ceiling.
# Every assertion below that depends on the two-tier model is expected to fail on
# MISSING BEHAVIOR (a missing sub, a missing tier argument, a missing CLI seam, a
# stale SKILL.md section) -- never a harness bug of this file's own making.
#
# UNCHANGED BY THIS MIGRATION (spec SS5.2: "No existing assertion in
# context-growth-checkpoint.t:34-135 may change"): the context_tokens_from_usage and
# last_coordinator_usage blocks immediately below are copied byte-for-byte from the
# pre-migration file. They test two PURE, I/O-free helpers that the spec explicitly
# keeps "byte-identical behaviour and signatures" (SS5.2). If any of these regress,
# that is a real regression, not expected red from missing two-tier behavior.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Cwd qw(getcwd);

require "$Bin/../../scripts/bp-orchestrator.pl";

# Call guard for subs that may not exist yet -- a missing subroutine becomes a
# string result, never a script-aborting die.
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }

# =====================================================================================
# context_tokens_from_usage -- UNCHANGED (SS5.2). Copied verbatim from the pre-
# migration file, lines 34-68.
# =====================================================================================

{
    my $full = { input_tokens => 100, cache_creation_input_tokens => 20, cache_read_input_tokens => 5 };
    is(sc(sub { BpOrch::context_tokens_from_usage($full) }), 125,
       'sums input_tokens + cache_creation_input_tokens + cache_read_input_tokens');
}

{
    my $with_output = {
        input_tokens => 100, cache_creation_input_tokens => 20,
        cache_read_input_tokens => 5, output_tokens => 9_999,
    };
    is(sc(sub { BpOrch::context_tokens_from_usage($with_output) }), 125,
       'output_tokens is deliberately excluded -- it is what the model produced, not what was resent as context');
}

{
    my $partial = { input_tokens => 42 };
    is(sc(sub { BpOrch::context_tokens_from_usage($partial) }), 42,
       'missing fields are treated as 0, not as a fatal error');
}

is(sc(sub { BpOrch::context_tokens_from_usage(undef) }), 0,
   'undef usage -> 0 (Observable behavior 5)');

is(sc(sub { BpOrch::context_tokens_from_usage({}) }), 0,
   'empty-hash usage -> 0 (Observable behavior 5)');

is(sc(sub { BpOrch::context_tokens_from_usage({ input_tokens => 'not-a-number' }) }), 0,
   'non-numeric input_tokens -> 0, never a die (Observable behavior 5)');

is(sc(sub { BpOrch::context_tokens_from_usage('not-a-hashref') }), 0,
   'a non-hashref usage argument -> 0, never a die (defensive, matches _tunables()\' fail-open posture)');

is(sc(sub { BpOrch::context_tokens_from_usage({ input_tokens => -5 }) }), 0,
   'a negative input_tokens does not match the \\d+ numeric-tolerance pattern -> 0, never a negative sum');

# =====================================================================================
# last_coordinator_usage -- UNCHANGED (SS5.2). Copied verbatim from the pre-migration
# file, lines 74-135.
# =====================================================================================

is(sc(sub { BpOrch::last_coordinator_usage([]) }), undef,
   'empty records array -> undef (Observable behavior 9)');

is(sc(sub { BpOrch::last_coordinator_usage(undef) }), undef,
   'undef records -> undef (Observable behavior 9)');

is(sc(sub { BpOrch::last_coordinator_usage('not-an-arrayref') }), undef,
   'a non-arrayref records argument -> undef, never a die');

{
    # A subagent's assistant record is chronologically LAST in the file, but it
    # carries a defined parent_tool_use_id and must be skipped in favor of the
    # coordinator's own (earlier) turn -- the exact distinction Observable
    # behavior 8 calls out, and the reason this sub cannot be "just take the
    # last assistant record."
    my $coord_usage    = { input_tokens => 111, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $subagent_usage = { input_tokens => 999, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $records = [
        { type => 'user',      message => { role => 'user' } },
        { type => 'assistant', parent_tool_use_id => undef, message => { usage => $coord_usage } },
        { type => 'assistant', parent_tool_use_id => 'toolu_01subagent', message => { usage => $subagent_usage } },
    ];
    is(sc(sub { BpOrch::last_coordinator_usage($records) }), $coord_usage,
       'a later subagent-tagged assistant record does not fool the coordinator-own-turn lookup');
}

{
    # Two coordinator turns; the later one must win.
    my $older = { input_tokens => 10, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $newer = { input_tokens => 20, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $records = [
        { type => 'assistant', parent_tool_use_id => undef, message => { usage => $older } },
        { type => 'assistant', parent_tool_use_id => undef, message => { usage => $newer } },
    ];
    is(sc(sub { BpOrch::last_coordinator_usage($records) }), $newer,
       'among multiple own-turn records, the LAST one is returned');
}

{
    # No coordinator-own record exists at all -- only subagent turns.
    my $subagent_usage = { input_tokens => 5, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $records = [
        { type => 'assistant', parent_tool_use_id => 'toolu_01x', message => { usage => $subagent_usage } },
    ];
    is(sc(sub { BpOrch::last_coordinator_usage($records) }), undef,
       'records with only subagent-tagged assistant turns -> undef, never a false coordinator reading');
}

{
    # Malformed/irrelevant records interleaved must not crash the scan.
    my $coord_usage = { input_tokens => 7, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $records = [
        undef,
        'a bare string, not a hashref',
        { type => 'assistant', parent_tool_use_id => undef, message => { usage => $coord_usage } },
        { type => 'assistant', parent_tool_use_id => undef },                  # no message/usage at all
        { type => 'assistant', parent_tool_use_id => undef, message => 'nope' }, # message not a hashref
        { type => 'tool_result' },
    ];
    is(sc(sub { BpOrch::last_coordinator_usage($records) }), $coord_usage,
       'garbage/malformed records are skipped, not fatal, and do not mask a real coordinator record');
}

# =====================================================================================
# TWO-TIER MIGRATION STARTS HERE. Everything below is NEW (or rewritten), covering
# AC1-AC10, AC31, AC32 of the 02-context-ceiling-guidance-and-flush spec.
# =====================================================================================

sub clear_ceiling_env {
    delete $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_HARD_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS}; # the OLD var -- must have zero effect (Decision 7)
}

sub usage_of { my ($n) = @_; return { input_tokens => $n, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } }

# =====================================================================================
# AC1 (B1) -- _tunables_base() defaults: two keys, no ctx_ceiling at all.
# =====================================================================================
subtest 'AC1: _tunables_base() returns ctx_ceiling_soft=250000, ctx_ceiling_hard=350000, no ctx_ceiling key (B1)' => sub {
    local %ENV = %ENV;
    clear_ceiling_env();
    my $t = sc(sub { BpOrch::_tunables_base() });
    is(ref $t, 'HASH', '_tunables_base() returns a hashref') or diag(explain($t));
    SKIP: {
        skip 'not a hashref', 3 unless ref $t eq 'HASH';
        is($t->{ctx_ceiling_soft}, 250_000, 'ctx_ceiling_soft defaults to 250_000');
        is($t->{ctx_ceiling_hard}, 350_000, 'ctx_ceiling_hard defaults to 350_000');
        ok(!exists $t->{ctx_ceiling}, 'the OLD single ctx_ceiling key is GONE, not aliased');
    }
};

# =====================================================================================
# AC2 (B2) -- each env var moves only its own tier, independently.
# =====================================================================================
subtest 'AC2: BP_CONTEXT_CEILING_SOFT_TOKENS and _HARD_TOKENS move only their own tier (B2)' => sub {
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS} = '1000';
        my $t = sc(sub { BpOrch::_tunables_base() });
        SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
            is($t->{ctx_ceiling_soft}, 1000, 'soft moved to 1000');
            is($t->{ctx_ceiling_hard}, 350_000, 'hard untouched by the soft override');
        }
    }
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_HARD_TOKENS} = '2000';
        my $t = sc(sub { BpOrch::_tunables_base() });
        SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
            is($t->{ctx_ceiling_hard}, 2000, 'hard moved to 2000');
            is($t->{ctx_ceiling_soft}, 250_000, 'soft untouched by the hard override');
        }
    }
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS} = '1000';
        local $ENV{BP_CONTEXT_CEILING_HARD_TOKENS} = '2000';
        my $t = sc(sub { BpOrch::_tunables_base() });
        SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
            is($t->{ctx_ceiling_soft}, 1000, 'both set: soft honored');
            is($t->{ctx_ceiling_hard}, 2000, 'both set: hard honored');
        }
    }
};

# =====================================================================================
# AC3 (B3) -- malformed env falls back per tier, never to 0, and warns naming the value;
# the other tier is unaffected.
# =====================================================================================
subtest 'AC3: malformed env falls back per tier, never to 0, warns; other tier unaffected (B3)' => sub {
    for my $bad (qw(abc 0 -5 1.5), '') {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS} = $bad;
        my @warnings;
        my $t;
        { local $SIG{__WARN__} = sub { push @warnings, $_[0] };
          $t = sc(sub { BpOrch::_tunables_base() }); }
        SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
            is($t->{ctx_ceiling_soft}, 250_000, "soft='$bad' falls back to 250_000, not 0");
            is($t->{ctx_ceiling_hard}, 350_000, "soft='$bad' does not disturb hard's default");
        }
        ok((grep { /\Q$bad\E/ } @warnings) || !length($bad),
           "soft='$bad' produced a warning naming the rejected value") unless $bad eq '';
    }
    for my $bad (qw(abc 0 -5 1.5), '') {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_HARD_TOKENS} = $bad;
        my @warnings;
        my $t;
        { local $SIG{__WARN__} = sub { push @warnings, $_[0] };
          $t = sc(sub { BpOrch::_tunables_base() }); }
        SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
            is($t->{ctx_ceiling_hard}, 350_000, "hard='$bad' falls back to 350_000, not 0");
            is($t->{ctx_ceiling_soft}, 250_000, "hard='$bad' does not disturb soft's default");
        }
        ok((grep { /\Q$bad\E/ } @warnings) || !length($bad),
           "hard='$bad' produced a warning naming the rejected value") unless $bad eq '';
    }
};

# =====================================================================================
# AC4 (B4) -- resolution order per tier: tunables key > env > default; empty hashref
# falls through to env, not straight to default; a caller-supplied 0 is honoured.
# =====================================================================================
subtest 'AC4: resolution order per tier -- tunables > env > default (B4)' => sub {
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        my $usage = usage_of(500);
        is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling_soft => 500 }, 'soft') }), 1,
           'tunables ctx_ceiling_soft resolves and breaches at that custom ceiling');
        is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling_soft => 501 }, 'soft') }), 0,
           'and does not breach one below that custom ceiling');
    }
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS} = '1000';
        my $at    = usage_of(1000);
        my $under = usage_of(999);
        is(sc(sub { BpOrch::context_growth_ceiling_breached($at, undef, 'soft') }), 1,
           'env override honored when no tunables hashref is passed');
        is(sc(sub { BpOrch::context_growth_ceiling_breached($under, {}, 'soft') }), 0,
           'an EMPTY tunables hashref (no key) still falls through to the env override, not straight to the default');
    }
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        local $ENV{BP_CONTEXT_CEILING_SOFT_TOKENS} = '9999999';
        my $usage = usage_of(42);
        is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling_soft => 42 }, 'soft') }), 1,
           'tunables key beats a simultaneously-set env override');
    }
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        my $tiny = usage_of(1);
        my $zero = usage_of(0);
        is(sc(sub { BpOrch::context_growth_ceiling_breached($tiny, { ctx_ceiling_soft => 0 }, 'soft') }), 1,
           'a caller-supplied 0 is honoured as-is: breaches on the first nonzero turn');
        is(sc(sub { BpOrch::context_growth_ceiling_breached($zero, { ctx_ceiling_soft => 0 }, 'soft') }), 1,
           'and breaches at exactly zero usage too, since 0 >= 0');
    }
    # Same resolution order for hard.
    {
        local %ENV = %ENV;
        clear_ceiling_env();
        my $usage = usage_of(3000);
        is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling_hard => 3000 }, 'hard') }), 1,
           'tunables ctx_ceiling_hard resolves and breaches at that custom ceiling');
        local $ENV{BP_CONTEXT_CEILING_HARD_TOKENS} = '5000';
        is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(4999), {}, 'hard') }), 0,
           'empty tunables hashref falls through to the hard env override too');
    }
};

# =====================================================================================
# AC5 (B5) -- context_growth_ceiling_breached is >=, tolerant, tier-defaulted.
# =====================================================================================
subtest 'AC5: context_growth_ceiling_breached is >=, tolerant of bad usage, tier-defaulted (B5)' => sub {
    local %ENV = %ENV;
    clear_ceiling_env();
    my $t = { ctx_ceiling_soft => 1000, ctx_ceiling_hard => 3000 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(1000), $t, 'soft') }), 1, 'sum exactly at soft breaches');
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(999),  $t, 'soft') }), 0, 'one below soft does not breach');
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(3000), $t, 'hard') }), 1, 'sum exactly at hard breaches');
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(2999), $t, 'hard') }), 0, 'one below hard does not breach');
    is(sc(sub { BpOrch::context_growth_ceiling_breached(undef, $t, 'soft') }), 0, 'undef usage -> 0, never a die');
    is(sc(sub { BpOrch::context_growth_ceiling_breached('not-a-hashref-usage', $t, 'soft') }), 0, 'non-hashref usage -> 0, never a die');
    # Omitted / unrecognized tier defaults to soft.
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(1000), $t) }), 1, 'omitted tier defaults to soft, breaches at 1000');
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(1000), $t, 'HARD') }), 1, "tier 'HARD' (wrong case) treated as soft, breaches at 1000");
    is(sc(sub { BpOrch::context_growth_ceiling_breached(usage_of(1000), $t, 'x') }), 1, "tier 'x' (unrecognized) treated as soft, breaches at 1000");
};

# =====================================================================================
# AC6 (B6) -- context_ceiling_tier: hard/soft/none, hard checked first (monotone even
# when misconfigured).
# =====================================================================================
subtest 'AC6: context_ceiling_tier returns hard/soft/none, hard-first, monotone under inversion (B6)' => sub {
    local %ENV = %ENV;
    clear_ceiling_env();
    my $t = { ctx_ceiling_soft => 250_000, ctx_ceiling_hard => 350_000 };
    is(sc(sub { BpOrch::context_ceiling_tier(usage_of(400_000), $t) }), 'hard', '400,000 -> hard');
    is(sc(sub { BpOrch::context_ceiling_tier(usage_of(300_000), $t) }), 'soft', '300,000 -> soft');
    is(sc(sub { BpOrch::context_ceiling_tier(usage_of(10), $t) }), 'none', '10 -> none');
    is(sc(sub { BpOrch::context_ceiling_tier(undef, $t) }), 'none', 'undef usage -> none');

    my $inverted = { ctx_ceiling_soft => 500, ctx_ceiling_hard => 100 };
    is(sc(sub { BpOrch::context_ceiling_tier(usage_of(300), $inverted) }), 'soft',
       'inverted ceilings (hard < soft): 300 -> soft (hard checked first, but 300 < 100 fails hard)');
    is(sc(sub { BpOrch::context_ceiling_tier(usage_of(600), $inverted) }), 'hard',
       'inverted ceilings: 600 -> hard (>= both, hard wins as checked first) -- monotone, no crash, no clamp');
};

# =====================================================================================
# AC7 (B7) -- neither new key is honoured from a runs/.tunables live overlay.
# =====================================================================================
subtest 'AC7: ctx_ceiling_soft/ctx_ceiling_hard are NOT live-overlayable (B7)' => sub {
    local %ENV = %ENV;
    clear_ceiling_env();
    my $dir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$dir/.tunables") or die "tunables fixture: $!";
    print {$fh} '{"ctx_ceiling_soft":1,"ctx_ceiling_hard":2}';
    close $fh;
    my $t = sc(sub { BpOrch::_tunables($dir, "$dir/.tunables") });
    is(ref $t, 'HASH', '_tunables() with an overlay file still returns a hashref');
    SKIP: { skip 'not a hashref', 2 unless ref $t eq 'HASH';
        is($t->{ctx_ceiling_soft}, 250_000, 'ctx_ceiling_soft ignored from the overlay -- base default stands');
        is($t->{ctx_ceiling_hard}, 350_000, 'ctx_ceiling_hard ignored from the overlay -- base default stands');
    }
};

# =====================================================================================
# --ctx-usage CLI seam scaffolding (AC8-AC10).
# =====================================================================================
my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
my $J = JSON::PP->new->canonical;

my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
    grep { !/^BP_/ && $_ ne 'CLAUDE_PROJECT_DIR' && $_ ne 'CCPRAXIS_DISPATCH_LOG_TEST_NOW' }
    keys %ENV;

sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub jline { return $J->encode($_[0]) . "\n" }
sub assistant_rec {
    my (%o) = @_;
    return { type => 'assistant', parent_tool_use_id => $o{sub} ? 'toolu_01x' : undef,
             message => { usage => usage_of($o{tokens}) } };
}

# run_ctx_usage(BPDIR_OR_UNDEF, PKG_OR_UNDEF) -> ($rc, $stdout, $stderr)
sub run_ctx_usage {
    my ($bpdir, $pkg) = @_;
    my @args = ('--ctx-usage', (defined $bpdir ? $bpdir : ()), (defined $pkg ? $pkg : ()));
    my $tmp = tempdir(CLEANUP => 1);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($ORCH), map { $q->($_) } @args);
    local %ENV = %CLEAN_ENV;
    system(qq{$cmd > "$out_f" 2> "$err_f"});
    my $rc = ($? == -1) ? undef : ($? >> 8);
    my $read = sub { my ($p) = @_; open my $r, '<', $p or return ''; local $/; my $c = <$r>; close $r; return $c // '' };
    return ($rc, $read->($out_f), $read->($err_f));
}

# =====================================================================================
# AC8 (B8) -- --ctx-usage prints the four lines in order, correct values; exit 0.
# =====================================================================================
subtest 'AC8: --ctx-usage prints context_tokens/ceiling_soft/ceiling_hard/tier in order (B8)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs");
    write_bytes("$dir/runs/p.jsonl",
        jline(assistant_rec(tokens => 100, sub => 1))
      . jline(assistant_rec(tokens => 260_000)));
    my ($rc, $out, $err) = run_ctx_usage($dir, 'p');
    is($rc, 0, 'exit 0') or diag("stderr: $err");
    is($out, "context_tokens: 260000\nceiling_soft: 250000\nceiling_hard: 350000\ntier: soft\n",
        'stdout is exactly the four lines, in order, byte for byte') or diag("stdout was: [$out]");
};

# =====================================================================================
# AC9 (B9) -- --ctx-usage degrades to unknown, never to zero.
# =====================================================================================
subtest 'AC9: --ctx-usage degrades to unknown, never 0; missing args -> exit 2 (B9)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs");
    {
        my ($rc, $out) = run_ctx_usage($dir, 'missing-pkg');
        is($rc, 0, 'missing transcript file -> exit 0');
        like($out, qr/^context_tokens: unknown$/m, 'context_tokens: unknown, never 0');
        like($out, qr/^tier: unknown$/m, 'tier: unknown');
        like($out, qr/^ceiling_soft: 250000$/m, 'ceiling_soft still printed');
        like($out, qr/^ceiling_hard: 350000$/m, 'ceiling_hard still printed');
    }
    {
        write_bytes("$dir/runs/empty.jsonl", '');
        my ($rc, $out) = run_ctx_usage($dir, 'empty');
        is($rc, 0, 'empty transcript -> exit 0');
        like($out, qr/^context_tokens: unknown$/m, 'empty file -> unknown');
    }
    {
        write_bytes("$dir/runs/subonly.jsonl", jline(assistant_rec(tokens => 99, sub => 1)));
        my ($rc, $out) = run_ctx_usage($dir, 'subonly');
        is($rc, 0, 'subagent-only transcript -> exit 0');
        like($out, qr/^context_tokens: unknown$/m, 'only-subagent-owned records -> unknown, not a false coordinator reading');
    }
    {
        write_bytes("$dir/runs/garbage.jsonl", "not json at all\n{{{\n");
        my ($rc, $out) = run_ctx_usage($dir, 'garbage');
        is($rc, 0, 'unparseable garbage -> exit 0');
        like($out, qr/^context_tokens: unknown$/m, 'garbage -> unknown');
    }
    {
        my ($rc, $out, $err) = run_ctx_usage(undef, 'p');
        is($rc, 2, 'missing <bp-dir> -> exit 2');
        is($out, '', 'nothing on stdout');
        like($err, qr/^usage:/m, 'usage: line on stderr');
    }
    {
        my ($rc, $out, $err) = run_ctx_usage($dir, undef);
        is($rc, 2, 'missing <pkg> -> exit 2');
        is($out, '', 'nothing on stdout');
        like($err, qr/^usage:/m, 'usage: line on stderr');
    }
    {
        my ($rc, $out, $err) = run_ctx_usage($dir, '');
        is($rc, 2, 'empty <pkg> -> exit 2');
        is($out, '', 'nothing on stdout');
    }
};

# =====================================================================================
# AC10 (B10) -- tail-reads a large (>=2MB) transcript, promptly.
# =====================================================================================
subtest 'AC10: --ctx-usage tail-reads a >=2MB transcript, only the last usable line counts (B10)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs");
    my $path = "$dir/runs/big.jsonl";
    open my $fh, '>', $path or die "write $path: $!";
    binmode $fh;
    # ~2.2MB of non-JSON padding lines (never usable records).
    my $pad = ('# padding filler ' x 12) . "\n"; # ~216 bytes/line
    my $target = 2 * 1024 * 1024 + 200_000;
    my $written = 0;
    while ($written < $target) { print {$fh} $pad; $written += length($pad); }
    print {$fh} jline(assistant_rec(tokens => 12_345));
    close $fh;
    ok(-s $path >= 2 * 1024 * 1024, 'fixture sanity: file really is >=2MB') or diag(-s $path);

    my $t0 = time;
    my ($rc, $out, $err) = run_ctx_usage($dir, 'big');
    my $elapsed = time - $t0;
    is($rc, 0, 'exit 0') or diag("stderr: $err");
    like($out, qr/^context_tokens: 12345$/m, 'only the LAST usable record\'s sum is returned');
    cmp_ok($elapsed, '<', 25, "returns promptly on a >=2MB file ($elapsed s elapsed)");
};

# =====================================================================================
# AC31 (B30) -- ctx_ceiling and BP_CONTEXT_CEILING_TOKENS (whole word) appear nowhere
# in bp-orchestrator.pl, SKILL.md, or either new hook.
# =====================================================================================
subtest 'AC31: ctx_ceiling / BP_CONTEXT_CEILING_TOKENS (whole word) appear nowhere in the migrated files (B30)' => sub {
    my $SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md";
    my $GUIDANCE_HOOK = "$Bin/../../hooks/context-ceiling-guidance.sh";
    my $FLUSH_HOOK    = "$Bin/../../hooks/context-ceiling-flush.sh";
    my $sub_re = sub {
        my ($path) = @_;
        return unless -f $path;
        open my $r, '<', $path or return;
        local $/; my $c = <$r>; close $r;
        return $c;
    };
    for my $f ($ORCH, $SKILL, $GUIDANCE_HOOK, $FLUSH_HOOK) {
        my $src = $sub_re->($f);
        ok(defined $src, "$f exists and is readable") or next;
        unlike($src, qr/\bctx_ceiling\b/, "$f: no whole-word 'ctx_ceiling' (ctx_ceiling_soft/hard are fine, this is not a substring check)");
        unlike($src, qr/\bBP_CONTEXT_CEILING_TOKENS\b/, "$f: no whole-word 'BP_CONTEXT_CEILING_TOKENS'");
    }
};

# =====================================================================================
# AC32 -- SKILL.md's "## Context-growth checkpoint" section contains every literal
# from spec SS2.11, neither 'carry over' nor any of AC17's banned strings, and no
# longer contains the old hand-rolled tail -c 200000 recipe.
# =====================================================================================
subtest 'AC32: SKILL.md documents the two-tier model per SS2.11' => sub {
    my $SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md";
    ok(-f $SKILL, "$SKILL exists") or return;
    open my $r, '<', $SKILL or die "read $SKILL: $!";
    local $/; my $doc = <$r>; close $r;

    my $idx = index($doc, '## Context-growth checkpoint');
    ok($idx >= 0, 'SKILL.md still has the "## Context-growth checkpoint" heading (Decision 1: the ritual keeps its name)');
    my $start = $idx >= 0 ? $idx : 0;
    my $next  = index($doc, "\n## ", $start + 10);
    my $section = $next >= 0 ? substr($doc, $start, $next - $start) : substr($doc, $start);

    like($section, qr/250,000/, 'contains 250,000');
    like($section, qr/350,000/, 'contains 350,000');
    like($section, qr/CTX_CEILING_DEFAULT/, 'names %CTX_CEILING_DEFAULT as the canonical source');
    like($section, qr/BP_CONTEXT_CEILING_SOFT_TOKENS/, 'contains BP_CONTEXT_CEILING_SOFT_TOKENS');
    like($section, qr/BP_CONTEXT_CEILING_HARD_TOKENS/, 'contains BP_CONTEXT_CEILING_HARD_TOKENS');
    like($section, qr/context-ceiling-guidance\.sh/, 'names context-ceiling-guidance.sh');
    like($section, qr/context-ceiling-flush\.sh/, 'names context-ceiling-flush.sh');
    like($section, qr/bp-dispatch-log\.pl outstanding/, 'names bp-dispatch-log.pl outstanding');
    like($section, qr/\bguidance\b/, 'uses the word "guidance" for the soft tier');
    like($section, qr/\bflush\b/, 'uses the word "flush" for the hard tier');
    like($section, qr/already going to receive|already going to get|tool result you were already/,
        'states the soft tier arrives attached to a tool result already coming');
    like($section, qr/status:\s*blocked/, 'documents the status: blocked escalation path');
    like($section, qr/##\s*Escalation/, 'documents the ## Escalation section');
    like($section, qr/5[\s-]*turn/i, 'documents the 5-turn cap');
    like($section, qr/\bcold\b/i, 'documents that relaunch forces cold');
    unlike($section, qr/carry over/i, 'the phrase "carry over" does not appear (Decision 1 reserves it)');
    for my $bad ('nothing is outstanding', 'all clear', 'is done', 'has finished', 'checkpoint now') {
        unlike($section, qr/\Q$bad\E/i, "banned phrase '$bad' does not appear");
    }
    unlike($section, qr/tail -c 200000/, 'the old hand-rolled tail -c 200000 recipe is removed');
    unlike($section, qr/wc -l/, 'the old hand-rolled wc -l recipe is removed');
};

done_testing();
