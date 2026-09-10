#!/bin/bash
# bp-continuity.sh — thin shim so the continuity verbs are reachable by name
# instead of by a path nobody can type. All logic lives in
# ../scripts/bp-continuity.pl; this only locates it and exec's it.
#
# RESOLVED FROM THIS FILE'S OWN LOCATION, not from $HOME. claude-sandbox.sh
# hardcodes ~/.claude/ccpraxis/... because it only ever runs on the host. This
# one is also read inside a sandbox, where the plugin tree is bind-mounted at
# /root/.claude/plugins/marketplaces/ccpraxis-local/, so a $HOME assumption
# would point at nothing. BASH_SOURCE follows the file wherever it lives.
set -e

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(cd "$BIN_DIR/.." && pwd)/scripts/bp-continuity.pl

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: bp-continuity.pl not found at $SCRIPT" >&2
  echo "       This shim expects to sit in <plugin>/bin next to <plugin>/scripts." >&2
  exit 1
fi

exec perl "$SCRIPT" "$@"
