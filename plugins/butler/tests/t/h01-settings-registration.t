#!/usr/bin/env perl
# platform: any
# REWRITTEN oracle for batch B of blueprint hook-continuity-remake, package
# 16-cutover (specs/16-cutover-spec.md sec 2.2/2.3, acceptance B-2/B-3).
#
# The file's ORIGINAL subject (whether the old separate headless-background
# and judge-checks Bash guards route via settings.json or hooks.json, packages
# g02/h01) is retired here: both scripts are on the batch-B deletion list, so
# a route decision about a deleted script is not an oracle for the tree this
# package leaves behind. What replaces it: .claude/settings.json carries
# exactly one hook (guard-git-mutations.sh, sec 2.2's settings form), no Stop
# and no PostToolUse key, every other top-level key pinned literally from the
# file as it stood before this package touched it; and, jointly with
# hooks.json, exactly one Stop entry across both files (naming stop-gate.sh)
# and a SubagentStop entry naming only track-dispatch.sh (Decision 5).
#
# READ-ONLY against both tracked files -- never writes to either. Runs
# standalone: perl this file.
#
# RIGHT NOW (before batch B lands) this file is red: settings.json still
# carries guard-git-mutations.sh in its pre-cutover unguarded form plus the
# old subagent-stall-guard PostToolUse/Stop entries, and hooks.json still
# carries three old Stop entries and no SubagentStop entry at all. That is
# the correct shape of red for an oracle written from the spec.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $SETTINGS   = "$REPO_ROOT/.claude/settings.json";
my $HOOKS_JSON = "$REPO_ROOT/plugins/butler/hooks/hooks.json";

ok(-f $SETTINGS,   '.claude/settings.json exists') or BAIL_OUT('no settings.json');
ok(-f $HOOKS_JSON, 'hooks.json exists')             or BAIL_OUT('no hooks.json');

sub read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return ($doc, $raw, $@);
}

my ($settings, $settings_raw, $serr) = read_json($SETTINGS);
unless (ref $settings eq 'HASH') { fail('A1: .claude/settings.json parses as an object'); diag("decode failed: $serr"); BAIL_OUT('unparseable settings.json') }
pass('A1: .claude/settings.json parses as an object');

my ($hooksjson, $hooksjson_raw, $herr) = read_json($HOOKS_JSON);
unless (ref $hooksjson eq 'HASH') { fail('A2: hooks.json parses as an object'); diag("decode failed: $herr"); BAIL_OUT('unparseable hooks.json') }
pass('A2: hooks.json parses as an object');

# ---------------------------------------------------------------------------
# sec 2.2's settings form: ${CLAUDE_PLUGIN_ROOT} replaced by
# $CLAUDE_PROJECT_DIR/plugins/butler in both assignments.
# ---------------------------------------------------------------------------
sub settings_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{f="\$CLAUDE_PROJECT_DIR/plugins/butler/hooks/$file" ; w="\$CLAUDE_PROJECT_DIR/plugins/butler/hooks/run-hook.sh" ; unset BASH_ENV ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

# ===========================================================================
# B2: settings.json's hooks equal sec 2.3 exactly: ONE group, PreToolUse
# Bash, ONE command (guard-git-mutations.sh, sec 2.2 settings form, no args,
# type "command", timeout 15); no Stop key; no PostToolUse key.
# ===========================================================================
{
    my $hooks = $settings->{hooks} // {};
    ok(ref $hooks eq 'HASH', 'B2a: settings.json has a "hooks" object');

    ok(!exists $hooks->{Stop}, 'B2b: settings.json has no Stop key at all')
        or diag('Stop key present: ' . JSON::PP->new->encode($hooks->{Stop}));
    ok(!exists $hooks->{PostToolUse}, 'B2c: settings.json has no PostToolUse key at all')
        or diag('PostToolUse key present: ' . JSON::PP->new->encode($hooks->{PostToolUse}));

    my @pretooluse = @{ $hooks->{PreToolUse} // [] };
    is(scalar(@pretooluse), 1,
       'B2d: settings.json has exactly ONE PreToolUse group')
        or diag('found ' . scalar(@pretooluse) . ' PreToolUse groups');

    if (@pretooluse == 1) {
        my $group = $pretooluse[0];
        is($group->{matcher}, 'Bash', 'B2e: ...whose matcher is exactly "Bash"');
        my @cmds = @{ $group->{hooks} // [] };
        is(scalar(@cmds), 1, 'B2f: ...carrying exactly ONE command');
        if (@cmds == 1) {
            my $h = $cmds[0];
            is($h->{command}, settings_template('guard-git-mutations.sh', ''),
               'B2g: ...equal to the sec 2.2 settings-form template for guard-git-mutations.sh, no args');
            is($h->{type}, 'command', 'B2h: ...type is "command"');
            is($h->{timeout}, 15, 'B2i: ...timeout is 15');
        }
    } else {
        fail('B2e/B2f/B2g/B2h/B2i: skipped, PreToolUse group count was not exactly 1');
        fail('B2e/B2f/B2g/B2h/B2i: skipped, PreToolUse group count was not exactly 1');
        fail('B2e/B2f/B2g/B2h/B2i: skipped, PreToolUse group count was not exactly 1');
        fail('B2e/B2f/B2g/B2h/B2i: skipped, PreToolUse group count was not exactly 1');
        fail('B2e/B2f/B2g/B2h/B2i: skipped, PreToolUse group count was not exactly 1');
    }

    unlike($settings_raw, qr/guard-subagent-stall/,
       'B2j: settings.json does not mention the old subagent-stall guard anywhere in the raw file');
}

# ===========================================================================
# B2k: every other top-level key of settings.json is unchanged in VALUE from
# the pre-B file. Pinned literally against the values captured from the
# tracked, still-unedited file at the time this oracle was written
# (2026-09-25) -- Decision 34's "pinned literally from the pre-B file".
# ===========================================================================
{
    my $expect_enabled_plugins = {
        'almanac@ccpraxis-local'          => JSON::PP::true,
        'backpack@ccpraxis-local'         => JSON::PP::true,
        'blueprint@ccpraxis-local'        => JSON::PP::true,
        'butler@ccpraxis-local'           => JSON::PP::true,
        'feature-dev@claude-plugins-official' => JSON::PP::true,
        'frontend-design@claude-plugins-official' => JSON::PP::true,
        'sandbox@ccpraxis-local'          => JSON::PP::true,
    };
    is_deeply($settings->{enabledPlugins}, $expect_enabled_plugins,
       'B2k-1: enabledPlugins is byte-for-byte unchanged from the pre-B file');
    is_deeply($settings->{enabledMcpjsonServers}, [],
       'B2k-2: enabledMcpjsonServers is unchanged ([])');
    is_deeply($settings->{disabledMcpjsonServers}, [],
       'B2k-3: disabledMcpjsonServers is unchanged ([])');
}

# ===========================================================================
# B3: Decision 5 -- Stop commands across hooks.json AND settings.json number
# exactly 1 and name stop-gate.sh; SubagentStop names only track-dispatch.sh.
# ===========================================================================
{
    my @stop_commands;
    for my $doc ($hooksjson, $settings) {
        next unless ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH';
        for my $group (@{ $doc->{hooks}{Stop} // [] }) {
            next unless ref $group eq 'HASH';
            for my $h (@{ $group->{hooks} // [] }) {
                next unless ref $h eq 'HASH';
                push @stop_commands, $h->{command} // '';
            }
        }
    }
    is(scalar(@stop_commands), 1,
       'B3a: exactly ONE Stop command is registered across hooks.json + settings.json')
        or diag('found: ' . join(' | ', @stop_commands));
    if (@stop_commands == 1) {
        like($stop_commands[0], qr/stop-gate\.sh/,
             'B3b: ...and it names stop-gate.sh');
    } else {
        fail('B3b: skipped, Stop command count was not exactly 1');
    }

    my @subagentstop_commands;
    for my $group (@{ $hooksjson->{hooks}{SubagentStop} // [] }) {
        next unless ref $group eq 'HASH';
        for my $h (@{ $group->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            push @subagentstop_commands, $h->{command} // '';
        }
    }
    is(scalar(@subagentstop_commands), 1,
       'B3c: exactly ONE SubagentStop command is registered (hooks.json only)')
        or diag('found: ' . join(' | ', @subagentstop_commands));
    if (@subagentstop_commands == 1) {
        like($subagentstop_commands[0], qr/track-dispatch\.sh/,
             'B3d: ...and it names track-dispatch.sh');
    } else {
        fail('B3d: skipped, SubagentStop command count was not exactly 1');
    }
}

done_testing();
