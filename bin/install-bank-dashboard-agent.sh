#!/usr/bin/env bash
# ============================================================================
# install-bank-dashboard-agent.sh — install the bank dashboard as TWO durable
# launchd USER agents so the page is ALWAYS live + reachable:
#   com.seedbed.bank-dashboard          -> the regen LOOP (re-probes every 120s)
#   com.seedbed.bank-dashboard-server   -> the :8899 HTTP file-server
# Both KeepAlive + RunAtLoad → auto-restart on death or reboot. A durable loop is
# pointless if the server serving its HTML can die, so we make both durable.
# Idempotent + re-runnable.
#
#   bash bin/install-bank-dashboard-agent.sh            # install/refresh + start both
#   bash bin/install-bank-dashboard-agent.sh --uninstall
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/bank-dashboard-loop.sh"
SERVE="$HERE/bank-dashboard-serve.sh"
UID_NUM="$(id -u)"
LA="$HOME/Library/LaunchAgents"
DOCKER_HOST_VAL="${DOCKER_HOST:-ssh://server-ts}"
LEASE_DIR_VAL="${SEEDBED_LEASE_DIR:-$HOME/.config/seedbed/leases-bank}"

LOOP_LABEL="com.seedbed.bank-dashboard"
SERVE_LABEL="com.seedbed.bank-dashboard-server"

uninstall_one(){ local label="$1"; launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true; rm -f "$LA/$label.plist"; }

if [ "${1:-}" = "--uninstall" ]; then
  uninstall_one "$LOOP_LABEL"; uninstall_one "$SERVE_LABEL"
  echo "uninstalled both bank-dashboard agents"; exit 0
fi

# render a plist: $1=label $2=script $3=extra <dict> env lines $4=log basename
write_and_load(){
  local label="$1" script="$2" extra_env="$3" logname="$4"
  local plist="$LA/$label.plist"
  chmod +x "$script"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$script</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>$extra_env
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/workspace/$logname</string>
  <key>StandardErrorPath</key><string>$HOME/workspace/$logname</string>
</dict>
</plist>
PLIST_EOF
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  if launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null; then
    launchctl enable "gui/$UID_NUM/$label" 2>/dev/null || true
    launchctl kickstart -k "gui/$UID_NUM/$label" 2>/dev/null || true
  else
    launchctl load -w "$plist"   # legacy fallback
  fi
}

[ -f "$LOOP" ]  || { echo "FATAL: missing $LOOP"  >&2; exit 1; }
[ -f "$SERVE" ] || { echo "FATAL: missing $SERVE" >&2; exit 1; }
mkdir -p "$LA" "$HOME/seedbed-bank-www"

# Retire any BARE (non-launchd) instances so nothing double-runs.
pkill -f "bank-dashboard-live.sh" 2>/dev/null || true
pkill -f "bank-dashboard-loop.sh" 2>/dev/null || true
pkill -f "http.server 8899"       2>/dev/null || true

write_and_load "$LOOP_LABEL"  "$LOOP" \
  "
    <key>DOCKER_HOST</key><string>$DOCKER_HOST_VAL</string>
    <key>SEEDBED_LEASE_DIR</key><string>$LEASE_DIR_VAL</string>" \
  "bank-dashboard-agent.log"

write_and_load "$SERVE_LABEL" "$SERVE" "" "bank-dashboard-server-agent.log"

sleep 2
echo "installed both agents:"
for label in "$LOOP_LABEL" "$SERVE_LABEL"; do
  st="$(launchctl print "gui/$UID_NUM/$label" 2>/dev/null | grep -E 'state =|pid =' | tr '\n' ' ')"
  echo "  $label -> ${st:-(check launchctl list)}"
done
