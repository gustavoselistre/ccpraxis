#!/usr/bin/env perl
# platform: any
# The dispatch-time attribution hook (hooks/record-dispatch-package.sh):
# records {tool_use_id -> blueprint, package} for an Agent/Task dispatch made
# by a drive-solo DRIVER or a fleet coordinator, so report-session can join a
# subagent's sidecar toolUseId against it exactly.
#
# Every fixture is hermetic: the marker registry, the data dir and HOME are
# tempdirs pinned through CCPRAXIS_DRIVE_ACTIVE_DIR / CCPRAXIS_DATA_DIR /
# HOME, and every ambient BP_* / CCPRAXIS_* variable is stripped first -- this
# suite may itself be running inside a live drive or a butler worker.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $HOOK  = "$Bin/../../hooks/record-dispatch-package.sh";
my $HJSON = "$Bin/../../hooks/hooks.json";
ok(-f $HOOK, 'hook script exists') or BAIL_OUT('no hook');

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w;
}

sub slurp {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return $c;
}

sub records {
    my ($data) = @_;
    my $c = slurp("$data/.dispatch-log/attribution.jsonl");
    return [] unless defined $c;
    return [ map { $J->decode($_) } grep { length } split /\n/, $c ];
}

# A driver fixture: a project with a data dir, a blueprint + running ledger,
# the director's current-package pointer, and a marker registry holding the
# driver session's own marker.
sub driver_fixture {
    my (%o) = @_;
    my $root   = tempdir(CLEANUP => 1);
    my $data   = "$root/.ccpraxis-local-data";
    my $active = "$root/registry";
    my $home   = "$root/home";
    my $bp     = $o{blueprint} // 'demo-bp';
    my $pkg    = $o{package}   // '03-thing';
    make_path("$data/.drive-solo", $active, $home);
    write_file("$data/blueprints/$bp/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: $bp\nstatus: running\nwrite_set: src/\ntest_paths: t/\n---\n\n## Next action\nx\n");
    my $recorded = $o{recorded_at} // time;
    write_file("$data/.drive-solo/current.json",
        $J->encode({ blueprint => $bp, package => $pkg, recorded_at => $recorded }));
    write_file("$active/$_", "") for @{ $o{markers} // ['sess-driver'] };
    return { root => $root, data => $data, active => $active, home => $home, bp => $bp, pkg => $pkg };
}

# run_hook($payload_hashref_or_string, \%env) -> ($exit, $stdout, $stderr).
# Captured through files: reopening STDOUT onto a scalar fails on this host.
sub run_hook {
    my ($payload, $env) = @_;
    my $dir = tempdir(CLEANUP => 1);
    write_file("$dir/in", ref($payload) ? $J->encode($payload) : $payload);
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\A(?:BP_|CCPRAXIS_)/ } keys %ENV;
    delete $ENV{CLAUDE_PROJECT_DIR};
    $ENV{$_} = $env->{$_} for keys %$env;
    system(qq(bash "$HOOK" < "$dir/in" > "$dir/out" 2> "$dir/err"));
    my $exit = $? >> 8;
    return ($exit, slurp("$dir/out") // '', slurp("$dir/err") // '');
}

sub driver_env {
    my ($f) = @_;
    return { CCPRAXIS_DRIVE_ACTIVE_DIR => $f->{active}, CCPRAXIS_DATA_DIR => $f->{data}, HOME => $f->{home} };
}

sub payload {
    my (%o) = @_;
    my %p = (
        hook_event_name => 'PreToolUse',
        tool_name       => 'Agent',
        session_id      => $o{session} // 'sess-driver',
        tool_use_id     => exists $o{tuid} ? $o{tuid} : 'toolu_01AbCdEf',
        cwd             => $o{cwd} // '/nonexistent',
        tool_input      => { subagent_type => $o{type} // 'butler:bp-implementer', prompt => 'do it', description => 'x' },
    );
    delete $p{tool_use_id} unless defined $p{tool_use_id};
    return \%p;
}

sub silent_ok {
    my ($exit, $out, $err, $label) = @_;
    is($exit, 0, "$label: exit 0");
    is($out, '', "$label: stdout empty");
    is($err, '', "$label: stderr empty");
}

subtest 'registered as a PreToolUse hook on the Agent tool' => sub {
    my $h = $J->decode(slurp($HJSON));
    my @hits = grep {
        my $m = $_->{matcher} // '';
        (grep { ($_->{command} // '') =~ m{/hooks/record-dispatch-package\.sh"} } @{ $_->{hooks} // [] })
            && $m =~ /(?:\A|\|)Agent(?:\||\z)/ && $m =~ /(?:\A|\|)Task(?:\||\z)/
    } @{ $h->{hooks}{PreToolUse} // [] };
    is(scalar(@hits), 1, 'exactly one PreToolUse entry runs it, matching both Agent and Task');
};

subtest 'driver session: its own dispatch is recorded with the current package' => sub {
    my $f = driver_fixture();
    my @r = run_hook(payload(), driver_env($f));
    silent_ok(@r, 'driver');
    my $recs = records($f->{data});
    is(scalar(@$recs), 1, 'one record appended');
    my $rec = $recs->[0];
    is($rec->{tool_use_id}, 'toolu_01AbCdEf', 'keyed by the payload tool_use_id');
    is($rec->{blueprint}, 'demo-bp', 'blueprint from the director pointer');
    is($rec->{package}, '03-thing', 'package from the director pointer');
    is($rec->{source}, 'driver-pointer', 'source names the mechanism');
    is($rec->{session_id}, 'sess-driver', 'session recorded');
    is($rec->{subagent_type}, 'butler:bp-implementer', 'subagent type recorded verbatim');
    like($rec->{at}, qr/\A[1-9][0-9]{8,}\z/, 'epoch timestamp');

    run_hook(payload(tuid => 'toolu_02Second', type => 'general-purpose'), driver_env($f));
    is(scalar(@{ records($f->{data}) }), 2, 'every Agent type is recorded, not only bp-* workers');
};

subtest 'a different session in the same project is not the driver' => sub {
    my $f = driver_fixture(markers => ['sess-driver']);
    my @r = run_hook(payload(session => 'sess-other'), driver_env($f));
    silent_ok(@r, 'other session');
    is(scalar(@{ records($f->{data}) }), 0, 'nothing recorded for a session without its own marker');
};

subtest 'no drive active: nothing is recorded' => sub {
    my $f = driver_fixture(markers => []);
    my @r = run_hook(payload(), driver_env($f));
    silent_ok(@r, 'idle');
    ok(!-e "$f->{data}/.dispatch-log", 'the dispatch-log dir is not even created');
};

subtest 'a stale director pointer attributes nothing' => sub {
    my $f = driver_fixture(recorded_at => time - 6 * 3600);
    my @r = run_hook(payload(), driver_env($f));
    silent_ok(@r, 'stale pointer');
    is(scalar(@{ records($f->{data}) }), 0, 'bp_driver_context refuses a pointer past its TTL');
};

subtest 'tool_use_id must be present and path/JSON-safe' => sub {
    my $f = driver_fixture();
    for my $bad (undef, '', 'toolu_"x', 'toolu/../x', 'a' x 200) {
        my @r = run_hook(payload(tuid => $bad), driver_env($f));
        silent_ok(@r, 'bad tool_use_id ' . (defined $bad ? "'" . substr($bad, 0, 12) . "'" : 'absent'));
    }
    is(scalar(@{ records($f->{data}) }), 0, 'no record for any of them');
};

subtest 'coordinator: the package comes from its own environment' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    my %env = (BP_LEDGER => "$root/ledger.md", BP_BLUEPRINT => 'fleet-bp', BP_PACKAGE => '07-x',
               BP_PROJECT_ROOT => $root, HOME => "$root/home");
    my @r = run_hook(payload(session => 'sess-coord'), \%env);
    silent_ok(@r, 'coordinator');
    my $recs = records("$root/.ccpraxis-local-data");
    is(scalar(@$recs), 1, 'one record');
    is($recs->[0]{blueprint}, 'fleet-bp', 'BP_BLUEPRINT');
    is($recs->[0]{package}, '07-x', 'BP_PACKAGE');
    is($recs->[0]{source}, 'coordinator-env', 'source');

    for my $bad ('../evil', '.hidden', "a\nb", 'a"b') {
        my @r2 = run_hook(payload(session => 'sess-coord', tuid => 'toolu_bad'),
                          { %env, BP_PACKAGE => $bad });
        silent_ok(@r2, "coordinator bad package");
    }
    is(scalar(@{ records("$root/.ccpraxis-local-data") }), 1, 'no record for an unsafe name');
};

subtest 'BP_DISPATCH_LOG_OFF=1 turns recording off' => sub {
    my $f = driver_fixture();
    my @r = run_hook(payload(), { %{ driver_env($f) }, BP_DISPATCH_LOG_OFF => '1' });
    silent_ok(@r, 'log off');
    is(scalar(@{ records($f->{data}) }), 0, 'nothing recorded');
};

subtest 'past 8 MiB the file rolls over and the new record survives' => sub {
    my $f = driver_fixture();
    my $file = "$f->{data}/.dispatch-log/attribution.jsonl";
    my $old = ('{"x":1}' . "\n") x (8 * 1024 * 1024 / 8 + 1);
    write_file($file, $old);
    my @r = run_hook(payload(), driver_env($f));
    silent_ok(@r, 'rollover');
    is(-s "$file.1", length($old), 'the full file moved to .1');
    my $recs = records($f->{data});
    is(scalar(@$recs), 1, 'the live file holds just the new record');
    is($recs->[0]{tool_use_id}, 'toolu_01AbCdEf', 'and it is the new one');
};

subtest 'garbage on stdin never blocks or speaks' => sub {
    my $f = driver_fixture();
    my @r = run_hook('{not json', driver_env($f));
    silent_ok(@r, 'garbage payload');
    is(scalar(@{ records($f->{data}) }), 0, 'nothing recorded');
};

done_testing();
