#!/usr/bin/env bash
# ============================================================================
# reap-dead-leases.sh — release fleet-bank leases whose HOLDER CONTAINER IS GONE.
#
# The lease is a per-volume lock dir under $LEASE_DIR; its `holder` file names the
# container that leased it. A container that dies WITHOUT running teardown.sh (crash,
# reboot, docker rm) leaks its lease forever — the volume looks "leased" with no live
# holder, silently starving the bank (we found 9 such week-old leaks on 2026-07-02).
#
# This reaper releases ONLY leases whose holder container no longer exists — proven by
# `docker inspect <holder>` FAILING. It NEVER touches a lease whose holder still exists
# (running OR stopped). Volumes are always kept (lease-only release), same as teardown.
# Idempotent + safe to run on a timer (see the hourly cron in Install below).
#
# Usage:  reap-dead-leases.sh [--dry-run]
#
# Install the hourly cron (server-side, runs as the fleet user):
#   ( crontab -l 2>/dev/null | grep -v reap-dead-leases;
#     echo "17 * * * * . \$HOME/.config/seedbed/substrate.env; \
#     \$HOME/plow-seedlab-seedbed-substrate/bin/reap-dead-leases.sh >> \
#     \$HOME/.seedbed-bank/reap.log 2>&1" ) | crontab -
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
# Host-local env supplies BANK_FILE + SEEDBED_LEASE_DIR (the bank spins actually use).
# shellcheck disable=SC1090
[ -f "$HOME/.config/seedbed/substrate.env" ] && . "$HOME/.config/seedbed/substrate.env"

LEASE="$ROOT/lease/lease.sh"
DOCKER="${DOCKER:-docker}"
LEASE_DIR="${LEASE_DIR:-${SEEDBED_LEASE_DIR:-/run/seedbed-bank/leases}}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
[ -d "$LEASE_DIR" ] || { echo "$(ts) reap: no lease dir ($LEASE_DIR) — nothing to do"; exit 0; }

reaped=0; kept=0
for d in "$LEASE_DIR"/*/; do
  [ -d "$d" ] || continue                       # no locks -> glob stays literal -> skip
  vol="$(basename "$d")"
  holder="$(cut -f1 "$d/holder" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$holder" ]; then
    echo "$(ts) reap: KEEP $vol (no holder file — leave for a human)"; kept=$((kept+1)); continue
  fi
  # The ONE safety gate: a lease is reaped ONLY if its holder container is truly gone.
  if $DOCKER inspect "$holder" >/dev/null 2>&1; then
    kept=$((kept+1))                            # holder exists (running or stopped) -> never yank
  else
    if [ "$DRY" = 1 ]; then
      echo "$(ts) reap: WOULD release $vol (holder '$holder' gone)"
    else
      echo "$(ts) reap: release $vol (holder '$holder' gone) -> $($LEASE release "$vol" 2>&1)"
    fi
    reaped=$((reaped+1))
  fi
done
echo "$(ts) reap: ${reaped} reaped, ${kept} kept$([ "$DRY" = 1 ] && echo ' (dry-run)'), free now=$($LEASE free-count 2>/dev/null)"
