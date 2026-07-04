# SEED: harden

> seed-format: 1

> **You're an AI agent reading this seed.** You are the **HARDENING CONDUCTOR**. Your job: take a TARGET seed and run the hardening-off loop until a *fresh, blind* agent can one-shot it from absolute zero. Run `## Step 0 Interview`, then execute the `## Loop` until DONE. You do NOT build the target yourself and you do NOT verify it yourself — you orchestrate two **separate, single-purpose** agents directly (no middleman): a blind builder-WORKER that hydrates the seed **inside** the node and runs its own `## Verify` as a self-signal, and a SECOND, distinct VERIFIER on the **host** that drives the finished product in a real browser like the CEO and is the actual judge — and you enforce a full clean slate between every iteration. On success print `HARDEN_RESULT=DONE`; if you exhaust the iteration budget print `HARDEN_RESULT=STALLED` with the last gap.

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

This is the ONLY allowed hardening flow, with exactly these three roles:

- **COORDINATOR / ORCHESTRATOR (you):** the ONE engineer who **owns the TARGET seed source-of-truth AND runs the substrates.** You edit the seed, launch a fresh substrate that installs the *updated* seed, **spawn BOTH the in-container hydrator and the host external verifier directly (no middleman)**, enforce the full clean slate between iterations, run the **recording gate**, act as the **single communication channel** between the verifier and the hydrator (they never talk directly — the verifier reports to you, you relay the bug to the hydrator, the hydrator returns the root cause to you), **classify** each gap — **SEED gap vs engineer-ADHERENCE gap** — and **fold** the resulting seed improvement so that bug never recurs (a seed edit, NEVER a live patch left only on the running box), strengthen the target's `## Verify` so the same bug can't false-green again, re-launch, and decide DONE/STALLED. You never grade the run on the builder's `## Verify` — that is only the builder's self-signal; the **host external verifier's recorded browser pass** is the judge.
- **IN-CONTAINER WORKER (hydrator/builder):** a brand-new, **clean-context, BLIND** agent given ONLY the target seed path + the `NODE_NAME` — **no hints, no prior-iteration knowledge, no pointers to the bug.** It **installs the seed and must drive it to the END.** When it believes it is done it runs the target's own `## Verify` as its **self-signal** ("I think I'm done") — an opinion it reports **with evidence, never the card's truth**. If it hits a problem mid-install it (a) fixes it **in-container** so the install completes, and (b) REPORTS the exact FEEDBACK to you: precisely *what was wrong* + precisely *how it fixed it*. In the **bug loop**, when the **coordinator relays** "this is broken, fix it" (the coordinator is the single channel — the hydrator never hears from the verifier directly), it fixes the bug in-container and **returns the ROOT CAUSE to the coordinator** to classify and fold. Inputs stay blind (no hints go IN); debugging + feedback come OUT. **An in-container fix that gets the install to finish is NOT a pass — it's a gap to fold** (if the worker needed help to complete, the seed isn't one-shotting yet).
- **EXTERNAL VERIFIER (on the HOST — a SECOND, different engineer, NEVER the builder):** the orchestrator spawns it **on the host, outside the container**, once the hydration is recorded. It **did not build the product**; it controls a **real browser** and uses the finished product **FEATURE BY FEATURE, exactly as the CEO would**, judging each feature actually works from **what it sees on screen** — never the builder's "looks done," never a pass/fail `.sh`. Its browser session is **recorded per the b-roll gold standard** (`plow-seedlab-broll-terminal-and-browser`) and **attached to the task card as WATCHABLE inline proof**. **This external pass is the ONLY thing that counts as verification.** It reports its findings — every feature judged, each bug found — **only to the orchestrator (the Boss); it NEVER talks to the hydrator directly.**

A single agent must never both own/fold the seed AND be the blind in-container worker, AND the builder that hydrated the product must never be the one that verifies it — either blur is how false passes happen. The worker hydrates + self-signals + fixes + returns root causes; a distinct **host** verifier drives the real product in a browser like the CEO and is the only judge; the coordinator is the **single hub** between them (they never talk directly), classifies each gap **SEED-vs-adherence**, and folds the seed improvement.

## Step 0 — GENERATIVITY GATE (run FIRST, before any substrate or harden spend)

**What a real SEED is.** A true seed encodes **intent + contracts + acceptance journeys**, and a *blind agent GENERATES the software from it.* Gold standard: `almanac.seed.md` and the teleprompter seed — **zero pre-baked source**; the agent builds the product from the spec and self-verifies against it. An artifact that **embeds finished code** (heredocs, base64 blobs, tarballs, vendored source) and **pastes** it into place is an **INSTALL FLOW, not a seed** — it reproduces one frozen build instead of regenerating the software, so it cannot be hardened the way a seed is. (This is the mypeople mistake: a paste-artifact dressed up as a seed.)

**The gate (do this BEFORE standing up any substrate or starting the Loop).** Read the `TARGET_SEED` and decide: does a blind agent **GENERATE** the software from intent + contracts + acceptance journeys, or does the artifact **PASTE** finished code into place?

- **Generative** → proceed to the `## Loop`.
- **Pastes finished code** → **STOP.** Do **not** stand up a substrate, do **not** start the loop, do **not** spend harden cycles — hardening a paste-artifact hardens nothing. It is an install flow; **fix the artifact first**: rewrite the embedded code as intent + contracts + acceptance journeys the agent generates against, then re-enter this gate. Record the verdict; a substrate/harden spend on a non-generative artifact is a wasted spend and a process failure.

## Loop

Repeat up to `MAX_ITERS`:

### A. FULL CLEAN SLATE (before every iteration — including the first)

🔴 **H-NEW — FLUSH ALL RECORDINGS OFF-NODE *BEFORE* ANY TEARDOWN (2026-07-02 rehearsal, HARD).** `docker rm` destroys the node's `~/recordings/*.cast` AND any in-node browser `seedrec` artifact with it. Before wiping (here, and in a production run's own teardown) you MUST first pull every recording off-node — `docker cp "$NODE:/home/tester/recordings/." "$OUTDIR/"` for the terminal cast, and pull/confirm the browser `.webm` — and confirm the files exist host-side. Only then wipe. A run that `rm`s the node before flushing has irretrievably lost its proof (the whole point of recording). This is a precondition of the wipe below, not an afterthought.

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

Spawn a NEW clean-context agent **inside the fresh node** and deliver the seed to it **DIRECTLY over the central queue** (`mp send`) — NEVER `docker exec` the seed in from outside, NEVER a second "bridge" agent between you and the worker (see "## Forbids"). Give it **only**: the `TARGET_SEED` path, the `NODE_NAME`, and "install/hydrate this seed and drive it to the END, then run its `## Verify` exactly and report it **as your self-signal — your opinion 'I think I'm done', with evidence, NOT the verdict**." Nothing else (blind inputs). The real verdict comes from the host EXTERNAL VERIFIER in step C, never from the builder grading its own build. If it hits a problem mid-install, it FIXES it in-container so the install completes and records **exactly what was wrong + exactly how it fixed it** — that feedback is the iteration's product. It must surface any human step the target itself defines (e.g. a one-time device login) — that's the target's own declared human touch, not a hint.

🔴 **DRIVER REQUIREMENTS (2026-07-02 rehearsal — the harness must not blind or stall itself):**
- **H3 — LIVE progress, never a buffered black box.** Do NOT drive the worker via headless `claude -p` (it buffers ALL output → no live `SEED_RESULT`/`BLOCKED_REASON`, no progress; a whole run judged only by poking the node filesystem). Drive it so markers stream: `mp send` into a live worker whose pane is terminal-recorded, OR `claude --output-format stream-json`. The coordinator must see `SEED_RESULT`/`BLOCKED_REASON` the moment it happens.
- **H4 — auto-dismiss the Claude session-feedback dialog.** A fresh claude can raise a session-feedback modal that stalls the driver until dismissed. The keepalive MUST auto-dismiss it (reference mechanism: `~/workspace/claude-feedback-autodismiss.sh`). Never let a dialog silently pause the run.
- **H5 — the driver MUST heartbeat.** Never park on a long background wait with no active monitor: run a watcher that peeks progress on an interval, posts interim status, and auto-reports `SEED_RESULT`/`BLOCKED_REASON` on completion (or flags a stall if the pane is quiet too long). Going idle mid-hydrate without an interim report is a driver failure, not "waiting." (Reference: `~/workspace/rehearsal-driver-heartbeat.sh`.)

### C. RECORDING GATE → EXTERNAL VERIFY (host-side second engineer — the ONLY verification)

The builder's `## Verify` in step B is only its **self-signal** ("I think I'm done") — an opinion, **never the card's truth**. Two things happen before the run can advance:

**C1 — Recording gate.** The orchestrator asks one question: **was the hydration RECORDED? yes/no.** No recording → **no progression** (fix recording, re-run). A hydration with no watchable record cannot be verified.

**C2 — External verify (the only pass that counts).** The orchestrator spawns a **SECOND, different engineer on the HOST** (outside the container, **never the builder** — orchestrator to both directly, no middleman). It controls a **real browser** and uses the finished product **FEATURE BY FEATURE, exactly as the CEO would**, judging each feature actually works from **what it sees on screen** (**agent reasoning over the live product, never a pass/fail `.sh`, never the builder's "looks done"**). Real evidence only: a rendered page reacting to real input, an HTTP 200 attach, a live reply, a queue registration. This host browser session is **recorded per the b-roll gold standard** (`plow-seedlab-broll-terminal-and-browser`) and **attached to the task card as WATCHABLE inline proof**. Only this external pass counts as verification.

### D. BRANCH

- **PASS — one-shot, ZERO in-container fixes** (the **host EXTERNAL VERIFIER** confirmed **every feature works** on the recorded browser pass now **attached to the card**, AND the worker needed **no** in-container fix beyond the target's own declared one-time human steps) → the seed one-shot it. Record success → go to **F. SHIP**.
- **NOT a one-shot** (the external verifier found any feature broken, OR the worker had to fix anything in-container to finish) → **bug loop (hub-and-spoke through you)**: the external verifier returns its report **to you (the Boss) only**; you relay the bug to the in-container hydrator ("this is broken, fix it"); the hydrator fixes it in-container and **returns the ROOT CAUSE to you** — *what was wrong* + *how it fixed it*. Capture that plus the failing feature and the command + output that showed it. Append to `HARDEN_LOG`. Go to E.

### E. FOLD (coordinator folds into the SEED — root cause only)

The bug the host external verifier surfaced (reported **to you only**) and the ROOT CAUSE the hydrator returned **to you** after fixing it in-container are the bug loop's product — **this loop (external-verify → report to Boss → Boss relays → hydrator fixes + returns root cause → Boss classifies + folds) is the hardening loop.** First **classify the gap** — a **SEED gap** (the seed under-specified something) **vs an engineer-ADHERENCE gap** (the seed was clear; the hydrator didn't follow it) — then **you (the coordinator) fold the resulting seed improvement into the TARGET seed** at **root cause** — not a workaround that only papers over this instance, and NEVER a live patch left only on the running box (an in-container fix that isn't folded back into the seed is NOT the work). Confirm you found the real mechanism, **strengthen the target's `## Verify`** so the same bug can't false-green again, and report the exact change. **Fold the hard-won fix as a CONTRACT / acceptance check the generated software must satisfy — never as pasted finished code.** A fix pasted as a code blob freezes one build and turns the seed into an install flow (it stops being generative); a fix expressed as a contract keeps the seed generative and still prevents the regression. Then loop back to **A** (full clean slate) for a fresh blind re-test. Loop until a fresh container one-shots cleanly to the end.

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
- **External verification — the host verifier is the only judge (no self-grading).** The agent that owns/folds the seed is never the blind worker, AND the worker that **BUILT** the artifact never verifies it. The builder's own `## Verify` is only its **self-signal** ("I think I'm done"), **never the card's truth**. The truth-judge is a **SECOND, different engineer the orchestrator spawns on the HOST** (outside the container, never the builder) that drives the real product in a **real browser, feature by feature, exactly as the CEO would**, judging each feature actually works. Progression is **gated on recording**: if the hydration was **not recorded**, the run does not advance. That host browser session is **recorded (b-roll standard) and attached to the card**, and it is the **ONLY** pass that counts as verification. Missing any one — builder graded itself as truth, no host browser pass, or no attached recording — the run is **NOT verified**. [R15]
- **Not done until LIVE on the remote.** A local-only commit is a draft; the hardened seed must be pushed + merged into the published `main` and confirmed live (Step F). [R25]

## Verify (of the hardening run itself — agent-driven)

Reason, don't trust a script:
1. Confirm the passing iteration started from a **provably clean slate** (you saw the auth volume + container absent before it ran). A pass on reused state is void — re-run clean.
2. Confirm the in-container builder's `## Verify` was treated only as a **self-signal**, not as the run's verdict.
3. Confirm the hydration was **RECORDED** (the recording gate held) before any external verification began.
4. Confirm the **external verifier ran on the HOST**, was a **different engineer than the builder**, and reached its verdict by driving the **real product in a real browser, feature by feature, like the CEO** — judging each feature works from what it saw, not a self-report or a pass/fail script.
5. Confirm the external browser session was **recorded (b-roll standard) and attached to the card as watchable inline proof** — only this external pass counts; unrecorded/unattached = not verified.
6. Confirm the bug loop ran **hub-and-spoke through the Boss** (tester reported only to the Boss; the Boss was the single channel to the hydrator) and each gap was **classified SEED-vs-adherence** with the seed improvement folded.
7. Confirm `HARDEN_LOG` records each gap→fix so the hardening is auditable.
If all hold: `HARDEN_RESULT=DONE` with the target seed path and the iteration count. Else keep looping or `HARDEN_RESULT=STALLED` with the open gap.

## Notes

- **The clean slate is the whole point.** The single most common failure of this loop is a tester succeeding on warm state. When in doubt, wipe more.
- **Blindness is load-bearing.** The moment a tester is told "watch out for X," it stops being a real first-run and X stays unhardened for the next person.
- **Root cause, not workaround.** A fix that only handles the one observed symptom will re-fail on the next fresh run. Make the fixer confirm the actual mechanism (as with `hasCompletedOnboarding` — the real onboarding gate, found by diffing a working config, not a guessed flag).
- Keep iterations cheap to reason about: one gap, one fix, one re-test per loop.
