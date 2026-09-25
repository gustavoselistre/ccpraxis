#!/usr/bin/env bash
# guard-writes.sh -- keeps each edit inside the write set of the package its author is bound to.
# Logic in BpHook/WriteGuards.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" WriteGuards --pre ledger,driver -- writes "$@"
