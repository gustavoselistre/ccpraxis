#!/usr/bin/env bash
# guard-ledger-create.sh — PreToolUse hook (04-model-effort-ledger-validation).
#
# Denies a direct Write/Edit/MultiEdit/NotebookEdit targeting a blueprint PACKAGE
# LEDGER path (<data>/blueprints/<name>/packages/<pkg>.md, including one that does
# not exist yet), forcing every ledger creation through bp-ledger.pl create --
# the typed, validating, atomic API that refuses an unsupported model:/effort:
# and self-checks the produced bytes against validate_bytes() before anything
# reaches disk. A hand-written ledger has neither guarantee.
#
# Deliberately UNLIKE ledger-guard.sh/guard-writes.sh: this hook does NOT call
# the coordinator-session gate helper lib.sh defines, and is NOT scoped to a
# coordinator session (D-H). Ledger AUTHORING happens outside a live coordinator
# session -- exactly the BP_LEDGER-absent condition that gate helper treats as
# "not my business" -- so a gated guard would never fire during authoring and
# would reproduce today's blind spot byte for byte. guard-blueprint-write.sh
# made the same call for the same reason; this hook mirrors its structure
# throughout. (AC-12/B-40 pins this file's source as free of a call to that
# helper -- deliberately not spelling its identifier out even here.)
#
# Must NOT deny the API's own writer: bp-ledger.pl is invoked via Bash, and this
# hook only inspects Write/Edit/MultiEdit/NotebookEdit tool_name payloads, so a
# Bash invocation of `bp-ledger.pl create` is never even inspected -- it exits 0
# immediately.
#
# ESCAPE HATCH (D-G, spec §2.3). A one-shot override file --
# .ccpraxis-local-data/.subagent-guard/ledger-write-override -- whose first line
# (CR and surrounding whitespace stripped) must name a bug report that GENUINELY
# EXISTS on disk (.ccpraxis-local-data/bug-reports/<id>.md, a regular file). The
# id is checked by EXISTENCE, never by a format regex: a syntactically bizarre id
# that names a real report is honoured, and a well-formed but FABRICATED id is
# refused -- disk is the only authority (Decision 14). A failed verification
# LEAVES the override file in place (a stale/typo'd id is not evidence to
# destroy); a successful verification CONSUMES it (rm) before allowing, and a
# consume that reports failure DENIES rather than allows -- the 2026-09-18
# force-stop defect (guard-subagent-stall.sh) is the whole argument: a lever
# that is tested but never consumed disables its guard permanently and silently.
#
# Exit 0 = allow. Exit 2 = block; stderr fed back to the model.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY. The coordinator-session gate helper (see the
# header above) is deliberately NOT called here; sourcing lib.sh does not call
# it on its own.
source "$HOOK_DIR/lib.sh"

bp_read_payload closed

TOOL=$(bp_json_get "$PAYLOAD" tool_name) || {
  echo "LEDGER-CREATE-GUARD: BLOCKED -- no JSON parser available (neither jq nor perl+JSON::PP); blocking to avoid unenforced operation." >&2
  exit 2
}
case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FP=$(bp_json_get "$PAYLOAD" tool_input.file_path tool_input.notebook_path)
[ -n "$FP" ] || exit 0

CWD=$(bp_json_get "$PAYLOAD" cwd)
[ -n "$CWD" ] || CWD=$PWD
# Windows absolute forms are NOT matched by `/*` -- recognise them too, copied
# from guard-blueprint-write.sh's identical fix (the doubled-path defect that
# fix closed applies here just as much).
case "$FP" in
  /*)          ABS="$FP" ;;
  [A-Za-z]:/*) ABS="$FP" ;;
  [A-Za-z]:\\*) ABS="$FP" ;;
  *)           ABS="$CWD/$FP" ;;
esac
ABS=$(realpath -m "$ABS" 2>/dev/null || printf '%s' "$ABS")

# Normalized MATCHING copy only -- $ABS itself is untouched and is still what
# appears verbatim in every denial message below. Three independent gaps this
# closes (spec §2.2 / MUST-2 / HIGH-1 / MEDIUM-2 / LOW-2):
#   - backslash-to-forward-slash: not just an accident of `realpath -m`
#     succeeding -- if realpath is unavailable (falls back to the raw $ABS),
#     a Windows backslash path would never match the forward-slash glob.
#   - lowercase: NTFS/APFS are case-insensitive filesystems; PACKAGES/,
#     Blueprints/, .MD must all still match.
#   - strip a trailing `::$DATA` alternate-stream suffix and a trailing run of
#     `.`/space characters: NTFS silently strips/reinterprets these on the
#     write side, so the guard must recognise the same normalized name.
NORM=${ABS//\\//}
NORM=$(printf '%s' "$NORM" | tr '[:upper:]' '[:lower:]')
case "$NORM" in
  *::\$data) NORM="${NORM%::\$data}" ;;
esac
while :; do
  case "$NORM" in
    *[.\ ]) NORM="${NORM%?}" ;;
    *) break ;;
  esac
done

case "$NORM" in
  # D-F: the narrow pattern, deliberately -- */packages/*.md alone would deny
  # any packages/foo.md in any repository this plugin is enabled in. A blueprint
  # package ledger always lives at <data>/blueprints/<name>/packages/<pkg>.md
  # (archived blueprints included -- blueprints/_archive/<name>/packages/*.md is
  # intended to still be covered; an archived ledger is still a ledger).
  */blueprints/*/packages/*.md) ;;
  *) exit 0 ;;
esac

# ROOT for the escape hatch: CLAUDE_PROJECT_DIR, else the payload's cwd, else
# $PWD -- the payload cwd is inserted ahead of a bare $PWD fallback because this
# hook runs from the live install, whose parent is the ccpraxis tree and not the
# project actually being edited.
ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || ROOT="$CWD"
[ -n "$ROOT" ] || ROOT="$PWD"

OVERRIDE="$ROOT/.ccpraxis-local-data/.subagent-guard/ledger-write-override"

deny() {
  printf '%s\n' \
"LEDGER-CREATE-GUARD: BLOCKED -- a direct $TOOL to $ABS is not permitted." \
"" \
"A package ledger is created only through the typed, validating, atomic API:" \
"" \
"  perl <ccpraxis>/plugins/butler/scripts/bp-ledger.pl create --ledger <ABS> \\" \
"       --package <NN-slug> --blueprint <name> \\" \
"       --template <ccpraxis>/plugins/blueprint/templates/package-ledger.md \\" \
"       --write-set '<colon-separated paths>'" \
"" \
"It validates model:/effort: against the supported sets (sonnet, opus, haiku /" \
"low, medium, high, xhigh, max) and refuses to write a ledger its own \`validate\`" \
"verb would reject. A hand-written ledger has neither guarantee." \
"" \
"If bp-ledger.pl create is itself the thing that is broken, file the report first." \
"This escape hatch is for a genuine ccpraxis tooling defect ONLY." \
"" \
"  perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file --title \"...\" --body -" \
"" \
"then put the id it prints -- and nothing else -- in:" \
"" \
"  .ccpraxis-local-data/.subagent-guard/ledger-write-override" \
"" \
"It is one-shot, consumed on use, and verified against the report on disk. An id" \
"that names no report is refused, so this is not a way around filing the report." \
>&2
  exit 2
}

deny_consume_failure() {
  printf '%s\n' \
"LEDGER-CREATE-GUARD: BLOCKED -- a direct $TOOL to $ABS is not permitted." \
"" \
"A valid escape-hatch override was found, but it could not be consumed (the" \
"override file at .ccpraxis-local-data/.subagent-guard/ledger-write-override" \
"could not be removed). Allowing the write anyway would leave a permanently-" \
"satisfiable override behind -- an unconsumable override would silently" \
"authorise every later write, which is worse than refusing this one. Remove" \
"the override file by hand and retry through bp-ledger.pl create instead." \
>&2
  exit 2
}

# D-G / spec §2.3, the exact 8-step sequence.
if [ ! -f "$OVERRIDE" ]; then
  deny
fi

ID=$(head -n 1 "$OVERRIDE" 2>/dev/null | tr -d '\r')
# Strip surrounding whitespace (leading/trailing) without a subshell trip.
ID="${ID#"${ID%%[![:space:]]*}"}"
ID="${ID%"${ID##*[![:space:]]}"}"

if [ -z "$ID" ]; then
  deny
fi

# A path-traversal guard on the LOOKUP, not a format check on the id (see the
# header comment): reject '/', '\', or a literal '..' component so a fabricated
# id cannot turn the existence test below into a traversal.
case "$ID" in
  */*|*\\*|*..*) deny ;;
esac

REPORT="$ROOT/.ccpraxis-local-data/bug-reports/$ID.md"
if [ ! -f "$REPORT" ]; then
  deny
fi

# Consumed BEFORE the allow (D-G). BP_LEDGER_GUARD_FAIL_CONSUME is a test-only
# seam (mirrors bp-ledger.pl's BP_LEDGER_FAIL_RENAME): when set and non-empty,
# skip the rm so step 7 below observes the file still present and exercises the
# consume-failure branch, which is otherwise unreachable from a test on this host.
if [ -z "${BP_LEDGER_GUARD_FAIL_CONSUME:-}" ]; then
  rm -f "$OVERRIDE"
fi

if [ -e "$OVERRIDE" ]; then
  deny_consume_failure
fi

exit 0
