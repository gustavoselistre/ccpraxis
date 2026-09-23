# Butler hook architecture

The target design for butler's hooks, written by package 02 of blueprint `hook-continuity-remake`.
Packages 03-16 implement it. After the cutover, package 16 owns this file and its coverage test
(`plugins/butler/tests/t/hook-architecture-coverage.t`) and keeps both in step with `hooks/`.

The system in one paragraph: every hook is a short shell file that execs one wrapper, and the wrapper
either exits in bash (the hook does not apply to this session) or execs one perl process that loads
`BpHook.pm` inside an exit-0 guard and parses the payload once. Continuity is one per-session file,
written by three commands and one hook. The Stop gate blocks only when that file exists and there is
no live holder and no silence. When it blocks, the agent sees 7 lines, and those lines carry a
single-use stop token the gate itself minted. With that token, `butler-hold`, `butler-continuity off`
and `butler-continuity silence` work even if every other hook has failed. There are no override files.

## Harness facts and what they decided

Evidence: `plugins/butler/docs/harness-facts.md` (Claude Code 2.1.280). Each fact below changed a choice.

| fact | what it forced |
|---|---|
| A missing perl script exits 2, and 2 is the blocking code on every event (Method). Measured by red-team: `perl -MX` where X fails to load also exits 2 | Every registration is guarded. `run-hook.sh` checks `BpHook.pm` exists, and perl loads it with `require` inside `eval`, never with `-M` or `use`. An END block forces the exit code to 0 unless the hook deliberately returned 2. |
| (a) Stop payloads carry `background_tasks` (entries with `id`, `type` `subagent` or `shell`, `status`), not `agent_id`. Tool payloads carry `tool_use_id`, plus `agent_id`/`agent_type` inside a subagent. SubagentStop is a separate event | A holder counts only while one of its held ids is `running` in `background_tasks`. Dispatch binding keys on `tool_use_id`. Subagent context is "payload has `agent_id`". Only `Stop` is registered, so a subagent's own stop is never gated and never mints a token. |
| (b) A subagent's tool calls carry the parent's `session_id` | Subagents share the session's arm state and are told apart by `agent_id` alone. Forks were not measured (see Session roles). |
| (c) `agent-<id>.meta.json` exists before a background subagent's first PreToolUse. Foreground dispatch was not measured | Write guards resolve a subagent's package through `meta.json` `toolUseId`. An unresolvable binding with two or more packages in flight is refused, not widened. |
| (d) `/clear` allocates a new `session_id`. `--resume` and headless `/compact` keep it. In-process env behaviour is open (D-1..D-3) | All state is keyed by the payload `session_id`. No component reads `$CLAUDE_CODE_SESSION_ID`. Commands learn their session from a hook-written ticket or a gate-minted stop token. |
| (e) Background Bash (normal exit or killed) and background Agent completions wake an idle interactive session. A killed task is reported as `failed with exit code 143`. Headless `-p` kills a running background Bash a few seconds after its final result | The holder is a background Bash task whose exit at the deadline is the wake-up. Re-invocation extends, never replaces. A headless coordinator's holder counts only alongside a running background subagent (see Holder protocol). |
| (f) Stop exit 2 feeds stderr back as a synthetic user message and forces a paid turn. `stop_hook_active` is not a counter. No retry cap was observed | The denial is 7 lines. The gate never keys on `stop_hook_active`. There is no block cap (Decisions 6 and 45). The way out that depends on no other hook is the stop token (see Constraint conflicts). |
| (g) Bash hook floor ~30.6 ms, one perl parse adds ~47 ms | Every hook has a bash-only early exit that spawns nothing, and env-only prefilters run before stdin is read. Decision 33's target is ~131 ms for the applies path. |
| (h) In one headless run each, `.claude/settings.json` hot-reloaded and plugin `hooks.json` did not | Settings changes land in the same commit as the files they point at. The no-shim verdict rests on exit 127 being non-blocking; (h) only supports it (see Shims). |
| Method: `--max-turns` is absent from `claude --help` in 2.1.280 | Nothing in this design relies on a turn cap, for coordinators or anyone else. |
| 7417f0c: `/proc/<pid>/stat` costs 45-70 ms per read on this host; `cmdline`, `cwd`, `exename` and `ppid` cost under 1 ms | Holder liveness reads a pid and `/proc/<pid>/cmdline` only, never `stat` or `status`. |

## Inventory

Every regular file directly in `plugins/butler/hooks/` and every hook registration in
`plugins/butler/hooks/hooks.json` and `.claude/settings.json` has one row below (Decision 14). The
new hooks are built under `plugins/butler/hooks/next/` and `plugins/butler/hooks/next/guards/`, and
package 16 flattens both into `hooks/` (Decision 40). So a "merge into" target under `next/` ends at
`hooks/<basename>`. Nine successors land at the path of the file they replace (guard-bash.sh,
guard-git-mutations.sh, gate-shutdown.sh, guard-blueprint-write.sh, guard-ask-operator.sh,
track-dispatch.sh, wait-shape-guard.sh, guard-writes.sh, ledger-guard.sh). Their old tests keep
running against the successor as a regression floor.

Retired outright (Decision 6): `.reporter-stop-ok`, `.subagent-guard/force-stop`,
`.drive-solo/.stop-ok`, `.drive-solo/.run-finished`, the continuity `MARK.stop-ok`,
`CCPRAXIS_DRIVE_STOP_OK`, `CCPRAXIS_REPORTER_STOP_OK`, `CCPRAXIS_CONTINUITY_STOP_OK`, and
`MAX_BLOCKS=3` (Decision 45). Also retired: the three machine registries (`.drive-solo-active`,
`.reporter-active`, `.continuity-active`), both watchers (`bp-watch.pl --arm`, `bp-continuity.pl hold`)
and the wakeup-pending markers. Decision 4 keeps only the fleet files `runs/.paused`, `runs/.shutdown`
and `runs/<pkg>.force-stop`.

**Target registrations after the cutover** (Decision 5: exactly one Stop entry across both files):

| source | event | matcher | hook |
|---|---|---|---|
| hooks.json | PreToolUse | Bash | guard-bash.sh, guard-git-mutations.sh --only-during-butler-run, arm-on-entry.sh, continuity-off-check.sh |
| hooks.json | PreToolUse | Edit\|Write\|MultiEdit\|NotebookEdit | guard-writes.sh, ledger-guard.sh, guard-blueprint-write.sh |
| hooks.json | PreToolUse | Edit\|Write\|MultiEdit\|NotebookEdit\|Task\|Agent | gate-shutdown.sh |
| hooks.json | PreToolUse | Task\|Agent | bind-dispatch.sh, track-dispatch.sh |
| hooks.json | PreToolUse | Task\|Agent\|Bash | context-ceiling.sh |
| hooks.json | PreToolUse | (none) | wait-shape-guard.sh |
| hooks.json | PreToolUse | AskUserQuestion | guard-ask-operator.sh |
| hooks.json | PostToolUse | Task\|Agent | track-dispatch.sh |
| hooks.json | PostToolUse | Task\|Agent\|Bash | context-ceiling.sh |
| hooks.json | Stop | (none) | stop-gate.sh |
| settings.json | PreToolUse | Bash | guard-git-mutations.sh (bare path, unchanged) |

This is 16 hooks.json commands, down from 30, and 1 settings.json command, down from 3. PreToolUse on
Bash drops from 11 hook processes (10 hooks.json entries that match Bash plus the settings.json guard)
to 7 (6 plus 1). In a session none of them applies to, none of the 7 starts perl.

**Shims (Decision 38).** Before the cutover `.claude/settings.json` registers two script paths.
`guard-git-mutations.sh` keeps its path, because its successor is flattened to the same file.
`guard-subagent-stall.sh` gets no forwarding shim. The reason is that its entry runs the script path
directly, so a session that still holds the old registration gets exit 127 from the missing file, and
127 does not block. Harness-facts (h) supports this: in one headless run a changed settings.json was
re-read by the running session, which is the Decision 38 exemption. It is not proof for interactive
sessions, and the design does not need it to be. Every commit that touches hooks still meets
Decision 38's check: each registered command exists, passes `bash -n`, and exits 0 or 2 on an empty
payload.

### file: context-ceiling-flush.sh
verdict: merge into `plugins/butler/hooks/next/guards/context-ceiling.sh`
reason: The hard-ceiling denial for coordinators stays, because a coordinator past its context ceiling must flush its ledger before it dispatches more work. It shares the guidance hook's probe, early exit and state, so both become one guard with a PreToolUse and a PostToolUse branch and one probe call per invocation.

### file: context-ceiling-guidance.sh
verdict: merge into `plugins/butler/hooks/next/guards/context-ceiling.sh`
reason: The soft-ceiling reminder is the PostToolUse half of the same context-ceiling rule, reads the same probe and applies to the same sessions (coordinators only), so it merges with the flush guard rather than surviving as a second copy of the same gating logic.

### file: dispatch-discipline-nudge.sh
verdict: delete
reason: It never blocks; it attaches advisory text when a coordinator's own tool calls outnumber its dispatches, after a whole-transcript scan. Advisory prose attached to tool results is the agent-facing noise this remake removes, and the context-ceiling guard already enforces the costly end of the same problem.

### file: gate-continuity.sh
verdict: merge into `plugins/butler/hooks/next/stop-gate.sh`
reason: Its rule, that an armed session may not end a turn unless something will resume it, is the Decision 1 condition, so it becomes the one Stop gate. Its wakeup-pending markers, MARK.stop-ok file and CCPRAXIS_CONTINUITY_STOP_OK variable are retired, and its /proc stat fingerprinting gives way to the holder record's cheap cmdline fingerprint; the new gate reads the arm file, the silence record, the holder record and the stop token.

### file: gate-drive-loop.sh
verdict: delete
reason: Its driver branch and reporter branch are replaced by the generic armed-session rule of the one Stop gate, because drivers and reporters are simply armed sessions. Everything specific to this file is retired by Decisions 6 and 45: the bp-watch.pl probe, the .run-finished and .stop-ok files, both STOP_OK variables and the three-block bound.

### file: gate-headless-background.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: The rule that a headless coordinator or judge may not background a Bash call, because its turn ending ends the process, is kept as one rule of the merged Bash guard, which shares its BP_LEDGER early exit. The merged rule exempts a command that is exactly one butler-hold invocation and nothing else, so that a coordinator can hold under Decision 4 without backgrounding other work.

### file: gate-shutdown.sh
verdict: merge into `plugins/butler/hooks/next/guards/gate-shutdown.sh`
reason: Decision 4 keeps the fleet stop contracts: under runs/.shutdown, runs/.paused or runs/<pkg>.force-stop a coordinator may not start new work or edit the worksite. The behaviour is preserved and rebuilt on the core, with one registration covering the edit tools and Task or Agent dispatch instead of two.

### file: gate-stop.sh
verdict: merge into `plugins/butler/hooks/next/stop-gate.sh`
reason: The coordinator ledger rule moves unchanged into the coordinator branch of the one Stop gate that Decision 5 requires: a terminal and fresh ledger, a concrete Next action when blocked or parked, the paused variant, force-stop consumption, the registry status sync and last_updated stamping.

### file: guard-ask-operator.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-ask-operator.sh`
reason: Refusing AskUserQuestion while unattended work runs, and queueing the question, is kept. The rebuild reads the one arm state for THIS session (bug 20260922-210421-0468), writes the legacy queue until package 09 moves it (Decision 22), and its message drops the .run-finished instruction, which no longer exists.

### file: guard-bash.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: The coordinator Bash denials are kept: git history and working-tree mutation, rm -rf outside scratch paths, deploys and BP_BASH_EXTRA_DENY. This file becomes the merged PreToolUse Bash guard that also carries the headless-background, judge-checks and validation-interlock rules, so one process parses the payload once instead of four.

### file: guard-blueprint-write.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-blueprint-write.sh`
reason: Direct edits to blueprint.md stay denied in every session, forcing the typed bp-blueprint.pl write path. The ledger-creation guard inspects the same tools and the same blueprint tree with the same shape of check, so both become one guard with one early exit on the payload text.

### file: guard-git-mutations.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-git-mutations.sh`
reason: The destructive-git denial stays a guard of its own because it has two registrations with different scope: always, from this repo's settings.json, and only while this session runs butler work (armed or coordinator), from hooks.json. After the Decision 40 flatten it lands back at its current path, so the settings.json command never changes. In this repo both registrations run, as they do today; there is no de-duplication between them.

### file: guard-judge-checks.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Refusing pnpm, npm and yarn lint, build and test re-runs inside a harvest judge is kept as one rule of the merged Bash guard, gated on BP_ROLE=harvest-judge, so it costs nothing outside a judge and needs no separate process anywhere.

### file: guard-ledger-create.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-blueprint-write.sh`
reason: Denying hand-written package ledgers, which forces bp-ledger.pl create, is kept together with its evidence-gated ledger-write-override, and merged into the blueprint write guard because both inspect the same Edit and Write payloads for paths under a blueprints tree.

### file: guard-run-finish.sh
verdict: merge into `plugins/butler/hooks/next/continuity-off-check.sh`
reason: Its one lasting idea, that only the operator's own latest message can authorise ending unattended work, becomes the operator-off check of Decision 37. The .run-finished marker it guarded and the bp-runstate finish path are retired, so only the transcript reading survives the move, tightened to a whole-message slash-command record.

### file: guard-subagent-stall.sh
verdict: delete
reason: Its dispatch-activation state machine, the bp-watch.pl probe it consults and the .subagent-guard/force-stop override are all retired by Decisions 1 and 6. A stalled background subagent is now covered by the one Stop gate plus the 50-minute holder, whose exit wakes the session. Bug 20260923-020433-8d6e disappears with the file.

### file: guard-validation-interlock.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Denying test, build and lint commands while a write-capable worker is in flight is kept as a rule of the merged Bash guard. Its drive-solo branch now applies only when THIS session is armed as a driver, instead of whenever any drive is active in the project, and it exempts the worker that owns the marker.

### file: guard-writes.sh
verdict: merge into `plugins/butler/hooks/next/guard-writes.sh`
reason: Write-set containment and role separation are kept and rebuilt by package 13 so that the driver's edits and each subagent's edits are checked against the package bound to that subagent (Decision 16), and only in the driving session or a coordinator.

### file: hooks.json
verdict: keep
reason: It remains the plugin's hook registry. Package 16 rewrites its contents to the target registration table in this section, with every command in the guarded form and exactly one Stop entry, which is the only change the file needs.

### file: hooks.json.about
verdict: delete
reason: It is a stale one-line description of registrations that no longer match hooks.json, and nothing in the repository reads it. The registration table in this section replaces it as the description of what is registered and why.

### file: ledger-guard.sh
verdict: merge into `plugins/butler/hooks/next/ledger-guard.sh`
reason: Validating the resulting content of a package-ledger write stays fail-closed: control bytes, frontmatter, required keys, the status set and required sections. Package 13 rebuilds it on the core with the same subagent-aware package resolution as the write guard.

### file: lib.sh
verdict: merge into `plugins/butler/scripts/BpHook.pm`
reason: The payload reader, JSON getter, registry accessors and driver-context predicate are replaced by the core's single payload parse and per-session accessors. The three machine registries it resolves are retired, and package 16 inlines the three helpers bp-worker.pl borrows from it.

### file: log-dispatch.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Appending the mechanical dispatch line to the coordinator ledger and clearing the worker marker happen at the same PostToolUse point as the completion half of track-dispatch, so one tracker does both jobs.

### file: mark-wakeup.sh
verdict: merge into `plugins/butler/hooks/next/arm-on-entry.sh`
reason: Only its arming block survives: a real invocation of the drive-solo director arms the calling session, now in the one arm state. Its wakeup-pending markers are retired because Decision 1 counts only a live holder, and the reporter registry it wrote is retired by Decision 24.

### file: record-dispatch-package.sh
verdict: merge into `plugins/butler/hooks/next/bind-dispatch.sh`
reason: Recording tool_use_id to package for every dispatch is the Decision 16 binding. Package 12 extends it to the in-flight set, adds the one-ledger rule, writes one lookup file per tool_use_id, and keeps appending the history line in today's shape so bp-spend.pl reads both stores with one parser.

### file: repeat-guard.sh
verdict: merge into `plugins/butler/hooks/next/guards/wait-shape-guard.sh`
reason: The identical-call detector is kept for coordinators. It is registered on every tool with the same BP_LEDGER early exit as the wait-shape guard, and both detect polling pathologies, so one guard with one state file per session serves both.

### file: track-dispatch.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: The one-write-capable-worker rule, the worker marker and the running and done dispatch records are kept, and this becomes the single dispatch tracker for coordinators and armed drivers, absorbing log-dispatch and both solo trackers.

### file: track-worker-solo.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: It writes the drive-solo twin of the coordinator worker marker. The merged tracker writes one marker per write-capable dispatch, named by its tool_use_id, keyed on the armed-driver role instead of a project-wide drive marker.

### file: untrack-worker-solo.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Its compare-and-clear of the drive-solo worker marker is the PostToolUse half of the merged tracker, and the session check it added through a sidecar file becomes a session field inside the marker itself.

### file: wait-shape-guard.sh
verdict: merge into `plugins/butler/hooks/next/guards/wait-shape-guard.sh`
reason: The four polling pathologies it denies are kept for coordinators (sleep loops, false-green pipes, task-output polls and repeated TaskOutput), with the repeat detector folded in, and every denial is cut to the message budget set in this document.

### registration: hooks.json PostToolUse [Task] log-dispatch.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Replaced by the single PostToolUse Task|Agent registration of the merged tracker, which appends the ledger line and resolves the dispatch record in one process.

### registration: hooks.json PostToolUse [Task] track-dispatch.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Becomes the PostToolUse Task|Agent registration of the merged tracker; the matcher gains Agent because Claude Code 2.1.280 names the dispatch tool Agent.

### registration: hooks.json PostToolUse [Task|Agent] untrack-worker-solo.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Covered by the same PostToolUse Task|Agent registration of the merged tracker, so the separate drive-solo untracker registration is no longer needed.

### registration: hooks.json PostToolUse [Task|Bash] context-ceiling-guidance.sh
verdict: merge into `plugins/butler/hooks/next/guards/context-ceiling.sh`
reason: Becomes the PostToolUse Task|Agent|Bash registration of the merged context-ceiling guard, which attaches the soft-ceiling guidance from its PostToolUse branch.

### registration: hooks.json PostToolUse [Bash|Read|Edit|Grep] dispatch-discipline-nudge.sh
verdict: delete
reason: The script is deleted, so its registration goes with it; nothing replaces the advisory, and the post-cutover table has no PostToolUse entry on Read, Edit or Grep.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] gate-shutdown.sh
verdict: merge into `plugins/butler/hooks/next/guards/gate-shutdown.sh`
reason: Folded into the single gate-shutdown registration whose matcher covers the four edit tools plus Task and Agent, replacing today's two separate entries for the same script.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] guard-writes.sh
verdict: merge into `plugins/butler/hooks/next/guard-writes.sh`
reason: Re-registered on the same four edit tools, pointing at the package-13 successor in the guarded command form, which after the flatten sits at the same path.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] ledger-guard.sh
verdict: merge into `plugins/butler/hooks/next/ledger-guard.sh`
reason: Re-registered on the same four edit tools, pointing at the package-13 successor in the guarded command form, which after the flatten sits at the same path.

### registration: hooks.json PreToolUse [Bash] guard-git-mutations.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-git-mutations.sh`
reason: Re-registered on Bash with the same --only-during-butler-run argument, now meaning this session is armed or is a coordinator, instead of any drive being active in the project.

### registration: hooks.json PreToolUse [Bash] guard-bash.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Becomes the one registration of the merged Bash guard, which replaces four of today's seven PreToolUse Bash entries in hooks.json.

### registration: hooks.json PreToolUse [Bash] mark-wakeup.sh
verdict: merge into `plugins/butler/hooks/next/arm-on-entry.sh`
reason: The Bash registration carried the drive-solo arming check, which now lives in arm-on-entry.sh registered on Bash in the guarded form.

### registration: hooks.json PreToolUse [Bash] gate-headless-background.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Its rule runs inside the merged Bash guard's process, so the separate registration and its extra process per Bash call are removed.

### registration: hooks.json PreToolUse [Bash] guard-judge-checks.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Its rule runs inside the merged Bash guard's process, so the separate registration and its extra process per Bash call are removed.

### registration: hooks.json PreToolUse [Bash] guard-validation-interlock.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-bash.sh`
reason: Its rule runs inside the merged Bash guard's process, so the separate registration and its extra process per Bash call are removed.

### registration: hooks.json PreToolUse [Bash] guard-run-finish.sh
verdict: merge into `plugins/butler/hooks/next/continuity-off-check.sh`
reason: The Bash registration that watched for run-ending commands is replaced by the continuity-off-check registration on Bash, which watches butler-continuity and butler-hold invocations.

### registration: hooks.json PreToolUse [Task] gate-shutdown.sh
verdict: merge into `plugins/butler/hooks/next/guards/gate-shutdown.sh`
reason: Folded into the single gate-shutdown registration whose matcher covers the edit tools plus Task and Agent, so a dispatch under a fleet stop is still denied.

### registration: hooks.json PreToolUse [Task] track-dispatch.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Becomes the PreToolUse Task|Agent registration of the merged tracker, which also absorbs the drive-solo tracker's registration on the same tools.

### registration: hooks.json PreToolUse [Task] mark-wakeup.sh
verdict: delete
reason: On Task it only wrote a wakeup-pending marker, which Decision 1 retires because only a live holder lets an armed session stop; nothing replaces this registration.

### registration: hooks.json PreToolUse [] repeat-guard.sh
verdict: merge into `plugins/butler/hooks/next/guards/wait-shape-guard.sh`
reason: Folded into the single matcher-less registration of the merged wait-shape guard, which runs both polling detectors in one process per tool call.

### registration: hooks.json PreToolUse [] wait-shape-guard.sh
verdict: merge into `plugins/butler/hooks/next/guards/wait-shape-guard.sh`
reason: Becomes the single matcher-less registration of the merged wait-shape guard, in the guarded command form, at the same flattened path.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] guard-blueprint-write.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-blueprint-write.sh`
reason: Becomes the one registration of the merged blueprint write guard on the four edit tools, which also carries the ledger-creation rule.

### registration: hooks.json PreToolUse [Agent] mark-wakeup.sh
verdict: delete
reason: On Agent it only wrote a wakeup-pending marker, which Decision 1 retires because only a live holder lets an armed session stop; nothing replaces this registration.

### registration: hooks.json PreToolUse [Task|Agent] track-worker-solo.sh
verdict: merge into `plugins/butler/hooks/next/guards/track-dispatch.sh`
reason: Covered by the merged tracker's PreToolUse Task|Agent registration, which writes the worker marker for armed drivers as well as coordinators.

### registration: hooks.json PreToolUse [Task|Agent] record-dispatch-package.sh
verdict: merge into `plugins/butler/hooks/next/bind-dispatch.sh`
reason: Replaced by the bind-dispatch registration on Task|Agent, which records the same tool_use_id binding and may also deny an ambiguous dispatch.

### registration: hooks.json PreToolUse [AskUserQuestion] guard-ask-operator.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-ask-operator.sh`
reason: Re-registered on AskUserQuestion in the guarded form; the successor lands at the same path, where package 09 later re-points it at the almanac store.

### registration: hooks.json PreToolUse [Task|Bash] context-ceiling-flush.sh
verdict: merge into `plugins/butler/hooks/next/guards/context-ceiling.sh`
reason: Becomes the PreToolUse Task|Agent|Bash registration of the merged context-ceiling guard; Agent is added so a dispatch past the hard ceiling is denied under either tool name.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] guard-ledger-create.sh
verdict: merge into `plugins/butler/hooks/next/guards/guard-blueprint-write.sh`
reason: Its rule runs inside the merged blueprint write guard's process, so this separate registration on the same four edit tools is removed.

### registration: hooks.json Stop [] gate-stop.sh
verdict: merge into `plugins/butler/hooks/next/stop-gate.sh`
reason: The coordinator ledger rule moves into the one Stop registration, which is the only Stop entry left in either file (Decision 5).

### registration: hooks.json Stop [] gate-drive-loop.sh
verdict: delete
reason: Its gate is deleted and the driver case is covered by the one Stop registration, so this second Stop entry must go for Decision 5 to hold.

### registration: hooks.json Stop [] gate-continuity.sh
verdict: merge into `plugins/butler/hooks/next/stop-gate.sh`
reason: Its armed-session rule is the Decision 1 condition, so this entry becomes the one Stop registration, pointing at stop-gate.sh in the guarded form.

### registration: settings.json PostToolUse [Task|Bash] guard-subagent-stall.sh
verdict: delete
reason: The script is deleted. Package 16 removes the entry without a forwarding shim (Decision 38): an entry that still points at the missing file exits 127, which does not block, and harness-facts (h) supports the exemption by showing one headless session re-read settings.json.

### registration: settings.json PreToolUse [Bash] guard-git-mutations.sh
verdict: keep
reason: This repo keeps its unconditional protection against destructive git, run from the clone by $CLAUDE_PROJECT_DIR. The successor is flattened to the same path, so the command string stays byte-identical and no shim or edit is needed.

### registration: settings.json Stop [] guard-subagent-stall.sh
verdict: delete
reason: A second Stop entry would break Decision 5, and the script is deleted; the same no-shim reasoning as its PostToolUse sibling applies, since a stale entry exits 127 and does not block.

## BpHook core API

Package 03 builds `plugins/butler/scripts/BpHook.pm` and `plugins/butler/hooks/next/run-hook.sh`.
The core is the only code that decides "is this session running butler work" (Decision 3). Every
hook reads that answer through it, and none asks whether any drive is active in the project, which
was the defect behind bug 20260922-210421-0468. Everything below is tested in-process in
`plugins/butler/tests/t/hook-core-api.t`, with `BUTLER_STATE_DIR` pointed at a tempdir and payloads
passed as hashes (Decision 12).

### Entry path and process budget

Harness-facts records the rule that each perl hook is registered guarded, as
`[ -f "$f" ] || exit 0; exec perl "$f"`, because `perl <missing file>` exits 2 and 2 blocks. In this
design every registered command runs bash, and the one perl exec is guarded inside the wrapper.
Registration form, with spaces around each `;`. The coverage test takes the first token that ends in
`.sh` as the script name, and a token ending in `;` would hide it:

```
f="${CLAUDE_PLUGIN_ROOT}/hooks/stop-gate.sh" ; [ -f "$f" ] || exit 0 ; exec bash "$f"
```

Each per-hook file (stop-gate.sh, arm-on-entry.sh, the guards, and the rest) is exactly this shape,
with its own module name and its own prefilter clauses (see Guard message budgets). The file belongs
to the package that owns the hook, so a package changes its own prefilter without touching 03's files:

```
#!/usr/bin/env bash
# stop-gate.sh -- the one Stop gate. Logic in BpHook/StopGate.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" StopGate --pre ledger,armed -- "$@"
```

`run-hook.sh <Module> [--pre <clause>]... -- [hook args]` uses bash builtins only. It never uses
`$(...)`, a pipe or an external command on the path to the early exit. A clause is a comma-separated
list of atoms and holds when any atom holds. The hook applies only when every clause holds. The atoms
are a closed set owned by 03:

| atom | holds when |
|---|---|
| `ledger` | `BP_LEDGER` is non-empty |
| `coordinator` | `BP_LEDGER` is non-empty and `BP_ROLE` is empty or `coordinator` |
| `stopfile` | `BP_DIR` is set and `runs/.shutdown`, `runs/.paused` or `runs/$BP_PACKAGE.force-stop` exists under it |
| `armed` | `armed/<sid>` exists, or the session id could not be extracted |
| `driver` | the first line of `armed/<sid>` contains `"role":"driver"`, or the session id could not be extracted |
| `text:<s>` | the raw payload contains `<s>` |

Steps:

1. `r=${BASH_SOURCE[0]}` (this file's own path). Parse the `--pre` clauses up to `--`.
2. Evaluate every clause made only of env atoms (`ledger`, `coordinator`, `stopfile`). If one fails,
   `exit 0` before reading stdin, as today's hooks already do.
3. Bulk read: `IFS= read -r -N 8388608 -t 10 BP_PAYLOAD`. Never `$(cat)`, which hung forever on an
   inherited pipe (bug 20260828-095201-7c1e), and never `read -d ''`, which reads a pipe one byte per
   syscall (red-team measured 5.7 s for 200 KB). A status above 128 (timeout), or a payload of exactly
   the cap, sets `BP_PAYLOAD_TRUNCATED=1`.
4. Extract the session id without forking: `sid=${BP_PAYLOAD#*\"session_id\":\"}; sid=${sid%%\"*}`,
   kept only if `[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]]`. If extraction fails, `armed` and `driver`
   count as holding, so the wrapper falls through to perl and never exits on a guess.
5. Evaluate the remaining clauses. When one fails, `exit 0`. That path costs one bash process and no perl.
6. `s=${r%/*}/../scripts`, and if `$s/BpHook.pm` is missing, `s=${r%/*}/../../scripts` (while under
   `next/`). If it is still missing, `exit 0`. Then:

```
exec perl -I"$s" -e 'our $X = 0; END { $? = $X } my $r = eval { require BpHook; BpHook::main(@ARGV) }; $X = (defined $r && $r == 2) ? 2 : 0; exit $X' "$module" "$@" <<<"$BP_PAYLOAD"
```

The module is loaded by `require` inside `eval`, so a missing dependency, a compile error or a `die`
at load time becomes exit 0. `main` loads the per-hook module (`BpHook::<Module>`) with `require`
inside its own `eval`, never with `use`. The END block overrides `$?`, so even a module that calls
`exit` itself cannot produce anything but 0, unless `main` returned 2. For the Stop gate, exit 0 means
the stop is allowed. That is the gate's fail direction, and it is what makes a broken promotion fail
open instead of looping. `hook-core-spawn-budget.t` includes one case where `BpHook.pm` `require`s a
missing module, and asserts exit 0.

Registration shell, hook file, wrapper and perl form one `exec` chain, so an invocation is one
process. That meets Decision 33's budget (the wrapper plus at most one perl, payload parsed once) and
Decision 20's at-most-one-perl rule. `plugins/butler/tests/t/hook-core-spawn-budget.t` proves it with
the PATH shim, and times a 30 KB and a 200 KB payload alone for the ledger. The wall-time target is
harness-facts (g)'s floor plus 100 ms, about 131 ms, measured alone and recorded in the ledger, never
asserted in the sweep.

### Perl API (`BpHook.pm`)

```
main($module, @args)          -> exit code. Reads STDIN once, in bulk (binmode, sysread loop), decodes
                                 once, requires and calls BpHook::<Module>::run($payload, @args) inside
                                 eval. Returns 2 only when run() returned 2; any exception -> 0, plus
                                 one line appended to <state>/hook-errors.log (rolled at 256 KiB).
                                 Modules never call exit.
payload()                     -> the decoded hashref; {} if the JSON is bad or BP_PAYLOAD_TRUNCATED.
payload_ok()                  -> false when payload() had to return {}. Fail-closed hooks deny on it.
session_id($p)                -> payload session_id if it matches ^[A-Za-z0-9_-]{1,128}$, else undef.
agent_id($p)                  -> undef when the payload has no agent_id (main thread). When present:
                                 the id if it matches ^[A-Za-z0-9_-]{1,64}$, else '?'. Defined means a
                                 subagent is calling; '?' is never used to build a path.
role($p)                      -> 'coordinator' | 'judge' | 'driver' | 'reporter' | 'manual'.
is_armed($sid)                -> true for a coordinator; else armed/<sid> exists. No age test.
arm($sid, role=>R, by=>B, transcript_path=>T)  -> under flock armlock/<sid>: writes armed/<sid>,
                                 removes off/<sid> only when B is 'on'.
disarm($sid, actor=>A, reason=>T) -> under flock armlock/<sid>: removes armed/<sid>, silence/<sid>,
                                 holder/<sid>.json and the session's stop token; writes off/<sid>.
latest_is_off($sid)           -> off/<sid> exists (Decision 36).
set_silence($sid, reason=>T)  -> writes silence/<sid>. Only butler-continuity.pl calls it.
take_silence($sid)            -> 1 iff silence/<sid> parses, names this sid, carries a reason of 2+
                                 words and "by":"butler-continuity", and this call unlinked it. A
                                 malformed file (for example one made by touch) is unlinked and ignored.
holder($sid)                  -> holder record hashref or undef.
holder_live($sid, $p)         -> the liveness rule of the Holder protocol section.
log_reason($sid, $actor, $verb, $text, $project) -> appends one reason-log line.
invocations($command, $name)  -> list of argv arrayrefs, one per REAL invocation of $name.
write_ticket($p, $name, \@argv, operator=>0|1, background=>0|1) -> command binding (below).
take_ticket($name, \@argv)    -> the ticket hashref, undef (none), or the string 'ambiguous'.
mint_stop_token($sid)         -> a fresh token string, or undef when it cannot be stored.
revoke_stop_token($sid)       -> removes this session's token, if any.
take_stop_token($token)       -> the session id the token was minted for, or undef. Single use.
gc_sessions()                 -> removes state of sessions whose recorded transcript file is gone.
state_dir()                   -> continuity state root, or undef (then nothing is armed). The one
                                 resolver: hooks, commands and the statusline all call it.
data_dir($p)                  -> the project's .ccpraxis-local-data, or undef.
deny(@lines)                  -> prints the lines to STDERR, returns 2.
context($text)                -> prints {"hookSpecificOutput":{"hookEventName":...,
                                 "additionalContext":$text}} to STDOUT, returns 0.
```

### Session roles

The payload's `session_id` is authoritative (Constraints H6, harness-facts (b) and (d)). The role is
resolved per invocation, in this order:

| role | how it is known | armed |
|---|---|---|
| coordinator | `BP_LEDGER` is set in the hook's environment and `BP_ROLE` is empty or `coordinator` | by construction (Decision 2). There is no file, and it can never be turned off or silenced (Decision 25). |
| judge | `BP_LEDGER` is set and `BP_ROLE` is anything else (harvest, resolve or conformance judge) | never. A one-shot process must be free to end. |
| driver | `armed/<sid>` exists with `"role":"driver"` (written by arm-on-entry at the director call, or by the drive-solo skill's first step `butler-continuity on --role driver`) | yes |
| reporter | `armed/<sid>` exists with `"role":"reporter"` (`butler-continuity on --role reporter`, the reporter skill's first step, Decision 24) | yes |
| manual | anything else, including an armed session with `"role":"manual"` (`/butler:continuity on` or agent self-arm) | only when the file exists |

Role `reporter` changes no gate or guard behaviour. It is recorded so that `status` shows what armed
the session, and it keeps the four roles apart for the done criteria of package 03.

**Subagents and forks.** A subagent's tool calls carry its parent's `session_id` (harness-facts (b)),
so it shares the session's role and arm state, and `agent_id` is how it is told apart. A **fork** is a
subagent dispatched with `subagent_type: fork`. It inherits the parent's whole conversation, including
a driver's live task state and instructions. It is not a second session, has no role of its own, and
is never the driver. The core does not rely on `agent_type` being `fork`. Every rule below applies to
any payload that carries an `agent_id`. Bug 20260922-205201-f421 (Decision 46) is closed by three such
rules. A subagent's director call arms nothing and is denied in a driving session (arm-on-entry). A
subagent's dispatch is denied in a driving session (bind-dispatch). A subagent's
`butler-continuity on|off|silence` and `butler-hold` are refused when its ticket carries an `agent_id`.

Harness-facts (a) measured `agent_id` only for `general-purpose` subagents, not for forks. **Package 03
obligation:** before any rule relies on it, capture one fork's PreToolUse with
`plugins/butler/scripts/bp-hook-probe.pl` in a nested `claude -p` in a scratch project (the Decision 28
method) and record in its ledger whether `agent_id` is present. If it is, the rules above stand. If it
is not, package 12's bind-dispatch also denies, in a driving session, any main-thread Agent dispatch
whose `tool_input.subagent_type` is `fork`, with one line:
`No fork dispatch while this session drives; name a subagent type instead.`

### Command binding: tickets and stop tokens

A Bash command is never told its session, and `$CLAUDE_CODE_SESSION_ID` is unverified in-process after
`/compact` or `/clear` (D-1, D-2). A hook is told. Two bindings exist, and the escape path needs only
the second.

**Tickets** (any time, for example arming when no stop is pending). The PreToolUse hook
`continuity-off-check.sh` writes one ticket per real invocation of `butler-continuity` or `butler-hold`
whose argv it can predict:

- Key: `k` = lowercase hex SHA-1 (core `Digest::SHA`) of `join("\0", $name, @argv)`, where `$name` is
  normalised to `butler-continuity` or `butler-hold`. The command computes the same `k` from its own
  `@ARGV`, so a ticket is found only for the exact same command.
- File: `<state>/tickets/<k>/<session_id>.<tool_use_id>.json`, for example
  `{"session_id":"abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10","tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm","agent_id":null,"operator":false,"background":true,"transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl","cwd":"C:/Development/ccpraxis","at":1790212345}`.
- `take_ticket` reads the one directory `tickets/<k>/`, deletes entries older than 30 s, and then:
  exactly one entry left is claimed by an atomic rename, read and deleted; none returns undef; two or
  more returns `'ambiguous'` and claims nothing. There is no age order and no tie-break. Two sessions
  that issue the same command inside 30 s get a refusal, never each other's binding. A ticket orphaned
  by a refused permission prompt or a sibling hook's deny dies within 30 s.
- Residual, stated rather than hidden: if this call's own hook wrote nothing (a hook failure) while
  another session's identical, never-run call left the only live ticket in the same 30 s, the command
  takes that ticket. That needs two independent faults, and it affects one command.
- The 30 s window covers the gap between hook and command. If a permission prompt outlasts it, the
  command refuses in one line and the agent runs it again.

The argv prediction is a bash-compatible splitter for a small subset, not `Text::ParseWords` (which
drops a backslash before any character inside double quotes, unlike bash). Unquoted words with `\`
escapes, single-quoted strings (literal), and double-quoted strings without `$`, backtick or `\` are
split exactly as bash splits them. A word with an expansion outside single quotes (`$`, backtick, `*`,
`?`, `[`, `{`, or a leading `~`) cannot be predicted, and the hook writes no ticket for that
invocation. The command then refuses unless it carries a valid stop token. This is why every
agent-facing template quotes the reason in single quotes.

**Stop tokens** (only when the gate denies a stop). The Stop gate itself mints a token each time it
denies, and prints it in the denial text:

- Format: 8 lowercase hex characters, from 4 bytes of `/dev/urandom` (fallback: SHA-1 of time, pid
  and `rand`). Files: `<state>/stop-tokens/<token>` holding `{"session_id":...,"minted_at":...}`, and
  `<state>/stop-tokens/<sid>.current` holding the token. A name that already exists is re-minted.
- Bound to (session_id, that Stop event): every Stop gate run for the session starts with
  `revoke_stop_token($sid)`, so a token dies at the next Stop, which is the end of the turn the
  denial forced. `disarm` also revokes it. There is no wall-clock expiry, so a long turn keeps its
  way out.
- `take_stop_token($t)`: `$t` must match `^[0-9a-f]{8}$`. The command claims `stop-tokens/<t>` by
  rename, reads the session id, checks that `<sid>.current` still names `$t`, and deletes both. Any
  failure returns undef. The lookup is one file open, never a scan.
- Only the `Stop` event mints. SubagentStop is not registered, and the gate also refuses to mint for
  any payload that carries an `agent_id` or whose `hook_event_name` is not `Stop`.
- A token proves the session, never the operator. It is accepted by `butler-continuity off`,
  `butler-continuity silence` and `butler-hold`, and by nothing else.

**How a command resolves its binding** (`butler-continuity.pl` and `butler-hold.pl` alike):

1. Parse and validate the arguments first (verb, reason, ids, token format). A bad argument refuses
   in one line and consumes nothing.
2. `take_ticket`. If it returns one ticket: that is the binding. If `--token` is also given and valid
   for a different session, refuse. If the token is valid for the same session, it is consumed. An
   invalid token next to a good ticket is ignored.
3. Otherwise (no ticket, or ambiguous), a valid `--token` is the binding, with `agent_id` unknown
   (treated as the main thread), `operator` false, and `background` unknown (treated as true).
4. Otherwise refuse, in one line, and change nothing.

A fork that inherited the denial text could use the token only when its own ticket is missing,
because a ticket with an `agent_id` refuses first. That is a double fault inside one turn, and it is
accepted.

`invocations($command, $name)` is the shared "a real invocation, never a mention" matcher (84ae5a1).
It splits the command into segments at `;` `&` `|` and newline, outside single and double quotes only,
so a reason such as `'tests & docs done'` stays one word. It opens a new segment at `$(`, backtick,
`<(` and `>(`. Heredoc bodies are skipped. A segment is an invocation when its command word, after
leading `VAR=value` words, after the transparent prefixes `timeout <duration>`, `env [VAR=value]...`,
`nice [-n N]`, `nohup`, `command` and `exec`, and after an interpreter (`perl`, `bash`, `sh`) plus its
options, has a basename matching `^$name(\.sh|\.pl)?$`. A segment whose first word is a reader (`echo`,
`printf`, `grep`, `rg`, `cat`, `sed`, `awk`, `head`, `tail`) is not an invocation, and neither is a
quoted string. Packages 04 (ticketing), 07 (director calls) and 14 (the headless-background exemption)
all use it. Its tests cover reasons containing `; & | $ !`, a newline and non-ASCII text.

### Paths and bytes

Payload strings used as paths are converted to UTF-8 byte strings (`utf8::encode` only if
`utf8::is_utf8`), and backslashes are turned into `/`. Git-for-Windows perl opens `C:/...` directly.
Nothing re-encodes a string that is already bytes, because `André` would come out as `AndrÃ©`.
`data_dir($p)` returns `CCPRAXIS_DATA_DIR` if absolute. Otherwise it uses `BpProjectRoot.pm` (reused,
not copied) from `CLAUDE_PROJECT_DIR` or the payload `cwd`. The upward walk stops when `dirname`
returns its own input, because a drive-letter path reaches the fixed point `C:`, and that is the
25-second hang `hook-path-walk-and-scope.t` recorded. `hook-core-api.t` re-expresses that case.
The only pids the core reads are holder pids, which perl's `$$` wrote and which are read back through
`/proc` in the same MSYS namespace. Liveness never compares an MSYS pid with a WINPID.

## Arm state storage and format

One store, one writer module (BpHook.pm), keyed by the payload `session_id` (Decision 2; harness-facts
(d)). Every reader goes through `BpHook::is_armed` or the documented bash `-f` test in `run-hook.sh`,
which is part of the core.

arm-state-path: ~/.claude/butler-state/continuity/armed/<session_id>

The root is `$BUTLER_STATE_DIR/continuity` when `BUTLER_STATE_DIR` is set and absolute, otherwise
`$HOME/.claude/butler-state/continuity` (`$USERPROFILE` if `HOME` is unset). A root that is not
absolute counts as nothing armed, which fails open, and writers refuse in one line. `BpHook::state_dir()`
is the only resolver: the hooks, both commands and the statusline (package 10) call it, and
`plugins/butler/tests/t/continuity-statusline-badge.t` asserts that the statusline resolves the same
root as the core. The store is machine-level, not per project. Session ids are globally unique, the
wake-lock lease must see every armed session in one directory scan, and the statusline reads it knowing
only the session id. It lives outside the live-install git tree. Inside a sandbox, `$HOME/.claude` is
the project's claude-home, so container sessions have their own store and their own busy-lease.

```
continuity/
  armed/<sid>             exists iff armed. One JSON line. mtime = last Stop gate run.
  armlock/<sid>           flock target for arm and disarm.
  off/<sid>               exists iff the latest continuity event is an off (Decision 36).
  silence/<sid>           exists iff one stop is to be let through.
  holder/<sid>.json       the session's holder record (Holder protocol).
  holder/<sid>.lock       flock target for become, extend and holder exit.
  tickets/<k>/            command-binding tickets for one exact command.
  stop-tokens/            gate-minted stop tokens and one <sid>.current pointer per session.
  reasons.log             the Decision 7 reason log.
  hook-errors.log         internal errors caught by BpHook::main.
```

Formats, one JSON object per file, written to a same-directory temp file and renamed:

```
armed/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10","role":"driver","by":"arm-on-entry","transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl","at":"2026-09-24T01:02:03Z"}

off/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-...","actor":"agent","reason":"all packages done; nothing left to run","at":"2026-09-24T05:00:00Z"}

silence/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-...","by":"butler-continuity","reason":"reporting results to the operator","at":"2026-09-24T03:10:00Z"}
```

**Who arms (Decision 1 triggers):**

| trigger | mechanism | role written |
|---|---|---|
| `/butler:continuity on` by the operator | the skill runs `butler-continuity on` | manual |
| drive-solo start | the drive-solo skill's first step `butler-continuity on --role driver`, which also clears an earlier off | driver |
| every later director call | arm-on-entry.sh on a real `bp-drive-next.pl next` from the main thread, skipped when `latest_is_off` | driver |
| reporter start | the reporter skill's first step `butler-continuity on --role reporter` (Decision 24) | reporter |
| agent self-arm per the continuity skill's prose | `butler-continuity on` | manual |
| fleet coordinator | `BP_LEDGER` in the environment; no file | coordinator |

The skill's first step makes an operator-fired drive-solo arm even after an earlier off, because "drive
solo is fired" is one of the operator's arm triggers. The director-call re-arm keeps honouring an off
(Decision 36), and arm-on-entry is then a refresh rather than the only arming path.

**Who disarms: exactly the three operator-allowed paths.** `butler-continuity off` in its operator
form (`/butler:continuity off`), `butler-continuity off --reason` from an agent, and
`butler-continuity silence --reason` for one stop. Nothing else removes `armed/<sid>` or turns a live
session off. There is no age-based expiry: `is_armed` is "the file exists". A coordinator cannot be
disarmed or silenced (Decision 25). The command refuses, and the gate ignores any file for a
coordinator. `arm` and `disarm` serialise on `armlock/<sid>`, so parallel `on` and `off` calls in one
message leave either an arm file or an off file, never both.

**Off is permanent until on (Decision 36).** `off` writes `off/<sid>`. arm-on-entry does not arm a
session that has it. Only `butler-continuity on`, from the operator's `/butler:continuity on`, an agent,
or the drive-solo and reporter first steps, deletes it.

**Garbage collection, which is not a disarm.** `gc_sessions()` deletes every state file of a session
(`armed`, `off`, `silence`, `holder`, its stop token) only when the arm or off record carries a
`transcript_path` and that file no longer exists on disk. A session whose transcript is gone can never
stop again, so nothing is disarmed. Each removal appends one line to the reason log with actor `gc`,
verb `gc` and the reason `transcript gone: <path>`. Records without a `transcript_path` are never
collected. The lease daemon runs it at most once an hour.

**Resumed sessions.** `--resume` keeps the session id and its transcript file (harness-facts (d)), so
the arm file, an off file and the reason history all carry over untouched and GC never touches them. A
holder record left by the previous process fails the pid check at once, so the first stop after the
resume is gated normally and the agent holds again.

**New session ids.** SessionStart with `source=clear` (and, per D-3, a carry-over clear) is the point
where the id changes. The new id is a new session and starts unarmed, because state is keyed by id and
nothing is carried across. That is Decision 2 as written: drive-solo re-arms at its first director call,
a reporter at its first step, and any other session "only via /butler:continuity on or agent
self-arm". For a manual session after the operator's own `/clear`, the operator re-arms with
`/butler:continuity on`. After a carry-over, the carry-over skill prose tells the fresh session to run
`butler-continuity on` when the work was armed. The old id's arm file is not a live session. It stays
until its transcript is gone and stops holding the wake-lock 12 h after its last stop. No SessionStart
or SessionEnd hook is registered.

**Wake-lock (Decision 18).** `BpContinuityLease.pm` (package 04) holds the lock while any `armed/*` file
was touched by a Stop gate run in the last 12 h, and also, until package 16, while the old
`.continuity-active` registry says so. The 12 h is only the lease's view of activity: it never deletes
a file and never changes what `is_armed` answers. Its refresher daemon becomes the internal verb
`butler-continuity lease --daemon`, which also runs `gc_sessions()`. `keep-awake.ps1` is untouched.

**Statusline contract (package 10).** `scripts/statusline.pl` resolves the root through
`BpHook::state_dir()`, then reads `off/<sid>` (a badge when `"actor":"agent"`) and `silence/<sid>` (a
badge when present), with no subprocess.

## Holder protocol

Decision 1: one command, one or more items, fixed 50 minutes, no timeout parameter. Decision 9: at
most one live holder per session, and re-invocation never leaves the session with zero live holders.

holder-reinvocation: extend

**Why extend, from the evidence.** Item (e) of harness-facts.md shows that every exit of a background
Bash task, normal or killed, wakes an idle interactive session. It also shows a killed task reaches
the agent as `failed with exit code 143`. Replacing would kill the old holder on every re-invocation,
producing a "failed" notification the agent may try to repair, and a two-process handover whose
ordering has to be proven to never reach zero holders. Extending keeps the one process running.
Re-invocation only rewrites its record, and the extending call exits 0 at once. Zero live holders
cannot happen, because the live process never stops, and stacking (bug 20260922-213451-6382) cannot
happen by construction. The holder exists because a background exit is a wake-up: at the deadline its
own exit wakes the session and the gate asks again.

**Command.** `butler-hold [--token <token>] <id> [<id> ...]`, run as a Bash tool call with
`run_in_background: true`. An id is a subagent id (for example `a2f2aacc903afc6ac`) or a background
task id (for example `bsp949ih1`), matching `^[A-Za-z0-9_-]{1,64}$`. `--token` is the stop token from
a denial. Any other argument starting with `-` is refused with
`butler-hold: takes ids only, plus --token from a stop message; the hold is always 50 minutes.`
(exit 1). Files: `plugins/butler/scripts/butler-hold.pl` and the extensionless shim
plugins/butler/bin/butler-hold (Decision 47).

**Binding.** As in "Command binding" above: a ticket, or the stop token. The hook never denies a
foreground call. With neither binding, it prints
`butler-hold: no session binding; use the --token from the stop message, or quote ids plainly.` and
exits 1. If the ticket carries an `agent_id`, it prints
`butler-hold: only the main session holds; a subagent may not.` and exits 1.

**Become or extend** (under `flock` on `holder/<sid>.lock`):

- A holder is running when the record's deadline is in the future and its process passes the pid
  check below. Then the command sets `items` to the old items plus the new ones (order kept, no
  duplicates) and `deadline` to now + 3000 s, rewrites the record, prints
  `extended holder of session abb7e549 until 02:03Z: a2f2aacc903afc6ac, bsp949ih1`, and exits 0.
  Extending works from a foreground call too.
- Otherwise this process becomes the holder, unless its ticket says `"background":false`, in which
  case it prints `butler-hold: start it with run_in_background: true.` and exits 1. It writes the
  record with a fresh random `token`, its own `pid` (`$$`) and `fp`, the SHA-1 of the bytes of
  `/proc/$$/cmdline` read right after start, and prints
  `holding session abb7e549 until 02:03Z: a2f2aacc903afc6ac`. Then it loops. Every 30 s it re-reads the
  record, which picks up extensions. It stops when `deadline` passes, when the record is gone, or when
  the record carries another token (superseded).

```
holder/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10.json
{"session_id":"abb7e549-...","token":"9f2c41d07ab3e855","pid":832282,"fp":"3b1f...e09a",
 "items":["a2f2aacc903afc6ac","bsp949ih1"],"started_at":1790212345,"deadline":1790215345,
 "transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl"}
```

**Exit.** At the deadline the holder takes `holder/<sid>.lock`, re-reads the record, and goes back to
looping if an extension moved the deadline. Otherwise it removes the record if the token is still its
own, releases the lock, prints one line per item, and exits 0. If the record is gone because `off`
removed it, it prints `continuity is off; holder ended.` and exits 0 at its next tick. On SIGTERM,
SIGINT or SIGHUP it prints the item lines and exits 143, and it leaves the record in place: the pid
check makes the record dead for an interactive session, and a headless coordinator keeps the record it
needs (see Headless coordinators). Item lines:

```
a2f2aacc903afc6ac finished
bsp949ih1 running, last activity 01:51Z
bq7x2 unknown
```

"Finished" means the session transcript (`transcript_path`, tail-read, at most 1 MiB) holds a
`<task-notification>` naming the id with a terminal status. "Last activity" for a subagent is the
mtime of `<dirname(transcript_path)>/<session_id>/subagents/agent-<id>.jsonl` (harness-facts (c)).
For a background task it is the mtime of its output file when that path appears in the transcript. An
id that resolves to neither is `unknown`, and the command never fails on it. Item status is read only
at exit.

**Liveness at Stop**, `holder_live($sid, $p)`. All of these must hold:

1. `holder/<sid>.json` parses, names this session, and `deadline` > now.
2. Held work is running. When the payload carries a `background_tasks` array, at least one entry has
   `"status":"running"` and an `id` that is one of the record's `items`. For a coordinator that entry
   must also have `"type":"subagent"`. A held id that is finished, mistyped or invented therefore
   counts for nothing, so a holder can never act as a reasonless 50-minute silence. When the array is
   absent (a harness that stopped sending it), an interactive session skips this check and a
   coordinator fails it, which leaves the coordinator its ledger path.
3. The process is alive (interactive sessions only; a coordinator skips this, see below). With `/proc`
   (MSYS on Windows, Linux in the sandbox): `/proc/<pid>/cmdline` is readable and its SHA-1 equals
   `fp`. A killed holder fails at once, a reused pid fails because its command line differs, and
   nothing waits out a heartbeat. Without `/proc` (a macOS host): `kill 0, $pid` succeeds.

The cost is one small JSON read, one read of `/proc/<pid>/cmdline` (under 1 ms, 7417f0c) and a field of
a payload that is already parsed. Never `stat` or `status`, which cost 45-70 ms each, and never a
WINPID. An orphaned process from a killed dispatch can no longer count (bug 20260922-211901-2cad),
because it holds no record for this session. `plugins/butler/tests/t/continuity-holder.t` (package 05)
asserts that the fingerprint matches a live holder and fails once the holder is killed without cleanup,
and records the read cost in the ledger.

**Test seams (package 05 only).** `BUTLER_HOLD_TEST_SECONDS` (1..3000) and `BUTLER_HOLD_TEST_TICK`
(seconds) are honoured only when `BUTLER_STATE_DIR` is also set. They can only shorten the hold, and
no skill or message mentions them.

**Prior art (Decision 44).** The untracked `plugins/butler/scripts/bp-hold.pl` is the stopped
almanac-records session's prototype. Coordinators never edit, delete or commit it. Package 05 reads
the copy at `reports/evidence/prior-art/bp-hold.pl`. Its debounce-and-reset idea is the extend
choice here. Its `/proc/<pid>/stat` fingerprinting is replaced by the cheap cmdline fingerprint, and its
exit-on-first-item is not carried over.

**Headless coordinators (Decision 4).** A fleet coordinator is `claude -p`. Harness-facts (e) shows
headless kills a still-running background Bash task a few seconds after its final result, and that a
background Agent keeps the process alive and wakes it. So for a coordinator the wake-up is the Agent's
completion, not the holder's exit, and a live holder alone never lets a coordinator stop. The gate
allows a coordinator stop on a holder only when the record is unexpired and a held id is a `running`
`subagent` in the Stop payload's `background_tasks`. It does not check the holder's process, and the
holder keeps its record when it is killed. Whatever headless does to the holder, that gives the same
answer:

- The holder survives while the Agent runs: the record is valid, the stop is allowed, and the Agent's
  completion wakes the coordinator.
- The holder is killed and its kill wakes the coordinator: the record is still valid and the Agent
  still runs, so that one extra stop is allowed at once. No re-hold loop starts.
- The holder is killed silently: the Agent's completion still wakes the coordinator.

A coordinator holding an id that is not a running background subagent is refused, and the process
cannot end with a non-terminal ledger that way. **Package 08 obligation:** measure this once in a
nested `claude -p` (the Decision 28 method): a background Agent plus a background `butler-hold`, then
end the turn, and record whether the holder is killed and whether its kill wakes the session. Cite the
result in 08's ledger. `plugins/butler/tests/t/fleet-holder-integration.t` exercises the gate and holder
contract in-process for all three outcomes. The merged Bash guard exempts a command that is exactly one
`butler-hold` invocation from the headless no-background rule.

## Reason log

Decision 7: every off and silence reason goes into one log the operator can read, with session, time
and text.

reason-log: ~/.claude/butler-state/continuity/reasons.log

This is the same root as the arm state (`$BUTLER_STATE_DIR/continuity/reasons.log` when overridden).
One tab-separated line per event, appended with `O_APPEND` by `butler-continuity.pl`, and by
`gc_sessions()` for its own removals:

```
2026-09-24T05:00:00Z	abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10	agent	off	C:/Development/ccpraxis	all packages done; nothing left to run
2026-09-24T03:10:00Z	abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10	agent	silence	C:/Development/ccpraxis	reporting results to the operator
2026-09-24T06:00:00Z	7d8355c7-3202-461f-b319-c85a3402d87c	operator	off	C:/Development/ccpraxis	(operator)
2026-09-25T07:00:00Z	0409cb25-7656-418b-99f3-e9402646f33a	gc	gc	-	transcript gone: C:/Users/André/.claude/projects/x/0409cb25-....jsonl
```

Fields: ISO-8601 UTC time, session id, actor (`agent`, `operator` or `gc`), verb (`off`, `silence` or
`gc`), project root (the ticket `cwd` resolved through `data_dir`, or `-` when the binding was a stop
token or GC), and reason. Tabs and newlines in the reason become spaces. The reason is capped at 300
characters. An agent reason must hold at least two whitespace-separated words, so it is never empty and
never a single word. Otherwise the command prints
`butler-continuity: --reason needs at least two words saying why.` and exits 1, and nothing is logged.
An operator off without a reason logs `(operator)`. The log rolls to `reasons.log.1` past 1 MiB. The
statusline badge (package 10) reads the per-session `off/` and `silence/` files, not this log.

## Stop gate denial text

One Stop hook (Decision 5): `plugins/butler/hooks/next/stop-gate.sh`, logic in
`plugins/butler/scripts/BpHook/StopGate.pm` (package 06). The only ways past it are a live holder, or
the off and silence commands, each with a reason (Decision 1, Decision 6). Exact text when an armed
non-coordinator session stops with no live holder and no silence (Decision 8: at most 8 lines, the
three commands, nothing else, no pending dispatches, no history). `<token>` is replaced by the token
this denial minted, in all four places:

```
Continuity is on for this session and no holder is running. Stop token: <token>
Waiting on a subagent or background task? Hold it, as a background Bash tool call:
  butler-hold --token <token> <id> [<id> ...]
All work done? Turn continuity off, as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token <token>
Only this one stop, e.g. to report or to wait for the operator? Let it through:
  butler-continuity silence --reason '<why this stop>' --token <token>
```

The text is written to stderr with exit 2, and Claude Code feeds it back verbatim (harness-facts (f)).
Waiting for the operator goes to `silence`, not `off`: the operator's reply starts the next turn and the
gate is back in force, while an off would stay off. Reasons are in single quotes so bash expands nothing
in them.

Coordinator variant (off and silence refuse there, Decision 25). `<reason>` is exactly one of: the
ledger does not exist; status '<s>' is not terminal; the ledger is <n>m stale (limit 15m);
'## Next action' is empty or a placeholder; a fleet pause is active and status '<s>' is terminal; the
held ids are not running background subagents. If no token could be minted, the holder line omits
`--token <token>`; the ledger path needs no token.

```
Coordinator stop refused: <reason>. Stop token: <token>
Waiting on a background subagent? Hold it, as a background Bash tool call:
  butler-hold --token <token> <id> [<id> ...]
Otherwise finish or park the ledger: status done|blocked|parked, a concrete '## Next action' when blocked or parked, last_updated from iso_now.
```

**Algorithm** (`StopGate::run`, after the wrapper's prefilter has let the invocation through):

```
if hook_event_name(p) ne 'Stop' or agent_id(p) defined -> allow   (never mints)
sid = session_id(p)                      ; undef -> allow
revoke_stop_token(sid)                   ; the previous turn's token dies here
if role is coordinator:
    runs/<pkg>.force-stop exists         -> unlink, allow
    runs/.paused and not runs/.shutdown  -> paused rules (non-terminal status, Next action, fresh)
                                            -> stamp last_updated, allow | deny(coordinator text)
    ledger terminal, fresh (15m), Next action when blocked|parked
                                         -> sync runs/registry.json, stamp last_updated, allow
    holder_live(sid, p)                  -> allow   (coordinator rule: running subagent held)
    deny(coordinator text, mint_stop_token(sid))
if role is judge                         -> allow
if not is_armed(sid)                     -> allow
touch armed/<sid>                        ; activity for the wake-lock lease
holder_live(sid, p)                      -> allow   (checked first, so a silence is not wasted)
take_silence(sid)                        -> allow   (consumed by exactly this stop)
t = mint_stop_token(sid)                 ; undef -> allow, one hook-errors.log line
deny(continuity text with t)
```

`stop_hook_active` is never read. It resets after a wake and is not a block counter (harness-facts
(f)). If `take_silence` cannot unlink the silence file, the stop is treated as not silenced, because a
file that survives would let more than one stop through. If the gate cannot store a token, it allows
the stop rather than print a denial whose way out would not work. The same holds for any exception:
the gate fails open.

## Operator off versus agent off

Package 04 owns both halves (Decision 37). The check is a hook, not something the agent can supply
as an argument:

off-check: plugins/butler/hooks/next/continuity-off-check.sh

Its logic lives in the module BpHook::ContinuityOffCheck, at plugins/butler/scripts/BpHook/ContinuityOffCheck.pm,
which is a re-scope request for package 04 (see Re-scope requests), in line with Decision 35's one
module per hook package.

**Mechanism.** `continuity-off-check.sh` is a PreToolUse Bash hook with the prefilter
`--pre text:butler-continuity,text:butler-hold`. It writes the tickets described under Command binding.
For each real invocation of `butler-continuity off`, with or without `--reason`, from a payload
without `agent_id`, it reads the tail (at most 1 MiB) of the payload's `transcript_path` and finds the
latest genuine operator record, walking back past everything that is not one:

- It must be a `"type":"user"` record that is not `isMeta`, not `isSynthetic` and not
  `isCompactSummary`, has no `toolUseResult`, and whose content is text rather than `tool_result`
  blocks. Records that start with `<task-notification>` or `Stop hook feedback` are skipped.
- The operator flag is set only when that record's whole trimmed text is the slash-command shape and
  nothing else: an optional `<command-message>...</command-message>`, then
  `<command-name>/butler:continuity</command-name>`, then `<command-args>off</command-args>` (arguments
  trimmed). A literal `/butler:continuity off` inside other text, a compaction summary that quotes an
  earlier off, a carry-over plan, or any message with more text never qualifies.

If the latest genuine operator record qualifies, the ticket is written with `"operator":true`. The hook
never denies. It only records who asked. This is the transcript technique `guard-run-finish.sh` already
uses, and 04 reads that parser rather than extending it.

**Package 04 obligation: the agent-invoked Skill.** How Claude Code records a model's own Skill-tool
invocation of `/butler:continuity` with argument `off` has not been measured. 04 measures it before it
ever sets `"operator":true`: in a nested `claude -p` in a scratch project (the Decision 28 method), one
run where the prompt is the slash command and one where the model is asked to invoke the skill through
the Skill tool. It records both transcript records in its ledger. The design covers both outcomes:

- **Distinguishable** (the model's record is `isMeta`, carries a field such as `sourceToolUseID`, or
  otherwise differs from the operator's record in a way the filter above can test): 04 adds that test
  to the filter and ships the operator form as described.
- **Indistinguishable:** 04 never sets `"operator":true`. A reasonless `off` always refuses, and the
  continuity skill's operator branch runs
  `butler-continuity off --reason 'operator ran /butler:continuity off'`, logged with actor `agent`.
  The operator loses the reasonless form and sees a badge for their own off, but no agent can ever be
  logged as the operator.

`plugins/butler/tests/t/continuity-command-verbs.t` covers: an agent Skill-tool record of the measured
shape leaves `"operator":false`; a quoted mention, a compaction summary and a synthetic record leave it
false; the operator's whole-message record sets it.

**The command decides** (`plugins/butler/scripts/butler-continuity.pl`):

| call | binding says | result |
|---|---|---|
| `off --reason '<2+ words>'` | ticket or token, main thread | off, actor `agent` (actor `operator` if the ticket says `"operator":true`), reason logged |
| `off` (no reason) | ticket with `"operator":true` | off, actor `operator`, logged as `(operator)` |
| `off` (no reason) | anything else | refused: `butler-continuity: off needs --reason '<why>' unless the operator typed /butler:continuity off.`, exit 1 |
| any of on, off, silence | ticket with `agent_id` set | refused: `butler-continuity: only the main session changes continuity; a subagent may not.`, exit 1 |
| off or silence | `BP_LEDGER` set in the command's environment | refused: `butler-continuity: a coordinator cannot turn continuity off; it stops when its ledger is terminal.`, exit 1 (Decision 25) |
| off, silence, status | no ticket (or two) and no valid token | refused: `butler-continuity: no session binding; use the --token from the stop message, or quote arguments in single quotes.`, exit 1 |
| on | no ticket, or two | refused: `butler-continuity: no session binding for on; run it again as a plain Bash tool call.`, exit 1 |

There is no `--session` option and no environment variable that names a session. No argument, flag,
token or environment variable produces `"operator":true`. Only the hook sets it, from a transcript
record the agent cannot write. As everywhere in this repo, the threat model is accident, not adversary:
an agent that hand-writes a ticket file or reads another session's token out of the state directory is
outside the model, and so is one that edits the hook. An off by either actor is permanent until `on`
(Decision 36). Package 10 shows the badge only for `"actor":"agent"`, so the operator sees when an
agent has turned continuity off or silenced it.

Other verbs, each printing one line unless noted: `on [--role driver|reporter]`,
`silence --reason '<2+ words>' [--token <token>]`, `status` (at most 4 lines: arm state and role, the
holder and its items and deadline, any pending silence; holder read through `BpHook::holder`),
`ask '<question>'` (appends to the legacy `.subagent-guard/questions.md` exactly as `bp-continuity.pl
ask` does, Decision 22), and the internal `lease --daemon`. `silence` on an unarmed session prints
`continuity is off for this session; nothing to silence.`, exits 0 and records nothing. The command
honours `CCPRAXIS_NO_WAKELOCK` exactly as `bp-continuity.pl` does, so tests never take the real lock.

## Concurrency binding store and switch

Decision 16: the director tracks a set of in-flight packages, every dispatch is bound to one package by
`tool_use_id`, and write guards apply the package of the subagent making the edit. Decision 31: behind
the switch, the director hands out further disjoint ready packages.

binding-store: <project>/.ccpraxis-local-data/.drive-solo/bindings/<tool_use_id>.json
concurrency-switch: BUTLER_CONCURRENCY

**The switch (Decision 19).** It is on only when the environment variable `BUTLER_CONCURRENCY` equals
`1`. Unset or any other value is off. Three places read it: `plugins/butler/scripts/bp-drive-next.pl`
(package 11: concurrent hand-out), and `plugins/butler/scripts/bp-orchestrator.pl` and
`plugins/butler/scripts/bp-launch.sh` (package 08: the fleet holder path). No hook reads it. The
one-ledger dispatch rule only bites when more than one package is in flight, and only the switch can
make that happen. With the switch off, all three behave exactly as today. Package 16 turns it on by
deleting the off branches and the variable from the three readers. The new path becomes
unconditional, and the old fleet path and `current.json` go with them.

**In-flight set (package 11):** `<data>/.drive-solo/inflight.json`, written only by the director,
atomically:

```
{"packages":[{"blueprint":"hook-continuity-remake","package":"03-hook-core",
  "ledger":".ccpraxis-local-data/blueprints/hook-continuity-remake/packages/03-hook-core.md",
  "since":1790212345}],"updated_at":1790212345}
```

A package is added on `run-package`. It is removed by the first director call that finds its ledger
terminal (done, blocked, parked or dropped). The file is project-level, so it survives a new session
id. As with today's `current.json`, one driving session per project is the supported configuration. A
package whose driver crashed stays in flight until its ledger turns terminal, which is correct, because
the next driver resumes it. With the switch off the director still records it, never with more than one
entry, and keeps writing `current.json` until package 16. With the switch on, `ready_packages` receives
the real in-flight set instead of `[]`, and a further ready package is handed out when
`write_sets_overlap` is false against every in-flight one.

**Binding store (package 12).** One lookup file per dispatch, `bindings/<tool_use_id>.json`, written
atomically, so a write guard's lookup is one file open, never a scan. The `tool_use_id` must match
`^[A-Za-z0-9_-]{1,128}$` before it names a file. Each binding is also appended with `O_APPEND` to the
history `bindings.jsonl` beside it, in the same shape as today's `.dispatch-log/attribution.jsonl`, so
`bp-spend.pl report-session` reads both histories with one parser, de-duplicated by `tool_use_id` with
the binding record preferred. The history rolls to `bindings.jsonl.1` past 8 MiB. Lookup files older
than 7 days are removed by bind-dispatch when it writes a new one.

```
{"tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm","blueprint":"hook-continuity-remake","package":"03-hook-core","subagent_type":"bp-implementer","session_id":"abb7e549-...","source":"bind-dispatch","at":1790212400}
```

**Dispatch rule** (`plugins/butler/hooks/next/bind-dispatch.sh`, PreToolUse Task|Agent):

- Coordinator: bind to `BP_BLUEPRINT`/`BP_PACKAGE`, never deny.
- Armed driver, main thread. With 0 in flight, allow and record nothing. With 1, bind to it. With 2 or
  more, `tool_input.prompt` must name exactly one in-flight ledger: after turning `\` into `/`, it
  contains `blueprints/<bp>/packages/<pkg>.md`. If it does, bind. If not, deny:
  ```
  With 2 packages in flight a dispatch prompt must name exactly one ledger path:
    .ccpraxis-local-data/blueprints/hook-continuity-remake/packages/03-hook-core.md
    .ccpraxis-local-data/blueprints/hook-continuity-remake/packages/11-director-inflight-set.md
  ```
  (one header line, at most 4 ledgers, then `  ...and <n> more`).
- Armed driver, `agent_id` present (any subagent, fork included): deny
  `Only the driving session dispatches workers; a subagent may not.`
- Any other session: allow, record nothing. A denial never happens in an unarmed or non-driving
  session.
- If `inflight.json` is missing (a director older than package 11), the single package in
  `current.json` stands in for the set.

**Write-guard resolution (package 13)**, for `guard-writes.sh` and `ledger-guard.sh` under `next/`:

1. `BP_LEDGER` set: today's `BP_WRITE_SET`/`BP_TEST_PATHS`/role rules, unchanged.
2. Armed driver and `agent_id` present: read `toolUseId` from
   `<dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.meta.json` (harness-facts (c)),
   open `bindings/<toolUseId>.json`, and check the edit against that package's ledger `write_set` +
   `test_paths` + the blueprint dir + `/tmp`. The refusal names the package and the file.
3. Armed driver, `agent_id` present, and no resolvable binding (no `meta.json`, which a foreground
   dispatch may lack, a malformed `agent_id`, or no binding file): with 1 package in flight, that
   package's set. With 2 or more, deny with one line,
   `No package binding for this subagent; with <n> packages in flight its edits are refused.`
   Decision 16 is not weakened to a union.
4. Armed driver, main thread (no `agent_id`): with 1 package in flight, that package's set. With 2 or
   more, the union, and the refusal names every in-flight package. With 0, allow.
5. Anything else: allow.

**Fleet (package 08).** With the switch on, `bp-launch.sh` starts coordinators with
`BUTLER_CONCURRENCY=1` exported and `plugins/butler/bin` on `PATH`, so `butler-hold` resolves. The
coordinator then waits through the holder and stops through the one gate, under the coordinator rule of
the Holder protocol section. The orchestrator's `runs/.paused`, `runs/.shutdown` and
`runs/<pkg>.force-stop` behaviour is unchanged. Neither file calls `bp-watch.pl` today. Fleet use of
watchers lives in coordinator-protocol prose, which package 15 rewrites.

## Guard message budgets and early exits

One row per surviving hook: the most message lines it may print on any path, and the `--pre` clauses
its wrapper passes to `run-hook.sh`, under which it exits 0 in bash before perl starts (Decision 12,
Decision 20, Decision 33). Every hook exits 0 or 2 and nothing else (exit 2 only for a deliberate
deny). Every message line is at most 160 characters. A command echoed back is cut to 80 characters
with `...`. No message names a retired mechanism or says how to disable the guard. Decision 3 applies
throughout: every "armed" below is THIS session's `armed/<session_id>`, never "any session in the
project".

| stop-gate.sh | 7 | --pre ledger,armed : exits when BP_LEDGER is unset and armed/<session_id> is absent |
| arm-on-entry.sh | 1 | --pre text:bp-drive-next : exits when the payload text does not contain bp-drive-next |
| continuity-off-check.sh | 0 | --pre text:butler-continuity,text:butler-hold : exits when the payload text contains neither name |
| bind-dispatch.sh | 6 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| guard-writes.sh | 3 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| ledger-guard.sh | 1 | --pre text:/packages/ --pre ledger,driver : exits when the payload text lacks /packages/, or when BP_LEDGER is unset and the session is not an armed driver |
| guard-bash.sh | 2 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| guard-git-mutations.sh | 2 | --pre text:git, plus --pre ledger,armed when its argument is --only-during-butler-run : exits when the payload text lacks git, or for that registration when BP_LEDGER is unset and the session is unarmed |
| wait-shape-guard.sh | 2 | --pre ledger : exits when BP_LEDGER is unset |
| context-ceiling.sh | 2 | --pre coordinator : exits when BP_LEDGER is unset or BP_ROLE is set to anything but coordinator |
| gate-shutdown.sh | 2 | --pre ledger --pre stopfile : exits when BP_LEDGER is unset or none of runs/.shutdown, runs/.paused, runs/<pkg>.force-stop exists under BP_DIR |
| guard-blueprint-write.sh | 2 | --pre text:blueprint : exits when the payload text does not contain blueprint |
| guard-ask-operator.sh | 4 | --pre ledger,armed : exits when BP_LEDGER is unset and armed/<session_id> is absent |
| track-dispatch.sh | 1 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |

**Who each rule applies to.** A fork counts as a subagent everywhere.

- stop-gate: the main thread's Stop only. SubagentStop is not registered.
- arm-on-entry: a main-thread director call arms. A subagent's director call arms nothing and, in a
  driving session, is denied.
- continuity-off-check: any caller. The ticket records the `agent_id`, and the commands refuse a
  subagent.
- bind-dispatch: coordinator (binds); armed driver main thread (binds, or denies an ambiguous
  dispatch); armed driver subagent (denied).
- guard-writes and ledger-guard: coordinator; armed driver main thread (its package or the union);
  armed driver subagent (its own binding, refused when unresolvable with 2+ in flight).
- guard-bash: the coordinator denials and the headless-background deny apply only when `BP_LEDGER` is
  set, never to an armed driver, so a driver can still commit. Judge checks apply only when `BP_ROLE`
  is `harvest-judge`. The validation interlock applies to coordinators and to every caller in an armed
  driver session, except a payload whose `agent_id` owns a worker marker, so the worker can run its
  own tests.
- guard-git-mutations with `--only-during-butler-run`: coordinator, or any caller in an armed session.
  The settings.json registration: everyone.
- wait-shape-guard, context-ceiling and gate-shutdown: coordinators only.
- guard-blueprint-write: every session and caller.
- guard-ask-operator: coordinator, or any caller in an armed session.
- track-dispatch: coordinator, and an armed driver's main thread.

Behaviour kept by package 14, and which existing tests each rebuild re-expresses in
`plugins/butler/tests/t/guards-remake-suite.t` (Decision 26: assertions about a Decision 6 override
are exempt and listed in 14's ledger). Merged guards run each old rule behind its old applicability
test, inside one process:

- guard-bash.sh: coordinator denials (git checkout, switch, restore, reset, clean, rebase, merge,
  commit, push and stash except list/show; rm -rf outside /tmp, BP_DIR and screenshots; deploys;
  BP_BASH_EXTRA_DENY). Headless background deny when `BP_LEDGER` is set, exempting a command that is
  exactly one `butler-hold` invocation (so `butler-hold x; sleep 3000` is still denied). Harvest-judge
  pnpm/npm/yarn lint, build and test. Validation interlock while a fresh writer marker exists. Sources:
  `plugins/butler/tests/t/guard-bash-quote-strip.t`,
  `plugins/butler/tests/t/gate-headless-background.t`, `plugins/butler/tests/t/guard-judge-checks.t`,
  `plugins/butler/tests/t/guard-judge-checks-quote-strip.t`,
  `plugins/butler/tests/t/validation-interlock-hooks.t`, `plugins/butler/tests/t/parallel-tree-interlock.t`.
- guard-git-mutations.sh: stash (except list/show), checkout, switch, restore, reset and clean, with
  today's quote masking, heredoc and carrier rules. Sources:
  `plugins/butler/tests/t/git-mutation-guard-reach.t`,
  `plugins/butler/tests/t/guard-git-mutations-heredoc-strip.t`,
  `plugins/butler/tests/t/guard-git-mutations-quote-mask.t`,
  `plugins/butler/tests/t/guard-prose-not-invocation.t`.
- wait-shape-guard.sh: wait-loop, false-green pipe, task-output poll, repeated TaskOutput, and the
  identical-call repeat detector (fires once per run). Sources: `plugins/butler/tests/t/wait-shape-guard.t`,
  `plugins/butler/tests/t/wait-shape-guard-quote-strip.t`, `plugins/butler/tests/t/repeat-guard.t`.
- context-ceiling.sh: hard-ceiling deny of dispatch and non-flush Bash, bounded to 5 flush turns, plus
  soft-ceiling guidance through `context()`. Sources: `plugins/butler/tests/t/context-ceiling-flush.t`,
  `plugins/butler/tests/t/context-ceiling-guidance.t`.
- gate-shutdown.sh: deny dispatch and worksite edits under a fleet stop, and allow the ledger
  park-write. Sources: `plugins/butler/tests/t/orchestrate-shutdown-clear.t`,
  `plugins/butler/tests/t/graceful-stop-gate.t` (shutdown assertions).
- guard-blueprint-write.sh: blueprint.md edits denied, and hand-written package ledgers denied with
  the evidence-gated `ledger-write-override`. Sources: `plugins/butler/tests/t/blueprint-write-api.t`,
  `plugins/butler/tests/t/blueprint-guard-exempts-template.t`, `plugins/butler/tests/t/guard-ledger-create.t`.
- guard-ask-operator.sh: deny and queue only when THIS session is armed or a coordinator. Source:
  `plugins/butler/tests/t/no-halt-for-questions.t`.
- track-dispatch.sh: one write-capable worker at a time for coordinators, as today. For armed drivers,
  one marker per write-capable dispatch at `.drive-solo/workers/<tool_use_id>` (carrying the session
  and the subagent type), removed at its PostToolUse, so two concurrent writers never clear each
  other's marker. Running and done dispatch records, and the ledger dispatch line. Sources:
  `plugins/butler/tests/t/dispatch-tracking-hook.t`,
  `plugins/butler/tests/t/validation-interlock-hooks.t` (tracker assertions).

Fail direction per hook, applied only after the early exit has let the call through. Fail open
(exit 0) for everything except coordinator `guard-writes.sh`, `ledger-guard.sh` and `gate-shutdown.sh`
under an active stop signal. Those three fail closed with one line, as today, and that includes a
payload `payload_ok()` rejects (unparseable, or truncated past the 8 MiB read cap). A guard that wedges
an interactive session costs more than the mistake it prevents. A coordinator's write discipline has
failed closed since b12, and one retry with a diagnostic is cheap there. A missing perl, a missing
`BpHook.pm` or a module that fails to load fails open everywhere, because the wrapper's guard and the
eval-require run before any hook logic. That differs from today's destructive-git guard, which failed
closed when no JSON parser existed, and the difference is accepted: perl ships with every supported
host.

## Skill line budgets

Each `SKILL.next.md` that package 15 writes (Decision 19, Decision 24) puts all of its stop and
continuity guidance inside one block delimited by the lines `<!-- continuity:begin -->` and
`<!-- continuity:end -->`. The budget is the number of non-blank lines inside that block.
`plugins/butler/tests/t/continuity-prose-budget.t` fails if a file lacks exactly one such block,
exceeds its budget, mentions `butler-hold`, `butler-continuity` or `silence` outside the block, or
mentions a retired mechanism anywhere.

| plugins/butler/skills/continuity/SKILL.next.md | 40 |
| plugins/butler/skills/drive-solo/SKILL.next.md | 12 |
| plugins/butler/skills/reporter/SKILL.next.md | 4 |
| plugins/butler/skills/coordinator-protocol/SKILL.next.md | 12 |
| plugins/butler/skills/orchestrator-protocol/SKILL.next.md | 6 |
| plugins/butler/skills/dispatch-fleet/SKILL.next.md | 4 |
| skills/carry-over/SKILL.next.md | 3 |

What each block must carry, in the fewest words. Continuity: when to self-arm (background work
expected to outlive the turn, unattended multi-step work), when off and silence are acceptable and
what a reason must say (off when all work is done; silence to report or to wait for the operator),
reasons in single quotes, the stop token from a denial, how to call the holder (once, backgrounded,
re-run to add ids), and the operator branch that 04's Skill-tool measurement decides. Drive-solo: first
step `butler-continuity on --role driver`, hold on dispatched ids, the one-ledger dispatch rule, and
never dispatch a fork during a drive. Reporter: first step `butler-continuity on --role reporter`.
Coordinator-protocol: the ledger stop rule, and that a hold counts only for a running background
subagent. Orchestrator-protocol: the three fleet files. Dispatch-fleet: the holder line. Carry-over:
re-arm the fresh session with `butler-continuity on` when the work was armed.

## Deletion list

Package 16 deletes exactly these (Decision 34 lets it widen its write set to fix what the deletions
break). Its no-reference grep exempts this file, `plugins/butler/docs/harness-facts.md`, everything
under `.ccpraxis-local-data/`, and the allowlist in `plugins/butler/tests/t/tests-never-run-tests.t`,
whose entries 16 removes as it deletes their files (Decision 21). Assertions that pin a Decision 6
override are exempt from re-expression and listed by file and name in the relevant ledgers (Decision
26). Decision 43 is decided here: both `reporter-gate-regression.t` and `arming-binds-or-reports.t`
are deleted. Neither survives the cutover, so neither needs its sibling re-run fixed.

Hook files. Nine are replaced in place by their flattened successor, marked (same path):

- `plugins/butler/hooks/context-ceiling-flush.sh`
- `plugins/butler/hooks/context-ceiling-guidance.sh`
- `plugins/butler/hooks/dispatch-discipline-nudge.sh`
- `plugins/butler/hooks/gate-continuity.sh`
- `plugins/butler/hooks/gate-drive-loop.sh`
- `plugins/butler/hooks/gate-headless-background.sh`
- `plugins/butler/hooks/gate-shutdown.sh` (same path)
- `plugins/butler/hooks/gate-stop.sh`
- `plugins/butler/hooks/guard-ask-operator.sh` (same path)
- `plugins/butler/hooks/guard-bash.sh` (same path)
- `plugins/butler/hooks/guard-blueprint-write.sh` (same path)
- `plugins/butler/hooks/guard-git-mutations.sh` (same path)
- `plugins/butler/hooks/guard-judge-checks.sh`
- `plugins/butler/hooks/guard-ledger-create.sh`
- `plugins/butler/hooks/guard-run-finish.sh`
- `plugins/butler/hooks/guard-subagent-stall.sh`
- `plugins/butler/hooks/guard-validation-interlock.sh`
- `plugins/butler/hooks/guard-writes.sh` (same path)
- `plugins/butler/hooks/hooks.json.about`
- `plugins/butler/hooks/ledger-guard.sh` (same path)
- `plugins/butler/hooks/lib.sh`
- `plugins/butler/hooks/log-dispatch.sh`
- `plugins/butler/hooks/mark-wakeup.sh`
- `plugins/butler/hooks/record-dispatch-package.sh`
- `plugins/butler/hooks/repeat-guard.sh`
- `plugins/butler/hooks/track-dispatch.sh` (same path)
- `plugins/butler/hooks/track-worker-solo.sh`
- `plugins/butler/hooks/untrack-worker-solo.sh`
- `plugins/butler/hooks/wait-shape-guard.sh` (same path)

Scripts and shims whose only callers are retired:

- `plugins/butler/scripts/bp-continuity.pl` (replaced by butler-continuity.pl)
- `plugins/butler/scripts/bp-watch.pl` (replaced by the holder and the gate)
- `plugins/butler/scripts/bp-resumption.pl` (only gate-continuity.sh called it)
- `plugins/butler/scripts/bp-session.pl` (nonce claim for the old arm path; tickets and stop tokens replace it)
- `plugins/butler/scripts/bp-watchdog.pl` (already superseded by bp-watch.pl, which goes too)
- `plugins/butler/bin/bp-continuity.sh`
- `plugins/butler/bin/bp-watch.sh`

Tests whose whole subject is deleted. Their live assertions are re-expressed by stop-gate-single.t,
stop-gate-coordinator-ledger.t, continuity-command-verbs.t, continuity-holder.t,
continuity-arm-on-entry.t, continuity-lease-follows-arm.t, dispatch-binding.t, guards-per-subagent.t
and guards-remake-suite.t. Two of them pin fixes to the hook plumbing itself, and package 03 re-expresses
those: hook-core-api.t carries the drive-letter `dirname` fixed point of hook-path-walk-and-scope.t, and
hook-core-spawn-budget.t carries the bounded payload read of hook-payload-read-bound.t (bug 7c1e).

- `plugins/butler/tests/t/reporter-gate-regression.t`
- `plugins/butler/tests/t/arming-binds-or-reports.t`
- `plugins/butler/tests/t/reporter-stop-gate.t`
- `plugins/butler/tests/t/reporter-registration.t`
- `plugins/butler/tests/t/bp-watch-cli.t`
- `plugins/butler/tests/t/bp-watch-decision-core.t`
- `plugins/butler/tests/t/bp-watch-doctrine.t`
- `plugins/butler/tests/t/watcher-probe-liveness.t`
- `plugins/butler/tests/t/watcher-reaped-on-wake.t`
- `plugins/butler/tests/t/waits-check-liveness.t`
- `plugins/butler/tests/t/continuity-gate.t`
- `plugins/butler/tests/t/continuity-gate-idle-exit.t`
- `plugins/butler/tests/t/continuity-gate-write-race.t`
- `plugins/butler/tests/t/continuity-toggle.t`
- `plugins/butler/tests/t/continuity-bounded-hold.t`
- `plugins/butler/tests/t/continuity-output-stays-parseable.t`
- `plugins/butler/tests/t/continuity-lease-held.t`
- `plugins/butler/tests/t/disarm-nonce-guard.t`
- `plugins/butler/tests/t/session-identity-binding.t`
- `plugins/butler/tests/t/drive-loop-gate.t`
- `plugins/butler/tests/t/drive-loop-runstate-fold.t`
- `plugins/butler/tests/t/drive-loop-watchdog.t`
- `plugins/butler/tests/t/drive-solo-marker-retirement.t`
- `plugins/butler/tests/t/driver-arm-noise-stripping.t`
- `plugins/butler/tests/t/mark-wakeup-agent-dispatch.t`
- `plugins/butler/tests/t/mark-wakeup-quoted-script-path.t`
- `plugins/butler/tests/t/run-finish-guard.t`
- `plugins/butler/tests/t/run-finish-reads-invocations.t`
- `plugins/butler/tests/t/finish-guard-counts-live-runs.t`
- `plugins/butler/tests/t/subagent-stall-guard.t`
- `plugins/butler/tests/t/registry-path-one-rule.t`
- `plugins/butler/tests/t/registry-path-parity.t`
- `plugins/butler/tests/t/hook-path-walk-and-scope.t`
- `plugins/butler/tests/t/graceful-stop-gate.t`
- `plugins/butler/tests/t/run-continuity-gaps.t`
- `plugins/butler/tests/t/driver-guard-reach.t`
- `plugins/butler/tests/t/driver-context-session-scope.t`
- `plugins/butler/tests/t/gate-headless-background.t`
- `plugins/butler/tests/t/guard-judge-checks.t`
- `plugins/butler/tests/t/guard-judge-checks-quote-strip.t`
- `plugins/butler/tests/t/validation-interlock-hooks.t`
- `plugins/butler/tests/t/parallel-tree-interlock.t`
- `plugins/butler/tests/t/repeat-guard.t`
- `plugins/butler/tests/t/context-ceiling-flush.t`
- `plugins/butler/tests/t/context-ceiling-guidance.t`
- `plugins/butler/tests/t/guard-ledger-create.t`
- `plugins/butler/tests/t/dispatch-discipline-nudge.t`
- `plugins/butler/tests/t/dispatch-package-hook.t`
- `plugins/butler/tests/t/hook-payload-read-bound.t`
- `plugins/butler/tests/t/read-payload-idempotent.t`
- `plugins/butler/tests/t/json-get-array-index.t`
- `plugins/butler/tests/t/match-any-divergence.t`

Runtime state is not in git and is not deleted by 16. Once the files above are gone nothing reads it:
the three machine registries, the `.subagent-guard/<session>` stall state, the `.watchers/`
arm registry, `.drive-solo/.stop-ok`, `.run-finished`, and the old continuity markers.

## Cutover obligations

What package 16 changes rather than deletes, so the "exact list" above stays exact:

- Kept, with the reason: `plugins/butler/scripts/bp-watch-child.pl`, the fleet child parent that
  `bp-launch.sh` uses for exit status. It is not a watcher. `plugins/butler/scripts/BpResumption.pm`,
  whose pid helpers `plugins/butler/scripts/bp-worker.pl` uses. `plugins/butler/scripts/BpSession.pm`,
  whose transcript discovery `plugins/butler/scripts/bp-feedback.pl` uses.
  `plugins/butler/scripts/BpContinuityLease.pm`, which 16 rewires to read the new store only.
- `plugins/butler/scripts/bp-worker.pl` sources `hooks/lib.sh` for `marker_path`, `ledger_lock` and
  `bp_active_stop_signal`. Package 16 inlines those three helpers there (Decision 34 widening).
- Tests that keep running against a same-path successor or an updated file, where 16 fixes whatever
  goes red (Decision 34): `plugins/butler/tests/t/guard-bash-quote-strip.t`,
  `plugins/butler/tests/t/git-mutation-guard-reach.t`,
  `plugins/butler/tests/t/guard-git-mutations-heredoc-strip.t`,
  `plugins/butler/tests/t/guard-git-mutations-quote-mask.t`,
  `plugins/butler/tests/t/guard-prose-not-invocation.t`, `plugins/butler/tests/t/wait-shape-guard.t`,
  `plugins/butler/tests/t/wait-shape-guard-quote-strip.t`, `plugins/butler/tests/t/ledger-guard.t`,
  `plugins/butler/tests/t/guard-writes-specificity.t`,
  `plugins/butler/tests/t/write-set-refusal-diagnoses-itself.t`,
  `plugins/butler/tests/t/dispatch-tracking-hook.t`, `plugins/butler/tests/t/blueprint-write-api.t`,
  `plugins/butler/tests/t/blueprint-guard-exempts-template.t`,
  `plugins/butler/tests/t/no-halt-for-questions.t`, `plugins/butler/tests/t/orchestrate-shutdown-clear.t`,
  `plugins/butler/tests/t/hooks-selftest.t`, `plugins/butler/tests/t/hooks-json-route-registration.t`,
  `plugins/butler/tests/t/h01-settings-registration.t`, `plugins/sandbox/tests/t/settings-scope-split.t`,
  `plugins/butler/tests/t/hooks-reach-non-ccpraxis-project.t`,
  `plugins/butler/tests/t/continuity-lease-liveness.t`, `plugins/butler/tests/t/resumption-contract.t`
  (trimmed to what bp-worker.pl uses), and `plugins/butler/tests/t/bp-commands-on-path.t` (the
  bp-watch.sh and bp-continuity.sh shims go).
- Two tests would otherwise go quietly inert. `plugins/butler/tests/t/dispatch-write-path.t` does
  `skip_all` unless `hooks/lib.sh` exists, so after the deletion it is green by skipping. 16 re-points
  it at the merged tracker or removes the dead cases, and never leaves it skipping.
  `plugins/butler/tests/t/test-wakelock-hygiene.t` names only `bp-continuity.pl` and
  `gate-continuity.sh` in its `$ACTUATORS` pattern. 16 adds `butler-continuity.pl` and `stop-gate.sh`,
  so new tests that drive the new command are checked for `CCPRAXIS_NO_WAKELOCK`.
- `plugins/butler/scripts/bp-containment-audit.pl` mirrors lib.sh's `match_any`. Package 16 re-points
  the comment to `BpHook/WriteGuards.pm`, which keeps the same colon-separated dialect.
- `.claude/settings.json`: the two `guard-subagent-stall.sh` entries are removed in the same commit
  that deletes the script. The `guard-git-mutations.sh` entry is untouched. A settings commit must
  never point at a file that is not yet on disk (Decision 10), whether or not a running session re-reads
  it (harness-facts (h)).
- The Decision 19 switch is removed, as described under the concurrency switch.

## Constraint conflicts

- **No Stop block cap, and a way out that depends on no other hook.** Harness-facts (f), design
  constraint 1, recommends a per-session hard cap on Stop retries. Decisions 6 and 45 retire
  `MAX_BLOCKS=3` and forbid any way past the gate except a holder, off or silence. This design follows
  the Decisions and removes the dead end a different way. Every denial carries a stop token minted and
  stored by the gate itself. `butler-hold`, `butler-continuity off` and `butler-continuity silence`
  accept it as proof of session, so the three documented exits work even when the ticket hook has
  failed. If the gate cannot store a token, or anything in it throws, or its module cannot load, it
  allows the stop. What remains is one paid turn per refused stop while an agent ignores a 7-line
  instruction, and the case where the command scripts themselves are broken, which every package's
  `perl-compile` check guards. There is no turn cap to fall back on: `--max-turns` does not exist in
  2.1.280.
- **Headless coordinators and the holder.** Decision 4 puts coordinators under the holder. Headless
  `-p` kills background Bash tasks shortly after the final result (harness-facts (e)), and
  gate-headless-background forbids background Bash in coordinators. The design answers it without
  depending on the unmeasured case: a coordinator's hold counts only alongside a running background
  subagent it names, and a killed holder keeps its record. Package 08 measures the behaviour once.
- **The wake-lock's 12 hours.** Decision 18 ties the wake-lock to the armed state. With the 12-hour
  disarm gone, an arm file can outlive its session (a closed terminal, the old id after `/clear`). The
  lease therefore counts only arm files a Stop gate touched in the last 12 h. That keeps the earlier
  behaviour for the lock and never disarms anything.
- **Manual sessions after /clear.** Not a conflict: Decision 2 re-arms drive-solo and reporter sessions
  automatically and leaves every other session to `/butler:continuity on` or self-arm. A new id is a
  new session, so nothing is disarmed.
- **Command names.** The denial text must name `butler-continuity off --reason` (Decision 8 and the
  coverage test). Decision 47 settles the spelling: the commands are extensionless files.

## NEEDS-OPERATOR forks

Harness-facts lists three items only an interactive session can settle (Decision 13: measured, never
assumed). The design works under either answer to each (Decision 32), because no component reads
`$CLAUDE_CODE_SESSION_ID`. Commands bind through hook-written tickets or gate-minted stop tokens, and
all state is keyed by the payload `session_id`. Each assumption leans toward the outcome that does not
depend on the variable.

### D-1
question: Does /compact change the session id in-process?
if yes: The compacted session starts with an unarmed id. A drive-solo session re-arms at its next director call, a reporter or manual session must run butler-continuity on again, and the old id's arm file stays until its transcript is gone and stops holding the wake-lock 12 h after its last stop.
if no: nothing changes; arm state, holder and silence stay attached to the unchanged id.
assumed: no

### D-2
question: Does the in-process $CLAUDE_CODE_SESSION_ID follow the new id after /clear?
if yes: nothing changes; no component reads the variable, and commands bind to the session through tickets written by a hook that sees the payload session_id, or through a stop token the gate minted for that session.
if no: nothing changes, for the same reason; a stale variable cannot misdirect an arm, off, silence or holder.
assumed: no

### D-3
question: Does a carry-over-style clear allocate a new session id?
if yes: The fresh id starts unarmed. drive-solo re-arms at its first director call (Decision 2), and the carry-over prose tells a reporter or manual session to run butler-continuity on. The old id's arm file stays until its transcript is gone and stops holding the wake-lock 12 h after its last stop.
if no: nothing changes; the arm state carries over under the unchanged id and the re-arm call is an idempotent refresh.
assumed: yes

## Re-scope requests

For the driving session to apply (Decisions 29 and 35):

1. **Applied as Decision 47.** Package 04 ships plugins/butler/bin/butler-continuity and package 05
   ships plugins/butler/bin/butler-hold, both extensionless, in place of the `.sh` shims their write
   sets named. No `.sh` shim for either command is created. The denial text and skill prose name the
   commands as agents type them.
2. **04-continuity-command: add plugins/butler/scripts/BpHook/ContinuityOffCheck.pm.** Every hook file
   runs `run-hook.sh <Module>`, which calls `BpHook::<Module>::run`, and Decision 35 gives each hook
   package one module of its own. The logic of `continuity-off-check.sh` (ticket writing, the
   operator-record filter) needs that home, or 04 would have to edit 03's `BpHook.pm`. The shared
   ticket and stop-token functions stay in `BpHook.pm` (03), because the Stop gate (06) and both
   commands (04, 05) use them. The path is written here without code formatting until the write set
   is amended, because the coverage test's rule C13 checks formatted paths against blueprint.md.
