# PLAN — plow-seedlab-seedbed-substrate

> **Status: PLAN ONLY.** No provisioning logic is built yet. This document captures the
> CEO-confirmed design for green-light. Build begins only after explicit approval (Rule 1:
> plan first).

## Scope

**SUBSTRATE setup ONLY.** This repo provisions and manages the *substrate* — the base
environment plus its pre-authed Claude auth. It does **NOT** build or manage the product
that gets hydrated inside the substrate. That is a separate concern in a separate repo.

---

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

## Verify

Acceptance checks for the eventual build:

- [ ] **No double-lease under concurrency:** spin **10 concurrent** containers. Prove that
      **no two containers share a volume** (each of the 10 volumes is held by exactly one
      container; the lease store shows 10 distinct holders).
- [ ] **11th request with bank full:** with all 10 leased, the 11th spin-up does NOT reuse a
      volume — it blocks or fails fast.
- [ ] **Spin-up latency:** spin-up completes in **~5s**.
- [ ] **Teardown preserves volume:** after teardown, the container is gone but its auth
      volume still exists and is marked `free`.
- [ ] **Re-lease works:** a freed volume can be leased by a new container and is still
      authed (tokens auto-refreshed, no re-login needed).
- [ ] **Versioning:** change the seed → rebuild → image gets a new tag; old tag still spins.

---

*Generated for CEO green-light. Do not build provisioning logic until the plan is approved.*
