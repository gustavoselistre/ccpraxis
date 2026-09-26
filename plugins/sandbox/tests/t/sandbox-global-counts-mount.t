#!/usr/bin/env perl
# platform: any
# MountSpec-side oracle for the global-counts read-only mount (blueprint
# almanac-records, package 19-global-counts-snapshot). See
# .ccpraxis-local-data/blueprints/almanac-records/specs/19-global-counts-
# snapshot-spec.md sections 2.5, 3, 4 (AC14-AC22).
#
# AC14-AC19 are pure MountSpec structural checks and always run. AC20-AC21
# need a REAL container and are wrapped in a single SKIP: block, following
# plugins/sandbox/tests/t/test-harness-orphan-reaping.t's convention of
# detecting the container CLI BEFORE `require TestSandbox` -- TestSandbox.pm
# dies (not skips) at load with no CLI on PATH, so probing for a CLI first
# and gating the require behind that is what turns a hard die into a clean
# `# SKIP` for the rest of this suite (AC22). This file never spawns
# launcher.pl (checked by the final self-scan below) and never runs the
# rest of the suite's assertions only if the whole-file plan would have to
# be skip_all -- since AC14-AC19 have nothing to do with a container, a
# whole-file skip_all (which is a hard exit) is the wrong tool here; a
# lexically-scoped SKIP: block is.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use MountSpec qw(winify_path v_to_mount convert_v_to_mount
    claude_home_create_args parse_create_args audit_claude_home);

my $ISO_RE = qr/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/;

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub mkdir_p { my ($d) = @_; make_path($d) unless -d $d; return; }

sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} (defined $bytes ? $bytes : '');
    close $fh;
    return;
}

# capture_stderr($coderef) -> (\@return_values, $eval_error, $stderr_text)
#
# Redirects STDERR to a REAL File::Temp file for the duration of the call --
# never to an in-memory scalar filehandle, which fails on this host with
# "Bad file descriptor" (CLAUDE.md-documented landmine).
sub capture_stderr {
    my ($code) = @_;
    my (undef, $tmp) = tempfile();
    open(my $save_err, '>&', \*STDERR) or die "fixture: cannot dup STDERR: $!";
    open(STDERR, '>', $tmp) or die "fixture: cannot redirect STDERR: $!";
    my @ret = eval { $code->() };
    my $died = $@;
    open(STDERR, '>&', $save_err) or die "fixture: cannot restore STDERR: $!";
    close $save_err;
    my $captured = slurp_text($tmp);
    unlink $tmp;
    return (\@ret, $died, defined($captured) ? $captured : '');
}

my $claude_data  = tempdir(CLEANUP => 1);
$claude_data =~ s{\\}{/}g;
my $launcher_dir = "$claude_data/.launcher";
mkdir_p($launcher_dir);
my (undef, $statusline) = tempfile(SUFFIX => '.pl');
write_raw($statusline, "#!/usr/bin/env perl\n1;\n");

my @expected_base = (
    '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
    '-v', "$claude_data:/root/.claude",
    '-v', "$launcher_dir:/root/.claude/.launcher:ro",
    '-v', "$statusline:/root/.claude/statusline.pl:ro",
);

# ---------------------------------------------------------------------------
# AC14 (DC-d, no regression): absent global_counts is byte-identical to
# today; an empty-string global_counts dies naming the option.
# ---------------------------------------------------------------------------
{
    my @base = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline) };
    is_deeply(\@base, \@expected_base,
        'AC14: without global_counts, output equals the current 8-element list exactly')
        or diag("error: " . ($@ // '(none)'));

    eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => '') };
    like($@ // '', qr/global_counts/, 'AC14: global_counts=>"" dies with a message naming global_counts');
}

# ---------------------------------------------------------------------------
# AC15 (DC-c, DC-d): global_counts=>P, P absent, parent exists -- seeded and
# appended as the last pair.
# ---------------------------------------------------------------------------
my $gc_path = "$claude_data/almanac-global-counts.json";
{
    ok(!-e $gc_path, 'AC15 setup: P does not exist before the call');

    my @withgc = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_path) };

    if (@withgc >= 2) {
        my @tail = @withgc[-2, -1];
        is_deeply(\@tail, ['-v', "$gc_path:/root/.claude/almanac-global-counts.json:ro"],
            'AC15: the last two elements are the global_counts ro bind pair');
        my @preceding = @withgc[0 .. $#withgc - 2];
        is_deeply(\@preceding, \@expected_base,
            'AC15: the preceding elements equal AC14\'s 8-element base list');
    } else {
        fail("AC15: $_") for 1 .. 2;
        diag("claude_home_create_args error: " . ($@ // '(none)') . "; got: " . scalar(@withgc) . " elements");
    }

    ok(-f $gc_path, 'AC15: P now exists as a plain file') or diag("no such file: $gc_path");

    my $bytes = slurp_raw($gc_path);
    if (defined $bytes) {
        like($bytes, qr/\n\z/, 'AC15: P ends in a trailing newline');
        my $body_only = substr($bytes, 0, length($bytes) - 1);
        unlike($body_only, qr/\n\z/, 'AC15: exactly one trailing newline, not two');

        my $decoded = eval { JSON::PP->new->decode($bytes) };
        if (ref($decoded) eq 'HASH') {
            is_deeply([ sort keys %$decoded ], [ sort qw(generated_at note schema todo) ],
                'AC15: P decodes to exactly the section-2.2 key set');
            is($decoded->{schema}, 1, 'AC15: P\'s schema is 1');
            like($decoded->{generated_at} // '', $ISO_RE, 'AC15: P\'s generated_at matches the ISO pattern');
            is_deeply($decoded->{note}, { total => 0 }, 'AC15: P\'s note block is the zero seed');
            is_deeply($decoded->{todo}, { done => 0, open => 0, total => 0 }, 'AC15: P\'s todo block is the zero seed');
        } else {
            fail('AC15: P decodes to exactly the section-2.2 key set');
            fail('AC15: P\'s schema is 1');
            fail('AC15: P\'s generated_at matches the ISO pattern');
            fail('AC15: P\'s note block is the zero seed');
            fail('AC15: P\'s todo block is the zero seed');
            diag("decode error: " . ($@ // '(none)'));
        }
    } else {
        fail("AC15: $_") for 1 .. 6;
    }
}

# ---------------------------------------------------------------------------
# AC16 (DC-d): through convert_v_to_mount -> parse_create_args, the new
# mount is type=bind, readonly, targets the fixed container path, and
# audit_claude_home reports zero violations. On Windows the source is drive
# form.
#
# The drive-form sub-check needs a global_counts PATH that is itself in
# single-drive-letter-mount POSIX form (/c/...) BEFORE winify_path ever
# touches it -- that is what winify_path converts (a bare "/c/..." ->
# "C:/..."), not an arbitrary path. File::Temp's own tempdir() is NOT
# reliably in that form: its base directory follows $ENV{TMPDIR}/$TEMP/$TMP,
# and under a stripped environment (e.g. `env -i PATH=... HOME=...`, this
# suite's own documented way to hide the container CLI for AC22) those are
# all gone and File::Temp falls back to MSYS's internal /tmp, which is not a
# drive mount at all -- winify_path is then a correct no-op, and the
# assertion below would fail for a FIXTURE reason, not a real one. In
# production the equivalent value is "${CLAUDE_HOST_CONFIG}/almanac-global-
# counts.json", and CLAUDE_HOST_CONFIG is already winified by the launcher
# before MountSpec ever sees it -- so anchoring this fixture under
# $ENV{HOME} (which Git-for-Windows always sets to a /c/... path, and which
# the stripped-environment invocation above deliberately preserves) is the
# equivalent starting point for this test, independent of TMPDIR/TEMP/TMP.
my $ac16_base = (defined $ENV{HOME} && length $ENV{HOME}) ? tempdir(DIR => $ENV{HOME}, CLEANUP => 1)
                                                            : tempdir(CLEANUP => 1);
$ac16_base =~ s{\\}{/}g;
my $gc_path_ac16 = "$ac16_base/almanac-global-counts.json";
{
    my @withgc = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_path_ac16) };
    my @converted = eval { convert_v_to_mount(@withgc) };
    my $parsed = eval { MountSpec::parse_create_args(\@converted) };

    if (ref($parsed) eq 'HASH') {
        my ($m) = grep { defined($_->{target}) && $_->{target} eq '/root/.claude/almanac-global-counts.json' }
                       @{ $parsed->{mounts} || [] };
        ok($m, 'AC16: a parsed mount targets /root/.claude/almanac-global-counts.json') or diag(explain($parsed));
        if ($m) {
            is($m->{type}, 'bind', 'AC16: that mount is type bind');
            is($m->{readonly}, 1, 'AC16: that mount is readonly');
            if ($MountSpec::WINDOWS_FAMILY) {
                like($m->{source} // '', qr{^[A-Za-z]:/}, 'AC16: on Windows the source is in drive form (X:/...)');
            }
        } else {
            fail('AC16: that mount is type bind');
            fail('AC16: that mount is readonly');
        }
        my @viol = eval { MountSpec::audit_claude_home($parsed) };
        is(scalar(@viol), 0, 'AC16: audit_claude_home returns zero violations') or diag(explain(\@viol));
    } else {
        fail("AC16: $_") for 1 .. 3;
        diag("pipeline error: " . ($@ // '(none)'));
    }
}

# ---------------------------------------------------------------------------
# AC17 (DC-c): pre-existing P with custom bytes is untouched, pair still
# emitted.
# ---------------------------------------------------------------------------
{
    my $gc_existing = "$claude_data/pre-existing-global-counts.json";
    write_raw($gc_existing, "custom bytes, not a valid snapshot at all\n");
    my $before = slurp_raw($gc_existing);

    my @args = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_existing) };

    if (@args >= 2) {
        my @tail = @args[-2, -1];
        is_deeply(\@tail, ['-v', "$gc_existing:/root/.claude/almanac-global-counts.json:ro"],
            'AC17: the pair is still emitted for a pre-existing P');
    } else {
        fail('AC17: the pair is still emitted for a pre-existing P');
        diag("error: " . ($@ // '(none)'));
    }
    is(slurp_raw($gc_existing), $before, 'AC17: the pre-existing P\'s bytes are identical after the call');
}

# ---------------------------------------------------------------------------
# AC18 (DC-c, DC-g): P is a directory, or contains a claude-code-vault
# segment -- pair omitted, exactly one STDERR line, no die, nothing created
# for vault_path.
# ---------------------------------------------------------------------------
{
    my $dir_p = "$claude_data/global-counts-is-a-dir";
    mkdir_p($dir_p);

    my ($ret, $died, $stderr) = capture_stderr(sub {
        return MountSpec::claude_home_create_args(
            claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
            global_counts => $dir_p);
    });
    ok(!length($died), 'AC18 (directory): claude_home_create_args does not die') or diag($died);
    is_deeply($ret, [ \@expected_base ]->[0], 'AC18 (directory): the pair is omitted (output equals the base block)')
        if !length($died);
    fail('AC18 (directory): the pair is omitted (output equals the base block)') if length($died);
    my @lines = grep { length } split /\n/, $stderr;
    is(scalar(@lines), 1, 'AC18 (directory): exactly one STDERR line') or diag($stderr);
    like($stderr, qr/^MountSpec: global counts snapshot not mounted \(not_a_file\): \Q$dir_p\E$/m,
        'AC18 (directory): that line names not_a_file and the path');

    my $vault_p = "$claude_data/claude-code-vault/almanac-global-counts.json";
    ok(!-e $vault_p, 'AC18 (vault_path) setup: P does not exist before the call');

    my ($ret2, $died2, $stderr2) = capture_stderr(sub {
        return MountSpec::claude_home_create_args(
            claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
            global_counts => $vault_p);
    });
    ok(!length($died2), 'AC18 (vault_path): claude_home_create_args does not die') or diag($died2);
    is_deeply($ret2, [ \@expected_base ]->[0], 'AC18 (vault_path): the pair is omitted')
        if !length($died2);
    fail('AC18 (vault_path): the pair is omitted') if length($died2);
    my @lines2 = grep { length } split /\n/, $stderr2;
    is(scalar(@lines2), 1, 'AC18 (vault_path): exactly one STDERR line') or diag($stderr2);
    like($stderr2, qr/^MountSpec: global counts snapshot not mounted \(vault_path\): \Q$vault_p\E$/m,
        'AC18 (vault_path): that line names vault_path and the path');
    ok(!-e $vault_p, 'AC18 (vault_path): nothing is created on disk');
}

# ---------------------------------------------------------------------------
# AC19 (DC-d, DC-g): launcher.pl's single call site, by source text. The
# launcher is never executed.
# ---------------------------------------------------------------------------
{
    my $launcher_src = slurp_text("$Bin/../../scripts/launcher.pl");
    ok(defined $launcher_src, 'AC19 setup: launcher.pl is readable') or BAIL_OUT('launcher.pl missing');

    like($launcher_src, qr/global_counts\s*=>\s*"\$\{CLAUDE_HOST_CONFIG\}\/almanac-global-counts\.json"/,
        'AC19: launcher.pl passes global_counts => "${CLAUDE_HOST_CONFIG}/almanac-global-counts.json"');

    if ($launcher_src =~ /(MountSpec::claude_home_create_args\s*\([^;]*?\)\s*;)/s) {
        my $call = $1;
        unlike($call, qr/claude-code-vault/, 'AC19: the literal claude-code-vault does not occur in that call');
    } else {
        fail('AC19: located the claude_home_create_args call site to check for claude-code-vault');
    }
}

# ---------------------------------------------------------------------------
# AC20/AC21 (DC-e, B11 freshness). REAL container. Skipped cleanly (never
# passed as a false green) when no container CLI is on PATH OR is on PATH
# but not REACHABLE (AC22's exact wording) -- e.g. podman.exe present but
# its machine/daemon stopped, which fails `<cli> info` fast (connection
# refused) while `<cli> --version` alone still reports success (it only
# inspects the binary, never dials the daemon). Both checks run BEFORE
# `require TestSandbox` so its die-at-load-with-no-CLI never fires here,
# and the reachability probe is bounded (`timeout 10 ...`) so a wedged
# daemon cannot hang this file instead of skipping it.
# ---------------------------------------------------------------------------
my ($HAVE_CLI, $CLI_UNAVAILABLE_REASON);
{
    my $cli_bin;
    for my $c ($^O =~ /^(MSWin32|cygwin|msys)$/ ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        if (system("$c --version > /dev/null 2>&1") == 0) { $cli_bin = $c; last }
    }
    if (!defined $cli_bin) {
        $CLI_UNAVAILABLE_REASON = 'no container CLI on PATH (docker/podman)';
    } else {
        my $rc = system("timeout 10 $cli_bin info > /dev/null 2>&1");
        if ($rc == 0) {
            $HAVE_CLI = 1;
        } else {
            $CLI_UNAVAILABLE_REASON = "$cli_bin is on PATH but not reachable "
                . "('$cli_bin info' failed or timed out, rc=" . ($rc >> 8) . ") -- "
                . "e.g. the machine/daemon is stopped";
        }
    }
}

SKIP: {
    skip("$CLI_UNAVAILABLE_REASON -- AC20/AC21 need a real, reachable container runtime "
       . "(TestSandbox.pm dies at load without one)", 9)
        unless $HAVE_CLI;

    require TestSandbox;
    TestSandbox->import(qw(podman_run_capture create_probe_container new_temp_dir probe_image));

    # A fresh, container-scoped set of paths (TestSandbox's own scratch-root
    # convention), independent of the host-only paths used by AC14-AC19
    # above.
    my $claude_data_c  = TestSandbox::new_temp_dir();
    my $launcher_dir_c = "$claude_data_c/.launcher";
    mkdir_p($launcher_dir_c);
    my $statusline_c = "$claude_data_c/statusline.pl";
    write_raw($statusline_c, "#!/usr/bin/env perl\n1;\n");
    my $gc_c = "$claude_data_c/almanac-global-counts.json";

    my @args_c = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data_c, launcher_dir => $launcher_dir_c, statusline => $statusline_c,
        global_counts => $gc_c) };

    if (!@args_c) {
        fail("AC20/AC21: $_") for 1 .. 9;
        diag("claude_home_create_args error: " . ($@ // '(none)'));
        last SKIP;
    }

    my $c = eval { TestSandbox::create_probe_container(mounts => \@args_c) };
    ok(defined $c, 'AC20: a probe container was created from the MountSpec block') or diag($@);

    if (!defined $c) {
        fail("AC20/AC21: $_") for 1 .. 8;
        last SKIP;
    }

    my ($rc_w, $out_w) = TestSandbox::podman_run_capture('exec', $c, 'sh', '-c',
        'echo x > /root/.claude/almanac-global-counts.json');
    isnt($rc_w, 0, 'AC20: a write inside the container to the mounted path fails') or diag($out_w);
    like($out_w, qr/read-only/i, 'AC20: the failure names a read-only filesystem') or diag($out_w);

    my $host_bytes_before = slurp_raw($gc_c);
    my (undef, $out_cat) = TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    is($out_cat, $host_bytes_before, "AC20: cat inside the container returns P's bytes") or diag($out_cat);

    my $host_bytes_after = slurp_raw($gc_c);
    is($host_bytes_after, $host_bytes_before, 'AC20: the host file bytes are unchanged after the failed write');

    # AC21: host-side temp+rename rewrite, then a restart, then re-read.
    my $new_bytes = qq({"generated_at":"2030-01-01T00:00:00Z","note":{"total":9},"schema":1,)
                  . qq("todo":{"done":1,"open":1,"total":2}}\n);
    my $tmp = "$gc_c.tmp.$$";
    write_raw($tmp, $new_bytes);
    my $renamed = rename($tmp, $gc_c);
    ok($renamed, 'AC21: a host-side temp+rename over P succeeds') or diag("rename failed: $!");

    my ($rc_before_restart, $out_before_restart) =
        TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    diag('AC21 (not asserted, recorded per spec): container cat WITHOUT a restart returned '
       . ($out_before_restart eq $new_bytes ? 'the NEW bytes' : 'the OLD bytes')
       . " (rc=$rc_before_restart)");

    my ($rc_restart) = TestSandbox::podman_run_capture('restart', $c);
    is($rc_restart, 0, 'AC21: podman restart of the probe container exits 0');

    my (undef, $out_cat2) = TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    is($out_cat2, $new_bytes, 'AC21: after restart, the container cat returns the newly-renamed bytes')
        or diag($out_cat2);
}

# ---------------------------------------------------------------------------
# AC22 (suite rules): this file never spawns launcher.pl.
# ---------------------------------------------------------------------------
{
    open(my $fh, '<', $0) or die "fixture: cannot reread self ($0): $!";
    local $/;
    my $self_src = <$fh>;
    close $fh;
    ok(defined($self_src) && $self_src !~ /system\([^)]*launcher\.pl/ && $self_src !~ /exec\([^)]*launcher\.pl/,
        'AC22: this test file never spawns launcher.pl');
}

done_testing();
