#!/usr/bin/env perl
# platform: any
# The drive-solo write-guards (guard-writes.sh, ledger-guard.sh) act only for
# the session that is DRIVING -- the one holding its own driver marker -- and
# its subagents, which report their parent's session_id. A second session in
# the same project is not held to the run's current package.
#
# Regression: on 2026-09-23 an interactive session was refused every
# Edit/Write outside almanac-records/06's write set while another session
# drove that package, because bp_driver_context asked only "is any drive
# active in this project".
#
# Hermetic: data dir, marker registry and HOME are tempdirs under this test's
# own directory (NOT /tmp, which guard-writes.sh always allows, and which
# would make every write pass for the wrong reason), and every ambient BP_* /
# guards-off variable is stripped.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);

my $HOOKS = "$Bin/../../hooks";
my $GW    = "$HOOKS/guard-writes.sh";
my $LG    = "$HOOKS/ledger-guard.sh";
ok(-f $GW && -f $LG, 'both guards exist') or BAIL_OUT('missing guard');

my $BASE = "$Bin/.driver-context-session-scope-scratch";
make_path($BASE);
$ENV{TMPDIR} = $BASE;
END { remove_tree($BASE) if $BASE && -d $BASE }

my $J = JSON::PP->new->canonical;
my %CLEAN = map { ($_ => $ENV{$_}) }
            grep { !/^BP_/ && !/^CCPRAXIS_DRIVER_GUARDS_OFF/ && $_ ne 'CLAUDE_PROJECT_DIR' } keys %ENV;

sub write_file {
    my ($p, $s) = @_;
    make_path(dirname($p));
    open my $w, '>:raw', $p or die "$p: $!";
    print $w $s;
    close $w;
}

# A running package whose write set is src/ only, the director's fresh
# pointer to it, and a registry where only sess-driver holds a marker.
sub fixture {
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    write_file("$data/blueprints/demo-bp/blueprint.md", "# demo-bp\n");
    write_file("$data/blueprints/demo-bp/packages/01-a.md",
        "---\npackage: 01-a\nblueprint: demo-bp\nstatus: running\nwrite_set: src/\ntest_paths: t/\n"
      . "last_updated: 2025-01-01T00:00:00Z\n---\n\n## Next action\nx\n");
    write_file("$data/.drive-solo/current.json",
        $J->encode({ blueprint => 'demo-bp', package => '01-a', recorded_at => time }));
    write_file("$root/registry/sess-driver", "$data\n");
    make_path("$root/home");
    return { root => $root, data => $data, reg => "$root/registry", home => "$root/home" };
}

sub run_guard {
    my ($hook, $fx, $payload) = @_;
    my $in  = "$fx->{root}/in.json";
    my $out = "$fx->{root}/out.txt";
    write_file($in, $J->encode($payload));
    local %ENV = (%CLEAN, CCPRAXIS_DATA_DIR => $fx->{data},
                  CCPRAXIS_DRIVE_ACTIVE_DIR => $fx->{reg}, HOME => $fx->{home});
    system(qq(bash "$hook" < "$in" > "$out" 2>&1));
    my $rc = $? >> 8;
    open my $r, '<', $out; local $/; my $o = <$r> // ''; close $r;
    return ($rc, $o);
}

sub write_payload {
    my ($fx, $rel, $sid) = @_;
    my %p = (hook_event_name => 'PreToolUse', tool_name => 'Write', cwd => $fx->{root},
             tool_input => { file_path => "$fx->{root}/$rel", content => 'x' });
    $p{session_id} = $sid if defined $sid;
    return \%p;
}

subtest 'guard-writes: only the driving session is held to the write set' => sub {
    my $fx = fixture();
    my ($rc_in) = run_guard($GW, $fx, write_payload($fx, 'src/ok.pl', 'sess-driver'));
    is($rc_in, 0, 'driver, inside the write set: allowed');

    my ($rc_out, $o) = run_guard($GW, $fx, write_payload($fx, 'other/x.txt', 'sess-driver'));
    is($rc_out, 2, 'driver (or its subagent, same session_id), outside the write set: blocked')
        or diag($o);

    my ($rc_other, $o2) = run_guard($GW, $fx, write_payload($fx, 'other/x.txt', 'sess-someone-else'));
    is($rc_other, 0, 'another session in the same project: not held to the run\'s package') or diag($o2);

    my ($rc_none) = run_guard($GW, $fx, write_payload($fx, 'other/x.txt', undef));
    is($rc_none, 2, 'a payload with no session_id keeps the old any-drive-active behaviour');
};

subtest 'ledger-guard: the same scope' => sub {
    my $fx = fixture();
    my $ledger = '.ccpraxis-local-data/blueprints/demo-bp/packages/01-a.md';
    my $bad = { hook_event_name => 'PreToolUse', tool_name => 'Write', cwd => $fx->{root},
                tool_input => { file_path => "$fx->{root}/$ledger", content => "not a ledger\n" } };
    my ($rc_drv, $o) = run_guard($LG, $fx, { %$bad, session_id => 'sess-driver' });
    is($rc_drv, 2, 'driver writing a corrupt ledger: blocked') or diag($o);
    my ($rc_other, $o2) = run_guard($LG, $fx, { %$bad, session_id => 'sess-someone-else' });
    is($rc_other, 0, 'another session: this guard does not apply') or diag($o2);
};

done_testing();
