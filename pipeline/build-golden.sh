#!/usr/bin/env bash
# ============================================================================
# build-golden.sh — build the GOLDEN substrate image: hydrate seedbed.seed.md to
# SUBSTRATE_READY, then snapshot the ready node into a re-runnable image.
#
#   SEED (seedbed.seed.md) --hydrate--> SUBSTRATE_READY node --commit--> GOLDEN IMAGE
#
# The seed DEFINES the image. Change the seed -> rebuild -> re-tag (versioned).
#
# Heavy/static work (packages, mypeople install, claude onboarding config,
# tailscale + ttyd + recorder kit) is baked into the snapshot so a later `spin`
# only re-establishes per-node identity on boot (fast -> ~5s / 5-in-15s target).
#
# Secrets: the hydration reads keys (QUEUE_SECRET, TAILSCALE_API_KEY, TKMX_*)
# from the host's gitignored env at BUILD time (see config.env.example). They are
# NEVER baked into the image and NEVER committed here. The committed image must
# contain no tokens — verified at the end.
#
# Usage: build-golden.sh [build-node-name] [output-tag]
#   build-node-name  scratch node used to hydrate (default: golden-build)
#   output-tag       resulting image tag (default: $GOLDEN_IMAGE or seedbed-golden:latest)
#
# Prereqs (host that owns docker + central queue + render kit):
#   - seedbed.seed.md present (this repo: SEED/seedbed.seed.md)
#   - a working hydration driver (e.g. build-seedbed-node.sh) that runs the seed
#     Steps and reaches SEEDBED_RESULT=DONE on the build node.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
DOCKER="${DOCKER:-docker}"

NODE="${1:-golden-build}"
TAG="${2:-${GOLDEN_IMAGE:-seedbed-golden:latest}}"
HYDRATE="${HYDRATE_DRIVER:?set HYDRATE_DRIVER to the seed-hydration script (e.g. ~/build-seedbed-node.sh)}"
READY_MARKER="${READY_MARKER:-/home/tester/SUBSTRATE_READY.json}"

echo "[golden] hydrating $NODE to SUBSTRATE_READY via $HYDRATE ..."
"$HYDRATE" "$NODE"

echo "[golden] confirming SUBSTRATE_READY marker on $NODE ..."
$DOCKER exec "$NODE" test -f "$READY_MARKER" \
  || { echo "BLOCKED_REASON=node_not_substrate_ready (no $READY_MARKER) — refusing to snapshot a half-baked substrate"; exit 1; }

echo "[golden] snapshotting $NODE -> $TAG ..."
# Bake a fast-boot entrypoint that re-establishes per-node identity then re-runs
# the seed's Verify hard-gate to (re)write SUBSTRATE_READY. (Entrypoint lives in
# pipeline/golden-entrypoint.sh and is installed by the hydration driver / here.)
$DOCKER commit \
  --change 'ENTRYPOINT ["/usr/local/bin/seedbed-golden-boot"]' \
  "$NODE" "$TAG"

echo "[golden] secret scan of the committed image (must find nothing) ..."
if $DOCKER run --rm --entrypoint sh "$TAG" -c \
   'grep -rIlE "sk-ant-[A-Za-z0-9]|tskey-(auth|api)-[A-Za-z0-9]" /home/tester/.config /home/tester/workspace 2>/dev/null' \
   | grep -q .; then
  echo "BLOCKED_REASON=secret_baked_into_image — aborting"; exit 1
fi
echo "[golden] DONE: $TAG (snapshot of a SUBSTRATE_READY node; no baked secrets)"
echo "GOLDEN_IMAGE=$TAG"
