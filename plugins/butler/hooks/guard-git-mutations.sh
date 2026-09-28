#!/usr/bin/env bash
# guard-git-mutations.sh -- denies git working-tree/history mutations (stash,
# checkout/switch/restore/reset/clean). Logic in
# BpHook/Guards/GuardGitMutations.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
for a in "$@"; do
  if [ "$a" = "--only-during-butler-run" ]; then
    exec bash "$d/run-hook.sh" Guards::GuardGitMutations --pre text:git --pre ledger,armed -- "$@"
  fi
done
exec bash "$d/run-hook.sh" Guards::GuardGitMutations --pre text:git -- "$@"
