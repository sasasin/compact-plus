#!/usr/bin/env bash
# Automated tests for the compact-plus OpenCode v1 adapter core
# (developed and tested against v1.18.32).
#
# The OpenCode plugin itself is a thin edge adapter; every decision it relies on
# lives in scripts/opencode-core.sh, so these tests exercise the externally
# observable behavior of that core with fixtures. No claude or codex executable
# is required. Run: bash tests/test-opencode.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CORE="$ROOT/scripts/opencode-core.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/compact-plus-opencode-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export TMPDIR="$TEST_ROOT/tmp"
export HOME="$TEST_ROOT/home"
mkdir -p "$TMPDIR" "$HOME"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_file() {
  [[ -f "$1" ]] || fail "$2 (missing: $1)"
}

assert_not_file() {
  [[ ! -e "$1" ]] || fail "$2 (unexpected: $1)"
}

assert_contains() {
  printf '%s' "$1" | grep -Fq "$2" || fail "$3 (missing text: $2)"
}

assert_empty() {
  [[ -z "$1" ]] || fail "$2 (got: $1)"
}

assert_heading_order() {
  local file="$1"
  local message="${2:-heading order}"
  local expected
  expected=$(printf '%s\n' \
    '# Compact Prep State' \
    '## Active Plan' \
    '## Current Phase' \
    '## TaskList Summary' \
    '## Session Decisions' \
    '## Constraints and Blockers' \
    '## Worker Topology' \
    '## Skills Invoked' \
    '## Editing Files' \
    '## Failed Attempts' \
    '## Recovery Notes')
  local actual
  actual=$(grep -E '^(# Compact Prep State|## )' "$file" 2>/dev/null)
  [[ "$actual" == "$expected" ]] || fail "$message (heading order differs)"
}

make_state_backend() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CAPTURE_FILE:-}" ]]; then
  cat > "$CAPTURE_FILE"
else
  cat >/dev/null
fi
cat <<'STATE'
# Compact Prep State
## Active Plan
Not verified
## Current Phase
OpenCode adapter test
## TaskList Summary
Not verified
## Session Decisions
Keep OpenCode storage separate
## Constraints and Blockers
Not verified
## Worker Topology
Not used
## Skills Invoked
Not verified
## Editing Files
Not verified
## Failed Attempts
None
## Recovery Notes
Synthetic fixture
STATE
EOF
  chmod +x "$path"
}

# One OpenCode message: {info, parts}. parts must be valid JSON.
# The object value needs parentheses: jq rejects `"m" + (...)` without them.
msg() {
  jq -nc --arg role "$1" --argjson parts "$2" '{info: {role: $role, id: ("m" + ($parts | tostring))}, parts: $parts}'
}

run_core() {
  local sub="$1"
  local input="${2:-}"
  if [[ -z "$input" ]]; then
    input=$(cat)
  fi
  COMPACT_PLUS_RUNTIME=opencode bash "$CORE" "$sub" <<< "$input"
}

test_opencode_paths_are_separate() {
  local paths
  paths=$(run_core paths '{}')
  assert_contains "$paths" "opencode-compact-state" "OpenCode uses its own state directory"
  assert_contains "$paths" "opencode-compact-state" "OpenCode uses its own state directory"
  assert_contains "$paths" "backups/compact-plus" "OpenCode uses its own backup directory"
  printf '%s' "$paths" | grep -Eq 'claude-|codex-' && fail "OpenCode paths must not collide with Claude or Codex directories"

  # Runtime auto-detection for Claude and Codex is unchanged.
  local actual
  actual=$(env -u COMPACT_PLUS_RUNTIME -u PLUGIN_ROOT bash -c \
    'source "$1/scripts/runtime-paths.sh"; printf "%s" "$COMPACT_PLUS_RUNTIME_NAME"' _ "$ROOT")
  [[ "$actual" == "claude" ]] || fail "Claude runtime is still detected without PLUGIN_ROOT"
  actual=$(env -u COMPACT_PLUS_RUNTIME PLUGIN_ROOT="$ROOT" bash -c \
    'source "$1/scripts/runtime-paths.sh"; printf "%s" "$COMPACT_PLUS_RUNTIME_NAME"' _ "$ROOT")
  [[ "$actual" == "codex" ]] || fail "Codex runtime is still detected from PLUGIN_ROOT"
}

test_precompaction_state_capture() {
  local backend="$TEST_ROOT/backend.sh"
  local capture="$TEST_ROOT/capture.txt"
  make_state_backend "$backend"

  local messages
  messages=$(jq -nc --argjson m1 "$(msg user '[{"type":"text", "text":"continue the implementation"}]')" \
    --argjson m2 "$(msg assistant '[{"type":"tool", "tool":"read", "state":{"status":"completed", "input":{"filePath":"/tmp/project/src/app.ts"}, "output":"small read output"}}]')" \
    '[$m1, $m2]')

  local prepared
  prepared=$(COMPACT_PLUS_RUNTIME=opencode \
    COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" COMPACT_PLUS_FALLBACK_BACKEND="" \
    bash "$CORE" prepare <<< "$(jq -nc --argjson msgs "$messages" '{session_id: "oc-state", messages: $msgs, todos: [{content: "finish tests", status: "in_progress"}]}')")

  assert_contains "$prepared" '"mode":"initial"' "First capture builds an initial state"

  local state
  state=$(COMPACT_PLUS_RUNTIME=opencode CAPTURE_FILE="$capture" \
    COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" COMPACT_PLUS_FALLBACK_BACKEND="" \
    bash "$CORE" run-backend <<< "$(jq -r '.prompt' <<< "$prepared")")
  run_core commit <<< "$(jq -nc --arg s oc-state --arg m "$(jq -r '.mode' <<< "$prepared")" \
    --argjson c "$(jq -r '.message_count' <<< "$prepared")" --arg o "$state" \
    '{session_id: $s, mode: $m, message_count: $c, output: $o}')"

  assert_contains "$(cat "$capture")" "continue the implementation" "OpenCode message text reaches the state backend"
  assert_contains "$(cat "$capture")" "TaskList (session todo):" "State prompt includes the OpenCode todo list"
  assert_contains "$(cat "$capture")" "Skills and commands invoked this session:" "State prompt includes skill observation status"

  assert_file "$TMPDIR/opencode-compact-state/oc-state.md" "State file is keyed to the OpenCode session id"
  assert_not_file "$TMPDIR/claude-compact-state/oc-state.md" "OpenCode state does not use the Claude state directory"
  assert_not_file "$TMPDIR/codex-compact-state/oc-state.md" "OpenCode state does not use the Codex state directory"
  assert_heading_order "$TMPDIR/opencode-compact-state/oc-state.md" "State keeps the 10-section format in order"

  # Backup artifact exists and is named per session.
  if ! find "$HOME/.local/share/opencode/backups/compact-plus" -maxdepth 1 -type f -name '*-oc-state.jsonl' -print -quit 2>/dev/null | grep -q .; then
    fail "Pre-compaction session backup artifact is created"
  fi
}

test_sessions_do_not_overwrite_each_other() {
  local backend="$TEST_ROOT/backend.sh"
  make_state_backend "$backend"
  local messages
  messages=$(jq -nc --argjson m "$(msg user '[{"type":"text", "text":"session a work"}]')" '[$m]')

  for session in oc-a oc-b; do
    local prepared
    prepared=$(COMPACT_PLUS_RUNTIME=opencode COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
      COMPACT_PLUS_FALLBACK_BACKEND="" bash "$CORE" prepare <<< "$(jq -nc --arg s "$session" --argjson msgs "$messages" '{session_id: $s, messages: $msgs, todos: []}')")
    run_core commit <<< "$(jq -nc --arg s "$session" --arg m "$(jq -r '.mode' <<< "$prepared")" \
      --argjson c "$(jq -r '.message_count' <<< "$prepared")" --arg o "# Compact Prep State
## Recovery Notes
state for $session" '{session_id: $s, mode: $m, message_count: $c, output: $o}')"
  done

  assert_contains "$(cat "$TMPDIR/opencode-compact-state/oc-a.md")" "state for oc-a" "Session A keeps its own state"
  assert_contains "$(cat "$TMPDIR/opencode-compact-state/oc-b.md")" "state for oc-b" "Session B keeps its own state"
}

test_squash_is_preserved() {
  local read_text bash_text messages prepared
  read_text=$(awk 'BEGIN { for (i = 1; i <= 150; i++) printf "read line %d\n", i }')
  bash_text=$(awk 'BEGIN { for (i = 1; i <= 60; i++) printf "bash output chunk %d\n", i }')
  messages=$(jq -nc --arg r "$read_text" --arg b "$bash_text" '[
    {"info":{"role":"user","id":"u1"}, "parts":[{"type":"text", "text":"first turn"}]},
    {"info":{"role":"assistant","id":"a1"}, "parts":[{"type":"tool", "tool":"read", "state":{"status":"completed", "input":{"filePath":"/tmp/project/big.ts"}, "output":$r}}]},
    {"info":{"role":"assistant","id":"a2"}, "parts":[{"type":"tool", "tool":"bash", "state":{"status":"completed", "input":{"command":"ls"}, "output":$b}}]}
  ]')
  prepared=$(COMPACT_PLUS_RUNTIME=opencode bash "$CORE" prepare <<< "$(jq -nc --argjson msgs "$messages" '{session_id: "oc-squash", messages: $msgs, todos: []}')")
  assert_contains "$(jq -r '.prompt' <<< "$prepared")" "[Read: 150 lines from" "Large read output is squashed"
  assert_contains "$(jq -r '.prompt' <<< "$prepared")" "[ToolResult: " "Large tool output is squashed"
}

test_incremental_offset_and_refresh() {
  local backend="$TEST_ROOT/backend.sh"
  make_state_backend "$backend"
  local first second prepared

  first=$(jq -nc --argjson m "$(msg user '[{"type":"text", "text":"turn one"}]')" '[$m]')
  prepared=$(COMPACT_PLUS_RUNTIME=opencode COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" bash "$CORE" prepare <<< "$(jq -nc --argjson msgs "$first" '{session_id: "oc-inc", messages: $msgs, todos: []}')")
  run_core commit <<< "$(jq -nc --arg o "# Compact Prep State
## Recovery Notes
valid" '{session_id: "oc-inc", mode: "initial", message_count: 1, output: $o}')"

  second=$(jq -nc --argjson m1 "$(msg user '[{"type":"text", "text":"turn one"}]')" \
    --argjson m2 "$(msg user '[{"type":"text", "text":"turn two"}]')" '[$m1, $m2]')
  prepared=$(COMPACT_PLUS_RUNTIME=opencode COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" bash "$CORE" prepare <<< "$(jq -nc --argjson msgs "$second" '{session_id: "oc-inc", messages: $msgs, todos: []}')")
  assert_contains "$(jq -r '.prompt' <<< "$prepared")" "turn two" "Incremental capture includes new messages"
  printf '%s' "$(jq -r '.prompt' <<< "$prepared")" | grep -Fq "turn one" \
    && fail "Incremental capture does not resend already processed messages"
  assert_contains "$prepared" '"mode":"incremental"' "Incremental mode is reported"

  # Refresh cadence: counter 10 triggers a full head-tail refresh.
  printf '9\n' > "$TMPDIR/opencode-compact-state-counter/oc-inc"
  prepared=$(COMPACT_PLUS_RUNTIME=opencode COMPACT_PLUS_PRIMARY_BACKEND="bash \"$backend\"" \
    COMPACT_PLUS_FALLBACK_BACKEND="" bash "$CORE" prepare <<< "$(jq -nc --argjson msgs "$second" '{session_id: "oc-inc", messages: $msgs, todos: []}')")
  assert_contains "$prepared" '"mode":"refresh"' "Periodic refresh cadence is honored"
}

test_backup_retention_keeps_newest_20() {
  local dir="$HOME/.local/share/opencode/backups/compact-plus"
  mkdir -p "$dir"
  local i
  for i in $(seq 1 21); do
    printf '{"info":{"role":"user"},"parts":[]}\n' > "$dir/100000000$i-oc-retention.jsonl"
  done
  local messages
  messages=$(jq -nc --argjson m "$(msg user '[{"type":"text", "text":"retention run"}]')" '[$m]')
  run_core prepare <<< "$(jq -nc --argjson msgs "$messages" '{session_id: "oc-retention", messages: $msgs, todos: []}')" >/dev/null
  local count
  count=$(find "$dir" -maxdepth 1 -type f -name '*-oc-retention.jsonl' -print 2>/dev/null | wc -l | tr -d ' ')
  [[ "$count" == "20" ]] || fail "Backup retention keeps the newest 20 per session (got $count)"
}

test_state_generation_fails_open() {
  local before="$TMPDIR/opencode-compact-state"
  run_core prepare <<< '{"session_id":"", "messages":[{"info":{"role":"user"},"parts":[]}]}' >/dev/null
  assert_not_file "$before/missing-id.md" "Missing session id fails open without state"

  local messages
  messages=$(jq -nc --argjson m "$(msg user '[{"type":"text", "text":"fail open"}]')" '[$m]')
  COMPACT_PLUS_PRIMARY_BACKEND="" COMPACT_PLUS_FALLBACK_BACKEND="" \
    run_core prepare <<< "$(jq -nc --argjson msgs "$messages" '{session_id: "oc-fail", messages: $msgs, todos: []}')" >/dev/null
  run_core commit <<< "$(jq -nc '{session_id: "oc-fail", mode: "initial", message_count: 1, output: "not a state file"}')" >/dev/null
  assert_not_file "$before/oc-fail.md" "Invalid backend output fails open without partial state"
}

test_recovery_is_exactly_once() {
  mkdir -p "$TMPDIR/opencode-compact-state"
  printf '# Compact Prep State\n## Recovery Notes\nOpenCode recovery\n' > "$TMPDIR/opencode-compact-state/oc-recovery.md"

  run_core arm '{"session_id":"oc-recovery"}'
  local out
  out=$(run_core inject '{"session_id":"oc-recovery"}')
  assert_contains "$out" "OpenCode recovery" "Recovery injects the saved state once"
  assert_contains "$out" "COMPACTION RECOVERY" "Recovery uses the established header"
  assert_not_file "$TMPDIR/opencode-compacted/oc-recovery" "Recovery consumes the marker"

  out=$(run_core inject '{"session_id":"oc-recovery"}')
  assert_empty "$out" "Recovery is not injected again on later turns"

  # A second compaction in the same session can recover again.
  run_core arm '{"session_id":"oc-recovery"}'
  out=$(run_core inject '{"session_id":"oc-recovery"}')
  assert_contains "$out" "OpenCode recovery" "A second compaction triggers a second recovery"

  # A stale marker from an interrupted compaction does not permanently suppress
  # later recovery: after it is consumed once, the next arm still delivers.
  run_core arm '{"session_id":"oc-stale"}'
  out=$(run_core inject '{"session_id":"oc-stale"}')
  assert_contains "$out" "COMPACTION RECOVERY" "Stale marker path still injects once"
  out=$(run_core inject '{"session_id":"oc-stale"}')
  assert_empty "$out" "Stale marker is consumed once"
  run_core arm '{"session_id":"oc-stale"}'
  out=$(run_core inject '{"session_id":"oc-stale"}')
  assert_contains "$out" "COMPACTION RECOVERY" "Later compaction recovers after a stale marker"
}

test_recovery_reports_stale_state() {
  mkdir -p "$TMPDIR/opencode-compact-state"
  printf '# Compact Prep State\n## Recovery Notes\nOlder snapshot\n' > "$TMPDIR/opencode-compact-state/oc-stale-state.md"
  touch -t 202601010000 "$TMPDIR/opencode-compact-state/oc-stale-state.md"
  run_core arm '{"session_id":"oc-stale-state"}'
  local out
  out=$(run_core inject '{"session_id":"oc-stale-state"}')
  assert_contains "$out" "State saved at: " "Recovery reports when the state was saved"
  printf '%s' "$out" | grep -Eq 'State saved at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
    || fail "The saved-at line carries a real UTC timestamp"
  assert_contains "$out" "state generation failed" "Recovery makes staleness discoverable"
}

test_large_recovery_state_is_truncated() {
  mkdir -p "$TMPDIR/opencode-compact-state"
  {
    printf '# Compact Prep State\n## Recovery Notes\n'
    awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "state line %d padding padding padding\n", i }'
    printf 'TAIL_SENTINEL\n'
  } > "$TMPDIR/opencode-compact-state/oc-big.md"
  run_core arm '{"session_id":"oc-big"}'
  local out
  out=$(run_core inject '{"session_id":"oc-big"}')
  assert_contains "$out" "State truncated at 30720 bytes" "An oversized state is truncated"
  assert_contains "$out" "$TMPDIR/opencode-compact-state/oc-big.md" "Truncated injection points at the full file"
  printf '%s' "$out" | grep -Fq "TAIL_SENTINEL" && fail "Truncated injection stops before the oversized tail"
  printf '%s' "$out" | jq -e '.text' >/dev/null 2>&1 || fail "Truncated injection is still valid JSON"
}

test_warning_threshold_and_recitation() {
  mkdir -p "$TMPDIR/opencode-compact-state"
  printf '# Compact Prep State\n## Active Plan\nplan.md\n## Current Phase\nwarning test\n## Session Decisions\nUse a real metric\n## Recovery Notes\nx\n' \
    > "$TMPDIR/opencode-compact-state/oc-warn.md"

  # Below threshold: silent.
  local out
  out=$(COMPACT_PLUS_OPENCODE_WARN_THRESHOLD=75 run_core inject '{"session_id":"oc-warn","tokens":50000,"limit":100000}')
  assert_empty "$out" "No warning below the threshold"

  # At threshold: warns once with the three-line recitation.
  out=$(COMPACT_PLUS_OPENCODE_WARN_THRESHOLD=75 run_core inject '{"session_id":"oc-warn","tokens":75000,"limit":100000}')
  assert_contains "$out" "context usage reached 75%" "Warning fires at the configured threshold"
  assert_contains "$out" "Active Plan: plan.md" "Recitation includes Active Plan"
  assert_contains "$out" "Current Phase: warning test" "Recitation includes Current Phase"
  assert_contains "$out" "Recent Session Decision: Use a real metric" "Recitation includes the most recent Session Decision"
  assert_file "$TMPDIR/opencode-compact-warned/oc-warn" "Warning creates a cooldown marker"

  # Repeated prompts do not repeat the same warning before compaction.
  out=$(COMPACT_PLUS_OPENCODE_WARN_THRESHOLD=75 run_core inject '{"session_id":"oc-warn","tokens":90000,"limit":100000}')
  assert_empty "$out" "Warning is one-shot per compaction cycle"

  # Successful compaction resets the cooldown.
  run_core arm '{"session_id":"oc-warn"}'
  assert_not_file "$TMPDIR/opencode-compact-warned/oc-warn" "Compaction resets the warning cooldown"
  # The arm also armed the recovery marker, so the next turn delivers recovery
  # first; the warning path becomes reachable again after that marker is consumed.
  out=$(run_core inject '{"session_id":"oc-warn","tokens":80000,"limit":100000}')
  assert_contains "$out" "COMPACTION RECOVERY" "Compaction delivers recovery before the warning"
  out=$(COMPACT_PLUS_OPENCODE_WARN_THRESHOLD=75 run_core inject '{"session_id":"oc-warn","tokens":80000,"limit":100000}')
  assert_contains "$out" "context usage reached 80%" "Warning can fire again in the next cycle"

  # Helper sessions are excluded from warning logic.
  out=$(COMPACT_PLUS_OPENCODE_WARN_THRESHOLD=1 run_core inject '{"session_id":"oc-helper","tokens":99000,"limit":100000,"helper":true}')
  assert_empty "$out" "State-generation helper sessions do not warn"
}

test_session_id_detection() {
  local actual
  actual=$(env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u CODEX_COMPANION_SESSION_ID \
    OPENCODE_SESSION_ID="opencode-session-id" "$ROOT/scripts/get-session-id.sh" 2>/dev/null || true)
  [[ "$actual" == "opencode-session-id" ]] || fail "OPENCODE_SESSION_ID is detected as the OpenCode fallback"

  actual=$(CLAUDE_CODE_SESSION_ID="claude-session-id" OPENCODE_SESSION_ID="opencode-session-id" \
    "$ROOT/scripts/get-session-id.sh" 2>/dev/null || true)
  [[ "$actual" == "claude-session-id" ]] || fail "Claude session id keeps priority over OpenCode"
}

test_mechanical_state_builder() {
  local messages
  messages=$(jq -nc '[
    {"info":{"role":"user","id":"u1","sessionID":"oc-mech"},"parts":[{"type":"text","text":"build the adapter"}]},
    {"info":{"role":"assistant","id":"a1","sessionID":"oc-mech"},"parts":[{"type":"tool","tool":"skill","state":{"status":"completed","input":{"name":"compact-plus"},"output":"loaded"}},{"type":"tool","tool":"edit","state":{"status":"error","input":{"filePath":"/tmp/x.ts"},"error":"permission denied"}}]}
  ]')
  run_core mechanical <<< "$(jq -nc --argjson msgs "$messages" '{session_id: "oc-mech", messages: $msgs, todos: [{content: "finish", status: "in_progress"}]}')"
  local f="$TMPDIR/opencode-compact-state/oc-mech.md"
  assert_file "$f" "Mechanical adapter writes a state file"
  assert_heading_order "$f" "Mechanical state keeps the 10-section format"
  assert_contains "$(cat "$f")" "build the adapter" "Mechanical state records the last user request"
  assert_contains "$(cat "$f")" "compact-plus" "Mechanical state records invoked skills"
  assert_contains "$(cat "$f")" "permission denied" "Mechanical state records failed attempts"
  assert_contains "$(cat "$f")" "in_progress: finish" "Mechanical state records the todo list"
}

test_manual_fallback_surfaces() {
  local command_file="$ROOT/opencode/commands/compact-plus.md"
  assert_file "$command_file" "OpenCode manual fallback command exists"
  assert_contains "$(cat "$command_file")" "get-session-id.sh" "Manual fallback obtains the real session id"
  assert_contains "$(cat "$command_file")" "opencode-core.sh" "Manual fallback uses the OpenCode state directory"
  assert_contains "$(cat "$command_file")" "Preparation complete. Please run /compact." "Manual fallback reports completion"
  for h in '# Compact Prep State' '## Active Plan' '## Current Phase' '## TaskList Summary' \
    '## Session Decisions' '## Constraints and Blockers' '## Worker Topology' \
    '## Skills Invoked' '## Editing Files' '## Failed Attempts' '## Recovery Notes'; do
    assert_contains "$(cat "$command_file")" "$h" "Manual fallback declares heading $h"
  done
}

test_plugin_adapter_surface() {
  local plugin="$ROOT/opencode/plugins/compact-plus.js"
  assert_file "$plugin" "OpenCode plugin adapter exists"
  for hook in 'experimental.session.compacting' 'experimental.chat.messages.transform' 'experimental.chat.system.transform' 'session.compacted' 'shell.env' 'command.execute.before'; do
    assert_contains "$(cat "$plugin")" "$hook" "Plugin wires the $hook surface"
  done
  assert_contains "$(cat "$plugin")" 'COMPACT_PLUS_RUNTIME: "opencode"' "Plugin selects OpenCode storage through the core"
  printf '%s' "$(cat "$plugin")" | grep -Fq 'claude -p' && fail "Plugin must not depend on the claude executable"
  printf '%s' "$(cat "$plugin")" | grep -Fq 'codex exec' && fail "Plugin must not depend on the codex executable"
}

test_opencode_paths_are_separate
test_precompaction_state_capture
test_sessions_do_not_overwrite_each_other
test_squash_is_preserved
test_incremental_offset_and_refresh
test_backup_retention_keeps_newest_20
test_state_generation_fails_open
test_recovery_is_exactly_once
test_recovery_reports_stale_state
test_large_recovery_state_is_truncated
test_warning_threshold_and_recitation
test_session_id_detection
test_mechanical_state_builder
test_manual_fallback_surfaces
test_plugin_adapter_surface

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s OpenCode test assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'All compact-plus OpenCode tests passed\n'
