#!/usr/bin/env perl
# 184 — WHICH SESSION AM I, and who is allowed to say.
#
# THE FAILURE THIS REPLACES. bp-continuity.pl guessed the live session id from
# ${CLAUDE_SESSION_ID}, a Claude Code TEMPLATE SUBSTITUTION baked into a skill
# body at render time -- not an environment variable, and never verified against
# anything. The consumer disagreed: gate-continuity.sh looks its marker up by the
# session_id in its own hook payload and exits SILENTLY when there is none. One
# unverified writer, one authoritative reader, no comparison between them, so any
# disagreement produced the worst outcome available -- "armed" reported, nothing
# enforced. An operator hit exactly that after a container rebuild + resume.
#
# THE MECHANISM NOW. A Bash tool call is never told which session is live, but a
# HOOK is. So `arm` writes a TICKET carrying a nonce and prints the nonce (which
# lands in the arming session's transcript), and the Stop hook binds that ticket
# to the session whose transcript actually carries it. Binding requires TWO
# independent facts to agree: the transcript record says which session printed
# the nonce, the hook payload says which session is stopping.
#
#
# WHY THE RECORD AND NOT THE FILENAME. Each record carries its own `sessionId`,
# and that is what is read -- never the .jsonl's name. Measured: `--resume`
# creates a NEW transcript with a NEW id, and separately, every record carrying
# both `sessionId` and `session_id` has them DIFFERENT (`session_id` is the
# predecessor in a resume chain, not a synonym). So a name-or-second-field
# shortcut would bind a ticket to a session that has already ended. AC3 pins the
# general case: filename and record disagreeing, record wins.
#
# WHY UNIQUENESS IS REQUIRED. A tool call's COMMAND TEXT is recorded in the
# transcript, not just its output -- so a nonce merely NAMED on a command line
# is planted in that session's transcript by the naming. Measured while building
# this: querying a never-planted nonce resolved to the querying session. A
# "first match wins" scan would therefore let any session claim any ticket by
# mentioning its nonce. AC4 pins the refusal.
#
# AC1  a ticket binds to the session whose transcript carries its nonce
# AC2  and to NO other session, however many are stopping (the concurrency case)
# AC3  the id comes from the record's sessionId, not the transcript's filename
# AC4  an ambiguous nonce (in two transcripts) resolves to nothing at all
# AC5  a ticket past its TTL is expired rather than left to bind late
# AC6  arm writes a ticket and arms nothing; the gate's claim is what arms
# AC7  disarm cancels a still-unbound ticket
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

my $SESSION_PL = "$Bin/../../scripts/bp-session.pl";
my $CONT_PL    = "$Bin/../../scripts/bp-continuity.pl";
ok(-f $SESSION_PL, 'bp-session.pl exists') or BAIL_OUT('script missing');
ok(-f $CONT_PL,    'bp-continuity.pl exists') or BAIL_OUT('script missing');

require "$Bin/../../scripts/BpSession.pm";

# A world of its own. Redirecting HOME and USERPROFILE is NOT sufficient, and
# an earlier version of this comment claimed it was: transcript_roots also walks
# UP FROM THE CWD looking for .ccpraxis-local-data/claude-home/projects, and
# this repo has one, so every test was still reading the real machine's
# transcripts. AC4 (ambiguity) is the assertion whose outcome depends on
# unrelated on-disk state, so that was a live flake, not a cosmetic slip.
#
# Every child therefore runs with its cwd inside the temp world (see run_cli),
# where that walk finds nothing. Isolation is now a property of the fixture
# rather than a claim in a comment.
sub new_world {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home/.claude/projects/proj");
    make_path("$root/reg/pending");
    return $root;
}

sub world_env {
    my ($root, %extra) = @_;
    return {
        HOME                            => "$root/home",
        USERPROFILE                     => "$root/home",
        CCPRAXIS_CONTINUITY_ACTIVE_DIR  => "$root/reg",
        CLAUDE_CONFIG_DIR               => undef,
        CCPRAXIS_DATA_DIR               => undef,
        CLAUDE_SESSION_ID               => undef,
        CLAUDE_CODE_SESSION_ID          => undef,
        BP_LEDGER                       => undef,
        %extra,
    };
}

sub run_cli {
    my ($script, $args, $env) = @_;
    local %ENV = %ENV;
    for my $k (sort keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} }
        else                    { delete $ENV{$k} }
    }
    my $argstr = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @$args;
    # Run INSIDE the temp world, so transcript_roots' walk up from the cwd finds
    # no .ccpraxis-local-data and the child cannot see this repo's transcripts.
    my $home = $env->{HOME};
    my $prefix = (defined $home && -d $home) ? "cd '$home' && " : '';
    my $out = `$prefix perl "$script" $argstr 2>&1`;
    return (defined($out) ? $out : '', $? >> 8);
}

sub kv {
    my ($out, $key) = @_;
    return $1 if $out =~ /^\Q$key\E:\s*(.*)$/m;
    return undef;
}

# Write a transcript record carrying $nonce. $file_id names the .jsonl; $rec_id
# goes in the record's sessionId. They differ only where a test wants them to.
sub plant {
    my ($root, $file_id, $rec_id, $nonce, %opt) = @_;
    my $path = "$root/home/.claude/projects/proj/$file_id.jsonl";
    open my $fh, '>>:raw', $path or die "plant $path: $!";
    my %rec = (type => 'user', toolUseResult => { stdout => "NONCE: $nonce" });
    $rec{sessionId} = $rec_id unless $opt{no_session_field};
    print {$fh} JSON::PP->new->canonical->encode(\%rec), "\n";
    close $fh;
    return $path;
}

sub make_ticket {
    my ($root, $nonce) = @_;
    open my $fh, '>', "$root/reg/pending/$nonce" or die $!;
    print {$fh} "operator 2026-09-10T00:00:00Z\n";
    close $fh;
}

# Nonces are generated IN PROCESS and never interpolated into a shell command,
# for the reason AC4 exists: naming one on a command line plants it.
sub fresh_nonce { return BpSession::new_nonce() }

# ── AC1/AC2 — binding, and the concurrency counter-check ──────────────────
{
    my $root  = new_world();
    my $mine  = '11111111-1111-1111-1111-111111111111';
    my $other = '22222222-2222-2222-2222-222222222222';
    my $nonce = fresh_nonce();

    plant($root, $mine, $mine, $nonce);
    make_ticket($root, $nonce);

    my ($o1, $rc1) = run_cli($SESSION_PL, ['claim', '--session', $other], world_env($root));
    is($rc1, 0, 'AC2 claim by another session exits cleanly');
    is(kv($o1, 'STATUS'), 'nothing_bound',
       'AC2 CANONICAL: a session that did not print the nonce cannot claim the ticket -- '
     . 'this is what makes a shared registry safe for concurrent sessions');
    ok(!-f "$root/reg/$other", 'AC2 no marker for the other session');
    ok(-f "$root/reg/pending/$nonce", 'AC2 and the ticket is still pending');

    my ($o2, $rc2) = run_cli($SESSION_PL, ['claim', '--session', $mine], world_env($root));
    is($rc2, 0, 'AC1 claim by the printing session exits cleanly');
    is(kv($o2, 'STATUS'), 'bound', 'AC1 STATUS: bound');
    is(kv($o2, 'BOUND'), $mine, 'AC1 bound to the session whose transcript carries the nonce');
    ok(-f "$root/reg/$mine", 'AC1 CANONICAL: the marker now exists under the real session id');
    ok(!-f "$root/reg/pending/$nonce", 'AC1 and the ticket is consumed, so it cannot bind twice');

    open my $fh, '<', "$root/reg/$mine" or die $!;
    my $line = <$fh>;
    close $fh;
    like($line, qr/^operator\s+\S+/,
         'AC1 the marker keeps the ticket line shape, so status and the badge read it unchanged');
}

# ── AC3 — the record wins over the filename (the resume case) ─────────────
{
    my $root     = new_world();
    my $resumed  = '33333333-3333-3333-3333-333333333333';   # the file's name
    my $live     = '44444444-4444-4444-4444-444444444444';   # the record's id
    my $nonce    = fresh_nonce();

    # A file whose NAME is one session and whose RECORD is another.
    #
    # The scenario originally written here was wrong and is worth correcting
    # rather than deleting: it claimed a resumed session appends to the
    # transcript it resumed. Measured on real transcripts, `--resume` produces a
    # NEW file with a NEW id, so that particular shape does not arise that way.
    # What DOES arise is the general case this pins -- filename and record
    # disagreeing -- which the resolver must survive however it is produced,
    # because reading the filename would arm a session that is not the one whose
    # tool output this is. The rule (record over filename) is right; only the
    # story justifying it was.
    plant($root, $resumed, $live, $nonce);
    make_ticket($root, $nonce);

    my ($out) = run_cli($SESSION_PL, ['claim', '--session', $live], world_env($root));
    is(kv($out, 'STATUS'), 'bound',
       'AC3 CANONICAL: the id comes from the record, so a resumed session binds correctly');
    ok(-f "$root/reg/$live", 'AC3 marker under the live id');
    ok(!-f "$root/reg/$resumed", 'AC3 and nothing under the transcript filename');
}

# ── AC4 — an ambiguous nonce resolves to nothing ──────────────────────────
{
    my $root  = new_world();
    my $a     = '55555555-5555-5555-5555-555555555555';
    my $b     = '66666666-6666-6666-6666-666666666666';
    my $nonce = fresh_nonce();

    # The same nonce present in two sessions' transcripts -- what happens when
    # one session NAMES another's nonce on a command line.
    plant($root, $a, $a, $nonce);
    plant($root, $b, $b, $nonce);
    make_ticket($root, $nonce);

    my ($oa) = run_cli($SESSION_PL, ['claim', '--session', $a], world_env($root));
    is(kv($oa, 'STATUS'), 'nothing_bound',
       'AC4 CANONICAL: an ambiguous nonce binds to NOBODY -- refusing to answer is safe, '
     . 'guessing would arm the wrong session silently');
    my ($ob) = run_cli($SESSION_PL, ['claim', '--session', $b], world_env($root));
    is(kv($ob, 'STATUS'), 'nothing_bound', 'AC4 and not to the other one either');
    ok(-f "$root/reg/pending/$nonce",
       'AC4 the ticket stays pending, so it expires visibly instead of binding wrongly');
}

# ── AC5 — a ticket past its TTL is expired ────────────────────────────────
{
    my $root  = new_world();
    my $sid   = '77777777-7777-7777-7777-777777777777';
    my $nonce = fresh_nonce();
    plant($root, $sid, $sid, $nonce);
    make_ticket($root, $nonce);
    my $old = time() - 7200;
    utime($old, $old, "$root/reg/pending/$nonce");

    my ($out) = run_cli($SESSION_PL, ['claim', '--session', $sid],
                        world_env($root, CCPRAXIS_CONTINUITY_TICKET_TTL_S => '60'));
    is(kv($out, 'EXPIRED'), $nonce, 'AC5 an over-age ticket is reported expired');
    ok(!-f "$root/reg/pending/$nonce", 'AC5 and removed');
    ok(!-f "$root/reg/$sid",
       'AC5 CANONICAL: it does NOT bind late -- a session that never reached a Stop and '
     . 'one that has since died look identical from here');
}

# ── AC6 — arm writes a ticket and arms nothing ────────────────────────────
{
    my $root = new_world();
    my ($out, $rc) = run_cli($CONT_PL, ['arm', '--by', 'operator'], world_env($root));
    is($rc, 0, 'AC6 arm exits 0');
    is(kv($out, 'STATUS'), 'arming', 'AC6 STATUS: arming, not armed');
    my $nonce = kv($out, 'NONCE');
    like($nonce // '', qr/\Accpx-sess-/, 'AC6 it prints the nonce it will be identified by');
    ok(-f "$root/reg/pending/$nonce", 'AC6 a ticket exists under that nonce');

    opendir(my $dh, "$root/reg") or die $!;
    my @markers = grep { !/^\.\.?$/ && $_ ne 'pending' && $_ ne 'beacons' } readdir $dh;
    closedir $dh;
    is(scalar(@markers), 0,
       'AC6 CANONICAL: no marker under any name -- arming a guessed id is the failure '
     . 'being removed, so nothing is armed until a hook confirms the session');

    # Now let the session that "printed" it claim it, end to end.
    my $sid = '88888888-8888-8888-8888-888888888888';
    plant($root, $sid, $sid, $nonce);
    my ($cout) = run_cli($SESSION_PL, ['claim', '--session', $sid], world_env($root));
    is(kv($cout, 'STATUS'), 'bound', 'AC6 and the gate binding it is what arms it');
    ok(-f "$root/reg/$sid", 'AC6 marker present after binding');
}

# ── AC7 — disarm cancels an unbound ticket ────────────────────────────────
{
    my $root = new_world();
    my $env  = world_env($root, CLAUDE_CODE_SESSION_ID => 'stable-process-handle');
    my ($aout) = run_cli($CONT_PL, ['arm', '--by', 'operator'], $env);
    my $nonce = kv($aout, 'NONCE');
    ok(-f "$root/reg/pending/$nonce", 'AC7 fixture: a ticket is pending');

    my ($dout, $drc) = run_cli($CONT_PL, ['disarm'], $env);
    is($drc, 0, 'AC7 disarm exits 0 for a pending arm');
    is(kv($dout, 'STATUS'), 'disarmed', 'AC7 STATUS: disarmed');
    ok(!-f "$root/reg/pending/$nonce",
       'AC7 CANONICAL: the ticket is cancelled -- otherwise "off" would report success '
     . 'and then arm the session at the next turn boundary anyway');
}

# ===========================================================================
# X. THE SEAM: the GATE must actually bind a ticket (M6).
#
# Everything else here tests bp-session.pl's claim directly, and t/150 tests the
# gate directly -- so the LINE THAT JOINS THEM was covered by nothing. It is
# `perl "$HOOK_DIR/../scripts/bp-session.pl" claim ... >/dev/null 2>&1 || true`:
# silenced and failure-tolerant by design, so if that relative path broke, or
# perl went missing, every arm in existence would quietly never bind and every
# test in this repo would still pass. That is the precise shape of the defect
# this whole subsystem was written to remove, so leaving it untested was the one
# gap that mattered most.
#
# This drives the real hook, with a real Stop payload, and requires the marker
# to exist afterwards.
# ===========================================================================
{
    my $GATE = "$Bin/../../hooks/gate-continuity.sh";
    SKIP: {
        skip 'gate-continuity.sh not present', 4 unless -f $GATE;

        my $root  = new_world();
        my $sid   = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
        my $env   = world_env($root);

        # Arm the way the skill does: no --session, so a ticket is written.
        my ($aout, $arc) = run_cli($CONT_PL, ['arm', '--by', 'operator'], $env);
        is($arc, 0, 'X1 fixture: arm wrote a ticket');
        my $nonce = kv($aout, 'NONCE');
        ok(-f "$root/reg/pending/$nonce", 'X2 fixture: the ticket is on disk');

        # The session's transcript carries the nonce, as it would after the arm
        # call returned.
        plant($root, $sid, $sid, $nonce);

        # Now drive the GATE itself, exactly as Claude Code would.
        my $payload = JSON::PP->new->canonical->encode({
            session_id => $sid, cwd => "$root/proj",
        });
        my %e = %$env;
        my $envstr = join ' ', map {
            defined $e{$_} ? "$_='$e{$_}'" : ()
        } sort keys %e;
        my $out = `$envstr bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;

        ok(-f "$root/reg/$sid",
           'X3 CANONICAL: the GATE bound the ticket -- the seam between the hook and '
         . 'bp-session.pl is wired, not merely each side of it');
        ok(!-f "$root/reg/pending/$nonce",
           'X4: and consumed the ticket, so it cannot bind twice');
    }
}

done_testing();
