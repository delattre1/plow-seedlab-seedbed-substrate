#!/usr/bin/env bash
# ============================================================================
# bake-golden.sh — REPRODUCIBLE build of the golden substrate image from a base
# snapshot, applying every fold this provisioning relies on (zero manual steps).
#
# This is the FROM-BASE path: the base here is a snapshot of a known-good
# hydrated substrate node (see BASE_IMAGE), and everything ON TOP of the base is
# scripted + committed here. (The FROM-SEED path is pipeline/build-golden.sh.)
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

echo "[bake] 5. queue-client V2 compat shim (fleet fix — card ca09a42c386febed)"
# The central queue-server is V2: /task/poll returns a LIST with the verb in 'type'.
# The base snapshot bakes a pre-V2 queue-client that expects a DICT + 'action', so it
# CRASHES on the first spawn task and goes registered-but-deaf (JOIN spawns silently
# fail fleet-wide). Apply the idempotent shim at bake time so every golden node ships
# V2-compatible. Single source of truth: pipeline/queue-client-v2-shim.py.
$DOCKER cp "$ROOT/pipeline/queue-client-v2-shim.py" "$B":/tmp/queue-client-v2-shim.py
$DOCKER exec -u tester "$B" python3 /tmp/queue-client-v2-shim.py /home/tester/mypeople/bin/queue-client.py
$DOCKER exec -u tester "$B" python3 -c 'import ast,sys; ast.parse(open("/home/tester/mypeople/bin/queue-client.py").read()); print("  queue-client.py parses ✓")'

echo "[bake] 6. Chromium OS deps + pre-warmed Playwright browser (card fb8ffbb6d8b4a0ed)"
# ROOT-CAUSE FOLD (hydration run 1ab7bbd104f7b1e1): Playwright fetches the Chromium
# BINARY, but the Debian 12 base lacks the OS shared libraries Chromium links against
# (libglib-2.0.so.0, libnss3, …) — Chromium dies at launch with
# 'error while loading shared libraries: libglib-2.0.so.0'. EVERY browser-verified seed
# on this image hit it and had to run `sudo npx playwright install-deps chromium`
# in-container, voiding the one-shot. Fix at the IMAGE, not the seed:
#   (a) install the Chromium/Playwright OS deps here at BAKE time — explicit apt list
#       (deterministic, no node needed, == `playwright install-deps chromium`); and
#   (b) pre-warm the Playwright Chromium browser into tester's cache so a fresh node
#       launches headless Chromium with ZERO in-container installs (the seed's own
#       `npx playwright install chromium` then hits a warm cache instead of re-fetching).
# The pinned package set is validated: a fresh install of these + `playwright install
# chromium` launches headless Chromium clean on this base (see ## Verify gate 9).
$DOCKER exec -u root "$B" bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends \
    libglib2.0-0 libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libatspi2.0-0 libx11-6 libxcomposite1 libxdamage1 libxext6 \
    libxfixes3 libxrandr2 libgbm1 libxcb1 libxkbcommon0 libpango-1.0-0 libcairo2 \
    libasound2 libxshmfence1 fonts-liberation >/dev/null
  apt-get clean; rm -rf /var/lib/apt/lists/*
  echo "  apt chromium deps installed (libglib-2.0=$(ldconfig -p | grep -c libglib-2.0) libnss3=$(ldconfig -p | grep -c libnss3))"
'
# Pre-warm the browser as tester so the cache lands in tester HOME (image layer, NOT the
# per-node leased ~/.claude volume, which is the only mount at spin time).
$DOCKER exec -u tester "$B" bash -lc '
  set -e
  mkdir -p ~/.pw-selftest && cd ~/.pw-selftest
  # No `npm init` — npm rejects a package name beginning with "." (the .pw-selftest dir);
  # `npm install` needs no package.json and installs straight into ./node_modules.
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install playwright >/dev/null 2>&1
  PWVER=$(sed -n "s/.*\"version\": *\"\([^\"]*\)\".*/\1/p" node_modules/playwright/package.json | head -1)
  echo "  playwright js installed: $PWVER — downloading chromium browser ..."
  npx playwright install chromium 2>&1 | grep -iE "download|install" | tail -3
  echo "  chromium cache: $(du -sh ~/.cache/ms-playwright | cut -f1)"
'
# Drop the committed launch probe (single source of truth: pipeline/chromium-launch-probe.js)
# and PROVE headless Chromium launches now — a bake that cannot launch Chromium FAILS HARD.
$DOCKER cp "$ROOT/pipeline/chromium-launch-probe.js" "$B":/tmp/launch.js
$DOCKER exec -u root "$B" bash -lc 'install -o tester -g tester -m 644 /tmp/launch.js /home/tester/.pw-selftest/launch.js && rm -f /tmp/launch.js'
echo -n "[bake] 6. chromium launch self-check: "
$DOCKER exec -u tester "$B" node /home/tester/.pw-selftest/launch.js

echo "[bake] commit -> $OUT"
$DOCKER commit --change 'ENTRYPOINT ["/usr/local/bin/seedbed-golden-boot"]' "$B" "$OUT" >/dev/null

echo "[bake] verify"
$DOCKER run --rm --entrypoint sh "$OUT" -c '
  echo -n "fonts(must be 0)="; fc-list 2>/dev/null | grep -ciE "fira|powerline"
  echo -n "asciinema="; command -v asciinema >/dev/null && echo yes || echo NO
  echo -n "tkmx-client="; ls -d /home/tester/tkmx-client >/dev/null 2>&1 && echo yes || echo NO
  echo -n "claude-wrapper-fwd="; tail -1 /usr/local/bin/claude-wrapper | grep -q "\"\$@\"" && echo ok || echo BAD
  echo -n "entrypoint-placeholder="; grep -o "new-session -d -s mc-main -n console" /usr/local/bin/seedbed-golden-boot || echo BAD
  echo -n "queue-client-v2(must be ok)="; grep -q "v2-compat-shim" /home/tester/mypeople/bin/queue-client.py && grep -q "isinstance(tasks, dict)" /home/tester/mypeople/bin/queue-client.py && echo ok || echo BAD
  echo -n "chromium-launch(must be ok)="; node /home/tester/.pw-selftest/launch.js 2>&1 | grep -q "^CHROMIUM_OK" && echo ok || echo BAD
'
echo "[bake] DONE: $OUT"
