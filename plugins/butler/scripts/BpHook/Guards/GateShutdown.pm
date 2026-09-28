# BpHook::Guards::GateShutdown -- a fleet stop signal (shutdown, force-stop
# or paused) STOPS-AND-PARKS every Task/Agent dispatch and every edit
# outside BP_DIR or /tmp/ (package 14 of blueprint hook-continuity-remake),
# successor to gate-shutdown.sh's two old registrations (the edit-tool
# registration and the Task registration, now one module).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.5. Architecture:
# plugins/butler/docs/hook-architecture.md ("gate-shutdown" successor row).
# Env-only (coordinator fleet files, Decision 4); no session state read.
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). FAILS CLOSED under an active signal (the one
# exception to package 14's usual fail-open rule): a bad payload or a
# missing tool_name denies instead of allowing.
package BpHook::Guards::GateShutdown;
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

my $NO_TOOLNAME = "STOP-AND-PARK: a fleet stop is active and this tool call has no identifiable tool_name; denied. Record '## Next action' and stop.";

# ---------------------------------------------------------------------------
# _signal($bpdir_fs, $pkg) -> ($l1, $l2) | () for the active signal, in
# precedence order: shutdown, force-stop, paused. () means no signal.
# ---------------------------------------------------------------------------
sub _signal {
    my ($bpdir_fs, $pkg) = @_;
    if (-e "$bpdir_fs/runs/.shutdown") {
        return (
            "STOP-AND-PARK: a fleet-wide graceful shutdown is in progress; set status: parked, last_updated via iso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock), stop.",
            "Record the in-flight result and '## Next action' first; new work is denied and the run stays down until relaunched.",
        );
    }
    if (-e "$bpdir_fs/runs/$pkg.force-stop") {
        return (
            "STOP-AND-PARK: this package is being force-stopped (runs/$pkg.force-stop); new work is denied.",
            "Record a concrete '## Next action', then stop.",
        );
    }
    if (-e "$bpdir_fs/runs/.paused") {
        return (
            "STOP-AND-PARK: the fleet is paused to preserve the usage reserve; stay non-terminal, last_updated via iso_now (or date -u +%Y-%m-%dT%H:%M:%SZ; no clock).",
            "Record the drained result and a concrete '## Next action', then stop; this package auto-resumes after the window resets.",
        );
    }
    return ();
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    # review m1 (Rm1): this gate scopes to coordinator sessions -- the old
    # hook ran bp_hook_gate first. Without this, any in-process caller whose
    # BP_DIR happens to hold a signal file gets a fail-closed deny where the
    # scope says allow.
    return 0 unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};

    my $bp_dir = $ENV{BP_DIR};
    return 0 unless defined $bp_dir && length $bp_dir;
    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};

    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;

    my ($l1, $l2) = _signal($bpdir_fs, $pkg);
    return 0 unless defined $l1;

    my $tool = $p->{tool_name};
    if (!BpHook::payload_ok() || !defined $tool || ref($tool) || !length $tool) {
        return BpHook::deny(BpHook::Guards::Common::fit($NO_TOOLNAME));
    }

    if ($tool eq 'Task' || $tool eq 'Agent') {
        return BpHook::deny(BpHook::Guards::Common::fit($l1), BpHook::Guards::Common::fit($l2));
    }

    if ($tool =~ /^(?:Write|Edit|MultiEdit|NotebookEdit)$/) {
        my $ti = $p->{tool_input};
        my $fp;
        if (ref $ti eq 'HASH') {
            $fp = $ti->{file_path};
            if (!defined $fp || ref($fp) || !length $fp) {
                $fp = $ti->{notebook_path};
            }
        }
        return BpHook::deny(BpHook::Guards::Common::fit($l1), BpHook::Guards::Common::fit($l2))
            unless defined $fp && !ref($fp) && length $fp;

        my $cwd = (defined $p->{cwd} && !ref($p->{cwd})) ? $p->{cwd} : undef;
        my $abs = BpHook::Guards::Common::resolve_path($fp, $cwd);

        my $canon_abs   = BpHook::Guards::Common::canon($abs);
        my $canon_bpdir = BpHook::Guards::Common::canon($bpdir_fs);
        my $under_bpdir = (defined $canon_abs && defined $canon_bpdir
            && index($canon_abs, "$canon_bpdir/") == 0) ? 1 : 0;
        my $under_tmp = (defined $abs && $abs =~ m{^/tmp/}) ? 1 : 0;

        return 0 if $under_bpdir || $under_tmp;
        return BpHook::deny(BpHook::Guards::Common::fit($l1), BpHook::Guards::Common::fit($l2));
    }

    return 0;
}

1;
