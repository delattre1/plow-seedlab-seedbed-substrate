# The Claude Auth Bank — new-engineer onboarding

Read this once before you spin any substrate. It explains **what the Claude Auth Bank is, how
authentication happens, how leasing keeps it safe, where the single source of truth lives, and
the everyday operations** — plus the one mistake that keeps recurring (scattered per-workstream
banks). Nothing here needs the CEO except the initial browser login.

---

## 1. What it is

The **Claude Auth Bank** is a fixed pool of **10 pre-authed Claude Docker volumes**:

```
claude-auth-bank-01  claude-auth-bank-02  …  claude-auth-bank-10
```

Each volume holds **one completed Claude login** on the CEO's **Max subscription** (OAuth, cached
in that volume's `~/.claude`). A substrate container mounts one of these volumes at `~/.claude` and
instantly has an authed `claude` — no login at spin time.

**The core rule: one volume is used by AT MOST one live container at a time.** Two containers sharing
one volume = auth theft: their Claude processes rotate each other's refresh tokens and **both log
out**. Everything below (the lease) exists to enforce that rule.

Tokens auto-refresh inside each volume; the volume is **kept** across container teardowns and
**never re-authed** on the normal path. A brand-new host has zero authed volumes — they are **live
host state**, not something this repo can regenerate on its own.

---

## 2. The login / auth flow (how a volume gets authed)

You almost never do this by hand. The bank is authed through the **browserauth CDP controller**:

- The controller drives a real Chrome over CDP and walks the Claude OAuth device-login flow for
  each `claude-auth-bank-NN` volume.
- The **only** human step is the CEO approving the login in **Safari + 1Password** (his Plow
  account, `daniel@plow.co`). One approval per volume, done through the controller — **zero manual
  per-volume `claude login` in a terminal**.
- On success the controller writes the credentials into that volume's `~/.claude` and moves to the
  next. The result is all 10 volumes AUTH_OK.

You request a (re)auth by asking the **browserauth** workstream/agent — do not hand-roll device
logins per volume; that is exactly the toil this flow removes.

---

## 3. Atomic per-node leasing (how a spin gets a volume safely)

Leasing is handled by [`lease/lease.sh`](../lease/lease.sh) and used automatically by
[`bin/spin.sh`](../bin/spin.sh). You rarely call `lease.sh` directly, but know what it does:

- **Acquire** — a spin atomically leases the **next free** volume (a test-and-set `mkdir` lock dir).
  Two concurrent spins can never grab the same volume; if none is free it **fails fast**
  (`NO_FREE_VOLUME`, exit 3) instead of double-leasing.
- **Release** — on teardown (or a failed run) the lease is released; the **volume is kept**, only
  the lock is removed. The volume flips back to free for the next spin.

So `bin/spin.sh N` leases N distinct volumes, mounts each into a fresh container, and rolls the
lease back on any container that fails to come up. Bank of 10 → at most 10 concurrent substrates;
the 11th request fails cleanly.

---

## 4. Canonical source of truth — there is exactly ONE of each

Do not create a second one of any of these. This is the whole point of the bank.

- **Volume-name convention:** `claude-auth-bank-NN` — literal prefix `claude-auth-bank-`, `NN`
  zero-padded to 2 digits, `01`–`10` (N=10).
- **The manifest (names only, version-controlled):**
  [`bank/volumes.txt`](../bank/volumes.txt) in this repo
  (abs `/Users/delattre/workspace/plow-seedlab-seedbed-substrate/bank/volumes.txt`).
  It lists the 10 names — **no secrets, no tokens**. This is the ONLY bank roster.
- **The lease dir (host-local lock dirs):** `~/.config/seedbed/leases-bank`
  (abs `/Users/delattre/.config/seedbed/leases-bank`). Lives on the machine that RUNS
  `lease.sh`/`spin.sh` — today `daniels-MacBook-Pro-2` (user `delattre`). **Why the Mac, not a
  server path:** `DOCKER_HOST=ssh://server` routes the *containers* to the server, but the lock
  files must be local to the machine issuing the spin. `/run/seedbed-bank/leases` is a server path
  and is not writable from the Mac — do not use it.

Workstream configs (`bridge.env`, `core.env`, …) all point at these two paths. If you find a config
pointing elsewhere, it is wrong — fix it to these.

---

## 5. The status dashboard

A live, **read-only** HTML dashboard shows every bank volume: authed? AUTH_OK? leased? which node?
subscription + token expiry.

- **URL:** http://100.103.163.104:8899/
- **Regenerate / (re)serve it:** run [`bin/bank-dashboard.sh`](../bin/bank-dashboard.sh) with
  `SERVE_PORT=8899`. It probes each volume (`PROBE=1`), writes the HTML, and serves the folder on
  the tailnet. It **never mutates a volume or a lease** — safe to run anytime.

```bash
# from the substrate repo, on the coordinator (Mac)
SERVE_PORT=8899 PROBE=1 bin/bank-dashboard.sh      # regen + serve on :8899
PROBE=0 bin/bank-dashboard.sh                       # fast render, skip auth probes
```

If the dashboard looks stale, just re-run it — it reflects live host state at run time.

### Keep it ALWAYS live (durable launchd agent)

A one-shot regen goes stale the moment leases change. The **durable** setup is a launchd user
agent that re-runs the regen loop every 120s and **auto-restarts on death or reboot** (a bare
`nohup` loop kept dying and freezing the page). One-time install on the coordinator (Mac):

```bash
# from the substrate repo, on the coordinator (Mac)
bash bin/install-bank-dashboard-agent.sh            # install + start the launchd agent
bash bin/install-bank-dashboard-agent.sh --uninstall
```

- Agent label **`com.seedbed.bank-dashboard`** (`~/Library/LaunchAgents/`), `KeepAlive=true` +
  `RunAtLoad=true`, env `DOCKER_HOST=ssh://server-ts` (the LAN `server` route is down — the tailnet
  alias is the reliable path), `SEEDBED_LEASE_DIR=~/.config/seedbed/leases-bank`.
- It runs [`bin/bank-dashboard-loop.sh`](../bin/bank-dashboard-loop.sh) (the repo-tracked loop —
  **not** an untracked host-local script, which is how it drifted before).
- Verify durability: `kill` the loop pid and confirm launchd respawns a new one within ~10s and the
  page's `generated` timestamp stays current.

---

## 6. Common operations

**Check bank status (free/used + auth):**
```bash
lease/lease.sh status        # per volume: FREE | USED <holder> <ts>
lease/lease.sh free-count    # how many are free right now
```
…or just open the dashboard (§5).

**Spin substrates (normal path — leasing is automatic):**
```bash
bin/spin.sh 3                # lease 3 free volumes, spin 3 substrates
bin/teardown.sh --prefix sub # tear down; leases released, volumes kept
```

**Add or replace a volume (rare — keep N=10 unless the CEO changes it):**
1. Add the new name to [`bank/volumes.txt`](../bank/volumes.txt) (follow `claude-auth-bank-NN`).
2. Create the Docker volume and have **browserauth** authenticate it (§2) — never a manual per-volume login.
3. `lease/lease.sh init` to register it and clear stale leases (run only when no containers are live).
4. Confirm on the dashboard it shows AUTH_OK.
   To *replace*, do the above for the new one, then retire the old (below).

**Retire a volume (drain first):**
- Only remove a volume when **no live container holds it** (check `lease.sh status` / the dashboard).
- `docker volume rm <name>` once its holder has drained, then remove its line from `bank/volumes.txt`.

---

## 7. What NOT to do

- **Do NOT create a per-workstream bank.** No `bridge-bank.txt`, `core-bank.txt`, `cto-bank.txt`,
  `authed-bank.txt`, `claude-auth-bank-10.txt`, etc. There is **one** manifest: `bank/volumes.txt`.
  (We just spent a cleanup retiring 54 scattered/duplicate volumes and six manifests — don't rebuild
  that mess.)
- **Do NOT use a second lease dir.** No `leases-bridge`, `leases-core`,
  `~/.seedbed-bank/leases-mpctofull`, or `/run/seedbed-bank/leases`. One lease dir:
  `~/.config/seedbed/leases-bank`.
- **Do NOT share one volume across two live containers** — that's the auth-theft failure the lease
  prevents. Always go through `spin.sh` / `lease.sh acquire`, never mount a bank volume by hand into
  a second container.
- **Do NOT do manual per-volume `claude login`** in a terminal — use the browserauth CDP flow (§2).
- **Do NOT commit secrets.** `bank/volumes.txt` is names only; tokens live inside the volumes
  (host state) and host secrets live in gitignored `~/.config/seedbed/substrate.env`.

---

## 8. Quick reference

| thing | where |
|---|---|
| Bank manifest (names only) | `bank/volumes.txt` |
| Lease dir (lock dirs) | `~/.config/seedbed/leases-bank` |
| Lease manager | `lease/lease.sh` (`status` / `free-count` / `acquire` / `release` / `init`) |
| Spin / teardown | `bin/spin.sh`, `bin/teardown.sh` |
| Status dashboard | http://100.103.163.104:8899/ — regen `SERVE_PORT=8899 bin/bank-dashboard.sh` |
| Volume convention | `claude-auth-bank-01` … `claude-auth-bank-10` |
| Login flow | browserauth CDP controller; CEO approves in Safari + 1Password (`daniel@plow.co`) |

Bank consolidation reached DONE on 2026-07-01: the canonical 10 are 10/10 AUTH_OK and a live
`/hydrate` passed 8/8. See the README "Honest live-state caveats" for the current live snapshot.
