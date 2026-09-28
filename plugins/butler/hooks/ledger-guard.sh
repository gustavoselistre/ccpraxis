#!/usr/bin/env bash
# ledger-guard.sh -- refuses a package-ledger write whose resulting content would be corrupt.
# Logic in BpHook/WriteGuards.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" WriteGuards --pre text:packages --pre ledger,driver -- ledger "$@"
