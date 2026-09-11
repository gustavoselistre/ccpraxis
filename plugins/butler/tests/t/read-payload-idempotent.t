#!/usr/bin/env perl
# Oracle for making bp_read_payload (lib.sh:83) safe to call MORE THAN ONCE
# in the same hook process. Today it performs one BOUNDED `read -r -d ''
# -t TIMEOUT` straight into the global PAYLOAD on every bare call, with no
# memory of a prior call -- so a second call re-enters that read against an
# already-exhausted stdin.
#
# Every case here calls the shared shell function through a small bash
# harness (never sourced into this file's own perl process), so a
# still-broken hook body can only fail an assertion, never crash the
# harness. Every FIFO-writer-never-closes case is bounded by an outer
# alarm(), mirroring guard-git-mutations.sh's own bound-of-a-bound
# technique -- a test for a hang that can itself hang is worse than no test.
#
# AC-8   double bare call, clean EOF -- both leave PAYLOAD at the SAME,
#        correct decoded string
# AC-9   the SECOND call alone is fast (< 1s), with BP_PAYLOAD_READ_TIMEOUT
#        lowered so a real second `read` attempt would measurably exceed it
# AC-10  first call, mode=closed, stdin never closes -- still exit 2,
#        still says why
# AC-11  first call, mode=open, stdin never closes -- still exit 0, quietly
# AC-12  the lib.sh:43 subshell rule: a call INSIDE $(...) can only ever set
#        the flag in its OWN copy -- the parent's next bare call still
#        performs a genuine read
#
# Companion file: json-get-array-index.t (the other half of this package's
# two defects).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64 decode_base64);
use POSIX qw(WIFEXITED WEXITSTATUS);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $LIB = "$HOOKS/lib.sh";

ok(-f $LIB, 'lib.sh exists at plugins/butler/hooks/lib.sh') or BAIL_OUT('lib.sh missing');

my $BASH = 'bash';
my $have_bash = do {
    my $out = `$BASH -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

my $ROOT = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    binmode $fh;
    print {$fh} $content;
    close $fh;
    return $path;
}

sub b64_of { encode_base64($_[0], '') }

# ---------------------------------------------------------------------------
# Harness 1 -- DOUBLE bare call in ONE process, both reading the SAME stdin.
# Payload is transmitted via base64 (P1_B64/P2_B64) so the assertion cannot
# be fooled by whitespace/newline handling differences.
# ---------------------------------------------------------------------------
my $DOUBLE_RUNNER = "$ROOT/double-read.sh";
write_file($DOUBLE_RUNNER, <<'RUNNER');
#!/usr/bin/env bash
set -u
HOOK_DIR="$1"; shift
MODE1="$1"; shift
MODE2="$1"; shift
source "$HOOK_DIR/lib.sh" 2>/dev/null || { echo "SOURCE_FAIL"; exit 9; }

bp_read_payload "$MODE1"
RC1=$?
P1B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')

T0=$(date +%s%N)
bp_read_payload "$MODE2"
RC2=$?
T1=$(date +%s%N)
P2B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')

ELAPSED_MS=$(( (T1 - T0) / 1000000 ))

printf 'RC1=%s\n' "$RC1"
printf 'RC2=%s\n' "$RC2"
printf 'ELAPSED_MS=%s\n' "$ELAPSED_MS"
printf 'DONE_FLAG=%s\n' "${BP_PAYLOAD_READ_DONE:-<unset>}"
printf 'P1_B64=%s\n' "$P1B64"
printf 'P2_B64=%s\n' "$P2B64"
RUNNER
chmod 0755, $DOUBLE_RUNNER;

# run_double(payload_text, mode1, mode2, timeout_secs) -> \%fields, bounded
# by an outer alarm. Delivers the payload over a FIFO whose writer closes
# IMMEDIATELY after writing -- clean EOF, matching lib.sh:50-53's documented
# real-dispatch shape and AC-8's own fixture description.
my $fifo_n = 0;
sub run_double {
    my ($payload, $mode1, $mode2, $timeout, $wall) = @_;
    $wall //= 25;
    my $fifo = "$ROOT/double" . (++$fifo_n) . ".fifo";
    my $mk = system("mkfifo '$fifo' 2>/dev/null");
    return (undef, 'mkfifo unavailable') if $mk != 0 || !-p $fifo;

    my $writer = fork();
    return (undef, 'fork unavailable') unless defined $writer;
    if ($writer == 0) {
        open(my $wfh, '>', $fifo) or POSIX::_exit(127);
        print {$wfh} $payload;
        close $wfh;   # writer closes immediately after writing -- clean EOF
        POSIX::_exit(0);
    }

    my %env = %ENV;
    delete $env{BP_PAYLOAD_READ_TIMEOUT};
    $env{BP_PAYLOAD_READ_TIMEOUT} = $timeout if defined $timeout;

    # DO NOT waitpid the writer here: its `open(... '>', $fifo)` blocks until
    # a READER opens the other end, and no reader exists yet -- the wrapper
    # script (which redirects stdin from $fifo) has not been launched. Reap
    # the writer only AFTER the reader has run and finished.
    #
    # perl's list-form open (no shell) cannot express "< $fifo" -- reopen via
    # a tiny one-shot wrapper script instead of a hand-built -c STRING with
    # interpolated payload content, so no quoting of PAYLOAD is ever needed.
    my @result = _run_double_via_shell($fifo, $mode1, $mode2, \%env, $wall);
    waitpid($writer, 0);
    return @result;
}

# Actual execution: bash's own "< fifo" redirection, invoked through a
# one-shot wrapper script (never a hand-built -c STRING with interpolated
# payload content) so no quoting of PAYLOAD is ever needed.
sub _run_double_via_shell {
    my ($fifo, $mode1, $mode2, $env, $wall) = @_;
    my $wrapper = "$ROOT/double-wrap-$fifo_n.sh";
    write_file($wrapper, qq{#!/usr/bin/env bash\nexec "$DOUBLE_RUNNER" "$HOOKS" "$mode1" "$mode2" < "$fifo"\n});
    chmod 0755, $wrapper;

    my ($exit, $out) = (-1, '');
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        local %ENV = %$env;
        open(my $fh, '-|', $BASH, $wrapper) or die "bash: $!";
        $out = do { local $/; <$fh> };
        close $fh;
        $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1 };

    return (undef, 'wedged (alarm fired)') if $exit == -1 && (!defined $out || $out eq '');

    my %f;
    for my $line (split /\n/, $out // '') {
        if ($line =~ /^([A-Z0-9_]+)=(.*)$/) { $f{$1} = $2; }
    }
    $f{_exit} = $exit;
    return (\%f, undef);
}

# ===========================================================================
# AC-8 (DC3) -- double bare call, clean EOF: both calls leave PAYLOAD at the
# SAME, correct decoded string.
# ===========================================================================
{
    my $payload = '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"extra":"idempotence-fixture-8"}';
    my ($f, $err) = run_double($payload, 'open', 'open', undef, 25);
    SKIP: {
        skip "AC-8 fixture unavailable: $err", 5 unless defined $f;
        is($f->{_exit}, 0, 'AC-8: the harness process itself exits cleanly (neither call denies/wedges)');
        is($f->{RC1}, 0, 'AC-8: first bare call: exit 0');
        is(decode_base64($f->{P1_B64} // ''), $payload,
           'AC-8: first bare call: PAYLOAD is the real, correctly decoded payload');
        is($f->{RC2}, 0, 'AC-8: second bare call: exit 0 (idempotent, not a denial)');
        is(decode_base64($f->{P2_B64} // ''), $payload,
           'AC-8 CANONICAL: second bare call: PAYLOAD is the SAME correct string as the first call -- '
         . 'no second read is attempted, so nothing can clobber it');
    }
}

# ===========================================================================
# AC-9 (DC3) -- the SECOND call alone completes in comfortably under 1
# second. BP_PAYLOAD_READ_TIMEOUT is lowered to 2s for this case specifically
# (spec's own prescribed technique) so that a regression -- a real second
# `read -t` being attempted against an already-exhausted stdin -- would
# measurably exceed the 1s bound, rather than the assertion only restating
# the literal wording.
# ===========================================================================
{
    my $payload = '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"extra":"idempotence-fixture-9"}';
    my ($f, $err) = run_double($payload, 'open', 'open', 2, 25);
    SKIP: {
        skip "AC-9 fixture unavailable: $err", 1 unless defined $f;
        my $ms = $f->{ELAPSED_MS};
        ok(defined $ms && $ms =~ /^-?\d+$/, 'AC-9 fixture sanity: an elapsed-ms figure for the second call was captured')
            or diag("harness fields: " . join(',', map {"$_=$f->{$_}"} sort keys %$f));
        cmp_ok($ms, '<', 1000,
            sprintf('AC-9 CANONICAL: the SECOND bare call completes in under 1000ms (measured %sms, BP_PAYLOAD_READ_TIMEOUT=2s) -- '
                  . 'no second read is attempted at all', $ms // '?'));
    }
}

# ===========================================================================
# AC-10 / AC-11 (DC4) -- FIRST call, stdin NEVER closes (a writer that opens
# the FIFO and never writes/closes). Fail-closed (mode=closed) and fail-open
# (mode=open) on a genuine, in-progress read must be UNCHANGED from today.
# Mirrors hook-payload-read-bound.t's own AC4 technique exactly.
# ===========================================================================
my $SINGLE_RUNNER = "$ROOT/single-read.sh";
write_file($SINGLE_RUNNER, <<'RUNNER');
#!/usr/bin/env bash
set -u
HOOK_DIR="$1"; shift
MODE="$1"; shift
source "$HOOK_DIR/lib.sh" 2>/dev/null || { echo "SOURCE_FAIL"; exit 9; }
bp_read_payload "$MODE"
rc=$?
printf 'RC=%s\n' "$rc"
exit "$rc"
RUNNER
chmod 0755, $SINGLE_RUNNER;

sub run_single_stalled {
    my ($mode, $read_timeout, $wall) = @_;
    $wall //= 25;
    my $fifo = "$ROOT/stall" . (++$fifo_n) . ".fifo";
    my $mk = system("mkfifo '$fifo' 2>/dev/null");
    return (-1, '', 'mkfifo unavailable') if $mk != 0 || !-p $fifo;

    my $writer = fork();
    return (-1, '', 'fork unavailable') unless defined $writer;
    if ($writer == 0) {
        exec($BASH, '-c', "sleep 60 > '$fifo'");
        exit 127;   # exec() only returns on failure; matches hook-payload-read-bound.t's own fallback
    }

    # 2>&1 at the bash level: stderr is where the timeout message actually
    # goes (lib.sh's own `echo ... >&2`), and perl's list-form '-|' open
    # captures only stdout unless the child merges it itself.
    my $wrapper = "$ROOT/single-wrap-$fifo_n.sh";
    write_file($wrapper, qq{#!/usr/bin/env bash\nexec "$SINGLE_RUNNER" "$HOOKS" "$mode" < "$fifo" 2>&1\n});
    chmod 0755, $wrapper;

    my %env = %ENV;
    $env{BP_PAYLOAD_READ_TIMEOUT} = $read_timeout if defined $read_timeout;

    my ($exit, $out) = (-1, '');
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        local %ENV = %env;
        open(my $fh, '-|', $BASH, $wrapper) or die "bash: $!";
        $out = do { local $/; <$fh> };
        close $fh;
        $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1 };

    kill 'TERM', $writer;
    waitpid($writer, 0);
    return ($exit, defined $out ? $out : '', undef);
}

{
    my ($exit, $out, $err) = run_single_stalled('closed', 2, 25);
    SKIP: {
        skip "AC-10 fixture unavailable: $err", 3 if defined $err;
        isnt($exit, -1, 'AC-10: the hook RETURNS when stdin never closes (does not block forever)');
        is($exit, 2, 'AC-10 CANONICAL: first call, mode=closed, timeout -> exit 2 (fail-closed, unchanged)');
        like($out, qr/did not arrive within/, 'AC-10: ...and says why, unchanged');
    }
}

{
    my ($exit, $out, $err) = run_single_stalled('open', 2, 25);
    SKIP: {
        skip "AC-11 fixture unavailable: $err", 2 if defined $err;
        isnt($exit, -1, 'AC-11: the hook RETURNS when stdin never closes (does not block forever)');
        is($exit, 0, 'AC-11 CANONICAL: first call, mode=open, timeout -> exit 0 (fail-open, unchanged)');
    }
}

# ===========================================================================
# AC-12 (DC5) -- the lib.sh:43 subshell rule, for the NEW idempotence flag
# specifically. A call INSIDE $(...) (the deliberately-forbidden form) can
# only ever set BP_PAYLOAD_READ_DONE=1 in that subshell's OWN copy. The
# parent's NEXT bare call, against a SECOND independent payload, must still
# perform a genuine read and return that second payload's real content --
# not empty, not the first payload's content, and not a short-circuited
# "already done".
# ===========================================================================
my $SUBSHELL_RUNNER = "$ROOT/subshell-then-bare.sh";
write_file($SUBSHELL_RUNNER, <<'RUNNER');
#!/usr/bin/env bash
set -u
HOOK_DIR="$1"; shift
FIFO_A="$1"; shift
FIFO_B="$1"; shift
source "$HOOK_DIR/lib.sh" 2>/dev/null || { echo "SOURCE_FAIL"; exit 9; }

# THE FORBIDDEN FORM, deliberately, to prove the flag's containment.
SUBOUT=$( (bp_read_payload open) < "$FIFO_A" )
SUB_RC=$?

# The parent's bare call -- against a SECOND, independent payload.
bp_read_payload open < "$FIFO_B"
RC2=$?
P2B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')

printf 'SUB_RC=%s\n' "$SUB_RC"
printf 'RC2=%s\n' "$RC2"
printf 'PARENT_DONE_FLAG=%s\n' "${BP_PAYLOAD_READ_DONE:-<unset>}"
printf 'P2_B64=%s\n' "$P2B64"
RUNNER
chmod 0755, $SUBSHELL_RUNNER;

{
    my $payload_a = '{"marker":"FIRST-inside-the-forbidden-subshell-form"}';
    my $payload_b = '{"marker":"SECOND-the-parents-own-bare-call","extra":"idempotence-fixture-12"}';

    my $fifo_a = "$ROOT/sub-a.fifo";
    my $fifo_b = "$ROOT/sub-b.fifo";
    my $mk_a = system("mkfifo '$fifo_a' 2>/dev/null");
    my $mk_b = system("mkfifo '$fifo_b' 2>/dev/null");

  SKIP: {
        skip 'mkfifo unavailable on this host -- AC-12 cannot be built', 4
            if $mk_a != 0 || !-p $fifo_a || $mk_b != 0 || !-p $fifo_b;

        my $writer_a = fork();
        skip('fork unavailable', 4) unless defined $writer_a;
        if ($writer_a == 0) {
            open(my $wfh, '>', $fifo_a) or POSIX::_exit(127);
            print {$wfh} $payload_a;
            close $wfh;
            POSIX::_exit(0);
        }
        my $writer_b = fork();
        if (!defined $writer_b) { kill 'TERM', $writer_a; waitpid($writer_a, 0); skip('fork unavailable', 4); }
        if ($writer_b == 0) {
            open(my $wfh, '>', $fifo_b) or POSIX::_exit(127);
            print {$wfh} $payload_b;
            close $wfh;
            POSIX::_exit(0);
        }

        my ($exit, $out) = (-1, '');
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm 25;
            open(my $fh, '-|', $BASH, $SUBSHELL_RUNNER, $HOOKS, $fifo_a, $fifo_b) or die "bash: $!";
            $out = do { local $/; <$fh> };
            close $fh;
            $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
            alarm 0;
            1;
        } or do { alarm 0; $exit = -1 };

        waitpid($writer_a, 0);
        waitpid($writer_b, 0);

        my %f;
        for my $line (split /\n/, $out // '') {
            if ($line =~ /^([A-Z0-9_]+)=(.*)$/) { $f{$1} = $2; }
        }

        isnt($exit, -1, 'AC-12 fixture sanity: the harness process returns (does not wedge)');
        is($f{RC2}, 0, 'AC-12: the parent\'s bare call succeeds');
        is($f{PARENT_DONE_FLAG}, 1, 'AC-12: the parent DID perform its own, real read -- BP_PAYLOAD_READ_DONE is 1 in the PARENT');
        is(decode_base64($f{P2_B64} // ''), $payload_b,
           'AC-12 CANONICAL: the parent\'s bare call returns the SECOND payload\'s real content -- not empty, not the '
         . 'first (subshell) payload, and not short-circuited by the subshell\'s own copy of the flag');
    }
}

# ===========================================================================
# fix-batch FIX 3 -- BP_PAYLOAD_READ_DONE pre-set in the INHERITED environment
# (never by this process's own bp_read_payload) must NOT skip the real read.
# A flag of 1 with PAYLOAD unset is self-evidently not a completed read in
# THIS process -- a real completed read always sets PAYLOAD (even to "")
# before setting the flag. This is not reachable via crafted JSON tool-call
# content, only via control of the hook's process environment -- but it is
# the exact silent-permit shape this package exists to remove.
# ===========================================================================
{
    my $preset_runner = "$ROOT/preset-done-flag.sh";
    write_file($preset_runner, <<'RUNNER');
#!/usr/bin/env bash
set -u
HOOK_DIR="$1"; shift
source "$HOOK_DIR/lib.sh" 2>/dev/null || { echo "SOURCE_FAIL"; exit 9; }
bp_read_payload open
rc=$?
PB64=$(printf '%s' "${PAYLOAD:-}" | base64 | tr -d '\n')
printf 'RC=%s\n' "$rc"
printf 'P_B64=%s\n' "$PB64"
RUNNER
    chmod 0755, $preset_runner;

    my $payload = '{"marker":"fix3-preset-done-flag-must-not-skip-the-real-read","extra":"forced-env-flag"}';
    my $pf = "$ROOT/fix3-payload.json";
    write_file($pf, $payload);

    my $wrapper = "$ROOT/fix3-wrap.sh";
    write_file($wrapper, qq{#!/usr/bin/env bash\nexec "$preset_runner" "$HOOKS" < "$pf"\n});
    chmod 0755, $wrapper;

    my %env = %ENV;
    # Pre-set in the INHERITED environment -- exactly what a stray `export
    # BP_PAYLOAD_READ_DONE=1` left on from a debugging session, or any future
    # orchestration that copies %ENV wholesale, would do. PAYLOAD is
    # deliberately never set here: the whole point is that this flag alone
    # must not be trusted.
    $env{BP_PAYLOAD_READ_DONE} = 1;

    my ($exit, $out) = (-1, '');
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 25;
        local %ENV = %env;
        open(my $fh, '-|', $BASH, $wrapper) or die "bash: $!";
        $out = do { local $/; <$fh> };
        close $fh;
        $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1 };

    my %f;
    for my $line (split /\n/, $out // '') {
        if ($line =~ /^([A-Z0-9_]+)=(.*)$/) { $f{$1} = $2; }
    }

    isnt($exit, -1, 'FIX3 fixture sanity: the harness process returns (does not wedge)');
    is($f{RC}, 0, 'FIX3: bp_read_payload succeeds even with a pre-set (inherited) BP_PAYLOAD_READ_DONE=1');
    is(decode_base64($f{P_B64} // ''), $payload,
       'FIX3 CANONICAL: a pre-set BP_PAYLOAD_READ_DONE=1 with PAYLOAD unset did NOT skip the read -- '
     . 'PAYLOAD holds the real stdin content, not empty and not unset');
}

done_testing();
