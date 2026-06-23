# RUNBOOK — create / use / kill a substrate

The one canonical page for **operating** substrates. (The *why* lives in
[`PLAN.md`](./PLAN.md); the *what-is-ready* contract lives in [`README.md`](./README.md).)

Three commands. Run on the docker host (or with `DOCKER_HOST` pointed at it).

## 0. One-time setup (host, gitignored — never committed)

```sh
# runtime secrets, injected at spin via -e (never baked into the image)
~/.config/seedbed/substrate.env   # TAILSCALE_API_KEY, CENTRAL_QUEUE_*, TKMX_*  (chmod 600)
bank/bank.env                     # BANK_FILE / SEEDBED_LEASE_DIR / GOLDEN_IMAGE pointers
```

Template + which file holds what: [`config.env.example`](./config.env.example). The bank is
10 **pre-authed** Claude volumes (`bank/volumes.txt`) — live host state, see README caveats.

## 1. CREATE the golden image (build once; rebuild only when the seed/folds change)

```sh
pipeline/bake-golden.sh [base-image] [out-tag]
#   base-image  default: seedbed-golden:0.1-local   (snapshot of a SUBSTRATE_READY node)
#   out-tag     default: seedbed-golden:latest
```

Produces `seedbed-golden:latest` — a pre-hydrated seed snapshot with all folds baked
(fast-boot entrypoint, glyph fixes, tkmx, asciinema). You do **not** rebuild to spin more
substrates; you rebuild only when the seed or a fold changes.

## 2. USE — spin substrates from the golden image (the everyday command)

```sh
# A) spin N, each leases a distinct auth volume, wait until SUBSTRATE_READY:
bin/spin.sh <N> [name-prefix]          # prefix default: sub  ->  sub-1..sub-N

# B) spin N AND spawn a live Boss claude in each + print attach URL + timing:
bin/provision.sh <N> [name-prefix]     # this is the "5-ready-in-~16s" path
```

`provision.sh` prints, per substrate: `READY <s>  http://<tailnet-ip>:7681/`.

**Use it** — attach in a browser to that `:7681` URL (ttyd) to watch/drive the substrate's
Boss; or `docker exec <name> ...` on the host. Each substrate is on the tailnet and joined to
the central queue, so it also appears to the central Boss / mp grid.

```sh
bin/verify-acceptance.sh [prefix]      # optional: run the CEO acceptance gates with captured proof
```

## 3. KILL — tear a substrate down (container dies, auth volume is kept)

```sh
bin/teardown.sh <name> [<name> ...]    # specific containers
bin/teardown.sh --prefix <prefix>      # all <prefix>-* containers
```

Destroys the container, **keeps** the auth volume, and **releases the lease** back to the bank
(free for the next spin). Never deletes a volume — containers are ephemeral, volumes durable.

---

### Quickstart (copy-paste)

```sh
pipeline/bake-golden.sh                 # 1. build golden image  (once)
bin/provision.sh 5                      # 2. spin 5 -> READY + attach URLs
#    ... open http://<ip>:7681/ , or docker exec sub-1 ... ...
bin/teardown.sh --prefix sub            # 3. kill all 5 (volumes kept, leases freed)
```
