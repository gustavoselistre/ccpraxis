---
name: note
description: Keep a durable fact as an almanac note, a pointer plus metadata for a file that holds the fact, in project or global scope. Use proactively when you learn something a future session needs and would otherwise lose, such as a platform quirk, a measured figure or an operator preference, and use when the operator says "remember this" or "make a note". Skip for work still to do (/almanac:todo), for task progress (/almanac:task), and for facts already written in CLAUDE.md or a tracked doc.
allowed-tools: Bash, Read
---

# Notes that outlive a session

A note record points at a content file rather than embedding the fact itself. `internal` (the
default) creates that file for you, at `.ccpraxis-local-data/notes/<id>.md` in the project or
`notes/<id>.md` in the vault for a global note; `external` points at an existing versioned `.md`
you name with `--target`.

Project is the default; add `--global` for anything cross-project. Inside a sandbox only project
scope is reachable; a `--global` call there is refused by the store itself.

## See what's recorded

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note list
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note list --global
```

## Add one

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note create --title "one line" --covers "what it's about" \
  --content -   <<'NOTE'
...the fact...
NOTE
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note create --audience external --target docs/x.md \
  --title "one line" --covers "what it's about"
```

## Work it

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note show <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note edit <id> --covers "..."
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note promote <id> --target docs/x.md
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note delete <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" note check-pointers
```

A global note appears in the imported notes index `~/.claude/almanac-notes.md` once someone runs
`perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac-migrate-memories.pl" render-index` on the host.
