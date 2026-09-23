#!/usr/bin/env bash
# record-dispatch-package.sh — PreToolUse hook for Task|Agent. Records which
# blueprint package a subagent dispatch belongs to, keyed by the dispatch's
# tool_use_id, so `bp-spend.pl report-session` can attribute that subagent's
# tokens EXACTLY.
#
# WHY A HOOK. report-session used to attribute a drive-solo subagent by
# matching its start time against bp-dispatch-log.pl records and parsing the
# blueprint out of a hand-written record id. On one real session that left
# 78% of subagent tokens unattributed: records the driver never wrote, windows
# that overlapped (324M tokens `ambiguous`), ids that did not parse. Passing
# --blueprint/--package on every `start` would have fixed the parsing but
# still depended on the driver remembering to. This hook depends on nothing
# the agent does: the package comes from the director's own current-package
# pointer (bp_driver_context), and the key is the tool_use_id Claude Code
# assigns the dispatch -- the same id Claude Code writes into the subagent's
# `<agent>.meta.json` sidecar as `toolUseId`, so report-session joins on
# that id exactly.
#
# WHEN IT RECORDS. Two cases, and nothing else:
#   * a fleet coordinator (BP_LEDGER set): the package is its own
#     BP_BLUEPRINT/BP_PACKAGE, exported by bp-launch.sh;
#   * a drive-solo DRIVER: bp_driver_context resolves the current package AND
#     this session holds its own live driver marker. The marker check is what
#     keeps a second terminal in the same project from stamping its unrelated
#     dispatches with the run's package -- bp_driver_context alone answers "is
#     any drive active here", not "is THIS session driving".
# Known limit, shared with the write-guards that read the same pointer: the
# pointer names ONE package. A driver that works two packages at once gets
# every dispatch stamped with whichever it started last.
#
# OBSERVER ONLY. Never blocks, never prints, exits 0 on every path. A session
# that is not in a butler run pays two stat()s and leaves before any payload
# field is parsed.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

[ "${BP_DISPATCH_LOG_OFF:-}" != "1" ] || exit 0

MODE=""
if [ -n "${BP_LEDGER:-}" ]; then
  MODE=coordinator
elif bp_drive_any_active 2>/dev/null; then
  MODE=driver
fi
[ -n "$MODE" ] || exit 0

bp_read_payload open

TUID=$(bp_json_get "$PAYLOAD" tool_use_id 2>/dev/null) || exit 0
[[ "$TUID" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || exit 0
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null) || SID=""
[[ "$SID" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || SID=""

BLUEPRINT=""; PACKAGE=""; DATA=""; SOURCE=""
if [ "$MODE" = coordinator ]; then
  BLUEPRINT="${BP_BLUEPRINT:-}"; PACKAGE="${BP_PACKAGE:-}"
  bp_is_absolute_path "${BP_PROJECT_ROOT:-}" || exit 0
  DATA=$(bp_find_data_dir "$BP_PROJECT_ROOT" 2>/dev/null) || exit 0
  SOURCE=coordinator-env
else
  [ -n "$SID" ] || exit 0
  MARKER=$(bp_drive_marker "$SID" 2>/dev/null) || exit 0
  [ -f "$MARKER" ] || exit 0
  CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null); CWD=${CWD:-$PWD}
  bp_driver_context "$CWD" || exit 0
  BLUEPRINT="$BP_BLUEPRINT"; PACKAGE="$BP_PACKAGE"; DATA="$BP_DATA_DIR"
  SOURCE=driver-pointer
fi

# Same name rule bp_driver_context applies before a name touches a path; here
# it also guarantees the values need no JSON escaping below.
for _n in "$BLUEPRINT" "$PACKAGE"; do
  case "$_n" in ''|.*|*..*) exit 0 ;; esac
  [[ "$_n" =~ ^[A-Za-z0-9._-]{1,120}$ ]] || exit 0
done
[ -n "$DATA" ] && [ -d "$DATA" ] || exit 0

TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type 2>/dev/null) || TYPE=""
[[ "$TYPE" =~ ^[A-Za-z0-9:._-]{1,64}$ ]] || TYPE=""
NOW=$(date +%s 2>/dev/null) || NOW=0
[[ "$NOW" =~ ^[0-9]+$ ]] || NOW=0

DIR="$DATA/.dispatch-log"
FILE="$DIR/attribution.jsonl"
mkdir -p "$DIR" 2>/dev/null || exit 0

# Bounded without ever discarding the newest records: past 8 MiB (~40,000
# dispatches) the file rolls to attribution.jsonl.1, replacing the previous
# roll. report-session reads both.
SZ=0
[ -f "$FILE" ] && SZ=$(wc -c < "$FILE" 2>/dev/null || echo 0)
if [ "${SZ:-0}" -gt 8388608 ] 2>/dev/null; then
  mv -f "$FILE" "$FILE.1" 2>/dev/null || :
fi

# One short line per dispatch: O_APPEND keeps concurrent writers from
# interleaving inside a line.
printf '{"tool_use_id":"%s","blueprint":"%s","package":"%s","subagent_type":"%s","session_id":"%s","source":"%s","at":%s}\n' \
  "$TUID" "$BLUEPRINT" "$PACKAGE" "$TYPE" "$SID" "$SOURCE" "$NOW" >> "$FILE" 2>/dev/null || :
exit 0
