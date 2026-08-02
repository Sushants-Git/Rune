import Foundation
import SQLite3

/// Asks each coding agent what it's doing, using whatever the agent itself
/// publishes.
///
/// This has been wrong twice, in instructive ways.
///
/// First it read the rendered screen back out of libghostty and looked for the
/// agent's status line. That took the same lock the IO thread holds while
/// parsing output, so it stalled the main thread under a busy agent.
///
/// Then it parsed the conversation transcript and inferred whose turn it was
/// from the last entry. That was off the main thread and cheap, but it inferred
/// — and it picked the transcript by "newest file in this directory", which is
/// simply wrong when a directory has several sessions in it. This repo has four.
///
/// Claude Code publishes exactly what's needed and none of that is necessary:
/// `~/.claude/sessions/<pid>.json` carries a `status` of `busy`, `idle` or
/// `waiting`, plus a `waitingFor` reason. It's keyed by **process id**, which
/// is precisely what a terminal emulator knows about the program running in it,
/// so there is no matching heuristic left to get wrong. It's 400 bytes.
///
/// Codex has no equivalent, so it still reads its rollout log, which at least
/// records explicit `task_started` / `task_complete` events.
///
/// opencode has no equivalent either, but it keeps its sessions in a SQLite
/// database and stamps every assistant message with a completion time — so the
/// question "is it still going" is a column rather than an inference.
///
/// Nothing here reads the terminal, and nothing here runs on the main thread.
enum AgentSession {}

/// One terminal, as much as the monitor needs to know about it.
struct AgentProbe: Sendable {
    let surface: UUID
    /// The foreground process. This is the join key: agents publish their state
    /// against their own pid.
    let pid: pid_t
    let directory: String?
}

/// What the monitor found.
struct AgentVerdict: Sendable {
    let surface: UUID
    let agent: AgentIcon?
    /// Already resolved, because the agent states this outright now rather than
    /// leaving it to be inferred.
    let activity: Activity
    /// Why, when the agent says why — "dialog open" while it holds a prompt.
    let detail: String?
    /// The agent's own name for the session: `rune-4b`, `devfolio-api-a7`.
    let sessionName: String?

    static func none(_ surface: UUID) -> AgentVerdict {
        AgentVerdict(
            surface: surface, agent: nil, activity: .idle, detail: nil, sessionName: nil)
    }
}

/// Polls agent state on a background queue.
///
/// The main thread's entire share of this is collecting one foreground pid per
/// terminal — a `tcgetpgrp`, which takes no libghostty lock.
final class AgentMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rune.agent-monitor", qos: .utility)

    /// Queue-confined. Codex logs are filed by date rather than by pid, so the
    /// mapping from a working directory to its log has to be built by reading
    /// headers.
    private var codexByDirectory: [String: URL] = [:]
    private var codexIndexedAt: Date = .distantPast
    private var codexCwdCache: [URL: String?] = [:]

    /// Queue-confined, same shape as the Codex index and refreshed on the same
    /// cadence: one query covers every directory, so there is nothing to be
    /// gained by asking per terminal.
    private var openCodeByDirectory: [String: OpenCodeStore.State] = [:]
    private var openCodeIndexedAt: Date = .distantPast

    private static let codexIndexInterval: TimeInterval = 15
    /// How many day-directories of rollouts to consider live, and how many of
    /// the resulting logs to keep. Both are bounded because this re-runs every
    /// 15 seconds; both are generous because falling out of the index is
    /// indistinguishable, from the outside, from the agent going quiet.
    private static let dayWindow = 10
    private static let logLimit = 48

    /// Look at every probe and hand back what it found. The completion runs on
    /// the main actor.
    func probe(
        _ probes: [AgentProbe],
        completion: @escaping @MainActor @Sendable ([AgentVerdict]) -> Void
    ) {
        queue.async { [self] in
            let verdicts = probes.map(examine)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(verdicts) }
            }
        }
    }

    /// Kept so the controller has something to call when a terminal closes;
    /// there is no per-surface state left to discard, which is the point.
    func forget(_ surface: UUID) {}

    // MARK: - The work, all of it off the main thread

    private func examine(_ probe: AgentProbe) -> AgentVerdict {
        guard probe.pid > 0 else { return .none(probe.surface) }

        // Claude publishes against its own pid, so try that before spending a
        // `sysctl` on identifying the process at all. A hit is proof of both
        // which agent it is and what it's doing.
        if let session = ClaudeSessionFile.find(startingAt: probe.pid) {
            return AgentVerdict(
                surface: probe.surface,
                agent: .claude,
                activity: session.activity,
                detail: session.detail,
                sessionName: session.name)
        }

        let agent = AgentIcon.detect(arguments: ProcessArguments.of(pid: probe.pid))
        guard let agent else { return .none(probe.surface) }

        // Codex: fall back to its rollout log.
        if agent == .codex, let directory = probe.directory,
           let url = codexSession(directory: directory),
           let state = CodexRollout.read(url: url) {
            return AgentVerdict(
                surface: probe.surface,
                agent: agent,
                activity: state.activity,
                detail: state.detail,
                sessionName: nil)
        }

        // opencode: its database says outright whether the turn is still going.
        if agent == .openCode, let directory = probe.directory,
           let state = openCodeState(directory: directory) {
            return AgentVerdict(
                surface: probe.surface,
                agent: agent,
                activity: state.activity,
                detail: state.detail,
                sessionName: nil)
        }

        // A recognised agent that says nothing Rune can read. Claiming to know
        // what it's doing would be a guess, and a guess shown as fact is worse
        // than saying nothing — so it gets an icon and no indicator.
        return AgentVerdict(
            surface: probe.surface, agent: agent, activity: .idle,
            detail: nil, sessionName: nil)
    }

    // MARK: - opencode

    private func openCodeState(directory: String) -> OpenCodeStore.State? {
        if Date().timeIntervalSince(openCodeIndexedAt) >= Self.codexIndexInterval {
            openCodeByDirectory = OpenCodeStore.index()
            openCodeIndexedAt = Date()
        }
        return openCodeByDirectory[directory]
    }

    // MARK: - Codex

    private func codexSession(directory: String) -> URL? {
        if Date().timeIntervalSince(codexIndexedAt) >= Self.codexIndexInterval {
            codexByDirectory = indexCodexSessions()
            codexIndexedAt = Date()
        }
        return codexByDirectory[directory]
    }

    private func indexCodexSessions() -> [String: URL] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions")

        // year/month/day, newest first. The window is days rather than hours
        // because a rollout is filed under the date the session *started* and
        // then written to for as long as it lives — and a coding agent left
        // running over a weekend is the case Rune exists for. At three days a
        // session older than that dropped out of the index entirely, Rune
        // stopped being able to say what it was doing, and the pane kept
        // whatever the last bell had claimed.
        var days: [URL] = []
        for year in Self.newestChildren(of: root, limit: 2) {
            for month in Self.newestChildren(of: year, limit: 2) {
                days.append(contentsOf: Self.newestChildren(of: month, limit: Self.dayWindow))
                if days.count >= Self.dayWindow { break }
            }
            if days.count >= Self.dayWindow { break }
        }

        var logs: [URL] = []
        for day in days.prefix(Self.dayWindow) {
            logs.append(contentsOf: (try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        }
        logs = logs
            .filter { $0.pathExtension == "jsonl" }
            .sorted { Self.modified($0) > Self.modified($1) }
            .prefix(Self.logLimit)
            .map { $0 }

        // Newest first, first write wins, so a directory maps to its most
        // recent session.
        var result: [String: URL] = [:]
        for log in logs {
            guard let cwd = codexWorkingDirectory(of: log) else { continue }
            if result[cwd] == nil { result[cwd] = log }
        }
        return result
    }

    /// A log's header never changes, so its directory is worth remembering —
    /// otherwise every re-index re-reads tens of kilobytes to learn something
    /// it already knew.
    private func codexWorkingDirectory(of url: URL) -> String? {
        if let known = codexCwdCache[url] { return known }
        let cwd = CodexRollout.workingDirectory(url: url)
        codexCwdCache[url] = cwd
        return cwd
    }

    private static func newestChildren(of url: URL, limit: Int) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        // Date-named directories sort correctly as strings.
        return children.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit).map { $0 }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}

// MARK: - Claude Code

/// `~/.claude/sessions/<pid>.json`, which Claude Code keeps current for every
/// live session it owns.
enum ClaudeSessionFile {
    struct State {
        var activity: Activity
        var detail: String?
        var name: String?
    }

    /// Find the session belonging to `pid`, or to whichever ancestor of it owns
    /// one.
    ///
    /// The walk matters because the foreground process isn't always the agent
    /// itself — run something from inside Claude and the pty's foreground group
    /// is the child, whose pid Claude has never heard of. Its parent is.
    static func find(startingAt pid: pid_t, maximumDepth: Int = 4) -> State? {
        var current = pid
        for _ in 0..<maximumDepth {
            // The file existing isn't quite proof on its own. Claude leaves one
            // behind when it exits, and macOS reuses process ids eventually, so
            // a long-lived window could land a plain shell on a dead session's
            // number and inherit its status. Confirming the process really is
            // Claude costs one `sysctl`, on this queue, only for terminals that
            // matched — which is to say, only for real agents.
            if let state = read(pid: current), isClaude(current) { return state }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func isClaude(_ pid: pid_t) -> Bool {
        AgentIcon.detect(arguments: ProcessArguments.of(pid: pid)) == .claude
    }

    private static func read(pid: pid_t) -> State? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else { return nil }

        // Guard against a stale file left by a dead process that a new one has
        // since been given the same pid: the file names its own pid.
        if let recorded = object["pid"] as? Int, pid_t(recorded) != pid { return nil }

        let name = object["name"] as? String
        switch status {
        case "busy":
            return State(activity: .working, detail: nil, name: name)
        case "waiting":
            // Blocked on you rather than merely finished, but that's the same
            // instruction either way, so it reads as "your turn" too. The
            // difference survives in the detail: `waitingFor` says what it's
            // stuck on, "dialog open" while it holds a permission prompt.
            let reason = object["waitingFor"] as? String
            return State(activity: .waiting, detail: reason.map(phrase), name: name)
        case "idle":
            return State(activity: .waiting, detail: nil, name: name)
        default:
            return nil
        }
    }

    /// Claude's reasons are written for a log, not for a row.
    private static func phrase(_ reason: String) -> String {
        switch reason {
        case "dialog open": "answer it"
        case "input": "wants input"
        default: reason
        }
    }

    /// A process's parent, via `sysctl`. Cheap, and this is on the monitor's
    /// own queue regardless.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - opencode

/// opencode's SQLite database, at `~/.local/share/opencode/opencode.db`.
///
/// Nicer to read than a log: every message row carries `role`, and an assistant
/// message gains a `time.completed` the moment its turn ends. So the state is a
/// field rather than something reconstructed from the order of events — an
/// assistant message without a completion time is a turn still running, and one
/// with a completion time is your move.
///
/// Read-only, and deliberately not held open: opencode writes this database
/// while Rune reads it, and the index is only rebuilt every 15 seconds, so
/// there is nothing to gain from keeping a handle on someone else's file.
enum OpenCodeStore {
    struct State {
        var activity: Activity
        var detail: String?
    }

    /// Overridable so the states that only occur mid-turn can be exercised
    /// against a copy, the same way `RUNE_UPDATE_FEED` exists for the updater.
    /// An interrupted turn is easy to find in history and impossible to stage
    /// on demand without spending someone's API quota.
    static var databaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["RUNE_OPENCODE_DB"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// Working directory to what opencode is doing there.
    ///
    /// One query for every session rather than one per terminal: the join is
    /// cheap, and a directory maps to its most recently updated session, which
    /// is the same "newest wins" rule the Codex index uses.
    static func index() -> [String: State] {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let db = open(databaseURL) else { return [:] }
        defer { sqlite3_close(db) }

        // The last message of each session, newest sessions first. `LIMIT` is a
        // guard against a database with years of history in it, not a guess
        // about how many terminals are open.
        let sql = """
            SELECT s.directory, s.id, m.data
            FROM session s
            JOIN message m ON m.id = (
                SELECT id FROM message WHERE session_id = s.id
                ORDER BY time_created DESC LIMIT 1
            )
            ORDER BY s.time_updated DESC
            LIMIT 128
            """

        var result: [String: State] = [:]
        forEachRow(db, sql) { statement in
            guard let directory = text(statement, 0), result[directory] == nil,
                  let sessionID = text(statement, 1),
                  let data = text(statement, 2)?.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            let role = message["role"] as? String
            let time = message["time"] as? [String: Any]
            let completed = time?["completed"] != nil

            // A user message means the turn has just been handed over, so the
            // agent owns it even though it hasn't written anything yet.
            switch role {
            case "assistant" where completed:
                result[directory] = State(activity: .waiting, detail: nil)
            case "assistant", "user":
                result[directory] = State(
                    activity: .working, detail: runningTool(db, session: sessionID))
            default:
                break
            }
        }
        return result
    }

    /// What the turn is doing right now, when it's doing something nameable.
    private static func runningTool(_ db: OpaquePointer, session: String) -> String? {
        // Newest part first; a tool part carries the tool's name and whether it
        // is still going. Anything else — plain text, step markers — has no
        // name worth putting on a row.
        let sql = """
            SELECT data FROM part
            WHERE session_id = '\(session.replacingOccurrences(of: "'", with: "''"))'
            ORDER BY time_created DESC LIMIT 12
            """
        var detail: String?
        forEachRow(db, sql) { statement in
            guard detail == nil,
                  let raw = text(statement, 0)?.data(using: .utf8),
                  let part = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  part["type"] as? String == "tool",
                  let tool = part["tool"] as? String,
                  let state = part["state"] as? [String: Any],
                  state["status"] as? String == "running"
            else { return }
            detail = "Running \(tool)"
        }
        return detail
    }

    // MARK: - SQLite, kept to the three calls this needs

    private static func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        // Read-only, but *not* `immutable`: opencode is writing to this while
        // Rune reads it, and an immutable open ignores the write-ahead log —
        // which would mean reading a consistent snapshot of the past.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        // Don't sit on a locked database while an agent is mid-write.
        sqlite3_busy_timeout(db, 100)
        return db
    }

    private static func forEachRow(
        _ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}

// MARK: - Codex

/// Codex's rollout log, which records the turn boundaries explicitly.
enum CodexRollout {
    struct State {
        var activity: Activity
        var detail: String?
    }

    /// How much of the tail to read, widening until the turn boundary is in it.
    ///
    /// This used to be a single 96KB gulp, on the theory that the decisive entry
    /// is always within a few kilobytes of the end. It isn't. Codex writes whole
    /// response items into the log, so one turn that reads a few large files
    /// pushes its own `task_started` a long way back — measured at 374KB in a
    /// real session here.
    ///
    /// The consequence was not a missing badge, which would at least look like
    /// ignorance. `read` returned nil, the terminal fell back to "no idea", and
    /// the *bell* Codex rang at the end of the previous turn stayed the only
    /// thing anyone had said about that pane — so it sat on "your turn" while
    /// Codex was visibly working. A stale fact outlives a missing one.
    ///
    /// Widening steps rather than one big read because the first window is
    /// nearly always enough, and this runs for every Codex terminal on every
    /// poll.
    private static let tailWindows = [96 * 1024, 768 * 1024, 6 * 1024 * 1024]
    private static let headerLimit = 512 * 1024

    static func read(url: URL) -> State? {
        for window in tailWindows {
            guard let (lines, fromStart) = tail(of: url, bytes: window) else { return nil }
            if let state = scan(lines) { return state }
            // The whole file has been read and it says nothing decisive; a
            // wider window would just be the same bytes again.
            if fromStart { return nil }
        }
        return nil
    }

    private static func scan(_ lines: [Substring]) -> State? {
        var detail: String?
        for line in lines.reversed() {
            guard let entry = json(line),
                  let payload = entry["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            switch type {
            case "task_complete":
                return State(activity: .waiting, detail: nil)
            case "task_started", "user_message":
                return State(activity: .working, detail: detail)
            case "exec_command_begin":
                detail = detail ?? "Running a command"
            case "function_call", "custom_tool_call":
                detail = detail ?? (payload["name"] as? String).map { "Running \($0)" }
            case "web_search_call":
                detail = detail ?? "Searching the web"
            case "patch_apply_begin":
                detail = detail ?? "Editing"
            default:
                continue
            }
        }
        return nil
    }

    /// The `cwd` out of a rollout's header, which is its first line.
    ///
    /// Read in chunks rather than one fixed-size gulp: the header carries the
    /// model's entire base instruction set, so that line runs to tens of
    /// kilobytes and a small window never reaches the newline at all.
    static func workingDirectory(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while data.count < headerLimit {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
            guard let newline = data.firstIndex(of: 0x0A) else { continue }
            guard let entry = try? JSONSerialization.jsonObject(with: data[..<newline])
                    as? [String: Any],
                  let payload = entry["payload"] as? [String: Any]
            else { return nil }
            return payload["cwd"] as? String
        }
        return nil
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The last `bytes` of the file as lines, plus whether that reached the
    /// beginning — which is how the caller knows a wider window is pointless.
    private static func tail(of url: URL, bytes: Int) -> (lines: [Substring], fromStart: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Seeking to a byte offset almost certainly landed mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return (lines, start == 0)
    }
}
