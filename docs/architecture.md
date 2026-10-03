# compact-plus Architecture

[Japanese architecture](./architecture.ja.md) | [README](../README.md) | [Japanese README](../README.ja.md)

compact-plus is a Claude Code, Codex, and OpenCode plugin that captures working state around context compaction. It does not replace any runtime's compaction implementation. It uses documented hook events to save the source transcript and a structured state summary before compaction, then injects recovery guidance after compaction. The OpenCode integration was developed and tested against v1.18.32 and follows a different plugin surface, so its lifecycle is described separately in section 3b rather than pretending the hook protocols are identical. Newer v1 releases are expected to work as long as the plugin API has no breaking changes.

## 1. Goals and Non-Goals

### Goals

- Preserve task state before Claude Code or Codex compacts context.
- Keep recovery data outside the compacted conversation summary.
- Make the next user prompt after compaction reread the saved state, relevant plan file, and original instruction sources when needed.
- Keep hook failures non-blocking so compaction can continue.
- Support configurable LLM backends without editing installed hook files.

### Non-Goals

- compact-plus does not change Claude Code's or Codex's internal compaction algorithm.
- compact-plus does not provide a documented replacement for Claude Code's compaction prompt. The checked Claude Code documentation exposes `/compact [instructions]` and hook-based extension points, but no official user setting equivalent to Codex CLI `compact_prompt`.
- compact-plus does not trigger `/compact` or inject terminal input. Forced auto-compaction through Herdr is a separate design.
- compact-plus does not own the base repository's Claude statusline threshold hook; it consumes that hook's marker. Codex notification is plugin-owned and uses the current thread rollout.

## 2. Claude Code Compaction Surface

Claude Code exposes `/compact` as a slash command that summarizes the conversation to free context. It also accepts optional text after the command, for example `/compact focus on the current implementation plan`, and passes that text as compact instructions.

Claude Code hook events relevant to compact-plus:

| Event | compact-plus use |
|---|---|
| `PreCompact` | Back up the transcript and generate the state file before compaction |
| `PostCompact` | Consume the injected mark or write a recovery marker, and reset the warning cooldown after compaction |
| `SessionStart`, matcher `compact` | Inject saved state through `additionalContext` before the first post-compaction prompt |
| `UserPromptSubmit` | Fallback delivery when no `SessionStart(source=compact)` reached the thread |

Claude Code dispatches `SessionStart(source=compact)` **before** `PostCompact` within one compaction, which is the reverse of Codex. Section 5 describes the handshake that makes recovery independent of that order.

Claude Code plugin hooks are configured through `hooks/hooks.json`. For `PreCompact` and `PostCompact`, Claude Code documents `manual` and `auto` matcher values. Claude Code also documents command, HTTP, and MCP tool hooks for those compact events. compact-plus uses command hooks.

Claude Code settings can provide environment variables through the `env` key in `settings.json`. compact-plus uses that setting surface for backend and transcript tuning. Claude Code also documents `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, which changes the auto-compaction threshold percentage. That threshold setting is separate from compact-plus state capture.

## 3. Codex CLI Compaction Surface

Codex CLI has a separate compaction model and configuration surface. compact-plus ships a Codex plugin manifest and uses Codex hooks around manual and automatic compaction.

Codex CLI documents:

| Surface | Meaning |
|---|---|
| `/compact` | Summarizes visible conversation to free tokens |
| Auto compaction | Codex can compact long tasks automatically when context space is low |
| `model_auto_compact_token_limit` | Token threshold for auto compaction |
| `compact_prompt` | Inline prompt text used for compaction |
| `experimental_compact_prompt_file` | File path for a compaction prompt |
| `PreCompact` / `PostCompact` hooks | Command hooks around manual or auto compaction |
| Session transcripts | Local session data under `$CODEX_HOME/sessions`, defaulting to `~/.codex/sessions` |

Codex hooks are command-only in the checked manual. `PreCompact` and `PostCompact` expose fields such as `session_id`, `turn_id`, `transcript_path`, and `trigger`, where `trigger` is `manual` or `auto`. `SessionStart` supports matcher `compact` and `additionalContext`. The transcript format is convenient but not a stable hook interface, so parsing fails open.

### compact-plus Codex layer

The Codex plugin uses the same state-generation scripts as the Claude Code plugin, but `scripts/runtime-paths.sh` selects separate storage from the `PLUGIN_ROOT` environment variable. Codex state, incremental offsets, refresh counters, recovery markers, plan pointers, warning cooldowns, and transcript backups therefore do not share paths with Claude Code sessions. The Codex transcript backups live under `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/`.

Manual and automatic compaction follow the same Codex hook sequence:

1. `PreCompact` creates a versioned transcript backup and the structured state file for the current thread id.
2. `PostCompact` writes a one-shot recovery marker and clears the thread's warning cooldown.
3. Codex's built-in compact summary continues the thread immediately.
4. Before the first post-compaction prompt, `SessionStart(source=compact)` consumes the marker and adds the saved state content, optional plan path, and original-source reminder through `additionalContext`.

"Current thread id" above is `agent_id` when hook input carries it and `session_id` otherwise. Codex sets `session_id` to the identity shared by the root thread and all of its descendants, and adds `agent_id` for a thread-spawn subagent, so a subagent keyed on `session_id` alone would store its state under the parent and overwrite the parent's own state file.

Step 4 applies to root threads only. Codex dispatches `SessionStart(source=compact)` to a thread-spawn subagent's start only when the start source is `Startup`; after compaction the subagent receives no start hook at all. Its recovery therefore arrives through the next `UserPromptSubmit`, which does run for subagents because parent messages are delivered as user input. Both channels read the same one-shot marker, so exactly one of them injects.

The Codex notification does not depend on Claude Code's statusline marker. On each eligible prompt, compact-plus reads the latest usable `token_count` event from the final 500 transcript records after verifying that the rollout's `session_meta.id` equals the hook input's `session_id`. A missing transcript, an unreadable or mismatched `session_meta`, or no usable `token_count` event in those records produces no notification. A newer unusable event does not discard an earlier usable event in the same range.

Codex's displayed context includes a fixed 12,000-token baseline in the checked runtime. compact-plus uses the same effective-window basis:

```text
effective usage % =
  max(total tokens - 12,000, 0)
  / (model context window - 12,000)
  * 100
```

`COMPACT_PLUS_CODEX_WARN_THRESHOLD` controls the notification point and defaults to `75`. Values outside `1` through `100` fall back to `75`. After a notification, a thread-specific cooldown suppresses repeats until `PostCompact` clears it. The notification adds the current state file's Active Plan, Current Phase, and most recent Session Decision when available.

This layer only recommends `/compact` at a work boundary. It does not execute the command or inject terminal input; Herdr-driven forced compaction remains a separate design.

The default compaction prompt shipped by Codex is deliberately handoff-oriented. The template at [`codex-rs/prompts/templates/compact/prompt.md`](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/prompt.md) frames compaction as "CONTEXT CHECKPOINT COMPACTION" and requires the summarizing LLM to include four sections:

1. Current progress and key decisions made
2. Important context, constraints, or user preferences
3. What remains to be done (clear next steps)
4. Any critical data, examples, or references needed to continue

This is the built-in handoff engineering that users of Codex get without any configuration.

The OpenAI Responses API also has server-side context compaction through `context_management` and the `/responses/compact` endpoint. That API returns an encrypted compaction item and is not the same mechanism as Claude Code plugin hooks.

## 3b. OpenCode v1 Compaction Surface (tested on v1.18.32)

OpenCode v1 exposes a plugin API rather than command hooks. The integration is an adapter boundary: `opencode/plugins/compact-plus.js` is a thin edge that reads OpenCode data, and `scripts/opencode-core.sh` holds every compact-plus decision so it is testable without a JavaScript runtime. The behavior below was verified on the v1.18.32 runtime; newer v1 releases are expected to behave the same as long as the plugin API has no breaking changes.

| Surface | Meaning for compact-plus |
|---|---|
| `experimental.session.compacting` | Fires before the compaction LLM call. Marks the compaction in progress; it receives only `sessionID` |
| `experimental.chat.messages.transform` | Delivers the message objects during the compaction request. This is the capture channel, because plugin SDK calls made from inside the compaction hook re-enter the server and fail |
| `session.compacted` event | Published after a successful compaction. Arms the one-shot recovery marker and resets the warning cooldown |
| `experimental.chat.system.transform` | Delivery channel for recovery and warning text on the next model turn |
| `chat.message` / `command.execute.before` | Not used for injection; `command.execute.before` records invoked commands for the Skills Invoked section |
| `shell.env` | Exports `OPENCODE_SESSION_ID` and `COMPACT_PLUS_OPENCODE_ROOT` for the manual fallback |

There is no `transcript_path` hook field on OpenCode. The source data is the session message list (`Array<{info, parts}>`), and the backup artifact is that list serialized as one message JSON object per line under `${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/backups/compact-plus/`, newest 20 per session retained.

Lifecycle ordering observed on the running runtime:

1. `experimental.session.compacting` marks the compaction in progress.
2. `experimental.chat.messages.transform` delivers the messages; the core writes the backup, applies the existing head/tail/incremental selection and squash rules, and builds the state prompt.
3. State generation runs through the configured shell backend when `COMPACT_PLUS_PRIMARY_BACKEND` or `COMPACT_PLUS_FALLBACK_BACKEND` is set. Otherwise the deterministic OpenCode-native adapter writes the state file. A nested model call from inside the compaction hook is unsafe on the v1 plugin API (it re-enters the server, verified on v1.18.32), so the OpenCode default backend does not depend on any external CLI executable.
4. The `session.compacted` event arms the marker and clears the warning cooldown.
5. The first `experimental.chat.system.transform` after the event consumes the marker and injects the recovery payload exactly once. Repeated turns stay quiet; a second compaction arms a new marker and recovers again. A stale marker from an interrupted compaction is consumed once and does not suppress later compactions.

The warning metric is real on the v1 plugin API (verified on v1.18.32): the last assistant message's token usage against the model context limit, passed through `experimental.chat.system.transform`. `COMPACT_PLUS_OPENCODE_WARN_THRESHOLD` (default `75`) controls the notification point; the warning fires once per compaction cycle and includes the three-line recitation when a state file exists.

OpenCode storage uses `opencode-*` directories and the OpenCode data backup directory, so it never collides with `claude-*` or `codex-*` paths. Artifacts are keyed on the OpenCode `sessionID`.

Known OpenCode parity gaps:

- Per-compaction natural-language instructions (`/compact <text>`) are not exposed through the plugin API, so priority guidance cannot be forwarded on this runtime.
- OpenCode v1 (checked on v1.18.32) has no durable plan artifact contract. The active-plan pointer is honored only when an external plan-management hook writes `opencode-active-plan/<session_id>`; otherwise `## Active Plan` stays `Not verified`. The session todo list is used for `## TaskList Summary`.
- The deterministic default backend records observable facts; semantic synthesis (decisions, rationale) requires a configured LLM backend.

## 4. Compaction Capability Comparison

Compared along user-facing outcomes ("can the session actually continue past compaction?"), not implementation mechanisms.

| Outcome | Claude Code (baseline) | Codex CLI (built-in) | Claude Code or Codex + compact-plus |
|---|---|---|---|
| Session goal survives compaction | △ (relies on unstructured summary; easy to dilute) | ○ (CONTEXT CHECKPOINT prompt requires progress and key decisions as sections) | ○ (externalized to `## Active Plan` and `## Current Phase`) |
| Remaining work is handed off clearly | △ (same as above) | ○ (requires "remaining work (clear next steps)" as a section) | ○ (externalized to `## TaskList Summary` and `## Recovery Notes`) |
| Important decisions are preserved | △ (same as above) | ○ (requires "key decisions made" as a section) | ○ (externalized to `## Session Decisions`) |
| Skills invoked earlier can be recovered | × | × | ○ when transcript evidence exists; otherwise `Not verified` |
| Scope drift in the summary's memory / rule mentions is corrected | × | × | ○ (recovery hook injects an "originals are authoritative" factual note) |
| User can name priorities in natural language before compaction | △ (`/compact <text>` reaches hooks; the built-in effect on the summary is undocumented) | × (no documented per-compaction natural-language argument) | Claude: ○ (instructions are forwarded to the state-generation LLM); Codex: × (record priorities in the conversation or state before compacting) |
| The original transcript is preserved | ○ (transcript JSONL persists in place) | ○ (rollout file preserves the whole transcript) | ○ (plus runtime-specific versioned backups) |
| Agent and user are warned before context runs out | △ (statusline percentage only) | × (requires custom implementation) | ○ (Claude marker or Codex token-count notification plus a three-line recitation) |
| A manual, structured recovery-note path is available | × | × | ○ (the `/compact-plus` skill) |
| User can replace the compaction prompt itself | × | ○ (`compact_prompt` and `experimental_compact_prompt_file`) | Out of scope by design (does not touch the compaction prompt) |

compact-plus does not touch either compaction prompt. It places structured state outside compaction and re-injects it afterwards, adding explicit recovery references and separate threshold warnings to both runtimes.

## 5. Runtime Flow

1. `PreCompact` starts.
2. `precompact-transcript-backup.sh` copies the transcript JSONL to the runtime-specific backup directory.
3. `precompact-state-summary.sh` reads the transcript according to the configured mode:
   - `incremental`: read new bytes since the previous run, with periodic full refresh.
   - `head-tail`: keep early context and recent context.
   - `tail`: keep only recent context.
4. `precompact-state-summary.sh` applies tool output squash to large Read and Bash outputs.
5. The script calls the primary backend. If that fails and fallback is enabled, it calls the fallback backend.
6. The state file is written to the runtime-specific state directory.
7. The compaction hooks run. Their order differs by runtime, so steps 8 and 9 happen in the opposite sequence on each:
   - Claude Code: `SessionStart(source=compact)` first, then `PostCompact`.
   - Codex: `PostCompact` first, then `SessionStart(source=compact)`.
8. `compaction-recovery.sh` removes its warning cooldown marker. If an injected mark is present, `SessionStart` already delivered the state, so it consumes that mark and writes no recovery marker. Otherwise it writes the runtime-specific marker.
9. `sessionstart-compaction-recovery.sh` injects before the first post-compaction prompt. It takes whichever handshake signal exists: a marker means `PostCompact` already ran, so it consumes it; no marker with a state file on disk means `SessionStart` ran first, so it injects and leaves an injected mark for step 8. With neither signal it stays silent and leaves the `PostCompact` to `UserPromptSubmit` fallback intact. A Codex thread-spawn subagent receives no start hook after compaction, so it always recovers through that fallback. The recovery hook injects:
   - saved state file content, truncated at 30720 bytes with a pointer to the full file,
   - active plan path when present,
   - original-source factual note.
10. Claude consumes the statusline marker. Codex calculates usage from the latest current-thread token-count event and warns at `COMPACT_PLUS_CODEX_WARN_THRESHOLD` (default `75`).

Because the injected mark is written only by a `SessionStart` that actually produced output, a runtime that never dispatches that hook never grows a mark, and its `PostCompact` keeps arming the marker for the `UserPromptSubmit` fallback.

The mark is trusted only while it is newer than the state file it covers. A `PostCompact` that never finishes, because the hook timed out or the process was killed, leaves its mark behind. Treating that leftover as authoritative would make the next compaction disappear from every channel at once: `SessionStart` would skip on the mark, `PostCompact` would consume the mark instead of arming a marker, and the fallback would have nothing to deliver. Comparing timestamps confines a leaked mark to the compaction it leaked from, since the next `PreCompact` writes a state file newer than it. Equal timestamps count as delivered, because the mark is always written after the state file and a tie therefore means the same compaction.

The injected payload also reports when the state file was written. When `PreCompact`'s backend fails, the previous state file stays on disk and is injected again, so the timestamp is what tells the reader that the state predates the work just compacted.

## 6. State File Format

Generated state files and manually created `/compact-plus` state files share the same heading order:

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

The stable heading order lets hooks and agents skim the file predictably after compaction. The state file is not treated as more authoritative than original project files, rules, skills, or plans. Recovery guidance explicitly reminds the agent to reread original sources when the compacted summary mentions them.

## 7. Marker Files and Ownership

| Path | Writer | Reader | Ownership rule |
|---|---|---|---|
| `${TMPDIR:-/tmp}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` or `/compact-plus` skill | recovery hook and agent | State payload. Rewritten by each state-generation run |
| `${TMPDIR:-/tmp}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Incremental transcript offset. Internal to state generation |
| `${TMPDIR:-/tmp}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Refresh cadence counter. Internal to state generation |
| `${TMPDIR:-/tmp}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` and `userpromptsubmit-compaction-recovery.sh` | One-shot recovery trigger. Written only when `SessionStart` has not already injected |
| `${TMPDIR:-/tmp}/claude-compact-injected/<session_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | Injected mark. Tells a later `PostCompact` that the state was already delivered |
| `${TMPDIR:-/tmp}/claude-compact-warn/<session_id>` | Base repository statusline hook | `userpromptsubmit-compact-plus-reminder.sh` | Threshold warning. compact-plus reads but does not own the producer |
| `${TMPDIR:-/tmp}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline side and recovery hook | Notification cooldown |
| `${TMPDIR:-/tmp}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | Active plan pointer. compact-plus reads but does not own the producer |
| `${TMPDIR:-/tmp}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` or `/compact-plus` skill | Codex recovery hook and agent | Codex state payload |
| `${TMPDIR:-/tmp}/codex-compact-state-offset/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex incremental transcript offset |
| `${TMPDIR:-/tmp}/codex-compact-state-counter/<thread_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | Codex full-refresh cadence counter |
| `${TMPDIR:-/tmp}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` and `userpromptsubmit-compaction-recovery.sh` | Codex one-shot recovery trigger |
| `${TMPDIR:-/tmp}/codex-compact-injected/<thread_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | Codex injected mark for the same handshake |
| `${TMPDIR:-/tmp}/codex-active-plan/<thread_id>` | Optional external plan-management hook | Codex recovery hook | Optional Codex active-plan pointer |
| `${TMPDIR:-/tmp}/codex-compact-warned/<thread_id>` | reminder hook | reminder and recovery hook | Codex notification cooldown |
| `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/<epoch>-<thread_id>.jsonl` | `precompact-transcript-backup.sh` | Codex recovery hook and agent | Versioned Codex transcript backup; the newest 20 per thread are retained |

Hook scripts fail open. If a marker is missing, malformed, or already consumed, the hooks continue without blocking the user prompt or compaction.

## 8. Configuration Boundaries

compact-plus owns the following environment variables:

| env var | Scope |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | Primary LLM backend command |
| `COMPACT_PLUS_FALLBACK_BACKEND` | Fallback LLM backend command |
| `COMPACT_PLUS_TRANSCRIPT_MODE` | Transcript selection mode |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | Head-side turn count |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | Tail-side turn count |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | Head-side byte cap |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | Tail-side byte cap |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | Full refresh cadence |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | Backend output cap |
| `COMPACT_PLUS_SQUASH_ENABLED` | Tool output squash toggle |
| `COMPACT_PLUS_SQUASH_READ_LINES` | Read output squash threshold |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | Bash output squash threshold |
| `COMPACT_PLUS_TWO_PASS` | Two-pass critique toggle |
| `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | Codex effective context usage notification threshold; default `75` |
| `COMPACT_PLUS_OPENCODE_WARN_THRESHOLD` | OpenCode context usage notification threshold; default `75` |

The base repository owns Claude's `COMPACT_WARN_THRESHOLD`, because the producer is `home/hooks/claude/statusline.sh`. The two threshold settings are independent.

## 9. Source Notes

The architecture statements above were checked against official documentation:

- [Claude Code slash commands](https://code.claude.com/docs/en/commands)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [OpenAI Codex hooks](https://developers.openai.com/codex/hooks)
- [OpenAI Codex config reference](https://developers.openai.com/codex/config-reference)
- [OpenAI Codex manual](https://developers.openai.com/codex/codex-manual.md)
- [OpenAI Responses API compaction guide](https://developers.openai.com/api/docs/guides/compaction)
