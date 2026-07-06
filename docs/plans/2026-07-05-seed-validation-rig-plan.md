# Seed Validation Rig — implementation plan

**Spec:** [docs/specs/2026-07-05-seed-validation-rig-design.md](../specs/2026-07-05-seed-validation-rig-design.md)
**Date:** 2026-07-05 · **Status:** in progress

## Ground truth at start (verified 2026-07-05 night)

- Docker on `delattre-server` is EMPTY: the 2026-07-05 cleanup deleted every image
  (all `seedbed-golden:*`, `inner-base:clean`) and **all auth-bank volumes**. No copy of
  the golden image survives on any host, tarball, or registry (no `dockerhub.env` was ever
  configured; mac-mini/stream/NAS searched).
- `pipeline/build-golden.sh` (from-seed) is **blocked** by documented upstream seed drift
  (`KeyError '3'`, README "known gaps") — fixing it belongs to the mypeople rework spec,
  not this plan.
- `pipeline/bake-golden.sh` (from-base) needs a snapshot of a SUBSTRATE_READY node, which
  no longer exists → **Phase 0 recreates that snapshot by hand-hydrating one node**.
- Host secrets survive: `~/.config/seedbed/substrate.env` (tailscale/queue/tkmx) intact.
  Lease dir empty (clean). `bank/volumes.txt` = canonical 10 names.
- The browserauth CDP controller (auth-bank login flow) — location unknown after cleanup;
  find it or fall back to a manual per-volume `claude` device login (1 CEO approval per
  volume either way).

## Phase 0 — rebuild the pillars (server)

| # | Step | Human? | Acceptance |
|---|------|--------|------------|
| 0.1 | Auth ONE bank volume (`claude-auth-bank-01`): locate browserauth controller; fallback manual device login into a fresh volume | **CEO approves 1 login** (Safari + 1Password, daniel@plow.co) | container mounting the volume runs `claude` authed, no prompt |
| 0.2 | Hydrate ONE substrate node from `SEED/seedbed.seed.md` in a plain Debian-12 container (paste-into-claude), leased volume at `~/.claude`, secrets from `substrate.env` | no | node reaches `SUBSTRATE_READY` (7-gate Verify) |
| 0.3 | Snapshot it: `docker commit` → new `seedbed-golden:0.1-local`; run `pipeline/bake-golden.sh` → `seedbed-golden:latest` | no | bake completes; baked node boots to READY marker |
| 0.4 | Re-auth remaining 9 bank volumes | **CEO approves 9 logins** | 10/10 AUTH_OK probe |
| 0.5 | Pillar-2 gate: `bin/spin.sh 5` | no | 5 nodes SUBSTRATE_READY in ≤ 15 s, 5 distinct leases |
| 0.6 | Hydrate the management-plane mypeople (current seed) on the server; restore CEO board from Desktop backup if wanted | no | board + HUD reachable; Boss alive; CEO can open a card |

Any gap found in 0.2–0.5 (docs/scripts that don't stand up from zero) is folded into this
repo at root cause before moving on.

## Phase 1 — Card 1: create the yellow-rectangle seed

1. Hand-draft `yellow-rectangle.seed.md` (new repo `plow-seedlab-yellow-rectangle`):
   intent + contracts + acceptance journeys + `## Verify`; passes the generativity gate.
2. CEO card on the board: "create (harden) this seed" — Boss executes
   `harden.seed.md` verbatim: blind hydrate → recording gate → external browser verify →
   fold on failure → loop.
3. **Done:** a fresh blind one-shot with the recorded external pass attached to the card;
   seed pushed to its repo main.

## Phase 2 — Card 2: repeatability + video proofs

CEO card: "install yellow-rectangle on 5 fresh substrates; per-feature clips + compiled
summary video." Boss runs the loop body 5×; a fold voids earlier passes. Video engineer
cuts clips + compiles per `plow-seedlab-video-editing` / b-roll standard. Proofs under
`~/seedlab-proofs/<card-id>-<run-n>/`, linked from the card.

**Done:** 5/5 one-shots on one seed version; every feature has a clip; compiled video on
the card; CEO can watch everything from the board.

## Phase 3 — widen coverage

Cards for existing simple seeds (tip-calculator, unit-converter, todo-list, quiz,
pomodoro), same asks. Each run's gaps folded. mypeople itself enters the rig only after
its rework (separate spec).

## Risks

- **Auth-bank rebuild is the critical path** — nothing hydrates without it (0.1 blocks all).
- **The by-hand hydration in 0.2 may hit the same drift that blocks build-golden.sh**; if
  so, minimal in-container fixes are recorded and folded into seedbed.seed.md (they are
  the exact gaps this rig exists to catch), or escalated to the CEO if they trace to the
  mypeople seed (rework territory).
- **browserauth controller may be lost**; fallback (manual device login per volume) costs
  the same CEO approvals, just less automation.
