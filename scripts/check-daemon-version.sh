#!/usr/bin/env bash
#
# check-daemon-version.sh — is the running pockettts daemon built from HEAD?
#
# Queries GET /health for the running binary's git SHA and compares it to the
# repo's current HEAD. Exits 0 if current, 1 if stale/mismatched, 2 if the
# daemon isn't reachable.
#
# Usage: scripts/check-daemon-version.sh [port]   (default 8891)
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-${POCKETTTS_PORT:-8891}}"
cd "$REPO"

HEAD_SHA="$(git rev-parse --short HEAD)"

HEALTH="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
if [ -z "$HEALTH" ]; then
  echo "✗ daemon not reachable on :$PORT"
  exit 2
fi

# Pull git_sha out of the JSON (jq if present, else a sed fallback).
if command -v jq >/dev/null 2>&1; then
  RUN_SHA="$(printf '%s' "$HEALTH" | jq -r '.git_sha // "unknown"')"
  RUN_BRANCH="$(printf '%s' "$HEALTH" | jq -r '.branch // "?"')"
  RUN_BUILT="$(printf '%s' "$HEALTH" | jq -r '.built_at // "?"')"
  RUN_DIRTY="$(printf '%s' "$HEALTH" | jq -r '.dirty // "?"')"
else
  RUN_SHA="$(printf '%s' "$HEALTH" | sed -n 's/.*"git_sha"[: ]*"\([^"]*\)".*/\1/p')"
  RUN_BRANCH="?"; RUN_BUILT="?"; RUN_DIRTY="?"
  [ -n "$RUN_SHA" ] || RUN_SHA="unknown"
fi

echo "running : $RUN_SHA (branch $RUN_BRANCH · dirty $RUN_DIRTY · built $RUN_BUILT)"
echo "HEAD    : $HEAD_SHA"

if [ "$RUN_SHA" = "$HEAD_SHA" ] && [ "$RUN_DIRTY" != "true" ]; then
  echo "✓ daemon is current"
  exit 0
fi

echo "✗ STALE — running daemon does not match HEAD; redeploy with scripts/deploy-daemon.sh --restart"
exit 1
