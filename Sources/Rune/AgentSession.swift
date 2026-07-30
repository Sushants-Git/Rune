import Foundation

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

    private static let codexIndexInterval: TimeInterval = 15

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

        // A recognised agent that says nothing Rune can read. Claiming to know
        // what it's doing would be a guess, and a guess shown as fact is worse
        // than saying nothing — so it gets an icon and no indicator.
        return AgentVerdict(
            surface: probe.surface, agent: agent, activity: .idle,
            detail: nil, sessionName: nil)
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

        // year/month/day, newest first, and only the newest few days: anything
        // older is not a live session.
        var days: [URL] = []
        for year in Self.newestChildren(of: root, limit: 2) {
            for month in Self.newestChildren(of: year, limit: 2) {
                days.append(contentsOf: Self.newestChildren(of: month, limit: 3))
                if days.count >= 3 { break }
            }
            if days.count >= 3 { break }
        }

        var logs: [URL] = []
        for day in days.prefix(3) {
            logs.append(contentsOf: (try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        }
        logs = logs
            .filter { $0.pathExtension == "jsonl" }
            .sorted { Self.modified($0) > Self.modified($1) }
            .prefix(24)
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

// MARK: - Codex

/// Codex's rollout log, which records the turn boundaries explicitly.
enum CodexRollout {
    struct State {
        var activity: Activity
        var detail: String?
    }

    /// How much of the tail to read. These run to megabytes; the decisive entry
    /// is always within a few kilobytes of the end.
    private static let tailBytes = 96 * 1024
    private static let headerLimit = 512 * 1024

    static func read(url: URL) -> State? {
        guard let lines = tail(of: url) else { return nil }

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

    private static func tail(of url: URL) -> [Substring]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Seeking to a byte offset almost certainly landed mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
