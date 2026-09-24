#!/usr/bin/env perl
# platform: any
# Every perl command that global-config/settings.json registers (hooks and the
# statusline) must use the guarded form
#   f="<script>"; [ -f "$f" ] || exit 0; exec perl "$f"
# because a bare `perl "<script>"` exits 2 when the script is missing, and
# Claude Code reads exit 2 from a PreToolUse hook as a BLOCK. With the live
# install absent or mid-move, every Bash and Edit/Write call in every project
# would be refused. Measured 2026-09-23 (hook-continuity-remake package 01,
# red-team H1): `perl /missing.pl` exits 2, `bash /missing.sh` exits 127. The
# guarded form keeps a present script's own exit code, including a deliberate
# exit 2.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $settings = "$Bin/../../../../global-config/settings.json";
ok(-f $settings, 'global-config/settings.json exists') or BAIL_OUT('no settings');
my $doc = do { open my $f, '<:raw', $settings or die $!; local $/; JSON::PP->new->decode(<$f>) };

my @commands;
for my $event (sort keys %{ $doc->{hooks} || {} }) {
    for my $group (@{ $doc->{hooks}{$event} }) {
        push @commands, [ "$event hook", $_->{command} ] for grep { defined $_->{command} } @{ $group->{hooks} || [] };
    }
}
push @commands, [ 'statusLine', $doc->{statusLine}{command} ] if ref $doc->{statusLine} && defined $doc->{statusLine}{command};

my $GUARDED = qr{\Af="([^"]+\.pl)"; \[ -f "\$f" \] \|\| exit 0; exec perl "\$f"\z};
my @perl = grep { $_->[1] =~ /\bperl\b/ } @commands;
cmp_ok(scalar @perl, '>=', 1, 'the payload registers at least one perl command');
for my $c (@perl) {
    like($c->[1], $GUARDED, "$c->[0] uses the guarded form: $c->[1]");
}

# The guarded form itself: a missing script allows (exit 0), and a present
# script's own exit code, including a deliberate block, passes through.
my $dir = tempdir(CLEANUP => 1);
open my $w, '>', "$dir/blocker.pl" or die; print $w "exit 2;\n"; close $w;
my $form = sub { my ($p) = @_; qq{f="$p"; [ -f "\$f" ] || exit 0; exec perl "\$f"} };
my $run  = sub { my ($cmd) = @_; system('bash', '-c', $cmd); return $? >> 8 };
is($run->($form->("$dir/no-such-script.pl")), 0, 'guarded form: a missing script exits 0 (does not block)');
is($run->($form->("$dir/blocker.pl")), 2, 'guarded form: a present script that blocks still exits 2');
isnt($run->(qq{perl "$dir/no-such-script.pl" 2>/dev/null}), 0, 'contrast: the bare form fails on a missing script');

done_testing();
