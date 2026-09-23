# Claude Code harness facts

## Summary

| item | status | one-line answer | Claude Code version |
|---|---|---|---|
| (a) payload fields | ANSWERED | PreToolUse/PostToolUse/Stop field sets captured for parent and subagent context; `tool_use_id` and `agent_id`/`agent_type` present on tool events, `stop_hook_active` present on Stop, absent elsewhere observed | 2.1.280 |
| (b) subagent vs parent session_id | ANSWERED | A subagent's own tool-call payloads carry the **same** `session_id` as the parent, matching the stream-json init id and the subagent transcript's `sessionId` | 2.1.280 |
| (c) meta.json at subagent's first PreToolUse | ANSWERED | Present, not racy, for one auto-backgrounded (`requestShape: background`) dispatch in headless -p: `agent-<id>.meta.json` and `agent-<id>.jsonl` already existed (created at Agent-tool dispatch) roughly 3.4 s before the subagent's own first PreToolUse. A foreground (synchronous) dispatch was not measured | 2.1.280 |
| (d) session ids across --resume, /compact, /clear, carry-over | PARTIAL -- see NEEDS-OPERATOR D-1, D-2, D-3 | `--resume` keeps the id (ANSWERED); `/compact` keeps the id headlessly (session_id unchanged across the compact call and the following resumed call); `/clear` allocates a brand new id headlessly; the in-process (`$CLAUDE_CODE_SESSION_ID` inside one still-running interactive process) part of all three, plus the carry-over-style clear, is NEEDS-OPERATOR | 2.1.280 |
| (e) background completion waking an idle session | ANSWERED (interactive) | An idle **interactive** session (this package's own driver session, mid-run) was woken with no further input by all three completion types: a background Agent completion, a background Bash task killed by SIGTERM (correctly reported "failed with exit code 143"), and a background Bash task exiting normally -- see `interactive-wakes-abb7e549.jsonl`. Headless -p is supplementary only: it shows the CLI kills a still-running background Bash task a few seconds after its own final result (no new turn), which is a **timing artifact** of when the task ends relative to the CLI's exit, not a normal-exit-vs-killed distinction | 2.1.280 |
| (f) Stop exit 2 headless | ANSWERED | Each exit-2 Stop is retried: the model sees the stderr text, delivered as a synthetic `isSynthetic:true` user message quoting the hook command and its stderr verbatim (it also appears nowhere else in stream-json), and replies with the requested `CONTINUEDn`; `stop_hook_active` is `false` on the first Stop and `true` on every re-entry, and resets to `false` after a task-notification wake, so it is not a reliable block counter; the run ends when the hook itself stops returning exit 2 (f1: 1 block, `num_turns=2`; f2: 5 blocks, `num_turns=6`, `terminal_reason=completed`). No upper bound on retries, and no crash/timeout/invalid-JSON case was measured -- see the design-constraints paragraph below | 2.1.280 |
| (g) wall cost of a bash hook with one perl parse | ANSWERED | Floor (bash hook, no parse) median ~30.6 ms over 2 runs; +1 perl JSON::PP parse median ~77-78 ms; delta ~46-47 ms | 2.1.280 |
| (h) hot reload of settings.json / plugin hooks.json | ANSWERED (headless -p, single run each) | `.claude/settings.json`: picked up mid-session without restart (a change made between two Bash tool calls in the same `-p` invocation took effect for the second call). Plugin `hooks.json` (via `--plugin-dir`, not the marketplace `directory`-source path ccpraxis actually uses): **not** picked up within the ~6 s window tested -- both calls kept using the original registration. A blocked attempt's refusal was the harness's own permission system reacting to the 8.3 short-path, not a model-only heuristic | 2.1.280 |

## Method

### P0 preflight (verbatim, captured once; version unchanged across all experiments -- re-run at the end confirmed `2.1.280`)

```
$ claude --version
2.1.280 (Claude Code)
$ command -v claude
/c/Users/André/.local/bin/claude
$ bash --version | head -1
GNU bash, version 5.3.15(2)-release (x86_64-pc-cygwin)
$ perl -e 'print "$^V $^X\n"'
v5.42.3 perl
$ cygpath -w "$(command -v bash)"
C:\Program Files\Git\usr\bin\bash.exe
$ date -u
Wed Sep 23 21:17:23 UTC 2026
```

Flag availability from `claude --help` (saved verbatim to the evidence dir as `claude-help.txt`), checked against the candidate list in spec §3.0 step 2:

| flag | listed? |
|---|---|
| `-p` / `--print` | yes |
| `--model` | yes |
| `--output-format` (`json`, `stream-json`) | yes (both values present) |
| `--verbose` | yes |
| `--input-format` (`stream-json`) | yes |
| `--resume` | yes (`-r, --resume [value]`) |
| `--max-turns` | **absent** -- not in `claude --help` at all in this version |
| `--allowedTools` | yes |
| `--setting-sources` | yes |
| `--plugin-dir` | yes |
| `--max-budget-usd` | yes |
| `--debug` | yes |

**Spec deviation, recorded per §3.0's own instruction to record it:** `--max-turns` is not a flag of this Claude Code version (2.1.280); it was replaced/renamed upstream. Per §3.0 ("use a flag only if it is listed"), every experiment below that the spec described with `--max-turns` was run **without** it, bounded instead by `timeout` and, for item (f)'s N=5 case, by the Stop-blocker's own release. This did not prevent any item from being answered; f2's termination bound is recorded explicitly as "the hook's own release", not a turn cap.

Auto-update check: `claude --version` re-run after all experiments still reported `2.1.280`. No item needed a re-run.

### Scratch root `$S`

```
S=$(cygpath -ms "$(mktemp -d)")
# => C:/Users/ANDR~1/AppData/Local/Temp/TMP~1.61A
```

ASCII check passed (`printf '%s' "$S" | perl -ne 'exit(/[^\x00-\x7f]/ ? 1 : 0)'` exited 0). Ancestor walk (`C:/Users/ANDR~1/AppData/Local/Temp/TMP~1.61A` -> `.../Temp` -> `.../Local` -> `.../AppData` -> `.../ANDR~1` -> `.../Users` -> `C:`) found no `.claude` or `.ccpraxis-local-data` component at any level, and `$S` is not inside `C:/Development/ccpraxis`.

Layout used: `$S/exp-abc`, `$S/exp-d`, `$S/exp-e`, `$S/exp-f`, `$S/exp-h1`, `$S/exp-h2`, `$S/plug-h2` (scratch plugin for item h2), each with its own `.claude/settings.json`; `$S/logs/*.jsonl` per experiment; `$S/bin/*` for the shared helpers below; `$S/g/*` for item (g)'s driver; `$S/state/*` for the Stop-blocker's counters.

**Finding worth flagging on its own, corrected during the fix-batch:** the 8.3 short form the ASCII requirement forces (`ANDR~1`) was, on one occasion (item h2, see below), flagged and refused. The refusal was **not** model-only: `h2b-stdout.jsonl` shows the harness itself emitting a `system`/`permission_denied` message first (`decision_reason_type: "safetyCheck"`, *"Claude requested permissions to write to ...\\TMP~1.61A\\...\\hooks.B.json, which contains a suspicious Windows path pattern that requires manual approval"*), and only afterwards does the model's own reply relay that block in prose ("The system has blocked this request..."). This is the harness's permission system reacting to the short-name shape, not a model-side heuristic. Recorded under (h).

**Fact recorded for hook registration, found by the fix-batch's own repro (not a nested `claude -p` session):** `perl <missing-path>` exits **2**, and Claude Code treats exit 2 as its blocking code (PreToolUse denied, Stop blocked and retried with the stderr fed back to the model) -- unlike a missing bash script, which exits 127 (non-blocking):
```
$ perl /nonexistent/x.pl; echo $?
Can't open perl script "/nonexistent/x.pl": No such file or directory
2
$ bash /nonexistent/x.sh; echo $?
127
```
Consequence for every registration below and in any future production hook: a bare `perl '<abs path>'` command is one moved/renamed/unpromoted file away from turning every PreToolUse/Stop into a hard block, with no cap on Stop's retry (see (f) below). The probe registration template used throughout this doc is therefore written in the guarded form, never a bare `perl` invocation:
```
f='<abs path to bp-hook-probe.pl>'; [ -f "$f" ] || exit 0; exec perl "$f"
```

### Probe registration template

As specified verbatim in spec §3.0, one `settings.json` per experiment, generated by `$S/bin/mkprobe.pl <out-settings.json> <probe-path> <log-path> [events-csv]` (full text below), e.g. for `exp-abc`:
```
perl "$S/bin/mkprobe.pl" "$S/exp-abc/.claude/settings.json" C:/Development/ccpraxis/plugins/butler/scripts/bp-hook-probe.pl "$S/logs/abc.jsonl"
```
`mkprobe.pl`, full text:
```perl
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP;
# args: out probe log [events-csv, default full set]
my ($out, $probe, $log, $events_csv) = @ARGV;
my @events = $events_csv ? split(/,/, $events_csv) : qw(PreToolUse PostToolUse Stop SubagentStop SessionStart SessionEnd UserPromptSubmit PreCompact);
my $cmd = "CCPRAXIS_HOOK_PROBE_LOG='$log' perl '$probe'";
my %hooks;
for my $e (@events) {
  $hooks{$e} = [ { hooks => [ { type => "command", timeout => 15, command => $cmd } ] } ];
}
open(my $fh, ">", $out) or die $!;
print $fh JSON::PP->new->pretty->canonical->encode({ hooks => \%hooks });
close $fh;
```
This is the tool actually used to build every scratch `settings.json` in this package; it emits a bare `perl '<probe>'` command (not the guarded form above), which was safe here only because the probe's absolute repo path never moved during the run. The guarded form is the one recommended for any real registration.

**Deviation, recorded:** the generated command is a bare `perl '<probe>'`, not the guarded `[ -f "$f" ] || exit 0; exec perl "$f"` form recommended above -- acceptable for a diagnostic run inside one session where the path is known not to move, but not for a production hook.

All eight events (`PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreCompact`) were accepted on the first smoke run (item a) -- every one of them produced at least one log line (see (a) below), so E1/E3's fallback was never needed and no event was dropped.

### Env scrub: `$S/bin/run-claude.sh`

```bash
#!/usr/bin/env bash
# run-claude.sh <secs> <projectdir> <flags...> -- <prompt>
set -u
SECS="$1"; shift
PROJDIR="$1"; shift
ARGS=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  ARGS+=("$1"); shift
done
PROMPT="$1"

for v in $(compgen -e); do
  case "$v" in BP_*|CCPRAXIS_*) unset "$v";; esac
done
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR

if compgen -e | grep -E '^(BP_|CCPRAXIS_)|^CLAUDE_CODE_SESSION_ID$|^CLAUDE_PROJECT_DIR$' >/dev/null; then
  echo "SCRUB-ASSERT-FAILED" >&2
  exit 97
fi

cd "$PROJDIR" || exit 98
exec timeout "$SECS" claude -p "${ARGS[@]}" "$PROMPT"
```

Every nested session in every experiment below was launched through this wrapper; none hit the `exit 97` assertion path.

**Verbatim `compgen -e` evidence from item (a)'s session** (the first Bash tool call), taken from the `PostToolUse` payload's `tool_response.stdout` in `$S/logs/abc.jsonl`:

```
CLAUDECODE
CLAUDE_AUTO_BACKGROUND_TASKS
CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR
CLAUDE_CODE_CHILD_SESSION
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY
CLAUDE_CODE_ENABLE_AWAY_SUMMARY
CLAUDE_CODE_ENABLE_TODO_TOOLS
CLAUDE_CODE_ENTRYPOINT
CLAUDE_CODE_EXECPATH
CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL
CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION
CLAUDE_CODE_MESSAGING_SOCKET
CLAUDE_CODE_MESSAGING_TOKEN
CLAUDE_CODE_NEW_INIT
CLAUDE_CODE_NO_FLICKER
CLAUDE_CODE_SCROLL_SPEED
CLAUDE_CODE_SEND_FEEDBACK
CLAUDE_CODE_SESSION_ATTENDED
CLAUDE_CODE_SESSION_ID
CLAUDE_CODE_USE_POWERSHELL_TOOL
CLAUDE_EFFORT
CLAUDE_PID
```

None of `BP_*`, `CCPRAXIS_*`, or a *pre-existing* `CLAUDE_PROJECT_DIR` are present -- the scrub worked. `CLAUDE_CODE_SESSION_ID` **is** present in this list, but that is not a scrub failure: this is the name Claude Code itself assigns for the **new** nested session it just started (its value is that new session's own id, confirmed against the same session's `ENV-SID` capture under (d)), not a leaked value from the worker's shell. `compgen -e` lists exported names regardless of who most recently set them.

### `$S/bin/snap.pl` (item c)

Full text (as actually used, including a fix applied mid-run -- see the note below):

```perl
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Time::HiRes qw(time);

my $outfile = $ARGV[0];
local $/;
binmode(STDIN, ':raw');
my $raw = <STDIN>;
$raw = '' unless defined $raw;

my $t = time();
my %rec = (t => $t);
my $data;
eval { $data = JSON::PP::decode_json($raw); };
if (!$data) { $rec{error} = 'decode'; _write(\%rec, $outfile); exit 0; }

$rec{hook_event_name} = $data->{hook_event_name};
$rec{tool_name} = $data->{tool_name};
$rec{agent_id} = exists $data->{agent_id} ? $data->{agent_id} : undef;
$rec{tool_use_id} = exists $data->{tool_use_id} ? $data->{tool_use_id} : undef;
$rec{command} = (ref($data->{tool_input}) eq 'HASH' && exists $data->{tool_input}{command}) ? $data->{tool_input}{command} : undef;

my $transcript = $data->{transcript_path};
my $session_id = $data->{session_id};
if (!defined $transcript) { $rec{error} = 'missing transcript_path'; _write(\%rec, $outfile); exit 0; }
if (!defined $session_id)  { $rec{error} = 'missing session_id';     _write(\%rec, $outfile); exit 0; }

# NOTE: File::Basename::dirname does not understand backslash-separated
# Windows paths under this Git-for-Windows perl (it returned "." on a
# transcript_path with backslashes, which silently reported
# subagents_dir_exists=0 on every line in the first abc run). Fixed by
# normalising backslashes to forward slashes before splitting.
(my $tnorm = $transcript) =~ tr{\\}{/};
$tnorm =~ s{/[^/]+$}{};
my $dir = $tnorm . "/" . $session_id . "/subagents";

if (-d $dir) {
  $rec{subagents_dir_exists} = 1;
  opendir(my $dh, $dir) or do { $rec{subagents_dir_exists} = 0; _write(\%rec, $outfile); exit 0; };
  my @listing;
  for my $name (readdir($dh)) {
    next if $name eq '.' or $name eq '..';
    my $path = "$dir/$name";
    my @st = stat($path);
    push @listing, { name => $name, size => (defined $st[7] ? $st[7] : undef), mtime => (defined $st[9] ? $st[9] + 0.0 : undef) };
  }
  closedir($dh);
  $rec{listing} = \@listing;
} else {
  $rec{subagents_dir_exists} = 0;
  $rec{listing} = [];
}

_write(\%rec, $outfile);
exit 0;

sub _write {
  my ($rec, $file) = @_;
  eval {
    open(my $fh, '>>:raw', $file) or return;
    my $json = JSON::PP->new->canonical->encode($rec);
    print $fh $json . "\n";
    close($fh);
  };
}
```

**This bug and its fix are themselves a recorded finding, not smoothed over:** the first `exp-abc` run used the buggy version and every line showed `subagents_dir_exists: 0`, which would have been a wrong "absent" answer. It was caught by cross-checking against the real directory on disk (`ls` showed the `subagents/` dir existed at the end of the run) before being reported. The second `exp-abc` run (below) used the fixed version and produced the real timing evidence for (c).

### `$S/bin/stop-block.sh` (item f)

```bash
#!/usr/bin/env bash
MAX="$1"
COUNTFILE="$2"
cat >/dev/null
if [ ! -f "$COUNTFILE" ]; then echo 0 > "$COUNTFILE"; fi
COUNT=$(cat "$COUNTFILE")
COUNT=$((COUNT+1))
echo "$COUNT" > "$COUNTFILE"
if [ "$COUNT" -le "$MAX" ]; then
  echo "STOP-BLOCKED-${COUNT}: reply with the single word CONTINUED${COUNT} and then stop." >&2
  exit 2
fi
exit 0
```

### `$S/g/g0.sh`, `$S/g/g1.sh`, `$S/g/time-hooks.pl` (item g)

```bash
# g0.sh
#!/usr/bin/env bash
exit 0
```

```bash
# g1.sh
#!/usr/bin/env bash
SID=$(perl -MJSON::PP -0777 -e 'my $d = JSON::PP::decode_json(<STDIN>); print $d->{session_id} // ""')
exit 0
```

```perl
#!/usr/bin/env perl
use strict; use warnings;
use Time::HiRes qw(time);

my $payload_file = "$ENV{S_G}/payload.json";
my $g0 = "$ENV{S_G}/g0.sh";
my $g1 = "$ENV{S_G}/g1.sh";

sub run_one {
  my ($script) = @_;
  open(my $savedin, '<&', \*STDIN) or die "cannot save stdin: $!";
  open(STDIN, '<', $payload_file) or die "cannot open payload: $!";
  my $t0 = time();
  my $rc = system('bash', $script);
  my $t1 = time();
  open(STDIN, '<&', $savedin) or die "cannot restore stdin: $!";
  close($savedin);
  die "nonzero exit for $script: $rc" if $rc != 0;
  return ($t1 - $t0) * 1000.0;
}

for (1..5) { run_one($g0); run_one($g1); }   # 5 discarded warm-ups per variant

my (@g0times, @g1times);
for (1..40) {
  push @g0times, run_one($g0);
  push @g1times, run_one($g1);
}

sub stats {
  my @s = sort { $a <=> $b } @_;
  my $n = scalar(@s);
  my $min = $s[0]; my $max = $s[$n-1];
  my $median = ($n % 2) ? $s[int($n/2)] : (($s[$n/2-1]+$s[$n/2])/2);
  my $p90 = $s[int(0.9 * ($n-1))];
  return ($n, $min, $median, $p90, $max);
}

my ($n0,$min0,$med0,$p900,$max0) = stats(@g0times);
my ($n1,$min1,$med1,$p901,$max1) = stats(@g1times);
printf("g0: n=%d min=%.3f median=%.3f p90=%.3f max=%.3f\n", $n0,$min0,$med0,$p900,$max0);
printf("g1: n=%d min=%.3f median=%.3f p90=%.3f max=%.3f\n", $n1,$min1,$med1,$p901,$max1);
printf("delta(median g1-g0)=%.3f\n", $med1-$med0);
```

**Note on `time-hooks.pl`'s own history:** the first version used `local *STDIN = $fh` to redirect the child's input, which only aliases Perl's own filehandle glob and does **not** repoint OS file descriptor 0 that `system()` shares with the child -- so `g1.sh`'s `perl ... <STDIN>` read an already-exhausted real stdin and failed to decode JSON on every single invocation (visible as 40+ `"malformed JSON string ... (before end of string)"` warnings from `g1.sh`'s own subprocess in the first two driver runs). This did not corrupt the *timing* numbers (both scripts still ran and exited 0, which is all `system()` measures), but it meant `g1.sh` was not actually doing the one-perl-parse-of-real-payload work the spec describes. Fixed by saving/restoring the real fd 0 with `open(my $savedin, '<&', \*STDIN)` / `open(STDIN, '<', ...)` / `open(STDIN, '<&', $savedin)`. The two runs reported under (g) both use the fixed version and produced no parse warnings.

`ps -W | grep -c run-tests` was checked immediately before running the driver: `0` (no test sweep was running).

### Budget actually used

- **Recounted for the fix-batch (MINOR-4/L7 -- the original "19, breakdown sums to 17" did not add up):** 19 nested `claude -p` sessions with a surviving stdout transcript, against the budget of 20 (15 planned + retries/fallbacks), by item: **2** for (a)/(b)/(c) (one buggy-`snap.pl` run `a`, one corrected re-run `a2`); **5** for (d) (`d1`..`d5`: `--resume` x2, `/compact`, post-compact resume, `/clear`); **2** for (e) (`e1`, `e2`); **2** for (f) (`f1`, `f2`); **8** for (h) (`h1`, `h2`, `h2b`, `h2c` -- all four blocked by the harness's permission system before the design changed to an external file swap; `h1v2`, `h1v3`, `h1v4`, `h2v2` -- the four working runs of the revised design). 2+5+2+2+8 = 19. Plus **one** further resumed session for the mangled first `/compact` attempt (the literal string was expanded by MSYS into `C:/Program Files/Git/compact`; visible only inside `d3-stdout.jsonl`'s later compaction summary, no stdout of its own survived) brings the true total to **20**, exactly at the budget cap.
- **Wall time:** approximately 20 minutes of worker time from the first nested session to the last, well inside the 60-minute cap.
- **Timeouts:** `timeout 60`-`180` per session depending on the item (120 for most, 60 for the short single-turn (d)/(e)/(h) probes, 180 for (a)/(b)/(c) to allow for the subagent dispatch).
- No item was marked NEEDS-OPERATOR *because of* the budget; the NEEDS-OPERATOR items below are NEEDS-OPERATOR because they require an interactive TUI (Decision 32), not because the budget ran out.

---

## (a) PreToolUse, PostToolUse and Stop payload fields

### Question

The fields of PreToolUse, PostToolUse and Stop payloads, including `tool_use_id`, `agent_id`, `agent_type`, `stop_hook_active`.

### Status

ANSWERED

### Answer

Project `exp-abc`, prompt per spec §3.1, run twice (see Method's snap.pl note); field sets below are from the corrected second run (`abc2.jsonl`), cross-checked against the first run (`abc.jsonl`) which showed the same key sets.

**PreToolUse, parent context** (command `echo PARENT-MARK-...`): top-level keys `cwd, hook_event_name, permission_mode, prompt_id, session_id, tool_input, tool_name, tool_use_id, transcript_path`. `tool_input` keys: `command, description`. `agent_id`/`agent_type`: **absent** in parent context (not present in either observed parent PreToolUse payload). `tool_use_id`: **present**, e.g. `toolu_01BTFXvtd6Em4iTBx24yp5Dm`. `stop_hook_active`: **absent** (not a Stop event).

**PreToolUse, subagent context** (command `echo SUB-MARK-...`): top-level keys `agent_id, agent_type, cwd, hook_event_name, permission_mode, prompt_id, session_id, tool_input, tool_name, tool_use_id, transcript_path`. `agent_id`: **present**, e.g. `ab5d9090e4986670f`. `agent_type`: **present**, e.g. `general-purpose`. `tool_use_id`: **present**, e.g. `toolu_01QTJU4S4DKw6UiAupVevKTY`.

**PostToolUse, parent context**: adds `duration_ms` and `tool_response` to the PreToolUse key set. `tool_response` keys: `interrupted, isImage, noOutputExpected, stderr, stdout`. Same `agent_id`/`agent_type` absence as parent PreToolUse.

**PostToolUse, subagent context**: same shape as parent PostToolUse plus `agent_id`, `agent_type` (both present, same values as the matching PreToolUse).

**Stop** (observed twice per run -- once immediately after step 3, once after the async subagent notification, see (e)): top-level keys `background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, session_crons, session_id, stop_hook_active, transcript_path`. `stop_hook_active`: **present**, `false` in both observed Stop payloads of this item (no Stop-blocker was registered here; see (f) for `true`). `tool_use_id`, `agent_id`, `agent_type`: **absent in all Stop payloads observed** (0 of 4 across both runs).

**Bonus -- SubagentStop** (observed once per run): top-level keys `agent_id, agent_transcript_path, agent_type, background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, session_crons, session_id, stop_hook_active, transcript_path`. `agent_id`/`agent_type` **present** here (unlike the parent-only Stop event).

### Evidence

```
# PARENT PreToolUse (abc2.jsonl)
{"session_id":"8335a0f0-4d3f-4938-8c56-0acbbf78a81f","transcript_path":"C:\\Users\\André\\.claude\\projects\\C--Users-Andr--AppData-Local-Temp-tmp-61a6Uzopja-exp-abc\\8335a0f0-4d3f-4938-8c56-0acbbf78a81f.jsonl","cwd":"C:\\Users\\André\\AppData\\Local\\Temp\\tmp.61a6Uzopja\\exp-abc","prompt_id":"e44bf731-ffa6-429d-8da4-19144ffb8746" /* trimmed: repeated prompt_id value, real payload differs per run */,"permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo PARENT-MARK-n2403265-abc2","description":"Output parent mark"},"tool_use_id":"toolu_01BTFXvtd6Em4iTBx24yp5Dm"}
```

```
# SUB PreToolUse (abc2.jsonl)
{"session_id":"8335a0f0-4d3f-4938-8c56-0acbbf78a81f","transcript_path":"...","cwd":"...","prompt_id":"...","permission_mode":"default","agent_id":"ab5d9090e4986670f","agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo SUB-MARK-n2403265-abc2","description":"Echo the specified marker string"},"tool_use_id":"toolu_01QTJU4S4DKw6UiAupVevKTY"}
```

```
# PARENT PostToolUse (abc.jsonl, first run)
{"session_id":"7a9c7c20-1cc1-4f2f-9d66-835ecd0d6b9d","transcript_path":"...","cwd":"...","prompt_id":"e44bf731-ffa6-429d-8da4-19144ffb8746","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo PARENT-MARK-n2399093-abc","description":"Output parent mark"},"tool_response":{"stdout":"PARENT-MARK-n2399093-abc","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_013XcTg98FcxTL9SLCXujr4p","duration_ms":302}
```

```
# Stop (abc.jsonl, first of two in the first run)
{"session_id":"7a9c7c20-1cc1-4f2f-9d66-835ecd0d6b9d","transcript_path":"...","cwd":"...","prompt_id":"e44bf731-ffa6-429d-8da4-19144ffb8746","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done with steps 1-3. The subagent is running in the background and will notify when complete.","background_tasks":[{"id":"a2f2aacc903afc6ac","type":"subagent","status":"running","description":"Subagent test task","agent_type":"general-purpose"}],"session_crons":[]}
```

```
# SubagentStop (abc.jsonl, first run)
{"session_id":"7a9c7c20-1cc1-4f2f-9d66-835ecd0d6b9d","transcript_path":"...","cwd":"...","prompt_id":"e44bf731-ffa6-429d-8da4-19144ffb8746","permission_mode":"default","agent_id":"a2f2aacc903afc6ac","agent_type":"general-purpose","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"C:\\Users\\André\\.claude\\projects\\C--Users-Andr--AppData-Local-Temp-tmp-61a6Uzopja-exp-abc\\7a9c7c20-1cc1-4f2f-9d66-835ecd0d6b9d\\subagents\\agent-a2f2aacc903afc6ac.jsonl","last_assistant_message":"🤖 done","background_tasks":[{"id":"a2f2aacc903afc6ac","type":"subagent","status":"running","description":"Subagent test task","agent_type":"general-purpose"}],"session_crons":[]}
```

Full lines (untrimmed) are in the evidence dir: `.ccpraxis-local-data/blueprints/hook-continuity-remake/reports/01-harness-facts/evidence/logs/abc.jsonl` and `abc2.jsonl`. That directory is under gitignored `.ccpraxis-local-data/`, so it is machine-local and does **not** travel with a fresh clone -- the excerpts quoted in each section of this doc are the durable record; the raw files are a convenience for whoever ran this package.

### Claude Code version

2.1.280

### Reproduction

1. `S=$(cygpath -ms "$(mktemp -d)")`; verify ASCII per Method.
2. `mkdir -p "$S/exp-abc/.claude" "$S/logs"`.
3. Write `$S/exp-abc/.claude/settings.json` from the Method template (probe on all 8 events, `snap.pl` added to PreToolUse/PostToolUse) writing to `$S/logs/abc.jsonl` / `$S/logs/abc-snap.jsonl`.
4. `bash "$S/bin/run-claude.sh" 180 "$S/exp-abc" --model haiku --output-format stream-json --verbose --allowedTools "Bash,Task,Agent" --setting-sources project,local --max-budget-usd 0.50 -- "$PROMPT"` with `$PROMPT` as in spec §3.1 (nonce substituted).
5. `perl -MJSON::PP -ne '...' "$S/logs/abc.jsonl"` (as used above) to extract per-event key sets, splitting on the presence of `SUB-MARK`/`PARENT-MARK` in `tool_input.command`.

---

## (b) Subagent session_id vs parent session_id

### Question

The `session_id` seen in a subagent's own tool calls vs its parent's.

### Status

ANSWERED

### Answer

**Equal.** The subagent's own `PreToolUse`/`PostToolUse` payloads for the `echo SUB-MARK-...` command carry the exact same `session_id` as the parent's `PreToolUse`/`PostToolUse` payloads for `echo PARENT-MARK-...`, and both equal the stream-json init message's `session_id`. The subagent's own transcript record (under `<project>/<session_id>/subagents/agent-<id>.jsonl`) carries `sessionId` equal to the same parent session id -- corroborating the ledger's existing transcript-only evidence (`lib.sh` step 3b) with a hook-payload-level measurement.

### Evidence

```
# real stream-json init line (a2-stdout.jsonl), trimmed of tool/plugin lists:
{"type":"system","subtype":"init","cwd":"C:\\Users\\André\\...\\exp-abc","session_id":"8335a0f0-4d3f-4938-8c56-0acbbf78a81f","claude_code_version":"2.1.280","model":"claude-haiku-4-5-20251001","permissionMode":"default", /* trimmed: tools, plugins, agents, skills, slash_commands, mcp_servers, capabilities */ "uuid":"..."}
```
(The earlier draft of this section quoted a `subtype:"hook_started"` line instead, which is the SessionStart *hook's own* logging line, not the CLI's init message -- corrected here.)

```
# PARENT-MARK PreToolUse (abc2.jsonl)  -- session_id = 8335a0f0-4d3f-4938-8c56-0acbbf78a81f
# SUB-MARK PreToolUse (abc2.jsonl)     -- session_id = 8335a0f0-4d3f-4938-8c56-0acbbf78a81f  (agent_id = ab5d9090e4986670f)
```

(Full lines quoted under (a); the `session_id` field of every extracted line above -- parent and subagent, Pre and Post -- was `8335a0f0-4d3f-4938-8c56-0acbbf78a81f`, checked programmatically, not by eye.)

```
# subagent transcript record containing SUB-MARK, grep -m1:
$ grep -m1 "SUB-MARK-n2403265" ".../8335a0f0-4d3f-4938-8c56-0acbbf78a81f/subagents/agent-ab5d9090e4986670f.jsonl" | perl -MJSON::PP -ne '...'
sessionId=8335a0f0-4d3f-4938-8c56-0acbbf78a81f
```

### Claude Code version

2.1.280

### Reproduction

1-4. Same as (a).
5. `perl -MJSON::PP -ne 'print $d->{session_id} if $d->{tool_input}{command} =~ /SUB-MARK|PARENT-MARK/' "$S/logs/abc2.jsonl"` -- compare values.
6. `find "$HOME/.claude/projects" -maxdepth 1 -iname '*exp-abc*'` to locate the project dir; `ls <dir>/<session_id>/subagents` to find the agent transcript; `grep -m1 SUB-MARK <that file> | perl -MJSON::PP -ne 'print $d->{sessionId}'`.

---

## (c) Subagent meta.json at the subagent's first PreToolUse

### Question

Whether `<session>/subagents/agent-<id>.meta.json` exists at the subagent's first PreToolUse.

### Status

ANSWERED

### Answer

**Present, and not racy, for one auto-backgrounded dispatch** -- a clear margin, not a sub-100 ms one, but measured on a single asynchronous `Agent` dispatch: the parent's own `Agent` PostToolUse `tool_use_result` in `a2-stdout.jsonl` carries `"isAsync":true,"status":"async_launched"` (quoted in full below), confirming this dispatch was backgrounded rather than awaited synchronously. `snap.pl`'s corrected run shows `subagents_dir_exists: 0` at the parent's PreToolUse for the `Agent` tool call itself (t=...563.114), `subagents_dir_exists: 0` still at the unrelated `PARENT-MARK` Bash PreToolUse a moment later (t=...563.122), `subagents_dir_exists: 1` with `agent-<id>.meta.json` (202 bytes) and `agent-<id>.jsonl` already present by the `Agent` call's own PostToolUse (t=...563.290, ~176 ms after the Agent PreToolUse), and the subagent's own first PreToolUse does not fire until t=...566.669 -- about **3.4 seconds** after the meta.json file is already there. Part of that 3.4 s margin is the async scheduling gap inherent to a backgrounded dispatch; nothing was measured for a **foreground** (synchronous) subagent dispatch, which package 02's worker-identity lookups may involve. Run once; the margin was large enough that spec §3.3's "run a second identical session" clause (only required for a sub-100 ms margin) did not apply. The parent's own `PreToolUse` snapshot for the `Agent` tool call (the before-state) shows `subagents_dir_exists: 0`, confirming the directory is created as part of dispatching the subagent, not pre-existing.

```
# a2-stdout.jsonl, the Agent tool's own PostToolUse tool_use_result (trimmed of prompt/outputFile text):
"tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"ab5d9090e4986670f", /* trimmed */ }
```

### Evidence

```
# abc-snap.jsonl (corrected snap.pl), in order:
{"agent_id":null,"command":null,"hook_event_name":"PreToolUse","listing":[],"subagents_dir_exists":0,"t":1790198563.11412,"tool_name":"Agent","tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm"}
{"agent_id":null,"command":"echo PARENT-MARK-n2403265-abc2","hook_event_name":"PreToolUse","listing":[],"subagents_dir_exists":0,"t":1790198563.12221,"tool_name":"Bash","tool_use_id":"toolu_01BTFXvtd6Em4iTBx24yp5Dm"}
{"agent_id":null,"command":null,"hook_event_name":"PostToolUse","listing":[{"mtime":1790198563,"name":"agent-ab5d9090e4986670f.jsonl","size":53939},{"mtime":1790198563,"name":"agent-ab5d9090e4986670f.meta.json","size":202}],"subagents_dir_exists":1,"t":1790198563.2897,"tool_name":"Agent","tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm"}
{"agent_id":"ab5d9090e4986670f","command":"echo SUB-MARK-n2403265-abc2","hook_event_name":"PreToolUse","listing":[{"mtime":1790198566,"name":"agent-ab5d9090e4986670f.jsonl","size":58094},{"mtime":1790198563,"name":"agent-ab5d9090e4986670f.meta.json","size":202}],"subagents_dir_exists":1,"t":1790198566.66893,"tool_name":"Bash","tool_use_id":"toolu_01QTJU4S4DKw6UiAupVevKTY"}
```

### Claude Code version

2.1.280

### Reproduction

1-4. Same as (a), using the corrected `snap.pl` from Method.
5. `cat "$S/logs/abc-snap.jsonl"` and take the first line whose `command` contains `SUB-MARK` (or the first line with non-null `agent_id`); compare its `t` against the preceding `Agent`-tool `PostToolUse` snapshot's `t` and `listing`.

---

## (d) Session ids across --resume, /compact, /clear and a carry-over clear

### Question

`session_id` and `$CLAUDE_CODE_SESSION_ID` after `/compact`, `/clear`, `--resume` and a `/carry-over`-style clear.

### Status

PARTIAL -- see NEEDS-OPERATOR D-1, D-2, D-3

### Answer

**d1 (`--resume`, ANSWERED):** Run 1 (`ID-PROMPT` fresh) gets `session_id = S1 = 0409cb25-7656-418b-99f3-e9402646f33a`, `SessionStart.source = "startup"`, `ENV-SID = S1`. Run 2 (`--resume S1`, `ID-PROMPT` again, separate process) gets the exact same `session_id = S1`, `SessionStart.source = "resume"` (plus resume-specific fields `seconds_since_last_response`, `context_tokens`, etc.), and `ENV-SID = S1` again. `--resume` fully preserves the id across process boundaries.

**d2 (`/compact`, headless, PARTIAL):** Run 3 (`--resume S1`, prompt `/compact`) produced a `PreCompact` payload (`trigger: "manual"`) and a `SubagentStop` for the compaction subagent, then a `SessionStart` with `source: "compact"` -- the compact command counted as executed. `session_id` stayed `S1` throughout (unchanged by compaction). Run 4 (`--resume S1`, `ID-PROMPT` again, a separate process after the compact) got `ENV-SID = S1` again -- so **across process boundaries**, the id survives compaction. What this headless sequence *cannot* show is whether `$CLAUDE_CODE_SESSION_ID` changes *within* one still-running interactive process at the moment `/compact` runs (each `-p` call here is a fresh process reading the resumed transcript) -- that part is NEEDS-OPERATOR (D-1).

**d3 (`/clear`, headless, PARTIAL):** Run 5 (`--resume S1`, prompt `/clear`) produced `SessionEnd` (`reason: "clear"`) on `S1`, immediately followed by a `SessionStart` (`source: "clear"`) on a **brand new** `session_id = bec23e31-e292-4be2-95b7-5c1051ce993d`. Headless `/clear` allocates a new id rather than reusing the old one. The in-process `$CLAUDE_CODE_SESSION_ID` behaviour (whether a long-running interactive process's own env var changes without a process restart) is NEEDS-OPERATOR (D-2).

**d4 (carry-over-style clear):** No headless form exists (it is an interactive plan-mode UI action). NEEDS-OPERATOR (D-3).

### Evidence

```
# Run 1 SessionStart + PostToolUse (d.jsonl)
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"SessionStart","source":"startup"}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ENV-SID=$CLAUDE_CODE_SESSION_ID", /* trimmed */},"tool_response":{"stdout":"ENV-SID=0409cb25-7656-418b-99f3-e9402646f33a", /* trimmed */}, /* trimmed */}
```

```
# Run 2 SessionStart (resume) + PostToolUse (d.jsonl)
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"SessionStart","source":"resume","seconds_since_last_response":10,"context_tokens":29885,"prompt_cache_likely_expired":false,"estimated_cache_write_usd":0.0598}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"tool_response":{"stdout":"ENV-SID=0409cb25-7656-418b-99f3-e9402646f33a", /* trimmed */}, /* trimmed */}
```

```
# Run 3 /compact (d-compact.jsonl)
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"SessionStart","source":"resume", /* trimmed */}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"PreCompact","trigger":"manual","custom_instructions":null}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"agent_id":"a2c49bbac80fe52ed","agent_type":"","hook_event_name":"SubagentStop", ... ,"agent_transcript_path":"...\\0409cb25-7656-418b-99f3-e9402646f33a\\subagents\\agent-a2c49bbac80fe52ed.jsonl", /* last_assistant_message trimmed: long compaction summary */ ...}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-4-5-20251001"}
```

```
# Run 4 post-compact ID-PROMPT (d-postcompact.jsonl), PostToolUse tool_response.stdout:
ENV-SID=0409cb25-7656-418b-99f3-e9402646f33a
```

```
# Run 5 /clear (d-clear.jsonl)
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"hook_event_name":"SessionStart","source":"resume", /* trimmed */}
{"session_id":"0409cb25-7656-418b-99f3-e9402646f33a", ... ,"prompt_id":"94368987-4403-40a9-a720-19893cfee09a","hook_event_name":"SessionEnd","reason":"clear"}
{"session_id":"bec23e31-e292-4be2-95b7-5c1051ce993d", ... ,"hook_event_name":"SessionStart","source":"clear"}
{"session_id":"bec23e31-e292-4be2-95b7-5c1051ce993d", ... ,"hook_event_name":"SessionEnd","reason":"other"}
```

**Deviation note (corrected, MINOR-6):** the literal `/compact`/`/clear` prompt string, when passed as the `-p` positional argument from Git Bash, is expanded by MSYS's own path-conversion heuristic into `C:/Program Files/Git/compact` (a leading-slash argument handed to a native binary gets resolved against the Git install root) -- the same *class* of landmine the project CLAUDE.md documents for `:`-separated args (`MSYS2_ARG_CONV_EXCL`), just triggered by a single leading slash instead of a colon, and fixed with a **different** Git-for-Windows switch: `MSYS_NO_PATHCONV`, not `MSYS2_ARG_CONV_EXCL` (the project's documented technique is for the colon case; it was not reused here, and this doc should not have implied it was). The first attempt at Run 3 shows this verbatim in evidence (`"prompt":"C:/Program Files/Git/compact"`, model replied asking for clarification, no `PreCompact` fired). Fixed by setting `MSYS_NO_PATHCONV=1` for that one invocation (not a repo-wide env change, scoped to the single `bash "$S/bin/run-claude.sh" ...` call) rather than hand-translating, since there is nothing to translate -- the literal string `/compact` must reach `claude` unchanged.

### Claude Code version

2.1.280

### Reproduction

1. `S=...`; `mkdir -p "$S/exp-d/.claude"`; write probe settings writing to `$S/logs/d.jsonl`.
2. `bash "$S/bin/run-claude.sh" 120 "$S/exp-d" --model haiku --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- 'Run the Bash command `echo ENV-SID=$CLAUDE_CODE_SESSION_ID` and stop.'` -- capture `S1` from the first stream-json line's `session_id`.
3. Same command plus `--resume "$S1"`.
4. `export MSYS_NO_PATHCONV=1; bash "$S/bin/run-claude.sh" 120 "$S/exp-d" --model haiku --resume "$S1" --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- "/compact"; unset MSYS_NO_PATHCONV` (new probe log).
5. Re-run step 2's full command (`--model haiku --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30`) with `--resume "$S1"` added and the ID-PROMPT again (new probe log).
6. `export MSYS_NO_PATHCONV=1; bash "$S/bin/run-claude.sh" 120 "$S/exp-d" --model haiku --resume "$S1" --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- "/clear"; unset MSYS_NO_PATHCONV` (new probe log).
7. `grep` each resulting `*.jsonl` for `SessionStart`/`SessionEnd`/`PreCompact`/`PostToolUse` and diff `session_id` values.

---

## (e) Background completion waking an idle session

### Question

Whether a backgrounded Bash task that exits normally, or is killed, wakes an idle session, and whether a background Agent completion does.

### Status

ANSWERED (interactive)

Corrected by the fix-batch. The core question is about an idle **interactive** session, and this package's own driver session (`abb7e549`, an ordinary drive-solo session running concurrently with this package, not the scripted E-1/E-2/E-3 checklist) supplies direct evidence for all three sub-questions while genuinely idle: three separate wakes each followed an assistant `end_turn` with nothing pending in the session's own turn (i.e. no foreground tool call was outstanding), and each is answered below without an operator. E-1, E-2 and E-3 are therefore removed from NEEDS-OPERATOR (see that section). The headless `-p` runs below remain as supplementary evidence only, labelled "headless -p", and one of their conclusions is corrected (BLOCKER-1/H2 from review and red-team).

### Answer

**Interactive, idle session -- ANSWERED.** From `interactive-wakes-abb7e549.jsonl` (this session's own transcript, Claude Code 2.1.280):
- **Background Agent completion (answers the (a)-derived question above for a real interactive session):** woke the idle session with no further input, `end_turn` at 18:40:06.530Z, wake at 18:40:54.020Z (~47 s idle), reporting `<status>completed</status>`.
- **Background Bash, killed by SIGTERM:** woke the idle session, `end_turn` at 20:45:30.237Z, wake at 20:47:28.900Z (~119 s idle), reporting `<status>failed</status>` with `"failed with exit code 143"` -- SIGTERM (128+15=143) reported **correctly**, unlike the headless e2 result below.
- **Background Bash, normal exit:** woke the idle session, `end_turn` at 21:23:42.476Z, wake at 21:37:43.427Z (~14 min idle), reporting `<status>completed</status>` with `"completed (exit code 0)"`.

So: yes to all three -- a background Bash task's normal exit, a killed background Bash task, and a background Agent completion each wake an idle interactive session on their own, and the notification's reported status matches how the task actually ended (completed vs. failed/killed), at least in this session.

**Headless -p, supplementary only -- and one earlier conclusion corrected.** The original draft of this section read the e1/e2 headless contrast as "normal exit did not wake, killed did". That is not what the evidence shows once the post-result stream is read past the `result` line. In **e1** (background Bash, meant to exit normally), the `sleep 20` task was still `status:"running"` at the final `Stop`/`result` (6.79 s after start), and about 5 s **after** that result the stream shows the CLI itself killing the task and stopping there -- no new turn:
```
# e1-stdout.jsonl, after the result line (t≈6.79s):
{"type":"system","subtype":"background_tasks_changed","tasks":[],...}
{"type":"system","subtype":"task_updated","task_id":"bsp949ih1","patch":{"status":"killed","end_time":1790199286134},...}
{"type":"system","subtype":"task_notification","task_id":"bsp949ih1","status":"stopped",...}
```
The process never got a chance to observe a *normal* exit, because headless `-p` kills whatever background task is still running a few seconds after its own final result. In **e2** the task was (deliberately) killed about 3 s in, which happens to land inside that same short post-result window, and a `<task-notification>` and a new turn followed. The variable that separates e1 from e2 is **whether the task ends inside the CLI's brief post-result window before it kills anything still running** -- not whether the task was killed. This run never isolated "normal exit inside the window" from "killed inside the window", so no headless claim about normal-exit-vs-killed should be drawn from it; the interactive evidence above is the answer for the actual (idle-session) question.

**The e2 "killed -> completed (exit code 0)" result is also now flagged as unverified rather than a general fact:** the kill was confirmed against the MSYS pid recorded by the command's own shell and cross-checked by WINPID/`tasklist`, but nobody verified that pid was the `sleep` itself rather than a wrapper shell, so "exit code 0" may just be the wrapper's own exit, not the killed process's. The interactive evidence's SIGTERM report (`"failed with exit code 143"`) is a real leaf-process kill correctly reported, so the safer working assumption is that e2's headless "completed (exit code 0)" is a headless-`-p`/wrapper-process artifact, not evidence that the CLI mis-reports kills in general.

**Background Agent, no explicit background parameter observed (e3):** across the two `Agent` PreToolUse payloads captured in `exp-abc` (one per run, not four -- corrected count), `tool_input` carried only `description` and `prompt`, no `background` key. That is evidence the model did not *use* such a parameter here, not evidence the parameter does not exist in the tool's schema (payloads never show tool schemas, only the arguments sent). What the evidence *does* show is that the dispatch was auto-backgrounded regardless: the `Agent` PostToolUse `tool_use_result` in `a2-stdout.jsonl` carries `"isAsync":true,"status":"async_launched"`. Recorded precisely: "the model sent no `background` key; Claude Code 2.1.280 auto-backgrounds an `Agent` dispatch without one." The interactive evidence above answers the practical question (does a background Agent completion wake an idle session) directly, so no operator action is needed for e3 either.

### Evidence

```
# abc.jsonl: async Agent wake (headless -p)
{"session_id":"7a9c7c20-...","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done with steps 1-3. The subagent is running in the background and will notify when complete.","background_tasks":[{"id":"a2f2aacc903afc6ac","type":"subagent","status":"running", /* trimmed */}], /* trimmed */}
{"session_id":"7a9c7c20-...","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>a2f2aacc903afc6ac</task-id>\n...\n<status>completed</status>\n<summary>Agent \"Subagent test task\" finished</summary>\n<note>A task-notification fires each time this agent stops with no live background children of its own. ...</note>\n<result>🤖 done</result>\n<usage><subagent_tokens>20374</subagent_tokens><tool_uses>1</tool_uses><duration_ms>5350</duration_ms></usage>\n</task-notification>"}
{"session_id":"7a9c7c20-...","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The subagent completed successfully with output \"done\". All four steps have been executed as requested.","background_tasks":[],"session_crons":[]}
```

```
# interactive-wakes-abb7e549.jsonl: three wakes of an idle interactive session, this package's own driver
{"previous_assistant":{"sessionId":"abb7e549-...","stop_reason":"end_turn","timestamp":"2026-09-23T18:40:06.530Z","line":1980}}
{"sessionId":"abb7e549-...","content":"<task-notification>\n<task-id>abbaf1efcae43f465</task-id>\n...\n<status>completed</status>\n<summary>Agent \"Profile slowest test files\" finished</summary>\n...","timestamp":"2026-09-23T18:40:54.020Z","line":1990}
{"previous_assistant":{"sessionId":"abb7e549-...","stop_reason":"end_turn","timestamp":"2026-09-23T20:45:30.237Z","line":3286}}
{"sessionId":"abb7e549-...","content":"<task-notification>\n<task-id>bqnude788</task-id>\n...\n<status>failed</status>\n<summary>Background command \"Arm the watcher as the sole final call\" failed with exit code 143</summary>\n</task-notification>","timestamp":"2026-09-23T20:47:28.900Z","line":3291}
{"previous_assistant":{"sessionId":"abb7e549-...","stop_reason":"end_turn","timestamp":"2026-09-23T21:23:42.476Z","line":3935}}
{"sessionId":"abb7e549-...","content":"<task-notification>\n<task-id>bp0eh59xq</task-id>\n...\n<status>completed</status>\n<summary>Background command \"Hold continuity while the measurement worker runs\" completed (exit code 0)</summary>\n</task-notification>","timestamp":"2026-09-23T21:37:43.427Z","line":3940}
```
Full file: `.../evidence/interactive-wakes-abb7e549.jsonl` (6 lines, 3 wake pairs).

```
# e1-stdout.jsonl (headless -p, correctly labelled): CLI kills the still-running task ~5s after its own result, no new turn
{"type":"result", ... ,"result":"🤖 Background task started (ID: bsp949ih1). I'll await the completion notification.","duration_ms":6790, /* trimmed */}
{"type":"system","subtype":"background_tasks_changed","tasks":[],...}
{"type":"system","subtype":"task_updated","task_id":"bsp949ih1","patch":{"status":"killed","end_time":1790199286134},...}
{"type":"system","subtype":"task_notification","task_id":"bsp949ih1","status":"stopped",...}
```
**Correction (MINOR-1):** the probe log archived under the filename `e1.jsonl` is not the e1 run -- it holds only session `00278eea` (the e2 command); the true e1 probe log was overwritten when the e2 run reused the filename. `e1-stdout.jsonl` (the stream-json, quoted above) survives and is now cited for e1 instead.

```
# e1.jsonl (headless -p; this file is actually the e2 run's probe log, session 00278eea -- see correction above): killed-task wake
{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done. Command running in background.","background_tasks":[{"id":"b3mdfpc4w","type":"shell","status":"running", /* trimmed */}], /* trimmed */}
{"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>b3mdfpc4w</task-id>\n...\n<status>completed</status>\n<summary>Background command \"echo $$ &gt; .../e2.pid; ... sleep 60; echo BG-DONE-n2413906-e2\" completed (exit code 0)</summary>\n</task-notification>"}
{"hook_event_name":"Stop","last_assistant_message":"Background command completed successfully (exit code 0)."}
```

```
$ cat .../e2.winpid
78564
$ tasklist //FI "PID eq 78564"
INFO: No tasks are running which match the specified criteria.
```
(This confirms the WINPID was gone; it does not confirm that pid belonged to the `sleep` itself rather than a wrapper shell -- see the Answer's note on the e2 "completed (exit code 0)" result being unverified.)

### Claude Code version

2.1.280

### Reproduction

**Interactive (the answer this item rests on):** no scripted reproduction was run; the evidence is this package's own driver session, `abb7e549`, an ordinary drive-solo run. `grep -B1 '"content":"<task-notification>' <transcript>` after filtering to lines whose immediately preceding record is `"type":"assistant"` with `"stop_reason":"end_turn"` and no other tool call pending isolates a genuine idle-session wake; the three such pairs are archived verbatim at `.../evidence/interactive-wakes-abb7e549.jsonl`.

**Headless -p (supplementary only):**

1. `mkdir -p "$S/exp-e/.claude"`; probe settings on all 8 events writing `$S/logs/e1.jsonl`.
2. e1: `bash "$S/bin/run-claude.sh" 60 "$S/exp-e" --model haiku --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- 'Run the Bash command `sleep 20; echo BG-DONE-<nonce>` with run_in_background set to true, then end your turn immediately without checking on it.'`, bracketed with `date +%s.%N`. Use a **distinct** log filename for this run (e.g. `e1-only.jsonl`) so a later run cannot overwrite it -- this package's own e1.jsonl was lost that way (MINOR-1).
3. e2: same prompt shape substituting the pid/winpid-capturing command; in parallel, poll for `$S/e2.pid` to appear, `sleep 3`, `kill -TERM $(cat $S/e2.pid)`, confirm via `kill -0` (MSYS ns) then `tasklist //FI "PID eq $(cat $S/e2.winpid)"` (WINPID ns), never mixing the two. For a cleaner isolation of the e1/e2 confound, kill a verified leaf pid (the `sleep` itself, not its parent shell) and confirm no child survives.
4. e3: grep the `Agent` `tool_input` keys already captured for (a) (2 dispatches, not 4); none named `background`; also check the matching `Agent` PostToolUse `tool_use_result` for `isAsync`/`status` to confirm auto-backgrounding.
5. `grep -c '"hook_event_name":"Stop"'` on each log; inspect `UserPromptSubmit` payloads for `<task-notification>` bodies; for e1/e2, also inspect the stream-json stdout for `task_updated`/`task_notification` system events **after** the final `result` line.
6. Optional extra isolation (not run, budget/time): a `sleep 1` background task under the same e1 shape would isolate "normal exit landing inside the CLI's brief post-result window" from "killed inside that window", which this run did not separate.

---

## (f) Stop hook exit 2 in headless claude -p

### Question

What a Stop hook exit 2 does in headless `claude -p`.

### Status

ANSWERED

### Answer

**f1 (N=1):** exit code of `claude` was 0. The stream-json `result` message had `subtype: "success"`, `num_turns: 2`. Two `Stop` payloads: the first had `stop_hook_active: false` and `last_assistant_message: "🤖 READY"`; the stop-blocker then wrote `STOP-BLOCKED-1: reply with the single word CONTINUED1 and then stop.` to stderr and exited 2; the second `Stop` had `stop_hook_active: true` and `last_assistant_message: "🤖 CONTINUED1"` -- the model demonstrably saw the stderr text and complied. **Corrected (MAJOR-2):** the stderr text does appear in the stream-json stdout -- it is delivered as a synthetic `isSynthetic:true` user message ("Stop hook feedback:") that quotes the full hook command string and its stderr verbatim (`f1-stdout.jsonl` line 13, one such line; `f2-stdout.jsonl` has five). It is not echoed a second time anywhere else, and it is not part of the assistant's own turn -- but it is present in the stream, which answers AC19's question directly.

**f2 (N=5):** without `--max-turns` (absent from this version, see Method), the run was bounded only by `timeout` and the hook's own release. Six `Stop` payloads fired: `stop_hook_active` was `false` on the first and `true` on each of the next five (`CONTINUED1` through `CONTINUED5`), the blocker's counter file reached `6` (five blocks plus the one call that saw `count > max` and exited 0), and the run ended because **the hook's own release** stopped returning exit 2 -- not because of a turn cap or the `timeout`. `num_turns: 6`, `subtype: "success"`, `terminal_reason: "completed"`.

**Design constraints this section's evidence supports, none of them extrapolated beyond what was measured (red-team M2, H1):**
1. Nothing here shows an upper bound on Stop-hook retries above N=5; a production Stop gate must keep its own per-session counter and hard cap rather than assume the harness supplies one.
2. Every non-intentional exit path of a hook must be exit 0. A missing/unpromoted/wrong-path `perl` hook exits **2** (Perl's own ENOENT code, not the script's `exit 0`, since the script never runs -- see Method's registration-template fix), and exit 2 is Claude Code's blocking code on every event, including Stop. Register perl hooks only in the guarded form given in Method.
3. `stop_hook_active` is `false` only on the *first* Stop of a chain and resets to `false` again after a task-notification wake (see (e)); it is not a reliable block counter and a gate must not key its release on it alone.
4. Not measured here, and left for a follow-up: what a Stop hook that itself times out, crashes (exit 1/255), or prints invalid JSON does, and whether Stop fires at all on a user interrupt (Esc) in an interactive session. One `-p` run with a Stop hook that `sleep`s past its own `timeout` would settle the first of these; the no-`claude`-in-nested-session budget rule and this package's time cap did not allow it here.

### Evidence

```
# f1.jsonl, both Stop lines
{"session_id":"9051d29e-...","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"🤖 READY", /* trimmed */}
{"session_id":"9051d29e-...","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"🤖 CONTINUED1", /* trimmed */}
```

```
# f1-stdout.jsonl, result line (trimmed of the usage/cost sub-object's less relevant fields)
{"duration_api_ms":10075,"stop_reason":"end_turn","session_id":"9051d29e-...","total_cost_usd":0.0334751, /* usage details trimmed */ "terminal_reason":"completed","is_error":false,"num_turns":2,"subtype":"success","result":"🤖 CONTINUED1", /* trimmed */}
```

```
# f2 stop-block counter file
$ cat "$S/state/f2.count"
6
```

```
# f1-stdout.jsonl line 13, verbatim synthetic Stop-hook-feedback user message:
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\n[bash 'C:/Users/ANDR~1/AppData/Local/Temp/TMP~1.61A/bin/stop-block.sh' 1 'C:/Users/ANDR~1/AppData/Local/Temp/TMP~1.61A/state/f1.count']: STOP-BLOCKED-1: reply with the single word CONTINUED1 and then stop.\n"}]},"parent_tool_use_id":null,"session_id":"9051d29e-03a6-413c-aa93-f5811b282dad", /* trimmed: uuid, isSynthetic:true, timestamp */}
```

```
# f2.jsonl, all six Stop lines' stop_hook_active + message (extracted programmatically, not paraphrased):
stop_hook_active=0 msg=READY
stop_hook_active=1 msg=CONTINUED1
stop_hook_active=1 msg=CONTINUED2
stop_hook_active=1 msg=CONTINUED3
stop_hook_active=1 msg=CONTINUED4
stop_hook_active=1 msg=CONTINUED5
```

```
# f2-stdout.jsonl: one verbatim Stop-hook-feedback line (5 total in the file, same shape as f1's above)
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\n[bash '.../stop-block.sh' 5 '.../f2.count']: STOP-BLOCKED-1: reply with the single word CONTINUED1 and then stop.\n"}]},"isSynthetic":true, /* trimmed */}
```

```
# f2-stdout.jsonl, result line
subtype=success num_turns=6 terminal_reason=completed result=🤖 CONTINUED5
```

### Claude Code version

2.1.280

### Reproduction

1. `mkdir -p "$S/exp-f/.claude" "$S/state"`.
2. f1: write `$S/exp-f/.claude/settings.json` with the probe on all 8 events plus a second `Stop` hook `bash '$S/bin/stop-block.sh' 1 '$S/state/f1.count'`, writing probe output to `$S/logs/f1.jsonl`. `rm -f "$S/state/f1.count"`. `bash "$S/bin/run-claude.sh" 120 "$S/exp-f" --model haiku --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- "Reply with the single word READY and stop."`
3. f2: regenerate settings with `bash '$S/bin/stop-block.sh' 5 '$S/state/f2.count'`, writing probe output to `$S/logs/f2.jsonl`; `rm -f "$S/state/f2.count"`; re-run the same command (no `--max-turns`, absent from this version).
4. Inspect `stop_hook_active`/`last_assistant_message` per `Stop` line and the final stream-json `result`/`subtype`/`num_turns`/`terminal_reason`.

---

## (g) Wall cost of a bash hook with one perl parse (Windows host)

### Question

Measured wall cost on the Windows host (Git-for-Windows perl and bash; jq is not installed there) of a bash hook that parses its payload once with perl vs not at all.

### Status

ANSWERED

### Answer

Run alone (`ps -W | grep -c run-tests` = `0`, confirming no test sweep was concurrent). Driver run twice (medians agree within ~0.3 %, well under the 25 % re-run threshold, so a third run was not needed):

| run | g0 (floor) n / min / median / p90 / max (ms) | g1 (+1 perl parse) n / min / median / p90 / max (ms) | delta (median g1-g0) |
|---|---|---|---|
| A | 40 / 27.930 / 30.597 / 32.313 / 33.113 | 40 / 72.208 / 77.222 / 82.121 / 84.170 | 46.625 ms |
| B | 40 / 26.543 / 30.681 / 31.951 / 46.383 | 40 / 73.210 / 78.093 / 81.887 / 95.389 | 47.412 ms |

**The g0 median (~30.6 ms) is the floor that Decision 33's target (floor + 100 ms) refers to**, measured with the driver above (5 discarded warm-ups per variant, then 40 interleaved timed rounds per variant, each round reopening real stdin from a fixed captured payload and calling `system('bash', <script>)` -- the same `bash <script>` shape `hooks.json` uses). g1's median (~77-78 ms) is one perl process start plus one `JSON::PP::decode_json` of a real ~340-byte hook payload. **Later packages must measure with this same driver (`$S/g/time-hooks.pl`, reproduced in Method) for the figures to be comparable** -- a different measurement method (e.g. PowerShell or node) is explicitly out of scope per spec §6.

An earlier version of this driver had a stdin-redirection bug (documented in Method) that made every `g1.sh` invocation fail to decode its payload, though it did not affect the timing numbers reported here (both runs above used the fixed version, with zero decode warnings).

### Evidence

```
$ ps -W | grep -c run-tests
0
$ export S_G="$S/g"
$ perl "$S/g/time-hooks.pl"
g0: n=40 min=27.930 median=30.597 p90=32.313 max=33.113
g1: n=40 min=72.208 median=77.222 p90=82.121 max=84.170
delta(median g1-g0)=46.625
$ perl "$S/g/time-hooks.pl"
g0: n=40 min=26.543 median=30.681 p90=31.951 max=46.383
g1: n=40 min=73.210 median=78.093 p90=81.887 max=95.389
delta(median g1-g0)=47.412
```

Raw driver output for both runs is also saved verbatim at `.../evidence/g/run-a.txt` and `.../evidence/g/run-b.txt`; the fixture payload is `.../evidence/g/payload.json` -- **corrected (MINOR-2): this is the `SessionStart` line of `abc.jsonl` (`head -1`), not the first `PreToolUse` line as originally stated.** It is somewhat smaller than a `PreToolUse` payload (about 340 bytes vs. about 630), so the measured floor and delta may be a slightly optimistic (smaller-than-typical-hook-payload) estimate; re-running with a `PreToolUse` fixture was not done (budget).

### Claude Code version

2.1.280 (not exercised by this item -- no `claude` process runs during the g0/g1 timing; the version is recorded for consistency with AC22, and because the fixture payload was captured from a 2.1.280 session)

### Reproduction

1. `ps -W | grep -c run-tests` (must be run alone, per spec).
2. `head -1 "$S/logs/abc.jsonl" > "$S/g/payload.json"`.
3. Write `$S/g/g0.sh`, `$S/g/g1.sh`, `$S/g/time-hooks.pl` exactly as in Method.
4. `export S_G="$S/g"; perl "$S/g/time-hooks.pl"` -- run twice; a third run is only needed if the two medians differ by more than 25 %.

---

## (h) Hook registration changes in a running session

### Question

Whether a running session picks up a changed hook registration in `.claude/settings.json` or a plugin `hooks.json` without a restart.

### Status

ANSWERED

Answers are for headless `-p` only and do not extrapolate to an interactive session.

### Answer

**First finding, before the real answer: the spec's literal reproduction (the model's own Bash tool running `cp settings.B.json settings.json`) cannot execute headlessly.** Four attempts (h1, h2, h2b, h2c) hit blockers, all of them the harness's own permission system, not the model acting alone:
1. **h1, h2:** writing to `.claude/settings.json` (h1) or a plugin's `hooks.json` (h2) via the model's own `cp` triggered a built-in permission check (`decision_reason_type: "safetyCheck"`, message *"Claude requested permissions to edit ... which is a sensitive file"*), auto-denied in headless mode with no approver -- the copy never happened. Verbatim (`h1-stdout.jsonl`, naming `exp-h1\.claude\settings.B.json`): `{"type":"system","subtype":"permission_denied", ... ,"decision_reason":"Claude requested permissions to edit C:\\Users\\André\\...\\exp-h1\\.claude\\settings.B.json which is a sensitive file."}`.
2. **h2c** hit the same "sensitive file" check for the plugin's `hooks.B.json` (`h2c-stdout.jsonl`, naming `plug-h2\hooks\hooks.B.json` -- **correcting the earlier draft's label of "h1 original design" for this excerpt**).
3. **h2b, corrected (MAJOR-3):** on this attempt the copy used the mandatory 8.3 short-form scratch path (`ANDR~1`/`TMP~1.61A`, required by spec §3.0 to keep the path ASCII given the `André` username). `h2b-stdout.jsonl` shows the **harness's own permission system** flagged it first -- a `system`/`permission_denied` line, `decision_reason_type: "safetyCheck"`, *"Claude requested permissions to write to ...\\TMP~1.61A\\...\\hooks.B.json, which contains a suspicious Windows path pattern that requires manual approval"* -- and only *after* that block does the model's own reply relay it in prose ("The system has blocked this request due to a suspicious Windows path pattern..."). The earlier draft of this section called this "a purely model-side heuristic ... without any hook or permission system being involved"; that is contradicted by the message order in the same file and is corrected here: **the refusal is the harness's permission system reacting to the 8.3 short-path shape, and the model only relays it.** This is a harness fact package 02 needs directly: 8.3 short paths trigger a manual-approval permission gate in headless mode.

None of these are workable within the spec's fixed "standard nested flags" list (no `--dangerously-skip-permissions`/`--permission-mode` was used, since neither is in that list). **Spec deviation, recorded:** the reproduction was changed so the settings/hooks-file swap is done by the *worker*, externally, while the nested `claude -p` process is mid-turn (between its two Bash tool calls, both of which now run innocuous commands instead of the file swap itself) rather than by the model's own tool call. This tests the identical question -- does an already-running process pick up a hook-file change without restarting -- without touching the permission gate above.

**h1 (`.claude/settings.json`): picked up -- headless -p, single run (h1v4).** The nested session ran `sleep 6` as its first Bash call; the worker waited for that call's `PreToolUse` to land in the probe log (config A), then copied `settings.B.json` over `settings.json` mid-sleep; the session's second Bash call (`echo AFTER-SWAP-<nonce>`) landed in log **B**, not A. The change took effect without any restart, within the same running process, inside the same turn. **Two earlier runs of this design exist and their outcome is not recoverable (MAJOR-4):** `h1v2` (`sleep 3`, logged at the time as "racy") and `h1v3` (`sleep 8`) both completed successfully (`"subtype":"success"`, both Bash calls ran, per their surviving `-stdout.jsonl` transcripts), but their probe logs were written to the same `h1-A.jsonl`/`h1-B.jsonl` filenames as h1v4 and were overwritten before being archived, so which log (A or B) received the `AFTER-SWAP` line for v2 and v3 cannot be determined from surviving evidence. The design moved from v2 (3 s sleep, felt racy relative to when the worker's swap script could land) to v3 (8 s) to v4 (6 s, with the swap timing logged precisely, shown below) specifically to remove that raciness; only v4's outcome is backed by surviving per-run logs. **This "picked up" answer therefore rests on n=1 (v4) with unrecoverable, not merely unreported, results for v2/v3** -- do not read "picked up" as replicated.

**h2 (plugin `hooks.json` via `--plugin-dir`): not picked up -- headless -p, single run.** `--plugin-dir` is listed (see Method), so h2 was run directly rather than deferred to H-1. Same design (worker swaps `hooks.json` over `hooks.B.json` mid-sleep, in the plugin's `hooks/` directory this time), but **both** Bash calls landed in log A -- the original registration. Within the ~6-second window tested, a plugin's `hooks.json` change loaded via `--plugin-dir` was **not** hot-reloaded, in contrast to `.claude/settings.json`. **Scope, not extrapolated:** ccpraxis's own hooks ship from a `directory`-source marketplace served by a read-only bind mount, not via `--plugin-dir` -- a materially different loading path that this measurement does not cover. Do not treat "edit `.claude/settings.json` to unregister a stuck gate" as a proven escape hatch for an interactive session; that was not tested (M3).

No CLI warning about changed hooks appeared on stdout/stderr in either case.

### Evidence

```
# h1: worker timeline + resulting logs
saw first PreToolUse in A at iter 40 t=1790199176.658714800
swapped at 1790199176.705326400
=== A (settings.json, before swap) ===
sleep 6
=== B (settings.B.json, after swap) ===
echo AFTER-SWAP-n2412129-h1v4
```

```
# h2: worker timeline + resulting logs
saw first PreToolUse in A at iter 39 t=1790199212.533074500
swapped at 1790199212.584858600
=== A (hooks.json, unchanged throughout) ===
sleep 6
echo AFTER-SWAP-n2412495-h2v2
=== B (hooks.B.json) ===
(empty)
```

```
# h1-stdout.jsonl: the model's own cp of settings.B.json, "sensitive file" denial:
{"type":"system","subtype":"permission_denied","tool_name":"Bash","decision_reason_type":"safetyCheck","decision_reason":"Claude requested permissions to edit C:\\Users\\André\\AppData\\Local\\Temp\\tmp.61a6Uzopja\\exp-h1\\.claude\\settings.B.json which is a sensitive file.", /* trimmed */}
```

```
# h2c-stdout.jsonl (corrected label -- MAJOR-3: this is h2c, not "h1 original design"):
{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"toolu_01KwmdGar3GPxo9Hfk8wjbte","decision_reason_type":"safetyCheck","decision_reason":"Claude requested permissions to edit C:\\Users\\André\\AppData\\Local\\Temp\\tmp.61a6Uzopja\\plug-h2\\hooks\\hooks.B.json which is a sensitive file.", /* trimmed */}
```

```
# h2b-stdout.jsonl: the harness's OWN permission check fires first (line 11), before the model's reply (lines 16-17):
{"type":"system","subtype":"permission_denied","decision_reason_type":"safetyCheck","decision_reason":"Claude requested permissions to write to C:\\Users\\ANDR~1\\AppData\\Local\\Temp\\TMP~1.61A\\plug-h2\\hooks\\hooks.B.json, which contains a suspicious Windows path pattern that requires manual approval.", /* trimmed */}
```

```
# h2b-stdout.jsonl, the model's reply AFTER that harness block -- a relay, not an independent refusal:
{"type":"assistant","message":{... "content":[{"type":"text","text":"The system has blocked this request due to a suspicious Windows path pattern in the command. Before proceeding, I need clarification:\n\nWhat are you trying to accomplish with copying `hooks.B.json` to `hooks.json`? The DOS sho ..." }]} ...}
```

### Claude Code version

2.1.280

### Reproduction

1. h1: `mkdir -p "$S/exp-h1/.claude"`; write `settings.json` (probe on `PreToolUse` only, log `h1-A.jsonl`) and `settings.B.json` (same, log `h1-B.jsonl`).
2. `( bash "$S/bin/run-claude.sh" 60 "$S/exp-h1" --model haiku --output-format stream-json --verbose --allowedTools Bash --setting-sources project,local --max-budget-usd 0.30 -- 'Run these Bash commands as two separate tool calls, in order: 1) `sleep 6` 2) `echo AFTER-SWAP-<nonce>`. Then stop.' > out.jsonl 2> err.txt ) &`
3. Poll `[ -s "$S/logs/h1-A.jsonl" ]` in a loop; once true, `cp "$S/exp-h1/.claude/settings.B.json" "$S/exp-h1/.claude/settings.json"`.
4. `wait`; compare `h1-A.jsonl` and `h1-B.jsonl` for the `AFTER-SWAP` command.
5. h2: `mkdir -p "$S/plug-h2/.claude-plugin" "$S/plug-h2/hooks" "$S/exp-h2/.claude"`; write `plugin.json`, `hooks.json` (probe, log `h2-A.jsonl`), `hooks.B.json` (probe, log `h2-B.jsonl`).
6. Same two-step prompt and poll/swap pattern as h1, but with `--plugin-dir "$S/plug-h2"` and swapping `$S/plug-h2/hooks/hooks.json` from `hooks.B.json`.

---

## NEEDS-OPERATOR

Rewritten by the fix-batch (MAJOR-5) so each checklist is followable, unaided, from a fresh Git Bash shell with no other context. Every path below is spelled out in full; do not substitute `$S`/`<S>` literally -- step 0 defines it.

**Step 0 -- rebuild the scratch project (do this once, before D-1/D-2/D-3):**
1. Open Git Bash. Run:
   ```
   S=$(cygpath -ms "$(mktemp -d)")
   printf '%s' "$S" | perl -ne 'exit(/[^\x00-\x7f]/ ? 1 : 0)' && echo "ASCII ok: $S" || echo "NOT ASCII -- stop, do not proceed: $S"
   mkdir -p "$S/exp-d/.claude" "$S/logs" "$S/bin"
   ```
   If the ASCII check fails, stop and report the path instead of continuing.
2. Save this file as `$S/bin/mkprobe.pl` (byte-for-byte, this is the exact tool the measurement worker used):
   ```perl
   #!/usr/bin/env perl
   use strict; use warnings;
   use JSON::PP;
   # args: out probe log [events-csv, default full set]
   my ($out, $probe, $log, $events_csv) = @ARGV;
   my @events = $events_csv ? split(/,/, $events_csv) : qw(PreToolUse PostToolUse Stop SubagentStop SessionStart SessionEnd UserPromptSubmit PreCompact);
   my $cmd = "CCPRAXIS_HOOK_PROBE_LOG='$log' perl '$probe'";
   my %hooks;
   for my $e (@events) {
     $hooks{$e} = [ { hooks => [ { type => "command", timeout => 15, command => $cmd } ] } ];
   }
   open(my $fh, ">", $out) or die $!;
   print $fh JSON::PP->new->pretty->canonical->encode({ hooks => \%hooks });
   close $fh;
   ```
3. Generate the settings file for `exp-d`:
   ```
   perl "$S/bin/mkprobe.pl" "$S/exp-d/.claude/settings.json" C:/Development/ccpraxis/plugins/butler/scripts/bp-hook-probe.pl "$S/logs/d.jsonl"
   ```
4. `cd "$S/exp-d"`.
5. Start the interactive session with the **same** setting-sources restriction the headless runs used, so no user-level plugin or hook is a confound (spec E10; this is a deliberate extension of the launch line beyond a bare `env -u ...`, for the same reason the package's own §3.0 frame extended Decision 42):
   ```
   env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR claude --model haiku --setting-sources project,local
   ```

The ID-PROMPT referenced below is, verbatim: `Run the Bash command \`echo ENV-SID=$CLAUDE_CODE_SESSION_ID\` and stop.`

### D-1 -- /compact in-process

1. Complete Step 0 above (fresh session, `cd`'d into `$S/exp-d`, launched with the command in step 5).
2. Type the ID-PROMPT and press Enter.
3. Once it replies, type `/compact` and press Enter.
4. Once compaction finishes, type the ID-PROMPT again and press Enter.
5. Record: both `ENV-SID` values shown in the transcript; every `session_id` value in `$S/logs/d.jsonl` written during this session (`grep -o '"session_id":"[^"]*"' "$S/logs/d.jsonl" | sort -u`); the full `PreCompact` payload and the `SessionStart` payload whose `source` is `"compact"`. These are all things the probe already records -- nothing else is needed. Completes the in-process part of section (d).

### D-2 -- /clear in-process

1. Complete Step 0 above (a fresh session; do not reuse D-1's still-open session).
2. Type the ID-PROMPT and press Enter.
3. Once it replies, type `/clear` and press Enter.
4. Type the ID-PROMPT again and press Enter.
5. Record: both `ENV-SID` values; the `session_id` value in `$S/logs/d.jsonl` immediately before and after the `/clear` (a `SessionEnd` with `reason:"clear"` followed by a `SessionStart` with `source:"clear"` marks the boundary); the full `SessionEnd`/`SessionStart` payloads at that boundary. Completes the in-process part of section (d).

### D-3 -- carry-over-style clear

1. Complete Step 0 above (a fresh session).
2. Type the ID-PROMPT and press Enter.
3. Press **Shift+Tab repeatedly** until the footer/status line shows plan mode is active (one press normally cycles default -> accept-edits -> plan -> default; do not assume one press is enough -- watch the footer, not a fixed count).
4. Type: `one-line plan: run ID-PROMPT` (ask it to plan re-running the same ID-PROMPT command), and press Enter.
5. When the plan is presented, select the approval option that clears context (the exact label varies by version -- it is a **menu option to select with arrow keys + Enter**, not a phrase to type; look for wording like "Yes, and clear context"). Record the exact label text shown.
6. Once the new context starts, type the ID-PROMPT again and press Enter.
7. Record exactly as D-1 (both `ENV-SID` values, the `session_id` values in `$S/logs/d.jsonl`, the relevant hook payloads, and the exact menu label from step 5). Completes the carry-over row of section (d).

**E-1, E-2 and E-3 removed by the fix-batch.** Item (e) is now `ANSWERED (interactive)`: `interactive-wakes-abb7e549.jsonl` shows an idle interactive session woken, unattended, by a background Bash task exiting normally, one killed by SIGTERM, and a background Agent completion -- all three of the sub-questions these checklists existed to answer. See (e) above for the evidence and timestamps. If a future package needs a *scripted* (not incidentally-observed) repeat of this, the steps are: rebuild `$S/exp-e/.claude/settings.json` from Method; start an interactive session in it; ask for the e1/e2 command shapes from (e)'s Reproduction, or a subagent dispatch for the Agent case; end the turn; wait 60+ seconds without typing; record whether a new turn appears on its own and the `$S/logs/e.jsonl` lines after the completion.

### H-1 -- plugin hooks.json hot reload

Not needed: `--plugin-dir` **is** present in Claude Code 2.1.280 (see Method's flag table), so h2 was answered headlessly above (worker-driven external swap; **not picked up** within the ~6 s window tested). This checklist is only for a future version where `--plugin-dir` is absent:

1. Rebuild `$S/plug-h2` from Method (§ item h2's reproduction).
2. Start an interactive session with `--plugin-dir "$S/plug-h2"`.
3. Ask the model to run `sleep 6` then, from a separate Git Bash window, copy `hooks.B.json` over `hooks.json` mid-sleep; ask it to run a second marker command.
4. Record which log (`h2-A.jsonl` or `h2-B.jsonl`) the second marker lands in.
