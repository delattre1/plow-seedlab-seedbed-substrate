# plow-seedlab-seedbed-substrate

Substrate provisioning for the seedlab: a **golden substrate image** built from a seed, plus
an **auth bank** that leases pre-authed Claude volumes so fresh substrate machines come up in
~5s.

> **Two docs, that's it:**
> - **You are here — `README.md`** = understand it (the model, the design, what "ready" means).
> - **[`RUNBOOK.md`](./RUNBOOK.md)** = operate it (create / use / kill, + operational reference).
>
> The seed itself lives in **[`SEED/`](./SEED/)**. **Scope:** this repo provisions the
> *substrate* — the base environment + its pre-authed Claude auth. It does **NOT** build the
> product hydrated inside it (separate repo).

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

## Layout

```
README.md          this file — the model, the design, the SUBSTRATE_READY contract
RUNBOOK.md         operate it: create / use / kill + operational reference (reproducibility,
                   terminal rendering, secret injection, live-state caveats)
SEED/
  seedbed.seed.md  THE substrate seed — the foundation the golden image is built from
  harden.seed.md   companion hardening seed
  README.md        seed provenance + secrets posture
bin/ lease/ pipeline/ bank/   provisioning code (see RUNBOOK.md)
.gitignore         public-repo guardrail: blocks auth tokens/volumes, QUEUE_SECRET, authkeys, creds
```

## Secrets (PUBLIC repo)

Never commit secrets. The seeds reference secrets by **name only** (read at hydration/spin time
from gitignored host `.env` files); no literal token values are present. Host secrets
(`TAILSCALE_API_KEY`, `QUEUE_SECRET`, `TKMX_*`) live in `~/.config/seedbed/substrate.env` and
are injected at `docker run` via `-e` — never baked into the image. See
[`SEED/README.md`](./SEED/README.md), [`config.env.example`](./config.env.example), and
**[`RUNBOOK.md` → Secret injection](./RUNBOOK.md)** for the full mechanism + verification.
