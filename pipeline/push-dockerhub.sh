#!/usr/bin/env bash
# ============================================================================
# push-dockerhub.sh — tag the golden image and push it to Docker Hub.
#
# CREDS: read from the environment ONLY (never hardcoded, never committed). The
# public GitHub repo stays secret-free. Provide via your shell / a gitignored
# env file / CI secret store:
#   DOCKERHUB_USER   Docker Hub username
#   DOCKERHUB_TOKEN  Docker Hub access token (NOT your password; revocable)
#   DOCKERHUB_REPO   target repo, e.g. plowco/seedbed-substrate   <-- ASK CEO
#
# Usage: push-dockerhub.sh [local-image] [remote-tag]
#   local-image  default: $GOLDEN_IMAGE (seedbed-golden:latest)
#   remote-tag   default: $DOCKERHUB_REPO:latest  (also pushes :$VERSION if set)
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/bank/bank.env" ] && . "$ROOT/bank/bank.env"
DOCKER="${DOCKER:-docker}"

# Secure creds handoff: a GITIGNORED, host-local secret file (mode 600), placed
# OUT of the repo. The CEO writes it; this script reads it. Never on the board,
# the repo, or a chat. Override with DOCKERHUB_ENV.
DOCKERHUB_ENV="${DOCKERHUB_ENV:-$HOME/.config/seedbed/dockerhub.env}"
# shellcheck disable=SC1090
[ -f "$DOCKERHUB_ENV" ] && . "$DOCKERHUB_ENV"

: "${DOCKERHUB_USER:?set DOCKERHUB_USER (env only; never commit)}"
: "${DOCKERHUB_TOKEN:?set DOCKERHUB_TOKEN (access token; env only; never commit)}"
: "${DOCKERHUB_REPO:?set DOCKERHUB_REPO, e.g. plowco/seedbed-substrate (ask CEO)}"

LOCAL_IMAGE="${1:-${GOLDEN_IMAGE:-seedbed-golden:latest}}"
REMOTE_TAG="${2:-${DOCKERHUB_REPO}:latest}"

echo "[push] docker login as $DOCKERHUB_USER ..."
printf '%s' "$DOCKERHUB_TOKEN" | $DOCKER login -u "$DOCKERHUB_USER" --password-stdin

echo "[push] tag $LOCAL_IMAGE -> $REMOTE_TAG"
$DOCKER tag "$LOCAL_IMAGE" "$REMOTE_TAG"
$DOCKER push "$REMOTE_TAG"

if [ -n "${VERSION:-}" ]; then
  $DOCKER tag "$LOCAL_IMAGE" "${DOCKERHUB_REPO}:${VERSION}"
  $DOCKER push "${DOCKERHUB_REPO}:${VERSION}"
  echo "[push] also pushed ${DOCKERHUB_REPO}:${VERSION}"
fi

$DOCKER logout >/dev/null 2>&1 || true
echo "[push] DONE: $REMOTE_TAG published to Docker Hub"
