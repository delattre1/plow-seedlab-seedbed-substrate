# SEED DOCTRINE — the onboarding index (creating & validating SEEDs)

**THE page a new engineer reads to learn the whole thing.** Self-contained. Every link below is a
GitHub URL or an in-repo relative path — so it resolves for anyone who clones this repo. Verified
2026-07-02.

This repo (`delattre1/plow-seedlab-seedbed-substrate`) holds the machinery: the substrate seed, the
harden loop, and the Claude Auth Bank.

---

## 0. What a SEED is (the generativity gate — read first)

A real SEED encodes **intent + contracts + acceptance journeys**, and a **blind agent GENERATES the
software from it**. An artifact that **embeds finished code** (heredocs, base64, tarballs, vendored
source) and **pastes** it is an **INSTALL FLOW, not a seed** — it reproduces one frozen build instead
of regenerating the software, so it can't be hardened. (This is the "mypeople mistake": a
paste-artifact dressed up as a seed.) **Check this BEFORE spending any substrate/harden cycle.**
Source: [`../SEED/harden.seed.md`](../SEED/harden.seed.md) (§ generativity gate).

## 1. CREATE == VALIDATE (the model)

Creating and validating a seed are the **same process, same roles — a loop vs a single pass:**

- **CREATE a seed** = run the **HARDEN LOOP** until a fresh, BLIND agent one-shots it from **absolute
  zero** → `HARDEN_RESULT=DONE`.
- **VALIDATE a seed** = **ONE** blind-hydrate + verify pass that reports the result (one iteration of
  the same loop, no fix-and-repeat).

Same conductor, same blind tester, same acceptance bar. Validation is create-loop-run-once.

## 2. The 3 PILLARS (what makes it work)

- **#1 — Claude Auth Bank** *(the #1 pillar)*: a pool of 10 pre-authed `claude-auth-bank-NN` Claude
  Max logins (one OAuth login each, leased atomically, never shared) so a fresh node comes up
  **already authed**. → this repo, §5.
- **#2 — spawn a SUBSTRATE in < 15 s**: CEO-locked gate *spin 5 → 5 `SUBSTRATE_READY` within 15 s*
  (one ≈ 5 s), from a pre-hydrated golden image + a leased bank volume. → this repo, §5.
- **#3 — EXTERNAL VERIFICATION**: after the hydrator says "done," an **independent, blind** check
  verifies real running state. Never trust the hydrator's "done." → §3–§4.

## 3. THE HARDEN LOOP — the engine ([`../SEED/harden.seed.md`](../SEED/harden.seed.md))

You are the **HARDENING CONDUCTOR**. You do **NOT** fix the target and you do **NOT** test it; you
orchestrate two separate, single-purpose agents and enforce a clean slate between every iteration:

- **Blind TESTER** — a brand-new **clean-context** in-container agent given **only** the target seed
  path + `NODE_NAME`. No hints, no prior-iteration knowledge. It hydrates the seed, drives it to the
  END, runs the seed's own `## Verify`, and reports the verdict + (if it had to fix anything
  in-container) *exactly what was wrong + how it fixed it*.
- **Builder FIXER / conductor fold** — you fold the reported root cause **into the target seed as a
  CONTRACT / acceptance check** (never as pasted code — that freezes one build and kills
  generativity), and **strengthen the seed's `## Verify`** so it can't false-green again.

The loop:
1. **A — ABSOLUTE ZERO.** Wipe ALL state (container, **auth volume**, queue/registry entries). No
   cached auth, no leftover container, no warm registration. *A green run on reused state proves
   nothing.*
2. **B — BLIND HYDRATE + DRIVE.** Deliver the seed to the fresh blind worker **directly over the
   queue** (`mp send`) — never `docker exec` it in, never a bridge agent.
3. **Verdict.** **PASS = one-shot with ZERO in-container fixes** (all Verify checks hold, no help
   beyond the target's own declared one-time human steps) → **SHIP**. Otherwise capture the exact gap
   → **fold root cause into the seed** → back to **A** (full clean slate).
4. **SHIP.** Not done until **live on remote `main`** (commit → push → merge → confirm on remote).
   Then `HARDEN_RESULT=DONE` (or `HARDEN_RESULT=STALLED` if the iteration budget is exhausted).

> **A single agent must NEVER both own/fold the seed AND be the blind worker** — that is how false
> passes happen. Tester is always fresh + blind; fixer never tests; conductor never fixes/tests.

## 4. Pillar #3 in depth — external verification

- **The separation IS the external verification.** The blind TESTER (§3) is independent of the
  fixer/conductor and judges **real running state**, not the hydrator's claim.
- **The SUBSTRATE_READY hard-gate** — in [`../SEED/seedbed.seed.md`](../SEED/seedbed.seed.md)
  `## Verify` (agent-driven): a node is "ready to hydrate a seed" **only if all 7 gates** (8 with
  `SEEDBED_DIND=1`) are confirmed by **HARD ARTIFACT** — a tailscale Self line, a `/clients` entry,
  the Boss-pane ping, a respawn-after-kill 200, a tkmx 200 + leaderboard hostname, a growing
  asciinema `.cast`. Never a label / exit code / "process launched" proxy. All 7 true → writes
  `~/SUBSTRATE_READY.json` → `SEEDBED_RESULT=DONE`; any gate unproven → no marker →
  `BLOCKED_REASON=substrate_gate_failed`. **No partial "done" — a half-baked substrate is REFUSED.**
- **Dedicated CI (future canonical, DESIGN PHASE — not built):**
  [github.com/plow-pbc/seed-validator](https://github.com/plow-pbc/seed-validator)
  (`validate <git-url> --agent <agent>`, 3 tiers on ephemeral EC2). **Interim harness:**
  [github.com/plow-pbc/seed-refine](https://github.com/plow-pbc/seed-refine) (disposable target →
  install → verify → fix-PRs). NOT a code reviewer — do NOT confuse with
  [github.com/plow-pbc/knightwatch-reviewer](https://github.com/plow-pbc/knightwatch-reviewer) (that
  reviews CODE, not seeds).

## 5. Substrate spawn + Auth Bank (pillars #1 + #2) — how a validation node exists

All in this repo:

- [`../SEED/seedbed.seed.md`](../SEED/seedbed.seed.md) — the substrate seed: stand up ONE
  `SUBSTRATE_READY` node (the 7-gate lives in its `## Verify`).
- [`../bin/spin.sh`](../bin/spin.sh) — spin N substrates from the golden image, each leasing a bank
  volume (the <15 s path).
- [`../pipeline/bake-golden.sh`](../pipeline/bake-golden.sh) — build the pre-hydrated golden image once.
- [`../bin/verify-acceptance.sh`](../bin/verify-acceptance.sh) — the "spin 5 → ready in 15 s"
  acceptance driver.
- **Auth Bank:** [`../bank/volumes.txt`](../bank/volumes.txt) (the ONE manifest) ·
  [`../lease/lease.sh`](../lease/lease.sh) (atomic lease) ·
  [`../bin/bank-dashboard.sh`](../bin/bank-dashboard.sh) (status `:8899`) ·
  [`./AUTH-BANK-ONBOARDING.md`](./AUTH-BANK-ONBOARDING.md) (bank onboarding).

## 6. The hard rules (memorize)

1. **Fold fixes as CONTRACTS, never pasted code** — a code blob turns a seed into an install flow.
2. **Never reuse state** — reused auth/container/registration fakes a green pass.
3. **Tester fresh + blind; fixer never tests; conductor never fixes/tests** — one agent doing two roles = false pass.
4. **Not done until live on remote `main`** — a local green Verify is not done.
5. **No partial "ready"** — every SUBSTRATE_READY gate is proven by hard artifact or the node is refused.
6. **Generativity gate first** — a blind agent must GENERATE from the seed, not paste embedded code.

---
This is the single, authoritative, external-facing onboarding index. Registered by CEO directive
2026-07-02.
