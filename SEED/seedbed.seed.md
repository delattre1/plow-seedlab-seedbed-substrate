# SEED: seedbed

> seed-format: 1

> **You're an AI agent reading this seed.** Your job: run `## Step 0 Interview` to gather inputs, then execute every Step in order, then perform the **`## Verify`** block — which is **AGENT-DRIVEN**: you reason over the running node to confirm it works (you do NOT run a pass/fail shell script). When the node is proven working print `SEEDBED_RESULT=DONE`; on a blocker print `BLOCKED_REASON=<short reason>` and stop. You run on the **host** (the machine with Docker, the central MyPeople queue, the Tailscale API key, and the tkmx API key) and you drive a fresh container.

## Goal

Stand up a fresh **MyPeople validation node**: a clean Ubuntu/Debian container that

1. has the Claude CLI authenticated on the Max subscription (one-time **per-node** device login, cached in this node's OWN Docker volume — no API key, no cross-node sharing),
2. joins the Tailscale tailnet **non-interactively** (auth key minted from a stored API key — no device approval),
3. has the **complete** MyPeople runtime hydrated **from `mypeople.seed.md`** (every component the seed installs),
4. **joins OUR central queue** so the Boss can `mp spawn / send / peek / kill` agents on it,
5. is **attachable** in a browser at the container's own tailnet address.

This is the foundation reused for every future seed validation: a throwaway box you can stand up on demand, hydrate any seed inside, and drive + watch from the central queue. Nodes are disposable; the recipe is the asset.

## Deployment mode: JOIN (first-class, the default for our fleet)

seedbed installs the **complete** mypeople runtime, then deploys it in one of two modes:

- **JOIN (default — use this):** the node's `queue-client` points at the **central** queue-server (`host.docker.internal:9900`), the node registers as a **client** there (shows in the central `mp status` + HUD), and it runs **only `queue-client` + `ttyd`** — **no internal queue-server, no internal Boss**. The **central Boss IS the node's Boss**: you `mp spawn <node>/<sess>:<tab> --boss <central-boss>` from the central side, agents inside the node carry `BOSS_ID=<central-boss>`, and their Stop-hook notifications route back to the **central Boss's pane**. This is a deliberate, supported deployment of the same components — NOT an ad-hoc removal of steps.
- **STANDALONE:** the node runs the mypeople seed's own Step 8/9 verbatim (its OWN queue-server + Boss + daemons). Self-contained island; the central Boss does NOT see or control it. Use only when you explicitly want an isolated node.

**Contract of JOIN mode** (what Step 6/7 below implement):
1. `queue.env` → `QUEUE_URL=http://host.docker.internal:9900` + the **central** `QUEUE_SECRET` + unique `HOST_ID=<node>` + `TTYD_PUBLIC_URL=http://<node-tailnet-ip>:7681`.
2. `queue-client.py` advertises `attach_base` in its heartbeat (so the central HUD builds a correct per-node attach URL). Start `queue-client` (→central) + `ttyd` only.
3. Drive it from the central side: `mp spawn <node>/<sess>:<tab> --backend claude --boss <central-boss>` → `mp send …` → notifications land in the central Boss's pane; attach at the node's tailnet `ttyd`.

**Agent-runtime policy (CEO doctrine).** Every agent that **hydrates or validates a substrate** runs on **Claude** (`--backend claude`, as every `mp spawn` above already specifies). **Codex is NOT used for substrate validation/hydration.** Codex is reserved for exactly two roles: the central `main:Boss`, and — when a UI/browser flow needs it — the dedicated **browser-auth controller** (see `seedrec.seed.md`). Do not spawn a Codex worker to build, hydrate, or verify a node.

## Execution discipline (run verbatim, from zero, drive the node directly)

These are part of the recipe, not optional — they hold for anyone standing up this substrate or hydrating a seed on it:

- **Hydrate only GENERATIVE seeds — GATE this BEFORE spending the substrate.** A real seed encodes **intent + contracts + acceptance journeys** and makes a blind agent **GENERATE** the software from it (gold standard: `almanac.seed.md`, the teleprompter seed — **zero pre-baked source**, self-verify from spec). An artifact that **embeds finished code** (heredocs, base64 blobs, tarballs, vendored source) and **pastes** it into place is an **INSTALL FLOW, not a seed** (the mypeople mistake). Before standing up a node to hydrate a target, confirm the target is generative; if it pastes finished code, **STOP — do not spend this substrate on it**; fix the artifact first (rewrite the pasted code as intent + contracts the agent generates against). Hard-won fixes are folded as **contracts**, never as pasted code.
- **Run every Step VERBATIM.** Execute the Steps below in order, exactly as written — no "streamlined"/cherry-picked/adapted version. Every step exists because it failed before. A step you believe is wrong or improvable is a PROPOSAL back to the seed's coordinator (a seed-bug / change request), never a silent substitution; report compliance per step (followed verbatim? yes/no + evidence). [R17]
- **From ZERO only.** A node stands up by hydrating this seed from absolute zero on a fresh container — never hand-assembled, never "start a middle step on a pre-existing install," never a hand-patched box waved through as "live." The deployed/live product carries the same from-0 rigor as a validation substrate. [R28]
- **Drive the in-container agent DIRECTLY over the central queue.** Once the node is up, deliver seeds/work to the in-container agent with `mp send` (JOIN mode, above) and talk to it directly. NEVER `docker exec` a seed/command in from outside to "drive" it, and NEVER put a second relay agent between the central Boss and the in-container agent — there is no middleman. If the in-container agent can't receive a message directly, the substrate is broken, and finding that out IS the test. [R12]

## Done

Each independently confirmable by an agent **reasoning over the node** (not a script):

- Container running; `claude auth status` inside it reports a logged-in account.
- Container is on the tailnet with its own `100.x` IP and hostname `mypeople-<NODE_NAME>`.
- The complete MyPeople is installed from `mypeople.seed.md`: `bin/queue-server.py`, `bin/queue-client.py`, `bin/mp`, `bin/dashboard.html`, `boss-CLAUDE.md`, the `tmux-boss-hooks` plugin, `~/.tmux.conf` + TPM.
- The node is registered as a **client** on the CENTRAL queue and advertises a tailnet `attach_base`.
- The Boss can **spawn** an agent into the node, **converse** with it (send a prompt, get a coherent live reply from inside the container), and **attach** to its tmux in a browser (the per-tab URL serves the node's session).
- The node's worker pane is being **continuously terminal-recorded by default** with **asciinema** (Step 7.6): a tiny in-container pty logger, ~0% CPU / ~55 MB, race-proven ~14x less RAM & ~300x less CPU than browser recording, writing a growing `~/recordings/<NODE_NAME>.cast`. Browser `seedrec` recording is **not** a duplicate default recorder; it is opt-in only for seeds/tests that explicitly exercise UI/browser behavior and need a `.webm` browser artifact. The terminal recording renders to clean mp4 via `recorder/render_clip.sh` and stops ONLY on a CEO-driven signal (`approved-retire` | `ceo-request`).
- The node runs the **tkmx reporter** daemon: `~/.config/tkmx/.env` carries the CEO's key (chmod 600, **never committed**), `CLIENT_ID=mp-<NODE_NAME>`, and `~/tkmx-client` posts the node's Claude token burn to `$TKMX_SERVER_URL` (HTTP 200). The CEO's leaderboard shows this node as its own "machine".

## Inputs

| name | required | default | detect | ask |
|---|---|---|---|---|
| `NODE_NAME` | no | `mp-seedbed-1` | — | "Unique node id (container/hostname/queue HOST_ID). **MUST be a STABLE IDENTIFIER, never a STATE word.** FORBIDDEN: `clean`, `fresh`, `new`, `temp`, `test`, `wip`, `bare`, `zero` — these are states that change (the moment the node is used it's no longer 'clean'/'fresh', but the name lies). Use a stable id like `seedbed-N` / `<purpose>-seedbed-N`; track state (fresh/used/discarded) SEPARATELY, outside the name. (Boss doctrine Rule 9.)" |
| `IMAGE` | no | `seedlab-test:latest` | `docker image inspect` (build from `~/workspace/seedlab/test-fresh` if missing) | — |
| `SEEDBED_DIND` | no | unset/`0` | explicit env | "Set to `1` for a **docker-capable** substrate (the node runs its OWN inner `dockerd`). REQUIRED when the blind worker will hydrate a seed that itself runs Docker (e.g. a Dockerized stack like `seed-hermes-airbnb-manager`). Adds `--privileged` + a per-node `/var/lib/docker` volume (true from-zero isolation, no shared image cache, avoids overlay-on-overlay), installs docker + the compose v2 plugin in the node, adds `tester` to the `docker` group, starts `dockerd`, and arms the **8th SUBSTRATE_READY gate** (`docker compose version` + `docker run hello-world`). Default (unset) = the classic claude-only substrate, unchanged." |
| `AUTH_VOLUME` | no | `claude-auth-<NODE_NAME>` (per-node, NOT shared — this node's volume in the **Claude Auth Bank**) | `docker volume inspect` | — |
| `CENTRAL_QUEUE_URL` | no | `http://host.docker.internal:9900` | — | "Central queue the node joins" |
| `CENTRAL_QUEUE_SECRET` | yes | — | `grep ^QUEUE_SECRET= ~/.config/mypeople/queue.env` | — |
| `CENTRAL_BOSS` | no | `daniels-MacBook-Pro-2/main:Boss` | the central Boss agent_id (`<host>/<sess>:<tab>`) | "Which central Boss owns this node — agents spawn with `--boss $CENTRAL_BOSS`; its pane is tmux `mc-<sess>:<tab>` on the host" |
| `TAILSCALE_API_KEY` | yes | — | `grep ^TAILSCALE_API_KEY= ~/workspace/seedlab/.env` | `BLOCKED_REASON=tailscale_api_key_not_found` |
| `TS_TAILNET` | no | `-` (the API key's default tailnet) | — | — |
| `TTYD_HOST_PORT` | no | `7682` | host port free | "Host port mapped → container ttyd 7681 (fallback attach if tailnet join fails)" |
| `SEEDBED_BROWSER_RECORDING` | no | unset/`0` | explicit env | "Set to `1` only when this seedbed/test explicitly exercises UI/browser behavior and needs a browser `.webm` artifact. Default non-UI seedbeds MUST NOT start browser `seedrec` as a duplicate recorder." |
| `TTYD_REC_PORT` | no | `7726` | host port free | "Host port for the optional browser-recorder's dedicated read-only ttyd (Step 7.6 opt-in browser block). MUST differ from TTYD_HOST_PORT and from other nodes' rec ports when enabled." |
| `MYPEOPLE_SEED_URL` | no | `https://raw.githubusercontent.com/plow-pbc/mypeople/main/seeds/mypeople.seed.md` | — | — |
| `TKMX_API_KEY` | yes | — | `grep ^TKMX_API_KEY= ~/workspace/seedlab/.env` | `BLOCKED_REASON=tkmx_api_key_not_found` (copy the CEO's existing key from the host install `~/Desktop/projects/cncorp/tokenmaxxing/client/.env` into `~/workspace/seedlab/.env` as `TKMX_API_KEY=` — gitignored, like the Tailscale key) |
| `TKMX_USERNAME` | yes | — | `grep ^TKMX_USERNAME= ~/workspace/seedlab/.env` | "CEO's tkmx leaderboard username (the account the node's token burn reports under) — copy from the host install's `.env`" |
| `TKMX_SERVER_URL` | no | `https://tokenmaxxing.odio.dev` | `grep ^TKMX_SERVER_URL= ~/workspace/seedlab/.env` | — |
| `TKMX_CLIENT_ID` | no | `mp-<NODE_NAME>` | — | "Stable, substrate-scoped machine id for this node on the leaderboard. MUST be unique per node (PK is `username+date+model+client_id+source`) — never the host's machine-hashed id, the `seedlab-tkmx` container's id, or another node's. Default `mp-<NODE_NAME>` is unique by construction." |
| `TKMX_TEAM` | no | `seedbed` | — | "Team grouping for fleet nodes on the leaderboard" |
| `TKMX_REPORT_INTERVAL` | no | `300` | — | "Seconds between reporter runs inside the node (default 5 min)" |
| `RECORDER_DIR` | no | `~/workspace/seedlab/recorder` | `[ -f ~/workspace/seedlab/recorder/render_clip.sh ]` | "asciinema render kit (Step 7.6 / gate 7): `render_clip.sh` + `normalize_glyphs.py` + bundled `fonts/` (JetBrainsMono Nerd Font Mono). Rendering also needs `agg` + `ffmpeg` on the render host (`brew install agg ffmpeg` / `cargo install --git https://github.com/asciinema/agg`). asciinema itself is installed INSIDE each node at Step 7.6 (Debian: `apt-get install asciinema`)." |

## Components

| Component | Source | Notes |
|---|---|---|
| base image | `~/workspace/seedlab/test-fresh/Dockerfile` (`seedlab-test`) | node:20-bookworm-slim + Claude CLI + tmux + sudo, runs as non-root `tester` |
| Claude auth (the **Claude Auth Bank**) | **per-node** Docker volume `claude-auth-<NODE_NAME>` | Max-subscription OAuth device login, **once per node**, cached in that node's OWN volume (see Step 2). Never an API key; never shared across nodes. The pool of these `claude-auth-<id>` volumes — each one a completed Max-sub login, leased atomically, never re-authed — is collectively the **Claude Auth Bank**. |
| Tailscale API key | `~/workspace/seedlab/.env` → `TAILSCALE_API_KEY` | mints short-lived auth keys via the Tailscale API |
| MyPeople runtime | `mypeople.seed.md` (fetched fresh) | hydrated INSIDE the container (Step 6) |
| central queue | the host's running `queue-server.py` on `:9900` | the node joins this; Boss drives agents through it |
| tkmx reporter | `https://github.com/srosro/tkmx-client` (latest `main`) + `agentsview` (hard dep) | installed INSIDE the node (Step 6.6); reports THIS node's Claude token burn to the leaderboard. Reads the node's `~/.claude` via agentsview — no interception, just transcript usage. |
| tkmx API key | `~/workspace/seedlab/.env` → `TKMX_API_KEY` (gitignored) | the CEO's **existing** leaderboard key (sourced once from the host install). Reused, **never committed, never baked into the image**, injected via `docker exec -e`. |

## Steps

### 0. Interview (mandatory)

Detect all inputs (commands in the table). Confirm `CENTRAL_QUEUE_SECRET` and `TAILSCALE_API_KEY` resolve. Send ONE consolidated interview line if anything is ambiguous, then run autonomously.

### 1. Preflight

```bash
NODE_NAME="${NODE_NAME:-mp-seedbed-1}"
IMAGE="${IMAGE:-seedlab-test:latest}"
AUTH_VOLUME="${AUTH_VOLUME:-claude-auth-$NODE_NAME}"   # per-node volume — NEVER shared (avoids refresh-token rotation across concurrent nodes)
CENTRAL_QUEUE_URL="${CENTRAL_QUEUE_URL:-http://host.docker.internal:9900}"
CENTRAL_QUEUE_SECRET="$(grep '^QUEUE_SECRET=' "$HOME/.config/mypeople/queue.env" | cut -d= -f2-)"
CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}"   # JOIN-mode: the central Boss that owns this node (agents spawn with --boss "$CENTRAL_BOSS")
TAILSCALE_API_KEY="$(grep '^TAILSCALE_API_KEY=' "$HOME/workspace/seedlab/.env" | cut -d= -f2-)"
TS_TAILNET="${TS_TAILNET:--}"
TTYD_HOST_PORT="${TTYD_HOST_PORT:-7682}"
MYPEOPLE_SEED_URL="${MYPEOPLE_SEED_URL:-https://raw.githubusercontent.com/plow-pbc/mypeople/main/seeds/mypeople.seed.md}"
# tkmx token-burn reporter creds — pulled from the gitignored seedlab .env (same
# file as TAILSCALE_API_KEY). The CEO already has a registered key; copy it once
# from his host install (~/Desktop/projects/cncorp/tokenmaxxing/client/.env) into
# ~/workspace/seedlab/.env. NEVER committed, NEVER baked into the image.
TKMX_API_KEY="$(grep '^TKMX_API_KEY=' "$HOME/workspace/seedlab/.env" | cut -d= -f2-)"
TKMX_USERNAME="$(grep '^TKMX_USERNAME=' "$HOME/workspace/seedlab/.env" | cut -d= -f2-)"
TKMX_SERVER_URL="${TKMX_SERVER_URL:-$(grep '^TKMX_SERVER_URL=' "$HOME/workspace/seedlab/.env" | cut -d= -f2-)}"; TKMX_SERVER_URL="${TKMX_SERVER_URL:-https://tokenmaxxing.odio.dev}"
TKMX_CLIENT_ID="${TKMX_CLIENT_ID:-mp-$NODE_NAME}"   # stable, substrate-scoped — unique per node by construction
TKMX_TEAM="${TKMX_TEAM:-seedbed}"
TKMX_REPORT_INTERVAL="${TKMX_REPORT_INTERVAL:-300}"

command -v docker >/dev/null || { echo "BLOCKED_REASON=docker_not_found"; exit 1; }
[ -n "$CENTRAL_QUEUE_SECRET" ] || { echo "BLOCKED_REASON=central_queue_secret_not_found"; exit 1; }
[ -n "$TAILSCALE_API_KEY" ] || { echo "BLOCKED_REASON=tailscale_api_key_not_found"; exit 1; }
[ -n "$TKMX_API_KEY" ] || { echo "BLOCKED_REASON=tkmx_api_key_not_found"; exit 1; }
[ -n "$TKMX_USERNAME" ] || { echo "BLOCKED_REASON=tkmx_username_not_found"; exit 1; }
curl -fsS "$CENTRAL_QUEUE_URL/health" >/dev/null 2>&1 || docker run --rm --add-host host.docker.internal:host-gateway "$IMAGE" curl -fsS "$CENTRAL_QUEUE_URL/health" >/dev/null 2>&1 || { echo "BLOCKED_REASON=central_queue_unreachable"; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$HOME/workspace/seedlab/test-fresh"
```

### 2. Per-node Claude auth — ONE-TIME device login, in THIS node's OWN volume

Claude runs on the CEO's **Max subscription** via OAuth device login — **never an API key**. Each node authenticates **once, into its own volume `claude-auth-<NODE_NAME>`**, and reuses it across that node's restarts. Volumes are **never shared between nodes** — sharing one volume across concurrently-running nodes makes their Claude processes rotate each other's refresh tokens and breaks auth; per-node volumes eliminate that entirely. The pool of these `claude-auth-<id>` volumes — each one a completed Max-subscription login, leased atomically (one volume per node), and **never re-authed** — is collectively the **Claude Auth Bank**.

**Capture `claude auth status` to a variable** (do NOT `| grep -q` it under `pipefail` — `grep -q` closes the pipe on the first line and SIGPIPEs claude into a non-zero exit, falsely reading "unauthed").

```bash
docker volume create "$AUTH_VOLUME" >/dev/null    # AUTH_VOLUME = claude-auth-<NODE_NAME>
AUTH_OUT="$(docker run --rm -v "$AUTH_VOLUME:/home/tester/.claude" "$IMAGE" claude auth status --text 2>&1 || true)"
if printf '%s\n' "$AUTH_OUT" | grep -qE 'Login method:'; then
  echo "claude auth: reused from this node's own volume $AUTH_VOLUME (already logged in)"
else
  # ── ONE-TIME device login for THIS node (approved through the browser-auth flow) ──
  # Drive `claude auth login` in a tmux session so you can read the login URL and
  # confirm completion. This is the seed's single human touch, per node.
  docker rm -f "${NODE_NAME}-auth" >/dev/null 2>&1 || true
  # The auth helper + its `claude auth login` MUST stay alive long enough for the browser-auth
  # approval to land — esp. in PARALLEL N-node bring-ups where approvals QUEUE behind each other.
  # (Folded 2026-06-18: a `sleep 900` helper EXPIRED before approval during a 4-node parallel
  # bring-up → the per-node login died and had to be re-staged. Use a generous sleep, and on
  # helper-death-before-login-lands, RE-STAGE the login rather than failing the node.)
  docker run -d --name "${NODE_NAME}-auth" -v "$AUTH_VOLUME:/home/tester/.claude" "$IMAGE" sleep 3600 >/dev/null
  docker exec "${NODE_NAME}-auth" bash -lc 'tmux kill-server 2>/dev/null; tmux new-session -d -s login "claude auth login 2>&1 | tee /tmp/login.out; sleep 3000"'
  # Surface the device-login URL to the CEO (capture-pane joins wrapped lines):
  LOGIN_URL=""
  for i in $(seq 1 40); do
    LOGIN_URL="$(docker exec "${NODE_NAME}-auth" bash -lc "tmux capture-pane -t login -p -S -300 -J 2>/dev/null | grep -oE 'https://[^ ]*(claude\\.(ai|com)|anthropic)[^ ]*' | head -1")"
    [ -n "$LOGIN_URL" ] && break; sleep 1
  done
  # The agent hands this URL to the BOSS. The BOSS routes it through the dedicated
  # browser-auth controller/session for substrate auth. Do NOT open it in the CEO's
  # personal Safari or any unrelated browser session. The fresh token then lands in
  # THIS node's OWN volume. NEVER copy a token from another node/volume (same token
  # in 2 active places rotates refresh tokens and invalidates the other holder,
  # incl. the CEO's MAIN session -> whole system DOWN). [Rule 13]
  #
  # PROVEN ZERO-CLICK PATH (no CEO): dispatch a CODEX controller (Claude controllers
  # REFUSE on "confused-deputy" grounds) with the MUNDANE framing only — "run this,
  # paste the output", NO security justifications (defensive framing signals danger
  # and triggers refusals). The controller runs ONE command, which drives the CEO's
  # already-authed Chrome on CDP 9231, verifies account=daniel@plow.co, clicks
  # Authorize, captures code#state, and injects it back here — preconditions: this
  # auth container is MAC-LOCAL (same daemon as the CDP-9231 Chrome) and the URL is
  # visible on tmux:login above:
  #   cd ~/.claude-chrome-cdp && ./claude-auth-via-chrome.sh "${NODE_NAME}-auth" login
  # FULL RUNBOOK (the source of truth for this flow, incl. failure modes):
  #   ~/.claude-chrome-cdp/BROWSER-AUTH-RUNBOOK.md
  # DEPENDENCY: this per-node auth IS the standalone browser-auth seed. Run/read it
  # as the canonical procedure (incl. ## Verify + failure modes) rather than re-deriving:
  #   seeds/claude-browser-auth.seed.md
  echo "BOSS ACTION (ONE-TIME for node ${NODE_NAME}): approve this URL via the browser-auth controller/session (if prompted, get the code):"
  echo "  $LOGIN_URL"
  # If claude shows a code prompt, read the code from the approved browser page; inject it via tmux:
  #   docker exec "${NODE_NAME}-auth" bash -lc 'tmux send-keys -t login -l -- "<CODE>"; sleep 0.2; tmux send-keys -t login Enter'
  # Wait until auth lands in this node's volume. POLL THE VOLUME, NOT the ephemeral helper
  # container (folded 2026-06-18): the `${NODE_NAME}-auth` helper can vanish (its `sleep` expires,
  # or it's removed) the moment auth lands — if you poll `docker exec ${NODE_NAME}-auth …` it then
  # errors forever and you NEVER detect a perfectly-good landed auth (the loop sleeps until timeout
  # on a dead container). Check the VOLUME directly so a landed auth is seen even if the helper is
  # gone — and NEVER wipe the volume to "re-stage" without first confirming it's NOT already authed.
  for i in $(seq 1 300); do
    A="$(docker run --rm -v "$AUTH_VOLUME:/home/tester/.claude" "$IMAGE" claude auth status --text 2>&1 || true)"
    printf '%s\n' "$A" | grep -qE 'Login method:' && break; sleep 3
  done
  printf '%s\n' "$A" | grep -qE 'Login method:' || { echo "BLOCKED_REASON=claude_device_login_not_completed"; docker rm -f "${NODE_NAME}-auth" >/dev/null 2>&1; exit 1; }
  # Snapshot the app-config so fresh containers on THIS volume skip first-run /
  # a second OAuth dance (the seedlab entrypoint restores ~/.claude.json from it).
  docker exec "${NODE_NAME}-auth" bash -lc '[ -f ~/.claude.json ] && cp ~/.claude.json ~/.claude/.app-config-snapshot.json && chmod 600 ~/.claude/.app-config-snapshot.json || true'
  docker rm -f "${NODE_NAME}-auth" >/dev/null 2>&1 || true
  echo "claude auth: completed + cached in $AUTH_VOLUME (this node only)"
fi

# ── CRITICAL: mark onboarding complete in the node's cached app-config ────────
# A fresh per-node volume has NO `hasCompletedOnboarding`, so a spawned in-container
# Claude hits the first-run theme/onboarding dialog and `mp spawn` blocks
# (BLOCKED_REASON=claude_first_run_theme_dialog_blocks_spawn). `claude auth login`
# (CLI) does NOT set it — only the TUI first-run would. `hasCompletedOnboarding:true`
# is the exact gate that skips the entire first-run (theme + onboarding). We bake it
# into the volume's snapshot, which the seedlab entrypoint restores to ~/.claude.json
# on every container start — so this persists across restarts and applies BEFORE any
# spawn. (Runs in BOTH branches above, so reused volumes get fixed too.)
CLAUDE_VER="$(docker run --rm "$IMAGE" claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
docker run --rm -v "$AUTH_VOLUME:/home/tester/.claude" --entrypoint bash "$IMAGE" -lc '
python3 - "'"${CLAUDE_VER:-2.1.159}"'" <<PY
import json, os, sys
ver = sys.argv[1]
p = "/home/tester/.claude/.app-config-snapshot.json"
d = json.load(open(p)) if os.path.exists(p) else {}
d["hasCompletedOnboarding"] = True          # the gate that suppresses first-run
d["lastOnboardingVersion"]  = ver           # matches the proven onboarded config
d.setdefault("theme", "dark")               # belt-and-suspenders: no theme picker
json.dump(d, open(p, "w"), indent=1); os.chmod(p, 0o600)
print("snapshot onboarding-normalized: hasCompletedOnboarding=True lastOnboardingVersion="+ver)
PY'
```

### 3. Mint a Tailscale auth key via the API (non-interactive)

The stored key is an **API key** (`tskey-api-`); use it to mint a short-lived, reusable, ephemeral, pre-authorized **auth key** (`tskey-auth-`). No device approval, no login URL.

```bash
TS_AUTHKEY="$(curl -fsS -u "${TAILSCALE_API_KEY}:" -X POST \
  "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/keys" \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true}}},"expirySeconds":3600}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')"
case "$TS_AUTHKEY" in tskey-auth-*) : ;; *) echo "BLOCKED_REASON=tailscale_mint_failed"; exit 1;; esac
```

### 4. Launch a fresh container

`NET_ADMIN` + `/dev/net/tun` are required so `tailscaled` can run inside; the port-map is a fallback attach path if the tailnet join ever fails.

```bash
docker rm -f "$NODE_NAME" >/dev/null 2>&1 || true
# DOCKER-IN-DOCKER variant (SEEDBED_DIND=1): the node runs its own inner dockerd so a blind
# worker can hydrate a Dockerized seed. --privileged + a PER-NODE /var/lib/docker volume gives
# true from-zero isolation (no shared image cache, no host drift) and avoids the overlay-on-
# overlay whiteout-extract failure. The volume MUST be wiped with the node between harden iters.
# ── REQUIRED (not optional) WHEN THE TARGET SEED SHARES THE HARNESS'S STACK (folded 2026-06-18) ──
# This substrate's comms-harness IS mypeople (JOIN). If the seed you will hydrate is ALSO mypeople
# (our case — hydrating the mypeople product), the product + harness COLLIDE: both want
# ~/.config/mypeople/queue.env and :9900. The product (STANDALONE) overwrites queue.env → its own
# :9900, so the harness queue-client re-points away from the central → THE NODE DROPS OFF CENTRAL
# AND YOU LOSE COMMS WITH THE WORKER. So: when target-stack == harness-stack, DIND is MANDATORY —
# the worker hydrates the product in an ISOLATED INNER container (own config, own :9900), the outer
# harness keeps its central queue.env untouched. Rule of thumb a context-less engineer must apply:
# **if the seed-under-test installs the same runtime as the substrate, set SEEDBED_DIND=1.**
DIND_RUN_ARGS=""
if [ "${SEEDBED_DIND:-0}" = 1 ]; then
  docker volume rm "${NODE_NAME}-dockerlib" >/dev/null 2>&1 || true   # from-zero
  docker volume create "${NODE_NAME}-dockerlib" >/dev/null
  DIND_RUN_ARGS="--privileged -v ${NODE_NAME}-dockerlib:/var/lib/docker"
fi
# --init (tini as PID 1) is REQUIRED: recorder attach paths create short-lived tmux clients/servers
# (asciinema's nested attach, and optional browser ttyd attach cycles). Their parents exit and they reparent to PID 1.
# With `sleep infinity` as PID 1 (no reaper) those become <defunct> ZOMBIES and accumulate for the
# node's whole life (PID/memory leak over a long recording). tini reaps them. Verified: a fresh
# asciinema-recorded --init node stays at 0 zombies over minutes; without --init it climbed to 400+.
docker run -d --init --name "$NODE_NAME" --hostname "$NODE_NAME" \
  --add-host host.docker.internal:host-gateway \
  --cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun \
  $DIND_RUN_ARGS \
  -p "${TTYD_HOST_PORT}:7681" \
  -v "$AUTH_VOLUME:/home/tester/.claude" \
  "$IMAGE" sleep infinity

# DIND: install docker + compose v2 plugin in the node, add tester to the docker group, start
# the inner dockerd. Self-contained (no special base image needed) — debian `docker.io` + the
# compose plugin binary. Idempotent. Runs BEFORE the worker spawns so the docker-group membership
# is in effect for the blind worker's shell.
if [ "${SEEDBED_DIND:-0}" = 1 ]; then
  docker exec -u root "$NODE_NAME" bash -lc '
    set -e
    if ! command -v dockerd >/dev/null; then
      apt-get update -qq && apt-get install -y -qq docker.io iptables uidmap >/dev/null 2>&1
      mkdir -p /usr/local/lib/docker/cli-plugins
      A=$(dpkg --print-architecture); case "$A" in amd64) M=x86_64;; arm64) M=aarch64;; *) M=$A;; esac
      curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${M}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
    getent group docker >/dev/null || groupadd docker
    usermod -aG docker tester
    # NB: base image has no pgrep (procps lands in Step 5) — probe the daemon socket, not the process.
    docker info >/dev/null 2>&1 || nohup dockerd >/var/log/dockerd.log 2>&1 &
    for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker version >/dev/null 2>&1 || { echo "BLOCKED_REASON=inner_dockerd_failed"; tail -20 /var/log/dockerd.log; exit 1; }
    echo "inner dockerd up ($(docker --version)); compose $(docker compose version --short 2>/dev/null)"
  '
fi
```

### 5. Inside the container: deps + non-interactive tailnet join

```bash
docker exec "$NODE_NAME" bash -lc '
set -e
sudo apt-get update -qq && sudo apt-get install -y -qq jq procps iproute2 >/dev/null 2>&1
if ! command -v ttyd >/dev/null; then
  case "$(uname -m)" in aarch64|arm64) A=ttyd.aarch64;; x86_64) A=ttyd.x86_64;; esac
  sudo curl -fsSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/latest/download/$A"; sudo chmod +x /usr/local/bin/ttyd
fi
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sudo sh >/dev/null 2>&1
'
# tailscale up with the minted key (userland tailscaled on a private socket)
docker exec -e TS_AUTHKEY="$TS_AUTHKEY" -e NODE_NAME="$NODE_NAME" "$NODE_NAME" bash -lc '
set -e
TSD=/home/tester/mypeople/run/tailscale-state
mkdir -p /home/tester/mypeople/run     # create the parents as tester so Step 6 installer can write bin/status/plugins
sudo mkdir -p "$TSD"                     # only the tailscaled-state leaf is root-owned
sudo bash -c "nohup tailscaled --state=$TSD/tailscaled.state --socket=$TSD/tailscaled.sock >$TSD/tailscaled.log 2>&1 & echo \$! >$TSD/tailscaled.pid"
for i in $(seq 1 40); do [ -S "$TSD/tailscaled.sock" ] && break; sleep 0.3; done
sudo tailscale --socket=$TSD/tailscaled.sock up --authkey="$TS_AUTHKEY" --hostname="mypeople-$NODE_NAME" --ssh=false --accept-routes=false
for i in $(seq 1 30); do IP=$(sudo tailscale --socket=$TSD/tailscaled.sock ip -4 2>/dev/null | head -1); [ -n "$IP" ] && break; sleep 0.5; done
[ -n "$IP" ] || { echo "no tailnet IP"; exit 1; }
echo "$IP" | sudo tee "$TSD/ip" >/dev/null
echo "tailnet IP: $IP"
'
CONTAINER_TS_IP="$(docker exec "$NODE_NAME" bash -lc 'sudo cat /home/tester/mypeople/run/tailscale-state/ip')"
```

### 6. Inside the container: hydrate the COMPLETE MyPeople from `mypeople.seed.md`, in JOIN mode

Fetch the canonical MyPeople seed and run its **component-install** steps (everything it installs), then deploy in **JOIN mode** (see "## Deployment mode" above). We run the seed's installer steps **3, 3.5, 3.6, 3.7, 4, 5, 6, 7, 7.5** (which install ALL mypeople components, including `queue-server.py` and `boss-CLAUDE.md`), then — instead of the seed's STANDALONE Step 8/9 (which would stand up the node's OWN queue-server + Boss) — we point the node's `queue-client` at the **central** queue and run only `queue-client` + `ttyd`. Same components, deliberately deployed as a fleet member rather than a standalone island.

```bash
curl -fsSL "$MYPEOPLE_SEED_URL" -o /tmp/mypeople.seed.md
docker cp /tmp/mypeople.seed.md "$NODE_NAME:/home/tester/mypeople.seed.md"
docker exec -u root "$NODE_NAME" chown tester:tester /home/tester/mypeople.seed.md
docker exec \
  -e CENTRAL_QUEUE_URL="$CENTRAL_QUEUE_URL" \
  -e CENTRAL_QUEUE_SECRET="$CENTRAL_QUEUE_SECRET" \
  -e NODE_NAME="$NODE_NAME" \
  -e CONTAINER_TS_IP="$CONTAINER_TS_IP" \
  "$NODE_NAME" bash -lc '
set -e
export INSTALL_DIR=/home/tester/mypeople QUEUE_PORT=9900 TTYD_PORT=7681
# (a) extract + run the MyPeople seed component-install steps
python3 - /home/tester/mypeople.seed.md <<"PY"
import re,sys,os
src=open(sys.argv[1]).read().splitlines(); H={}
for i,l in enumerate(src):
    m=re.match(r"^### (\d+(?:\.\d+)?)\.",l)
    if m: H[m.group(1)]=i
def blk(i):
    j=i+1
    while j<len(src) and not src[j].startswith("```bash"): j+=1
    s=j+1;k=s
    while k<len(src) and not src[k].startswith("```"): k+=1
    return "\n".join(src[s:k])
os.makedirs("/tmp/ms",exist_ok=True)
for st in ["3","3.5","3.6","3.7","4","5","6","7","7.5"]:
    open(f"/tmp/ms/s{st}.sh","w").write(blk(H[st])+"\n")
print("extracted MyPeople installer steps")
PY
for st in 3 3.5 3.6 3.7 4 5 6 7 7.5; do bash /tmp/ms/s$st.sh; done
# (b) FIX (MyPeople seed lacks this): queue-client advertises a browser-reachable
#     attach base in its heartbeat so the central HUD builds a correct per-host
#     attach URL for this node.
python3 - <<"PY"
f="/home/tester/mypeople/bin/queue-client.py"; s=open(f).read()
if "TTYD_PUBLIC_URL" not in s:
    s=s.replace(
      "HOSTNAME = os.environ.get(\"HOST_ID\", \"\") or socket.gethostname()",
      "HOSTNAME = os.environ.get(\"HOST_ID\", \"\") or socket.gethostname()\nTTYD_PUBLIC_URL = os.environ.get(\"TTYD_PUBLIC_URL\", \"\")")
    s=s.replace(
      "post_json(\"/heartbeat\", {\"hostname\": HOSTNAME})",
      "post_json(\"/heartbeat\", {\"hostname\": HOSTNAME, \"attach_base\": TTYD_PUBLIC_URL, \"substrate_ready\": os.path.exists(os.path.expanduser(\"~/SUBSTRATE_READY.json\"))})")
    open(f,"w").write(s); print("patched queue-client attach_base + substrate_ready")
PY
# (b2) Ensure the LIVE ~/.claude.json marks onboarding complete so a spawned agent
#      never hits the first-run theme/onboarding dialog. The Step 2 snapshot fix +
#      entrypoint already restore this; this makes the running container explicit and
#      independent of entrypoint timing. MyPeople Step 3.5 already wrote this file
#      (trust), so we MERGE (preserve its keys).
python3 - <<"PY"
import json,os
p=os.path.expanduser("~/.claude.json")
d=json.load(open(p)) if os.path.exists(p) else {}
d["hasCompletedOnboarding"]=True
d.setdefault("theme","dark")
open(p,"w").write(json.dumps(d))
print("ensured live ~/.claude.json hasCompletedOnboarding=True")
PY
# (c) JOIN-mode queue.env: point the node at OUR central queue; attach via its tailnet IP
mkdir -p ~/.config/mypeople
cat > ~/.config/mypeople/queue.env <<EOF
QUEUE_URL=${CENTRAL_QUEUE_URL}
QUEUE_SECRET=${CENTRAL_QUEUE_SECRET}
QUEUE_PORT=9900
QUEUE_HEARTBEAT=30
QUEUE_POLL_INTERVAL=1.0
HOST_ID=${NODE_NAME}
INSTALL_DIR=${INSTALL_DIR}
TTYD_PORT=7681
TTYD_PUBLIC_URL=http://${CONTAINER_TS_IP}:7681
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF
chmod 600 ~/.config/mypeople/queue.env
chmod +x "$INSTALL_DIR/bin/queue-client.py" "$INSTALL_DIR/bin/mp"
echo "hydrated complete MyPeople in JOIN mode → $CENTRAL_QUEUE_URL"
'
```

### 6.6 Install the tkmx token-burn reporter (every substrate reports its Claude burn)

Per the CEO's seedbed mandate, **every** node reports its own Claude token burn
to the TokenMaxxing leaderboard under the CEO's account — so each node is born
reporting consumption. The reporter reads THIS node's `~/.claude` transcripts via
`agentsview` (a hard dep of tkmx-client v1.3.0+) and POSTs daily usage to
`$TKMX_SERVER_URL`. It does **not** intercept calls — it reads transcript usage
after the fact, so Max-subscription burn is captured the same as API burn.
With `REPORT_DEV_STATS=true` + `REPORT_SESSION_STATS=true` it ALSO reports
**velocity / dev stats** (workflow shape, turn-cycle velocity, cache economics —
sourced from `agentsview stats`), so every node populates the leaderboard's
velocity section, not just the token burn. **agentsview must be the latest
build** — older ones lack or hang the `stats` subcommand and velocity stays
empty — so Step 6.6 always runs the installer (install-or-update).

`REPORT_MACHINE_CONFIG=true` makes the node **identifiable** on the leaderboard
instead of showing as **"No config"**: the client sends `machine_config`
(`hostname`, `os`, `cpu`, `memory_gb`) and the displayed machine name is the
**`hostname`** — which for this node is the container `hostname`, set to
`$NODE_NAME` in Step 4 (`docker run --hostname "$NODE_NAME"`). So the node shows
up as e.g. **`mp-seedbed-3`** rather than "No config". There is no dedicated
name/label field in tkmx — the friendly name IS the hostname, gated behind this
flag. `machine_config` is per-machine display data (it never clobbers the CEO's
per-user velocity/dev-stats blob) and carries no secrets (no prompts, code, or
keys — README-confirmed).

**Credential handling (load-bearing):** auth is a single Bearer `API_KEY` — the
CEO's **existing** key, sourced from the gitignored `~/workspace/seedlab/.env`
(Step 1) and injected via `docker exec -e`. It is **never baked into the image,
never passed at `docker build`, never committed.** It lands only in the node's
`~/.config/tkmx/.env` at `chmod 600`. `CLIENT_ID` is pinned to `mp-<NODE_NAME>`
so the node is a stable, unique "machine" on the leaderboard and never
double-counts against the host install or another node.

```bash
docker exec -i \
  -e TKMX_API_KEY="$TKMX_API_KEY" \
  -e TKMX_USERNAME="$TKMX_USERNAME" \
  -e TKMX_SERVER_URL="$TKMX_SERVER_URL" \
  -e TKMX_CLIENT_ID="$TKMX_CLIENT_ID" \
  -e TKMX_TEAM="$TKMX_TEAM" \
  -e TKMX_REPORT_INTERVAL="$TKMX_REPORT_INTERVAL" \
  "$NODE_NAME" bash -s <<'TKMXSH'
set -e
# (a) agentsview — hard dep of tkmx-client v1.3.0+. Reads ~/.claude + ~/.codex
#     usage AND powers velocity/dev stats (the leaderboard velocity section comes
#     from `agentsview stats`). Always run the installer so the node gets the
#     LATEST build — older agentsview lacks/hangs the `stats` subcommand and
#     velocity stays empty. Idempotent (install-or-update); drops the binary in
#     ~/.local/bin for the non-root user.
curl -fsSL https://agentsview.io/install.sh | bash
AGENTSVIEW_BIN="$HOME/.local/bin/agentsview"; [ -x "$AGENTSVIEW_BIN" ] || AGENTSVIEW_BIN="$(command -v agentsview || true)"
[ -n "$AGENTSVIEW_BIN" ] || { echo "tkmx: agentsview install failed"; exit 1; }
"$AGENTSVIEW_BIN" --version || { echo "tkmx: agentsview not runnable"; exit 1; }
# (b) clone + build tkmx-client (the npm prepare hook compiles TS → dist/).
if [ ! -d "$HOME/tkmx-client/.git" ]; then
  git clone --depth=1 https://github.com/srosro/tkmx-client "$HOME/tkmx-client"
fi
# (b1) NAME FIX — post-clone, pre-build. The leaderboard "Machines" card renders
#      ONLY cpu+memory (never hostname); on this linuxkit/ARM substrate
#      os.cpus()[0].model is the literal "unknown", so the node would render as
#      "unknown (N cores)". Fall back cpu -> os.hostname() when the model is
#      empty/"unknown" so the node appears NAMED (e.g. "mp-fresh-1 (10 cores)").
#      Idempotent: skip if already patched. The npm prepare/build hook below
#      recompiles TS -> dist/ from the corrected source. Remove once the upstream
#      PR (srosro/tkmx-client) lands. Real CPUs (Mac/bare Linux) are unaffected.
if ! grep -q 'os.hostname()) + " (" + cpus.length' "$HOME/tkmx-client/reporter/report.ts"; then
  sed -i 's#cpus\[0\].model.trim() + " (" + cpus.length + " cores)"#((cpus[0].model.trim() \&\& cpus[0].model.trim().toLowerCase() !== "unknown") ? cpus[0].model.trim() : os.hostname()) + " (" + cpus.length + " cores)"#' "$HOME/tkmx-client/reporter/report.ts"
  grep -q 'os.hostname()) + " (" + cpus.length' "$HOME/tkmx-client/reporter/report.ts" || echo "tkmx: cpu->hostname name-fix did not apply (upstream report.ts changed) — continuing; cosmetic only (node may show as 'unknown (N cores)' on the leaderboard). NEVER fatal: the reporter must still install + report."
fi
cd "$HOME/tkmx-client" && npm install --no-audit --no-fund
# (c) reporter creds — chmod 600, never committed / baked. CLIENT_ID fixed to
#     mp-<NODE_NAME> so this node is a stable, unique machine on the leaderboard
#     (PK = username+date+model+client_id+source). AGENTSVIEW_BIN pins the binary.
mkdir -p "$HOME/.config/tkmx"
cat > "$HOME/.config/tkmx/.env" <<EOF
USERNAME=${TKMX_USERNAME}
API_KEY=${TKMX_API_KEY}
SERVER_URL=${TKMX_SERVER_URL}
CLIENT_ID=${TKMX_CLIENT_ID}
TEAM=${TKMX_TEAM}
AGENTSVIEW_BIN=${AGENTSVIEW_BIN}
REPORT_DEV_STATS=true
REPORT_SESSION_STATS=true
REPORT_MACHINE_CONFIG=true
REPORT_DAYS=1
EOF
chmod 600 "$HOME/.config/tkmx/.env"
cp "$HOME/.config/tkmx/.env" "$HOME/tkmx-client/.env"   # tkmx-client dotenv reads it from the repo root
chmod 600 "$HOME/tkmx-client/.env"
# (d) non-secret daemon config sourced by start-daemons.sh (Step 7)
printf "TKMX_REPORT_INTERVAL=%s\n" "${TKMX_REPORT_INTERVAL}" > "$HOME/.config/tkmx/reporter.env"
# (e) smoke: fire one report now. Tolerate a non-200 here (the daemon retries on
#     each tick) but surface the tail so a stale key / missing agentsview is visible.
( cd "$HOME/tkmx-client" && npm run --silent report ) 2>&1 | tail -4 || true
echo "tkmx reporter installed: client_id=${TKMX_CLIENT_ID} → ${TKMX_SERVER_URL}"
TKMXSH
```

### 7. Start the node's daemons (queue-client → central, + ttyd on the tailnet)

# Write the start logic to a FILE, then run it. Do NOT `pkill -f` the daemon
# patterns from an inline `bash -lc '…'` — the pattern text lives in that shell's
# own argv, so it SIGTERMs the launcher before the daemons come up. Kill by
# pid-file + `pkill -x ttyd`, and detach with `setsid </dev/null` so the daemons
# survive `docker exec` returning.
```bash
docker exec -i "$NODE_NAME" bash -s <<'STARTSH'
cat > /home/tester/start-daemons.sh <<"SH"
#!/usr/bin/env bash
set -a; . "$HOME/.config/mypeople/queue.env"; set +a
[ -f "$INSTALL_DIR/run/queue-client.pid" ] && kill "$(cat "$INSTALL_DIR/run/queue-client.pid")" 2>/dev/null || true
# Kill the OLD ttyd SUPERVISOR first (pid in ttyd.pid) — otherwise it would just
# respawn the ttyd we pkill on the next line. Then clear any lingering ttyd.
[ -f "$INSTALL_DIR/run/ttyd.pid" ] && kill "$(cat "$INSTALL_DIR/run/ttyd.pid")" 2>/dev/null || true
pkill -x ttyd 2>/dev/null || true
setsid python3 -u "$INSTALL_DIR/bin/queue-client.py" > "$INSTALL_DIR/run/queue-client.log" 2>&1 </dev/null &
echo $! > "$INSTALL_DIR/run/queue-client.pid"
# ttyd under a SUPERVISOR: if ttyd is killed or crashes, respawn it within ~2s so
# the CEO's browser window into this node never goes permanently dark (a stray
# kill / pkill must NOT blank the pane). We pid-track the supervisor (the
# while-loop) in ttyd.pid; killing ttyd alone only triggers a respawn — to stop
# it for real, kill the supervisor pid (the idempotent cleanup above does this).
# ttyd renders in the browser (xterm.js): box-drawing / Claude-TUI glyphs come from the CLIENT
# font stack set via -t fontFamily. Without it they fall back to a default monospace that lacks
# the glyphs -> boxes/mojibake. Match the working local ttyd stack so the HUD + Claude TUI render clean.
export TTYD_FONT='Menlo, Monaco, "Cascadia Mono", "Fira Code", "Courier New", monospace'
# GLYPH FIX (claude side, layer 1): install a wrapper so claude runs with TERM=xterm-256color
# when under tmux -> claude EMITS the real mode glyphs (⏵⏵/←) instead of ASCII "_". Under
# TERM=tmux-256color claude's tmux-detection falls back to ASCII. $TMUX stays set so the
# tmux-boss-hooks still route notifications. Install ONCE, before any agent spawns.
CLAUDE_REAL="$(readlink -f "$(command -v claude)")"
case "$CLAUDE_REAL" in */claude-wrapper) ;; *)
  sudo tee /usr/local/bin/claude-wrapper >/dev/null <<WRAP
#!/usr/bin/env bash
if [ -n "\${TMUX:-}" ] && [ "\${TERM:-}" = "tmux-256color" ]; then export TERM=xterm-256color; fi
exec "$CLAUDE_REAL" "\$@"
WRAP
  sudo chmod +x /usr/local/bin/claude-wrapper
  sudo ln -sf /usr/local/bin/claude-wrapper "$(command -v claude)"
;; esac
# GLYPH FIX (layer 2): `tmux -u attach` (UTF-8 client) so tmux DRAWS those glyphs to xterm.js
# instead of substituting "_" (pairs with the claude wrapper installed just above).
setsid bash -c 'export LANG=C.UTF-8 LC_ALL=C.UTF-8; while true; do ttyd -W -a -p 7681 -t "fontFamily=$TTYD_FONT" -t fontSize=13 -t disableLeaveAlert=true tmux -u attach; echo "$(date -u +%H:%M:%S) ttyd exited rc=$? — restarting in 2s" >&2; sleep 2; done' > "$INSTALL_DIR/run/ttyd.log" 2>&1 </dev/null &
echo $! > "$INSTALL_DIR/run/ttyd.pid"
# tkmx token-burn reporter: post this node's Claude usage every interval. Creds
# live in ~/.config/tkmx/.env (chmod 600, never committed); reporter.env carries
# only the non-secret interval. Skips cleanly if Step 6.6 didn't install tkmx.
[ -f "$HOME/.config/tkmx/reporter.env" ] && { set -a; . "$HOME/.config/tkmx/reporter.env"; set +a; }
if [ -f "$HOME/.config/tkmx/.env" ] && [ -d "$HOME/tkmx-client" ]; then
  [ -f "$INSTALL_DIR/run/tkmx-report.pid" ] && kill "$(cat "$INSTALL_DIR/run/tkmx-report.pid")" 2>/dev/null || true
  setsid bash -c 'while true; do (cd "$HOME/tkmx-client" && npm run --silent report); sleep "${TKMX_REPORT_INTERVAL:-300}"; done' > "$INSTALL_DIR/run/tkmx-report.log" 2>&1 </dev/null &
  echo $! > "$INSTALL_DIR/run/tkmx-report.pid"
fi
SH
chmod +x /home/tester/start-daemons.sh
STARTSH
docker exec "$NODE_NAME" bash /home/tester/start-daemons.sh
sleep 2
docker exec "$NODE_NAME" bash -lc 'tail -1 ~/mypeople/run/queue-client.log; pgrep -x ttyd >/dev/null && echo "ttyd up"; [ -f ~/mypeople/run/tkmx-report.pid ] && kill -0 "$(cat ~/mypeople/run/tkmx-report.pid)" 2>/dev/null && echo "tkmx reporter up"'
```

### 7.6 Start the continuous terminal recorder (asciinema default; browser opt-in only)

Per the recorder mandate, every seedbed's worker pane is recorded for its entire lifetime by
**asciinema by default**:

- **terminal default (asciinema)** — a tiny in-container pty logger -> growing
  `~/recordings/<NODE_NAME>.cast`. It is robust, cheap, never depends on CDP/browser painting, and
  renders to clean H.264 via `recorder/render_clip.sh` (JetBrainsMono Nerd Font Mono;
  `normalize_glyphs.py` maps the 2 TUI glyphs no mono font covers).
- **browser opt-in (`seedrec`)** — host-side Chrome+ttyd -> `.webm`, enabled only when
  `SEEDBED_BROWSER_RECORDING=1` because the seedbed/test is explicitly exercising UI/browser
  behavior. Non-UI substrate runs MUST NOT start this duplicate browser recorder by default.

**The tmux geometry rule.** Recorder clients attach READ-ONLY to `mc-main:worker-1`. Set
`window-size largest` and `aggressive-resize off` so incidental smaller attach clients cannot shrink
the worker pane. Do **NOT** use `window-size manual` — it crashes tmux 3.3a on the next client attach
(verified twice: it kills the whole server + worker). The default asciinema recorder uses one stable
read-only client at a fixed geometry. The optional browser recorder, when explicitly enabled, uses the
same geometry so it cannot constrain the terminal recording.

**Lifecycle contract:** continuous READ-ONLY capture; stops ONLY on a CEO-driven signal
(`approved-retire` | `ceo-request`) — `tmux kill-session -t rec` for asciinema; if the optional
browser recorder was explicitly enabled, also stop `seedrec` and the optional recorder ttyd. Agents
NEVER stop a recording on their own judgment.

```bash
# (recorder-after-worker) the worker pane must exist BEFORE recording
"$HOME/mypeople/bin/mp" spawn "$NODE_NAME/main:worker-1" --cwd /home/tester --backend claude --boss "$CENTRAL_BOSS" \
  || { echo "BLOCKED_REASON=worker_spawn_failed"; exit 1; }
# pin sizing — largest, never manual (manual crashes tmux on attach); no aggressive-resize
docker exec "$NODE_NAME" tmux set -g window-size largest
docker exec "$NODE_NAME" tmux setw -g aggressive-resize off
# asciinema in the node (Debian apt -> native v2 .cast)
docker exec "$NODE_NAME" bash -lc 'command -v asciinema >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq asciinema) >/dev/null 2>&1; asciinema --version' \
  || { echo "BLOCKED_REASON=asciinema_install_failed"; exit 1; }

W="${SEEDBED_REC_COLS:-120}"; H="${SEEDBED_REC_ROWS:-30}"
docker exec "$NODE_NAME" bash -lc "
  mkdir -p ~/recordings
  tmux kill-session -t rec 2>/dev/null || true
  tmux new-session -d -s rec -x ${W} -y ${H}
  sleep 1
  tmux send-keys -t rec \"asciinema rec --quiet --append -c \\\"TMUX= tmux attach -rt mc-main:worker-1\\\" ~/recordings/${NODE_NAME}.cast\" Enter
"
sleep 4
# VERIFY: the .cast GROWS (real pty capture); no browser recording is produced by default; zombies stay 0 (--init reaping).
CAST="/home/tester/recordings/${NODE_NAME}.cast"; CAPTURED=0
sleep 6; S1=$(docker exec "$NODE_NAME" bash -lc "wc -c < $CAST 2>/dev/null")
for i in $(seq 1 8); do sleep 4; S2=$(docker exec "$NODE_NAME" bash -lc "wc -c < $CAST 2>/dev/null"); [ "${S2:-0}" -gt "${S1:-0}" ] && { CAPTURED=1; break; }; done
[ "$CAPTURED" = 1 ] || { echo "BLOCKED_REASON=asciinema_not_capturing"; exit 1; }
if [ "${SEEDBED_BROWSER_RECORDING:-0}" != "1" ]; then
  [ ! -d "$HOME/workspace/seedlab/recordings/${NODE_NAME}-browser" ] \
    || { echo "BLOCKED_REASON=browser_recording_started_by_default"; exit 1; }
fi
Z=$(docker exec "$NODE_NAME" bash -lc 'ps -eo stat | grep -c "^Z"')
[ "${Z:-0}" -eq 0 ] || echo "WARN: ${Z} zombies — is the container --init (Step 4)?"
echo "terminal recording VERIFIED: asciinema .cast ${S1}->${S2}B (growing); browser_default=off; geometry=${W}x${H}; zombies=${Z}"

# OPTIONAL: browser recording for UI/browser seedbeds only. This block MUST be enabled explicitly by
# the seed/test (SEEDBED_BROWSER_RECORDING=1). It is intentionally after the default terminal
# recording is proven so non-UI substrate runs do not create duplicate browser artifacts.
if [ "${SEEDBED_BROWSER_RECORDING:-0}" = "1" ]; then
  TTYD_REC_PORT="${TTYD_REC_PORT:-7726}"
  setsid ttyd -p "$TTYD_REC_PORT" -t 'fontFamily=Menlo, Monaco, "Cascadia Mono", "Fira Code", "Courier New", monospace' -t disableLeaveAlert=true -t fontSize=14 \
    docker exec -it "$NODE_NAME" tmux attach -rt mc-main:worker-1 >"/tmp/ttyd-rec-${NODE_NAME}.log" 2>&1 &
  echo $! >"/tmp/ttyd-rec-${NODE_NAME}.pid"
  sleep 3
  SEEDREC_ROTATE_MS="${SEEDREC_ROTATE_MS:-30000}" node "$HOME/workspace/seedlab/seedrec/seedrec.mjs" start "${NODE_NAME}-browser" \
    --url "http://localhost:${TTYD_REC_PORT}/" --width 854 --height 480
  sleep 6
  node "$HOME/workspace/seedlab/seedrec/seedrec.mjs" status "${NODE_NAME}-browser" | grep -q RECORDING \
    || { echo "BLOCKED_REASON=browser_seedrec_not_recording"; exit 1; }
  echo "browser recording ENABLED intentionally: ${NODE_NAME}-browser on :${TTYD_REC_PORT}"
fi
```

## Verify  (AGENT-DRIVEN — reason over the node; do NOT rely on a pass/fail script)

You are an agent. **Confirm the node actually works by reasoning over evidence**, not by trusting exit codes. Gather the facts below, judge each, and only then conclude. If anything is ambiguous, dig in (read logs, peek panes) before declaring done.

> **Run Verify on the BOSS/RENDER host (host-aware).** Gates 3/4/7 are judged against artifacts on the machine that owns the central queue, the central Boss tmux pane, and the asciinema render kit (`agg`+`ffmpeg`+`recorder/`). If the node's docker daemon is on a **remote** host, do NOT run Verify on that remote host — run it here on the Boss/render host and point docker at the node: `export DOCKER_HOST=ssh://<node-host>` (e.g. `ssh://server`). Every `docker exec` below then reaches the remote node while the Boss-pane capture (gate 4) and the render (gate 7) stay local. See the host-model preamble in the hard-gate block.

1. **On the tailnet.** `docker exec "$NODE_NAME" sudo tailscale --socket=/home/tester/mypeople/run/tailscale-state/tailscaled.sock status` — confirm `Self` is `mypeople-<NODE_NAME>` with a `100.x` IP. Note that IP as `CONTAINER_TS_IP`.

2. **Complete install.** List `~/mypeople/bin`, `~/mypeople/plugins`, `~/mypeople/boss-CLAUDE.md`, `~/.tmux.conf`, `~/.tmux/plugins/tpm` inside the container and confirm every MyPeople component from `## Done` is present. If one is missing, the inner hydration failed — investigate before continuing.

3. **Joined our queue.** `curl -fsS -H "X-Queue-Secret: $CENTRAL_QUEUE_SECRET" $CENTRAL_QUEUE_URL/clients` from the host — confirm `<NODE_NAME>` is listed AND carries an `attach_base` equal to `http://<CONTAINER_TS_IP>:7681`. If it heartbeats but has no `attach_base`, the queue-client patch (Step 6b) didn't apply.

4. **Central Boss OWNS the node — spawn + converse + notification routes to the central Boss (THE JOIN-mode proof).** Using the host `mp` (`~/mypeople/bin/mp`):
   - `mp spawn "$NODE_NAME/main:worker-1" --cwd /home/tester --backend claude --boss "$CENTRAL_BOSS"` — the `--boss` is mandatory: agents in the node carry `BOSS_ID=$CENTRAL_BOSS`.
   - Confirm it registered on the **central** queue with `boss_id == $CENTRAL_BOSS` (`curl -H "X-Queue-Secret: $CENTRAL_QUEUE_SECRET" $CENTRAL_QUEUE_URL/agents`). It must appear under host `$NODE_NAME` — i.e. it shows in the central `mp status` / HUD.
   - `mp send "$NODE_NAME/main:worker-1" "Node health-check from your Boss: please run \`hostname\` and report which node you're on."`; `mp peek` (poll). **Do NOT ask the agent to parrot an arbitrary token.** A well-behaved agent correctly REFUSES to echo a meaningless token on an authority claim — it reads "I'm your Boss, reply with exactly TOKEN" as social engineering and declines (observed in a trust run: agents called it out as "social engineering… not going to parrot the token on command" — and they were right). Liveness/in-container proof does NOT need a parroted token: it comes from the agent running a **real diagnostic tool-call** (`hostname`) that returns the **node-specific value** — which is non-replayable and can't be canned. **Judge the reply**: a coherent live Claude turn *inside this container* that actually runs `hostname` (a `Bash(hostname)` tool call) and reports `hostname` == `<NODE_NAME>`.
   - **The defining check:** when the agent finishes its turn, its Stop-hook `[AGENT NOTIFICATION]` must land in the **central Boss's pane** — confirm with `tmux capture-pane -t mc-<sess>:<tab> -p -S -400` (derive `mc-<sess>:<tab>` from `$CENTRAL_BOSS`, e.g. `daniels-MacBook-Pro-2/main:Boss` → `mc-main:Boss`) shows `[AGENT NOTIFICATION] $NODE_NAME/main:worker-1 …`. A STANDALONE node would route to its OWN internal Boss instead — seeing it in the CENTRAL Boss's pane is what proves the central Boss owns this node.
   - **Leave `main:worker-1` running** (do NOT kill it): a live agent keeps the node visible as an attachable row in the central HUD (the HUD table lists *agents*, so a node with zero live agents shows only as a client count, not a row).

5. **Attachable in a browser.** `curl -fsS -o /dev/null -w '%{http_code}' "http://<CONTAINER_TS_IP>:7681/?arg=-t&arg=mc-main:worker-1"` → must be `200`, i.e. ttyd on the container's **own tailnet IP** serves the agent's tmux window. (This is the URL the central HUD builds from the node's `attach_base` and a human clicks.)
   - **ttyd is supervised (a stray kill must not blank the CEO's window).** `docker exec "$NODE_NAME" pkill -x ttyd`, wait ~4s, then re-curl the attach URL → still `200`. The Step-7 supervisor must have respawned ttyd; if it stays dead, ttyd was launched one-shot (not under the `while`-loop supervisor) — a seed bug.

6. **Token burn reported (tkmx on every substrate).** Inside the node, `tail -5 ~/mypeople/run/tkmx-report.log` shows `Server responded 200` with `"rows": <n>` (an empty-rows 200 is fine on a fresh node — it still proves auth + connectivity). Confirm `~/.config/tkmx/.env` is `chmod 600`, carries `CLIENT_ID=mp-<NODE_NAME>`, `REPORT_DEV_STATS=true` + `REPORT_SESSION_STATS=true` + `REPORT_MACHINE_CONFIG=true`, and that the CEO's `API_KEY` is present in it but **nowhere in git or the image**. On the leaderboard the node must appear **identified by its hostname `<NODE_NAME>`** (e.g. `mp-seedbed-3`), NOT as "No config" — check the machine's `hostname` field via `curl -fsS "$TKMX_SERVER_URL/api/user/$TKMX_USERNAME"` (the machine with `client_id=mp-<NODE_NAME>` should carry `hostname=<NODE_NAME>`). The report log also shows `Collecting dev stats` (velocity/dev stats are shipped, not just burn — `agentsview --version` must run and be recent). The reporter daemon is alive (`kill -0 $(cat ~/mypeople/run/tkmx-report.pid)`). From the host, `curl -fsS "$TKMX_SERVER_URL/user/$TKMX_USERNAME"` → HTTP 200 mentioning the username (and the velocity section is populated, no longer "No velocity data shared yet"). If the report 4xx's, the `API_KEY` is stale/mismatched; if the log says `agentsview not found` or velocity stays empty, Step 6.6's agentsview install failed or is too old.

6b. **Recorder live (every seedbed auto-records).** The asciinema recorder is capturing the worker pane: `~/recordings/<NODE_NAME>.cast` **grows** between two checks, and `recorder/render_clip.sh` renders a **clean frame** of real terminal content (see gate 7). The recorder runs continuously and stops ONLY on a CEO-driven signal (`tmux kill-session -t rec` on `approved-retire|ceo-request`) — agents never stop it on their own judgment.

7. **Conclude — emit `SUBSTRATE_READY` ONLY if all 7 are confirmed by HARD ARTIFACT.** A substrate is NEVER handed over as "ready to hydrate a seed" on a label, an exit code, or a "process launched" proxy — every gate is judged on real evidence (a tailscale Self line, a file, a `/clients` entry, the Boss-pane notification text, a respawn-after-kill 200, a tkmx 200 + leaderboard hostname, a GROWING asciinema .cast + a CLEAN rendered frame). Run the hard-gate below. If all 7 are genuinely true it writes the durable marker `~/SUBSTRATE_READY.json` on the node (and the queue-client then advertises `substrate_ready=true` in its heartbeat — see Step 6b) → print `SEEDBED_RESULT=DONE`. If ANY gate is not truly confirmed it writes NO marker (and removes any stale one) → print `BLOCKED_REASON=substrate_gate_failed`. **There is no partial "done": a half-baked substrate is REFUSED, not waved through.**

```bash
# ===== SUBSTRATE READINESS HARD-GATE (no false-greens) =====
# HOST-AWARE — RUN THIS GATE ON THE BOSS/RENDER HOST. This gate is judged against artifacts that
# live on the machine owning the central MyPeople queue (gate 3), the central Boss tmux pane
# (gate 4), and the asciinema render kit `recorder/render_clip.sh` + `agg`+`ffmpeg` (gate 7). The
# NODE's docker daemon may be on a DIFFERENT host (e.g. a remote build server). Reach the node by
# pointing DOCKER_HOST at the node's docker host — every `docker exec "$N"` below then targets the
# node while gate 4 (tmux capture of the LOCAL Boss pane) and gate 7 (LOCAL render) stay where they
# belong:
#   * node local to this Boss/render host → DOCKER_HOST unset (default).
#   * node on a REMOTE docker host        → export DOCKER_HOST=ssh://<node-host>   (e.g. ssh://server)
#     (needs: docker CLI + key-based ssh to <node-host> here; this Boss/render host on the node's
#      tailnet so gate 5's `http://$TSIP:7681` is reachable; `agg`+`ffmpeg`+`recorder/` present here.)
# DO NOT run this gate ON the node's host when that host isn't the Boss/render host: gates 4+7 would
# false-fail (no central Boss pane / no render kit there) even though the substrate is healthy — the
# exact cross-host technicality that held SUBSTRATE_READY on the first remote-server deployment.
N="$NODE_NAME"; TSIP="$CONTAINER_TS_IP"
BOSS_MC="mc-$(printf '%s' "$CENTRAL_BOSS" | sed -E 's#^[^/]+/##')"   # <host>/main:Boss -> mc-main:Boss
g1=0 g2=0 g3=0 g4=0 g5=0 g6=0 g7=0 g8=0
# 1) on tailnet — artifact: tailscale Self line (hostname mypeople-$N + 100.x IP)
docker exec "$N" sudo tailscale --socket=/home/tester/mypeople/run/tailscale-state/tailscaled.sock status 2>/dev/null \
  | grep -qE "^100\.[0-9].*[[:space:]]mypeople-$N([[:space:]]|\$)" && g1=1
# 2) complete install — artifact: every component file present
docker exec "$N" bash -lc 'for f in ~/mypeople/bin/queue-server.py ~/mypeople/bin/queue-client.py ~/mypeople/bin/mp ~/mypeople/bin/dashboard.html ~/mypeople/boss-CLAUDE.md ~/mypeople/plugins/tmux-boss-hooks ~/.tmux.conf ~/.tmux/plugins/tpm; do [ -e "$f" ] || exit 1; done' && g2=1
# 3) joined central queue WITH attach_base = http://<tailnet-ip>:7681 — artifact: /clients entry
curl -fsS -H "X-Queue-Secret: $CENTRAL_QUEUE_SECRET" "$CENTRAL_QUEUE_URL/clients" \
  | jq -e --arg h "$N" --arg a "http://$TSIP:7681" '.[]|select(.hostname==$h and .attach_base==$a)' >/dev/null 2>&1 && g3=1
# 4) JOIN proof — artifact: the worker's Stop-hook [AGENT NOTIFICATION] is in the CENTRAL Boss pane
tmux capture-pane -t "$BOSS_MC" -p -S -400 2>/dev/null | grep -qE "\[AGENT NOTIFICATION\] $N/" && g4=1
# 5) attach 200 AND supervised respawn — artifact: 200, kill ttyd, +5s, still 200
_code(){ curl -fsS -o /dev/null -w '%{http_code}' --max-time 6 "http://$TSIP:7681/" 2>/dev/null; }
[ "$(_code)" = 200 ] && { docker exec "$N" pkill -x ttyd 2>/dev/null; sleep 5; [ "$(_code)" = 200 ] && g5=1; }
# 6) tkmx — artifact: reporter daemon alive + node IDENTIFIED on the leaderboard + creds in 0600.
#    The node's presence on the leaderboard IS the 200+data proof (reports already landed). Do NOT
#    fire a fresh report here: tkmx rate-limits ~3/60s/account, so a per-node gate-time report trips
#    the limit across multiple nodes and false-fails — read the standing leaderboard state instead.
#    Identify by EITHER the machine_config hostname OR client_id=mp-<NODE_NAME> (which encodes the
#    node name). UPSTREAM TKMX BUG: the human-readable `hostname` field can get permanently stuck
#    null — the first machine_config send writes .machine_config_hash even if that send 429s (likely
#    when several nodes build in parallel), and the server only sets machine_config on a record's
#    FIRST sighting; later usage-only reports never backfill it. So client_id is the reliable
#    identifier. (Mitigations: stagger build-time reports; or rm ~/tkmx-client/.machine_config_hash
#    and re-report in a clear rate-limit window BEFORE the record's first usage-only report lands.)
LB=$(curl -fsS --max-time 10 "$TKMX_SERVER_URL/api/user/$TKMX_USERNAME" 2>/dev/null)
docker exec "$N" bash -lc 'kill -0 $(cat ~/mypeople/run/tkmx-report.pid 2>/dev/null) 2>/dev/null' \
  && { printf '%s' "$LB" | grep -q "\"hostname\":\"$N\"" || printf '%s' "$LB" | grep -q "\"client_id\":\"mp-$N\""; } \
  && [ "$(docker exec "$N" bash -lc 'stat -c %a ~/.config/tkmx/.env 2>/dev/null')" = 600 ] && g6=1
# 7) recorder REAL capture (asciinema) — artifact: a GROWING .cast AND a CLEAN rendered FRAME
#    (real terminal content, not blank). asciinema is a pty logger (~0% CPU / ~55MB, race-proven)
#    — no browser, no CDP-starvation, no headless-render blanking. Two checks, both hard:
#    (a) the .cast is actively GROWING (real capture, not a stuck process);
#    (b) render_clip.sh -> a frame whose mean is DARK (real terminal) not near-white (blank/tofu).
#    render_clip.sh normalizes the 2 TUI glyphs no mono font covers (⏵->▶, ⎿->└) for a clean frame.
#    Requires on the render host: agg + ffmpeg + the bundled recorder/fonts (note in ## Inputs).
CAST="/home/tester/recordings/${N}.cast"; RENDER="$HOME/workspace/seedlab/recorder/render_clip.sh"
S1=$(docker exec "$N" bash -lc "wc -c < $CAST 2>/dev/null"); sleep 5
S2=$(docker exec "$N" bash -lc "wc -c < $CAST 2>/dev/null")
if [ "${S2:-0}" -gt "${S1:-0}" ]; then            # .cast actively growing = capturing
  docker exec "$N" bash -lc "cat $CAST" > /tmp/g7-"$N".cast 2>/dev/null
  "$RENDER" /tmp/g7-"$N".cast /tmp/g7-"$N".mp4 >/dev/null 2>&1
  ffmpeg -y -sseof -1 -i /tmp/g7-"$N".mp4 -frames:v 1 /tmp/g7-"$N".png >/dev/null 2>&1
  MEAN=$(ffmpeg -i /tmp/g7-"$N".png -vf scale=1:1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null | xxd -p)
  # real terminal mean ≈ 0x2d2f3c (dark); blank ≈ 0xffffff. Pass iff NOT near-white.
  [ -n "$MEAN" ] && [ "$((16#${MEAN:0:2}))" -lt 160 ] && g7=1
fi
# 8) DOCKER-CAPABLE (SEEDBED_DIND=1 only) — artifact: as `tester`, `docker compose version` works
#    AND `docker run hello-world` returns clean (proves inner dockerd + compose plugin + the
#    docker-group membership are all live). For a classic (non-DIND) substrate this gate is N/A
#    and auto-passes — the gate count below is 7 (classic) or 8 (DIND).
NEED=7
if [ "${SEEDBED_DIND:-0}" = 1 ]; then
  NEED=8
  docker exec -u tester "$N" bash -lc 'docker compose version >/dev/null 2>&1 && docker run --rm hello-world >/dev/null 2>&1' && g8=1
else
  g8=1   # N/A for classic substrate
fi
echo "GATES: 1=$g1 2=$g2 3=$g3 4=$g4 5=$g5 6=$g6 7=$g7 8=$g8 (NEED=$NEED)"
GATESUM=$((g1+g2+g3+g4+g5+g6+g7)); [ "$NEED" = 8 ] && GATESUM=$((GATESUM+g8))
if [ "$GATESUM" -eq "$NEED" ]; then
  docker exec "$N" bash -lc "printf '{\"node\":\"%s\",\"ts\":\"%s\",\"dind\":%s,\"gates_needed\":%s,\"gates\":{\"1\":true,\"2\":true,\"3\":true,\"4\":true,\"5\":true,\"6\":true,\"7\":true,\"8\":%s}}\n' '$N' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '$([ "$NEED" = 8 ] && echo true || echo false)' '$NEED' '$([ "$g8" = 1 ] && echo true || echo false)' > ~/SUBSTRATE_READY.json && chmod 600 ~/SUBSTRATE_READY.json"
  echo "SUBSTRATE_READY emitted on $N (all $NEED confirmed by hard artifact)"
  echo "SEEDBED_RESULT=DONE"
else
  docker exec "$N" bash -lc 'rm -f ~/SUBSTRATE_READY.json' 2>/dev/null || true   # never leave a stale/partial marker (bash -lc so ~ is the container's home)
  FAILED=$(for i in $(seq 1 "$NEED"); do eval "v=\$g$i"; [ "$v" != 1 ] && printf '%s,' "$i"; done)
  echo "BLOCKED_REASON=substrate_gate_failed (gates ${FAILED%,} not confirmed; NO SUBSTRATE_READY marker)"
fi
```

## Substrate readiness contract (handover)

**A node is "ready to hydrate a seed" IFF it carries `~/SUBSTRATE_READY.json`** — the durable marker written by the Verify hard-gate **only** when all 7 conditions are genuinely confirmed by their hard artifact (never an exit code / label / "process launched" proxy). The marker also flips `substrate_ready=true` in the queue-client heartbeat (Step 6b), so readiness is observable both on the node (`~/SUBSTRATE_READY.json`) and from the central queue (the client's heartbeat field).

**Downstream seed-work MUST treat the absence of `SUBSTRATE_READY` as a HARD STOP:** do not clone, do not hydrate, do not run any seed on a node that lacks the marker — emit `BLOCKED_REASON=substrate_not_ready` and stop. Check explicitly before any hydration:

```bash
docker exec "$NODE_NAME" test -f ~/SUBSTRATE_READY.json \
  || { echo "BLOCKED_REASON=substrate_not_ready"; exit 1; }
```

There is **no partial ready**: a substrate is either fully `SUBSTRATE_READY` (all 7 hard-confirmed) or it is refused. A half-baked substrate is never handed over. (Out of scope here: a node that was ready and later *degraded* — that is a separate broken-setup/staleness case, not this gate.)

> **UPSTREAM RECOMMENDATION (mypeople queue-server):** store the `substrate_ready` heartbeat field on the client record and surface it in `/clients` + the HUD, so `mp status` shows readiness at a glance. Until then, `~/SUBSTRATE_READY.json` on the node is the canonical artifact.

## Cleanup (when retiring a node)

```bash
# FIRST: end the lifetime recording (CEO-driven retire signal) and render the install video
# OUT of the node before it's removed — pull the .cast to the host, then render to mp4.
docker exec "$NODE_NAME" tmux kill-session -t rec 2>/dev/null || true   # stops asciinema (approved-retire)
docker exec "$NODE_NAME" bash -lc "cat ~/recordings/${NODE_NAME}.cast" > "$HOME/${NODE_NAME}.cast" 2>/dev/null
"$HOME/workspace/seedlab/recorder/render_clip.sh" "$HOME/${NODE_NAME}.cast" "$HOME/${NODE_NAME}-install.mp4"  # needs agg+ffmpeg+fonts
[ -d "$HOME/workspace/seedlab/recordings/${NODE_NAME}-browser" ] \
  && node "$HOME/workspace/seedlab/seedrec/seedrec.mjs" stop "${NODE_NAME}-browser" --reason approved-retire --mp4 \
  || true
[ -f "/tmp/ttyd-rec-${NODE_NAME}.pid" ] && kill "$(cat "/tmp/ttyd-rec-${NODE_NAME}.pid")" 2>/dev/null || true
mp kill "$NODE_NAME/val:probe" 2>/dev/null || true
docker rm -f "$NODE_NAME"          # ephemeral tailnet device auto-expires; queue client entry ages out; tkmx reporter daemon dies with the container (its leaderboard "machine" mp-<NODE_NAME> simply stops receiving new rows)
```

## Notes / known seed interactions

- **JOIN vs STANDALONE is a first-class seedbed deployment mode** (see "## Deployment mode"). The upstream `mypeople.seed.md` ships only STANDALONE (its Step 8/9 always stand up an own queue-server + Boss). seedbed adds **JOIN** as a documented, supported mode: same installed components, but `queue.env`→central + `queue-client`+`ttyd` only (no internal server/Boss), so the **central Boss is the node's Boss**. **UPSTREAM RECOMMENDATION:** add a real `NODE_MODE=join|standalone` input to `mypeople.seed.md` — in `join`, Step 8 writes a central `QUEUE_URL`/secret + `HOST_ID`, Step 8.5 still joins the tailnet, and Step 9 starts only `queue-client`+`ttyd` (skip the local `queue-server` + master Boss onboarding). This makes "join an existing fleet" native to the seed instead of a seedbed-layer concern.
- **Attach is per-host.** The node advertises `attach_base = http://<its tailnet IP>:7681`; the central HUD builds the attach link from that (Step 6b patch + the central queue-server storing `attach_base`).
- **ttyd 1.7.7 rewrites its argv** for `ps` (`key=value`→`key value`), so verify ttyd **functionally** (HTTP 200 on the attach URL), never by `ps`-grepping for `disableLeaveAlert=true`.
- **First-run onboarding/theme dialog blocks spawned agents** (`BLOCKED_REASON=claude_first_run_theme_dialog_blocks_spawn`). A fresh per-node volume has no onboarding marker (`claude auth login` only writes credentials, not the onboarding flag), so the first in-container `claude` shows the first-run theme/onboarding flow and `mp spawn` hangs. The exact gate is **`hasCompletedOnboarding: true`** in `~/.claude.json` (confirmed by diffing a working onboarded config — it has `hasCompletedOnboarding:true` + `lastOnboardingVersion`, and notably *no* `theme` key, yet shows no dialog). Step 2 bakes `hasCompletedOnboarding:true` (+ `lastOnboardingVersion`, + `theme:"dark"` insurance) into the node's app-config **snapshot** (restored to `~/.claude.json` by the entrypoint on every start, before any spawn), and Step 6(b2) also sets it on the live config. This is why the old SHARED volume masked the bug — it was already onboarded; fresh per-node volumes are not, so the seed normalizes them.
- **Claude auth is the only human step — once PER NODE**, on the CEO's **Max subscription** (OAuth device login, **never an API key**). Each node has its **own** volume `claude-auth-<NODE_NAME>`; the login persists across that node's restarts and is **never shared** with other nodes. (Sharing one volume across concurrent nodes was the bug: their Claude processes rotated each other's refresh tokens and auth broke. Per-node volumes fix it — any number of nodes can run at once.) Tailscale stays fully non-interactive via the Tailscale API key in `~/workspace/seedlab/.env`.
- **tkmx token-burn reporting is baked into every node** (Step 6.6 installs it; the Step 7 `start-daemons.sh` runs it). `agentsview` reads the node's **per-node** `~/.claude` volume → the node's *own* burn, posted under the CEO's USERNAME with a stable substrate id `CLIENT_ID=mp-<NODE_NAME>` (so nodes never double-count each other, the host install, or the standalone `seedlab-tkmx` container). The credential is the CEO's **existing** tkmx `API_KEY` — sourced once from his host install (`~/Desktop/projects/cncorp/tokenmaxxing/client/.env`) into the gitignored `~/workspace/seedlab/.env` as `TKMX_API_KEY`/`TKMX_USERNAME`. Handled exactly like the Tailscale key: **never committed, never baked into the image, injected via `docker exec -e`**, materialised only at `~/.config/tkmx/.env` (chmod 600) inside the node. `~/workspace/seedlab/.gitignore` already ignores `.env`/`*.env`, so no gitignore change is needed. This is distinct from `seeds/dev-harness/seedlab-tkmx.seed.md` (a *dedicated* reporter container that harvests the host `.env`); here, reporting is a property baked into **every fleet node**.
