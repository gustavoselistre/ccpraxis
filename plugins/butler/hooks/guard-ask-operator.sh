#!/usr/bin/env bash
# guard-ask-operator.sh -- denies AskUserQuestion while continuity is armed
# for this session, queuing the question instead. Logic in
# BpHook/Guards/GuardAskOperator.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardAskOperator --pre ledger,armed -- "$@"
