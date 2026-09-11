#!/usr/bin/env perl
# 190 — `host-only: true` on the plugin path.
#
# WHAT WAS WRONG
#
# There are two paths that put a skill into a container, and the marker was
# honored on one of them. skills.pl's skill_host_only_status() parses the
# frontmatter, and discover_skills() drops a host-only STANDALONE skill. Plugin-
# shipped skills come in through plugin SELECTION instead — discover_plugins()
# ranks installs by scope and project match and never opens a SKILL.md, so it
# could not see the marker. Nine skills across three plugins declared themselves
# host-only and were mounted anyway, including /sandbox:setup (whose body is
# "exit this session and run claude-sandbox from a terminal") and /sandbox:test
# (which needs a container runtime the image does not ship).
#
# TWO MECHANISMS, BECAUSE THERE ARE TWO KINDS OF PLUGIN
#
#   * ALL skills host-only -> discover_plugins drops the plugin. Nothing is left
#     to offer. sandbox and todo are this case.
#   * MIXED -> the host-only skill dirs are MASKED. steward ships setup-project
#     and audit, which belong in a container, alongside four that do not. A
#     directory-source marketplace is bind-mounted live and read-only, so there
#     is no copy to leave a skill out of; the launcher binds an empty dir over
#     each host-only skill dir instead, leaving a directory with no SKILL.md.
#
# A THIRD THING THIS PINS: installPath is not where the files are. Claude Code
# records plugins/cache/<marketplace>/<plugin>/<version> for every install but
# never populates that cache for a directory-source marketplace — it resolves
# from the marketplace's source.path. So a census keyed on installPath alone
# reports ZERO skills for exactly the plugins whose skills need judging. That is
# what plugin_source_dir() exists for, and AC4 is its regression lock.
#
# AC1  a plugin whose skills are ALL host-only is dropped from discovery
# AC2  a MIXED plugin survives, carrying the names of its host-only skills
# AC3  a plugin with NO skills is untouched (hooks/agents/scripts-only plugins)
# AC4  a plugin whose installPath does not exist still gets censused, via the
#      directory-source marketplace's source.path
# AC5  host-only-masks emits one container path per host-only skill of a
#      SELECTED live-bound plugin, and nothing for an unselected one
# AC6  the launcher pushes each mask AFTER the marketplace bind it nests inside
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

my $SKILLS_PL = "$Bin/../../scripts/skills.pl";
my $LAUNCHER  = "$Bin/../../scripts/launcher.pl";
ok(-f $SKILLS_PL, 'skills.pl present') or BAIL_OUT('no skills.pl');

# ── a throwaway HOME with its own marketplace, plugins and registry ────────
my $root = tempdir(CLEANUP => 1);
my $home = "$root/home";
my $mkt  = "$root/marketplace";       # the directory-source marketplace

sub write_file {
    my ($path, $body) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $body;
    close $fh;
}

sub write_skill {
    my ($plugin, $name, $host_only) = @_;
    my $fm = "---\nname: $name\ndescription: fixture\n"
           . ($host_only ? "host-only: true\n" : "")
           . "---\n\n# $name\n";
    write_file("$mkt/$plugin/skills/$name/SKILL.md", $fm);
}

sub write_plugin_manifest {
    my ($plugin) = @_;
    write_file("$mkt/$plugin/.claude-plugin/plugin.json",
               qq({\n  "name": "$plugin",\n  "version": "0.1.0"\n}\n));
}

# allhost: every skill host-only.  mixed: two of three.  noskills: none at all.
write_plugin_manifest($_) for qw(allhost mixed noskills);
write_skill('allhost', 'alpha',  1);
write_skill('allhost', 'beta',   1);
write_skill('mixed',   'keeper', 0);
write_skill('mixed',   'gone-a', 1);
write_skill('mixed',   'gone-b', 1);
make_path("$mkt/noskills/hooks");

write_file("$mkt/.claude-plugin/marketplace.json", JSON::PP->new->pretty->encode({
    name    => 'fixture-local',
    plugins => [
        { name => 'allhost',  source => './allhost'  },
        { name => 'mixed',    source => './mixed'    },
        { name => 'noskills', source => './noskills' },
    ],
}));

write_file("$home/.claude/plugins/known_marketplaces.json", JSON::PP->new->pretty->encode({
    'fixture-local' => { source => { source => 'directory', path => $mkt } },
}));

# Every installPath below points at a cache dir that does NOT exist — exactly
# what Claude Code records for a directory-source marketplace (AC4).
my $project = "$root/project";
make_path($project);
my $fake_cache = "$home/.claude/plugins/cache/fixture-local";
write_file("$home/.claude/plugins/installed_plugins.json", JSON::PP->new->pretty->encode({
    plugins => {
        'allhost@fixture-local'  => [ { scope => 'user', version => '0.1.0',
                                        installPath => "$fake_cache/allhost/0.1.0" } ],
        'mixed@fixture-local'    => [ { scope => 'user', version => '0.1.0',
                                        installPath => "$fake_cache/mixed/0.1.0" } ],
        'noskills@fixture-local' => [ { scope => 'user', version => '0.1.0',
                                        installPath => "$fake_cache/noskills/0.1.0" } ],
    },
}));
ok(!-d "$fake_cache/mixed/0.1.0",
   'fixture: the recorded installPath genuinely does not exist');

# ── run a skills.pl subcommand under that HOME ─────────────────────────────
sub run_skills {
    my (@args) = @_;
    local $ENV{HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    open my $ph, '-|', $^X, $SKILLS_PL, @args or die "spawn: $!";
    local $/;
    my $out = <$ph>;
    close $ph;
    return defined $out ? $out : '';
}

my $raw = run_skills('discover-plugins', '--project-path', $project);
my $found = eval { JSON::PP->new->decode($raw) };
ok(ref $found eq 'ARRAY', 'discover-plugins returned JSON') or diag("raw: $raw");
my %by_key = map { $_->{key} => $_ } @{ $found || [] };

# AC1 — all-host-only plugin is gone
ok(!exists $by_key{'allhost@fixture-local'},
   'AC1 a plugin whose skills are all host-only is dropped from discovery');

# AC2 — mixed plugin survives and names its host-only skills
ok(exists $by_key{'mixed@fixture-local'}, 'AC2 a mixed plugin survives discovery');
if (my $m = $by_key{'mixed@fixture-local'}) {
    is($m->{skills_total}, 3, 'AC2 census counted every skill with a SKILL.md');
    is_deeply($m->{host_only_skills}, ['gone-a', 'gone-b'],
              'AC2 the host-only skills are named, sorted');
}

# AC3 — a plugin with no skills is not judged
ok(exists $by_key{'noskills@fixture-local'},
   'AC3 a plugin that ships no skills is not dropped');
if (my $n = $by_key{'noskills@fixture-local'}) {
    is($n->{skills_total}, 0, 'AC3 no skills counted');
    is_deeply($n->{host_only_skills}, [], 'AC3 nothing reported host-only');
}

# AC4 — the census reached the real files despite the dead installPath
if (my $m = $by_key{'mixed@fixture-local'}) {
    cmp_ok($m->{skills_total}, '>', 0,
           'AC4 census resolved through the directory-source marketplace, not installPath');
}

# ── AC5 — masks for the selected set ──────────────────────────────────────
my $sel = "$root/selected.json";
write_file($sel, JSON::PP->new->encode({
    schema_version            => 1,
    selected                  => [],
    selected_plugins          => ['mixed@fixture-local'],
    mounted_at_create         => [],
    mounted_plugins_at_create => [],
}));

my $masks = eval {
    JSON::PP->new->decode(
        run_skills('host-only-masks', '--selection-file', $sel,
                   '--project-path', $project))
};
ok(ref $masks eq 'ARRAY', 'AC5 host-only-masks returned JSON');
is(scalar @{ $masks || [] }, 2,
   'AC5 one mask per host-only skill of the selected plugin');
is_deeply([ sort map { $_->{container_path} } @{ $masks || [] } ],
          [ '/root/.claude/plugins/marketplaces/fixture-local/mixed/skills/gone-a',
            '/root/.claude/plugins/marketplaces/fixture-local/mixed/skills/gone-b' ],
          'AC5 mask paths are container paths under the marketplace bind target');

# Nothing selected -> nothing masked. The counter-check that AC5 is keyed on
# selection and not merely on "this plugin has host-only skills".
write_file($sel, JSON::PP->new->encode({
    schema_version            => 1,
    selected                  => [],
    selected_plugins          => [],
    mounted_at_create         => [],
    mounted_plugins_at_create => [],
}));
my $none = eval {
    JSON::PP->new->decode(
        run_skills('host-only-masks', '--selection-file', $sel,
                   '--project-path', $project))
};
is_deeply($none, [], 'AC5 an unselected plugin contributes no masks');

# ── AC6 — the launcher nests each mask inside the marketplace bind ────────
SKIP: {
    skip 'launcher.pl not present', 4 unless -f $LAUNCHER;
    open my $fh, '<:raw', $LAUNCHER or skip 'cannot read launcher.pl', 4;
    local $/;
    my $src = <$fh>;
    close $fh;

    like($src, qr/host-only-masks/,
         'AC6 launcher runs the host-only-masks subcommand');
    like($src, qr/EMPTY_SKILL_DIR/,
         'AC6 launcher binds a shared empty directory over each mask');

    # Ordering is the whole correctness argument: a mask bound BEFORE the
    # marketplace bind it nests inside would be shadowed by it.
    my $bind_at = index($src, "host_path}:\${container_path}:ro");
    my $mask_at = index($src, "host-only mask discovery");
    cmp_ok($bind_at, '>=', 0, 'AC6 found the marketplace bind in launcher.pl');
    cmp_ok($mask_at, '>', $bind_at,
           'AC6 masks are pushed after the marketplace bind they nest inside');
}

done_testing();
