// compact-plus OpenCode v1 adapter (developed and tested against v1.18.32;
// newer v1 releases are expected to work as long as the plugin API has no
// breaking changes).
//
// Thin edge adapter: OpenCode-specific host APIs (plugin hooks) stay here; every
// compact-plus decision runs through the testable bash core (scripts/opencode-core.sh).
// Install by placing or symlinking this file into .opencode/plugins/ or
// ~/.config/opencode/plugins/.
//
// Verified against OpenCode v1.18.32: plugin SDK calls made from inside the
// compaction hook re-enter the server and fail, so session data is captured
// through experimental.chat.messages.transform, which receives the message
// objects without an API round-trip. The default OpenCode backend is the
// deterministic core adapter; an LLM synthesis remains available through the
// existing COMPACT_PLUS_PRIMARY_BACKEND / COMPACT_PLUS_FALLBACK_BACKEND env vars.
//
// fail-open: adapter errors never propagate into OpenCode compaction.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PLUGIN_FILE = (() => {
  try {
    return fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return fileURLToPath(import.meta.url);
  }
})();
const ROOT = path.dirname(path.dirname(path.dirname(PLUGIN_FILE)));
const CORE = path.join(ROOT, "scripts", "opencode-core.sh");

function testLog(line) {
  if (!process.env.COMPACT_PLUS_OPENCODE_TEST_LOG) return;
  try {
    fs.appendFileSync(process.env.COMPACT_PLUS_OPENCODE_TEST_LOG, `${line}\n`);
  } catch {
    // fail-open
  }
}

// Session whose compaction is in progress; the next messages.transform for it is
// the compaction request, so that is where state capture happens.
let pendingCompaction = null;
// Last full message view per session, captured from normal-turn transforms.
const messageCache = new Map();
// Last assistant token usage per session, from message.updated events.
const lastUsage = new Map();

function core(subcommand, inputJson, timeoutMs = 120000) {
  const out = execFileSync("bash", [CORE, subcommand], {
    input: inputJson,
    env: { ...process.env, COMPACT_PLUS_RUNTIME: "opencode" },
    timeout: timeoutMs,
    encoding: "utf8",
  });
  return out.trim();
}

function runPipeline(sessionID, messages) {
  const prepared = JSON.parse(core("prepare", JSON.stringify({ session_id: sessionID, messages, todos: [] })));
  if (!prepared?.prompt) return;

  const envBackend = process.env.COMPACT_PLUS_PRIMARY_BACKEND || process.env.COMPACT_PLUS_FALLBACK_BACKEND;
  let state = "";
  if (envBackend) {
    try {
      state = core("run-backend", prepared.prompt);
    } catch {
      state = "";
    }
  }
  if (!state) {
    // No shell backend configured: use the deterministic OpenCode-native adapter.
    core("mechanical", JSON.stringify({ session_id: sessionID, messages, todos: [] }));
  } else {
    core("commit", JSON.stringify({
      session_id: sessionID,
      mode: prepared.mode,
      message_count: prepared.message_count,
      output: state,
    }));
  }
}

export const CompactPlusOpenCodePlugin = async () => {
  testLog(`plugin-loaded root=${ROOT}`);

  return {
    "experimental.session.compacting": async (input) => {
      try {
        if (!input.sessionID) return;
        pendingCompaction = input.sessionID;
      } catch {
        // fail-open
      }
    },

    "experimental.chat.messages.transform": async (_input, output) => {
      try {
        const messages = output.messages ?? [];
        if (!Array.isArray(messages) || messages.length === 0) return;

        if (pendingCompaction) {
          const sessionID = pendingCompaction;
          pendingCompaction = null;
          const source = messageCache.get(sessionID) ?? messages;
          runPipeline(sessionID, source);
          return;
        }

        // Normal turn: keep the fullest view for the next compaction capture.
        if (messages.length >= (messageCache.get(sessionIDOf(messages))?.length ?? 0)) {
          const sid = sessionIDOf(messages);
          if (sid) messageCache.set(sid, messages);
        }
      } catch {
        // fail-open
      }
    },

    "experimental.chat.system.transform": async (input, output) => {
      try {
        const sessionID = input.sessionID;
        if (!sessionID) return;
        const limit = input.model?.limit?.context ?? 0;
        const usage = lastUsage.get(sessionID) ?? 0;
        const result = JSON.parse(core("inject", JSON.stringify({ session_id: sessionID, tokens: usage, limit })));
        if (result?.text) output.system.push(result.text);
      } catch {
        // fail-open
      }
    },

    "command.execute.before": async (input) => {
      try {
        if (!input.sessionID || !input.command) return;
        core("record", JSON.stringify({ session_id: input.sessionID, command: input.command }));
      } catch {
        // fail-open
      }
    },

    "shell.env": async (input, output) => {
      try {
        if (input.sessionID) output.env.OPENCODE_SESSION_ID = input.sessionID;
        output.env.COMPACT_PLUS_OPENCODE_ROOT = ROOT;
      } catch {
        // fail-open
      }
    },

    event: async ({ event }) => {
      try {
        if (event.type === "session.compacted" && event.properties?.sessionID) {
          core("arm", JSON.stringify({ session_id: event.properties.sessionID }));
          return;
        }
        if (event.type === "message.updated") {
          const message = event.properties;
          if (message?.role === "assistant") {
            const t = message.tokens;
            const total = t?.total ?? ((t?.input ?? 0) + (t?.output ?? 0) + (t?.cache?.read ?? 0) + (t?.cache?.write ?? 0));
            lastUsage.set(message.sessionID, total);
          }
        }
      } catch {
        // fail-open
      }
    },
  };
};

function sessionIDOf(messages) {
  return messages[0]?.info?.sessionID ?? null;
}

export default CompactPlusOpenCodePlugin;
