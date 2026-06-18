#!/usr/bin/env bash
#
# deploy-daemon.sh — build the headless pockettts daemon with a stamped version
# and deploy it to the PAI daemon bin.
#
# Stamps headless/BuildInfo.swift with the real git SHA / branch / dirty flag /
# timestamp, does a release build (into a /tmp scratch path to dodge the
# dual-mount ModuleCache collision), restores BuildInfo.swift, then copies the
# binary into ~/Library/Application Support/pai/pocket-coreml-bin/.
#
# The deployed binary then reports its provenance via `pockettts --version` and
# GET /health, so check-daemon-version.sh can tell whether the latest is running.
#
# Usage:
#   scripts/deploy-daemon.sh [version-tag] [--restart]
#     version-tag   optional human tag (default: short SHA)
#     --restart     gracefully stop the running daemon after deploy so its
#                   supervisor respawns on the new binary (default: leave the
#                   old process running; new binary activates on next start)
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${POCKETTTS_BIN_DIR:-$HOME/Library/Application Support/pai/pocket-coreml-bin}"
BIN="$BIN_DIR/pockettts"
PORT="${POCKETTTS_PORT:-8891}"
SCRATCH="${POCKETTTS_SCRATCH:-/tmp/pockettts-release}"
BUILDINFO="$REPO/headless/BuildInfo.swift"

cd "$REPO"

RESTART=false
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=true ;;
    *) VERSION="$arg" ;;
  esac
done

SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -n "$VERSION" ] || VERSION="$SHA"

# dirty = any tracked change EXCEPT BuildInfo.swift (which we are about to stamp).
if [ -n "$(git status --porcelain --untracked-files=no -- . ':!headless/BuildInfo.swift')" ]; then
  DIRTY=true
else
  DIRTY=false
fi

# Restore from a file backup (not `git checkout`) so it works whether or not
# BuildInfo.swift is committed/tracked.
cp "$BUILDINFO" "$BUILDINFO.orig"
restore() { [ -f "$BUILDINFO.orig" ] && mv -f "$BUILDINFO.orig" "$BUILDINFO" || true; }
trap restore EXIT

cat > "$BUILDINFO" <<EOF
//
//  BuildInfo.swift — AUTO-STAMPED by scripts/deploy-daemon.sh.
//  Restored to its committed default after the build (git checkout). Do not edit.
//

// MARK: - BuildInfo

nonisolated enum BuildInfo {
    static let gitSHA  = "$SHA"
    static let branch  = "$BRANCH"
    static let dirty   = $DIRTY
    static let builtAt = "$BUILT_AT"
    static let version = "$VERSION"

    static var summary: String {
        "pockettts \\(version) (\\(gitSHA)\\(dirty ? "-dirty" : "") · \\(branch) · built \\(builtAt))"
    }
}
EOF

echo "→ building release  sha=$SHA  branch=$BRANCH  dirty=$DIRTY  tag=$VERSION"
swift build -c release --scratch-path "$SCRATCH"
ART="$SCRATCH/release/pockettts"
[ -x "$ART" ] || { echo "ERROR: build artifact not found at $ART" >&2; exit 1; }

if "$RESTART"; then
  echo "→ stopping running daemon on :$PORT (graceful)…"
  curl -fsS -X POST "http://127.0.0.1:$PORT/shutdown" >/dev/null 2>&1 || true
  sleep 1
fi

mkdir -p "$BIN_DIR"
# Replace via temp + atomic rename: the running process keeps its old inode
# (no "Text file busy"); the new binary lands under a fresh inode.
cp "$ART" "$BIN.new"
chmod +x "$BIN.new"
mv -f "$BIN.new" "$BIN"
echo "→ deployed: $("$BIN" --version)"

if "$RESTART"; then
  echo "→ note: restart relies on the daemon's supervisor (VoiceServer/launchd) respawning it."
  echo "        verify with: scripts/check-daemon-version.sh"
else
  echo "→ binary replaced; the OLD process keeps running until restarted."
  echo "        restart it your usual way (or re-run with --restart), then:"
  echo "        scripts/check-daemon-version.sh"
fi
