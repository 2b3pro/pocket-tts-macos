#!/usr/bin/env bash
# Strip non-stock voice KV states from Resources/ before building a
# release archive. Only the seven Kyutai stock voices (alba, azelma,
# cosette, fantine, javert, jean, marius) are safe to bundle in
# public binaries — anything else in voice_kv_states/ is local-only
# and gets removed here so it never ships.
#
# Workflow:
#   ./scripts/strip-custom-voices.sh    # before archiving
#   xcodebuild archive ...
#   # sign + notarize the archive
#   ./scripts/sync-assets.sh            # restore dev state
#
# Idempotent — running twice is a no-op once everything's stripped.
# Nothing is destroyed here that sync-assets.sh can't restore from
# its upstream source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VOICE_DIR="$PROJECT_ROOT/pocket-tts-macos/Resources/voice_kv_states"

# The seven Kyutai-stock voices that ship with the open
# `pocket-tts-without-voice-cloning` weights. Anything else under
# voice_kv_states/ at archive time is a licensing risk.
STOCK_VOICES=(alba azelma cosette fantine javert jean marius)

if [[ ! -d "$VOICE_DIR" ]]; then
    echo "error: voice_kv_states directory not found at $VOICE_DIR" >&2
    echo "       run ./scripts/sync-assets.sh first" >&2
    exit 1
fi

removed=0
kept=0
for f in "$VOICE_DIR"/*.safetensors; do
    [[ -e "$f" ]] || continue          # empty directory guard
    name=$(basename "$f" .safetensors)
    is_stock=false
    for s in "${STOCK_VOICES[@]}"; do
        [[ "$name" == "$s" ]] && is_stock=true
    done
    if $is_stock; then
        kept=$((kept + 1))
    else
        rm "$f"
        removed=$((removed + 1))
    fi
done

echo "stripped $removed custom voice(s); kept $kept Kyutai-stock voice(s)"
echo "ready to archive — restore with ./scripts/sync-assets.sh after"
