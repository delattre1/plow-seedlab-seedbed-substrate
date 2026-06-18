#!/usr/bin/env bash
# ============================================================================
# hydrate-recorded.sh — hydrate a PRODUCT seed INSIDE a spun substrate while
# RECORDING the whole session, so the CEO can WATCH what the blind agent did.
#
# Re-scoped "gate 7": record the actual SEED HYDRATION (the blind agent building
# the product from its seed) end-to-end, renderable to mp4 — NOT an idle pane.
#
#   start  -> asciinema records a tmux pane in the substrate while the engineer
#             hydrates the product seed ON-CAMERA -> ~/recordings/<node>-hydration.cast
#   render -> copy the .cast to the render host + render mp4 via recorder/render_clip.sh
#
# Usage:
#   hydrate-recorded.sh start  <node> <seed-url-or-path>
#   hydrate-recorded.sh render <node> [out-mp4]
#   hydrate-recorded.sh watch  <node>          # attach live to the hydration pane
#
# Env: DOCKER (honors DOCKER_HOST), RENDER_KIT (default ~/workspace/seedlab/recorder),
#      REC_COLS/REC_ROWS geometry.
# ============================================================================
set -uo pipefail
DOCKER="${DOCKER:-docker}"
RENDER_KIT="${RENDER_KIT:-$HOME/workspace/seedlab/recorder}"
cast_path(){ echo "/home/tester/recordings/${1}-hydration.cast"; }

cmd_start(){
  local N="${1:?node}" SEED="${2:?seed url or path}" W="${REC_COLS:-120}" H="${REC_ROWS:-30}"
  local CAST; CAST="$(cast_path "$N")"
  $DOCKER exec "$N" bash -lc 'test -f ~/SUBSTRATE_BOOTED.json' || { echo "BLOCKED_REASON=substrate_not_booted ($N)"; exit 1; }
  $DOCKER exec "$N" bash -lc 'command -v asciinema >/dev/null' || { echo "BLOCKED_REASON=asciinema_absent"; exit 1; }
  echo "[rec] staging product seed into $N ..."
  case "$SEED" in
    http*://*) $DOCKER exec "$N" bash -lc "curl -fsSL '$SEED' -o ~/product.seed.md" ;;
    *)         $DOCKER cp "$SEED" "$N":/home/tester/product.seed.md ;;
  esac
  echo "[rec] starting asciinema recording of the hydration session ..."
  $DOCKER exec "$N" bash -lc "
    mkdir -p ~/recordings
    tmux kill-session -t hyd 2>/dev/null || true
    tmux new-session -d -s hyd -x ${W} -y ${H}
    tmux set -g window-size largest; tmux setw -g aggressive-resize off
    sleep 1
    tmux send-keys -t hyd \"asciinema rec --quiet --overwrite -c 'claude -p \\\"Hydrate ~/product.seed.md end to end: build the product it defines and run its Verify.\\\" --allowedTools Bash Edit Write' ${CAST}; touch ~/recordings/${N}-hydration.done\" Enter
  "
  echo "[rec] recording -> $CAST (records until the agent finishes)."
  echo "[rec] watch live:  $0 watch $N        render when done:  $0 render $N"
}

cmd_watch(){ local N="${1:?node}"; exec $DOCKER exec -it "$N" tmux attach -t hyd; }

cmd_render(){
  local N="${1:?node}" OUT="${2:-./recordings/${N}-hydration.mp4}"
  local CAST; CAST="$(cast_path "$N")"
  mkdir -p "$(dirname "$OUT")"
  local TMPCAST="/tmp/${N}-hydration.cast"
  $DOCKER exec "$N" bash -lc "cat $CAST" > "$TMPCAST" 2>/dev/null || { echo "BLOCKED_REASON=no_cast ($CAST)"; exit 1; }
  [ -s "$TMPCAST" ] || { echo "BLOCKED_REASON=empty_cast"; exit 1; }
  echo "[render] $TMPCAST -> $OUT via $RENDER_KIT/render_clip.sh"
  "$RENDER_KIT/render_clip.sh" "$TMPCAST" "$OUT" || { echo "BLOCKED_REASON=render_failed (need agg+ffmpeg+recorder kit on this host)"; exit 1; }
  echo "[render] DONE: $OUT  ($(du -h "$OUT" 2>/dev/null | cut -f1))"
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  watch)  shift; cmd_watch "$@" ;;
  render) shift; cmd_render "$@" ;;
  *) echo "usage: hydrate-recorded.sh {start <node> <seed> | watch <node> | render <node> [out.mp4]}"; exit 2 ;;
esac
