// Rune's opencode hook.
//
// Installed with `rune install-opencode-hook`, which copies this into
// ~/.config/opencode/plugin/ and registers it in opencode.json. It exists
// because opencode's own database is a record of what happened, and Rune needs
// to know what is happening: reading the database means inferring a live turn
// from the absence of a completion timestamp, on a 15-second poll, and being
// wrong in between.
//
// opencode publishes exactly the right thing instead. `session.status` carries
// {type: "busy"} and {type: "idle"} outright, so the state is stated rather
// than reconstructed, and it arrives the moment it changes.
//
// The file this writes is the whole interface. Rune reads it and nothing else;
// if this plugin isn't installed, Rune falls back to the database and behaves
// as it did before.

import { mkdirSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";

const STATE = join(homedir(), ".local", "state", "rune", "opencode.json");

export const Rune = async () => {
  // sessionID -> what that session is doing, and where.
  const sessions = new Map();

  // The server this plugin lives in. Rune uses it to tell a live session from
  // one left behind by a server that has since exited — opencode's server is
  // detached (its parent is launchd), so it outlives the terminal that started
  // it and would otherwise leave a "working" that never ends.
  const pid = process.pid;

  function flush() {
    const payload = { pid, sessions: Object.fromEntries(sessions) };
    try {
      mkdirSync(dirname(STATE), { recursive: true });
      // Written beside and renamed over: Rune polls this file, and a reader
      // that catches a half-written one gets nothing rather than nonsense.
      const temporary = `${STATE}.${pid}.tmp`;
      writeFileSync(temporary, JSON.stringify(payload));
      renameSync(temporary, STATE);
    } catch {
      // A terminal indicator is not worth breaking someone's session over.
    }
  }

  function remember(sessionID, changes) {
    const previous = sessions.get(sessionID) ?? {};
    sessions.set(sessionID, {
      ...previous,
      ...changes,
      pid,
      at: Math.floor(Date.now() / 1000),
    });
    flush();
  }

  return {
    event: async ({ event }) => {
      const { type, properties: p = {} } = event;

      switch (type) {
        // Where a session lives, which is how Rune matches it to a terminal.
        case "session.created":
        case "session.updated":
          if (p.info?.id && p.info?.directory) {
            remember(p.info.id, { directory: p.info.directory });
          }
          break;

        // The whole point: opencode says so itself.
        case "session.status":
          if (p.sessionID && p.status?.type) {
            remember(p.sessionID, {
              status: p.status.type,
              // A new turn's detail belongs to that turn, not the last one.
              detail: p.status.type === "busy" ? undefined : null,
            });
          }
          break;

        case "session.idle":
          if (p.sessionID) remember(p.sessionID, { status: "idle", detail: null });
          break;

        case "session.deleted":
          if (p.sessionID) {
            sessions.delete(p.sessionID);
            flush();
          }
          break;

        // What the turn is doing right now, when it's doing something with a
        // name. Rune shows this instead of the bare word "working".
        case "message.part.updated":
          if (p.sessionID && p.part?.type === "tool" && p.part?.tool) {
            const running = p.part.state?.status === "running";
            remember(p.sessionID, {
              detail: running ? `Running ${p.part.tool}` : null,
            });
          }
          break;
      }
    },
  };
};
