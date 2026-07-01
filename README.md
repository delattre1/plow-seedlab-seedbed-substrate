# plow-seedlab-seedbed-substrate

Substrate provisioning for the seedlab: a **golden substrate image** built from a seed, plus
an **auth bank** that leases pre-authed Claude volumes so fresh substrate machines come up in
~5s.

> **One doc — this one.** Read top-to-bottom: the **model + design** first, then
> **[Operate it (create / use / kill)](#operate-it--create--use--kill)** for the commands, then
> an **[Operational reference](#operational-reference)** for the deeper detail. The seed itself
> lives in **[`SEED/`](./SEED/)**.
>
> **Scope:** this repo provisions the *substrate* — the base environment + its pre-authed Claude
> auth. It does **NOT** build the product hydrated inside it (separate repo).

## The one-line model

```
SEED/seedbed.seed.md  --hydrate-->  SUBSTRATE_READY node  --snapshot-->  golden IMAGE  --spin + lease auth volume-->  fresh substrate (~5s)
```

- **The seed defines the image.** The image is a snapshot of a node hydrated from
  `SEED/seedbed.seed.md`. You never hand-edit the image — you change the **seed** and rebuild.
- **Versioned:** change the seed → rebuild → re-tag. The seed is the source of truth; the
  image is its compiled, runnable artifact.

```
SEED (source of truth)  --hydrate-->  IMAGE (snapshot, tagged)  --spin-->  CONTAINER (live)
        ^                                                                        |
        |________________________ feedback (dogfood) ___________________________|
```

**Dogfood loop** — the substrate improves by being used: spin it → notice something you
dislike → feed that back into the **seed** (not the image, not the container) → re-hydrate →
new image → new tag. Every dislike becomes a seed change; the image is disposable, the seed
accrues the learning.

### The seed (`SEED/`)

The image is built **from the seed** in [`SEED/`](./SEED/):

| File | What it is |
|------|-----------|
| `seedbed.seed.md` | **The substrate seed** (~70KB / 788 lines). An AI agent reads it and: runs `## Step 0 Interview` (gather inputs) → executes every `## Step` in order → performs the agent-driven `## Verify` (reason over the running node, no pass/fail script) → prints `SEEDBED_RESULT=DONE` (or `BLOCKED_REASON=<reason>`). Produces a node that passes the `SUBSTRATE_READY` gates below. |
| `harden.seed.md` | **Companion seed** (~14.5KB / 114 lines). Hardening pass applied to a hydrated substrate / the product hydrated inside it. |

**Provenance:** vendored from the canonical source repo `plow-pbc/seedlab`; the copies here are
the current working versions (`~/workspace/seedlab/`) as of vendoring. The seed carries **no
secret values** — see [Secrets](#secrets-public-repo).

## The AUTH BANK — the one invariant everything protects

A pool of **N = 10** pre-authed Claude auth **volumes**.

> **THE rule: one volume is used by AT MOST ONE live container at a time.**

Concurrent reuse of the same auth volume = **auth theft** → Anthropic detects the conflict and
**logs us out**. This is the single most important property of the system; the lease exists to
enforce it.

- The bank tracks each volume as **free** or **used** (leased), with `holder` + `leased_at`.
- On spin-up a container **atomically leases the next free volume** (mkdir test-and-set — two
  simultaneous spins can never grab the same volume). No free volume → spin **fails fast**
  (`NO_FREE_VOLUME`), never double-leases.
- On teardown the lease is **released** → volume flips back to `free`. The container is
  destroyed; **the auth volume is kept** (durable, reused across many container lifetimes).
- **Tokens auto-refresh** inside a volume — there is no expiry logic to write. We manage only
  *exclusive possession*, not *freshness*.

```
free  --lease (atomic test-and-set)-->  used (holder=container)
used  --release (on teardown)-------->  free   (volume preserved)
```

Crash/orphan (a container dies without releasing) → stale-lease reclamation frees the volume.

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

## Acceptance gates (CEO-locked)

The build is accepted iff these pass, **each proven by a CAPTURED run** (genuine captured
output, never claims). Driver: [`bin/verify-acceptance.sh`](./bin/verify-acceptance.sh) (gates
1–3) + [`pipeline/pull-and-run.sh`](./pipeline/pull-and-run.sh) (gate 4).

1. **spin 5 → 5 `SUBSTRATE_READY` within 15s** (fast because the golden image is a pre-hydrated
   seed snapshot; boot only re-establishes per-node identity).
2. **No two substrates reuse the same auth volume** — atomic lease enforces 1-volume-1-container
   (`docker inspect` each `~/.claude` mount → all distinct).
3. **bank=10 full → the 11th spin FAILS CLEANLY** (`NO_FREE_VOLUME`, no container created).
4. **published to Docker Hub, pullable + usable** on a clean host (creds via env only, never in
   this repo). *Parked per CEO.*

---

# Operate it — create / use / kill

Three commands. Run on the docker host (or with `DOCKER_HOST` pointed at it).

### 0. One-time setup (host, gitignored — never committed)

```sh
# runtime secrets, injected at spin via -e (never baked into the image)
~/.config/seedbed/substrate.env   # TAILSCALE_API_KEY, CENTRAL_QUEUE_*, TKMX_*  (chmod 600)
bank/bank.env                     # BANK_FILE / SEEDBED_LEASE_DIR / GOLDEN_IMAGE pointers
```

Template + which file holds what: [`config.env.example`](./config.env.example). The bank is
10 **pre-authed** Claude volumes (`bank/volumes.txt`) — live host state, see caveats below.

### 1. CREATE the golden image (build once; rebuild only when the seed/folds change)

```sh
pipeline/bake-golden.sh [base-image] [out-tag]
#   base-image  default: seedbed-golden:0.1-local   (snapshot of a SUBSTRATE_READY node)
#   out-tag     default: seedbed-golden:latest
```

Produces `seedbed-golden:latest` — a pre-hydrated seed snapshot with all folds baked
(fast-boot entrypoint, glyph fixes, tkmx, asciinema). You do **not** rebuild to spin more
substrates; you rebuild only when the seed or a fold changes.

### 2. USE — spin substrates from the golden image (the everyday command)

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

### 3. KILL — tear a substrate down (container dies, auth volume is kept)

```sh
bin/teardown.sh <name> [<name> ...]    # specific containers
bin/teardown.sh --prefix <prefix>      # all <prefix>-* containers
```

Destroys the container, **keeps** the auth volume, and **releases the lease** back to the bank
(free for the next spin). Never deletes a volume — containers are ephemeral, volumes durable.

### Quickstart (copy-paste)

```sh
pipeline/bake-golden.sh                 # 1. build golden image  (once)
bin/provision.sh 5                      # 2. spin 5 -> READY + attach URLs
#    ... open http://<ip>:7681/ , or docker exec sub-1 ... ...
bin/teardown.sh --prefix sub            # 3. kill all 5 (volumes kept, leases freed)
```

---

# Operational reference

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
  - **CURRENT STATE (2026-07-01):** the fresh canonical bank `claude-auth-bank-01` … `claude-auth-bank-10` is **10/10 AUTH_OK** (probed concurrently), authed via the proven browser flow (`daniel@plow.co`, browserauth CDP). Canonical lease dir `~/.config/seedbed/leases-bank`. **Pending** (owner `discordhydrate:eng-1`): Phase 3 = repoint `bank/volumes.txt` contents from the old `seedbed-bank-vol-01..10` names to these 10; Phase 4 = retire the old per-workstream volumes/manifests/lease-dirs. Until Phase 3 lands, the manifest file still lists the old names even though the authed volumes are the `claude-auth-bank-NN` set.
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

---

## Layout

```
README.md          THIS FILE — the one doc: model + design + SUBSTRATE_READY contract,
                   "Operate it" (create/use/kill), and operational reference
SEED/
  seedbed.seed.md  THE substrate seed — the foundation the golden image is built from
  harden.seed.md   companion hardening seed
bin/               spin.sh, provision.sh, spawn-boss.sh, teardown.sh, verify-acceptance.sh
lease/             lease.sh — atomic auth-volume lease (1-volume-1-container)
pipeline/          bake-golden.sh, golden-boot.sh, glyphfix.sh, hydrate-recorded.sh, ...
bank/              volumes.txt — the auth bank roster (names only)
config.env.example template for the gitignored host env (secrets by name only)
.gitignore         public-repo guardrail: blocks auth tokens/volumes, QUEUE_SECRET, authkeys, creds
```

## Secrets (PUBLIC repo)

Never commit secrets. **The seeds and all tracked files reference secrets by name only** (read
at hydration/spin time from gitignored host `.env` files); no literal token values are present.
The seed carries only variable names + runtime commands that *read* secrets from the host at
hydration time (e.g. `grep '^QUEUE_SECRET=' ~/.config/mypeople/queue.env`). Scanned before each
commit for literal token patterns (`tskey-auth-…`, `sk-ant-…`, `gho_…`, `AKIA…`) → **zero
matches**; never add a real key.

Host secrets live in `~/.config/seedbed/substrate.env` and are injected at `docker run` via
`-e` — never baked into the image. Secrets consumed at hydration/spin (kept OUT of this repo):
`QUEUE_SECRET` (central MyPeople queue), `TAILSCALE_API_KEY` (mints short-lived ephemeral
`tskey-auth-` keys), `TKMX_API_KEY` / `TKMX_USERNAME` (CEO's token-burn leaderboard). Template:
[`config.env.example`](./config.env.example); full mechanism + verification:
[Secret injection](#secret-injection--how-the-ceos-tkmx-api_key-reaches-every-spun-substrate-never-baked)
above.
