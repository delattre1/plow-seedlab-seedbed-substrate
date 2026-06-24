# RUNBOOK — operate a substrate (create / use / kill)

The one page for **operating** substrates. The *why* (model, design, the
`SUBSTRATE_READY` contract) lives in [`README.md`](./README.md).

Three commands. Run on the docker host (or with `DOCKER_HOST` pointed at it).

## 0. One-time setup (host, gitignored — never committed)

```sh
# runtime secrets, injected at spin via -e (never baked into the image)
~/.config/seedbed/substrate.env   # TAILSCALE_API_KEY, CENTRAL_QUEUE_*, TKMX_*  (chmod 600)
bank/bank.env                     # BANK_FILE / SEEDBED_LEASE_DIR / GOLDEN_IMAGE pointers
```

Template + which file holds what: [`config.env.example`](./config.env.example). The bank is
10 **pre-authed** Claude volumes (`bank/volumes.txt`) — live host state, see caveats below.

## 1. CREATE the golden image (build once; rebuild only when the seed/folds change)

```sh
pipeline/bake-golden.sh [base-image] [out-tag]
#   base-image  default: seedbed-golden:0.1-local   (snapshot of a SUBSTRATE_READY node)
#   out-tag     default: seedbed-golden:latest
```

Produces `seedbed-golden:latest` — a pre-hydrated seed snapshot with all folds baked
(fast-boot entrypoint, glyph fixes, tkmx, asciinema). You do **not** rebuild to spin more
substrates; you rebuild only when the seed or a fold changes.

## 2. USE — spin substrates from the golden image (the everyday command)

```sh
# A) spin N, each leases a distinct auth volume, wait until SUBSTRATE_READY:
bin/spin.sh <N> [name-prefix]          # prefix default: sub  ->  sub-1..sub-N

# B) spin N AND spawn a live Boss claude in each + print attach URL + timing:
bin/provision.sh <N> [name-prefix]     # this is the "5-ready-in-~16s" path
```

`provision.sh` prints, per substrate: `READY <s>  http://<tailnet-ip>:7681/`.

**Use it** — attach in a browser to that `:7681` URL (ttyd) to watch/drive the substrate's
Boss; or `docker exec <name> ...` on the host. Each substrate is on the tailnet and joined to
the central queue, so it also appears to the central Boss / mp grid.

```sh
bin/verify-acceptance.sh [prefix]      # optional: run the CEO acceptance gates with captured proof
```

## 3. KILL — tear a substrate down (container dies, auth volume is kept)

```sh
bin/teardown.sh <name> [<name> ...]    # specific containers
bin/teardown.sh --prefix <prefix>      # all <prefix>-* containers
```

Destroys the container, **keeps** the auth volume, and **releases the lease** back to the bank
(free for the next spin). Never deletes a volume — containers are ephemeral, volumes durable.

---

### Quickstart (copy-paste)

```sh
pipeline/bake-golden.sh                 # 1. build golden image  (once)
bin/provision.sh 5                      # 2. spin 5 -> READY + attach URLs
#    ... open http://<ip>:7681/ , or docker exec sub-1 ... ...
bin/teardown.sh --prefix sub            # 3. kill all 5 (volumes kept, leases freed)
```

---

## Operational reference

### Reproducibility — what the "5-ready-in-~16s" run relies on, and where it's folded

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

#### ⚠️ Honest live-state caveats (NOT reproducible from this repo alone)
- **Auth bank is live state.** The bank is 10 **pre-authed** Claude volumes on the docker host. A brand-new machine has none — they require per-volume OAuth device logins (browserauth). `bank/volumes.txt` lists names only; the authed volumes themselves are host state. Provisioning *reuses* these volumes (it does **not** do a fresh login per spin).
- **The golden image base is a snapshot, not from-seed.** `pipeline/build-golden.sh` (from-seed) is **blocked** by upstream `mypeople` seed drift (`KeyError '3'`), so `bake-golden.sh` starts from a snapshot of a known-good node (`seedbed-golden:0.1-local`). True from-zero-from-seed needs that drift fixed (seedbed/mypeople owner).
- **Host secrets** (`TAILSCALE_API_KEY`, `QUEUE_SECRET`, `TKMX_*`) live in gitignored host files (`~/.config/seedbed/substrate.env`); documented in `config.env.example`, injected at run — never committed.

### Terminal rendering (ttyd) — what's load-bearing

ttyd renders in the **browser** (xterm.js) using the **CLIENT** machine's fonts, so installing
fonts **inside** the container does nothing for rendering. Do **NOT** add `fonts-firacode` /
`fonts-powerline` / etc. to the golden image — they're dead weight (audited + removed).

The actual fixes for clean rendering of the Claude TUI / mypeople HUD:
- **`-t fontFamily="Menlo, Monaco, …, monospace"`** on ttyd — a *client* hint; renders box-drawing borders cleanly.
- **claude `TERM=xterm-256color` wrapper** — so Claude emits the real mode glyphs (`⏵⏵`/`←`) instead of ASCII `_` (it falls back under `TERM=tmux-256color`).
- **`ttyd … tmux -u attach` + `LANG=C.UTF-8`** — so tmux *draws* those glyphs to the xterm.js client instead of substituting `_`.

No tmux upgrade and no Claude update are required (both tested and ruled out).

### Secret injection — how the CEO's tkmx `API_KEY` reaches every spun substrate (never baked)

The golden image is shared and spun many times — so the key is **never in the image**. It is
injected at `docker run` time and materialised only inside each live container:

1. **On the host** the key lives in one gitignored, `chmod 600` file
   `~/.config/seedbed/substrate.env` → `TKMX_API_KEY=<the CEO's key>` (also `TKMX_USERNAME`,
   `TKMX_SERVER_URL`). This file is **outside the repo**; `.gitignore` blocks `substrate.env`.

2. **Spin-time injection** — `bin/spin.sh` sources that file, then passes the var into the
   container with `-e` (value never on disk in the image):
   ```sh
   SUBSTRATE_ENV="${SUBSTRATE_ENV:-$HOME/.config/seedbed/substrate.env}"
   [ -f "$SUBSTRATE_ENV" ] && . "$SUBSTRATE_ENV"
   docker run -d ... -e TKMX_API_KEY="${TKMX_API_KEY:-}" ... "$GOLDEN_IMAGE"
   ```

3. **On boot** — `pipeline/golden-boot.sh` (the image ENTRYPOINT) reads `$TKMX_API_KEY` and
   writes the per-node reporter config (`~/.config/tkmx/.env`, `chmod 600`,
   `CLIENT_ID=mp-${NODE_NAME}` → hostname on the leaderboard), then starts the reporter daemon.

4. **Never in image/repo** — verified: the image has **no** `~/.config/tkmx/.env` baked (written
   at boot), the key literal is **not** anywhere in the image fs, and it is **not** in the repo
   (`substrate.env` gitignored; tracked files reference `TKMX_API_KEY` by name only). The key
   exists only in the host's `600` file and, transiently, in each live container's `600`
   `~/.config/tkmx/.env` (gone when the container is destroyed).
