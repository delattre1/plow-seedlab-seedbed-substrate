#!/usr/bin/env bash
# ============================================================================
# golden-boot.sh — fast-boot ENTRYPOINT for a PROVEN golden substrate image.
#
# Model (CEO): hydrate seed -> golden image (once) -> PROVE the image with the
# full 7-gate Verify ONCE (worker turn + recording happen here) -> then SPINNING
# a proven image is just a FAST BOOT of a container. This script is that boot.
# It does NOT re-run the full Verify; it re-establishes per-node identity and
# brings the substrate to READY-TO-USE quickly (<15s target):
#   - fresh Tailscale identity (mint ephemeral authkey, up as mypeople-$NODE_NAME)
#   - write this node's central-JOIN queue.env (new HOST_ID)
#   - start daemons (queue-client -> central queue, ttyd supervisor, recorder)
#   - ensure a tmux session exists so ttyd is attachable
#   - assert the fast READY-TO-USE gates and write ~/SUBSTRATE_BOOTED.json
#   - stay PID-alive
#
# Secrets are injected at RUN time via -e (never baked): TAILSCALE_API_KEY,
# CENTRAL_QUEUE_SECRET, CENTRAL_QUEUE_URL, CENTRAL_BOSS. The auth volume (claude)
# is mounted at ~/.claude by the leasing spin.
# ============================================================================
set -uo pipefail
NODE_NAME="${NODE_NAME:-$(hostname)}"
INSTALL_DIR=/home/tester/mypeople
TSD="$INSTALL_DIR/run/tailscale-state"
TS_TAILNET="${TS_TAILNET:--}"
CENTRAL_QUEUE_URL="${CENTRAL_QUEUE_URL:?}"
CENTRAL_QUEUE_SECRET="${CENTRAL_QUEUE_SECRET:?}"
CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}"
log(){ echo "[golden-boot:$NODE_NAME] $*"; }

# ---- 1. fresh Tailscale identity (reset baked state, mint authkey, up) -------
log "minting tailscale authkey ..."
TS_AUTHKEY="$(curl -fsS -u "${TAILSCALE_API_KEY}:" -X POST \
  "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/keys" \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true}}},"expirySeconds":3600}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')" || { echo "BLOCKED_REASON=tailscale_mint_failed"; exit 1; }
case "$TS_AUTHKEY" in tskey-auth-*) : ;; *) echo "BLOCKED_REASON=tailscale_mint_failed"; exit 1;; esac

sudo pkill -x tailscaled 2>/dev/null || true
sudo rm -f "$TSD/tailscaled.state" "$TSD/tailscaled.sock" 2>/dev/null || true   # drop baked identity
sudo mkdir -p "$TSD"
sudo bash -c "nohup tailscaled --state=$TSD/tailscaled.state --socket=$TSD/tailscaled.sock >$TSD/tailscaled.log 2>&1 & echo \$! >$TSD/tailscaled.pid"
for i in $(seq 1 40); do [ -S "$TSD/tailscaled.sock" ] && break; sleep 0.3; done
sudo tailscale --socket="$TSD/tailscaled.sock" up --authkey="$TS_AUTHKEY" --hostname="mypeople-$NODE_NAME" --ssh=false --accept-routes=false
IP=""; for i in $(seq 1 30); do IP=$(sudo tailscale --socket="$TSD/tailscaled.sock" ip -4 2>/dev/null | head -1); [ -n "$IP" ] && break; sleep 0.4; done
[ -n "$IP" ] || { echo "BLOCKED_REASON=no_tailnet_ip"; exit 1; }
echo "$IP" | sudo tee "$TSD/ip" >/dev/null
log "on tailnet as mypeople-$NODE_NAME @ $IP"

# ---- 2. this node's central-JOIN queue.env (new HOST_ID) ---------------------
mkdir -p ~/.config/mypeople
cat > ~/.config/mypeople/queue.env <<EOC
INSTALL_DIR=$INSTALL_DIR
QUEUE_URL=$CENTRAL_QUEUE_URL
QUEUE_SECRET=$CENTRAL_QUEUE_SECRET
HOST_ID=$NODE_NAME
BOSS_ID=$CENTRAL_BOSS
TTYD_PUBLIC_URL=http://$IP:7681
TTYD_PORT=7681
QUEUE_PORT=9900
EOC

# ---- 3. a tmux session so ttyd is attachable --------------------------------
tmux has-session -t mc-main 2>/dev/null || tmux new-session -d -s mc-main -n Boss

# ---- 4. start daemons (queue-client -> central, ttyd supervisor, recorder) ---
log "starting daemons ..."
bash ~/start-daemons.sh >/dev/null 2>&1 || true
[ -x ~/start-recorder.sh ] && bash ~/start-recorder.sh >/dev/null 2>&1 || true

# ---- 5. assert fast READY-TO-USE gates, write booted marker ------------------
ready_ok=1
# auth present (leased volume mounted + authed)
claude auth status --text >/dev/null 2>&1 || ready_ok=0
# queue-client alive
[ -f "$INSTALL_DIR/run/queue-client.pid" ] && kill -0 "$(cat "$INSTALL_DIR/run/queue-client.pid")" 2>/dev/null || ready_ok=0
# ttyd serving locally
for i in $(seq 1 20); do code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:7681/" 2>/dev/null); [ "$code" = 200 ] && break; sleep 0.3; done
[ "${code:-}" = 200 ] || ready_ok=0

if [ "$ready_ok" = 1 ]; then
  printf '{"node":"%s","tailnet_ip":"%s","ready":"use","booted":true,"reverify":false}\n' "$NODE_NAME" "$IP" > ~/SUBSTRATE_BOOTED.json
  chmod 600 ~/SUBSTRATE_BOOTED.json
  log "READY-TO-USE (authed + tailnet + central queue + ttyd). marker: ~/SUBSTRATE_BOOTED.json"
else
  log "WARN: not all fast gates green (auth/queue/ttyd) — see daemon logs"
fi

# ---- 6. stay alive as PID 1 -------------------------------------------------
exec sleep infinity
