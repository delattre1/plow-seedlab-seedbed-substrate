#!/usr/bin/env bash
# bank-dashboard.sh — render + (optionally) serve a STATUS HTML for the canonical Claude Auth Bank.
#
# Per canonical volume (claude-auth-bank-NN): name, authed?, AUTH_OK (last probe + time),
# leased-vs-free (+ which node), Max subscription, token expiry. Writes an HTML snapshot and can
# serve it on the tailnet. Read-only: never mutates a volume or a lease. Gathers all volumes in
# PARALLEL so it renders fast.
#
# Env: DOCKER_HOST(=ssh://server) BASE_IMG(=inner-base:clean) SEEDBED_LEASE_DIR(canonical lease dir)
#      OUT(html path — served dir is its dirname, so use a DEDICATED dir, never one with secrets)
#      PROBE(1=run AUTH_OK probes, 0=skip/fast) SERVE_PORT(if set, serve dirname(OUT) on tailnet)
set -uo pipefail
# SINGLE SOURCE OF TRUTH: the same env file spin.sh + reap-dead-leases.sh read, so the
# dashboard's lease dir + bank membership can NEVER drift from what actually leases.
[ -f "$HOME/.config/seedbed/substrate.env" ] && . "$HOME/.config/seedbed/substrate.env"
export DOCKER_HOST="${DOCKER_HOST:-ssh://server-ts}"   # LAN `server` route is down; tailnet `server-ts` is the reliable path
BASE_IMG="${BASE_IMG:-inner-base:clean}"
# Bank membership AND lease state both come from the ledger — never from probing the host.
BANK_FILE="${BANK_FILE:-$HOME/.config/seedbed/cto-bank.txt}"          # canonical membership (fixed volume list)
LEASE_DIR="${SEEDBED_LEASE_DIR:-$HOME/.config/seedbed/leases-bank}"   # canonical lease ledger
OUT="${OUT:-$HOME/seedbed-bank-www/index.html}"
PROBE="${PROBE:-1}"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$(dirname "$OUT")"

# Membership is AUTHORITATIVE from the ledger file, NOT the host — so total/free/leased
# stay correct even when the docker host is offline (host down must never read as 0/0).
VOLS=$(grep -vE '^\s*(#|$)' "$BANK_FILE" 2>/dev/null | awk '{print $1}' | sort)
# One cheap reachability probe. If the host is unreachable we SKIP the live auth probes
# (authed / AUTH_OK) and mark them 'unverified (host offline)' — never a false failure.
HOST_UP=0; timeout 10 docker version >/dev/null 2>&1 && HOST_UP=1
TMPDIR="$(mktemp -d)"

gather_one(){
  local v="$1" authed sub exp ok oktime leased node ctr line r
  sub="-"; exp="-"; ok="—"; oktime="—"; leased="free"; node="-"
  if [ "$HOST_UP" = 1 ]; then
    authed=$(docker run --rm --entrypoint bash -v "$v:/c" "$BASE_IMG" -lc 'test -s /c/.credentials.json && echo yes || echo no' 2>/dev/null)
    [ -n "$authed" ] || authed="unverified"
    if [ "$authed" = yes ]; then
      line=$(docker run --rm --entrypoint bash -v "$v:/c" "$BASE_IMG" -lc 'python3 -c "import json,datetime;d=json.load(open(\"/c/.credentials.json\")).get(\"claudeAiOauth\",{});e=d.get(\"expiresAt\");print((d.get(\"subscriptionType\") or \"?\")+\"|\"+(datetime.datetime.utcfromtimestamp(e/1000).strftime(\"%Y-%m-%d %H:%MZ\") if e else \"?\"))"' 2>/dev/null)
      sub="${line%%|*}"; exp="${line##*|}"
      if [ "$PROBE" = 1 ]; then
        r=$(docker run --rm --entrypoint bash -v "$v:/home/tester/.claude" "$BASE_IMG" -lc 'timeout 45 claude -p "reply with exactly: AUTH_OK" 2>&1 | tail -1' 2>/dev/null)
        [ "$r" = "AUTH_OK" ] && ok="PASS" || ok="FAIL"
        oktime="$NOW"
      fi
    fi
  else
    # Host offline: volumes can't be inspected. Report 'unverified' — never a false no/FAIL/0.
    authed="unverified"; ok="unverified"; oktime="host offline"
  fi
  # Lease/free ALWAYS derive from the canonical ledger — host-independent, always available.
  if [ -d "$LEASE_DIR/$v" ]; then
    leased="LEASED"
    node="$( [ -f "$LEASE_DIR/$v/holder" ] && cut -f1 "$LEASE_DIR/$v/holder" 2>/dev/null || echo '?')"
  fi
  # Live-container cross-check only when the host is reachable (refines the node label).
  if [ "$HOST_UP" = 1 ]; then
    ctr=$(docker ps --filter volume="$v" --format '{{.Names}}' 2>/dev/null | head -1)
    [ -n "$ctr" ] && { leased="LEASED"; node="$ctr"; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$authed" "$ok" "$oktime" "$leased" "$node" "$sub" "$exp" > "$TMPDIR/$v.row"
}

for v in $VOLS; do gather_one "$v" & done
wait

TMP="$TMPDIR/all.tsv"; cat "$TMPDIR"/*.row 2>/dev/null | sort > "$TMP"
total_n=$(wc -l < "$TMP" | tr -d ' ')
authed_n=$(awk -F'\t' '$2=="yes"' "$TMP" | wc -l | tr -d ' ')
ok_n=$(awk -F'\t' '$3=="PASS"' "$TMP" | wc -l | tr -d ' ')
leased_n=$(awk -F'\t' '$5=="LEASED"' "$TMP" | wc -l | tr -d ' ')
free_n=$(( total_n - leased_n ))

{
cat <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">
<title>Claude Auth Bank — status</title><style>
body{font:14px -apple-system,Segoe UI,Roboto,sans-serif;background:#0b0e14;color:#d7dce5;margin:24px}
h1{font-size:20px;margin:0 0 4px}.sub{color:#8b95a7;margin:0 0 16px;font-size:13px}
table{border-collapse:collapse;width:100%;max-width:1100px}th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #1d2430}
th{color:#8b95a7;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.pass{color:#3fb950;font-weight:700}.fail{color:#f85149;font-weight:700}.dash{color:#6b7385}
.leased{color:#d29922}.free{color:#3fb950}.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px}
.yes{background:#12331d;color:#3fb950}.no{background:#3a1416;color:#f85149}.unk{background:#26303f;color:#8b95a7}
.summary{margin:14px 0;font-size:15px}.big{font-size:22px;font-weight:800}
</style></head><body>
<h1>Claude Auth Bank — status</h1>
<p class="sub">canonical bank · generated $NOW · auto-refresh 60s · ledger $LEASE_DIR · host $DOCKER_HOST ($([ "$HOST_UP" = 1 ] && echo online || echo OFFLINE))</p>
<p class="summary"><span class="big">$free_n free / $leased_n leased</span> &nbsp;·&nbsp; $total_n volumes &nbsp;·&nbsp; AUTH_OK $ok_n/$total_n &nbsp;·&nbsp; authed $authed_n/$total_n$([ "$HOST_UP" = 0 ] && echo ' &nbsp;·&nbsp; <span class="fail">host offline — auth unverified</span>')</p>
<table><tr><th>volume</th><th>authed</th><th>AUTH_OK</th><th>last probe</th><th>lease</th><th>node</th><th>sub</th><th>token expiry</th></tr>
HTML
while IFS=$'\t' read -r v authed ok oktime leased node sub exp; do
  ac=$([ "$authed" = yes ] && echo "pill yes" || { [ "$authed" = unverified ] && echo "pill unk" || echo "pill no"; })
  okc=$([ "$ok" = PASS ] && echo pass || { [ "$ok" = FAIL ] && echo fail || echo dash; })
  lc=$([ "$leased" = LEASED ] && echo leased || echo free)
  printf '<tr><td><b>%s</b></td><td><span class="%s">%s</span></td><td class="%s">%s</td><td class="dash">%s</td><td class="%s">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
    "$v" "$ac" "$authed" "$okc" "$ok" "$oktime" "$lc" "$leased" "$node" "$sub" "$exp"
done < "$TMP"
echo "</table></body></html>"
} > "$OUT"
echo "wrote $OUT ($ok_n/$total_n AUTH_OK, $authed_n/$total_n authed)"
rm -rf "$TMPDIR"

if [ -n "${SERVE_PORT:-}" ]; then
  pkill -f "http.server ${SERVE_PORT}" 2>/dev/null || true
  ( cd "$(dirname "$OUT")" && nohup python3 -m http.server "$SERVE_PORT" --bind 0.0.0.0 >/tmp/bank-dash-serve.log 2>&1 & )
  echo "serving $(dirname "$OUT") on :$SERVE_PORT"
fi
