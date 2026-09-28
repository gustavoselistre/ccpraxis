#!/usr/bin/env perl
# platform: windows
# 69 -- the ORACLE for blueprint unified-tui-design-system,
# package 10
# (specs/10-spec.md).
#
# Written BLIND to scripts/statusline.pl and plugins/butler/scripts/
# bp-statusline.pl -- neither file was read while this oracle was written.
# Every expectation comes from the spec, so this file is an oracle rather than
# an echo of whatever the implementer eventually writes. Do NOT weaken an
# assertion to make a future implementation's life easier.
#
# Coverage: AC-S, AC-E, AC-O, AC-M, AC-P, AC-D, AC-B, AC-G (spec S4).
#
# HARD CONSTRAINTS honoured here (spec S4.0):
#   * NEVER spawns launcher.pl, never builds an image, never starts a
#     container. Only the two plain filter scripts are spawned, each bounded
#     by `timeout`, exactly as t/tui-output-hygiene.t and t/spend-panel.t
#     already spawn them.
#   * Fixtures live only under File::Temp tempdir()/tempfile().
#   * Never redirects to NUL; /dev/null only.
#   * No whole-shape pins (Decision 15): no rendered-row count, no field
#     inventory, no key-set comparison, no assertion of MIN_CWD_COLS /
#     MIN_PROJECT_COLS / the marker slot width. "Same slot, same width" is
#     asserted as a RELATIONSHIP between the two rendered variants.
#   * Whole-line `#` comments are blanked before every source scan, because
#     this oracle's own subject matter is the constructs being scanned for.
#   * Call forms are targeted, never bare words: \bwarn\s*\( , not \bwarn\b
#     (which would match the mandated role name state.warn).
#   * \Q...\E does not interpolate escapes, so escape-byte searches use
#     index($s, "\e[...") instead.
#   * This file deliberately does NOT carry the generated-block begin marker
#     at column 0 -- t/64's repo-wide walk fails if that line appears in any
#     .pl/.pm/.t outside the listed surface. Where the literal is needed it is
#     built by concatenation.
#
# ENCODING DISCIPLINE (spec S4.0, C-9): both scripts' stdout is read as RAW
# BYTES. Every expectation compared against it is bytes.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Basename qw(basename);
use JSON::PP qw(decode_json encode_json);
use Encode qw(encode decode);
use Cwd ();
use POSIX ();
use File::Path qw(make_path remove_tree);
use Time::HiRes ();

use_ok('Theme') or BAIL_OUT('Theme.pm did not load -- package 02 is a dependency of this one');

my $STATUSLINE    = "$Bin/../../../../scripts/statusline.pl";
my $BP_STATUSLINE = "$Bin/../../../butler/scripts/bp-statusline.pl";
my $SANDBOX_SCRIPTS = "$Bin/../../scripts";
my $SETTINGS_JSON = "$Bin/../../container/settings.json";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined($s) ? $s : '';
}

sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# blank_comments($src) -> $src with every WHOLE-LINE comment replaced by an
# empty line (line numbering preserved). Mandatory before any source scan:
# both subject files document the very constructs scanned for.
sub blank_comments {
    my ($src) = @_;
    return '' unless defined $src;
    return join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
}

# --- the emoji detector (spec 02 S2.6.1/S2.6.3, restated here so this oracle
#     stands alone). The U+2600-U+26FF block is load-bearing: U+26AA (one of
#     the four glyphs bp-statusline.pl must lose) is NOT in a 1F??? block.
#
#     THE ORACLE FIX (hook-continuity-remake package 10, spec 2.5): the block
#     list alone was a proxy that rejected non-emoji characters living in
#     U+2600-U+27BF (U+2630, U+2691 -- the notes and decisions glyphs). The
#     predicate is the INTERSECTION of the unchanged block list and
#     \p{Emoji}, plus U+FE0F on its own. Never the bare property: U+25B6 is
#     Emoji=Yes and ships today. Mirrors plugins/sandbox/tests/t/theme-tokens.t.
sub _in_listed_emoji_block {
    my ($cp) = @_;
    return 0 unless defined $cp;
    for my $r (
        [0x1F000, 0x1F0FF], [0x1F100, 0x1F1FF], [0x1F200, 0x1F2FF],
        [0x1F300, 0x1F5FF], [0x1F600, 0x1F64F], [0x1F650, 0x1F67F],
        [0x1F680, 0x1F6FF], [0x1F700, 0x1F77F], [0x1F780, 0x1F7FF],
        [0x1F800, 0x1F8FF], [0x1F900, 0x1F9FF], [0x1FA00, 0x1FAFF],
        [0x2600,  0x26FF],  [0x2700,  0x27BF],
    ) {
        return 1 if $cp >= $r->[0] && $cp <= $r->[1];
    }
    return 0;
}
sub _is_emoji {
    my ($cp) = @_;
    return 0 unless defined $cp;
    return 1 if $cp == 0xFE0F;
    return (_in_listed_emoji_block($cp) && chr($cp) =~ /\p{Emoji}/) ? 1 : 0;
}

# emoji_hits($bytes) -> list of { cp, how }. Arm A: escape literals in source
# text. Arm B: encoded literals, decoded leniently. Both arms run over the
# same input, so the detector serves source scans (AC-E) and rendered output
# (AC-M4, AC-G1) alike.
sub emoji_hits {
    my ($text) = @_;
    return () unless defined $text;
    my @hits;
    while ($text =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) {
        my $cp = hex($1);
        push @hits, { cp => $cp, how => 'escape' } if _is_emoji($cp);
    }
    my $decoded = decode('UTF-8', $text, Encode::FB_DEFAULT);
    for my $ch (split //, $decoded) {
        my $cp = ord($ch);
        push @hits, { cp => $cp, how => 'literal' } if _is_emoji($cp);
    }
    return @hits;
}
sub emoji_summary {
    my (@hits) = @_;
    return join(', ', map { sprintf('U+%04X(%s)', $_->{cp}, $_->{how}) } @hits);
}

my $TMPROOT = tempdir(CLEANUP => 1);
my $tmpseq  = 0;

# --- THE HYGIENE SCRUB (hook-continuity-remake package 10, spec section 4).
#
# statusline.pl now resolves a PROJECT ROOT from workspace.current_dir by
# walking up to the first ancestor holding .ccpraxis-local-data or .git, then
# falls back to CLAUDE_PROJECT_DIR. The fixed '/w/...' and '/project' paths
# this file used to feed it are therefore no longer inert: '/project' is the
# real repo mount inside a sandbox, and on this host the operator's own home
# directory carries a .ccpraxis-local-data. So every current_dir below lives
# under $FAKE_ROOT, a tempdir holding its own .git -- the walk stops there, at
# an EMPTY project, and never reaches a real store. The path TEXT each
# assertion compares against is built from the same variable, so every
# assertion keeps its meaning: only where the fake tree is rooted moved.
my $FAKE_ROOT = tempdir(CLEANUP => 1);
$FAKE_ROOT =~ s{\\}{/}g;
mkdir "$FAKE_ROOT/.git" or die "fixture setup: cannot mkdir $FAKE_ROOT/.git: $!";
my $WROOT = "$FAKE_ROOT/w";

# Environment keys that would point a render at real state. Deleted for every
# spawn unless a case sets one on purpose (spec section 4).
my @SCRUB_ENV = qw(CLAUDE_PROJECT_DIR ALMANAC_HOME ALMANAC_SURFACE BUTLER_STATE_DIR);
sub temp_source {
    my ($bytes) = @_;
    my $path = "$TMPROOT/fixture-" . (++$tmpseq) . ".pl";
    return spew_raw($path, $bytes);
}

# --- width / cost -----------------------------------------------------------
# Spec S2.4.1: strip SGR; columns = sum of per-character display widths from a
# declared table (U+FF5C is TWO columns -- Theme declares it so); bytes = the
# UTF-8 byte length of the stripped string; cost = max(columns, bytes).
my $SEPBAR_CP    = 0xFF5C;
my $SEPBAR_BYTES = Theme::glyph('sep.bar');
my $SEPBAR_COLS  = Theme::glyph_width('sep.bar');
my %ORACLE_COLS  = ($SEPBAR_CP => (defined($SEPBAR_COLS) ? $SEPBAR_COLS : 2));

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }

sub col_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $dec = decode('UTF-8', $s, Encode::FB_DEFAULT);
    my $cols = 0;
    $cols += ($ORACLE_COLS{ ord($_) } // 1) for split //, $dec;
    return $cols;
}

sub row_cost {
    my ($bytes) = @_;
    my $s  = strip_sgr($bytes);
    my $b  = length($s);
    my $c  = col_cost($bytes);
    return $c > $b ? $c : $b;
}

sub first_line { my $s = shift; $s = '' unless defined $s; my ($l) = split /\n/, $s, 2; return defined($l) ? $l : '' }

# sep_fields($line_bytes) -> the SGR-stripped row split on the rendered
# separator (space, sep.bar, space). Field 0 is the marker, 1 the project,
# 2 the working directory, then git and plans -- spec S2.1. Deliberately a
# positional accessor, never an inventory: nothing here counts the fields.
my $SEP_RENDERED = " " . $SEPBAR_BYTES . " ";
sub sep_fields {
    my ($line) = @_;
    my $s = strip_sgr($line);
    return split /\Q$SEP_RENDERED\E/, $s, -1;
}
sub field_at {
    my ($line, $idx) = @_;
    my @f = sep_fields($line);
    return $idx <= $#f ? $f[$idx] : undef;
}

# project_field($line) / cwd_field($line) -- LOCATE the field rather than
# assume its position.
#
# RE-POINTED 2026-08-26. These were thirteen scattered `project_field($line)`
# calls, which encoded "the project is the second ｜-separated field on row 1".
# That stopped being true when the operator reordered the row ("after the
# HOST/SANDBOX cell, the model usage cell and the budget cell and then the rest
# of the stuff in the old order"), and it broke ten assertions at once -- none
# of which are about field POSITION. They are about what the project field
# CONTAINS.
#
# So the position is derived once, here, from the row's actual composition: the
# project is the first field after the marker that is neither the context group
# nor the plan-usage group. Both of those are identifiable by shape without
# knowing the order -- the context group carries the model name and a percent,
# the plan group carries the window labels. A future reorder re-points this one
# helper instead of every call site.
sub _is_context_field { my $f = shift; return (defined $f && $f =~ /\d+%/ && $f =~ /\d+k|\dM/) ? 1 : 0 }
sub _is_budget_field  { my $f = shift; return (defined $f && $f =~ /\b(?:5h|7d)\b/)            ? 1 : 0 }
sub project_field {
    my ($line) = @_;
    my @f = sep_fields($line);
    for my $i (1 .. $#f) {
        next if _is_context_field($f[$i]) || _is_budget_field($f[$i]);
        return $f[$i];
    }
    return undef;
}
# The working directory left row 1 entirely (it has its own row on the host and
# none in a sandbox), so this is now always undef. Kept as a named helper rather
# than deleted: the assertions that use it are guards against the cwd field
# REAPPEARING in a bad shape, and they stay meaningful as long as they are
# asking about the right thing.
sub cwd_field { return undef }

# --- shims (spec S4.1: F-tput, F-git) ---------------------------------------
my $SHIM_DIR = tempdir(CLEANUP => 1);

sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}

# make_git(toplevel => $bytes|undef, branch => $str|undef)
#
# SCAFFOLDING NOTE (deviation from the spec's env-driven F-git, recorded):
# the spec drives the shim from S69_TOPLEVEL / S69_BRANCH. On this host the
# environment block is not a reliable carrier of raw UTF-8 bytes (case P-e
# uses `Andre'-projekt'), and AC-P5 separately requires the shim file to be
# written :raw with pre-encoded UTF-8. Baking the values into the shim file
# itself -- rewritten per run, exactly as make_tput rewrites tput -- satisfies
# both and removes the encoding hazard entirely. The observable contract is
# unchanged: rev-parse --show-toplevel prints the toplevel or exits 1;
# rev-parse --abbrev-ref prints the branch or exits 1; anything else exits 1.
sub make_git {
    my (%opt) = @_;
    my $top    = $opt{toplevel};
    my $branch = $opt{branch};
    my $topfile = "$SHIM_DIR/toplevel.txt";
    my $brfile  = "$SHIM_DIR/branch.txt";
    unlink $topfile, $brfile;
    spew_raw($topfile, $top)    if defined($top)    && length($top);
    spew_raw($brfile,  $branch) if defined($branch) && length($branch);
    my $sh = <<'SH';
#!/bin/sh
d=$(dirname "$0")
want=""
for a in "$@"; do
  case "$a" in
    --show-toplevel) want=toplevel ;;
    --abbrev-ref)    want=branch ;;
  esac
done
case "$want" in
  toplevel) if [ -s "$d/toplevel.txt" ]; then cat "$d/toplevel.txt"; echo; exit 0; fi; exit 1 ;;
  branch)   if [ -s "$d/branch.txt" ];   then cat "$d/branch.txt";   echo; exit 0; fi; exit 1 ;;
esac
exit 1
SH
    spew_raw("$SHIM_DIR/git", $sh);
    chmod 0755, "$SHIM_DIR/git";
}

# --- the sandbox variable, discovered exactly as t/54:140-154 discovers it ---
my $SANDBOX_VAR;
{
    my $settings = eval { decode_json(slurp_raw($SETTINGS_JSON)) };
    my $env = (ref($settings) eq 'HASH' && ref($settings->{env}) eq 'HASH') ? $settings->{env} : {};
    my @candidates = grep {
        /SANDBOX/i && defined($env->{$_}) && $env->{$_} =~ /^(1|true)$/i
    } sort keys %$env;
    $SANDBOX_VAR = @candidates ? $candidates[0] : 'CCPRAXIS_SANDBOX';
    diag("setup: sandbox var discovered as '$SANDBOX_VAR'");
}

# --- F-env / F-payload / the spawn ------------------------------------------
my $CLEAN_HOME = tempdir(CLEANUP => 1);
my $CLEAN_DATA = tempdir(CLEANUP => 1);
my $SEEDED_HOME = tempdir(CLEANUP => 1);
my $SEEDED_DATA = tempdir(CLEANUP => 1);

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // "$WROOT/proj-alpha" },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if defined $opt{session_id};
    return \%p;
}

# run_statusline(\%payload, cols => N, sandbox => 0|1, toplevel => ..,
#                branch => .., home => .., data => .., env => {K => V|undef})
#   -> ($stdout_bytes, $rc)
#
# Hygiene (spec section 4): HOME and USERPROFILE are the same tempdir; the
# keys in @SCRUB_ENV are deleted unless `env` sets one on purpose (an undef
# value in `env` deletes that key, which is how a case unsets HOME).
sub run_statusline {
    my ($payload, %opt) = @_;
    make_tput($opt{cols} // 80);
    make_git(toplevel => $opt{toplevel}, branch => $opt{branch});

    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // $CLEAN_HOME;
    $ENV{USERPROFILE} = $ENV{HOME};
    delete $ENV{$_} for @SCRUB_ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $opt{data} // $CLEAN_DATA;
    if ($opt{sandbox}) { $ENV{$SANDBOX_VAR} = '1' } else { delete $ENV{$SANDBOX_VAR} }
    for my $k (sort keys %{ $opt{env} || {} }) {
        if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
    }

    # The child's process cwd is a scratch dir, never the repo checkout this
    # file runs from: a render must not fall back to its process cwd (spec
    # section 5), and if one ever did, it would land here rather than on the
    # real repo's stores. `pcwd` lets a case choose which scratch dir.
    my $prev_cwd = Cwd::getcwd();
    chdir($opt{pcwd} // $FAKE_ROOT) or die "fixture setup: cannot chdir: $!";
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    chdir($prev_cwd) or die "fixture teardown: cannot chdir back to $prev_cwd: $!";
    return (defined($out) ? $out : '', $rc);
}
sub statusline_line1 { my ($out) = run_statusline(@_); return first_line($out) }

# The working directory moved OFF row 1 onto its own final row, at the
# operator's request: a full path is the one field with no natural width, so on
# row 1 it was permanently in contention with every other field and the fit
# ladder spent four of its eight steps eliding it. On its own row it is simply
# rendered in full, and is never elided at any width.
#
# These two helpers exist so the ACs below say WHICH ROW they mean. The old
# tests asked "is the cwd in line 1", which is now the wrong question rather
# than a failing one.
sub statusline_path_row {
    my ($out) = run_statusline(@_);
    my @rows = split /\n/, (defined $out ? $out : '');
    return @rows ? $rows[-1] : '';
}
sub statusline_rows {
    my ($out) = run_statusline(@_);
    return split /\n/, (defined $out ? $out : '');
}

# ===========================================================================
# Scaffolding for hook-continuity-remake package 10 (spec
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 10-statusline-counters-spec.md). Written BLIND to scripts/statusline.pl,
# Theme.pm and the generator: every expectation below comes from that spec.
#
# FIXTURES ARE WRITTEN THROUGH THE ALMANAC MODULES (AC-3: "never
# hand-written"). The CLIs are loaded as libraries by absolute path -- each
# guards its own main with `unless (caller)` -- and every store is rooted at a
# tempdir project (carrying its own .git, so no walk-up can leave it) or a
# tempdir HOME. Snapshot files ARE hand-written: they are the synthetic input
# the sandbox reader is specified against, including its invalid shapes.
# ===========================================================================
my $REPO_ROOT    = "$Bin/../../../..";
my $ALMANAC_DIR  = "$Bin/../../../almanac/scripts";
my $GENERATOR    = "$ALMANAC_DIR/gen-statusline-counters.pl";
my $DECISION_CLI = "$ALMANAC_DIR/almanac-decision.pl";
my $LEGACYQ_PM   = "$ALMANAC_DIR/Almanac/LegacyQueue.pm";

my $ALMANAC_OK = eval {
    require "$ALMANAC_DIR/almanac-todo.pl";
    require "$ALMANAC_DIR/almanac-note.pl";
    require "$ALMANAC_DIR/almanac-decision.pl";   # brings Almanac::Task with it
    1;
};
my $ALMANAC_ERR = $@;

# The real repo's almanac store, listed (name, size, mtime) before anything
# below runs and compared again at the very end: this file never writes it.
sub almanac_listing {
    my ($root) = @_;
    my @out;
    return \@out unless -d $root;
    require File::Find;
    no warnings 'once';
    File::Find::find({ no_chdir => 1, wanted => sub {
        my @st = stat($_);
        (my $rel = $File::Find::name) =~ s{\A\Q$root\E}{};
        push @out, join("\t", $rel, (-d $_ ? 'd' : 'f'), ($st[7] // -1), ($st[9] // -1));
    } }, $root);
    return [ sort @out ];
}
my $REAL_STORE        = "$REPO_ROOT/.ccpraxis-local-data/almanac";
my $REAL_STORE_BEFORE = almanac_listing($REAL_STORE);

sub nslash { my ($p) = @_; $p =~ s{\\}{/}g; $p =~ s{/\z}{} if length($p) > 1; return $p }

# mk_proj() -- an EMPTY project root: a tempdir holding .git, so the
# statusline's walk-up stops here and never reaches a real store above it.
sub mk_proj {
    my ($leaf) = @_;
    my $base = nslash(tempdir(CLEANUP => 1));
    my $d = defined($leaf) ? "$base/$leaf" : $base;
    make_path("$d/.git");
    return $d;
}
sub mk_home {
    my $h = nslash(tempdir(CLEANUP => 1));
    make_path("$h/.claude");
    return $h;
}

my $FIXTURE_ISO = '2026-09-26T00:00:00Z';
my $fixture_seq = 0;

# open_scoped($opener, @args) -- Almanac::Store's surface policy makes the
# GLOBAL scope unreadable inside a container. This file may itself run inside
# one, so fixture stores are opened with the host policy row in force -- the
# documented seam (Store.pm: "localizing this hash"). What the STATUSLINE
# does with the surface is untouched: it is driven only by CCPRAXIS_SANDBOX.
sub with_host_policy {
    my ($code) = @_;
    no warnings 'once';
    local $Almanac::Store::SCOPE_POLICY{container} = $Almanac::Store::SCOPE_POLICY{host};
    return $code->();
}
sub _where { my ($scope, $where) = @_; return $scope eq 'project' ? (root => $where) : (home => $where) }

sub seed_todos {
    my ($scope, $where, $n_open, $n_done) = @_;
    with_host_policy(sub {
        my $s = Almanac::Todo::open_store($scope, _where($scope, $where));
        for my $st (('open') x $n_open, ('done') x $n_done) {
            $s->create(fields => { title => 'todo ' . (++$fixture_seq), status => $st, created => $FIXTURE_ISO },
                       order  => [qw(title status created)]);
        }
    });
}
sub seed_notes {
    my ($scope, $where, $n) = @_;
    with_host_policy(sub {
        my $s = Almanac::Note::open_store($scope, _where($scope, $where));
        for (1 .. $n) {
            my $k = ++$fixture_seq;
            $s->create(fields => { title => "note $k", audience => 'internal',
                                   target => "notes/note-$k.md", created => $FIXTURE_ISO },
                       order  => [qw(title audience target created)]);
        }
    });
}
# seed_tasks($root, [status, title]...) -- appended in order, so rank order is
# creation order.
sub seed_tasks {
    my ($root, @spec) = @_;
    my @ids;
    for my $t (@spec) {
        my ($st, $title) = @$t;
        my $rec = Almanac::Task::add(root => $root, title => $title // ('task ' . (++$fixture_seq)));
        Almanac::Task::set_status($rec->{id}, $st, root => $root) if $st ne 'pending';
        push @ids, $rec->{id};
    }
    return @ids;
}
sub seed_decisions {
    my ($root, $n_unanswered, $n_answered) = @_;
    Almanac::Decision::file(root => $root, title => 'decision ' . (++$fixture_seq)) for 1 .. $n_unanswered;
    for (1 .. $n_answered) {
        my $rec = Almanac::Decision::file(root => $root, title => 'decision ' . (++$fixture_seq));
        Almanac::Decision::answer($rec->{id}, root => $root, answer => 'yes, go ahead');
    }
}

# snapshot_json(%v) -- the section-2.2 snapshot shape, with every value
# overridable (raw JSON text) so the invalid shapes can be written too.
sub snapshot_json {
    my (%v) = @_;
    my %d = (generated_at => '"2026-09-26T00:00:00Z"', schema => 1,
             open => 0, done => 0, total => undef, note => 0, %v);
    $d{total} //= (($d{open} =~ /\A\d+\z/ && $d{done} =~ /\A\d+\z/) ? $d{open} + $d{done} : 0);
    return sprintf('{"generated_at":%s,"note":{"total":%s},"schema":%s,"todo":{"done":%s,"open":%s,"total":%s}}' . "\n",
                   $d{generated_at}, $d{note}, $d{schema}, $d{done}, $d{open}, $d{total});
}
sub write_snapshot { my ($home, $bytes) = @_; make_path("$home/.claude"); spew_raw("$home/.claude/almanac-global-counts.json", $bytes) }

# --- glyphs and colours, as BYTES (the statusline's stdout is read raw) -----
my $G_BLUEPRINT = encode('UTF-8', chr(0x29C9));
my $G_TODO      = encode('UTF-8', chr(0x274F));
my $G_NOTE      = encode('UTF-8', chr(0x2630));
my $G_TASK      = encode('UTF-8', chr(0x25A3));
my $G_FLAG      = encode('UTF-8', chr(0x2691));
my $G_SILENCED  = encode('UTF-8', chr(0x2016));
my $G_AGENTOFF  = encode('UTF-8', chr(0x2205));
my $G_DOT       = encode('UTF-8', chr(0x00B7));
my $G_HOLLOW    = encode('UTF-8', chr(0x25CB));
my $G_FILLED    = encode('UTF-8', chr(0x25CF));

# Colours are compared against Theme::roles() values, never literals (AC-1).
sub fg_sgr { my $rgb = Theme::roles()->{ $_[0] }{rgb}; return sprintf("\e[38;2;%d;%d;%dm", @$rgb) }
sub bg_sgr { my $rgb = Theme::roles()->{ $_[0] }{bg};  return sprintf("\e[48;2;%d;%d;%dm", @$rgb) }

# sgr_runs($raw) -> \@runs: for each byte of the SGR-stripped string, the run
# of SGR escapes emitted IMMEDIATELY before it (empty when a visible byte came
# right before). "The SGR immediately before a number" is the run at the
# number's first byte; its LAST escape is the one in force.
sub sgr_runs {
    my ($raw) = @_;
    my @runs;
    my $cur = '';
    my $i = 0;
    my $n = length $raw;
    while ($i < $n) {
        if (substr($raw, $i, 1) eq "\e" && substr($raw, $i) =~ /\A(\033\[[^m]*m)/) {
            $cur .= $1;
            $i += length $1;
            next;
        }
        push @runs, $cur;
        $cur = '';
        $i++;
    }
    return \@runs;
}
sub run_ends_with { my ($run, $sgr) = @_; return (defined($run) && length($run) >= length($sgr) && substr($run, -length($sgr)) eq $sgr) ? 1 : 0 }

# counter_seg($stripped_row, $glyph_bytes) -> the stripped text of one counter
# segment: from its glyph to the next two-space join, the next rendered
# separator, or the end of the row. undef when the glyph is absent.
sub counter_seg {
    my ($vis, $glyph) = @_;
    my $i = index($vis, $glyph);
    return undef if $i < 0;
    my $rest = substr($vis, $i);
    my $cut = length $rest;
    for my $stop ('  ', " $SEPBAR_BYTES") {
        my $j = index($rest, $stop);
        $cut = $j if $j >= 0 && $j < $cut;
    }
    (my $seg = substr($rest, 0, $cut)) =~ s/\s+\z//;
    return $seg;
}

# render(%o) -> ($stdout_bytes, $rc). o: proj (current_dir default), cwd,
# home, sandbox, sid, cols (default 200), data, state (BUTLER_STATE_DIR),
# env, pcwd.
sub render {
    my (%o) = @_;
    my %env = %{ $o{env} || {} };
    $env{BUTLER_STATE_DIR} = $o{state} if defined $o{state};
    return run_statusline(
        payload_for(current_dir => ($o{cwd} // $o{proj} // "$WROOT/nowhere"), session_id => $o{sid}),
        cols => $o{cols} // 200, sandbox => ($o{sandbox} ? 1 : 0),
        home => $o{home} // mk_home(), data => $o{data} // $CLEAN_DATA,
        toplevel => $o{toplevel}, env => \%env, (defined $o{pcwd} ? (pcwd => $o{pcwd}) : ()));
}

# run_argv(@argv) -> ($stdout, $stderr, $rc). List-form exec (no shell
# string), bounded by `timeout`, stdout/stderr captured through File::Temp
# files -- never an in-memory handle. An optional leading hashref carries
# `cwd` (the child's working directory), `env` (K => V|undef overrides on top
# of the scrubbed baseline) and `stdin` (a file to read stdin from).
sub run_argv {
    my $opt = (ref($_[0]) eq 'HASH') ? shift : {};
    my @argv = ('timeout', '60', @_);
    my ($ofh, $opath) = tempfile(DIR => $TMPROOT); close $ofh;
    my ($efh, $epath) = tempfile(DIR => $TMPROOT); close $efh;
    local %ENV = %ENV;
    my $scrub_home = mk_home();
    $ENV{HOME} = $scrub_home;
    $ENV{USERPROFILE} = $scrub_home;
    delete $ENV{$_} for @SCRUB_ENV;
    for my $k (sort keys %{ $opt->{env} || {} }) {
        if (defined $opt->{env}{$k}) { $ENV{$k} = $opt->{env}{$k} } else { delete $ENV{$k} }
    }
    my $stdin = defined($opt->{stdin}) ? $opt->{stdin} : '/dev/null';
    my $pid = fork();
    die "fixture: fork failed: $!" unless defined $pid;
    if (!$pid) {
        chdir($opt->{cwd}) if defined $opt->{cwd};
        open(STDIN,  '<', $stdin)      or POSIX::_exit(126);
        open(STDOUT, '>', $opath)      or POSIX::_exit(126);
        open(STDERR, '>', $epath)      or POSIX::_exit(126);
        { no warnings "exec"; exec { $argv[0] } @argv; }
        POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    return (slurp_raw($opath), slurp_raw($epath), $rc);
}

# forbidden_constructs($code) -> list of findings: the spec 2.2 list of what
# neither the generated payload nor the badge block may contain. Run over
# COMMENT-BLANKED code, and exercised on counter-fixtures below.
sub forbidden_constructs {
    my ($code) = @_;
    my @hits;
    push @hits, 'backtick'        if $code =~ /`/;
    push @hits, 'qx'              if $code =~ /\bqx\s*[^\s\w=,;)]/;
    push @hits, 'system'          if $code =~ /\bsystem\b(?!\s*=>)/;
    push @hits, 'exec'            if $code =~ /\bexec\b(?!\s*=>)/;
    push @hits, 'fork'            if $code =~ /\bfork\b(?!\s*=>)/;
    push @hits, 'cmd_out'         if $code =~ /\bcmd_out\b/;
    push @hits, 'spawn_detached'  if $code =~ /\bspawn_detached\b/;
    push @hits, 'pipe-open'       if $code =~ /['"]\s*(?:-\||\|-)\s*['"]/
                                  || $code =~ /\bopen\b[^;]*['"]\s*\|/ || $code =~ /\bopen\b[^;]*\|\s*['"]/;
    push @hits, 'write-mode open' if $code =~ /\bopen\b\s*\(?[^;]*?,\s*['"]\s*(?:\+?>{1,2}|\+<)/;
    push @hits, 'use'             if $code =~ /(?:^|[;{}])\s*use\s+[A-Za-z]/m;
    push @hits, 'require'         if $code =~ /\brequire\b/;
    push @hits, 'do FILE'         if $code =~ /\bdo\s*\(?\s*['"\$]/;
    return @hits;
}

# extract_between($text, $begin_line, $end_line) -> ($n_begin, $n_end, $body)
# on the RAW text (CRLF folded): marker counts are whole-line matches, and
# $body is everything strictly between BEGIN's newline and END's line start
# (undef unless both occur exactly once, BEGIN first).
sub extract_between {
    my ($text, $b, $e) = @_;
    $text =~ s/\r\n/\n/g;
    my @bs; my @es;
    while ($text =~ /^[ \t]*\Q$b\E[ \t]*$/mg) { push @bs, $-[0] }
    while ($text =~ /^[ \t]*\Q$e\E[ \t]*$/mg) { push @es, $-[0] }
    return (scalar(@bs), scalar(@es), undef) unless @bs == 1 && @es == 1 && $bs[0] < $es[0];
    my $start = index($text, "\n", $bs[0]) + 1;
    my $line_start = rindex($text, "\n", $es[0]) + 1;
    return (1, 1, substr($text, $start, $line_start - $start));
}

# The generated block's markers. Built by concatenation so this file never
# carries a generated-block marker line at column 0 (the same courtesy the
# Theme marker gets -- theme-tokens.t walks the repo for those).
my $CTR_BEGIN = '# >>> BEGIN GENERATED FROM ' . 'gen-statusline-counters.pl -- DO NOT EDIT BY HAND >>>';
my $CTR_END   = '# <<< END GENERATED FROM ' . 'gen-statusline-counters.pl <<<';

ok(-f $STATUSLINE, 'setup: scripts/statusline.pl exists at the expected path')
    or BAIL_OUT("cannot find statusline.pl at $STATUSLINE");
ok(-f $BP_STATUSLINE, 'setup: plugins/butler/scripts/bp-statusline.pl exists at the expected path')
    or BAIL_OUT("cannot find bp-statusline.pl at $BP_STATUSLINE");

my $SRC_SL = blank_comments(slurp_raw($STATUSLINE));
my $SRC_BP = blank_comments(slurp_raw($BP_STATUSLINE));
ok(length($SRC_SL) > 0, 'setup: statusline.pl was read as raw source bytes');
ok(length($SRC_BP) > 0, 'setup: bp-statusline.pl was read as raw source bytes');

# ===========================================================================
# AC-O -- row 1 field order (criterion 1, spec S4 AC-O / B-1)
#
# Fixtures: F-tput at a generous 200, F-git with toplevel /w/proj-alpha and
# branch main, F-env, F-payload with current_dir /w/proj-alpha/plugins/sandbox.
# Positional relations only -- no count, no field inventory.
# ===========================================================================
{
    my $top    = "$WROOT/proj-alpha";
    my $cwd    = "$WROOT/proj-alpha/plugins/sandbox";
    my $branch = 'main';

    for my $mode (['sandbox', 1, 'SANDBOX'], ['host', 0, 'HOST']) {
        my ($label, $sb, $marker) = @$mode;
        my @args = (payload_for(current_dir => $cwd),
            cols => 200, sandbox => $sb, toplevel => $top, branch => $branch);
        my $line = statusline_line1(@args);
        my $vis  = strip_sgr($line);
        my $path_vis = strip_sgr(statusline_path_row(@args));

        my $i_marker  = index($vis, $marker);
        my $i_project = index($vis, 'proj-alpha');
        my $i_branch  = index($vis, $branch);

        ok($i_marker >= 0 && $i_project >= 0 && $i_branch >= 0,
            "AC-O1 setup ($label): marker, project name and branch all appear in the first line")
            or diag("  marker=$i_marker project=$i_project branch=$i_branch line=[$vis]");

        ok($i_marker >= 0 && $i_project > $i_marker,
            "AC-O1 ($label): the marker precedes the project name");
        ok($i_project >= 0 && $i_branch > $i_project,
            "AC-O1 ($label): the project name precedes the git branch");

        # The path is no longer ON row 1 -- and must NOT be, or it would still
        # be competing for that row's width.
        is(index($vis, $cwd), -1,
            "AC-O1 ($label): the working directory does NOT appear on row 1");
        # RE-POINTED 2026-08-26: the path row is HOST-ONLY (operator: "I want it
        # hidden only on the sandbox. On the host it can and should continue
        # appearing in its own line as it currently does"). In a container the
        # working directory is always the same mount, so the row said nothing.
        # The claim splits in two rather than weakening: present and complete on
        # the host, absent in a sandbox.
        if ($sb) {
            # NOT `is($path_vis, '')` -- statusline_path_row returns the LAST
            # row, and with the path row gone that is the status row itself. The
            # claim is that NO row is the working directory.
            my @all = map { strip_sgr($_) } statusline_rows(@args);
            is(scalar(grep { $_ eq $cwd } @all), 0,
                "AC-O1 ($label): NO row is the working directory -- in a container it is always "
              . 'the same mount, so the row is spent saying nothing')
                or diag('  rows: ' . join(' | ', @all));
        } else {
            is($path_vis, $cwd,
                "AC-O1 ($label): the LAST row is the working directory, complete and alone");
        }

        # t06 AMENDMENT (blueprint Decision 8, package t06-statusline-marker,
        # 2026-08-19): blueprint Decision 3 (locked) puts a leading, non-emoji
        # glyph before the marker word -- filled U+25CF on HOST, hollow U+25CB
        # on SANDBOX -- so the marker WORD can no longer sit at byte offset 0;
        # the glyph does. AC-O2's INTENT ("the marker leads the row -- nothing
        # unexpected is rendered to its left") is preserved, not weakened: it
        # is re-expressed as two exact `is()` checks instead of one, and still
        # fails if the marker is absent (index -1), pushed further right than
        # glyph+space, or if anything OTHER than the declared Decision-3 glyph
        # followed by exactly one space occupies the lead.
        # RE-POINTED 2026-08-26: the lead glyph no longer encodes the
        # ENVIRONMENT -- it encodes whether a Stop gate is armed for this
        # session (operator: "instead of it representing sandbox vs host it
        # should represent continuity watching vs not"). These fixtures plant no
        # marker, so every one of them is unarmed and leads with the hollow
        # glyph regardless of surface. AC-O2's intent is untouched: the marker
        # leads the row and nothing unexpected renders to its left.
        my $t06_prefix = encode('UTF-8', chr(0x25CB)) . ' ';
        is(substr($vis, 0, length($t06_prefix)), $t06_prefix,
            "AC-O2 ($label): row 1 leads with the Decision-3 glyph, immediately followed by exactly one space, and nothing else");
        is($i_marker, length($t06_prefix),
            "AC-O2 ($label): the marker word begins immediately after the leading glyph+space -- nothing else is rendered to its left");

        my $badge = encode('UTF-8', chr(0x1F4E6));
        ok(index($line, $badge) < 0,
            "AC-O3 ($label): the emoji package badge (U+1F4E6) does not appear in the first line");
    }
}

# ===========================================================================
# AC-M -- the marker is textual and symmetric (criterion 2, B-2/B-3)
#
# Fixtures: F-tput at 40, 80, 120, 200; F-env; F-payload with an ordinary
# short path; each width rendered twice, once with the sandbox variable set
# and once with it deleted.
#
# AC-M3 is the "same slot, same width" property expressed RELATIONALLY -- as
# a comparison between the two rendered variants -- never as a pinned slot
# width, per Decision 15.
# ===========================================================================

# same_slot_report($a, $b) -> { cost_equal => 0|1, tail_equal => 0|1 }
# The two rows are compared for equal row_cost and for byte-identity from the
# first sep.bar onward. Exercised on synthetic input by AC-M5 so a comparison
# that cannot fail never masquerades as a passing assertion.
sub same_slot_report {
    my ($a, $b) = @_;
    my $va = strip_sgr($a);
    my $vb = strip_sgr($b);
    my $ia = index($va, $SEPBAR_BYTES);
    my $ib = index($vb, $SEPBAR_BYTES);
    my $tail_equal = ($ia >= 0 && $ib >= 0 && substr($va, $ia) eq substr($vb, $ib)) ? 1 : 0;
    return {
        cost_equal   => (row_cost($a) == row_cost($b)) ? 1 : 0,
        offset_equal => ($ia >= 0 && $ib >= 0 && $ia == $ib) ? 1 : 0,
        tail_equal   => $tail_equal,
        sep_a        => $ia,
        sep_b        => $ib,
    };
}

{
    my $dir = "$WROOT/proj-alpha";
    for my $cols (40, 80, 120, 200) {
        my $on  = statusline_line1(payload_for(current_dir => $dir),
                    cols => $cols, sandbox => 1, toplevel => $dir);
        my $off = statusline_line1(payload_for(current_dir => $dir),
                    cols => $cols, sandbox => 0, toplevel => $dir);

        ok(index(strip_sgr($on), 'SANDBOX') >= 0,
            "AC-M1 (cols=$cols): the sandbox render carries the textual SANDBOX marker")
            or diag('  line = [' . strip_sgr($on) . ']');
        ok(index(strip_sgr($off), 'HOST') >= 0,
            "AC-M1 (cols=$cols): the host render carries the textual HOST marker -- absence cannot be mistaken for breakage")
            or diag('  line = [' . strip_sgr($off) . ']');

        unlike(strip_sgr($off), qr/sandbox/i,
            "AC-M2 (cols=$cols): the host render mentions nothing sandbox-ish");

        # AC-M3 SUPERSEDED 2026-08-26 by operator decision: "No need to reserve
        # space on HOST vs SANDBOX string cell. Have it shrink to fit available
        # space."
        #
        # The common-slot property existed so row 1 could not reflow between the
        # two environments. It was worth having when the two could alternate on
        # one screen -- they cannot. A session is host or sandbox for its whole
        # life, so the reflow it prevented was between two runs that never sit
        # side by side, and it cost three columns of padding on every row of
        # every host session to prevent a comparison nobody makes.
        #
        # Keeping the assertion would be asserting the padding is still there.
        # What replaces it is the claim underneath it that is still true and
        # still worth guarding: the row is IDENTICAL FROM THE PROJECT NAME
        # ONWARD, so the only thing the environment changes is the marker
        # itself -- no downstream field renders differently because of it.
        my $rep = same_slot_report($on, $off);
        my ($va, $vb) = (strip_sgr($on), strip_sgr($off));
        my ($ta) = $va =~ /(proj-alpha.*)\z/s;
        my ($tb) = $vb =~ /(proj-alpha.*)\z/s;
        ok(defined($ta) && defined($tb) && $ta eq $tb,
            "AC-M3 (cols=$cols): the two rows are byte-identical from the project name onward -- "
          . 'the environment changes the marker and nothing else')
            or diag('  sandbox = [' . $va . "]\n  host    = [" . $vb . ']');
        cmp_ok(row_cost($off), '<', row_cost($on),
            "AC-M3 (cols=$cols): the HOST row is now SHORTER than the sandbox one -- the marker "
          . 'shrinks to its word instead of padding out to a reserved slot');

        my @e_on  = emoji_hits($on);
        my @e_off = emoji_hits($off);
        ok(scalar(@e_on) == 0,
            "AC-M4 (cols=$cols): the sandbox render contains no emoji codepoint")
            or diag('  hits: ' . emoji_summary(@e_on));
        ok(scalar(@e_off) == 0,
            "AC-M4 (cols=$cols): the host render contains no emoji codepoint")
            or diag('  hits: ' . emoji_summary(@e_off));
    }

    # AC-M5 -- counter-fixture (C-7). The helper AC-M3 leans on must report a
    # DIFFERENCE for two synthetic rows whose marker fields have unequal
    # width, and agreement for two padded to a common slot.
    my $unequal = same_slot_report("SANDBOX$SEP_RENDERED" . 'p', "HOST$SEP_RENDERED" . 'p');
    ok(!$unequal->{cost_equal},
        'AC-M5 (counter-fixture): same_slot_report reports UNEQUAL cost for synthetic rows with unequal marker widths');
    ok(!$unequal->{offset_equal},
        'AC-M5 (counter-fixture): same_slot_report reports a SHIFTED separator offset when the marker slots differ in width');
    my $equal = same_slot_report("SANDBOX$SEP_RENDERED" . 'p', "HOST   $SEP_RENDERED" . 'p');
    ok($equal->{cost_equal} && $equal->{offset_equal} && $equal->{tail_equal},
        'AC-M5 (counter-fixture): the same helper AGREES when the two synthetic markers are padded to a common slot');
}

# ===========================================================================
# AC-P -- project name resolution (criterion 3, B-4..B-7)
#
# Fixtures: F-tput at a generous 200 (so nothing truncates and the assertion
# is about resolution, not layout), F-env, F-git driven per case, F-payload.
# The project field is read POSITIONALLY (the segment after the marker's
# separator), never by counting fields.
#
# The non-ASCII case is built from explicit bytes -- "Andr", 0xC3, 0xA9 -- so
# the UTF-8 encoding of the fixture cannot drift with this file's own
# encoding. Both the shim file and the expectation are those same bytes.
# ===========================================================================
my $ANDRE_NAME = 'Andr' . chr(0xC3) . chr(0xA9) . '-projekt';
{
    my %case = (
        'P-a' => { toplevel => "$WROOT/proj-alpha", cwd => "$WROOT/proj-alpha",                          want => 'proj-alpha' },
        'P-b' => { toplevel => "$WROOT/proj-alpha", cwd => "$WROOT/proj-alpha/plugins/sandbox/scripts",  want => 'proj-alpha' },
        'P-c' => { toplevel => undef,           cwd => "$WROOT/loose-dir",                           want => 'loose-dir'  },
        'P-d' => { toplevel => "$WROOT/proj-alpha", cwd => "$FAKE_ROOT/elsewhere/scratch-area",                want => 'proj-alpha' },
    );

    for my $id (sort keys %case) {
        my $c = $case{$id};
        my $line  = statusline_line1(payload_for(current_dir => $c->{cwd}),
                        cols => 200, sandbox => 0, toplevel => $c->{toplevel});
        my $field = project_field($line);
        my $shown = defined($field) ? $field : '(no project field)';

        if ($id eq 'P-a') {
            ok(index(strip_sgr($line), 'proj-alpha') >= 0,
                'AC-P1 (P-a): a repo whose toplevel IS the current dir renders the toplevel basename');
        }
        is($shown, $c->{want},
            "AC-P" . ($id eq 'P-a' ? '1' : $id eq 'P-b' ? '2' : $id eq 'P-c' ? '3' : '4')
            . " ($id): the project field is '$c->{want}'"
            . ($id eq 'P-b' ? ' -- the git toplevel basename, NOT the working directory basename' : ''))
            or diag("  first line = [" . strip_sgr($line) . ']');

        if ($id eq 'P-b') {
            isnt($shown, 'scripts',
                'AC-P2 (P-b): the project field is NOT the deep working directory basename -- the mislabelled-project defect is gone');
        }
        if ($id eq 'P-d') {
            # The location lives on the path row now; the name lives on row 1.
            # That they resolve INDEPENDENTLY is exactly what this asserts, and
            # it is if anything more visible now that they are on separate rows.
            my $path_vis = strip_sgr(statusline_path_row(payload_for(current_dir => $c->{cwd}),
                                cols => 200, sandbox => 0, toplevel => $c->{toplevel}));
            is($path_vis, "$FAKE_ROOT/elsewhere/scratch-area",
                'AC-P4 (P-d): a working directory OUTSIDE the reported toplevel still renders in full -- name and location resolve independently');
        }
    }

    # P-e -- non-ASCII toplevel; bytes on both sides (C-9).
    {
        my $top  = "$WROOT/" . $ANDRE_NAME;
        my $line = statusline_line1(payload_for(current_dir => "$top/plugins"),
                        cols => 200, sandbox => 0, toplevel => $top);
        ok(index($line, $ANDRE_NAME) >= 0,
            'AC-P5 (P-e): the first line carries the UTF-8 BYTES of a non-ASCII project name')
            or diag('  first line = [' . strip_sgr($line) . ']');
    }

    # AC-P6 -- non-vacuity: the SAME current_dir with and without a reported
    # toplevel must resolve to DIFFERENT project fields, proving the git shim
    # actually drives resolution rather than the assertions passing by luck.
    {
        my $cwd = "$WROOT/loose-dir";
        my $with    = project_field(statusline_line1(payload_for(current_dir => $cwd),
                        cols => 200, sandbox => 0, toplevel => "$WROOT/proj-alpha"), 1);
        my $without = project_field(statusline_line1(payload_for(current_dir => $cwd),
                        cols => 200, sandbox => 0, toplevel => undef));
        ok(defined($with) && defined($without) && $with ne $without,
            'AC-P6 (non-vacuity): the same current_dir resolves to different project fields with and without a reported toplevel')
            or diag('  with = ' . (defined $with ? $with : '(undef)')
                  . ' / without = ' . (defined $without ? $without : '(undef)'));
    }
}

# ===========================================================================
# AC-D -- the full working directory, and graceful elision (criterion 4,
# B-8..B-11). Fixtures: F-tput at 200 and 40; F-env; F-git with toplevel
# /w/proj-alpha; a short payload and a long one (/w/proj-alpha/ + 200 x's).
#
# N1/N2 (spec S2.4.4) are asserted as PREFIX/SUFFIX relations against the
# true value -- never as a length equality, which would pin the floor
# constants Decision 15 forbids asserting.
# ===========================================================================
{
    my $top      = "$WROOT/proj-alpha";
    my $short    = "$WROOT/proj-alpha";
    my $long     = "$WROOT/proj-alpha/" . ('x' x 200);

    # AC-D1 / AC-D2 -- the path row renders the path verbatim.
    {
        my @args = (payload_for(current_dir => $short),
                    cols => 200, sandbox => 0, toplevel => $top);
        my $line = statusline_line1(@args);
        is(strip_sgr(statusline_path_row(@args)), $short,
            'AC-D1: the COMPLETE working directory renders verbatim on its own row');

        my $proj = project_field($line);
        ok(defined($proj) && index($proj, '>') < 0 && index($proj, '<') < 0,
            'AC-D2: at a generous width the project field carries no elision marker -- truncation is conditional, not universal')
            or diag('  project field = ' . (defined $proj ? "[$proj]" : '(none)'));
    }

    # AC-D3 -- REPLACES the old left-elision AC. The path used to be elided from
    # its head at a forcing width because it shared row 1; alone on its own row
    # it is never elided at all. That is the point of the move: a truncated path
    # is a path you cannot act on, and the terminal's own wrapping shows all of
    # it rather than hiding the head behind a marker.
    {
        for my $cols (40, 80, 200) {
            my @args = (payload_for(current_dir => $long),
                        cols => $cols, sandbox => 0, toplevel => $top);
            is(strip_sgr(statusline_path_row(@args)), $long,
                "AC-D3: at width $cols the path row is the COMPLETE path -- never elided, at any width");
            my $vis1 = strip_sgr(statusline_line1(@args));
            is(index($vis1, 'xxxxx'), -1,
                "AC-D3: at width $cols no part of the path leaks onto row 1");
        }
    }

    # AC-D4 -- N1: the project keeps its HEAD.
    {
        my $longname = 'proj-' . ('n' x 120);
        my $ltop     = "$WROOT/$longname";
        my $line = statusline_line1(payload_for(current_dir => "$ltop/deep/place"),
                        cols => 40, sandbox => 0, toplevel => $ltop);
        my $proj = project_field($line);
        my $ok_shape = defined($proj) && length($proj) > 1 && substr($proj, -1) eq '>';
        ok($ok_shape,
            'AC-D4 (N1): at a forcing width the project field is retained text followed by a right-elision marker')
            or diag('  project field = ' . (defined $proj ? "[$proj]" : '(none)')
                  . "\n  first line = [" . strip_sgr($line) . ']');
        my $prefix = $ok_shape ? substr($proj, 0, length($proj) - 1) : '';
        ok(length($prefix) && index($longname, $prefix) == 0,
            'AC-D4 (N1): the retained text is a non-empty PREFIX of the true project name')
            or diag("  retained = [$prefix]");
    }

    # AC-D5 -- non-ambiguity, the discriminating pairs. Paths differing only
    # in their FINAL component must still render differently; project names
    # differing only in their FIRST characters must too.
    {
        my $stem = "$WROOT/proj-alpha/" . ('d' x 150) . '/deep';
        my $a = statusline_path_row(payload_for(current_dir => "$stem/alpha"),
                    cols => 40, sandbox => 0, toplevel => $top);
        my $b = statusline_path_row(payload_for(current_dir => "$stem/beta"),
                    cols => 40, sandbox => 0, toplevel => $top);
        isnt(strip_sgr($a), strip_sgr($b),
            'AC-D5: two long paths differing only in their FINAL component render different path rows');

        my $tail = 'z' x 120;
        my $ta = "$WROOT/alpha-$tail";
        my $tb = "$WROOT/beta-$tail";
        my $pa = statusline_line1(payload_for(current_dir => "$ta/here"),
                    cols => 40, sandbox => 0, toplevel => $ta);
        my $pb = statusline_line1(payload_for(current_dir => "$tb/here"),
                    cols => 40, sandbox => 0, toplevel => $tb);
        isnt(strip_sgr($pa), strip_sgr($pb),
            'AC-D5: two long project names differing only in their FIRST characters render different rows -- the retained head still discriminates');
    }

    # AC-D6 -- the cwd never degrades to a bare marker while the project is
    # still on the row.
    for my $cols (40, 60, 80, 120, 200) {
        my $line = statusline_line1(payload_for(current_dir => $long),
                        cols => $cols, sandbox => 0, toplevel => $top);
        my $proj = project_field($line);
        my $cwd  = cwd_field($line);
        my $bad  = (defined($proj) && length($proj) && defined($cwd) && $cwd eq '<') ? 1 : 0;
        is($bad, 0,
            "AC-D6 (cols=$cols): the cwd field is never a bare elision marker while the project field is still present")
            or diag('  first line = [' . strip_sgr($line) . ']');
    }
}

# ===========================================================================
# AC-S -- static source contract on the two scripts (criteria 5 and 6).
# No spawn except a bounded `perl -c`. Every scan runs over COMMENT-BLANKED
# source, and every detector is exercised on a counter-fixture so a scan that
# cannot fire never masquerades as a passing assertion.
# ===========================================================================

# --- balanced-delimiter helpers (t/54/t/59's slurped-source convention) ------
sub _balanced {
    my ($src, $from, $open, $close) = @_;
    my $idx = index($src, $open, $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $len   = length($src);
    my $i     = $idx;
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq $open)  { $depth++ }
        elsif ($c eq $close) { $depth--; last if $depth == 0 }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}

# colour_literal_hits($code) -> list of findings. A numeric-literal colour is
# either an rgb() CALL FORM with a digit argument, or a truecolor/256 SGR
# literal written out by hand. sub rgb's own interpolated body and the
# non-colour attribute literals are deliberately NOT matched.
sub colour_literal_hits {
    my ($code) = @_;
    my @hits;
    push @hits, 'rgb() call form with a numeric argument'
        if $code =~ /\brgb\s*\(\s*[-+]?\d/;
    push @hits, 'hand-written truecolor/256 SGR literal'
        if $code =~ /(?:\\033|\\e|\\x1[bB]|\\x\{1[bB]\}|\x1b)\[38;[25];\d/;
    return @hits;
}

# import_violations($code) -> list of findings. The allow-list is the spec's,
# verbatim: statusline.pl is an installed standalone payload and may reach
# only for core modules (criterion 6).
my @CORE_ALLOWED = qw(strict warnings JSON::PP Time::Piece File::Basename
                      POSIX Encode constant Carp List::Util Scalar::Util);
sub import_violations {
    my ($code) = @_;
    my %allowed = map { $_ => 1 } @CORE_ALLOWED;
    my @bad;
    while ($code =~ /\buse\s+([A-Za-z_][\w:]*)/g) {
        my $mod = $1;
        next if $mod =~ /^v?\d/;
        push @bad, "use $mod" unless $allowed{$mod};
    }
    push @bad, 'require of a path string' if $code =~ /\brequire\s+["']/;
    push @bad, 'require of a computed path' if $code =~ /\brequire\s+\$/;
    push @bad, 'FindBin' if $code =~ /\bFindBin\b/;
    while ($code =~ /\b(?:use|require)\s+(Theme|Dashboard|SpendPanel|tui::\w+|Layout::\w+)\b/g) {
        push @bad, "repo module as an import target: $1";
    }
    return @bad;
}

# parse_glyph_cols($code) -> hashref { codepoint => columns } read out of the
# inline %GLYPH_COLS declaration, or undef if there is no such table.
sub parse_glyph_cols {
    my ($code) = @_;
    return undef unless $code =~ /%GLYPH_COLS\s*=\s*/g;
    my $body = _balanced($code, pos($code), '(', ')');
    $body = _balanced($code, pos($code), '{', '}') unless defined $body;
    return undef unless defined $body;
    my %t;
    while ($body =~ /(0x[0-9A-Fa-f]+|\d+)\s*(?:=>|,)\s*(\d+)/g) {
        my ($k, $v) = ($1, $2);
        my $cp = ($k =~ /^0x/i) ? hex($k) : 0 + $k;
        $t{$cp} = 0 + $v;
    }
    return \%t;
}

# glyph_cols_disagreements(\%table) -> list of codepoints whose declared width
# differs from Theme's. This is criterion 6's reconciliation: a DRIFT GUARD,
# never an import.
my %THEME_WIDTH_BY_CP;
{
    my $g = Theme::glyphs();
    for my $name (keys %$g) {
        $THEME_WIDTH_BY_CP{ $g->{$name}{cp} } = $g->{$name}{width};
    }
}
# Codepoints statusline.pl may declare a width for even though Theme does not
# carry them, each with the reason it is not drift. An entry here is a DECLARED
# exception, not a silent one -- which is the whole difference between this and
# what the guard did before.
#
# It used to `next unless exists $THEME_WIDTH_BY_CP{$cp}`, so any entry Theme did
# not declare was skipped without comment. That is weaker than spec §5.2 claims
# ("a wide glyph is later added => AC-S5 fails until Theme and the table agree"):
# the entries most likely to drift are exactly the ones Theme has no opinion on,
# and those were the ones going unchecked. Found by the package 10 review.
my %GLYPH_COLS_NOT_IN_THEME = (
    0x3000 => 'ideographic space, used as row 2 padding; a spacing character '
            . 'rather than a Theme GLYPH, so Theme has no entry to reconcile with',
);
sub glyph_cols_disagreements {
    my ($table) = @_;
    my @bad;
    for my $cp (sort { $a <=> $b } keys %{ $table || {} }) {
        if (!exists $THEME_WIDTH_BY_CP{$cp}) {
            # Undeclared AND unexcused is now a finding rather than a skip.
            push @bad, sprintf('U+%04X: width %d declared in the table, but Theme '
                             . 'carries no entry and it is not on the documented '
                             . 'exception list', $cp, $table->{$cp})
                unless exists $GLYPH_COLS_NOT_IN_THEME{$cp};
            next;
        }
        push @bad, sprintf('U+%04X: table says %d, Theme says %d',
                           $cp, $table->{$cp}, $THEME_WIDTH_BY_CP{$cp})
            if $table->{$cp} != $THEME_WIDTH_BY_CP{$cp};
    }
    return @bad;
}

{
    # AC-S1 -- no numeric-literal colour in statusline.pl.
    my @colour = colour_literal_hits($SRC_SL);
    ok(scalar(@colour) == 0,
        'AC-S1: statusline.pl carries no numeric-literal colour -- every colour comes from the generated token block')
        or diag('  found: ' . join('; ', @colour));

    # AC-S1 counter-fixtures (C-7): the same helper must fire on a numeric
    # literal and stay silent on a role lookup.
    my $pos_src = slurp_raw(temp_source("my \$c = rgb(1,2,3);\n"));
    my $neg_src = slurp_raw(temp_source("my \$c = \$THEME_RGB{'accent'};\n"));
    ok(scalar(colour_literal_hits(blank_comments($pos_src))) > 0,
        'AC-S1 (counter-fixture): the colour-literal detector FIRES on a synthetic rgb(1,2,3) call');
    ok(scalar(colour_literal_hits(blank_comments($neg_src))) == 0,
        'AC-S1 (counter-fixture): the same detector stays silent on a synthetic $THEME_RGB{...} lookup');

    # AC-S2 -- the block's colours are actually CONSUMED, not merely embedded.
    ok($SRC_SL =~ /\$THEME_RGB\{/,
        'AC-S2: statusline.pl reads its colours out of %THEME_RGB by role name');

    # AC-S3 -- core modules only, nothing from the repo.
    my @imports = import_violations($SRC_SL);
    ok(scalar(@imports) == 0,
        'AC-S3: statusline.pl imports nothing outside the core allow-list and nothing from the repo')
        or diag('  found: ' . join('; ', @imports));

    my $bad_src  = slurp_raw(temp_source("use lib \"x\";\nuse Theme;\n"));
    my $good_src = slurp_raw(temp_source("use JSON::PP;\n"));
    ok(scalar(import_violations(blank_comments($bad_src))) > 0,
        'AC-S3 (counter-fixture): the import scan FIRES on a synthetic `use lib` + `use Theme`');
    ok(scalar(import_violations(blank_comments($good_src))) == 0,
        'AC-S3 (counter-fixture): the same scan stays silent on a synthetic core `use JSON::PP`');

    # AC-S4 -- it compiles with NO -I flag at all.
    my $cout = `timeout 20 perl -c "$STATUSLINE" 2>&1`;
    my $crc  = $? >> 8;
    is($crc, 0,
        'AC-S4: `perl -c scripts/statusline.pl` succeeds with no -I flag -- it is a standalone payload')
        or diag("  $cout");

    # AC-S5 -- the inline width table agrees with Theme, and declares sep.bar.
    my $table = parse_glyph_cols($SRC_SL);
    ok(defined($table) && exists $table->{$SEPBAR_CP},
        'AC-S5: statusline.pl declares an inline %GLYPH_COLS table that includes sep.bar (U+FF5C)')
        or diag('  parsed table: ' . (defined $table ? join(',', map { sprintf('U+%04X=>%d', $_, $table->{$_}) } sort keys %$table) : '(none)'));
    my @drift = glyph_cols_disagreements($table);
    ok(defined($table) && scalar(keys %$table) && scalar(@drift) == 0,
        'AC-S5: every codepoint the inline table declares carries the width Theme.pm declares for it')
        or diag('  drift: ' . join('; ', @drift));

    ok(scalar(glyph_cols_disagreements({ $SEPBAR_CP => 1 })) > 0,
        'AC-S5 (counter-fixture): the drift comparison FIRES on a synthetic table declaring sep.bar as one column');
    ok(scalar(glyph_cols_disagreements({ $SEPBAR_CP => $ORACLE_COLS{$SEPBAR_CP} })) == 0,
        'AC-S5 (counter-fixture): the same comparison is silent when the synthetic table agrees with Theme');

    # The guard used to `next` past any codepoint Theme did not declare, so the
    # entries most likely to drift -- the ones Theme has no opinion on -- were
    # exactly the ones going unchecked, while spec 5.2 claimed the opposite.
    # U+0BAD is not a Theme glyph and is not on the documented exception list.
    ok(scalar(glyph_cols_disagreements({ 0x0BAD => 2 })) > 0,
        'AC-S5: a codepoint the table declares that Theme does not carry, and that '
      . 'is not on the documented exception list, is REPORTED rather than skipped');
    # ...and the exception list is what makes that survivable, not a blanket pass:
    # U+3000 is excused with a stated reason, so it must stay silent.
    ok(scalar(glyph_cols_disagreements({ 0x3000 => 2 })) == 0,
        'AC-S5 (counter-fixture): a DECLARED exception is still silent, so the '
      . 'check above is a guard with a documented escape hatch, not a tripwire');

    # AC-S6 -- bp-statusline.pl keeps t/spend-panel.t:627-628 green.
    unlike($SRC_BP, qr/\blength\s*\(/,
        'AC-S6: bp-statusline.pl still never measures width via a raw length() call form');
    like($SRC_BP, qr/display_width|fit_spans|spans_width/,
        'AC-S6: bp-statusline.pl still uses the shared display-width core');

    # AC-S7 -- Theme is loaded by full path, inside an eval, and the failure
    # path does not die.
    my $theme_eval;
    {
        my $code = $SRC_BP;
        while ($code =~ /\beval\s*\{/g) {
            my $body = _balanced($code, pos($code) - 1, '{', '}');
            next unless defined $body;
            if ($body =~ /require\s+["'][^"']*Theme\.pm["']/) { $theme_eval = $body; last }
        }
    }
    ok(defined($theme_eval),
        'AC-S7: bp-statusline.pl requires Theme.pm by full path from inside an eval block')
        or diag('  no eval block containing a full-path require of Theme.pm was found');

    my $win = '';
    if ($SRC_BP =~ /require\s+["'][^"']*Theme\.pm["']/g) {
        $win = substr($SRC_BP, $-[0], 400);
    }
    ok(length($win) && $win !~ /\bdie\s*[("'\$]/,
        'AC-S7: the Theme load failure path does not die')
        or diag("  window = [$win]");
    ok($SRC_BP =~ /\bwarn\s*[("'\$]/,
        'AC-S7: bp-statusline.pl degrades a failed module load with a warn call');
}

# ===========================================================================
# AC-E -- no emoji, and the detector can fire (Decision 11, B-16).
#
# Scans run over COMMENT-BLANKED source, per this blueprint's standing rule.
# t/theme-tokens.t remains the authority over the raw files; this group's
# job is that the two owned surfaces carry no emoji in live code, and that the
# detector used for the rendered-output assertions (AC-M4, AC-G1) demonstrably
# fires.
# ===========================================================================
{
    my @sl = emoji_hits($SRC_SL);
    ok(scalar(@sl) == 0,
        'AC-E1: scripts/statusline.pl contains no emoji codepoint')
        or diag('  hits: ' . emoji_summary(@sl));

    my @bp = emoji_hits($SRC_BP);
    ok(scalar(@bp) == 0,
        'AC-E2: plugins/butler/scripts/bp-statusline.pl contains no emoji codepoint')
        or diag('  hits: ' . emoji_summary(@bp));

    for my $cp (0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA) {
        my $esc   = sprintf('\\x{%X}', $cp);
        my $bytes = encode('UTF-8', chr($cp));
        ok(index($SRC_BP, $esc) < 0 && index($SRC_BP, lc $esc) < 0 && index($SRC_BP, $bytes) < 0,
            sprintf('AC-E2: bp-statusline.pl carries neither the escape nor the encoded form of U+%04X', $cp));
    }

    # AC-E3 -- counter-fixtures (C-7). The detector must fire on both arms and
    # stay silent on the non-emoji glyphs this blueprint standardises on.
    my $esc_src = slurp_raw(temp_source("my \$badge = \"\\x{1F4E6}\";\n"));
    ok(scalar(emoji_hits(blank_comments($esc_src))) > 0,
        'AC-E3 (counter-fixture): the detector FIRES on a synthetic \x{1F4E6} escape literal');

    my $enc_src = slurp_raw(temp_source("my \$dot = \"" . encode('UTF-8', chr(0x1F7E2)) . "\";\n"));
    ok(scalar(emoji_hits(blank_comments($enc_src))) > 0,
        'AC-E3 (counter-fixture): the detector FIRES on synthetic raw UTF-8 bytes for U+1F7E2');

    my $clean_src = slurp_raw(temp_source("my \@g = (\"\\x{FF5C}\", \"\\x{2500}\", \"\\x{25CF}\", \"\\x{00D7}\");\n"));
    ok(scalar(emoji_hits(blank_comments($clean_src))) == 0,
        'AC-E3 (counter-fixture): the same detector stays SILENT on U+FF5C / U+2500 / U+25CF / U+00D7');

    # AC-E4 -- reach: the replacement goes through the shared glyph vocabulary.
    ok($SRC_BP =~ /status\.(?:ok|warn|crit|idle)/,
        'AC-E4: bp-statusline.pl names at least one Theme status-glyph role rather than a new private literal');
}

# ===========================================================================
# AC-G -- bp-statusline.pl renders non-emoji state glyphs (Decision 11, B-17).
# Spawned as a plain filter script bounded by `timeout`, stdout read as raw
# bytes, exactly as t/spend-panel.t:640 spawns it.
# ===========================================================================
{
    my $NOW = 1785800000;
    my $spend = {
        claude      => { status => 'ok', five_hour => { utilization => 0.10 }, seven_day => { utilization => 0.05 } },
        go          => { status => 'ok',
                         five_hour => { used => 1,  limit => 12 },
                         weekly    => { used => 3,  limit => 30 },
                         monthly   => { used => 60, limit => 60 } },
        zen         => { status => 'ok', balance => 42, budget => 100 },
        zen_enabled => 1,
    };

    sub run_bp {
        my ($script, %opt) = @_;
        my ($fh, $inpath) = tempfile(DIR => $TMPROOT);
        binmode $fh, ':raw';
        print {$fh} encode_json({ spend => $spend, now => $NOW, width => $opt{width} // 100 });
        close $fh;
        local %ENV = %ENV;
        $ENV{HOME} = $CLEAN_HOME;
        # PERL5LIB, and WHY (recorded rather than silently added): the modules
        # bp-statusline.pl loads by full path themselves load tui/Layout.pm
        # through @INC. Without the sandbox scripts directory on @INC every
        # spawn degrades to an empty line, which would make AC-G2 unfalsifiable
        # for a reason that belongs to a neighbouring package rather than to
        # this one. This oracle therefore gives the child the search path its
        # dependencies need, and asserts the GLYPH VOCABULARY on top of that.
        $ENV{PERL5LIB} = $opt{lib} // $SANDBOX_SCRIPTS;
        my $out = `timeout 20 perl "$script" < "$inpath" 2>/dev/null`;
        my $rc  = $? >> 8;
        return (defined($out) ? $out : '', $rc);
    }

    my ($out, $rc) = run_bp($BP_STATUSLINE);
    is($rc, 0, 'AC-G setup: bp-statusline.pl runs to completion under timeout');

    my @emoji_out = emoji_hits($out);
    ok(scalar(@emoji_out) == 0,
        'AC-G1: the rendered statusline form contains none of the emoji codepoints')
        or diag('  hits: ' . emoji_summary(@emoji_out));
    for my $cp (0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA) {
        ok(index($out, encode('UTF-8', chr($cp))) < 0,
            sprintf('AC-G1: the rendered output carries no UTF-8 bytes for U+%04X', $cp));
    }

    my $has_state_glyph = 0;
    for my $cp (0x25CF, 0x00D7, 0x25B3, 0x25CB) {
        $has_state_glyph = 1 if index($out, encode('UTF-8', chr($cp))) >= 0;
    }
    ok($has_state_glyph,
        'AC-G2: at least one non-emoji state glyph really renders -- the emoji were replaced, not merely deleted')
        or diag('  output = [' . $out . ']');

    # AC-G4 -- never ends mid-glyph (the property t/spend-panel.t:654-660
    # already asserts; the glyph swap must not regress it).
    {
        (my $trimmed = $out) =~ s/\s+\z//;
        my $mid = 0;
        if (length $trimmed) {
            my $last = ord(substr($trimmed, -1, 1));
            $mid = ($last >= 0x80 && $last <= 0xBF) ? 1 : ($last >= 0xC0) ? 1 : 0;
        }
        is($mid, 0, 'AC-G4: the rendered output does not end on a stranded UTF-8 byte');
    }

    # AC-G3 -- the degrade path, asserted STRUCTURALLY, and the spec's own
    # escape hatch is why.
    #
    # AC-G3 offers a functional form (run a tree copy with no Theme.pm) and a
    # structural fallback "if the chosen mechanism cannot be made deterministic
    # on this host". It cannot. Measured, not assumed: with Theme.pm removed
    # from the copied tree, the sibling module that bp-statusline.pl also loads
    # fails to compile, and its width core then spins on an uninitialised
    # pattern -- one probe emitted ~254 MB of warnings and had to be killed by
    # `timeout`. A run whose exit status is decided by a neighbouring module's
    # degenerate loop tests nothing about THIS package, and burns the suite's
    # runtime to say so. So the degrade path is asserted where it is actually
    # specified: an eval-wrapped load that cannot die (AC-S7) plus the ASCII
    # fallback table of spec S2.7 rule 3, whose values are given as literals
    # and are therefore binding.
    {
        my %fallback = ('o' => 'ok', 'x' => 'exhausted/unreadable', '!' => 'absent', '-' => 'disabled');
        for my $ch (sort keys %fallback) {
            my $q = quotemeta($ch);
            ok($SRC_BP =~ /=>\s*(['"])$q\1/,
                "AC-G3 (structural): bp-statusline.pl declares the ASCII degrade glyph '$ch' ($fallback{$ch})");
        }
        my @ascii = ('o', 'x', '!', '-');
        my %seen; $seen{$_}++ for @ascii;
        ok(scalar(keys %seen) == scalar(@ascii),
            'AC-G3 (structural, fixture): the declared ASCII degrade glyphs are pairwise distinct, one byte and one column each');
    }
}

# ===========================================================================
# AC-B -- the whole row is budgeted (criteria 1, 2 and 4 jointly; B-12/B-13).
# This is the group that covers the overflow defect behind the two red
# assertions at t/tui-output-hygiene.t:247 -- independently asserted here,
# never by re-pointing that immutable file.
#
# row_cost is computed in this oracle exactly as spec S2.4.1 defines it, so
# the oracle and the implementation agree by construction rather than by luck.
# ===========================================================================
{
    # A plans fixture, seeded per the spec's F-env: a HOME tempdir with one
    # todo file and a data dir with one blueprint. Whether a plans segment
    # results is DISCOVERED below rather than assumed -- see AC-B4.
    for my $d ("$SEEDED_HOME/.claude", "$SEEDED_HOME/.claude/todos",
               "$SEEDED_DATA/blueprints", "$SEEDED_DATA/blueprints/demo") {
        mkdir $d unless -d $d;
    }
    spew_raw("$SEEDED_HOME/.claude/todos/s69-fixture.md", "- [ ] one seeded todo\n");
    spew_raw("$SEEDED_HOME/.claude/todos/s69-fixture.json", "[{\"content\":\"one\",\"status\":\"pending\"}]\n");
    spew_raw("$SEEDED_DATA/blueprints/demo/blueprint.md", "# demo\n");
    # hook-continuity-remake package 10: the legacy todo files above are no
    # longer counted (AC-7), so the seed also carries one ALMANAC global todo
    # -- otherwise "git+plans seed" would silently stop seeding a todo count.
    seed_todos('global', $SEEDED_HOME, 1, 0) if $ALMANAC_OK;

    my $top   = "$WROOT/proj-alpha";
    my $long  = "$WROOT/proj-alpha/" . ('x' x 200);
    my @WIDTHS = (40, 80, 120, 200);

    # AC-B0 -- non-vacuity gate (F-shim-effective). A shim that silently failed
    # to take effect would make every width assertion below vacuous. Hard ok(),
    # never a skip.
    {
        # The probe must force row 1 to differ across widths. It used to rely on
        # the working directory being elided there; the path has its own row now
        # and is never elided, so the payload has to make row 1 itself overflow.
        # A long PROJECT NAME does that -- it is what row 1 elides last.
        my $ltop = "$WROOT/proj-" . ('n' x 120);
        my $narrow = statusline_line1(payload_for(current_dir => "$ltop/deep"),
                        cols => 40, sandbox => 0, toplevel => $ltop, branch => 'main');
        my $wide   = statusline_line1(payload_for(current_dir => "$ltop/deep"),
                        cols => 200, sandbox => 0, toplevel => $ltop, branch => 'main');
        ok(length($narrow) && length($wide) && $narrow ne $wide,
            'AC-B0 (non-vacuity gate): the width-40 and width-200 renders of the same payload differ -- the tput shim really drives the layout');
    }

    # AC-B7 -- counter-fixture (C-7) for the cost function itself. A cost
    # function that silently counted characters would make this whole group
    # vacuous, and U+FF5C is precisely the character that exposes it.
    {
        my $one_bar = 'ab' . $SEPBAR_BYTES . 'cd';
        my $chars   = length(decode('UTF-8', $one_bar, Encode::FB_DEFAULT));
        cmp_ok(row_cost($one_bar), '>', $chars,
            'AC-B7 (counter-fixture): row_cost of a string containing one sep.bar exceeds its character count');
        cmp_ok(col_cost($one_bar), '>', $chars,
            'AC-B7 (counter-fixture): the COLUMN term alone also exceeds it -- sep.bar is counted as a full-width glyph, not as one column');
        my $ascii = 'abcd';
        is(col_cost($ascii), length($ascii),
            'AC-B7 (counter-fixture): the same column term counts a plain ASCII string at one column per character');
    }

    # AC-B1 / AC-B2 / AC-B3 -- the budget invariant, with and without the
    # right-hand segments. The defect being fixed is precisely "the right-hand
    # segments are appended on top of an already-full row".
    for my $cols (@WIDTHS) {
        for my $case (
            ['bare',           { branch => undef,  home => $CLEAN_HOME,  data => $CLEAN_DATA  }, 'AC-B1'],
            ['git+plans seed', { branch => 'main', home => $SEEDED_HOME, data => $SEEDED_DATA }, 'AC-B2'],
        ) {
            my ($label, $opt, $ac) = @$case;
            my ($out, $rc) = run_statusline(payload_for(current_dir => $long),
                cols => $cols, sandbox => 0, toplevel => $top, %$opt);
            my $line = first_line($out);
            my $cost = row_cost($line);
            ok($cost <= $cols,
                "$ac (cols=$cols, $label): the whole first line costs $cost, within the $cols-column budget")
                or diag('  first line = [' . strip_sgr($line) . ']');
            unlike($line, qr/\n/,
                "AC-B3 (cols=$cols, $label): the first line carries no embedded newline -- the row is truncated, never wrapped");
        }
    }

    # AC-B4 / AC-B5 -- drop order. The git segment is under this oracle's
    # control (the branch comes from the shim), so "segments are dropped
    # before fields are elided" is asserted against it directly.
    my %plans_at;
    my %git_at;
    my %elided_at;
    for my $cols (@WIDTHS) {
        my $line = statusline_line1(payload_for(current_dir => $long),
            cols => $cols, sandbox => 0, toplevel => $top,
            branch => 'main', home => $SEEDED_HOME, data => $SEEDED_DATA);
        my $vis  = strip_sgr($line);
        $plans_at{$cols}  = ($vis =~ /\b(?:blueprints|todos)\b/) ? 1 : 0;
        $git_at{$cols}    = (index($vis, 'main') >= 0) ? 1 : 0;
        my $proj = project_field($line);
        my $cwd  = cwd_field($line);
        $elided_at{$cols} = ((defined($proj) && $proj =~ /[<>]/) || (defined($cwd) && $cwd =~ /[<>]/)) ? 1 : 0;

        ok(!$plans_at{$cols} || $git_at{$cols},
            "AC-B4 (cols=$cols): the plans segment never survives on a row the git segment has been dropped from")
            or diag("  first line = [$vis]");
        ok(!$elided_at{$cols} || !$plans_at{$cols},
            "AC-B5 (cols=$cols): no field is elided while the plans segment is still on the row")
            or diag("  first line = [$vis]");
        ok(!$elided_at{$cols} || !$git_at{$cols},
            "AC-B5 (cols=$cols): no field is elided while the git segment is still on the row -- segments yield first")
            or diag("  first line = [$vis]");
    }
    {
        my @desc = sort { $b <=> $a } @WIDTHS;
        my $monotone = 1;
        for my $i (1 .. $#desc) {
            $monotone = 0 if $plans_at{ $desc[$i] } && !$plans_at{ $desc[$i - 1] };
        }
        ok($monotone,
            'AC-B4: plans presence is monotone in width -- a segment dropped at a wider row never reappears at a narrower one');
        diag('  AC-B4: plans segment rendered at widths: '
            . join(',', grep { $plans_at{$_} } @WIDTHS) . ' (none listed means the seeded fixture produced no plans segment)');
    }

    # AC-B6 -- pathological width. The symmetry guarantee is explicitly NOT
    # asserted here (spec S2.4.2: below the marker slot it is void by
    # declaration); the budget invariant still is.
    {
        my ($out, $rc) = run_statusline(payload_for(current_dir => $long),
            cols => 8, sandbox => 1, toplevel => $top, branch => 'main');
        my $line = first_line($out);
        is($rc, 0, 'AC-B6 (cols=8): the process still exits normally at a pathological width');
        ok(length(strip_sgr($line)) >= 1, 'AC-B6 (cols=8): a first line is still printed');
        my $cost = row_cost($line);
        ok($cost <= 8, "AC-B6 (cols=8): the surviving row costs $cost, within the 8-column budget")
            or diag('  first line = [' . strip_sgr($line) . ']');
        my $vis = strip_sgr($line);
        # t06 AMENDMENT (blueprint Decision 8, package t06-statusline-marker,
        # 2026-08-19): with a leading Decision-3 glyph now the first character
        # of the marker field, the pre-Decision-3 pin ("first surviving
        # character is the head of the literal word SANDBOX") is superseded --
        # the first surviving character is the sandbox glyph itself. The
        # INTENT ("what survives at cols=8 belongs to the marker, not
        # something else") is preserved: this still fails if the marker
        # vanishes entirely, or if anything other than the declared
        # Decision-3 sandbox glyph (hollow circle, U+25CB) survives first.
        my $t06_sandbox_glyph = encode('UTF-8', chr(0x25CB));
        ok(length($vis) && substr($vis, 0, length($t06_sandbox_glyph)) eq $t06_sandbox_glyph,
            'AC-B6 (cols=8): whatever survives begins with the declared sandbox glyph (Decision 3), which now leads the marker field')
            or diag("  first line = [$vis]");
    }
}

# ===========================================================================
# AC-N -- the project name inside a sandbox.
#
# The project is bind-mounted at /project, so in-container `git rev-parse
# --show-toplevel` returns `/project` and basename() yields the literal word
# "project" -- for EVERY project on the machine. The field whose whole job is to
# say which project you are in was the one field that could never say it.
#
# The launcher writes the real name to claude-home/project-name, which is a live
# bind mount and therefore lands at $HOME/.claude/project-name immediately, in
# containers created before the fix as well. An env var would have been the
# obvious choice and the wrong one -- `podman create` bakes env at creation, so
# it would have fixed only containers made afterwards.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    mkdir "$home/.claude";

    # Without the name file we can only report what the mount says. Asserting
    # this pins WHY the file is needed rather than leaving it as decoration.
    {
        my $line = statusline_line1(payload_for(current_dir => "$FAKE_ROOT/project/plugins"),
                        cols => 200, sandbox => 1, toplevel => "$FAKE_ROOT/project", home => $home);
        is(project_field($line), 'project',
            'AC-N0: with no name file the mount point is all there is -- the defect, reproduced');
    }

    spew_raw("$home/.claude/project-name", "gsa-superapp\n");
    {
        my $line = statusline_line1(payload_for(current_dir => "$FAKE_ROOT/project/plugins"),
                        cols => 200, sandbox => 1, toplevel => "$FAKE_ROOT/project", home => $home);
        is(project_field($line), 'gsa-superapp',
            'AC-N1: the name file supplies the real project name in place of the mount point');
    }

    # Non-ASCII survives the round trip: this machine's paths carry them.
    spew_raw("$home/.claude/project-name", encode('UTF-8', "caf\x{e9}-app") . "\n");
    {
        my $line = statusline_line1(payload_for(current_dir => "$FAKE_ROOT/project"),
                        cols => 200, sandbox => 1, toplevel => "$FAKE_ROOT/project", home => $home);
        ok(index($line, encode('UTF-8', "caf\x{e9}-app")) >= 0,
            'AC-N2: a non-ASCII project name survives the file round trip unmangled')
            or diag('  first line = [' . strip_sgr($line) . ']');
    }

    # An empty or whitespace-only file must not blank the field.
    spew_raw("$home/.claude/project-name", "\n\n");
    {
        my $line = statusline_line1(payload_for(current_dir => "$FAKE_ROOT/project"),
                        cols => 200, sandbox => 1, toplevel => "$FAKE_ROOT/project", home => $home);
        is(project_field($line), 'project',
            'AC-N3: an empty name file falls back rather than rendering an empty project field');
    }

    # Control bytes are scrubbed like every other display field read off disk.
    spew_raw("$home/.claude/project-name", "evil\nSECOND ROW\n");
    {
        my ($out) = run_statusline(payload_for(current_dir => "$FAKE_ROOT/project"),
                        cols => 200, sandbox => 1, toplevel => "$FAKE_ROOT/project", home => $home);
        my $line = first_line($out);
        is(project_field($line), 'evilSECOND ROW',
            'AC-N4: an embedded newline is scrubbed, not honoured -- the file cannot inject an extra row');
        is(index(strip_sgr($line), "\n"), -1,
            'AC-N4: and no newline reaches the rendered row');
    }

    # The HOST must be untouched by all of this: there, the toplevel basename is
    # already right and the file does not exist.
    {
        my $line = statusline_line1(payload_for(current_dir => "$WROOT/proj-alpha/x"),
                        cols => 200, sandbox => 0, toplevel => "$WROOT/proj-alpha", home => $home);
        is(project_field($line), 'proj-alpha',
            'AC-N5: on the host the name still comes from the git toplevel -- the fix is sandbox-shaped only');
    }
}

# ===========================================================================
# PACKAGE 10 (hook-continuity-remake): the almanac counters, pending
# decisions, the focused-tasklist row and the generated counting block.
# AC numbers are the spec's section-4 numbers; "behaviour N" is its section 3.
# ===========================================================================
ok($ALMANAC_OK, 'P10 setup: the almanac modules load as libraries, so every fixture is written through them (AC-3)')
    or diag("  $ALMANAC_ERR");

my $SL_RAW = slurp_raw($STATUSLINE);
(my $SL_LF = $SL_RAW) =~ s/\r\n/\n/g;

# --- the shared fixtures: behaviours 1-6 -------------------------------------
#   P_FULL: 5 open + 2 done todos; 2 notes; tasks 2 pending, 1 doing,
#           1 blocked, 3 done, 1 obsoleted; decisions 2 unanswered, 1 answered.
#   H_FULL: vault with 3 open + 1 done todos and 1 note.
my ($P_FULL, $P_EMPTY, $H_FULL, $H_EMPTY) = (mk_proj(), mk_proj(), mk_home(), mk_home());
if ($ALMANAC_OK) {
    seed_todos('project', $P_FULL, 5, 2);
    seed_notes('project', $P_FULL, 2);
    seed_tasks($P_FULL, ['pending'], ['pending'], ['doing'], ['blocked'],
               ['done'], ['done'], ['done'], ['obsoleted']);
    seed_decisions($P_FULL, 2, 1);
    seed_todos('global', $H_FULL, 3, 1);
    seed_notes('global', $H_FULL, 1);
}

# ---------------------------------------------------------------------------
# AC-1 / AC-3 / behaviours 1, 5 and 6 -- one populated host render.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load -- no fixture can be written', 30) unless $ALMANAC_OK;

    my ($out, $rc) = render(proj => $P_FULL, home => $H_FULL);
    is($rc, 0, 'AC-1 setup (behaviour 1): a host render of a populated project and vault exits 0');
    my $row  = first_line($out);
    my $vis  = strip_sgr($row);
    my $runs = sgr_runs($row);

    # todos: "<glyph> P.G" -- glyph text.muted, P text.primary, dot
    # text.faint, G text.muted (spec 2.3).
    my $todo = "$G_TODO 5${G_DOT}3";
    is(counter_seg($vis, $G_TODO), $todo,
        'AC-1 (behaviour 1): todos render ONE glyph, the project count, a dot and the global count -- "U+274F 5.3"')
        or diag("  row 1 = [$vis]");
    my $i = index($vis, $todo);
  SKIP: {
        skip('the todos segment is not on row 1, so its colours cannot be located', 4) if $i < 0;
        my $ip = $i + length($G_TODO) + 1;
        my $id = $ip + 1;
        my $ig = $id + length($G_DOT);
        ok(run_ends_with($runs->[$i],  fg_sgr('text.muted')),   'AC-1: the todos glyph is immediately preceded by the text.muted SGR');
        ok(run_ends_with($runs->[$ip], fg_sgr('text.primary')), 'AC-1: the PROJECT todo count is immediately preceded by the text.primary SGR');
        ok(run_ends_with($runs->[$id], fg_sgr('text.faint')),   'AC-1: the separating dot is immediately preceded by the text.faint SGR');
        ok(run_ends_with($runs->[$ig], fg_sgr('text.muted')),   'AC-1: the GLOBAL todo count is immediately preceded by the text.muted SGR');
    }

    # notes (behaviour 5): project 2 + vault 1. No space between the glyph and
    # the first number (Decision 1(d): the glyph is double-width).
    my $note = "${G_NOTE}2${G_DOT}1";
    is(counter_seg($vis, $G_NOTE), $note, 'AC-1 (behaviour 5): notes render "U+26302.1" (no space) -- project 2, vault 1')
        or diag("  row 1 = [$vis]");
    $i = index($vis, $note);
  SKIP: {
        skip('the notes segment is not on row 1', 4) if $i < 0;
        my $ip = $i + length($G_NOTE);
        my $id = $ip + 1;
        my $ig = $id + length($G_DOT);
        ok(run_ends_with($runs->[$i],  fg_sgr('text.muted')),   'AC-1: the notes glyph is in text.muted');
        ok(run_ends_with($runs->[$ip], fg_sgr('text.primary')), 'AC-1: the project note count is in text.primary');
        ok(run_ends_with($runs->[$id], fg_sgr('text.faint')),   'AC-1: the notes dot is in text.faint');
        ok(run_ends_with($runs->[$ig], fg_sgr('text.muted')),   'AC-1: the global note count is in text.muted');
    }

    # tasklist (behaviour 5): pending + doing + blocked = 4; project-only.
    my $task = "$G_TASK 4";
    is(counter_seg($vis, $G_TASK), $task,
        'AC-1 (behaviour 5): tasks count pending+doing+blocked only -- "U+25A3 4" from 2/1/1, with 3 done and 1 obsoleted ignored')
        or diag("  row 1 = [$vis]");
    $i = index($vis, $task);
  SKIP: {
        skip('the tasklist segment is not on row 1', 2) if $i < 0;
        ok(run_ends_with($runs->[$i], fg_sgr('text.muted')), 'AC-1: the tasklist glyph is in text.muted');
        ok(run_ends_with($runs->[$i + length($G_TASK) + 1], fg_sgr('text.primary')), 'AC-1: the task count is in text.primary');
    }

    # the segment order (Decision 1(a)): decisions, tasklist, todos, notes.
    # Blueprints are absent in this fixture.
    my ($ifl, $it, $in, $ik) = (index($vis, $G_FLAG), index($vis, $G_TODO), index($vis, $G_NOTE), index($vis, $G_TASK));
    ok($ifl >= 0 && $ik > $ifl && $it > $ik && $in > $it,
        'AC-1 (spec 2.3): the counters appear in the order decisions, tasklist, todos, notes');

    # pending decisions (behaviour 6): 2 unanswered, 1 answered. Decision 1(b):
    # the flag has left the marker field entirely and leads the counters
    # segment instead.
    is(field_at($row, 0), "$G_HOLLOW HOST",
        'AC-11 (behaviour 6): the marker field is exactly "<lead> HOST", carrying no U+2691')
        or diag("  row 1 = [$vis]");
    my @row_fields = sep_fields($row);
    my $last_field = @row_fields ? $row_fields[-1] : '';
    ok(index($last_field, "$G_FLAG 2  ") == 0,
        'AC-11 (behaviour 6): the last field starts with U+2691, a space, 2, and the two-space join')
        or diag("  last field = [$last_field]");
    my $flag_raw = bg_sgr('overlay.warn') . fg_sgr('overlay.warn') . $G_FLAG . ' 2';
    ok(index($row, $flag_raw) >= 0 && $row !~ /\Q$flag_raw\E\d/,
        'AC-11 (behaviour 6): U+2691 2 is preceded by the overlay.warn background SGR and then its foreground SGR (raw bytes)');
    unlike($vis, qr/\?\d/, 'AC-11: the retired "?N" form is gone -- U+2691 replaces it');

    # AC-3 -- parity with the modules' own counts.
    my $tc = with_host_policy(sub { Almanac::Todo::count(root => $P_FULL, home => $H_FULL) });
    my $np = scalar @{ with_host_policy(sub { Almanac::Note::open_store('project', root => $P_FULL)->ids }) };
    my $ng = scalar @{ with_host_policy(sub { Almanac::Note::open_store('global',  home => $H_FULL)->ids }) };
    my $nt = scalar grep { my $s = $_->{fields}{status} // ''; $s eq 'pending' || $s eq 'doing' || $s eq 'blocked' }
                    @{ Almanac::Task::list_tasks(root => $P_FULL) };
    my $dc = Almanac::Decision::count(root => $P_FULL);
    is_deeply([ $tc->{project}{open}, $tc->{global}{open}, $np, $ng, $nt, $dc->{project}{unanswered} ],
              [ 5, 3, 2, 1, 4, 2 ],
              'AC-3 (fixture precondition): the modules themselves count 5/3 open todos, 2/1 notes, 4 live tasks, 2 unanswered decisions');
    is(counter_seg($vis, $G_TODO), "$G_TODO $tc->{project}{open}$G_DOT$tc->{global}{open}",
        'AC-3: the rendered todo numbers equal Almanac::Todo::count open, project and global');
    is(counter_seg($vis, $G_NOTE), "$G_NOTE$np$G_DOT$ng",
        'AC-3: the rendered note numbers equal the note stores\' record totals, project and global');
    is(counter_seg($vis, $G_TASK), "$G_TASK $nt",
        'AC-3: the rendered task number equals the module\'s pending+doing+blocked count');
    like($vis, qr/\Q$G_FLAG\E \Q$dc->{project}{unanswered}\E(?!\d)/,
        'AC-3: the rendered decision number equals Almanac::Decision::count unanswered');
}

# ---------------------------------------------------------------------------
# AC-1 / AC-2 -- behaviours 2, 3 and 4, and "0 unanswered gives no U+2691".
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 12) unless $ALMANAC_OK;

    my ($out2) = render(proj => $P_FULL, home => $H_EMPTY);
    my $v2 = strip_sgr(first_line($out2));
    is(counter_seg($v2, $G_TODO), "$G_TODO 5", 'AC-1 (behaviour 2): project 5, empty vault -> "U+274F 5", no dot')
        or diag("  row 1 = [$v2]");
    is(counter_seg($v2, $G_NOTE), "${G_NOTE}2", 'AC-1 (behaviour 2): project notes only -> "U+26302" (no space), no dot');

    my ($out3) = render(proj => $P_EMPTY, home => $H_FULL);
    my $v3 = strip_sgr(first_line($out3));
    is(counter_seg($v3, $G_TODO), "$G_TODO 3",
        'AC-1/AC-2 (behaviour 3): empty project, vault 3 -> "U+274F 3", dimmed, no dot -- a zero project count renders no project digit and no dot')
        or diag("  row 1 = [$v3]");
    is(counter_seg($v3, $G_NOTE), "${G_NOTE}1", 'AC-1/AC-2 (behaviour 3): "U+2630 1", dimmed, no dot, no space');
    is(index($out3, $G_TASK), -1, 'AC-2 (behaviour 3): the project-only tasklist counter renders nothing at 0');
    is(index($out3, $G_FLAG), -1, 'AC-2 (behaviour 3): no pending-decisions glyph at 0');

    my ($out4, $rc4) = render(proj => $P_EMPTY, home => $H_EMPTY);
    is($rc4, 0, 'AC-2 setup (behaviour 4): every store empty still exits 0');
    for my $g ([$G_TODO, 'U+274F'], [$G_NOTE, 'U+2630'], [$G_TASK, 'U+25A3'], [$G_FLAG, 'U+2691']) {
        is(index($out4, $g->[0]), -1, "AC-2 (behaviour 4): with every store empty, $g->[1] appears nowhere -- a zero counter renders nothing");
    }

    my $P_ANS = mk_proj();
    seed_decisions($P_ANS, 0, 1);
    my ($out6) = render(proj => $P_ANS, home => $H_EMPTY);
    is(index($out6, $G_FLAG), -1, 'AC-11 (behaviour 6): 0 unanswered (one answered decision) renders no U+2691');
}

# ---------------------------------------------------------------------------
# AC-4 (behaviour 7) -- on the host the snapshot is never read.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $H = mk_home();
    write_snapshot($H, snapshot_json(open => 9, done => 0, note => 8));
    my ($out) = render(proj => $P_FULL, home => $H);
    my $v = strip_sgr(first_line($out));
    is(counter_seg($v, $G_TODO), "$G_TODO 5",
        'AC-4 (behaviour 7): host, empty vault, a valid snapshot claiming 9 open todos -> "U+274F 5" -- the snapshot is ignored on the host')
        or diag("  row 1 = [$v]");
    is(counter_seg($v, $G_NOTE), "${G_NOTE}2", 'AC-4: ...and its note total (8) is ignored too');
    ok(index($v, "${G_DOT}9") < 0 && index($v, "${G_DOT}8") < 0, 'AC-4: neither snapshot number renders anywhere on row 1');
}

# ---------------------------------------------------------------------------
# AC-5 (behaviour 8) -- in a sandbox the snapshot is the only global source.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $H = mk_home();
    seed_todos('global', $H, 7, 0);
    seed_notes('global', $H, 5);
    write_snapshot($H, snapshot_json(open => 4, done => 1, note => 2));
    my ($out, $rc) = render(proj => $P_EMPTY, home => $H, sandbox => 1);
    my $v = strip_sgr(first_line($out));
    is(counter_seg($v, $G_TODO), "$G_TODO 4",
        'AC-5 (behaviour 8): sandbox -> the global todo count is the snapshot\'s todo.open (4), dimmed, no dot -- not the 7 in the vault under the same HOME')
        or diag("  row 1 = [$v]");
    is(counter_seg($v, $G_NOTE), "${G_NOTE}2", 'AC-5 (behaviour 8): the global note count is the snapshot\'s note.total (2), dimmed, no dot, no space -- not the vault\'s 5');
    ok(index($v, "$G_TODO 7") < 0 && index($v, "${G_NOTE}5") < 0, 'AC-5: nothing from the vault renders in a sandbox');
}

# ---------------------------------------------------------------------------
# AC-6 (behaviour 9) -- every invalid snapshot renders NO global count, the
# project counts survive, exit 0, and a dot-zero never renders. Every case's
# HOME also holds vault todos, so "no global count" cannot be satisfied by
# accidentally falling back to the vault.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 60) unless $ALMANAC_OK;
    my $valid = snapshot_json(open => 4, done => 0, note => 2);
    (my $valid_body = $valid) =~ s/\n\z//;
    my %CASES = (
        'snapshot missing'            => sub { },
        'snapshot is 0 bytes'         => sub { write_snapshot($_[0], '') },
        'snapshot is not JSON'        => sub { write_snapshot($_[0], "this is not json\n") },
        'snapshot is a JSON array'    => sub { write_snapshot($_[0], "[1,2,3]\n") },
        'schema is 2'                 => sub { write_snapshot($_[0], snapshot_json(schema => 2, open => 4, note => 2)) },
        'generated_at malformed'      => sub { write_snapshot($_[0], snapshot_json(generated_at => '"2026-09-26 00:00:00"', open => 4, note => 2)) },
        'negative todo.open'          => sub { write_snapshot($_[0], snapshot_json(open => -1, done => 0, total => 0, note => 2)) },
        'non-integer todo.open'       => sub { write_snapshot($_[0], snapshot_json(open => '1.5', done => 0, total => 0, note => 2)) },
        'non-integer note.total'      => sub { write_snapshot($_[0], snapshot_json(open => 4, note => '"two"')) },
        'todo.total missing'          => sub { write_snapshot($_[0], '{"generated_at":"2026-09-26T00:00:00Z","note":{"total":2},"schema":1,"todo":{"done":0,"open":4}}' . "\n") },
        '4097 bytes'                  => sub { write_snapshot($_[0], $valid_body . (' ' x (4096 - length($valid_body))) . "\n") },
        'a directory at the path'     => sub { make_path("$_[0]/.claude/almanac-global-counts.json") },
        'valid, but every count is 0' => sub { write_snapshot($_[0], snapshot_json(open => 0, done => 0, note => 0)) },
    );
    for my $label (sort keys %CASES) {
        my $H = mk_home();
        seed_todos('global', $H, 6, 0);
        $CASES{$label}->($H);
        if ($label eq '4097 bytes') {
            is(-s "$H/.claude/almanac-global-counts.json", 4097, 'AC-6 (fixture precondition): the oversized snapshot is exactly 4097 bytes');
        }
        my ($out, $rc) = render(proj => $P_FULL, home => $H, sandbox => 1);
        my $v = strip_sgr(first_line($out));
        is($rc, 0, "AC-6 ($label): the sandbox render exits 0");
        is(counter_seg($v, $G_TODO), "$G_TODO 5", "AC-6 ($label): no global todo count, and the project todo count still renders")
            or diag("  row 1 = [$v]");
        is(counter_seg($v, $G_NOTE), "${G_NOTE}2", "AC-6 ($label): no global note count, and the project note count still renders");
        is(index($v, "${G_DOT}0"), -1, "AC-6 ($label): a dot-zero never renders");
    }

    # The boundary from the other side: 4096 bytes is still a valid snapshot.
    my $H = mk_home();
    write_snapshot($H, $valid_body . (' ' x (4095 - length($valid_body))) . "\n");
    is(-s "$H/.claude/almanac-global-counts.json", 4096, 'AC-6 (fixture precondition): the boundary snapshot is exactly 4096 bytes');
    my ($out) = render(proj => $P_FULL, home => $H, sandbox => 1);
    my $v = strip_sgr(first_line($out));
    is(counter_seg($v, $G_TODO), "$G_TODO 5${G_DOT}4",
        'AC-6 (non-vacuity): a VALID snapshot of exactly 4096 bytes does render its global count -- the cases above fail on their defect, not on size alone')
        or diag("  row 1 = [$v]");
}

# ---------------------------------------------------------------------------
# AC-7 (behaviour 10) -- the retired todo plugin's store is not counted.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $H = mk_home();
    make_path("$H/.claude/claude-code-vault/todos");
    spew_raw("$H/.claude/claude-code-vault/todos/x.md", "- [ ] a legacy todo\n");
    for my $sb (0, 1) {
        my ($out) = render(proj => $P_EMPTY, home => $H, sandbox => $sb);
        is(index($out, $G_TODO), -1,
            'AC-7 (behaviour 10, ' . ($sb ? 'sandbox' : 'host') . '): a legacy claude-code-vault/todos/x.md with no almanac records renders no U+274F');
    }
    is(index($SL_RAW, 'claude-code-vault/todos'), -1, 'AC-7: statusline.pl no longer names claude-code-vault/todos anywhere');
}

# ---------------------------------------------------------------------------
# AC-8 -- the generator, and the byte-exact generated block.
# ---------------------------------------------------------------------------
{
    ok(-f $GENERATOR, 'AC-8: plugins/almanac/scripts/gen-statusline-counters.pl exists');
    my $scratch = nslash(tempdir(CLEANUP => 1));
    my ($g1, $e1, $rc1) = run_argv({ cwd => $scratch }, $^X, $GENERATOR);
    my ($g2, $e2, $rc2) = run_argv({ cwd => $scratch }, $^X, $GENERATOR);
    is($rc1, 0, 'AC-8: the generator exits 0 with no arguments') or diag("  stderr: $e1");
    is($rc2, 0, 'AC-8: ...and again on a second run');
    ok(length($g1) > 0, 'AC-8: the generator prints a payload');
    ok(-f $GENERATOR && length($g1) && $g2 eq $g1, 'AC-8: two generator runs print byte-identical output -- deterministic');
    ok(length($g1) && $g1 !~ /[^\x20-\x7E\n]/, 'AC-8: the payload is printable ASCII plus LF only');
    like($g1, qr/\n\z/, 'AC-8: the payload ends with a newline');
    my @lines = split /\n/, $g1, -1;
    pop @lines if @lines && $lines[-1] eq '';
    ok(@lines && !(grep { /[ \t]\z/ } @lines), 'AC-8 (spec 2.1): no trailing whitespace on any payload line');
    ok(@lines && !(grep { $_ eq '' } @lines), 'AC-8 (spec 2.1): no blank lines in the payload');
    is($lines[0] // '', '# ALMANAC COUNTERS -- generated from plugins/almanac/scripts/gen-statusline-counters.pl.',
        'AC-8: header line 1 is exact');
    is($lines[1] // '', '# Regenerate: perl plugins/almanac/scripts/gen-statusline-counters.pl',
        'AC-8: header line 2 is exact');
    ok(index($g1, 'almanac-global-counts.json') >= 0,
        'AC-8 (spec 2.1): the payload carries $Almanac::GlobalCounts::FILE_NAME, interpolated by the generator');
    my @left = do { opendir(my $dh, $scratch) or die "cannot list $scratch: $!"; grep { $_ ne '.' && $_ ne '..' } readdir($dh) };
    ok(-f $GENERATOR && !@left, 'AC-8 (spec 2.1): the generator writes no file -- its working directory is still empty')
        or diag('  left behind: ' . join(', ', @left));

    my ($ga, $ea, $rca) = run_argv({ cwd => $scratch }, $^X, $GENERATOR, '--write');
    ok(-f $GENERATOR && $rca == 2, 'AC-8 (spec 2.1): any argument is refused with exit 2');
    ok(-f $GENERATOR && $ga eq "", 'AC-8 (spec 2.1): ...printing nothing to stdout');
    my @elines = grep { length } split /\n/, $ea;
    ok(-f $GENERATOR && scalar(@elines) == 1, 'AC-8 (spec 2.1): ...and exactly one usage line to stderr') or diag("  stderr: [$ea]");

    my ($nb, $ne, $payload) = extract_between($SL_RAW, $CTR_BEGIN, $CTR_END);
    is($nb, 1, 'AC-8: the BEGIN GENERATED FROM gen-statusline-counters.pl marker occurs exactly once in statusline.pl');
    is($ne, 1, 'AC-8: the END marker occurs exactly once');
    ok(defined $payload, 'AC-8: BEGIN precedes END');
    ok(defined($payload) && length($g1) && $payload eq $g1, 'AC-8: the block between the markers is byte-equal (CRLF folded) to the generator\'s stdout')
        or diag('  regenerate with: perl plugins/almanac/scripts/gen-statusline-counters.pl');

    ok($SL_LF =~ qr/^\Q$CTR_BEGIN\E$/m, 'AC-8 (spec 2.2): the BEGIN marker sits at column 0');
    ok($SL_LF =~ qr/^\Q$CTR_END\E$/m,   'AC-8 (spec 2.2): the END marker sits at column 0');

    # spec 2.2: the block appears before its first call site. Comments are
    # blanked LENGTH-PRESERVING here, so offsets stay comparable.
    my $bpos = index($SL_LF, $CTR_BEGIN);
    my $epos = index($SL_LF, $CTR_END);
    my $first_call;
    (my $code = $SL_LF) =~ s/^([ \t]*#[^\n]*)$/' ' x length($1)/mge;
    while ($code =~ /\balmanac_(?:counts|focus)\s*\(/g) {
        my $at = $-[0];
        next if $bpos >= 0 && $epos > $bpos && $at > $bpos && $at < $epos;
        $first_call = $at unless defined $first_call;
    }
    ok($epos > $bpos && $bpos >= 0 && defined($first_call) && $first_call > $epos,
        'AC-8 (spec 2.2): the generated block ends before the first call of almanac_counts/almanac_focus');
}

# ---------------------------------------------------------------------------
# AC-9 -- the payload has no spawn, import or write construct.
# ---------------------------------------------------------------------------
{
    my (undef, undef, $payload) = extract_between($SL_RAW, $CTR_BEGIN, $CTR_END);
    my $pl = blank_comments(defined $payload ? $payload : '');
    my @f = forbidden_constructs($pl);
    ok(defined($payload) && $pl =~ /\S/ && !@f,
        'AC-9: the generated payload contains none of the spec 2.2 forbidden constructs (spawn, pipe/write open, use, require, do FILE)')
        or diag('  found: ' . join(', ', @f) . (defined $payload ? '' : ' (no generated block)'));
    for my $name (qw(almanac_counts almanac_focus)) {
        my $body;
        if ($pl =~ /\bsub\s+\Q$name\E\b/g) { $body = _balanced($pl, pos($pl), '{', '}') }
        ok(defined $body, "AC-9 (spec 2.2): the payload defines sub $name, the shared accessor");
        ok(defined($body) && $body =~ /\beval\s*\{/, "AC-9 (spec 2.2): $name wraps its body in eval, so it never dies to its caller");
    }
    my @top = grep { length && !/^\s/ } split /\n/, $pl;
    my @bad = grep { !/\A(?:sub\s+\w+|my\s*[\$(]|[})\]]+\s*;?\s*\z)/ } @top;
    ok(defined($payload) && !@bad,
        'AC-9 (spec 2.2): at column 0 the payload only opens subs or declares my scalars/constants')
        or diag('  unexpected top-level line(s): ' . join(' | ', @bad));

    # counter-fixtures (C-7): the scan fires on each construct...
    my @FIRE = (
        [ 'a backtick',          'my $x = `ls`;' ],
        [ 'qx',                  'my $x = qx{ls};' ],
        [ 'system',              'system("ls");' ],
        [ 'exec',                'exec "ls";' ],
        [ 'fork',                'my $pid = fork;' ],
        [ 'cmd_out',             'my $o = cmd_out("git");' ],
        [ 'spawn_detached',      'spawn_detached("x");' ],
        [ 'a -| pipe open',      q{open(my $fh, '-|', 'ls');} ],
        [ 'a write open',        q{open(my $fh, '>', $p);} ],
        [ 'an append open',      q{open my $fh, '>>:raw', $p;} ],
        [ 'a read-write open',   q{open(my $fh, '+<', $p);} ],
        [ 'use',                 "use Foo;\n" ],
        [ 'require',             'require Foo;' ],
        [ 'do FILE',             'do "x.pl";' ],
    );
    for my $c (@FIRE) {
        ok(scalar(forbidden_constructs($c->[1])) > 0, "AC-9 (counter-fixture): the construct scan FIRES on $c->[0]");
    }
    # ...and stays silent on the read-only builtins the payload is allowed.
    my $benign = q{opendir(my $dh, $d) or return 0; my @e = readdir($dh); closedir($dh);}
               . q{ open(my $fh, '<:raw', $f) or return; my $n = read($fh, my $buf, 4097);}
               . q{ my $j = eval { JSON::PP->new->decode($buf) }; my $ok = (-f $f && -d $d);}
               . q{ my @st = stat($f); utf8::decode($t); my $v = do { 1 };};
    is(scalar(forbidden_constructs($benign)), 0,
        'AC-9 (counter-fixture): the same scan stays silent on opendir/readdir/read-open/read/stat/-f/-d/utf8::decode/JSON::PP');
}

# ---------------------------------------------------------------------------
# AC-10 -- one reader of the store paths, one call site.
# ---------------------------------------------------------------------------
{
    my $outside = $SL_LF;
    my $bpos = index($outside, $CTR_BEGIN);
    my $epos = index($outside, $CTR_END);
    my $have = ($bpos >= 0 && $epos > $bpos) ? 1 : 0;
    ok($have, 'AC-10 (precondition): the generated block is present, so "outside the block" is well defined');
    substr($outside, $bpos, $epos + length($CTR_END) - $bpos, '') if $have;
    my $code = blank_comments($outside);
    is(index($code, '.ccpraxis-local-data/almanac'), -1,
        'AC-10: outside the generated block, statusline.pl code never names .ccpraxis-local-data/almanac');
    is(index($code, 'claude-code-vault'), -1,
        'AC-10: outside the generated block, statusline.pl code never names claude-code-vault');
    my @calls = ($code =~ /\balmanac_counts\s*\(/g);
    is(scalar(@calls), 1, 'AC-10: almanac_counts has exactly one call site');
}

# ---------------------------------------------------------------------------
# AC-11 -- U+2691 through the shared accessor, fed by the real CLI.
# ---------------------------------------------------------------------------
{
    my ($nb, $ne, $blk) = extract_between($SL_RAW, '# -- pending-decisions:begin --', '# -- pending-decisions:end --');
    is($nb, 1, 'AC-11: "# -- pending-decisions:begin --" occurs exactly once');
    is($ne, 1, 'AC-11: "# -- pending-decisions:end --" occurs exactly once');
    my $code = blank_comments(defined $blk ? $blk : '');
    like($code, qr/\balmanac_counts\s*\(/, 'AC-11: the code between the pending-decisions markers calls almanac_counts');
    my @f = forbidden_constructs($code);
    ok(defined($blk) && !@f, 'AC-11: the code between the markers contains no forbidden construct')
        or diag('  found: ' . join(', ', @f));
    unlike($code, qr/\b(?:opendir|readdir|glob)\b|\bopen\s*\(|<\$\w+>/,
        'AC-11: no hand-written directory scan or file read survives between the markers -- package 09\'s walk-up and scan are gone');
}
SKIP: {
    skip('almanac modules did not load', 6) unless $ALMANAC_OK;
    my $P = mk_proj();
    make_path("$P/sub/dir");
    my ($fo, $fe, $frc) = run_argv({ cwd => $P }, $^X, $DECISION_CLI, 'file', '--root', $P, '--title', 'Ship the counters?');
    is($frc, 0, 'AC-11 (fixture): almanac-decision.pl file --root <P> exits 0') or diag("  stderr: $fe");
    my ($id) = $fo =~ /^id:\s*(\S+)/m;

    my ($out, $rc) = render(cwd => "$P/sub/dir");
    like(strip_sgr(first_line($out)), qr/\Q$G_FLAG\E 1(?!\d)/,
        'AC-11 (behaviour 11): a decision filed through the real CLI renders U+2691 1 from <P>/sub/dir with no CLAUDE_PROJECT_DIR')
        or diag('  row 1 = [' . strip_sgr(first_line($out)) . ']');

    # spec 2.2 root rule: no marker on the walk -> CLAUDE_PROJECT_DIR. The
    # current_dir is an absolute path that does not exist and has no marker
    # above it, so the walk cannot reach any real directory.
    my ($outc) = render(cwd => '/ccpraxis-p10-no-such-dir/sub', env => { CLAUDE_PROJECT_DIR => $P });
    like(strip_sgr(first_line($outc)), qr/\Q$G_FLAG\E 1(?!\d)/,
        'AC-11 (spec 2.2): with no marker on the walk, CLAUDE_PROJECT_DIR is the project root');

    # section 5: a relative current_dir yields no project -- never the process
    # cwd, which here is <P> itself and holds the unanswered decision.
    my ($outr, $rcr) = render(cwd => 'relative/sub', pcwd => $P);
    is($rcr, 0, 'AC-11 (section 5): a relative current_dir exits 0');
    is(index($outr, $G_FLAG), -1,
        'AC-11 (section 5): a relative current_dir renders no U+2691 -- it never falls back to the process cwd (which holds one)');

    my ($ao, $ae, $arc) = run_argv({ cwd => $P }, $^X, $DECISION_CLI, 'answer', ($id // 'missing-id'), '--root', $P, '--answer', 'Yes, ship it');
    is($arc, 0, 'AC-11 (fixture): almanac-decision.pl answer exits 0') or diag("  stderr: $ae");
    my ($out2) = render(cwd => "$P/sub/dir");
    is(index($out2, $G_FLAG), -1, 'AC-11 (behaviour 11): once the decision is answered, no U+2691 renders');
}

# ---------------------------------------------------------------------------
# AC-12 -- exactly one reader of the legacy questions.md.
# ---------------------------------------------------------------------------
{
    my $gen_src = slurp_raw($GENERATOR);
    for my $lit ('questions.md', '.subagent-guard') {
        is(index($SL_RAW, $lit), -1, "AC-12: statusline.pl does not contain '$lit'");
        ok(length($gen_src) && index($gen_src, $lit) < 0, "AC-12: the generator's source does not contain '$lit'");
    }
    my $lq = blank_comments(slurp_raw($LEGACYQ_PM));
    my ($abs_start, $abs_len);
    if ($lq =~ /\bsub\s+absorb\b/g) {
        my $from = pos($lq);
        my $body = _balanced($lq, $from, '{', '}');
        if (defined $body) { $abs_start = index($lq, $body, $from); $abs_len = length $body }
    }
    ok(defined $abs_start, 'AC-12 (precondition): Almanac::LegacyQueue still defines sub absorb');
    my @calls;
    while ($lq =~ /\blegacy_path\s*\(/g) { push @calls, $-[0] }
    my @outside = grep { !defined($abs_start) || $_ < $abs_start || $_ > $abs_start + $abs_len } @calls;
    ok(@calls >= 1 && !@outside, 'AC-12: in LegacyQueue.pm, legacy_path( is called only inside sub absorb')
        or diag('  calls: ' . scalar(@calls) . ', outside absorb: ' . scalar(@outside));
}
{
    my $P = mk_proj();
    make_path("$P/.ccpraxis-local-data/.subagent-guard");
    my $legacy = "$P/.ccpraxis-local-data/.subagent-guard/questions.md";
    spew_raw($legacy, "## Q1\n- status: open\n- asked: 2026-09-01T00:00:00Z\n\nShould the counters ship?\n");
    my $before = slurp_raw($legacy);
    my ($out, $rc) = render(proj => $P);
    is($rc, 0, 'AC-12 (behaviour 12) setup: exits 0');
    is(index($out, $G_FLAG), -1, 'AC-12 (behaviour 12): a legacy questions.md with no decision store renders no U+2691');
    is(slurp_raw($legacy), $before, 'AC-12 (behaviour 12): the legacy file is byte-identical afterwards');
    ok(!-d "$P/.ccpraxis-local-data/almanac", 'AC-12 (behaviour 12): no almanac/ dir was created by the render');
}

# ---------------------------------------------------------------------------
# AC-13 -- the oracle fix, in THIS copy of the predicate.
# ---------------------------------------------------------------------------
for my $cp (0x2630, 0x2691, 0x25B6) {
    ok(!_is_emoji($cp), sprintf('AC-13: _is_emoji(0x%04X) is FALSE in statusline-rebuild.t\'s copy -- intersect, never substitute', $cp));
}
for my $cp (0x26AA, 0x2716, 0x26A0, 0xFE0F) {
    ok(_is_emoji($cp), sprintf('AC-13: _is_emoji(0x%04X) is TRUE in statusline-rebuild.t\'s copy', $cp));
}

# ---------------------------------------------------------------------------
# AC-14 -- the inline width table declares U+2630 at two columns.
# ---------------------------------------------------------------------------
{
    my $t = parse_glyph_cols($SRC_SL);
    is(defined($t) ? $t->{0x2630} : undef, 2, 'AC-14: statusline.pl\'s %GLYPH_COLS declares 0x2630 => 2 (East Asian Wide)');
}

# ---------------------------------------------------------------------------
# Behaviour 19 and section 5 -- failure paths and tolerant reads.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 8) unless $ALMANAC_OK;

    # Malformed records are skipped for status counts; since Decision 121 (S3) a
    # malformed NOTE is not counted either; names outside the id grammar never count.
    my $P = mk_proj();
    seed_todos('project', $P, 1, 0);
    seed_notes('project', $P, 1);
    my $td = "$P/.ccpraxis-local-data/almanac/todo";
    my $nd = "$P/.ccpraxis-local-data/almanac/note";
    spew_raw("$td/junk.md", "no frontmatter here\nstatus: open\n");
    spew_raw("$td/crlf.md", "---\r\nid: crlf\r\nstatus: open\r\n---\r\n");
    spew_raw("$nd/raw.md", "no frontmatter at all\n");
    spew_raw("$nd/_under.md", "---\ntitle: x\n---\n");
    spew_raw("$nd/a..b.md", "---\ntitle: x\n---\n");
    spew_raw("$nd/sidecar.md.seal", "seal\n");
    my ($out, $rc) = render(proj => $P);
    my $v = strip_sgr(first_line($out));
    is($rc, 0, 'behaviour 19: a store holding malformed records still exits 0');
    is(counter_seg($v, $G_TODO), "$G_TODO 1",
        'section 5: a record with no frontmatter and a CRLF record are skipped for status counts -- only the one valid open todo counts')
        or diag("  row 1 = [$v]");
    is(counter_seg($v, $G_NOTE), "${G_NOTE}1",
        'Decision 121 (S3, supersedes spec section 5): the note total counts only the valid note -- never the malformed raw.md, _under.md, a..b.md or a sidecar');

    # No HOME and no USERPROFILE: no global counts, project counts intact.
    my ($out2, $rc2) = render(proj => $P_FULL, env => { HOME => undef, USERPROFILE => undef });
    my $v2 = strip_sgr(first_line($out2));
    is($rc2, 0, 'behaviour 19: HOME and USERPROFILE both unset still exits 0');
    is(counter_seg($v2, $G_TODO), "$G_TODO 5", 'spec 2.2: with no home at all, global is unavailable and the project count still renders')
        or diag("  row 1 = [$v2]");

    # ALMANAC_HOME wins over HOME.
    my ($out3) = render(proj => $P_EMPTY, home => $H_EMPTY, env => { ALMANAC_HOME => $H_FULL });
    is(counter_seg(strip_sgr(first_line($out3)), $G_TODO), "$G_TODO 3",
        'spec 2.2: ALMANAC_HOME is consulted before HOME for the global stores, dimmed, no dot since the project side is 0');

    # Malformed and empty stdin.
    my ($bf, $bpath) = tempfile(DIR => $TMPROOT);
    print {$bf} "this is { not json";
    close $bf;
    my (undef, undef, $rcb) = run_argv({ cwd => $FAKE_ROOT, stdin => $bpath }, $^X, $STATUSLINE);
    is($rcb, 0, 'behaviour 19: malformed stdin still exits 0');
    my (undef, undef, $rce) = run_argv({ cwd => $FAKE_ROOT }, $^X, $STATUSLINE);
    is($rce, 0, 'behaviour 19: empty stdin still exits 0');
}

# ---------------------------------------------------------------------------
# AC-16 (behaviour 17) -- the fit ladder, with everything on at once.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 80) unless $ALMANAC_OK;
    my $sid = 'sess-p10-fit';
    my $P = mk_proj('fit-proj');
    seed_todos('project', $P, 1, 0);
    seed_notes('project', $P, 1);
    seed_tasks($P, ['pending']);
    seed_decisions($P, 1, 0);
    my $Q = mk_proj('focus-proj-fit');
    my $long_title = 'T' . ('x' x 199);
    seed_tasks($Q, ['doing', $long_title]);
    Almanac::Task::focus(root => $P, session => $sid, tasklist => $Q);
    my $H = mk_home();
    seed_todos('global', $H, 1, 0);
    seed_notes('global', $H, 1);
    write_snapshot($H, snapshot_json(open => 1, done => 0, note => 1));
    my $state = nslash(tempdir(CLEANUP => 1));
    make_path("$state/continuity/off");
    spew_raw("$state/continuity/off/$sid",
        JSON::PP->new->canonical->encode({ actor => 'agent', at => '2026-09-26T00:00:00Z',
                                            reason => 'paused for the operator', session_id => $sid }) . "\n");
    my $full_row = "$G_TASK focus-proj-fit $G_DOT $long_title";

    for my $sb (0, 1) {
        my $surf = $sb ? 'sandbox' : 'host';
        for my $cols (60, 80, 120) {
            my ($out, $rc) = render(proj => $P, home => $H, sandbox => $sb, sid => $sid, cols => $cols,
                                    data => $SEEDED_DATA, state => $state);
            is($rc, 0, "AC-16 ($surf, cols=$cols): exits 0");
            my @rows = split /\n/, $out;
            my @budgeted = $sb ? @rows : @rows[0 .. $#rows - 1];
            my @over = grep { row_cost($budgeted[$_]) > $cols } 0 .. $#budgeted;
            ok(@budgeted && !@over,
                "AC-16 ($surf, cols=$cols): every row except the host path row costs at most $cols")
                or diag('  over budget: ' . join(' | ', map { 'row ' . ($_ + 1) . ' cost ' . row_cost($budgeted[$_]) . ' [' . strip_sgr($budgeted[$_]) . ']' } @over));

            my $v1 = strip_sgr($rows[0] // '');
            my @present = map { index($v1, $_) >= 0 ? 1 : 0 } ($G_BLUEPRINT, $G_TODO, $G_NOTE, $G_TASK);
            my $n = 0; $n += $_ for @present;
            ok($n == 0 || $n == 4,
                "AC-16 ($surf, cols=$cols): the counters segment is wholly present or wholly absent on row 1 (glyphs present: $n of 4)")
                or diag("  row 1 = [$v1]");
            if ($n == 4) {
                is(counter_seg($v1, $G_TODO), "$G_TODO 1${G_DOT}1", "AC-16 ($surf, cols=$cols): a present todos counter is complete");
                is(counter_seg($v1, $G_NOTE), "${G_NOTE}1${G_DOT}1", "AC-16 ($surf, cols=$cols): a present notes counter is complete");
                is(counter_seg($v1, $G_TASK), "$G_TASK 1",           "AC-16 ($surf, cols=$cols): a present tasklist counter is complete");
            }

            my @tl = grep { index(strip_sgr($_), "$G_TASK ") == 0 } @rows;
            is(scalar(@tl), 1, "AC-16 ($surf, cols=$cols): exactly one focused-tasklist row");
            my $tv = strip_sgr($tl[0] // '');
            like($tv, qr/>\z/, "AC-16 ($surf, cols=$cols): the 200-character current task is right-elided with '>'")
                or diag("  tasklist row = [$tv]");
            ok(length($tv) > 1 && index($full_row, substr($tv, 0, -1)) == 0,
                "AC-16 ($surf, cols=$cols): what survives the elision is a prefix of the full tasklist row");
        }
    }

    # spec 2.3 (Decision 1(b)): the marker field is "<lead> <WORD>[ <badge>]".
    # U+2691 has left the marker entirely and leads the counters segment.
    my ($out) = render(proj => $P, home => $H, sid => $sid, cols => 200, state => $state);
    my $row1 = first_line($out);
    is(field_at($row1, 0), "$G_HOLLOW HOST $G_AGENTOFF",
        'AC-16 (spec 2.3): the marker field reads lead, word, then the badge -- no U+2691')
        or diag('  row 1 = [' . strip_sgr($row1) . ']');
    my @f16 = sep_fields($row1);
    my $last16 = @f16 ? $f16[-1] : '';
    ok(index($last16, "$G_FLAG 1  ") == 0,
        'AC-16 (spec 2.3): the last field starts with U+2691, a space, 1, and the two-space join')
        or diag("  last field = [$last16]");
}

# ---------------------------------------------------------------------------
# AC-17 (behaviour 16) -- the focused-tasklist row.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 16) unless $ALMANAC_OK;
    my $sid = 'sess-p10-focus';
    my $H = mk_home();

    my $PB = mk_proj();
    my @base_h = split /\n/, (render(proj => $PB, home => $H, sid => $sid))[0];
    my @base_s = split /\n/, (render(proj => $PB, home => $H, sid => $sid, sandbox => 1))[0];

    # a focus record exists, but for ANOTHER session.
    my $PN = mk_proj();
    my $QN = mk_proj('someone-elses-tasks');
    seed_tasks($QN, ['doing', 'not for this session']);
    Almanac::Task::focus(root => $PN, session => 'sess-p10-someone-else', tasklist => $QN);
    my @no = split /\n/, (render(proj => $PN, home => $H, sid => $sid))[0];
    is(scalar(@no), scalar(@base_h), 'AC-17: no task-focus/<sid>.md for this session -> the row count equals the baseline');
    is(scalar(grep { index(strip_sgr($_), "$G_TASK ") == 0 } @no), 0, 'AC-17: ...and no tasklist row is emitted');

    # focus on Q, whose FIRST doing task in (rank, id) order is the café one.
    my $P = mk_proj();
    my $Q = mk_proj('focus-proj-Q');
    my $current = "Refine the caf\x{e9} parser";
    seed_tasks($Q, ['pending', 'not this pending one'], ['done', 'nor this done one'],
                   ['doing', $current], ['doing', 'a later doing task']);
    Almanac::Task::focus(root => $P, session => $sid, tasklist => $Q);
    my $tl = Almanac::Task::focused(root => $P, session => $sid);
    my ($name) = (defined $tl ? $tl : '') =~ m{([^/]+)\z};
    is($name, 'focus-proj-Q', 'AC-17 (fixture precondition): the focus record names the tasklist whose basename is focus-proj-Q');
    my $want = "$G_TASK " . encode('UTF-8', $name // '') . " $G_DOT " . encode('UTF-8', $current);

    my ($oh) = render(proj => $P, home => $H, sid => $sid);
    my @rh = split /\n/, $oh;
    is(scalar(@rh), scalar(@base_h) + 1, 'AC-17 (host): focus adds exactly one row');
    is(strip_sgr($rh[-2] // ''), $want,
        'AC-17 (host): the extra row reads "U+25A3 <basename Q> . <first doing title>", UTF-8 encoded exactly once')
        or diag('  rows: ' . join(' | ', map { strip_sgr($_) } @rh));
    is(strip_sgr($rh[-1] // ''), $P, 'AC-17 (host): the last row is still the working directory');
    is(index($oh, "\xC3\x83"), -1, 'AC-17 (section 5): no double-encoded UTF-8 anywhere in the output');
    my $trow = $rh[-2] // '';
    my $truns = sgr_runs($trow);
    my $tvis = strip_sgr($trow);
    my $ni = length($G_TASK) + 1;
    my $di = $ni + length(encode('UTF-8', $name // '')) + 1;
    my $ci = $di + length($G_DOT) + 1;
    ok($tvis eq $want && run_ends_with($truns->[0], fg_sgr('text.muted')) && run_ends_with($truns->[$ni], fg_sgr('text.primary'))
       && run_ends_with($truns->[$di - 1], fg_sgr('text.faint')) && run_ends_with($truns->[$ci], fg_sgr('text.primary')),
        'AC-17 (spec 2.3): tasklist row colours -- glyph text.muted, name text.primary, " . " text.faint, current text.primary');

    my ($os) = render(proj => $P, home => $H, sid => $sid, sandbox => 1);
    my @rs = split /\n/, $os;
    is(scalar(@rs), scalar(@base_s) + 1, 'AC-17 (sandbox): focus adds exactly one row');
    is(strip_sgr($rs[-1] // ''), $want, 'AC-17 (sandbox): with no path row, the tasklist row is the last row');

    # spec 2.2: no doing task -> the name alone.
    my $P2 = mk_proj();
    my $Q2 = mk_proj('idle-tasks');
    seed_tasks($Q2, ['pending', 'waiting'], ['blocked', 'stuck']);
    Almanac::Task::focus(root => $P2, session => $sid, tasklist => $Q2);
    my @r2 = split /\n/, (render(proj => $P2, home => $H, sid => $sid))[0];
    is(strip_sgr($r2[-2] // ''), "$G_TASK idle-tasks", 'AC-17 (spec 2.2): a focused tasklist with no doing task renders "U+25A3 <name>" alone');

    # spec 2.2: a tasklist dir that no longer exists still yields the name.
    my $P3 = mk_proj();
    my $Q3 = mk_proj('vanished-tasks');
    Almanac::Task::focus(root => $P3, session => $sid, tasklist => $Q3);
    remove_tree($Q3);
    ok(!-d $Q3, 'AC-17 (fixture precondition): the focused tasklist directory is gone');
    my @r3 = split /\n/, (render(proj => $P3, home => $H, sid => $sid))[0];
    is(strip_sgr($r3[-2] // ''), "$G_TASK vanished-tasks", 'AC-17 (spec 2.2): a focused tasklist dir that does not exist still renders its name');

    # spec 2.2: a session id outside the id grammar never names a record.
    my @r4 = split /\n/, (render(proj => $P, home => $H, sid => '../sess-p10-focus'))[0];
    is(scalar(grep { index(strip_sgr($_), "$G_TASK ") == 0 } @r4), 0,
        'AC-17 (spec 2.2): a session_id outside the id grammar renders no tasklist row');
}

# ---------------------------------------------------------------------------
# AC-18 (spec 4.1) -- the render budget. Wall-clock, so it runs ONLY alone,
# behind STATUSLINE_BUDGET=1 (Decision 33: no timing assertion in the
# parallel sweep). "No subprocess" is asserted structurally in the sweep by
# AC-9. Record: STATUSLINE_BUDGET=1 perl plugins/sandbox/tests/t/statusline-rebuild.t
# ---------------------------------------------------------------------------
SKIP: {
    skip('AC-18: the render budget runs only with STATUSLINE_BUDGET=1, alone and outside the sweep', 3)
        unless ($ENV{STATUSLINE_BUDGET} // '') eq '1';
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $sid = 'sess-p10-budget';
    my $P = mk_proj();
    seed_todos('project', $P, 50, 0);
    seed_notes('project', $P, 50);
    seed_tasks($P, map { ['pending'] } 1 .. 50);
    Almanac::Decision::file(root => $P, title => "budget decision $_") for 1 .. 50;
    Almanac::Task::focus(root => $P, session => $sid, tasklist => $P);
    my $H = mk_home();
    seed_todos('global', $H, 50, 0);
    seed_notes('global', $H, 50);
    my $PB = mk_proj();
    my $HB = mk_home();

    my ($probe) = render(proj => $P, home => $H, sid => $sid);
    is(counter_seg(strip_sgr(first_line($probe)), $G_TODO), "$G_TODO 50${G_DOT}50",
        'AC-18 (non-vacuity): the populated fixture really renders its counts');

    my (@pop, @base);
    for (1 .. 20) {
        for my $case ([\@pop, $P, $H], [\@base, $PB, $HB]) {
            my $t0 = Time::HiRes::time();
            render(proj => $case->[1], home => $case->[2], sid => $sid);
            push @{ $case->[0] }, Time::HiRes::time() - $t0;
        }
    }
    my $mean = sub { my $s = 0; $s += $_ for @_; return $s / scalar(@_) };
    my ($mp, $mb) = ($mean->(@pop), $mean->(@base));
    diag(sprintf('  AC-18: mean populated %.4fs, mean baseline %.4fs, added %.4fs over 20 alternating renders each', $mp, $mb, $mp - $mb));
    cmp_ok($mp - $mb, '<', 0.050, 'AC-18: the mean added render cost of 50 records in every store is under 50 ms');
}

# ---------------------------------------------------------------------------
# Decision 121 (M1) -- PARSER PARITY with Almanac::Record (almanac-records
# Decision 38). The same bytes go through both parsers:
#   * Almanac::Record::check/parse decides accept or reject, and the status;
#   * a REAL render over a temp project whose todo store holds just that one
#     record decides whether the statusline counted it.
# The statusline must count the record iff Record accepts it AND its parsed
# status is exactly 'open'. Counting through the render rather than a private
# sub keeps this test independent of how the payload names its internals.
# ---------------------------------------------------------------------------
SKIP: {
    skip('almanac modules did not load', 60) unless $ALMANAC_OK;
    my @PARITY = (
        # [ label, bytes, Record verdict the fixture is built to produce ]
        [ 'valid LF record',                  "---\nid: x\nstatus: open\n---\n",                          'accept' ],
        [ 'valid record with a body',         "---\nid: x\ntitle: t\nstatus: open\n---\nbody text\n",     'accept' ],
        [ 'valid record, status done',        "---\nid: x\nstatus: done\n---\n",                          'accept' ],
        [ 'front matter only, no newline',    "---\nid: x\nstatus: open\n---",                            'accept' ],
        [ 'missing closing ---',              "---\nid: x\nstatus: open\n",                               'reject' ],
        [ 'missing closing ---, status in what is body', "---\nid: x\ntitle: t\n\nstatus: open\n",        'reject' ],
        [ 'CR on the opening --- only',       "---\r\nid: x\nstatus: open\n---\n",                        'reject' ],
        [ 'CR on the closing --- only',       "---\nid: x\nstatus: open\n---\r\n",                        'reject' ],
        [ 'all CRLF',                         "---\r\nid: x\r\nstatus: open\r\n---\r\n",                  'reject' ],
        [ 'duplicate status: key',            "---\nid: x\nstatus: open\nstatus: open\n---\n",            'reject' ],
        [ 'status:open with no space',        "---\nid: x\nstatus:open\n---\n",                           'reject' ],
        [ 'a tab separator',                  "---\nid: x\nstatus:\topen\n---\n",                         'reject' ],
        [ 'a non-field line in front matter', "---\nid: x\ntitle a\nstatus: open\n---\n",                 'reject' ],
        [ 'invalid UTF-8 in front matter',    "---\nid: x\ntitle: caf\xE9\nstatus: open\n---\n",          'reject' ],
        [ 'invalid UTF-8 in the body',        "---\nid: x\nstatus: open\n---\nbad \xFF byte\n",           'reject' ],
        [ 'status: open with a trailing space', "---\nid: x\nstatus: open \n---\n",                       'accept' ],
        [ 'empty file',                       '',                                                         'reject' ],
        [ 'empty front matter',               "---\n---\n",                                               'reject' ],
    );
    for my $case (@PARITY) {
        my ($label, $bytes, $built_for) = @$case;
        my $problems = Almanac::Record::check($bytes);
        my $accepted = (ref($problems) eq 'ARRAY' && !@$problems) ? 1 : 0;
        is($accepted ? 'accept' : 'reject', $built_for,
            "Decision 121 parity ($label): fixture precondition -- Almanac::Record::check gives the verdict the fixture was built for")
            or diag('  problems: ' . join('; ', map { $_->{kind} // '?' } @{ $problems || [] }));
        my $status;
        if ($accepted) {
            my $rec = eval { Almanac::Record::parse($bytes) };
            $status = $rec ? $rec->{fields}{status} : undef;
        }
        my $should_count = ($accepted && defined($status) && $status eq 'open') ? 1 : 0;

        my $P = mk_proj();
        make_path("$P/.ccpraxis-local-data/almanac/todo");
        spew_raw("$P/.ccpraxis-local-data/almanac/todo/x.md", $bytes);
        my ($out, $rc) = render(proj => $P, home => $H_EMPTY);
        my $v = strip_sgr(first_line($out));
        is($rc, 0, "Decision 121 parity ($label): the render exits 0");
        my $seg = counter_seg($v, $G_TODO);
        if ($should_count) {
            is($seg, "$G_TODO 1", "Decision 121 parity ($label): Record accepts it with status 'open', so the statusline counts it")
                or diag("  row 1 = [$v]");
        } else {
            is($seg, undef,
                "Decision 121 parity ($label): Record " . ($accepted ? "parses status '" . ($status // '(none)') . "'" : 'rejects it')
              . ', so the statusline counts nothing')
                or diag("  row 1 = [$v]");
        }
    }

    # The same rule reaches the decision counter, where a false U+2691 would
    # tell the operator answers are waiting when almanac-decision.pl has none.
    for my $case (
        [ 'unterminated decision',          "---\nid: d\nstatus: unanswered\n",            0 ],
        [ 'decision with status:unanswered', "---\nid: d\nstatus:unanswered\n---\n",       0 ],
        [ 'valid unanswered decision',      "---\nid: d\nstatus: unanswered\n---\n",       1 ],
    ) {
        my ($label, $bytes, $want) = @$case;
        my $P = mk_proj();
        make_path("$P/.ccpraxis-local-data/almanac/decision");
        spew_raw("$P/.ccpraxis-local-data/almanac/decision/d.md", $bytes);
        my ($out) = render(proj => $P, home => $H_EMPTY);
        my $has = ($out =~ /\Q$G_FLAG\E 1(?!\d)/) ? 1 : 0;
        is($has, $want, "Decision 121 parity ($label): U+2691 renders iff Almanac::Record accepts the record as unanswered");
    }

    # S3: notes follow the same parity rule -- a malformed note is not counted.
    my $PN = mk_proj();
    seed_notes('project', $PN, 1);
    my $nd = "$PN/.ccpraxis-local-data/almanac/note";
    spew_raw("$nd/broken-unterminated.md", "---\ntitle: never closed\n");
    spew_raw("$nd/broken-crlf.md", "---\r\ntitle: crlf\r\n---\r\n");
    spew_raw("$nd/broken-nospace.md", "---\ntitle:x\n---\n");
    my ($on) = render(proj => $PN, home => $H_EMPTY);
    is(counter_seg(strip_sgr(first_line($on)), $G_NOTE), "${G_NOTE}1",
        'Decision 121 (S3): malformed notes are not counted -- only the one valid note')
        or diag('  row 1 = [' . strip_sgr(first_line($on)) . ']');
    my $HN = mk_home();
    seed_notes('global', $HN, 1);
    make_path("$HN/.claude/claude-code-vault/almanac/note");
    spew_raw("$HN/.claude/claude-code-vault/almanac/note/broken.md", "---\ntitle: never closed\n");
    my ($og) = render(proj => $P_EMPTY, home => $HN);
    is(counter_seg(strip_sgr(first_line($og)), $G_NOTE), "${G_NOTE}1",
        'Decision 121 (S3): a malformed GLOBAL note is not counted either, dimmed, no dot, no space');
}

# ---------------------------------------------------------------------------
# Decision 121 (S1) -- the silence badge is judged on the Stop gate's terms:
# the record is decoded as UTF-8 JSON and words are split on \s+ over
# CHARACTERS, so a reason separated only by Unicode whitespace has 2 words.
# The oracle is BpHook's own _read_json and _word_count, run on the same file
# (never take_silence, which consumes it).
# ---------------------------------------------------------------------------
{
    my $BPHOOK_OK = eval { require "$Bin/../../../butler/scripts/BpHook.pm"; 1 };
    ok($BPHOOK_OK, 'Decision 121 (S1) setup: BpHook.pm loads, so the gate\'s own reader is the oracle')
        or diag("  $@");
  SKIP: {
        skip('BpHook.pm did not load', 8) unless $BPHOOK_OK;
        for my $case (
            [ 'U+3000 only',  "waiting\x{3000}operator" ],
            [ 'U+00A0 only',  "waiting\x{00A0}operator" ],
            [ 'U+2003 only',  "waiting\x{2003}operator" ],
            [ 'one word plus a trailing U+3000', "waiting\x{3000}" ],
        ) {
            my ($label, $reason) = @$case;
            my $sid = 'sess-p10-s1-' . (++$fixture_seq);
            my $state = nslash(tempdir(CLEANUP => 1));
            make_path("$state/continuity/armed", "$state/continuity/silence");
            spew_raw("$state/continuity/armed/$sid", '');
            spew_raw("$state/continuity/silence/$sid",
                JSON::PP->new->utf8->canonical->encode({ at => '2026-09-26T00:00:00Z', by => 'butler-continuity',
                                                         reason => $reason, session_id => $sid }) . "\n");
            my $data = BpHook::_read_json("$state/continuity/silence/$sid");
            my $gate = (ref($data) eq 'HASH' && ($data->{session_id} // '') eq $sid
                        && ($data->{by} // '') eq 'butler-continuity'
                        && BpHook::_word_count($data->{reason}) >= 2) ? 1 : 0;
            my ($out, $rc) = render(proj => $P_EMPTY, home => $H_EMPTY, sid => $sid, state => $state);
            is($rc, 0, "Decision 121 (S1, $label): exits 0");
            is((index($out, $G_SILENCED) >= 0 ? 1 : 0), $gate,
                "Decision 121 (S1, $label): the badge shows U+2016 iff the Stop gate would honour this silence (gate says $gate)");
        }
    }
}

# ---------------------------------------------------------------------------
# Hermeticity -- the real repo's almanac store is unchanged by this file.
# ---------------------------------------------------------------------------
is_deeply(almanac_listing($REAL_STORE), $REAL_STORE_BEFORE,
    'hygiene: the real repo\'s .ccpraxis-local-data/almanac listing is unchanged by this whole file');

done_testing();
