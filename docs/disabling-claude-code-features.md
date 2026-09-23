# Disabling a Claude Code feature: which lever removes it from context

Reference for a recurring question: to keep a built-in tool, MCP server, subagent type, or skill
out of an agent's context entirely (not merely blocked at call time), which setting actually does
that? Written after `.ccpraxis-local-data/bug-reports/20260922-213748-6c76.md` found this
undocumented and cost two passes on a `SendFeedback` fix. Verified against Claude Code 2.1.280
(2026-09-23); re-check on major version bumps, since these are shipped-binary behaviors, not a
stable public contract.

## The core distinction

Per [code.claude.com/docs/en/permissions](https://code.claude.com/docs/en/permissions) (Deny and
ask rules section): "A bare tool name like `Bash` removes the tool from Claude's context entirely,
so Claude never sees it... A scoped rule like `Bash(rm *)` leaves the tool available and blocks
matching calls when Claude attempts them." The same page confirms a bare-name **glob** deny (e.g.
`"mcp__*"`) has the same context-removing effect as a bare literal name.

So for `permissions.deny` / `--disallowedTools`: **bare name → out of context; scoped pattern →
call-time gate only.** This is the one lever that generalizes across tool categories.

## Per-category levers, verified

| category | removes from context | gates calls only | source |
|---|---|---|---|
| built-in tool | bare name in `permissions.deny` / `--disallowedTools`; a tool's own kill switch when it has one (e.g. `feedbackDrafts: "off"` for SendFeedback, plus its env vars `CLAUDE_CODE_SEND_FEEDBACK=0` / `DISABLE_FEEDBACK_COMMAND=1`) | scoped rule, e.g. `Bash(rm *)` | [permissions](https://code.claude.com/docs/en/permissions); [tools-reference](https://code.claude.com/docs/en/tools-reference) ("Sessions without Claude-drafted feedback") |
| MCP server | `disabledMcpjsonServers` (settings key); bare `mcp__<server>__*` glob deny | scoped rule on one MCP tool, e.g. `mcp__server__tool(pattern)` | [permissions](https://code.claude.com/docs/en/permissions) |
| subagent type | `Agent(<name>)` in `permissions.deny` (e.g. `Agent(Explore)`) or `--disallowedTools` | *(not applicable — Agent rules match by name, not by call pattern)* | [permissions § Agent (subagents)](https://code.claude.com/docs/en/permissions) |
| skill | **unverified.** No dedicated "Skill" rule section found on the permissions page (checked 2026-09-23). This repo's settings only use `Skill(plugin:name)` in `permissions.allow` (see `global-config/settings.json`), never in `deny` — that is precedent for the syntax, not confirmation that a bare or scoped `Skill(...)` deny removes a skill from context. Verify before relying on it. | — | none found yet |
| `fork` (the `Agent` subagent_type that inherits the caller's context) | **unknown.** No lever found. | — | none found yet |

Also confirmed: non-interactive `claude -p` runs and Agent SDK sessions never receive several
tools regardless of settings (SendFeedback among them) — see the `tools-reference` quote above.
Do not assume this generalizes to every built-in tool without checking that tool's own doc section.

## What this does NOT cover

- This table is about **built-in Claude Code levers**. It says nothing about ccpraxis-specific
  gating (butler write-set guards, hook-enforced constraints) — those are a different mechanism
  documented per-plugin.
- A hand-maintained "which tools/skills/subagents currently exist" inventory drifts with every
  release and plugin change and is deliberately not attempted here. If that inventory is ever
  needed, generate it (`claude -p --output-format stream-json --verbose` for the tool list; each
  enabled plugin's `agents/*.md` and `skills/*/SKILL.md` for subagents/skills) rather than
  hand-maintaining it — only the lever mapping above is worth keeping as prose.
