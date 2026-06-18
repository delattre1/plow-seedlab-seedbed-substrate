#!/usr/bin/env bash
# ============================================================================
# teardown.sh — destroy substrate container(s), KEEP the auth volume, release
# the lease back to the bank (free for the next container).
#
# Teardown doctrine: the container is ephemeral; the auth volume is durable and
# reused across many container lifetimes. We NEVER delete the volume here.
#
# Usage:
#   teardown.sh <container> [<container> ...]   # tear down specific containers
#   teardown.sh --prefix <prefix>               # tear down all <prefix>-* containers
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
LEASE="$ROOT/lease/lease.sh"
DOCKER="${DOCKER:-docker}"

teardown_one(){
  local ctr="$1"
  $DOCKER rm -f "$ctr" >/dev/null 2>&1 && echo "  destroyed container $ctr"
  # release whatever volume this container held (volume is preserved)
  $LEASE release-holder "$ctr" 2>/dev/null || echo "  (no lease recorded for $ctr)"
}

if [ "${1:-}" = "--prefix" ]; then
  pfx="${2:?usage: teardown.sh --prefix <prefix>}"
  mapfile -t ctrs < <($DOCKER ps -a --format '{{.Names}}' | grep -E "^${pfx}-[0-9]+$" || true)
  [ "${#ctrs[@]}" -gt 0 ] || { echo "no containers matching ${pfx}-*"; exit 0; }
  for c in "${ctrs[@]}"; do teardown_one "$c"; done
else
  [ "$#" -ge 1 ] || { echo "usage: teardown.sh <container>... | --prefix <prefix>"; exit 2; }
  for c in "$@"; do teardown_one "$c"; done
fi
echo "teardown complete (auth volumes kept; leases released)"
