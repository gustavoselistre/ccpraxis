#!/usr/bin/env bash
# guard-writes.sh — PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
#
# Enforces, inside coordinator sessions only:
#   1. All writes stay inside the package's declared scope
#      (BP_WRITE_SET ∪ BP_TEST_PATHS), the blueprint dir, or /tmp.
#   2. Role separation while a write-capable worker is in flight:
#        bp-implementer  may NOT touch BP_TEST_PATHS (tests are the immutable oracle)
#        bp-test-writer  may ONLY touch BP_TEST_PATHS (and the blueprint dir)
#        bp-ui-prober    may ONLY touch BP_TEST_PATHS (and the blueprint dir) —
#                        its screenshots/artifacts are written by test runs (Bash),
#                        not Edit/Write, so this is safe
#
# Exit 0 = allow. Exit 2 = block; stderr is fed back to the model.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

# 07-guards-reach-the-driver: two activation paths, one body. BP_LEDGER set ->
# a launched worker, byte-identical to today (bp_hook_gate, fail-CLOSED on a
# missing parser). Otherwise -> a driver / driver-dispatched Task subagent,
# reached via lib.sh's driver-context predicate, which fails OPEN on any
# internal error (spec §2.3): a driver that can wedge on a guard error is
# worse than the thing the guard prevents.
if [ -n "${BP_LEDGER:-}" ]; then
  bp_hook_gate
  bp_hook_require_json_parser
else
  bp_drive_any_active 2>/dev/null || exit 0
  bp_read_payload open
  _cwd=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true)
  bp_driver_context "${_cwd:-$PWD}" || exit 0
fi

# longest_glob_match REL PATTERNS
#   PATTERNS: colon-separated, same dialect as lib.sh:match_any
#             (trailing '/' = prefix match; otherwise a bash glob whose '*' crosses '/')
#   Sets LGM_LEN = character length of the LONGEST pattern that matches REL, or -1 if none.
#   Sets LGM_PAT = that pattern, or '' when LGM_LEN is -1.
#   No subshell, no output; globals only. Never exits.
longest_glob_match() {
  local p="$1" pats="$2" pat
  LGM_LEN=-1
  LGM_PAT=''
  [ -n "$pats" ] || return 0
  local IFS=':'
  # step-6 red-team MINOR-10: $pats is unquoted below (required, so ':'-split
  # words re-split on IFS) but that also subjects each word to pathname
  # expansion against the hook's cwd -- a '*' entry then silently stops
  # covering brand-new files once run from a directory containing matches.
  # set -f for the duration of the loop only, restored unconditionally after.
  set -f
  # shellcheck disable=SC2086
  for pat in $pats; do
    [ -n "$pat" ] || continue
    local hit=0
    case "$pat" in
      */) if [[ "$p" == "$pat"* || "$p/" == "$pat" ]]; then hit=1; fi ;;
      *)  # shellcheck disable=SC2053
          if [[ "$p" == $pat ]]; then hit=1; fi ;;
    esac
    if [ "$hit" -eq 1 ] && [ "${#pat}" -gt "$LGM_LEN" ]; then
      LGM_LEN=${#pat}
      LGM_PAT=$pat
    fi
  done
  set +f
  return 0
}

# show_patterns LABEL PATTERNS
#   Emits PATTERNS one per line to stderr, each as it will actually be matched
#   after the ':' split, and marks any element containing whitespace.
#
#   Bug 20260916-175013-34af. These fields are a single colon-delimited string.
#   An author who annotates the field in prose -- `a.pm:b.t:c.pl -- in scope for
#   ONE thing only: the entry point` -- gets FOUR patterns instead of three, and
#   the annotated path silently stops being in the write set. bp-ledger.pl's V4b
#   check now refuses to WRITE such a field, but a session launched before that
#   landed still carries the corrupt value in BP_WRITE_SET, and nothing
#   re-derives it mid-session.
#
#   The refusal used to print the RAW string, so the corruption was invisible
#   unless the reader mentally split on ':' and noticed the prose. The report's
#   closing line is that this would have turned a half-session of misdiagnosis
#   into a five-second read: a coordinator seeing "outside your write set" for a
#   path that is plainly listed diagnoses a SCOPE dispute and escalates for a
#   re-scope it does not need. The scope was already right; only its
#   serialization was broken.
#
#   Display only. Nothing here participates in the allow/deny decision.
show_patterns() {
  local label="$1" pats="$2" pat
  if [ -z "$pats" ]; then
    printf '  %s: (empty)\n' "$label" >&2
    return 0
  fi
  printf '  %s, as %d pattern(s) after splitting on ":" --\n' \
         "$label" "$(printf '%s' "$pats" | awk -F: '{print NF}')" >&2
  local IFS=':'
  set -f
  # shellcheck disable=SC2086
  for pat in $pats; do
    case "$pat" in
      *[[:space:]]*) printf '    %s   <-- contains whitespace: not a path (report 20260916-175013-34af)\n' "$pat" >&2 ;;
      '')            printf '    (empty element)\n' >&2 ;;
      *)             printf '    %s\n' "$pat" >&2 ;;
    esac
  done
  set +f
  return 0
}

bp_read_payload closed
FP=$(bp_json_get "$PAYLOAD" tool_input.file_path tool_input.notebook_path)
[ -n "$FP" ] || exit 0
CWD=$(bp_json_get "$PAYLOAD" cwd); CWD=${CWD:-$PWD}

# A Windows drive-letter path ("C:/..." or "C:\...") is ALREADY absolute --
# the tool payload's file_path/cwd arrive in that form on this host. The
# original two-way case here only recognised a POSIX leading "/" as
# "already absolute", so a drive-letter FP fell into the "*" branch and got
# CWD (itself POSIX-form, e.g. "/c/Development/...") prepended in front of
# it -- producing a doubled, non-existent path like
# "/c/Development/ccpraxis/C:/Development/ccpraxis/...". realpath -m does not
# repair that; it has no relationship to fix. Recognise both absolute forms
# up front so neither is ever joined onto CWD.
case "$FP" in
  /*) ABS="$FP" ;;
  [A-Za-z]:/*|[A-Za-z]:\\*) ABS="$FP" ;;
  *)  ABS="$CWD/$FP" ;;
esac
ABS=$(realpath -m "$ABS")

# Windows/MSYS path-form landmine (same class as this repo's other documented
# ones): the tool payload's cwd/file_path arrives in Windows drive-letter form
# ("C:/Development/..."), while lib.sh's driver-context resolution (a
# pure-bash/MSYS caller) produces "/c/Development/...". realpath -m does NOT
# convert between the two -- it only canonicalises "."/".."/symlinks within
# whichever form it is handed -- so every later literal-prefix `case` match
# and `realpath --relative-to` against BP_DATA_DIR/BP_DIR/BP_PROJECT_ROOT
# silently fails to match a real containment, and every glob match against a
# still-absolute (never reduced to relative) $REL silently fails too. Both
# failure directions land on "not in scope" -- a false BLOCKED, not a missed
# guard, but a real one: it made a legitimate driver spec-file edit
# indistinguishable from a genuine write-set violation. Normalize ONCE, here,
# to the same MSYS form lib.sh already uses everywhere else in this file.
# cygpath is Git-for-Windows/MSYS-only; on a non-Windows host both forms are
# already the same POSIX spelling and this is a no-op passthrough.
if command -v cygpath >/dev/null 2>&1; then
  ABS_NORM=$(cygpath -u "$ABS" 2>/dev/null) && [ -n "$ABS_NORM" ] && ABS="$ABS_NORM"
fi

# fix-batch MAJOR-3: derive the driver/worker branch from whether the
# lib.sh driver-context predicate actually populated BP_DATA_DIR, not from
# BP_DRIVER_SESSION alone. BP_DRIVER_SESSION is an ordinary shell variable
# that can be inherited
# ambiently (same doctrine lib.sh:100-109 already states for
# BP_PAYLOAD_READ_DONE); trusting it alone as the sole discriminator, combined
# with an unbraced "$BP_DATA_DIR" reference under `set -u`, previously let a
# stray ambient BP_DRIVER_SESSION=1 crash this script with an unbound-variable
# error on the worker path -- rc 1 from a PreToolUse hook is non-blocking, so
# the write proceeded with nothing checked (redteam MAJOR-3).
IS_DRIVER=0
if [ "${BP_DRIVER_SESSION:-0}" = "1" ] && [ -n "${BP_DATA_DIR:-}" ]; then IS_DRIVER=1; fi

# The hatch advertisement (§2.5), only ever emitted on the driver path.
HATCH_ADVERT=""
if [ "$IS_DRIVER" -eq 1 ]; then
  HATCH_ADVERT=" Escape hatch: touch \"${BP_DATA_DIR:-}/.drive-solo/.driver-guards-off\" or export CCPRAXIS_DRIVER_GUARDS_OFF=1 (self-clearing by default after ${CCPRAXIS_DRIVER_GUARDS_OFF_TTL_MIN:-60} minutes; override with CCPRAXIS_DRIVER_GUARDS_OFF_TTL_MIN)."
fi

# Always allowed: /tmp, and -- worker path -- the blueprint's own dir
# (ledger, reports, specs); driver path -- the data dir, EXCEPT the
# control-plane directory <data>/.drive-solo/ (redteam BLOCKER-1/BLOCKER-2:
# that directory holds the hatch file, the current-package pointer file,
# the active-worker marker and other director-owned state that the driver
# predicate in lib.sh re-reads on every invocation -- a guarded actor with
# the whole data dir always-allowed could switch both
# guards off, or rewrite its own policy inputs, with one permitted write. It
# is written only by bp-drive-next.pl and the tracking hooks, never by a
# legitimate Edit/Write tool call, so carving it out of the always-allow
# costs the driver nothing and falls through to ordinary write-set
# enforcement below, which denies it (none of it is ever in a write_set)).
if [ "$IS_DRIVER" -eq 1 ]; then
  case "$ABS" in
    "${BP_DATA_DIR:-}"/.drive-solo/*) ;;
    "${BP_DATA_DIR:-}"/*|/tmp/*) exit 0 ;;
  esac
else
  case "$ABS" in
    "${BP_DIR:-}"/*|/tmp/*) exit 0 ;;
  esac
fi

REL=$(realpath -m --relative-to="$BP_PROJECT_ROOT" "$ABS")
case "$REL" in
  ../*)
    echo "BLOCKED: $ABS is outside the project root ($BP_PROJECT_ROOT). Coordinator sessions may only write inside the project, the blueprint dir, or /tmp." >&2
    exit 2 ;;
esac

longest_glob_match "$REL" "${BP_TEST_PATHS:-}"; T_LEN=$LGM_LEN; T_PAT=$LGM_PAT
longest_glob_match "$REL" "${BP_WRITE_SET:-}";  W_LEN=$LGM_LEN
IN_TESTS=1
if [ "$T_LEN" -ge 0 ] && [ "$T_LEN" -ge "$W_LEN" ]; then IN_TESTS=0; fi

# step-6 red-team MAJOR-2/MINOR-8: a write_set entry naming a REAL test file
# (this repo's immutable-oracle shape, documented in CLAUDE.md's "Tests"
# section: plugins/<plugin>/tests/t/NN-name.t) must never win a specificity
# race against a test_paths prefix that already covers it -- an implementer
# could otherwise edit the very file it is being judged by, silently,
# whenever write_set happens to name that file more specifically (character-
# length-wise) than the test_paths prefix, including via the sanctioned
# --widen-write-set unblock. This is deliberately narrower than "any
# write_set entry nested under test_paths" -- AC-1's legitimate non-test
# scripts/bp-blueprint.pl is ALSO textually nested under a broad
# test_paths='plugins/butler/' prefix, so nesting alone cannot be the signal.
# It targets the actual test-FILE shape, not mere directory containment.
if [ "$T_LEN" -ge 0 ]; then
  case "$REL" in
    */tests/t/*.t|tests/t/*.t) IN_TESTS=0 ;;
  esac
fi

# Role resolution: driver path reads BP_DRIVER_ROLE (the predicate above
# already consulted the solo marker); marker_path() -- the COORDINATOR marker
# at $BP_DIR/runs/<pkg>.active-worker -- is never consulted on the driver
# path, because a solo run does not write it.
if [ "$IS_DRIVER" -eq 1 ]; then
  WORKER="${BP_DRIVER_ROLE:-}"
else
  WORKER=""
  MARKER=$(marker_path)
  [ -f "$MARKER" ] && WORKER=$(cat "$MARKER" 2>/dev/null || true)
fi

# The driver is the implementer's PEER with respect to the oracle: it
# dispatches bp-test-writer to author tests and must not hand-edit them
# itself (§2.3.3). "the driver itself is writing" = driver path with an
# empty WORKER (no solo worker marker, or one that resolved to "").
DRIVER_SELF=0
if [ "$IS_DRIVER" -eq 1 ] && [ -z "$WORKER" ]; then DRIVER_SELF=1; fi

# review M1: the package-name interpolation below is gated on IS_DRIVER, same
# pattern as HATCH_ADVERT -- unconditional interpolation would contaminate
# the worker-path denial text, which the spec pins as byte-identical to
# today's (BP_PACKAGE is exported into every worker session too, so this was
# a real, observable text change on that path, not a no-op).
PKG_NOTE=""
[ "$IS_DRIVER" -eq 1 ] && PKG_NOTE=" in package ${BP_PACKAGE:-pkg}"

if [ "$IN_TESTS" -eq 0 ] && { [[ "$WORKER" == *bp-implementer* ]] || [ "$DRIVER_SELF" -eq 1 ]; }; then
  WHO="bp-implementer"
  [ "$DRIVER_SELF" -eq 1 ] && WHO="the driver"
  echo "BLOCKED: $WHO may not modify test files ($REL; matched test_paths pattern '$T_PAT')$PKG_NOTE. Tests are the immutable oracle for this package. If a test is wrong, finish what you can, then report the exact test, why it contradicts the spec, and your evidence — the coordinator decides.$HATCH_ADVERT" >&2
  exit 2
fi

if [ "$IN_TESTS" -ne 0 ] && [[ "$WORKER" == *bp-test-writer* ]]; then
  echo "BLOCKED: bp-test-writer may only write under the package's test paths ($BP_TEST_PATHS), not $REL.$HATCH_ADVERT If implementation scaffolding is genuinely required, report it back instead of writing it." >&2
  exit 2
fi

if [ "$IN_TESTS" -ne 0 ] && [[ "$WORKER" == *bp-ui-prober* ]]; then
  echo "BLOCKED: bp-ui-prober may only write under the package's test paths ($BP_TEST_PATHS), not $REL.$HATCH_ADVERT Prober artifacts (screenshots, fixtures) are produced by test *runs*, not by Edit/Write. If something else genuinely must change, report it back instead of writing it." >&2
  exit 2
fi

if [ "$IN_TESTS" -eq 0 ]; then exit 0; fi
if match_any "$REL" "${BP_WRITE_SET:-}"; then exit 0; fi

PKG_PAREN=""
[ "$IS_DRIVER" -eq 1 ] && PKG_PAREN=" (package ${BP_PACKAGE:-pkg})"
echo "BLOCKED: $REL is outside this package's write set$PKG_PAREN." >&2
show_patterns "write_set" "${BP_WRITE_SET:-}"
show_patterns "test_paths" "${BP_TEST_PATHS:-}"
echo "If the path you tried to write appears above only as part of a LONGER element, this package's write_set was serialized wrong and the scope is already correct — relaunch is the only recovery, because nothing re-derives BP_WRITE_SET mid-session. Otherwise this is a scope problem: record it in the ledger under 'Next action' / escalation, set status to blocked or finish without it — the orchestrator re-scopes packages, coordinators do not.$HATCH_ADVERT" >&2
exit 2
