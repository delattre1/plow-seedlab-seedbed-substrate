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
# Source host-local secrets/defaults (esp. SEEDBED_LEASE_DIR + BANK_FILE) so the
# lease release hits the SAME lease dir spin.sh acquired into. Mirrors spin.sh:
# CALLER ENV WINS — snapshot any control vars the caller explicitly exported,
# source the file, then restore the snapshot. Without this, release-holder falls
# back to lease.sh's compiled-in default lease dir and ORPHANS the lease on any
# host whose substrate.env overrides SEEDBED_LEASE_DIR.
SUBSTRATE_ENV="${SUBSTRATE_ENV:-$HOME/.config/seedbed/substrate.env}"
_TD_CTRL_VARS="BANK_FILE SEEDBED_LEASE_DIR DOCKER"
for _v in $_TD_CTRL_VARS; do eval "[ -n \"\${$_v+x}\" ] && _TD_SAVED_$_v=\"\${$_v}\""; done
# shellcheck disable=SC1090
[ -f "$SUBSTRATE_ENV" ] && . "$SUBSTRATE_ENV"
for _v in $_TD_CTRL_VARS; do eval "[ -n \"\${_TD_SAVED_$_v+x}\" ] && $_v=\"\${_TD_SAVED_$_v}\""; done
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
