# plow-seedlab-seedbed-substrate

Substrate provisioning for the seedlab: a **golden substrate image** built from a seed, plus
an **auth bank** that leases pre-authed Claude volumes so fresh substrate machines come up in
~5s.

> **Status: PLAN + SEED only.** No provisioning logic is built yet (Rule 1 — plan first).
> Design lives in [`PLAN.md`](./PLAN.md); the foundation seed lives in [`SEED/`](./SEED/).

## The one-line model

```
SEED/seedbed.seed.md  --hydrate-->  SUBSTRATE_READY node  --snapshot-->  golden IMAGE  --spin + lease auth volume-->  fresh substrate (~5s)
```

- **The seed defines the image.** The image is a snapshot of a node hydrated from
  `SEED/seedbed.seed.md`. Change the seed → rebuild → re-tag (versioned). See `PLAN.md` §1.
- **This repo's scope is the SUBSTRATE only** — not the product hydrated inside it.

## What "a fully-setup substrate" means — `SUBSTRATE_READY`

A node is **`SUBSTRATE_READY`** — i.e. ready to hydrate a seed / be snapshotted as the golden
image — **iff it carries the durable marker `~/SUBSTRATE_READY.json`**, written by the seed's
agent-driven `## Verify` hard-gate **only** when **all 7 gates** (8 with `SEEDBED_DIND=1`) are
confirmed by **hard artifact** (never an exit code / label / "process launched" proxy). There
is **no partial ready**: a half-baked substrate is **refused**, not waved through.

| # | Gate | Confirmed by (hard artifact) |
|---|------|------------------------------|
| 1 | **On the tailnet** | `tailscale status` shows `Self` = `mypeople-<NODE>` with a `100.x` IP |
| 2 | **Complete install** | every MyPeople component present in the node: `queue-server.py`, `queue-client.py`, `mp`, `dashboard.html`, `boss-CLAUDE.md`, `tmux-boss-hooks` plugin, `.tmux.conf`, `tpm` |
| 3 | **Joined the central queue** | `/clients` lists `<NODE>` carrying `attach_base = http://<container-tailnet-ip>:7681` |
| 4 | **Boss can spawn an engineer ON DEMAND** *(re-scoped 2026-06-18)* | NO worker auto-runs in the substrate. The managing Boss spawns an engineer when needed via `docker exec` (or `mp spawn`); the substrate has `claude` (authed via the leased volume) + `mp`, so an exec-spawned engineer runs a real turn. Verified by `docker exec <node> claude -p ...` executing a `Bash(hostname)` tool call returning `<NODE>` |
| 5 | **Attachable in a browser (supervised)** | ttyd on the container's own tailnet IP returns `200`; after `pkill ttyd` + ~5s it is **still 200** (the supervisor respawned it) |
| 6 | **Token burn reported (tkmx) — REQUIRED** | tkmx reporter daemon alive; node **identified on the leaderboard** by `hostname`/`client_id=mp-<NODE>`; `~/.config/tkmx/.env` is `chmod 600`; the CEO's `API_KEY` is injected at spin (from the host) — present there but **nowhere in git or the image**. tkmx-client + agentsview are **baked into the golden image**; `golden-boot.sh` writes the env + starts the reporter |
| 7 | **Hydration recording** *(re-scoped 2026-06-18)* | the **product-seed hydration session** (the blind agent building the product INSIDE the substrate) is recorded end-to-end via asciinema → `~/recordings/<NODE>-hydration.cast` and rendered to mp4 (`recorder/render_clip.sh`). Invoked by [`pipeline/hydrate-recorded.sh`](./pipeline/hydrate-recorded.sh) (`start`/`watch`/`render`). asciinema is **baked into the golden image** |
| 8 | **Docker-capable** *(only when `SEEDBED_DIND=1`)* | as `tester`: `docker compose version` works AND `docker run hello-world` returns clean (inner `dockerd` + compose plugin + docker-group membership all live). Classic substrate: N/A, gate count = 7 |

**Completion signal:** all gates true → seed writes `~/SUBSTRATE_READY.json` and prints
`SEEDBED_RESULT=DONE`; the queue-client then advertises `substrate_ready=true` in its
heartbeat. Any gate not truly confirmed → no marker (stale one removed) →
`BLOCKED_REASON=substrate_gate_failed`.

**Downstream rule:** absence of `~/SUBSTRATE_READY.json` is a **HARD STOP** — do not clone,
hydrate, or run any seed on a node that lacks the marker (`BLOCKED_REASON=substrate_not_ready`).

## Layout

```
PLAN.md            design (process): seed→image, dogfood loop, AUTH BANK, lease/lock, Verify
README.md          this file — the one-line model + what a fully-setup substrate is
SEED/
  seedbed.seed.md  THE substrate seed — the foundation the golden image is built from
  harden.seed.md   companion hardening seed
  README.md        seed provenance + secrets posture
.gitignore         public-repo guardrail: blocks auth tokens/volumes, QUEUE_SECRET, authkeys, creds
```

## Fold audit — reproducing the 5-ready-in-~16s run from zero

| What the run relied on | Folded? Where |
|---|---|
| Fast-boot entrypoint (tailnet, central-queue JOIN, daemons, READY marker) | ✅ `pipeline/golden-boot.sh` (baked as image ENTRYPOINT) |
| Glyph fix 1 — claude `TERM=xterm-256color` wrapper | ✅ baked by `pipeline/bake-golden.sh`; live-apply `pipeline/glyphfix.sh` |
| Glyph fix 2 — ttyd `tmux -u attach` + `LANG=C.UTF-8` | ✅ `pipeline/golden-boot.sh` + `SEED/seedbed.seed.md` |
| ttyd `fontFamily` (client font hint; borders) | ✅ `pipeline/golden-boot.sh` + `SEED/seedbed.seed.md` |
| Boss-window fix — `console` placeholder + single live Boss window | ✅ `pipeline/golden-boot.sh` (placeholder) + `bin/spawn-boss.sh` (`kill-window -a`) |
| tkmx reporting (client+agentsview+env+reporter) | ✅ `bake-golden.sh` (baked) + `golden-boot.sh` (env+start) |
| asciinema recording (gate 7) | ✅ `bake-golden.sh` (baked) + `pipeline/hydrate-recorded.sh` |
| Atomic lease bank (1-volume-1-container) | ✅ `lease/lease.sh`, `bank/volumes.txt` |
| Pooled/parallel spin → ready + timing | ✅ `bin/provision.sh` (folds the ad-hoc run scripts) |
| Reproducible golden-image build | ✅ `pipeline/bake-golden.sh` (from-base) |
| NO container fonts (audited dead weight) | ✅ removed; `bake-golden.sh` never installs them |

### ⚠️ Honest live-state caveats (NOT reproducible from this repo alone)
- **Auth bank is live state.** The bank is 10 **pre-authed** Claude volumes on the docker host. A brand-new machine has none — they require per-volume OAuth device logins (browserauth). `bank/volumes.txt` lists names only; the authed volumes themselves are host state. Provisioning *reuses* these volumes (it does **not** do a fresh login per spin).
- **The golden image base is a snapshot, not from-seed.** `pipeline/build-golden.sh` (from-seed) is **blocked** by upstream `mypeople` seed drift (`KeyError '3'`), so `bake-golden.sh` starts from a snapshot of a known-good node (`seedbed-golden:0.1-local`). True from-zero-from-seed needs that drift fixed (seedbed/mypeople owner).
- **Host secrets** (`TAILSCALE_API_KEY`, `QUEUE_SECRET`, `TKMX_*`) live in gitignored host files (`~/.config/seedbed/substrate.env`); documented in `config.env.example`, injected at run — never committed.

## Terminal rendering (ttyd) — what's load-bearing

ttyd renders in the **browser** (xterm.js) using the **CLIENT** machine's fonts, so installing
fonts **inside** the container does nothing for rendering. Do **NOT** add `fonts-firacode` /
`fonts-powerline` / etc. to the golden image — they're dead weight (audited + removed).

The actual fixes for clean rendering of the Claude TUI / mypeople HUD:
- **`-t fontFamily="Menlo, Monaco, …, monospace"`** on ttyd — a *client* hint; renders box-drawing borders cleanly.
- **claude `TERM=xterm-256color` wrapper** — so Claude emits the real mode glyphs (`⏵⏵`/`←`) instead of ASCII `_` (it falls back under `TERM=tmux-256color`).
- **`ttyd … tmux -u attach` + `LANG=C.UTF-8`** — so tmux *draws* those glyphs to the xterm.js client instead of substituting `_`.

No tmux upgrade and no Claude update are required (both tested and ruled out).

## Secrets (PUBLIC repo)

Never commit secrets. The seeds reference secrets by **name only** (read at hydration time
from gitignored host `.env` files); no literal token values are present. See
`SEED/README.md` and `.gitignore`.

### How the CEO's tkmx `API_KEY` reaches every spun substrate (runtime injection, never baked)

The golden image is shared and spun many times — so the key is **never in the image**. It is
injected at `docker run` time and materialised only inside each live container:

1. **On the host** (`server`) the key lives in one gitignored, `chmod 600` file:
   `~/.config/seedbed/substrate.env` →
   ```
   TKMX_API_KEY=<the CEO's key>      # also TKMX_USERNAME, TKMX_SERVER_URL
   ```
   This file is **outside the repo** and `.gitignore` blocks `substrate.env`.

2. **Spin-time injection** — `bin/spin.sh` sources that file, then passes the var into the
   container with `-e` (value never on disk in the image):
   ```sh
   SUBSTRATE_ENV="${SUBSTRATE_ENV:-$HOME/.config/seedbed/substrate.env}"
   [ -f "$SUBSTRATE_ENV" ] && . "$SUBSTRATE_ENV"
   ...
   docker run -d ... -e TKMX_API_KEY="${TKMX_API_KEY:-}" ... "$GOLDEN_IMAGE"
   ```

3. **On boot** — `pipeline/golden-boot.sh` (the image ENTRYPOINT) reads `$TKMX_API_KEY` from
   the env and writes the per-node reporter config, then starts the reporter:
   ```sh
   cat > ~/.config/tkmx/.env <<EOF
   USERNAME=${TKMX_USERNAME:-}
   API_KEY=${TKMX_API_KEY}
   CLIENT_ID=mp-${NODE_NAME}     # stable, unique per node -> hostname on the leaderboard
   ...
   EOF
   chmod 600 ~/.config/tkmx/.env
   setsid bash -c 'while true; do (cd ~/tkmx-client && npm run --silent report); sleep ...; done' &
   ```

4. **Never in image/repo** — verified: the image has **no** `~/.config/tkmx/.env` baked (it's
   written at boot), the key literal is **not found anywhere in the image fs**, and it is
   **not in the repo** (`substrate.env` is gitignored; tracked files reference `TKMX_API_KEY`
   by name only). The key exists only in the host's `600` file and, transiently, in each live
   container's `600` `~/.config/tkmx/.env` (gone when the container is destroyed).
