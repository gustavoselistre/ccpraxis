#!/usr/bin/env perl
# platform: any
# Oracle for blueprint sandbox-session-ux, package 02-session-index
# (SessionIndex.pm). Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/02-session-index-spec.md
# and blueprint.md Decisions 2-5, 15, 18, 20. The module's eventual
# implementation was never read (beyond confirming the $HEAD_MAX_BYTES /
# $TAIL_MAX_BYTES / $MAX_TEXT_CHARS tunable names the spec itself documents).
#
# Decision 20 fix-round additions (reports/02-session-index-review.md M1-M3,
# and the review's "beyond any fixed window" finding): the forward/backward
# scans are no longer capped at a fixed byte window when a typed message or a
# timestamp has not yet been found -- they widen until found or the file is
# exhausted. AC-22..AC-25 below exercise that and the three MAJOR defects the
# review found in the pre-fix implementation. These are EXPECTED TO FAIL
# against the pre-fix module: a middle-only typed message is missed entirely
# (empty/not listable), a huge final line makes last_active_at collapse to
# started_at (M1), a nested "timestamp" key inside toolUseResult overrides the
# real one (M2), and a nested "type":"user"/"message" pair inside a tool_use
# input is mistaken for a real typed message (M3).
#
# AC-1..AC-21 were written before SessionIndex.pm existed (missing-module/
# missing-sub failures turned into one explicit failing assertion each by
# criterion() below, so every criterion still got to run independently) and
# now pass against the shipped module (124/124). AC-22..AC-25 are the fix-
# round additions and are EXPECTED TO FAIL against today's pre-Decision-20
# module for the reasons in the block comment above -- not for a scaffolding
# reason of this file's own making.
#
# Decision 15 (open-source hygiene): every fixture here is synthetic, built
# fresh in a File::Temp dir by this file -- invented UUIDs, an invented
# /work/demo cwd, invented message text. Nothing is copied or read from the
# operator's real transcripts.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Time::HiRes ();
use Time::Local qw(timegm);
use POSIX qw(strftime);

# ---------------------------------------------------------------------------
# Load the module under test.
# ---------------------------------------------------------------------------
my $mod_path = "$Bin/../../scripts/SessionIndex.pm";
my $HAVE_MOD = eval { require $mod_path; 1 };
my $LOAD_ERR = $@;
ok($HAVE_MOD, "SessionIndex.pm loads via require '$mod_path'")
    or diag("load error was: $LOAD_ERR");

# ---------------------------------------------------------------------------
# criterion($name, $code) -- turns a die (missing sub/module) into one
# explicit failing assertion instead of aborting the whole file, so every
# criterion still gets a chance to run and report independently.
# ---------------------------------------------------------------------------
sub criterion {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    if (!$ok) {
        my $err = $@;
        $err = 'unknown error' unless length $err;
        $err =~ s/\s+\z//;
        fail("$name -- DIED (missing behavior): $err");
    }
    return;
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
my $JSON = JSON::PP->new->utf8->canonical;

my $T0 = 1_734_000_000;   # arbitrary fixed anchor epoch, for deterministic fixtures

sub ts { my ($offset) = @_; return iso_ts($T0 + $offset); }

sub iso_ts {
    my ($epoch) = @_;
    return strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch)) . '.000Z';
}

# write_jsonl($path, @records) -- each record a hashref, encoded to a UTF-8
# BYTE json line via JSON::PP->utf8 (produces already-encoded bytes), written
# through a ':raw' handle so nothing is re-decoded/re-encoded on the way to
# disk (double-UTF-8-decoding trap).
sub write_jsonl {
    my ($path, @records) = @_;
    open my $fh, '>:raw', $path or die "write_jsonl($path): $!";
    for my $rec (@records) {
        print {$fh} $JSON->encode($rec), "\n";
    }
    close $fh;
    return $path;
}

sub write_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "write_raw($path): $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub user_rec {
    my (%opts) = @_;
    my $content = delete $opts{content};
    my $rec = {
        type      => 'user',
        sessionId => delete($opts{sessionId}) // $opts{_default_sid} // 'aaaaaaaa-0000-0000-0000-000000000000',
        cwd       => '/work/demo',
        message   => { role => 'user', content => $content },
    };
    delete $rec->{sessionId} if !defined $rec->{sessionId};
    for my $k (qw(timestamp entrypoint promptSource origin isSidechain isMeta
                  isCompactSummary isVisibleInTranscriptOnly agentId toolUseResult)) {
        $rec->{$k} = $opts{$k} if exists $opts{$k};
    }
    return $rec;
}

sub assistant_rec {
    my (%opts) = @_;
    my $content = delete $opts{content} // 'ok, understood.';
    my $rec = {
        type      => 'assistant',
        sessionId => $opts{sessionId} // 'aaaaaaaa-0000-0000-0000-000000000000',
        message   => { role => 'assistant', content => $content },
    };
    $rec->{timestamp} = $opts{timestamp} if exists $opts{timestamp};
    return $rec;
}

my $UUID_A = 'aaaaaaaa-1111-2222-3333-444444444444';
my $UUID_B = 'bbbbbbbb-1111-2222-3333-444444444444';
my $UUID_C = 'cccccccc-1111-2222-3333-444444444444';

# =============================================================================
# AC-1 -> DC 1: human fixture (entrypoint "cli", no promptSource) -> human
# =============================================================================
criterion('AC-1: human fixture (entrypoint cli, no promptSource) -> kind human, classified_by metadata, listable 1', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => 'Please help me fix the demo widget.'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(5), content => 'Sure, on it.'),
    );
    my $entry = SessionIndex::index_file($path);
    ok(defined $entry, 'AC-1: index_file returns a defined entry');
    is($entry->{kind}, 'human', 'AC-1: kind is human');
    is($entry->{classified_by}, 'metadata', 'AC-1: classified_by is metadata');
    is($entry->{human}, 1, 'AC-1: human flag is 1');
    is($entry->{listable}, 1, 'AC-1: listable is 1');
});

# =============================================================================
# AC-2 -> DC 1: human fixture in the newer shape (promptSource typed, origin human)
# =============================================================================
criterion('AC-2: newer-shape human fixture (promptSource typed, origin.kind human) -> human, listable 1', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), promptSource => 'typed',
                 origin => { kind => 'human' }, content => 'What does this function do?'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'human', 'AC-2: kind is human');
    is($entry->{listable}, 1, 'AC-2: listable is 1');
});

# =============================================================================
# AC-3 -> DC 1: sidechain fixture (top-level file, isSidechain true) -> sidechain
# =============================================================================
criterion('AC-3: top-level sidechain fixture -> kind sidechain, listable 0', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/agent-deadbeef.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 isSidechain => 1, agentId => 'agent-deadbeef', content => 'side task prompt'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'sidechain', 'AC-3: kind is sidechain');
    is($entry->{listable}, 0, 'AC-3: listable is 0');
});

# =============================================================================
# AC-4: index_dir on a dir holding one human <uuid>.jsonl plus
# <uuid>/subagents/agent-x.jsonl -> exactly one entry (subdirs never read)
# =============================================================================
criterion('AC-4: index_dir never recurses into a session-named subdirectory (subagents)', sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => 'top-level human prompt'),
    );
    make_path("$dir/$UUID_A/subagents");
    write_jsonl("$dir/$UUID_A/subagents/agent-cafef00d.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 isSidechain => 1, agentId => 'agent-cafef00d', content => 'sidechain prompt'),
    );
    my $entries = SessionIndex::index_dir($dir);
    is(ref($entries), 'ARRAY', 'AC-4: index_dir returns an arrayref');
    is(scalar(@$entries), 1, 'AC-4: exactly one entry (the subagents dir was never read)');
    is($entries->[0]{id}, $UUID_A, 'AC-4: the one entry is the top-level session') if scalar(@$entries) == 1;
});

# =============================================================================
# AC-5 -> DC 1: headless fixture (queue-operation preamble, sdk-cli, sdk) -> headless
# =============================================================================
criterion('AC-5: headless fixture (queue-operation lead-in, entrypoint sdk-cli, promptSource sdk) -> headless', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        { type => 'queue-operation', operation => 'enqueue', sessionId => $UUID_A },
        { type => 'queue-operation', operation => 'dequeue', sessionId => $UUID_A },
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'sdk-cli',
                 promptSource => 'sdk', content => 'Summarize the open pull requests.'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'headless', 'AC-5: kind is headless');
    is($entry->{classified_by}, 'metadata', 'AC-5: classified_by is metadata');
    is($entry->{listable}, 0, 'AC-5: listable is 0');
    is($entry->{first_typed}, 'Summarize the open pull requests.', 'AC-5: first_typed is still populated');
});

# =============================================================================
# AC-6 -> DC 1: coordinator with metadata (sdk-cli + preamble prompt) -> coordinator
# =============================================================================
criterion('AC-6: sdk-cli + promptSource sdk + butler-coordinator preamble -> coordinator, classified_by metadata', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'sdk-cli',
                 promptSource => 'sdk',
                 content => "You are a ccpraxis **butler coordinator**, driving a run for package 02."),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'coordinator', 'AC-6: kind is coordinator');
    is($entry->{classified_by}, 'metadata', 'AC-6: classified_by is metadata');
});

# =============================================================================
# AC-7 -> DC 1: old coordinator (no entrypoint, no promptSource, preamble text)
# =============================================================================
criterion('AC-7: old-transcript coordinator (no entrypoint/promptSource, preamble text) -> coordinator, classified_by preamble', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0),
                 content => "You are a ccpraxis butler coordinator for this run."),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'coordinator', 'AC-7a: kind is coordinator');
    is($entry->{classified_by}, 'preamble', 'AC-7a: classified_by is preamble');
    is($entry->{listable}, 0, 'AC-7a: listable is 0');
});

criterion('AC-7: same shape (no entrypoint/promptSource) with an ORDINARY prompt -> human, classified_by default', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_B.jsonl",
        user_rec(sessionId => $UUID_B, timestamp => ts(0), content => 'Please tidy up this module.'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'human', 'AC-7b: kind is human');
    is($entry->{classified_by}, 'default', 'AC-7b: classified_by is default');
});

# =============================================================================
# AC-8 -> DC 1: metadata wins even over a preamble-looking prompt
# =============================================================================
criterion('AC-8: entrypoint cli WITH a preamble-looking prompt -> human, classified_by metadata (preamble not consulted)', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => "You are a ccpraxis butler coordinator for this run."),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{kind}, 'human', 'AC-8: kind is human (entrypoint metadata wins over preamble text)');
    is($entry->{classified_by}, 'metadata', 'AC-8: classified_by is metadata');
});

# =============================================================================
# AC-9 -> DC 2: typed_text() per-record noise/positive table
# =============================================================================
criterion('AC-9: typed_text returns undef for every noise kind in spec 3.2', sub {
    my @noise_cases = (
        ['isSidechain true'                  => user_rec(isSidechain => 1, content => 'noisy sidechain text')],
        ['isMeta true'                        => user_rec(isMeta => 1, content => 'Base directory for this skill...')],
        ['isCompactSummary true'              => user_rec(isCompactSummary => 1, content => 'a compacted summary')],
        ['isVisibleInTranscriptOnly true'     => user_rec(isVisibleInTranscriptOnly => 1, content => 'transcript-only text')],
        ['top-level toolUseResult present'    => user_rec(toolUseResult => { ok => 1 }, content => 'ignored text')],
        ['tool_result content block'          => user_rec(content => [ { type => 'tool_result', tool_use_id => 'x', content => 'blob' } ])],
        ['promptSource system'                => user_rec(promptSource => 'system', content => 'system-injected text')],
        ["origin.kind task-notification"      => user_rec(origin => { kind => 'task-notification' }, content => 'a task notification')],
        ['assistant-type record'              => assistant_rec(content => 'I will do that now.')],
        ['whitespace-only text'               => user_rec(content => "   \n\t  ")],
        ['image-only content (no text block)' => user_rec(content => [ { type => 'image', source => { data => 'xyz' } } ])],
    );

    my @prefix_cases = (
        [ '[Request interrupted marker'        => '[Request interrupted by user]' ],
        [ '<command-name> stub'                => '<command-name>foo</command-name>' ],
        [ '<command-message> stub'             => '<command-message>bar</command-message>' ],
        [ '<command-args> stub'                => '<command-args>baz</command-args>' ],
        [ '<command-stdout> stub'              => '<command-stdout>qux</command-stdout>' ],
        [ '<local-command-caveat> stub'        => '<local-command-caveat>note</local-command-caveat>' ],
        [ '<local-command-stdout> stub'        => '<local-command-stdout>out</local-command-stdout>' ],
        [ '<local-command-stderr> stub'        => '<local-command-stderr>err</local-command-stderr>' ],
        [ '<task-notification> stub'           => '<task-notification>ping</task-notification>' ],
        [ '<system-reminder> stub'              => '<system-reminder>remember</system-reminder>' ],
        [ '<bash-input> stub'                   => '<bash-input>ls -la</bash-input>' ],
        [ '<bash-stdout> stub'                  => '<bash-stdout>total 0</bash-stdout>' ],
        [ '<bash-stderr> stub'                  => '<bash-stderr>error</bash-stderr>' ],
        [ '<user-prompt-submit-hook> stub'       => '<user-prompt-submit-hook>hook</user-prompt-submit-hook>' ],
        [ 'compact-summary continuation banner' => 'This session is being continued from a previous conversation, summarized below.' ],
        [ 'local-command caveat banner'         => 'Caveat: The messages below were generated by the user while running local commands. Do not respond.' ],
    );

    for my $case (@noise_cases) {
        my ($label, $rec) = @$case;
        my $got = SessionIndex::typed_text($rec);
        is($got, undef, "AC-9: typed_text is undef for [$label]");
    }

    for my $case (@prefix_cases) {
        my ($label, $text) = @$case;
        my $rec = user_rec(content => $text);
        my $got = SessionIndex::typed_text($rec);
        is($got, undef, "AC-9: typed_text is undef for [$label]");
    }

    # Indentation before a noise prefix must still be recognized as noise
    # (leading whitespace is stripped before the prefix check, spec 3.2).
    my $indented = user_rec(content => "   <task-notification>ping</task-notification>");
    is(SessionIndex::typed_text($indented), undef,
        'AC-9: typed_text is undef for a noise prefix preceded by leading whitespace');

    # Positive cases: string content, and a text-block array joined with "\n".
    my $string_rec = user_rec(content => 'Please refactor the parser module.');
    is(SessionIndex::typed_text($string_rec), 'Please refactor the parser module.',
        'AC-9: typed_text returns the exact text for string content');

    my $array_rec = user_rec(content => [
        { type => 'text', text => 'First line of the message.' },
        { type => 'text', text => 'Second line of the message.' },
    ]);
    is(SessionIndex::typed_text($array_rec), "First line of the message.\nSecond line of the message.",
        'AC-9: typed_text joins text-type blocks with "\n" for array content');
});

# =============================================================================
# AC-10 -> DC 2: noise surrounds two typed messages -> first/last are exactly
# those two; same_message 0
# =============================================================================
criterion('AC-10: noise records first and last in file; first_typed/last_typed are the two real messages, same_message 0', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => '<task-notification>startup ping</task-notification>'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli',
                 content => 'Please review the attached diff.'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(15), content => 'Reviewing now.'),
        user_rec(sessionId => $UUID_A, timestamp => ts(20), entrypoint => 'cli',
                 content => "Thanks, that's exactly what I needed."),
        user_rec(sessionId => $UUID_A, timestamp => ts(25), entrypoint => 'cli',
                 content => '[Request interrupted by user]'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{first_typed}, 'Please review the attached diff.', 'AC-10: first_typed is the first real message');
    is($entry->{last_typed}, "Thanks, that's exactly what I needed.", 'AC-10: last_typed is the second real message');
    is($entry->{same_message}, 0, 'AC-10: same_message is 0');
});

# =============================================================================
# AC-11 -> DC 2: single typed message, and two records with identical text
# =============================================================================
criterion('AC-11a: exactly one typed message -> first_typed eq last_typed, same_message 1', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => 'One and only real message.'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(5), content => 'Got it.'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{first_typed}, 'One and only real message.', 'AC-11a: first_typed set');
    is($entry->{last_typed}, $entry->{first_typed}, 'AC-11a: last_typed eq first_typed');
    is($entry->{same_message}, 1, 'AC-11a: same_message is 1');
});

criterion('AC-11b: two distinct typed records with identical text -> same_message 1', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'repeat me please'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(5), content => 'sure'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli', content => 'repeat me please'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{first_typed}, 'repeat me please', 'AC-11b: first_typed set');
    is($entry->{last_typed}, 'repeat me please', 'AC-11b: last_typed set');
    is($entry->{same_message}, 1,
        'AC-11b: same_message is 1 for two distinct records whose TEXT is identical');
});

# =============================================================================
# AC-12 -> DC 3: last_active_at is the tool-result record's time, not the last
# typed message's, and not mtime; timestamp-less trailing records ignored
# =============================================================================
criterion('AC-12: last_active_at is the last record with a timestamp, even when it is a tool-result, not the last typed message', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'do the thing'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(5), content => 'doing it'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), toolUseResult => { ok => 1 },
                 content => [ { type => 'tool_result', tool_use_id => 'x', content => 'result blob' } ]),
        { type => 'last-prompt', sessionId => $UUID_A, lastPrompt => 'do the thing' },
        { type => 'ai-title', sessionId => $UUID_A, title => 'Do the thing' },
    );
    my $mtime = time - 100000;
    utime($mtime, $mtime, $path) or die "utime: $!";
    my $entry = SessionIndex::index_file($path);
    is($entry->{last_active_at}, $T0 + 10, 'AC-12: last_active_at equals the tool-result record\'s time');
    isnt($entry->{last_active_at}, $T0 + 0, 'AC-12: last_active_at is not the last typed message\'s time');
    isnt($entry->{last_active_at}, $mtime, 'AC-12: last_active_at is not mtime');
    is($entry->{time_source}, 'records', 'AC-12: time_source is records');
});

# =============================================================================
# AC-13 -> DC 3: started_at from the first timestamped record; all-timestamp-
# less file falls back to mtime for both times
# =============================================================================
criterion('AC-13a: started_at is the first timestamped record\'s time even when the file begins with timestamp-less lines', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        { type => 'mode', sessionId => $UUID_A, mode => 'default' },
        { type => 'permission-mode', sessionId => $UUID_A, mode => 'ask' },
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'first real record'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{started_at}, $T0 + 0, 'AC-13a: started_at is the first timestamped record\'s time');
    is($entry->{time_source}, 'records', 'AC-13a: time_source is records');
});

criterion('AC-13b: a file with no timestamps at all -> both times equal mtime, time_source mtime', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        { type => 'mode', sessionId => $UUID_A, mode => 'default' },
        { type => 'permission-mode', sessionId => $UUID_A, mode => 'ask' },
        { type => 'ai-title', sessionId => $UUID_A, title => 'Untimed session' },
    );
    my $mtime = time - 54321;
    utime($mtime, $mtime, $path) or die "utime: $!";
    my $entry = SessionIndex::index_file($path);
    is($entry->{started_at}, $mtime, 'AC-13b: started_at equals mtime');
    is($entry->{last_active_at}, $mtime, 'AC-13b: last_active_at equals mtime');
    is($entry->{time_source}, 'mtime', 'AC-13b: time_source is mtime');
});

# =============================================================================
# AC-14 -> DC 3: out-of-time-order records -> last_active_at is the LAST
# record's time in file order, not the maximum timestamp seen
# =============================================================================
criterion('AC-14: records out of time order -> last_active_at is the last record\'s time in file order, even when an earlier record is later', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(500), entrypoint => 'cli', content => 'first, timestamped later'),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(100), content => 'second, timestamped earlier'),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{started_at}, $T0 + 500, 'AC-14: started_at is the FIRST record\'s time (500)');
    is($entry->{last_active_at}, $T0 + 100, 'AC-14: last_active_at is the LAST record\'s time (100), not the max (500)');
});

# =============================================================================
# AC-15 -> DC 4: interruption markers alongside real typed messages -> listed
# =============================================================================
criterion('AC-15: interruption markers plus real typed messages -> empty 0, listable 1, first/last are the real messages', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => '[Request interrupted by user]'),
        user_rec(sessionId => $UUID_A, timestamp => ts(5), entrypoint => 'cli',
                 content => 'Please continue the task.'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli',
                 content => '[Request interrupted by user for tool use]'),
        user_rec(sessionId => $UUID_A, timestamp => ts(15), entrypoint => 'cli',
                 content => "Thanks, that's exactly right."),
        assistant_rec(sessionId => $UUID_A, timestamp => ts(20), content => "You're welcome."),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{empty}, 0, 'AC-15: empty is 0');
    is($entry->{listable}, 1, 'AC-15: listable is 1');
    is($entry->{first_typed}, 'Please continue the task.', 'AC-15: first_typed is the first real message');
    is($entry->{last_typed}, "Thanks, that's exactly right.", 'AC-15: last_typed is the second real message');
});

# =============================================================================
# AC-16 -> DC 4: only noise -> empty; zero-byte file -> empty
# =============================================================================
criterion('AC-16a: only interruption/slash-command/caveat/tool-result noise -> empty 1, listable 0, first_typed undef; still returned by index_dir', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => '[Request interrupted by user]'),
        user_rec(sessionId => $UUID_A, timestamp => ts(5), entrypoint => 'cli',
                 content => '<command-name>foo</command-name>'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli',
                 content => '<local-command-stdout>output text</local-command-stdout>'),
        user_rec(sessionId => $UUID_A, timestamp => ts(15), entrypoint => 'cli',
                 toolUseResult => { ok => 1 },
                 content => [ { type => 'tool_result', tool_use_id => 'y', content => 'blob' } ]),
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{empty}, 1, 'AC-16a: empty is 1');
    is($entry->{listable}, 0, 'AC-16a: listable is 0');
    is($entry->{first_typed}, undef, 'AC-16a: first_typed is undef');

    my $entries = SessionIndex::index_dir($dir);
    is(scalar(@$entries), 1, 'AC-16a: index_dir still returns the all-noise session (consumer filters)');
});

criterion('AC-16b: a zero-byte file -> a defined entry with empty 1', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/$UUID_A.jsonl";
    write_raw($path, '');
    my $entry = SessionIndex::index_file($path);
    ok(defined $entry, 'AC-16b: index_file returns a defined entry for a zero-byte file');
    is($entry->{empty}, 1, 'AC-16b: empty is 1');
});

# =============================================================================
# AC-17 -> DC 5: non-ASCII typed text with embedded newline round-trips
# exactly; the fixture dir name is also non-ASCII where the filesystem allows it
# =============================================================================
{
    my $NONASCII_TEXT = "a\x{e7}\x{e3}o \x{2014} \x{65e5}\x{672c}\nsecond line, still non-ASCII: \x{e9}\x{e8}";

    criterion('AC-17a: a typed message with non-ASCII text and an embedded newline round-trips character-for-character', sub {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = write_jsonl("$dir/$UUID_A.jsonl",
            user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                     content => $NONASCII_TEXT),
        );
        my $entry = SessionIndex::index_file($path);
        is($entry->{first_typed}, $NONASCII_TEXT,
            'AC-17a: first_typed is character-equal to the original non-ASCII string, newline intact');
    });

    # Best-effort: the fixture DIRECTORY name is also non-ASCII, per spec
    # section 5 ("Fixture paths under this host's temp dir contain e-acute").
    # This is attempted and, on a filesystem/Perl build where a non-ASCII
    # mkdir genuinely cannot be created, skipped rather than failing the
    # whole file -- the substantive round-trip guarantee is already proven
    # in AC-17a above, independent of the directory name.
    my $base17 = tempdir(CLEANUP => 1);
    my $nonascii_dirname = "caf\x{e9}-\x{65e5}\x{672c}-session";
    my $dir17 = "$base17/$nonascii_dirname";
    my $mkdir_ok = eval { mkdir($dir17) or die "mkdir failed: $!"; 1 };

    SKIP: {
        skip 'AC-17b: could not create a non-ASCII-named directory on this filesystem/Perl build', 1
            unless $mkdir_ok && -d $dir17;
        criterion('AC-17b: fixture dir with a non-ASCII name still indexes correctly', sub {
            my $path = write_jsonl("$dir17/$UUID_A.jsonl",
                user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                         content => $NONASCII_TEXT),
            );
            my $entry = SessionIndex::index_file($path);
            is($entry->{first_typed}, $NONASCII_TEXT,
                'AC-17b: first_typed round-trips exactly even when the containing dir name is non-ASCII');
        });
    }
}

# =============================================================================
# AC-18 -> DC 5: 300 synthetic sessions, ~30 records incl. ~2 KiB tool
# results -> index_dir returns 300 entries; best of 3 timed runs < 1.0s
# =============================================================================
criterion('AC-18: index_dir over 300 sessions (~30 records each) returns 300 entries; best-of-3 timed run is under 1.0s', sub {
    my $dir = tempdir(CLEANUP => 1);
    my $n_sessions = 300;
    my $tool_blob = 'X' x 2048;

    for my $i (1 .. $n_sessions) {
        my $uuid = sprintf('%08x-0000-4000-8000-%012x', $i, $i);
        my @recs;
        my $t = 0;
        for my $j (1 .. 30) {
            $t += 3;
            if ($j == 1) {
                push @recs, user_rec(sessionId => $uuid, timestamp => ts($t), entrypoint => 'cli',
                                      content => "session $i message $j");
            } elsif ($j % 5 == 0) {
                push @recs, user_rec(sessionId => $uuid, timestamp => ts($t), toolUseResult => { ok => 1 },
                                      content => [ { type => 'tool_result', tool_use_id => "t$j", content => $tool_blob } ]);
            } elsif ($j % 3 == 0) {
                push @recs, user_rec(sessionId => $uuid, timestamp => ts($t), entrypoint => 'cli',
                                      content => "session $i message $j");
            } else {
                push @recs, assistant_rec(sessionId => $uuid, timestamp => ts($t), content => "assistant reply $j for session $i");
            }
        }
        write_jsonl("$dir/$uuid.jsonl", @recs);
    }

    my $best;
    for my $run (1 .. 3) {
        my $t0 = Time::HiRes::time();
        my $entries = SessionIndex::index_dir($dir);
        my $elapsed = Time::HiRes::time() - $t0;
        is(scalar(@$entries), $n_sessions, "AC-18: run $run: index_dir returns exactly $n_sessions entries");
        $best = $elapsed if !defined $best || $elapsed < $best;
    }
    ok($best < 1.0, "AC-18: best of 3 timed runs is under 1.0s (best was ${best}s)");
});

# =============================================================================
# AC-19 -> DC 5: work cap. With tiny HEAD/TAIL windows, a big fixture is
# truncated; only start/end typed messages are seen, never the middle one;
# a tail with no typed message falls back to the last typed message in head.
# =============================================================================
criterion('AC-19a: work cap -- truncated file finds start and end typed messages, never the untouched middle one', sub {
    local $SessionIndex::HEAD_MAX_BYTES = 4096;
    local $SessionIndex::TAIL_MAX_BYTES = 4096;

    my $dir = tempdir(CLEANUP => 1);
    my $filler = 'F' x 100_000;
    my @recs = (
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'start message'),
        { type => 'queue-operation', operation => 'noise', filler => $filler },
        user_rec(sessionId => $UUID_A, timestamp => ts(100), entrypoint => 'cli', content => 'middle message -- must never be chosen'),
        { type => 'queue-operation', operation => 'noise', filler => $filler },
        user_rec(sessionId => $UUID_A, timestamp => ts(200), entrypoint => 'cli', content => 'end message'),
    );
    my $path = write_jsonl("$dir/$UUID_A.jsonl", @recs);
    my $size = (stat($path))[7];
    ok($size > $SessionIndex::HEAD_MAX_BYTES + $SessionIndex::TAIL_MAX_BYTES,
        "AC-19a: fixture ($size bytes) exceeds HEAD+TAIL (" . ($SessionIndex::HEAD_MAX_BYTES + $SessionIndex::TAIL_MAX_BYTES) . ' bytes)');

    my $entry = SessionIndex::index_file($path);
    is($entry->{truncated}, 1, 'AC-19a: truncated is 1');
    is($entry->{first_typed}, 'start message', 'AC-19a: first_typed is the start message');
    is($entry->{last_typed}, 'end message', 'AC-19a: last_typed is the end message, not the middle one');
});

criterion('AC-19b: work cap -- no typed message in the tail window falls back to the last typed message seen in the head window', sub {
    local $SessionIndex::HEAD_MAX_BYTES = 4096;
    local $SessionIndex::TAIL_MAX_BYTES = 4096;

    my $dir = tempdir(CLEANUP => 1);
    my $filler = 'F' x 150_000;
    my @recs = (
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'head-first message'),
        user_rec(sessionId => $UUID_A, timestamp => ts(1), entrypoint => 'cli', content => 'head-second message'),
        { type => 'queue-operation', operation => 'noise', filler => $filler },
        assistant_rec(sessionId => $UUID_A, timestamp => ts(200), content => 'tail-only assistant reply, no typed message here'),
    );
    my $path = write_jsonl("$dir/$UUID_A.jsonl", @recs);
    my $size = (stat($path))[7];
    ok($size > $SessionIndex::HEAD_MAX_BYTES + $SessionIndex::TAIL_MAX_BYTES,
        "AC-19b: fixture ($size bytes) exceeds HEAD+TAIL");

    my $entry = SessionIndex::index_file($path);
    is($entry->{truncated}, 1, 'AC-19b: truncated is 1');
    is($entry->{first_typed}, 'head-first message', 'AC-19b: first_typed is the first head message');
    is($entry->{last_typed}, 'head-second message',
        'AC-19b: last_typed falls back to the LAST typed message seen in head (not the first)');
});

# =============================================================================
# AC-20 -> DC 1-5: robustness -- malformed lines, partial last line, CRLF,
# unreadable/missing paths never die or warn
# =============================================================================
criterion('AC-20a: malformed JSON lines are ignored, not fatal; the scan continues over valid lines', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/$UUID_A.jsonl";
    my $good1 = $JSON->encode(user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'good first message'));
    my $good2 = $JSON->encode(user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli', content => 'good last message'));
    write_raw($path, "$good1\n{not json at all\n[]\nnull\n\"just a string\"\n$good2\n");

    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };
    my $entry = eval { SessionIndex::index_file($path) };
    is($@, '', 'AC-20a: index_file does not die on malformed JSON lines');
    is($warn_count, 0, 'AC-20a: index_file does not warn on malformed JSON lines');
    ok(defined $entry, 'AC-20a: a defined entry is still returned');
    is($entry->{first_typed}, 'good first message', 'AC-20a: first_typed still found around the malformed lines');
    is($entry->{last_typed}, 'good last message', 'AC-20a: last_typed still found around the malformed lines');
});

criterion('AC-20b: a partial (truncated) last line does not die or warn', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/$UUID_A.jsonl";
    my $good = $JSON->encode(user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'complete message'));
    write_raw($path, "$good\n" . '{"type":"user","message":{"role":"user","content":"cut off mid-writ');

    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };
    my $entry = eval { SessionIndex::index_file($path) };
    is($@, '', 'AC-20b: index_file does not die on a partial trailing line');
    is($warn_count, 0, 'AC-20b: index_file does not warn on a partial trailing line');
    ok(defined $entry, 'AC-20b: a defined entry is still returned');
    is($entry->{first_typed}, 'complete message', 'AC-20b: the complete line before the partial one is still found');
});

criterion('AC-20c: CRLF line endings do not die or warn, and the trailing CR is stripped from parsed content', sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/$UUID_A.jsonl";
    my $good1 = $JSON->encode(user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'crlf message one'));
    my $good2 = $JSON->encode(assistant_rec(sessionId => $UUID_A, timestamp => ts(5), content => 'crlf reply'));
    write_raw($path, "$good1\r\n$good2\r\n");

    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };
    my $entry = eval { SessionIndex::index_file($path) };
    is($@, '', 'AC-20c: index_file does not die on CRLF line endings');
    is($warn_count, 0, 'AC-20c: index_file does not warn on CRLF line endings');
    is($entry->{first_typed}, 'crlf message one', 'AC-20c: CRLF-terminated JSON still parses correctly');
});

criterion('AC-20d: unreadable/missing paths never die or warn', sub {
    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };

    my $missing_dir = tempdir(CLEANUP => 1);
    my $missing_file = "$missing_dir/does-not-exist.jsonl";
    my $r1 = eval { SessionIndex::index_file($missing_file) };
    is($@, '', 'AC-20d: index_file(missing path) does not die');
    is($r1, undef, 'AC-20d: index_file(missing path) returns undef');

    my $dir_as_file = eval { SessionIndex::index_file($missing_dir) };
    is($@, '', 'AC-20d: index_file(a directory, not a regular file) does not die');
    is($dir_as_file, undef, 'AC-20d: index_file(a directory) returns undef (not a readable regular file)');

    my $r2 = eval { SessionIndex::index_dir("$missing_dir/no-such-subdir") };
    is($@, '', 'AC-20d: index_dir(missing dir) does not die');
    is_deeply($r2, [], 'AC-20d: index_dir(missing dir) returns []');

    is($warn_count, 0, 'AC-20d: none of the unreadable/missing-path calls emitted a warning');
});

# =============================================================================
# AC-21 -> DC 3: index_dir ordering -- last_active_at descending, ties by id
# ascending; id falls back to sessionId for a non-UUID filename
# =============================================================================
criterion('AC-21a: index_dir sorts by last_active_at descending', sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl("$dir/$UUID_A.jsonl", user_rec(sessionId => $UUID_A, timestamp => ts(100), entrypoint => 'cli', content => 'a'));
    write_jsonl("$dir/$UUID_B.jsonl", user_rec(sessionId => $UUID_B, timestamp => ts(300), entrypoint => 'cli', content => 'b'));
    write_jsonl("$dir/$UUID_C.jsonl", user_rec(sessionId => $UUID_C, timestamp => ts(200), entrypoint => 'cli', content => 'c'));

    my $entries = SessionIndex::index_dir($dir);
    is(scalar(@$entries), 3, 'AC-21a: 3 entries returned');
    is_deeply([ map { $_->{id} } @$entries ], [ $UUID_B, $UUID_C, $UUID_A ],
        'AC-21a: order is most-recently-active first (B=300, C=200, A=100)');
});

criterion('AC-21b: ties in last_active_at are broken by id ascending (string compare)', sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl("$dir/$UUID_B.jsonl", user_rec(sessionId => $UUID_B, timestamp => ts(500), entrypoint => 'cli', content => 'b'));
    write_jsonl("$dir/$UUID_A.jsonl", user_rec(sessionId => $UUID_A, timestamp => ts(500), entrypoint => 'cli', content => 'a'));

    my $entries = SessionIndex::index_dir($dir);
    is_deeply([ map { $_->{id} } @$entries ], [ $UUID_A, $UUID_B ],
        'AC-21b: identical last_active_at ties broken by id ascending (A before B)');
});

criterion('AC-21c: id falls back to the first record\'s sessionId when the filename stem is not UUID-shaped', sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl("$dir/notauuid.jsonl", user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'fallback id test'));

    my $entries = SessionIndex::index_dir($dir);
    is(scalar(@$entries), 1, 'AC-21c: one entry returned');
    is($entries->[0]{id}, $UUID_A, 'AC-21c: id falls back to the first record\'s sessionId, not the filename stem');
});

# =============================================================================
# AC-22 (Decision 20, point 1): a typed message that sits ONLY in the middle
# of a file over 1 MiB -- strictly beyond either a fixed head or a fixed tail
# window -- is still found by an unbounded-until-found scan. The session must
# be listable with correct first/last typed messages, never empty.
# =============================================================================
criterion('AC-22 (Decision 20): a typed message buried in the middle of a >1 MiB file, beyond any fixed head/tail window, is still found -- listable, not empty', sub {
    my $dir = tempdir(CLEANUP => 1);
    my $pad = 'M' x 600_000;
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        { type => 'queue-operation', operation => 'noise', filler => $pad },
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => 'the only real message, buried in the middle'),
        { type => 'queue-operation', operation => 'noise', filler => $pad },
    );
    my $size = (stat($path))[7];
    ok($size > 1024 * 1024, "AC-22: fixture ($size bytes) exceeds 1 MiB");
    ok(length($pad) > $SessionIndex::HEAD_MAX_BYTES,
        'AC-22: the leading padding alone exceeds the fixed head window');
    ok(length($pad) > $SessionIndex::TAIL_MAX_BYTES,
        'AC-22: the trailing padding alone exceeds the fixed tail window');

    my $entry = SessionIndex::index_file($path);
    ok(defined $entry, 'AC-22: index_file returns a defined entry');
    is($entry->{empty}, 0, 'AC-22: empty is 0 -- the middle message was found (not silently dropped)');
    is($entry->{listable}, 1, 'AC-22: listable is 1');
    is($entry->{first_typed}, 'the only real message, buried in the middle',
        'AC-22: first_typed is the buried message');
    is($entry->{last_typed}, $entry->{first_typed},
        'AC-22: last_typed equals first_typed (it is the only typed message in the file)');
});

# =============================================================================
# AC-23 (Decision 20 / review M1): a truncated file whose LAST line by itself
# exceeds the tail window must still yield the correct last_active_at -- not
# collapse to started_at because the tail window contained no newline.
# =============================================================================
criterion('AC-23 (M1): a final line larger than the tail window still yields the correct last_active_at, never collapsed to started_at', sub {
    my $dir = tempdir(CLEANUP => 1);
    my $pad = 'F' x 600_000;
    my $huge_blob = 'H' x 600_000;
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'session start'),
        { type => 'queue-operation', operation => 'noise', filler => $pad },
        { type => 'user', sessionId => $UUID_A, timestamp => ts(18000), toolUseResult => { ok => 1 },
          message => { role => 'user', content => [ { type => 'tool_result', tool_use_id => 'z', content => $huge_blob } ] } },
    );
    my $size = (stat($path))[7];
    ok($size > $SessionIndex::HEAD_MAX_BYTES + $SessionIndex::TAIL_MAX_BYTES,
        "AC-23: fixture ($size bytes) exceeds HEAD+TAIL -- this is a truncated-scan case");

    my $entry = SessionIndex::index_file($path);
    is($entry->{started_at}, $T0 + 0, 'AC-23: started_at is the session-start record\'s time');
    is($entry->{last_active_at}, $T0 + 18000,
        'AC-23: last_active_at is the huge final record\'s OWN timestamp (18000s after start)');
    isnt($entry->{last_active_at}, $entry->{started_at},
        'AC-23: last_active_at is never collapsed to started_at just because the last line has no newline in the tail window (the M1 defect)');
});

# =============================================================================
# AC-24 (Decision 20 / review M2): a nested "timestamp" key inside
# toolUseResult must never override the record's own top-level timestamp.
# =============================================================================
criterion('AC-24 (M2): a nested toolUseResult.timestamp never overrides the record\'s top-level timestamp', sub {
    my $dir = tempdir(CLEANUP => 1);
    my $nested_bogus_epoch = timegm(0, 0, 0, 5, 4, 2020);   # 2020-05-05T00:00:00Z -- far from $T0
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli', content => 'session start'),
        { type => 'user', sessionId => $UUID_A, timestamp => ts(50),
          toolUseResult => { timestamp => '2020-05-05T00:00:00Z', ok => 1 },
          message => { role => 'user', content => [ { type => 'tool_result', tool_use_id => 'w', content => 'a tool result blob' } ] } },
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{last_active_at}, $T0 + 50,
        'AC-24: last_active_at is the record\'s own TOP-LEVEL timestamp (50s after start)');
    isnt($entry->{last_active_at}, $nested_bogus_epoch,
        'AC-24: last_active_at is never the bogus timestamp nested inside toolUseResult');
});

# =============================================================================
# AC-25 (Decision 20 / review M3): a tool_use input carrying a nested
# "type":"user" pair, preceded by an unrelated nested "message" key, must
# never be mistaken for the operator's typed message.
# =============================================================================
criterion('AC-25 (M3): a tool_use input carrying "type":"user", plus an earlier nested "message" key ahead of the real top-level message, never changes first_typed or last_typed', sub {
    my $dir  = tempdir(CLEANUP => 1);
    # The trap record's TOP-LEVEL keys, in the byte order JSON::PP->canonical
    # actually emits them (alphabetical): error, message, sessionId, timestamp,
    # type. "error" sorts before the real top-level "message" key, so its own
    # nested "message" key is the FIRST "message" occurrence in the raw line
    # -- exactly the ordering review finding M3(b) describes (its own "error"
    # example). The tool_use block nested inside the REAL message additionally
    # carries a "type":"user" pair in its `input`, matching M3(a): the
    # unanchored `"type":"user"` prefilter must not treat this assistant
    # record as a typed-message candidate at all.
    #
    # Placed LAST in the file, deliberately: last_typed is overwritten by
    # whatever the scan finds on each subsequent matching line (first_typed
    # alone is "first wins"), so a trap placed before the real last message
    # would simply be overwritten by it and prove nothing. Only a trap AFTER
    # every genuine typed message can show whether it corrupts last_typed.
    my $trap_rec = {
        error     => { message => { content => 'ERR NESTED, must never be picked as typed text' } },
        message   => { role => 'assistant', content => [
            { type => 'tool_use', id => 'tu1', name => 'some_mcp_tool',
              input => { type => 'user', message => { role => 'user', content => 'NESTED FAKE MESSAGE inside tool_use input' } } },
        ] },
        sessionId => $UUID_A,
        timestamp => ts(20),
        type      => 'assistant',
    };
    my $path = write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(0), entrypoint => 'cli',
                 content => 'genuine first message'),
        user_rec(sessionId => $UUID_A, timestamp => ts(10), entrypoint => 'cli',
                 content => 'genuine last message'),
        $trap_rec,
    );
    my $entry = SessionIndex::index_file($path);
    is($entry->{first_typed}, 'genuine first message', 'AC-25: first_typed is the real first message');
    is($entry->{last_typed}, 'genuine last message',
        'AC-25: last_typed is the real last message -- never the nested tool_use trap, nor the "error" wrapper\'s nested message');
});

done_testing();
