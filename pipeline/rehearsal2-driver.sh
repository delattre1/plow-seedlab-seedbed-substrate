#!/usr/bin/env bash
# ============================================================================
# rehearsal2-driver.sh — FULLY HANDS-OFF blind core-hydrate rehearsal (2026-07-02).
#
# ONE autonomous invocation does the whole cycle with ZERO manual kicks, implementing
# the folded contracts ITSELF (no external band-aids):
#   lease authed volume -> mint TS_AUTHKEY HOST-SIDE (sidesteps in-node DNS) -> spin
#   disposable inner-base:clean -> pre-set claude onboarding/trust flags -> record the
#   hydrate in a tmux pane via asciinema -> deliver seed -> blind claude drives to
#   SEED_RESULT (H3: markers visible live in the recorded pane; H4: flags pre-set so
#   NO trust/onboarding dialog) -> SELF-HEARTBEAT progress loop (H5, never idle,
#   auto-report) -> SUBSTRATE_READY 7-gate (H6 stable-200, H7 socket-pinned) ->
#   AUTO-FLUSH the cast off-node BEFORE teardown (H-NEW) -> auto-teardown (rm + release
#   lease) -> AUTO-POST the result to the card. Logs "manual kicks needed: N".
#
# Run: rehearsal2-driver.sh <SEED_PATH> <OUTDIR> <CARD_ID>
# Env: sources ~/.config/seedbed/substrate.env (lease dir, bank, DOCKER_HOST, TS/CQ/TKMX keys)
# ============================================================================
set -uo pipefail
SEED="${1:?seed path}"; OUTDIR="${2:?outdir}"; CARD="${3:?card id}"
mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
LOG="$OUTDIR/driver.log"; exec > >(tee -a "$LOG") 2>&1
ts(){ printf '%(%H:%M:%S)T' -1; }
say(){ echo "[reh2 $(ts)] $*"; }

# --- config (host-local secrets; never baked) --------------------------------
set -a; . /Users/delattre/.config/seedbed/substrate.env 2>/dev/null; set +a
export DOCKER_HOST="${DOCKER_HOST:-ssh://server}"
R=/Users/delattre/workspace/plow-seedlab-seedbed-substrate
LEASE="$R/lease/lease.sh"
NODE="rehearsal2-$(date +%H%M%S)-1"
IMAGE="inner-base:clean"
TS_TAILNET="${TS_TAILNET:-tailac9c4.ts.net}"
MPSEC="$(grep '^QUEUE_SECRET=' /Users/delattre/.config/mypeople/queue.env|cut -d= -f2-)"
KICKS=0
VOL=""; STAGE="init"; VERDICT="FAIL"; SEED_RESULT="TIMEOUT"; GATETBL=""; CASTHOST=""

post_card(){  # auto-report (H5)
  python3 - "$MPSEC" "$CARD" "$1" <<'PY' 2>/dev/null || true
import sys,json,urllib.request
sec,card,body=sys.argv[1:4]
req=urllib.request.Request("http://127.0.0.1:9933/todo/comment",
 data=json.dumps({"task_id":card,"by":"daniels-MacBook-Pro-2/seed-conductor:eng-1","body":body}).encode(),
 headers={"Content-Type":"application/json","X-Queue-Secret":sec},method="POST")
try: print("card:",urllib.request.urlopen(req,timeout=10).read().decode())
except Exception as e: print("card post failed:",e)
PY
}
dex(){ docker exec "$NODE" bash -lc "$1"; }

teardown(){  # H-NEW already flushed the cast before this; now destroy + release
  say "teardown: rm $NODE + release lease $VOL"
  docker rm -f "$NODE" >/dev/null 2>&1 || true
  [ -n "$VOL" ] && bash "$LEASE" release "$VOL" >/dev/null 2>&1 || true
}

fail_out(){ # a phase needed intervention we can't self-resolve => a KICK would be required
  STAGE="$1"; KICKS=$((KICKS+1)); say "BLOCKED at $STAGE: $2"; }

# --- 1. lease an authed volume (atomic; Pillar #1) ---------------------------
STAGE=lease
VOL="$(bash "$LEASE" acquire "$NODE" 2>/dev/null)" || { fail_out lease "no free bank volume"; post_card "REHEARSAL #2 BLOCKED at lease: no free authed bank volume. manual kicks needed: 1 (provision/free a volume)."; exit 1; }
say "leased $VOL for $NODE"

# --- 2. mint TS_AUTHKEY host-side (host reaches api.tailscale.com) ------------
STAGE=mint
TS_AUTHKEY="$(curl -fsS -u "${TAILSCALE_API_KEY}:" -X POST \
  "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/keys" \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true}}},"expirySeconds":3600}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])' 2>/dev/null)"
case "$TS_AUTHKEY" in tskey-auth-*) say "minted TS_AUTHKEY host-side";; *) fail_out mint "authkey mint failed"; teardown; post_card "REHEARSAL #2 BLOCKED at host-side authkey mint. manual kicks needed: 1."; exit 1;; esac

# --- 3. spin disposable node (mount authed vol + inject secrets) --------------
STAGE=spin
docker rm -f "$NODE" >/dev/null 2>&1 || true
docker run -d --init --name "$NODE" --hostname "$NODE" --entrypoint sleep \
  --add-host host.docker.internal:host-gateway --cap-add=NET_ADMIN --device /dev/net/tun:/dev/net/tun \
  -e NODE_NAME="$NODE" -e TS_AUTHKEY="$TS_AUTHKEY" -e TAILSCALE_API_KEY="${TAILSCALE_API_KEY:-}" -e TS_TAILNET="${TS_TAILNET}" \
  -e CENTRAL_QUEUE_URL="${CENTRAL_QUEUE_URL:-}" -e CENTRAL_QUEUE_SECRET="${CENTRAL_QUEUE_SECRET:-}" -e CENTRAL_BOSS="${CENTRAL_BOSS:-daniels-MacBook-Pro-2/main:Boss}" \
  -e TKMX_API_KEY="${TKMX_API_KEY:-}" -e TKMX_USERNAME="${TKMX_USERNAME:-}" -e TKMX_SERVER_URL="${TKMX_SERVER_URL:-https://tokenmaxxing.odio.dev}" -e TKMX_TEAM="${TKMX_TEAM:-seedbed}" \
  -v "$VOL:/home/tester/.claude" "$IMAGE" infinity >/dev/null 2>&1 \
  || { fail_out spin "docker run failed"; teardown; post_card "REHEARSAL #2 BLOCKED at spin. manual kicks needed: 1."; exit 1; }
say "spun $NODE ($IMAGE, vol $VOL)"

# --- 4. preflight auth (real claude -p probe) + H4: pre-set onboarding/trust --
STAGE=preflight
dex 'python3 - <<PY 2>/dev/null || true
import json,os
p=os.path.expanduser("~/.claude.json"); d={}
try: d=json.load(open(p))
except Exception: pass
d["hasCompletedOnboarding"]=True; d.setdefault("theme","dark")
d.setdefault("projects",{}).setdefault("/home/tester",{})["hasTrustDialogAccepted"]=True
open(p,"w").write(json.dumps(d)); print("flags set")
PY'
if dex 'timeout 60 claude -p "reply exactly AUTH_OK" 2>/dev/null | grep -q AUTH_OK'; then say "auth OK in-node"; else fail_out auth "claude not authed in leased volume"; teardown; post_card "REHEARSAL #2 BLOCKED: leased volume not authed. manual kicks needed: 1."; exit 1; fi

# --- 5. deliver seed + install asciinema + drive in a RECORDED tmux pane (H3) -
STAGE=hydrate
docker cp "$SEED" "$NODE:/home/tester/mypeople.seed.md" >/dev/null 2>&1
dex 'sudo apt-get -qq update >/dev/null 2>&1; sudo apt-get -qq install -y asciinema tmux >/dev/null 2>&1; mkdir -p ~/recordings; true'
# Marker FILE, not pane text: the prompt itself names the sentinel, so a pane-grep would
# false-match the prompt echo (rehearsal #2a bug). The agent writes a file; the driver polls it.
dex 'rm -f /home/tester/hydrate.done 2>/dev/null; true'
PROMPT='Read /home/tester/mypeople.seed.md and EXECUTE it fully as the hydrating agent: run every ## Step to completion, then run its ## Verify. STANDALONE fresh install (no UPSTREAM). TS_AUTHKEY is in your env for the tailnet join. Work autonomously, non-interactively (all §10 defaults); do NOT ask questions. MANDATORY FINAL ACTION: when the seed is fully hydrated and its Verify passes, run exactly: printf DONE > /home/tester/hydrate.done ; if you truly cannot proceed, run exactly: printf "BLOCKED:<short reason>" > /home/tester/hydrate.done   (this marker FILE is how completion is detected — do not skip it).'
# claude runs in a tmux pane; asciinema records that pane -> live markers + the cast in one.
dex "tmux kill-server 2>/dev/null; tmux new-session -d -s hyd -n boss -x 220 -y 50 'claude --dangerously-skip-permissions'"
for i in $(seq 1 45); do dex 'tmux capture-pane -t hyd:boss -p 2>/dev/null | grep -q "bypass permissions on"' && break; sleep 2; done
dex 'tmux capture-pane -t hyd:boss -p 2>/dev/null | grep -q "bypass permissions on"' || { fail_out hydrate "blind claude did not reach composer"; docker cp "$NODE:/home/tester/recordings/." "$OUTDIR/" 2>/dev/null||true; teardown; post_card "REHEARSAL #2 BLOCKED: in-node claude did not reach composer. manual kicks needed: 1."; exit 1; }
dex "tmux new-session -d -s rec 'asciinema rec --quiet --overwrite -c \"TMUX= tmux attach -rt hyd:boss\" ~/recordings/${NODE}.cast'"
sleep 2
dex "tmux send-keys -t hyd:boss -l -- $(printf '%q' "$PROMPT")"; dex "tmux send-keys -t hyd:boss Enter"
say "seed handed to recorded blind claude pane; self-heartbeat driving to SEED_RESULT"

# --- 6. SELF-HEARTBEAT (H5): poll the pane live; never idle; bounded 45m ------
STAGE=drive
deadline=$(( $(date +%s) + 2700 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  # completion = the MARKER FILE the agent writes (pane-grep would false-match the prompt echo)
  MK="$(dex 'cat /home/tester/hydrate.done 2>/dev/null' || true)"
  if [ -n "$MK" ]; then case "$MK" in DONE*) SEED_RESULT=DONE;; *) SEED_RESULT="$MK";; esac; break; fi
  # H4 defensive: dismiss an in-node feedback dialog if it ever appears
  dex 'tmux capture-pane -t hyd:boss -p 2>/dev/null | grep -q "How is Claude doing this session"' && { dex 'tmux send-keys -t hyd:boss 0' 2>/dev/null; say "H4: dismissed in-node feedback dialog"; }
  # stop early if the pane's claude died without a marker
  dex 'tmux has-session -t hyd 2>/dev/null' || { SEED_RESULT="PANE_DIED_NO_MARKER"; break; }
  say "…building: bin=$(dex 'ls ~/mypeople/bin 2>/dev/null|wc -l') daemons=$(dex 'pgrep -c -f "queue-server|todo-server|queue-client" 2>/dev/null') tn=$(dex 'sudo tailscale --socket=/home/tester/mypeople/run/tailscale-state/tailscaled.sock ip -4 2>/dev/null|head -1' 2>/dev/null)"
  sleep 45
done
say "hydrate ended: $SEED_RESULT"

# --- 7. SUBSTRATE_READY 7-gate (H6 stable-200, H7 socket-pinned) --------------
STAGE=gate
TSD=/home/tester/mypeople/run/tailscale-state
GATES="$(dex "
G=0; P=0
ip=\$(sudo tailscale --socket=$TSD/tailscaled.sock ip -4 2>/dev/null|head -1)   # H7 socket-pinned
[ -n \"\$ip\" ] && { echo 'G1 tailnet: PASS ('\$ip')'; P=\$((P+1)); } || echo 'G1 tailnet: FAIL'
cn=\$(ls ~/mypeople/bin/queue-server.py ~/mypeople/bin/mp ~/mypeople/bin/todo-server.py ~/mypeople/bin/dashboard.html 2>/dev/null|wc -l)
[ \"\$cn\" -ge 4 ] && { echo 'G2 components: PASS'; P=\$((P+1)); } || echo \"G2 components: FAIL (\$cn)\"
# H6: queue stably 200 over 3 probes ~1s apart
ok=0; for k in 1 2 3; do [ \"\$(curl -fsS -o /dev/null -w %{http_code} --max-time 4 http://127.0.0.1:9900/health 2>/dev/null)\" = 200 ] && ok=\$((ok+1)); sleep 1; done
ag=\$(curl -fsS --max-time 4 -H \"X-Queue-Secret: \$(grep '^QUEUE_SECRET=' ~/.config/mypeople/queue.env|cut -d= -f2-)\" http://127.0.0.1:9900/agents 2>/dev/null)
nag=\$(echo \"\$ag\"|grep -oE agent_id|wc -l)
[ \"\$ok\" = 3 ] && [ \"\$nag\" -ge 1 ] && { echo \"G3 registration: PASS (\$nag agents, queue stable 3/3)\"; P=\$((P+1)); } || echo \"G3 registration: FAIL (queue200=\$ok/3 agents=\$nag)\"
echo \"\$ag\"|grep -qE ':Boss' && { echo 'G4 boss-notify: PASS (Boss registered)'; P=\$((P+1)); } || echo 'G4 boss-notify: FAIL'
tt=\$(curl -fsS -o /dev/null -w %{http_code} --max-time 4 http://127.0.0.1:7681/ 2>/dev/null)
[ \"\$tt\" = 200 ] && { echo 'G5 attach/ttyd: PASS'; P=\$((P+1)); } || echo \"G5 attach/ttyd: FAIL (\$tt)\"
pgrep -f tkmx >/dev/null 2>&1 && { echo 'G6 tkmx: PASS'; P=\$((P+1)); } || echo 'G6 tkmx: FAIL'
pgrep -f asciinema >/dev/null 2>&1 && { echo 'G7 recorder: PASS'; P=\$((P+1)); } || echo 'G7 recorder: FAIL'
echo \"GATES_PASSED=\$P/7\"
")"
echo "$GATES"; GATETBL="$GATES"

# --- 8. H-NEW: FLUSH cast off-node BEFORE teardown ---------------------------
STAGE=flush
docker cp "$NODE:/home/tester/recordings/." "$OUTDIR/" >/dev/null 2>&1 || true
CASTHOST="$(ls "$OUTDIR"/*.cast 2>/dev/null | head -1)"
[ -n "$CASTHOST" ] && say "flushed cast -> $CASTHOST ($(wc -c <"$CASTHOST" 2>/dev/null) bytes)" || say "WARN: no cast to flush"

# --- 9. teardown + verdict + auto-post ---------------------------------------
teardown
PASSN="$(echo "$GATES" | grep -oE 'GATES_PASSED=[0-9]+/7' | cut -d= -f2)"
[ "$SEED_RESULT" = DONE ] && [ "$PASSN" = "7/7" ] && VERDICT="PASS (unattended)" || VERDICT="PARTIAL/FAIL"
# stage the cast as a servable proof
CASTPROOF=""
if [ -n "$CASTHOST" ]; then HX=$(python3 -c 'import secrets;print(secrets.token_hex(6))'); cp "$CASTHOST" "/Users/delattre/mypeople/todos/proofs/${HX}_reh2.cast" 2>/dev/null && CASTPROOF="/todo/proof-file/${HX}_reh2.cast"; fi
say "VERDICT=$VERDICT SEED_RESULT=$SEED_RESULT gates=$PASSN kicks=$KICKS"
post_card "REHEARSAL #2 — HANDS-OFF PROOF (node $NODE, disposable, self-spun+torn-down). Seed @ c935826 folds live.
RESULT: $VERDICT · SEED_RESULT=$SEED_RESULT
manual kicks needed: $KICKS   (0 = fully unattended; the driver self-spun, self-drove, self-flushed, self-tore-down, self-posted)
SUBSTRATE_READY 7-gate:
$GATES
Contracts exercised by the DRIVER itself: H3 recorded-pane live markers · H4 onboarding/trust flags pre-set (no dialog stall) + defensive in-node dismiss · H5 self-heartbeat (interval progress, auto-report) · H6 queue stable-200 x3 · H7 tailscaled --socket pinned in the gate · H-NEW cast flushed off-node BEFORE teardown${CASTPROOF:+ (attached)} · auto-teardown (rm + lease release).
RECORDING: terminal cast ${CASTPROOF:-'(none captured — gap)'}. Browser seedrec: not wired into this self-contained headless driver (gap: browser recording needs the seedrec tooling; terminal cast is the primary proof).
$([ "$KICKS" = 0 ] && [ "$VERDICT" = 'PASS (unattended)' ] && echo 'UNATTENDED-100% PROVEN for the drive: zero kicks, 7/7.' || echo 'NOT fully clean — see gate table + kicks; iterate on the failing item.')"
[ -n "$CASTPROOF" ] && curl -fsS -X POST "http://127.0.0.1:9933/todo/proof" -H "Content-Type: application/json" -H "X-Queue-Secret: $MPSEC" -d "{\"task_id\":\"$CARD\",\"kind\":\"link\",\"url\":\"$CASTPROOF\"}" >/dev/null 2>&1 || true
say "done."
