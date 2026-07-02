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
export DOCKER_HOST="${DOCKER_HOST:-ssh://server-ts}"   # LAN `server` route is down; tailnet `server-ts` is the reliable path
BASE_IMG="${BASE_IMG:-inner-base:clean}"
LEASE_DIR="${SEEDBED_LEASE_DIR:-$HOME/.config/seedbed/leases-bank}"
OUT="${OUT:-$HOME/seedbed-bank-www/index.html}"
PROBE="${PROBE:-1}"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$(dirname "$OUT")"

VOLS=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^claude-auth-bank-[0-9]+$' | sort)
TMPDIR="$(mktemp -d)"

gather_one(){
  local v="$1" authed sub exp ok oktime leased node ctr line r
  authed=$(docker run --rm --entrypoint bash -v "$v:/c" "$BASE_IMG" -lc 'test -s /c/.credentials.json && echo yes || echo no' 2>/dev/null)
  sub="-"; exp="-"; ok="—"; oktime="—"; leased="free"; node="-"
  if [ "$authed" = yes ]; then
    line=$(docker run --rm --entrypoint bash -v "$v:/c" "$BASE_IMG" -lc 'python3 -c "import json,datetime;d=json.load(open(\"/c/.credentials.json\")).get(\"claudeAiOauth\",{});e=d.get(\"expiresAt\");print((d.get(\"subscriptionType\") or \"?\")+\"|\"+(datetime.datetime.utcfromtimestamp(e/1000).strftime(\"%Y-%m-%d %H:%MZ\") if e else \"?\"))"' 2>/dev/null)
    sub="${line%%|*}"; exp="${line##*|}"
    if [ "$PROBE" = 1 ]; then
      r=$(docker run --rm --entrypoint bash -v "$v:/home/tester/.claude" "$BASE_IMG" -lc 'timeout 45 claude -p "reply with exactly: AUTH_OK" 2>&1 | tail -1' 2>/dev/null)
      [ "$r" = "AUTH_OK" ] && ok="PASS" || ok="FAIL"
      oktime="$NOW"
    fi
  fi
  [ -f "$LEASE_DIR/$v/holder" ] && { leased="LEASED"; node="$(cut -f1 "$LEASE_DIR/$v/holder" 2>/dev/null)"; }
  ctr=$(docker ps --filter volume="$v" --format '{{.Names}}' 2>/dev/null | head -1)
  [ -n "$ctr" ] && { leased="LEASED"; node="$ctr"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$authed" "$ok" "$oktime" "$leased" "$node" "$sub" "$exp" > "$TMPDIR/$v.row"
}

for v in $VOLS; do gather_one "$v" & done
wait

TMP="$TMPDIR/all.tsv"; cat "$TMPDIR"/*.row 2>/dev/null | sort > "$TMP"
total_n=$(wc -l < "$TMP" | tr -d ' ')
authed_n=$(awk -F'\t' '$2=="yes"' "$TMP" | wc -l | tr -d ' ')
ok_n=$(awk -F'\t' '$3=="PASS"' "$TMP" | wc -l | tr -d ' ')

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
.yes{background:#12331d;color:#3fb950}.no{background:#3a1416;color:#f85149}
.summary{margin:14px 0;font-size:15px}.big{font-size:22px;font-weight:800}
</style></head><body>
<h1>Claude Auth Bank — status</h1>
<p class="sub">canonical bank · generated $NOW · auto-refresh 60s · lease dir $LEASE_DIR</p>
<p class="summary"><span class="big">$ok_n/$total_n</span> AUTH_OK &nbsp;·&nbsp; $authed_n/$total_n authed</p>
<table><tr><th>volume</th><th>authed</th><th>AUTH_OK</th><th>last probe</th><th>lease</th><th>node</th><th>sub</th><th>token expiry</th></tr>
HTML
while IFS=$'\t' read -r v authed ok oktime leased node sub exp; do
  ac=$([ "$authed" = yes ] && echo "pill yes" || echo "pill no")
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
