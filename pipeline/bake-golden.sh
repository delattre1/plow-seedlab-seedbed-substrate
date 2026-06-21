#!/usr/bin/env bash
# ============================================================================
# bake-golden.sh — REPRODUCIBLE build of the golden substrate image from a base
# snapshot, applying every fold this provisioning relies on (zero manual steps).
#
# This is the FROM-BASE path. The FROM-SEED path (pipeline/build-golden.sh) is
# currently blocked by upstream mypeople-seed drift (KeyError '3'), so the base
# here is a snapshot of a known-good hydrated substrate node (see BASE_IMAGE).
# Everything ON TOP of the base is scripted + committed here.
#
# Bakes, in order:
#   1. asciinema            (apt) — terminal recording (gate 7 / hydrate-recorded.sh)
#   2. agentsview + tkmx-client   — token-burn reporting under the CEO's account
#   3. claude TERM wrapper        — GLYPH FIX layer 1 (claude emits ⏵⏵/← not "_")
#   4. golden-boot.sh entrypoint  — fast boot: tailnet + central queue + daemons +
#                                   ttyd `tmux -u attach` (GLYPH FIX layer 2) +
#                                   tkmx + "console" placeholder window + READY marker
#   DOES NOT install fonts-firacode/powerline (audited dead weight — ttyd uses CLIENT fonts).
#
# Usage: bake-golden.sh [base-image] [out-tag]
#   base-image  default: seedbed-golden:0.1-local  (snapshot of a SUBSTRATE_READY node)
#   out-tag     default: seedbed-golden:latest
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOCKER="${DOCKER:-docker}"
BASE="${1:-seedbed-golden:0.1-local}"
OUT="${2:-seedbed-golden:latest}"
B="bake-$$"
$DOCKER rm -f "$B" >/dev/null 2>&1 || true
# --dns so apt/curl resolve even though the base baked a tailnet/LAN resolv.conf
$DOCKER run -d --name "$B" --dns 8.8.8.8 --entrypoint sleep "$BASE" 1800 >/dev/null
trap '$DOCKER rm -f "$B" >/dev/null 2>&1 || true' EXIT

echo "[bake] 1. asciinema"
$DOCKER exec -u root "$B" bash -lc 'apt-get update -qq && apt-get install -y -qq asciinema >/dev/null 2>&1; asciinema --version'

echo "[bake] 2. agentsview + tkmx-client"
$DOCKER exec -u tester "$B" bash -lc '
  curl -fsSL https://agentsview.io/install.sh | bash >/dev/null 2>&1
  [ -d ~/tkmx-client/.git ] || git clone --depth=1 https://github.com/srosro/tkmx-client ~/tkmx-client >/dev/null 2>&1
  cd ~/tkmx-client && npm install --no-audit --no-fund >/dev/null 2>&1
  echo "agentsview=$(~/.local/bin/agentsview --version 2>/dev/null | head -1) tkmx=$([ -d ~/tkmx-client ] && echo ok)"
'

echo "[bake] 3. claude TERM wrapper (glyph fix layer 1)"
REAL=$($DOCKER exec "$B" bash -lc 'readlink -f "$(command -v claude)"')
$DOCKER exec -u root -e REAL="$REAL" "$B" bash -lc '
  { printf "%s\n" "#!/usr/bin/env bash" \
      "if [ -n \"\${TMUX:-}\" ] && [ \"\${TERM:-}\" = \"tmux-256color\" ]; then export TERM=xterm-256color; fi" \
      "exec \"$REAL\" \"\$@\""; } > /usr/local/bin/claude-wrapper
  chmod +x /usr/local/bin/claude-wrapper
  ln -sf /usr/local/bin/claude-wrapper /usr/local/bin/claude
  tail -1 /usr/local/bin/claude-wrapper
'

echo "[bake] 4. golden-boot.sh entrypoint"
$DOCKER cp "$ROOT/pipeline/golden-boot.sh" "$B":/usr/local/bin/seedbed-golden-boot
$DOCKER exec -u root "$B" chmod +x /usr/local/bin/seedbed-golden-boot

echo "[bake] commit -> $OUT"
$DOCKER commit --change 'ENTRYPOINT ["/usr/local/bin/seedbed-golden-boot"]' "$B" "$OUT" >/dev/null

echo "[bake] verify"
$DOCKER run --rm --entrypoint sh "$OUT" -c '
  echo -n "fonts(must be 0)="; fc-list 2>/dev/null | grep -ciE "fira|powerline"
  echo -n "asciinema="; command -v asciinema >/dev/null && echo yes || echo NO
  echo -n "tkmx-client="; ls -d /home/tester/tkmx-client >/dev/null 2>&1 && echo yes || echo NO
  echo -n "claude-wrapper-fwd="; tail -1 /usr/local/bin/claude-wrapper | grep -q "\"\$@\"" && echo ok || echo BAD
  echo -n "entrypoint-placeholder="; grep -o "new-session -d -s mc-main -n console" /usr/local/bin/seedbed-golden-boot || echo BAD
'
echo "[bake] DONE: $OUT"
