#!/usr/bin/env perl
# platform: any
# report-session's exact attribution path and its data-root default:
#
#   * a subagent whose sidecar toolUseId has a record written at dispatch
#     time by hooks/track-dispatch.sh is attributed from it (source
#     dispatch-hook), ahead of the dispatch-log time-window match;
#   * two records disagreeing about one tool_use_id attribute nothing;
#   * the rolled-over attribution.jsonl.1 is read too;
#   * unsafe names in a record are ignored;
#   * with no --data-root, the data root comes from the `cwd` the session
#     recorded (walking up to the nearest .ccpraxis-local-data) before
#     CLAUDE_PROJECT_DIR, and the text report says where it came from.
#
# spend-session-attribution.t stays the oracle for everything else
# report-session does, including the --json key set (AC18). Every
# fixture is synthetic, in a tempdir; nothing reads ~/.claude or the repo's
# own .ccpraxis-local-data.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Find ();

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');
ok(eval { require $SPEND_PL; 1 }, 'bp-spend.pl loads as a module') or BAIL_OUT("require: $@");

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w;
}

sub jsonl { join('', map { $J->encode($_) . "\n" } @_) }

sub assistant {
    my (%o) = @_;
    return {
        type => 'assistant', uuid => $o{uuid}, requestId => $o{req}, timestamp => $o{ts},
        effort => 'medium', session_id => 'sess-1',
        message => { id => "msg-$o{req}", model => 'claude-sonnet-5',
                     usage => { input_tokens => $o{input}, output_tokens => 10, speed => 'standard' } },
    };
}

# A project with a data dir, and a session in a SEPARATE transcripts dir (as
# ~/.claude/projects/<slug>/ is), whose records say they ran in the project.
# Agents: a (hook-attributed), b (only a dispatch-log record), c (conflicting
# hook records), d (hook record in the rolled-over file), e (no record).
sub fixture {
    my (%o) = @_;
    my $root    = tempdir(CLEANUP => 1);
    my $project = "$root/project";
    my $data    = "$project/.ccpraxis-local-data";
    my $cwd     = $o{cwd} // $project;
    make_path("$data/blueprints/bp-one/packages", "$data/blueprints/bp-two/packages");
    write_file("$data/blueprints/bp-one/packages/01-alpha.md", "---\nstatus: done\n---\n");
    write_file("$data/blueprints/bp-two/packages/02-beta.md",  "---\nstatus: done\n---\n");

    my $sdir = "$root/transcripts";
    my $main = "$sdir/sess-1.jsonl";
    my @head = $o{no_cwd} ? () : ({ type => 'permission-mode', cwd => $cwd, sessionId => 'sess-1' });
    write_file($main, jsonl(@head, assistant(uuid => 'm1', req => 'r-main', ts => '2026-09-23T10:00:00Z', input => 1000)));

    my %agents = (
        a => { tuid => 'toolu_A', input => 100, ts => '2026-09-23T10:01:00Z' },
        b => { tuid => 'toolu_B', input => 200, ts => '2026-09-23T10:02:00Z' },
        c => { tuid => 'toolu_C', input => 300, ts => '2026-09-23T10:03:00Z' },
        d => { tuid => 'toolu_D', input => 400, ts => '2026-09-23T10:04:00Z' },
        e => { tuid => 'toolu_E', input => 500, ts => '2026-09-23T10:05:00Z' },
    );
    for my $k (sort keys %agents) {
        my $a = $agents{$k};
        write_file("$sdir/sess-1/subagents/agent-$k.jsonl",
            jsonl(assistant(uuid => "u$k", req => "r-$k", ts => $a->{ts}, input => $a->{input})));
        write_file("$sdir/sess-1/subagents/agent-$k.meta.json",
            $J->encode({ agentType => 'butler:bp-implementer', description => "agent $k", toolUseId => $a->{tuid} }));
    }

    my $t0 = 1790157600;   # 2026-09-23T10:00:00Z
    # A dispatch-log record that, by time window alone, would claim agent a
    # for bp-two -- the hook record must win over it.
    write_file("$data/.dispatch-log/bp-two-2-implementer-$t0.json", $J->encode({
        id => "bp-two-2-implementer-$t0", worker_type => 'bp-implementer',
        started_at => $t0, ended_at => $t0 + 150 }));
    write_file("$data/.dispatch-log/attribution.jsonl", jsonl(
        { tool_use_id => 'toolu_A', blueprint => 'bp-one', package => '01-alpha', source => 'driver-pointer' },
        { tool_use_id => 'toolu_C', blueprint => 'bp-one', package => '01-alpha', source => 'driver-pointer' },
        { tool_use_id => 'toolu_C', blueprint => 'bp-two', package => '02-beta',  source => 'driver-pointer' },
        { tool_use_id => 'toolu_E', blueprint => '../evil', package => '01-alpha', source => 'driver-pointer' },
        { tool_use_id => 'toolu_E', blueprint => 'bp-one', package => "01\x{1b}[31m", source => 'driver-pointer' },
    ) . "not json at all\n");
    write_file("$data/.dispatch-log/attribution.jsonl.1", jsonl(
        { tool_use_id => 'toolu_D', blueprint => 'bp-two', package => '02-beta', source => 'coordinator-env' },
    ));
    return { root => $root, project => $project, data => $data, main => $main };
}

sub by_path {
    my ($doc, $letter) = @_;
    my ($a) = grep { $_->{path} =~ m{/agent-$letter\.jsonl\z} } @{ $doc->{attribution}{agents} };
    return $a;
}

sub snapshot {
    my ($dir) = @_;
    my %s;
    File::Find::find({ no_chdir => 1, wanted => sub { my @st = stat($_); $s{$_} = "$st[7]:$st[9]" } }, $dir);
    return \%s;
}

subtest 'hook records attribute exactly, ahead of the dispatch-log match' => sub {
    my $f = fixture();
    my $doc = BpSpend::Derive::report_session(session => $f->{main}, data_root => $f->{data},
                                              by => [qw(blueprint package)]);
    my $a = by_path($doc, 'a');
    is($a->{kind}, 'attributed', 'a: attributed');
    is($a->{source}, 'dispatch-hook', 'a: from the hook record, not the time window');
    is("$a->{blueprint}/$a->{package}", 'bp-one/01-alpha', 'a: the hook record wins over the bp-two window match');

    my $b = by_path($doc, 'b');
    is($b->{source}, 'record-id', 'b: no hook record, so the dispatch-log path still runs');
    is("$b->{blueprint}/$b->{package}", 'bp-two/02-beta', 'b: attributed by that path');

    my $c = by_path($doc, 'c');
    isnt($c->{source}, 'dispatch-hook', 'c: two disagreeing hook records attribute nothing');

    my $d = by_path($doc, 'd');
    is($d->{source}, 'dispatch-hook', 'd: found in the rolled-over attribution.jsonl.1');
    is("$d->{blueprint}/$d->{package}", 'bp-two/02-beta', 'd: with its package');

    my $e = by_path($doc, 'e');
    isnt($e->{source}, 'dispatch-hook', 'e: records with unsafe names are ignored');
    unlike($J->encode($doc), qr/evil|\\u001b/, 'no unsafe name reaches the report');

    my %row = map { ("$_->{blueprint}/$_->{package}" => $_->{tokens}) } @{ $doc->{rows} };
    is($row{'bp-one/01-alpha'}, 110, 'bp-one/01-alpha row = agent a (100 input + 10 output)');
};

subtest 'load_dispatch_attribution in isolation' => sub {
    my $f = fixture();
    my $m = BpSpend::Derive::load_dispatch_attribution($f->{data});
    is_deeply($m->{toolu_A}, { blueprint => 'bp-one', package => '01-alpha', source => 'driver-pointer' }, 'A');
    is_deeply($m->{toolu_C}, { conflict => 1 }, 'C: conflict marker');
    ok(!exists $m->{toolu_E}, 'E: every E record was unsafe');
    is_deeply(BpSpend::Derive::load_dispatch_attribution("$f->{root}/nowhere"), {}, 'missing dir: empty map, no error');
};

subtest 'the default data root is the session cwd, before CLAUDE_PROJECT_DIR' => sub {
    my $f = fixture();
    my $decoy = tempdir(CLEANUP => 1);
    make_path("$decoy/.ccpraxis-local-data");
    local $ENV{CLAUDE_PROJECT_DIR} = $decoy;
    my ($r, $src) = BpSpend::Derive::resolve_data_root(undef, $f->{main});
    is($r, "$f->{data}", 'resolves to the project the session ran in');
    is($src, 'session-cwd', 'source session-cwd');
    my $doc = BpSpend::Derive::report_session(session => $f->{main}, by => [qw(blueprint package)]);
    is($doc->{data_root}, $f->{data}, 'report_session uses it');
    is($doc->{data_root_source}, 'session-cwd', 'and the --json document says which rule chose it');
    is(by_path($doc, 'a')->{source}, 'dispatch-hook', 'and attributes from that project');
};

subtest 'a cwd below the project walks up to its data root' => sub {
    my $f = fixture();
    # Re-point the session at a subdirectory of its own project.
    my $sub = "$f->{project}/plugins/deep/dir";
    make_path($sub);
    open my $r, '<:raw', $f->{main} or die; my @l = <$r>; close $r;
    $l[0] = $J->encode({ type => 'permission-mode', cwd => $sub, sessionId => 'sess-1' }) . "\n";
    write_file($f->{main}, join('', @l));
    my ($root, $src) = BpSpend::Derive::resolve_data_root(undef, $f->{main});
    is($root, $f->{data}, 'nearest .ccpraxis-local-data above the cwd');
    is($src, 'session-cwd', 'source session-cwd');
};

subtest 'a Windows-style recorded cwd is honoured' => sub {
    my $f = fixture();
    SKIP: {
        # Claude Code on Windows records `C:\\...`. Only meaningful where the
        # tempdir has a drive-letter form: natively, or via cygpath under MSYS.
        my $native = $f->{project};
        if ($native !~ m{\A[A-Za-z]:/}) {
            my $w = ($^O =~ /\A(?:msys|cygwin|MSWin32)\z/) ? `cygpath -m "$native" 2>/dev/null` : '';
            chomp $w;
            skip 'no drive-letter form of the tempdir on this platform', 2 unless $w =~ m{\A[A-Za-z]:/};
            $native = $w;
        }
        (my $bs = $native) =~ s{/}{\\}g;
        open my $r, '<:raw', $f->{main} or die; my @l = <$r>; close $r;
        $l[0] = $J->encode({ type => 'permission-mode', cwd => $bs, sessionId => 'sess-1' }) . "\n";
        write_file($f->{main}, join('', @l));
        my ($root, $src) = BpSpend::Derive::resolve_data_root(undef, $f->{main});
        is($src, 'session-cwd', 'backslashed drive path resolves');
        is($root, "$native/.ccpraxis-local-data", 'to the slashified project data root');
    }
};

subtest 'no recorded cwd: CLAUDE_PROJECT_DIR, then the script location' => sub {
    my $f = fixture(no_cwd => 1);
    {
        local $ENV{CLAUDE_PROJECT_DIR} = $f->{project};
        my ($r, $src) = BpSpend::Derive::resolve_data_root(undef, $f->{main});
        is($r, $f->{data}, 'CLAUDE_PROJECT_DIR');
        is($src, 'CLAUDE_PROJECT_DIR', 'source');
    }
    {
        local %ENV = %ENV;
        delete $ENV{CLAUDE_PROJECT_DIR};
        my (undef, $src) = BpSpend::Derive::resolve_data_root(undef, $f->{main});
        is($src, 'script-location', 'last resort');
    }
    my ($r, $src) = BpSpend::Derive::resolve_data_root("$f->{data}/", $f->{main});
    is("$r|$src", "$f->{data}|explicit", 'an explicit --data-root always wins, trailing slash stripped');
    is(scalar(BpSpend::Derive::resolve_data_root($f->{data})), $f->{data}, 'scalar context still returns the path');
};

subtest 'CLI: the text report names where the data root came from; nothing is written' => sub {
    my $f = fixture();
    my $before = snapshot($f->{root});
    my $out = `"$^X" "$SPEND_PL" report-session --session "$f->{main}" --by blueprint,package 2>&1`;
    is($? >> 8, 0, 'exit 0');
    like($out, qr{^data-root: \Q$f->{data}\E \(from session-cwd\)$}m, 'data-root line names session-cwd');
    like($out, qr{^row: blueprint=bp-one package=01-alpha \| 110 tokens, }m, 'the hook-attributed row is there');
    my $out2 = `"$^X" "$SPEND_PL" report-session --session "$f->{main}" --data-root "$f->{data}" 2>&1`;
    like($out2, qr{^data-root: \Q$f->{data}\E \(from explicit\)$}m, 'explicit is named too');
    is_deeply(snapshot($f->{root}), $before, 'no file created or modified anywhere in the fixture');
};

# ===========================================================================
# AC-21 (package 12-dispatch-binding): report-session reads the new
# .drive-solo/bindings.jsonl(.1) store too, ahead of the old attribution
# store on a shared tool_use_id. Every existing subtest above is untouched.
# ===========================================================================

subtest 'AC-21: an agent found only in the bindings store is attributed from it' => sub {
    my $f = fixture();
    my $data = $f->{data};

    # agent f: a subagent whose tool_use_id has NO record in attribution.jsonl
    # at all, only in the new .drive-solo/bindings.jsonl store.
    write_file("$f->{root}/transcripts/sess-1/subagents/agent-f.jsonl",
        jsonl(assistant(uuid => 'uf', req => 'r-f', ts => '2026-09-23T10:06:00Z', input => 600)));
    write_file("$f->{root}/transcripts/sess-1/subagents/agent-f.meta.json",
        $J->encode({ agentType => 'butler:bp-implementer', description => 'agent f', toolUseId => 'toolu_F' }));

    write_file("$data/.drive-solo/bindings.jsonl", jsonl(
        { tool_use_id => 'toolu_F', blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch', at => 1790157660 },
        # an id present in BOTH stores, disagreeing on the package: store B wins.
        { tool_use_id => 'toolu_A', blueprint => 'bp-two', package => '02-beta',  source => 'bind-dispatch', at => 1790157670 },
    ));

    # agent g: found only in the ROLLED-OVER bindings.jsonl.1.
    write_file("$f->{root}/transcripts/sess-1/subagents/agent-g.jsonl",
        jsonl(assistant(uuid => 'ug', req => 'r-g', ts => '2026-09-23T10:07:00Z', input => 700)));
    write_file("$f->{root}/transcripts/sess-1/subagents/agent-g.meta.json",
        $J->encode({ agentType => 'butler:bp-implementer', description => 'agent g', toolUseId => 'toolu_G' }));
    write_file("$data/.drive-solo/bindings.jsonl.1", jsonl(
        { tool_use_id => 'toolu_G', blueprint => 'bp-two', package => '02-beta', source => 'bind-dispatch', at => 1790157600 },
    ));

    my $doc = BpSpend::Derive::report_session(session => $f->{main}, data_root => $data, by => [qw(blueprint package)]);

    my $fa = by_path($doc, 'f');
    is($fa->{kind}, 'attributed', 'AC-21: agent f (bindings-store-only) is attributed');
    is($fa->{source}, 'dispatch-hook', 'AC-21: source is still dispatch-hook');
    is("$fa->{blueprint}/$fa->{package}", 'bp-one/01-alpha', 'AC-21: with its bindings-store package');

    my $aa = by_path($doc, 'a');
    is("$aa->{blueprint}/$aa->{package}", 'bp-two/02-beta',
        'AC-21: an id present in both stores takes the bindings store (B) entry');

    my $ga = by_path($doc, 'g');
    is($ga->{source}, 'dispatch-hook', 'AC-21: agent g (rolled-over bindings.jsonl.1 only) is attributed');
    is("$ga->{blueprint}/$ga->{package}", 'bp-two/02-beta', 'AC-21: with its rolled-over package');
};

subtest 'AC-21: load_dispatch_attribution merges both stores, B winning on a shared id' => sub {
    my $f = fixture();
    my $data = $f->{data};
    write_file("$data/.drive-solo/bindings.jsonl", jsonl(
        { tool_use_id => 'toolu_A',  blueprint => 'bp-two', package => '02-beta',  source => 'bind-dispatch', at => 1790157670 },
        { tool_use_id => 'toolu_F2', blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch', at => 1790157680 },
    ));
    my $m = BpSpend::Derive::load_dispatch_attribution($data);
    is_deeply($m->{toolu_A}, { blueprint => 'bp-two', package => '02-beta', source => 'bind-dispatch' },
        'AC-21: toolu_A is overridden by the bindings-store entry');
    is_deeply($m->{toolu_F2}, { blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch' },
        'AC-21: an id present only in the bindings store is found');
};

subtest 'AC-21: with no .drive-solo directory, load_dispatch_attribution is exactly today\'s map' => sub {
    my $f = fixture();
    my $m = BpSpend::Derive::load_dispatch_attribution($f->{data});
    is_deeply($m->{toolu_A}, { blueprint => 'bp-one', package => '01-alpha', source => 'driver-pointer' },
        'AC-21: toolu_A unaffected with no .drive-solo directory');
    is_deeply($m->{toolu_C}, { conflict => 1 }, 'AC-21: toolu_C conflict marker unaffected');
    ok(!exists $m->{toolu_E}, 'AC-21: toolu_E is still absent (unsafe names)');
};

subtest 'AC-21: CLI -- a .drive-solo store present still creates nothing' => sub {
    my $f = fixture();
    my $data = $f->{data};
    write_file("$data/.drive-solo/bindings.jsonl", jsonl(
        { tool_use_id => 'toolu_A', blueprint => 'bp-two', package => '02-beta', source => 'bind-dispatch', at => 1790157670 },
    ));
    my $before = snapshot($f->{root});
    my $out = `"$^X" "$SPEND_PL" report-session --session "$f->{main}" --by blueprint,package 2>&1`;
    is($? >> 8, 0, 'AC-21: exit 0');
    is_deeply(snapshot($f->{root}), $before, 'AC-21: no file created or modified anywhere, with a .drive-solo store present');
};

# ===========================================================================
# FIX-ROUND REGRESSIONS (12-dispatch-binding, review MINOR gaps m3/m4).
# ===========================================================================

subtest 'R9-m3: load_dispatch_attribution merge is exactly the full expected map, nothing spurious' => sub {
    my $f = fixture();
    my $data = $f->{data};
    write_file("$data/.drive-solo/bindings.jsonl", jsonl(
        { tool_use_id => 'toolu_F2', blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch', at => 1790157680 },
    ));
    my $m = BpSpend::Derive::load_dispatch_attribution($data);
    is_deeply($m, {
        toolu_A  => { blueprint => 'bp-one', package => '01-alpha', source => 'driver-pointer' },
        toolu_C  => { conflict => 1 },
        toolu_D  => { blueprint => 'bp-two', package => '02-beta',  source => 'coordinator-env' },
        toolu_F2 => { blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch' },
    }, 'R9-m3: the merged map has exactly these keys and values -- no id added or dropped by mistake');
};

subtest 'R9-m4: a store-B conflict marker overrides a valid store-A entry' => sub {
    my $f = fixture();
    my $data = $f->{data};
    # toolu_A resolves cleanly in store A (fixture()); store B has two
    # disagreeing lines for that same id, which is a conflict within B.
    write_file("$data/.drive-solo/bindings.jsonl", jsonl(
        { tool_use_id => 'toolu_A', blueprint => 'bp-two', package => '02-beta',  source => 'bind-dispatch', at => 1790157670 },
        { tool_use_id => 'toolu_A', blueprint => 'bp-one', package => '01-alpha', source => 'bind-dispatch', at => 1790157671 },
    ));
    my $m = BpSpend::Derive::load_dispatch_attribution($data);
    is_deeply($m->{toolu_A}, { conflict => 1 },
        "R9-m4: store B's conflict marker wins over store A's otherwise-clean entry for the same id");

    my $doc = BpSpend::Derive::report_session(session => $f->{main}, data_root => $data, by => [qw(blueprint package)]);
    my $aa = by_path($doc, 'a');
    isnt($aa->{source}, 'dispatch-hook',
        'R9-m4: agent a is no longer attributed by the hook map once B marks the id a conflict');
};

done_testing();
