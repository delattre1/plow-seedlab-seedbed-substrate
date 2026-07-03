#!/bin/bash
# ============================================================================
# bank-dashboard-serve.sh — serve the Claude Auth Bank dashboard HTML on :8899.
#
# Read-only static file server for the dir the regen loop writes to. Run under
# launchd (KeepAlive) so a death/reboot self-heals — a durable regen loop is
# pointless if the server that serves its HTML can die. Install via
# bin/install-bank-dashboard-agent.sh (installs BOTH the loop + this server agent).
#
# Env (overridable): PORT (8899), WWW_DIR (~/seedbed-bank-www), BIND (0.0.0.0 — all
# interfaces incl. the tailnet 100.x so the CEO reaches it off-box).
# ============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PORT="${PORT:-8899}"
WWW_DIR="${WWW_DIR:-$HOME/seedbed-bank-www}"
BIND="${BIND:-0.0.0.0}"
mkdir -p "$WWW_DIR"
# exec so THIS process becomes the server (launchd tracks + KeepAlive-respawns it).
exec python3 -m http.server "$PORT" --bind "$BIND" --directory "$WWW_DIR"
