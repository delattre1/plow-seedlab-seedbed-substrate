#!/usr/bin/env bash
# ============================================================================
# lease.sh — atomic auth-volume lease manager for the substrate AUTH BANK.
#
# THE rule (critical): one auth volume is used by AT MOST ONE live container at
# a time. Concurrent reuse of a claude-auth volume = auth theft (two Claude
# processes rotate each other's refresh tokens) -> Anthropic logs us out.
#
# Race prevention: acquisition is an ATOMIC test-and-set via mkdir(2). POSIX
# guarantees mkdir fails if the directory already exists, and the create+check
# is one indivisible syscall — so under N concurrent `acquire` calls, exactly
# ONE wins each free volume. No two callers can ever lease the same volume.
#
# State store: one lock directory per volume under $LEASE_DIR. Presence = leased.
# Holder + timestamp recorded inside. Release = remove the lock dir (the VOLUME
# itself is never touched — kept for the next container, per teardown doctrine).
#
# IMPORTANT: the lease store coordinates atomicity on a SINGLE host. Run all
# spin/teardown for one bank on one coordinator host (the docker host) so every
# acquire hits the same $LEASE_DIR. No secrets are stored here — only volume
# names and holder labels.
#
# Usage:
#   lease.sh init                 # ensure bank volumes exist + clear stale leases
#   lease.sh acquire <holder>     # atomically lease next-free volume; prints name
#                                 #   exit 0 = leased (volume name on stdout)
#                                 #   exit 3 = NO_FREE_VOLUME (fail-fast, nothing leased)
#   lease.sh release <volume>     # release a specific volume's lease (keeps volume)
#   lease.sh release-holder <h>   # release whatever volume <h> holds
#   lease.sh status               # print each bank volume: FREE | USED <holder> <ts>
#   lease.sh free-count           # print number of currently-free volumes
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANK_FILE="${BANK_FILE:-$HERE/../bank/volumes.txt}"
LEASE_DIR="${LEASE_DIR:-${SEEDBED_LEASE_DIR:-/run/seedbed-bank/leases}}"
DOCKER="${DOCKER:-docker}"   # honors DOCKER_HOST (e.g. ssh://server)

die(){ echo "lease: $*" >&2; exit 2; }

# Bank = the ordered list of auth-volume names in bank/volumes.txt (comments/blank ok).
bank_volumes(){
  [ -f "$BANK_FILE" ] || die "bank file not found: $BANK_FILE"
  grep -vE '^\s*(#|$)' "$BANK_FILE" | awk '{print $1}'
}

ensure_lease_dir(){ mkdir -p "$LEASE_DIR" 2>/dev/null || die "cannot create LEASE_DIR=$LEASE_DIR"; }

cmd_init(){
  ensure_lease_dir
  local v created=0 existed=0
  for v in $(bank_volumes); do
    if $DOCKER volume inspect "$v" >/dev/null 2>&1; then existed=$((existed+1))
    else $DOCKER volume create "$v" >/dev/null && created=$((created+1)); fi
    # clear any stale lease (only safe to call when no containers are live)
    rm -rf "${LEASE_DIR:?}/$v" 2>/dev/null || true
  done
  echo "bank initialized: $(bank_volumes | wc -l | tr -d ' ') volumes (existed=$existed created=$created); leases cleared"
}

# Atomic acquire: first volume whose lock dir we can mkdir is ours.
cmd_acquire(){
  local holder="${1:?usage: acquire <holder>}"
  ensure_lease_dir
  local v lock
  for v in $(bank_volumes); do
    lock="$LEASE_DIR/$v"
    if mkdir "$lock" 2>/dev/null; then          # <-- atomic test-and-set
      printf '%s\t%s\n' "$holder" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/holder"
      echo "$v"
      return 0
    fi
  done
  echo "NO_FREE_VOLUME" >&2
  return 3                                       # fail-fast: bank full, nothing leased
}

cmd_release(){
  local v="${1:?usage: release <volume>}"
  rm -rf "${LEASE_DIR:?}/$v" && echo "released $v (volume kept)"
}

cmd_release_holder(){
  local h="${1:?usage: release-holder <holder>}"
  local v lock hit=0
  for v in $(bank_volumes); do
    lock="$LEASE_DIR/$v"
    if [ -f "$lock/holder" ] && [ "$(cut -f1 "$lock/holder")" = "$h" ]; then
      rm -rf "$lock"; echo "released $v held by $h (volume kept)"; hit=1
    fi
  done
  [ "$hit" = 1 ] || { echo "no lease held by $h" >&2; return 1; }
}

cmd_status(){
  ensure_lease_dir
  local v lock
  for v in $(bank_volumes); do
    lock="$LEASE_DIR/$v"
    if [ -d "$lock" ]; then
      printf 'USED\t%s\t%s\n' "$v" "$( [ -f "$lock/holder" ] && tr '\t' ' ' < "$lock/holder" || echo '?')"
    else
      printf 'FREE\t%s\n' "$v"
    fi
  done
}

cmd_free_count(){
  ensure_lease_dir
  local v n=0
  for v in $(bank_volumes); do [ -d "$LEASE_DIR/$v" ] || n=$((n+1)); done
  echo "$n"
}

case "${1:-}" in
  init)            cmd_init ;;
  acquire)         shift; cmd_acquire "$@" ;;
  release)         shift; cmd_release "$@" ;;
  release-holder)  shift; cmd_release_holder "$@" ;;
  status)          cmd_status ;;
  free-count)      cmd_free_count ;;
  *) die "usage: lease.sh {init|acquire <holder>|release <vol>|release-holder <h>|status|free-count}" ;;
esac
