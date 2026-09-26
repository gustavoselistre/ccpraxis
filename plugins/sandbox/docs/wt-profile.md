# The `[c]` Windows Terminal profile

## What this is

Pressing `[c]` (launch-claude) in the sandbox dashboard opens a new Windows Terminal
window. That window runs under a Windows Terminal profile named `claude-sandbox`,
whose only purpose is cosmetic: it hides the scrollbar gutter. `wt.exe` has no
command-line flag for that setting directly, so the only way to get a
scrollbar-free window is to launch it under a profile that sets
`scrollbarState: "hidden"`.

## Where the profile lives

The profile is not written into the user's own Windows Terminal settings. It is
delivered as a JSON fragment extension, a mechanism Windows Terminal reads
automatically from every application's `Fragments` folder, at:

```
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\ccpraxis\claude-sandbox.json
```

The user's own Windows Terminal `settings.json` (the packaged/Store location
or the unpackaged one, whichever exists) is read, read-only, on every `[c]`
press, to copy the operator's default profile's appearance into the
fragment. It is never written, never backed up and never copied by this
feature — only its `profiles.defaults` and default-profile appearance keys
are inspected.

## What it sets

The fragment always sets `scrollbarState: "hidden"`, plus the `name` and
`guid` needed to identify the profile. On top of that, it copies the related
appearance keys (font face/size/weight/features, `colorScheme`, cursor and
background colors, `opacity`, `useAcrylic`, `padding` and a few others) from
the operator's default Windows Terminal profile, merged with
`profiles.defaults`. If the settings file cannot be read or parsed, or no
default profile can be resolved, the fragment falls back to just
`scrollbarState: "hidden"` — the window still inherits the user's own
`profiles.defaults` and looks like their normal terminal minus the
scrollbar.

## When it is written

On every `[c]` press, immediately before the window opens, and only when the
file's content differs from what is already on disk. An unchanged fragment is
not rewritten — the common case, on every press after the first.

## What happens when it fails

Writing or reading the fragment is a best-effort, cosmetic step. If the
fragment itself cannot be produced — `%LOCALAPPDATA%` unresolvable, the
fragment directory uncreatable, the file unwritable, or anything else — the
`[c]` window still opens, under no profile, exactly as it did before this
feature existed. One `launch_profile_degraded` event carrying a
machine-readable reason is written to the launch log so that failure is
visible without ever blocking the session.

Reading the operator's `settings.json` for appearance is a narrower,
separate failure mode: if that file is missing, unreadable, unparseable, or
has no resolvable default profile, the `[c]` window still opens under the
`claude-sandbox` profile — only its appearance falls back to the bare
`scrollbarState: "hidden"` fragment, not the pre-feature no-profile
behavior. This never blocks the session, but today it is not yet written to
the launch log as its own event — only visible to a caller inspecting
`WtProfile::ensure_fragment`'s return value directly.

## What does NOT degrade

A missing `wt.exe` itself is a different matter: `[c]` requires Windows
Terminal, and that path still fails loudly — there is no fallback to a plain
console, by design. That behavior is unchanged by this feature; only the
cosmetic profile step degrades silently, never the requirement for Windows
Terminal itself.

## No off-switch

There is no off-switch for this behavior, and none is planned. ccpraxis owns
the fragment file entirely: the next `[c]` press rewrites it whenever its
content differs from what ccpraxis expects. Deleting it is not durable — the
very next launch simply recreates it. There is no flag, no environment
variable, and no settings key that disables this. The only way to turn it off
is editing ccpraxis itself.

## Scope

This only affects the windows that `[c]` spawns. The manager window (the one
you are reading the dashboard in) is launched by you, under your own default
profile, and is completely untouched by any of this.
