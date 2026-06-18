# PLAN — plow-seedlab-seedbed-substrate

> **Status: PLAN ONLY.** No provisioning logic is built yet. This document captures the
> CEO-confirmed design for green-light. Build begins only after explicit approval (Rule 1:
> plan first).

## Scope

**SUBSTRATE setup ONLY.** This repo provisions and manages the *substrate* — the base
environment plus its pre-authed Claude auth. It does **NOT** build or manage the product
that gets hydrated inside the substrate. That is a separate concern in a separate repo.

---

## 0. The SEED (the foundation — see [`SEED/`](./SEED/))

The image is built **from a seed**. That seed lives in this repo at
[`SEED/seedbed.seed.md`](./SEED/seedbed.seed.md) (companion:
[`SEED/harden.seed.md`](./SEED/harden.seed.md)), vendored from `plow-pbc/seedlab`.

`seedbed.seed.md` is **agent-driven**: an AI agent reads it and runs `## Step 0 Interview`
→ every `## Step` in order → the agent-driven `## Verify` → `SEEDBED_RESULT=DONE`. The
result is a node that passes the **SUBSTRATE_READY gates** (the 7/8-gate definition of "fully
set up" — see [`README.md`](./README.md)). That ready node is what gets snapshotted as the
golden image:

```
SEED/seedbed.seed.md  --hydrate-->  SUBSTRATE_READY node  --snapshot-->  golden IMAGE
```

The seed carries **no secret values** — only references read from gitignored host `.env`
at hydration time (see `SEED/README.md`).

## 1. Core model: image = hydrated SEED snapshot

- The **image is a snapshot of a hydrated SEED**. The seed *defines* the image.
- **Building the image = hydrating the substrate seed.** You do not hand-edit the image;
  you change the seed and rebuild.
- **Versioned:** change the seed → rebuild → re-tag the image. The seed is the source of
  truth; the image is its compiled, runnable artifact.

```
SEED (source of truth)  --hydrate-->  IMAGE (snapshot, tagged)  --spin-->  CONTAINER (live)
        ^                                                                        |
        |________________________ feedback _____________________________________|
```

## 2. Dogfood loop

The substrate improves by being used:

1. **Spin** the image into a live container.
2. **Use it** — and notice something you dislike.
3. **Feed that back into the SEED** (not the image, not the container — the seed).
4. **Re-hydrate** → new image → new tag.
5. **Use + feedback again.** Iterate.

Every dislike becomes a seed change. The image is disposable; the seed accrues the learning.

## 3. AUTH BANK

A pool of **N = 10** pre-authed Claude auth **volumes**.

### THE rule (critical)

> **One volume is used by AT MOST ONE live container at a time.**

Concurrent reuse of the same auth volume = **auth theft** → Anthropic detects the conflict
and **logs us out**. This invariant is the single most important property of the system.
Everything below exists to enforce it.

### Mechanism: lease / lock

- The bank tracks each volume as **free** or **used** (leased).
- On spin-up, a container **leases the next free volume**. The lease atomically flips that
  volume to `used` and records the holder (container id).
- On teardown, the lease is **released** → volume flips back to `free`.
- **Tokens AUTO-REFRESH.** There is no token-expiry logic to write; the auth inside a volume
  stays valid on its own. We only manage *exclusive possession*, not *freshness*.

### Lease state store + race prevention

- A **lease state store** holds, per volume: `id`, `status` (free/used), `holder`
  (container id or null), `leased_at`.
- **Race prevention:** lease acquisition must be **atomic** — two simultaneous spin-ups must
  never both grab the same "free" volume. Implemented via an atomic
  compare-and-set / single-writer lock on the store (e.g. a transactional
  test-and-set on the chosen row, or a mutex around select-free-then-mark-used). The
  selection-and-mark is one indivisible operation.
- If no volume is free → the spin-up **blocks or fails fast** (decision deferred to build
  phase) rather than reusing a `used` volume. Never violate THE rule.

## 4. Spin-from-image + lease-next-free flow

```
1. Request: spin a substrate container.
2. ATOMIC: lease next-free auth volume from the bank.
     - no free volume -> block / fail (never double-lease).
3. Start container from the current IMAGE tag, mounting the leased volume.
4. Container is live, auth-ready (tokens auto-refresh inside).
   ... work happens (or dogfood / hydrate / product runs inside — out of scope) ...
5. Teardown:
     - DESTROY the container.
     - KEEP the auth volume (do NOT delete).
     - RELEASE the lease -> volume back to `free` for the next container.
```

**Teardown rule:** destroy the container, **keep its auth volume** for the next container.
Volumes are durable and reused across many container lifetimes; containers are ephemeral.

## 5. Lease lifecycle (state)

```
free  --lease (atomic test-and-set)-->  used (holder=container)
used  --release (on teardown)-------->  free   (volume preserved)
```

- Crash/orphan handling (a container dies without releasing) → reaper / stale-lease
  reclamation. Detail deferred to build phase, but called out now so the design accounts
  for it.

---

## Verify — CEO ACCEPTANCE GATES (locked)

The build is accepted iff all four gates pass, **each proven by a CAPTURED run** (genuine
captured output, never claims — Rule 22). Driver: [`bin/verify-acceptance.sh`](./bin/verify-acceptance.sh)
(gates 1–3) + [`pipeline/pull-and-run.sh`](./pipeline/pull-and-run.sh) (gate 4).

- [ ] **Gate 1 — spin 5 → 5 SUBSTRATE_READY within 15 SECONDS.** `spin 5` brings up 5
      substrates that each carry `~/SUBSTRATE_READY.json` within 15s. Fast because the golden
      image is a **pre-hydrated seed snapshot** (boot only re-establishes per-node identity).
- [ ] **Gate 2 — NO two substrates reuse the same credential/auth volume.** The atomic lease
      (mkdir test-and-set) enforces 1-volume-1-container. Proof: `docker inspect` each
      substrate's `~/.claude` mount → all distinct.
- [ ] **Gate 3 — bank=10 → the 11th FAILS CLEANLY.** With 10 running (bank full), the 11th
      `spin` fails fast (`NO_FREE_VOLUME`, no container created) — never double-leases.
- [ ] **Gate 4 — published to Docker Hub, pullable + usable.** The golden image
      (build → snapshot → push) can be **pulled on a clean host and run** to a working,
      authed substrate. Pipeline: [`build-golden.sh`](./pipeline/build-golden.sh) →
      [`push-dockerhub.sh`](./pipeline/push-dockerhub.sh) →
      [`pull-and-run.sh`](./pipeline/pull-and-run.sh). Creds via env only — never in this repo.

Supporting invariants (covered by the same flow): teardown preserves the volume (lease
released, volume kept); a freed volume re-leases and is still authed (tokens auto-refresh);
versioning = change seed → rebuild → re-tag.

---

*CEO green-lit the build (card 3dcee5b19212). Provisioning logic lives in `lease/`, `bin/`,
`pipeline/`. No secrets in this public repo — creds via env only.*
