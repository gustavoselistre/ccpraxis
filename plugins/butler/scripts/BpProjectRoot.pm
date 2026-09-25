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

    my $d = Cwd::getcwd();
    if (defined $d && length $d) {
        my %seen;
        while (!$seen{$d}++) {
            return $d if -d "$d/.ccpraxis-local-data";
            my $parent = dirname($d);
            last if $parent eq $d;
            $d = $parent;
        }
    }

    return Cwd::getcwd() // '.';
}

1;
