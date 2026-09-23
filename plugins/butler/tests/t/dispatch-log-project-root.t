#!/usr/bin/env perl
# platform: any
# Where bp-dispatch-log.pl puts its store when no --root is given: under the
# PROJECT (BpProjectRoot::resolve), never under the directory the script
# itself is installed in.
#
# The regression: log_dir defaulted to $CLAUDE_PROJECT_DIR, else three levels
# above the script. A drive-solo driver's Bash tool does not carry
# CLAUDE_PROJECT_DIR, so a driver running the live install's copy wrote its
# dispatch records into ~/.claude/ccpraxis/.ccpraxis-local-data -- 21 of them
# were found there on 2026-09-23. An empty --root (passed by two hooks when
# BP_PROJECT_ROOT is unset) resolved to "/.ccpraxis-local-data".
#
# Every fixture is a tempdir with GIT_CEILING_DIRECTORIES pinned above it, so
# `git rev-parse` can never discover a real repository from inside one, and
# CLAUDE_PROJECT_DIR / BP_PROJECT_ROOT are stripped.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd ();

my $SCRIPTS = "$Bin/../../scripts";
my $LOG_PL  = "$SCRIPTS/bp-dispatch-log.pl";
ok(eval { require "$SCRIPTS/BpProjectRoot.pm"; 1 }, 'BpProjectRoot.pm loads') or BAIL_OUT($@);
ok(eval { require $LOG_PL; 1 }, 'bp-dispatch-log.pl loads as a library') or BAIL_OUT($@);

delete $ENV{$_} for qw(CLAUDE_PROJECT_DIR BP_PROJECT_ROOT);

sub project {
    my $base = tempdir(CLEANUP => 1);
    my $proj = "$base/proj";
    make_path("$proj/.ccpraxis-local-data", "$proj/deep/er");
    return (Cwd::abs_path($base), Cwd::abs_path($proj));
}

sub in_dir {
    my ($dir, $code) = @_;
    my $old = Cwd::getcwd();
    chdir $dir or die "chdir $dir: $!";
    my @r = eval { $code->() };
    my $err = $@;
    chdir $old;
    die $err if $err;
    return wantarray ? @r : $r[0];
}

subtest 'resolve: environment first, then the directory walk, never the install' => sub {
    my ($base, $proj) = project();
    local $ENV{GIT_CEILING_DIRECTORIES} = $base;
    {
        local $ENV{CLAUDE_PROJECT_DIR} = '/from/claude';
        local $ENV{BP_PROJECT_ROOT}    = '/from/bp';
        is(BpProjectRoot::resolve(), '/from/claude', 'CLAUDE_PROJECT_DIR first');
    }
    {
        local $ENV{BP_PROJECT_ROOT} = '/from/bp';
        is(BpProjectRoot::resolve(), '/from/bp', 'then BP_PROJECT_ROOT');
    }
    {
        local $ENV{CLAUDE_PROJECT_DIR} = '';
        is(in_dir("$proj/deep/er", sub { BpProjectRoot::resolve() }), $proj,
           'an EMPTY variable is unset; walks up from cwd to the dir holding .ccpraxis-local-data');
    }
    my $plain = Cwd::abs_path(tempdir(CLEANUP => 1));
    {
        local $ENV{GIT_CEILING_DIRECTORIES} = dirname($plain);
        # The machine may hold a real data dir above the tempdir (a home
        # directory can), so the expectation is computed, not assumed: the
        # nearest ancestor holding one, else cwd itself.
        my $want = $plain;
        for (my $d = $plain; ; ) {
            if (-d "$d/.ccpraxis-local-data") { $want = $d; last }
            my $p = dirname($d);
            last if $p eq $d;
            $d = $p;
        }
        is(in_dir($plain, sub { BpProjectRoot::resolve() }), $want,
           'no data dir in the tempdir: the nearest ancestor holding one, else cwd');
    }
    my $install = Cwd::abs_path("$SCRIPTS/../../..");
    isnt(in_dir("$proj/deep", sub { BpProjectRoot::resolve() }), $install, 'never the install dir');
};

subtest 'log_dir: undef and empty root both resolve to the project' => sub {
    my ($base, $proj) = project();
    local $ENV{GIT_CEILING_DIRECTORIES} = $base;
    is(in_dir($proj, sub { BpDispatchLog::log_dir(undef) }), "$proj/.ccpraxis-local-data/.dispatch-log", 'undef root');
    is(in_dir($proj, sub { BpDispatchLog::log_dir('') }),    "$proj/.ccpraxis-local-data/.dispatch-log", 'empty root');
    is(BpDispatchLog::log_dir('/explicit'), '/explicit/.ccpraxis-local-data/.dispatch-log', 'an explicit root is kept');
};

subtest 'CLI start with no --root writes into the project it runs in' => sub {
    my ($base, $proj) = project();
    local $ENV{GIT_CEILING_DIRECTORIES} = $base;
    my $id = 'rootcheck-01-impl-' . $$ . int(rand(1e6));
    my $script_store = Cwd::abs_path("$SCRIPTS/../../..") . "/.ccpraxis-local-data/.dispatch-log/$id.json";
    my $out = in_dir($proj, sub {
        `"$^X" "$LOG_PL" start --id $id --worker-type bp-implementer --budget-seconds 60 2>&1`
    });
    is($? >> 8, 0, 'start exits 0') or diag($out);
    ok(-f "$proj/.ccpraxis-local-data/.dispatch-log/$id.json", 'record written under the project');
    ok(!-e $script_store, 'nothing written beside the script');

    my $id2 = "$id-empty";
    in_dir($proj, sub {
        `"$^X" "$LOG_PL" start --id $id2 --worker-type bp-implementer --budget-seconds 60 --root "" 2>&1`
    });
    ok(-f "$proj/.ccpraxis-local-data/.dispatch-log/$id2.json", '--root "" also lands in the project');
    unlink $script_store;   # belt and braces: never leave one behind if the assertion failed
};

done_testing();
