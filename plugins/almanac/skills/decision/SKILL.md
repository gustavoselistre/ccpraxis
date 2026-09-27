---
name: decision
description: File anything that needs the operator -- a manual check, a taste call, a question -- keep working, and record the answer when it comes. It shows as the statusline flag in every session of the project until answered. Use when the choice is genuinely the operator's (scope, priorities, user-visible behaviour, spending a limited budget) and other work can continue meanwhile, and use when the operator answers one or asks what is pending. Skip for technical questions you can settle from the code, the docs or a measurement, and decide those yourself with the assumption stated.
allowed-tools: Bash, Read
---

# Pending product decisions

A product call (scope, priorities, user-visible behaviour, spending a limited budget) goes here.
An implementation call, settled from the code, the docs or a measurement, does not; decide that
yourself and state the assumption.

Filing returns immediately. Carry on with other work rather than waiting on an answer.

## See what's pending

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" decision list
```

## File one

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" decision file --title "one line" --body "the choice and why it's the operator's"
```

## Work it

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" decision show <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" decision answer <id> --answer "..."
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" decision blocks <id>
```

A task waiting on a decision carries `--blocked-on <decision-id>` (see /almanac:task); `answer`
lists the tasks it unblocks.
