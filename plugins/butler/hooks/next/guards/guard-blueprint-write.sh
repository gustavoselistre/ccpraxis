#!/usr/bin/env bash
# guard-blueprint-write.sh -- denies a direct write to blueprint.md or a
# package ledger path, absorbing guard-ledger-create. Logic in
# BpHook/Guards/GuardBlueprintWrite.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardBlueprintWrite --pre text:blueprint -- "$@"
