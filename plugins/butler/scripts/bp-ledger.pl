#!/usr/bin/env perl
# bp-ledger.pl — the deterministic ledger API (b13-deterministic-ledger-api).
#
# Five typed, surgical mutation ops on a package ledger (set-status, append-attempt,
# tick-step, set-next-action, add-output) plus a `validate` subcommand that runs the
# same V1-V5 byte-oriented rule set ledger-guard.sh (b12) enforces. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b13-deterministic-ledger-api-spec.md
#
# Plus a sixth op, `rotate` (b45-ledger-context-budget), which moves stale
# `## Decisions & attempt log` entries out to reports/ledger-history/<pkg>.md so the
# ledger stays inside a context budget. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b45-ledger-context-budget-spec.md
#
# Exit codes (an interface, fixed): 0 success, 2 validation rejection (byte-identical
# file), 3 usage/argument error (nothing read), 4 I/O/lock/atomicity failure
# (byte-identical), 5 target region not found (byte-identical).
#
# stdout is ALWAYS empty, EXCEPT `rotate --dry-run` and `claim-check`, both of which
# are report-only ops (b45 §3; 08-completion-claims-checked-spec.md §2.6) that print
# their report to stdout while touching nothing. stderr on any
# non-zero exit is EXACTLY ONE line. `append-attempt` may ALSO print one budget-notice
# line to stderr on an otherwise-successful (exit 0) run — see DEFAULT_BUDGET_BYTES
# below; that is not a rejection, just visibility, and the append still happens.
# `rotate` may likewise print one LEDGER_IRREDUCIBLE notice to stderr on an otherwise-
# successful (exit 0) run when it determines the ledger cannot be reduced further
# (a03-ledger-budget-irreducible spec §2.1/§2.5) — same non-error notice shape, same
# one-line discipline.
#
# Core Perl only: strict, warnings, Getopt::Long, Fcntl(:flock), JSON::PP, B. No
# other module may be loaded on any path (latency constraint, §2.5).
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use Fcntl qw(:flock);
use JSON::PP ();
use B ();

my $EMDASH = "\xE2\x80\x94";

# b45-ledger-context-budget-spec.md §4: a single named constant, ~10k tokens at this
# repo's ~4 bytes/token estimate. `rotate --budget` may override it for that one call;
# `append-attempt`'s warning always measures against this default (no CLI override
# there — the warning is visibility, not policy).
use constant DEFAULT_BUDGET_BYTES => 40000;

# =====================================================================================
# Oracle identity (08-completion-claims-checked) — constants (spec §2.1, exact names).
# =====================================================================================
use constant ORACLE_SECTION_HEADING   => '## Oracle identity';
use constant ORACLE_LINE_PREFIX       => '- oracle ';   # note the single trailing space
use constant ORACLE_DESCRIPTION_CAP   => 300;           # descriptions[] omitted above this
use constant ORACLE_DEFAULT_TIMEOUT_S => 300;
our @ORACLE_RECORDED_STEPS = (3, 5);
our @PIPELINE_CONDITIONAL_STEPS = (8);

# The default test-run implementation (spec §2.2). Test-only in-process seam: a caller
# may override $main::ORACLE_RUN_FN entirely (e.g. to `die`, simulating an unrecoverable
# derivation failure — AC-12). Never loaded/used outside tick-step --step 3|5.
#
# Uses a real fork ('-|' open with no LIST — MSYS2/Git-for-Windows perl supports genuine
# fork/exec, unlike native Win32 perl) plus a select()-based polling read loop for the
# timeout, deliberately NOT alarm(): measured on this host, alarm's SIGALRM does not
# reliably interrupt a blocking read on a forked pipe here, so a select() with an
# explicit per-iteration timeout (which needs no signal delivery at all) is what
# actually bounds the wait. On timeout the child is killed outright (best-effort; see
# spec §5's named residual risk).
our $ORACLE_RUN_FN = sub {
    my ($test_path, $timeout_s) = @_;
    $timeout_s = ORACLE_DEFAULT_TIMEOUT_S unless defined $timeout_s && $timeout_s > 0;
    my $interp = (defined $ENV{BP_ORACLE_RUN_CMD} && length $ENV{BP_ORACLE_RUN_CMD})
        ? $ENV{BP_ORACLE_RUN_CMD} : $^X;

    my $pid = open(my $fh, '-|');
    die "ORACLE_SPAWN_FAIL\n" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&STDOUT');
        exec($interp, $test_path) or exit(126);
    }

    my $out = '';
    my $deadline = time() + $timeout_s;
    my $timed_out = 0;
    while (1) {
        my $remaining = $deadline - time();
        if ($remaining <= 0) { $timed_out = 1; last }
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        my $wait = $remaining > 1 ? 1 : $remaining;
        my $nfound = select($rin, undef, undef, $wait);
        if ($nfound && $nfound > 0) {
            my $buf;
            my $n = sysread($fh, $buf, 65536);
            last unless defined $n && $n > 0;   # EOF or read error -> child is done
            $out .= $buf;
        }
    }

    if ($timed_out) {
        eval { kill('KILL', $pid) };
        eval { waitpid($pid, 0) };
        eval { close($fh) };
        die "ORACLE_TIMEOUT\n";
    }

    close($fh);
    waitpid($pid, 0);
    my $exit_code = defined $? ? ($? >> 8) : undef;
    return ($out, $exit_code);
};

# The injected-rename seam (bp-token-keeper.pl's `rename_fn` shape). When
# BP_LEDGER_FAIL_RENAME is set and non-empty, simulate a mid-write rename failure
# without touching the filesystem — the only test-only environment hook here.
my $RENAME_FN = sub { return rename($_[0], $_[1]) };
if (defined $ENV{BP_LEDGER_FAIL_RENAME} && length($ENV{BP_LEDGER_FAIL_RENAME})) {
    $RENAME_FN = sub { return 0 };
}

# =====================================================================================
# stderr / exit helpers — one line, one framing convention: `bp-ledger: <sub>: ...`
# =====================================================================================

sub emit_err {
    my ($m) = @_;
    $m =~ s/[\r\n]+/ /g;
    print STDERR $m . "\n";
}

sub arg_error      { my ($sub, $msg)          = @_; emit_err("bp-ledger: $sub: $msg"); exit 3 }
sub io_error       { my ($sub, $path, $msg)   = @_; emit_err("bp-ledger: $sub: $path: $msg"); exit 4 }
sub reject_error   { my ($sub, $path, $detail)= @_; emit_err("bp-ledger: $sub: $path: $detail"); exit 2 }
sub notfound_error { my ($sub, $path, $msg)   = @_; emit_err("bp-ledger: $sub: $path: $msg"); exit 5 }

# A NOTICE is a state of the ledger, never an outcome of the call (a03 spec §2.1): it
# must NOT reuse the `bp-ledger: <sub>: <path>: <msg>` shape the four error helpers
# above emit (that shape is indistinguishable from a real rejection), and it must carry
# a stable, greppable, machine-readable TOKEN right after the op prefix (spec §2.2) so a
# caller can tell the three budget outcomes apart without parsing English. Exit code is
# whatever the caller was already going to exit with (0, always, for a notice) — this
# never calls exit itself.
sub emit_notice {
    my ($sub, $token, $msg) = @_;
    $msg =~ s/[\r\n]+/ /g;
    print STDERR "bp-ledger: $sub: $token: $msg\n";
}

# =====================================================================================
# Budget-notice marker (a03 spec §2.1) — cross-process suppression for the ONE-TIME
# "this ledger is irreducible" fact. A sidecar file next to the ledger, so it survives
# across processes (a per-process flag is explicitly NOT acceptable — each bp-ledger.pl
# invocation is a fresh process). `rotate` writes it when it determines irreducibility
# and clears it the moment a rotate finds the ledger reducible again; `append-attempt`
# clears it the moment the ledger is genuinely back under budget. Either clearing means
# the NEXT over-budget notice starts fresh, so suppression can never go stale (spec's
# own bullet: "stale suppression is a worse defect than the noise it replaces").
# =====================================================================================

sub budget_marker_path { return "$_[0].budget-state" }

# Trust window for a "notified, stop repeating" marker (red-team step6 MAJOR-1): the
# sidecar lives in the same directory as the ledger, outside ledger-guard.sh's
# `packages/*.md` glob, so anything with ordinary write access to that directory can
# plant one without ever running a genuine `rotate`. This file cannot cheaply re-derive
# rotate's own floor/forced-entry computation to *prove* a marker's claim, so instead it
# bounds how long a "notified" marker is trusted before append-attempt re-asserts the
# notice regardless of what the marker says. A forged or stale marker therefore fails
# toward NOISY, never toward permanently silent -- the worst a forgery/staleness can do
# is delay one re-notification by at most this many seconds, not suppress forever.
# Override for tests only (mirrors the BP_LEDGER_FAIL_RENAME test-only seam above).
my $BUDGET_MARKER_TTL_SECONDS = 3600;
if (defined $ENV{BP_LEDGER_BUDGET_MARKER_TTL} && $ENV{BP_LEDGER_BUDGET_MARKER_TTL} =~ /^\d+$/) {
    $BUDGET_MARKER_TTL_SECONDS = $ENV{BP_LEDGER_BUDGET_MARKER_TTL};
}

# Deliberately a plain truncate-and-write, not the tmp+rename+read-back ceremony the
# ledger/history writes use elsewhere in this file (reviewer step6 MINOR): the marker is
# a single short advisory line, its own worst-case torn-read is "treat it as absent/
# stale and re-notify" (see budget_marker_fresh above), which is already the fail-safe
# this file wants -- the ceremony would add real complexity for no correctness gain here.
sub mark_irreducible {
    my ($ledger) = @_;
    open(my $fh, '>', budget_marker_path($ledger)) or return;
    print {$fh} "irreducible pending " . time() . "\n";
    close $fh;
}

sub mark_irreducible_notified {
    my ($ledger) = @_;
    open(my $fh, '>', budget_marker_path($ledger)) or return;
    print {$fh} "irreducible notified " . time() . "\n";
    close $fh;
}

sub clear_budget_marker {
    my ($ledger) = @_;
    my $p = budget_marker_path($ledger);
    unlink $p if -e $p;
}

sub read_budget_marker {
    my ($ledger) = @_;
    my $p = budget_marker_path($ledger);
    return undef unless -e $p;
    open(my $fh, '<', $p) or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    chomp $line;
    my ($state, $flag, $ts) = split(' ', $line);
    return undef unless defined $state;
    return { state => $state, flag => ($flag // ''), ts => $ts };
}

# Was this marker's "notified" claim stamped recently enough (by a real bp-ledger.pl
# process, in the past, within the trust window) to still be honoured? A missing,
# non-numeric, or future timestamp is exactly what a hand-planted forgery looks like
# (the demonstrated attack wrote no timestamp at all) -- treat any of those as already
# expired rather than trusting them, so the fail-safe direction is always toward noise.
sub budget_marker_fresh {
    my ($ts) = @_;
    return 0 unless defined $ts && $ts =~ /^\d+$/;
    my $now = time();
    return 0 if $ts > $now;
    return ($now - $ts) < $BUDGET_MARKER_TTL_SECONDS;
}

sub iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# =====================================================================================
# last_updated VALUE integrity (b19-ledger-timestamp-integrity) — an AUDIT-TRAIL check,
# not a run-control one (bp-status.sh uses mtime; gate-stop.sh and the watchdog never
# parse this field at all, per the spec's own retracted impact claim). ONE
# implementation, enforced at BOTH this API (below) and the b12 hook, which `require`s
# THIS FILE rather than reimplementing the check — two copies would drift, and the
# failure mode is specific and nasty: a sanctioned API write the guard then rejects,
# leaving a coordinator with no legal move at all.
# =====================================================================================

# Ordinary container/host clock skew is seconds to low single-digit minutes, while the
# defect this check exists to catch was observed at 25-55 minutes, once ~1 hour. 300s
# sits an order of magnitude above normal skew and an order of magnitude below the
# smallest observed defect, so neither bound is close. Verified against the full real
# ledger corpus at this value (0 of it is future-dated beyond 300s).
use constant LEDGER_FUTURE_SKEW_S => 300;

# Pull the last_updated: VALUE out of a frontmatter block, byte-wise, exactly as V3
# above locates keys. Returns undef if there is no parseable frontmatter or no such key
# (both cases are V3's job to reject; this function is silent about it).
sub extract_last_updated {
    my ($B) = @_;
    return undef unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my $FM = $1;
    for my $l (split(/\n/, $FM, -1)) {
        if ($l =~ /^last_updated:\s*(.*?)\s*$/) { return $1 }
    }
    return undef;
}

# Core-Perl-only (§2.5 forbids adding Time::Local to the allowed-module list): epoch
# seconds (UTC) from a strict `YYYY-MM-DDTHH:MM:SSZ` stamp, via Howard Hinnant's
# civil_from_days day-counting algorithm. Returns undef on anything not exactly that
# shape or out of range — deliberately lenient: a malformed VALUE is not this check's
# job (V1-V5 above police shape; this function only ever compares two valid stamps).
sub epoch_from_iso {
    my ($s) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    my ($Y, $Mo, $D, $H, $Mi, $S) = (int($1), int($2), int($3), int($4), int($5), int($6));
    return undef if $Mo < 1 || $Mo > 12 || $D < 1 || $D > 31 || $H > 23 || $Mi > 59 || $S > 60;
    my $y = $Y;
    $y-- if $Mo <= 2;
    my $era = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe = $y - $era * 400;                                       # [0, 399]
    my $mp  = ($Mo + 9) % 12;                                        # Mar=0 .. Feb=11
    my $doy = int((153 * $mp + 2) / 5) + $D - 1;                     # [0, 365]
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;   # [0, 146096]
    my $days = $era * 146097 + $doe - 719468;                        # days since 1970-01-01
    return $days * 86400 + $H * 3600 + $Mi * 60 + $S;
}

# THE check (spec §2). $old_bytes may be undef (nothing on disk to compare against —
# e.g. a fresh Write, or the static `validate --stdin`/`--ledger` surfaces, which
# validate one buffer with no notion of a prior write at all). Returns undef (fine) or
# a one-sentence DETAIL FRAGMENT in the same no-framing-prefix convention as
# validate_bytes above.
sub last_updated_check {
    my ($old_bytes, $new_bytes) = @_;

    my $new_val = extract_last_updated($new_bytes);
    return undef unless defined $new_val;
    my $new_ep = epoch_from_iso($new_val);
    return undef unless defined $new_ep;

    my $now = time;
    if (($new_ep - $now) > LEDGER_FUTURE_SKEW_S) {
        return sprintf(
            'has a last_updated: value that is more than %d seconds ahead of the current time (%s): '
          . '%s. Clock skew this large is rejected so a coordinator with a wrong clock can correct rather than guess.',
            LEDGER_FUTURE_SKEW_S, iso_now(), $new_val);
    }

    if (defined $old_bytes) {
        my $old_val = extract_last_updated($old_bytes);
        if (defined $old_val) {
            my $old_ep = epoch_from_iso($old_val);
            if (defined $old_ep && $new_ep < $old_ep) {
                return sprintf(
                    'has a last_updated: value (%s) OLDER than the value currently on disk (%s); '
                  . 'a write must never move last_updated: backward (an equal, same-second value is permitted).',
                    $new_val, $old_val);
            }
        }
    }

    return undef;
}

# =====================================================================================
# The validation core — V1..V5, normative (spec §2.4). First failing class wins.
# Returns undef (valid) or a one-sentence DETAIL FRAGMENT (no framing prefix — the two
# framings differ only in prefix, per §2.2 / AC-30).
# =====================================================================================

my @REQUIRED_KEYS = qw(package blueprint status write_set last_updated);
# `dropped` added 2026-08-13, the THIRD home of the same defect (07d28a2 fixed
# bp-blueprint.pl, 8cc98d8 fixed ledger-guard.sh and gate-stop.sh). This is the
# sanctioned WRITER of package ledgers, so without it a coordinator that
# legitimately dropped its package could not record that through the typed API
# at all -- while bp-drive-next.pl and bp-orchestrator.pl both read the field and
# call `dropped` terminal. Filed as 2026-08-06 batch2 #12.
#
# `converging` belongs here and NOT in bp-blueprint.pl's vocabulary: this is the
# package ledger's mid-flight value, which the blueprint.md summary table has no
# use for. Two vocabularies on purpose -- do not "unify" them.
my @STATUSES      = qw(pending running converging reviewing done blocked parked dropped);

# A STRINGIFIED PERL REFERENCE IN A LEDGER BODY IS NEVER INTENTIONAL.
#
# Observed on a live run (almanac 20260915-191939-da6e): a package's Escalation
# section ended
#
#     ...or adding the boolean fallback.SCALAR(0x5c7bd4bd3308)
#
# welded onto the last sentence with no separator. A writer interpolated a ref
# where it meant the referent, so whatever that text WAS is gone -- not
# mis-rendered, lost -- and nothing refused the write, because the section still
# parses as prose. The Escalation section is exactly what the orchestrator and
# the reporter read to decide what a blocked package needs.
#
# WHY THIS IS NOT PART OF validate_bytes. run_op validates the ORIGINAL bytes as
# well as the new ones, and a ledger that already carries this corruption would
# then reject every subsequent operation -- bricking the package this rule exists
# to protect. So the check is DIFFERENTIAL: it fires only when an operation
# INTRODUCES a ref address that was not already there. Existing damage stays
# operable and repairable; new damage cannot get in.
#
# Blessed refs stringify as Foo=HASH(0x...), so the optional class prefix is
# matched too.
my $REF_ADDR_RE = qr/(?:\w+=)?(?:SCALAR|ARRAY|HASH|CODE|REF|GLOB|Regexp|FORMAT|LVALUE|IO)\(0x[0-9a-fA-F]+\)/;

sub count_ref_addrs {
    my ($B) = @_;
    return 0 unless defined $B && length $B;
    my $n = 0;
    $n++ while $B =~ /$REF_ADDR_RE/g;
    return $n;
}

# validate_no_new_ref_addr($orig, $new) -> $detail | undef
sub validate_no_new_ref_addr {
    my ($orig, $new) = @_;
    my $before = count_ref_addrs($orig);
    my $after  = count_ref_addrs($new);
    return undef if $after <= $before;
    my ($sample) = ($new =~ /($REF_ADDR_RE)/);
    return 'would write a stringified Perl reference into the ledger body ('
         . (defined $sample ? $sample : 'ref address')
         . '). That is always a writer bug -- the value it points at is being '
         . 'LOST, not merely mis-rendered. Dereference it before writing.';
}

sub validate_bytes {
    my ($B) = @_;

    # V1 — control byte. Exempt \t \n \r. C1 (0x80-0x9F) is NOT rejected.
    if ($B =~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/) {
        my $off  = $-[1];
        my $byte = ord($1);
        my $pre  = substr($B, 0, $off);
        my $line = 1 + ($pre =~ tr/\n//);
        return sprintf('contains a control byte 0x%02X at line %d.', $byte, $line);
    }

    # V2 — frontmatter block, \A-anchored, non-greedy.
    my ($FM) = $B =~ /\A---\s*\n(.*?)\n---/s;
    unless (defined $FM) {
        return 'has no parseable frontmatter block: it must begin at byte 0 with a line '
             . '"---" and be closed by a later line "---".';
    }
    my @FML = split(/\n/, $FM, -1);

    # V3 — required frontmatter keys, matched line-wise inside the FM block only.
    my @missing;
    for my $k (@REQUIRED_KEYS) {
        my $found = 0;
        for my $l (@FML) { if ($l =~ /^\Q$k\E:\s*(.*?)\s*$/) { $found = 1; last } }
        push @missing, $k unless $found;
    }
    if (@missing) {
        return 'is missing required frontmatter key(s): ' . join(', ', @missing) . '.';
    }

    # V4 — status value. The FIRST status: line wins.
    my $status;
    for my $l (@FML) { if ($l =~ /^status:\s*(.*?)\s*$/) { $status = $1; last } }
    $status = '' unless defined $status;
    unless (grep { $_ eq $status } @STATUSES) {
        return 'frontmatter status: "' . $status . '" is not a protocol status. Allowed: '
             . join(', ', @STATUSES) . '.';
    }

    # V4a — write_set: must not be EMPTY.
    #
    # Bug 20260916-180317-71de: a ledger was rewritten to a 727-byte stub with a
    # bare `write_set:` and nothing after it, losing test_paths, checks,
    # max_turns, effort, Inputs, Constraints and most of Scope. It passed
    # validation, because @REQUIRED_KEYS checks a key is PRESENT, never that it
    # carries a value.
    #
    # AN EMPTY WRITE SET IS NOT A DEGRADED STATE, IT IS A DEAD ONE. guard-writes
    # permits nothing, so the package cannot write a single file -- it would
    # relaunch, be unable to touch its own deliverables, and block again, with no
    # field left to explain why.
    #
    # The rule already existed and was enforced in the wrong place: bp-auditor's
    # DAG-integrity list says in as many words "no package declares an empty
    # `write_set`". That is an authoring-time check by an agent. This is the
    # sanctioned WRITER, and a writer that accepts a state its own auditor
    # forbids is how the stub reached disk. Same shape as V4b below, which was
    # added for the same reason an hour earlier.
    #
    # Verified before shipping: every ledger in the tree, active and archived,
    # carries a non-empty write_set, so this rejects nothing that exists.
    # THE FIELD HAS TWO LEGAL FORMS, and the first draft of these rules knew only
    # one. A colon-delimited scalar (`write_set: a/b.pm:c/d.t`) is what every
    # ledger in this tree uses -- and a YAML-ish list is ALSO accepted:
    #
    #   write_set:
    #     - plugins/butler/scripts/bp-ledger.pl
    #
    # ledger-api.t's own canonical fixture uses the list form. Validating the
    # scalar-only rules against "every ledger in the tree" missed this entirely,
    # because the tree happens to use one form and the oracle uses the other --
    # 100 assertions went red the moment the rules ran against it. A check
    # written against the data you have, rather than the format you accept, is a
    # check that passes until someone uses the other half of the contract.
    my $field_segments = sub {
        my ($field) = @_;
        my ($i, $scalar) = (-1, undef);
        for my $n (0 .. $#FML) {
            if ($FML[$n] =~ /^\Q$field\E:\s*(.*?)\s*$/) { $i = $n; $scalar = $1; last }
        }
        return (undef, ()) if $i < 0;
        my @items;
        for my $n ($i + 1 .. $#FML) {
            last unless $FML[$n] =~ /^\s+-\s*(.*?)\s*$/;
            push @items, $1 if length $1;
        }
        return ($scalar, @items);
    };

    {
        my ($ws, @items) = $field_segments->('write_set');
        if (defined $ws && $ws eq '' && !@items) {
            return 'frontmatter write_set: is EMPTY. A package whose write set permits nothing '
                 . 'cannot edit its own deliverables -- it would relaunch, write nothing, and block '
                 . 'again with no field left to explain why. This is the shape a truncated ledger '
                 . 'takes (report 20260916-180317-71de); if the package genuinely owns no files, it '
                 . 'should not be a package.';
        }
    }

    # V4b — write_set:/test_paths: segments must be PATHS, not prose.
    #
    # Bug 20260916-175013-34af. These fields are a single COLON-DELIMITED string,
    # exported verbatim into BP_WRITE_SET by bp-launch.sh and split on ':' by
    # guard-writes.sh. An author who annotates the field in prose --
    #
    #   write_set: a/b.pm:c/d.t:e/f.pl — in scope for ONE thing only: the entry point
    #
    # -- produces FOUR patterns instead of three, and the third is
    # "e/f.pl — in scope for ONE thing only", which matches no file on disk. The
    # bare path `e/f.pl` is then NOT IN THE WRITE SET AT ALL, and the package
    # cannot edit a file its own blueprint mandates in three places. Measured:
    # `match_any "scripts/fleet-orchestrator.pl" "$BP_WRITE_SET"` -> NOMATCH.
    #
    # WHY IT MUST BE CAUGHT HERE AND NOT LATER. Nothing re-derives BP_WRITE_SET
    # mid-session -- guard-writes.sh reads only the env var -- so the corrupt
    # value is fixed for the session's lifetime and no in-session ledger repair
    # unblocks the running coordinator. A relaunch is the only recovery. The
    # field is malformed AT REST and every layer below faithfully propagates it,
    # so the only place to stop it is where the ledger is written.
    #
    # The test is whitespace. The FIRST justification written here was that "a
    # path with a space is already unrepresentable in a colon-delimited list, so
    # this forbids nothing that previously worked" -- and that was WRONG, caught
    # by running the rule over every ledger in the tree including the archive:
    #
    #   _archive/audit-remediation/packages/08-job-search-coherence.md
    #   write_set: C:/Users/André/Personal Files/Job search/CLAUDE.md:C:/Users/...
    #
    # Absolute paths, with spaces, targeting another project. The rule flags it,
    # and flagging it is CORRECT -- but not for the reason first given. That
    # field was already broken before anyone annotated anything, because a
    # WINDOWS DRIVE LETTER CONTAINS A COLON: splitting it yields "C",
    # "/Users/André/Personal Files/Job search/CLAUDE.md", "C", ... So the
    # colon-delimited write_set format cannot express an absolute Windows path
    # AT ALL, and a blueprint that targets another project by absolute path has
    # a silently corrupt write set from the moment it is authored.
    #
    # That is a separate finding from 34af and is recorded in the V4c check
    # below rather than left implicit in a whitespace rule that happens to catch
    # it. The honest statement of THIS rule is narrower than the original: it
    # forbids prose, and it also refuses space-bearing absolute paths, which the
    # format could never carry safely in the first place.
    for my $field (qw(write_set test_paths)) {
        my ($val, @items) = $field_segments->($field);
        next unless defined $val;

        # DEFER TO V4c WHEN A DRIVE LETTER IS PRESENT. An absolute Windows path
        # splits into a bare drive letter plus a remainder that usually contains
        # spaces, so this whitespace rule fires first and reports "not a path"
        # -- true, but a symptom. The drive letter is the root cause and the
        # more useful message, so it gets to speak.
        next if join(':', (length $val ? $val : ()), @items) =~ m{(?:^|:)[A-Za-z]:[/\\]};

        my @segs = ((length $val ? split(/:/, $val, -1) : ()), @items);
        for my $seg (@segs) {
            next unless length $seg;
            next unless $seg =~ /\s/;
            return "frontmatter $field: contains a segment that is not a path: \"$seg\". "
                 . 'These fields are colon-delimited and are split on ":" by guard-writes.sh, so '
                 . 'an annotation containing a colon silently splits into extra patterns and '
                 . 'DROPS the annotated path from the write set (report 20260916-175013-34af). '
                 . 'Put explanatory prose in the Scope section, never in this field.';
        }
    }

    # V4c — a Windows DRIVE LETTER in write_set:/test_paths: is always corrupt.
    #
    # Found 2026-09-17 while validating V4b against the archive, not filed from
    # a symptom -- which is why it is worth its own check rather than being left
    # to the whitespace rule that happened to catch one instance.
    #
    # These fields are split on ":". `C:/Users/...` therefore splits into "C" and
    # "/Users/...", so a blueprint targeting another project by absolute Windows
    # path has a silently corrupt write set FROM THE MOMENT IT IS AUTHORED --
    # before anyone annotates anything, and with no symptom until a guard refuses
    # a write nobody expected it to refuse. The bare "C" pattern is also the
    # dangerous half: depending on the matcher it can match far more than
    # intended, not less.
    #
    # The format cannot carry absolute Windows paths, so the rule is to say so at
    # the point of writing rather than to let the field look plausible.
    for my $field (qw(write_set test_paths)) {
        my ($val, @items) = $field_segments->($field);
        next unless defined $val;
        my $joined = join(':', (length $val ? $val : ()), @items);
        next unless length $joined;
        next unless $joined =~ m{(?:^|:)([A-Za-z]):[/\\]};
        my $drive = $1;
        return "frontmatter $field: contains a Windows drive letter (\"$drive:\"). This field is "
             . 'split on ":", so an absolute Windows path splits into a bare drive letter plus the '
             . 'rest and the intended path is never matched -- the field is corrupt from the moment '
             . 'it is written, with no symptom until a guard refuses a write. Use repository-'
             . 'relative paths.';
    }

    # V4d — a ledger may not carry a `depends_on:` frontmatter field.
    #
    # Report 20260916-185610-8ee1 established it is a PHANTOM FIELD: written by
    # hand, read by NOTHING, validated by nothing, and absent from the template
    # that defines what a ledger contains. The scheduler's DAG comes from
    # blueprint.md's package-status table -- bp-drive-next.pl says so in as many
    # words -- and no script anywhere reads a ledger's frontmatter depends_on.
    #
    # It looks exactly as authoritative as write_set and test_paths, which ARE
    # contracts. The measured harm was comprehension, not scheduling: a
    # coordinator reading "this file alone", which every ledger header promises
    # is sufficient, learns nothing about ordering or learns something false;
    # and the report's own filer inferred a scheduling hazard from it and filed
    # at the wrong severity before checking which representation the scheduler
    # reads.
    #
    # Measured 2026-09-17 before adding this: ZERO of the 32 active ledgers
    # carry the field. So this forbids nothing in use -- it stops it coming
    # back, which is the report's own revised suggestion 1 (delete it entirely
    # rather than reconcile two sources that can only ever disagree).
    #
    # Ordering belongs in a `## Dependency edges` SECTION, in prose, where a
    # reader can see the reason and not just the edge.
    {
        for my $l (@FML) {
            next unless $l =~ /^depends_on:/;
            return 'frontmatter depends_on: is not a ledger field. The scheduler builds its DAG '
                 . 'from blueprint.md\'s package-status table and NOTHING reads this key, so a '
                 . 'second copy here can only ever drift out of agreement with the one that counts '
                 . '(report 20260916-185610-8ee1). Put ordering, and the reason for it, in a '
                 . '"## Dependency edges" section instead.';
        }
    }

    # V5 — required sections, presence only, prefix matches. No uniqueness constraint.
    my @sections = (
        ['## Next action',             qr/^## Next action/m],
        ['## Decisions & attempt log', qr/^##\s+Decisions & attempt log\b/m],
        ['## Pipeline',                qr/^##\s+Pipeline\b/m],
        ['## Outputs',                 qr/^##\s+Outputs\b/m],
        ['## Escalation',              qr/^##\s+Escalation\b/m],
    );
    my @gone = map { $_->[0] } grep { $B !~ $_->[1] } @sections;
    if (@gone) {
        return 'drops required section heading(s): ' . join(', ', @gone) . '.';
    }

    return undef;
}

# =====================================================================================
# Shared mechanics (§2.11): fence-aware line walking, section location.
# =====================================================================================

# Walk lines in [start, end) of $B. $cb->($line, $abs_offset, $len, $has_nl) is called
# for each; if it returns a defined value, the walk stops and that value is returned.
sub each_line_with_offset {
    my ($B, $start, $end, $cb) = @_;
    my $pos = $start;
    while ($pos < $end) {
        my $nl       = index($B, "\n", $pos);
        my $has_nl   = ($nl >= 0 && $nl < $end) ? 1 : 0;
        my $line_end = $has_nl ? $nl : $end;
        my $line     = substr($B, $pos, $line_end - $pos);
        my $r = $cb->($line, $pos, $line_end - $pos, $has_nl);
        return $r if defined $r;
        $pos = $has_nl ? $nl + 1 : $end;
    }
    return undef;
}

# A fence delimiter line, CommonMark-accurate: a backtick fence's info string may not
# itself contain a backtick (else it is not a valid fence, e.g. an inline ``` `x` ```
# aside quoted in prose — b09's live landmine). Tilde fences have no such restriction.
#
# RESOLVES A SPEC INCONSISTENCY (2026-08-03, coordinator). Spec §2.11's prose describes
# a NAIVE toggle — "any line whose leading-whitespace-stripped form begins with three or
# more backticks or three or more tildes" — while §469 puts b09 in the corpus precisely
# as "the corpus's live proof a naive parser is foolable". Both cannot hold.
#
# It is not a matter of taste; the naive rule is IMPOSSIBLE here, demonstrated by running
# it. b09:625 is prose containing an inline ``` `## Next action` ``` aside; the only real
# fence pair is 925/928. Naive counting therefore sees 3 fence lines (odd), leaves the
# Decisions section unterminated at EOF, and §2.11's own rule then mandates exit 5 —
# contradicting AC-8's "append-attempt on b09 exits 0". Measured: the naive rule fails
# AC-8 assertions 125, 126 and 128; CommonMark fails none.
#
# The oracle's own fence helpers (fenced_lines / offset_in_fence in t/65) were naive and
# were corrected to match, so parser and oracle agree on what a fence IS. That agreement
# is load-bearing beyond this package: the MEANS-DEVIATION anti-forgery guard at
# SKILL.md:121 is fence-scoped, and if the guard and the parser disagreed about which
# lines are fences, the gap between them would be exactly the forgery window the guard
# exists to close.
sub is_fence_line {
    my ($line) = @_;
    if ($line =~ /^[ \t]*(`{3,})(.*)$/s) {
        return index($2, '`') >= 0 ? 0 : 1;
    }
    return 1 if $line =~ /^[ \t]*~{3,}/;
    return 0;
}

# Locate the FIRST heading matching $head_re and its fence-aware section end
# (first non-fenced /^##\s/ line after it, or EOF).
#
# BOTH scans are fence-aware, and the heading scan must be. The original version
# located the heading with a bare `$B =~ /$head_re/`, which matches the first
# occurrence ANYWHERE — including inside a fenced code block. A ledger that
# quotes `## Decisions & attempt log` inside a ``` fence (this repo's own
# documentation does exactly that) anchored the section on the fenced lookalike.
# The end-scan then started from inside a fence with $infence = 0, inverting
# every subsequent toggle, and the entry was spliced INTO the code block —
# corrupting quoted content that AC-8 requires stay byte-identical.
# All three call sites pass /m line-anchored patterns, so per-line matching is
# equivalent for the heading itself.
sub locate_section {
    my ($B, $head_re) = @_;
    my $len_B   = length($B);
    my $infence = 0;
    my ($body_start, $found_head);
    each_line_with_offset($B, 0, $len_B, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ /$head_re/) {
            $body_start = $has_nl ? $off + $len + 1 : $len_B;
            $found_head = 1;
            return 1;
        }
        return undef;
    });
    return undef unless $found_head;

    $infence  = 0;
    my $end   = $len_B;
    my $found = 0;
    each_line_with_offset($B, $body_start, $len_B, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /^##\s/) { $end = $off; $found = 1; return 1 }
        return undef;
    });
    return {
        body_start   => $body_start,
        body_end     => $end,
        unterminated => (!$found && $infence) ? 1 : 0,
    };
}

# =====================================================================================
# Region-splice functions — one per op. Each returns ($new_bytes, undef) on success, or
# (undef, $reason) when the target region is not found (-> exit 5 at the call site).
# =====================================================================================

sub replace_first_key_line {
    my ($B, $rstart, $rend, $key, $new_line) = @_;
    my $region = substr($B, $rstart, $rend - $rstart);
    my $off = 0;
    for my $line (split(/\n/, $region, -1)) {
        if ($line =~ /^\Q$key\E:\s*(.*?)\s*$/) {
            my $line_start = $rstart + $off;
            my $line_len   = length($line);
            return substr($B, 0, $line_start) . $new_line . substr($B, $line_start + $line_len);
        }
        $off += length($line) + 1;
    }
    return undef;
}

sub splice_set_status {
    my ($B, $status, $iso) = @_;
    return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my ($fs, $fe) = ($-[1], $+[1]);
    my $new = replace_first_key_line($B, $fs, $fe, 'status', "status: $status");
    return (undef, 'status: key not found in frontmatter') unless defined $new;
    $new =~ /\A---\s*\n(.*?)\n---/s;
    my ($fs2, $fe2) = ($-[1], $+[1]);
    my $new2 = replace_first_key_line($new, $fs2, $fe2, 'last_updated', "last_updated: $iso");
    return (undef, 'last_updated: key not found in frontmatter') unless defined $new2;
    return ($new2, undef);
}

# append-attempt / add-output share this mechanic: insert $entry_text (no trailing
# newline) either replacing a lone italic placeholder line, or before the section's
# terminating heading / EOF.
sub splice_insert_entry {
    my ($B, $head_re, $entry_text) = @_;
    my $loc = locate_section($B, $head_re);
    return (undef, 'target section heading not found') unless $loc;
    return (undef, 'section ends inside an unterminated fenced code block; refusing to insert into a fence')
        if $loc->{unterminated};

    my $infence = 0;
    my @nonblank;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line !~ /^\s*$/) { push @nonblank, { off => $off, len => $len, line => $line } }
        return undef;
    });

    if (@nonblank == 1 && $nonblank[0]{line} =~ /^_\(.*\)_$/) {
        my $abs = $nonblank[0]{off};
        my $len = $nonblank[0]{len};
        return (substr($B, 0, $abs) . $entry_text . substr($B, $abs + $len), undef);
    }

    my $off = $loc->{body_end};
    return (substr($B, 0, $off) . $entry_text . "\n" . substr($B, $off), undef);
}

sub splice_tick_step {
    my ($B, $N) = @_;
    my $head_re = qr/^##\s+Pipeline\b/m;
    my $loc = locate_section($B, $head_re);
    return (undef, '## Pipeline section not found') unless $loc;

    my $infence = 0;
    my $target_re = qr/^(\s*-\s*\[)([ xX])(\]\s*\Q$N\E\.)/;
    my $result;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ $target_re) {
            my $bracket_off = $off + length($1);
            my $cur = $2;
            if ($cur eq 'x' || $cur eq 'X') { $result = [$B, undef] }
            else { $result = [substr($B, 0, $bracket_off) . 'x' . substr($B, $bracket_off + 1), undef] }
            return 1;
        }
        return undef;
    });
    return @$result if $result;
    return (undef, "no line matching '- [ ] $N.' (or [x]/[X]) found in ## Pipeline");
}

sub splice_set_next_action {
    my ($B, $body) = @_;
    my $head_re = qr/^## Next action/m;
    my $loc = locate_section($B, $head_re);
    return (undef, '## Next action section not found') unless $loc;
    my $has_term = ($loc->{body_end} < length($B)) ? 1 : 0;
    my $new_span = "\n" . $body . ($has_term ? "\n\n" : "\n");
    return (substr($B, 0, $loc->{body_start}) . $new_span . substr($B, $loc->{body_end}), undef);
}

# =====================================================================================
# Oracle identity — derivation, records, sections, pipeline/claim-check (spec §2.3-2.9).
# =====================================================================================

# Pure. Strips a trailing TAP directive, truncates at the first "(", squeezes
# whitespace, trims. Returns '' for a description that normalizes to nothing.
sub normalize_description {
    my ($desc) = @_;
    return '' unless defined $desc;
    my $d = $desc;
    $d =~ s/\s+#\s*(?:SKIP|TODO)\b.*\z//i;
    $d =~ s/\(.*\z//s;
    $d =~ s/\s+/ /g;
    $d =~ s/^\s+|\s+\z//g;
    return $d;
}

# Pure. $tap is the combined stdout+stderr of a run. Returns ($assertion_count,
# \@normalized_descriptions_sorted_unique).
sub parse_tap {
    my ($tap) = @_;
    $tap = '' unless defined $tap;
    my $count = 0;
    my %descset;
    for my $line (split(/\n/, $tap, -1)) {
        next if $line =~ /^\s/;   # indented (subtest) lines are never top-level
        next unless $line =~ /^(?:not )?ok(?:\s+(\d+))?(?:\s*-?\s*(.*))?$/;
        $count++;
        my $norm = normalize_description(defined $2 ? $2 : '');
        $descset{$norm} = 1 if length $norm;
    }
    my @descs = sort keys %descset;
    return ($count, \@descs);
}

# Impure but TOTAL: never dies, never warns, never writes to stderr, never exits.
# Returns a hashref, always (spec §2.3).
sub derive_oracle_identity {
    my ($test_path) = @_;
    my $result;
    local $SIG{__DIE__} = sub { };
    local $SIG{__WARN__} = sub { };
    eval {
        unless (defined $test_path && length $test_path && -f $test_path && -r $test_path) {
            $result = { status => 'unavailable', reason => 'not a readable file' };
            return;
        }
        my $sha_ok = eval { require Digest::SHA; 1 };
        unless ($sha_ok) {
            $result = { status => 'unavailable', reason => 'Digest::SHA unavailable' };
            return;
        }
        my $bytes;
        {
            open(my $fh, '<:raw', $test_path) or die "ORACLE_UNREADABLE\n";
            local $/;
            $bytes = <$fh>;
            close $fh;
            $bytes = '' unless defined $bytes;
        }
        my $sha = Digest::SHA::sha256_hex($bytes);

        my $timeout_s = ORACLE_DEFAULT_TIMEOUT_S;
        if (defined $ENV{BP_ORACLE_TIMEOUT_S} && $ENV{BP_ORACLE_TIMEOUT_S} =~ /^\d+$/) {
            $timeout_s = $ENV{BP_ORACLE_TIMEOUT_S};
        }

        my ($tap, $exit_code) = $ORACLE_RUN_FN->($test_path, $timeout_s);

        unless (defined $exit_code) {
            $result = { status => 'unavailable', reason => 'run failed' };
            return;
        }
        unless (defined $tap && length $tap) {
            $result = { status => 'unavailable', reason => 'no TAP output' };
            return;
        }

        my ($count, $descs) = parse_tap($tap);
        unless ($count) {
            $result = { status => 'unavailable', reason => 'no TAP output' };
            return;
        }

        my %rec = (status => 'ok', sha256 => $sha, assertions => $count + 0);
        $rec{descriptions_sha256} = Digest::SHA::sha256_hex(join("\n", @$descs));
        $rec{descriptions} = $descs if scalar(@$descs) <= ORACLE_DESCRIPTION_CAP;
        $result = \%rec;
    };
    if (my $err = $@) {
        if ($err =~ /ORACLE_TIMEOUT/) {
            $result = { status => 'unavailable', reason => 'timed out' };
        }
        else {
            $result = { status => 'unavailable', reason => 'internal error' };
        }
    }
    return $result // { status => 'unavailable', reason => 'internal error' };
}

# Replace every ref-address-shaped substring with a fixed elision token (spec §2.4),
# so a recorded description can never trip validate_no_new_ref_addr.
sub sanitize_ref_addrs_str {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/$REF_ADDR_RE/<ref-address-elided>/g;
    return $s;
}

sub encode_oracle_record {
    my ($rec) = @_;
    return ORACLE_LINE_PREFIX . JSON::PP->new->canonical(1)->ascii(1)->encode($rec);
}

sub oracle_records_equal_ignoring_time {
    my ($a, $b) = @_;
    my %a2 = %$a; delete $a2{recorded_at};
    my %b2 = %$b; delete $b2{recorded_at};
    return JSON::PP->new->canonical(1)->ascii(1)->encode(\%a2)
        eq JSON::PP->new->canonical(1)->ascii(1)->encode(\%b2);
}

# Build the JSON-ready record hash (spec §2.4). $identity is derive_oracle_identity's
# return; $reaccept, if given, is {reason=>..., delta=>...} already computed.
sub build_oracle_record {
    my (%p) = @_;
    my %rec = (
        step        => $p{step} + 0,
        path        => $p{path},
        recorded_at => $p{recorded_at},
        status      => $p{identity}{status},
    );
    if ($rec{status} eq 'ok') {
        $rec{sha256}     = $p{identity}{sha256};
        $rec{assertions} = $p{identity}{assertions} + 0;
        $rec{descriptions_sha256} = $p{identity}{descriptions_sha256};
        if (exists $p{identity}{descriptions}) {
            $rec{descriptions} = [ map { sanitize_ref_addrs_str($_) } @{ $p{identity}{descriptions} } ];
        }
    }
    else {
        $rec{reason} = sanitize_ref_addrs_str($p{identity}{reason});
    }
    if (exists $p{reaccept}) {
        my %ra = %{ $p{reaccept} };
        $ra{reason} = sanitize_ref_addrs_str($ra{reason}) if defined $ra{reason};
        $rec{reaccept} = \%ra;
    }
    return \%rec;
}

# Fence-aware, scoped to the ORACLE_SECTION_HEADING section. Silently skips any line
# that is not `- oracle <json-object>` or whose JSON fails to decode (spec §2.4).
sub parse_oracle_records {
    my ($bytes) = @_;
    my $loc = locate_section($bytes, qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m);
    return () unless $loc;
    my $prefix_re = qr/^\Q@{[ORACLE_LINE_PREFIX]}\E(\{.*\})\s*$/;
    my @records;
    my $infence = 0;
    each_line_with_offset($bytes, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ $prefix_re) {
            my $rec = eval { JSON::PP->new->decode($1) };
            push @records, $rec if ref $rec eq 'HASH';
        }
        return undef;
    });
    return @records;
}

# Fence-aware search for a heading's LINE START offset (not locate_section's body
# start, which is after the heading line).
sub locate_heading_start {
    my ($B, $head_re) = @_;
    my $infence = 0;
    my $found;
    each_line_with_offset($B, 0, length($B), sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ /$head_re/) { $found = $off; return 1 }
        return undef;
    });
    return $found;
}

sub render_oracle_section {
    my (@lines) = @_;
    my $body = join('', map { $_ . "\n" } @lines);
    return "\n" . ORACLE_SECTION_HEADING . "\n\n"
         . "Machine-written by `bp-ledger.pl tick-step` at steps 3 and 5. One JSON record per line.\n"
         . "Never hand-edit: `bp-ledger.pl claim-check` reads these to verify the completion claim.\n\n"
         . $body . "\n";
}

sub insert_oracle_section {
    my ($B, @lines) = @_;
    my $section_text = render_oracle_section(@lines);
    my $pos = locate_heading_start($B, qr/^##\s+Decisions & attempt log\b/m);
    if (defined $pos) {
        return substr($B, 0, $pos) . substr($section_text, 1) . substr($B, $pos);
    }
    return $B . $section_text;
}

sub replace_oracle_section {
    my ($B, @lines) = @_;
    my $head_re = qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m;
    my $heading_start = locate_heading_start($B, $head_re);
    return insert_oracle_section($B, @lines) unless defined $heading_start;
    my $loc = locate_section($B, $head_re);
    return insert_oracle_section($B, @lines) unless $loc;
    my $section_text = render_oracle_section(@lines);
    return substr($B, 0, $heading_start) . substr($section_text, 1) . substr($B, $loc->{body_end});
}

sub insert_or_replace_oracle_section {
    my ($B, @lines) = @_;
    my $head_re = qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m;
    if (defined locate_heading_start($B, $head_re)) {
        return replace_oracle_section($B, @lines);
    }
    return insert_oracle_section($B, @lines);
}

# Merge @new_records (each already carrying step/path) into whatever the ledger
# currently has, replacing a (step,path) pair in place, keeping an unchanged record
# byte-stable (ignoring recorded_at) for idempotency (AC-6/AC-7), and rendering the
# whole section fresh via the canonical/ascii encoder (deterministic -> stable bytes).
sub merge_and_render_oracle_section {
    my ($B, @new_records) = @_;
    my @existing = parse_oracle_records($B);
    my %new_by_key = map { (($_->{step} // '') . '|' . ($_->{path} // '')) => $_ } @new_records;
    my %used;
    my @final;
    for my $rec (@existing) {
        my $key = ($rec->{step} // '') . '|' . ($rec->{path} // '');
        if (exists $new_by_key{$key} && !$used{$key}) {
            my $cand = $new_by_key{$key};
            push @final, oracle_records_equal_ignoring_time($rec, $cand) ? $rec : $cand;
            $used{$key} = 1;
        }
        else {
            push @final, $rec;
        }
    }
    for my $cand (@new_records) {
        my $key = ($cand->{step} // '') . '|' . ($cand->{path} // '');
        next if $used{$key};
        push @final, $cand;
        $used{$key} = 1;
    }
    my @lines = map { encode_oracle_record($_) } @final;
    return insert_or_replace_oracle_section($B, @lines);
}

# Both legal frontmatter forms (colon-delimited scalar AND the YAML-ish list), mirroring
# the existing $field_segments closure inside validate_bytes (spec §2.9).
sub ledger_field_segments {
    my ($B, $field) = @_;
    return () unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my @FML = split(/\n/, $1, -1);
    my ($i, $scalar) = (-1, undef);
    for my $n (0 .. $#FML) {
        if ($FML[$n] =~ /^\Q$field\E:\s*(.*?)\s*$/) { $i = $n; $scalar = $1; last }
    }
    return () if $i < 0;
    my @items;
    for my $n ($i + 1 .. $#FML) {
        last unless $FML[$n] =~ /^\s+-\s*(.*?)\s*$/;
        push @items, $1 if length $1;
    }
    my @segs;
    push @segs, split(/:/, $scalar, -1) if defined $scalar && length $scalar;
    push @segs, @items;
    return @segs;
}

# An oracle path is a test_paths segment ending in ".t" (spec §2.9). Scope-prefix
# segments (e.g. "t/") are skipped entirely.
sub ledger_test_paths {
    my ($B) = @_;
    return grep { length($_) && /\.t\z/ } ledger_field_segments($B, 'test_paths');
}

# Pipeline satisfaction rules (spec §2.8), scoped to ## Pipeline via locate_section /
# is_fence_line so a fenced lookalike never counts. Conditionality is decided by step
# NUMBER, never by prose.
sub ledger_pipeline_items {
    my ($B) = @_;
    my $loc = locate_section($B, qr/^##\s+Pipeline\b/m);
    return () unless $loc;
    my $item_re = qr/^\s*-\s*\[([ xX])\]\s*(\d+)\.\s*(.*?)\s*$/;
    my @items;
    my $infence = 0;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ $item_re) {
            my ($box, $n, $text) = ($1, $2 + 0, $3);
            my $ticked      = ($box eq 'x' || $box eq 'X') ? 1 : 0;
            my $conditional = (grep { $_ == $n } @PIPELINE_CONDITIONAL_STEPS) ? 1 : 0;
            my $na          = ($text =~ /(?<![A-Za-z0-9])N\/A(?![A-Za-z0-9])/i) ? 1 : 0;
            my $satisfied   = ($ticked || ($conditional && $na)) ? 1 : 0;
            push @items, { step => $n, ticked => $ticked, conditional => $conditional,
                           na => $na, satisfied => $satisfied, text => $text };
        }
        return undef;
    });
    return @items;
}

# =====================================================================================
# The shared five-op algorithm (spec §2.3, steps 1..10).
# =====================================================================================

sub run_op {
    my ($sub, $path, $splice_cb, $post_cb) = @_;

    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error($sub, $path, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error($sub, $path, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $path) or io_error($sub, $path, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    my $detail = validate_bytes($orig);
    reject_error($sub, $path, $detail) if defined $detail;

    my ($new, $notfound) = $splice_cb->($orig);
    notfound_error($sub, $path, $notfound) unless defined $new;

    my $detail2 = validate_bytes($new);
    reject_error($sub, $path, $detail2) if defined $detail2;

    my $ref_detail = validate_no_new_ref_addr($orig, $new);
    reject_error($sub, $path, $ref_detail) if defined $ref_detail;

    my $lu_detail = last_updated_check($orig, $new);
    reject_error($sub, $path, $lu_detail) if defined $lu_detail;

    if ($new eq $orig) { $post_cb->($new) if $post_cb; exit 0 }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error($sub, $path, "cannot open temp file $tmp: $!");
    print {$w} $new or do { close $w; unlink $tmp; io_error($sub, $path, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error($sub, $path, "close $tmp failed: $!") };

    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        io_error($sub, $path, "rename $tmp -> $path failed: $!");
    }

    # a01 §7 / behavior 33: the read-back is not optional even in the house
    # precedent -- still under the lock, still routed through the EXISTING
    # io_error/exit-4 path (no new exit-code vocabulary, per spec §6 "Changing
    # run_op's exit-code vocabulary ... is out of scope"). A rename that reports
    # success but whose bytes don't read back is exactly the DROP shape this
    # package exists to close.
    my $after;
    {
        open(my $rfh, '<:raw', $path) or io_error($sub, $path, "read-back: cannot read: $!");
        local $/;
        $after = <$rfh>;
        close $rfh;
        $after = '' unless defined $after;
    }
    unless ($after eq $new) {
        io_error($sub, $path, "value did not survive the write");
    }

    # a03-ledger-budget-irreducible spec: $post_cb (the budget-marker read/mutate) must
    # run under the SAME lock discipline on every path through run_op -- the no-op path
    # above already calls it before releasing the lock (it never explicitly unlocks;
    # process exit does that). Calling it here, before flock(LOCK_UN), keeps this path
    # consistent with that one and with op_rotate's own $finalize_budget_state (always
    # called before its flock(LOCK_UN)) -- all three marker-mutation sites now agree.
    # Reviewer step6 MAJOR / red-team MINOR-2: previously this ran AFTER the unlock,
    # opening a race window against a concurrent invocation on the same lockfile.
    $post_cb->($new) if $post_cb;
    flock($lk, LOCK_UN);
    close($lk);
    exit 0;
}

# =====================================================================================
# Free-text argument acquisition: --text/--body (inline, '-' means stdin),
# --text-file/--body-file (raw file read). Exactly one source.
# =====================================================================================

sub get_freetext_arg {
    my (%p) = @_;
    my ($sub, $opt, $primary, $filekey) = @p{qw(sub opt primary filekey)};
    my $has_inline = defined $opt->{$primary};
    my $has_file   = defined $opt->{$filekey};
    if ($has_inline && $has_file) {
        arg_error($sub, "specify exactly one of --$primary or --$filekey, not both");
    }
    if (!$has_inline && !$has_file) {
        arg_error($sub, "missing required --$primary (or --$filekey, or --$primary -  for stdin)");
    }
    if ($has_file) {
        my $path = $opt->{$filekey};
        open(my $fh, '<:raw', $path) or arg_error($sub, "cannot read --$filekey $path: $!");
        local $/;
        my $c = <$fh>;
        close $fh;
        return defined $c ? $c : '';
    }
    my $v = $opt->{$primary};
    if ($v eq '-') {
        binmode STDIN;
        local $/;
        my $c = <STDIN>;
        return defined $c ? $c : '';
    }
    return $v;
}

# =====================================================================================
# Op handlers.
# =====================================================================================

sub op_set_status {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'status=s'); }
    arg_error('set-status', 'unrecognised option') unless $ok;
    arg_error('set-status', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-status', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('set-status', 'missing required --status') unless defined $opt{status};
    unless (grep { $_ eq $opt{status} } @STATUSES) {
        arg_error('set-status',
            "'$opt{status}' is not a recognised status; allowed values: " . join(', ', @STATUSES));
    }
    my $iso = iso_now();
    run_op('set-status', $opt{ledger}, sub { return splice_set_status($_[0], $opt{status}, $iso) });
}

sub op_append_attempt {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'text=s', 'text-file=s'); }
    arg_error('append-attempt', 'unrecognised option') unless $ok;
    arg_error('append-attempt', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('append-attempt', 'missing required --ledger') unless defined $opt{ledger};
    my $text = get_freetext_arg(sub => 'append-attempt', opt => \%opt, primary => 'text', filekey => 'text-file');
    $text =~ s/[\r\n]+/ /g;
    my $iso   = iso_now();
    my $entry = "- ${iso} ${EMDASH} ${text}";
    # b45 §4: visibility, never a refusal. The append has already happened (or is a
    # no-op) by the time this fires; we only ever warn, never block.
    my $budget_check = sub {
        my ($bytes) = @_;
        my $size = length($bytes);
        if ($size <= DEFAULT_BUDGET_BYTES) {
            # Genuinely back under budget: any prior suppression is stale now, and any
            # prior "reducible" notice state is moot -- clear the marker so the NEXT
            # over-budget encounter (whatever it turns out to be) starts fresh (spec
            # §2.1's own bullet on staleness).
            clear_budget_marker($opt{ledger});
            return;
        }
        my $marker = read_budget_marker($opt{ledger});
        if ($marker && $marker->{state} eq 'irreducible') {
            # A rotate already determined this ledger cannot be reduced further.
            # Say it once (the marker's own "notified" flag), not on every append --
            # but only while that "notified" claim is still within its trust window
            # (red-team step6 MAJOR-1). A forged or stale marker falls through here and
            # re-notifies rather than staying silent forever.
            return if $marker->{flag} eq 'notified' && budget_marker_fresh($marker->{ts});
            emit_notice('append-attempt', 'LEDGER_IRREDUCIBLE',
                "$opt{ledger} is $size bytes, over the " . DEFAULT_BUDGET_BYTES
                . '-byte budget; a prior rotate already determined this ledger cannot be reduced '
                . 'further -- see that rotate run for the diagnosis. Not repeated on subsequent appends.');
            mark_irreducible_notified($opt{ledger});
            return;
        }
        # b45 §4: visibility, never a refusal. The append has already happened (or is a
        # no-op) by the time this fires; we only ever notify, never block.
        emit_notice('append-attempt', 'BUDGET_OVER',
            "$opt{ledger} is $size bytes, exceeding the " . DEFAULT_BUDGET_BYTES
            . "-byte budget; run: bp-ledger.pl rotate --ledger $opt{ledger}");
    };
    run_op('append-attempt', $opt{ledger},
        sub { return splice_insert_entry($_[0], qr/^##\s+Decisions & attempt log\b/m, $entry) },
        $budget_check);
}

# Recompute a delta between a step-3 and step-5 record (both must exist and be
# considered), for the `reaccept` object the caller's --reaccept-oracle names (spec
# §2.4) as well as for claim-check's own report (spec §2.6/§2.7). Booleans use
# JSON::PP::true/false so they encode as JSON booleans, not 0/1.
sub oracle_delta {
    my ($step3, $step5) = @_;
    my $before = ($step3 && $step3->{status} eq 'ok') ? $step3->{assertions} + 0 : undef;
    my $after  = ($step5 && $step5->{status} eq 'ok') ? $step5->{assertions} + 0 : undef;
    my $comparable = ($step3 && $step5 && exists $step3->{descriptions} && exists $step5->{descriptions}) ? 1 : 0;
    my (@added, @removed);
    if ($comparable) {
        # Comparison is always by NORMALIZED description (spec §2.3/AC-25/AC-26):
        # a stored record's descriptions may themselves be un-normalized (e.g. a
        # hand-authored fixture record), so normalize here defensively -- idempotent
        # against an already-normalized live derivation.
        my %s3 = map { (normalize_description($_) => 1) } @{ $step3->{descriptions} || [] };
        my %s5 = map { (normalize_description($_) => 1) } @{ $step5->{descriptions} || [] };
        delete $s3{''}; delete $s5{''};
        @added   = sort grep { !$s3{$_} } keys %s5;
        @removed = sort grep { !$s5{$_} } keys %s3;
    }
    return {
        assertions_before      => $before,
        assertions_after       => $after,
        descriptions_added     => \@added,
        descriptions_removed   => \@removed,
        descriptions_comparable=> $comparable ? JSON::PP::true : JSON::PP::false,
    };
}

sub op_tick_step {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'step=s',
                                 'reaccept-oracle=s@', 'reaccept-reason=s'); }
    arg_error('tick-step', 'unrecognised option') unless $ok;
    arg_error('tick-step', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('tick-step', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('tick-step', 'missing required --step') unless defined $opt{step};
    unless ($opt{step} =~ /^[1-9][0-9]*$/) {
        arg_error('tick-step', "'--step $opt{step}' is not a positive integer without a leading zero");
    }
    my @reaccept_paths = @{ $opt{'reaccept-oracle'} || [] };
    if (@reaccept_paths && $opt{step} != 5) {
        arg_error('tick-step', '--reaccept-oracle is only valid with --step 5');
    }
    if (@reaccept_paths && !defined $opt{'reaccept-reason'}) {
        arg_error('tick-step', '--reaccept-oracle requires --reaccept-reason');
    }
    if (!@reaccept_paths && defined $opt{'reaccept-reason'}) {
        arg_error('tick-step', '--reaccept-reason requires at least one --reaccept-oracle');
    }

    run_op('tick-step', $opt{ledger}, sub {
        my ($B) = @_;
        my ($ticked, $notfound) = splice_tick_step($B, $opt{step});
        return (undef, $notfound) unless defined $ticked;

        # Fail-silent mandate (spec §5): recording may never subtract availability.
        # Any exception/undef/validation failure anywhere below -> plain tick only.
        my $step_n = $opt{step} + 0;
        return ($ticked, undef)
            if defined $ENV{BP_ORACLE_RECORD} && $ENV{BP_ORACLE_RECORD} eq '0';
        return ($ticked, undef) unless grep { $_ == $step_n } @ORACLE_RECORDED_STEPS;

        my $final = eval {
            local $SIG{__DIE__} = sub { };
            local $SIG{__WARN__} = sub { };
            my @paths = ledger_test_paths($B);
            return $ticked unless @paths;

            my $now = iso_now();
            my %reaccept_wanted = map { ($_ => 1) } @reaccept_paths;
            my @existing = parse_oracle_records($B);
            my %step3_by_path;
            for my $r (@existing) {
                next unless defined $r->{step} && $r->{step} == 3;
                $step3_by_path{ $r->{path} } = $r if defined $r->{path};
            }

            my @new_records;
            for my $path (@paths) {
                my $identity = derive_oracle_identity($path);
                my %args = (step => $step_n, path => $path, recorded_at => $now, identity => $identity);
                if ($step_n == 5 && $reaccept_wanted{$path}) {
                    my $step3 = $step3_by_path{$path};
                    my $delta = oracle_delta($step3, $identity);
                    $args{reaccept} = { reason => $opt{'reaccept-reason'}, delta => $delta };
                }
                push @new_records, build_oracle_record(%args);
            }

            my $merged = merge_and_render_oracle_section($ticked, @new_records);

            # Self-validate BEFORE returning: never let run_op's own re-validation
            # be the thing that discovers a problem (that path exits 2, forbidden here).
            return $ticked if defined validate_bytes($merged);
            return $ticked if defined validate_no_new_ref_addr($B, $merged);
            return $merged;
        };
        $final = $ticked if $@ || !defined $final;
        return ($final, undef);
    });
}

sub op_set_next_action {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'body=s', 'body-file=s'); }
    arg_error('set-next-action', 'unrecognised option') unless $ok;
    arg_error('set-next-action', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-next-action', 'missing required --ledger') unless defined $opt{ledger};
    my $body = get_freetext_arg(sub => 'set-next-action', opt => \%opt, primary => 'body', filekey => 'body-file');
    $body =~ s/\s+\z//;
    if ($body eq '') {
        arg_error('set-next-action',
            'the --body is empty after stripping trailing whitespace; set-next-action requires non-empty content');
    }
    my @lines = split(/\n/, $body, -1);
    my $first = $lines[0];
    if ($first eq '' || $first =~ /^#/) {
        arg_error('set-next-action',
            "the first line of --body must be non-blank and must not begin with '#': bp-status.sh renders the "
          . "first non-blank line as the human-facing summary while gate-stop.sh additionally skips '#'-leading "
          . "lines, so the two readers would disagree about what the next action is");
    }
    if (grep { /^\s*-\s*\[[xX]\]/ } @lines) {
        arg_error('set-next-action',
            "the --body must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    run_op('set-next-action', $opt{ledger}, sub { return splice_set_next_action($_[0], $body) });
}

sub op_add_output {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'text=s', 'text-file=s'); }
    arg_error('add-output', 'unrecognised option') unless $ok;
    arg_error('add-output', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('add-output', 'missing required --ledger') unless defined $opt{ledger};
    my $text = get_freetext_arg(sub => 'add-output', opt => \%opt, primary => 'text', filekey => 'text-file');
    if (grep { /^\s*-\s*\[[xX]\]/ } split(/\n/, $text, -1)) {
        arg_error('add-output',
            "the --text must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    $text =~ s/[\r\n]+/ /g;
    my $entry = "- ${text}";
    run_op('add-output', $opt{ledger}, sub { return splice_insert_entry($_[0], qr/^##\s+Outputs\b/m, $entry) });
}

# =====================================================================================
# `claim-check` (08-completion-claims-checked spec §2.6/§2.7) — READ-ONLY report. Never
# mutates, never refuses on pipeline/oracle state; always exits 0 when it can produce a
# report. Exit 3 usage, exit 4 I/O.
# =====================================================================================

sub extract_frontmatter_value {
    my ($B, $key) = @_;
    return undef unless $B =~ /\A---\s*\n(.*?)\n---/s;
    for my $l (split(/\n/, $1, -1)) {
        if ($l =~ /^\Q$key\E:\s*(.*?)\s*$/) { return $1 }
    }
    return undef;
}

sub op_claim_check {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s'); }
    arg_error('claim-check', 'unrecognised option') unless $ok;
    arg_error('claim-check', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('claim-check', 'missing required --ledger') unless defined $opt{ledger};

    my $B;
    {
        open(my $fh, '<:raw', $opt{ledger}) or io_error('claim-check', $opt{ledger}, "cannot read: $!");
        local $/;
        $B = <$fh>;
        close $fh;
        $B = '' unless defined $B;
    }

    my $status  = extract_frontmatter_value($B, 'status');
    my $package = extract_frontmatter_value($B, 'package');
    my $gated   = (defined $status && $status eq 'done') ? 1 : 0;

    my @items = ledger_pipeline_items($B);
    my @unsatisfied = map { $_->{step} } grep { !$_->{satisfied} } @items;

    my @test_paths = ledger_test_paths($B);
    my @records    = parse_oracle_records($B);
    my %latest;   # "$step|$path" => rec (last one wins if somehow duplicated)
    $latest{ ($_->{step} // '') . '|' . ($_->{path} // '') } = $_ for @records;

    my %all_paths = map { ($_ => 1) } @test_paths;
    $all_paths{ $_->{path} } = 1 for grep { defined $_->{path} } @records;

    my @oracle_paths;
    my @findings;

    for my $path (sort keys %all_paths) {
        my $r3 = $latest{"3|$path"};
        my $r5 = $latest{"5|$path"};
        my $step3_ticked = grep { $_->{step} == 3 && $_->{satisfied} } @items;
        my $step5_ticked = grep { $_->{step} == 5 && $_->{satisfied} } @items;

        my $verdict = 'unknown';
        my $delta;

        if ($gated) {
            if ($step3_ticked && !$r3) {
                push @findings, { code => 'ORACLE_NOT_RECORDED',
                                   path => $path, step => undef,
                                   detail => "step 3 is ticked but no oracle record exists for $path" };
            }
            if ($r3 && $r3->{status} eq 'unavailable') {
                push @findings, { code => 'ORACLE_UNDERIVABLE', path => $path, step => 3,
                                   detail => "step-3 record for $path is unavailable: " . ($r3->{reason} // '') };
            }
            if ($r5 && $r5->{status} eq 'unavailable') {
                push @findings, { code => 'ORACLE_UNDERIVABLE', path => $path, step => 5,
                                   detail => "step-5 record for $path is unavailable: " . ($r5->{reason} // '') };
            }
            if ($step5_ticked && $r3 && !$r5) {
                push @findings, { code => 'ORACLE_NOT_REVALIDATED', path => $path, step => undef,
                                   detail => "step 5 is ticked and $path has a step-3 record but no step-5 record" };
            }

            if ($r3 && $r5 && $r3->{status} eq 'ok' && $r5->{status} eq 'ok') {
                $delta = oracle_delta($r3, $r5);
                my $comparable = (exists $r3->{descriptions} && exists $r5->{descriptions}) ? 1 : 0;

                # "differ" (sha256, assertion count, or description SET) is judged on
                # NORMALIZED descriptions (AC-25/AC-26: a parenthetical-only or
                # whitespace/TODO-only difference is not a real change), never on the
                # raw descriptions_sha256, which is a surface hash over unnormalized text.
                my $desc_changed = $comparable
                    ? (scalar(@{ $delta->{descriptions_added} }) > 0 || scalar(@{ $delta->{descriptions_removed} }) > 0)
                    : (($r3->{descriptions_sha256} // '') ne ($r5->{descriptions_sha256} // ''));
                my $sha_changed        = (($r3->{sha256} // '') ne ($r5->{sha256} // ''));
                my $assertions_changed = ($r3->{assertions} != $r5->{assertions});
                my $identical = !$desc_changed && !$sha_changed && !$assertions_changed;

                my $shrank = ($r5->{assertions} < $r3->{assertions})
                          || ($comparable && scalar(@{ $delta->{descriptions_removed} }) > 0);

                if ($shrank) {
                    $verdict = 'shrunk';
                    push @findings, { code => 'ORACLE_SHRANK', path => $path, step => undef, delta => $delta,
                        detail => sprintf('%s: assertions %d -> %d (or a description vanished)',
                                           $path, $r3->{assertions}, $r5->{assertions}) };
                }
                elsif (!$identical) {
                    $verdict = 'drifted';
                    if (!exists $r5->{reaccept}) {
                        my @added = @{ $delta->{descriptions_added} };
                        push @findings, { code => 'ORACLE_DRIFT_UNACCEPTED', path => $path, step => undef, delta => $delta,
                            detail => "$path: oracle changed without a reaccept (added: "
                                    . join(', ', @added) . ')' };
                    }
                    else {
                        $verdict = 'reaccepted';
                    }
                }
                else {
                    $verdict = 'ok';
                }
            }
            elsif ($r3 && !$r5) { $verdict = 'not-revalidated' }
            elsif (!$r3)        { $verdict = 'not-recorded' }
        }

        push @oracle_paths, {
            path    => $path,
            verdict => $verdict,
            step3   => $r3 ? $r3->{status} : undef,
            step5   => $r5 ? $r5->{status} : undef,
            (defined $delta ? (delta => $delta) : ()),
            reaccept => ($r5 && exists $r5->{reaccept}) ? $r5->{reaccept} : undef,
        };
    }

    if ($gated) {
        for my $it (sort { $a->{step} <=> $b->{step} } grep { !$_->{satisfied} } @items) {
            push @findings, { code => 'PIPELINE_STEP_UNTICKED', path => undef, step => $it->{step},
                               detail => $it->{text} };
        }
    }
    @findings = () unless $gated;

    my $report = {
        ledger   => $opt{ledger},
        package  => $package,
        status   => $status,
        gated    => $gated ? JSON::PP::true : JSON::PP::false,
        pipeline => {
            items => [ map {
                { step => $_->{step} + 0, ticked => ($_->{ticked} ? JSON::PP::true : JSON::PP::false),
                  conditional => ($_->{conditional} ? JSON::PP::true : JSON::PP::false),
                  na => ($_->{na} ? JSON::PP::true : JSON::PP::false),
                  satisfied => ($_->{satisfied} ? JSON::PP::true : JSON::PP::false),
                  text => $_->{text} }
            } @items ],
            unsatisfied => [ sort { $a <=> $b } @unsatisfied ],
        },
        oracle   => { paths => \@oracle_paths },
        findings => \@findings,
    };

    print JSON::PP->new->canonical(1)->ascii(1)->encode($report) . "\n";
    exit 0;
}

# =====================================================================================
# `rotate` (b45-ledger-context-budget-spec.md §3) — moves stale
# `## Decisions & attempt log` entries to reports/ledger-history/<pkg>.md.
# =====================================================================================

# Split the `## Decisions & attempt log` body [$body_start, $body_end) into ordered,
# fence-aware "entries". An entry begins at a NOT-in-fence line matching /^-\s/ (the
# shape every append-attempt/MEANS-DEVIATION entry has, per SKILL.md) and runs up to
# (but not including) the next such line, or to $body_end. Content before the first
# entry (placeholder text, blank lines) is "preamble" and is never a rotation
# candidate. Because entry boundaries are only recognised OUTSIDE a fence, a fence
# can never be split: any fence-toggle line and everything inside it is absorbed into
# whichever entry (or the preamble) precedes it, never carved into its own entry.
sub parse_attempt_entries {
    my ($B, $body_start, $body_end) = @_;
    my $infence = 0;
    my @entries;
    my $cur_start;
    each_line_with_offset($B, $body_start, $body_end, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /^-\s/) {
            push @entries, { start => $cur_start, end => $off } if defined $cur_start;
            $cur_start = $off;
        }
        return undef;
    });
    push @entries, { start => $cur_start, end => $body_end } if defined $cur_start;
    my $preamble_end = @entries ? $entries[0]{start} : $body_end;
    return (\@entries, $preamble_end);
}

# Does this entry span contain a LIVE (non-fenced) MEANS-DEVIATION: marker? Mirrors
# BpJudge::parse_means_deviations's own fence-skipping exactly (bp-judge.pl:635) —
# parser and retention rule must agree on what counts, or the gap between them is a
# forgery window (spec §1 / SKILL.md:159-161).
sub entry_has_live_marker {
    my ($B, $start, $end) = @_;
    my $infence = 0;
    my $found = 0;
    each_line_with_offset($B, $start, $end, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /MEANS-DEVIATION:/) { $found = 1; return 1 }
        return undef;
    });
    return $found;
}

# reports/ledger-history/<pkg>.md is relative to the BLUEPRINT dir (spec §3), derived
# from the ledger path's own `.../packages/<pkg>.md` shape — never a second, parallel
# naming convention. Deliberately requires the packages/ path element: bp-resume-sweep.sh
# and bp-status.sh glob "packages/*.md" (spec §2), so history must never be reachable
# by guessing a sibling of the ledger without going through that exact anchor.
sub derive_history_path {
    my ($ledger) = @_;
    return undef unless $ledger =~ m{^(.*)/packages/([^/]+)\.md$};
    my ($bpdir, $pkg) = ($1, $2);
    return "$bpdir/reports/ledger-history/$pkg.md";
}

# mkdir -p, core-Perl only (File::Path is not on the allowed-module list, §2.5).
sub ensure_dir_exists {
    my ($dir) = @_;
    return 1 if -d $dir;
    # Drive-RELATIVE (red-team step6 MAJOR-2): "C:foo" (a colon with NO separator
    # right after it) is a distinct, legal Windows path form that resolves against
    # that drive's own process-specific "current directory" -- something this function
    # has no way to know or safely guess. Falling through to the generic branches below
    # would silently rebuild the whole path as a literally-named "C:foo" directory
    # relative to the CWD (demonstrated) -- the exact stray-directory class §2.4 exists
    # to close, just for an input shape the drive-absolute fix didn't cover. Refuse
    # outright rather than guess; the caller already treats a false return as io_error.
    return 0 if $dir =~ m{^[A-Za-z]:(?![\\/])};
    my @parts = split(m{[\\/]}, $dir);
    my $cur;
    if ($dir =~ m{^([A-Za-z]:)[\\/]}) {
        # Windows drive-absolute (a03 spec §2.4/§1c): the walk must start AT the drive
        # root (e.g. "C:"), never be treated as relative -- the bug this fixes rebuilt
        # the whole tree under the process cwd as a stray "./C:/..." directory.
        $cur = $1;
        shift @parts; # the split's first element is the same "C:" already in $cur
    }
    elsif ($dir =~ m{^[\\/]}) {
        $cur = '';
    }
    else {
        $cur = '.';
    }
    for my $p (@parts) {
        next if $p eq '';
        $cur .= '/' . $p;
        next if -d $cur;
        return 0 unless mkdir($cur, 0755);
    }
    return 1;
}

sub op_rotate {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'keep=i', 'budget=i', 'dry-run'); }
    arg_error('rotate', 'unrecognised option') unless $ok;
    arg_error('rotate', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('rotate', 'missing required --ledger') unless defined $opt{ledger};
    my $keep = defined $opt{keep} ? $opt{keep} : 5;
    arg_error('rotate', "'--keep $opt{keep}' must be a non-negative integer") if $keep !~ /^\d+$/;
    my $budget = defined $opt{budget} ? $opt{budget} : DEFAULT_BUDGET_BYTES;
    arg_error('rotate', "'--budget $opt{budget}' must be a positive integer") if $budget !~ /^[1-9]\d*$/;
    my $dry_run = $opt{'dry-run'} ? 1 : 0;
    my $ledger  = $opt{ledger};

    my $history = derive_history_path($ledger);
    arg_error('rotate', "--ledger '$ledger' is not of the form .../packages/<pkg>.md; "
        . 'cannot derive the blueprint dir and package name for history routing')
        unless defined $history;

    my $lockpath = "$ledger.lock";
    open(my $lk, '>', $lockpath) or io_error('rotate', $ledger, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('rotate', $ledger, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $ledger) or io_error('rotate', $ledger, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    # Deliberately NO validate_bytes() call here (unlike the other five ops). rotate
    # is pure byte-preserving surgery, never content synthesis, and the corpus
    # contains at least one ledger with a raw NUL byte inside an entry (SYN-19: q01)
    # that V1 would otherwise reject outright — rotating that ledger back under
    # budget must not itself be blocked by the very check that flags NUL as invalid.
    my $head_re = qr/^##\s+Decisions & attempt log\b/m;
    my $loc = locate_section($orig, $head_re);
    notfound_error('rotate', $ledger, '## Decisions & attempt log section not found') unless $loc;
    notfound_error('rotate', $ledger,
        'section ends inside an unterminated fenced code block; refusing to rotate')
        if $loc->{unterminated};

    my ($entries, $preamble_end) = parse_attempt_entries($orig, $loc->{body_start}, $loc->{body_end});
    my $total = scalar @$entries;

    # b45 §3 (amended): retention is BUDGET-DRIVEN with a count FLOOR, not count-driven.
    # Mandatory, absolute, never movable at any budget: every entry with a live
    # MEANS-DEVIATION marker (any age, §1), and the most recent --keep (floor, default 5)
    # NON-marker entries, "however large they are" (a replacement coordinator always has
    # recent context). Above that floor, move as many of the OLDER non-marker entries as
    # it takes to land the whole ledger under --budget -- never fewer than needed, never
    # digging into the floor to do it.
    my @forced;     # entry indices with a live marker -- never movable, any age
    my @non_forced; # {idx, len} in original order, excluding forced
    for my $i (0 .. $total - 1) {
        my $e = $entries->[$i];
        if (entry_has_live_marker($orig, $e->{start}, $e->{end})) { push @forced, $i }
        else { push @non_forced, { idx => $i, len => $e->{end} - $e->{start} } }
    }
    my $n_nf    = scalar @non_forced;
    my $floor_k = $keep < $n_nf ? $keep : $n_nf;

    # suffix_len[$j] = total bytes of the LAST $j non-forced entries (by recency).
    my @suffix_len = (0) x ($n_nf + 1);
    for my $j (1 .. $n_nf) {
        $suffix_len[$j] = $suffix_len[$j - 1] + $non_forced[$n_nf - $j]{len};
    }
    my $forced_len = 0;
    $forced_len += ($entries->[$_]{end} - $entries->[$_]{start}) for @forced;
    my $const_len = $loc->{body_start} + ($preamble_end - $loc->{body_start})
                  + (length($orig) - $loc->{body_end}) + $forced_len;

    # Prefer the LARGEST k (fewest entries moved) that lands at/under budget, without ever
    # going below the floor. If even the floor itself is over budget, use the floor anyway
    # (it is mandatory) and report the shortfall rather than fabricate compliance.
    my $k = $n_nf;
    my $unreachable = 0;
    while ($k > $floor_k && ($const_len + $suffix_len[$k]) > $budget) { $k-- }
    if (($const_len + $suffix_len[$k]) > $budget) { $unreachable = 1 }

    my %kept_non_forced = map { $non_forced[$n_nf - $_ - 1]{idx} => 1 } (0 .. $k - 1) if $k > 0;
    my (@moved, @retained);
    for my $i (0 .. $total - 1) {
        my $e = $entries->[$i];
        if ($kept_non_forced{$i} || grep { $_ == $i } @forced) { push @retained, $e }
        else { push @moved, $e }
    }

    my $moved_bytes = 0;
    $moved_bytes += ($_->{end} - $_->{start}) for @moved;
    my $new_len = $const_len + $suffix_len[$k];

    # a03 spec §2.1/§2.3: the irreducible fact is a STATE, reported via emit_notice's
    # distinct, non-error-shaped, machine-readable-token line -- never emit_err's
    # `bp-ledger: <sub>: <path>: <msg>` shape. Diagnosis wording is preserved verbatim
    # (done-criterion 4); only the framing (prefix/token) changes.
    my $irreducible_msg = $unreachable
        ? "$ledger is $new_len bytes, over the $budget-byte budget after rotating everything it "
          . "legitimately can (floor --keep $floor_k non-marker entries (" . $suffix_len[$k]
          . " bytes) + " . scalar(@forced) . " MEANS-DEVIATION entry/ies ($forced_len bytes) + "
          . 'fixed sections are, together, already over budget). Not reducible further without '
          . 'either dropping mandated retention or losing the record.'
        : undef;

    # a03 spec §2.5: exactly one stderr line on any non-zero exit. Deferring the notice
    # to right before each SUCCESS exit point (never called on a path that is about to
    # io_error) is how this file satisfies that invariant -- by the time this runs, every
    # fallible step on that path has already succeeded. `touch_marker` is off for
    # --dry-run, which is a report-only op that touches nothing on disk (header comment,
    # bp-ledger.pl:18-19) -- the marker is disk state, so writing it would violate that.
    my $finalize_budget_state = sub {
        my (%o) = @_;
        my $touch_marker = exists $o{touch_marker} ? $o{touch_marker} : 1;
        if ($unreachable) {
            emit_notice('rotate', 'LEDGER_IRREDUCIBLE', $irreducible_msg);
            mark_irreducible($ledger) if $touch_marker;
        }
        elsif ($touch_marker) {
            # A rotate call that finds the ledger reducible (or already fine) is exactly
            # the "new rotate finds it reducible again" case spec §2.1 says must clear
            # any earlier irreducible suppression.
            clear_budget_marker($ledger);
        }
    };

    if (!@moved) {
        if ($dry_run) {
            $finalize_budget_state->(touch_marker => 0);
            print "bp-ledger: rotate: $ledger: 0 of $total entries eligible to move; nothing to do.\n";
        }
        else {
            $finalize_budget_state->();
        }
        flock($lk, LOCK_UN);
        close($lk);
        exit 0;
    }

    my $new_body = substr($orig, $loc->{body_start}, $preamble_end - $loc->{body_start})
                 . join('', map { substr($orig, $_->{start}, $_->{end} - $_->{start}) } @retained);
    my $new_ledger = substr($orig, 0, $loc->{body_start}) . $new_body . substr($orig, $loc->{body_end});
    my $history_append = join('', map { substr($orig, $_->{start}, $_->{end} - $_->{start}) } @moved);

    if ($dry_run) {
        $finalize_budget_state->(touch_marker => 0);
        my $over = $unreachable ? " -- unreachable (see prior stderr line)" : '';
        print "bp-ledger: rotate: $ledger: would move " . scalar(@moved) . " of $total entries "
            . "($moved_bytes bytes) to $history: ledger would be $new_len bytes (budget $budget)$over.\n";
        flock($lk, LOCK_UN);
        close($lk);
        exit 0;
    }

    # History first, ledger second: on ANY failure between here and the final
    # rename, the ledger (read above, untouched on disk so far) stays byte-identical
    # (spec §3 "atomic ... any failure at any point leaves the ledger byte-identical").
    # Writing history first means a crash after it succeeds risks a *duplicate*
    # history append on retry (the ledger still shows those entries as un-rotated) --
    # strictly preferable to the alternative order, which risks losing the entries
    # outright (removed from the ledger, never landed in history).
    my $hist_dir = $history;
    $hist_dir =~ s{/[^/]+$}{};
    ensure_dir_exists($hist_dir) or io_error('rotate', $ledger, "cannot create directory $hist_dir: $!");

    my $hist_orig = '';
    if (-e $history) {
        open(my $hfh, '<:raw', $history) or io_error('rotate', $ledger, "cannot read $history: $!");
        local $/;
        $hist_orig = <$hfh>;
        close $hfh;
        $hist_orig = '' unless defined $hist_orig;
    }
    my $hist_new = $hist_orig . $history_append;

    my $hist_tmp = "$history.tmp.$$";
    open(my $hw, '>:raw', $hist_tmp) or io_error('rotate', $ledger, "cannot open temp file $hist_tmp: $!");
    print {$hw} $hist_new or do { close $hw; unlink $hist_tmp; io_error('rotate', $ledger, "write to $hist_tmp failed: $!") };
    close($hw) or do { unlink $hist_tmp; io_error('rotate', $ledger, "close $hist_tmp failed: $!") };
    unless ($RENAME_FN->($hist_tmp, $history)) {
        unlink $hist_tmp;
        io_error('rotate', $ledger, "rename $hist_tmp -> $history failed: $! (ledger untouched)");
    }

    my $tmp = "$ledger.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error('rotate', $ledger, "cannot open temp file $tmp: $!");
    print {$w} $new_ledger or do { close $w; unlink $tmp; io_error('rotate', $ledger, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error('rotate', $ledger, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $ledger)) {
        unlink $tmp;
        io_error('rotate', $ledger, "rename $tmp -> $ledger failed: $!");
    }

    # Every fallible step on this path has now succeeded -- safe to finalize/notify
    # (a03 spec §2.5's one-stderr-line invariant: deferred to here, so an earlier
    # failure above never reaches this line at all).
    $finalize_budget_state->();

    flock($lk, LOCK_UN);
    close($lk);
    exit 0;
}

# =====================================================================================
# `validate` — three entry shapes (spec §2.5).
# =====================================================================================

# --- payload-mode helpers, a pure lift of ledger-guard.sh:87-329 ---------------------

sub is_str {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $f = B::svref_2object(\$v)->FLAGS;
    return 0 unless $f & B::SVp_POK();
    return 0 if $f & (B::SVp_IOK() | B::SVp_NOK());
    return 1;
}

sub as_bytes {
    my ($s) = @_;
    return '' unless defined $s;
    utf8::encode($s) unless utf8::downgrade($s, 1);
    return $s;
}

sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if $needle eq '';
    my ($n, $p) = (0, 0);
    while ((my $i = index($hay, $needle, $p)) >= 0) { $n++; $p = $i + length($needle) }
    return $n;
}

sub splice_bytes {
    my ($hay, $old, $new, $all) = @_;
    my ($out, $p) = ('', 0);
    while ((my $i = index($hay, $old, $p)) >= 0) {
        $out .= substr($hay, $p, $i - $p) . $new;
        $p = $i + length($old);
        last unless $all;
    }
    return $out . substr($hay, $p);
}

sub read_bytes_or_m6 {
    my ($path, $abs, $tool) = @_;
    open(my $fh, '<', $path) or m6_payload($abs, $tool, "cannot read $path: $!");
    binmode($fh);
    my ($out, $buf) = ('', '');
    while (1) {
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) { close $fh; m6_payload($abs, $tool, "read error on $path: $!") }
        last if $n == 0;
        $out .= $buf;
    }
    close $fh;
    return $out;
}

sub deny_payload {
    my ($msg) = @_;
    emit_err($msg);
    exit 2;
}

sub m6_payload {
    my ($abs, $tool, $reason) = @_;
    my $what = ($tool // '') ne '' ? $tool : 'write';
    deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} cannot reconstruct the content this $what would leave in "
        . "$abs ($reason), so it cannot be validated, and an unvalidated ledger write is not permitted. "
        . 'Use Write with the full file content, or Edit with a non-empty old_string, then retry.');
}

sub validate_and_exit_payload {
    my ($abs, $bytes, $old_bytes) = @_;
    my $detail = validate_bytes($bytes);
    if (defined $detail) {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} the content this write would leave in $abs $detail");
    }
    my $lu_detail = last_updated_check($old_bytes, $bytes);
    if (defined $lu_detail) {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} the content this write would leave in $abs $lu_detail");
    }
    exit 0;
}

# Best-effort read of the CURRENT on-disk bytes at $abs, for the last_updated_check's
# monotonicity comparison only. Never fatal: an unreadable or absent prior file just
# means there is nothing to compare a Write's candidate value against (a fresh ledger
# has no "older" to violate) — reconstruction failures for Edit/MultiEdit are handled
# separately by read_bytes_or_m6, since THOSE tools need the prior bytes to even know
# what they would write.
sub try_read_bytes {
    my ($path) = @_;
    return undef unless -e $path;
    return eval {
        open(my $fh, '<:raw', $path) or die "open failed";
        local $/;
        my $b = <$fh>;
        close $fh;
        defined $b ? $b : '';
    };
}

sub op_validate_payload {
    my $ABS  = defined $ENV{LG_ABS}  ? $ENV{LG_ABS}  : '';
    my $TOOL = defined $ENV{LG_TOOL} ? $ENV{LG_TOOL} : '';

    binmode STDIN;
    my $raw = do { local $/; <STDIN> };
    $raw = '' unless defined $raw;
    my $payload = eval { JSON::PP->new->decode($raw) };
    if (!defined $payload || ref($payload) ne 'HASH') {
        m6_payload($ABS, $TOOL, 'payload is not a JSON object (decode failed or non-object)');
    }
    my $ti = $payload->{tool_input};
    $ti = {} unless ref($ti) eq 'HASH';

    if ($TOOL eq 'Write') {
        my $c = $ti->{content};
        m6_payload($ABS, $TOOL, 'Write payload has no string "content" field') unless is_str($c);
        validate_and_exit_payload($ABS, as_bytes($c), try_read_bytes($ABS));
    }
    elsif ($TOOL eq 'Edit') {
        exit 0 unless -e $ABS;
        my $orig = read_bytes_or_m6($ABS, $ABS, $TOOL);
        my ($old, $new) = ($ti->{old_string}, $ti->{new_string});
        m6_payload($ABS, $TOOL, 'Edit payload has no string old_string/new_string')
            unless is_str($old) && is_str($new);
        $old = as_bytes($old);
        $new = as_bytes($new);
        m6_payload($ABS, $TOOL, 'empty old_string') if $old eq '';
        my $all = $ti->{replace_all} ? 1 : 0;
        my $n   = count_occ($orig, $old);
        exit 0 if $n == 0;
        exit 0 if $n > 1 && !$all;
        validate_and_exit_payload($ABS, splice_bytes($orig, $old, $new, $all), $orig);
    }
    elsif ($TOOL eq 'MultiEdit') {
        my $edits = $ti->{edits};
        my $bad   = '"edits" is missing or is not a non-empty array of {old_string,new_string} objects';
        m6_payload($ABS, $TOOL, $bad) unless ref($edits) eq 'ARRAY' && @$edits;
        for my $e (@$edits) {
            m6_payload($ABS, $TOOL, $bad)
                unless ref($e) eq 'HASH' && is_str($e->{old_string}) && is_str($e->{new_string});
        }
        exit 0 unless -e $ABS;
        my $buf  = read_bytes_or_m6($ABS, $ABS, $TOOL);
        my $orig = $buf;
        for my $e (@$edits) {
            my $old = as_bytes($e->{old_string});
            my $new = as_bytes($e->{new_string});
            m6_payload($ABS, $TOOL, 'empty old_string') if $old eq '';
            my $all = $e->{replace_all} ? 1 : 0;
            my $n   = count_occ($buf, $old);
            exit 0 if $n == 0;
            exit 0 if $n > 1 && !$all;
            $buf = splice_bytes($buf, $old, $new, $all);
        }
        validate_and_exit_payload($ABS, $buf, $orig);
    }
    elsif ($TOOL eq 'NotebookEdit') {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} NotebookEdit cannot target a package ledger ($ABS): "
            . 'a ledger is markdown, not a notebook. Use Edit or Write.');
    }
    else {
        m6_payload($ABS, $TOOL, $TOOL eq '' ? 'payload has no tool_name' : qq(unrecognised tool "$TOOL"));
    }
}

sub op_validate {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'stdin', 'payload'); }
    arg_error('validate', 'unrecognised option') unless $ok;
    arg_error('validate', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    my $n = (defined $opt{ledger} ? 1 : 0) + ($opt{stdin} ? 1 : 0) + ($opt{payload} ? 1 : 0);
    arg_error('validate', 'specify exactly one of --ledger, --stdin, --payload') unless $n == 1;

    if ($opt{payload}) { op_validate_payload(); return }

    my ($bytes, $label);
    if (defined $opt{ledger}) {
        $label = $opt{ledger};
        open(my $fh, '<:raw', $opt{ledger}) or io_error('validate', $opt{ledger}, "cannot read: $!");
        local $/;
        $bytes = <$fh>;
        close $fh;
        $bytes = '' unless defined $bytes;
    }
    else {
        binmode STDIN;
        local $/;
        $bytes = <STDIN>;
        $bytes = '' unless defined $bytes;
        $label = '(stdin)';
    }
    my $detail = validate_bytes($bytes);
    if (defined $detail) {
        emit_err("bp-ledger: validate: $label: $detail");
        exit 2;
    }
    # Static surface, no on-disk "before": only the future-skew half of the b19 check
    # applies here (monotonicity needs a prior value to compare against, which this
    # single-buffer surface has no notion of).
    my $lu_detail = last_updated_check(undef, $bytes);
    if (defined $lu_detail) {
        emit_err("bp-ledger: validate: $label: $lu_detail");
        exit 2;
    }
    exit 0;
}

# =====================================================================================
# `migrate-depends-on` — the repair path for a ledger the V-checks now refuse.
#
# Report 20260917-063908-db14. `blueprint/templates/blueprint.md` told the author
# that every listed package field is copied into the ledger's frontmatter, and
# listed `depends_on:` among them, while this script rejects that key on EVERY
# write. The two plugins disagreed and the authoring side won at create time, so
# blueprints authored before the rule landed carry the key in every ledger.
#
# That is worse than a normal refusal. The rejection covers `set-status`, which
# is the only sanctioned way a coordinator reaches a terminal state, so such a
# package cannot be finished, blocked OR parked -- and `gate-stop.sh` will not
# let the session end until it is. The prescribed remedy was an edit to the very
# frontmatter the protocol tells coordinators never to hand-edit: the escape
# hatch was also the thing the doctrine forbids. Measured blast radius: all five
# ledgers of one blueprint, with the rule activating MID-RUN after package 01
# had already reached done.
#
# WHY THIS CANNOT USE run_op. run_op validates the ORIGINAL bytes before calling
# the splice callback (:782) and rejects on failure -- which is the whole point
# of it, and exactly what makes it unable to repair a file whose stored form is
# already invalid. This op therefore owns its own lock/read/write, and its
# safety comes from the other end: it REFUSES unless removing `depends_on:` is
# sufficient to make the file valid. A ledger that is broken in some further way
# is left alone and reported, rather than half-repaired into a shape whose
# remaining fault is now harder to see.
# =====================================================================================

sub op_migrate_depends_on {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'dry-run'); }
    arg_error('migrate-depends-on', 'unrecognised option') unless $ok;
    arg_error('migrate-depends-on', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('migrate-depends-on', 'missing required --ledger') unless defined $opt{ledger};

    my $path = $opt{ledger};
    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath)
        or io_error('migrate-depends-on', $path, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX)
        or io_error('migrate-depends-on', $path, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $path)
            or io_error('migrate-depends-on', $path, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    my ($FM) = $orig =~ /\A---\s*\n(.*?)\n---/s;
    unless (defined $FM) {
        reject_error('migrate-depends-on', $path,
            'has no parseable frontmatter block, so there is no `depends_on:` line to move. '
          . 'This op repairs exactly one fault; fix the frontmatter first.');
    }

    # Collect the edges being moved, in file order, before removing anything.
    my @edges;
    for my $l (split(/\n/, $FM, -1)) {
        next unless $l =~ /^depends_on:\s*(.*?)\s*$/;
        push @edges, $1;
    }
    unless (@edges) {
        emit_err("bp-ledger: migrate-depends-on: $path: no frontmatter depends_on: line; nothing to do.");
        exit 0;
    }

    # Remove the key from the frontmatter block ONLY. A `depends_on:` written in
    # the body -- inside a Dependency edges section, say, or quoted in an attempt
    # log entry -- is prose and must survive untouched, so the substitution is
    # scoped to the matched block rather than run over the whole file.
    my $new_fm = join("\n", grep { !/^depends_on:/ } split(/\n/, $FM, -1));
    my $new = $orig;
    substr($new, 0, length($FM) + 8) =~ s/\A---\s*\n\Q$FM\E\n---/---\n$new_fm\n---/
        or reject_error('migrate-depends-on', $path, 'could not rewrite the frontmatter block');

    # Record the edge where it belongs. Appended, never merged into an existing
    # section body, so a hand-written Dependency edges section keeps its prose and
    # the migrated value sits beside it plainly marked as migrated.
    my $edge_txt = join(', ', map { length($_) ? $_ : '(empty)' } @edges);
    my $note = "\n## Dependency edges\n\n"
             . "- Migrated from frontmatter `depends_on:` by `bp-ledger.pl migrate-depends-on`: $edge_txt\n"
             . "  The scheduler builds its DAG from blueprint.md's package-status table; this is the\n"
             . "  record of what the ledger used to claim, kept so the edge and its reason are not lost.\n";
    if ($new =~ /^##\s+Dependency edges\b/m) {
        $new =~ s/(^##\s+Dependency edges\b[^\n]*\n)/$1\n- Migrated from frontmatter `depends_on:` by `bp-ledger.pl migrate-depends-on`: $edge_txt\n/m;
    }
    else {
        $new =~ s/\s*\z//;
        $new .= "\n$note";
    }

    # THE SAFETY PROPERTY. Removing the key must be SUFFICIENT. If the file is
    # still invalid afterwards it was broken in some further way, and a partial
    # repair would leave a harder problem wearing a "migrated" label.
    my $detail = validate_bytes($new);
    if (defined $detail) {
        reject_error('migrate-depends-on', $path,
            "removing depends_on: is not sufficient -- the ledger is still invalid: $detail "
          . 'Nothing was written. Fix the remaining fault, then re-run.');
    }
    my $lu_detail = last_updated_check($orig, $new);
    reject_error('migrate-depends-on', $path, $lu_detail) if defined $lu_detail;

    if ($opt{'dry-run'}) {
        print "bp-ledger: migrate-depends-on: $path: would move depends_on: $edge_txt\n";
        exit 0;
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp)
        or io_error('migrate-depends-on', $path, "cannot open temp file $tmp: $!");
    print {$w} $new
        or do { close $w; unlink $tmp; io_error('migrate-depends-on', $path, "write to $tmp failed: $!") };
    close($w)
        or do { unlink $tmp; io_error('migrate-depends-on', $path, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        io_error('migrate-depends-on', $path, "rename $tmp -> $path failed: $!");
    }
    print "bp-ledger: migrate-depends-on: $path: moved depends_on: $edge_txt\n";
    exit 0;
}

# =====================================================================================
# Main
# =====================================================================================

my %DISPATCH = (
    'set-status'      => \&op_set_status,
    'migrate-depends-on' => \&op_migrate_depends_on,
    'append-attempt'   => \&op_append_attempt,
    'tick-step'        => \&op_tick_step,
    'set-next-action'  => \&op_set_next_action,
    'add-output'       => \&op_add_output,
    'rotate'           => \&op_rotate,
    'validate'         => \&op_validate,
    'claim-check'      => \&op_claim_check,
);

# Guarded so ledger-guard.sh's embedded validator (b19) can `require` this file for
# its shared last_updated_check() without also running this CLI — the same
# requirable-module shape bp-orchestrator.pl already uses.
unless (caller) {
    my $sub = shift @ARGV;
    if (!defined $sub || $sub eq '') {
        arg_error('(none)', 'missing subcommand; expected one of: '
            . join(', ', sort keys %DISPATCH));
    }
    unless (exists $DISPATCH{$sub}) {
        arg_error($sub, "unknown subcommand '$sub'; expected one of: " . join(', ', sort keys %DISPATCH));
    }
    $DISPATCH{$sub}->(@ARGV);
    exit 0;
}

1;
