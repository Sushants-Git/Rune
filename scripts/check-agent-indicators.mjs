// Run with: node scripts/check-agent-indicators.mjs (macOS + Swift + Node).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const temporary = mkdtempSync(join(tmpdir(), "rune-indicators-"));
const previousHome = process.env.HOME;
try {
  process.env.HOME = temporary;
  const source = readFileSync(new URL("../Resources/opencode-plugin.js", import.meta.url), "utf8");
  const { Rune } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
  const client = { session: { get: async ({ path: { id } }) => ({
    data: { id, directory: "/project", ...(id === "child" ? { parentID: "root" } : {}) },
  }) } };
  const first = await Rune({ client });
  const second = await Rune({ client });
  const event = (plugin, type, properties) => plugin.event({ event: { type, properties } });
  await Promise.all([
    event(first, "session.status", { sessionID: "root", status: { type: "busy" } }),
    event(second, "session.status", { sessionID: "child", status: { type: "idle" } }),
  ]);
  const directory = join(temporary, ".local/state/rune/opencode.d");
  const snapshots = () => readdirSync(directory).map(file => JSON.parse(readFileSync(join(directory, file))));
  assert.equal(snapshots().length, 2, "same-pid plugin instances must not overwrite each other");
  const session = id => snapshots().map(snapshot => snapshot.sessions[id]).find(Boolean);
  assert.equal(session("root").directory, "/project", "resumed sessions resolve metadata");
  assert.equal(session("child").parentID, "root");
  await event(first, "message.part.updated", { part: {
    sessionID: "root", type: "tool", tool: "bash", state: { status: "running" },
  } });
  assert.equal(session("root").detail, "Running bash", "tool session ID belongs to the part");
  await event(first, "session.status", { sessionID: "root", status: { type: "retry" } });
  assert.equal(session("root").status, "retry");
  await Promise.all([
    event(first, "session.status", { sessionID: "resumed", status: { type: "busy" } }),
    event(first, "session.status", { sessionID: "resumed", status: { type: "idle" } }),
  ]);
  assert.equal(session("resumed").status, "idle", "async metadata must preserve event order");
  await event(second, "session.deleted", { info: { id: "child" } });
  assert.equal(session("child"), undefined);
  let attempts = 0;
  const recovering = await Rune({ client: { session: { get: async () => {
    if (++attempts === 1) throw new Error("temporary SDK failure");
    return { data: { id: "recovering", directory: "/recovered" } };
  } } } });
  await event(recovering, "session.status", { sessionID: "recovering", status: { type: "busy" } });
  assert.equal(session("recovering").directory, undefined, "failed metadata must not invent a root session");
  await event(recovering, "session.status", { sessionID: "recovering", status: { type: "busy" } });
  assert.equal(session("recovering").directory, "/recovered", "metadata failures are retried");
  console.log("OpenCode plugin regression checks passed");

  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  const root = resolve(import.meta.dirname, "..");
  const executable = join(temporary, "check-agent-indicators");
  const compile = spawnSync("swiftc", [
    "-swift-version", "6", "-o", executable, "-lsqlite3",
    ...["AgentSession", "Activity", "AgentIcon", "ProgramIcon", "ProcessGroup"]
      .map(name => join(root, "Sources/Rune", `${name}.swift`)),
    join(root, "scripts/check-agent-indicators.swift"),
  ], { stdio: "inherit" });
  assert.equal(compile.status, 0, "indicator sources compile independently of Ghostty/UI edits");
  const run = spawnSync(executable, [], { stdio: "inherit" });
  assert.equal(run.status, 0);
} finally {
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  rmSync(temporary, { recursive: true, force: true });
}
