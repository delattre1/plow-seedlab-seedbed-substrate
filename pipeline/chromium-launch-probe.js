// chromium-launch-probe.js — SUBSTRATE_READY chromium-launch gate probe.
//
// Baked into the golden image at /home/tester/.pw-selftest/launch.js by
// pipeline/bake-golden.sh (step 6) and exercised by:
//   * bake-golden.sh's post-commit self-check (bake-time proof), and
//   * SEED/seedbed.seed.md ## Verify SUBSTRATE_READY hard-gate, gate 9 (per-node proof).
//
// WHY THIS EXISTS (root-cause fold of hydration run 1ab7bbd104f7b1e1): Playwright
// fetches the Chromium BINARY, but the Debian 12 base lacked the OS shared libraries
// Chromium links against (libglib-2.0.so.0, libnss3, …) — so Chromium died at launch
// with 'error while loading shared libraries: libglib-2.0.so.0'. Every browser-verified
// seed on this image hit it and had to run `sudo npx playwright install-deps chromium`
// in-container, voiding the one-shot. bake-golden.sh now bakes those OS deps + a
// pre-warmed Chromium; this probe is the CONTRACT that proves a fresh node launches
// headless Chromium with ZERO in-container installs, so the gap can never false-green
// again. A non-zero exit / missing CHROMIUM_OK means the OS deps or the browser cache
// regressed — the substrate is REFUSED (no SUBSTRATE_READY marker).
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ headless: true });
  const v = b.version();
  const p = await b.newPage();
  await p.setContent("<h1>substrate chromium ok</h1>");
  await p.title();
  await b.close();
  console.log("CHROMIUM_OK version=" + v);
})().catch((e) => {
  console.error("CHROMIUM_FAIL " + String(e));
  process.exit(1);
});
