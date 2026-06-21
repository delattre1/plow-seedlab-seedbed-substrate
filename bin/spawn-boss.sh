#!/usr/bin/env bash
# ============================================================================
# spawn-boss.sh — put a LIVE Boss claude into a spun substrate's Boss window.
#
# Expected ready-substrate layout: the tmux session `mc-main` has exactly ONE
# window, `Boss`, running a live Boss claude (NOT an empty Boss window, and NOT
# the claude parked in an eng-* window).
#
# golden-boot.sh creates a neutral `console` placeholder window at boot (so ttyd
# has something to attach to). This helper spawns the Boss agent into a clean
# `Boss` window and removes the placeholder.
#
# Run on the coordinator (central queue / Boss host). DOCKER honors DOCKER_HOST.
#
# Usage: spawn-boss.sh <node> [central-boss-id]
# ============================================================================
set -uo pipefail
MP="${MP:-$HOME/mypeople/bin/mp}"
DOCKER="${DOCKER:-docker}"
N="${1:?usage: spawn-boss.sh <node> [central-boss-id]}"
CENTRAL_BOSS="${2:-${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}}"

# never let an empty pre-existing "Boss" window block the spawn; keep the session alive
$DOCKER exec "$N" bash -lc 'tmux has-session -t mc-main 2>/dev/null && { tmux new-window -t mc-main -n console 2>/dev/null || true; tmux kill-window -t mc-main:Boss 2>/dev/null || true; }' 2>/dev/null || true

"$MP" spawn "$N/main:Boss" --cwd /home/tester --backend claude --boss "$CENTRAL_BOSS"

# wait for the Boss claude to render, then drop the placeholder so only "Boss" remains
for _ in $(seq 1 30); do
  $DOCKER exec "$N" bash -lc 'tmux capture-pane -t mc-main:Boss -p 2>/dev/null | grep -q "bypass permissions on"' && break
  sleep 1
done
$DOCKER exec "$N" bash -lc 'tmux kill-window -t mc-main:console 2>/dev/null || true' 2>/dev/null || true

# verify
if $DOCKER exec "$N" bash -lc 'tmux capture-pane -t mc-main:Boss -p 2>/dev/null | grep -q "bypass permissions on"'; then
  echo "$N: Boss window has a LIVE Boss claude; windows=[$($DOCKER exec "$N" bash -lc 'tmux list-windows -t mc-main -F "#{window_name}" | paste -sd,')]"
else
  echo "$N: BLOCKED_REASON=boss_claude_not_live"; exit 1
fi
