#!/usr/bin/env perl
# platform: any
# Oracle for the lifecycle gate in bp-drive-next.pl: a blueprint that has not
# been AUDITED is never handed out as work.
#
# THE DEFECT, measured on the host 2026-09-18. bp-drive-next.pl's USAGE block
# documents `--scope all` as "all audited blueprints", but candidate discovery
# was an unfiltered directory listing -- nothing anywhere read blueprint.md's own
# `status:`. The director returned
#   {"action":"run-package","blueprint":"butler-gate-ergonomics","package":"01-..."}
# for a blueprint sitting at `status: drafting`.
#
# The second-order cost is what made it expensive rather than merely wrong.
# `next` is invoked from the Stop hook on every turn end; wait-shape-guard.sh
# activates the runstate whenever it sees a run-package verdict come back; and
# keepawake_apply('active') re-spawns the Windows wake-lock on every tick. So a
# drafting blueprint held the machine awake for hours, re-arming itself after the
# helper was killed, on a run whose runstate said `finished`.
#
# TWO FILTERS, BOTH LOAD-BEARING, and that is the point of AC-2. Filtering
# candidate resolution alone does not fix it: the B3 walk iterates @$order, not
# @candidates, so a blueprint already recorded in order.json is visited whatever
# the scope resolved to -- which is exactly how the real order.json was shaped.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/bp-drive-next.pl";
my $LOADED = do { local $@; eval { require $SCRIPT }; !$@ };
ok($LOADED, 'bp-drive-next.pl loads') or diag($@);

my $NOW = 1_830_297_600;
my $J   = JSON::PP->new->canonical;

# make_bp_dir($data, $name, $lifecycle, \@pkgs)
#   $lifecycle: 'audited' | 'drafting' | 'archived' | undef (omit the line entirely)
sub make_bp_dir {
    my ($data, $name, $lifecycle, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n";
    $md .= "status: $lifecycle\n\n" if defined $lifecycle;
    $md .= "## Package status\n\n"
         . "| pkg | deliverable | depends_on | model | status |\n"
         . "|-----|-------------|------------|-------|--------|\n";
    $md .= "| $_->{key} | thing | -- | sonnet | $_->{status} |\n" for @$pkgs;
    open my $bfh, '>:raw', "$bp/blueprint.md" or die "blueprint.md: $!";
    print $bfh $md;
    close $bfh;
    for my $p (@$pkgs) {
        my $ws = $p->{write_set} // "blueprints/$name/$p->{key}/";
        open my $lfh, '>:raw', "$bp/packages/$p->{key}.md" or die "ledger: $!";
        print $lfh "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
                 . "model: sonnet\nmax_turns: 80\nwrite_set: $ws\n"
                 . "test_paths: $ws\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n";
        close $lfh;
    }
    return $bp;
}

sub write_json {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "write_json $path: $!";
    print $fh $J->encode($data);
    close $fh;
}

# Reopening STDOUT onto an in-memory scalar fails on Git-for-Windows perl
# ("Bad file descriptor"), so capture via a real temp file.
sub capture_run {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    my ($ofh, $opath) = tempfile('lifecycle-outXXXXXX', TMPDIR => 1);
    close $ofh;
    open my $oldout, '>&STDOUT' or die "dup: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen: $!" };
    $| = 1;
    my $rc  = eval { BpDrive::run($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore: $!";
    close $oldout;
    my $out = do { open my $r, '<:raw', $opath or die $!; local $/; my $x = <$r>; close $r; $x // '' };
    unlink $opath;
    die $err if $err;
    chomp $out;
    return ($rc, $out);
}

sub action_of {
    my $o = shift;
    my @lines = grep { /\S/ } split /\n/, $o;
    return eval { $J->decode($lines[-1] // '') };
}

# AC-1: a drafting blueprint is not a candidate
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-ready', 'audited',  [{key=>'p1', status=>'pending', write_set=>'ready/'}]);
    make_bp_dir($data, 'bp-draft', 'drafting', [{key=>'q1', status=>'pending', write_set=>'draft/'}]);
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = action_of($out);
    is($rc, 0, 'AC-1: exits 0');
    is($act->{action}, 'need-order', 'AC-1: need-order with no order.json');
    ok( (grep { $_ eq 'bp-ready' } @{ $act->{candidates} || [] }),
        'AC-1: audited blueprint IS a candidate');
    ok(!(grep { $_ eq 'bp-draft' } @{ $act->{candidates} || [] }),
        'AC-1: drafting blueprint is NOT a candidate');
}

# AC-2: the walk skips it even when order.json already names it.
# This is the one a resolve_scope-only fix would fail: B3 iterates @$order.
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-draft', 'drafting', [{key=>'q1', status=>'pending', write_set=>'draft/'}]);
    make_bp_dir($data, 'bp-ready', 'audited',  [{key=>'p1', status=>'pending', write_set=>'ready/'}]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    # drafting one FIRST in the order, so a walk that did not skip would hit it first.
    write_json("$dsdir/order.json", { order => ['bp-draft','bp-ready'], recorded_at => $NOW });
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = action_of($out);
    is($act->{action}, 'run-package', 'AC-2: still hands out real work');
    is($act->{blueprint}, 'bp-ready', 'AC-2: drives the AUDITED blueprint');
    isnt($act->{blueprint}, 'bp-draft', 'AC-2: never drives the drafting one');

    my $log = do { open my $r, '<', "$dsdir/run.md" or die $!; local $/; <$r> };
    like($log, qr/NOT-AUDITED.*bp-draft/,
        'AC-2: the skip is recorded in run.md, not silent');
}

# AC-3: archived is excluded on the same rule
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-old',   'archived', [{key=>'q1', status=>'pending', write_set=>'old/'}]);
    make_bp_dir($data, 'bp-ready', 'audited',  [{key=>'p1', status=>'pending', write_set=>'ready/'}]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-old','bp-ready'], recorded_at => $NOW });
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = action_of($out);
    is($act->{blueprint}, 'bp-ready', 'AC-3: archived blueprint is not driven');
}

# AC-4: FAILS OPEN -- no status line at all stays drivable.
# Every pre-existing fixture in this suite writes a blueprint.md with no
# `status:` line, and real blueprints predate the field. Failing closed here
# would stall every one of them, which is the strictly worse error.
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-nostatus', undef, [{key=>'p1', status=>'pending', write_set=>'ns/'}]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-nostatus'], recorded_at => $NOW });
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = action_of($out);
    is($act->{action}, 'run-package', 'AC-4: no status line -> still drivable');
    is($act->{blueprint}, 'bp-nostatus', 'AC-4: drives it');
}

# AC-5: unknown status also fails open
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-weird', 'frobnicated', [{key=>'p1', status=>'pending', write_set=>'w/'}]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-weird'], recorded_at => $NOW });
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = action_of($out);
    is($act->{action}, 'run-package', 'AC-5: unrecognised status -> drivable (fail open)');
}

# AC-6: the pure predicates
{
    is(BpDrive::blueprint_drivable('audited'),  1, 'AC-6: audited is drivable');
    is(BpDrive::blueprint_drivable('drafting'), 0, 'AC-6: drafting is not');
    is(BpDrive::blueprint_drivable('archived'), 0, 'AC-6: archived is not');
    is(BpDrive::blueprint_drivable('AUDITED'),  1, 'AC-6: case-insensitive');
    is(BpDrive::blueprint_drivable('Drafting'), 0, 'AC-6: case-insensitive for deny too');
    is(BpDrive::blueprint_drivable(''),         1, 'AC-6: empty fails open');
    is(BpDrive::blueprint_drivable(undef),      1, 'AC-6: undef fails open');

    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-l', 'drafting', [{key=>'p1', status=>'pending'}]);
    is(BpDrive::blueprint_lifecycle("$data/blueprints/bp-l"), 'drafting',
        'AC-6: lifecycle reads blueprint.md status');
    is(BpDrive::blueprint_lifecycle("$data/blueprints/nope"), '',
        'AC-6: missing blueprint.md -> empty (fail open)');
}

# AC-7: a `status:` far down the file is prose, not the declaration
{
    my $data = tempdir(CLEANUP => 1);
    my $bp = make_bp_dir($data, 'bp-late', 'audited', [{key=>'p1', status=>'pending'}]);
    open my $fh, '>>', "$bp/blueprint.md" or die $!;
    print $fh "\n" . ("filler line\n" x 60) . "status: drafting\n";
    close $fh;
    is(BpDrive::blueprint_lifecycle($bp), 'audited',
        'AC-7: only the frontmatter declaration counts');
}

done_testing();
