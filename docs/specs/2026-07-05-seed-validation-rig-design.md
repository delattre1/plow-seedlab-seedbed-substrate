# Seed Validation Rig — design

**Date:** 2026-07-05 · **Status:** approved by CEO (chat session) · **Owner:** CEO (daniel@bion42.com)

## Problem

The CEO wants to reliably create and install seeds: write a card like "install mypeople on 5
fresh substrates" and get back working instances with **watchable video proof for every
feature**, so the seed can be shared with strangers with confidence. The doctrine for this
already exists (harden.seed.md, the 3 pillars); what is missing is a standing, operational
rig that executes it end-to-end from a card ask — and the substrate infrastructure, which
was wiped on 2026-07-05 (all golden images and auth-bank volumes deleted in a Docker prune).

## Scope

Covered: the operational rig — management plane, substrate rebuild, run flow, proof
deliverables, first-run plan.

Non-goals (explicit CEO decisions):
- **No new process documents.** `harden.seed.md` remains the single source of truth for
  roles, pillars, loop, forbids. Nothing here restates its rules (DRY; this doc only points).
- **No CLI, no CI.** Real agents do the work, in the doctrine roles.
- **No "campaign" concept.** Run parameters — target seed, substrate count (e.g. N=5),
  proof format — are written in the task card, never encoded in a document.
- **No seed-drafting tooling.** First drafts of new seeds are hand-written.
- **No mypeople rework here.** Nightwatch removal / watchdog consolidation / client-server
  split is a separate future spec; mypeople enters this rig only after that rework.

## Architecture — two planes on delattre-server

**Management plane (persistent).** One mypeople instance — board, queue-server/HUD, Boss —
hydrated once from the current mypeople seed. Ops infrastructure where the CEO writes cards
and receives proofs. Not itself a validation subject (bootstrapping, not validation).

**Work plane (ephemeral, per run).** Exactly the harden.seed.md roles, spawned per card:
- **Boss (coordinator):** hub of all communication; spins the substrate himself and hands
  the seed directly to the in-container worker over the queue (the documented no-middleman
  exception); classifies gaps seed-vs-adherence; never touches the work otherwise.
- **Blind in-container hydrator:** hydrates the target seed from absolute zero; own
  `## Verify` is a self-signal only.
- **Host external verifier:** a different agent; drives the finished product in a real
  browser feature-by-feature like the CEO; its recorded pass is the only verification.
- **Seed engineer:** owns seed edits when a fold is required.
- **Video engineer (when the card asks):** cuts per-feature clips and compiles the summary
  video per the b-roll and video-editing repos.

## Bootstrap (milestone 0) — rebuild the pillars from zero

The 2026-07-05 cleanup deleted all `seedbed-golden` images and all auth-bank volumes.
Before any run:
1. **Pillar #2:** bake a golden image (`pipeline/bake-golden.sh`); verify `bin/spin.sh`
   meets the 15-second gate ("spin 5 → 5 ready in 15 s").
2. **Pillar #1:** re-onboard the Claude Auth Bank (`docs/AUTH-BANK-ONBOARDING.md`) — needs
   the CEO's Claude Max logins (declared human step).
3. Hydrate the management-plane mypeople from the current seed on the server.

This rebuild doubles as a from-zero test of this repo itself: any gap found in the
bake/bank/spin docs or scripts is folded back into them at root cause.

## Run flow

A card ask triggers exactly `harden.seed.md → Loop` — clean slate, spin, blind hydrate over
the queue (H3 live progress / H4 dialog auto-dismiss / H5 heartbeat), self-signal Verify,
recordings flushed off-node before teardown (H-NEW), recording gate, recorded external
browser verify, then PASS → proofs to the card, or FAIL → the hub-and-spoke bug loop and a
fold. An N-substrate ask means the Boss runs the loop body N times fresh; **a fold voids
earlier passes** (the doctrine's re-confirmability bar — a changed seed starts the count
over).

## Proof deliverables

Always: the hydration terminal cast + the verifier's recorded browser session, attached to
the card. When the card asks: per-feature clips cut from the verifier session (each feature
checklist row links its clip) and one compiled summary video (title card per feature: what
was tested, result, proof), built per `plow-seedlab-video-editing` /
`plow-seedlab-broll-terminal-and-browser`. All proof files archived off-node in a per-run
directory on the server (default `~/seedlab-proofs/<card-id>-<run-n>/`; override in the
card) and linked from the card.

## First-run plan (proving the rig bottom-up)

1. **Card 1:** hand-draft a trivial seed — a web page with a yellow rectangle and a button
   that triggers a visible effect (generativity gate applies: intent + contracts +
   acceptance journeys, zero pasted code) — and harden it until a blind one-shot with a
   recorded external pass.
2. **Card 2:** same seed, "5 fresh substrates, per-feature clips + compiled video" —
   proves repeatability and the video pipeline.
3. **Card 3+:** existing simple seeds (tip-calculator, unit-converter, todo-list, quiz,
   pomodoro) to widen coverage.
4. mypeople itself enters the rig only after its rework (separate spec).

## Error handling

Defined where it is enforced: harden.seed.md owns stall/driver failures (H3–H5), lost-proof
prevention (H-NEW), dirty-slate voiding, and the Forbids. The only rig-level addition: the
Boss reports any run the doctrine voids (dirty slate, missing recording, self-graded pass)
on the card as VOID with the reason — a voided run is never a counted pass or fail.

## Decisions log (from the brainstorm)

| Question | Decision |
|---|---|
| "5 substrates" means | 5 identical fresh containers on one host (repeatability) |
| Harness form | Real agents in doctrine roles; no CLI, no CI |
| On failure | Full bug loop + fold via Boss (pillar #3); never report-only |
| Videos | Both: per-feature clips + compiled edited summary video |
| Create vs install | CREATE == VALIDATE (doctrine): same machinery, loop vs once |
| Drafting new seeds | Out of scope; hand-written |
| Scope split | This spec = rig only; mypeople rework = separate later spec |
| Where run params live | In the task card, never in a document |
