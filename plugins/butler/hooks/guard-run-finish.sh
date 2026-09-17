#!/usr/bin/env bash
# AN AGENT MAY NOT END A RUN. Only the operator ends one, and only by saying so.
#
# THE INCIDENT, 2026-09-17, and it was not the first: five background tasks were
# killed at once -- a full sweep, two watchers, a continuity hold. The driver
# read "five at once" as a deliberate human halt, ran `bp-runstate.pl finish`
# and `bp-continuity.pl disarm`, and wound the session down with the in-flight
# package's own required check never run. The task notifications say WHAT
# stopped. They never say WHO stopped it, and they carry an explicit banner
# saying they are not user input. An instruction was inferred from evidence that
# did not contain one.
#
# The operator's words, which are the rule: "me pressing stop is me coming here
# and telling you directly to stop."
#
# WHY THIS IS A HOOK AND NOT A NOTE. A note was written first, and indexed in
# CLAUDE.md, and the operator's answer was: "that's just prose, and I don't think
# it's enough." They are right, and the repo already knows it -- the git-mutation
# guard exists because prose forbidding a destructive command failed to prevent
# it. Blueprint butler-gate-ergonomics Decision 23 records the same conclusion.
#
# THE AUTHORISATION CHANNEL, and why it is the transcript. The agent cannot write
# the user's turn. Every other candidate fails: an env var, a flag, a marker file
# and a config key are all things the agent can produce itself, so none of them
# can distinguish "the operator said stop" from "the agent decided to stop". The
# most recent USER-authored message is the one signal in reach that an agent
# cannot manufacture.
#
# FAILS OPEN on every internal error (missing payload, unreadable transcript,
# absent jq/perl, malformed JSON). A guard that can wedge a session is worse than
# the thing it prevents -- the same ruling as guard-subagent-stall.sh's header and
# Decision 3 of the blueprint. Note which direction "open" is here: open means
# ALLOW THE STOP, because refusing to let a session ever stop is the worse wedge.
#
# THE ASYMMETRY THAT DECIDES AMBIGUOUS CASES, stated in the denial text too:
# wrongly continuing costs some tokens; wrongly stopping abandons an unattended
# run with nobody present to notice.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=/dev/null
. "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

# bp_read_payload SETS $PAYLOAD; it does not print it. Capturing it in a
# command substitution runs it in a subshell, so the assignment is lost and the
# guard silently stands aside on every call -- which is exactly what the first
# draft of this file did, and the test caught it. `open` is the right mode: on a
# stdin timeout an observer stands aside rather than denying, matching this
# guard's fail-open direction (see the header -- open means ALLOW the stop).
bp_read_payload open || exit 0
[ -n "${PAYLOAD:-}" ] || exit 0

CMD="$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null)" || exit 0
[ -n "${CMD:-}" ] || exit 0

# ---------------------------------------------------------------------------
# 1. Is this a run-ending command at all? Narrow on purpose: every OTHER verb
#    of both scripts stays untouched, including `status`, `hold`, `pause` and
#    `ask`. `arm` is untouched too -- arming more is never the failure mode.
# ---------------------------------------------------------------------------
is_run_ending=0
case "$CMD" in
  *bp-runstate*finish*)   is_run_ending=1 ;;
  *bp-continuity*disarm*) is_run_ending=1 ;;
  *bp-continuity*' off'*) is_run_ending=1 ;;
esac
[ "$is_run_ending" -eq 1 ] || exit 0

# ---------------------------------------------------------------------------
# 2. Is there anything to protect? With no run registered and no continuity
#    arm, these commands are ordinary maintenance and the operator's own
#    cleanup must not be obstructed.
# ---------------------------------------------------------------------------
run_live=1
bp_drive_any_active 2>/dev/null || run_live=0
if [ "$run_live" -eq 0 ]; then
  # No drive-solo run. Continuity may still be armed on its own (the skill is
  # explicitly independent of drive-solo), so check that before standing down.
  cdir="$(bp_continuity_active_dir 2>/dev/null)" || exit 0
  [ -n "${cdir:-}" ] && [ -d "$cdir" ] || exit 0
  set -- "$cdir"/*
  [ -e "${1:-}" ] || exit 0
fi

# ---------------------------------------------------------------------------
# 3. IS THERE ANY OUTSTANDING WORK? If not, the stop is legitimate and this
#    guard must get out of the way.
#
# THIS CHECK IS NOT A CONCESSION, IT IS HALF THE RULE. Blueprint Decision 4
# says a turn ends for exactly two reasons; the same two end a RUN -- the
# operator said so, or THE WORK IS FINISHED. A guard that only understood the
# first would refuse to let a completed unattended run ever stop, and the
# session would spin on an empty queue burning tokens with nobody watching.
# That is a worse failure than the one this guard exists to prevent: the bug
# abandons work that was in flight, this would abandon nothing but never end.
#
# "Finished" is read off the ledgers, which is where it is actually recorded --
# every package of every non-archived blueprint sitting at a TERMINAL status.
# done, blocked and parked are all terminal: blocked and parked are ends WITH A
# RECORDED REASON, and a run that is legitimately blocked legitimately stops.
# pending and running are the two that mean work remains.
#
# Fails open: unreadable blueprint dir, no ledgers, no perl -> allow the stop.
# ---------------------------------------------------------------------------
OUTSTANDING=""
if command -v perl >/dev/null 2>&1; then
  OUTSTANDING="$(perl -e '
    use strict; use warnings;
    my $root = shift @ARGV;
    my $dir  = "$root/.ccpraxis-local-data/blueprints";
    -d $dir or exit 0;
    opendir(my $dh, $dir) or exit 0;
    my @bps = grep { $_ !~ /^\.\.?$/ && $_ ne "_archive" && -d "$dir/$_" } readdir $dh;
    closedir $dh;
    my @open;
    for my $bp (@bps) {
        my $bpmd = "$dir/$bp/blueprint.md";
        if (-r $bpmd) {
            open my $b, "<", $bpmd or next;
            my $archived = 0;
            while (my $l = <$b>) {
                last if $. > 40;
                if ($l =~ /^status:\s*archived\b/) { $archived = 1; last }
            }
            close $b;
            next if $archived;
        }
        my $pdir = "$dir/$bp/packages";
        -d $pdir or next;
        opendir(my $pd, $pdir) or next;
        my @l = grep { /\.md$/ } readdir $pd;
        closedir $pd;
        for my $f (sort @l) {
            open my $h, "<", "$pdir/$f" or next;
            my $st = "";
            while (my $l = <$h>) {
                last if $. > 30;
                if ($l =~ /^status:\s*(\S+)/) { $st = lc $1; last }
            }
            close $h;
            next unless $st eq "pending" || $st eq "running";
            push @open, "$bp/" . ($f =~ s/\.md$//r) . " ($st)";
        }
    }
    print join("\n", @open), "\n" if @open;
    exit 0;
  ' "${BP_PROJECT_ROOT:-$PWD}" 2>/dev/null)" || OUTSTANDING=""
fi
# Nothing pending or running anywhere: the work is done, let the session stop.
[ -n "${OUTSTANDING:-}" ] || exit 0

# ---------------------------------------------------------------------------
# 4. Work remains. Did the OPERATOR authorise the stop anyway, in their own
#    most recent message? They are always allowed to stop an unfinished run --
#    this guard exists to stop the AGENT doing it on an inference, never to
#    argue with the operator.
#
# Read the last user-authored message from the transcript. Claude Code supplies
# transcript_path on the hook payload; absent or unreadable, fail open.
# ---------------------------------------------------------------------------
TRANSCRIPT="$(bp_json_get "$PAYLOAD" transcript_path 2>/dev/null)" || exit 0
[ -n "${TRANSCRIPT:-}" ] && [ -r "$TRANSCRIPT" ] || exit 0

command -v perl >/dev/null 2>&1 || exit 0

# Prints AUTHORISED or UNAUTHORISED. Any internal failure prints nothing, and an
# empty verdict is treated as fail-open below.
VERDICT="$(perl -e '
  use strict; use warnings;
  my $path = shift @ARGV;
  my $json = eval { require JSON::PP; JSON::PP->new->utf8 } or exit 0;
  open my $fh, "<", $path or exit 0;
  my $last = "";
  my $decoded_lines = 0;
  while (my $line = <$fh>) {
      next unless $line =~ /\S/;
      my $rec = eval { $json->decode($line) } or next;
      $decoded_lines++;
      # Only genuine user turns. Tool results and system reminders are delivered
      # on the user role too, and a task notification is EXACTLY the thing that
      # must not read as an instruction -- that is the bug this guard exists for.
      next unless ($rec->{type} // "") eq "user";
      my $m = $rec->{message} or next;
      next unless ($m->{role} // "") eq "user";
      next if $rec->{isMeta};
      my $c = $m->{content};
      my $text = "";
      if (ref $c eq "ARRAY") {
          for my $part (@$c) {
              next unless ref $part eq "HASH";
              next if ($part->{type} // "") ne "text";
              $text .= ($part->{text} // "") . "\n";
          }
      } elsif (!ref $c) { $text = $c // ""; }
      next unless $text =~ /\S/;
      # A tool_result-bearing turn carries no author text; skip those.
      next if $text =~ /^\s*<(?:system-reminder|local-command)/;
      $last = $text;
  }
  close $fh;
  # PARSED FINE, NOTHING THERE is not the same as COULD NOT PARSE. A transcript
  # whose only user-role entries are task notifications IS the incident shape,
  # and the absence of an instruction is not an authorisation -- so this prints
  # UNAUTHORISED rather than falling through to the fail-open path, which is
  # reserved for genuine errors (unreadable file, malformed JSON, no JSON::PP).
  # NOTHING DECODED AT ALL means the transcript is unreadable as JSONL, which is
  # a genuine error -> fail open. At least one record decoded but no user text
  # means it PARSED and contained no instruction -> UNAUTHORISED. Collapsing
  # those two would either let a malformed file wedge the session or let a
  # transcript of pure task notifications authorise a stop.
  exit 0 if $decoded_lines == 0;
  if ($last !~ /\S/) { print "UNAUTHORISED\n"; exit 0 }

  my $t = lc $last;
  $t =~ s/\s+/ /g;

  # Narrow, imperative stop instructions only. Deliberately NOT matching bare
  # "done", "ok" or "thanks": those end a topic, never a run.
  my @stop = (
      qr/\bstop\b/, qr/\bhalt\b/, qr/\bwind (?:it )?down\b/,
      qr/\bend the run\b/, qr/\bdisarm\b/, qr/\bstand down\b/,
      qr/\bthat(?:\x27|)s enough\b/, qr/\bwe(?:\x27|)re done\b/,
      qr/\bdone for (?:now|today|the night)\b/, qr/\bcall it a (?:night|day)\b/,
  );
  for my $re (@stop) {
      next unless $t =~ $re;
      my $at = $-[0];
      # Negation window: "do not stop", "dont stop", "no need to stop",
      # "instead of stopping", "why did you stop". A matched word inside a
      # question ABOUT stopping is not an instruction TO stop.
      my $before = substr($t, ($at > 60 ? $at - 60 : 0), ($at > 60 ? 60 : $at));
      next if $before =~ /\b(?:do ?n(?:o|\x27)t|dont|never|no need to|instead of|rather than|without|why did you|why(?: did)? you|you should ?n(?:o|\x27)t)\b[^.]{0,30}$/;
      print "AUTHORISED\n";
      exit 0;
  }
  print "UNAUTHORISED\n";
  exit 0;
' "$TRANSCRIPT" 2>/dev/null)" || exit 0

# Empty verdict == could not determine == FAIL OPEN (allow the stop).
[ "${VERDICT:-}" = "UNAUTHORISED" ] || exit 0

cat >&2 <<DENIED
BLOCKED (butler run-finish guard): you are about to end a run the operator did not ask you to end.

A run ends when the OPERATOR says so, in their own message. Nothing else is a stop
instruction -- not background tasks dying, not all of them dying at once, not a task
notification, not a denied tool, not silence. Those notifications say WHAT stopped;
they never say WHO stopped it, and they carry a banner saying they are not user input.

Their words: "me pressing stop is me coming here and telling you directly to stop."

Work is still outstanding AND the last thing the operator actually said contains no stop
instruction, so this is an
inference, and inferring an instruction is how an unattended run gets abandoned with
nobody present to notice.

WHAT TO DO INSTEAD:
  * Re-launch whatever died, record what was lost, and carry on.
  * Genuinely blocked? Queue it -- this does NOT end the turn:
        bp-continuity.sh ask --text "<your question>"
    then continue with everything that does not depend on the answer.
  * Need to keep the turn alive while you wait? Take a bounded hold:
        bp-continuity.pl hold --seconds 600      (as a BACKGROUND call)

THE ASYMMETRY: wrongly continuing costs some tokens. Wrongly stopping abandons the run.
When the signal is ambiguous, CONTINUE.

STILL PENDING OR RUNNING (this guard stands aside the moment none are):
$OUTSTANDING

If the operator has in fact told you to stop, they said so in a message -- and this guard
reads that message and stands aside. It is not standing aside, so they did not.
DENIED
exit 2
