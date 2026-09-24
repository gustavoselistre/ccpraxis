# BpHook::Guards::GuardBlueprintWrite -- denies a direct Write/Edit/
# MultiEdit/NotebookEdit that targets a blueprint.md path or a package
# ledger path, forcing both kinds of mutation through their typed APIs
# (bp-blueprint.pl and bp-ledger.pl create). Absorbs guard-ledger-create
# (package 14 of blueprint hook-continuity-remake), successor to
# guard-blueprint-write.sh and guard-ledger-create.sh.
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

    # Rule 1: a direct write to blueprint.md itself, except the template
    # bp-blueprint.pl init reads from.
    if ($abs =~ m{/blueprint\.md$} && $abs !~ m{/plugins/.*/templates/blueprint\.md$}) {
        return BpHook::deny(
            BpHook::Guards::Common::fit("BLUEPRINT-GUARD: BLOCKED -- direct $tool refused: $path_disp"),
            BpHook::Guards::Common::fit($BLUEPRINT_L2),
        );
    }

    # Rule 2: a package ledger path -- the evidence-gated override check.
    my $norm = lc($abs);
    $norm =~ s/::\$data\z//;
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
