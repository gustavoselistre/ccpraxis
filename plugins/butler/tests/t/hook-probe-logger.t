#!/usr/bin/env perl
# platform: any
# Contract test for the append-only hook-payload diagnostic (blueprint
# hook-continuity-remake, package 01-harness-facts, spec section 2.1). The
# script under test is registered nowhere in this repo -- it is invoked here
# directly, and only here, as a bare subprocess with stdin from a file and
# stdout/stderr captured to files. Every case asserts exit 0 AND empty stdout
# AND empty stderr, in addition to its own check, because "never blocks" and
# "never prints" are load-bearing on every code path, not just the happy one.
#
# ALL FIXTURE I/O IS RAW/BINARY. Windows text-mode translates a bare "\n" to
# "\r\n" on write and back on read; several cases here depend on an EXACT
# terminator byte sequence (a lone "\n", or "\r\n\r\n"), so every open() in
# this file uses the ':raw' layer and nothing here ever relies on Perl's
# default line-ending behaviour.
#
# STDIN/STDOUT/STDERR REDIRECTION IS VIA REAL FILES, NEVER A SCALAR. Reopening
# a process's own STDOUT onto an in-memory scalar fails with "Bad file
# descriptor" on this host (Git-for-Windows perl) -- this file dups the
# process's real handles aside, reopens them onto File::Temp-backed files for
# the duration of one subprocess call, then restores them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use POSIX qw(WIFEXITED WEXITSTATUS);
use FindBin qw($Bin);

my $PROBE = abs_path("$Bin/../../scripts/bp-hook-probe.pl") // "$Bin/../../scripts/bp-hook-probe.pl";
my $ROOT  = abs_path("$Bin/../../../..");

my $TMP = tempdir(CLEANUP => 1);

# $FIX is a SEPARATE tempdir for run_probe()'s own scratch (the stdin fixture
# it reads from, and the stdout/stderr files it captures the subprocess into
# on every call). It must never be $TMP or any subdirectory of it: AC6 takes
# a directory listing of $TMP before and after a probe call and asserts it is
# UNCHANGED, and a scratch file that run_probe itself drops into that same
# directory on every invocation would make that assertion fail on every run,
# for a reason that has nothing to do with the probe under test.
my $FIX = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# Byte-exact fixture I/O helpers. No text-mode translation, ever.
# ---------------------------------------------------------------------------
sub write_bytes {
    my ($path, $bytes) = @_;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print $fh $bytes;
    close $fh or die "cannot close $path: $!";
    return $path;
}

sub read_bytes {
    my ($path) = @_;
    return undef unless -e $path;
    open(my $fh, '<:raw', $path) or die "cannot read $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

my $fixture_n = 0;
# fixture_path(): scratch for run_probe()'s stdin/stdout/stderr -- lives
# under $FIX, never under $TMP (see the AC6 note above).
sub fixture_path { return "$FIX/fx-" . (++$fixture_n) . "-$_[0]"; }

# log_path(): a TARGET log-file path for a case under test -- lives under
# $TMP, so AC6's directory-listing assertion sees exactly what the probe
# itself did or did not create.
sub log_path { return "$TMP/log-" . (++$fixture_n) . "-$_[0]"; }

# ---------------------------------------------------------------------------
# run_probe(%opt) -> ($exit, $stdout_bytes, $stderr_bytes)
#
#   stdin => path to a file supplying stdin (required)
#   log   => the value CCPRAXIS_HOOK_PROBE_LOG is set to, or undef to leave
#            the variable UNSET entirely (required key, value may be undef)
#   argv  => arrayref of extra command-line arguments (default: none)
#
# Sets the env var via 'local %ENV' (restored automatically when this sub
# returns), and redirects the CURRENT PROCESS's real STDIN/STDOUT/STDERR onto
# real files for the duration of the system() call, restoring them
# afterwards. Never touches an in-memory scalar.
# ---------------------------------------------------------------------------
sub run_probe {
    my (%o) = @_;
    die 'run_probe: stdin is required' unless defined $o{stdin};
    die 'run_probe: log key is required (value undef means unset)' unless exists $o{log};
    my @argv = @{ $o{argv} || [] };

    local %ENV = %ENV;
    if (defined $o{log}) {
        $ENV{CCPRAXIS_HOOK_PROBE_LOG} = $o{log};
    } else {
        delete $ENV{CCPRAXIS_HOOK_PROBE_LOG};
    }

    my $outp = fixture_path('stdout');
    my $errp = fixture_path('stderr');

    open(my $save_in,  '<&', \*STDIN)  or die "dup STDIN: $!";
    open(my $save_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $save_err, '>&', \*STDERR) or die "dup STDERR: $!";

    my $rc;
    {
        open(STDIN,  '<:raw', $o{stdin}) or die "reopen STDIN from $o{stdin}: $!";
        open(STDOUT, '>:raw', $outp)     or die "reopen STDOUT to $outp: $!";
        open(STDERR, '>:raw', $errp)     or die "reopen STDERR to $errp: $!";

        $rc = system($^X, $PROBE, @argv);

        open(STDIN,  '<&', $save_in)   or die "restore STDIN: $!";
        open(STDOUT, '>&', $save_out)  or die "restore STDOUT: $!";
        open(STDERR, '>&', $save_err)  or die "restore STDERR: $!";
    }
    close $save_in; close $save_out; close $save_err;

    my $exit = ($rc == -1) ? -1 : (WIFEXITED($rc) ? WEXITSTATUS($rc) : -1);
    my $out  = read_bytes($outp) // '';
    my $err  = read_bytes($errp) // '';
    return ($exit, $out, $err);
}

# assert_silent($exit, $out, $err, $label): the three checks every case owes,
# per spec section 4's preamble.
sub assert_silent {
    my ($exit, $out, $err, $label) = @_;
    is($exit, 0, "$label: exit 0");
    is(length($out), 0, "$label: stdout is 0 bytes");
    is(length($err), 0, "$label: stderr is 0 bytes");
}

sub dir_listing {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return [];
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    return \@entries;
}


# ===========================================================================
# AC1: perl -c on the probe succeeds (compile check).
# ===========================================================================
{
    ok(-f $PROBE, "AC1: bp-hook-probe.pl exists at $PROBE")
        or diag('the probe has not been written yet -- every subsequent case is expected to fail because of this, not because of test scaffolding');

    my $out = `"$^X" -c "$PROBE" 2>&1`;
    my $rc  = $? == -1 ? -1 : ($? >> 8);
    is($rc, 0, 'AC1: perl -c exits 0') or diag("perl -c output: $out");
}


# ===========================================================================
# AC2: a single compact JSON payload leads to a log file whose bytes equal
# payload . "\n" exactly.
# ===========================================================================
{
    my $payload = '{"hook_event_name":"PreToolUse","session_id":"abc123","tool_name":"Bash"}';
    my $stdin   = write_bytes(fixture_path('in'), $payload);
    my $log     = log_path('log.jsonl');

    my ($exit, $out, $err) = run_probe(stdin => $stdin, log => $log);
    assert_silent($exit, $out, $err, 'AC2');

    is(read_bytes($log), $payload . "\n",
        'AC2: log file bytes equal payload . "\n" exactly, no more, no less');
}


# ===========================================================================
# AC3: two sequential invocations with different payloads give exactly two
# lines in invocation order. A pre-seeded line is preserved byte-for-byte
# ahead of them (append, never truncate).
# ===========================================================================
{
    my $log = log_path('log.jsonl');
    my $preseed = '{"pre":"seeded","order":0}' . "\n";
    write_bytes($log, $preseed);

    my $p1 = '{"seq":1,"mark":"first"}';
    my $p2 = '{"seq":2,"mark":"second"}';

    my ($e1, $o1, $r1) = run_probe(stdin => write_bytes(fixture_path('in'), $p1), log => $log);
    assert_silent($e1, $o1, $r1, 'AC3 (invocation 1)');

    my ($e2, $o2, $r2) = run_probe(stdin => write_bytes(fixture_path('in'), $p2), log => $log);
    assert_silent($e2, $o2, $r2, 'AC3 (invocation 2)');

    is(read_bytes($log), $preseed . $p1 . "\n" . $p2 . "\n",
        'AC3: pre-seeded line preserved, then the two payloads appear as two lines in invocation order (append, not truncate)');
}


# ===========================================================================
# AC4: a payload ending in "\n", and another ending in "\r\n\r\n", each
# become exactly one line terminated by a single "\n", with no blank lines
# and the payload body unchanged.
# ===========================================================================
{
    my $body1 = '{"terminator":"lf"}';
    my $body2 = '{"terminator":"crlf-crlf"}';

    my $log1 = log_path('log.jsonl');
    my ($e1, $o1, $r1) = run_probe(
        stdin => write_bytes(fixture_path('in'), $body1 . "\n"), log => $log1);
    assert_silent($e1, $o1, $r1, 'AC4 (LF-terminated payload)');
    is(read_bytes($log1), $body1 . "\n",
        'AC4: a trailing "\n" becomes exactly one line, body unchanged, no blank line');

    my $log2 = log_path('log.jsonl');
    my ($e2, $o2, $r2) = run_probe(
        stdin => write_bytes(fixture_path('in'), $body2 . "\r\n\r\n"), log => $log2);
    assert_silent($e2, $o2, $r2, 'AC4 (CRLF-CRLF-terminated payload)');
    is(read_bytes($log2), $body2 . "\n",
        'AC4: a trailing "\r\n\r\n" run becomes exactly one line terminated by a single "\n", body unchanged, no blank lines');
}


# ===========================================================================
# AC5: verbatim bytes. A payload containing raw UTF-8 non-ASCII (Andre, the
# right-arrow glyph) and a payload that is not valid JSON are each logged
# byte-identical (compared as raw bytes, not decoded text).
# ===========================================================================
{
    my $utf8_payload = "{\"transcript_path\":\"C:/Users/Andr\x{c3}\x{a9}/proj\",\"note\":\"\x{e2}\x{86}\x{92}\"}";
    my $log1 = log_path('log.jsonl');
    my ($e1, $o1, $r1) = run_probe(
        stdin => write_bytes(fixture_path('in'), $utf8_payload), log => $log1);
    assert_silent($e1, $o1, $r1, 'AC5 (raw UTF-8 payload)');
    is(read_bytes($log1), $utf8_payload . "\n",
        'AC5: raw UTF-8 bytes (Andre / right-arrow) are logged byte-identical, untouched');

    my $invalid_json = '{not json';
    my $log2 = log_path('log.jsonl');
    my ($e2, $o2, $r2) = run_probe(
        stdin => write_bytes(fixture_path('in'), $invalid_json), log => $log2);
    assert_silent($e2, $o2, $r2, 'AC5 (invalid-JSON payload)');
    is(read_bytes($log2), $invalid_json . "\n",
        'AC5: invalid JSON is logged byte-identical -- the probe never validates or rejects it');
}


# ===========================================================================
# AC6: CCPRAXIS_HOOK_PROBE_LOG unset gives exit 0 and no output, and creates
# no file in the test's temp dir (the dir listing is unchanged). The same
# holds with the variable set to the empty string.
# ===========================================================================
{
    my $payload = '{"case":"unset-env"}';

    my $before = dir_listing($TMP);
    my ($e1, $o1, $r1) = run_probe(
        stdin => write_bytes(fixture_path('in'), $payload), log => undef);
    my $after = dir_listing($TMP);
    assert_silent($e1, $o1, $r1, 'AC6 (unset CCPRAXIS_HOOK_PROBE_LOG)');
    is_deeply($after, $before,
        'AC6: with the env var unset, the temp dir listing is unchanged -- no file was created')
        or diag('before: ' . join(',', @$before) . "\nafter: " . join(',', @$after));

    my $before2 = dir_listing($TMP);
    my ($e2, $o2, $r2) = run_probe(
        stdin => write_bytes(fixture_path('in'), $payload), log => '');
    my $after2 = dir_listing($TMP);
    assert_silent($e2, $o2, $r2, 'AC6 (CCPRAXIS_HOOK_PROBE_LOG="")');
    is_deeply($after2, $before2,
        'AC6: with the env var set to the empty string, the temp dir listing is unchanged -- no file was created')
        or diag('before: ' . join(',', @$before2) . "\nafter: " . join(',', @$after2));
}


# ===========================================================================
# AC7: empty stdin, and stdin of only "\r\n": exit 0, no output, and the
# target file is not created. If the file was pre-seeded, it is unchanged.
# ===========================================================================
{
    my $log = log_path('log.jsonl');
    my ($e1, $o1, $r1) = run_probe(
        stdin => write_bytes(fixture_path('in'), ''), log => $log);
    assert_silent($e1, $o1, $r1, 'AC7 (empty stdin)');
    ok(!-e $log, 'AC7: empty stdin creates no target file');

    my $log2 = log_path('log.jsonl');
    my ($e2, $o2, $r2) = run_probe(
        stdin => write_bytes(fixture_path('in'), "\r\n"), log => $log2);
    assert_silent($e2, $o2, $r2, 'AC7 (stdin of only "\r\n")');
    ok(!-e $log2, 'AC7: stdin of only "\r\n" creates no target file');

    # Pre-seeded target must be left byte-for-byte unchanged.
    my $log3 = log_path('log.jsonl');
    my $preseed = '{"already":"here"}' . "\n";
    write_bytes($log3, $preseed);
    my ($e3, $o3, $r3) = run_probe(
        stdin => write_bytes(fixture_path('in'), ''), log => $log3);
    assert_silent($e3, $o3, $r3, 'AC7 (empty stdin, pre-seeded target)');
    is(read_bytes($log3), $preseed,
        'AC7: a pre-seeded target is left byte-for-byte unchanged when stdin has nothing to write');
}


# ===========================================================================
# AC8: unwritable targets give exit 0, no output, and no side effect for:
#   (i)  a path whose parent dir does not exist (the parent stays absent);
#   (ii) a path that is an existing directory.
# ===========================================================================
{
    my $payload = '{"case":"unwritable"}';

    my $missing_parent = "$TMP/does-not-exist-" . (++$fixture_n) . "/nested/log.jsonl";
    my ($dir_that_must_stay_absent) = $missing_parent =~ m{^(.*)/nested/log\.jsonl$};
    ok(!-e $dir_that_must_stay_absent, 'AC8 precondition: the missing-parent dir does not exist yet');

    my ($e1, $o1, $r1) = run_probe(
        stdin => write_bytes(fixture_path('in'), $payload), log => $missing_parent);
    assert_silent($e1, $o1, $r1, 'AC8 (missing parent dir)');
    ok(!-e $dir_that_must_stay_absent,
        'AC8: the missing parent dir is still absent afterwards -- the probe never creates parent directories');
    ok(!-e $missing_parent, 'AC8: the target itself was never created');

    my $target_is_dir = log_path('is-a-dir');
    mkdir $target_is_dir or die "mkdir $target_is_dir: $!";
    my ($e2, $o2, $r2) = run_probe(
        stdin => write_bytes(fixture_path('in'), $payload), log => $target_is_dir);
    assert_silent($e2, $o2, $r2, 'AC8 (target is an existing directory)');
    ok(-d $target_is_dir, 'AC8: the directory target is unchanged (still a plain directory)');
    my $listing = dir_listing($target_is_dir);
    is_deeply($listing, [], 'AC8: nothing was written inside the directory target');
}


# ===========================================================================
# AC9: a 1 MiB single-line payload is logged byte-identical, and the
# invocation exits 0 (proves stdin is fully drained). No wall-clock
# assertion.
# ===========================================================================
{
    my $body = '{"pad":"' . ('A' x (1024 * 1024 - 32)) . '"}';
    my $log  = log_path('log.jsonl');
    my ($exit, $out, $err) = run_probe(
        stdin => write_bytes(fixture_path('in'), $body), log => $log);
    assert_silent($exit, $out, $err, 'AC9');
    is(read_bytes($log), $body . "\n",
        'AC9: a 1 MiB single-line payload is logged byte-identical (stdin fully drained)');
}


# ===========================================================================
# AC10: 10 invocations launched in parallel (fork), each with a distinct
# ~4 KiB payload, give exactly 10 lines. The set of lines equals the set of
# payloads (order free), so no line is interleaved or torn.
#
# CHOICE OF MECHANISM: fork(), not `system 1, ...`. fork() is already
# exercised successfully on this exact host elsewhere in this suite
# (the retired hook-payload-read-bound coverage's FIFO-writer case; the retired hook-path-walk-and-scope coverage
# section H), so it is the proven-working primitive here.
# ===========================================================================
{
    my $log = log_path('log.jsonl');
    my $n = 10;
    my @payloads;
    for my $i (1 .. $n) {
        my $pad = ('x' x 10) . $i;
        # ~4 KiB distinct payload per invocation.
        push @payloads, sprintf(
            '{"concurrency_idx":%d,"nonce":"%s","pad":"%s"}',
            $i, "nonce-$i-$$", $pad x 200,
        );
    }

    my @pids;
    for my $i (0 .. $n - 1) {
        my $stdin_file = write_bytes(fixture_path("cin$i"), $payloads[$i]);
        my $outp = fixture_path("cout$i");
        my $errp = fixture_path("cerr$i");

        my $pid = fork();
        if (!defined $pid) {
            BAIL_OUT("AC10: fork() failed: $!");
        }
        if ($pid == 0) {
            local %ENV = %ENV;
            $ENV{CCPRAXIS_HOOK_PROBE_LOG} = $log;
            open(STDIN,  '<:raw', $stdin_file) or exit 90;
            open(STDOUT, '>:raw', $outp)       or exit 91;
            open(STDERR, '>:raw', $errp)       or exit 92;
            exec($^X, $PROBE);
            exit 93; # exec failed to replace the process image
        }
        push @pids, $pid;
    }
    for my $pid (@pids) {
        waitpid($pid, 0);
    }

    my $content = read_bytes($log) // '';
    my @lines = split /\n/, $content, -1;
    pop @lines if @lines && $lines[-1] eq '';

    is(scalar(@lines), $n, "AC10: exactly $n lines after $n parallel invocations (no interleaving, no lost writes)")
        or diag("got " . scalar(@lines) . " lines:\n$content");

    my %expected = map { $_ => 1 } @payloads;
    my %got      = map { $_ => 1 } @lines;
    is_deeply(\%got, \%expected,
        'AC10: the set of logged lines equals the set of payloads -- every line is intact and none is torn or duplicated');
}


# ===========================================================================
# AC11: registered nowhere. plugins/*/hooks/hooks.json and
# .claude/settings.json in the repo contain no occurrence of "bp-hook-probe".
# ===========================================================================
{
    my @hooks_json = glob("$ROOT/plugins/*/hooks/hooks.json");
    ok(scalar(@hooks_json) > 0,
        'AC11 precondition: at least one plugins/*/hooks/hooks.json was found (glob is not silently empty)');

    my @offenders;
    for my $f (@hooks_json, "$ROOT/.claude/settings.json") {
        next unless -f $f;
        my $src = read_bytes($f) // '';
        push @offenders, $f if $src =~ /bp-hook-probe/;
    }
    is_deeply(\@offenders, [],
        'AC11: no hooks.json and no .claude/settings.json mentions bp-hook-probe -- registered nowhere')
        or diag("mentions found in: @offenders");
}


# ===========================================================================
# AC12: arguments are ignored. An invocation with extra argv ("--foo bar")
# behaves exactly like AC2.
# ===========================================================================
{
    my $payload = '{"hook_event_name":"PreToolUse","session_id":"argv-case","tool_name":"Bash"}';
    my $stdin   = write_bytes(fixture_path('in'), $payload);
    my $log     = log_path('log.jsonl');

    my ($exit, $out, $err) = run_probe(
        stdin => $stdin, log => $log, argv => ['--foo', 'bar']);
    assert_silent($exit, $out, $err, 'AC12');

    is(read_bytes($log), $payload . "\n",
        'AC12: extra argv has no effect -- behaves exactly like AC2');
}

done_testing();
