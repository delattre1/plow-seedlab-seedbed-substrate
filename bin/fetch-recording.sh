#!/usr/bin/env bash
# ============================================================================
# fetch-recording.sh — pull + render any engineer's terminal recording to mp4.
#
# Recordings are produced by the mypeople spawn recorder (SPAWN ⟺ RECORDING,
# mypeople.seed.md): every spawned engineer's pane is captured to
# ~/recordings/<node>-<agent>.cast INSIDE its node. This helper pulls that .cast
# off the node and renders it to a clean 1920x1080 mp4 on demand — so the Boss can
# hand the CEO the video of any engineer whenever asked.
#
#   fetch-recording.sh <node> [agent] [out.mp4]
#     node    container/node name (e.g. ponta-grossa-jul-3-1)
#     agent   tmux tab / worker name (default: worker-1)
#     out     output mp4 path (default: ~/recordings-rendered/<node>-<agent>.mp4)
#
#   fetch-recording.sh <node> [agent] --cast-only    # just pull the .cast, no render
#
# Env: DOCKER_HOST (default ssh://server-ts — LAN `server` is down),
#      RENDER_KIT (default ~/workspace/plow-seedlab-broll-terminal-and-browser/terminal).
# ============================================================================
set -euo pipefail
NODE="${1:?usage: fetch-recording.sh <node> [agent] [out.mp4|--cast-only]}"
AGENT="${2:-worker-1}"
OUT="${3:-}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://server-ts}"
RENDER_KIT="${RENDER_KIT:-$HOME/workspace/plow-seedlab-broll-terminal-and-browser/terminal}"

CAST_NAME="${NODE}-${AGENT}.cast"
LOCAL_CAST_DIR="${LOCAL_CAST_DIR:-$HOME/recordings-fetched}"
mkdir -p "$LOCAL_CAST_DIR"
LOCAL_CAST="$LOCAL_CAST_DIR/$CAST_NAME"

echo "[fetch] $NODE:/home/tester/recordings/$CAST_NAME  (DOCKER_HOST=$DOCKER_HOST)"
docker cp "$NODE:/home/tester/recordings/$CAST_NAME" "$LOCAL_CAST" 2>/dev/null || {
  echo "  no recording found — is $AGENT spawned on $NODE? (expected ~/recordings/$CAST_NAME)" >&2
  echo "  recordings on $NODE:" >&2
  docker exec "$NODE" ls -1 /home/tester/recordings/ 2>/dev/null | sed 's/^/    /' >&2 || true
  exit 1
}
echo "  pulled -> $LOCAL_CAST ($(wc -c < "$LOCAL_CAST" | tr -d ' ') bytes)"

if [ "$AGENT" = "--cast-only" ] || [ "$OUT" = "--cast-only" ]; then
  echo "[fetch] --cast-only: skipping render"; echo "$LOCAL_CAST"; exit 0
fi

[ -x "$RENDER_KIT/lib/render_clip.sh" ] || {
  echo "  render kit not found at $RENDER_KIT/lib/render_clip.sh" >&2
  echo "  clone it:  git clone https://github.com/delattre1/plow-seedlab-broll-terminal-and-browser" >&2
  echo "  (or re-run with --cast-only and render elsewhere)" >&2
  exit 1
}

[ -n "$OUT" ] || OUT="$HOME/recordings-rendered/${NODE}-${AGENT}.mp4"
mkdir -p "$(dirname "$OUT")"
echo "[render] $LOCAL_CAST -> $OUT (1920x1080 via broll render kit)"
IDLE_LIMIT="${IDLE_LIMIT:-3}" FONTDIR="$RENDER_KIT/fonts" bash "$RENDER_KIT/lib/render_clip.sh" "$LOCAL_CAST" "$OUT"
echo "[done] $OUT"
