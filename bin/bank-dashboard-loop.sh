#!/bin/bash
# ============================================================================
# bank-dashboard-loop.sh — keep the Claude Auth Bank dashboard LIVE.
#
# Re-probes + regenerates the dashboard HTML every $INTERVAL seconds so the page's
# auto-refresh always shows the REAL current state (leased-vs-free / usage), never a
# stale snapshot. Run under launchd (KeepAlive) so a death/reboot self-heals — a bare
# nohup loop kept dying and freezing the page. Install: bin/install-bank-dashboard-agent.sh
#
# Env (all overridable): DOCKER_HOST (tailnet — LAN `server` is down), SEEDBED_LEASE_DIR,
# INTERVAL.
# ============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export DOCKER_HOST="${DOCKER_HOST:-ssh://server-ts}"    # LAN `server` route is down; tailnet is reliable
export SEEDBED_LEASE_DIR="${SEEDBED_LEASE_DIR:-$HOME/.config/seedbed/leases-bank}"
INTERVAL="${INTERVAL:-120}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/bank-dashboard.sh"
LOG="${BANK_DASH_LOG:-$HOME/workspace/bank-dashboard-live.log}"
ts(){ date '+%Y-%m-%dT%H:%M:%S'; }

echo "$(ts) live-regen loop started (every ${INTERVAL}s, DOCKER_HOST=$DOCKER_HOST)" >>"$LOG"
while true; do
  if bash "$GEN" >>"$LOG" 2>&1; then echo "$(ts) regenerated" >>"$LOG"; else echo "$(ts) regen FAILED" >>"$LOG"; fi
  sleep "$INTERVAL"
done
