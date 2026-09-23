#!/usr/bin/env bash
# context-ceiling-guidance.sh — PostToolUse on Task|Bash.
# coordinator-context-discipline/02-context-ceiling-guidance-and-flush spec §2.8.
#
# At or above the SOFT context ceiling, attaches a short, hedged guidance
# reminder to a tool result the coordinator was already going to receive
# (additionalContext, the same mechanism plugins/backpack/hooks/auto-declare.pl
# already uses). Below soft: exits silently, having spent exactly one bounded
# tail-read (the --ctx-usage probe below) and nothing else.
#
# Fails OPEN (silent, exit 0) on: BP_LEDGER unset, BP_ROLE=judge, no perl on
# PATH, an unreadable/absent transcript, a probe that dies. D-D: everything
# here is conditional on a number that was not obtained, and a hook that
# cannot measure must never assert anything about the measurement.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd) || exit 0
[ -n "$HOOK_DIR" ] && [ -r "$HOOK_DIR/lib.sh" ] || exit 0
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0
bp_hook_gate
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0
bp_read_payload open
command -v perl >/dev/null 2>&1 || exit 0

PKG="${BP_PACKAGE:-pkg}"
case "$PKG" in ''|*/*|.|..) exit 0 ;; esac

# THE ONE BOUNDED TAIL-READ. Nothing else in this hook reads the transcript.
PROBE_OUT=$(perl "$HOOK_DIR/../scripts/bp-orchestrator.pl" --ctx-usage "$BP_DIR" "$PKG" 2>/dev/null) || exit 0

N=""; SOFT=""; HARD=""; TIER=""
while IFS= read -r line; do
  case "$line" in
    context_tokens:*) N="${line#context_tokens: }" ;;
    ceiling_soft:*)   SOFT="${line#ceiling_soft: }" ;;
    ceiling_hard:*)   HARD="${line#ceiling_hard: }" ;;
    tier:*)           TIER="${line#tier: }" ;;
  esac
done <<EOF
$PROBE_OUT
EOF

case "$N" in ''|unknown) exit 0 ;; esac
case "$SOFT" in ''|*[!0-9]*) exit 0 ;; esac
case "$HARD" in ''|*[!0-9]*) exit 0 ;; esac

STATE="$BP_DIR/runs/$PKG.ctx-guidance"

case "$TIER" in
  none)
    rm -f "$STATE" 2>/dev/null
    exit 0
    ;;
  soft|hard)
    ;;
  *)
    exit 0
    ;;
esac

INTERVAL="${BP_CTX_GUIDANCE_INTERVAL_SECS:-900}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=900 ;; esac
[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=900

NOW=$(date +%s 2>/dev/null || echo 0)
if [ -f "$STATE" ]; then
  LAST=$(sed -n 's/^last_emit: *\([0-9][0-9]*\).*/\1/p' "$STATE" 2>/dev/null | head -1)
  case "$LAST" in
    ''|*[!0-9]*) ;;  # malformed/missing -> emit
    *)
      if [ "$NOW" -gt 0 ] && [ "$LAST" -gt 0 ] 2>/dev/null; then
        AGE=$(( NOW - LAST ))
        # A negative AGE (clock moved backwards, or a corrupted/future
        # last_emit) fails toward SPEAKING, not toward permanent silence
        # (spec §5.3; Redteam MEDIUM-1).
        if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL" ]; then
          exit 0
        fi
      fi
      ;;
  esac
fi

# The outstanding check, run ONLY on the emit path (spec §2.8), scoped exactly
# per package 01's amended consumer rule for automated use.
SUMMARY=""
if command -v perl >/dev/null 2>&1 && [ -f "$HOOK_DIR/../scripts/bp-dispatch-log.pl" ]; then
  OUT=$(perl "$HOOK_DIR/../scripts/bp-dispatch-log.pl" outstanding --blueprint "${BP_BLUEPRINT:-}" --package "${BP_PACKAGE:-}" --root "${BP_PROJECT_ROOT:-}" 2>/dev/null)
  # tail -1, not head -1: bp-dispatch-log.pl outstanding prints per-record
  # detail lines before the summary, so the real summary is always the LAST
  # matching line (Redteam LOW-1).
  SUMMARY=$(printf '%s\n' "$OUT" | sed -n 's/^summary: //p' | tail -1)
fi
if [ -z "$SUMMARY" ]; then
  SUMMARY='the dispatch check could not be run, so whether anything is outstanding was not determined.'
fi

LINE1="[context-ceiling] Your last recorded own-turn context measured about $N tokens, at or above the soft ceiling of $SOFT (hard ceiling $HARD). This is guidance, not a block."
LINE2='[context-ceiling] You are also at or above the hard ceiling, so a flush is in force: Task dispatch and non-essential Bash are denied until you write a concrete "## Next action" and stop.'
LINE3="[context-ceiling] Dispatch check (bp-dispatch-log.pl outstanding, scoped to this blueprint and package): $SUMMARY"
LINE4='[context-ceiling] Consider finishing the step you are on, writing a concrete "## Next action", leaving status: non-terminal, and stopping, per coordinator-protocol'"'"'s "Context-growth checkpoint" section. The figure above is read from the last usage record in your own runs transcript, so it may lag your true current context and is a signal, not a verdict.'

if [ "$TIER" = "hard" ]; then
  CTX="$LINE1
$LINE2
$LINE3
$LINE4"
else
  CTX="$LINE1
$LINE3
$LINE4"
fi

perl -MJSON::PP -e '
  binmode(STDIN, ":raw"); binmode(STDOUT, ":raw");
  my $ctx = do { local $/; <STDIN> };
  $ctx =~ s/\n\z//;
  print JSON::PP->new->encode({ hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $ctx } });
' <<EOF 2>/dev/null
$CTX
EOF
EMIT_RC=$?

# Only rate-limit the NEXT fire if this one actually emitted (Review m-4): a
# host missing JSON::PP must not silently self-suppress for the interval.
if [ "$EMIT_RC" -eq 0 ]; then
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  printf 'last_emit: %s\n' "$NOW" > "$STATE" 2>/dev/null
fi

exit 0
