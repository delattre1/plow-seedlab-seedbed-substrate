#!/usr/bin/env bash
# ============================================================================
# spin.sh — spin N substrate containers from the golden image, each leasing a
# DISTINCT auth volume from the bank (atomic lease-next-free), then wait until
# each is SUBSTRATE_READY.
#
# Flow per substrate (the spin-from-image + lease-next-free flow):
#   1. ATOMIC lease next-free auth volume from the bank (lease.sh acquire).
#        - no free volume -> fail fast for THAT substrate (never double-lease).
#   2. docker run -d the golden image, mounting the leased volume at ~/.claude
#      (same flags as seedbed.seed.md Step 4).
#   3. wait for the SUBSTRATE_READY marker (golden image boots pre-hydrated).
#
# Because the image is a pre-hydrated seed snapshot, boot only re-establishes
# per-node identity (tailnet join, queue-client, worker, ttyd, recorder) — fast.
#
# Usage: spin.sh <N> [name-prefix]
#   N            number of substrates to spin
#   name-prefix  container name prefix (default: sub) -> <prefix>-1..<prefix>-N
#
# Env (source bank/bank.env first): GOLDEN_IMAGE, CLAUDE_MOUNT, BANK_SIZE,
#   READY_MARKER, READY_TIMEOUT, SEEDBED_LEASE_DIR, DOCKER.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
LEASE="$ROOT/lease/lease.sh"
DOCKER="${DOCKER:-docker}"
GOLDEN_IMAGE="${GOLDEN_IMAGE:-seedbed-golden:latest}"
CLAUDE_MOUNT="${CLAUDE_MOUNT:-/home/tester/.claude}"
READY_MARKER="${READY_MARKER:-/home/tester/SUBSTRATE_READY.json}"
READY_TIMEOUT="${READY_TIMEOUT:-15}"

N="${1:?usage: spin.sh <N> [name-prefix]}"
PREFIX="${2:-sub}"

# Spin one substrate: lease -> run -> (caller waits for ready). Prints a TSV line:
#   <result>\t<container>\t<volume>   where result = SPUN | NO_FREE_VOLUME | RUN_FAILED
spin_one(){
  local ctr="$1" vol
  vol="$($LEASE acquire "$ctr" 2>/dev/null)" || { printf 'NO_FREE_VOLUME\t%s\t-\n' "$ctr"; return 3; }
  if $DOCKER run -d --init --name "$ctr" --hostname "$ctr" \
        --add-host host.docker.internal:host-gateway \
        --cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun \
        -e NODE_NAME="$ctr" \
        -v "$vol:$CLAUDE_MOUNT" \
        "$GOLDEN_IMAGE" >/dev/null 2>&1; then
    printf 'SPUN\t%s\t%s\n' "$ctr" "$vol"
  else
    $LEASE release "$vol" >/dev/null 2>&1     # roll back the lease on a failed run
    printf 'RUN_FAILED\t%s\t%s\n' "$ctr" "$vol"
    return 1
  fi
}

# Wait until a container has the SUBSTRATE_READY marker (or timeout).
wait_ready(){
  local ctr="$1" deadline=$(( SECONDS + READY_TIMEOUT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    $DOCKER exec "$ctr" test -f "$READY_MARKER" 2>/dev/null && return 0
    sleep 0.3
  done
  return 1
}

echo "spin: requesting $N substrate(s) from $GOLDEN_IMAGE (bank free=$($LEASE free-count))"
START=$SECONDS
declare -a SPUN=()
# Launch all leases+runs concurrently (proves the atomic lease under concurrency).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for i in $(seq 1 "$N"); do ( spin_one "${PREFIX}-${i}" > "$TMP/$i" ) & done
wait
for i in $(seq 1 "$N"); do cat "$TMP/$i"; done | sort > "$TMP/all"
mapfile -t lines < "$TMP/all"

ready=0 failed=0
for l in "${lines[@]}"; do
  res="$(cut -f1 <<<"$l")"; ctr="$(cut -f2 <<<"$l")"; vol="$(cut -f3 <<<"$l")"
  case "$res" in
    SPUN)
      if wait_ready "$ctr"; then echo "  READY   $ctr  <- $vol"; ready=$((ready+1))
      else echo "  TIMEOUT $ctr  <- $vol (no SUBSTRATE_READY in ${READY_TIMEOUT}s)"; failed=$((failed+1)); fi ;;
    NO_FREE_VOLUME) echo "  FAILFAST $ctr (bank full — no free authed volume; nothing leased)"; failed=$((failed+1)) ;;
    RUN_FAILED)     echo "  RUNFAIL  $ctr (docker run failed; lease rolled back)"; failed=$((failed+1)) ;;
  esac
done
ELAPSED=$(( SECONDS - START ))
echo "spin: $ready READY, $failed failed, in ${ELAPSED}s (bank free now=$($LEASE free-count))"
[ "$failed" = 0 ]
