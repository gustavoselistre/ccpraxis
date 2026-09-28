---
name: ccpraxis-extend
description: THE single entrypoint for changing ccpraxis or adding new functionality to it. Decides whether the request is NEW (scaffold a skill, plugin, or plugin-skill — applying the packaging rule) or a CHANGE (locate the existing skill/plugin/script and edit it), then does the work and wires it in (related links, settings perms, marketplace, README). Use proactively whenever the user wants to add, build, create, scaffold, or design a new skill / plugin / slash command / capability for ccpraxis, OR change, fix, improve, refactor, rename, or extend an existing ccpraxis skill, plugin, or script. Use when the user says "add a skill", "make a plugin", "new slash command", "extend ccpraxis", "change the X skill", "update the Y plugin", or describes a capability they want ccpraxis to have.
argument-hint: [what you want to add or change]
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob, Grep, Skill
---

# /steward:ccpraxis-extend

The one tool for evolving ccpraxis. The user does **not** pick "create vs update" or "skill vs plugin" — they describe what they want in their own words and this skill figures out the shape. It absorbs what used to be `/create-skill` and `/update-skill`, generalized beyond a single skill to **skills, plugins, plugin-skills, and scripts**.

This skill operates on a **checked-out ccpraxis clone**: read, edit, and validate the clone, then stop. It never touches the machinery a session is running from.

The request: `$ARGUMENTS`. If empty, ask the user what they want to add or change.

**Take your time.** Extending ccpraxis is a design task. Read the references, understand the request, propose the shape, and confirm before writing anything. Don't rush to deliver.

## Before anything: confirm this is a ccpraxis clone

Find the repo toplevel and confirm it is a tracked ccpraxis checkout, never the install a session runs from:

```bash
top="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$top" ] && grep -q '"name": *"ccpraxis-local"' "$top/plugins/.claude-plugin/marketplace.json"
```

If there is no git toplevel, or `$top/plugins/.claude-plugin/marketplace.json` is missing or its `name` field isn't `ccpraxis-local`, stop with exactly one line and write nothing:

> Not a ccpraxis clone: /steward:ccpraxis-extend only works inside a checkout of the ccpraxis repository.

Otherwise, guard against the live install with a resolved, case-folded, trailing-slash-anchored compare. This catches both an `ANDR~1`-style short name and a case variant, neither of which a plain string compare would.

```bash
hc=$(cd "$HOME/.claude" 2>/dev/null && pwd -P | tr 'A-Z' 'a-z')
real=$(cd "$top" && pwd -P | tr 'A-Z' 'a-z')
[ -n "$hc" ] && case "$real/" in "$hc"/*) echo LIVE ;; esac
echo "$top"
```

If that prints `LIVE`, stop with exactly one line and write nothing (a missing `$HOME/.claude` never matches, so an empty `$hc` never triggers this):

> Refusing: this checkout is under $HOME/.claude, the live install, not a development clone. Work in your clone.

Otherwise the last line printed is the repo's absolute path. Bash calls do not share shell variables, so `$top` will not survive into a later call. Take that printed absolute path and use it literally, in place of every `<repo>` below, in every later command, including `Read`/`Edit`/`Write` targets, which no shell re-derivation covers anyway. Never re-run `git rev-parse --show-toplevel` later in this task: if a later step changes the working directory, re-deriving from the cwd would silently point at the wrong tree and skip the guard above.

## Step 0 — Load the references (always)

Two docs are load-bearing. Read both before scaffolding or editing:

- **`references/extending-ccpraxis.md`** — where extensions live (plugin / standalone skill / standalone surface), the packaging rule, plugin layout, the `ccpraxis-install.pl` contract, marketplace + `enabledPlugins` wiring, and a worked plugin example.
- **`references/skill-writing-guide.md`** — frontmatter fields, progressive disclosure, description-writing, string substitutions, and style for the SKILL.md body itself.

```bash
cat "<repo>/references/extending-ccpraxis.md"
cat "<repo>/references/skill-writing-guide.md"
```

Everything below assumes you've internalized them — this skill is the *process*; those docs are the *conventions*. Don't duplicate their detail here; defer to them.

## Step 1 — Understand the request, classify NEW vs CHANGE

Parse `$ARGUMENTS` (or ask). Decide which it is:

- **NEW** — the capability doesn't exist yet ("I want something that does X"). → Step 2.
- **CHANGE** — modify/fix/refactor/rename/remove something that already exists ("change the backup skill to…", "the X plugin should also…"). → Step 3.

If genuinely ambiguous (e.g. "make the todo thing also sync on close" — is that a new skill or a change to an existing one?), don't guess — ask the user with `AskUserQuestion`, framing both readings. When the request names an existing surface, it's almost always a CHANGE. When in doubt, a quick `Glob`/`Grep` over `plugins/` and `skills/` tells you whether the thing already exists.

## Step 2 — NEW: pick the shape, propose, scaffold

### 2a. Apply the packaging rule

This is the rule the skill exists to enforce (memory `feedback_packaging_multi_op`). Analyze the request: **how many distinct user-facing operations, on how many domain objects, with how much shared state?**

| Situation | Shape | Where |
|-----------|-------|-------|
| 1 operation, or operations with no shared domain object | **standalone skill** | `skills/<name>/SKILL.md` |
| 2+ user-facing operations on **one** domain object | **new plugin**, one verb per skill | `plugins/<name>/` + `.claude-plugin/plugin.json` + `skills/<verb>/` |
| Adding an operation that belongs to an **existing** plugin's domain | **new skill inside that plugin** | `plugins/<existing>/skills/<verb>/` |

Standalone surfaces (top-level dirs) are reserved and rare — see the reference. Default to plugin/skill.

### 2b. Propose the shape, then confirm

State the chosen shape with a **one-line justification**, and confirm before scaffolding (memory `feedback_propose_vs_auto` — propose + decide, don't silently choose):

> This is 2 operations (`pack`, `unpack`) on one domain object (a backpack item), so I'll make it a **plugin** `backpack/` with `skills/pack/` and `skills/unpack/`. Sound right?

If it could legitimately go two ways, use `AskUserQuestion` with both options and the tradeoff (memory `feedback_design_conversation`) rather than asserting one. Only scaffold after the user agrees.

### 2c. Gather requirements + design

For each skill being created, settle: name (kebab-case, no "claude"/"anthropic"), one-line purpose, trigger conditions, `user-invocable` vs internal, needed `allowed-tools`, `host-only`?, whether it needs supporting files or a backing script, and how multiple skills divide responsibility. Ask follow-ups when the description is thin. Then present the full design (frontmatter + step outline + folder structure + `related` wiring) and get approval — see `create`-flow detail in `references/extending-ccpraxis.md` and the guide.

### 2d. Scaffold

Write the files into the **repo** (never into a live install):

- **Standalone skill:** `skills/<name>/SKILL.md` (+ any one-level-deep supporting files / `scripts/`).
- **New plugin:** `plugins/<name>/.claude-plugin/plugin.json` (no `displayName` — the validator rejects it), `skills/<verb>/SKILL.md` per verb, optional `scripts/`, `bin/` (+ `ccpraxis-install.pl` only if it ships a CLI that must land on PATH — delegate to `scripts/_install-bin-helper.pl`). Reference bundled scripts from a skill body via `${CLAUDE_PLUGIN_ROOT}/scripts/...` in bash blocks (the env var bash expands at runtime), matching the other steward skills.
- **Skill inside an existing plugin:** just `plugins/<existing>/skills/<verb>/SKILL.md`.

Then go to Step 4 (wiring).

## Step 3 — CHANGE: locate, scope, edit

### 3a. Detect the target's shape

Find what the user named and classify it, because the edit + rewiring differ:

```bash
ls -d "<repo>/skills/<name>" "<repo>/plugins/<name>" \
      "<repo>"/plugins/*/skills/<name> 2>/dev/null
```

- **bare skill** → `skills/<name>/`
- **plugin** → `plugins/<name>/` (a change may touch its `plugin.json`, several skills, scripts, hooks)
- **plugin-skill** → `plugins/<plugin>/skills/<name>/`
- **script** → a `.pl`/`.sh` under `scripts/` or a plugin's `scripts/`

If the name is unfamiliar, `Grep` for it before assuming it's missing. If it truly doesn't exist, this is really a NEW request — switch to Step 2.

### 3b. Expand the working set via `related` (skills only)

For skill targets, read the `related:` list in frontmatter and take the **transitive closure** — follow each related skill's `related` until the set stops growing. These siblings are pulled in for **consistency review**, not necessarily modification; tell the user which were added and why. (This is the old `/update-skill` behavior, preserved.)

### 3c. Read everything in scope, design, confirm

Read the full SKILL.md / script of every target + sibling and the guide, so you understand current behavior, frontmatter rationale, edge cases, and the 500-line budget before touching anything. Present the planned changes per file (what changes, what's preserved, ripple effects on README/settings/related skills, edge cases) and get approval via `AskUserQuestion`.

### 3d. Edit surgically

Use `Edit` for targeted changes (preserve everything the user didn't ask to change); reserve `Write`/full-rewrite for when a rewrite is genuinely cleaner. Keep the existing style, numbering, and frontmatter field order. If the change is a **rename or removal**, treat it as a change plus the reverse of the relevant wiring in Step 4 (move/delete the dir, drop the `Skill(...)` perm, drop the marketplace/`enabledPlugins` entry for a removed plugin), then regen the README.

Then go to Step 4 (wiring).

## Step 4 — Wire it in (both paths)

Only the steps that apply to what you touched:

1. **`related` frontmatter.** Skills created together link to each other; a new skill that pairs with an existing one is added to both `related` lists. Keep links symmetric.

2. **Settings permission.** For a user-invocable skill, add an allow entry so it doesn't prompt — `Skill(<name>)` for a bare skill, `Skill(<plugin>:<verb>)` for a plugin skill — to the repo source `global-config/settings.json`. Keep the list alphabetical.

3. **New plugin only:** register it in `plugins/.claude-plugin/marketplace.json` (`{"name","source":"./<name>","description"}`) and enable it — add `"<name>@ccpraxis-local": true` to `enabledPlugins` in `global-config/settings.json`. If you instead added a skill to an **existing** plugin, just update that plugin's `plugin.json` description so it stays accurate.

4. **Docs.** The file tree is generated and lives in **`docs/repo-layout.md`**, not the README — never hand-edit it. Run the clone's own scripts, in order:
   ```bash
   perl "<repo>"/scripts/gen-readme-tree.pl --write
   perl "<repo>"/scripts/gen-readme-tree.pl --check
   perl "<repo>"/scripts/lint-readme-paths.pl
   ```
   The tree comment comes from a `.about` sidecar if present, else `plugin.json`, else the SKILL.md `description` — so a good frontmatter description is usually enough; add a `<name>.about` one-liner only to override.

   Then place any prose by audience, because the split is the point:
   - **`README.md`** — the front door. Only touch it if the change alters *what
     ccpraxis is or why someone would want it*. A new slash command belongs in
     its "What you actually type" table; a new capability worth choosing the
     project for belongs in "What makes it different". Most changes need
     neither. Keep it short — it was cut from 849 lines to ~257 on purpose.
   - **`docs/reference.md`** — how the thing works. This is where mechanics,
     contracts, and flows go.
   - **`docs/install-protocol.md`** — only if the install procedure changed.

   Re-run `--check` + lint until clean.

## Step 5 — Validate + self-review

- **Plugin manifest** (if you created/changed a plugin): validate against the repo toplevel.
  ```bash
  claude plugin validate "<repo>/plugins/<name>"
  ```
  If you touched `plugins/.claude-plugin/marketplace.json`, also validate `"<repo>/plugins"` so the marketplace manifest itself is checked. This works the same on the host and inside a sandbox, since both carry the `claude` CLI.
- **Read back** every file you wrote or edited and self-review against the guide: third-person description with triggers, steps unambiguous, under 500 lines, supporting files one level deep, `related` symmetric, cross-references correct, works on Windows + Unix.

## Step 6 — Report

Tell the user: what was created/changed and its shape; the slash command(s) it adds once promoted; how `related`/settings/marketplace were wired; and that the README regenerated clean.

If the change added a bare skill or a new plugin, the report must also give the host-side follow-up, since nothing sits behind that slash command until it runs. Promotion (`perl scripts/promote.pl`, host-side, from the clone) merges the code and settings but does not mirror skills or record a plugin install. After promoting, run the live install's `install.pl --confirm`, then `/steward:backup`. Between them they link any new bare skill into the live install's skills directory and flag a new plugin that still needs installing. Skipping this leaves the change present on disk and invisible to Claude.

**Changed in the clone; inert until promoted by merge.**
