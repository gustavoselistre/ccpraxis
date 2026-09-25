#!/usr/bin/env bash
# guard-bash.sh -- merges guard-bash, gate-headless-background, guard-judge-checks
# and guard-validation-interlock into one Bash PreToolUse gate. Logic in
# BpHook/Guards/GuardBash.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardBash --pre ledger,driver -- "$@"
