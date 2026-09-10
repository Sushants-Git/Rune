// Standalone fixtures; no agent executables, network, or real store writes.
// swiftc -swift-version 6 Sources/Rune/AgentHistory.swift scripts/check-agent-history.swift -o /tmp/check-agent-history
// /tmp/check-agent-history
import Foundation
import SQLite3

@main
struct CheckAgentHistory {
    static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rune-history-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = AgentHistory.Roots(home: home, environment: [:])
        let cwd = home.appendingPathComponent("project 'quoted' $(touch SHOULD_NOT_EXIST)").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        func write(_ url: URL, _ data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func record(_ object: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            return data
        }

        let claudeID = "11111111-1111-4111-8111-111111111111"
        let claudeURL = roots.claude.appendingPathComponent("projects/project/\(claudeID).jsonl")
        let opening: [String: Any] = ["type": "user", "sessionId": claudeID, "cwd": cwd,
                                     "message": ["role": "user", "content": "Fix the sapphire parser"]]
        var claude = try record(opening)
        // Force the content match outside both preview windows and across a
        // streaming read boundary. Metadata search must not inspect it.
        let padding = try record(["type": "progress", "data": String(repeating: "x", count: 70_000)])
        for _ in 0..<5 { claude.append(padding) }
        claude.append(try record(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "text", "text": "HiddenNeedle exact conversation body"]]]]))
        for _ in 0..<5 { claude.append(padding) }
        claude.append(try record(["type": "custom-title", "customTitle": "Sapphire parser repair"]))
        claude.append(try record(["type": "assistant", "message": ["role": "assistant", "content": "Recent answer"]]))
        try write(claudeURL, claude)
        try write(roots.claude.appendingPathComponent("projects/project/subagents/agent-child.jsonl"), try record(opening))
        try write(roots.claude.appendingPathComponent("projects/project/broken.jsonl"), Data("not json\n".utf8))

        let codexID = "22222222-2222-4222-8222-222222222222"
        var codex = try record(["type": "session_meta", "payload": ["id": codexID, "cwd": cwd]])
        codex.append(try record(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "Investigate amber regression"]]]]))
        try write(roots.codex.appendingPathComponent("sessions/2026/09/10/rollout-test.jsonl"), codex)
        var index = try record(["id": codexID, "thread_name": "Old name"])
        index.append(try record(["id": codexID, "thread_name": "Amber regression"]))
        try write(roots.codex.appendingPathComponent("session_index.jsonl"), index)

        try FileManager.default.createDirectory(at: roots.openCode, withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(roots.openCodeDatabase.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        sql("PRAGMA journal_mode=WAL")
        sql("CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, time_updated INTEGER)")
        sql("CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT)")
        sql("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        sql("INSERT INTO session VALUES ('ses_test', 'Jade refactor', \(quote(cwd)), 1800000000000)")
        sql("INSERT INTO message VALUES ('msg_1', '{\"role\":\"assistant\"}')")
        sql("INSERT INTO part VALUES ('prt_1','msg_1','ses_test',1,'{\"type\":\"text\",\"text\":\"Jade database body\"}')")

        let storage = roots.openCode.appendingPathComponent("storage")
        try write(storage.appendingPathComponent("session/project/ses_legacy.json"), try record([
            "id": "ses_legacy", "title": "Legacy pearl", "directory": cwd, "time": ["updated": 1800000000000]]))
        try write(storage.appendingPathComponent("message/ses_legacy/msg_old.json"), try record(["id": "msg_old"]))
        try write(storage.appendingPathComponent("part/msg_old/prt_old.json"), try record(["type": "text", "text": "Legacy pearl body"]))

        let discovery = await AgentHistory.discover(roots: roots)
        precondition(discovery.sessions.count == 4, "Expected Claude, Codex, SQLite and legacy OpenCode")
        precondition(discovery.notes.isEmpty)
        let saved = discovery.sessions.first { $0.agent == .claude }!
        precondition(saved.title == "Sapphire parser repair")
        precondition(discovery.sessions.first { $0.agent == .codex }?.title == "Amber regression")
        precondition(AgentHistory.filter(discovery.sessions, query: "sphr claud").map(\.id) == [saved.id])
        precondition(AgentHistory.filter(discovery.sessions, query: "HiddenNeedle").isEmpty)
        // Letters that appear in order somewhere across a whole record are not
        // a match. Matching a subsequence of title + full path + agent + id run
        // together, with no bound on the gaps, meant nearly every query
        // returned nearly every session in a different order.
        precondition(AgentHistory.filter(discovery.sessions, query: "arst").isEmpty)

        let preview = await AgentHistory.preview(saved)
        precondition(preview.contains("Fix the sapphire parser") && preview.contains("Recent answer"))
        precondition(!preview.contains("HiddenNeedle") && preview.count < 25_000)
        let content = await AgentHistory.searchContent("hiddenneedle", sessions: discovery.sessions)
        precondition(content.sessions.map(\.id) == [saved.id])
        precondition(content.excerpts[saved.id]?.contains("HiddenNeedle") == true)
        for session in discovery.sessions {
            let single = await AgentHistory.searchContent("absent", sessions: [session])
            precondition(!single.incomplete, "Unexpected partial scan: \(session.id)")
        }
        let jade = await AgentHistory.searchContent("jade database", sessions: discovery.sessions)
        precondition(jade.sessions.count == 1 && jade.sessions[0].resume?.sessionID == "ses_test")
        let pearl = await AgentHistory.searchContent("pearl body", sessions: discovery.sessions)
        precondition(pearl.sessions.count == 1 && pearl.sessions[0].resume?.sessionID == "ses_legacy")
        let literal = await AgentHistory.searchContent(".*", sessions: discovery.sessions)
        precondition(literal.sessions.isEmpty)

        let live = AgentHistory.Session.live(target: UUID(), title: "Live", directory: cwd, resume: saved.resume)
        let merged = AgentHistory.merge([live, live], with: discovery.sessions)
        precondition(merged.count == 4 && merged[0].id == live.id && merged[0].transcript == saved.transcript)
        let unlinked = AgentHistory.Session.live(target: UUID(), title: "Same directory", directory: cwd, agent: .claude)
        precondition(AgentHistory.merge([unlinked], with: discovery.sessions).count == 5)
        precondition(AgentHistory.Resume(agent: .claude, sessionID: "--help", directory: cwd) == nil)
        precondition(AgentHistory.Resume(agent: .codex, sessionID: "x; touch pwn", directory: cwd) == nil)
        precondition(AgentHistory.Resume(agent: .openCode, sessionID: "../escape", directory: cwd) == nil)
        precondition(AgentHistory.Resume(agent: .claude, sessionID: "valid", directory: "/tmp\nwhoami") == nil)
        precondition(AgentHistory.Resume(agent: .claude, sessionID: "id 'quoted'", directory: cwd) == nil)
        precondition(AgentHistory.display("hello\u{1b}\u{202e}world") == "helloworld")

        // Real, harmless executables survive both shell execs; shell functions
        // would not. Exercise the exact Ghostty .shell wrapper, not a plain -c.
        //
        // Pinned to a stand-in shell. The wrapper runs a resume through the
        // user's *login* shell, interactively, because that is where `PATH`
        // comes from — which is the whole point of it, and also means that left
        // to itself this check would resolve `claude` to whatever the developer
        // running it happens to have installed, and `opencode` to Homebrew's,
        // rather than to the mocks below. The stand-in takes the same `-l -i -c
        // <script>` the real thing is handed and runs the script without
        // touching the environment, so everything this check is actually about
        // — the quoting, Ghostty's outer `exec -l`, the `cd`, the argument
        // splitting, resolution through `PATH` rather than a shell function —
        // is exercised against a `PATH` the test controls.
        let standIn = home.appendingPathComponent("stand-in shell")
        try write(standIn, Data("""
            #!/bin/sh
            while [ "$1" != "-c" ]; do shift; done
            exec /bin/sh -c "$2"
            """.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
        setenv("RUNE_RESUME_SHELL", standIn.path, 1)
        precondition(
            AgentHistory.Resume(agent: .claude, sessionID: claudeID, directory: cwd)!
                .shellCommand.hasPrefix("'\(standIn.path)' -l -i -c "),
            "Resume must run through a login, interactive shell")
        let launchCwd = home.appendingPathComponent("project 'quoted' \"double\" $(touch SHOULD_NOT_EXIST) `touch SHOULD_NOT_EXIST` ; &").path
        try FileManager.default.createDirectory(atPath: launchCwd, withIntermediateDirectories: true)
        let bin = home.appendingPathComponent("mock 'CLI' bin")
        let mock = """
            #!/bin/sh
            : > "$LAUNCH_MARKER"
            [ "$PWD" = "$EXPECTED_CWD" ] || exit 11
            [ "${0##*/}" = "$EXPECTED_AGENT" ] || exit 12
            [ "$#" = 2 ] || exit 13
            [ "$1" = "$EXPECTED_FLAG" ] || exit 14
            [ "$2" = "$EXPECTED_ID" ] || exit 15
            exit 0
            """
        for (agent, flag) in [(AgentHistory.Agent.claude, "--resume"), (.codex, "resume"), (.openCode, "--session")] {
            let resume = AgentHistory.Resume(agent: agent, sessionID: claudeID, directory: launchCwd)!
            let executable = bin.appendingPathComponent(resume.arguments[0])
            try write(executable, Data(mock.utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            func runGhostty(_ command: AgentHistory.Resume, marker: URL) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["--noprofile", "--norc", "-c", "exec -l " + command.shellCommand]
                process.currentDirectoryURL = home
                process.environment = [
                    "EXPECTED_CWD": command.directory, "EXPECTED_ID": claudeID,
                    "EXPECTED_AGENT": resume.arguments[0], "EXPECTED_FLAG": flag,
                    "LAUNCH_MARKER": marker.path, "PATH": bin.path + ":/usr/bin:/bin",
                ]
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }

            let marker = home.appendingPathComponent("launched-\(agent.rawValue)")
            let status = try runGhostty(resume, marker: marker)
            precondition(status == 0, "Ghostty wrapper failed for \(agent.name): \(status)")
            precondition(FileManager.default.fileExists(atPath: marker.path), "Mock CLI never launched")

            let missing = AgentHistory.Resume(agent: agent, sessionID: claudeID, directory: launchCwd + "/missing 'directory'")!
            let missingMarker = home.appendingPathComponent("must-not-launch-\(agent.rawValue)")
            let missingStatus = try runGhostty(missing, marker: missingMarker)
            precondition(missingStatus != 0, "Missing cwd must fail closed")
            precondition(!FileManager.default.fileExists(atPath: missingMarker.path), "CLI launched despite missing cwd")
        }
        for path in [home.path, launchCwd] {
            precondition(!FileManager.default.fileExists(atPath: path + "/SHOULD_NOT_EXIST"), "Shell substitution executed")
        }

        let cancelled = Task { await AgentHistory.searchContent("absent", sessions: Array(repeating: saved, count: 1000)) }
        cancelled.cancel()
        let start = Date()
        _ = await cancelled.value
        precondition(Date().timeIntervalSince(start) < 2, "Cancelled query continued reading")

        // Oversized records are skipped, not accumulated, and reported partial.
        var oversized = try record(opening)
        oversized.append(try record(["type": "progress", "data": String(repeating: "x", count: 2 * 1024 * 1024 + 1)]))
        try write(claudeURL, oversized)
        let partial = await AgentHistory.searchContent("absent", sessions: [saved])
        precondition(partial.incomplete && partial.sessions.isEmpty)
        print("Agent history fixtures passed: three agents, legacy/WAL, fuzzy/content search, bounded preview, merge, Ghostty exec wrapper, hostile cwd quoting, fail-closed launch, cancellation.")
        if CommandLine.arguments.contains("--local") {
            let start = Date()
            let local = await AgentHistory.discover()
            for agent in AgentHistory.Agent.allCases {
                print("\(agent.name): \(local.sessions.filter { $0.agent == agent }.count) saved sessions")
                if let session = local.sessions.first(where: { $0.agent == agent }) {
                    let preview = await AgentHistory.preview(session)
                    precondition(preview.count <= 25_000)
                    print("  bounded preview: \(preview.count) characters")
                }
            }
            print("Local read-only smoke check: \(Date().timeIntervalSince(start))s; \(local.notes.count) discovery notes")
        }
    }
}
