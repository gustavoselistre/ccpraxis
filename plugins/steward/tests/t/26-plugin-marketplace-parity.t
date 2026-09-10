#!/usr/bin/env perl
# 26-plugin-marketplace-parity.t — a plugin that ships but is never registered.
#
# WHAT HAPPENED
#
# plugins/almanac/ shipped complete — plugin.json, two skills, the almanac-bug.pl
# state machine, a PreToolUse write guard, four passing test files — and was never
# added to plugins/.claude-plugin/marketplace.json. Claude Code installs from the
# marketplace, so the plugin was installed nowhere. Two consequences, neither
# cosmetic:
#
#   * /almanac:bug-report and /almanac:bug-triage did not exist as slash commands,
#     so filing a ccpraxis bug depended on an agent remembering the script path.
#   * hooks.json registers guard-almanac-write.sh via ${CLAUDE_PLUGIN_ROOT}, which
#     only resolves for an INSTALLED plugin. The hook that enforces "almanac-bug.pl
#     is the only writer" never ran, so the frozen-report digest had nothing
#     protecting it.
#
# The plugin's own tests passed throughout — they test the state machine, not
# whether anything can reach it. That is why this failure was silent for its whole
# life: every signal the repo produces was green.
#
# WHAT THIS TEST DOES
#
# Asserts the two sets are equal, in both directions. A directory that ships a
# plugin.json but has no marketplace entry is unreachable; a marketplace entry
# pointing at a missing directory breaks marketplace load for every plugin in the
# file, not just that one.
#
# AC1  every plugins/<name>/ with a plugin.json has a marketplace entry
# AC2  every marketplace entry resolves to a directory that ships a plugin.json
# AC3  the entry's name matches the plugin.json's own declared name
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(basename);
use JSON::PP ();

my $PLUGINS_DIR = "$Bin/../../..";                       # repo/plugins
my $MARKETPLACE = "$PLUGINS_DIR/.claude-plugin/marketplace.json";

ok(-f $MARKETPLACE, 'marketplace.json exists') or do {
    diag("expected at $MARKETPLACE");
    done_testing();
    exit;
};

sub slurp_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->decode($raw) };
    return $@ ? undef : $data;
}

my $mkt = slurp_json($MARKETPLACE);
ok(ref $mkt eq 'HASH' && ref $mkt->{plugins} eq 'ARRAY',
   'marketplace.json parses and carries a plugins array') or do {
    done_testing();
    exit;
};

# ── what the marketplace claims ────────────────────────────────────────────
my %registered;   # name => source
for my $entry (@{ $mkt->{plugins} }) {
    next unless ref $entry eq 'HASH';
    my $name = $entry->{name};
    next unless defined $name && length $name;
    $registered{$name} = $entry->{source} // '';
}

# ── what the repo actually ships ───────────────────────────────────────────
my %shipped;      # dir basename => declared name from its plugin.json
for my $dir (sort glob("$PLUGINS_DIR/*")) {
    next unless -d $dir;
    my $manifest = "$dir/.claude-plugin/plugin.json";
    next unless -f $manifest;
    my $data = slurp_json($manifest);
    my $base = basename($dir);
    $shipped{$base} = (ref $data eq 'HASH' && defined $data->{name})
                    ? $data->{name} : undef;
}

cmp_ok(scalar keys %shipped, '>', 0, 'found at least one plugin directory');

# ── AC1 — nothing ships unregistered ───────────────────────────────────────
for my $base (sort keys %shipped) {
    my $declared = $shipped{$base} // $base;
    ok(exists $registered{$declared},
       "AC1 plugins/$base is registered in marketplace.json as '$declared'")
        or diag("plugins/$base ships a plugin.json but no marketplace entry names "
              . "'$declared' — Claude Code will never install it, and any hook it "
              . "registers via \${CLAUDE_PLUGIN_ROOT} will never run");
}

# ── AC2/AC3 — nothing registered is missing or misnamed ────────────────────
for my $name (sort keys %registered) {
    my $source = $registered{$name};
    like($source, qr{^\./}, "AC2 '$name' uses a repo-relative ./source")
        or next;

    (my $rel = $source) =~ s{^\./}{};
    my $dir = "$PLUGINS_DIR/$rel";
    ok(-d $dir, "AC2 '$name' source $source resolves to a directory")
        or next;
    ok(-f "$dir/.claude-plugin/plugin.json",
       "AC2 '$name' source $source ships a plugin.json")
        or next;

    my $declared = $shipped{ basename($dir) };
    is($declared, $name,
       "AC3 '$name' matches the name declared in $source/.claude-plugin/plugin.json");
}

done_testing();
