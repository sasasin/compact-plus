# compact-plus

[Japanese README](./README.ja.md) | [Architecture](./docs/architecture.md)

A transparent Claude Code, Codex, and OpenCode plugin that preserves working state around `/compact`. It does not replace any runtime's compaction algorithm; it augments compaction through documented hooks. The OpenCode integration was developed and tested against **OpenCode v1.18.32**; newer v1 releases are expected to work as long as the plugin API has no breaking changes.

## What It Does

- Backs up the transcript before compaction and writes a 10-section state file with an LLM
- Injects the state file, plan file, and original-source reminder after compaction through `additionalContext`
- Recovers mechanically observable skills and commands; unobservable Codex skill use is recorded as `Not verified`
- When context usage crosses a configured threshold, the next user prompt receives a suggestion to run `/compact`
- Alongside that reminder, the plugin injects a three-line recitation (Active Plan, Current Phase, and the most recent Session Decision from the state file) into `additionalContext`, so the agent keeps its bearings during the last few turns before compaction actually runs. This does not change the compaction algorithm itself; it is a focus aid that reduces late-session drift between warn and the real `/compact`
- Provides the `/compact-plus` skill for manual state capture

## Usage

After installation, just run `/compact` as usual. **No additional action is required** — the flow is fully transparent.

- Both manual `/compact` and auto-compaction trigger the same hook path
- Before compaction: the PreCompact hook automatically backs up the transcript and generates the 10-section state file
- After compaction: Claude Code and Codex recover exactly once through `SessionStart(source=compact)` before the first post-compaction prompt. On OpenCode, recovery is injected exactly once on the first model turn after the `session.compacted` event
- The agent does not need to call any specific skill or perform any preparation

Optional enhancements:

- Pass an instruction such as `/compact keep the security-related decisions` to send priority guidance to the state-generation LLM
- Invoke `/compact-plus` manually right before compaction if you want to leave richer recovery notes; this switches to the fallback path where the agent writes the structured state itself

## Requirements

- Claude Code v2.x or later, or a Codex version with plugin compaction hooks
- An LLM backend through `claude -p` or `codex exec`
- The default configuration uses `claude -p --model claude-sonnet-5 --effort medium` as the primary backend and `codex exec --model gpt-5.3-codex-spark` as the fallback backend
- The Codex Spark fallback assumes ChatGPT Pro access. You can switch the fallback to models such as `gpt-5.4` or `gpt-5.5`

For the OpenCode path:

- OpenCode v1.18.32 (the tested baseline). Newer v1 releases are expected to work as long as the plugin API has no breaking changes
- `bash`, `jq`, and Unix filesystem semantics
- **No `claude` or `codex` executable is required.** The OpenCode default backend is the deterministic adapter in `scripts/opencode-core.sh`. If you configure `COMPACT_PLUS_PRIMARY_BACKEND` / `COMPACT_PLUS_FALLBACK_BACKEND`, those shell backends are used instead, so the OpenCode path can also run through any command you provide

## Installation

### Claude Code

Add this GitHub repository as a marketplace, then install the plugin from it.

```bash
claude plugin marketplace add u-ichi/compact-plus --scope user
claude plugin install compact-plus@compact-plus
```

### Codex

Add the same GitHub repository as a marketplace, then install the Codex plugin.

```bash
codex plugin marketplace add u-ichi/compact-plus
codex plugin add compact-plus@compact-plus
```

Review and trust the hook definitions when Codex prompts.
Start a new thread after installation so Codex loads the installed plugin and hooks.

### OpenCode

OpenCode loads local plugins from `.opencode/plugins/` (project) or `~/.config/opencode/plugins/` (global). No npm publication or marketplace installation is needed. The tested procedure is a symlink from the cloned repository:

```bash
mkdir -p ~/.config/opencode/plugins ~/.config/opencode/commands
ln -s "$HOME/src/github.com/sasasin/compact-plus/opencode/plugins/compact-plus.js" ~/.config/opencode/plugins/compact-plus.js
ln -s "$HOME/src/github.com/sasasin/compact-plus/opencode/commands/compact-plus.md" ~/.config/opencode/commands/compact-plus.md
```

Start a new OpenCode session so the plugin is loaded. The plugin resolves the repository root through its own real path, so the symlink must point at the cloned repository. Project-level placement (`<repo>/.opencode/plugins/compact-plus.js`) works the same way.

The manual fallback is the `/compact-plus` command (`opencode/commands/compact-plus.md`); the existing `skills/compact-plus/SKILL.md` is not in an OpenCode-discovered skill path, so symlink it into `~/.config/opencode/skills/compact-plus/SKILL.md` or `.opencode/skills/compact-plus/SKILL.md` if you want the skill form as well.

### Updating

Refresh the GitHub marketplace snapshot, then update or reinstall the plugin.

```bash
# Claude Code
claude plugin update compact-plus@compact-plus

# Codex
codex plugin marketplace upgrade compact-plus
codex plugin add compact-plus@compact-plus
```

For local development, replace `u-ichi/compact-plus` in the marketplace-add command with the absolute path to this repository.
The plugin reference remains `compact-plus@compact-plus`.

## Configuration

Following the Claude Code plugin model, write environment variables under the `env` block in `~/.claude/settings.json`. For temporary per-session overrides, shell `export` also works.

### Backend Overrides

Two environment variables replace the primary and fallback commands as whole shell commands.

| env var | Meaning |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | Complete shell command for the primary backend. Set to an empty string (`""`) to skip the primary backend |
| `COMPACT_PLUS_FALLBACK_BACKEND` | Complete shell command for the fallback backend. Set to an empty string to skip the fallback backend |

Environment variables available inside those commands:

- `$SYSTEM_PROMPT`: the LLM system prompt from `prompts/state-summary.md`
- `$SESSION_ID`: Claude Code session id
- `$TRANSCRIPT_PATH`: transcript JSONL path
- `$MAX_OUTPUT_TOKENS`: LLM output cap

Default values are embedded in `hooks/precompact-state-summary.sh`.

Example `~/.claude/settings.json` override for a lower-cost Haiku backend:

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt \"$SYSTEM_PROMPT\""
  }
}
```

Example replacing the primary backend with Codex Spark (requires ChatGPT Pro; served through Cerebras for higher throughput):

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "tmp=$(mktemp \"${TMPDIR:-/tmp}/compact-plus-codex.XXXXXX\"); { printf \"%s\\n\\n\" \"$SYSTEM_PROMPT\"; cat; } | codex exec --model gpt-5.3-codex-spark --sandbox read-only --skip-git-repo-check --dangerously-bypass-hook-trust --ignore-user-config --ephemeral --output-last-message \"$tmp\" - >/dev/null && cat \"$tmp\"; status=$?; rm -f \"$tmp\"; exit \"$status\""
  }
}
```

Codex output can prepend a CLI preamble to stdout, so `--output-last-message "$tmp"` is used to capture only the final message. This mirrors the default fallback implementation.

Example disabling the fallback:

```json
{
  "env": {
    "COMPACT_PLUS_FALLBACK_BACKEND": ""
  }
}
```

### Transcript, Squash, and Two-Pass Tuning

| env var | default | Meaning |
|---|---|---|
| `COMPACT_PLUS_TRANSCRIPT_MODE` | `incremental` | Transcript selection mode: `incremental`, `head-tail`, or `tail` |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | `5` | Number of turns to keep from the head side |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | `25` | Number of turns to keep from the tail side |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | `10` | Head-side byte cap in KB |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | `40` | Tail-side byte cap in KB |
| `COMPACT_PLUS_RAW_DELTA_FACTOR` | `20` | Incremental mode reads at most `TAIL_KB * N` of raw transcript delta before squashing. Set `0` for unbounded |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | `10` | Full rebuild every N runs. Set `0` to disable |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | `4096` | LLM output cap for backends that read it |
| `COMPACT_PLUS_BACKEND_TIMEOUT` | `80` | Per-backend timeout in seconds. Primary and fallback run serially inside the 180s hook budget. Set `0` to disable |
| `COMPACT_PLUS_SQUASH_ENABLED` | `1` | Enables or disables tool result squash |
| `COMPACT_PLUS_SQUASH_READ_LINES` | `100` | Replaces Read tool output above N lines with `[Read: N lines from path]` |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | `500` | Replaces Bash output above N characters with `[Bash: exit code, N chars output]` |
| `COMPACT_PLUS_TWO_PASS` | `1` | Enables or disables two-pass self-critique |

### Warn Thresholds

Claude Code and Codex use separate settings:

| Runtime | env var | default | Source |
|---|---|---:|---|
| Claude Code | `COMPACT_WARN_THRESHOLD` | base repository setting | `home/hooks/claude/statusline.sh` writes the marker consumed by this plugin |
| Codex | `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | `75` | compact-plus reads the latest token-count event from the current thread rollout |
| OpenCode | `COMPACT_PLUS_OPENCODE_WARN_THRESHOLD` | `75` | compact-plus uses the last assistant message's token usage against the model context limit exposed by the OpenCode v1 plugin API (tested on v1.18.32) |

Both values are context **usage** percentages. Changing one does not change the other. Codex uses the same effective-window basis as its context display by excluding the current 12,000-token fixed baseline. Codex also verifies that the rollout's `session_meta.id` matches the current `session_id`; missing, malformed, or mismatched rollout data produces no notification.

The OpenCode value is `last assistant total tokens / model context limit * 100`, computed from the `message.updated` event and the model limit passed to `experimental.chat.system.transform`. This is a real metric exposed by the v1 plugin API (verified on v1.18.32), not an estimate. The warning fires once per compaction cycle and the cooldown resets when compaction completes.

### `/compact` Arguments

When you pass natural-language instructions, such as `/compact keep the important design decisions`, compact-plus forwards those instructions to the state-generation LLM as priority guidance.

On the OpenCode v1 plugin API (verified on v1.18.32) this is **not supported**: the plugin API does not expose per-compaction user instructions (`/compact` is not a command-service command, and the compaction hook receives only `sessionID`). The state prompt records this as `(none)`. Put priorities in the conversation or in the state file before compacting.

## Runtime Flow

1. **PreCompact hook**
   - `precompact-transcript-backup.sh` copies the transcript JSONL to `~/.claude/backups/transcripts/` or `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/`
   - `precompact-state-summary.sh` applies semantic chunking and tool output squash to the transcript, then calls the primary or fallback backend and writes the 10-section state file
2. **PostCompact hook**
   - `compaction-recovery.sh` resets the warning cooldown, and either consumes the injected mark left by `SessionStart` or writes a recovery marker when no injection has happened yet
3. **Recovery hook**
   - `sessionstart-compaction-recovery.sh` handles `SessionStart(source=compact)` for both Claude Code and Codex
   - It injects the saved state content, active plan reference when present, and original-source reminder through `additionalContext`
   - The two runtimes order the compaction hooks differently, so the two hooks agree through a handshake rather than a fixed sequence. Claude Code dispatches `SessionStart(source=compact)` **before** `PostCompact`, so on the first compaction there is no marker yet; the hook injects on the strength of the state file and leaves an injected mark, and the later `PostCompact` consumes that mark instead of arming a marker. Codex dispatches `PostCompact` **first**, so the marker already exists and `SessionStart` consumes it. Either way the state is injected exactly once
   - `userpromptsubmit-compaction-recovery.sh` stays registered as the fallback channel. Codex dispatches the start hook to root threads only, so a thread-spawn subagent receives no start hook after compaction and recovers through the next `UserPromptSubmit`; parent messages reach a subagent as user input. The marker is consumed once, so a thread that already recovered at `SessionStart` is a no-op on the following prompt
   - `userpromptsubmit-compact-plus-reminder.sh` consumes warn markers and injects a lightweight notification plus a three-line state recitation when available
4. **SessionStart hook**
   - `sessionstart-export-session-id.sh` writes `export CLAUDE_CODE_SESSION_ID=<id>` to `$CLAUDE_ENV_FILE` so the `/compact-plus` skill can obtain the session id through the bundled `scripts/get-session-id.sh` wrapper without depending on any file outside the plugin
5. **Manual fallback (`/compact-plus` skill)**
   - The agent follows the `SKILL.md` 10-section procedure and writes the state file manually

### OpenCode flow

OpenCode exposes a different plugin surface, so the OpenCode integration is an adapter, not a port of the Claude/Codex hook scripts. All decisions live in `scripts/opencode-core.sh`; `opencode/plugins/compact-plus.js` is a thin edge adapter.

1. `experimental.session.compacting` marks the compaction in progress. Plugin SDK calls made from inside this hook re-enter the server and fail (verified on v1.18.32), so the adapter does not fetch messages here.
2. `experimental.chat.messages.transform` delivers the session messages without an API round-trip. During the compaction request the adapter passes them to the core, which writes the session backup, applies the existing head/tail/incremental selection and tool-output squash rules, and builds the state prompt.
3. State generation: configured shell backends (`COMPACT_PLUS_PRIMARY_BACKEND` / `COMPACT_PLUS_FALLBACK_BACKEND`) are honored unchanged; otherwise the deterministic OpenCode-native adapter writes the 10-section state file. Semantic sections that cannot be derived from observable facts stay `Not verified`.
4. The `session.compacted` event arms the one-shot recovery marker and resets the warning cooldown.
5. The first `experimental.chat.system.transform` after the event consumes the marker and injects the recovery payload (state content truncated at 30720 bytes, active plan pointer when present, saved-at staleness note, original-source reminder). Later turns stay quiet; a second compaction recovers again.
6. `shell.env` exports `OPENCODE_SESSION_ID` and `COMPACT_PLUS_OPENCODE_ROOT` so the manual `/compact-plus` command obtains the real session identity.

OpenCode storage uses `opencode-*` directories and `${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/backups/compact-plus/`; it never collides with `claude-*` or `codex-*` paths.

## State File Sections

State files start with `# Compact Prep State` and use the same 10-section order in both the manual skill and LLM-generated output.

1. `## Active Plan`
2. `## Current Phase`
3. `## TaskList Summary`
4. `## Session Decisions`
5. `## Constraints and Blockers`
6. `## Worker Topology`
7. `## Skills Invoked`
8. `## Editing Files`
9. `## Failed Attempts`
10. `## Recovery Notes`

## Marker Files

| path | writer | reader | Purpose |
|---|---|---|---|
| `${TMPDIR}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | recovery hook / agent | Pre-compaction state |
| `${TMPDIR}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Incremental byte offset |
| `${TMPDIR}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Refresh cycle counter |
| `${TMPDIR}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` / `userpromptsubmit-compaction-recovery.sh` | One-shot PostCompact marker |
| `${TMPDIR}/claude-compact-injected/<session_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | Injected mark: `SessionStart` already delivered the state, so `PostCompact` skips the marker |
| `${TMPDIR}/claude-compact-warn/<session_id>` | base repo `statusline.sh` | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning |
| `${TMPDIR}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline / recovery hook | Notification cooldown |
| `${TMPDIR}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan path |
| `${TMPDIR}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | Codex recovery hook / agent | Codex pre-compaction state |
| `${TMPDIR}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` / `userpromptsubmit-compaction-recovery.sh` | Codex one-shot recovery marker |
| `${TMPDIR}/codex-compact-injected/<thread_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | Codex injected mark for the same handshake |
| `${TMPDIR}/codex-compact-warned/<thread_id>` | reminder hook | reminder / recovery hook | Codex notification cooldown |
| `${TMPDIR}/opencode-compact-state/<session_id>.md` | `scripts/opencode-core.sh` | recovery injection / agent | OpenCode pre-compaction state |
| `${TMPDIR}/opencode-compact-state-offset/<session_id>` | `scripts/opencode-core.sh` | `scripts/opencode-core.sh` | OpenCode incremental message offset |
| `${TMPDIR}/opencode-compact-state-counter/<session_id>` | `scripts/opencode-core.sh` | `scripts/opencode-core.sh` | OpenCode refresh cycle counter |
| `${TMPDIR}/opencode-compacted/<session_id>` | `scripts/opencode-core.sh` (event) | `scripts/opencode-core.sh` (inject) | OpenCode one-shot recovery marker |
| `${TMPDIR}/opencode-compact-warned/<session_id>` | `scripts/opencode-core.sh` | reminder / recovery | OpenCode notification cooldown |
| `${TMPDIR}/opencode-active-plan/<session_id>` | plan-management hook | `scripts/opencode-core.sh` | OpenCode active plan pointer |
| `${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/backups/compact-plus/<epoch>-<session_id>.jsonl` | `scripts/opencode-core.sh` | recovery injection / agent | OpenCode session backup; newest 20 per session retained |

On Codex, `<thread_id>` is the thread that actually compacted. Hook input carries `session_id` as the identity shared by the root thread and all of its descendants, plus `agent_id` for a thread-spawn subagent, so every artifact is keyed on `agent_id` when present and on `session_id` otherwise (`compact_plus_artifact_key` in `scripts/runtime-paths.sh`). Keying on `session_id` alone would file a subagent's state under the parent and overwrite the parent's own state file.

## Architecture

See [docs/architecture.md](./docs/architecture.md) for the design overview, Claude Code and Codex CLI compaction comparison, hook boundaries, marker ownership, and source references.

## Development Checks

```bash
python3 -m json.tool .claude-plugin/plugin.json >/dev/null
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
python3 -m json.tool .codex-plugin/plugin.json >/dev/null
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
python3 -m json.tool hooks/hooks.json >/dev/null
bash -n hooks/*.sh scripts/*.sh tests/*.sh
bash tests/test-runtime.sh
bash tests/test-opencode.sh
bash tests/test-opencode-integration.sh   # requires an OpenCode v1 executable (tested on 1.18.32); skips otherwise
```
