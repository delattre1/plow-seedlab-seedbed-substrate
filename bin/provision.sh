#!/usr/bin/env bash
# ============================================================================
# provision.sh — spin N substrates to READY (single Boss window, live Boss claude),
# in parallel, and report per-substrate ready time + total wall clock.
#
# This is the committed, zero-manual-step version of the run that hit 5-ready in
# ~15.8s. Each node, in parallel:
#   lease an auth volume -> docker run the golden image -> wait SUBSTRATE_BOOTED
#   -> bin/spawn-boss.sh (spawn live Boss claude into the Boss window, kill strays)
#   -> mark ready when the Boss window shows a live claude.
#
# Run on the coordinator (central queue / Boss host). DOCKER honors DOCKER_HOST.
# Source bank/bank.env is automatic; runtime secrets come from the gitignored
# host-local SUBSTRATE_ENV (default ~/.config/seedbed/substrate.env).
#
# Usage: provision.sh <N> [name-prefix]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
SUBSTRATE_ENV="${SUBSTRATE_ENV:-$HOME/.config/seedbed/substrate.env}"
# shellcheck disable=SC1090
[ -f "$SUBSTRATE_ENV" ] && . "$SUBSTRATE_ENV"
LEASE="$ROOT/lease/lease.sh"
DOCKER="${DOCKER:-docker}"
GOLDEN_IMAGE="${GOLDEN_IMAGE:-seedbed-golden:latest}"
# Ensure the (possibly substrate.env-provided) bank pointer is EXPORTED so the
# lease.sh subprocess inherits it — else it falls back to the generic placeholder bank.
export BANK_FILE SEEDBED_LEASE_DIR GOLDEN_IMAGE DOCKER
CLAUDE_MOUNT="${CLAUDE_MOUNT:-/home/tester/.claude}"
READY_MARKER="${READY_MARKER:-/home/tester/SUBSTRATE_BOOTED.json}"
N="${1:?usage: provision.sh <N> [name-prefix]}"
PFX="${2:-sub}"

ready_one(){
  local ctr="$1" vol
  vol="$($LEASE acquire "$ctr" 2>/dev/null)" || { echo "NO_FREE_VOLUME"; return 3; }
  $DOCKER run -d --init --name "$ctr" --hostname "$ctr" --add-host host.docker.internal:host-gateway \
    --cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun \
    -e NODE_NAME="$ctr" -e TAILSCALE_API_KEY="${TAILSCALE_API_KEY:-}" -e TS_TAILNET="${TS_TAILNET:--}" \
    -e CENTRAL_QUEUE_URL="${CENTRAL_QUEUE_URL:-}" -e CENTRAL_QUEUE_SECRET="${CENTRAL_QUEUE_SECRET:-}" \
    -e CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}" \
    -e TKMX_API_KEY="${TKMX_API_KEY:-}" -e TKMX_USERNAME="${TKMX_USERNAME:-}" -e TKMX_SERVER_URL="${TKMX_SERVER_URL:-https://tokenmaxxing.odio.dev}" \
    -v "$vol:$CLAUDE_MOUNT" "$GOLDEN_IMAGE" >/dev/null 2>&1 || { $LEASE release "$vol" >/dev/null 2>&1; echo "RUN_FAILED"; return 1; }
  local d=$(( SECONDS + 60 ))
  while [ "$SECONDS" -lt "$d" ]; do $DOCKER exec "$ctr" test -f "$READY_MARKER" 2>/dev/null && break; sleep 0.3; done
  MP="${MP:-$HOME/mypeople/bin/mp}" DOCKER="$DOCKER" CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}" \
    "$ROOT/bin/spawn-boss.sh" "$ctr" >/dev/null 2>&1 || { echo "BOSS_FAILED"; return 1; }
  echo "READY"
}

echo "provision: $N substrates from $GOLDEN_IMAGE -> ready (live Boss claude)"
START=$SECONDS
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for i in $(seq 1 "$N"); do
  ( s=$SECONDS; r=$(ready_one "${PFX}-${i}"); printf '%s\t%s\t%s\n' "${PFX}-${i}" "$r" "$(( SECONDS - START ))" > "$TMP/$i" ) &
done
wait
TOTAL=$(( SECONDS - START ))
echo "=== per-substrate ready (s from spawn-start) ==="
ok=0
for i in $(seq 1 "$N"); do
  read -r ctr res el < "$TMP/$i"
  if [ "$res" = READY ]; then
    ip=$($DOCKER exec "$ctr" bash -lc 'sudo cat /home/tester/mypeople/run/tailscale-state/ip 2>/dev/null')
    printf "  %-8s READY %ss   http://%s:7681/\n" "$ctr" "$el" "$ip"; ok=$((ok+1))
  else printf "  %-8s %s\n" "$ctr" "$res"; fi
done
echo "=== TOTAL wall clock (spawn-start -> all ready): ${TOTAL}s ($ok/$N) ==="
[ "$ok" -eq "$N" ]
