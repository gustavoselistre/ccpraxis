#!/usr/bin/env bash
# guard-ask-operator.sh — an UNATTENDED RUN MUST NOT STOP TO ASK A QUESTION.
#
# WHAT HAPPENED, repeatedly. An agent driving unattended work reaches something
# it is unsure about, opens AskUserQuestion, and the entire run stops dead until
# a human happens to look. The operator's own account: "a whole unattended run
# halt because of some blocking user input. 99% of the times it was not actually
# necessary and could have progressed while batching the question to the end or
# having the agent decide by itself when it's a non-product question."
#
# Both halves of that matter. The stopping is expensive -- hours of idle where
# there was work available -- and the question usually did not need an operator
# at all. There is already a standing ruling to this effect
# (.ccpraxis-local-data/guidance/escalate-product-decisions-only.md), and it kept
# being violated, which is this repo's recurring lesson: a written instruction is
# not an enforcement mechanism.
#
# WHAT IT DOES. While a run is ACTIVE, AskUserQuestion is denied and the question
# is APPENDED to the run's question queue. Nothing is lost -- it is batched for
# the end of the run, which is what "batch it" needs in order to be more than a
# hope -- and the agent is told to carry on with the work it can still do.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not fire when a run is inert, paused
# or finished. An interactive session asking its operator something is normal and
# good; only `active` means unattended work is in flight right now. It also never
# touches any other tool: an agent that genuinely cannot proceed can still finish
# or pause the run explicitly, which is a deliberate act rather than a side
# effect of asking a question.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

RUNSTATE="$HOOK_DIR/../scripts/bp-runstate.pl"
[ -f "$RUNSTATE" ] || exit 0

# UNATTENDED means either of two things, and both must trip this.
#
#   * a RUN is active -- `effective` resolves a pause whose watcher died back to
#     active, so a stale pause cannot be used to slip a question through;
#   * CONTINUITY IS ARMED for this session. Arming is the operator saying "watch
#     this, I am not here", so an armed session is unattended by definition. The
#     first version of this guard checked only the run, which meant a plain
#     armed overnight session -- the exact case the operator described -- sailed
#     straight past it.
UNATTENDED=0
WHY="unattended work is in flight"

STATE=$(perl "$RUNSTATE" status 2>/dev/null | perl -ne 'print $1 if /"state"\s*:\s*"([a-z_]+)"/')
[ "${STATE:-}" = "active" ] && { UNATTENDED=1; WHY="a run is ACTIVE"; }

if [ "$UNATTENDED" -eq 0 ]; then
  bp_read_payload open
  _SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
  if [ -n "${_SID:-}" ]; then
    _CDIR=$(bp_continuity_active_dir 2>/dev/null || true)
    [ -n "${_CDIR:-}" ] && [ -f "$_CDIR/$_SID" ] && { UNATTENDED=1; WHY="continuity is ARMED for this session"; }
  fi
  _PAYLOAD_READ=1
fi

[ "$UNATTENDED" -eq 1 ] || exit 0

# Read the payload only if the armed-check above did not already do it --
# bp_read_payload consumes stdin, and a second call would block until its
# timeout and then stand aside, silently letting every question through.
[ -n "${_PAYLOAD_READ:-}" ] || bp_read_payload open

# bp_json_get resolves dot-separated paths to SCALARS and has no array
# indexing, and AskUserQuestion's payload nests the text inside
# tool_input.questions[] -- so asking it for the question yields nothing, and a
# queued question with no text is barely better than no queue at all. Pull every
# question out with perl instead, which also handles the multi-question case
# bp_json_get could not have expressed at all.
QTEXT=$(printf '%s' "$PAYLOAD" | perl -MJSON::PP -0777 -ne '
    my $j = eval { decode_json($_) } or exit 0;
    my $q = $j->{tool_input}{questions};
    exit 0 unless ref $q eq "ARRAY";
    my @out = grep { defined && length } map {
        ref $_ eq "HASH" ? $_->{question} : undef
    } @$q;
    print join(" | ", @out);
' 2>/dev/null || true)
[ -n "${QTEXT:-}" ] || QTEXT="(question text not recoverable from the payload)"

# Queue it beside the run state, through the verb that owns that path.
QDIR=$(perl "$RUNSTATE" state-dir 2>/dev/null || true)
if [ -n "${QDIR:-}" ]; then
  mkdir -p "$QDIR" 2>/dev/null || true
  printf -- '- [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$QTEXT" \
    >> "$QDIR/questions.md" 2>/dev/null || true
fi

cat >&2 <<EOF
BLOCKED (butler ask-operator guard): $WHY, so asking the operator now would stop unattended work for an answer nobody is there to give.

The question has been queued and will not be lost:
    ${QDIR:-<queue unavailable>}/questions.md

Do this instead:
  1. Decide it yourself if it is not a PRODUCT decision. Naming, structure,
     which of two equivalent approaches to take -- these are yours. See
     .ccpraxis-local-data/guidance/escalate-product-decisions-only.md
  2. Carry on with the work that does NOT depend on the answer, and surface the
     batched questions when the run reports.
  3. Only if nothing can proceed without it, end the run deliberately:
         bp-runstate.pl finish --reason "blocked: <what you need>"
     That is a decision, not a side effect of asking.
EOF
exit 2
