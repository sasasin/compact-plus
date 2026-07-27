#!/bin/bash
# PostCompact hook (matcher: ""): record compaction with a marker file.
# PostCompact does not support additionalContext output, so context injection is
# handled by UserPromptSubmit on Claude Code, and on Codex by
# SessionStart(source=compact) for root threads plus UserPromptSubmit for
# thread-spawn subagents, which get no start hook after compaction.
#
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/runtime-paths.sh
source "$SCRIPT_DIR/../scripts/runtime-paths.sh"

INPUT=$(cat)
SESSION_ID=$(compact_plus_artifact_key "$INPUT")
[[ -z "$SESSION_ID" ]] && exit 0

# Write the marker file. The runtime-specific recovery hook consumes it once.
MARKER_DIR="$COMPACT_PLUS_MARKER_DIR"
mkdir -p "$MARKER_DIR" 2>/dev/null || true
printf '%s\n' "$(date +%s)" > "$MARKER_DIR/$SESSION_ID" 2>/dev/null || true

# Reset the compact reminder cooldown after compact runs.
WARN_DIR="$COMPACT_PLUS_WARNED_DIR"
rm -f "$WARN_DIR/$SESSION_ID" 2>/dev/null || true

exit 0
