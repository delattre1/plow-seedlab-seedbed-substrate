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
| 4 | **Central Boss OWNS the node (JOIN-mode proof)** | spawn `worker-1` with `--boss <CENTRAL_BOSS>`; it registers on the **central** queue, runs a real `hostname` diagnostic returning `<NODE>`, and its Stop-hook `[AGENT NOTIFICATION]` lands in the **central Boss's pane** (a standalone node would route to its own Boss) |
| 5 | **Attachable in a browser (supervised)** | ttyd on the container's own tailnet IP returns `200`; after `pkill ttyd` + ~5s it is **still 200** (the supervisor respawned it) |
| 6 | **Token burn reported (tkmx)** | tkmx reporter daemon alive; node **identified on the leaderboard** by `hostname`/`client_id=mp-<NODE>`; `~/.config/tkmx/.env` is `chmod 600`; the CEO's `API_KEY` is present there but **nowhere in git or the image** |
| 7 | **Terminal recording live** | asciinema `~/recordings/<NODE>.cast` is actively **growing** AND `render_clip.sh` renders a **clean (dark, non-blank) frame** of real terminal content |
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

## Secrets (PUBLIC repo)

Never commit secrets. The seeds reference secrets by **name only** (read at hydration time
from gitignored host `.env` files); no literal token values are present. See
`SEED/README.md` and `.gitignore`.
