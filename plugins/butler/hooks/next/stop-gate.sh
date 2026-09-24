#!/usr/bin/env bash
# stop-gate.sh -- the one Stop gate. Logic in BpHook/StopGate.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" StopGate --pre ledger,armed -- "$@"
