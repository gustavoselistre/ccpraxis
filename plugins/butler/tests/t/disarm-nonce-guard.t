#!/usr/bin/env perl
# platform: windows
# Bug report 20260922-233054-9a5d: bp-continuity.pl's cmd_disarm reads a
# beacon-derived nonce and uses it -- with no BpSession::valid_nonce guard --
# both as an existence check and as an unlink path. Same shape as the
# already-fixed redteam MEDIUM-1 sites (cmd_status's $nonce,
# report_and_consume_prior_unbound's $prior), just never dispatched to this
# third site.
#
# Repro, mirroring MEDIUM-1's own demonstrated shape: a beacon holding
# "../../victim.txt" makes "$dir/pending/$nonce" resolve OUTSIDE the pending/
# subdirectory entirely -- a sibling of the registry root -- so an unguarded
# disarm deletes an arbitrary file there.

use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK -- bp-continuity.pl is driven as
# a subprocess below, where bp-keepawake.pl's `$0 =~ /\.t\z/` guard cannot
# reach. CCPRAXIS_NO_WAKELOCK is the supported opt-out and IS inherited
# across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $SCRIPT = "$Bin/../../scripts/bp-continuity.pl";
ok(-f $SCRIPT, 'setup: bp-continuity.pl exists') or BAIL_OUT('script missing -- nothing else here can run');

sub run_cli {
    my ($args, $env_extra) = @_;
    $env_extra //= {};
    local %ENV = %ENV;
    for my $k (sort keys %$env_extra) {
        my $v = $env_extra->{$k};
        if (!defined $v) { delete $ENV{$k} }
        else              { $ENV{$k} = $v }
    }
    my $argstr = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @$args;
    my $out = `perl "$SCRIPT" $argstr 2>&1`;
    my $rc = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}

sub kv {
    my ($out, $key) = @_;
    return $1 if $out =~ /^\Q$key\E:\s*(.*)$/m;
    return undef;
}

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    return <$fh>;
}

# ===========================================================================
# A path-traversal nonce in the beacon must not reach outside pending/ --
# neither for the existence check nor for the unlink.
# ===========================================================================
{
    my $reg    = tempdir(CLEANUP => 1);
    my $parent = dirname($reg);
    my $victim = "$parent/disarm-nonce-guard-victim-$$.txt";
    write_file($victim, "do not delete me\n");
    # "pending" must exist as a REAL directory for the ".." traversal below to
    # resolve at all (most filesystems refuse to stat/unlink through a
    # nonexistent intermediate component) -- arm itself never creates it, so
    # this mirrors what a live registry actually has once any ticket ever
    # existed, not a hypothetical.
    make_path("$reg/pending");

    my $sid = 'sess-disarm-traversal';
    # continuity_marker/beacon_path key rules forbid '.', '*', '/', '\' in the
    # SESSION id and the CLAUDE_CODE_SESSION_ID beacon key respectively, but
    # place NO constraint on the beacon's own file CONTENT -- that content is
    # exactly what report 20260922-233054-9a5d says reaches a path unvalidated.
    write_file("$reg/beacons/$sid", "../../" . "disarm-nonce-guard-victim-$$.txt\n");

    # Arm the session for real so cmd_disarm's normal (valid) path also runs
    # and the marker exists -- this is not testing the ticket-only branch.
    my ($aout, $arc) = run_cli(['arm', '--session', $sid, '--by', 'agent'],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, CLAUDE_CODE_SESSION_ID => $sid, BP_LEDGER => undef });
    is($arc, 0, 'setup: arm succeeds so disarm runs its real path, not the invalid-id refusal');
    is(kv($aout, 'STATUS'), 'armed', 'setup: STATUS: armed');

    my ($dout, $drc) = run_cli(['disarm', '--session', $sid],
        { CCPRAXIS_CONTINUITY_ACTIVE_DIR => $reg, CLAUDE_CODE_SESSION_ID => $sid });

    ok(-f $victim, 'the traversal target survives disarm -- an invalid nonce must never be treated '
                 . 'as a path component, not for the existence check and not for the unlink')
        or diag("disarm output:\n$dout\nrc=$drc");
    is(slurp($victim), "do not delete me\n",
       'the traversal target\'s content is also untouched (not merely re-created)');

    is($drc, 0, 'disarm itself still exits 0 (the session really was armed and really gets disarmed)');
    is(kv($dout, 'STATUS'), 'disarmed', 'disarm reports STATUS: disarmed for the genuinely-armed session');
}

done_testing();
