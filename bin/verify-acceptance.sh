#!/usr/bin/env bash
# ============================================================================
# verify-acceptance.sh — run the CEO acceptance gates and CAPTURE real proof.
# (Genuine captured output only — never claims. Run on the docker host.)
#
#   Gate 1: spin 5 -> within 15s, 5 SUBSTRATE_READY substrates.
#   Gate 2: NO two substrates share an auth volume (atomic lease).
#   Gate 3: bank=10 full -> the 11th spin FAILS CLEANLY (fail-fast, no double-lease).
#   Gate 4: dockerhub pull-and-run -> see pipeline/pull-and-run.sh (needs creds).
#
# Usage: verify-acceptance.sh [prefix]
# Env: source bank/bank.env first. GOLDEN_IMAGE must point at the golden image.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/bank/bank.env"
LEASE="$ROOT/lease/lease.sh"
DOCKER="${DOCKER:-docker}"
PFX="${1:-acc}"
PASS=0; FAIL=0
hr(){ printf '%s\n' "------------------------------------------------------------"; }
ok(){ echo "PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== ACCEPTANCE @ $(date -u +%FT%TZ) | image=$GOLDEN_IMAGE bank=$BANK_SIZE ==="
"$LEASE" init
hr

# ---- Gate 1: spin 5, all SUBSTRATE_READY within 15s -------------------------
echo "## Gate 1 — spin 5 -> 5 SUBSTRATE_READY within 15s"
T0=$SECONDS
"$ROOT/bin/spin.sh" 5 "$PFX"
G1ELAPSED=$(( SECONDS - T0 ))
ready5=$($DOCKER ps --format '{{.Names}}' | grep -cE "^${PFX}-[1-5]$")
readymark=0
for i in 1 2 3 4 5; do $DOCKER exec "${PFX}-$i" test -f "$READY_MARKER" 2>/dev/null && readymark=$((readymark+1)); done
echo "gate1: containers up=$ready5 with-marker=$readymark elapsed=${G1ELAPSED}s"
{ [ "$readymark" -eq 5 ] && [ "$G1ELAPSED" -le 15 ]; } && ok "5 SUBSTRATE_READY in ${G1ELAPSED}s (<=15s)" || no "gate1 (ready=$readymark/5, ${G1ELAPSED}s)"
hr

# ---- Gate 2: no two substrates share an auth volume -------------------------
echo "## Gate 2 — no two substrates share an auth volume"
echo "container -> mounted auth volume (source of $CLAUDE_MOUNT):"
MAP="$(for i in 1 2 3 4 5; do
  v=$($DOCKER inspect -f "{{range .Mounts}}{{if eq .Destination \"$CLAUDE_MOUNT\"}}{{.Name}}{{end}}{{end}}" "${PFX}-$i" 2>/dev/null)
  printf '  %s -> %s\n' "${PFX}-$i" "$v"
done)"
echo "$MAP"
vols="$(echo "$MAP" | awk '{print $3}' | grep -v '^$')"
total=$(echo "$vols" | wc -l | tr -d ' '); uniq=$(echo "$vols" | sort -u | wc -l | tr -d ' ')
echo "gate2: $total volumes in use, $uniq distinct"
[ "$total" -ge 1 ] && [ "$total" -eq "$uniq" ] && ok "all $total auth volumes distinct (no sharing)" || no "gate2 (total=$total uniq=$uniq)"
hr

# ---- Gate 3: bank full -> 11th fails cleanly --------------------------------
echo "## Gate 3 — bank=$BANK_SIZE full -> the (N+1)th spin FAILS CLEANLY"
echo "filling the bank to $BANK_SIZE ..."
"$ROOT/bin/spin.sh" "$BANK_SIZE" "$PFX" >/dev/null 2>&1 || true
echo "lease status (expect $BANK_SIZE USED, 0 FREE):"; "$LEASE" status
freenow=$("$LEASE" free-count); echo "free volumes now: $freenow"
echo "attempting one more (the $((BANK_SIZE+1))th) ..."
EXTRA_OUT="$("$ROOT/bin/spin.sh" 1 "${PFX}-overflow" 2>&1)"; echo "$EXTRA_OUT"
overflow_ctr_created=$($DOCKER ps -a --format '{{.Names}}' | grep -cE "^${PFX}-overflow-1$")
{ [ "$freenow" -eq 0 ] && echo "$EXTRA_OUT" | grep -q "FAILFAST" && [ "$overflow_ctr_created" -eq 0 ]; } \
  && ok "11th spin failed fast (no free volume; no container created; no double-lease)" \
  || no "gate3 (free=$freenow, overflow_container=$overflow_ctr_created)"
hr

echo "=== RESULT: $PASS passed, $FAIL failed ==="
echo "(teardown: $ROOT/bin/teardown.sh --prefix $PFX ; volumes are kept)"
[ "$FAIL" -eq 0 ]
