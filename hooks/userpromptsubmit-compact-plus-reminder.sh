#!/bin/bash
# UserPromptSubmit hook: notify when context usage crosses the runtime-specific
# threshold and prompt compact-plus use through additionalContext (one-shot).
#
# Claude consumes the statusline marker. Codex reads the latest token_count
# event from the current thread rollout. PostCompact resets either cooldown.
#
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/runtime-paths.sh
source "$SCRIPT_DIR/../scripts/runtime-paths.sh"

INPUT=$(cat)
SESSION_ID=$(compact_plus_artifact_key "$INPUT")
[[ -z "$SESSION_ID" ]] && exit 0

WARN_DIR="$COMPACT_PLUS_WARN_DIR"
WARNED_DIR="$COMPACT_PLUS_WARNED_DIR"
WARN_MARKER="$WARN_DIR/$SESSION_ID"
WARNED_MARKER="$WARNED_DIR/$SESSION_ID"

if [[ "$COMPACT_PLUS_RUNTIME_NAME" == "codex" ]]; then
  # Codex hook input does not include context usage. Read the latest token_count
  # event from this thread's own rollout after verifying the session id.
  [[ -f "$WARNED_MARKER" ]] && exit 0
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
  [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || exit 0

  THRESHOLD="${COMPACT_PLUS_CODEX_WARN_THRESHOLD:-75}"
  [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || THRESHOLD=75
  [[ "$THRESHOLD" -ge 1 && "$THRESHOLD" -le 100 ]] || THRESHOLD=75
  BASELINE_TOKENS=12000

  ROLLOUT_SESSION_ID=$(
    head -n 20 "$TRANSCRIPT_PATH" 2>/dev/null \
      | jq -r 'select(.type == "session_meta") | .payload.id // empty' 2>/dev/null \
      | head -n 1
  )
  [[ "$ROLLOUT_SESSION_ID" == "$SESSION_ID" ]] || exit 0

  USAGE=$(
    tail -n 500 "$TRANSCRIPT_PATH" 2>/dev/null \
      | jq -rs '
        [
        .[]
        | select(.type == "event_msg" and .payload.type == "token_count")
        | .payload.info
        | select(
            (.last_token_usage.total_tokens | type) == "number"
            and (.model_context_window | type) == "number"
            and .model_context_window > 0
          )
        ] | last
      | [.last_token_usage.total_tokens, .model_context_window]
      | @tsv
      ' 2>/dev/null || true
  )
  [[ -n "$USAGE" ]] || exit 0
  USED_TOKENS=${USAGE%%$'\t'*}
  CONTEXT_WINDOW=${USAGE#*$'\t'}
  [[ "$CONTEXT_WINDOW" -gt "$BASELINE_TOKENS" ]] || exit 0
  EFFECTIVE_WINDOW=$((CONTEXT_WINDOW - BASELINE_TOKENS))
  EFFECTIVE_USED=$((USED_TOKENS - BASELINE_TOKENS))
  [[ "$EFFECTIVE_USED" -gt 0 ]] || EFFECTIVE_USED=0
  CTX_PCT=$((EFFECTIVE_USED * 100 / EFFECTIVE_WINDOW))
  [[ "$CTX_PCT" -le 100 ]] || CTX_PCT=100
  [[ "$CTX_PCT" -ge "$THRESHOLD" ]] || exit 0
else
  # Claude's statusline owns percentage calculation and writes this marker.
  [[ -f "$WARN_MARKER" ]] || exit 0
  CTX_PCT=$(cat "$WARN_MARKER" 2>/dev/null)
  CTX_PCT=${CTX_PCT:-"?"}
  rm -f "$WARN_MARKER" 2>/dev/null || true
fi

# Create the cooldown marker so the same session is not notified repeatedly.
mkdir -p "$WARNED_DIR" 2>/dev/null || true
printf '%s\n' "$(date +%s)" > "$WARNED_MARKER" 2>/dev/null || true

STATE_FILE="$COMPACT_PLUS_STATE_DIR/$SESSION_ID.md"

section_first_line() {
  local heading="$1"
  local file="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      line = $0
      sub(/^[[:space:]-]+/, "", line)
      if (line != "") {
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null
}

section_last_line() {
  local heading="$1"
  local file="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      line = $0
      sub(/^[[:space:]-]+/, "", line)
      if (line != "") {
        last = line
      }
    }
    END {
      if (last != "") print last
    }
  ' "$file" 2>/dev/null
}

CTX="[COMPACT REMINDER] context usage reached ${CTX_PCT}%."
if [[ -f "$STATE_FILE" ]]; then
  ACTIVE_PLAN=$(section_first_line "## Active Plan" "$STATE_FILE")
  CURRENT_PHASE=$(section_first_line "## Current Phase" "$STATE_FILE")
  SESSION_DECISION=$(section_last_line "## Session Decisions" "$STATE_FILE")
  CTX+=$'\n'"State recitation:"
  CTX+=$'\n'"- Active Plan: ${ACTIVE_PLAN:-Not verified}"
  CTX+=$'\n'"- Current Phase: ${CURRENT_PHASE:-Not verified}"
  CTX+=$'\n'"- Recent Session Decision: ${SESSION_DECISION:-Not verified}"
else
  CTX+=$'\n'"State recitation: no pre-compaction state file is available for this session."
fi
CTX+=$'\n'"- At a work boundary, tell the user they can run \`/compact\` as-is. The PreCompact hook automatically saves pre-compaction state."
CTX+=$'\n'"- Address the situation by saving pre-compaction state, not by shrinking scope or moving to another session."

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
exit 0
