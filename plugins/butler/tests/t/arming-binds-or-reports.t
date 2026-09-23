#!/usr/bin/env perl
# platform: windows
# Oracle for package 13-arming-binds-or-says-so
#
# Spec: .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/
#       13-arming-binds-or-says-so-spec.md  SS3 (behaviors 1-20), SS4 (AC1-AC20).
#
# Written BLIND to the implementation: neither bp-continuity.pl nor
# gate-continuity.sh has any of this package's changes yet. Every expectation
# below is transcribed from the spec's prose, pseudocode and acceptance
# criteria table -- never inferred by reading the current source beyond what
# the spec's own "Evidence table" already quotes (anchor text, existing
# subcommand shapes, existing field names). Assertions pinning EXISTING
# behavior (must-not-break: behaviors 3, 4, 11) are expected to PASS today.
# Assertions pinning NEW behavior (the tombstone, the third status state,
# arm's prior-failure reporting, the named TTL) are expected to FAIL today,
# for the right reason: the code does not exist yet.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. bp-continuity.pl and
# gate-continuity.sh hold the machine awake for an armed session, and they do
# it from SUBPROCESSES here (backticks), where bp-keepawake.pl's `$0 =~
# /\.t\z/` guard cannot reach. CCPRAXIS_NO_WAKELOCK is the supported opt-out
# and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $SCRIPTS = "$Bin/../../scripts";
my $HOOKS   = "$Bin/../../hooks";
my $PL      = "$SCRIPTS/bp-continuity.pl";
my $GATE    = "$HOOKS/gate-continuity.sh";
my $SESSPL  = "$SCRIPTS/bp-session.pl";

ok(-f $PL,     'setup: bp-continuity.pl exists') or BAIL_OUT('script missing');
ok(-f $GATE,   'setup: gate-continuity.sh exists') or BAIL_OUT('hook missing');
ok(-f $SESSPL, 'setup: bp-session.pl exists') or BAIL_OUT('sibling script missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub new_registry { return tempdir(CLEANUP => 1) }

# A valid nonce per BpSession::valid_nonce: ^ccpx-sess-[0-9a-f]{24}-[0-9]+$
my $NONCE_SEQ = 0;
sub gen_nonce {
    $NONCE_SEQ++;
    my @h = map { sprintf('%08x', int(rand(2**32))) } 1 .. 3;
    return 'ccpx-sess-' . join('', @h) . '-' . (time() * 1000 + $NONCE_SEQ);
}

sub iso_now {
    my @t = gmtime();
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub plant_ticket {
    my ($cdir, $nonce, %opt) = @_;
    make_path("$cdir/pending");
    my $p = "$cdir/pending/$nonce";
    open my $fh, '>', $p or die "plant ticket $p: $!";
    print {$fh} ($opt{content} // ('agent ' . iso_now() . "\n"));
    close $fh;
    if (defined $opt{age_s}) {
        my $t = time() - $opt{age_s};
        utime($t, $t, $p) or diag("utime failed: $!");
    }
    return $p;
}

sub plant_beacon {
    my ($cdir, $key, $nonce) = @_;
    make_path("$cdir/beacons");
    open my $fh, '>', "$cdir/beacons/$key" or die "plant beacon: $!";
    print {$fh} "$nonce\n";
    close $fh;
}

sub plant_tombstone {
    my ($cdir, $nonce, %opt) = @_;
    make_path("$cdir/unbound");
    my $reason = $opt{reason} // 'expired';
    my $ts     = $opt{ts}     // iso_now();
    my $sid    = $opt{sid}    // 'unknown-sid';
    my $p = "$cdir/unbound/$nonce";
    open my $fh, '>', $p or die "plant tombstone $p: $!";
    print {$fh} "$reason $ts $sid\n";
    close $fh;
    if (defined $opt{age_s}) {
        my $t = time() - $opt{age_s};
        utime($t, $t, $p) or diag("utime failed: $!");
    }
    return $p;
}

sub plant_marker {
    my ($cdir, $sid, %opt) = @_;
    open my $fh, '>', "$cdir/$sid" or die "plant marker: $!";
    print {$fh} ($opt{content} // ('agent ' . iso_now() . "\n"));
    close $fh;
}

sub plant_claim_error {
    my ($cdir, %opt) = @_;
    open my $fh, '>', "$cdir/.claim-error" or die $!;
    printf {$fh} "%s %s %s\n", ($opt{rc} // 1), ($opt{ts} // iso_now()), ($opt{sid} // 'unknown-sid');
    close $fh;
    return "$cdir/.claim-error";
}

# Plant a transcript record that makes BpSession::session_for_nonce($nonce)
# resolve to $sid. transcript_roots() reads $ENV{CCPRAXIS_DATA_DIR} directly,
# so exporting it and writing under <dir>/claude-home/projects/<proj>/*.jsonl
# is the one shape this module was documented to accept (BpSession.pm's own
# transcript_roots).
sub plant_transcript {
    my ($sid, $nonce) = @_;
    my $data_root = tempdir(CLEANUP => 1);
    make_path("$data_root/claude-home/projects/testproj");
    my $file = "$data_root/claude-home/projects/testproj/rec-$$-$NONCE_SEQ.jsonl";
    open my $fh, '>', $file or die "plant transcript: $!";
    print {$fh} JSON::PP->new->canonical->encode({ sessionId => $sid, marker => $nonce }) . "\n";
    close $fh;
    return $data_root;
}

# run_pl($cdir, \@args, %opt) -> ($rc, $out). Drives bp-continuity.pl directly
# (arm/status), BP_LEDGER neutralised, registry pinned to a fresh tempdir.
sub run_pl {
    my ($cdir, $args, %opt) = @_;
    my $env = "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$cdir' BP_LEDGER= ";
    $env .= "CLAUDE_CODE_SESSION_ID='$opt{sid}' "      if defined $opt{sid};
    $env .= "CCPRAXIS_CONTINUITY_TICKET_TTL_S=$opt{ttl} " if defined $opt{ttl};
    my $argstr = join(' ', @$args);
    my $out = `${env}perl "$PL" $argstr 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

sub stop_payload {
    my ($sid) = @_;
    return JSON::PP->new->canonical->encode({ session_id => $sid });
}

# run_gate($payload, %opt) -> ($rc, $out). Copies the harness shape of
# t/continuity-gate.t's own run_gate: env-var prefix, heredoc stdin.
sub run_gate {
    my ($payload, %opt) = @_;
    my $env = "CCPRAXIS_CONTINUITY_SKIP_IDLE_EXIT=1 BP_LEDGER= ";
    $env .= "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$opt{cdir}' "   if defined $opt{cdir};
    $env .= "CCPRAXIS_CONTINUITY_TICKET_TTL_S=$opt{ttl} "    if defined $opt{ttl};
    $env .= "CCPRAXIS_DATA_DIR='$opt{ddata}' "                if defined $opt{ddata};
    my $out = `${env}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# ===========================================================================
# AC1 / behavior 7: status on a tombstone for the beacon's nonce -> unbound,
# not unarmed, not arming.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac1';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_tombstone($cdir, $nonce, sid => $sid, reason => 'expired');

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid);
    is($rc, 0, 'AC1a: status on a tombstoned nonce exits 0');
    like($out, qr/^STATUS:\s*unbound\s*$/m, 'AC1b/behavior 7: STATUS: unbound');
    unlike($out, qr/^STATUS:\s*unarmed\s*$/m, 'AC1c: not unarmed');
    unlike($out, qr/^STATUS:\s*arming\s*$/m,  'AC1d: not arming');
    like($out, qr/^NONCE:\s*\Q$nonce\E\s*$/m, 'AC1e: NONCE line names the tombstoned nonce');
    like($out, qr/^UNBOUND_REASON:\s*expired\s*$/m, 'AC1f: UNBOUND_REASON: expired');
    # driver fix (package 13, 2026-09-23): spec SS2.3 pins `status`'s unbound
    # branch to emit, "in this order," STATUS/SESSION/CONFIDENCE/NONCE/
    # UNBOUND_REASON/UNBOUND_SINCE before WARN -- so WARN cannot legally be
    # the first line of the captured string, and `^` without /m only anchors
    # to the string's absolute start. /ms anchors per-line instead, which is
    # what these assertions actually mean to check (WARN starts a line and
    # contains the required substrings), without relaxing the ordering pin.
    like($out, qr/^WARN:.*did NOT bind/ms,       'AC1g: WARN mentions "did NOT bind"');
    like($out, qr/^WARN:.*nothing was gated/ms,  'AC1h: WARN mentions "nothing was gated"');
}

# ===========================================================================
# AC2 / behavior 9: status on a live fresh ticket -> arming, with
# TICKET_TTL_S / TICKET_AGE_S / BINDS_BY.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac2';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_ticket($cdir, $nonce);   # fresh, mtime = now

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid, ttl => 3600);
    is($rc, 0, 'AC2a: status on a fresh ticket exits 0');
    like($out, qr/^STATUS:\s*arming\s*$/m, 'AC2b/behavior 9: STATUS: arming');
    like($out, qr/^TICKET_TTL_S:\s*3600\s*$/m, 'AC2c: TICKET_TTL_S present and honours the env TTL');
    like($out, qr/^TICKET_AGE_S:\s*\d+\s*$/m,  'AC2d: TICKET_AGE_S present');
    like($out, qr/^BINDS_BY:\s*\S+/m,          'AC2e: BINDS_BY present');
    unlike($out, qr/^STATUS:\s*unbound\s*$/m, 'AC2f: not unbound');
}

# ===========================================================================
# AC3 / behavior 11: a marker takes precedence over a tombstone.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac3';
    my $nonce = gen_nonce();
    plant_marker($cdir, $sid);
    plant_tombstone($cdir, $nonce, sid => $sid);

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid);
    is($rc, 0, 'AC3a: status with a marker exits 0');
    like($out, qr/^STATUS:\s*armed\s*$/m, 'AC3b/behavior 11: STATUS: armed even with a tombstone present');
    unlike($out, qr/^STATUS:\s*unbound\s*$/m, 'AC3c: a stale tombstone never downgrades an armed session');
}

# ===========================================================================
# AC4 / behavior 8: an over-age ticket with no tombstone and no gate run ->
# unbound, window_passed.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac4';
    my $nonce = gen_nonce();
    my $ttl   = 5;
    plant_beacon($cdir, $sid, $nonce);
    plant_ticket($cdir, $nonce, age_s => $ttl + 30);   # aged well past the ticket TTL

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid, ttl => $ttl);
    is($rc, 0, 'AC4a: status on an over-age ticket exits 0');
    like($out, qr/^STATUS:\s*unbound\s*$/m, 'AC4b/behavior 8: STATUS: unbound with no gate run at all');
    like($out, qr/^UNBOUND_REASON:\s*window_passed\s*$/m, 'AC4c: UNBOUND_REASON: window_passed');
}

# ===========================================================================
# AC5 / behavior 10: a fully empty registry still reports unarmed with none
# of the new keys.
# ===========================================================================
{
    my $cdir = new_registry();
    my $sid  = 'sess-ac5';

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid);
    is($rc, 0, 'AC5a: status on an empty registry exits 0');
    like($out, qr/^STATUS:\s*unarmed\s*$/m, 'AC5b/behavior 10: STATUS: unarmed');
    unlike($out, qr/^STATUS:\s*unbound\s*$/m, 'AC5c: a new state does not fire everywhere');
    unlike($out, qr/^UNBOUND_REASON:/m, 'AC5d: no UNBOUND_REASON key');
    unlike($out, qr/^UNBOUND_PRIOR:/m,  'AC5e: no UNBOUND_PRIOR key');
    unlike($out, qr/^TICKET_TTL_S:/m,   'AC5f: no TICKET_TTL_S key');
}

# ===========================================================================
# AC6 / behavior 13: the next arm reports a prior unbound failure, then
# still succeeds.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac6';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_tombstone($cdir, $nonce, sid => $sid);

    my ($rc, $out) = run_pl($cdir, ['arm'], sid => $sid);
    is($rc, 0, 'AC6a: arm with a prior tombstone still succeeds (exit 0)');
    like($out, qr/^UNBOUND_PRIOR:\s*\Q$nonce\E\s*$/m, 'AC6b/behavior 13: UNBOUND_PRIOR names the tombstoned nonce');
    like($out, qr/^WARN:.*previous arm/s,    'AC6c: WARN mentions "previous arm"');
    like($out, qr/^WARN:.*never bound/s,     'AC6d: WARN mentions "never bound"');
    like($out, qr/^WARN:.*nothing was gated/s, 'AC6e: WARN mentions "nothing was gated"');
    like($out, qr/^STATUS:\s*arming\s*$/m,   'AC6f: the arm itself still succeeds (fresh nonce)');

    # Ordering: UNBOUND_PRIOR/WARN must precede the arm's own STATUS: line.
    if ($out =~ /^(UNBOUND_PRIOR:.*)$/m) {
        my $prior_pos  = index($out, 'UNBOUND_PRIOR:');
        my $status_pos = index($out, "\nSTATUS:");
        cmp_ok($prior_pos, '<', $status_pos, 'AC6g: UNBOUND_PRIOR precedes the arm\'s own STATUS: line')
            if $prior_pos >= 0 && $status_pos >= 0;
    } else {
        fail('AC6g: UNBOUND_PRIOR line present to order against STATUS:');
    }
}

# ===========================================================================
# AC7 / behavior 14: the warning fires once -- an immediate second arm prints
# no UNBOUND_PRIOR, and the tombstone is gone.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac7';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_tombstone($cdir, $nonce, sid => $sid);

    my (undef, $out1) = run_pl($cdir, ['arm'], sid => $sid);
    like($out1, qr/^UNBOUND_PRIOR:/m, 'AC7 setup: the first arm DOES report the prior tombstone');

    my (undef, $out2) = run_pl($cdir, ['arm'], sid => $sid);
    unlike($out2, qr/^UNBOUND_PRIOR:/m, 'AC7/behavior 14: an immediate second arm prints no UNBOUND_PRIOR');
    ok(!-f "$cdir/unbound/$nonce", 'AC7: ...and the tombstone file no longer exists');
}

# ===========================================================================
# AC8 / behavior 15: a clean arm on an empty registry is silent about all
# three new diagnostics.
# ===========================================================================
{
    my $cdir = new_registry();
    my $sid  = 'sess-ac8';

    my ($rc, $out) = run_pl($cdir, ['arm'], sid => $sid);
    is($rc, 0, 'AC8a: a clean arm succeeds');
    unlike($out, qr/^UNBOUND_PRIOR:/m, 'AC8b/behavior 15: no UNBOUND_PRIOR on a clean arm');
    unlike($out, qr/^CLAIM_ERROR:/m,   'AC8c: no CLAIM_ERROR on a clean arm');
    unlike($out, qr/did NOT bind/,     'AC8d: no binding-related WARN on a clean arm');
}

# ===========================================================================
# AC9 / behavior 1: a claim that expires a ticket leaves a tombstone whose
# first line begins "expired" and whose third field is the Stop payload's
# session_id.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac9';
    my $nonce = gen_nonce();
    my $ttl   = 2;
    plant_ticket($cdir, $nonce, age_s => $ttl + 30);   # aged well past the ticket TTL

    my ($rc, $out) = run_gate(stop_payload($sid), cdir => $cdir, ttl => $ttl);
    my $tpath = "$cdir/unbound/$nonce";
    ok(-f $tpath, 'AC9a/behavior 1: the gate wrote a tombstone for the expired nonce') or diag("gate output:\n$out");
    SKIP: {
        skip 'no tombstone written -- cannot inspect its content', 2 unless -f $tpath;
        open my $fh, '<', $tpath or die $!;
        my $line = <$fh> // '';
        close $fh;
        chomp $line;
        like($line, qr/^expired\b/, 'AC9b: first line begins with "expired"');
        my @fields = split ' ', ($line // '');
        is($fields[2], $sid, 'AC9c: third whitespace field is the payload\'s session_id');
    }
}

# ===========================================================================
# AC10 / behavior 2: the same run writes the required stderr diagnostic.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac10';
    my $nonce = gen_nonce();
    my $ttl   = 2;
    plant_ticket($cdir, $nonce, age_s => $ttl + 30);

    my (undef, $out) = run_gate(stop_payload($sid), cdir => $cdir, ttl => $ttl);
    like($out, qr/butler continuity-gate:/, 'AC10a: diagnostic present');
    like($out, qr/did NOT bind/,            'AC10b: "did NOT bind"');
    like($out, qr/\Q$nonce\E/,              'AC10c: names the nonce');
    like($out, qr/CCPRAXIS_CONTINUITY_TICKET_TTL_S/, 'AC10d: names the env var');
    like($out, qr/not armed/,               'AC10e: "not armed"');
}

# ===========================================================================
# AC11 / behavior 3: recording the failure never moves the gate's verdict --
# a session with no marker still stands aside (exit 0), exactly as before.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac11';
    my $nonce = gen_nonce();
    my $ttl   = 2;
    plant_ticket($cdir, $nonce, age_s => $ttl + 30);

    my ($rc, $out) = run_gate(stop_payload($sid), cdir => $cdir, ttl => $ttl);
    is($rc, 0, 'AC11/behavior 3: the gate\'s verdict is unchanged -- exit 0, stands aside');
    unlike($out, qr/BLOCKED/, 'AC11: recording the failure never blocks the turn');
}

# ===========================================================================
# AC12 / behavior 4: a ticket that DOES bind leaves a marker, removes the
# ticket, creates no tombstone, and prints no binding diagnostic.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac12';
    my $nonce = gen_nonce();
    plant_ticket($cdir, $nonce);   # fresh
    my $ddata = plant_transcript($sid, $nonce);
    # driver fix (package 13, 2026-09-23): CCPRAXIS_CONTINUITY_SKIP_IDLE_EXIT=1
    # (set by run_gate on every call, deliberately, to keep this suite
    # deterministic and independent of this repo's own real blueprint state)
    # means the gate's only remaining "stand aside" path once a marker exists
    # is genuinely-scheduled work -- something this package's write set does
    # not touch (SS6: "no change to ... the idle-exit branch ... or the block
    # message"). AC12 is about the binding side-effects (b/c/d/e below), not
    # the block-vs-allow decision, so plant a one-shot .stop-ok -- checked
    # AFTER the claim/binding logic runs -- to observe binding cleanly without
    # exercising real ledger state.
    open my $stopok_fh, '>', "$cdir/$sid.stop-ok" or die "stop-ok: $!";
    close $stopok_fh;

    my ($rc, $out) = run_gate(stop_payload($sid), cdir => $cdir, ddata => $ddata);
    is($rc, 0, 'AC12a: a binding stop exits 0');
    ok(-f "$cdir/$sid",            'AC12b/behavior 4: the marker now exists');
    ok(!-f "$cdir/pending/$nonce", 'AC12c: the ticket is gone');
    ok(!-f "$cdir/unbound/$nonce", 'AC12d: no tombstone was created for the bound nonce');
    unlike($out, qr/did NOT bind/, 'AC12e: no binding diagnostic on stderr');
}

# ===========================================================================
# AC13 / behavior 5: a fresh, unresolvable ticket produces no tombstone --
# "arming, still live" is not misreported as failure.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac13';
    my $nonce = gen_nonce();
    plant_ticket($cdir, $nonce);   # fresh, nonce resolves to nobody

    my (undef, $out) = run_gate(stop_payload($sid), cdir => $cdir);
    ok(!-f "$cdir/unbound/$nonce", 'AC13/behavior 5: no tombstone for a fresh, still-live ticket');
    unlike($out, qr/did NOT bind/, 'AC13: no binding-failure diagnostic either');
}

# ===========================================================================
# AC14 / behavior 19: source assertion -- the discarding invocation is gone,
# and the claim's exit status is captured.
# ===========================================================================
{
    open my $fh, '<', $GATE or die "read $GATE: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    unlike($src, qr/claim\s+--session\s+"\$SID"\s*>\s*\/dev\/null\s+2>&1\s*\|\|\s*true/,
        'AC14a/behavior 19: the discarding claim invocation no longer appears verbatim');
    like($src, qr/claim\b.*\n?.*\$\?/s,
        'AC14b: the claim call\'s exit status is captured into a variable somewhere nearby')
        or diag('looked for a claim invocation followed by a $? capture');
}

# ===========================================================================
# AC15 / behavior 16: arm names the binding window (TICKET_TTL_S, BINDS_BY),
# honouring the env TTL.
# ===========================================================================
{
    my $cdir = new_registry();
    my $sid  = 'sess-ac15a';
    my ($rc, $out) = run_pl($cdir, ['arm'], sid => $sid);
    is($rc, 0, 'AC15a: arm succeeds');
    like($out, qr/^TICKET_TTL_S:\s*3600\s*$/m, 'AC15b/behavior 16: TICKET_TTL_S defaults to 3600');
    like($out, qr/^BINDS_BY:\s*\S+/m,          'AC15c: BINDS_BY present');

    my $cdir2 = new_registry();
    my $sid2  = 'sess-ac15b';
    my ($rc2, $out2) = run_pl($cdir2, ['arm'], sid => $sid2, ttl => 120);
    is($rc2, 0, 'AC15d: arm succeeds with a custom TTL');
    like($out2, qr/^TICKET_TTL_S:\s*120\s*$/m, 'AC15e: TICKET_TTL_S honours CCPRAXIS_CONTINUITY_TICKET_TTL_S');
}

# ===========================================================================
# AC16 / behavior 12: CONFIDENCE: unverified survives the new state -- a
# tombstone naming the raw env session id, resolved with no beacon at all.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-ac16';
    my $nonce = gen_nonce();
    # Deliberately NO beacon: resolve_session_full falls through to the raw
    # env value, confidence 'unverified'. The fallback branch (SS2.3) must
    # find this tombstone by scanning unbound/ for one naming $sid.
    plant_tombstone($cdir, $nonce, sid => $sid);

    my ($rc, $out) = run_pl($cdir, ['status'], sid => $sid);
    is($rc, 0, 'AC16a: status exits 0');
    like($out, qr/^STATUS:\s*unbound\s*$/m,     'AC16b/behavior 12: STATUS: unbound via the beacon-less fallback');
    like($out, qr/^CONFIDENCE:\s*unverified\s*$/m, 'AC16c: CONFIDENCE: unverified is still emitted');
}

# ===========================================================================
# AC17: the status vocabulary is a pure function of registry contents, never
# of confidence -- same unverified setup, different registry contents.
# ===========================================================================
{
    # (a) a fresh, live ticket with an unresolvable nonce: still "arming".
    my $cdir  = new_registry();
    my $sid   = 'sess-ac17a';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_ticket($cdir, $nonce);   # fresh; nonce resolves to nobody -> unverified

    my (undef, $out) = run_pl($cdir, ['status'], sid => $sid);
    like($out, qr/^STATUS:\s*arming\s*$/m, 'AC17a: unverified + fresh ticket -> still "arming"');
    unlike($out, qr/^STATUS:\s*unbound\s*$/m, 'AC17b: ...never "unbound" merely because confidence is low');

    # (b) an empty registry: still "unarmed".
    my $cdir2 = new_registry();
    my $sid2  = 'sess-ac17b';
    my (undef, $out2) = run_pl($cdir2, ['status'], sid => $sid2);
    like($out2, qr/^STATUS:\s*unarmed\s*$/m, 'AC17c: unverified + empty registry -> still "unarmed"');
    unlike($out2, qr/^STATUS:\s*unbound\s*$/m, 'AC17d: ...never "unbound" here either');
}

# ===========================================================================
# AC18: source assertion -- the write set is exactly the three named files,
# and cmd_arm/cmd_status do not call directly into BpContinuityLease (their
# existing lease integration goes through hold_lease()/lease_report(), and
# this package's new code must not add a second, direct path).
# ===========================================================================
{
    my $repo_root = "$Bin/../../../..";
    ok(-f "$repo_root/plugins/butler/scripts/bp-continuity.pl", 'AC18a: write-set file 1 exists');
    ok(-f "$repo_root/plugins/butler/hooks/gate-continuity.sh",  'AC18b: write-set file 2 exists');
    ok(-f "$repo_root/plugins/butler/tests/t/arming-binds-or-reports.t", 'AC18c: write-set file 3 (this file) exists');

    open my $fh, '<', $PL or die "read $PL: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    for my $sub (qw(cmd_arm cmd_status)) {
        if ($src =~ /^sub \Q$sub\E \{(.*?)\n\}\n/ms) {
            my $body = $1;
            # crude but sufficient: strip any nested "sub NAME { ... }" this
            # regex might have over-captured by stopping at the first
            # top-level "\n}\n" -- acceptable false-negative risk given this
            # is a structural sentinel, not the sole guard on DC5.
            unlike($body, qr/BpContinuityLease/,
                "AC18d: sub $sub does not reference BpContinuityLease directly");
        } else {
            fail("AC18d: could not locate sub $sub to inspect");
        }
    }
}

# ===========================================================================
# AC19: the two sibling test files this package must not edit stay green.
# ===========================================================================
{
    for my $sibling (qw(run-continuity-gaps.t continuity-lease-liveness.t)) {
        my $path = "$Bin/$sibling";
        ok(-f $path, "AC19 setup: $sibling exists") or next;
        my $out = `perl "$path" 2>&1`;
        my $rc = $? >> 8;
        is($rc, 0, "AC19: $sibling exits 0 (green, unedited by this package)")
            or diag(substr($out, -2000));
        unlike($out, qr/^not ok/m, "AC19: $sibling reports no failing assertions");
    }
}

# ===========================================================================
# AC20 / behavior 20: unbound/ is never mistaken for an arm -- a tombstone
# present, no marker anywhere, gate for an unrelated session exits 0 and
# creates no marker.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $nonce = gen_nonce();
    plant_tombstone($cdir, $nonce, sid => 'sess-ac20-owner');

    my $unrelated = 'sess-ac20-unrelated';
    my ($rc, $out) = run_gate(stop_payload($unrelated), cdir => $cdir);
    is($rc, 0, 'AC20a/behavior 20: an unrelated session\'s Stop exits 0 with only a tombstone present');
    ok(!-f "$cdir/$unrelated", 'AC20b: no marker was created for the unrelated session');
}

# ===========================================================================
# BEH6 (no dedicated AC in the table, but numbered in SS3): a claim that
# itself fails (non-zero exit) is recorded in .claim-error, and stderr names
# claim, the exit code and "not armed". Forced by an invalid session id
# (bp-session.pl's own claim rejects chars [/\\*.\x00]).
# ===========================================================================
{
    my $cdir = new_registry();
    my $nonce = gen_nonce();
    plant_ticket($cdir, $nonce);   # HAVE_PENDING must be true to reach the claim call
    my $bad_sid = 'bad.session.id';   # '.' makes bp-session.pl's claim exit 1

    my (undef, $out) = run_gate(stop_payload($bad_sid), cdir => $cdir);
    my $err_path = "$cdir/.claim-error";
    ok(-f $err_path, 'BEH6a: a failed claim leaves .claim-error') or diag("gate output:\n$out");
    SKIP: {
        skip 'no .claim-error to inspect', 1 unless -f $err_path;
        open my $fh, '<', $err_path or die $!;
        my $line = <$fh> // '';
        close $fh;
        chomp $line;
        my @fields = split ' ', $line;
        is($fields[0], 1, 'BEH6b: first field is the claim exit code');
    }
    like($out, qr/butler continuity-gate:/, 'BEH6c: diagnostic present');
    like($out, qr/claim/,      'BEH6d: names "claim"');
    like($out, qr/\b1\b/,      'BEH6e: names the exit code');
    like($out, qr/not armed/,  'BEH6f: "not armed"');
}

# ===========================================================================
# BEH17 (no dedicated AC number, but explicit behavior 17): arm consumes a
# .claim-error record -- prints it once, removes it, silent on the next arm.
# ===========================================================================
{
    my $cdir = new_registry();
    my $sid  = 'sess-beh17';
    plant_claim_error($cdir, rc => 7, sid => $sid);

    my (undef, $out1) = run_pl($cdir, ['arm'], sid => $sid);
    like($out1, qr/^CLAIM_ERROR:.*7/m, 'BEH17a: the first arm prints CLAIM_ERROR with the recorded line');
    ok(!-f "$cdir/.claim-error", 'BEH17b: ...and removes the file');

    my (undef, $out2) = run_pl($cdir, ['arm'], sid => $sid);
    unlike($out2, qr/^CLAIM_ERROR:/m, 'BEH17c: a second arm prints nothing about it');
}

# ===========================================================================
# BEH18 (behavior 18): arm supersedes its own prior live ticket -- the old
# pending ticket is gone, exactly one new ticket exists.
# ===========================================================================
{
    my $cdir  = new_registry();
    my $sid   = 'sess-beh18';
    my $nonce = gen_nonce();
    plant_beacon($cdir, $sid, $nonce);
    plant_ticket($cdir, $nonce);   # fresh, live

    my ($rc, $out) = run_pl($cdir, ['arm'], sid => $sid);
    is($rc, 0, 'BEH18a: arm succeeds');
    ok(!-f "$cdir/pending/$nonce", 'BEH18b/behavior 18: the old ticket is gone');

    opendir(my $dh, "$cdir/pending") or die "opendir pending: $!";
    my @tickets = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
    is(scalar(@tickets), 1, 'BEH18c: exactly one ticket exists in pending/ after the supersede');
}

done_testing();
