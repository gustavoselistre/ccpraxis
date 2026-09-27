# BpProjectRoot.pm — which PROJECT a butler script is working on.
#
# One rule, previously written out separately in the retired continuity CLI,
# bp-drive-next.pl, bp-spend.pl, bp-lib.sh and the retired bp-runstate.pl:
#
#   $CLAUDE_PROJECT_DIR > $BP_PROJECT_ROOT > git toplevel
#     > walk up from cwd for a dir holding .ccpraxis-local-data > cwd
#
# THE CHAIN ENDS AT CWD, NEVER AT THE INSTALL DIR. Every copy of this rule
# exists because some script once guessed the project as three directories
# above its own file. Butler runs from an install outside the project
# (~/.claude/ccpraxis, or a plugin mount in a sandbox), so that guess names
# the install, and state written there is invisible to the project: 111
# stray dispatch records in the repo's store (report 20260911-185413-1eca),
# run-state anchored to the install (c724d0d), and 21 dispatch records left
# inside the live install by bp-dispatch-log.pl (2026-09-23).
#
# An empty value counts as unset at every step: `--root ""` or an exported
# empty variable must not resolve to the filesystem root.
package BpProjectRoot;
use strict;
use warnings;
no warnings 'redefine';   # this file may be require'd under >1 path spelling
use Cwd ();
use File::Basename qw(dirname);

# resolve() -> the project root, never undef. The git/walk-up answer is
# memoized per (cwd) for the life of the process: callers such as
# bp-dispatch-log.pl resolve several paths per run, and each `git rev-parse`
# costs ~0.3s on the Windows host. The environment steps are cheap and are
# re-read every call, so a changed variable always takes effect.
my %CACHE;
sub resolve {
    for my $var (qw(CLAUDE_PROJECT_DIR BP_PROJECT_ROOT)) {
        return $ENV{$var} if defined $ENV{$var} && length $ENV{$var};
    }
    my $cwd = Cwd::getcwd() // '';
    return $CACHE{$cwd} //= _from_cwd();
}

sub _from_cwd {

    # git toplevel — trust only a clean exit and a real directory.
    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    if ($? == 0 && defined $top) {
        chomp $top;
        return $top if length $top && -d $top;
    }

    my $found = bounded_walkup(Cwd::getcwd());
    return $found if defined $found;

    return Cwd::getcwd() // '.';
}

# ---------------------------------------------------------------------------
# bounded_walkup/bounded_ancestors (package 03, Decision 3 & 20) — the ONLY
# adapter between this file and BpDataRoot.pm. Every other widened caller
# (bp-feedback.pl, bp-checkpoint.pl, bp-orchestrator.pl, bp-cache-state.pl,
# bp-progress.pl, BpSession.pm, bp-spend.pl) calls these two functions, never
# BpDataRoot's own underscore-prefixed internals directly. They mirror
# BpDataRoot::_walkup's bounded rules exactly: never ascend out of temp, and
# never adopt home unless the start IS home (R1-R4, spec §2.2). BpDataRoot.pm
# is loaded lazily -- inside these functions, never at module load -- so a
# caller whose CLAUDE_PROJECT_DIR/BP_PROJECT_ROOT short-circuits resolve()
# never pays for it (AC13).
# ---------------------------------------------------------------------------

my $BPDATAROOT_DIR;

sub _bpdataroot_dir {
    return $BPDATAROOT_DIR if defined $BPDATAROOT_DIR;
    my $f = __FILE__;
    $f =~ s{\\}{/}g;
    $BPDATAROOT_DIR = dirname(Cwd::abs_path($f) // $f);
    return $BPDATAROOT_DIR;
}

# _load_bpdataroot() -> 1 on success, 0 on failure. Never dies.
#
# Decision 24 item 4 (review S3/red-team N3): gate on the two PUBLIC symbols
# this file actually calls (BpDataRoot::walkup / ::ancestors), not the
# private BpDataRoot::_walkup. Gating on the wrong symbol let an already-
# loaded BpDataRoot.pm without the Decision 20 public API pass this check,
# then die inside the `eval` at the call site below -- silently yielding "no
# project" instead of reporting the mismatch.
sub _load_bpdataroot {
    return 1 if defined &BpDataRoot::walkup && defined &BpDataRoot::ancestors;
    my $dir = _bpdataroot_dir();
    return eval { require "$dir/BpDataRoot.pm"; 1 } ? 1 : 0;
}

# _byte_path($p) -> $p re-encoded to raw UTF-8 bytes if it arrived as a
# decoded (utf8-flagged) Perl character string -- e.g. straight out of
# JSON::PP->utf8->decode (Decision 22). The filesystem, and every path this
# adapter compares or returns, uses that byte representation on this perl, so
# a caller may hand either form to bounded_walkup/bounded_ancestors.
sub _byte_path {
    my ($p) = @_;
    return $p unless defined $p;
    utf8::encode($p) if utf8::is_utf8($p);
    return $p;
}

# bounded_walkup($start) -> $dir | undef. $start undef/'' defaults to
# Cwd::getcwd(). Never dies; returns undef if BpDataRoot.pm cannot be loaded.
sub bounded_walkup {
    my ($start) = @_;
    $start = Cwd::getcwd() // '.' unless defined $start && length $start;
    $start = _byte_path($start);
    return undef unless _load_bpdataroot();
    my $r = eval { BpDataRoot::walkup(cwd => $start) };
    return $@ ? undef : $r;
}

# bounded_ancestors($start) -> @dirs (empty list if BpDataRoot.pm cannot be
# loaded). See BpDataRoot::ancestors for the algorithm.
sub bounded_ancestors {
    my ($start) = @_;
    $start = Cwd::getcwd() // '.' unless defined $start && length $start;
    $start = _byte_path($start);
    return () unless _load_bpdataroot();
    my @r = eval { BpDataRoot::ancestors(cwd => $start) };
    return $@ ? () : @r;
}

1;
