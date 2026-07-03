#!/usr/bin/env bash
# ============================================================================
# install-bank-dashboard-agent.sh — install the bank dashboard regen loop as a
# durable launchd USER agent (KeepAlive + RunAtLoad), so it auto-restarts on death
# or reboot and the page at :8899 is ALWAYS live. Idempotent + re-runnable.
#
#   bash bin/install-bank-dashboard-agent.sh            # install/refresh + start
#   bash bin/install-bank-dashboard-agent.sh --uninstall
#
# Replaces the fragile bare `nohup bank-dashboard-live.sh` loop (kept dying → page
# froze). launchd owns the lifecycle now.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/bank-dashboard-loop.sh"
LABEL="com.seedbed.bank-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
DOCKER_HOST_VAL="${DOCKER_HOST:-ssh://server-ts}"
LEASE_DIR_VAL="${SEEDBED_LEASE_DIR:-$HOME/.config/seedbed/leases-bank}"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "uninstalled $LABEL"; exit 0
fi

[ -f "$LOOP" ] || { echo "FATAL: loop script not found: $LOOP" >&2; exit 1; }
chmod +x "$LOOP"

# Kill any bare (non-launchd) loop so we don't double-regenerate.
pkill -f "bank-dashboard-live.sh" 2>/dev/null || true
pkill -f "bank-dashboard-loop.sh" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$LOOP</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
    <key>DOCKER_HOST</key><string>$DOCKER_HOST_VAL</string>
    <key>SEEDBED_LEASE_DIR</key><string>$LEASE_DIR_VAL</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/workspace/bank-dashboard-agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/workspace/bank-dashboard-agent.log</string>
</dict>
</plist>
PLIST_EOF

# Reload cleanly (bootout old, bootstrap new). Fall back to legacy load -w.
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
  launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  launchctl kickstart -k "gui/$UID_NUM/$LABEL" 2>/dev/null || true
else
  launchctl load -w "$PLIST"   # legacy fallback
fi

sleep 2
echo "installed $LABEL -> $LOOP"
launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -E 'state =|pid =' | head -2 || \
  launchctl list | grep "$LABEL" || echo "(agent registered; check launchctl list)"
