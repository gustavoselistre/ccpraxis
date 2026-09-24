#!/usr/bin/env bash
# track-dispatch.sh -- tracks Task/Agent dispatch: the single write-capable
# worker interlock, the per-dispatch bp-dispatch-log.pl-shaped budget record,
# the coordinator ledger's auto dispatch log, and the driver's 2.5 per-
# dispatch marker. Absorbs log-dispatch, track-worker-solo and
# untrack-worker-solo. Logic in BpHook/Guards/TrackDispatch.pm; contract in
# docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::TrackDispatch --pre ledger,driver -- "$@"
