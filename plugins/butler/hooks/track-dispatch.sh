#!/usr/bin/env bash
# track-dispatch.sh — dual-mode hook for Task inside coordinator sessions.
#
# PreToolUse:Task (the START half, unchanged from before this package): records
# which worker is in flight (marker file used by guard-writes.sh for role-scoped
# write rules), mechanically enforces the protocol rule that at most ONE
# write-capable worker runs at a time, and writes a `running` dispatch record.
# Read-only workers may run in parallel freely.
#
# PostToolUse:Task (the COMPLETION half — coordinator-context-discipline/
# 01-deterministic-dispatch-tracking): a butler coordinator's Task dispatch is
# SYNCHRONOUS (its tool_result arrives in the coordinator's own turn — see that
# package's spec §1.2), so PostToolUse on Task brackets exactly the tool_use/
# tool_result pair and is a real, mechanical completion signal. This half
# resolves the matching `running` record to `done`, correlated via a
# `dispatch_key` derived deterministically from tool_input.description — the
# key the START half already stamps on the way in.
#
# THE COMPLETION HALF IS AN OBSERVER, MORE STRICTLY THAN THE START HALF: it may
# NEVER exit 2 (there is no interlock to enforce on a tool that already
# returned) and NEVER write to stdout or stderr on any path (B5) — a missing
# parser, a missing/broken logger, no match found, a backgrounded dispatch, all
# degrade silently to "no record resolved", exactly as the start half already
# degrades to "no record written" for the identical reasons.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
# Coordinator-only: judges carry the env contract (for guard-writes scoping) but
# never dispatch workers, so the one-write-capable-worker bookkeeping is not theirs.
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0

# bp_dispatch_key_of DESCRIPTION -- pure, total text transform (spec §2.1).
# Computed IDENTICALLY by both halves below: called from each, never
# duplicated as separate logic, so the two sides can never disagree about the
# same tool_input.description.
#
#   1. start from DESCRIPTION as a raw string (absent -> "")
#   2. lowercase (ASCII A-Z only)
#   3. every character outside [a-z0-9] becomes '-'
#   4. collapse runs of '-' to a single '-'
#   5. strip leading and trailing '-'
#   6. truncate to 48 characters
#   7. strip trailing '-' again (step 6 may have created one)
#   8. the result is the TOKEN; empty means "no key" -> --dispatch-key is
#      OMITTED by the caller, never passed as ''
#
# `tr -sc 'a-z0-9' '-'` does steps 3+4 in one pass: -c complements the kept
# set (so every non-[a-z0-9] byte is a candidate for translation), and -s
# squeezes REPEATS of the translated output character ('-') together --
# exactly "replace, then collapse runs", with no separate regex needed.
# After that squeeze, at most ONE leading and ONE trailing '-' can remain
# (a run of 2+ is structurally impossible), so a single `#`/`%` parameter
# strip suffices for steps 5 and 7 -- no loop required either time.
bp_dispatch_key_of() {
  local desc="${1:-}" key
  key=$(printf '%s' "$desc" | tr 'A-Z' 'a-z' | tr -sc 'a-z0-9' '-')
  key="${key#-}"
  key="${key%-}"
  key="${key:0:48}"
  key="${key%-}"
  printf '%s' "$key"
}

# bp_dispatch_attribution_tokens -- sets the BPTOK/PKGTOK globals from
# BP_BLUEPRINT/BP_PACKAGE (spec §2.5's attribution rule): from the
# environment only, validated and OMITTED (never guessed, never
# substituted) when unset/empty/malshaped; '.'/'..' are explicitly rejected
# even though they match the character class.
#
# fixbatch SF-6: shared by BOTH halves rather than copy-pasted, so the two
# sides can never silently drift apart -- MF-1's whole safety argument (both
# halves omit blueprint/package IDENTICALLY when the env var is unset, so a
# resolve_plan comparing "both absent" still matches) depends on them
# agreeing byte for byte.
bp_dispatch_attribution_tokens() {
  BPTOK=""
  if [[ "${BP_BLUEPRINT:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    && [ "${BP_BLUEPRINT}" != "." ] && [ "${BP_BLUEPRINT}" != ".." ]; then
    BPTOK="$BP_BLUEPRINT"
  fi
  PKGTOK=""
  if [[ "${BP_PACKAGE:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    && [ "${BP_PACKAGE}" != "." ] && [ "${BP_PACKAGE}" != ".." ]; then
    PKGTOK="$BP_PACKAGE"
  fi
}

# bp_read_payload cannot itself exit (mode 'open': a stuck stdin stands aside,
# never blocks) -- moved above the event-kind branch so BOTH halves see the
# SAME payload read, at the SAME point, under the SAME timeout discipline.
bp_read_payload open
EVENT=$(bp_json_get "$PAYLOAD" hook_event_name) || EVENT=""
if [ -z "$EVENT" ]; then
  # Parser-free fallback: bp_json_get returned nothing (no JSON parser
  # available, or the field itself unreadable). Previously this matched a
  # literal '"hook_event_name":"PostToolUse"' substring anywhere in the
  # payload -- but the payload also carries tool_response (a worker's own
  # RETURNED TEXT) and tool_input.prompt (an inlined document a coordinator
  # may have quoted verbatim), either of which can contain that exact
  # substring with no relation to the real event kind, forging a
  # misclassification.
  #
  # fixbatch MEDIUM-1/SF-4: use a STRUCTURAL signal instead -- a PostToolUse
  # payload always carries a top-level `tool_response` key; a PreToolUse
  # payload never does (the tool has not returned yet). Grepped as a JSON
  # key pattern, not a value match, so it is far less likely to appear
  # embedded inside quoted prose than the previous full-event-name string.
  #
  # fixbatch MEDIUM-2: ambiguous stays PreToolUse. If this grep does not
  # match, EVENT stays empty and control falls through to the PreToolUse/
  # enforcement path below, which still runs bp_hook_require_json_parser and
  # correctly fails closed (exit 2) per this file's own existing fail-closed
  # design -- the SAFE direction. A real completion event misclassified as
  # PreToolUse just leaves one dispatch record unresolved (the already-
  # documented, over-report-safe residual `outstanding` is built to
  # tolerate); a real PreToolUse event misclassified as PostToolUse would
  # skip the marker interlock entirely, which is unsafe.
  if printf '%s' "$PAYLOAD" | grep -q '"tool_response"[[:space:]]*:'; then
    EVENT=PostToolUse
  fi
fi

if [ "$EVENT" = "PostToolUse" ]; then
  # --- completion half (coordinator-context-discipline/
  #     01-deterministic-dispatch-tracking spec §2.7/B6) -------------------
  #
  # Every branch below falls through to the single `exit 0` at the bottom of
  # this if-block. Nothing here writes to stdout/stderr or exits non-zero,
  # on ANY path (B5) -- including a malformed payload, a missing parser, a
  # missing/erroring bp-dispatch-log.pl, an unwritable store, or simply no
  # matching record. B6: a BACKGROUNDED Task's PostToolUse fires at launch,
  # not completion, so it must resolve nothing -- detected by a literal-JSON
  # grep, never bp_json_get (which returns empty for a JSON boolean, so it
  # cannot see `true` here at all).
  #
  # fixbatch MEDIUM-1/SF-4: bound that grep to (approximately) the
  # tool_input object rather than the whole payload. Eleven tracked files in
  # this repo -- including this package's own spec -- contain the literal
  # string '"run_in_background": true', so a worker quoting one of them
  # inside tool_response (its own returned text), or a coordinator inlining
  # one inside tool_input.prompt, could otherwise permanently disable
  # completion tracking for that dispatch. No real JSON parser is
  # guaranteed here (bp_json_get itself cannot see a boolean, per the
  # comment above), so this is a TEXT-bounded narrowing, not a real JSON
  # slice: Claude Code hook payloads are single-line JSON, so cutting at the
  # first literal occurrence of "tool_input" and, if present, the first
  # literal occurrence of "tool_response" AFTER it (tool_response is always
  # a sibling of tool_input, never nested inside it, and is exactly the
  # worker's-own-text carrier this narrowing exists to exclude) is the
  # safest available bound with only bash + grep on hand. It is not proof
  # against a pathological tool_input.prompt that itself quotes the literal
  # string "tool_response" before a genuine run_in_background field -- that
  # residual is accepted; run_in_background is a real Task-tool parameter
  # that normally appears without any user-authored text anywhere near it.
  TI_SLICE="${PAYLOAD#*\"tool_input\"}"
  TI_SLICE="${TI_SLICE%%\"tool_response\"*}"
  if [ "${BP_DISPATCH_LOG_OFF:-}" != "1" ] \
     && ! printf '%s' "$TI_SLICE" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true'; then
    TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type 2>/dev/null || true)
    if [ -n "$TYPE" ]; then
      BASE="${TYPE##*:}"
      if [[ "$BASE" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$BASE" == bp-* ]] \
         && bp_is_absolute_path "${BP_PROJECT_ROOT:-}"; then
        DESC=$(bp_json_get "$PAYLOAD" tool_input.description 2>/dev/null || true)
        KEY=$(bp_dispatch_key_of "$DESC")

        # Attribution, identical discipline to the start half -- SF-6: both
        # halves call the ONE shared function so they can never drift.
        bp_dispatch_attribution_tokens

        LOGGER="$HOOK_DIR/../scripts/bp-dispatch-log.pl"
        ARGS=(resolve --worker-type "$BASE" --status done --root "${BP_PROJECT_ROOT}")
        [ -n "$KEY" ]    && ARGS+=(--dispatch-key "$KEY")
        [ -n "$BPTOK" ]  && ARGS+=(--blueprint "$BPTOK")
        [ -n "$PKGTOK" ] && ARGS+=(--package "$PKGTOK")
        # </dev/null: the child can never inherit a pipe that never closes.
        # >/dev/null 2>&1: this half may NEVER speak (B5) -- neither the
        # logger's "resolved ..."/"NO-MATCH: ..." line nor its diagnostics
        # may reach Claude Code. || :: the child's exit status (including
        # the deliberately-non-error exit 5, "resolved nothing") is
        # discarded -- there is nothing for an OBSERVER to do with it.
        perl "$LOGGER" "${ARGS[@]}" </dev/null >/dev/null 2>&1 || :
      fi
    fi
  fi
  exit 0                                       # the ONLY exit of this branch
fi

# --- start half (unchanged except the §2.1/§3.2 dispatch_key additions) ----
[ -z "$(bp_active_stop_signal)" ] || exit 0
bp_hook_require_json_parser

TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type)
[ -n "$TYPE" ] || exit 0

MARKER=$(marker_path)
mkdir -p "$(dirname "$MARKER")"

is_writer() { [[ "$1" == *bp-implementer* || "$1" == *bp-test-writer* || "$1" == *bp-ui-prober* ]]; }

if is_writer "$TYPE"; then
  if [ -f "$MARKER" ]; then
    CURRENT=$(cat "$MARKER" 2>/dev/null || true)
    if [ -n "$CURRENT" ] && is_writer "$CURRENT"; then
      echo "BLOCKED: a write-capable worker ($CURRENT) is already in flight. The protocol allows at most one write-capable worker at a time — wait for it to return before dispatching $TYPE." >&2
      exit 2
    fi
  fi
  printf '%s' "$TYPE" > "$MARKER"
fi

# --- dispatch record write step (agent-telemetry/03-dispatch-write-path) ---
#
# The hook is an OBSERVER: every branch below falls through to the final
# `exit 0` at the bottom of this file. Nothing here may exit 2 or otherwise
# block the dispatch — a missing/broken/slow logger degrades to "no record
# written", never to "dispatch blocked" (spec S1.1).
#
# Only bp-* subagent types are recorded (Decision 6 vocabulary); the raw
# TYPE (e.g. "butler:bp-implementer") is normalized to its base name by
# stripping through the LAST ':'. --worker-type passes the NORMALIZED base,
# never the raw prefixed value.
if [ "${BP_DISPATCH_LOG_OFF:-}" != "1" ]; then
  BASE="${TYPE##*:}"
  if [[ "$BASE" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$BASE" == bp-* ]]; then
    NOW=$(date +%s 2>/dev/null || echo 0)
    if [[ "$NOW" =~ ^[0-9]+$ ]] && [ "$NOW" -gt 0 ] && bp_is_absolute_path "${BP_PROJECT_ROOT:-}"; then
      # Attribution -- SF-6: both halves call the ONE shared function
      # (defined above, alongside bp_dispatch_key_of) so they can never
      # silently drift apart.
      bp_dispatch_attribution_tokens

      # dispatch_key (spec §2.1/B2): the correlation key the completion half
      # will recompute from the SAME field of the SAME tool_name's payload.
      # Empty means "no usable description" -> the option is OMITTED below,
      # never stamped as '' (never null, never empty — B2).
      DESC=$(bp_json_get "$PAYLOAD" tool_input.description)
      KEY=$(bp_dispatch_key_of "$DESC")

      LOGDIR="$BP_PROJECT_ROOT/.ccpraxis-local-data/.dispatch-log"

      # Deduplication (spec S2.3, widened by B3): a `running` record whose
      # normalized worker_type equals BASE, whose package is absent or
      # equals PKGTOK, whose started_at is within 120s of NOW in either
      # direction, AND whose dispatch_key is EITHER ABSENT OR EQUAL TO KEY,
      # means the coordinator already stamped this dispatch — write nothing.
      # A record carrying a DIFFERENT dispatch_key no longer claims: two
      # concurrent same-type dispatches with different descriptions now
      # produce two records, where they previously collapsed to one.
      # Fork-free, bounded scan: over SCAN_CAP files, stand aside (treat as
      # claimed) rather than prove a negative in unbounded time.
      WT_RE='"worker_type":"([^"]*)"'
      PKG_RE='"package":"([^"]*)"'
      SA_RE='"started_at":([0-9]+)'
      DK_RE='"dispatch_key":"([^"]*)"'
      CLAIMED=0
      if [ -d "$LOGDIR" ]; then
        n=0
        for f in "$LOGDIR"/*.json; do
          [ -f "$f" ] || continue
          n=$((n + 1))
          if [ "$n" -gt 2000 ]; then
            # Over SCAN_CAP: stand aside for THIS dispatch (correct -- proving
            # a negative in unbounded time is worse), but do not simply leave.
            #
            # Standing aside alone was a ONE-WAY DOOR (bug 20260908-225444-b9db):
            # the store only grew, so once past 2000 it stayed past 2000, and
            # this branch then blocked the only thing that could ever shrink it
            # -- the logger, whose `start` is where retention now runs. Recording
            # would have been off from that moment on, silently and forever.
            #
            # So the over-cap path RUNS THE PRUNE ITSELF. This dispatch still
            # goes unrecorded; the next one finds a store back under 256 and
            # records normally. The alarm line is what makes the incident
            # discoverable at all, and it is bounded twice over: the prune that
            # follows it stops this branch from firing again for hundreds of
            # dispatches, and the append is skipped once the file passes 64 KiB
            # (the same ceiling bp-dispatch-log.pl's own note_alarm applies).
            ALARM="$LOGDIR/retention-alarm.log"
            ASZ=0
            [ -f "$ALARM" ] && ASZ=$(wc -c < "$ALARM" 2>/dev/null || echo 0)
            [ "$ASZ" -lt 65536 ] 2>/dev/null && \
              printf '%s track-dispatch.sh stood aside: over 2000 records, this dispatch went unrecorded; running a prune\n' \
                "$NOW" >> "$ALARM" 2>/dev/null || :
            perl "$HOOK_DIR/../scripts/bp-dispatch-log.pl" prune \
                 --root "$BP_PROJECT_ROOT" </dev/null >/dev/null 2>&1 || :
            CLAIMED=1
            break
          fi
          LINE=""
          IFS= read -r -N 8192 LINE < "$f" 2>/dev/null || true
          case "$LINE" in
            *'"status":"running"'*) ;;
            *) continue ;;
          esac
          [[ "$LINE" =~ $WT_RE ]] || continue
          rt="${BASH_REMATCH[1]##*:}"
          [ "$rt" = "$BASE" ] || continue
          if [[ "$LINE" =~ $PKG_RE ]]; then
            [ "${BASH_REMATCH[1]}" = "$PKGTOK" ] || continue
          fi
          [[ "$LINE" =~ $SA_RE ]] || continue
          d=$((NOW - 10#${BASH_REMATCH[1]}))
          [ "$d" -lt 0 ] && d=$((-d))
          [ "$d" -le 120 ] || continue
          if [[ "$LINE" =~ $DK_RE ]]; then
            [ "${BASH_REMATCH[1]}" = "$KEY" ] || continue
          fi
          CLAIMED=1
          break
        done
      fi

      if [ "$CLAIMED" = 0 ]; then
        ID="hk-${BPTOK:-nobp}-${PKGTOK:-nopkg}-${BASE}-${NOW}-$$-${RANDOM}"
        LOGGER="$HOOK_DIR/../scripts/bp-dispatch-log.pl"
        ARGS=(start --id "$ID" --worker-type "$BASE" --role worker --root "$BP_PROJECT_ROOT")
        [ -n "$BPTOK" ]  && ARGS+=(--blueprint "$BPTOK")
        [ -n "$PKGTOK" ] && ARGS+=(--package "$PKGTOK")
        [ -n "$KEY" ]    && ARGS+=(--dispatch-key "$KEY")
        # </dev/null: the child can never inherit a pipe that never closes.
        # >/dev/null 2>&1: a PreToolUse hook's stdout is a protocol channel —
        # neither the logger's "started ..." line nor its diagnostics may
        # reach Claude Code. || :: the child's exit status is discarded.
        perl "$LOGGER" "${ARGS[@]}" </dev/null >/dev/null 2>&1 || :
      fi
    fi
  fi
fi

exit 0
