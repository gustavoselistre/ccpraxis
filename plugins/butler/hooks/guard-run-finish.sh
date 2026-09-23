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

# ---------------------------------------------------------------------------
# bp_rf_scan_target / bp_rf_is_run_ending -- reimplements the quoted-span-
# masking TECHNIQUE of guard-git-mutations.sh's git_scan_target() (read, never
# called or edited) so that section 1 below stops matching a mere MENTION of
# bp-runstate/bp-continuity + finish/disarm/off (inside a quoted argument, a
# --text value, a perl -pe replacement string) the same way it matches a real
# invocation. Defined here, before any payload is read, so both functions are
# independently callable by sourcing this file alone (see the BASH_SOURCE
# guard around the main body, below) -- Spec 02-run-finish-guard-reads-
# invocations section 2.
# ---------------------------------------------------------------------------
RF_MASK_MAX=8192
RF_RAW_KIND=masked

# _bp_rf_mask LEN -- sets RF_MASK_OUT to LEN 'X' characters. Sets a global
# rather than printing, same convention as bp_rf_scan_target below: a
# $(...) capture would fork a subshell per call, which costs more than this
# loop ever does for a real (short) quoted span. Shared by the SINGLE- and
# DOUBLE-quote closing branches, which used to duplicate this loop inline.
_bp_rf_mask() {
  local len=$1 i=0
  RF_MASK_OUT=""
  while [ "$i" -lt "$len" ]; do RF_MASK_OUT+="X"; i=$((i+1)); done
}

# bp_rf_scan_target -- sets RF_SCAN / RF_RAW_KIND from the global $CMD. Called
# WITHOUT command substitution (assign via the globals, not $(...)): a
# subshell would discard the assignments, exactly as git_scan_target's own
# note explains.
bp_rf_scan_target() {
  local cmd="$CMD"
  local len=${#cmd}
  # 1. Over-long command: raw fallback without even walking it.
  if [ "$len" -gt "$RF_MASK_MAX" ]; then
    RF_RAW_KIND=toolong
    RF_SCAN="$cmd"
    return 0
  fi
  # 2. A backslash, a '#', or a heredoc marker ('<<') ANYWHERE in the command,
  #    regardless of quote context: raw fallback. Deliberately does NOT
  #    reimplement git_scan_target()'s later heredoc-stripping branch (Spec
  #    section 2's simplification) -- a heredoc marker degrades straight to
  #    the unmasked scan here, same as a backslash or '#'.
  case "$cmd" in
    *'\'*|*'#'*|*'<<'*)
      RF_RAW_KIND=escape
      RF_SCAN="$cmd"
      return 0
      ;;
  esac

  # 3. Walk the string character-by-character in a three-state machine
  #    (NONE/SINGLE/DOUBLE), identical to git_scan_target()'s walk -- EXCEPT
  #    a quoted span is no longer X-masked unconditionally. Its interior is
  #    buffered (qbuf) as the walk goes; only when the CLOSING quote is
  #    reached do we know whether the span is single-word (no internal
  #    whitespace) or multi-word (prose). Decision 15 / red-team Finding 1:
  #    quoting a bareword changes nothing about its argv value in bash
  #    (`finish`, "finish" and 'finish' are byte-identical), so a single-word
  #    quoted span is the ACTUAL VERB/SCRIPT NAME, not a mention of it, and
  #    must be scanned unquoted/literal rather than blanked to X. A
  #    multi-word quoted span (prose, a --text value, a sed replacement --
  #    F1/F2/F3) still X-masks in full, unchanged from before.
  #
  #    Red-team redteam-02 Finding A (MEDIUM): the single-word carve-out above
  #    had no positional constraint, so a single-word quoted span ANYWHERE
  #    (e.g. `bp-continuity.pl ask --text "off"`, the guard's own documented
  #    escape hatch) unmasked to its literal content and false-positived as a
  #    real invocation. Fix: only treat a single-word quoted span as literal
  #    when it sits in VERB POSITION -- immediately after one of the two
  #    script names (optionally interpreter-prefixed / path-prefixed), with
  #    nothing but whitespace between the script name and the opening quote,
  #    checked against the UNQUOTED content built so far ($out) at the moment
  #    the quote opens. Anything else -- a quoted word after a flag like
  #    `--text`, or after any other token -- stays X-masked, same as a
  #    multi-word span and same as this guard's behaviour before this
  #    package's fix-batch.
  local state=NONE
  local carrier=0
  local out="" c next
  local qbuf="" qhaswhite=0 qadjacent=0
  # BLOCKER-2 (redteam-step6.md): `touch .../.run-finished` is an ordinary,
  # unguarded Bash command that ends a run exactly as `bp-runstate.pl
  # finish` does (both hooks consuming that marker treat it as an
  # unconditional allow) -- so a quoted path immediately after `touch`,
  # `cp` or `mv` (verb position, same as the two script names above) must
  # unmask the same way, or a quoted target path would falsely X-mask into
  # a non-match. `>` is a single character, not a word, so it is matched
  # separately below rather than folded into this word-anchored class.
  local adj_re='(^|[;&|[:space:]`({])((perl|bash|sh)[[:space:]]+)?([[:alnum:]_./-]*/)?(bp-(runstate|continuity)\.(pl|sh)|touch|cp|mv)[[:space:]]*$|>[[:space:]]*$'
  local i=0
  while [ "$i" -lt "$len" ]; do
    c=${cmd:$i:1}
    case "$state" in
      NONE)
        case "$c" in
          "'")
            state=SINGLE; qbuf=""; qhaswhite=0
            [[ "$out" =~ $adj_re ]] && qadjacent=1 || qadjacent=0
            ;;
          '"')
            state=DOUBLE; qbuf=""; qhaswhite=0
            [[ "$out" =~ $adj_re ]] && qadjacent=1 || qadjacent=0
            ;;
          '`') carrier=1; out+='`' ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+='$' ;;
          *) out+="$c" ;;
        esac ;;
      SINGLE)
        case "$c" in
          "'")
            state=NONE
            if [ "$qhaswhite" -eq 0 ] && [ "$qadjacent" -eq 1 ]; then
              out+="$qbuf"
            else
              _bp_rf_mask "${#qbuf}"
              out+="'${RF_MASK_OUT}'"
            fi
            ;;
          ' '|$'\t'|$'\n') qhaswhite=1; qbuf+="$c" ;;
          *) qbuf+="$c" ;;
        esac ;;
      DOUBLE)
        case "$c" in
          '"')
            state=NONE
            if [ "$qhaswhite" -eq 0 ] && [ "$qadjacent" -eq 1 ]; then
              out+="$qbuf"
            else
              _bp_rf_mask "${#qbuf}"
              out+="\"${RF_MASK_OUT}\""
            fi
            ;;
          '`') carrier=1; qbuf+="$c" ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            qbuf+="$c" ;;
          ' '|$'\t'|$'\n') qhaswhite=1; qbuf+="$c" ;;
          *) qbuf+="$c" ;;
        esac ;;
    esac
    i=$((i+1))
  done

  # Walk ends with state != NONE (unbalanced quoting): raw fallback.
  if [ "$state" != "NONE" ]; then
    RF_RAW_KIND=unbalanced
    RF_SCAN="$cmd"
    return 0
  fi
  # carrier == 1 (an unquoted backtick or $( was seen): raw fallback.
  if [ "$carrier" -eq 1 ]; then
    RF_RAW_KIND=carrier
    RF_SCAN="$cmd"
    return 0
  fi
  # 4. A shell/eval word in command position on the MASKED string: it
  #    re-executes its own quoted argument as code, so what looked like a
  #    quoted mention must be scanned as real text (e.g.
  #    `bash -c "bp-runstate.pl finish"`). Raw fallback.
  if printf '%s' "$out" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)'; then
    RF_RAW_KIND=shellword
    RF_SCAN="$cmd"
    return 0
  fi

  RF_RAW_KIND=masked
  RF_SCAN="$out"
}

# bp_rf_is_run_ending -- args: $1=CMD (or reads global $CMD). Returns 0 (true,
# run-ending) or 1.
bp_rf_is_run_ending() {
  [ $# -gt 0 ] && CMD="$1"

  # Fast pre-check: the per-character masking walk in bp_rf_scan_target is
  # real work on every call this hook makes (every relevant Bash command),
  # and every branch below needs one of these two substrings present
  # somewhere in $CMD -- so a command mentioning neither is never a
  # candidate at all. Restores the old bare-glob's cheap fast path for the
  # overwhelming majority of commands, without weakening anything the walk
  # itself decides for the rare command that DOES mention one.
  # BLOCKER-2 (redteam-step6.md): `.run-finished` added as a third
  # candidate substring -- an ordinary, unguarded `touch <project>/.ccpraxis-
  # local-data/.drive-solo/.run-finished` makes _bp_finish_signal (the two
  # Stop gates that read this marker) return an UNCONDITIONAL allow, with no
  # authorisation check at all. Same fast pre-check shape as the other two:
  # a command mentioning none of the three substrings is never a candidate.
  case "$CMD" in
    *bp-runstate*|*bp-continuity*|*.run-finished*) ;;
    *) return 1 ;;
  esac

  bp_rf_scan_target

  # Anchor class per RF_RAW_KIND tier, values copied verbatim from
  # guard-git-mutations.sh's three tiers -- same technique, same values.
  local anchor_class
  case "$RF_RAW_KIND" in
    shellword) anchor_class='[;&|[:space:]'\''"`({]' ;;
    carrier)   anchor_class='[;&|[:space:]`({]' ;;
    *)         anchor_class='[;&|[:space:]({]' ;;
  esac

  # fix-batch B1 (red-team HIGH-2): extension made OPTIONAL -- `(\.(pl|sh))?`
  # rather than the mandatory `\.(pl|sh)` this used to require -- so the
  # bare/extensionless alias (created unconditionally for every *.sh in
  # plugins/*/bin/ on non-Windows installs, and the form gate-continuity.sh
  # itself prefers and recommends in its own denial text) is recognized as
  # run-ending identically to the .pl and .sh spellings, instead of silently
  # bypassing this authorization check.
  local runstate_re="(^|${anchor_class})((perl|bash|sh)[[:space:]]+)?([[:alnum:]_./-]*/)?bp-runstate(\.(pl|sh))?\b[^;&|(){}\n]*\bfinish\b"
  local continuity_re="(^|${anchor_class})((perl|bash|sh)[[:space:]]+)?([[:alnum:]_./-]*/)?bp-continuity(\.(pl|sh))?\b[^;&|(){}\n]*\b(disarm|off)\b"
  # BLOCKER-2: a command that WRITES to a path matching *.run-finished via
  # touch/cp/mv (verb position, masked/unmasked by adj_re above) or a `>`
  # redirect. Deliberately excludes `.run-finished.consumed` (the archived,
  # already-spent record) -- `([^.]|$)` after the literal requires the
  # match not be immediately followed by another '.', so a create of the
  # LIVE marker is caught while a stray write to the consumed archive is
  # not. Not anchored to command position for `>`: a redirect target can
  # appear anywhere in a compound command.
  local finish_marker_re="(^|${anchor_class})(touch|cp|mv)[[:space:]]+[^;&|(){}\n]*\.run-finished([^.]|\$)|>[[:space:]]*[^;&|(){}\n]*\.run-finished([^.]|\$)"

  grep -Eq "$runstate_re" <<<"$RF_SCAN" \
    || grep -Eq "$continuity_re" <<<"$RF_SCAN" \
    || grep -Eq "$finish_marker_re" <<<"$RF_SCAN"
}

# The main body below must not run when this file is merely SOURCED (e.g. by
# a test harness that wants only the two functions above) -- it must not
# touch stdin or exit the sourcing shell. Only run it on direct execution.
if [ "${BASH_SOURCE[0]}" != "${0:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# bp_read_payload SETS $PAYLOAD; it does not print it. Capturing it in a
# command substitution runs it in a subshell, so the assignment is lost and the
# guard silently stands aside on every call -- which is exactly what the first
# draft of this file did, and the test caught it. `open` is the right mode: on a
# stdin timeout an observer stands aside rather than denying, matching this
# guard's fail-open direction (see the header -- open means ALLOW the stop).
# The call stands ALONE with its fail direction as the argument, and no `||`
# tail: bp_read_payload EXITS by itself on a stdin timeout (exit 0 for `open`,
# exit 2 for `closed`), so a `|| exit 0` is not only redundant, it implies the
# helper RETURNS non-zero when it does not. hook-payload-read-bound.t's AC2
# pins the exact one-line shape repo-wide, and it caught this on the full sweep
# -- the check that a scripts/-scoped or hooks/-scoped change never runs.
bp_read_payload open
[ -n "${PAYLOAD:-}" ] || exit 0

CMD="$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null)" || exit 0
[ -n "${CMD:-}" ] || exit 0

# ---------------------------------------------------------------------------
# 1. Is this a run-ending command at all? Narrow on purpose: every OTHER verb
#    of both scripts stays untouched, including `status`, `hold`, `pause` and
#    `ask`. `arm` is untouched too -- arming more is never the failure mode.
# ---------------------------------------------------------------------------
is_run_ending=0
bp_rf_is_run_ending "$CMD" && is_run_ending=1
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
OUTSTANDING="$(bp_outstanding_work "$run_live")"
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
      # INTERRUPT NOTICES ARE NOT AUTHOR TEXT. The harness writes these on the
      # user role with isMeta=0, so they look exactly like a typed message and
      # become $last -- burying whatever the operator actually said one turn
      # earlier. Observed 2026-09-18: "[Request interrupted by user for tool
      # use]" was the newest qualifying record in this transcript.
      #
      # The failure is silent and inverted: an operator who says "stop" and then
      # interrupts a tool call has their instruction masked by the interrupt
      # their own action generated, and the guard reports UNAUTHORISED. That is
      # the same class of bug this guard exists to prevent, pointed the other way.
      next if $text =~ /^\s*\[Request interrupted by user/;
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

  # THE OFF SWITCH THIS GUARD POLICES, WHICH IT COULD NOT PREVIOUSLY READ.
  # `/butler:continuity off` is the documented way an operator disarms, and this
  # guard treats `bp-continuity.pl disarm` / ` off` as a run-ending command it
  # must authorise. But a slash-command invocation is recorded in the transcript
  # structurally, not as prose:
  #
  #   <command-message>butler:continuity</command-message>
  #   <command-name>/butler:continuity</command-name>
  #   <command-args>off</command-args>
  #
  # The whole instruction is the word "off", which appears in none of the
  # patterns below -- and must not be added to them, because "off" in prose
  # ("turn the display off") is not a stop instruction. So the guard blocked the
  # documented off switch and told the operator, wrongly, that they had not
  # asked. Observed 2026-09-18, on a session that was not even armed.
  #
  # NO APOSTROPHES ANYWHERE IN THIS PERL BLOCK. It is inside perl -e '...', so a
  # single quote in a COMMENT closes the string and bash then parses the rest as
  # shell. That is why the patterns below spell an apostrophe \x27, and it is why
  # this file must be checked with `bash -n` and not by eye.
  #
  # Matched structurally rather than by keyword: the command name AND the
  # argument, both inside their tags. Nothing an agent writes into prose can
  # forge this, because the agent cannot author a user turn at all -- which is
  # the same property the transcript channel was chosen for.
  if ($t =~ m{<command-name>\s*/?(?:butler:)?continuity\s*</command-name>}
      && $t =~ m{<command-args>\s*off\s*</command-args>}) {
      print "AUTHORISED\n";
      exit 0;
  }

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

OUT_COUNT=$(printf '%s\n' "$OUTSTANDING" | grep -c '[^[:space:]]')
OUT_HEAD=$(printf '%s\n' "$OUTSTANDING" | grep '[^[:space:]]' | head -n 5)
if [ "$OUT_COUNT" -gt 5 ]; then
  OUT_BLOCK="${OUT_HEAD}
... and $((OUT_COUNT - 5)) more."
else
  OUT_BLOCK="$OUT_HEAD"
fi

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

STILL PENDING OR RUNNING ($OUT_COUNT total, showing up to 5 -- this guard stands aside the moment none are)
$OUT_BLOCK

WHAT TO DO INSTEAD:
  * Re-launch whatever died, record what was lost, and carry on.
  * Genuinely blocked? Queue it -- this does NOT end the turn:
        bp-continuity.sh ask --text "<your question>"
    then continue with everything that does not depend on the answer.
  * Need to keep the turn alive while you wait? Take a bounded hold:
        bp-continuity.pl hold --seconds 600      (as a BACKGROUND call)

THE ASYMMETRY: wrongly continuing costs some tokens. Wrongly stopping abandons the run.
When the signal is ambiguous, CONTINUE.

If the operator has in fact told you to stop, they said so in a message -- and this guard
reads that message and stands aside. It is not standing aside, so they did not.
DENIED
exit 2
