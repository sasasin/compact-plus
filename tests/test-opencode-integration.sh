#!/usr/bin/env bash
# Integration test for the compact-plus OpenCode v1 adapter.
#
# Runs against the actual OpenCode v1 executable (developed and tested on
# v1.18.32) with a local mock provider, so the OpenCode path is exercised
# without claude or codex being
# installed. Verifies the lifecycle ordering that exactly-once recovery depends
# on, observed from the running runtime rather than assumed:
#
#   experimental.session.compacting marks the compaction in progress
#     -> experimental.chat.messages.transform delivers the session data
#        (state capture; plugin API calls from inside the hook re-enter the
#        server and fail, so capture rides on the transform)
#     -> compaction completes
#     -> session.compacted event arms the recovery marker
#     -> next model turn injects recovery exactly once
#     -> later turns stay quiet
#     -> a second compaction recovers again
#
# Run: bash tests/test-opencode-integration.sh
# Skips with exit 0 when opencode is not available or is older than the
# tested v1.18.32 baseline. Newer v1 releases are accepted as long as the
# plugin API has no breaking changes.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MIN_VERSION="1.18.32"

if ! command -v opencode >/dev/null 2>&1; then
  printf 'SKIP: opencode executable not found\n'
  exit 0
fi
VERSION=$(opencode --version 2>/dev/null)
MAJOR=$(printf '%s' "$VERSION" | cut -d. -f1)
if [[ "$MAJOR" != "1" ]]; then
  printf 'SKIP: opencode v1 required, found %s\n' "$VERSION"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -n 1)" != "$MIN_VERSION" ]]; then
  printf 'SKIP: opencode %s or newer required, found %s\n' "$MIN_VERSION" "$VERSION"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 required for the mock provider\n'
  exit 0
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/compact-plus-opencode-integration.XXXXXX")
MOCK_PID=""
SERVE_PID=""
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT/.opencode/plugins" "$TEST_ROOT/home"
ln -s "$ROOT/opencode/plugins/compact-plus.js" "$PROJECT/.opencode/plugins/compact-plus.js"

export HOME="$TEST_ROOT/home"
export COMPACT_PLUS_OPENCODE_TEST_LOG="$TEST_ROOT/order.log"

cat > "$PROJECT/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "mock": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Mock",
      "options": {
        "baseURL": "http://127.0.0.1:4100/v1",
        "apiKey": "test-key"
      },
      "models": {
        "test-model": {
          "name": "Test Model",
          "limit": { "context": 100000, "output": 1000 }
        }
      }
    }
  },
  "model": "mock/test-model"
}
EOF

cat > "$TEST_ROOT/mock.py" <<'EOF'
import http.server, json

STATE = ("# Compact Prep State\n## Active Plan\nNot verified\n## Current Phase\nIntegration test\n"
         "## TaskList Summary\nNot verified\n## Session Decisions\nMock provider\n"
         "## Constraints and Blockers\nNot verified\n## Worker Topology\nNot used\n"
         "## Skills Invoked\nNot verified\n## Editing Files\nNot verified\n"
         "## Failed Attempts\nNone\n## Recovery Notes\nIntegration state\n")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        body = {"id": "cmpl-1", "object": "chat.completion", "created": 1700000000,
                "model": "test-model",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": STATE},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}}
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def log_message(self, *a):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", 4100), Handler).serve_forever()
EOF

python3 "$TEST_ROOT/mock.py" >/dev/null 2>&1 &
MOCK_PID=$!
sleep 1

(cd "$PROJECT" && exec opencode serve --port 4101 >"$TEST_ROOT/serve.log" 2>&1) &
SERVE_PID=$!
sleep 6

P=http://127.0.0.1:4101
api() { curl -s -m 45 "$@"; }

FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

SID=$(api -X POST "$P/session" -H 'Content-Type: application/json' -d '{"title":"integration"}' | jq -r '.id // empty')
[[ -n "$SID" && "$SID" != "null" ]] || { fail "session created"; exit 1; }

api -X POST "$P/session/$SID/message" -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"first prompt"}]}' >/dev/null

# Compaction 1.
api -X POST "$P/session/$SID/summarize" -H 'Content-Type: application/json' \
  -d '{"providerID":"mock","modelID":"test-model"}' >/dev/null
sleep 2

# First post-compaction turn must inject once; the next must stay quiet.
api -X POST "$P/session/$SID/message" -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"second prompt"}]}' >/dev/null
sleep 1
api -X POST "$P/session/$SID/message" -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"third prompt"}]}' >/dev/null
sleep 1

# Compaction 2 must recover again.
api -X POST "$P/session/$SID/summarize" -H 'Content-Type: application/json' \
  -d '{"providerID":"mock","modelID":"test-model"}' >/dev/null
sleep 2
api -X POST "$P/session/$SID/message" -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"fourth prompt"}]}' >/dev/null
sleep 1

LOG="$TEST_ROOT/order.log"
STATE_DIR="${TMPDIR:-/tmp}/opencode-compact-state"

grep -q "^prepare session=$SID" "$LOG" || fail "state capture ran through messages.transform during compaction"
grep -q "^arm session=$SID" "$LOG" || fail "session.compacted event armed the recovery marker"
injects=$(grep -c "^inject-recovery session=$SID" "$LOG")
[[ "$injects" == "2" ]] || fail "recovery injected once per compaction (got $injects for 2 compactions)"
[[ ! -e "${TMPDIR:-/tmp}/opencode-compacted/$SID" ]] || fail "recovery marker consumed after injection"

[[ -f "$STATE_DIR/$SID.md" ]] || fail "state file created for the OpenCode session id"
[[ "$(head -n 1 "$STATE_DIR/$SID.md")" == "# Compact Prep State" ]] || fail "state file starts with the required heading"
find "$HOME/.local/share/opencode/backups/compact-plus" -maxdepth 1 -type f -name "*-$SID.jsonl" -print -quit 2>/dev/null | grep -q . || fail "session backup artifact created"

# Capture must precede the event, and the event must precede injection.
prepare_line=$(grep -n "^prepare session=$SID" "$LOG" | head -n 1 | cut -d: -f1)
arm_line=$(grep -n "^arm session=$SID" "$LOG" | head -n 1 | cut -d: -f1)
inject_line=$(grep -n "^inject-recovery session=$SID" "$LOG" | head -n 1 | cut -d: -f1)
if [[ -n "$prepare_line" && -n "$arm_line" && -n "$inject_line" ]]; then
  [[ "$prepare_line" -lt "$arm_line" ]] || fail "capture ran before the compaction event"
  [[ "$arm_line" -lt "$inject_line" ]] || fail "the event armed the marker before injection"
else
  fail "lifecycle ordering recorded"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s integration assertion(s) failed\n' "$FAILURES" >&2
  printf '--- order.log ---\n%s\n' "$(cat "$LOG")" >&2
  exit 1
fi

printf 'OpenCode %s integration test passed\n' "$VERSION"
exit 0
