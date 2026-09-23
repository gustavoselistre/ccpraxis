#!/usr/bin/env bash
# dispatch-discipline-nudge.sh — PostToolUse on Bash|Read|Edit|Grep.
# coordinator-context-discipline/03-dispatch-discipline-enforcement spec §2.7.
#
# WHY THIS EXISTS. SKILL.md:605's own sentence ("Anything resembling a step
# belongs to a worker") is unenforced prose -- one sampled coordinator made
# 704 self-Bash calls (473 of them cd), 3 dispatches, in 1,561 total tool
# calls (Decision 5, report 20260917-172750-285a). This hook is the
# mechanism: it counts the coordinator's own Bash/Read/Edit/Grep calls
# against dispatched Task calls, via bp-dispatch-log.pl's `ratio` verb, and
# attaches one hedged additionalContext payload when the ratio crosses both
# gates. It never blocks anything (PostToolUse has no deny channel) and
# exits 0 on every path.
#
# D-E: this hook does NO command-string handling of any kind. It never reads
# the command field of a tool_input payload, never splits on a separator,
# never matches an allow-list -- the payload is drained and NOT parsed
# (bp_read_payload open); the ONLY input this hook reads is the transcript,
# through the one bounded probe below.
#
# D-G: the rate-limit gate runs BEFORE the probe (a whole-file streaming
# scan, not a cheap tail read), so at most one scan runs per interval, per
# package. last_check is written on every fire that reaches that point,
# whether or not the probe succeeds -- the window is consumed either way.
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
case "$PKG" in ''|*/*|*\\*|.|..) exit 0 ;; esac

STATE="$BP_DIR/runs/$PKG.dispatch-discipline"

INTERVAL="${BP_DISPATCH_NUDGE_INTERVAL_SECS:-1800}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=1800 ;; esac
[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=1800

NOW=$(date +%s 2>/dev/null || echo 0)

# THE GATE, BEFORE THE PROBE (D-G). A missing/corrupt/malformed state file is
# treated as absent -- the probe runs. A FUTURE last_check (negative age)
# must NOT suppress -- the hook fails toward speaking (B20/redteam MEDIUM-1).
if [ -f "$STATE" ]; then
  LAST=$(sed -n 's/^last_check: *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$STATE" 2>/dev/null | head -1)
  case "$LAST" in
    ''|*[!0-9-]*) ;;  # malformed/missing -> probe
    *)
      if [ "$NOW" -gt 0 ] && [ "$LAST" -gt 0 ] 2>/dev/null; then
        AGE=$(( NOW - LAST ))
        if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL" ]; then
          exit 0
        fi
      fi
      ;;
  esac
fi

TRANSCRIPT="$BP_DIR/runs/$PKG.jsonl"
[ -f "$TRANSCRIPT" ] || exit 0
[ -f "$HOOK_DIR/../scripts/bp-dispatch-log.pl" ] || exit 0

# Record the probe window BEFORE running the probe (review SHOULD-2): if the
# hook is killed at hooks.json's 15s timeout mid-probe, the state file still
# carries this window, so the next matched tool call does not re-probe. The
# window is documented as "consumed either way" (spec §2.7), so writing it
# earlier changes no specified behavior.
mkdir -p "$BP_DIR/runs" 2>/dev/null
printf 'last_check: %s\n' "$NOW" > "$STATE" 2>/dev/null

# --blueprint/--package are passed to the probe only when the corresponding
# env var is actually non-empty (review MEDIUM-2). A real bp-launch.sh
# coordinator always has both set; passing an empty value instead of
# omitting the flag would hand package 01's ratio scope-guard an empty
# string, which its $ID_RE rejects -- exit 2, swallowed by 2>/dev/null,
# making this hook permanently and silently inert with no visible sign.
set -- ratio --transcript "$TRANSCRIPT"
[ -n "${BP_BLUEPRINT:-}" ] && set -- "$@" --blueprint "$BP_BLUEPRINT"
[ -n "${BP_PACKAGE:-}" ]   && set -- "$@" --package "$BP_PACKAGE"
set -- "$@" --root "${BP_PROJECT_ROOT:-}"

# THE ONE SCAN. Nothing else in this hook reads the transcript. The
# invocation is: ratio --transcript "$TRANSCRIPT" [--blueprint "$BP_BLUEPRINT"]
# [--package "$BP_PACKAGE"] --root "$BP_PROJECT_ROOT" -- --blueprint/--package
# each appear only when their env var is non-empty, per the guard above.
PROBE_OUT=$(perl "$HOOK_DIR/../scripts/bp-dispatch-log.pl" "$@" 2>/dev/null)

S=""; R=""; E=""; G=""; B=""; D=""; RATIO=""; M=""; VERDICT=""; DNOTE=""
while IFS= read -r line; do
  case "$line" in
    self_tool_calls:*)         S="${line#self_tool_calls: }" ;;
    self_bash_calls:*)         B="${line#self_bash_calls: }" ;;
    self_read_calls:*)         R="${line#self_read_calls: }" ;;
    self_edit_calls:*)         E="${line#self_edit_calls: }" ;;
    self_grep_calls:*)         G="${line#self_grep_calls: }" ;;
    dispatches:*)              D="${line#dispatches: }" ;;
    ratio:*)                   RATIO="${line#ratio: }" ;;
    min_ratio:*)                M="${line#min_ratio: }" ;;
    verdict:*)                 VERDICT="${line#verdict: }" ;;
    dispatch_note:*)           DNOTE="${line#dispatch_note: }" ;;
  esac
done <<EOF
$PROBE_OUT
EOF

[ "$VERDICT" = imbalance ] || exit 0

LINE1="[dispatch-discipline] Since this package's last cold launch, your own transcript records about $S direct tool calls of your own (Bash $B, Read $R, Edit $E, Grep $G) against $D dispatch(es) — a ratio of about $RATIO own calls per dispatch, at or above the $M this check is set to notice. This is an observation, not a verdict, and nothing is blocked."
LINE2="[dispatch-discipline] Dispatch check (bp-dispatch-log.pl, scoped to this blueprint and package): $DNOTE"
LINE3='[dispatch-discipline] A ratio this shape can mean substantive package work is being done here instead of dispatched, which coordinator-protocol'"'"'s "Worker dispatch contract" asks you to hand to a worker; it can equally mean a legitimate investigation or validation pass, and this mechanism cannot tell those apart. If a step is in progress, consider whether it belongs to a worker.'
LINE4='[dispatch-discipline] The counts are read from your own runs transcript, cover only Bash, Read, Edit and Grep, and stop at a scan bound, so they may undercount and are a signal rather than a measurement of everything you did.'

CTX="$LINE1
$LINE2
$LINE3
$LINE4"

perl -MJSON::PP -e '
  binmode(STDIN, ":raw"); binmode(STDOUT, ":raw");
  my $ctx = do { local $/; <STDIN> };
  $ctx =~ s/\n\z//;
  print JSON::PP->new->encode({ hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $ctx } });
' <<EOF 2>/dev/null
$CTX
EOF

exit 0
