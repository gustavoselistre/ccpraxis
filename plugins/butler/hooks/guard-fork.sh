#!/usr/bin/env bash
# guard-fork.sh -- denies every Agent/Task dispatch whose subagent_type is
# "fork" (package 19 of blueprint hook-continuity-remake, Decision 64/90).
# Logic in BpHook/Guards/GuardFork.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardFork --pre text:fork -- "$@"
