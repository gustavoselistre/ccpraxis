#!/usr/bin/env bash
# lib.sh — shared helpers for butler hooks.
#
# Scoping mechanism: every hook calls bp_hook_gate first. The env contract
# (BP_LEDGER etc.) is exported only by bp-launch.sh into coordinator processes,
# so in the orchestrator's interactive session — and in any unrelated session —
# these hooks exit 0 immediately and cost nothing.

bp_hook_gate() {
  [ -n "${BP_LEDGER:-}" ] || exit 0
  [ -n "${BP_DIR:-}" ] || exit 0
  [ -n "${BP_PROJECT_ROOT:-}" ] || exit 0
}

bp_hook_require_json_parser() {
  # Fail-closed: enforcement hooks must not silently degrade. But the thing they
  # actually need is A JSON PARSER, not jq specifically -- bp_json_get below has
  # read payloads through perl + JSON::PP for as long as it has existed.
  #
  # Requiring jq by name meant every hook calling this blocked outright on a host
  # without it, which is a stock Git-for-Windows machine: this repo's own primary
  # platform, and one that by its Perl-only doctrine is never going to have jq.
  # guard-git-mutations.sh hit exactly that, blocking EVERY Bash call on the host
  # instead of guarding anything, and was given the fallback. The rest were not.
  #
  # Only the absence of BOTH parsers still fails closed.
  command -v jq >/dev/null 2>&1 && return 0
  if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1; then
    return 0
  fi
  echo "butler hook: no JSON parser available (neither jq nor perl+JSON::PP) — blocking to avoid unenforced operation." >&2
  exit 2
}

# Kept so a hook not yet converted still behaves, and so an out-of-tree copy does
# not break. Same semantics as the parser check above.
bp_hook_require_jq() { bp_hook_require_json_parser; }

# bp_read_payload [FAIL_MODE] -- read the hook payload from stdin, BOUNDED, into
# the global PAYLOAD. FAIL_MODE is 'closed' (default) or 'open' and decides what
# happens if stdin never reaches EOF.
#
# CALL IT BARE -- `bp_read_payload closed` -- NEVER as `PAYLOAD=$(bp_read_payload)`.
# Command substitution runs it in a SUBSHELL, where its `exit 2` would terminate
# only that subshell: the hook would continue, with an empty payload, having
# printed a denial nobody acted on. That is the same subshell trap
# guard-git-mutations.sh records beside its own git_scan_target call, and the
# reason both communicate through a global instead of stdout.
#
# WHY THIS EXISTS. Every hook here used `PAYLOAD=$(cat)`, an UNBOUNDED read. When
# stdin reaches EOF -- which is what Claude Code's own hook dispatch does -- that
# is correct and instant. When stdin is an inherited pipe that never closes, cat
# blocks FOREVER at essentially zero CPU, and nothing upstream notices.
#
# That is not hypothetical. Bug report 20260828-095201-7c1e: a perl.exe running a
# throwaway probe out of a session scratchpad was found alive NINE DAYS after the
# session that spawned it had exited, having burnt 0.016s of CPU in total --
# blocked on a read, holding 11 MB and 135 handles, orphaned, with nothing in
# ccpraxis tracking or reaping it. Reproduced directly against
# guard-git-mutations.sh: with stdin closed it exits 0 at once; with stdin a pipe
# that never closes it blocks until killed.
#
# Note what this does NOT claim. The report guessed the probe had wedged on one
# of five specific payloads; replaying that probe shows it does not -- all five
# classify correctly in seconds. The defect is the unbounded read itself, and it
# was in NINE hooks, so it is fixed once, here.
#
# NOT `timeout`. On the Windows host a bare `timeout` resolves to
# C:\Windows\System32\timeout.exe -- the *pause* command -- which rejects these
# arguments outright. That exact mistake is bug report 20260825-193930-fff0,
# where it silently killed all six resources probes before their commands ran.
# `read -t` is a bash builtin: no PATH, no external binary, nothing to resolve.
#
# `read -r -d ''` reads to EOF (no NUL can appear -- JSON escapes U+0000 as the
# six ASCII bytes \u0000, which is what ledger-guard.sh depends on), returns 1 at
# EOF with the data intact, and >128 only on timeout. One difference from $(cat)
# is recorded rather than hidden: $(cat) strips trailing newlines and this does
# not. No JSON parser cares.
#
# The timeout is deliberately far longer than any real payload needs -- a Write
# tool_input can be hundreds of KB, and this must never fire on a slow-but-live
# producer. If it fires at all, the alternative was hanging forever.
#
# IDEMPOTENCE (BP_PAYLOAD_READ_DONE). A second bare call in the same process
# must NOT re-enter `read` at all -- not "make it fast," but "never attempt
# it." A second `read -t` against an already-exhausted stdin behaves
# differently across platforms -- this repo has measured a multi-second hang
# on Windows/cygwin (the ledger's own "runs out its timeout" symptom); on some
# other bash it can instead return immediately with PAYLOAD silently clobbered
# back to "". It does not matter, and this file makes no claim about, WHICH of
# those a given host does -- both are silent-permit failures (the caller's
# remaining logic runs against an empty-or-hung payload and looks healthy
# while having enforced nothing), so the fix is "never attempt it," not "make
# it fast." BP_PAYLOAD_READ_DONE is a plain (non-exported) global, exactly
# like PAYLOAD itself, set only after a read actually completes -- so it
# inherits PAYLOAD's own subshell semantics: a call inside $(...) can only
# ever set the flag in that subshell's own copy, never the parent's
# (lib.sh:43).
#
# THE FLAG ALONE IS NOT TRUSTED -- PAYLOAD must also be set (lib.sh
# fix-batch FIX 3). An ordinary shell variable does not distinguish "this
# process's own bp_read_payload set this" from "this process inherited
# BP_PAYLOAD_READ_DONE=1 from its environment at exec time" -- a stray export
# left on from a debugging session, or any future orchestration that copies
# %ENV wholesale, would otherwise skip the real read entirely and leave every
# downstream bp_json_get silently returning empty (several guards treat that
# as "no match" and ALLOW). A flag of 1 with PAYLOAD unset is self-evidently
# not a completed read in THIS process -- the real read always sets PAYLOAD
# (even to "") before setting the flag -- so it must not short-circuit.
bp_read_payload() {
  local mode="${1:-closed}"
  [ "${BP_PAYLOAD_READ_DONE:-0}" = 1 ] && [ "${PAYLOAD+set}" = set ] && return 0
  local rc=0
  PAYLOAD=""
  IFS= read -r -d '' -t "${BP_PAYLOAD_READ_TIMEOUT:-30}" PAYLOAD || rc=$?
  if [ "$rc" -gt 128 ]; then
    # Timed out. Fail direction follows the hook's OWN behaviour when it cannot
    # classify a call: enforcement hooks deny, observers stand aside.
    if [ "$mode" = open ]; then
      exit 0
    fi
    echo "butler hook: the tool payload did not arrive within ${BP_PAYLOAD_READ_TIMEOUT:-30}s (stdin never closed) -- blocking, because an unread payload cannot be checked." >&2
    exit 2
  fi
  BP_PAYLOAD_READ_DONE=1
  return 0
}

# bp_json_get PAYLOAD KEY [KEY...] -- echo the first non-empty scalar found at
# any of the dot-separated KEY paths in PAYLOAD (a JSON object). Prints nothing
# when no path resolves. Returns 2, printing nothing, when NEITHER jq nor
# perl+JSON::PP is available -- callers MUST treat that as fail-closed.
#
# WHY THIS EXISTS. jq is in the container but NOT on the Windows host (Git for
# Windows ships none), and this repo's premise is that a fresh clone runs with
# no toolchain installs -- everything is Perl, which ships with Git for Windows,
# macOS and Linux alike. The two DELIBERATELY UNGATED guards
# (guard-blueprint-write.sh, guard-git-mutations.sh -- they apply in ANY session,
# not just a bp-launch.sh coordinator) used to `command -v jq || exit 2`, so on
# the host they blocked EVERY Edit/Write and EVERY Bash call, in every session,
# forever. A guard that cannot run on the host is not a guard, it is an outage.
#
# jq stays PREFERRED when present, so container behaviour is unchanged.
#
# The payload reaches perl on stdin, never argv: a Write tool_input can be
# megabytes and would blow ARG_MAX.
#
# PATH GRAMMAR (both branches implement exactly this -- spec 02-hook-lib-fixes
# SS2.1). A KEY is split on '.'. A segment matching ^[0-9]+$ is ALWAYS a
# zero-based array index into the CURRENT node (leading zeros read as decimal,
# e.g. "007" -> index 7) -- never an object key, even against an object that
# happens to have a digit-spelled key. Indexing a non-array (object, scalar,
# null), or an out-of-range index, yields nothing -- same "nothing" as a
# missing key (SS2.3): zero stdout bytes, exit 0, never an error.
#
# BP_JSON_GET_FORCE (unset | perl | jq) -- TEST-ONLY branch selector, read at
# the very top. Unset: unchanged default (prefer jq if on PATH, else perl,
# else return 2). perl: skip the jq branch even if jq is on PATH. jq: require
# the jq branch -- if jq is not on PATH, return 2 immediately (the same
# no-parser signal), never a silent fallback to perl.
#
# THIS IS A TEST-ONLY SEAM, not a runtime tuning knob. Pre-setting
# BP_JSON_GET_FORCE=jq in a real hook's environment on a jq-less host (this
# repo's own stated primary platform) forces `return 2` on every single
# bp_json_get call for the process's lifetime -- several callers don't check
# the return code and just treat the resulting empty value as "no match",
# which several guards (guard-bash.sh, guard-git-mutations.sh, ledger-guard.sh)
# turn into a silent ALLOW; guard-subagent-stall.sh's own
# `EVENT=$(...) || exit 0` idiom makes that conversion explicit. Do NOT "fix"
# this by making the jq branch silently fall back to perl when forced and jq
# is absent -- json-get-array-index.t's own MECHANISM assertion deliberately
# pins exit 2 here precisely so this differential seam stays trustworthy: a
# seam that quietly degrades to "whichever parser happens to be present"
# would make every jq-vs-perl comparison in that file meaningless. Nothing in
# shipped hook code sets this variable; only the test harness does, scoped
# per-subprocess.
bp_json_get() {
  local payload="$1"; shift
  [ "$#" -gt 0 ] || return 2

  local __force="${BP_JSON_GET_FORCE:-}" __use_jq=0
  case "$__force" in
    jq)   command -v jq >/dev/null 2>&1 || return 2
          __use_jq=1 ;;
    perl) __use_jq=0 ;;
    *)    command -v jq >/dev/null 2>&1 && __use_jq=1 ;;
  esac

  if [ "$__use_jq" -eq 1 ]; then
    local expr="" k seg segexpr has_digit
    for k in "$@"; do
      [ -z "$expr" ] || expr="$expr // "
      segexpr=""
      has_digit=0
      local -a __segs=()
      IFS='.' read -r -a __segs <<<"$k"
      # bash < 4.4 (stock macOS /bin/bash 3.2) raises "unbound variable" under
      # set -u when expanding "${arr[@]}" on a genuinely zero-element array --
      # fixed in 4.4, but this file is sourced under set -u by every caller and
      # macOS is a first-class host here. `${#arr[@]}` is safe on every bash
      # version (only [@]/[*] EXPANSION is the trap), so gate on that instead
      # of ever expanding an empty __segs. Not live today (no caller passes an
      # empty KEY), but cheap to close.
      if [ "${#__segs[@]}" -gt 0 ]; then
        for seg in "${__segs[@]}"; do
          case "$seg" in
            ''|*[!0-9]*) segexpr="$segexpr.$seg" ;;      # literal object key
            *)           segexpr="$segexpr[$seg]?"; has_digit=1 ;;  # array index, error-suppressed
          esac
        done
      fi
      # A candidate that walked through at least one array index must yield
      # "nothing" for an object/array RESULT too, not just an out-of-range or
      # wrong-type STEP -- spec SS2.1: "resolving to an object, array, or null
      # counts as 'not a match' for that candidate", matching the perl branch's
      # `ref $v` check a few lines down. `[N]?` only suppresses a runtime error
      # from indexing a non-array; it does nothing to a successful index whose
      # element is itself an object/array, and jq's `//` only substitutes on
      # null/false, so a truthy object/array result would otherwise print
      # verbatim AND wrongly foreclose a later // candidate. `scalars` (jq
      # builtin: select(type != "array" and type != "object")) filters exactly
      # that. The parens are required here because `|` binds looser than `//`
      # in jq -- `.a[0]? | scalars // .b` parses as `.a[0]? | (scalars // .b)`,
      # which is wrong; `(.a[0]? | scalars) // .b` is what's needed.
      # Non-digit candidates are left bare -- AC-7's byte-identical contract
      # only covers KEYs with no digit segment anywhere, and a plain dotted
      # path can never resolve to something that needs this filter differently
      # than the pre-existing scalar-only contract already handled.
      if [ "$has_digit" -eq 1 ]; then
        segexpr="($segexpr | scalars)"
      fi
      expr="$expr$segexpr"
    done
    # rc deliberately UNCHECKED, matching the pre-existing `jq ... 2>/dev/null`
    # callers: malformed JSON yielded empty (allow) before and still does, so
    # this refactor cannot change what the container decides. A [N]? whose
    # runtime node is not an array degrades to "no output" for that step the
    # same way, chained into the rest of the // fallback.
    #
    # NO WRAPPING PARENS around the OUTER // chain. `//` is left-associative,
    # so `.a // .b // empty` and `(.a // .b) // empty` are the same query to
    # jq -- but they are NOT the same STRING, and several tests stand in for
    # jq with a small perl script that parses the expression. Those shims
    # split on `//` and treat each term as a dotted path; a leading `(` on the
    # WHOLE expression makes the first term unparseable, so the shim returns
    # nothing, the hook sees an empty value and ALLOWS what it should have
    # denied. Emitting the shape the hooks have always used keeps every such
    # stand-in working, and costs nothing with a real jq. A KEY with no digit
    # segment compiles to EXACTLY today's dot-concatenation string -- unchanged,
    # byte for byte (the per-candidate `(... | scalars)` wrapping above only
    # ever applies to a candidate that used a digit segment).
    jq -r "$expr // empty" <<<"$payload" 2>/dev/null
    return 0
  fi

  if command -v perl >/dev/null 2>&1; then
    local out rc
    out=$(perl -MJSON::PP -e '
      binmode(STDIN, ":raw"); binmode(STDOUT, ":raw");
      my $raw = do { local $/; <STDIN> };
      my $doc = eval { JSON::PP->new->utf8->decode($raw) };
      exit 0 unless ref $doc eq "HASH";          # malformed -> empty, as jq
      for my $path (@ARGV) {
        my $v = $doc;
        for my $seg (split /\./, $path) {
          if ($seg =~ /^[0-9]+$/) {
            # Bound-check numerically before subscripting -- a digit string
            # that overflows the interpreter integer range (e.g.
            # "99999999999999999999") converts to a huge double, and
            # $v->[$huge_double] behaves like a NEGATIVE index (wraps to the
            # LAST element) rather than "out of range". $seg <= $#$v compares
            # against a small int on the RHS, so the same huge-double
            # conversion happens but correctly evaluates false -- no
            # wraparound, matching the documented contract just above (an
            # out-of-range index yields nothing) and the jq branch, which
            # never wraps.
            $v = (ref $v eq "ARRAY" && $seg <= $#$v) ? $v->[$seg] : undef;   # never an object key
          } else {
            $v = (ref $v eq "HASH") ? $v->{$seg} : undef;
          }
          last unless defined $v;
        }
        next if !defined $v || ref $v || $v eq "";
        utf8::encode($v);                        # chars back to UTF-8 bytes
        print $v;
        last;
      }
    ' -- "$@" <<<"$payload" 2>/dev/null)
    rc=$?
    # rc IS checked here (unlike the jq branch): the perl program exits 0 on
    # every data outcome including malformed JSON, so a non-zero rc means the
    # interpreter itself failed -- JSON::PP absent, perl broken -- which is the
    # "no parser" case and must fail closed, not silently allow.
    [ "$rc" -eq 0 ] || return 2
    printf '%s' "$out"
    return 0
  fi

  return 2
}

# match_any REL_PATH PATTERNS — colon-separated bash-glob patterns,
# '*' crosses '/', trailing '/' means prefix.
match_any() {
  local p="$1" pats="$2" pat
  [ -n "$pats" ] || return 1
  local IFS=':'
  # shellcheck disable=SC2086
  for pat in $pats; do
    [ -n "$pat" ] || continue
    case "$pat" in
      */) if [[ "$p" == "$pat"* || "$p/" == "$pat" ]]; then return 0; fi ;;
      *)  # shellcheck disable=SC2053
          if [[ "$p" == $pat ]]; then return 0; fi ;;
    esac
  done
  return 1
}

marker_path() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.active-worker"; }

# ---------------------------------------------------------------------------
# 11-parallel-tree-interlock: shared marker-freshness / writer-classification
# / hatch-TTL / tree-scan primitives. See
# specs/11-parallel-tree-interlock-spec.md SS2.1-SS2.4. None of these ever
# exit, write to stderr, or mutate caller state beyond the documented hatch
# rm -f. All are safe under `set -u`.
# ---------------------------------------------------------------------------

# bp_marker_is_fresh MARKER STALE_MIN [UNKNOWN_AGE_POLICY] [NOW] -- the single
# definition of "this marker is live and recent enough to count".
# UNKNOWN_AGE_POLICY is "fresh" (default) or "stale": governs the verdict
# when the age cannot be computed (date/bp_mtime failure). A future-dated
# mtime yields a negative age, which is naturally "< STALE_MIN" and so
# already fresh under policy fresh (today's byte-for-byte behavior); policy
# stale additionally REQUIRES mtime <= now before computing that age.
# NOW (11-parallel-tree-interlock SS2.1) is an optional 4th, caller-supplied
# epoch-seconds value. When passed (a non-empty, all-digit string), it is
# used instead of forking `date +%s` internally -- bp_tree_writer_marker
# forks `date` once per hook invocation and passes it here, so a scan of up
# to 32 candidates costs one `date` fork, not 32. Omitted, empty, or
# non-numeric -> unchanged behavior: the function forks its own. Every
# existing 3-arg caller (bp_hatch_active does not call this at all; check
# (a)'s own call site in guard-validation-interlock.sh) is unaffected.
bp_marker_is_fresh() {
  local marker="$1" stale="$2" policy="${3:-fresh}" now_arg="${4:-}"
  case "$stale" in ''|*[!0-9]*) stale=180 ;; esac
  [ "$stale" -gt 0 ] 2>/dev/null || stale=180
  [ -s "$marker" ] || return 1
  case "$now_arg" in ''|*[!0-9]*) now_arg="" ;; esac
  local NOW MTIME
  if [ -n "$now_arg" ]; then
    NOW="$now_arg"
  else
    NOW=$(date +%s 2>/dev/null || echo 0)
  fi
  MTIME=$(bp_mtime "$marker")
  if [ "$NOW" -gt 0 ] && [ "$MTIME" -gt 0 ]; then
    if [ "$policy" = stale ] && [ "$MTIME" -gt "$NOW" ]; then
      return 1
    fi
    local age=$(( (NOW - MTIME) / 60 ))
    [ "$age" -lt "$stale" ] && return 0
    return 1
  fi
  # Age undeterminable.
  [ "$policy" = fresh ] && return 0
  return 1
}

# bp_marker_is_writer CONTENT -- rc 0 iff CONTENT names one of the three
# write-capable worker roles. Same closed set the pre-existing case
# statements in this hook and track-dispatch.sh's is_writer() use.
bp_marker_is_writer() {
  case "$1" in
    *bp-implementer*|*bp-test-writer*|*bp-ui-prober*) return 0 ;;
    *) return 1 ;;
  esac
}

# bp_hatch_active HATCH_PATH TTL_MIN -- the single definition of the file-form
# escape-hatch TTL rule, lifted verbatim in semantics from bp_driver_context's
# own file-hatch step (below). rc 1 if the hatch does not exist. TTL_MIN is
# normalized: empty/non-digit/<=0 -> 60; > 1440 -> 1440 (redteam MINOR-2 cap).
# An undeterminable age (clock/stat failure) -> rc 0 (hatch honoured -- fail
# toward the hatch staying honoured, never toward silently re-enforcing). A
# future-dated mtime is treated as already-expired (redteam MINOR-1). Past
# TTL, or future-dated: best-effort rm -f, then rc 1.
bp_hatch_active() {
  local hatch="$1" ttl="$2"
  [ -e "$hatch" ] || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
  [ "$ttl" -gt 0 ] 2>/dev/null || ttl=60
  [ "$ttl" -le 1440 ] 2>/dev/null || ttl=1440
  local now mt age
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(bp_mtime "$hatch")
  if [ "$now" -gt 0 ] && [ "$mt" -gt 0 ]; then
    if [ "$mt" -le "$now" ]; then
      age=$(( (now - mt) / 60 ))
      if [ "$age" -lt "$ttl" ]; then
        return 0
      fi
    fi
    rm -f "$hatch" 2>/dev/null
    return 1
  fi
  return 0
}

# bp_tree_writer_marker BLUEPRINTS_ROOT SELF_MARKER STALE_MIN -- the
# tree-wide scan. Enumerates every coordinator marker under BLUEPRINTS_ROOT
# and reports the first that belongs to someone else and is a live, fresh
# writer. Output: one TAB-separated line "blueprint\tpackage\tworker\tpath".
# rc 1 (nothing printed) when no such marker is found, the root is missing,
# or the bounded scan cap (32 non-self candidates) is exhausted with no match.
#
# REVISED POST-REDTEAM (11-parallel-tree-interlock spec SS2.4, "Revision
# note" -- supersedes an earlier version of this function that counted ALL
# candidates up front, before self-exclusion and before classification, and
# stood aside whenever that count exceeded the cap REGARDLESS of whether an
# examined candidate had already matched). Red-team measured that inverted
# the safety property it exists to provide: 300 one-byte junk files under any
# blueprints/*/runs/ path -- creatable by any Bash call, no writer content
# required -- silently disabled the entire tree-wide interlock, fleet-wide,
# indefinitely (report 20260916-231127-6e45 reopened by a different trigger).
#
# THE CORRECTED RULE, classify-in-order-then-decide: self-exclusion happens
# FIRST, by exact string equality against SELF_MARKER, before any counting or
# I/O -- a candidate that IS self is never counted or classified at all. Then
# at most 32 OTHER candidates are classified in deterministic (lexicographic
# glob) order; a match found within that window denies (rc 0) IMMEDIATELY,
# however many further candidates exist beyond the cap. Only once 32 non-self
# candidates have been examined with no match does the function stand aside
# (rc 1 = allow). This bounds the WORK (never more than 32 classifications,
# ~106ms each measured empirically by red-team, comfortably under the hook's
# 15s registered timeout) without letting an unbounded pile of harmless
# markers manufacture a false "no writer present" verdict.
#
# The cap dropped from 256 to 32 as a direct consequence of this ordering:
# under the OLD pre-count design the cap bounded nothing (candidates past it
# were never classified either way), so its value was arbitrary; under this
# design every candidate up to the cap is unconditionally classified on the
# allow path, so the cap IS the hook's worst-case latency budget.
#
# `now` is computed ONCE per invocation and passed as bp_marker_is_fresh's
# optional 4th arg, so a scan of up to 32 candidates costs one `date` fork,
# not 32 (review LOW-2 / red-team HIGH-2).
#
# Content, blueprint and package are sanitized to [A-Za-z0-9:_-] and
# truncated to 64 bytes BEFORE the TAB-separated line is ever printed (spec
# SS2.9, red-team HIGH-3): this string crosses into a DIFFERENT coordinator's
# transcript, verbatim, as the body of an authoritative-looking guard denial
# -- an untrusted, cross-session data flow that did not exist before this
# package. This also closes the TAB/newline field-corruption hazard (review
# LOW-3/LOW-4) in the same stroke.
#
# No intermediate array is ever built -- a single streaming loop over the
# glob -- which structurally eliminates the bash-<4.4 `set -u` trap around
# expanding an empty "${arr[@]}" (review HIGH-1): there is no array to expand.
bp_tree_writer_marker() {
  local root="$1" self="$2" stale="$3" c n=0 now content role bp pkg
  [ -n "$root" ] && [ -d "$root" ] || return 1
  now=$(date +%s 2>/dev/null) || now=""
  for c in "$root"/*/runs/*.active-worker; do
    [ -f "$c" ] || continue                       # unexpanded glob / stale dirent
    [ "$c" != "$self" ] || continue               # self-exclusion BEFORE any I/O, BEFORE cap counting
    n=$((n + 1))
    [ "$n" -le 32 ] || return 1                   # bounded WORK: classify at most 32 candidates,
                                                   # THEN stand aside (rc 1 = allow) -- see note above
    bp_marker_is_fresh "$c" "$stale" stale "$now" || continue
    content=$(cat "$c" 2>/dev/null) || continue
    bp_marker_is_writer "$content" || continue
    pkg=$(basename "$c"); pkg="${pkg%.active-worker}"
    bp=$(basename "$(dirname "$(dirname "$c")")")
    # Implementer deviation from the spec's literal one-line-per-field
    # sanitizer (flagged in the fix-batch report): a character-class filter
    # alone does not remove an EMBEDDED WORD made entirely of allowed
    # characters -- a marker crafted as "bp-implementer -- ... export ...
    # CCPRAXIS_TREE_INTERLOCK_OFF=1 ..." still has "export" survive
    # [^A-Za-z0-9:_-] stripping and the 64-byte truncation, because that
    # substring sits well inside the first 64 kept bytes. Sec2.2's own
    # classifier (bp_marker_is_writer) already reduces "worker identity" to a
    # closed 3-value set; printing that CANONICAL role token instead of the
    # raw (even if character-filtered) content closes the injection surface
    # completely rather than merely narrowing its alphabet, while still
    # satisfying every acceptance point that only requires "the worker name"
    # to appear (B1/A2 et al. -- one of the three role names always suffices).
    case "$content" in
      *bp-implementer*) role=bp-implementer ;;
      *bp-test-writer*) role=bp-test-writer ;;
      *bp-ui-prober*)   role=bp-ui-prober ;;
      *)                role="" ;;                # unreachable: bp_marker_is_writer already matched
    esac
    content=${role//[^A-Za-z0-9:_-]/}; content=${content:0:64}
    pkg=${pkg//[^A-Za-z0-9_-]/}; pkg=${pkg:0:64}
    bp=${bp//[^A-Za-z0-9_-]/}; bp=${bp:0:64}
    printf '%s\t%s\t%s\t%s\n' "$bp" "$pkg" "$content" "$c"
    return 0
  done
  return 1
}

ledger_lock() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.ledger.lock"; }

# --- graceful-stop gate (Decision #10/#18, package A4) -----------------------

# bp_active_stop_signal — which fleet stop signal (if any) is in force for THIS
# coordinator, by precedence (most directive first): a graceful-shutdown-all wins
# over a per-package force-stop wins over a usage/telemetry pause. Echoes one of
# "shutdown" | "forcestop" | "paused" | "" (empty = no stop in progress).
# I/O helper (reads runs/); keep the decision in bp_gate_verdict pure.
bp_active_stop_signal() {
  local runs="$BP_DIR/runs"
  if [ -f "$runs/.shutdown" ]; then printf '%s\n' shutdown; return 0; fi
  if [ -f "$runs/${BP_PACKAGE:-pkg}.force-stop" ]; then printf '%s\n' forcestop; return 0; fi
  if [ -f "$runs/.paused" ]; then printf '%s\n' paused; return 0; fi
  printf '%s\n' ""
}

# bp_gate_verdict TOOL PATHCLASS SIGNAL_ACTIVE -> echoes "allow" | "deny"
# Pure decision (no I/O — unit-tested as the allow-park/deny-work matrix). When a
# fleet stop signal is active, deny NEW work so the coordinator funnels to a clean
# park; always allow the ledger park-write and non-mutating tools (Decision #10).
#   TOOL          : Task | Edit | Write | MultiEdit | NotebookEdit | Bash | <read tools>
#   PATHCLASS     : for edit tools, "ledger" (BP_DIR/tmp park-write) | "worksite"
#                   (project files = new work); "-"/"" for non-path tools
#   SIGNAL_ACTIVE : 1 if any stop signal is in force, else 0
bp_gate_verdict() {
  local tool="$1" pclass="$2" sig="$3"
  [ "$sig" = 1 ] || { printf '%s\n' allow; return 0; }
  case "$tool" in
    Task)
      printf '%s\n' deny ;;                       # no new workers while stopping
    Edit|Write|MultiEdit|NotebookEdit)
      case "$pclass" in
        ledger) printf '%s\n' allow ;;            # the park-write is always permitted
        *)      printf '%s\n' deny ;;             # edits into the worksite are new work
      esac ;;
    *)
      printf '%s\n' allow ;;                       # Bash / read tools: finalize & park
  esac
}

# --- mechanical repeat-command guard (b10) -----------------------------------
#
# Five pure helpers backing repeat-guard.sh. All are sourceable with no
# filesystem or clock access apart from bp_repeat_state_path (env-vars only)
# and bp_repeat_hash (needs jq). See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md
# §2.3 for the exact contracts these implement.

# bp_repeat_verdict RUNLEN FIRED THRESHOLD ACTION -> echoes "fire" | "pass"
# PURE — no I/O. Any unparseable/missing argument -> pass (fail-open bias).
bp_repeat_verdict() {
  local runlen="$1" fired="$2" thresh="$3" action="$4"

  case "$runlen" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac
  case "$thresh" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac

  case "$action" in
    off)
      printf '%s\n' pass
      ;;
    deny)
      # deny is sticky: fires on every call past threshold, ignoring FIRED.
      if [ "$runlen" -ge "$thresh" ]; then printf '%s\n' fire; else printf '%s\n' pass; fi
      ;;
    nudge)
      case "$fired" in
        0|1) ;;
        *) printf '%s\n' pass; return 0 ;;
      esac
      if [ "$runlen" -ge "$thresh" ]; then
        if [ "$fired" = 1 ]; then printf '%s\n' pass; else printf '%s\n' fire; fi
      else
        printf '%s\n' pass
      fi
      ;;
    *)
      # unrecognised action -> disabled (a typo must never produce a block)
      printf '%s\n' pass
      ;;
  esac
}

# bp_repeat_runlen HASH NOW WINDOW_SECONDS (window lines on STDIN) -> "RUNLEN FIRED"
# PURE apart from reading stdin — no filesystem, no clock (NOW is a parameter).
# Walks stdin lines newest -> oldest starting from a virtual new entry
# (NOW, HASH, 0). Invalid lines (not matching TS\tHASH\t[01]) are skipped
# without breaking the run. A hash mismatch or a staleness gap (when
# WINDOW_SECONDS > 0) stops the walk.
bp_repeat_runlen() {
  local hash="$1" now="$2" winsecs="$3"
  local runlen=1 fired=0 prevts="$now"
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done
  local re=$'^([0-9]+)\t([^\t]+)\t([01])$'
  local i ts h f
  for (( i=${#lines[@]}-1; i>=0; i-- )); do
    line="${lines[$i]}"
    if [[ "$line" =~ $re ]]; then
      ts="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; f="${BASH_REMATCH[3]}"
      [ "$h" = "$hash" ] || break
      if [ "$winsecs" -gt 0 ] 2>/dev/null; then
        if (( prevts - ts > winsecs )); then
          break
        fi
      fi
      runlen=$(( runlen + 1 ))
      [ "$f" = 1 ] && fired=1
      prevts="$ts"
    fi
  done
  printf '%s %s\n' "$runlen" "$fired"
}

# bp_repeat_hash (payload on STDIN) -> echoes a hash token, or nothing on failure
# Deterministic, no filesystem writes, but needs jq. Applies the RULING-2(a)
# canonicalisation program (sorted keys, compact, whitespace-scrubbed strings),
# then digests with sha1sum (else cksum). Falls back once to a key-order-only
# canonicalisation if the primary jq program fails (older jq lacking walk/gsub).
bp_repeat_hash() {
  local payload
  payload=$(cat 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1

  local out
  out=$(jq -S -c '
    def scrub: walk(
      if type == "string"
      then (if length > 2048
            then (.[0:2048] | gsub("[[:space:]]+"; " ")) + "#" + (length|tostring)
            else (gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")) end)
      else . end);
    [ (.tool_name // ""), ((.tool_input // {}) | scrub) ]
  ' <<<"$payload" 2>/dev/null)

  if [ -z "$out" ]; then
    out=$(jq -S -c '[.tool_name // "", .tool_input // {}]' <<<"$payload" 2>/dev/null)
  fi
  [ -n "$out" ] || return 1

  local digest=""
  if command -v sha1sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | sha1sum 2>/dev/null)
    digest="${digest%% *}"
  elif command -v cksum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | cksum 2>/dev/null)
    digest="${digest%% *}"
  fi
  [ -n "$digest" ] || return 1

  digest=$(printf '%s' "$digest" | tr -cd 'A-Za-z0-9')
  [ -n "$digest" ] || return 1

  printf '%s\n' "$digest"
}

# bp_repeat_session_token RAW -> echoes sanitised token, or "nosid"
# PURE. Replaces every char outside [A-Za-z0-9_-] with '_', truncates to 16.
bp_repeat_session_token() {
  local raw="$1"
  local token
  token=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '_')
  token="${token:0:16}"
  if [ -z "$token" ]; then
    printf '%s\n' nosid
  else
    printf '%s\n' "$token"
  fi
}

# bp_repeat_state_path TOKEN -> echoes "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-<TOKEN>.log"
# PURE — reads only env vars.
bp_repeat_state_path() {
  local token="$1"
  printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-${token}.log"
}

# bp_repeat_config_int RAW DEFAULT MIN -> echoes RAW if a decimal integer >= MIN, else DEFAULT
# PURE.
bp_repeat_config_int() {
  local raw="$1" def="$2" min="$3"
  case "$raw" in
    ''|*[!0-9]*) printf '%s\n' "$def"; return 0 ;;
  esac
  if [ "$raw" -ge "$min" ] 2>/dev/null; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$def"
  fi
}

# bp_repeat_action_of RAW -> echoes "nudge" | "deny" | "off"
# PURE. Unset/empty -> nudge (default). Any other unrecognised value -> off
# (an unrecognised action disables the guard; a typo must never produce a block).
bp_repeat_action_of() {
  local raw="$1"
  case "$raw" in
    ''|nudge) printf '%s\n' nudge ;;
    deny)     printf '%s\n' deny ;;
    off)      printf '%s\n' off ;;
    *)        printf '%s\n' off ;;
  esac
}

# ---------------------------------------------------------------------------
# Path walking and drive-solo session scoping.
# ---------------------------------------------------------------------------

# bp_find_data_dir CWD -> echoes the .ccpraxis-local-data path, or nothing (rc 1).
#
# ⚠ TERMINATION IS THE WHOLE POINT OF THIS FUNCTION. It replaces two hand-rolled
# copies of
#
#     while [ -n "$d" ] && [ "$d" != "/" ]; do ... d=$(dirname "$d"); done
#
# which DID NOT TERMINATE on Windows. Claude Code puts a drive-letter cwd in the
# hook payload ("C:/Development/indocs"), and dirname walks that to "C:" and then
# returns "C:" forever — a fixed point that is neither empty nor "/". Any session
# whose cwd had no .ccpraxis-local-data ancestor therefore spun here until the
# hook timeout: 30s on every Stop, and — because mark-wakeup.sh is PreToolUse on
# Bash and Task — 15s on EVERY tool call, in EVERY unrelated project on the
# machine. Reported as an agent hanging at "running stop hooks… 1/2 · 56s".
#
# Two independent stops, because one is a promise and two is a guarantee:
#   * the loop ends at a FIXED POINT (d == prev), which covers "/", "C:", ".",
#     "//server" and anything else dirname converges on, and
#   * a hard depth cap, so even a pathological dirname cannot spin.
bp_find_data_dir() {
  local start="${1:-}" d prev n
  if [ -n "${CCPRAXIS_DATA_DIR:-}" ]; then
    printf '%s' "$CCPRAXIS_DATA_DIR"
    return 0
  fi
  [ -n "$start" ] || return 1
  d=$start; prev=''; n=0
  while [ -n "$d" ] && [ "$d" != "$prev" ] && [ "$n" -lt 64 ]; do
    if [ -d "$d/.ccpraxis-local-data" ]; then
      printf '%s' "$d/.ccpraxis-local-data"
      return 0
    fi
    prev=$d
    d=$(dirname "$d" 2>/dev/null) || return 1
    n=$((n + 1))
  done
  return 1
}

# bp_is_absolute_path VALUE -> rc 0 iff VALUE begins with a POSIX absolute
# path ('/...') or a Windows drive-letter path ('C:', 'C:/...', or 'C:\...').
# Anything else — empty, whitespace-only, '.', '..', a bare relative word —
# is rejected, rc 1.
#
# d04-registry-path-one-rule fixbatch step7 / FIX 1 (redteam-step6.md
# CRITICAL-1, driver-reproduced). bp_registry_root used to check only
# `[ -n "$base" ]`: non-empty, never absolute. A whitespace-only or relative
# $HOME (` `, `.`, `..`, a bare word) therefore passed as "resolved", and the
# resulting path — base/.claude/ccpraxis/<leaf> — did not start with `/`, so
# every downstream consumer (mkdir -p, printf > "$MARK", [ -d ]) resolved it
# relative to the hook's OWN cwd at the moment it ran: exactly the
# "$PWD is not stable across a session" hazard this whole package exists to
# close, reached by a different door. Reproduced end to end: HOME=" " left a
# directory literally named " " under the hook's cwd, marker written with
# ZERO stderr, and a Stop check from a different cwd never found it.
#
# WHAT COUNTS AS ABSOLUTE ON THIS PLATFORM, and why both forms are accepted:
# Git-for-Windows bash sees POSIX-style ($HOME=/c/Users/André, this machine's
# REAL value) and Windows-style (C:/Users/... or C:\Users\...) paths alike,
# both of which genuinely resolve. Rejecting either would disable the
# registry for a legitimate environment, which is worse than the bug this
# fixes. A trailing slash, embedded spaces, non-ASCII characters, and even an
# embedded newline after the leading slash/drive-letter are all accepted
# verbatim — they are properties of a real path, not evidence of relativity.
# bp_mtime FILE -- the file's mtime in epoch seconds, or 0 if it cannot be read.
#
# `stat -c %Y` is GNU-only. Every caller wrote `stat -c %Y "$f" 2>/dev/null ||
# echo 0`, which on BSD/macOS takes the `|| echo 0` branch for a file that
# exists and is perfectly readable -- and every one of those callers is an AGE
# check. An age of "0 epoch" is either infinitely old or, in the comparisons
# used here, indistinguishable from "cannot tell", so the effect is that TTL
# reaping quietly stops happening: stale markers become immortal and the sweeps
# that are supposed to clear an abandoned arm never fire.
#
# Windows and the Linux container both have GNU stat, so this is not a live
# outage today -- it is a portability claim this repo makes and does not keep.
# GNU first (no new cost where it works), BSD second, and perl last because
# perl is the one thing every supported host is guaranteed to have.
bp_mtime() {
  local f="$1" mt
  [ -n "$f" ] || { printf '0'; return 0; }
  mt=$(stat -c %Y "$f" 2>/dev/null) && [ -n "$mt" ] && { printf '%s' "$mt"; return 0; }
  mt=$(stat -f %m "$f" 2>/dev/null) && [ -n "$mt" ] && { printf '%s' "$mt"; return 0; }
  mt=$(perl -e 'print ((stat($ARGV[0]))[9] // 0)' "$f" 2>/dev/null) \
    && [ -n "$mt" ] && { printf '%s' "$mt"; return 0; }
  printf '0'
}

bp_is_absolute_path() {
  case "$1" in
    /*) return 0 ;;
    [A-Za-z]:|[A-Za-z]:[/\\]*) return 0 ;;
    *) return 1 ;;
  esac
}

# bp_registry_root -> echoes the base path every machine-level registry
# (drive-solo, reporter, continuity) resolves under: override, else $HOME,
# else $USERPROFILE, else UNRESOLVABLE (rc 1, nothing on stdout). $PWD is
# never a fallback here — a registry keyed on the current directory is not a
# registry, because a hook's cwd is not stable across a session (separate
# process spawns; a driver may `cd` mid-run). This is the ONLY place this
# order is spelled out; every registry-specific resolver below (and
# bp_continuity_active_dir) calls this rather than restating it.
# d04-registry-path-one-rule: extracted verbatim from
# bp_continuity_active_dir's own inline HOME/USERPROFILE fallback (g01),
# not reinvented.
#
# fixbatch step7 / FIX 1: "resolved" now means bp_is_absolute_path, not
# merely non-empty — see that helper's comment for the full rationale.
#
# fixbatch step7 / FIX 2 (redteam-step6.md MUST-FIX-1): sets the GLOBAL
# BP_REGISTRY_ROOT as well as printing on stdout. Every callsite below reads
# the global instead of capturing this function's own output via a nested
# $(...) — command substitution unconditionally strips trailing newlines, so
# a $HOME/$USERPROFILE ending in one or more newlines used to come out
# shorter after routing through an EXTRA, avoidable capture layer than the
# pre-refactor inline `base="${HOME:-}"` did (measured: 59 bytes -> 58).
# Reading the global instead removes that avoidable layer entirely, so the
# three registry-specific resolvers are now byte-for-byte identical to a
# direct `base="${HOME:-}"` assignment for EVERY input, not just the ones
# without trailing newlines. (The one remaining $(...) — where
# mark-wakeup.sh/gate-drive-loop.sh capture bp_drive_active_dir/
# bp_reporter_active_dir/bp_continuity_active_dir's OWN stdout — is
# unavoidable and pre-existing: those functions have always communicated
# their result over stdout, exactly as bp_continuity_active_dir did before
# this package touched it.)
bp_registry_root() {
  local base="${HOME:-}"
  [ -n "$base" ] || base="${USERPROFILE:-}"
  bp_is_absolute_path "$base" || { BP_REGISTRY_ROOT=""; return 1; }
  BP_REGISTRY_ROOT="$base"
  printf '%s' "$base"
  return 0
}

# bp_drive_active_dir -> echoes the machine-level registry of ACTIVE drive-solo
# driver sessions. One file per session, named by session_id.
#
# WHY A REGISTRY, replacing "is there a .drive-solo/order.json above my cwd".
# That question is wrong twice over. It says YES for every session in a tree
# that has ever run drive-solo — order.json was never deleted when a run
# finished, so two settled runs on this machine armed the Stop gate for every
# future session in those trees, forever. And it says yes for sessions that are
# not the driver at all: a second terminal in the same project inherited the
# gate. The registry answers the question actually being asked — "is THIS
# session driving?" — and answers it in one stat().
#
# d04-registry-path-one-rule: dropped the old inline HOME-or-cwd fallback in
# favor of bp_registry_root (override -> HOME -> USERPROFILE -> rc 1, no
# current-directory guess).
bp_drive_active_dir() {
  # fixbatch step7 / FIX 1: the override is validated too — an override that
  # is empty or relative would otherwise bypass bp_registry_root's guard
  # entirely and reintroduce the same cwd-relative hazard through a second
  # door. Test suites always set this to an absolute tempdir, so this is a
  # no-op for every oracle in this repo.
  if [ -n "${CCPRAXIS_DRIVE_ACTIVE_DIR:-}" ]; then
    bp_is_absolute_path "$CCPRAXIS_DRIVE_ACTIVE_DIR" || return 1
    printf '%s' "$CCPRAXIS_DRIVE_ACTIVE_DIR"
    return 0
  fi
  bp_registry_root >/dev/null || return 1
  printf '%s' "$BP_REGISTRY_ROOT/.claude/ccpraxis/.drive-solo-active"
  return 0
}

# bp_reporter_active_dir -> echoes the machine-level registry of ACTIVE
# reporter sessions. Mirrors bp_drive_active_dir exactly; own override var.
# d04-registry-path-one-rule: NEW -- the reporter registry previously had no
# shared resolver at all, just three literal inline HOME-or-cwd copies
# (mark-wakeup.sh's write site, gate-drive-loop.sh's two read sites).
bp_reporter_active_dir() {
  # fixbatch step7 / FIX 1: see bp_drive_active_dir's identical comment.
  if [ -n "${CCPRAXIS_REPORTER_ACTIVE_DIR:-}" ]; then
    bp_is_absolute_path "$CCPRAXIS_REPORTER_ACTIVE_DIR" || return 1
    printf '%s' "$CCPRAXIS_REPORTER_ACTIVE_DIR"
    return 0
  fi
  bp_registry_root >/dev/null || return 1
  printf '%s' "$BP_REGISTRY_ROOT/.claude/ccpraxis/.reporter-active"
  return 0
}

# bp_reporter_ttl_hours -> the staleness limit, sanitised. Mirrors
# bp_drive_ttl_hours; keeps the env var gate-drive-loop.sh already honoured
# (CCPRAXIS_REPORTER_TTL_H) so the two reap paths cannot disagree about the age
# of the same marker.
bp_reporter_ttl_hours() {
  local h="${CCPRAXIS_REPORTER_TTL_H:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  [ "$h" -gt 0 ] 2>/dev/null || h=12
  printf '%s' "$h"
}

# bp_reporter_any_active -> rc 0 if ANY reporter session is registered, AFTER
# reaping expired markers.
#
# THE SAME BUG AS bp_drive_any_active's, one registry over, and not fixed when
# that one was. gate-drive-loop.sh does TTL-reap a reporter marker -- but only
# the marker matching the CURRENT session id, and a dead reporter never comes
# back to match its own. So reporter markers were immortal in exactly the way
# that function's header describes, and the pre-check above it did no reaping at
# all: it asked only "does any file exist".
#
# Measured on this host 2026-09-18: .reporter-active held a marker from
# 2026-09-13, five days old, alongside one from a session that ended the
# previous evening. Neither could ever be collected.
#
# The cost is the one the drive header already names. A single leaked marker
# keeps this true forever, so gate-drive-loop.sh skips its bp_drive_any_active
# early-exit on EVERY Stop of EVERY session on the machine, parsing a payload and
# spawning a JSON reader instead of returning after two stats. A registry that
# only grows is a slow reintroduction of the bug it replaced.
#
# Pure stat + rm, no subprocess, over a directory holding one entry per
# CONCURRENT reporter.
bp_reporter_any_active() {
  local dir now ttl mt f live=1
  dir=$(bp_reporter_active_dir) || return 1
  [ -d "$dir" ] || return 1

  now=$(date +%s 2>/dev/null || echo 0)
  ttl=$(bp_reporter_ttl_hours)

  # "${1:-}" not "$1": under `set -u` with nullglob an unmatched glob leaves $1
  # UNSET and the hook dies instead of reporting "nothing active". Same reasoning
  # as bp_drive_any_active, same trap.
  set -- "$dir"/*
  [ -e "${1:-}" ] || return 1

  live=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ "$now" -gt 0 ]; then
      mt=$(bp_mtime "$f")
      if [ "$mt" -gt 0 ] && [ $(( (now - mt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
    fi
    live=$((live + 1))
  done

  [ "$live" -gt 0 ] || return 1
  return 0
}

# bp_drive_any_active -> rc 0 if ANY driver session is registered.
# The cheap pre-check: when nothing is driving anywhere (the overwhelmingly
# common case) a hook can return before parsing its payload, so an unrelated
# session pays two stats and spawns nothing at all.
# bp_drive_ttl_hours -> the staleness limit, sanitised.
bp_drive_ttl_hours() {
  local h="${CCPRAXIS_DRIVE_TTL_H:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  [ "$h" -gt 0 ] 2>/dev/null || h=12
  printf '%s' "$h"
}

# bp_drive_any_active -> rc 0 if ANY driver session is registered, AFTER reaping
# expired markers.
#
# THE REAP HAS TO LIVE HERE, not in the per-session TTL check. That check only
# ever runs for the session whose id MATCHES a marker — and a dead driver never
# comes back to match its own, so its marker was immortal. Measured before this:
# three markers 55h old survived three consecutive stops by another session and
# were still there afterwards.
#
# It never hung anything (an unmatched marker is only read by the session that
# owns it), but it defeated the entire point of the design: one leaked marker
# keeps this function true forever, so every session on the machine goes on to
# parse its payload and spawn a JSON reader on every stop instead of returning
# after two stats. A registry that only grows is a slow reintroduction of the
# bug this replaced.
#
# Pure stat + rm, no subprocess, over a directory that holds one entry per
# CONCURRENT driver — single digits in the worst realistic case.
# bp_drive_session_transcript_mtime MARKER_PATH -> epoch mtime, or 0.
#
# A marker's BASENAME is the session id, and Claude Code writes that session's
# transcript to ~/.claude/projects/<slugged-project-path>/<session-id>.jsonl.
# The project slug is not derivable here without guessing, so this globs the
# project dirs for that exact filename -- one stat per project, and only on the
# path where a marker would otherwise be believed.
#
# Returns 0 ("unknown -- keep the marker") for anything uncertain: no HOME, no
# projects dir, no match. Never prints an error, never fails the caller.
bp_drive_session_transcript_mtime() {
  local marker="${1:-}" sid home base t best=0
  [ -n "$marker" ] || { printf '0'; return 0; }
  sid=$(basename "$marker" 2>/dev/null) || { printf '0'; return 0; }
  case "$sid" in ''|*/*|*.*) printf '0'; return 0 ;; esac
  home="${HOME:-${USERPROFILE:-}}"
  [ -n "$home" ] && [ -d "$home/.claude/projects" ] || { printf '0'; return 0; }
  for base in "$home"/.claude/projects/*/; do
    [ -f "$base$sid.jsonl" ] || continue
    t=$(bp_mtime "$base$sid.jsonl")
    if [ "${t:-0}" -gt "$best" ] 2>/dev/null; then best=$t; fi
  done
  printf '%s' "$best"
  return 0
}

bp_drive_any_active() {
  local dir now ttl mt tmt f live=1
  dir=$(bp_drive_active_dir) || return 1
  [ -d "$dir" ] || return 1

  now=$(date +%s 2>/dev/null || echo 0)
  ttl=$(bp_drive_ttl_hours)

  # Positional params are function-scoped in bash, so this cannot disturb the
  # calling hook. "${1:-}" rather than "$1": every hook runs under `set -u`,
  # and with nullglob enabled anywhere in the environment an unmatched glob
  # leaves $1 UNSET, which under set -u is a fatal "unbound variable" — the
  # hook would die instead of returning "nothing active". Verified: with
  # `shopt -s nullglob; set -u`, the bare "$1" form aborts.
  set -- "$dir"/*
  [ -e "${1:-}" ] || return 1

  live=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ "$now" -gt 0 ]; then
      mt=$(bp_mtime "$f")
      if [ "$mt" -gt 0 ] && [ $(( (now - mt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
      # A MARKER'S OWN MTIME IS ITS CREATION TIME -- nothing refreshes it
      # (grepped: no writer touches this directory after the marker is made). So
      # the rule above measures AGE SINCE THE DRIVE STARTED, not whether the
      # drive is alive, and it is wrong in both directions: a genuinely active
      # drive is reaped at the TTL, while a session that died ten minutes in pins
      # this predicate -- and every guard consulting it -- for the rest of it.
      #
      # Measured 2026-09-18: a marker for a session whose transcript had been
      # untouched for 9h45m, with zero drive processes anywhere, held this true.
      # That made guard-run-finish.sh refuse every stop and deadlocked it against
      # guard-subagent-stall.sh, whose own suggested remedy is the command
      # guard-run-finish was refusing. Same family as report 20260916-134204-3645,
      # which fixed the continuity side.
      #
      # THE SESSION TRANSCRIPT is the liveness signal the marker is not: Claude
      # Code appends to it every turn, so a live drive touches it constantly.
      # Reaping on a transcript older than the SAME ttl can only remove markers
      # for sessions silent that long; it cannot reap a live drive. Fails SAFE --
      # if the transcript cannot be located the marker is KEPT, because a guard
      # going inert during a real run is the failure markers exist to prevent.
      tmt=$(bp_drive_session_transcript_mtime "$f")
      if [ "${tmt:-0}" -gt 0 ] && [ $(( (now - tmt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
    fi
    live=$((live + 1))
  done

  [ "$live" -gt 0 ] || return 1
  return 0
}

# bp_drive_marker SESSION_ID -> echoes the marker path for that session.
# Session ids come from the hook payload, so refuse anything with a path
# separator or traversal in it rather than letting it address another directory.
bp_drive_marker() {
  local sid="${1:-}" dir
  [ -n "$sid" ] || return 1
  case "$sid" in
    */*|*\*|.|..|*..*) return 1 ;;
  esac
  dir=$(bp_drive_active_dir) || return 1
  printf '%s/%s' "$dir" "$sid"
  return 0
}

# ---------------------------------------------------------------------------
# 07-guards-reach-the-driver: bp_driver_context — the ONE definition of "a
# butler run is in progress, whoever is driving it, and what is its current
# package context". See specs/07-guards-reach-the-driver-spec.md §2.2 for the
# normative 15-step resolution order this mirrors exactly. No hook may
# re-implement any part of it (registry-path-one-rule.t exists because that
# duplication already happened here once).
#
# bp_driver_context [CWD] -> rc 0 with BP_DRIVER_SESSION / BP_DATA_DIR /
# BP_PROJECT_ROOT / BP_BLUEPRINT / BP_DIR / BP_PACKAGE / BP_WRITE_SET /
# BP_TEST_PATHS / BP_DRIVER_ROLE set as plain (never exported) shell globals;
# or rc 1 with every one of those globals left UNTOUCHED (no partial
# population -- a half-set BP_WRITE_SET would be a live landmine for any
# later reader). NEVER exits. NEVER writes to stdout or stderr. NEVER sets
# BP_LEDGER -- that would satisfy bp_hook_gate in any hook that later ran in
# the same process, exactly the widening done criterion 3 forbids.
#
# Mutually exclusive with bp_hook_gate BY CONSTRUCTION (step 1): a worker
# session (BP_LEDGER set) always rc 1s here, so no session can take both
# activation paths.
bp_driver_context() {
  local cwd="${1:-$PWD}"

  # 1. Worker sessions belong to bp_hook_gate.
  [ -z "${BP_LEDGER:-}" ] || return 1

  # 2. Session-wide escape hatch (env form).
  [ "${CCPRAXIS_DRIVER_GUARDS_OFF:-}" != "1" ] || return 1

  # 3. The cheap liveness pre-check -- already reaps stale markers and
  # consults the session transcript; not re-derived here.
  bp_drive_any_active 2>/dev/null || return 1

  # 4. Data dir (honours CCPRAXIS_DATA_DIR).
  local data_dir
  data_dir=$(bp_find_data_dir "$cwd" 2>/dev/null) || return 1
  [ -n "$data_dir" ] || return 1

  # 5. Project root, must be absolute.
  local project_root
  project_root=$(dirname "$data_dir" 2>/dev/null) || return 1
  bp_is_absolute_path "$project_root" || return 1

  # 6. File-form escape hatch, TTL-bounded (default 60 min), re-expressed as
  # a call to bp_hatch_active (11-parallel-tree-interlock SS2.3) -- the
  # single definition of this TTL rule, shared with the tree-wide guard's own
  # hatch. Externally observable behavior is unchanged: past-TTL is
  # best-effort removed and enforcement resumes; an age that cannot be
  # determined (clock or stat failure) is treated as within-TTL -- fail
  # toward the hatch staying honoured, never toward silently re-enforcing.
  # NOTE the inversion at this call site: bp_hatch_active's rc 0 means "the
  # hatch is active" (a fact), which for bp_driver_context means "guards are
  # off for this session" -> return 1 (not driving).
  local hatch="$data_dir/.drive-solo/.driver-guards-off"
  bp_hatch_active "$hatch" "${CCPRAXIS_DRIVER_GUARDS_OFF_TTL_MIN:-60}" && return 1

  # 7. The current-package pointer. Absent/unreadable -> rc 1. bp_json_get
  # returns rc 2 (no parser) -> rc 1 here too, which is the correct fail-open.
  local cj="$data_dir/.drive-solo/current.json"
  [ -f "$cj" ] || return 1
  local cj_content
  cj_content=$(cat "$cj" 2>/dev/null) || return 1
  local blueprint package jg_rc
  blueprint=$(bp_json_get "$cj_content" blueprint 2>/dev/null); jg_rc=$?
  [ "$jg_rc" -eq 0 ] || return 1
  package=$(bp_json_get "$cj_content" package 2>/dev/null); jg_rc=$?
  [ "$jg_rc" -eq 0 ] || return 1
  [ -n "$blueprint" ] && [ -n "$package" ] || return 1

  # 7b. Pointer-freshness TTL (redteam MAJOR-1, driver decision recorded in
  # the package ledger 2026-09-22: pointer-freshness over session-identity
  # narrowing, because narrowing depends on an unverified assumption about
  # whether a Task subagent's PreToolUse payload carries its parent driver's
  # session_id). The driver rewrites current.json on every run-package, and
  # this blueprint's own /butler:drive-solo dispatches routinely run
  # 30-50 minutes per worker -- CCPRAXIS_DRIVER_POINTER_STALE_MIN defaults to
  # 240 (4h), generously above that, so a legitimately long-running package
  # is never false-negatived. A pointer older than the TTL, or one whose
  # recorded_at is missing/non-numeric/in the future, cannot be proven fresh
  # -> treated exactly like an absent pointer (F1-equivalent): rc 1, inert.
  # This is the SAFE fail direction throughout this predicate: rc 1 means the
  # guard does not enforce a stale package's write set on an unrelated
  # session, never the reverse.
  local recorded_at p_ttl p_now p_age
  recorded_at=$(bp_json_get "$cj_content" recorded_at 2>/dev/null); jg_rc=$?
  [ "$jg_rc" -eq 0 ] || return 1
  case "$recorded_at" in ''|*[!0-9]*) return 1 ;; esac
  p_ttl="${CCPRAXIS_DRIVER_POINTER_STALE_MIN:-240}"
  case "$p_ttl" in ''|*[!0-9]*) p_ttl=240 ;; esac
  [ "$p_ttl" -gt 0 ] 2>/dev/null || p_ttl=240
  p_now=$(date +%s 2>/dev/null || echo 0)
  [ "$p_now" -gt 0 ] || return 1
  p_age=$(( (p_now - recorded_at) / 60 ))
  [ "$p_age" -ge 0 ] || return 1
  [ "$p_age" -lt "$p_ttl" ] || return 1

  # 8. Name validation, BEFORE either value touches a path: reject empty,
  # anything with '/', '\', a leading '.', '..' anywhere, or any character
  # outside [A-Za-z0-9._-]. A pointer file is data; it must not address
  # another directory.
  local _n
  for _n in "$blueprint" "$package"; do
    case "$_n" in
      ''|*/*|*\\*|.*|*..*) return 1 ;;
    esac
    case "$_n" in
      *[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done

  # 9. Blueprint dir + package ledger must exist.
  local bp_dir="$data_dir/blueprints/$blueprint"
  local ledger="$bp_dir/packages/$package.md"
  [ -d "$bp_dir" ] || return 1
  [ -f "$ledger" ] || return 1

  # 9b. redteam BLOCKER-2(e), defense-in-depth: $bp_dir may be reached via a
  # symlinked blueprints/<name> pointing outside <data>/blueprints/, which
  # would source write_set/test_paths from an attacker-controlled tree even
  # though name validation (step 8) rejected traversal BY NAME, not by
  # resolved target. Resolve the real path and require it stays a
  # prefix-child of $data_dir/blueprints/. Not reachable via the Edit/Write
  # tool surface this predicate governs (creating a symlink needs Bash,
  # already unconstrained by write-set containment per established
  # coordinator-protocol doctrine), so no blocking oracle test pins this --
  # defense in depth only.
  local bp_dir_real blueprints_real
  bp_dir_real=$(cd "$bp_dir" 2>/dev/null && pwd -P) || return 1
  blueprints_real=$(cd "$data_dir/blueprints" 2>/dev/null && pwd -P) || return 1
  case "$bp_dir_real" in
    "$blueprints_real"/*) ;;
    *) return 1 ;;
  esac

  # 10. Single-pass frontmatter read of $ledger, matching BpOrch::ledger_fm /
  # BpDrive::ledger_fm exactly: line 1 must be exactly '---' (trailing \r
  # tolerated); reading stops at the next '---' line or after 200 lines,
  # whichever comes first; a key matches ^<key>: with the value trimmed of
  # leading/trailing whitespace; first occurrence wins. No file is read
  # twice; no subprocess is spawned for this step.
  local status="" write_set="" test_paths=""
  local have_status=0 have_ws=0 have_tp=0
  local lineno=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    if [ "$lineno" -eq 1 ]; then
      [ "$line" = "---" ] || return 1
      continue
    fi
    [ "$line" = "---" ] && break
    [ "$lineno" -gt 200 ] && break
    case "$line" in
      status:*)
        if [ "$have_status" -eq 0 ]; then
          status="${line#status:}"
          status="${status#"${status%%[![:space:]]*}"}"
          status="${status%"${status##*[![:space:]]}"}"
          have_status=1
        fi
        ;;
      write_set:*)
        if [ "$have_ws" -eq 0 ]; then
          write_set="${line#write_set:}"
          write_set="${write_set#"${write_set%%[![:space:]]*}"}"
          write_set="${write_set%"${write_set##*[![:space:]]}"}"
          have_ws=1
        fi
        ;;
      test_paths:*)
        if [ "$have_tp" -eq 0 ]; then
          test_paths="${line#test_paths:}"
          test_paths="${test_paths#"${test_paths%%[![:space:]]*}"}"
          test_paths="${test_paths%"${test_paths##*[![:space:]]}"}"
          have_tp=1
        fi
        ;;
    esac
  done < "$ledger" 2>/dev/null

  # 11. status missing -> rc 1 (malformed). Terminal -> rc 1 (stale pointer).
  # Any other value (including unrecognised) -> continue.
  [ "$have_status" -eq 1 ] || return 1
  case "$status" in
    done|blocked|parked|dropped) return 1 ;;
  esac

  # 12. write_set missing or empty after trimming -> rc 1 (load-bearing, not
  # defensive: an empty BP_WRITE_SET would deny every write outside BP_DIR/tmp).
  [ "$have_ws" -eq 1 ] && [ -n "$write_set" ] || return 1

  # 13. test_paths missing -> "" (not an error; a package may have no oracle).

  # 14. BP_DRIVER_ROLE: read the existing solo marker. Absent/empty/unreadable/
  # unrecognised, or older than CCPRAXIS_SOLO_WORKER_STALE_MIN minutes (default
  # 180, sanitised) -> "" (the driver itself). Substring match, as
  # guard-validation-interlock.sh:110-113 does.
  local role="" marker="$data_dir/.drive-solo/.active-worker"
  if [ -f "$marker" ]; then
    local m_content m_stale m_now m_mt m_age m_fresh=1
    m_content=$(cat "$marker" 2>/dev/null)
    m_stale="${CCPRAXIS_SOLO_WORKER_STALE_MIN:-180}"
    case "$m_stale" in ''|*[!0-9]*) m_stale=180 ;; esac
    [ "$m_stale" -gt 0 ] 2>/dev/null || m_stale=180
    m_now=$(date +%s 2>/dev/null || echo 0)
    m_mt=$(bp_mtime "$marker")
    if [ "$m_now" -gt 0 ] && [ "$m_mt" -gt 0 ]; then
      m_age=$(( (m_now - m_mt) / 60 ))
      [ "$m_age" -ge "$m_stale" ] && m_fresh=0
    fi
    if [ "$m_fresh" -eq 1 ]; then
      case "$m_content" in
        *bp-implementer*) role="bp-implementer" ;;
        *bp-test-writer*) role="bp-test-writer" ;;
        *bp-ui-prober*)   role="bp-ui-prober" ;;
        *)                role="" ;;
      esac
    fi
  fi

  # 15. Set every global; rc 0.
  BP_DRIVER_SESSION=1
  BP_DATA_DIR="$data_dir"
  BP_PROJECT_ROOT="$project_root"
  BP_BLUEPRINT="$blueprint"
  BP_DIR="$bp_dir"
  BP_PACKAGE="$package"
  BP_WRITE_SET="$write_set"
  BP_TEST_PATHS="$test_paths"
  BP_DRIVER_ROLE="$role"
  return 0
}

# ---------------------------------------------------------------------------
# g01-explicit-continuity-arming: a THIRD, INDEPENDENT registry, sibling to
# .drive-solo-active/.reporter-active — explicit arm/disarm for a session
# doing unattended work with no blueprint, no drive-solo, no reporter. See
# specs/g01-explicit-continuity-arming-spec.md SS2.3.
# ---------------------------------------------------------------------------

# bp_continuity_active_dir -> echoes the machine-level registry of ARMED
# continuity sessions. One flat dir; primary markers named by session id,
# companions dot-suffixed (see bp_continuity_marker).
#
# ── THE SINGLE PATH-RESOLUTION RULE (fix-batch F1, spec SS2.6/AC-13) ────────
# Three components resolve this same registry path: this function (bash,
# gate-continuity.sh's caller), bp-continuity.pl's continuity_active_dir
# (perl, the arm/disarm/status CLI), and scripts/statusline.pl's own inline
# copy (perl, standalone, cannot require this file). They previously diverged
# on what "$HOME is unset" means (`$PWD`, `$USERPROFILE`, and `.`
# respectively) — three plausible-but-different guesses that could silently
# disagree about whether a session is watched, which is the worst possible
# failure for a feature whose entire point is "know that you are being
# watched". ALL THREE now follow this exact order and must not drift again:
#   1. CCPRAXIS_CONTINUITY_ACTIVE_DIR, if set and non-empty — wins outright.
#   2. else $HOME, if set and non-empty.
#   3. else $USERPROFILE (the Windows fallback), if set and non-empty.
#   4. else: NO resolvable directory. This function returns 1 with NOTHING
#      on stdout — it refuses to guess (no $PWD, no '.'). The two WRITE
#      paths (bp-continuity.pl arm/disarm/status) must fail LOUDLY on this
#      (STATUS: error, exit 1) rather than silently write/read a marker
#      under an unpredictable path. The two READ paths that must never hard
#      -fail a Stop/statusline (this function's callers in
#      bp_continuity_marker/bp_continuity_any_active, and
#      scripts/statusline.pl's badge) instead FAIL SAFE: "unresolvable"
#      means "treat as nothing armed" (gate never blocks; badge never shows
#      WATCHED). This is not a fourth divergent guess — it is consistent
#      with rule 4's write-side refusal: if the directory could never be
#      resolved, arm() could never have written a marker there either, so
#      there is never a live marker for these fail-safe reads to miss.
bp_continuity_active_dir() {
  # fixbatch step7 / FIX 1: see bp_drive_active_dir's identical comment.
  if [ -n "${CCPRAXIS_CONTINUITY_ACTIVE_DIR:-}" ]; then
    bp_is_absolute_path "$CCPRAXIS_CONTINUITY_ACTIVE_DIR" || return 1
    printf '%s' "$CCPRAXIS_CONTINUITY_ACTIVE_DIR"
    return 0
  fi
  bp_registry_root >/dev/null || return 1
  printf '%s' "$BP_REGISTRY_ROOT/.claude/ccpraxis/.continuity-active"
  return 0
}

# bp_continuity_ttl_hours -> the staleness limit, sanitised exactly like
# bp_drive_ttl_hours.
bp_continuity_ttl_hours() {
  local h="${CCPRAXIS_CONTINUITY_TTL_H:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  [ "$h" -gt 0 ] 2>/dev/null || h=12
  printf '%s' "$h"
}

# bp_continuity_marker SESSION_ID -> echoes the primary marker path.
# Refuses everything bp_drive_marker refuses, PLUS a literal '.' anywhere in
# the id — companions are dot-suffixed off the primary marker's own path, so
# a dotted session id would be indistinguishable from a companion file by
# bp_continuity_any_active's own basename-has-no-dot sweep discrimination.
# PLUS (fix-batch F3): a literal '\' anywhere in the id. On this project's
# Windows/Git-for-Windows host, both bash coreutils and this host's Perl
# treat '\' inside a path string as a directory separator, not a literal
# character — an id like 'evilsub\evilfile' resolves ONE LEVEL NESTED under
# the registry root, which bp_continuity_any_active's top-level-only `"$dir"/*`
# sweep never descends into: a marker placed that way would be PERMANENTLY
# INVISIBLE to the owner-independent reap, exactly the "arming is bounded"
# guarantee (done-criterion 2) this package exists to provide. Matches
# scripts/statusline.pl's own read-side sid check, which already excluded
# '\' for the same reason (red-team MEDIUM-1).
bp_continuity_marker() {
  local sid="${1:-}" dir
  [ -n "$sid" ] || return 1
  case "$sid" in
    */*|*\\*|*\**|.|..|*..*|*.*) return 1 ;;
  esac
  dir=$(bp_continuity_active_dir) || return 1
  printf '%s/%s' "$dir" "$sid"
  return 0
}

# bp_continuity_any_active -> rc 0 iff >=1 LIVE marker after reaping every
# expired primary marker (and its companions), INLINE, regardless of which
# session is doing the sweeping.
#
# THIS IS THE REAP POINT — owner-independent by construction. Mirrors
# bp_drive_any_active's own reasoning (lib.sh:395-412 above) for the identical
# historical defect: a per-session TTL check that only ever runs for the
# session whose id matches a marker leaves a dead session's marker immortal,
# because that session never returns to reap its own. Sweeping the WHOLE
# directory on every caller's behalf, unconditionally, is what closes it.
bp_continuity_any_active() {
  local dir now ttl mt f base live=1
  dir=$(bp_continuity_active_dir) || return 1
  [ -d "$dir" ] || return 1

  now=$(date +%s 2>/dev/null || echo 0)
  ttl=$(bp_continuity_ttl_hours)

  # See bp_drive_any_active's own comment on "${1:-}" under set -u + nullglob.
  set -- "$dir"/*
  [ -e "${1:-}" ] || return 1

  live=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in *.*) continue ;; esac   # companion file, not a primary marker
    if [ "$now" -gt 0 ]; then
      mt=$(bp_mtime "$f")
      if [ "$mt" -gt 0 ] && [ $(( (now - mt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" "$f.wakeup-pending" "$f.stop-blocks" "$f.stop-ok" 2>/dev/null
        continue
      fi
    fi
    live=$((live + 1))
  done

  [ "$live" -gt 0 ] || return 1
  return 0
}

# bp_outstanding_work RUN_LIVE -> echoes "<bp>/<pkg> (<status>)" lines, one per
# package that still represents work; echoes nothing when the work is finished.
#
# ONE RULE, TWO CALLERS. guard-run-finish.sh asks it whether ending a RUN would
# abandon anything; gate-continuity.sh asks it whether a turn may end at all.
# They used to compute this separately, and the day they disagreed the session
# was trapped: the work was finished, so stopping was the honest move, and the
# only two exits the continuity gate offered were "hold" (I am still working --
# false) and "disarm" (refused by the sibling guard on stale state). The session
# then burned one turn per hold expiry, about fifteen of them, waiting for a 12h
# TTL to elapse. Report 20260918-134732-acfd.
#
# Derived from LEDGERS ON DISK, never from anything the agent asserts, so it
# cannot be talked into a false "finished". Fails toward WORK EXISTS when it
# cannot tell -- a gate going quiet on ignorance is the failure it exists to
# prevent.
bp_outstanding_work() {
  local run_live="${1:-0}" OUTSTANDING=""
  command -v perl >/dev/null 2>&1 || { printf "unknown (no perl)"; return 0; }
  OUTSTANDING="$(perl -e '
    use strict; use warnings;
    my $root = shift @ARGV;
    my $run_live = shift(@ARGV) ? 1 : 0;
    my $dir  = "$root/.ccpraxis-local-data/blueprints";
    -d $dir or exit 0;
    opendir(my $dh, $dir) or exit 0;
    my @bps = grep { $_ !~ /^\.\.?$/ && $_ ne "_archive" && -d "$dir/$_" } readdir $dh;
    closedir $dh;
    my @open;
    for my $bp (@bps) {
        my $bpmd = "$dir/$bp/blueprint.md";
        if (-r $bpmd) {
            open my $b, "<", $bpmd or next;
            my $archived = 0;
            while (my $l = <$b>) {
                last if $. > 40;
                if ($l =~ /^status:\s*archived\b/) { $archived = 1; last }
            }
            close $b;
            next if $archived;
        }
        # A BLUEPRINT NOBODY HAS LAUNCHED HAS NOTHING IN FLIGHT.
        #
        # This scan used to count every `pending` package in every non-archived
        # blueprint, which made AUTHORING a blueprint permanently prevent
        # disarming: a drafted package sits at `pending` from birth and only
        # leaves it when someone drives it, so the more planning existed on disk
        # the more locked every session became, forever. Measured 2026-09-18 --
        # 43 packages across six blueprints reported as outstanding with no run
        # live, no coordinator dispatched, the bug queue empty and the suite
        # green. The session could not stop, and idling is not the safe side of
        # this guard: it abandons nothing but never ends.
        #
        # The question this guard actually wants answered is "would stopping
        # ABANDON work that is in flight", and a blueprint that has never been
        # launched cannot have any. Execution always leaves a trace under runs/:
        # bp-launch.sh writes registry.json on every launch, the orchestrator
        # holds a .orchestrator marker while alive, and a coordinator writes its
        # own <pkg>.jsonl transcript. Requiring ANY of the three is deliberately
        # generous -- a false "launched" only costs the old behaviour, while a
        # false "never launched" is the failure this guard exists to prevent.
        # ONLY WHEN NO RUN IS LIVE. If a drive is active right now, every pending
        # package is potentially its next step and the old behaviour is correct
        # -- a drive-solo run does not necessarily write registry.json, so
        # requiring launch evidence would let a LIVE run be stopped. That hole
        # was caught by the oracle for this hook, run-finish-guard.t case A1,
        # whose fixture pairs a live drive marker with a blueprint that has no
        # runs/ dir -- after a first version of this filter applied always.
        unless ($run_live) {
            my $runs = "$dir/$bp/runs";
            my $launched = 0;
            if (-d $runs) {
                # A REGISTRY IS NOT A LAUNCH; A LAUNCHED ROW IS.
                #
                # `-e registry.json` was too weak. bp-answer-decision.pl creates
                # that file to record a package RESET, so a blueprint nobody has
                # ever run acquires one the moment somebody repairs a stale
                # status. Measured 2026-09-18: resetting one package in a parked,
                # never-driven blueprint wrote
                #   {"packages":{"03-store":{"attempt":0,"session_id":null,
                #                            "status":"pending"}}}
                # and that alone made all 17 of its pending packages count as
                # work in flight, blocking every stop in an unrelated session.
                # attempt 0 with a null session id is the file SAYING it never
                # ran; reading it as a launch inverts its own evidence.
                #
                # So: a row must carry a real attempt or a real session id. The
                # orchestrator marker and a coordinator transcript are unchanged
                # -- both are produced only by execution.
                $launched = 1 if -e "$runs/.orchestrator";
                if (!$launched && -f "$runs/registry.json") {
                    my $raw = do {
                        local $/;
                        if (open my $rh, "<", "$runs/registry.json") { my $c = <$rh>; close $rh; $c } else { undef }
                    };
                    if (defined $raw) {
                        my $doc = eval { require JSON::PP; JSON::PP->new->decode($raw) };
                        my $pk  = (ref $doc eq "HASH") ? $doc->{packages} : undef;
                        if (ref $pk eq "HASH") {
                            for my $row (values %$pk) {
                                next unless ref $row eq "HASH";
                                my $a = $row->{attempt};
                                if (defined $a && !ref $a && $a =~ /\A\d+\z/ && $a > 0) { $launched = 1; last }
                                my $s = $row->{session_id};
                                if (defined $s && !ref $s && $s =~ /\S/)               { $launched = 1; last }
                            }
                        }
                        # Undecodable registry: cannot tell, so assume launched.
                        $launched = 1 unless defined $doc;
                    }
                }
                unless ($launched) {
                    if (opendir(my $rd, $runs)) {
                        $launched = 1 if grep { /\.jsonl$/ } readdir $rd;
                        closedir $rd;
                    }
                }
            }
            next unless $launched;
        }

        my $pdir = "$dir/$bp/packages";
        -d $pdir or next;
        opendir(my $pd, $pdir) or next;
        my @l = grep { /\.md$/ } readdir $pd;
        closedir $pd;
        for my $f (sort @l) {
            open my $h, "<", "$pdir/$f" or next;
            my $st = "";
            while (my $l = <$h>) {
                last if $. > 30;
                if ($l =~ /^status:\s*(\S+)/) { $st = lc $1; last }
            }
            close $h;
            next unless $st eq "pending" || $st eq "running";
            push @open, "$bp/" . ($f =~ s/\.md$//r) . " ($st)";
        }
    }
    print join("\n", @open), "\n" if @open;
    exit 0;
  ' "${BP_PROJECT_ROOT:-$PWD}" "$run_live" 2>/dev/null)" || OUTSTANDING=""
  printf "%s" "${OUTSTANDING:-}"
  return 0
}
