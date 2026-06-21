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

# ---- 0. working DNS (the golden image baked the build node's resolv.conf, which
#         points at a LAN/MagicDNS resolver unreachable from a fresh container's
#         netns). Reset to public resolvers so the authkey mint resolves;
#         tailscale takes over DNS after `up`. -----------------------------------
sudo bash -c 'printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf' 2>/dev/null || \
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' | sudo tee /etc/resolv.conf >/dev/null 2>&1 || true

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

# ---- 4. start daemons (self-contained: queue-client -> central, ttyd supervisor) ----
# Started directly from the baked mypeople components so the boot does not depend
# on a start-daemons.sh that may not exist in every golden snapshot.
log "starting daemons ..."
mkdir -p "$INSTALL_DIR/run"
set -a; . ~/.config/mypeople/queue.env; set +a
# queue-client: JOIN the central queue (reads QUEUE_URL/QUEUE_SECRET/HOST_ID from env)
if [ -f "$INSTALL_DIR/run/queue-client.pid" ]; then kill "$(cat "$INSTALL_DIR/run/queue-client.pid")" 2>/dev/null || true; fi
setsid python3 -u "$INSTALL_DIR/bin/queue-client.py" > "$INSTALL_DIR/run/queue-client.log" 2>&1 </dev/null &
echo $! > "$INSTALL_DIR/run/queue-client.pid"
# ttyd under a supervisor (a stray kill must not blank the attach window)
if [ -f "$INSTALL_DIR/run/ttyd.pid" ]; then kill "$(cat "$INSTALL_DIR/run/ttyd.pid")" 2>/dev/null || true; fi
pkill -x ttyd 2>/dev/null || true
# ttyd renders in the browser (xterm.js) — glyphs (box-drawing / TUI) come from the
# CLIENT font stack, set via -t fontFamily. Match the working local ttyd so the
# mypeople HUD + Claude TUI render clean (no boxes/mojibake).
TTYD_FONT='Menlo, Monaco, "Cascadia Mono", "Fira Code", "Courier New", monospace'
setsid bash -c 'while true; do ttyd -W -a -p 7681 -t "fontFamily='"$TTYD_FONT"'" -t fontSize=13 -t disableLeaveAlert=true tmux attach; sleep 2; done' \
  > "$INSTALL_DIR/run/ttyd.log" 2>&1 </dev/null &
echo $! > "$INSTALL_DIR/run/ttyd.pid"
# ---- 4b. tkmx token-burn reporter (REQUIRED: every substrate reports under the
#         CEO's account). Creds injected at RUN time (never baked); land only in
#         ~/.config/tkmx/.env at chmod 600. CLIENT_ID = mp-<node> so the node is a
#         stable, hostname-identified machine on the leaderboard. -----------------
if [ -n "${TKMX_API_KEY:-}" ] && [ -d ~/tkmx-client ]; then
  AGENTSVIEW_BIN="$HOME/.local/bin/agentsview"; [ -x "$AGENTSVIEW_BIN" ] || AGENTSVIEW_BIN="$(command -v agentsview || true)"
  mkdir -p ~/.config/tkmx
  cat > ~/.config/tkmx/.env <<EOF
USERNAME=${TKMX_USERNAME:-}
API_KEY=${TKMX_API_KEY}
SERVER_URL=${TKMX_SERVER_URL:-https://tokenmaxxing.odio.dev}
CLIENT_ID=mp-${NODE_NAME}
TEAM=${TKMX_TEAM:-seedbed}
AGENTSVIEW_BIN=${AGENTSVIEW_BIN}
REPORT_DEV_STATS=true
REPORT_SESSION_STATS=true
REPORT_MACHINE_CONFIG=true
REPORT_DAYS=1
EOF
  chmod 600 ~/.config/tkmx/.env
  cp ~/.config/tkmx/.env ~/tkmx-client/.env && chmod 600 ~/tkmx-client/.env
  # reporter daemon: report now, then retry FAST until the first 200, then settle to
  # the normal interval. tkmx's server rate-limits ~3/60s/account, so 5 concurrent
  # nodes can't all 200 at once — a short retry lets every node converge to the
  # leaderboard within ~1-2 min instead of waiting a full 300s interval after a 429.
  setsid bash -c '
    while true; do
      out="$(cd "$HOME/tkmx-client" && npm run --silent report 2>&1)"; echo "$out"
      if echo "$out" | grep -q "responded 200"; then sleep "${TKMX_REPORT_INTERVAL:-300}"; else sleep 20; fi
    done' > "$INSTALL_DIR/run/tkmx-report.log" 2>&1 </dev/null &
  echo $! > "$INSTALL_DIR/run/tkmx-report.pid"
  log "tkmx reporter started (client_id=mp-$NODE_NAME, reports under ${TKMX_USERNAME:-CEO})"
else
  log "WARN: tkmx not started (TKMX_API_KEY not injected or tkmx-client absent)"
fi

# optional recorder of the worker pane (the HYDRATION recording is invoked separately
# via pipeline/hydrate-recorded.sh — it records the product-seed build session).
[ -x ~/start-recorder.sh ] && bash ~/start-recorder.sh >/dev/null 2>&1 || true

# ---- 5. assert fast READY-TO-USE gates, write booted marker ------------------
ready_ok=1
# auth present (leased volume mounted + authed) — fast file check, no `claude` spawn
[ -s ~/.claude/.credentials.json ] || ready_ok=0
# queue-client alive
[ -f "$INSTALL_DIR/run/queue-client.pid" ] && kill -0 "$(cat "$INSTALL_DIR/run/queue-client.pid")" 2>/dev/null || ready_ok=0
# ttyd serving locally
for i in $(seq 1 20); do code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:7681/" 2>/dev/null); [ "$code" = 200 ] && break; sleep 0.3; done
[ "${code:-}" = 200 ] || ready_ok=0

# tkmx reporter alive (token-burn reporting under the CEO's account)
tkmx_up=false
[ -f "$INSTALL_DIR/run/tkmx-report.pid" ] && kill -0 "$(cat "$INSTALL_DIR/run/tkmx-report.pid")" 2>/dev/null && tkmx_up=true

if [ "$ready_ok" = 1 ]; then
  printf '{"node":"%s","tailnet_ip":"%s","ready":"use","booted":true,"reverify":false,"tkmx_reporter":%s}\n' "$NODE_NAME" "$IP" "$tkmx_up" > ~/SUBSTRATE_BOOTED.json
  chmod 600 ~/SUBSTRATE_BOOTED.json
  log "READY-TO-USE (authed + tailnet + central queue + ttyd; tkmx_reporter=$tkmx_up). marker: ~/SUBSTRATE_BOOTED.json"
else
  log "WARN: not all fast gates green (auth/queue/ttyd) — see daemon logs"
fi

# ---- 6. stay alive as PID 1 -------------------------------------------------
exec sleep infinity
