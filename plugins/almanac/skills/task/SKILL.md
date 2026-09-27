---
name: task
description: The project's ordered task list, which persists across sessions. It holds steps of work actively under way now, never status notes or progress logs. Add the steps of multi-step work, focus the list for this session, and move each step through doing, blocked and done. Use proactively when starting work with more than one step and whenever a step changes state, and use when the operator asks where the work stands. Skip for one-step requests, for a subagent's own internal steps, and for follow-up work nobody is doing now, which goes in /almanac:todo.
allowed-tools: Bash, Read
---

# The project task list

One flat, ordered list per project, project scope only. Each step carries a status: `pending`,
`doing`, `blocked`, `done`, `obsoleted`. Status notes and progress logs do not belong here; move
the step's status instead.

## See where things stand

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task list
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task focused
```

## Add steps

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task focus
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task add --title "one step"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task add --title "waits on a call" --blocked-on <decision-id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task insert-after <id> --title "one step"
```

## Move them along

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task status <id> doing
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task status <id> done
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task move-first <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task edit <id> --blocked-on <decision-id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task edit <id> --clear-blocked-on
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" task show <id>
```

Focus is keyed to the session id and survives `--resume`.
