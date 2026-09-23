#!/usr/bin/env bash
# guard-git-mutations.sh — PreToolUse hook denying git working-tree mutations
# in ANY session, including manually-driven Task subagents.
#
# WHY THIS EXISTS SEPARATELY FROM guard-bash.sh
#
# guard-bash.sh already denies exactly these commands — and it did not fire,
# three times in one session, because lib.sh's bp_hook_gate() exits 0 (allow)
# unless BP_LEDGER, BP_DIR and BP_PROJECT_ROOT are all set. Those are exported
# by bp-launch.sh, so guard-bash.sh only enforces inside a butler-LAUNCHED
# coordinator session.
#
# A manual drive dispatches workers with the Agent/Task tool instead. Those
# subagents inherit none of the BP_* contract, so the gate opened and the
# prohibition survived only as text in the dispatch prompt. It was violated
# three times, and at least once it cost real work: the b25 fix-batch
# (R8-R11, R13, R18) was written, swept into a stash by a prohibited
# `git stash`, never restored, and never committed — while the ledger recorded
# step 7 as complete. A written instruction is not an enforcement mechanism.
#
# So this hook deliberately has NO bp_hook_gate: it applies everywhere.
#
# SCOPE. Only working-tree/history mutations that can DESTROY uncommitted work.
# Read-only git is untouched, because agents legitimately need it to inspect
# their own diffs — and pushing them toward `git stash` to "see what changed"
# is part of how this happened.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate here, by design (see above).
source "$HOOK_DIR/lib.sh"
# shellcheck source=../scripts/bp-lib.sh
# Sourced ONLY for bp_strip_shell_noise, used by the new heredoc-only branch
# of git_scan_target below (t09). Conditional/tolerant, like mark-wakeup.sh's
# own sourcing of this same file -- if unreadable, the branch degrades to
# TODAY's raw-fallback behavior (AC17), never to unconditional allow.
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

# --only-during-butler-run: THE PLUGIN-WIDE REGISTRATION IS SCOPED. THE
# ccpraxis ONE IS NOT.
#
# This guard has to reach two different populations, and they want different
# answers.
#
#   * ccpraxis's own .claude/settings.json registers it BARE. That is where the
#     original incident happened and the protection there is unconditional, as
#     the header above argues. Unchanged.
#
#   * The plugin's hooks.json registers it WITH THIS FLAG. hooks.json travels to
#     every project on the machine, and hooks-json-route-registration.t's AC7
#     deferred that registration for a reason worth respecting: registering it
#     bare would apply it to EVERY session on this machine, butler-related or
#     not, and confiscate `git st`+`ash` from the operator's own ordinary work
#     in unrelated projects. That is not a side effect anyone signed up for.
#
# So the travelling registration fires only while a butler run is actually in
# progress. Crucially the predicate is bp_drive_any_active -- a FILESYSTEM check,
# not an environment one -- so it still covers the case the guard exists for: a
# Task subagent dispatched by a drive-solo driver inherits none of the BP_*
# contract, but it can see the same marker directory. BP_LEDGER is accepted too,
# for butler-launched workers.
#
# Without this flag nothing changes, so the ccpraxis registration and every
# existing direct invocation behave exactly as before.
BP_RUN_SCOPED=0
for _arg in "$@"; do
  [ "$_arg" = "--only-during-butler-run" ] && BP_RUN_SCOPED=1
done
if [ "$BP_RUN_SCOPED" = "1" ]; then
  if [ -z "${BP_LEDGER:-}" ]; then
    bp_drive_any_active || exit 0
  fi
fi

bp_read_payload closed

# See lib.sh:bp_json_get. This used to hard-require jq, which the Windows host
# does not have and -- per this repo's Perl-only doctrine -- is never going to
# get. The result was that it blocked EVERY Bash call on the host instead of
# guarding anything. Only the absence of BOTH parsers still fails closed.
CMD=$(bp_json_get "$PAYLOAD" tool_input.command) || {
  echo "guard-git-mutations: BLOCKED -- no JSON parser available (neither jq nor perl+JSON::PP); blocking to avoid unenforced operation." >&2
  exit 2
}
[ -n "$CMD" ] || exit 0

deny() { echo "BLOCKED: $1 Command: $CMD" >&2; exit 2; }

# a02 defect 6 (spec §2.7): the two mutation regexes below used to grep the WHOLE
# raw command string, so prose that merely QUOTES/mentions a prohibited command
# (e.g. a --text argument) was blocked exactly like a real invocation. Both
# regexes are kept byte-identical below in what they look for; what changed is
# the STRING they scan -- a quote-masked copy of CMD, with the CONTENTS of
# quoted spans replaced by 'X' (quote characters themselves retained, length
# preserved). Both deny() messages and the printed "Command: $CMD" always show
# the RAW command -- the operator must see what they actually typed.
MASK_MAX=8192

# git_scan_target — echoes the string the mutation regexes must scan: CMD with
# quoted-span CONTENTS masked to 'X', or CMD UNCHANGED whenever masking would be
# unsafe (see the four raw-fallback conditions below). Single left-to-right pass,
# three-state machine (NONE/SINGLE/DOUBLE). Every failure mode of this walk
# degrades to the RAW string, never to "treat as allowed" -- a bug here must
# fail the way today's hook already does, not open a new hole.

# RAW_KIND — set by git_scan_target to record WHY it returned raw (or that it
# didn't). step-6 red-team MINOR-7: the anchor class was widened (below) to
# reach quoted invocations like `bash -c "git stash"` / `` `git stash` `` /
# `$(git reset --hard)`, all of which land on a RAW-fallback path -- but
# applying that widened class to EVERY raw fallback also matches a merely
# QUOTED MENTION whenever the SAME command independently trips an unrelated
# fallback (e.g. an unquoted `$(date +%s)` elsewhere forces the carrier
# fallback for the whole string, and the widened class then matches
# `'git reset --hard'` inside a `--text` argument that never runs as code).
# The widened class is only ever actually NEEDED for two of the five
# fallback reasons -- see the RAW_KIND-keyed anchor selection below.
RAW_KIND=masked

git_scan_target() {
  local cmd="$CMD"
  local len=${#cmd}
  # 1. Over-long command: raw fallback without even walking it.
  if [ "$len" -gt "$MASK_MAX" ]; then
    RAW_KIND=toolong
    SCAN_OUT="$cmd"
    return 0
  fi
  # 0. A backslash, a '#', or a heredoc marker ('<<') ANYWHERE in the command:
  #    raw fallback, EXCEPT for the two narrowly-characterised shapes named
  #    under "WHAT IS NARROWED" below.
  #
  # The three-state walk below models bash QUOTING only. It has no notion of
  # three other contexts where bash does NOT treat a quote character as a
  # delimiter, and all three were demonstrated (step-6 reviewer B1, red-team
  # BLOCKER-1) to silently mask a REAL, executable, unquoted mutation as
  # "allowed":
  #   - backslash escapes (`\"`, `\'`, and ANSI-C `$'...'` bodies) can flip the
  #     walk's quote-parity so a later escaped quote "re-balances" a span that
  #     was never actually open/closed the way the walk believes;
  #   - `#` starts a bash COMMENT (to end-of-line), where an apostrophe is
  #     just a literal character, not a quote delimiter -- the walk has no
  #     comment state at all, so `# don't ... # that's` toggles SINGLE->NONE
  #     around a genuinely unquoted, in-between command;
  #   - a heredoc body (`<<EOF ... EOF`) is verbatim text, not shell syntax --
  #     an apostrophe inside it (`it's fine`) is just a character, but the
  #     walk still toggles SINGLE on it, and a second apostrophe in a later
  #     heredoc body can "re-balance" the parity around a genuinely unquoted
  #     mutation sitting between the two heredocs.
  # Rather than add ESCAPE/COMMENT/HEREDOC sub-states to the walk (more
  # surface to get subtly wrong a second time), take the same raw-fallback
  # degrade the other three failure modes already use. This can only make the
  # scan MORE conservative (raw string still gets the anchor regexes applied
  # to it), so it cannot turn any existing DENY into an ALLOW, and per
  # N1/MINOR-7 in the step-6 reports, degrading to raw is the documented
  # "fails toward deny" direction -- never a security concern, only a
  # possible extra false positive on prose that itself contains a literal
  # backslash, '#', or '<<'.
  # t09 (guard-hooks-stripping). THREAT MODEL: ACCIDENT, not ADVERSARY -- the
  # same ruling already on record for this hook family (see
  # guard-validation-interlock.sh's header, and mark-wakeup.sh's own
  # bp_strip_shell_noise consumption); not re-derived here because nothing
  # about it is in tension. Nothing in this branch needs to survive a
  # deliberate bypass attempt, only ordinary prose/quoting/heredoc accidents
  # -- the confirmed live incident (a heredoc report body that merely NAMES
  # "git stash"/"git reset --hard" in prose, with no git invocation anywhere
  # in the command) is exactly that shape. A false positive (blocking
  # legitimate report-writing) is THIS hook's real defect to fix; a false
  # negative (a real mutation slipping through) must not be introduced --
  # hence the carrier/shellword re-check below, the comment-neutrality
  # check in the heredoc branch, and the backslash branch admitting nothing
  # but line continuations.
  #
  # WHAT IS NARROWED (bug 20260916-200412-3dd6, package 09) AND WHAT IS NOT.
  #
  # Two shapes no longer force the raw fallback. Each is admitted ONLY into a
  # path that already models the context that shape lives in; neither makes
  # the three-state walk any smarter, because that is what three earlier
  # attempts did and each one introduced a false negative.
  #
  #   N1. EVERY backslash in the command is a LINE CONTINUATION (immediately
  #       followed by a newline), and there is no '#' and no '<<'. Admitted to
  #       the walk. A backslash escapes the character after it, and a NEWLINE
  #       is never a quote delimiter, so it cannot flip the walk's quote
  #       parity -- which is the whole of failure mode 1 above. Every
  #       demonstrated escape shape (\" , \' , $'...') puts a backslash before
  #       a QUOTE, fails this predicate, and still takes the raw fallback.
  #       Note the size of the change: with no quoted span in the command the
  #       walk's output is byte-identical to the raw string, so the ONLY
  #       delta is that quoted spans are masked -- exactly as they already
  #       are for a backslash-free command.
  #
  #   N2. The command contains a '#' AND a heredoc marker, and EVERY heredoc
  #       delimiter is quoted. Admitted to the heredoc branch below -- never
  #       to the walk, which still has no comment state and still never sees
  #       a '#', so failure mode 2 stays structurally unreachable. Two guards
  #       bound it. Quoted delimiters only, because bash EXPANDS an unquoted
  #       heredoc body, so a $(...) in it executes and blanking the body
  #       would hide live code. And a COMMENT-NEUTRALITY check: the stripper
  #       models bash comments, but its comment state eats the newline that
  #       would have started a heredoc body, parsing the body late and, in a
  #       constructible shape, blanking a REAL trailing mutation. So strip
  #       twice -- as given, and with every '#' neutralised -- and require
  #       both to blank the same positions. If they agree, the inert/live
  #       partition is the one the already-accepted '#'-free path produces.
  #
  # RESIDUAL LEFT UNFIXED, KNOWINGLY, after that narrowing:
  #   - a backslash that is NOT a line continuation still forces the fully-raw
  #     scan anywhere it appears, so prose carrying a Windows path or an
  #     escaped quote can still be blocked for merely NAMING a forbidden verb;
  #   - a '#' in a command with no heredoc still forces it, unchanged;
  #   - a heredoc command that also contains a REAL bash comment fails the
  #     comment-neutrality check and takes the raw fallback, WHENEVER the
  #     stripper's heredoc parse agrees with bash's own (G2 is a relative
  #     check: it proves the '#' changed nothing RELATIVE TO the '#'-free
  #     parse, not that the '#'-free parse itself is correct);
  #   - an unquoted heredoc delimiter plus a '#' still forces it;
  #   - a line continuation sitting BETWEEN 'git' and its subcommand
  #     (git \<newline>stash) is not matched by the anchor regexes at the
  #     bottom of this file, and is ALLOWED. That is UNCHANGED by this
  #     package -- the pre-existing raw scan did not match it either -- and it
  #     sits inside the ACCIDENT threat model recorded above: it is not a
  #     shape ordinary prose or ordinary quoting produces by accident.
  local has_bs=0 has_hash=0 has_hd=0 bs_probe hd_alt
  case "$cmd" in *'\'*)  has_bs=1   ;; esac
  case "$cmd" in *'#'*)  has_hash=1 ;; esac
  case "$cmd" in *'<<'*) has_hd=1   ;; esac

  if [ "$has_bs" = 1 ]; then
    # N1. A backslash is admitted to the walk ONLY when every one of them is a
    # line continuation, and only when nothing else on this list is present.
    if [ "$has_hash" = 1 ] || [ "$has_hd" = 1 ]; then
      RAW_KIND=escape; SCAN_OUT="$cmd"; return 0
    fi
    bs_probe=${cmd//\\$'\n'/}          # delete every backslash+newline PAIR
    case "$bs_probe" in
      *'\'*) RAW_KIND=escape; SCAN_OUT="$cmd"; return 0 ;;
    esac
    # every backslash is a line continuation -> fall through to the walk
  elif [ "$has_hash" = 1 ]; then
    # N2. A '#' is admitted ONLY to the heredoc branch below, never to the walk.
    if [ "$has_hd" != 1 ]; then
      RAW_KIND=escape; SCAN_OUT="$cmd"; return 0
    fi
    # G1: every heredoc delimiter must be QUOTED. With an unquoted delimiter
    # bash expands the body, so blanking it would hide live code.
    if printf '%s' "$cmd" | grep -Eq "<<-?[[:space:]]*([^'\"]|$)"; then
      RAW_KIND=escape; SCAN_OUT="$cmd"; return 0
    fi
    # falls through to the heredoc branch, which carries G2 (2.4)
  fi

  # Heredoc marker present, and NEITHER a backslash NOR a '#' (those stay on
  # the raw fallback above, untouched): this is the ONE case
  # bp_strip_shell_noise already handles and git_scan_target's own three-
  # state walk cannot (no comment/heredoc state at all -- see the header
  # above). Reuse bp_strip_shell_noise UNMODIFIED; do not re-derive heredoc
  # parsing here (ledger criterion 2: one stripping implementation).
  case "$cmd" in
    *'<<'*)
      # TRUST THE STRIP ONLY WHERE THE STRIPPER'S HEREDOC PARSE CAN KEEP UP.
      #
      # Added after this package's own red-team found, and the driver confirmed
      # by running the PRE- and POST-change hooks side by side, that two
      # ordinary shapes desync bp_strip_shell_noise's terminator matching. In
      # both, it runs past the terminator, blanks the REST of the command --
      # including a real trailing mutation -- and returns something that looks
      # clean, so this branch allowed a command that the pre-change hook denied:
      #
      #   cat > f <<'EOF!' ... EOF!   <newline>   <a real mutation>
      #   the same command with CRLF line endings
      #
      # That is a false NEGATIVE in a guard that exists because a prohibited
      # history-discarding command once destroyed a completed fix-batch here.
      # Escalating instead costs a false POSITIVE, which is this hook's
      # acceptable failure and merely restores the behaviour that shipped
      # before the heredoc branch existed.
      #
      # Deliberately NOT fixed by teaching bp_strip_shell_noise more bash: it
      # is shared with other callers, and widening a parser to close a guard
      # hole is how the next hole gets opened. Detect what it cannot model and
      # decline to trust it there.
      #
      # `<<-` also escalates. The predicate below cannot distinguish the `-` of
      # a tab-stripping heredoc from punctuation in a delimiter, and the
      # red-team flagged `<<-` as an untested shape in its own right -- so it
      # takes the safe path rather than the clever one.
      case "$cmd" in
        *$'\r'*)
          RAW_KIND=escape
          SCAN_OUT="$cmd"
          return 0
          ;;
      esac
      if printf '%s' "$cmd" | grep -Eq "<<-?[[:space:]]*([^A-Za-z0-9_'\"[:space:]]|'[A-Za-z0-9_]*[^A-Za-z0-9_']|\"[A-Za-z0-9_]*[^A-Za-z0-9_\"]|[A-Za-z0-9_]*[^A-Za-z0-9_'\"[:space:]])"; then
        RAW_KIND=escape
        SCAN_OUT="$cmd"
        return 0
      fi
      HD_STRIPPED=""
      if command -v bp_strip_shell_noise >/dev/null 2>&1; then
        HD_STRIPPED=$(printf '%s' "$cmd" | bp_strip_shell_noise)
      fi
      if [ -z "$HD_STRIPPED" ]; then
        # perl / scripts/bp-lib.sh unavailable, or stripping produced empty
        # output: fall back to TODAY's behavior exactly. Never treat "could
        # not strip" as "no heredoc" -- that would silently narrow the scan.
        RAW_KIND=escape
        SCAN_OUT="$cmd"
        return 0
      fi
      if [ "$has_hash" = 1 ]; then
        # A '#' can desync the stripper's heredoc tracking: its comment state
        # consumes the newline that would have started the body (bp-lib.sh:252
        # vs :295), so the body is parsed late and a real trailing mutation can
        # be blanked. Strip twice -- as given, and with every '#' neutralised --
        # and require the two results to blank exactly the same positions. If a
        # '#' changed what the stripper treats as inert, take the raw fallback.
        hd_alt=$(printf '%s' "${cmd//'#'/q}" | bp_strip_shell_noise)
        if [ -z "$hd_alt" ] \
           || [ "${HD_STRIPPED//[! ]/x}" != "${hd_alt//[! ]/x}" ]; then
          RAW_KIND=escape; SCAN_OUT="$cmd"; return 0
        fi
      fi
      # Re-run git_scan_target's OWN carrier / shellword checks -- unmodified
      # regex text, new input -- before trusting the stripped text. Both must
      # still escalate to fully raw, exactly as the main walk already does
      # for these two cases below. bp_strip_shell_noise leaves a bare or
      # double-quoted $(...)/backtick verbatim in its output (it must -- both
      # genuinely execute), so a heredoc-triggered command that ALSO contains
      # an unquoted carrier or a `bash -c "..."` wrapper outside the heredoc
      # must still escalate, exactly as the un-heredoc'd walk already does.
      if printf '%s' "$HD_STRIPPED" | grep -Eq '`|\$\('; then
        RAW_KIND=carrier
        SCAN_OUT="$cmd"
        return 0
      fi
      if printf '%s' "$HD_STRIPPED" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)|(^|[;&|[:space:]])(perl|ruby|node)[[:space:]]+-e([[:space:]]|$)|(^|[;&|[:space:]])(python|python3)[[:space:]]+-c([[:space:]]|$)'; then
        RAW_KIND=shellword
        SCAN_OUT="$cmd"
        return 0
      fi
      RAW_KIND=heredoc
      SCAN_OUT="$HD_STRIPPED"
      return 0
      ;;
  esac

  # almanac 20260918-234106-0377: a quoted single-word span used to be
  # X-masked UNCONDITIONALLY, same as any multi-word (prose) span. Bash makes
  # an unquoted verb and its single-quoted/double-quoted equivalent
  # byte-identical argv entries once parsed (`git stash`, `git 'stash'` and
  # `'git' stash` all run the same command) -- so a quoted "git" or a quoted
  # subcommand walked to a masked scan string that could never match
  # STASH_RE/MUT_RE below, silently bypassing this guard. Mirrors the fix
  # already applied to guard-run-finish.sh's identical masking technique:
  # a quoted span's CONTENTS are buffered (qbuf) as the walk goes, and only
  # unmasked to their literal text (instead of X-masked) when BOTH (a) the
  # span has no internal whitespace -- a single word, hence byte-identical
  # whether quoted or not -- and (b) it sits in a position immediately after
  # an unquoted "git" token, i.e. verb-adjacent, checked against the
  # unquoted-so-far $out at the moment the quote OPENS. That positional
  # constraint mirrors the sibling hook's own red-team-driven fix (its
  # Finding A): without it, a single-word quoted span ANYWHERE (e.g. inside
  # a legitimate `--text "off"`-shaped argument) would unmask and could
  # false-positive. Anything else -- a quoted word after a flag, or multi-
  # word prose -- stays X-masked exactly as before.
  local state=NONE   # NONE | SINGLE | DOUBLE
  local carrier=0
  local out="" c next
  local qbuf="" qhaswhite=0 qadjacent=0
  local adj_re='(^|[;&|[:space:]({])git[[:space:]]+$'
  local i=0
  while [ "$i" -lt "$len" ]; do
    c=${cmd:$i:1}
    case "$state" in
      NONE)
        case "$c" in
          "'")
            state=SINGLE; qbuf=""; qhaswhite=0
            [[ "$out" =~ $adj_re ]] && qadjacent=1 || qadjacent=0
            ;;
          '"')
            state=DOUBLE; qbuf=""; qhaswhite=0
            [[ "$out" =~ $adj_re ]] && qadjacent=1 || qadjacent=0
            ;;
          '`') carrier=1; out+='`' ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+='$' ;;
          *) out+="$c" ;;
        esac ;;
      SINGLE)
        case "$c" in
          "'")
            state=NONE
            if [ "$qhaswhite" -eq 0 ] && [ "$qadjacent" -eq 1 ]; then
              out+="$qbuf"
            else
              out+="'"; out+="${qbuf//?/X}"; out+="'"
            fi
            ;;
          ' '|$'\t'|$'\n') qhaswhite=1; qbuf+="$c" ;;
          *) qbuf+="$c" ;;
        esac ;;
      DOUBLE)
        case "$c" in
          '"')
            state=NONE
            if [ "$qhaswhite" -eq 0 ] && [ "$qadjacent" -eq 1 ]; then
              out+="$qbuf"
            else
              out+='"'; out+="${qbuf//?/X}"; out+='"'
            fi
            ;;
          '`') carrier=1; qbuf+="$c" ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            qbuf+="$c" ;;
          ' '|$'\t'|$'\n') qhaswhite=1; qbuf+="$c" ;;
          *) qbuf+="$c" ;;
        esac ;;
    esac
    i=$((i+1))
  done

  # 2. Unbalanced quoting (walk never returned to NONE): raw fallback.
  if [ "$state" != "NONE" ]; then
    RAW_KIND=unbalanced
    SCAN_OUT="$cmd"
    return 0
  fi
  # 3. An unquoted backtick or $( anywhere in NONE/DOUBLE: the shell would
  #    evaluate the enclosed text as CODE, so it is not a mere "mention" --
  #    raw fallback so the carried text is still scanned.
  if [ "$carrier" -eq 1 ]; then
    RAW_KIND=carrier
    SCAN_OUT="$cmd"
    return 0
  fi
  # 4. A shell/eval/xargs in command position (checked on the MASKED string,
  #    precisely so the same words appearing INSIDE someone's quoted prose do
  #    not trigger this): it re-interprets its own quoted argument as code, so
  #    e.g. `bash -c "git stash"` must still be denied. Raw fallback.
  if printf '%s' "${out//\\$'\n'/}" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)|(^|[;&|[:space:]])(perl|ruby|node)[[:space:]]+-e([[:space:]]|$)|(^|[;&|[:space:]])(python|python3)[[:space:]]+-c([[:space:]]|$)'; then
    RAW_KIND=shellword
    SCAN_OUT="$cmd"
    return 0
  fi

  SCAN_OUT="$out"
}

# NOTE: called WITHOUT command substitution -- $(...) would run
# git_scan_target in a SUBSHELL, silently discarding its RAW_KIND assignment
# (and any other global it sets) once the subshell exits. It communicates its
# result via the global SCAN_OUT instead, precisely so RAW_KIND survives into
# the anchor-selection logic below.
SCAN_OUT=
git_scan_target
SCAN=$SCAN_OUT

# Anchor widened (a02 driver-verified bypass, beyond the scout's original seven):
# a quoted invocation of a prohibited verb -- e.g. `bash -c "git stash"` or
# `` `git stash` `` or `$(git reset --hard)` -- lands on the RAW-fallback path
# above with the preceding character being a quote/backtick/paren, none of
# which the original anchor `(^|[;&|[:space:]])` recognised as a boundary.
#
# step-6 red-team MINOR-7: applying the FULL widened class (quotes included)
# to every raw fallback also matches a merely QUOTED MENTION of a prohibited
# verb whenever the command independently trips an UNRELATED fallback (e.g.
# an unquoted `$(date +%s)` elsewhere forces fallback 3 for the whole
# string, and the quote-inclusive class then matches `'git reset --hard'`
# inside an unrelated `--text` argument that never runs as code). Only two of
# the five fallback reasons actually NEED the widened class:
#   - carrier (fallback 3, an unquoted backtick/`$(` somewhere): the verb can
#     sit immediately after that backtick/`(`, e.g. `` echo `git stash` `` --
#     needs backtick+`(` as boundary chars, but NOT quotes (a quote here is
#     never itself the reason the shell will execute the enclosed text).
#   - shellword (fallback 4, `bash`/`sh`/... in command position): the verb
#     can sit inside the shell's OWN quoted argument, e.g.
#     `bash -c "git stash"` -- needs quotes+backtick+`(` since the shell
#     re-interprets whatever it's quoted with as code.
# Every other reason (masked/toolong/escape/unbalanced) keeps the ORIGINAL
# narrow anchor: none of t/106's real-mutation fixtures for those paths sit
# immediately after a quote/backtick/paren (they follow a space/`;`/newline/
# start, already matched), so narrowing there costs no existing DENY while
# closing the false-positive class above.
# `(` and `{` are in the BASE class, not only the widened ones. almanac
# 20260819-164901-52d3, verified by running this hook: `(git stash push -m wip)`
# and `x=1; {git stash push -m wip; }` were both ALLOWED. A subshell or brace
# group opens a COMMAND POSITION -- the verb immediately after it runs, exactly
# as it would after a `;` -- so their absence here was a false NEGATIVE, which is
# the dangerous direction for a guard: a prohibited command executed.
#
# This does not reintroduce MINOR-7's false-positive class, and the distinction
# is the reason the widened classes stay separate. That class was about QUOTES:
# a quote is never itself a reason the shell will execute what it encloses, so
# treating it as a boundary makes a quoted MENTION look like an invocation. `(`
# and `{` are the opposite -- they mean "a command starts here" and nothing
# else. And this class is applied to the STRIPPED scan target, where quoted
# spans are already blanked, so a `(` inside prose cannot reach it.
case "$RAW_KIND" in
  shellword) ANCHOR_CLASS='[;&|[:space:]'\''"`({]' ;;
  carrier)   ANCHOR_CLASS='[;&|[:space:]`({]' ;;
  *)         ANCHOR_CLASS='[;&|[:space:]({]' ;;
esac
STASH_RE="(^|${ANCHOR_CLASS})git[[:space:]]+stash\\b"
STASH_RO_RE='git[[:space:]]+stash[[:space:]]+(list|show)\b'
MUT_RE="(^|${ANCHOR_CLASS})git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean)\\b"

# stash: list/show are read-only and explicitly allowed.
if grep -Eq "$STASH_RE" <<<"$SCAN" && \
   ! grep -Eq "$STASH_RO_RE" <<<"$SCAN"; then
  deny "git stash is forbidden: it silently removes uncommitted work from the tree and has already cost a completed fix-batch in this repo. To inspect your own changes use 'git diff' (read-only). 'git stash list' and 'git stash show' are allowed."
fi

# checkout/switch/restore/reset/clean: overwrite or delete uncommitted work.
# `git checkout -b` / `git switch -c` create a branch without touching content,
# but are still orchestrator-only here, so they are denied with the rest.
if grep -Eq "$MUT_RE" <<<"$SCAN"; then
  deny "git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work. Change files only via Edit/Write. Use 'git diff' or 'git status' to inspect state."
fi

exit 0
