#!/usr/bin/env bash
# continuity-off-check.sh -- writes command tickets; flags an operator-typed /butler:continuity off. Logic in BpHook/ContinuityOffCheck.pm.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" ContinuityOffCheck --pre text:butler-continuity,text:butler-hold -- "$@"
