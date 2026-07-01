#!/usr/bin/env bash
# ============================================================================
# hydrate-core.sh — the FROM-SEED core hydrate driver (the missing HYDRATE_DRIVER).
#
# Drives a REAL blind from-seed hydrate of the mypeople CORE seed on an already-spun,
# AUTHED bare node (inner-base:clean + a mounted leased Claude auth volume — NO human
# auth). A blind Claude in the node reads mypeople.seed.md, runs every §12 Step, runs
# its OWN §14 ## Verify (§15 J-jury + browser a-Q + Nightwatch), and prints
# SEED_RESULT=DONE. This driver captures the real result + per-gate pass/fail.
#
# It does NOT lease/spin (that is spin.sh's job, on the substrate host where the bank
# lease dir lives). Give it a node that is already up + authed:
#   spin.sh:  GOLDEN_IMAGE=inner-base:clean SPIN_CMD='sleep infinity' bin/spin.sh 1 core
#   then:     hydrate-core.sh <NODE> <SEED_PATH> <OUTDIR>
#
# Auth is proven up front (claude auth status). TS_AUTHKEY comes from the env/SUBSTRATE_ENV
# (headless tailscale — never device login). Standalone mode (no UPSTREAM_*) = a complete
# self-sufficient node, the real user's fresh-from-zero install (seed §10).
# ============================================================================
set -uo pipefail
NODE="${1:?usage: hydrate-core.sh <node> <seed.md> <outdir>}"
SEED="${2:?seed path}"
OUTDIR="${3:?outdir}"
DOCKER="${DOCKER:-docker}"
HYDRATE_TIMEOUT="${HYDRATE_TIMEOUT:-2700}"   # 45m — a full runtime build + §15 jury
mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
dex(){ $DOCKER exec "$NODE" bash -lc "$1"; }

emit(){ echo "[hydrate-core $(printf '%(%H:%M:%S)T' -1)] $*"; }

# ── 0. preconditions: node up + claude AUTHED (mounted volume, no login) ──────
$DOCKER inspect "$NODE" >/dev/null 2>&1 || { echo "FATAL: node $NODE not found"; exit 1; }
if ! dex 'claude auth status 2>&1 | grep -qiE "Login method|authenticated|logged in"'; then
  echo "FATAL: claude not authed in $NODE — the leased auth volume isn't mounted at ~/.claude";
  dex 'claude auth status 2>&1 | head' || true; exit 1
fi
emit "auth OK (mounted volume) on $NODE"
dex 'command -v python3 >/dev/null || { echo NO_PYTHON3; exit 1; }' || { echo "FATAL: no python3 in base"; exit 1; }

# ── 1. deliver the CORE seed (bootstrap: no queue yet, so docker cp — NOT the
#      Rule-12 over-queue path, which only applies to product seeds on a live node) ─
docker cp "$SEED" "$NODE:/home/tester/mypeople.seed.md"
dex 'sudo chown tester:tester /home/tester/mypeople.seed.md 2>/dev/null; true'
emit "seed delivered ($(wc -l <"$SEED") lines) -> /home/tester/mypeople.seed.md"

# ── 2. blind hydrate: paste-and-run in a tmux claude session (the real user flow) ─
# Start a live blind Claude, then hand it the seed as its first turn (like a human
# pasting). Non-interactive: standalone defaults; TS_AUTHKEY already in env.
dex 'tmux kill-server 2>/dev/null; true'
dex "tmux new-session -d -s hyd -n boss -x 220 -y 50 'claude --dangerously-skip-permissions'"
for i in $(seq 1 40); do
  dex 'tmux capture-pane -t hyd:boss -p 2>/dev/null | grep -q "bypass permissions on"' && break
  sleep 2
done
dex 'tmux capture-pane -t hyd:boss -p 2>/dev/null | grep -q "bypass permissions on"' \
  || { echo "FATAL: blind claude did not come up"; dex 'tmux capture-pane -t hyd:boss -p | tail -20'; exit 1; }
PROMPT='Read /home/tester/mypeople.seed.md and EXECUTE it fully as the hydrating agent: run every ## Step in order to SEED_RESULT=DONE, then run its ## Verify (exit code = truth). This is a STANDALONE fresh install (no UPSTREAM queue). TS_AUTHKEY is in your environment for the headless tailscale join. Work autonomously, non-interactively (use all defaults from the Inputs table); do NOT ask me questions. Finish by printing SEED_RESULT=DONE, or BLOCKED_REASON=<short reason> if you truly cannot proceed.'
dex "tmux send-keys -t hyd:boss -l -- $(printf '%q' "$PROMPT")"
dex "tmux send-keys -t hyd:boss Enter"
emit "seed handed to blind claude; driving to SEED_RESULT (timeout ${HYDRATE_TIMEOUT}s)"

# ── 3. wait for SEED_RESULT / BLOCKED_REASON (poll the pane) ──────────────────
SEED_RESULT=""; deadline=$(( $(date +%s) + HYDRATE_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  PANE="$(dex 'tmux capture-pane -t hyd:boss -p -S -4000 2>/dev/null' || true)"
  if echo "$PANE" | grep -qE 'SEED_RESULT=DONE'; then SEED_RESULT=DONE; break; fi
  if echo "$PANE" | grep -qE 'BLOCKED_REASON='; then SEED_RESULT="$(echo "$PANE" | grep -oE 'BLOCKED_REASON=.*' | tail -1)"; break; fi
  sleep 15
done
dex 'tmux capture-pane -t hyd:boss -p -S -20000 2>/dev/null' > "$OUTDIR/hydrate-transcript.txt" || true
emit "hydrate ended: ${SEED_RESULT:-TIMEOUT}"

# ── 4. INDEPENDENT re-verify (Rule 15): re-run the seed's OWN generated harness ──
# The seed generates verify.sh (§14) → §15 J-jury + browser a-Q + Nightwatch. Re-run it
# fresh and capture per-gate PASS/FAIL (exit code = truth).
VERIFY_RC="";
if dex 'test -x $HOME/mypeople/verify/verify.sh || test -f $HOME/mypeople/verify/verify.sh'; then
  dex 'cd $HOME/mypeople/verify && bash verify.sh 2>&1' > "$OUTDIR/verify-independent.log" 2>&1; VERIFY_RC=$?
elif dex 'test -f $HOME/mypeople/verify/verify.py'; then
  dex 'cd $HOME/mypeople/verify && python3 verify.py 2>&1' > "$OUTDIR/verify-independent.log" 2>&1; VERIFY_RC=$?
else
  echo "NO_VERIFY_HARNESS (seed did not generate ~/mypeople/verify)" > "$OUTDIR/verify-independent.log"; VERIFY_RC=127
fi
emit "independent verify exit=$VERIFY_RC (log: verify-independent.log)"

# ── 5. per-gate extraction (J-jury lines) + RESULT.json ──────────────────────
python3 - "$OUTDIR" "$NODE" "$SEED_RESULT" "$VERIFY_RC" <<'PY'
import json, os, re, sys
outdir, node, seed_result, vrc = sys.argv[1:5]
log = ""
p = os.path.join(outdir, "verify-independent.log")
if os.path.exists(p): log = open(p, errors="replace").read()
# Gate lines look like "JNN ... PASS/FAIL" or "✓/✗ Jxx" or "GATES: 1=1 2=0 ..." — capture broadly.
gates = {}
for m in re.finditer(r'\b(J\d{1,2}[a-z]?)\b[^\n]*?\b(PASS|FAIL|OK|ok|✓|✗)\b', log):
    v = m.group(2)
    gates[m.group(1)] = "PASS" if v in ("PASS","OK","ok","✓") else "FAIL"
for m in re.finditer(r'(\d+)=(\d)', log):   # GATES: 1=1 2=0 style
    gates.setdefault("g"+m.group(1), "PASS" if m.group(2)=="1" else "FAIL")
passed = sum(1 for v in gates.values() if v=="PASS")
failed = sum(1 for v in gates.values() if v=="FAIL")
res = {
  "node": node,
  "seed": "mypeople.seed.md",
  "seed_result": seed_result or "TIMEOUT",
  "independent_verify_exit": int(vrc) if str(vrc).lstrip("-").isdigit() else vrc,
  "gates_passed": passed, "gates_failed": failed,
  "gates_failing": sorted([k for k,v in gates.items() if v=="FAIL"]),
  "gates": gates,
  "verdict": "PASS" if (seed_result=="DONE" and str(vrc)=="0" and failed==0) else "FAIL",
}
json.dump(res, open(os.path.join(outdir,"RESULT.json"),"w"), indent=2)
print(json.dumps(res, indent=2))
PY
echo "hydrate-core RESULT -> $OUTDIR/RESULT.json"
