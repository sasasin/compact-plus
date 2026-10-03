---
description: Save compact-plus working state for the current OpenCode session before running /compact
---

You are running the compact-plus manual fallback for OpenCode v1
(tested against v1.18.32).

Strict procedure:

1. Get the real session id. Do not invent one.

   ```bash
   bash "$COMPACT_PLUS_OPENCODE_ROOT/scripts/get-session-id.sh"
   ```

   `$OPENCODE_SESSION_ID` is exported by the compact-plus OpenCode plugin through
   `shell.env`. If the command prints nothing, stop and report that preparation
   is incomplete because the session id is unavailable.

2. Resolve the OpenCode state directory. Do not write into the Claude or Codex
   state directories.

   ```bash
   bash "$COMPACT_PLUS_OPENCODE_ROOT/scripts/opencode-core.sh" paths
   ```

3. Check the current session todo list, the active plan pointer when one exists,
   skills and commands invoked earlier in this session, and the files currently
   being edited.

4. Write the state file to `<state_dir>/<session_id>.md` with these headings in
   this exact order:

   ```markdown
   # Compact Prep State
   ## Active Plan
   ## Current Phase
   ## TaskList Summary
   ## Session Decisions
   ## Constraints and Blockers
   ## Worker Topology
   ## Skills Invoked
   ## Editing Files
   ## Failed Attempts
   ## Recovery Notes
   ```

   Report facts supported by the current conversation. Write `Not verified` for
   anything that cannot be verified. If tmux-bridge is not used, write `Not used`
   under Worker Topology.

5. Read the state file back and verify that every heading above exists.

6. Tell the user: `Preparation complete. Please run /compact.`
