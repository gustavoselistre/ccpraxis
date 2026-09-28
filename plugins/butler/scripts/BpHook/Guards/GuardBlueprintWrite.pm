# BpHook::Guards::GuardBlueprintWrite -- denies a direct Write/Edit/
# MultiEdit/NotebookEdit that targets a blueprint.md path or a package
# ledger path, forcing both kinds of mutation through their typed APIs
# (bp-blueprint.pl and bp-ledger.pl create). Absorbs the old separate
# ledger-creation guard (package 14 of blueprint hook-continuity-remake),
# successor to both, now merged into hooks/guard-blueprint-write.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.3. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-blueprint-write"
# successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). Never re-parses the payload (BpHook::parse_count()
# is unchanged by run()). Applies to every session and caller -- no session
# state is read here (spec sec 3.3's opening line).
package BpHook::Guards::GuardBlueprintWrite;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;

my $LEDGER_L2_CREATE  = 'Create a package ledger only with bp-ledger.pl create, which validates model:/effort: and refuses a ledger its own validate verb would reject.';
my $LEDGER_L2_CONSUME = 'A valid ledger-write-override was found but could not be consumed; remove it by hand and retry through bp-ledger.pl create.';
my $BLUEPRINT_L2      = 'Change blueprint.md only through plugins/butler/scripts/bp-blueprint.pl (add-package, set-deps, add-decision, set-field) via Bash, then retry.';

# ---------------------------------------------------------------------------
# Decision 69 A2 (package 16 spec sec 2.6): $CASE_INSENSITIVE, duplicated
# minimally from BpHook::WriteGuards' own _is_ci/_foldc (same auto rule --
# undef means "auto-detect from $^O": true on msys, MSWin32, cygwin, darwin).
# ---------------------------------------------------------------------------
our $CASE_INSENSITIVE;

sub _is_ci {
    return $CASE_INSENSITIVE ? 1 : 0 if defined $CASE_INSENSITIVE;
    return ($^O =~ /\A(?:msys|MSWin32|cygwin|darwin)\z/) ? 1 : 0;
}

sub _foldc {
    my ($s) = @_;
    return $s unless defined $s;
    my $t = $s;
    $t =~ tr/A-Z/a-z/;
    return $t;
}

# ---------------------------------------------------------------------------
# _cmp_of($abs) -- package 16 spec sec 2.6: segments matching an 8.3 alias of
# "blueprints" or "packages" read as their long name; then ASCII-folded when
# case-insensitive.
# ---------------------------------------------------------------------------
sub _seg_expand {
    my ($seg) = @_;
    return 'blueprints' if $seg =~ /\ABLUEPR~[0-9]+\z/i;
    return 'packages'   if $seg =~ /\APACKAG~[0-9]+\z/i;
    return $seg;
}

sub _cmp_of {
    my ($abs) = @_;
    my @segs = split m{/}, $abs;
    my $cmp = join('/', map { _seg_expand($_) } @segs);
    $cmp = _foldc($cmp) if _is_ci();
    return $cmp;
}

# ---------------------------------------------------------------------------
# _has_8dot3_basename($raw_base) -- the raw basename matches the 8.3 alias
# of blueprint.md, on every host (independent of $CASE_INSENSITIVE).
# ---------------------------------------------------------------------------
sub _has_8dot3_basename {
    my ($raw_base) = @_;
    return 0 unless defined $raw_base;
    return ($raw_base =~ /\ABLUEPR~[0-9]+\.MD\z/i) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _deny_ledger($tool, $path_disp, $l2) -> 2.
# ---------------------------------------------------------------------------
sub _deny_ledger {
    my ($tool, $path_disp, $l2) = @_;
    return BpHook::deny(
        BpHook::Guards::Common::fit("LEDGER-CREATE-GUARD: BLOCKED -- direct $tool refused: $path_disp"),
        BpHook::Guards::Common::fit($l2),
    );
}

# ---------------------------------------------------------------------------
# _read_first_line($path) -> the first line of $path, trailing CR/LF
# stripped, or undef if the file cannot be opened.
# ---------------------------------------------------------------------------
sub _read_first_line {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    $line =~ s/\r\z//;
    return $line;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && length $tool;
    return 0 unless $tool =~ /^(?:Write|Edit|MultiEdit|NotebookEdit)$/;

    my $ti = $p->{tool_input};
    my $fp;
    if (ref $ti eq 'HASH') {
        $fp = $ti->{file_path};
        if (!defined $fp || ref($fp) || !length $fp) {
            $fp = $ti->{notebook_path};
        }
    }
    return 0 unless defined $fp && !ref($fp) && length $fp;

    my $cwd = (ref $p eq 'HASH' && defined $p->{cwd} && !ref($p->{cwd})) ? $p->{cwd} : undef;
    my $abs = BpHook::Guards::Common::resolve_path($fp, $cwd);
    return 0 unless defined $abs && length $abs;
    my $path_disp = BpHook::Guards::Common::path_echo($abs);

    # Decision 69 A2 (package 16 spec sec 2.6): $cmp reads an 8.3 alias
    # directory segment as its long name, then folds ASCII case when this
    # host (or the test) is case-insensitive.
    my $cmp = _cmp_of($abs);
    my ($raw_base) = $abs =~ m{([^/]+)\z};
    my ($cmp_base)  = $cmp =~ m{([^/]+)\z};

    # Rule 1: a direct write to blueprint.md itself (by its long name, a
    # case variant of it, or its 8.3 alias basename), except the template
    # bp-blueprint.pl init reads from (tested on $cmp).
    my $is_8dot3_basename = _has_8dot3_basename($raw_base);
    my $hits_blueprint_name = (defined $cmp_base && $cmp_base eq 'blueprint.md') ? 1 : 0;
    if ($is_8dot3_basename || $hits_blueprint_name) {
        my $templated = ($cmp =~ m{/plugins/[^/]+/templates/blueprint\.md\z}) ? 1 : 0;
        unless ($templated) {
            if ($is_8dot3_basename) {
                return BpHook::deny(BpHook::Guards::Common::fit(sprintf(
                    'BLOCKED: %s uses a Windows short (8.3) name; write it by its long name.', $path_disp)));
            }
            return BpHook::deny(
                BpHook::Guards::Common::fit("BLUEPRINT-GUARD: BLOCKED -- direct $tool refused: $path_disp"),
                BpHook::Guards::Common::fit($BLUEPRINT_L2),
            );
        }
        return 0;
    }

    # Rule 2: a package ledger path -- the evidence-gated override check.
    # Today's regex, applied to $cmp instead of lc($abs) (package 16 spec
    # sec 2.6).
    my $norm = $cmp;
    $norm =~ s/::\$data\z//i;
    $norm =~ s/[.\s]+\z//;
    if ($norm =~ m{/blueprints/.*/packages/.*\.md\z}) {
        my $root = $ENV{CLAUDE_PROJECT_DIR};
        if (!defined $root || !length $root) {
            $root = $cwd;
        }
        if (!defined $root || !length $root) {
            $root = Cwd::getcwd();
        }
        $root = '' unless defined $root;
        (my $root_fs = $root) =~ tr{\\}{/};
        $root_fs =~ s{/+\z}{};

        my $override = "$root_fs/.ccpraxis-local-data/.subagent-guard/ledger-write-override";
        unless (-f $override) {
            return _deny_ledger($tool, $path_disp, $LEDGER_L2_CREATE);
        }

        my $raw = _read_first_line($override);
        my $id = defined $raw ? $raw : '';
        $id =~ s/^\s+//;
        $id =~ s/\s+\z//;

        if ($id eq '' || $id =~ m{[/\\]} || index($id, '..') >= 0) {
            return _deny_ledger($tool, $path_disp, $LEDGER_L2_CREATE);
        }

        my $report = "$root_fs/.ccpraxis-local-data/bug-reports/$id.md";
        unless (-f $report) {
            return _deny_ledger($tool, $path_disp, $LEDGER_L2_CREATE);
        }

        my $skip_consume = $ENV{BP_LEDGER_GUARD_FAIL_CONSUME};
        unless (defined $skip_consume && length $skip_consume) {
            unlink $override;
        }
        if (-e $override) {
            return _deny_ledger($tool, $path_disp, $LEDGER_L2_CONSUME);
        }
        return 0;
    }

    return 0;
}

1;
