# SEED DOCTRINE — onboarding MAP (create & validate SEEDs)

**A MAP, not a manual.** One or two lines of orientation per topic, then a link to the **single
authoritative source** that owns that doctrine. The seeds are the territory; this page does not
copy their rules (that would drift). Every link resolves on GitHub. Repo:
`delattre1/plow-seedlab-seedbed-substrate`.

Read in order:

1. **What a SEED is / generativity gate** — a seed is *generative*: a blind agent BUILDS the
   software from intent+contracts+acceptance; pasted finished code = an install flow, not a seed.
   → [harden.seed.md → Step 0 generativity gate](../SEED/harden.seed.md#step-0--generativity-gate-run-first-before-any-substrate-or-harden-spend)

2. **CREATE == VALIDATE** — *creating* a seed = run the harden loop until a fresh blind agent
   one-shots it from absolute zero; *validating* = one blind-hydrate+verify pass. Same roles, loop
   vs once.
   → the loop: [harden.seed.md → Loop](../SEED/harden.seed.md#loop) · the roles:
   [harden.seed.md → Roles](../SEED/harden.seed.md#roles-strict-separation--the-documented-hardening-roles-never-blur-them) · done bar:
   [harden.seed.md → Done](../SEED/harden.seed.md#done)

3. **Pillar #1 — Claude Auth Bank** — a pool of pre-authed Claude Max logins so a fresh node comes
   up already authed.
   → [docs/AUTH-BANK-ONBOARDING.md](./AUTH-BANK-ONBOARDING.md) (the bank's own guide) · manifest
   [bank/volumes.txt](../bank/volumes.txt) · lease [lease/lease.sh](../lease/lease.sh)

4. **Pillar #2 — spawn a substrate < 15 s** — spin from a pre-hydrated golden image + a leased bank
   volume (CEO gate: spin 5 → 5 ready in 15 s).
   → [bin/spin.sh](../bin/spin.sh) · [pipeline/bake-golden.sh](../pipeline/bake-golden.sh) ·
   acceptance driver [bin/verify-acceptance.sh](../bin/verify-acceptance.sh) · the node spec
   [SEED/seedbed.seed.md](../SEED/seedbed.seed.md)

5. **Pillar #3 — external verification** — never trust the hydrator's "done"; a fresh BLIND tester
   judges real running state.
   → the role separation: [harden.seed.md → Roles](../SEED/harden.seed.md#roles-strict-separation--the-documented-hardening-roles-never-blur-them) ·
   the substrate hard-gate: [seedbed.seed.md → Verify (SUBSTRATE_READY 7-gate)](../SEED/seedbed.seed.md#verify--agent-driven--reason-over-the-node-do-not-rely-on-a-passfail-script) ·
   dedicated CI (design phase) [plow-pbc/seed-validator](https://github.com/plow-pbc/seed-validator) ·
   interim [plow-pbc/seed-refine](https://github.com/plow-pbc/seed-refine).
   *(NOT [plow-pbc/knightwatch-reviewer](https://github.com/plow-pbc/knightwatch-reviewer) — that
   reviews CODE, not seeds.)*

6. **The hard rules** — defined where they are enforced, not restated here.
   → [harden.seed.md → Forbids](../SEED/harden.seed.md#forbids-hard-rules--violating-any-one-voids-the-iteration)

Every rule/spec above is defined **once**, in the linked seed. This page only points.
Registered by CEO directive 2026-07-02.
