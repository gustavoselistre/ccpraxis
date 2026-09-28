#!/usr/bin/env perl
# platform: any
# Report 20260917-155539-b6bf, item 2.
#
# 436 watchdog relaunches across two days recorded exit_reason "unknown", which
# is what terminal_verdict returns whenever the last jsonl line is not a `result`
# object -- i.e. whenever the process was killed mid-stream. The report: "436
# deaths produce 436 identical log lines with no distinguishing information, and
# a reader has no way to tell one cause from another. A defect that recurs 436
# times and leaves no evidence is one that cannot be fixed, only absorbed."
#
# The transcripts existed the whole time. Nothing read them when a session died.
#
# SHAPE, NOT CONTENT is the constraint that makes this safe to log: coordinator
# transcripts contain prompts, so the evidence records event types, tool NAMES,
# and CLI-emitted error strings -- never message bodies.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-orchestrator.pl";

my $ROOT = tempdir(CLEANUP => 1);
my $J    = JSON::PP->new->canonical;

my $n = 0;
sub runs_with {
    my (@lines) = @_;
    my $runs = "$ROOT/runs" . (++$n);
    mkdir $runs or die "mkdir $runs: $!";
    open my $f, '>', "$runs/pkg.jsonl" or die "open: $!";
    print {$f} map { (ref $_ ? $J->encode($_) : $_) . "\n" } @lines;
    close $f;
    return $runs;
}

sub assistant_tool {
    my ($name) = @_;
    return { type => 'assistant',
             message => { content => [ { type => 'tool_use', name => $name,
                                         input => { command => 'SECRET-PROMPT-TEXT' } } ] } };
}

# ---- a missing transcript is not an error -----------------------------------
{
    my $runs = "$ROOT/empty"; mkdir $runs or die;
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg');
    is(ref $ev, 'HASH', 'a missing transcript still returns a record');
    is($ev->{tail_lines}, 0, 'with no lines');
    is_deeply($ev->{tail_types}, [], 'and no types');
}

# ---- an empty transcript is not an error ------------------------------------
{
    my $runs = runs_with();
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg');
    is($ev->{tail_lines}, 0, 'an empty transcript yields no lines');
}

# ---- the shape of the death is recorded -------------------------------------
{
    my $runs = runs_with(
        { type => 'system', subtype => 'init' },
        assistant_tool('Read'),
        { type => 'user' },
        assistant_tool('Bash'),
        { type => 'user' },
        assistant_tool('Bash'),
        { type => 'user' },
    );
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg');
    is($ev->{tail_lines}, 7, 'every tail line is counted');
    like(join(',', @{ $ev->{tail_types} }), qr/system/, 'the event-type sequence is recorded');
    is_deeply($ev->{tail_tools}, ['Read', 'Bash'],
              'the tools it was using are named, deduped, in first-seen order');
    ok(defined $ev->{jsonl_bytes} && $ev->{jsonl_bytes} > 0, 'the transcript size is recorded');
}

# ---- SHAPE, NOT CONTENT -----------------------------------------------------
# The single most important assertion in this file. A forensic record that copies
# prompts into the orchestrator log trades one defect for a worse one.
{
    my $runs = runs_with(assistant_tool('Bash'), { type => 'user' });
    my $ev   = BpOrch::coordinator_death_evidence($runs, 'pkg');
    my $dump = $J->encode($ev);
    unlike($dump, qr/SECRET-PROMPT-TEXT/,
           'tool INPUTS never reach the evidence record -- names only');
    like($dump, qr/Bash/, 'while the tool name does');
}

# ---- consecutive repeats collapse -------------------------------------------
# Forty lines of "assistant,user" tells a reader nothing that "assistant x20"
# does not, and an unbounded list would make the log line itself the problem.
{
    my $runs = runs_with(map { { type => 'assistant' } } 1 .. 25);
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg');
    is(scalar @{ $ev->{tail_types} }, 1, 'a run of identical types collapses to one entry');
    like($ev->{tail_types}[0], qr/^assistant x\d+$/, 'carrying its count');
}

# ---- a CLI error string is surfaced -----------------------------------------
{
    my $runs = runs_with(
        { type => 'assistant' },
        { type => 'result', subtype => 'error_during_execution' },
    );
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg');
    like($ev->{last_error}, qr/error_during_execution/,
         'an error the CLI reported about itself is surfaced');
}

# ---- a tail is BOUNDED ------------------------------------------------------
# The reader must never slurp a multi-GB coordinator stream inside the hot loop.
{
    my $runs = runs_with(map { { type => "t$_" } } 1 .. 500);
    my $ev = BpOrch::coordinator_death_evidence($runs, 'pkg', 10);
    cmp_ok($ev->{tail_lines}, '<=', 10, 'the tail honours its line bound');
}

# ---- garbage lines do not kill it -------------------------------------------
{
    my $runs = runs_with('not json at all', '{"broken":', { type => 'assistant' });
    my $ev = eval { BpOrch::coordinator_death_evidence($runs, 'pkg') };
    is(ref $ev, 'HASH', 'undecodable lines do not throw')
        or diag("died: $@");
}

# ---- evidence is attached to UNKNOWN deaths only ----------------------------
# terminal_verdict is the discriminator the log already uses. A clean success or
# a max_turns exhaustion already explains itself; attaching a tail to those puts
# noise on every ordinary relaunch and buries the ones carrying no information.
{
    is(BpOrch::terminal_verdict({ type => 'result', subtype => 'success' })->{verdict},
       'success', 'a terminal result object classifies as success');
    is(BpOrch::terminal_verdict({ type => 'assistant' })->{verdict},
       'unknown', 'a non-result last line is the "unknown" case -- the 436');
    is(BpOrch::terminal_verdict(undef)->{verdict},
       'unknown', 'and so is no last line at all');
}

done_testing();
