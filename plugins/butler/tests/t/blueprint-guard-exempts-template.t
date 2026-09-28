#!/usr/bin/env perl
# platform: any
# guard-blueprint-write.sh matched `*/blueprint.md`, which also matched the
# TEMPLATE at plugins/blueprint/templates/blueprint.md.
#
# That left the template maintainable through no sanctioned path at all. The
# guard's own remediation text points at bp-blueprint.pl's typed verbs, and none
# of them can touch a template: `init` REFUSES to overwrite an existing file (by
# design -- an existing blueprint is somebody's initiative), and `add-package`
# would splice a real package row into it. The only remaining route was `cp`
# through Bash, which is exactly the hand-splice the guard exists to prevent.
#
# Surfaced while fixing report 20260917-063908-db14: the template still told the
# author to emit a `depends_on:` key that bp-ledger.pl now rejects on every
# write, and the correction could not be applied.
#
# The exemption must stay narrow. A real blueprint lives at
# <data>/blueprints/<name>/blueprint.md and never under plugins/*/templates/, so
# the pattern requires the plugins/<plugin>/templates/ shape -- the looser
# */templates/blueprint.md would exempt a blueprint someone named "templates".
#
# This guard deliberately does NOT call bp_hook_gate (see its header), so no BP_*
# env is set up here; it runs in any session.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use HostCaps qw(tempdir_args);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-blueprint-write.sh";
ok(-f $GUARD, 'guard-blueprint-write.sh is present') or BAIL_OUT("no guard at $GUARD");

my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
my $J    = JSON::PP->new->canonical;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $n = 0;
sub fire {
    my ($path) = @_;
    my $pf = "$ROOT/payload." . (++$n) . ".json";
    open my $w, '>', $pf or die "open $pf: $!";
    print $w $J->encode({ tool_name => 'Edit', cwd => '/somewhere',
                          tool_input => { file_path => $path } });
    close $w;
    local %ENV = (%ENV, GPATH => fwd($GUARD), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> };
    close $f;
    return ($? >> 8, $o // '');
}

# ---- the template is editable again -----------------------------------------
{
    my ($rc, $out) = fire('/c/Development/ccpraxis/plugins/blueprint/templates/blueprint.md');
    is($rc, 0, 'the blueprint TEMPLATE is allowed through') or diag("guard said: $out");
}
{
    # Any plugin's template, not just this one -- the rule is structural.
    my ($rc, $out) = fire('/opt/x/plugins/somethingelse/templates/blueprint.md');
    is($rc, 0, 'any plugins/<plugin>/templates/blueprint.md is allowed') or diag("guard said: $out");
}

# ---- and every real blueprint is still denied --------------------------------
{
    my ($rc, $out) = fire('/c/Development/ccpraxis/.ccpraxis-local-data/blueprints/foo/blueprint.md');
    is($rc, 2, 'a real blueprint is still DENIED');
    like($out, qr/BLUEPRINT-GUARD: BLOCKED/, 'and says so');
}
{
    # The narrowness of the exemption is the point: a blueprint whose directory
    # happens to be named "templates" must NOT slip through.
    my ($rc) = fire('/c/proj/.ccpraxis-local-data/blueprints/templates/blueprint.md');
    is($rc, 2, 'a blueprint DIRECTORY named "templates" is still denied');
}
{
    # Nor a templates/ dir that is not inside a plugin.
    my ($rc) = fire('/c/proj/templates/blueprint.md');
    is($rc, 2, 'a bare templates/blueprint.md outside plugins/ is still denied');
}

# ---- unrelated files are untouched, as before --------------------------------
{
    my ($rc) = fire('/c/Development/ccpraxis/plugins/butler/scripts/bp-ledger.pl');
    is($rc, 0, 'a non-blueprint file is still allowed');
}

done_testing();
