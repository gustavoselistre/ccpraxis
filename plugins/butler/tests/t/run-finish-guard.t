#!/usr/bin/env perl
# platform: any
# AN AGENT MAY NOT END A RUN -- and a FINISHED run must still be able to stop.
#
# guard-run-finish.sh exists because prose did not hold. The driver read five
# background tasks dying as a human pressing Stop, ran `bp-runstate.pl finish`
# and `bp-continuity.pl disarm`, and wound a session down with the in-flight
# package's own required check never run. The operator's ruling: "me pressing
# stop is me coming here and telling you directly to stop." Their verdict on the
# guidance note written first: "that's just prose, and I don't think it's enough."
#
# THE SECOND HALF IS AS LOAD-BEARING AS THE FIRST, and it is the operator's own
# follow-up question: "make sure you're not fucking things up by disallowing
# disarming after everything that was supposed to be done has been done." A guard
# that only knew rule one would refuse to let a COMPLETED unattended run ever
# stop, and the session would spin on an empty queue burning tokens with nobody
# watching. That is the worse failure -- the original bug abandons work that was
# in flight; this would abandon nothing and never end. So B2 and B3 below are not
# politeness cases, they are the reason this file has two blocks.
#
# Everything here is hermetic: a File::Temp project root with fabricated ledgers
# and a fabricated transcript. Nothing reads the real blueprints, the real
# registry or the real session.
# test-wakelock-hygiene.t R3: this file's denial text names `bp-continuity.pl
# hold`, a wake-lock actuator, so the repo-wide rule requires the opt-out even
# though nothing here actually takes a lock. The rule is deliberately keyed on
# NAMING an actuator rather than calling one -- a test that can be read as
# taking a wake-lock is one somebody will eventually copy.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $GUARD = "$Bin/../../hooks/guard-run-finish.sh";
ok(-f $GUARD, 'the guard exists on disk') or BAIL_OUT('guard-run-finish.sh missing');

# --- fixtures --------------------------------------------------------------

# A project root whose blueprints hold packages at the given statuses.
sub make_root {
    my (@statuses) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $pdir = File::Spec->catdir($root, '.ccpraxis-local-data', 'blueprints', 'bp-x', 'packages');
    make_path($pdir);
    my $i = 0;
    for my $st (@statuses) {
        $i++;
        my $f = File::Spec->catfile($pdir, sprintf('%02d-pkg.md', $i));
        open my $fh, '>', $f or die "fixture: $!";
        print {$fh} "---\npackage: %02d-pkg\nstatus: $st\n---\n\n# fixture\n";
        close $fh;
    }
    return $root;
}

# A transcript whose LAST user-authored message is $text.
sub make_transcript {
    my ($text) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $f   = File::Spec->catfile($dir, 'transcript.jsonl');
    my $j   = JSON::PP->new->canonical;
    open my $fh, '>', $f or die "transcript: $!";
    # An assistant turn, then a TASK NOTIFICATION delivered on the user role --
    # the exact shape that caused the incident -- then the real user turn.
    print {$fh} $j->encode({ type => 'assistant', message => { role => 'assistant',
                             content => [ { type => 'text', text => 'working' } ] } }), "\n";
    print {$fh} $j->encode({ type => 'user', message => { role => 'user',
                             content => [ { type => 'text',
                             text => "<system-reminder>\n<task-notification><status>killed</status></task-notification>\n</system-reminder>" } ] } }), "\n";
    if (defined $text) {
        print {$fh} $j->encode({ type => 'user', message => { role => 'user',
                                 content => [ { type => 'text', text => $text } ] } }), "\n";
    }
    close $fh;
    return $f;
}

# Run the guard with a constructed payload. Returns ($rc, $stderr).
sub run_guard {
    my (%o) = @_;
    my $payload = JSON::PP->new->encode({
        tool_name  => 'Bash',
        tool_input => { command => $o{command} },
        ($o{transcript} ? (transcript_path => $o{transcript}) : ()),
    });
    my $errf = File::Spec->catfile(tempdir(CLEANUP => 1), 'err');
    # THE IDLE PREMISE IS CONSTRUCTED, NOT ASSUMED -- the lesson of bug
    # 20260916-150236-6684, fixed in ff464b6 hours before this file was written.
    # Without an explicit continuity dir these cases read the REAL machine
    # registry, so B1 passed or failed depending on whether the session running
    # the suite happened to be armed. It was, and B1 failed for that reason.
    my %env = (
        BP_PROJECT_ROOT                => $o{root} // '',
        CCPRAXIS_DRIVE_ACTIVE_DIR      => $o{drive_dir} // '',
        CCPRAXIS_CONTINUITY_ACTIVE_DIR => $o{cont_dir} // tempdir(CLEANUP => 1),
    );
    local %ENV = (%ENV, %env);
    delete $ENV{$_} for grep { !length $env{$_} } keys %env;
    open my $fh, '|-', "bash \"$GUARD\" 2> \"$errf\"" or die "spawn: $!";
    print {$fh} $payload;
    close $fh;
    my $rc  = $? >> 8;
    my $err = -f $errf ? do { local (@ARGV, $/) = ($errf); <> } : '';
    return ($rc, defined $err ? $err : '');
}

# A drive registry with one live marker, so the guard sees a run in progress.
sub live_drive_dir {
    my $d = tempdir(CLEANUP => 1);
    open my $fh, '>', File::Spec->catfile($d, 'fixture-session-id') or die "marker: $!";
    print {$fh} "fixture\n";
    close $fh;
    return $d;
}

# ===========================================================================
# A. THE BUG. Work outstanding, operator said nothing about stopping.
# ===========================================================================
{
    my $root = make_root('done', 'pending');
    my $tr   = make_transcript('continue with the sweep please');
    my $dd   = live_drive_dir();

    my ($rc, $err) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "x"',
                               root => $root, transcript => $tr, drive_dir => $dd);
    is($rc, 2, 'A1: finish is BLOCKED while a package is pending and the operator has not said stop');
    like($err, qr/BLOCKED \(butler run-finish guard\)/, 'A1: ...and says which guard denied it');
    like($err, qr/bp-x\/02-pkg \(pending\)/,
        'A1: ...and NAMES the outstanding package, so the denial is actionable rather than scolding');
    like($err, qr/wrongly continuing costs some tokens/i,
        'A1: ...and states the asymmetry that decides ambiguous cases');

    my ($rc2) = run_guard(command => 'perl plugins/butler/scripts/bp-continuity.pl disarm',
                          root => $root, transcript => $tr, drive_dir => $dd);
    is($rc2, 2, 'A2: disarm is blocked on the same terms -- both halves of the wind-down, not just one');

    # fix-batch B1 (red-team HIGH-2): the SAME disarm, but via the .sh-shim
    # and bare-alias spellings package 04-bp-on-path put on PATH, and the
    # form gate-continuity.sh's own denial text recommends (`bp-continuity`,
    # bare). Before the fix, the mandatory `\.(pl|sh)` extension in
    # continuity_re silently let the bare form bypass this guard entirely.
    my ($rc2sh) = run_guard(command => 'bp-continuity.sh disarm',
                            root => $root, transcript => $tr, drive_dir => $dd);
    is($rc2sh, 2, 'A2b: the .sh-spelled disarm is blocked identically to the .pl form');

    my ($rc2bare) = run_guard(command => 'bp-continuity disarm',
                              root => $root, transcript => $tr, drive_dir => $dd);
    is($rc2bare, 2, 'A2c: the bare-spelled disarm is blocked identically to the .pl form '
                   . '(this is the exact bypass HIGH-2 reported as already live on Linux)');

    # THE INCIDENT ITSELF: the last thing on the user ROLE is a task
    # notification. It must not read as an instruction.
    my ($rc3) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "tasks died"',
                          root => $root, transcript => make_transcript(undef), drive_dir => $dd);
    is($rc3, 2,
        'A3: a task notification on the user role does NOT authorise a stop -- the exact inference that caused this guard');
}

# ===========================================================================
# B. THE THINGS THAT MUST STILL WORK. Each of these is a way this guard could
#    do more harm than the bug it prevents.
# ===========================================================================
{
    my $tr = make_transcript('carry on');

    # B1: no run registered and no continuity arm -> ordinary maintenance.
    my ($rc) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "tidy"',
                         root => make_root('pending'), transcript => $tr,
                         drive_dir => tempdir(CLEANUP => 1));
    is($rc, 0, 'B1: with no run active and no arm, the operator\'s own cleanup is not obstructed');

    # B2 + B3: THE OPERATOR'S QUESTION. Everything done -> the stop is legitimate.
    my $dd = live_drive_dir();
    my ($rc2) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "all packages done"',
                          root => make_root('done', 'done', 'done'), transcript => $tr, drive_dir => $dd);
    is($rc2, 0,
        'B2: when EVERY package is done, finish is ALLOWED -- a completed unattended run must be able to stop');

    my ($rc3) = run_guard(command => 'perl plugins/butler/scripts/bp-continuity.pl disarm',
                          root => make_root('done', 'blocked', 'parked'), transcript => $tr, drive_dir => $dd);
    is($rc3, 0,
        'B3: blocked and parked count as terminal too -- they are ends WITH a recorded reason, so disarm is allowed');

    # B4: the operator may always stop an unfinished run.
    for my $said ('stop', 'please stop for now', 'halt the run', 'wind it down',
                  'that\'s enough for tonight', 'we\'re done here', 'disarm continuity') {
        my ($rcx) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "operator asked"',
                              root => make_root('pending'), transcript => make_transcript($said),
                              drive_dir => $dd);
        is($rcx, 0, "B4: the operator saying '$said' authorises the stop even with work outstanding");
    }

    # B5: a QUESTION about stopping is not an instruction to stop. This is the
    # negation window, and it is the one the incident's own follow-up needed:
    # the operator asked "you stopped. why?" -- which must not authorise another.
    for my $said ('you stopped. why?', 'why did you stop?', 'do not stop',
                  'no need to stop', "don't stop working") {
        my ($rcx) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "misread"',
                              root => make_root('pending'), transcript => make_transcript($said),
                              drive_dir => $dd);
        is($rcx, 2, "B5: '$said' is a question or a negation, NOT authorisation");
    }

    # B6: every other verb of both scripts is untouched. Narrow by design.
    for my $cmd ('perl plugins/butler/scripts/bp-continuity.pl status',
                 'perl plugins/butler/scripts/bp-continuity.pl hold --seconds 600',
                 'perl plugins/butler/scripts/bp-continuity.pl arm --by operator',
                 'perl plugins/butler/scripts/bp-runstate.pl pause --watcher-pid 1 --until 2',
                 'git status') {
        my ($rcx) = run_guard(command => $cmd, root => make_root('pending'),
                              transcript => $tr, drive_dir => $dd);
        is($rcx, 0, "B6: untouched -- $cmd");
    }
}

# ===========================================================================
# D. THE TWO WAYS THE OPERATOR'S INSTRUCTION WENT UNHEARD. Both measured on
#    2026-09-18, both in the same session, both silent.
# ===========================================================================
{
    # A transcript with SEVERAL user turns, because both defects here are about
    # which turn ends up being read as the last one.
    my $J2 = JSON::PP->new->canonical;
    my $mk = sub {
        my @texts = @_;
        my $dir = tempdir(CLEANUP => 1);
        my $f   = File::Spec->catfile($dir, 'transcript.jsonl');
        open my $fh, '>', $f or die "transcript: $!";
        print {$fh} $J2->encode({ type => 'assistant', message => { role => 'assistant',
                                  content => [ { type => 'text', text => 'working' } ] } }), "\n";
        for my $t (@texts) {
            print {$fh} $J2->encode({ type => 'user', message => { role => 'user',
                                      content => [ { type => 'text', text => $t } ] } }), "\n";
        }
        close $fh;
        return $f;
    };

    my $dd  = live_drive_dir();
    my $fin = 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "operator asked"';

    # D1: /butler:continuity off is THE documented off switch, and this guard
    # polices the very command it runs. It is recorded structurally, so the whole
    # instruction is the word "off" inside a tag -- which matched nothing.
    my $slash = "<command-message>butler:continuity</command-message>\n"
              . "<command-name>/butler:continuity</command-name>\n"
              . "<command-args>off</command-args>";
    my ($c1) = run_guard(command => $fin, root => make_root('pending'),
                         transcript => $mk->($slash), drive_dir => $dd);
    is($c1, 0, 'D1: /butler:continuity off authorises the stop it is asking for');

    # C2: the bare form, without the plugin prefix.
    my $slash2 = "<command-name>/continuity</command-name>\n<command-args>off</command-args>";
    my ($c2) = run_guard(command => $fin, root => make_root('pending'),
                         transcript => $mk->($slash2), drive_dir => $dd);
    is($c2, 0, 'D2: the unprefixed /continuity off is recognised too');

    # C3: COUNTER-FIXTURE, and the reason C1 is matched structurally rather than
    # by adding "off" to the keyword list. In prose it means nothing of the kind.
    for my $prose ('turn the display off', 'the screen went off overnight',
                   'switch off the wake lock') {
        my ($rcx) = run_guard(command => $fin, root => make_root('pending'),
                              transcript => $mk->($prose), drive_dir => $dd);
        is($rcx, 2, "D3: '$prose' is prose, NOT an off switch");
    }

    # C4: COUNTER-FIXTURE. Arming is the opposite instruction and must not pass.
    my $arm = "<command-name>/butler:continuity</command-name>\n<command-args>on</command-args>";
    my ($c4) = run_guard(command => $fin, root => make_root('pending'),
                         transcript => $mk->($arm), drive_dir => $dd);
    is($c4, 2, 'D4: /butler:continuity ON does not authorise a stop');

    # C5: THE MASKING BUG. The harness writes interrupt notices on the user role
    # with isMeta=0, so one becomes the last qualifying record and buries what the
    # operator actually said. An operator who says "stop" and then interrupts a
    # tool call had their instruction hidden by their own interruption.
    my ($c5) = run_guard(command => $fin, root => make_root('pending'),
                         transcript => $mk->('stop', '[Request interrupted by user for tool use]'),
                         drive_dir => $dd);
    is($c5, 0, 'D5: an interrupt notice does not mask the stop instruction before it');

    my ($c5b) = run_guard(command => $fin, root => make_root('pending'),
                          transcript => $mk->('wind it down', '[Request interrupted by user]'),
                          drive_dir => $dd);
    is($c5b, 0, 'D5b: the shorter interrupt variant is skipped as well');

    # C6: COUNTER-FIXTURE, and the one that keeps C5 from becoming a blanket
    # authorisation. Skipping the notice must not invent an instruction that was
    # never given -- with nothing but notices, the answer is still UNAUTHORISED.
    my ($c6) = run_guard(command => $fin, root => make_root('pending'),
                         transcript => $mk->('carry on', '[Request interrupted by user for tool use]'),
                         drive_dir => $dd);
    is($c6, 2, 'D6: skipping the notice reveals the REAL last message, it does not authorise');
}

# ===========================================================================
# E. CROSSCUTTING-DEFECTS -- BLOCKER-2 (redteam-step6.md). `touch
#    .../.run-finished` is an ORDINARY, unguarded Bash command that makes
#    both Stop gates reading that marker return an unconditional allow --
#    the same run-ending effect as `bp-runstate.pl finish`, but until this
#    fix, this guard had zero references to `.run-finished` at all and
#    never intercepted it. bp_rf_is_run_ending must now recognise a write to
#    that path (touch/cp/mv/`>`) as run-ending, gated behind the SAME
#    operator-authorisation transcript check as the other two patterns --
#    no new authorisation mechanism.
# ===========================================================================
{
    my $root = make_root('pending');
    my $dd   = live_drive_dir();
    my $marker = "$root/.ccpraxis-local-data/.drive-solo/.run-finished";

    # (a) UNAUTHORISED: denied the same way an unauthorised `bp-runstate.pl
    # finish` is denied.
    my ($rc_a, $err_a) = run_guard(command => qq{touch "$marker"},
                                   root => $root, transcript => make_transcript('continue with the sweep please'),
                                   drive_dir => $dd);
    is($rc_a, 2, 'E1a: an unauthorised touch of .../.run-finished is BLOCKED');
    like($err_a, qr/BLOCKED \(butler run-finish guard\)/, 'E1a: ...and says which guard denied it');

    # (b) AUTHORISED: the operator said "stop" in their own message ->
    # allowed, matching this file's B4 fixture pattern.
    my ($rc_b) = run_guard(command => qq{touch "$marker"},
                           root => $root, transcript => make_transcript('stop'),
                           drive_dir => $dd);
    is($rc_b, 0, 'E1b: the SAME touch is ALLOWED once the operator has said stop');

    # (c) COUNTER-FIXTURE: touch of an unrelated file is untouched by this
    # change -- the fast pre-check and the verb-position regex must not
    # over-match a bare `touch` of something else.
    my ($rc_c) = run_guard(command => 'touch /tmp/some-other-file.txt',
                           root => $root, transcript => make_transcript('continue with the sweep please'),
                           drive_dir => $dd);
    is($rc_c, 0, 'E1c: touch of an unrelated file is untouched -- narrow by design, same as B6');

    # (d) a MENTION of .run-finished inside prose/a quoted multi-word value
    # must not false-positive, mirroring the masking discipline already
    # pinned for the other two patterns.
    my ($rc_d) = run_guard(
        command => 'perl plugins/butler/scripts/bp-continuity.pl ask --text "waiting on .run-finished from the operator"',
        root => $root, transcript => make_transcript('continue with the sweep please'), drive_dir => $dd);
    is($rc_d, 0, 'E1d: a MENTION of .run-finished inside a multi-word quoted --text value is not run-ending');

    # (e) writing to the already-CONSUMED archive (.run-finished.consumed)
    # must not be treated as creating a fresh marker.
    my ($rc_e) = run_guard(command => qq{touch "$marker.consumed"},
                           root => $root, transcript => make_transcript('continue with the sweep please'),
                           drive_dir => $dd);
    is($rc_e, 0, 'E1e: touch of the already-consumed archive file is untouched');
}

# ===========================================================================
# C. FAIL OPEN. Decision 3: a guard that can wedge a session is worse than the
#    thing it prevents -- and here "open" means ALLOW THE STOP, because a
#    session that can never end is the worse wedge.
# ===========================================================================
{
    my $dd = live_drive_dir();
    my ($rc) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "x"',
                         root => make_root('pending'), drive_dir => $dd);   # no transcript_path
    is($rc, 0, 'C1: no transcript_path on the payload -> cannot determine -> FAIL OPEN, allow the stop');

    my ($rc2) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "x"',
                          root => make_root('pending'), drive_dir => $dd,
                          transcript => File::Spec->catfile(tempdir(CLEANUP => 1), 'absent.jsonl'));
    is($rc2, 0, 'C2: an unreadable transcript -> FAIL OPEN');

    my $bad = File::Spec->catfile(tempdir(CLEANUP => 1), 'bad.jsonl');
    open my $bf, '>', $bad or die; print {$bf} "not json at all\n{{{\n"; close $bf;
    my ($rc3) = run_guard(command => 'perl plugins/butler/scripts/bp-runstate.pl finish --reason "x"',
                          root => make_root('pending'), drive_dir => $dd, transcript => $bad);
    is($rc3, 0, 'C3: a malformed transcript -> FAIL OPEN, never a wedge');
}

done_testing();
