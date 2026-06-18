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
# Runtime secrets for the boot entrypoint (gitignored, host-local; never in repo).
SUBSTRATE_ENV="${SUBSTRATE_ENV:-$HOME/.config/seedbed/substrate.env}"
# shellcheck disable=SC1090
[ -f "$SUBSTRATE_ENV" ] && . "$SUBSTRATE_ENV"
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
  # SPIN_CMD: optional container command. Default empty = rely on the golden
  # image's long-running entrypoint (golden-boot.sh). Set it (e.g. "sleep
  # infinity") for a base image whose default command would exit under `-d`.
  #
  # Runtime secrets (NEVER baked): injected via -e from a host-local gitignored
  # file (default ~/.config/seedbed/substrate.env). The boot entrypoint uses them
  # to mint a fresh tailscale identity and JOIN the central queue.
  if $DOCKER run -d --init --name "$ctr" --hostname "$ctr" \
        --add-host host.docker.internal:host-gateway \
        --cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun \
        -e NODE_NAME="$ctr" \
        -e TAILSCALE_API_KEY="${TAILSCALE_API_KEY:-}" \
        -e TS_TAILNET="${TS_TAILNET:--}" \
        -e CENTRAL_QUEUE_URL="${CENTRAL_QUEUE_URL:-}" \
        -e CENTRAL_QUEUE_SECRET="${CENTRAL_QUEUE_SECRET:-}" \
        -e CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}" \
        -e TKMX_API_KEY="${TKMX_API_KEY:-}" \
        -e TKMX_USERNAME="${TKMX_USERNAME:-}" \
        -e TKMX_SERVER_URL="${TKMX_SERVER_URL:-https://tokenmaxxing.odio.dev}" \
        -e TKMX_TEAM="${TKMX_TEAM:-seedbed}" \
        -e TKMX_REPORT_INTERVAL="${TKMX_REPORT_INTERVAL:-300}" \
        -v "$vol:$CLAUDE_MOUNT" \
        "$GOLDEN_IMAGE" ${SPIN_CMD:-} >/dev/null 2>&1; then
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
# Wait for readiness CONCURRENTLY (booted markers appear in parallel) so per-container
# timeouts never stack — wall-clock = slowest boot, not the sum.
WTMP="$(mktemp -d)"
for l in "${lines[@]}"; do
  res="$(cut -f1 <<<"$l")"; ctr="$(cut -f2 <<<"$l")"; vol="$(cut -f3 <<<"$l")"
  case "$res" in
    SPUN) ( if wait_ready "$ctr"; then echo "READY $ctr $vol"; else echo "TIMEOUT $ctr $vol"; fi > "$WTMP/$ctr" ) & ;;
    NO_FREE_VOLUME) echo "NOFREE $ctr -" > "$WTMP/$ctr" ;;
    RUN_FAILED)     echo "RUNFAIL $ctr $vol" > "$WTMP/$ctr" ;;
  esac
done
wait
for f in "$WTMP"/*; do
  read -r st ctr vol < "$f"
  case "$st" in
    READY)   echo "  READY    $ctr  <- $vol"; ready=$((ready+1)) ;;
    TIMEOUT) echo "  TIMEOUT  $ctr  <- $vol (no ready marker in ${READY_TIMEOUT}s)"; failed=$((failed+1)) ;;
    NOFREE)  echo "  FAILFAST $ctr (bank full — no free authed volume; nothing leased)"; failed=$((failed+1)) ;;
    RUNFAIL) echo "  RUNFAIL  $ctr (docker run failed; lease rolled back)"; failed=$((failed+1)) ;;
  esac
done
rm -rf "$WTMP"
ELAPSED=$(( SECONDS - START ))
echo "spin: $ready READY, $failed failed, in ${ELAPSED}s (bank free now=$($LEASE free-count))"
[ "$failed" = 0 ]
