#!/usr/bin/env bash
# context-ceiling-flush.sh — PreToolUse on Task|Bash.
# coordinator-context-discipline/02-context-ceiling-guidance-and-flush spec §2.9.
#
# At or above the HARD context ceiling, denies Task dispatch outright and
# denies any Bash command that is not exactly flush work (a bounded
# bp-ledger.pl/bp-dispatch-log.pl allow-list). Bounded to 5 flush turns; past
# that, the overrun is recorded to disk and the coordinator is told to
# escalate through status: blocked + ## Escalation.
#
# Fails OPEN (silent, exit 0) on: BP_LEDGER unset, BP_ROLE=judge, no perl on
# PATH, an unreadable/absent transcript, a probe that dies, tier: unknown.
# D-D: everything here is conditional on a number that was not obtained.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd) || exit 0
[ -n "$HOOK_DIR" ] && [ -r "$HOOK_DIR/lib.sh" ] || exit 0
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0
bp_hook_gate
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0
bp_read_payload closed

TOOL=$(bp_json_get "$PAYLOAD" tool_name 2>/dev/null) || TOOL=""
if [ -z "$TOOL" ]; then
  # Parser-free fallback (gate-headless-background.sh:51 idiom): a malformed
  # payload that nonetheless carries the literal Task marker must still be
  # denied at hard (B25's last case).
  if printf '%s' "$PAYLOAD" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"Task"'; then
    TOOL=Task
  else
    exit 0
  fi
fi

command -v perl >/dev/null 2>&1 || exit 0

PKG="${BP_PACKAGE:-pkg}"
case "$PKG" in ''|*/*|.|..) exit 0 ;; esac
FLUSH_STATE="$BP_DIR/runs/$PKG.ctx-flush"
OVERRUN_LOG="$BP_DIR/runs/$PKG.ctx-flush-overrun.log"
OVERRUN_ONCE="$BP_DIR/runs/$PKG.ctx-flush-overrun.once"
CAP=5

# THE ONE BOUNDED TAIL-READ. Nothing else in this hook reads the transcript.
PROBE_OUT=$(perl "$HOOK_DIR/../scripts/bp-orchestrator.pl" --ctx-usage "$BP_DIR" "$PKG" 2>/dev/null) || exit 0

N=""; HARD=""; TIER=""
while IFS= read -r line; do
  case "$line" in
    context_tokens:*) N="${line#context_tokens: }" ;;
    ceiling_hard:*)   HARD="${line#ceiling_hard: }" ;;
    tier:*)           TIER="${line#tier: }" ;;
  esac
done <<EOF
$PROBE_OUT
EOF

case "$TIER" in
  hard) ;;
  soft|none)
    rm -f "$FLUSH_STATE" 2>/dev/null
    rmdir "$OVERRUN_ONCE" 2>/dev/null
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
case "$N" in ''|unknown) exit 0 ;; esac
case "$HARD" in ''|*[!0-9]*) exit 0 ;; esac

# --- at or above hard from here on -----------------------------------------

TURNS=1
if [ -f "$FLUSH_STATE" ]; then
  PREV=$(sed -n 's/^turns: *\([0-9][0-9]*\).*/\1/p' "$FLUSH_STATE" 2>/dev/null | head -1)
  case "$PREV" in
    ''|*[!0-9]*) TURNS=1 ;;  # corrupt/missing counter -> treat as absent, restart at 1
    *) TURNS=$((PREV + 1)) ;;
  esac
fi
STARTED_AT=""
if [ -f "$FLUSH_STATE" ]; then
  STARTED_AT=$(sed -n 's/^started_at: *\([0-9][0-9]*\).*/\1/p' "$FLUSH_STATE" 2>/dev/null | head -1)
fi
case "$STARTED_AT" in ''|*[!0-9]*) STARTED_AT=$(date +%s 2>/dev/null || echo 0) ;; esac

mkdir -p "$(dirname "$FLUSH_STATE")" 2>/dev/null
{
  printf 'started_at: %s\n' "$STARTED_AT"
  printf 'turns: %s\n' "$TURNS"
} > "$FLUSH_STATE" 2>/dev/null

# next_action_written -- one bounded read of $BP_LEDGER's "## Next action" body.
next_action_written() {
  local ledger="${BP_LEDGER:-}"
  [ -n "$ledger" ] && [ -f "$ledger" ] || { echo unknown; return; }
  local body
  body=$(perl -0777 -ne '
    if (/##\s*Next action[ \t]*\n(.*?)(?:\n##\s|\z)/s) {
      my $b = $1;
      $b =~ s/^\s+|\s+$//g;
      print $b;
    }
  ' "$ledger" 2>/dev/null)
  if [ -z "$body" ]; then
    echo false
    return
  fi
  case "$body" in
    '<'*'>') echo false ;;
    *) echo true ;;
  esac
}

allowed_bash() {
  local cmd="$1"
  # Substitution/redirection pre-check (spec §2.9 driver amendment, HIGH-2/M-1):
  # backtick and $(...) execute even inside double quotes, so they are denied
  # unconditionally; <(...) / >(...) process substitution the same way.
  case "$cmd" in
    *'`'*|*'$('*|*'<('*|*'>('*) return 1 ;;
  esac
  local re_ledger='^(perl[[:space:]]+)?([^[:space:]]*/)?bp-ledger\.pl[[:space:]]+(set-status|set-next-action|tick-step|append-attempt|add-output|validate)([[:space:]]|$)'
  local re_dispatch='^(perl[[:space:]]+)?([^[:space:]]*/)?bp-dispatch-log\.pl[[:space:]]+outstanding([[:space:]]|$)'

  # Quote-stripped view of $cmd (quoted spans blanked out), used only to
  # decide (a) whether an UNQUOTED redirection is present, and (b) whether
  # any UNQUOTED separator/operator is present at all -- never used for the
  # allow-list match itself, which always reads the real $cmd.
  local stripped
  stripped=$(printf '%s' "$cmd" | perl -0777 -pe '
    s/"[^"]*"/ /g;
    s/\x27[^\x27]*\x27/ /g;
  ' 2>/dev/null) || return 1
  case "$stripped" in
    *'<'*|*'>'*) return 1 ;;
  esac

  local trimmed_whole="$cmd"
  trimmed_whole="${trimmed_whole#"${trimmed_whole%%[![:space:]]*}"}"
  trimmed_whole="${trimmed_whole%"${trimmed_whole##*[![:space:]]}"}"

  # Fast path (spec §2.9 driver amendment, MAJOR-M-2): if no UNQUOTED
  # separator/operator is present anywhere, the whole trimmed command is a
  # single invocation end-to-end, and matching the allow-list ERE from the
  # start is matching it end-to-end -- this is what lets a legitimate quoted
  # argument (e.g. --body "Dispatch X; then Y") pass without ever being
  # tokenised.
  case "$stripped" in
    *';'*|*'&'*|*'|'*|*$'\n'*|*$'\r'*) ;;  # falls through to the segment path
    *)
      if [[ "$trimmed_whole" =~ $re_ledger ]] || [[ "$trimmed_whole" =~ $re_dispatch ]]; then
        return 0
      fi
      return 1
      ;;
  esac

  # Segment path: normalise every command-separator shape -- ';', '&&',
  # '||', '|', a lone '&', a literal newline, a literal '\r' -- to ';' and
  # require EVERY non-empty segment to independently match (BLOCKING/HIGH-1,
  # MAJOR/HIGH-2).
  local normalized="$cmd"
  normalized="${normalized//&&/;}"
  normalized="${normalized//||/;}"
  normalized="${normalized//|/;}"
  normalized="${normalized//$'\n'/;}"
  normalized="${normalized//$'\r'/;}"
  normalized="${normalized//&/;}"

  local IFS_SAVE="$IFS"
  local seg trimmed
  local -a segs=()
  IFS=';' read -r -d '' -a segs <<<"$normalized" || true
  IFS="$IFS_SAVE"

  local any=0
  if [ "${#segs[@]}" -gt 0 ]; then
    for seg in "${segs[@]}"; do
      trimmed="${seg#"${seg%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [ -n "$trimmed" ] || continue
      any=1
      if [[ "$trimmed" =~ $re_ledger ]] || [[ "$trimmed" =~ $re_dispatch ]]; then
        continue
      fi
      return 1
    done
  fi
  [ "$any" -eq 1 ] || return 1
  return 0
}

deny() {
  local tail_line="$1"
  local blueprint="${BP_BLUEPRINT:-}"
  local package="${BP_PACKAGE:-}"
  {
    printf 'BLOCKED: a context-ceiling flush is in force. Your last recorded own-turn context measured about %s tokens, at or above the hard ceiling of %s.\n' "$N" "$HARD"
    printf 'Permitted while the flush is in force: Read, Edit and Grep (this hook does not gate them at all), plus a Bash command consisting only of bp-ledger.pl set-status|set-next-action|tick-step|append-attempt|add-output|validate invocations, or a bp-dispatch-log.pl outstanding check.\n'
    printf 'Remedy: run bp-dispatch-log.pl outstanding --blueprint %s --package %s and record what it reports, write a concrete "## Next action" with bp-ledger.pl set-next-action, leave status: non-terminal, then stop.\n' "$blueprint" "$package"
    printf '%s\n' "$tail_line"
  } >&2
  exit 2
}

if [ "$TURNS" -gt "$CAP" ]; then
  # Overrun. Exactly once per flush -- gated on an atomic mkdir sentinel
  # (Redteam MEDIUM-2) rather than on the unlocked $TURNS value, so two
  # concurrent hook fires cannot both append a line to the overrun log.
  if mkdir "$OVERRUN_ONCE" 2>/dev/null; then
    NAW=$(next_action_written)
    mkdir -p "$(dirname "$OVERRUN_LOG")" 2>/dev/null
    ISO=$(perl -e 'my @g = gmtime(time); printf "%04d-%02d-%02dT%02d:%02d:%02dZ\n", $g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0];' 2>/dev/null)
    printf '%s package=%s turns=%s cap=%s context_tokens=%s next_action_written=%s\n' \
      "$ISO" "$PKG" "$TURNS" "$CAP" "$N" "$NAW" >> "$OVERRUN_LOG" 2>/dev/null
  fi
  OVERRUN_LINE="This is flush turn $TURNS, past the permitted $CAP. The overrun has been recorded to runs/<pkg>.ctx-flush-overrun.log. If you cannot complete the flush, set status: blocked with a filled \"## Escalation\" naming what is preventing it, then stop."
  if [ "$TOOL" = Task ]; then
    deny "$OVERRUN_LINE"
  else
    CMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null) || CMD=""
    [ -n "$CMD" ] || exit 0
    if allowed_bash "$CMD"; then
      exit 0
    fi
    deny "$OVERRUN_LINE"
  fi
fi

if [ "$TOOL" = Task ]; then
  deny "This is flush turn $TURNS of $CAP. Tool: Task"
elif [ "$TOOL" = Bash ]; then
  CMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null) || CMD=""
  [ -n "$CMD" ] || exit 0
  if allowed_bash "$CMD"; then
    exit 0
  fi
  CMD_Q=$(printf '%s' "$CMD" | tr '\n\r\t' '   ' | cut -c1-200)
  deny "This is flush turn $TURNS of $CAP. Command: $CMD_Q"
else
  exit 0
fi

exit 0
