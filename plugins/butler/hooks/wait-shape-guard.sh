#!/usr/bin/env bash
# wait-shape-guard.sh -- PreToolUse guard for repeated identical calls and four
# wait/poll pathologies (wait-loop, false-green-pipe, task-output-artifact-poll,
# task-output-repeat-poll). Absorbs repeat-guard. Logic in
# BpHook/Guards/WaitShapeGuard.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::WaitShapeGuard --pre ledger -- "$@"
