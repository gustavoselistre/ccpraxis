#!/usr/bin/env bash
# arm-on-entry.sh -- arms a driving session on its first real director "next" call. Logic in BpHook/ArmOnEntry.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" ArmOnEntry --pre text:bp-drive-next -- "$@"
