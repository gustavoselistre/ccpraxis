#!/usr/bin/env perl
# platform: any
# Oracle for blueprint sandbox-session-ux, package 08-steward-in-sandbox.
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/08-steward-in-sandbox-spec.md
# (17 acceptance criteria, section 4) and Decision 25 (docs/reference.md must
# stop calling ccpraxis-extend host-only; the validate step names the
# phrase claude plugin validate. NOT derived from any implementation of that
# spec -- setup-project/SKILL.md, ccpraxis-extend/SKILL.md and skills.pl's
# selector-note table do not exist yet at the time this file is written.
#
# Every skills.pl child below runs with HOME/USERPROFILE pointed at a
# tempdir (AC15). No launcher.pl, podman or claude process is ever spawned --
# the ccpraxis-extend validation step and gen-readme-tree.pl/promote.pl are
# checked as TEXT inside SKILL.md, never executed (AC17 and the "validation
# command, not a .t assertion" note in spec AC17 apply outside this file).
#
# AC16's cross-file regression list (host-only-plugin-skills.t and friends)
# is validated by the pipeline's own regression step, never by spawning
# another .t file from here -- this file's only own contribution to AC16 is
# a bare perl syntax check on skills.pl itself, not a test run.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use JSON::PP ();

my $SKILLS_PL = "$Bin/../../scripts/skills.pl";
my $LAUNCHER  = "$Bin/../../scripts/launcher.pl";
ok(-f $SKILLS_PL, 'skills.pl present') or BAIL_OUT('no skills.pl');

my $REPO_ROOT     = abs_path("$Bin/../../../..");
my $PLUGINS_DIR   = "$REPO_ROOT/plugins";
my $SETUP_SKILL   = "$PLUGINS_DIR/steward/skills/setup-project/SKILL.md";
my $EXTEND_SKILL  = "$PLUGINS_DIR/steward/skills/ccpraxis-extend/SKILL.md";
my $REFERENCE_MD  = "$REPO_ROOT/docs/reference.md";
my $NOTE_TEXT     = 'only relevant when working on ccpraxis itself';

ok(-f $SETUP_SKILL,  'fixture: setup-project SKILL.md exists in the clone') or BAIL_OUT('no setup-project SKILL.md');
ok(-f $EXTEND_SKILL, 'fixture: ccpraxis-extend SKILL.md exists in the clone') or BAIL_OUT('no ccpraxis-extend SKILL.md');

# ── generic helpers ─────────────────────────────────────────────────────────

sub write_file {
    my ($path, $body) = @_;
    my $dir = $path;
    $dir =~ s{[/\\][^/\\]+$}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $body;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

# Only the frontmatter block, between the first two `^---$` lines — the same
# region skill_host_only_status() itself scans (skills.pl:178-202), so a
# body/code-block mention of "host-only" can never false-positive an
# assertion here either.
sub frontmatter_of {
    my ($body) = @_;
    return $1 if $body =~ /\A---\r?\n(.*?)\r?\n---\r?\n/s;
    return '';
}

# Runs skills.pl as a real child process (list-form open — never a shell
# string), with HOME/USERPROFILE pointed at $home for the duration of the
# call only.
sub run_skills {
    my ($home, @args) = @_;
    local $ENV{HOME}        = $home;
    local $ENV{USERPROFILE} = $home;
    open my $ph, '-|', $^X, $SKILLS_PL, @args or die "spawn: $!";
    local $/;
    my $out = <$ph>;
    close $ph;
    return defined $out ? $out : '';
}

sub decode_or_die {
    my ($raw, $what) = @_;
    my $decoded = eval { JSON::PP->new->decode($raw) };
    ok(defined $decoded, "$what: valid JSON") or diag("raw: $raw");
    return $decoded;
}

# ── shared fixture builders ─────────────────────────────────────────────────
#
# The directory-source marketplace "ccpraxis-local" always points at the
# CLONE's own tracked plugins/ (spec section 4 preamble: "resolved from
# $Bin (tracked source, not operator state)") — so host-only-masks and
# discover-plugins are judged against the real setup-project/ccpraxis-extend
# skills this package edits, not a synthetic stand-in.
sub write_known_marketplaces {
    my ($home, %extra) = @_;
    my %mkts = (
        'ccpraxis-local' => { source => { source => 'directory', path => $PLUGINS_DIR } },
        %extra,
    );
    write_file("$home/.claude/plugins/known_marketplaces.json",
               JSON::PP->new->pretty->encode(\%mkts));
}

sub write_installed_plugins {
    my ($home, $plugins_href) = @_;
    write_file("$home/.claude/plugins/installed_plugins.json",
               JSON::PP->new->pretty->encode({ plugins => $plugins_href }));
}

sub write_selection_file {
    my ($path, @selected_plugins) = @_;
    write_file($path, JSON::PP->new->encode({
        schema_version            => 1,
        selected                  => [],
        selected_plugins          => \@selected_plugins,
        mounted_at_create         => [],
        mounted_plugins_at_create => [],
    }));
}

# ============================================================================
# AC1 — setup-project frontmatter: host-only, description unchanged.
# ============================================================================
{
    my $body = slurp($SETUP_SKILL);
    my $fm   = frontmatter_of($body);
    like($fm, qr/^host-only:\s*true\b/m,
         'AC1: setup-project SKILL.md frontmatter has a host-only: true line');
    like($fm, qr/^description:\s*Onboard the current project to the ccpraxis system/m,
         'AC1: setup-project description is unchanged (still begins '
       . '"Onboard the current project to the ccpraxis system")');
}

# ============================================================================
# AC2/AC3 — host-only-masks over a selection that includes steward@ccpraxis-local.
# ============================================================================
{
    my $root    = tempdir(CLEANUP => 1);
    my $home    = "$root/home";
    my $project = "$root/project";
    make_path($project);
    write_known_marketplaces($home);

    my $sel = "$root/selected.json";
    write_selection_file($sel, 'steward@ccpraxis-local');

    my $raw = run_skills($home, 'host-only-masks',
                          '--selection-file', $sel,
                          '--project-path',   $project);
    my $masks = decode_or_die($raw, 'AC2/AC3 host-only-masks');
    ok(ref $masks eq 'ARRAY', 'AC2/AC3: host-only-masks returned a JSON array')
        or diag("raw: $raw");
    $masks ||= [];

    my @container_paths = map { $_->{container_path} } @$masks;

    ok((grep { $_ eq '/root/.claude/plugins/marketplaces/ccpraxis-local/steward/skills/setup-project' }
        @container_paths),
       'AC2: the mask set includes the container_path for steward/skills/setup-project');

    ok(!(grep { m{/steward/skills/ccpraxis-extend$} } @container_paths),
       'AC3: no mask ends in /steward/skills/ccpraxis-extend');
    ok(!(grep { m{/steward/skills/audit$} } @container_paths),
       'AC3: no mask ends in /steward/skills/audit');

    # The set of steward skill dirs with a SKILL.md, minus the masked ones,
    # must equal exactly {audit, ccpraxis-extend} (spec AC3, Decision 13's
    # closing sentence).
    my @steward_skill_dirs = grep { -f "$_/SKILL.md" }
                              glob("$PLUGINS_DIR/steward/skills/*");
    my %all_steward_skills;
    for my $d (@steward_skill_dirs) {
        (my $name = $d) =~ s{^.*[/\\]}{};
        $all_steward_skills{$name} = 1;
    }
    my %masked_steward_skill = map { my $s = $_; $s =~ s{^.*/}{}; ($s => 1) }
                               grep { m{/steward/skills/} } @container_paths;
    my @unmasked = sort grep { !$masked_steward_skill{$_} } keys %all_steward_skills;
    is_deeply(\@unmasked, ['audit', 'ccpraxis-extend'],
              'AC3: steward skill dirs minus masked ones equal exactly {audit, ccpraxis-extend}');
}

# ============================================================================
# AC4 — discover-plugins still lists steward@ccpraxis-local; host_only_skills
# names setup-project and excludes ccpraxis-extend.
# ============================================================================
{
    my $root    = tempdir(CLEANUP => 1);
    my $home    = "$root/home";
    my $project = "$root/project";
    make_path($project);
    write_known_marketplaces($home);
    write_installed_plugins($home, {
        'steward@ccpraxis-local' => [ { scope => 'user', version => '0.1.0',
            installPath => "$home/.claude/plugins/cache/ccpraxis-local/steward/0.1.0" } ],
    });

    my $raw   = run_skills($home, 'discover-plugins', '--project-path', $project);
    my $found = decode_or_die($raw, 'AC4 discover-plugins');
    ok(ref $found eq 'ARRAY', 'AC4: discover-plugins returned a JSON array') or diag("raw: $raw");
    my %by_key = map { $_->{key} => $_ } @{ $found || [] };

    ok(exists $by_key{'steward@ccpraxis-local'},
       'AC4: discover-plugins still lists steward@ccpraxis-local');
    if (my $s = $by_key{'steward@ccpraxis-local'}) {
        ok((grep { $_ eq 'setup-project' } @{ $s->{host_only_skills} || [] }),
           'AC4: host_only_skills contains setup-project');
        ok(!(grep { $_ eq 'ccpraxis-extend' } @{ $s->{host_only_skills} || [] }),
           'AC4: host_only_skills does not contain ccpraxis-extend');
    }
}

# ============================================================================
# AC5/AC7 — select-model, SUGGESTION partition: steward's row carries the
# note; no other row does (including a same-named steward from another
# marketplace, and another real ccpraxis-local plugin).
# ============================================================================
{
    my $root       = tempdir(CLEANUP => 1);
    my $home       = "$root/home";
    my $project    = "$root/project";
    my $fixture_mkt = "$root/fixture-mkt";
    make_path($project);

    # Synthetic second marketplace: a plugin ALSO named "steward", one
    # visible (non-host-only) skill — so its key is steward@fixture-other,
    # distinct from steward@ccpraxis-local.
    write_file("$fixture_mkt/steward/.claude-plugin/plugin.json",
               qq({\n  "name": "steward",\n  "version": "0.1.0"\n}\n));
    write_file("$fixture_mkt/steward/skills/onlyskill/SKILL.md",
               "---\nname: onlyskill\ndescription: fixture\n---\n\n# onlyskill\n");
    write_file("$fixture_mkt/.claude-plugin/marketplace.json",
               JSON::PP->new->pretty->encode({
                   name    => 'fixture-other',
                   plugins => [ { name => 'steward', source => './steward' } ],
               }));

    write_known_marketplaces($home);
    write_installed_plugins($home, {
        'steward@ccpraxis-local' => [ { scope => 'user', version => '0.1.0',
            installPath => "$home/.claude/plugins/cache/ccpraxis-local/steward/0.1.0" } ],
        'butler@ccpraxis-local'  => [ { scope => 'user', version => '0.1.0',
            installPath => "$home/.claude/plugins/cache/ccpraxis-local/butler/0.1.0" } ],
        'steward@fixture-other'  => [ { scope => 'user', version => '0.1.0',
            installPath => "$fixture_mkt/steward" } ],
    });

    my $sel = "$root/selected.json";
    write_selection_file($sel);
    my $sel_before = slurp($sel);

    my $raw   = run_skills($home, 'select-model', '--selection-file', $sel,
                            '--project-path', $project);
    my $model = decode_or_die($raw, 'AC5/AC7 select-model (suggestion)');
    ok(ref $model eq 'HASH' && ref $model->{items} eq 'ARRAY',
       'AC5/AC7: select-model returned a well-shaped model') or diag("raw: $raw");
    my @rows = grep { ($_->{kind} // '') eq 'row' } @{ $model->{items} || [] };
    my %row_by_id = map { $_->{id} => $_ } @rows;

    if (my $r = $row_by_id{'steward@ccpraxis-local'}) {
        is($r->{display}, "steward\@ccpraxis-local [user] - $NOTE_TEXT",
           'AC5: suggestion-partition steward@ccpraxis-local row carries the exact note text');
        is($r->{group}, 'plugins_suggestion',
           'AC5: the row is in the suggestion partition group');
    } else {
        fail('AC5: no row found for id steward@ccpraxis-local');
    }

    for my $id (sort keys %row_by_id) {
        next if $id eq 'steward@ccpraxis-local';
        my $disp = $row_by_id{$id}{display} // '';
        unlike($disp, qr/\Q$NOTE_TEXT\E/,
               "AC7: row '$id' does not carry the steward-only note");
    }
    ok(exists $row_by_id{'butler@ccpraxis-local'},
       'AC7 fixture sanity: another real ccpraxis-local plugin (butler) is present in the model');
    ok(exists $row_by_id{'steward@fixture-other'},
       'AC7 fixture sanity: a same-named steward from a different marketplace is present in the model');

    # select-model must never write the selection file (spec section 5).
    is(slurp($sel), $sel_before, 'AC5: select-model left the selection file byte-identical');
}

# ============================================================================
# AC6/AC7 — select-model, PROJECT partition: steward's row carries the note
# and has group plugins_project; no other row does.
# ============================================================================
{
    my $root    = tempdir(CLEANUP => 1);
    my $home    = "$root/home";
    my $project = "$root/project";
    make_path("$project/.claude");

    write_known_marketplaces($home);
    write_installed_plugins($home, {
        'steward@ccpraxis-local' => [ { scope => 'project', version => '0.1.0',
            installPath => "$home/.claude/plugins/cache/ccpraxis-local/steward/0.1.0",
            projectPath => $project } ],
        'butler@ccpraxis-local'  => [ { scope => 'user', version => '0.1.0',
            installPath => "$home/.claude/plugins/cache/ccpraxis-local/butler/0.1.0" } ],
    });
    write_file("$project/.claude/settings.json",
               JSON::PP->new->pretty->encode({
                   enabledPlugins => { 'steward@ccpraxis-local' => JSON::PP::true },
               }));

    my $sel = "$root/selected.json";
    write_selection_file($sel);
    my $sel_before = slurp($sel);

    my $raw   = run_skills($home, 'select-model', '--selection-file', $sel,
                            '--project-path', $project);
    my $model = decode_or_die($raw, 'AC6/AC7 select-model (project)');
    my @rows  = grep { ($_->{kind} // '') eq 'row' } @{ $model->{items} || [] };
    my %row_by_id = map { $_->{id} => $_ } @rows;

    if (my $r = $row_by_id{'steward@ccpraxis-local'}) {
        is($r->{display}, "steward\@ccpraxis-local - $NOTE_TEXT",
           'AC6: project-partition steward@ccpraxis-local row carries the exact note text (no scope tag)');
        is($r->{group}, 'plugins_project',
           'AC6: the row is in the project partition group');
    } else {
        fail('AC6: no row found for id steward@ccpraxis-local');
    }

    for my $id (sort keys %row_by_id) {
        next if $id eq 'steward@ccpraxis-local';
        my $disp = $row_by_id{$id}{display} // '';
        unlike($disp, qr/\Q$NOTE_TEXT\E/,
               "AC7: row '$id' does not carry the steward-only note (project-partition run)");
    }
    is(slurp($sel), $sel_before, 'AC6: select-model left the selection file byte-identical');
}

# ============================================================================
# AC8 — the literal note text lives in exactly one place.
# ============================================================================
{
    my $skills_src = slurp($SKILLS_PL);
    my $count = () = $skills_src =~ /\Q$NOTE_TEXT\E/g;
    is($count, 1, "AC8: the literal note text occurs exactly once in skills.pl");

    if (-f $LAUNCHER) {
        my $launcher_src = slurp($LAUNCHER);
        unlike($launcher_src, qr/\Q$NOTE_TEXT\E/,
               'AC8: the note text does not appear in launcher.pl');
    } else {
        fail('AC8: launcher.pl not found to check');
    }

    my @tui_files = glob("$Bin/../../scripts/tui/*.pm");
    ok(scalar(@tui_files) > 0, 'AC8 fixture sanity: at least one tui/*.pm file found');
    for my $f (@tui_files) {
        my $src = slurp($f);
        unlike($src, qr/\Q$NOTE_TEXT\E/, "AC8: the note text does not appear in $f");
    }
}

# ============================================================================
# AC9 — ccpraxis-extend frontmatter: no host-only, description intact.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    my $fm   = frontmatter_of($body);
    unlike($fm, qr/^host-only:/m,
           'AC9: ccpraxis-extend frontmatter has no host-only: line');
    my ($desc_line) = $fm =~ /^description:\s*(.*(?:\n(?![A-Za-z-]+:).*)*)/m;
    $desc_line //= '';
    unlike($desc_line, qr/host-only/i,
           'AC9: ccpraxis-extend description does not match /host-only/i');
    like($fm, qr/^description:\s*THE single entrypoint for changing ccpraxis or adding new functionality to it\./m,
         'AC9: ccpraxis-extend description still begins with the pinned first sentence');
}

# ============================================================================
# AC10 — the whole file drops every live-install / podman / mirror phrase.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    for my $needle (
        '.claude/ccpraxis', '~/.claude', '.claude/settings.json',
        'sync-skills', 'claude plugin install', '/reload-plugins',
        'podman', 'live mirror',
    ) {
        unlike($body, qr/\Q$needle\E/i,
               "AC10: ccpraxis-extend SKILL.md does not contain '$needle' (case-insensitive)");
    }
}

# ============================================================================
# AC11 — the clone check, before Step 0.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    my $step0_at = index($body, '## Step 0');
    ok($step0_at >= 0, 'AC11 setup: "## Step 0" heading found') or BAIL_OUT('no Step 0 heading');

    for my $needle ('git rev-parse --show-toplevel', 'plugins/.claude-plugin/marketplace.json', 'ccpraxis-local') {
        my $at = index($body, $needle);
        ok($at >= 0 && $at < $step0_at,
           "AC11: '$needle' appears before the ## Step 0 heading");
    }

    like($body, qr/Not a ccpraxis clone/,
         'AC11: the refusal phrase "Not a ccpraxis clone" is present');
    like($body, qr/not a development clone/,
         'AC11: the refusal phrase "not a development clone" is present');
}

# ============================================================================
# AC12 — the inert-until-promoted closing line, after Step 6.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    my $step6_at = index($body, '## Step 6');
    ok($step6_at >= 0, 'AC12 setup: "## Step 6" heading found') or BAIL_OUT('no Step 6 heading');

    my $closing_at = -1;
    while (1) {
        my $at = index(lc($body), 'changed in the clone; inert until promoted by merge', $closing_at + 1);
        last if $at < 0;
        $closing_at = $at;
        last if $at > $step6_at;
    }
    ok($closing_at > $step6_at,
       'AC12: "changed in the clone; inert until promoted by merge" (case-insensitive) appears after ## Step 6');
}

# ============================================================================
# AC13 — every other step survives, in order, with its load-bearing content.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    my $prev_pos = -1;
    for my $heading (map { "## Step $_" } (0 .. 6)) {
        my $at = index($body, $heading);
        ok($at >= 0, "AC13: heading '$heading' is present") or next;
        ok($at > $prev_pos, "AC13: heading '$heading' appears after the previous Step heading");
        $prev_pos = $at;
    }

    for my $needle (
        'Apply the packaging rule',
        'gen-readme-tree.pl --write',
        'gen-readme-tree.pl --check',
        'lint-readme-paths.pl',
        'global-config/settings.json',
        'marketplace.json',
        'claude plugin validate',
    ) {
        ok(index($body, $needle) >= 0,
           "AC13: ccpraxis-extend SKILL.md still contains '$needle'");
    }
}

# ============================================================================
# AC14 — no fenced code block contains promote.pl.
# ============================================================================
{
    my $body = slurp($EXTEND_SKILL);
    my @fences = $body =~ /```.*?\n(.*?)```/gs;
    my @offending = grep { /promote\.pl/ } @fences;
    is(scalar(@offending), 0,
       'AC14: no fenced code block in ccpraxis-extend SKILL.md contains "promote.pl"')
        or diag(join("\n---\n", @offending));
}

# ============================================================================
# Decision 25 — docs/reference.md must stop calling ccpraxis-extend
# host-only (source-level text check only).
# ============================================================================
{
    ok(-f $REFERENCE_MD, 'Decision 25 fixture: docs/reference.md exists') or BAIL_OUT('no docs/reference.md');
    my @lines = split /\n/, slurp($REFERENCE_MD);
    my @extend_lines  = grep { /ccpraxis-extend/ } @lines;
    ok(scalar(@extend_lines) > 0,
       'Decision 25 setup: docs/reference.md mentions ccpraxis-extend at least once')
        or diag('no line mentioning ccpraxis-extend found');
    for my $line (@extend_lines) {
        unlike($line, qr/host-only/i,
               "Decision 25: a docs/reference.md line mentioning ccpraxis-extend does not also say host-only: $line");
    }
}

# ============================================================================
# AC15 — hygiene, self-check. This test file's own source spawns nothing
# naming launcher.pl, podman or claude via system/exec/backticks/qx/pipe-open.
# ============================================================================
{
    my $self = slurp(__FILE__);
    # $BT is a backtick char built at RUNTIME (chr(96)) so that this source
    # file itself never contains a literal backtick immediately followed by
    # "podman"/"claude"/"launcher.pl" -- otherwise this very check's own
    # regex-as-text (a backtick, forbidden words, a backtick) would match
    # itself. Every check below is written so that its own source text is
    # not an instance of the pattern it looks for.
    my $BT = chr(96);
    unlike($self, qr/\bsystem\s*\([^)]*(?:launcher\.pl|podman|claude)/i,
           'AC15: no system(...) call names launcher.pl, podman or claude');
    unlike($self, qr/\bexec\s*\([^)]*(?:launcher\.pl|podman|claude)/i,
           'AC15: no exec(...) call names launcher.pl, podman or claude');
    unlike($self, qr/\Q$BT\E[^\Q$BT\E\n]*(?:launcher\.pl|podman|claude)[^\Q$BT\E\n]*\Q$BT\E/,
           'AC15: no backtick command names launcher.pl, podman or claude, on one line');
    unlike($self, qr/qx(?:\{|\(|\/)[^)}\/\n]*(?:launcher\.pl|podman|claude)/,
           'AC15: no qx(...) call names launcher.pl, podman or claude, on one line');
    unlike($self, qr/open\s*\(?[^;\n]*['"]\s*\|\s*['"]?\s*,?\s*[^;\n]*(?:launcher\.pl|podman)/i,
           'AC15: no pipe-open spawns launcher.pl or podman, on one line');
    ok(1, 'AC15: every skills.pl child above sets HOME/USERPROFILE to a tempdir via run_skills()');
}

# ============================================================================
# AC16 (partial; the cross-.t regression list is validated outside this
# file — see header) — skills.pl still compiles.
# ============================================================================
{
    open(my $saved_stderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', File::Spec->devnull) or die "redirect STDERR: $!";
    my $rc = system($^X, '-c', $SKILLS_PL);
    open(STDERR, '>&', $saved_stderr) or die "restore STDERR: $!";
    close $saved_stderr;
    is($rc, 0, 'AC16 (partial): perl -c skills.pl exits 0');
}

done_testing();
