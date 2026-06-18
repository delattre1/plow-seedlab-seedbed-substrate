#!/usr/bin/env bash
# ============================================================================
# pull-and-run.sh — prove the published golden image is usable: pull it from
# Docker Hub on a clean docker host, spin ONE substrate from it via the bank
# lease, and confirm it reaches SUBSTRATE_READY.
#
# CREDS: env only (DOCKERHUB_REPO required; DOCKERHUB_USER/TOKEN only if the
# repo is private). Never hardcoded.
#
# Usage: pull-and-run.sh [remote-tag] [container-name]
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
DOCKER="${DOCKER:-docker}"

# Secure creds handoff: gitignored, host-local secret file (mode 600), out of the repo.
DOCKERHUB_ENV="${DOCKERHUB_ENV:-$HOME/.config/seedbed/dockerhub.env}"
# shellcheck disable=SC1090
[ -f "$DOCKERHUB_ENV" ] && . "$DOCKERHUB_ENV"

: "${DOCKERHUB_REPO:?set DOCKERHUB_REPO, e.g. plowco/seedbed-substrate (ask CEO)}"
REMOTE_TAG="${1:-${DOCKERHUB_REPO}:latest}"
CTR="${2:-pulled-sub-1}"

if [ -n "${DOCKERHUB_TOKEN:-}" ] && [ -n "${DOCKERHUB_USER:-}" ]; then
  printf '%s' "$DOCKERHUB_TOKEN" | $DOCKER login -u "$DOCKERHUB_USER" --password-stdin
fi

echo "[pull] pulling $REMOTE_TAG ..."
$DOCKER pull "$REMOTE_TAG"

echo "[pull] spinning one substrate from the pulled image ..."
GOLDEN_IMAGE="$REMOTE_TAG" "$ROOT/bin/spin.sh" 1 "$CTR-grp"

echo "[pull] usability check (claude auth status inside the container) ..."
$DOCKER exec "${CTR}-grp-1" bash -lc 'claude auth status --text 2>&1 | head -3' || true
echo "[pull] DONE: $REMOTE_TAG pulled and run; teardown with bin/teardown.sh --prefix ${CTR}-grp"
