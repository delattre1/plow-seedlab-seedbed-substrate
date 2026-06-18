# SEED: harden

> seed-format: 1

> **You're an AI agent reading this seed.** You are the **HARDENING CONDUCTOR**. Your job: take a TARGET seed and run the hardening-off loop until a *fresh, blind* agent can one-shot it from absolute zero. Run `## Step 0 Interview`, then execute the `## Loop` until DONE. You do NOT fix the target yourself and you do NOT test it yourself — you orchestrate two **separate, single-purpose** agents (a blind TESTER and a builder FIXER) and enforce a full clean slate between every iteration. On success print `HARDEN_RESULT=DONE`; if you exhaust the iteration budget print `HARDEN_RESULT=STALLED` with the last gap.

## Goal

"Harden off" a seed — drive it from *works-when-I-do-it* to *a fresh blind agent one-shots it every time* — by repeatedly: blind-hydrate → agent-driven verify → on fail, capture the exact gap, have a different agent fix the root cause, wipe ALL state, repeat. The output is a TARGET seed that reliably one-shots, plus the captured gaps/fixes as a record.

## Why this exists (the lesson — do not skip)

**Reused state masks gaps and produces false passes. It bit us twice on `seedbed.seed.md`:**
1. A **shared** Claude auth volume (`seedlab-claude-auth`) was already onboarded, so it hid a real bug: a fresh per-node volume hits Claude's first-run theme/onboarding dialog and blocks the spawned agent. Invisible until someone ran truly fresh.
2. After switching to per-node volumes, an iteration **kept** the node's auth volume "to avoid re-auth." That reused, already-onboarded volume produced a **FALSE PASS** — the run looked green but never exercised the fresh-login path, so the fix was unverified.

**Therefore: every iteration starts from ABSOLUTE ZERO.** No cached auth volume, no leftover container, no warm queue registration. If a step is "expensive" (e.g. a one-time human login), that cost is the *point* — paying it each iteration is what proves the seed handles it. A green run on reused state proves nothing.

## Inputs

| name | required | default | detect | ask |
|---|---|---|---|---|
| `TARGET_SEED` | yes | — | path exists | "Absolute path to the seed being hardened (e.g. `~/workspace/seedlab/seedbed.seed.md`)" |
| `MAX_ITERS` | no | `6` | — | "Max loop iterations before declaring STALLED" |
| `STATE_TO_WIPE` | yes | — | derived from the target | "The COMPLETE list of state a run creates that must be destroyed between iterations: containers, Docker volumes (esp. auth), queue/registry entries, tmpfiles. For `seedbed.seed.md`: the node container `<NODE_NAME>`, any `<NODE_NAME>-auth` helper, the per-node volume `claude-auth-<NODE_NAME>`, and the node's queue client/agent registrations." |
| `HARDEN_LOG` | no | `~/workspace/seedlab/harden-<target>-log.md` | — | "Where to append each iteration's gap + fix" |

## Roles (STRICT separation — the documented hardening roles; never blur them)

This is the ONLY allowed hardening flow, with exactly these two roles:

- **COORDINATOR (you):** the ONE engineer who **owns the TARGET seed source-of-truth AND runs the substrates.** You edit the seed, launch a fresh substrate that installs the *updated* seed, enforce the full clean slate between iterations, **fold** every reported problem+fix back into the seed (a seed edit, NEVER a live patch left only on the running box), strengthen the target's `## Verify` so the same bug can't false-green again, re-launch, and decide DONE/STALLED. You never grade your own run on the builder's word — the in-container worker's hard evidence + the target's own Verify are the judges.
- **IN-CONTAINER WORKER:** a brand-new, **clean-context, BLIND** agent given ONLY the target seed path + the `NODE_NAME` — **no hints, no prior-iteration knowledge, no pointers to the bug.** It **installs the seed and must drive it to the END.** If it hits a problem mid-install it (a) fixes it **in-container** so the install completes, and (b) REPORTS the exact FEEDBACK to you: precisely *what was wrong* + precisely *how it fixed it*. Inputs stay blind (no hints go IN); debugging + feedback come OUT. **An in-container fix that gets the install to finish is NOT a pass — it's a gap to fold** (if the worker needed help to complete, the seed isn't one-shotting yet).

A single agent must never both own/fold the seed AND be the blind in-container worker — that's how false passes happen. The worker installs+fixes+reports; the coordinator folds into the seed + re-runs.

## Step 0 — GENERATIVITY GATE (run FIRST, before any substrate or harden spend)

**What a real SEED is.** A true seed encodes **intent + contracts + acceptance journeys**, and a *blind agent GENERATES the software from it.* Gold standard: `almanac.seed.md` and the teleprompter seed — **zero pre-baked source**; the agent builds the product from the spec and self-verifies against it. An artifact that **embeds finished code** (heredocs, base64 blobs, tarballs, vendored source) and **pastes** it into place is an **INSTALL FLOW, not a seed** — it reproduces one frozen build instead of regenerating the software, so it cannot be hardened the way a seed is. (This is the mypeople mistake: a paste-artifact dressed up as a seed.)

**The gate (do this BEFORE standing up any substrate or starting the Loop).** Read the `TARGET_SEED` and decide: does a blind agent **GENERATE** the software from intent + contracts + acceptance journeys, or does the artifact **PASTE** finished code into place?

- **Generative** → proceed to the `## Loop`.
- **Pastes finished code** → **STOP.** Do **not** stand up a substrate, do **not** start the loop, do **not** spend harden cycles — hardening a paste-artifact hardens nothing. It is an install flow; **fix the artifact first**: rewrite the embedded code as intent + contracts + acceptance journeys the agent generates against, then re-enter this gate. Record the verdict; a substrate/harden spend on a non-generative artifact is a wasted spend and a process failure.

## Loop

Repeat up to `MAX_ITERS`:

### A. FULL CLEAN SLATE (before every iteration — including the first)

Destroy **all** `STATE_TO_WIPE`. Nothing carries over. For a `seedbed.seed.md` target:
```bash
NODE="${NODE_NAME:-harden-probe-1}"          # use a dedicated name so it's unambiguous to wipe
docker rm -f "$NODE" "${NODE}-auth" 2>/dev/null || true
docker volume rm "claude-auth-${NODE}" 2>/dev/null || true   # <-- the auth volume MUST go (no reuse)
# clear the node's queue registration so it can't show a stale 'pass':
# (state-preserving central restart that replays ONLY the real long-lived agents,
#  OR just confirm the dead node ages out — never let a prior node's client/agent linger)
```
Verify the slate is clean before proceeding: no target container, **no auth volume**, no stale queue client/agent for the node. If any remains, stop and fix the teardown — a dirty slate invalidates the iteration.

### B. BLIND HYDRATE + DRIVE TO THE END (fresh in-container worker)

Spawn a NEW clean-context agent **inside the fresh node** and deliver the seed to it **DIRECTLY over the central queue** (`mp send`) — NEVER `docker exec` the seed in from outside, NEVER a second "bridge" agent between you and the worker (see "## Forbids"). Give it **only**: the `TARGET_SEED` path, the `NODE_NAME`, and "install/hydrate this seed and drive it to the END, then run its `## Verify` exactly; report the verdict with evidence." Nothing else (blind inputs). If it hits a problem mid-install, it FIXES it in-container so the install completes and records **exactly what was wrong + exactly how it fixed it** — that feedback is the iteration's product. It must surface any human step the target itself defines (e.g. a one-time device login) — that's the target's own declared human touch, not a hint.

### C. AGENT-DRIVEN VERIFY (same worker, target's own Verify)

The worker runs the target's `## Verify` — **agent reasoning over the live node, never a pass/fail `.sh`**. It judges real evidence (e.g. a live in-container reply, an HTTP 200 attach, a queue registration) and concludes PASS or FAIL.

### D. BRANCH

- **PASS — one-shot, ZERO in-container fixes** (every Verify check holds AND the worker needed **no** in-container fix beyond the target's own declared one-time human steps) → the seed one-shot it. Record success → go to **F. SHIP**.
- **NOT a one-shot** (Verify failed, OR the worker had to fix anything in-container to finish) → capture the **EXACT feedback**: the precise `BLOCKED_REASON` / failing check, the command + output that showed it, and — from the worker — *what was wrong* + *how it fixed it in-container* (the root cause). Append to `HARDEN_LOG`. Go to E.

### E. FOLD (coordinator folds into the SEED — root cause only)

**You (the coordinator) fold the worker's reported problem+fix into the TARGET seed** at **root cause** — not a workaround that only papers over this instance, and NEVER a live patch left only on the running box (an in-container fix that isn't folded back into the seed is NOT the work). Confirm you found the real mechanism, **strengthen the target's `## Verify`** so the same bug can't false-green again, and report the exact change. **Fold the hard-won fix as a CONTRACT / acceptance check the generated software must satisfy — never as pasted finished code.** A fix pasted as a code blob freezes one build and turns the seed into an install flow (it stops being generative); a fix expressed as a contract keeps the seed generative and still prevents the regression. Then loop back to **A** (full clean slate) for a fresh blind re-test. Loop until a fresh container one-shots cleanly to the end.

### F. SHIP — LIVE ON THE REMOTE (a hardened seed is not done until it is published)

A green one-shot on your local box is **not** done. The hardened seed is the asset; it ships only when it is **live on the remote**: commit the edited TARGET seed, then **push → merge into the published branch (`main`) → confirm it's live** (`git fetch` shows the commit on remote `main`), and post the remote URL/commit. A change only committed locally — or sitting in the working tree — is NOT done, no matter how green the Verify. Publish only the completed, legitimate seed change; do not bundle unrelated in-progress work. Then → `HARDEN_RESULT=DONE`.

## Done

- A fresh, blind in-container worker hydrated the TARGET from absolute zero (clean slate, no reused state), drove it to the end with **zero in-container fixes**, and **all** of the target's own Verify checks passed — with **no human help beyond the target's own declared one-time steps**.
- Independently re-confirmable: wipe everything and have *another* fresh blind worker run it again — it should one-shot again.
- **Live on the remote (Step F):** the hardened seed is committed, pushed, and **merged into the published `main`** (`git fetch` confirms the commit on remote `main`), with the remote URL/commit posted. A local-only commit is NOT done.

## Forbids (hard rules — violating any one VOIDS the iteration)

- **The TARGET must be a real (generative) SEED, not an install flow.** Don't spend a single substrate/harden cycle until the Step 0 generativity gate passes: a blind agent must GENERATE the software from intent + contracts + acceptance journeys, not PASTE embedded code (heredocs/base64/vendored source). Hard-won fixes are folded as contracts, never as pasted code.
- **No reused state.** No cached auth volume, no leftover container, no warm queue registration carried across iterations. A green run on reused state proves nothing (see "## Why this exists").
- **Deliver the seed DIRECTLY to the in-container worker over the central queue (`mp send`).** NEVER `docker exec` the seed in from outside the container, and NEVER route it through a second "bridge" agent between you and the worker — there is no middleman. If the worker can't receive the seed directly, the substrate is broken — and finding that out IS the test. [R12]
- **Run the target's documented flow VERBATIM.** The worker executes every step of the seed as written — no "streamlined"/cherry-picked/adapted version. Every step exists because it failed before. A step an engineer believes is wrong or improvable is a PROPOSAL back to the coordinator (a seed-bug / fold request), never a silent substitution. Report compliance: each documented step → followed verbatim? yes/no + evidence. [R17]
- **The live/deployed product is a fresh-from-0 seed hydrate — never hand-assembled.** "Done/live" means a fresh node one-shot the documented Step 0→…→Verify from zero; never a hand-patched service, never "started a middle step on a pre-existing install." Same rigor as a validation substrate. [R28]
- **No self-grading.** The agent that owns/folds the seed is never the blind worker that runs it; the worker's hard evidence + the target's own Verify are the judges, never the builder's "looks done." [R15]
- **Not done until LIVE on the remote.** A local-only commit is a draft; the hardened seed must be pushed + merged into the published `main` and confirmed live (Step F). [R25]

## Verify (of the hardening run itself — agent-driven)

Reason, don't trust a script:
1. Confirm the passing iteration started from a **provably clean slate** (you saw the auth volume + container absent before it ran). A pass on reused state is void — re-run clean.
2. Confirm the TESTER was genuinely blind (given only the seed path, no gap hints) and was a different agent/context than any FIXER.
3. Confirm the tester's PASS rests on real evidence (live reply, HTTP 200, queue registration), not a self-reported "looks done."
4. Confirm `HARDEN_LOG` records each gap→fix so the hardening is auditable.
If all hold: `HARDEN_RESULT=DONE` with the target seed path and the iteration count. Else keep looping or `HARDEN_RESULT=STALLED` with the open gap.

## Notes

- **The clean slate is the whole point.** The single most common failure of this loop is a tester succeeding on warm state. When in doubt, wipe more.
- **Blindness is load-bearing.** The moment a tester is told "watch out for X," it stops being a real first-run and X stays unhardened for the next person.
- **Root cause, not workaround.** A fix that only handles the one observed symptom will re-fail on the next fresh run. Make the fixer confirm the actual mechanism (as with `hasCompletedOnboarding` — the real onboarding gate, found by diffing a working config, not a guessed flag).
- Keep iterations cheap to reason about: one gap, one fix, one re-test per loop.
