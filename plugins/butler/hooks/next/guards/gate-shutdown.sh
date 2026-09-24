#!/usr/bin/env bash
# gate-shutdown.sh -- STOP-AND-PARKs Task/Agent dispatch and edits outside
# BP_DIR/tmp while a fleet stop signal (shutdown, force-stop or paused) is
# active. Coordinator sessions only (BP_LEDGER set), as the old hook's
# bp_hook_gate was. Logic in BpHook/Guards/GateShutdown.pm; contract in
# docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GateShutdown --pre ledger --pre stopfile -- "$@"
