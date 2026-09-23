#!/usr/bin/env bash
# guard-validation-interlock.sh — PreToolUse hook for Bash.
#
# Implements
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# §2.1. Denies a validation-shaped Bash command (test/build/lint, see
# VALIDATION_DENYLIST below) whenever a write-capable worker's marker is live
# and fresh — headless coordinators via the existing marker_path() (lib.sh),
# interactive drive-solo sessions via a new, identically-shaped
# $DATA/.drive-solo/.active-worker marker (written by track-worker-solo.sh).
#
# DELIBERATELY NOT bp_hook_gate'd: this hook's entire purpose is to also fire
# in an interactive drive-solo session, which is exactly the session
# bp_hook_gate would silently exempt (BP_LEDGER/BP_DIR/BP_PROJECT_ROOT are
# exported only by bp-launch.sh into coordinator processes). Sources lib.sh
# for bp_json_get / marker_path / bp_find_data_dir only — never
# bp_hook_require_jq, which fails closed and would turn every host without
# jq (this one included) into an outage the moment this hook fires.
#
# Fail-open on every ambiguity: no JSON parser, malformed payload, missing
# marker, unresolved data dir — all resolve to "allow". A validation
# interlock that can wedge an interactive session is a worse defect than the
# false-red it exists to prevent.
#
# VALIDATION_DENYLIST scope (spec §2.1.1): a bounded, documented ERE list,
# not a claimed-exhaustive classifier. Covers pnpm/npm/yarn test|build|lint,
# npx vitest|jest|mocha|playwright, pytest/prove, go/cargo/flutter/dart
# test|analyze. Does NOT cover every ecosystem's build tooling (dotnet test,
# mvn test, bundle exec rspec, ...) — extend deliberately if a project needs it.
#
# fixbatch step7 / F2 — THREAT MODEL RULING, made explicit rather than tuned
# around implicitly. Red-team found the same raw-substring VALIDATION_RE both
# FALSE-BLOCKING an ordinary `git commit -m "fix: npm test now passes"` (the
# phrase merely appears in a commit message) and being BYPASSED by shell
# quote-reconstruction (`npm te''st`, `npm tes\t` — bash reconstitutes both
# into the literal command `npm test`, but the literal payload text never
# contains that substring). Tightening the regex worsens the bypass;
# loosening it worsens the false block — they cannot both be fixed by tuning
# one pattern, so this hook's job is decided on the THREAT MODEL, not the
# regex:
#
#   Is this guard defending against an ADVERSARY (something trying to defeat
#   it) or an ACCIDENT (a well-intentioned agent validating out of turn)?
#
# RULING: ACCIDENT. Every dispatcher of a Bash command this hook can see is
# either a butler worker following its own protocol or an interactive driver
# — neither is adversarial, and nothing in this package's scope (§0 of the
# spec) claims otherwise; the incident this whole package exists to prevent
# (sources/2026-08-12-gsa-worker-observability.md Gap C) was an ordinary
# concurrent `flutter test`/`dart analyze`, not an attempt to evade a guard.
# Given that ruling:
#   - The FALSE BLOCK is the real defect: an innocent commit or echo getting
#     denied, with a misleading message about a validation interlock, harms a
#     well-intentioned agent for no reason. FIXED below via
#     bp_strip_shell_noise() (scripts/bp-lib.sh, lifted from mark-wakeup.sh's
#     byte-scanner) — VALIDATION_RE is now matched against the command with
#     every quoted span, comment, and heredoc body blanked out first, so a
#     denylisted phrase sitting inert inside a string or comment can no
#     longer classify the whole command as validation-shaped.
#   - The BYPASS (quote-reconstruction defeating classification) is an
#     ACCEPTED, DOCUMENTED LIMIT, not fixed here: under the accident threat
#     model, nobody is deliberately spelling `npm te''st` to dodge this hook
#     — a well-intentioned worker/driver has no reason to write a command
#     that way, and if the classifier's own false-block fix (above) means
#     ordinary phrasing is never wrongly denied, there is no accidental
#     pressure toward that spelling either. Closing it would require actual
#     shell parsing (out of scope for a bash hook, per §2.1.1's own bounded-
#     denylist framing), so it is named here rather than silently accepted.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
# shellcheck source=../scripts/bp-lib.sh
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

bp_read_payload open
CMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null)
[ -n "$CMD" ] || exit 0

VALIDATION_RE='(^|[;&|[:space:]])(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(test|build|lint)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])npx[[:space:]]+(vitest|jest|mocha|playwright)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])(pytest|prove)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])(go|cargo|flutter|dart)[[:space:]]+(test|analyze)\b'
# 11-parallel-tree-interlock SS2.8: this repo's own suite entry point,
# scripts/run-tests.pl, matched none of the above -- a no-op for the exact
# command the measured bug (20260916-231127-6e45) was produced by.
#
# REVISED post-review/red-team (review MEDIUM-1, red-team MEDIUM-3): a single
# alternative anchoring only on the token beginning the command missed the
# wrapped forms an operator or coordinator actually types (`timeout 3600 perl
# scripts/run-tests.pl`, `perl -Ilib scripts/run-tests.pl`, `env FOO=1 perl
# ...`). Two alternatives replace the one. The first anchors on [:space:] too
# (safe -- it REQUIRES the literal token `perl` right after, so
# `cat scripts/run-tests.pl` has no `perl` there to match) and accepts any
# number of `perl` switches between `perl` and the path. The second is the
# original bare-path form, still anchored on command-start-or-separator ONLY
# (no leading [:space:]) -- this is the one that must NOT also accept
# [:space:], or `cat scripts/run-tests.pl` starts matching.
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])perl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([^[:space:];&|]*/)?run-tests\.pl\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|])[[:space:]]*([^[:space:];&|]*/)?run-tests\.pl\b'

# MATCH_TEXT: the quote/comment/heredoc-stripped command when bp_strip_shell_noise
# (and the perl it needs) is available and produces non-empty output; otherwise
# fall back to the RAW command, the pre-fix behavior — an unavailable stripper
# must not silently disable the interlock, only lose its false-block fix.
MATCH_TEXT="$CMD"
if command -v bp_strip_shell_noise >/dev/null 2>&1; then
  STRIPPED=$(printf '%s' "$CMD" | bp_strip_shell_noise)
  [ -n "$STRIPPED" ] && MATCH_TEXT="$STRIPPED"
fi

# 11-parallel-tree-interlock SS2.8 (red-team MEDIUM-4): grep -Eq anchors ^ at
# the start of EVERY line, not just the start of the whole string -- so
# `cp \` followed by a continuation line `  scripts/run-tests.pl /tmp/`
# matched the bare-path alternative above (the continuation line, after its
# leading whitespace, looks like a fresh command start). Join backslash-
# newline continuations before matching: a pure parameter-expansion
# substitution (no fork), closing the false-block for every VALIDATION_RE
# alternative, not only the new one.
MATCH_TEXT="${MATCH_TEXT//$'\\\n'/ }"

printf '%s' "$MATCH_TEXT" | grep -Eq "$VALIDATION_RE" || exit 0

# DATA is resolved once here (headless: derived below from BP_DIR; solo:
# via bp_find_data_dir) and reused by the tree-wide check (b) further down,
# so both checks agree on the same tree without re-deriving it twice.
DATA=""
HEADLESS=0
MARKER=""
if [ -n "${BP_LEDGER:-}" ] && [ -n "${BP_DIR:-}" ] && [ -n "${BP_PROJECT_ROOT:-}" ]; then
  HEADLESS=1
  MARKER=$(marker_path)
else
  CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null); CWD=${CWD:-$PWD}
  DATA=$(bp_find_data_dir "$CWD" 2>/dev/null) || exit 0
  [ -n "$DATA" ] || exit 0
  # 11-parallel-tree-interlock, driver ruling on review MEDIUM-2 / red-team
  # MEDIUM-5: .drive-solo/ gates ONLY check (a)'s package-scoped MARKER
  # resolution below -- check (b) (the tree-wide scan) must still run
  # whenever $DATA/blueprints exists, regardless of whether .drive-solo/
  # does. The precondition therefore moves down here, scoped to MARKER
  # alone; nothing about the headless/coordinator branch above is changed.
  if [ -d "$DATA/.drive-solo" ]; then
    MARKER="$DATA/.drive-solo/.active-worker"
  fi
fi

STALE_MIN="${CCPRAXIS_VALIDATION_STALE_MIN:-180}"
case "$STALE_MIN" in ''|*[!0-9]*) STALE_MIN=180 ;; esac
[ "$STALE_MIN" -gt 0 ] 2>/dev/null || STALE_MIN=180

# --- (a) package-scoped check -- unchanged in behavior, message, exit code.
# Re-expressed through bp_marker_is_writer / bp_marker_is_fresh (policy
# "fresh", today's pre-existing unknown-age-blocks semantics) rather than a
# second copy of the classification/age arithmetic (11-parallel-tree-
# interlock SS2.1/SS2.2, DC6).
if [ -s "$MARKER" ]; then
  CURRENT=$(cat "$MARKER" 2>/dev/null || true)
  if [ -n "$CURRENT" ] && bp_marker_is_writer "$CURRENT" \
     && bp_marker_is_fresh "$MARKER" "$STALE_MIN" fresh; then
    echo "BLOCKED (validation interlock): a write-capable worker ($CURRENT) is currently in flight -- running \"$CMD\" now can read its live or leftover temp state and report a false red that looks exactly like a real regression. The command was NOT executed. Wait for the worker to return (or for its marker to age out after $STALE_MIN minutes if it has crashed), then re-run." >&2
    exit 2
  fi
fi

# --- (b) tree-wide check -- is ANY OTHER coordinator's write-capable worker
# in flight anywhere in this tree? New (11-parallel-tree-interlock SS2.4).
# Never reached above if (a) already denied (B7: exactly one BLOCKED line).

# B17: an older/sourcing-failed lib.sh missing ANY of the three primitives
# this check composes degrades silently to check (a) alone, never errors
# under set -u (review LOW-5 -- widened from checking only
# bp_tree_writer_marker, since it internally calls the other two).
command -v bp_tree_writer_marker >/dev/null 2>&1 \
  && command -v bp_marker_is_writer >/dev/null 2>&1 \
  && command -v bp_marker_is_fresh >/dev/null 2>&1 || exit 0

SELF_MARKER="$MARKER"
if [ "$HEADLESS" -eq 1 ]; then
  BLUEPRINTS_ROOT=$(dirname "$BP_DIR" 2>/dev/null) || exit 0
  DATA=$(dirname "$BLUEPRINTS_ROOT" 2>/dev/null) || exit 0
  # B13: the tree check engages ONLY if BP_DIR's parent is literally named
  # "blueprints" -- the guard that keeps this from ever engaging against an
  # ambient, unrelated tree, and what keeps validation-interlock-hooks.t's
  # mk_headless fixture (parent = a tempdir, not "blueprints") unaffected.
  [ "$(basename "$BLUEPRINTS_ROOT")" = "blueprints" ] || exit 0
  # review LOW-1: build SELF_MARKER from the same base the glob itself uses
  # ($BLUEPRINTS_ROOT/basename(BP_DIR)/runs/...) rather than reusing
  # marker_path() (which is built from $BP_DIR directly), so a trailing- or
  # double-slash BP_DIR cannot desync the two string forms. marker_path()
  # itself -- used by check (a) and everything else -- is left untouched.
  SELF_MARKER="$BLUEPRINTS_ROOT/$(basename "$BP_DIR")/runs/${BP_PACKAGE:-pkg}.active-worker"
else
  # $PWD / the payload cwd are never used to locate the blueprints root here
  # -- DATA was already resolved via bp_find_data_dir above.
  BLUEPRINTS_ROOT="$DATA/blueprints"
  [ -d "$BLUEPRINTS_ROOT" ] || exit 0
fi

# This interlock's OWN hatch (SS2.7) -- disables ONLY this tree-wide check;
# the package-scoped check (a) above is never affected by it.
[ "${CCPRAXIS_TREE_INTERLOCK_OFF:-}" != "1" ] || exit 0
TREE_HATCH_TTL="${CCPRAXIS_TREE_INTERLOCK_OFF_TTL_MIN:-60}"
bp_hatch_active "$DATA/.tree-interlock-off" "$TREE_HATCH_TTL" && exit 0

FOREIGN=$(bp_tree_writer_marker "$BLUEPRINTS_ROOT" "$SELF_MARKER" "$STALE_MIN") || exit 0
IFS=$'\t' read -r F_BP F_PKG F_WORKER F_PATH <<<"$FOREIGN"
[ -n "$F_BP" ] && [ -n "$F_PKG" ] || exit 0

# Driver ruling on red-team MEDIUM-1/MEDIUM-2: the hatch mention is
# reworded to be explicit that it is an OPERATOR affordance, not something an
# agent reading this denial should reach for on its own -- wording only; no
# logging is added or implied (spec SS6 explicitly declines it).
echo "BLOCKED (tree interlock): a write-capable worker ($F_WORKER) belonging to blueprint '$F_BP' package '$F_PKG' is currently mid-edit elsewhere in this same working tree ($F_PATH) -- running \"$CMD\" now can read that edit's live or partially-written state and report a false red that looks exactly like a real regression. The command was NOT executed. This is a deny-and-retry, not a wait: nothing is queued on your behalf. Re-run once that worker returns, or once its marker ages out after $STALE_MIN minutes if it has crashed. This hatch is for the human operator: CCPRAXIS_TREE_INTERLOCK_OFF=1 or touching $DATA/.tree-interlock-off disables this tree-wide check (self-expires after ${TREE_HATCH_TTL} minutes). If you are an agent, do not set it -- re-run after the worker returns." >&2
exit 2
