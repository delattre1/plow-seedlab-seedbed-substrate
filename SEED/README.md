# SEED — the foundation the golden image is built FROM

This directory holds **the substrate seed**: the agent-driven specification that, when
**hydrated**, stands up a fully-setup substrate node. The golden image is a **snapshot of a
node hydrated from this seed**. The seed is the source of truth; the image is its compiled
artifact (see root `PLAN.md` §1).

```
SEED/seedbed.seed.md  --hydrate (agent runs it)-->  SUBSTRATE_READY node  --snapshot-->  golden IMAGE
```

## Files

| File | What it is |
|------|-----------|
| `seedbed.seed.md` | **The substrate seed.** An AI agent reads it and: runs `## Step 0 Interview` (gather inputs) → executes every `## Step` in order → performs the **agent-driven `## Verify`** (reason over the running node, no pass/fail script) → prints `SEEDBED_RESULT=DONE` (or `BLOCKED_REASON=<reason>`). Produces a node that passes the SUBSTRATE_READY gates (see root README). |
| `harden.seed.md` | **Companion seed.** Hardening pass applied to a hydrated substrate / the product hydrated inside it. |

## Provenance

- Vendored from the canonical source repo **`plow-pbc/seedlab`** (`seedbed.seed.md`,
  `harden.seed.md`). The copies here are the current working versions
  (`~/workspace/seedlab/`) as of vendoring.
- `seedbed.seed.md` is ~70KB / 788 lines; `harden.seed.md` ~14.5KB / 114 lines.

## Secrets posture (this is a PUBLIC repo)

These seeds carry **NO secret values**. They only contain **variable names and runtime
commands** that *read* secrets from gitignored `.env` files on the host at hydration time —
e.g. `grep '^QUEUE_SECRET=' ~/.config/mypeople/queue.env`, `grep '^TAILSCALE_API_KEY=
~/workspace/seedlab/.env`. The seed is explicit that the CEO's keys are
**"never committed, never baked into the image, injected via `docker exec -e`."**

Scanned before commit for literal token values (`tskey-auth-…`, `sk-ant-…`, `gho_…`,
`AKIA…`) → **zero matches**. Do not change that: never add a real key here.

> Secrets consumed by the seed at hydration time (kept OUT of this repo, sourced from host
> env / gitignored `.env`): `QUEUE_SECRET` (central MyPeople queue), `TAILSCALE_API_KEY`
> (mints short-lived ephemeral `tskey-auth-` keys), `TKMX_API_KEY` / `TKMX_USERNAME`
> (CEO's token-burn leaderboard). These are referenced by name only.
