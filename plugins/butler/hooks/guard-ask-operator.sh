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
# is APPENDED to the run's question queue. Nothing is lost within the 16-item
# safety cap below -- it is batched for the end of the run, which is what
# "batch it" needs in order to be more than a hope -- and the agent is told to
# carry on with the work it can still do. The deny decision itself never
# depends on the cap: every question in a call is refused regardless of how
# many there are or where the logging loop below stops.
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
fi

[ "$UNATTENDED" -eq 1 ] || exit 0

# bp_read_payload (lib.sh) is now safe to call more than once per process --
# whichever of this call and the one in the armed-check branch above runs
# first performs the real read; the other is a no-op that leaves PAYLOAD
# exactly as the first call left it. No caller-side bookkeeping needed any
# more; the guard against a hung-or-clobbered second read now lives in
# lib.sh itself, once, for every caller.
bp_read_payload open

# AskUserQuestion's payload nests the text inside tool_input.questions[] --
# bp_json_get (lib.sh) now indexes arrays, so pull each question out with a
# bounded loop rather than a standalone perl parse. 16 is a safety upper
# bound, not an assumed exact count -- the real fixture this must keep green
# (no-halt-for-questions.t AC7) exercises 4 questions in one call. Stop at the
# first gap: AskUserQuestion never produces a sparse array, so this is a
# deliberate, documented narrowing relative to the retired parse, not a bug.
# Do NOT raise or remove the cap -- it costs nothing to the deny decision
# above (that has already committed, unconditionally, by the time this loop
# runs); the cap only bounds how much LOGGED text this loop can build.
QTEXT=""
_QI=0
while [ "$_QI" -lt 16 ]; do
  _Q=$(bp_json_get "$PAYLOAD" "tool_input.questions.${_QI}.question" 2>/dev/null || true)
  [ -n "$_Q" ] || break
  if [ -n "$QTEXT" ]; then
    QTEXT="$QTEXT | $_Q"
  else
    QTEXT="$_Q"
  fi
  _QI=$((_QI + 1))
done
[ -n "${QTEXT:-}" ] || QTEXT="(question text not recoverable from the payload)"

# If the loop stopped because it hit the cap (not because of a real gap),
# check one index past it: a non-empty result there means the payload
# genuinely had more than 16 questions, and the logged text would otherwise
# claim completeness it doesn't have. One extra bp_json_get call, only on
# this already-rare path.
if [ "$_QI" -eq 16 ]; then
  _QMORE=$(bp_json_get "$PAYLOAD" "tool_input.questions.16.question" 2>/dev/null || true)
  [ -n "$_QMORE" ] && QTEXT="$QTEXT | (+more, truncated at 16)"
fi

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
