#!/usr/bin/env perl
# platform: any
# Package 02-context-growth-checkpoint (blueprint fleet-cost-accounting).
#
# Derived ONLY from specs/02-context-growth-checkpoint-spec.md (AC3, AC4, AC6;
# Observable behaviors 5, 6, 7, 8, 9). AC1/AC2/AC5 are explicitly marked
# review-verified prose in the spec -- not exercised here; SKILL.md's own
# prose content is never asserted against by this file.
#
# Covers the three pure helpers the spec adds to bp-orchestrator.pl
# (BpOrch::context_tokens_from_usage, BpOrch::last_coordinator_usage,
# BpOrch::context_growth_ceiling_breached) plus the new `ctx_ceiling` key in
# BpOrch::_tunables_base(), exactly the require-and-call idiom
# t/orchestrator-suspend-gap.t and t/keeper-resilience-antispam.t already use
# against this same file. A call-guard (`sc`, keeper-resilience-antispam.t
# style) turns "subroutine does not exist yet" into ONE readable failing
# assertion per call site instead of an aborted test file, so today's RED is
# legible as "missing behavior," not a parse/compile error.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

require "$Bin/../../scripts/bp-orchestrator.pl";

# Call guard for subs that may not exist yet -- a missing subroutine becomes a
# string result, never a script-aborting die.
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }

# =====================================================================================
# context_tokens_from_usage -- Observable behavior 5, spec section 2.3
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
# last_coordinator_usage -- Observable behaviors 8, 9, spec section 2.3
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
# context_growth_ceiling_breached -- Observable behaviors 6, 7; AC3, AC4
# =====================================================================================

{
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};

    my $at_ceiling   = { input_tokens => 200_000, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $below        = { input_tokens => 199_999, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $above        = { input_tokens => 200_001, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };

    is(sc(sub { BpOrch::context_growth_ceiling_breached($at_ceiling, undef) }), 1,
       'sum exactly AT the default 200_000 ceiling breaches (>=, not >) -- Observable behavior 6');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($below, undef) }), 0,
       'ceiling - 1 does not breach -- Observable behavior 6, and the literal AC4 "unaffected below ceiling" assertion');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($above, undef) }), 1,
       'one token over the default ceiling breaches');
}

{
    # Resolution order point 1: $t->{ctx_ceiling} wins, even with no env set.
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};
    my $usage = { input_tokens => 500, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling => 500 }) }), 1,
       'a tunables hashref with ctx_ceiling resolves and breaches at that custom ceiling');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling => 501 }) }), 0,
       'and does not breach one below that custom ceiling');
}

{
    # Resolution order point 2: env override used when no tunables key present.
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = '1000';
    my $at  = { input_tokens => 1000, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $under = { input_tokens => 999, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($at, undef) }), 1,
       'BP_CONTEXT_CEILING_TOKENS env override is honored when no tunables hashref is passed');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($under, {}) }), 0,
       'and an empty tunables hashref (no ctx_ceiling key) still falls through to the env override, not straight to 200_000');
}

{
    # Resolution order point 3: $t->{ctx_ceiling} beats the env override when both are set.
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = '9999999';
    my $usage = { input_tokens => 42, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, { ctx_ceiling => 42 }) }), 1,
       'tunables ctx_ceiling takes priority over a simultaneously-set env override -- Observable behavior 7\'s stated order');
}

{
    # Degenerate ceiling: 0 breaches on the very first (nonzero-or-zero) turn.
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};
    my $tiny = { input_tokens => 1, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $zero = { input_tokens => 0, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($tiny, { ctx_ceiling => 0 }) }), 1,
       'a misconfigured 0 ceiling breaches on the very first nonzero turn -- degenerate but documented, not a crash (spec section 5)');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($zero, { ctx_ceiling => 0 }) }), 1,
       'and breaches even at exactly zero usage, since 0 >= 0 -- the >= rule has no special case for a zero ceiling');
}

{
    # fix-batch step7 MEDIUM #2: a malformed BP_CONTEXT_CEILING_TOKENS override
    # must NOT silently degrade to an effective ceiling of 0 (which would
    # breach on every check, causing constant checkpoint thrashing). It must
    # fall back to the documented 200_000 default instead, mirroring
    # _min_relaunch_secs()'s own validation convention for exactly this risk
    # class.
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = 'abc';
    my $below_default = { input_tokens => 199_999, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    my $above_default = { input_tokens => 200_001, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($below_default, undef) }), 0,
       'a non-numeric BP_CONTEXT_CEILING_TOKENS falls back to the 200_000 default, not to 0 -- below-default usage does not breach');
    is(sc(sub { BpOrch::context_growth_ceiling_breached($above_default, undef) }), 1,
       'and above-default usage still breaches normally once fallen back to 200_000, confirming it is not stuck open either');
}

{
    # Same malformed-override guarantee for the non-positive case (0 and negative).
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = '0';
    my $tiny = { input_tokens => 1, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 };
    is(sc(sub { BpOrch::context_growth_ceiling_breached($tiny, undef) }), 0,
       'BP_CONTEXT_CEILING_TOKENS="0" is rejected as non-positive and falls back to 200_000, not an effective ceiling of 0');
}

{
    # The same fallback must apply where _tunables_base() resolves ctx_ceiling.
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = 'not-a-number';
    my $t = sc(sub { BpOrch::_tunables_base() });
    is(ref $t, 'HASH', '_tunables_base() still returns a hashref under a malformed env override');
    is($t->{ctx_ceiling}, 200_000,
       'a malformed BP_CONTEXT_CEILING_TOKENS falls back to the 200_000 default in _tunables_base() too, not 0')
        if ref $t eq 'HASH';
}

{
    # Combining the two "no data" helpers must never manufacture a false breach.
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};
    my $usage = sc(sub { BpOrch::last_coordinator_usage([]) });
    is(sc(sub { BpOrch::context_growth_ceiling_breached($usage, undef) }), 0,
       'no coordinator turn found (undef usage) combined into the breach check never reads as a breach');
}

# =====================================================================================
# ctx_ceiling tunable -- AC3, spec section 2.2, mirrors ceil5/ceil7's own coverage
# =====================================================================================

{
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};
    my $t = sc(sub { BpOrch::_tunables_base() });
    is(ref $t, 'HASH', '_tunables_base() still returns a hashref with the new key present') or diag(explain($t));
    is($t->{ctx_ceiling}, 200_000, 'ctx_ceiling defaults to 200_000 when BP_CONTEXT_CEILING_TOKENS is unset')
        if ref $t eq 'HASH';
}

{
    local $ENV{BP_CONTEXT_CEILING_TOKENS} = '55000';
    my $t = sc(sub { BpOrch::_tunables_base() });
    is(ref $t, 'HASH', '_tunables_base() returns a hashref under the env override too');
    is($t->{ctx_ceiling}, 55000, 'BP_CONTEXT_CEILING_TOKENS env override is honored by _tunables_base(), mirroring ceil5/ceil7')
        if ref $t eq 'HASH';
}

{
    # ctx_ceiling must NOT be in the runs/.tunables live-overlay whitelist
    # (spec section 2.2: "Do NOT add ctx_ceiling to the _tunables() overlay
    # whitelist" -- nothing in bp-orchestrator.pl reads it at runtime, so
    # overlaying it would silently do nothing and misrepresent live-retunability).
    use File::Temp qw(tempdir);
    local $ENV{BP_CONTEXT_CEILING_TOKENS};
    delete $ENV{BP_CONTEXT_CEILING_TOKENS};
    my $dir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$dir/.tunables") or die "tunables fixture: $!";
    print {$fh} '{"ctx_ceiling":1}';
    close $fh;
    my $t = sc(sub { BpOrch::_tunables($dir, "$dir/.tunables") });
    is(ref $t, 'HASH', '_tunables() with an overlay file still returns a hashref');
    is($t->{ctx_ceiling}, 200_000,
       'ctx_ceiling is NOT in the live-overlay whitelist -- a runs/.tunables value for it is silently ignored, base default stands')
        if ref $t eq 'HASH';
}

done_testing();
