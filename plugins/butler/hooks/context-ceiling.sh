#!/usr/bin/env bash
# context-ceiling.sh -- coordinator-only context flush enforcement (PreToolUse)
# and guidance (PostToolUse). Absorbs context-ceiling-flush and
# context-ceiling-guidance. Logic in BpHook/Guards/ContextCeiling.pm; contract
# in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::ContextCeiling --pre coordinator -- "$@"
