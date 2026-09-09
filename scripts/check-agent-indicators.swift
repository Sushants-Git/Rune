import Foundation
import SQLite3

@main
struct IndicatorChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = root.appendingPathComponent("opencode.json")
        let writers = root.appendingPathComponent("opencode.d")
        try FileManager.default.createDirectory(at: writers, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("opencode.db")
        setenv("RUNE_OPENCODE_STATE", hook.path, 1)
        setenv("RUNE_OPENCODE_DB", database.path, 1)
        var db: OpaquePointer?
        precondition(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) {
            precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK)
        }
        sql("CREATE TABLE session (id TEXT, directory TEXT, parent_id TEXT, time_updated INTEGER)")
        sql("CREATE TABLE message (id TEXT, session_id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        sql("CREATE TABLE part (session_id TEXT, data TEXT, time_created INTEGER)")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        sql("INSERT INTO session VALUES ('root', '/project', NULL, 1), ('child', '/project', 'root', 2), ('fallback', '/fallback', NULL, 3)")
        sql("INSERT INTO message VALUES ('m', 'fallback', '{\"role\":\"assistant\",\"finish\":\"tool-calls\",\"time\":{\"completed\":1}}', 1, \(now))")
        func record(_ status: String, _ at: Double, directory: String = "/project") -> [String: Any] {
            ["directory": directory, "status": status, "pid": getpid(), "at": at]
        }
        func write(_ sessions: [String: [String: Any]], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "sessions": sessions])
                .write(to: url, options: .atomic)
        }
        try write(["root": record("busy", 1), "child": record("idle", 2)], to: hook)
        precondition(OpenCodeStore.index()["/project"]?.activity == .working, "legacy child must not override root")
        precondition(OpenCodeStore.index()["/fallback"]?.activity == .working, "fallback is per directory; tool completion is not turn completion")
        let first = writers.appendingPathComponent("first.json")
        let second = writers.appendingPathComponent("second.json")
        try write(["root": record("retry", 3)], to: first)
        try write(["other": record("idle", 4)], to: second)
        precondition(OpenCodeStore.index()["/project"]?.activity == .working, "retry and busy outrank idle neighbours")
        try write(["root": record("idle", 5)], to: second)
        precondition(OpenCodeStore.index()["/project"]?.activity == .waiting, "newest record wins for the same session")
        var neighbour = record("busy", 6)
        neighbour["pid"] = getppid()
        try write(["neighbour": neighbour], to: first)
        precondition(OpenCodeStore.index()["/project"]?.activity == .working)
        precondition(OpenCodeStore.index(preferredPIDs: [getpid()])["/project"]?.activity == .waiting,
                     "matching process outranks a busy neighbour in the same directory")
        try write([:], to: first)
        try write([:], to: second)
        precondition(OpenCodeStore.index()["/project"] == nil, "new writers suppress stale legacy data for their pid")
        try write(["unknown": record("unknown", 6)], to: first)
        precondition(OpenCodeStore.index()["/project"] == nil, "unknown status is not waiting")
        var dead = record("busy", 7)
        dead["pid"] = Int32.max
        try write(["dead": dead], to: first)
        precondition(OpenCodeStore.index()["/project"] == nil, "dead server is ignored")
        try Data("{".utf8).write(to: first)
        precondition(OpenCodeStore.index()["/fallback"]?.activity == .working, "malformed hook does not suppress fallback")
        sql("UPDATE message SET time_updated = 1")
        precondition(OpenCodeStore.index()["/fallback"]?.activity == .idle, "old incomplete turns cannot prove liveness")
        precondition(CodexTitle.isWorking("\u{2834} project"))
        precondition(!CodexTitle.isWorking("project"))
        precondition(Activity.working.label == "working")
        print("Swift indicator regression checks passed")
    }
}
