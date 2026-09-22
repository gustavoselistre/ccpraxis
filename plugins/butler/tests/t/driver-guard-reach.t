#!/usr/bin/env perl
# platform: any
# 07-guards-reach-the-driver — immutable oracle.
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/07-guards-reach-the-driver-spec.md
# (AC-1..AC-32, B1..B14, F1..F14). Written BLIND to any implementation of
# bp_driver_context: at authoring time lib.sh has no such function, guard-writes.sh
# and ledger-guard.sh call bp_hook_gate unconditionally, bp-drive-next.pl writes no
# current.json. Every AC below is expected to fail on MISSING BEHAVIOUR (the guard
# stays inert in a driver session — exit 0 everywhere — or the pointer file/predicate
# simply does not exist), never on a bug in this harness.
#
# THE DRIVER FIXTURE (§5.1, normative) is built by build_fixture() below. Nothing
# reads the real machine registry or the real .ccpraxis-local-data — every path is
# under a fresh File::Temp tempdir, and CCPRAXIS_DATA_DIR / CCPRAXIS_DRIVE_ACTIVE_DIR
# pin bp_find_data_dir / bp_drive_active_dir to it.
#
# %CLEAN_ENV strips every ambient BP_* and CCPRAXIS_DRIVER_GUARDS_OFF (git-mutation-
# guard-reach.t's E0 lesson: an "idle"/"clean" premise must be CONSTRUCTED, never
# assumed — this suite may itself be running inside a butler worker or a live drive).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $HOOKS   = "$Bin/../../hooks";
my $LIB     = "$HOOKS/lib.sh";
my $GW      = "$HOOKS/guard-writes.sh";
my $LG      = "$HOOKS/ledger-guard.sh";
my $GBW     = "$HOOKS/guard-blueprint-write.sh";
my $SCRIPTS = "$Bin/../../scripts";
my $DRIVENEXT = "$SCRIPTS/bp-drive-next.pl";

ok(-f $LIB, 'lib.sh is present') or BAIL_OUT('no lib.sh');
ok(-f $GW,  'guard-writes.sh is present') or BAIL_OUT('no guard-writes.sh');
ok(-f $LG,  'ledger-guard.sh is present') or BAIL_OUT('no ledger-guard.sh');
ok(-f $GBW, 'guard-blueprint-write.sh is present') or BAIL_OUT('no guard-blueprint-write.sh');
ok(-f $DRIVENEXT, 'bp-drive-next.pl is present') or BAIL_OUT('no bp-drive-next.pl');

my $J = JSON::PP->new->canonical;

# CRITICAL: on this host File::Temp's tempdir() resolves under /tmp/ by
# default (Git-for-Windows perl is a cygwin build; File::Spec->tmpdir() falls
# back to POSIX '/tmp' when $TMPDIR is unset). guard-writes.sh's always-allow
# prefix is "$BP_DIR"/* and /tmp/* — so EVERY fixture built under the default
# tempdir would be silently always-allowed regardless of any driver logic,
# which would make AC-1..AC-6/AC-8/AC-11/AC-12/AC-18-26/AC-32 pass or fail for
# the WRONG reason. Redirect File::Temp's base dir to a scratch dir under this
# test's own directory, outside /tmp/, before any tempdir() call.
my $FIXTURE_TMP_BASE = "$Bin/.driver-guard-reach-scratch";
make_path($FIXTURE_TMP_BASE);
$ENV{TMPDIR} = $FIXTURE_TMP_BASE;
END { eval { require File::Path; File::Path::remove_tree($FIXTURE_TMP_BASE) } if $FIXTURE_TMP_BASE }

# ===========================================================================
# Scaffolding
# ===========================================================================

sub write_file {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub read_json_file {
    my ($path) = @_;
    my $t = read_file($path);
    return undef unless defined $t;
    return eval { $J->decode($t) };
}

# The 5 required "## " sections ledger-guard.sh's V5 demands.
sub _sections {
    return "## Next action\nbody\n\n## Decisions & attempt log\nbody\n\n"
         . "## Pipeline\nbody\n\n## Outputs\nbody\n\n## Escalation (when status: blocked)\nbody\n";
}

# build_fixture(%opt) — the §5.1 hermetic driver fixture, with knobs for the F1-F14
# fault matrix and the AC-8/AC-32 variants. Returns a hashref of paths.
sub build_fixture {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = $o{blueprint} // 'demo-bp';
    my $pkg  = $o{package}   // 'pkg-a';

    make_path("$data/blueprints/$bp/packages") unless $o{no_bp_dir};
    make_path("$data/.drive-solo");
    write_file("$root/src/a.pl",    "1;\n");
    write_file("$root/docs/api.md", "# api\n");
    write_file("$root/t/oracle.t",  "1;\n");
    write_file("$root/other/x.txt", "x\n");

    unless ($o{no_blueprint_md} || $o{no_bp_dir}) {
        write_file("$data/blueprints/$bp/blueprint.md",
            "# $bp\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n"
          . "|-----|-------------|------------|-------|--------|\n"
          . "| $pkg | thing | - | sonnet | running |\n");
    }

    unless ($o{no_ledger}) {
        my $status = exists $o{status} ? $o{status} : 'running';
        my $ws     = exists $o{write_set} ? $o{write_set} : 'src/:docs/api.md';
        my $tp     = exists $o{test_paths} ? $o{test_paths} : 't/';
        my $fm = "---\n";
        $fm .= "package: $pkg\n";
        $fm .= "blueprint: $bp\n";
        $fm .= "status: $status\n" unless $o{no_status_key};
        $fm .= "write_set: $ws\n"  unless $o{no_write_set_key};
        $fm .= "test_paths: $tp\n" unless $o{no_test_paths_key};
        # A safely-PAST date, deliberately: bp-ledger.pl's shared last_updated_check()
        # (required by ledger-guard.sh's V2 validator, unrelated to and untouched by
        # this package) rejects any last_updated: more than 300s ahead of the real
        # clock, which would make AC-6/B9's "valid ledger content -> exit 0" case
        # structurally unreachable if this were in the future (ORACLE FIX, verified
        # 2026-09-22: main::last_updated_check rejects the original 2028 value on this
        # host; a past value doesn't, and old==new here so monotonicity can't fire).
        $fm .= "last_updated: 2025-01-01T00:00:00Z\n";
        $fm .= "---\n\n" . _sections();
        $fm = "not-frontmatter-at-all\n" . $fm if $o{bad_first_line};
        write_file("$data/blueprints/$bp/packages/$pkg.md", $fm) unless $o{no_ledger_file};
    }

    unless ($o{no_current_json}) {
        if ($o{invalid_current_json}) {
            write_file("$data/.drive-solo/current.json", "{{{not json");
        } else {
            my $cj_bp  = exists $o{current_json_blueprint} ? $o{current_json_blueprint} : $bp;
            my $cj_pkg = exists $o{current_json_package}   ? $o{current_json_package}   : $pkg;
            write_file("$data/.drive-solo/current.json",
                $J->encode({ blueprint => $cj_bp, package => $cj_pkg, recorded_at => time }));
        }
    }

    if (defined $o{marker}) {
        my $mp = "$data/.drive-solo/.active-worker";
        write_file($mp, $o{marker});
        if (defined $o{marker_age_min}) {
            my $t = time - $o{marker_age_min} * 60;
            utime($t, $t, $mp);
        }
    }

    return {
        root => $root, data => $data, bp => $bp, pkg => $pkg,
        bpdir    => "$data/blueprints/$bp",
        ledger   => "$data/blueprints/$bp/packages/$pkg.md",
        src_a    => "$root/src/a.pl",
        docs_api => "$root/docs/api.md",
        t_oracle => "$root/t/oracle.t",
        other_x  => "$root/other/x.txt",
        current_json => "$data/.drive-solo/current.json",
        hatch    => "$data/.drive-solo/.driver-guards-off",
    };
}

my $ACTIVE_N = 0;
sub mk_active {
    my $dir = tempdir(CLEANUP => 1);
    write_file("$dir/sess-" . (++$ACTIVE_N), "1\n");
    return $dir;
}
sub mk_empty_active { return tempdir(CLEANUP => 1); }

# Base clean env: strip every ambient BP_* and the hatch env var. This suite may
# itself run inside a coordinator or a live drive-solo session.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
                grep { !/^BP_/ && $_ ne 'CCPRAXIS_DRIVER_GUARDS_OFF' } keys %ENV;

sub driver_env {
    my ($fx, $active, %extra) = @_;
    return (
        %CLEAN_ENV,
        CCPRAXIS_DATA_DIR        => $fx->{data},
        CCPRAXIS_DRIVE_ACTIVE_DIR=> $active,
        %extra,
    );
}

sub worker_env {
    my ($fx, %extra) = @_;
    return (
        %CLEAN_ENV,
        BP_LEDGER       => $fx->{ledger},
        BP_DIR          => $fx->{bpdir},
        BP_PROJECT_ROOT => $fx->{root},
        BP_PACKAGE      => $fx->{pkg},
        BP_WRITE_SET    => 'src/:docs/api.md',
        BP_TEST_PATHS   => 't/',
        CCPRAXIS_DRIVE_ACTIVE_DIR => mk_empty_active(),
        %extra,
    );
}

sub payload_json {
    my ($abs, $cwd, %extra) = @_;
    return $J->encode({
        tool_name  => ($extra{tool} // 'Write'),
        tool_input => { file_path => $abs, content => ($extra{content} // 'x') },
        cwd        => $cwd,
    });
}

my $PROBE_DIR = tempdir(CLEANUP => 1);
my $PROBE_N = 0;

# run_hook HOOK PAYLOAD %ENV -> (rc, combined stdout+stderr)
sub run_hook {
    my ($hook, $payload, %env) = @_;
    my $tmp = "$PROBE_DIR/probe." . (++$PROBE_N);
    local %ENV = %env;
    open my $fh, '|-', "bash \"$hook\" > \"$tmp\" 2>&1" or die "spawn: $!";
    print $fh $payload;
    close $fh;
    my $rc = $? >> 8;
    my $out = -f $tmp ? read_file($tmp) : '';
    unlink $tmp;
    return ($rc, defined $out ? $out : '');
}

# run_bash SNIPPET %ENV -> (rc, stdout)
sub run_bash {
    my ($snippet, %env) = @_;
    my $tmp = "$PROBE_DIR/snip." . (++$PROBE_N) . '.sh';
    write_file($tmp, $snippet);
    my $out_f = "$PROBE_DIR/snip-out." . $PROBE_N;
    local %ENV = %env;
    system("bash \"$tmp\" > \"$out_f\" 2>&1");
    my $rc = $? >> 8;
    my $out = -f $out_f ? read_file($out_f) : '';
    unlink $tmp, $out_f;
    return ($rc, defined $out ? $out : '');
}

sub read_src { return read_file(shift) // '' }

# ===========================================================================
# AC-7 / AC-8 / AC-10 / AC-31 (+ B14) — bp_driver_context, called directly.
# ===========================================================================

{
    my $fx = build_fixture();
    my $active = mk_active();
    my $snippet = <<'BASH';
set -u
source "$LIB"
bp_driver_context "$CWD"
rc=$?
printf 'RC=%s\n' "$rc"
printf 'SESSION=%s\n' "${BP_DRIVER_SESSION:-}"
printf 'DATA=%s\n' "${BP_DATA_DIR:-}"
printf 'PROJROOT=%s\n' "${BP_PROJECT_ROOT:-}"
printf 'BP=%s\n' "${BP_BLUEPRINT:-}"
printf 'DIR=%s\n' "${BP_DIR:-}"
printf 'PKG=%s\n' "${BP_PACKAGE:-}"
printf 'WS=[%s]\n' "${BP_WRITE_SET:-}"
printf 'TP=[%s]\n' "${BP_TEST_PATHS:-}"
printf 'ROLE=[%s]\n' "${BP_DRIVER_ROLE:-}"
printf 'LEDGERSET=%s\n' "${BP_LEDGER:+set}"
printf 'CHILD_BP_DIR=%s\n' "$(bash -c 'printf %s "${BP_DIR:-unset}"')"
printf 'CHILD_WS=%s\n' "$(bash -c 'printf %s "${BP_WRITE_SET:-unset}"')"
printf 'CHILD_TP=%s\n' "$(bash -c 'printf %s "${BP_TEST_PATHS:-unset}"')"
printf 'CHILD_LEDGER=%s\n' "$(bash -c 'printf %s "${BP_LEDGER:-unset}"')"
BASH
    my ($rc, $out) = run_bash($snippet, driver_env($fx, $active, LIB => $LIB, CWD => $fx->{root}));
    my %v;
    for my $ln (split /\n/, $out) {
        if ($ln =~ /^([A-Z_]+)=(.*)$/) { $v{$1} = $2 }
    }
    is($v{RC}, '0',
        'AC-7: bp_driver_context returns rc 0 for a healthy driver fixture')
        or diag("full output:\n$out");
    is($v{DATA} // '', $fx->{data}, 'AC-7: BP_DATA_DIR set to the fixture data dir');
    is($v{PROJROOT} // '', $fx->{root}, 'AC-7: BP_PROJECT_ROOT set to the fixture root');
    is($v{BP} // '', $fx->{bp}, 'AC-7: BP_BLUEPRINT set to the current blueprint');
    is($v{DIR} // '', $fx->{bpdir}, 'AC-7: BP_DIR set to <data>/blueprints/<bp>');
    is($v{PKG} // '', $fx->{pkg}, 'AC-7: BP_PACKAGE set to the current package');
    is($v{WS} // '', '[src/:docs/api.md]',
        'AC-7: BP_WRITE_SET is byte-identical to the ledger frontmatter value');
    is($v{TP} // '', '[t/]',
        'AC-7: BP_TEST_PATHS is byte-identical to the ledger frontmatter value');
    isnt($v{WS} // '', '[]', 'AC-7: BP_WRITE_SET is non-empty');

    is($v{LEDGERSET} // '', '', 'AC-31/B14: BP_LEDGER is still unset after a successful call');
    is($v{CHILD_BP_DIR} // '', 'unset', 'AC-31/B14: a child bash sees BP_DIR unset (never exported)');
    is($v{CHILD_WS} // '', 'unset', 'AC-31/B14: a child bash sees BP_WRITE_SET unset');
    is($v{CHILD_TP} // '', 'unset', 'AC-31/B14: a child bash sees BP_TEST_PATHS unset');
    is($v{CHILD_LEDGER} // '', 'unset', 'AC-31/B14: a child bash sees BP_LEDGER unset');
}

{
    # AC-8: empty write_set -> rc 1, no partial globals; and guard-writes.sh
    # exits 0 for a write that the populated fixture denies.
    my $fx = build_fixture(write_set => '');
    my $active = mk_active();
    my $snippet = <<'BASH';
set -u
source "$LIB"
bp_driver_context "$CWD"
printf 'RC=%s\n' "$?"
printf 'WS=[%s]\n' "${BP_WRITE_SET:-}"
BASH
    my ($rc, $out) = run_bash($snippet, driver_env($fx, $active, LIB => $LIB, CWD => $fx->{root}));
    like($out, qr/RC=1/, 'AC-8: empty write_set -> bp_driver_context rc 1')
        or diag($out);

    my ($grc) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}),
                          driver_env($fx, $active));
    is($grc, 0,
        'AC-8: guard-writes.sh exits 0 for a write the populated fixture would deny '
      . '(no deny-everything on an empty write_set)');
}

{
    # AC-10: bp_hook_gate's body is exactly the three checks, and mentions
    # neither bp_drive_any_active nor bp_driver_context nor any registry path.
    my $src = read_src($LIB);
    if ($src =~ /bp_hook_gate\s*\(\)\s*\{(.*?)\n\}/s) {
        my $body = $1;
        unlike($body, qr/bp_drive_any_active/, 'AC-10: bp_hook_gate body mentions no bp_drive_any_active');
        unlike($body, qr/bp_driver_context/,    'AC-10: bp_hook_gate body mentions no bp_driver_context');
        unlike($body, qr/drive-solo|registry/,  'AC-10: bp_hook_gate body mentions no registry path');
        my @checks = ($body =~ /\[\s*-n\s*"\$\{(BP_LEDGER|BP_DIR|BP_PROJECT_ROOT):-\}"\s*\]/g);
        is(scalar(@checks), 3, 'AC-10: bp_hook_gate body still consists of exactly the three checks')
            or diag("body:\n$body");
    } else {
        fail('AC-10: could not locate bp_hook_gate() { ... } in lib.sh');
    }

    my ($rc, $out) = run_bash(
        'set -u; source "$LIB"; bp_hook_gate; printf "AFTER\n"',
        (%CLEAN_ENV, LIB => $LIB));
    is($rc, 0, 'AC-10: with BP_LEDGER/BP_DIR/BP_PROJECT_ROOT all unset, sourcing+calling exits 0');
    unlike($out, qr/AFTER/, 'AC-10: ...and the call itself exits the script (never returns)');
}

# ===========================================================================
# AC-1..AC-6 (B1..B5, B9) — guard-writes.sh / ledger-guard.sh, driver session.
# ===========================================================================

{
    my $fx = build_fixture();
    my $active = mk_active();

    # AC-1 / B1
    my ($rc1, $out1) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
                                 driver_env($fx, $active));
    is($rc1, 2, 'AC-1/B1: driver session, Write to a test_paths path -> exit 2');
    like($out1, qr/BLOCKED/, 'AC-1/B1: stderr matches BLOCKED');
    like($out1, qr/\Q$fx->{pkg}\E/, 'AC-1/B1: stderr names the package');
    like($out1, qr/oracle/i, 'AC-1/B1: stderr contains "oracle"');
    like($out1, qr/t\//, 'AC-1/B1: stderr contains the matched test_paths pattern');

    # AC-2 / B2
    my ($rc2, $out2) = run_hook($GW, payload_json($fx->{src_a}, $fx->{root}),
                                 driver_env($fx, $active));
    is($rc2, 0, 'AC-2/B2: driver session, Write to a write_set path -> exit 0');
    is($out2, '', 'AC-2/B2: ...and stderr is empty');

    # AC-3 / B3
    my ($rc3, $out3) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}),
                                 driver_env($fx, $active));
    is($rc3, 2, 'AC-3/B3: driver session, Write to neither set -> exit 2');
    like($out3, qr/outside this package's write set/, 'AC-3/B3: stderr names the classic message');
    like($out3, qr/\Q$fx->{pkg}\E/, 'AC-3/B3: stderr contains the package name');

    # AC-4 / B4
    my ($rc4a) = run_hook($GW,
        payload_json("$fx->{bpdir}/reports/x.md", $fx->{root}), driver_env($fx, $active));
    is($rc4a, 0, 'AC-4/B4: driver session, Write under <data>/ -> exit 0');
    my ($rc4b) = run_hook($GW,
        payload_json('/tmp/driver-guard-reach-probe.txt', $fx->{root}), driver_env($fx, $active));
    is($rc4b, 0, 'AC-4/B4: driver session, Write under /tmp/ -> exit 0');

    # AC-5 / B5
    my $outside = dirname($fx->{root}) . "/driver-guard-reach-outside-$$/x.txt";
    if ($outside =~ m{^/tmp/}) { $outside = "/var/driver-guard-reach-outside-$$/x.txt" }
    my ($rc5, $out5) = run_hook($GW, payload_json($outside, $fx->{root}), driver_env($fx, $active));
    is($rc5, 2, 'AC-5/B5: driver session, Write outside the project root -> exit 2');
    like($out5, qr/outside the project root/, 'AC-5/B5: stderr carries the existing message');

    # AC-6 / B9 (ledger-guard.sh)
    my $good = read_file($fx->{ledger});
    my ($rc6a) = run_hook($LG, payload_json($fx->{ledger}, $fx->{root}, content => $good),
                           driver_env($fx, $active));
    is($rc6a, 0, 'AC-6/B9: driver session, ledger-guard.sh, valid ledger content -> exit 0');

    my ($rc6b, $out6b) = run_hook($LG,
        payload_json($fx->{ledger}, $fx->{root}, content => "no frontmatter here at all\n"),
        driver_env($fx, $active));
    is($rc6b, 2, 'AC-6/B9: driver session, ledger-guard.sh, corrupt content -> exit 2');
    like($out6b, qr/LEDGER-GUARD: BLOCKED/, 'AC-6/B9: stderr matches LEDGER-GUARD: BLOCKED');
}

# ===========================================================================
# AC-9 / B8 — guard-bash.sh, driver session: git commit still allowed.
# ===========================================================================
{
    my $GBASH = "$HOOKS/guard-bash.sh";
    SKIP: {
        skip 'guard-bash.sh absent', 1 unless -f $GBASH;
        my $fx = build_fixture();
        my $active = mk_active();
        my $payload = $J->encode({
            tool_name => 'Bash', tool_input => { command => 'git commit -m "x"' },
            cwd => $fx->{root},
        });
        my ($rc) = run_hook($GBASH, $payload, driver_env($fx, $active));
        is($rc, 0, 'AC-9/B8: driver session, guard-bash.sh, git commit -> exit 0');
    }
}

# ===========================================================================
# AC-11 / B7 — worker-session regression pin (registry pointed at an EMPTY dir).
# ===========================================================================
{
    my $fx = build_fixture();

    # In-set write -> 0
    my ($rc1) = run_hook($GW, payload_json($fx->{src_a}, $fx->{root}), worker_env($fx));
    is($rc1, 0, 'AC-11/B7: worker session, in-set write -> exit 0 (unchanged)');

    # Out-of-set write -> 2
    my ($rc2) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}), worker_env($fx));
    is($rc2, 2, 'AC-11/B7: worker session, out-of-set write -> exit 2 (unchanged)');

    # BP_TEST_PATHS write with a bp-implementer coordinator marker -> 2
    write_file("$fx->{bpdir}/runs/$fx->{pkg}.active-worker", 'bp-implementer');
    my ($rc3) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}), worker_env($fx));
    is($rc3, 2, 'AC-11/B7: worker session, bp-implementer coordinator marker, test write -> exit 2');
}

# ===========================================================================
# AC-12 / B11 — fault matrix F1..F14 against guard-writes.sh.
# The healthy fixture denies a Write to t_oracle (test_paths); every faulted
# variant below must instead ALLOW it (exit 0, empty stderr).
# ===========================================================================
{
    my $active = mk_active();

    my %faults = (
        F1  => sub { build_fixture(no_current_json => 1) },
        F2  => sub { build_fixture(invalid_current_json => 1) },
        F3  => sub { build_fixture(current_json_blueprint => 'ghost-bp-no-dir') },
        F4  => sub { build_fixture(current_json_package => 'ghost-pkg-no-ledger') },
        F5  => sub { build_fixture(bad_first_line => 1) },
        F6  => sub { build_fixture(write_set => '') },
        F7  => sub { build_fixture(status => 'done') },
        F8  => sub { build_fixture(no_status_key => 1) },
        F11 => sub { build_fixture(current_json_blueprint => '../../etc') },
        'F11b' => sub { build_fixture(current_json_package => 'a/b') },
    );

    for my $name (sort keys %faults) {
        my $fx = $faults{$name}->();
        my ($rc, $out) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
                                   driver_env($fx, $active));
        is($rc, 0, "AC-12/B11 $name: guard-writes.sh exits 0 on a write the healthy fixture denies");
        is($out, '', "AC-12/B11 $name: ...and prints nothing on stderr");
    }

    # F9: the drive registry directory is empty (no marker at all).
    {
        my $fx = build_fixture();
        my ($rc, $out) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
                                   driver_env($fx, mk_empty_active()));
        is($rc, 0, 'AC-12/B11 F9: empty drive registry -> exit 0');
        is($out, '', 'AC-12/B11 F9: ...and prints nothing');
    }

    # F12: the hook payload is empty / not JSON.
    {
        my $fx = build_fixture();
        for my $bad ('', 'not-json-at-all') {
            my ($rc, $out) = run_hook($GW, $bad, driver_env($fx, $active));
            is($rc, 0, 'AC-12/B11 F12: empty/non-JSON payload -> exit 0');
            is($out, '', 'AC-12/B11 F12: ...and prints nothing');
        }
    }

    # F13: no data dir can be found for the payload's cwd (no CCPRAXIS_DATA_DIR
    # override, and a cwd with no .ccpraxis-local-data ancestor anywhere).
    {
        my $fx = build_fixture();
        my $no_ancestor = tempdir(CLEANUP => 1);
        my %env = driver_env($fx, $active);
        delete $env{CCPRAXIS_DATA_DIR};
        # ORACLE FIX (2026-09-22): same run_hook(%env-not-\%env) shape as AC-23 below
        # -- was passing vacuously here only because F13's expected rc (0) doesn't
        # depend on %ENV surviving intact.
        my ($rc, $out) = run_hook($GW,
            payload_json("$no_ancestor/t/whatever.t", $no_ancestor), %env);
        is($rc, 0, 'AC-12/B11 F13: unresolvable data dir for the payload cwd -> exit 0');
        is($out, '', 'AC-12/B11 F13: ...and prints nothing');
    }

    # F14: a drive is active on the machine but THIS project has no
    # .drive-solo/current.json (another project's run). Mechanically identical
    # to F1 under this hermetic fixture (the registry is machine-level and the
    # pointer is project-level, so "no pointer here" is the whole signal) —
    # cross-referenced rather than reproduced as a byte-for-byte separate case.
    {
        my $fx = build_fixture(no_current_json => 1);
        my ($rc, $out) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
                                   driver_env($fx, $active));
        is($rc, 0, 'AC-12/B11 F14: active machine-wide drive, no pointer in THIS project -> exit 0');
        is($out, '', 'AC-12/B11 F14: ...and prints nothing');
    }
}

# ===========================================================================
# AC-13 — fault matrix subset F1, F2, F5, F9 against ledger-guard.sh with a
# CORRUPT ledger payload: exit 0 despite the corruption (fail-open activation).
# Non-vacuity: the same payload against the healthy fixture exits 2 (AC-6).
# ===========================================================================
{
    my $active = mk_active();
    my $corrupt_content = "no frontmatter here at all\n";

    my %subset = (
        F1 => sub { build_fixture(no_current_json => 1) },
        F2 => sub { build_fixture(invalid_current_json => 1) },
        F5 => sub { build_fixture(bad_first_line => 1) },
    );
    for my $name (sort keys %subset) {
        my $fx = $subset{$name}->();
        my ($rc, $out) = run_hook($LG,
            payload_json($fx->{ledger}, $fx->{root}, content => $corrupt_content),
            driver_env($fx, $active));
        is($rc, 0, "AC-13 $name: ledger-guard.sh, activation faulted, corrupt content -> exit 0 (fail open)");
    }
    {
        my $fx = build_fixture();
        my ($rc) = run_hook($LG,
            payload_json($fx->{ledger}, $fx->{root}, content => $corrupt_content),
            driver_env($fx, mk_empty_active()));
        is($rc, 0, 'AC-13 F9: empty drive registry, corrupt content -> exit 0');
    }
}

# ===========================================================================
# AC-14 — bp_driver_context defined exactly once, in lib.sh.
# ===========================================================================
{
    my @candidates = (glob("$HOOKS/*.sh"), glob("$SCRIPTS/*.pl"));
    my @defs;
    for my $f (@candidates) {
        my $src = read_src($f);
        my $n = () = ($src =~ /^\s*bp_driver_context\s*\(\)\s*\{/mg);
        push @defs, ($f) x $n if $n;
    }
    is(scalar(@defs), 1, 'AC-14: bp_driver_context is defined exactly once across hooks/** + scripts/**')
        or diag('definitions found in: ' . join(', ', @defs));
    is(($defs[0] // ''), $LIB, 'AC-14: ...and that definition lives in lib.sh')
        if @defs == 1;
}

# ===========================================================================
# AC-15 — guard-writes.sh / ledger-guard.sh call bp_driver_context exactly
# once each, and never re-derive liveness/context (no bp_drive_active_dir,
# .drive-solo-active, current.json, or inline frontmatter parse). The cheap
# bp_drive_any_active pre-check is permitted and expected.
# ===========================================================================
for my $pair ([guard_writes => $GW], [ledger_guard => $LG]) {
    my ($label, $file) = @$pair;
    my $src = read_src($file);
    my $n = () = ($src =~ /\bbp_driver_context\b/g);
    is($n, 1, "AC-15 $label: exactly one bp_driver_context call");
    unlike($src, qr/bp_drive_active_dir/, "AC-15 $label: no bp_drive_active_dir re-derivation");
    unlike($src, qr/\.drive-solo-active/, "AC-15 $label: no re-derivation of the drive-active registry path");
    unlike($src, qr/current\.json/, "AC-15 $label: no re-derivation of current.json's name");
    my $fm_re_count = () = ($src =~ /\\A---\\s\*\\n/g);
    if ($label eq 'ledger_guard') {
        # ORACLE FIX (2026-09-22): ledger-guard.sh's PRE-EXISTING, spec-frozen V2
        # content-validator (git HEAD, untouched by this package -- spec §2.4:
        # "Everything from LEDGER_PL= onward is unchanged") legitimately contains
        # this literal pattern text for an unrelated purpose (validating a
        # PROSPECTIVE WRITE's frontmatter, not bp_driver_context's own read). A
        # bare unlike() here can never pass for this file under a spec-compliant
        # implementation. Assert the count hasn't grown past the two known,
        # pre-existing occurrences instead of asserting zero.
        is($fm_re_count, 2,
            "AC-15 $label: no NEW inline frontmatter regex beyond the two known pre-existing V2-validator occurrences (the regex itself and its own denial-message text)");
    } else {
        is($fm_re_count, 0, "AC-15 $label: no inline frontmatter regex (ledger_fm's own pattern)");
    }
    like($src, qr/\bbp_drive_any_active\b/, "AC-15 $label: the cheap pre-check IS present");
}

# ===========================================================================
# AC-16 / AC-17 — THE CRITERION-7 TABLE, as data, asserted against source.
# ===========================================================================
{
    # [ hook_file, expect_hook_gate(0/1), expect_driver_context(0/1), expect_drive_any_active(0/1) ]
    my @TABLE = (
        ['guard-writes.sh',               1, 1, 1],
        ['ledger-guard.sh',                1, 1, 1],
        ['guard-blueprint-write.sh',       0, 0, 0],
        ['guard-bash.sh',                  1, 0, 0],
        ['gate-stop.sh',                   1, 0, 0],
        ['gate-shutdown.sh',               1, 0, 0],
        ['guard-validation-interlock.sh',  0, 0, 0],
        ['guard-subagent-stall.sh',        0, 0, 1],
        ['gate-drive-loop.sh',             0, 0, 1],
        # JUDGMENT CALL (documented in the report): the spec's §2.1 Predicate
        # column reads "none" for this row, meaning no bp_hook_gate-equivalent
        # ACTIVATION gate — but the file already calls bp_drive_any_active at
        # a line unrelated to this package (computing $_rl for
        # bp_outstanding_work, pre-existing, out of scope here). AC-16 grep's
        # for literal presence, so the expectation is set to match the real,
        # unrelated call rather than false-flag an untouched file.
        ['gate-continuity.sh',             0, 0, 1],
        ['guard-git-mutations.sh',         0, 0, 1],   # reference row; not in write set
    );

    sub _call_count {
        my ($src, $fn) = @_;
        my $n = 0;
        for my $ln (split /\n/, $src) {
            next if $ln =~ /^\s*#/;          # comment-only line
            $n++ if $ln =~ /^\s*\Q$fn\E\b/;
        }
        return $n;
    }

    for my $row (@TABLE) {
        my ($name, $eg, $ec, $ea) = @$row;
        my $path = "$HOOKS/$name";
        ok(-f $path, "AC-16: $name exists on disk (table row present)")
            or next;
        my $src = read_src($path);
        my $g = _call_count($src, 'bp_hook_gate') > 0 ? 1 : 0;
        my $c = _call_count($src, 'bp_driver_context') > 0 ? 1 : 0;
        my $a = _call_count($src, 'bp_drive_any_active') > 0 ? 1 : 0;
        is($g, $eg, "AC-16: $name calls bp_hook_gate iff table says so (got $g want $eg)");
        is($c, $ec, "AC-16: $name calls bp_driver_context iff table says so (got $c want $ec)");
        is($a, $ea, "AC-16: $name calls bp_drive_any_active iff table says so (got $a want $ea)");
    }
}

{
    # AC-17: non-vacuity — the detector fires on a control comparison.
    my $gated_src   = read_src("$HOOKS/guard-bash.sh");
    my $ungated_src = read_src("$HOOKS/guard-blueprint-write.sh");
    cmp_ok(_call_count($gated_src, 'bp_hook_gate'), '>', 0,
        'AC-17: control — a known-gated hook (guard-bash.sh) IS detected as gated');
    is(_call_count($ungated_src, 'bp_hook_gate'), 0,
        'AC-17: control — a known-ungated hook (guard-blueprint-write.sh) is detected as NOT gated');
}

# ===========================================================================
# AC-18 / AC-19 / AC-20 — guard-blueprint-write.sh: universal, no code change.
# ===========================================================================
{
    my $fx = build_fixture();

    # AC-18: every BP_* unset, no drive marker, no current.json.
    my %env_bare = (%CLEAN_ENV, CCPRAXIS_DRIVE_ACTIVE_DIR => mk_empty_active());
    # ORACLE FIX (2026-09-22): same run_hook(%env-not-\%env) shape as AC-23/F13 --
    # was passing vacuously here only because guard-blueprint-write.sh denies
    # unconditionally regardless of %ENV.
    my ($rc18, $out18) = run_hook($GBW,
        payload_json("$fx->{root}/anything/blueprint.md", $fx->{root}), %env_bare);
    is($rc18, 2, 'AC-18: guard-blueprint-write.sh, every BP_* unset, no marker -> exit 2');
    like($out18, qr/BLUEPRINT-GUARD: BLOCKED/, 'AC-18: stderr matches BLUEPRINT-GUARD: BLOCKED');

    # AC-19: same denial with the driver fixture active.
    my $active = mk_active();
    my ($rc19, $out19) = run_hook($GBW,
        payload_json("$fx->{root}/anything/blueprint.md", $fx->{root}), driver_env($fx, $active));
    is($rc19, 2, 'AC-19: guard-blueprint-write.sh, driver fixture active -> still exit 2');
    like($out19, qr/BLUEPRINT-GUARD: BLOCKED/, 'AC-19: stderr matches BLUEPRINT-GUARD: BLOCKED');

    # AC-20: no bp_hook_gate call, no bp_driver_context call — it is universal.
    my $src = read_src($GBW);
    is(_call_count($src, 'bp_hook_gate'), 0, 'AC-20: guard-blueprint-write.sh calls no bp_hook_gate');
    is(_call_count($src, 'bp_driver_context'), 0, 'AC-20: guard-blueprint-write.sh calls no bp_driver_context');
}

# ===========================================================================
# AC-21..AC-26 (B12) — the escape hatch.
# ===========================================================================
{
    my $fx = build_fixture();
    my $active = mk_active();

    # Direct-predicate check (non-vacuous companion to the integration checks
    # below, which would otherwise pass "for free" while the guard stays inert
    # pre-implementation — see report for the discussion).
    sub _ctx_rc {
        my (%env) = @_;
        my (undef, $out) = run_bash('set -u; source "$LIB"; bp_driver_context "$CWD"; printf "RC=%s" "$?"',
                                     %env);
        return ($out =~ /RC=(\d+)/) ? $1 : undef;
    }

    # AC-21: file hatch, fresh.
    write_file($fx->{hatch}, '');
    is(_ctx_rc(driver_env($fx, $active, LIB => $LIB, CWD => $fx->{root})), 1,
        'AC-21: bp_driver_context returns rc 1 with a fresh .driver-guards-off file present');
    my ($rc1) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}), driver_env($fx, $active));
    is($rc1, 0, 'AC-21: AC-1 denial becomes exit 0 with the file hatch present');
    my ($rc3) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}), driver_env($fx, $active));
    is($rc3, 0, 'AC-21: AC-3 denial becomes exit 0 with the file hatch present');
    my $good = read_file($fx->{ledger});
    my ($rc6) = run_hook($LG, payload_json($fx->{ledger}, $fx->{root},
                          content => "no frontmatter\n"), driver_env($fx, $active));
    is($rc6, 0, 'AC-21: AC-6 corrupt-ledger denial becomes exit 0 with the file hatch present');
    unlink $fx->{hatch};

    # AC-22: env hatch.
    is(_ctx_rc(driver_env($fx, $active, LIB => $LIB, CWD => $fx->{root},
                           CCPRAXIS_DRIVER_GUARDS_OFF => '1')), 1,
        'AC-22: bp_driver_context returns rc 1 with CCPRAXIS_DRIVER_GUARDS_OFF=1');
    my ($rc1e) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
        driver_env($fx, $active, CCPRAXIS_DRIVER_GUARDS_OFF => '1'));
    is($rc1e, 0, 'AC-22: AC-1 denial becomes exit 0 with CCPRAXIS_DRIVER_GUARDS_OFF=1');
    my ($rc3e) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}),
        driver_env($fx, $active, CCPRAXIS_DRIVER_GUARDS_OFF => '1'));
    is($rc3e, 0, 'AC-22: AC-3 denial becomes exit 0 with CCPRAXIS_DRIVER_GUARDS_OFF=1');

    # AC-23: hatch file older than TTL -> enforcement resumes, file removed.
    write_file($fx->{hatch}, '');
    my $t = time - 2 * 60;   # 2 minutes ago
    utime($t, $t, $fx->{hatch});
    my %ttl_env = driver_env($fx, $active, CCPRAXIS_DRIVER_GUARDS_OFF_TTL_MIN => '1');
    # ORACLE FIX (2026-09-22): run_hook's signature is ($hook, $payload, %env) -- a
    # flat hash, not a ref. Passing \%ttl_env made %env an odd-length list
    # assignment (Perl warns "Reference found where even-sized list expected"),
    # corrupting the child %ENV so bp_drive_any_active failed before the TTL logic
    # under test ever ran. Verified: replaying with the flattened hash returns the
    # expected rc=2.
    my ($rc1t) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}), %ttl_env);
    is($rc1t, 2, 'AC-23: AC-1 denies again once the hatch file is past TTL');
    my ($rc3t) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}), %ttl_env);
    is($rc3t, 2, 'AC-23: AC-3 denies again once the hatch file is past TTL');
    ok(!-e $fx->{hatch}, 'AC-23: the stale hatch file is gone afterwards');

    # AC-24: worker session + hatch file + hatch env -> still denies. The hatch
    # only disables the NEW predicate, never bp_hook_gate.
    write_file($fx->{hatch}, '');
    my ($rc_w) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}),
        worker_env($fx, CCPRAXIS_DRIVER_GUARDS_OFF => '1'));
    is($rc_w, 2, 'AC-24: worker session, hatch file + hatch env present, out-of-set write still denied');

    # AC-25: hatch present -> guard-blueprint-write.sh still denies.
    my ($rc_bw) = run_hook($GBW, payload_json("$fx->{root}/x/blueprint.md", $fx->{root}),
                            driver_env($fx, $active));
    is($rc_bw, 2, 'AC-25: hatch present, guard-blueprint-write.sh still denies a blueprint.md write');
    unlink $fx->{hatch};

    # AC-26: both driver-path refusal messages advertise the hatch.
    my ($rc1m, $out1m) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}), driver_env($fx, $active));
    like($out1m, qr/\.driver-guards-off/, 'AC-26: AC-1 refusal mentions .driver-guards-off');
    like($out1m, qr/CCPRAXIS_DRIVER_GUARDS_OFF/, 'AC-26: AC-1 refusal mentions CCPRAXIS_DRIVER_GUARDS_OFF');
    my ($rc3m, $out3m) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}), driver_env($fx, $active));
    like($out3m, qr/\.driver-guards-off/, 'AC-26: AC-3 refusal mentions .driver-guards-off');
    like($out3m, qr/CCPRAXIS_DRIVER_GUARDS_OFF/, 'AC-26: AC-3 refusal mentions CCPRAXIS_DRIVER_GUARDS_OFF');
}

# ===========================================================================
# AC-32 (B6) — the solo active-worker role, honoured by the driver path.
# ===========================================================================
{
    my $active = mk_active();

    # bp-test-writer: test write allowed, non-test write_set write denied.
    my $fx_tw = build_fixture(marker => 'bp-test-writer');
    my ($rc_t1) = run_hook($GW, payload_json($fx_tw->{t_oracle}, $fx_tw->{root}), driver_env($fx_tw, $active));
    is($rc_t1, 0, 'AC-32: solo marker bp-test-writer, test_paths write -> exit 0');
    my ($rc_t2) = run_hook($GW, payload_json($fx_tw->{src_a}, $fx_tw->{root}), driver_env($fx_tw, $active));
    is($rc_t2, 2, 'AC-32: solo marker bp-test-writer, non-test write_set write -> exit 2');

    # bp-implementer: mirror image.
    my $fx_im = build_fixture(marker => 'bp-implementer');
    my ($rc_i1) = run_hook($GW, payload_json($fx_im->{t_oracle}, $fx_im->{root}), driver_env($fx_im, $active));
    is($rc_i1, 2, 'AC-32: solo marker bp-implementer, test_paths write -> exit 2');
    my ($rc_i2) = run_hook($GW, payload_json($fx_im->{src_a}, $fx_im->{root}), driver_env($fx_im, $active));
    is($rc_i2, 0, 'AC-32: solo marker bp-implementer, write_set write -> exit 0');

    # Marker aged past CCPRAXIS_SOLO_WORKER_STALE_MIN -> treated as absent; driver rules apply.
    my $fx_stale = build_fixture(marker => 'bp-implementer', marker_age_min => 200);
    my ($rc_s1) = run_hook($GW, payload_json($fx_stale->{t_oracle}, $fx_stale->{root}),
                            driver_env($fx_stale, $active));
    is($rc_s1, 2, 'AC-32: marker aged past default 180min stale threshold -> driver rules (AC-1: exit 2)');
    my ($rc_s2) = run_hook($GW, payload_json($fx_stale->{src_a}, $fx_stale->{root}),
                            driver_env($fx_stale, $active));
    is($rc_s2, 0, 'AC-32: marker aged past default stale threshold -> driver rules (AC-2: exit 0)');
}

# ===========================================================================
# AC-27..AC-30 — bp-drive-next.pl's current.json pointer.
# ===========================================================================

my $LOADED = do { local $@; eval { require $DRIVENEXT }; !$@ };
diag("bp-drive-next.pl require failed: $@") unless $LOADED;

sub make_bp_dir {
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        my $deps = (ref $p->{deps} eq 'ARRAY' && @{$p->{deps}}) ? join(', ', @{$p->{deps}}) : '-';
        $md .= "| $p->{key} | thing | $deps | sonnet | $p->{status} |\n";
    }
    write_file("$bp/blueprint.md", $md);
    for my $p (@$pkgs) {
        my $ws = $p->{write_set} // "blueprints/$name/$p->{key}/";
        write_file("$bp/packages/$p->{key}.md",
            "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
          . "model: sonnet\nmax_turns: 80\nwrite_set: $ws\ntest_paths: $ws\n"
          . "last_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n");
    }
    return $bp;
}

sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = tempfile('t07-outXXXXXX', DIR => $PROBE_DIR); close $ofh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open STDOUT, '>:raw', $opath or die "reopen STDOUT: $!";
    my $rc = eval { BpDrive::run($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    my $out = read_file($opath); unlink $opath;
    die $err if $err;
    return ($rc, defined $out ? $out : '');
}

SKIP: {
    skip 'bp-drive-next.pl did not load', 20 unless $LOADED;

    my $NOW = 1_830_297_600;

    # AC-27
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data, 'bp-a', [{ key => 'p1', status => 'pending', write_set => 'a/p1/' }]);
        # ORACLE FIX (2026-09-22): _cmd_next's B2 check is unconditional -- with no
        # order.json on disk, 'next' can only ever answer need-order (see
        # drive-next.t AC-2..AC-5, which all write order.json first for exactly this
        # reason). Without this, run-package/current.json were unreachable here.
        make_path("$data/.drive-solo");
        write_file("$data/.drive-solo/order.json",
            $J->encode({ order => ['bp-a'], recorded_at => $NOW }));
        my ($rc, $out) = capture_run(['next', '--scope', 'bp-a'],
            { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
        is($rc, 0, 'AC-27: next --scope bp-a exits 0');
        chomp(my $line = $out);
        my $act = eval { $J->decode($line) };
        is($act->{action} // '', 'run-package', 'AC-27: emits run-package');
        my $cj = read_json_file("$data/.drive-solo/current.json");
        ok(ref $cj eq 'HASH', 'AC-27: current.json decodes to a hash') or diag($out);
        is($cj->{blueprint} // '', 'bp-a', 'AC-27: current.json blueprint matches');
        is($cj->{package}   // '', 'p1',   'AC-27: current.json package matches');
    }

    # AC-28: done removes it; in-flight leaves a pre-existing one untouched.
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data, 'bp-b', [{ key => 'p1', status => 'done', write_set => 'b/p1/' }]);
        make_path("$data/.drive-solo");
        # ORACLE FIX (2026-09-22): same missing order.json as AC-27 above -- B2 is
        # unconditional, so 'done' was unreachable without it too.
        write_file("$data/.drive-solo/order.json",
            $J->encode({ order => ['bp-b'], recorded_at => $NOW }));
        write_file("$data/.drive-solo/current.json",
            $J->encode({ blueprint => 'bp-b', package => 'p1', recorded_at => $NOW }));
        # ORACLE FIX (2026-09-22): a freshly-scoped, never-announced settled
        # blueprint emits blueprint-done first (fire-once via announced.json,
        # bp-drive-next.pl's own B4) -- 'done' asserts the WHOLE scope is
        # done-or-parked, which only a SECOND call (after announcement) reaches.
        # Was asserting the action of the wrong call.
        my ($rc0, $out0) = capture_run(['next', '--scope', 'bp-b'],
            { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
        chomp(my $line0 = $out0);
        my $act0 = eval { $J->decode($line0) };
        is($act0->{action} // '', 'blueprint-done', 'AC-28: first call announces blueprint-done');
        my ($rc, $out) = capture_run(['next', '--scope', 'bp-b'],
            { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
        chomp(my $line = $out);
        my $act = eval { $J->decode($line) };
        is($act->{action} // '', 'done', 'AC-28: second call (after announcement) emits done');
        ok(!-e "$data/.drive-solo/current.json", 'AC-28: done removes current.json');
    }
    {
        my $data = tempdir(CLEANUP => 1);
        # running -> in-flight (non-terminal, nothing else ready)
        make_bp_dir($data, 'bp-c', [{ key => 'p1', status => 'running', write_set => 'c/p1/' }]);
        make_path("$data/.drive-solo");
        # ORACLE FIX (2026-09-22): same missing order.json as AC-27 above.
        write_file("$data/.drive-solo/order.json",
            $J->encode({ order => ['bp-c'], recorded_at => $NOW }));
        my $pre = $J->encode({ blueprint => 'bp-c', package => 'p1', recorded_at => $NOW });
        write_file("$data/.drive-solo/current.json", $pre);
        my ($rc, $out) = capture_run(['next', '--scope', 'bp-c'],
            { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
        chomp(my $line = $out);
        my $act = eval { $J->decode($line) };
        is($act->{action} // '', 'in-flight', 'AC-28: fixture emits in-flight');
        my $after = read_file("$data/.drive-solo/current.json");
        is($after, $pre, 'AC-28: in-flight leaves an existing current.json byte-identical');
    }

    # AC-29: current.json pre-created as a directory -> pointer write never fatal.
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data, 'bp-d', [{ key => 'p1', status => 'pending', write_set => 'd/p1/' }]);
        make_path("$data/.drive-solo/current.json");   # a DIRECTORY at that path
        # ORACLE FIX (2026-09-22): same missing order.json as AC-27 above.
        write_file("$data/.drive-solo/order.json",
            $J->encode({ order => ['bp-d'], recorded_at => $NOW }));
        my ($rc, $out) = capture_run(['next', '--scope', 'bp-d'],
            { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
        is($rc, 0, 'AC-29: next still returns 0 when current.json cannot be written (it is a directory)');
        chomp(my $line = $out);
        my $act = eval { $J->decode($line) };
        is($act->{action} // '', 'run-package', 'AC-29: the emitted action is unaffected');
    }

    # AC-30: --help and the STATE header mention current.json.
    {
        my ($rc, $out) = capture_run(['--help'], {});
        like($out, qr/current\.json/, 'AC-30: bp-drive-next.pl --help output mentions current.json');
    }
    {
        my $src = read_src($DRIVENEXT);
        like($src, qr/STATE.*current\.json/s, "AC-30: the file's STATE header block mentions current.json");
    }
}

# ===========================================================================
# RT-1..RT-8 — DRIVER-AUTHORED ORACLE ADDITIONS (2026-09-22), pinning findings
# from the package's own red-team pass (redteam-step5.md), independently
# reproduced by the driver before being added here. These are NEW acceptance
# criteria the original spec's 32 ACs did not name; the driver is authorized
# to extend the oracle with newly-discovered criteria (same authority used
# earlier this session to fix genuine oracle bugs), always verified and
# recorded. None of these narrow or remove any existing assertion above.
# ===========================================================================

# RT-1 (redteam BLOCKER-1): the escape hatch file itself lives under the
# driver always-allow prefix today, letting the guarded actor switch both
# guards off with one permitted write. The fix carves <data>/.drive-solo/*
# out of the always-allow, falling through to ordinary write-set rules --
# under which the hatch (not in write_set, not under test_paths) is denied.
{
    my $fx = build_fixture();
    my $active = mk_active();
    my ($rc) = run_hook($GW, payload_json($fx->{hatch}, $fx->{root}), driver_env($fx, $active));
    is($rc, 2, 'RT-1 (redteam BLOCKER-1): driver-path write to the hatch file itself is denied');
}

# RT-2 (redteam BLOCKER-2a): a driver-path ledger-guard.sh write that widens
# the CURRENT package's own write_set must be rejected (V6: the scope fields
# of the package a driver is currently executing are not editable while
# current), not silently accepted because write_set's presence, not its
# value, was all V1-V5 ever checked.
{
    my $fx = build_fixture(write_set => 'src/:docs/api.md', test_paths => 't/');
    my $active = mk_active();
    my $widened = read_file($fx->{ledger});
    $widened =~ s/write_set: src\/:docs\/api\.md/write_set: src\/:docs\/api.md:other\//
        or die 'RT-2 fixture: write_set line not found to widen';
    my ($rc, $out) = run_hook($LG, payload_json($fx->{ledger}, $fx->{root}, content => $widened),
                               driver_env($fx, $active));
    is($rc, 2, 'RT-2 (redteam BLOCKER-2a): driver cannot widen its own current package\'s write_set');
    like($out, qr/LEDGER-GUARD: BLOCKED/, 'RT-2: ...and the denial names LEDGER-GUARD: BLOCKED');
}

# RT-3 (redteam BLOCKER-2b): same V6 rule, but blanking test_paths -- which
# would unprotect the package's own oracle files for every subsequent write.
{
    my $fx = build_fixture(write_set => 'src/:docs/api.md', test_paths => 't/');
    my $active = mk_active();
    my $blanked = read_file($fx->{ledger});
    $blanked =~ s/test_paths: t\//test_paths: /
        or die 'RT-3 fixture: test_paths line not found to blank';
    my ($rc, $out) = run_hook($LG, payload_json($fx->{ledger}, $fx->{root}, content => $blanked),
                               driver_env($fx, $active));
    is($rc, 2, 'RT-3 (redteam BLOCKER-2b): driver cannot blank its own current package\'s test_paths');
}

# RT-4 (redteam BLOCKER-2d): a driver-path write to current.json itself
# (the guard's own activation pointer) must be denied -- otherwise the
# pointer can be corrupted to force bp_driver_context's fail-open path (F2),
# which skips ledger-guard.sh's intended-fail-closed V1-V5 validator too.
{
    my $fx = build_fixture();
    my $active = mk_active();
    my ($rc) = run_hook($GW, payload_json($fx->{current_json}, $fx->{root}, content => '{{{not json'),
                         driver_env($fx, $active));
    is($rc, 2, 'RT-4 (redteam BLOCKER-2d): driver-path write to current.json itself is denied');
}

# RT-5 (redteam MAJOR-3): an ambient BP_DRIVER_SESSION=1 stray-inherited into
# a genuine WORKER session (BP_LEDGER set) must not crash guard-writes.sh
# with an unbound-variable error under `set -u` -- a crashing PreToolUse hook
# is non-blocking, i.e. the write proceeds with nothing having been checked.
{
    my $fx = build_fixture();
    my ($rc, $out) = run_hook($GW, payload_json($fx->{other_x}, $fx->{root}),
                               worker_env($fx, BP_DRIVER_SESSION => '1'));
    is($rc, 2, 'RT-5 (redteam MAJOR-3): ambient BP_DRIVER_SESSION=1 on the worker path still denies an out-of-set write');
    unlike($out, qr/unbound variable/i, 'RT-5: ...and does not crash with an unbound-variable error');
}

# RT-6 (redteam MINOR-1): a hatch file whose mtime is in the future (e.g. a
# clock-skewed touch, or a deliberately forged forward mtime) must be
# treated as EXPIRED, not honoured forever -- a negative age must not
# satisfy "age < ttl".
{
    my $fx = build_fixture();
    my $active = mk_active();
    write_file($fx->{hatch}, '');
    my $future = time + 10 * 365 * 24 * 3600;
    utime($future, $future, $fx->{hatch});
    my ($rc) = run_hook($GW, payload_json($fx->{t_oracle}, $fx->{root}),
        driver_env($fx, $active, CCPRAXIS_DRIVER_GUARDS_OFF_TTL_MIN => '1'));
    is($rc, 2, 'RT-6 (redteam MINOR-1): a future-dated hatch file is treated as expired, not honoured forever');
}

# RT-7 (redteam MAJOR-2): bp-drive-next.pl's EMPTY-SCOPE `done` branch
# (no blueprint at all matches the scope) must also remove current.json --
# B13 says unqualified "answering done removes it", but only the OTHER done
# emitter (B6, the all-settled case) actually called the removal helper.
SKIP: {
    skip 'bp-drive-next.pl did not load', 2 unless $LOADED;
    my $data = tempdir(CLEANUP => 1);
    make_path("$data/.drive-solo");
    make_path("$data/blueprints");   # present but empty -> zero candidates, not "no blueprints/ at all"
    my $NOW = 1_830_297_600;
    write_file("$data/.drive-solo/current.json",
        $J->encode({ blueprint => 'stale-bp', package => 'p1', recorded_at => $NOW }));
    my ($rc, $out) = capture_run(['next', '--scope', 'nonexistent-bp'],
        { data_dir => $data, now => sub { $NOW }, verdict => sub { { action => 'ok' } } });
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action} // '', 'done', 'RT-7 (redteam MAJOR-2): an empty-scope call also emits done');
    ok(!-e "$data/.drive-solo/current.json",
        'RT-7 (redteam MAJOR-2): ...and the empty-scope done branch removes current.json too');
}

done_testing();
