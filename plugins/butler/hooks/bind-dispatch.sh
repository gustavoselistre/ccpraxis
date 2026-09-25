#!/usr/bin/env bash
# bind-dispatch.sh -- binds each Task/Agent dispatch to one package by
# tool_use_id; with 2+ packages in flight in an armed driver session, denies
# a prompt that names no single in-flight ledger. Logic in
# BpHook/BindDispatch.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" BindDispatch --pre ledger,driver -- "$@"
