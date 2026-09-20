import CFFF
import Foundation

/// ⌘L's transcript search, done by fff (github.com/dmtrKovalenko/fff).
///
/// fff keeps an index of a directory in memory and greps it with SIMD, falling
/// back to a typo-tolerant fuzzy match — so "Search transcripts" is one call
/// over every Claude and Codex account's session folder instead of Rune
/// opening and parsing thousands of JSONL files one line at a time.
///
/// The library is loaded at run time rather than linked. It ships in
/// `Rune.app/Contents/Frameworks` (scripts/fetch-fff.sh, scripts/bundle.sh),
/// and a Rune without it — a `swift run`, a build whose fetch failed — still
/// searches transcripts, the old way; `FFF.shared` is simply nil.
///
/// OpenCode is not covered: its transcripts live in a SQLite database, which
/// is not a folder of text files for fff to index.
final class FFF: @unchecked Sendable {
    static let shared: FFF? = FFF.load()

    private typealias Create = @convention(c) (UnsafePointer<FffCreateOptions>?) -> UnsafeMutablePointer<FffResult>?
    private typealias WaitForScan = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> UnsafeMutablePointer<FffResult>?
    private typealias LiveGrep = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt8, UInt64, UInt32, Bool,
        UInt32, UInt32, UInt64, UInt32, UInt32, Bool) -> UnsafeMutablePointer<FffResult>?
    private typealias FreeResult = @convention(c) (UnsafeMutablePointer<FffResult>?) -> Void
    private typealias FreeGrep = @convention(c) (UnsafeMutablePointer<FffGrepResult>?) -> Void

    private let create: Create
    private let waitForScan: WaitForScan
    private let liveGrep: LiveGrep
    private let freeResult: FreeResult
    private let freeGrep: FreeGrep

    /// One index per folder, made on first use and kept, watching for new
    /// sessions. Every call into fff goes through `lock`: a search is a few
    /// milliseconds, and nothing here is worth a second index being built by
    /// two threads at once.
    fileprivate let lock = NSLock()
    private var instances: [String: UnsafeMutableRawPointer] = [:]

    private init?(_ library: UnsafeMutableRawPointer) {
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("fff_create_instance_with", as: Create.self),
              let waitForScan = symbol("fff_wait_for_scan", as: WaitForScan.self),
              let liveGrep = symbol("fff_live_grep", as: LiveGrep.self),
              let freeResult = symbol("fff_free_result", as: FreeResult.self),
              let freeGrep = symbol("fff_free_grep_result", as: FreeGrep.self)
        else { return nil }
        self.create = create
        self.waitForScan = waitForScan
        self.liveGrep = liveGrep
        self.freeResult = freeResult
        self.freeGrep = freeGrep
    }

    /// The bundled copy, or `RUNE_FFF_LIB` for a development build run outside
    /// an app bundle.
    private static func load() -> FFF? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["RUNE_FFF_LIB"] {
            candidates.append(override)
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent("libfff_c.dylib").path)
        }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let library = dlopen(path, RTLD_NOW | RTLD_LOCAL), let fff = FFF(library) {
                return fff
            }
        }
        return nil
    }

    /// Transcript search in the shape `AgentHistory.searchContent` takes, or
    /// nil when the library isn't there.
    static var historyGrep: AgentHistory.Grep? {
        guard let fff = shared else { return nil }
        return { query, folders in fff.candidates(matching: query, in: folders) }
    }

    /// Build the indexes ahead of the first search, off the main thread, so
    /// the first thing typed into ⌘L doesn't wait for a scan.
    static func warm(_ folders: [URL]) {
        guard let fff = shared else { return }
        DispatchQueue.global(qos: .utility).async {
            fff.lock.lock()
            defer { fff.lock.unlock() }
            for folder in folders { _ = fff.instance(for: folder) }
        }
    }

    struct Hit: Sendable {
        /// Absolute path of the file that matched.
        let path: String
        /// The matching line — for a transcript, one JSON record.
        let line: String
        /// Where in `line` the match begins, in bytes.
        let column: Int
        /// Where the line begins in the file.
        let offset: UInt64
        /// What fff matched, as byte ranges into `line`.
        let ranges: [Range<Int>]

        /// The matched text itself — for a fuzzy match, the stretch from its
        /// first matched byte to its last.
        var matched: String? {
            guard let lower = ranges.map(\.lowerBound).min(),
                  let upper = ranges.map(\.upperBound).max() else { return nil }
            let bytes = Array(line.utf8)
            guard lower < upper, upper <= bytes.count else { return nil }
            return String(decoding: bytes[lower..<upper], as: UTF8.self)
        }
    }

    /// Where in the transcripts under `folders` a match for `query` could be:
    /// for each file that holds every word — each as written or, three
    /// letters or more, as its letters in order inside one word
    /// (`intersection` in `interhihellosection`) — the offsets of the lines
    /// holding its longest word.
    ///
    /// Only candidates. A message that matches has to contain the longest
    /// word, so those lines are all that need reading, and ⌘L reads each one
    /// to decide whether the whole query is in what was *said* there and
    /// what to highlight. fff can't decide that itself: it returns only the
    /// first 512 bytes of a line, its fuzzy mode looks no further than that,
    /// and one regex spanning several words is slow over records megabytes
    /// long. Per word it is one plain search and one regex, both SIMD-fast.
    /// Bounded by `budget`; a partial answer says so.
    func candidates(matching query: String, in folders: [URL], budget: TimeInterval = 6)
        -> (lines: [String: [UInt64]], complete: Bool) {
        let deadline = Date().addingTimeInterval(budget)
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            .sorted { $0.count > $1.count }
        guard let longest = words.first else { return ([:], true) }
        var complete = true

        func search(_ word: String, perFile: UInt32) -> [Hit]? {
            var passes: [(UInt8, String)] = [(0, word)]
            if word.count >= 3 { passes.append((1, Self.inWordPattern(word))) }
            var hits: [Hit] = []
            for (mode, pattern) in passes {
                for folder in folders {
                    guard !Task.isCancelled else { return nil }
                    let result = grep(pattern, mode: mode, in: folder, perFile: perFile, deadline: deadline)
                    hits += result.hits
                    complete = complete && result.complete
                }
            }
            return hits
        }

        guard let lines = search(longest, perFile: 5_000) else { return ([:], false) }
        var found: [String: Set<UInt64>] = [:]
        for hit in lines { found[hit.path, default: []].insert(hit.offset) }
        // The other words only have to be somewhere in the file for it to
        // stay a candidate — whether they're in the same message is checked
        // when the line is read.
        for word in words.dropFirst() where !found.isEmpty {
            guard let hits = search(word, perFile: 1) else { return ([:], false) }
            let files = Set(hits.map(\.path))
            found = found.filter { files.contains($0.key) }
        }
        return (found.mapValues { $0.sorted() }, complete)
    }

    /// A word's letters in order within one word: `i\w?…n\w?…t…n`.
    ///
    /// Written the long way on purpose. fff reads `{…}` in a query as a glob,
    /// so `\w{0,8}` made the pattern match nothing, and `(?i)` stopped
    /// alternatives matching; the word is lower-cased instead, which fff's
    /// smart case searches without regard to case.
    static func inWordPattern(_ word: String) -> String {
        let gap = String(repeating: "\\w?", count: AgentHistory.maxGap)
        return word.lowercased()
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: gap)
    }

    fileprivate func grep(_ query: String, mode: UInt8, in folder: URL, perFile: UInt32 = 1,
                          deadline: Date) -> (hits: [Hit], complete: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return grepLocked(query, mode: mode, in: folder, perFile: perFile, deadline: deadline)
    }

    fileprivate func grepLocked(_ query: String, mode: UInt8, in folder: URL, perFile: UInt32,
                                deadline: Date) -> (hits: [Hit], complete: Bool) {
        guard let handle = instance(for: folder) else { return ([], false) }
        // Restricted to transcripts, and the query kept whole: fff reads a
        // leading `*.ext` as a file filter and the rest as the pattern.
        let pattern = "*.jsonl " + query
        var hits: [Hit] = []
        var offset: UInt32 = 0
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !Task.isCancelled else { return (hits, false) }
            guard let envelope = pattern.withCString({
                liveGrep(handle, $0, mode, 256 * 1024 * 1024, perFile, true, offset, 2000,
                         UInt64(left * 1000), 0, 0, false)
            }) else { return (hits, false) }
            defer { freeResult(envelope) }
            guard envelope.pointee.success,
                  let raw = envelope.pointee.handle?.assumingMemoryBound(to: FffGrepResult.self)
            else { return (hits, false) }
            defer { freeGrep(raw) }
            let result = raw.pointee
            for index in 0..<Int(result.count) {
                let match = result.items[index]
                guard let relative = match.relative_path.map({ String(cString: $0) }),
                      let line = match.line_content.map({ String(cString: $0) })
                else { continue }
                let ranges = (0..<Int(match.match_ranges_count)).compactMap { index -> Range<Int>? in
                    guard let range = match.match_ranges?[index], range.end > range.start else { return nil }
                    return Int(range.start)..<Int(range.end)
                }
                hits.append(Hit(
                    path: folder.appendingPathComponent(relative).standardizedFileURL.path,
                    line: line, column: Int(match.col), offset: match.byte_offset, ranges: ranges))
                if ProcessInfo.processInfo.environment["RUNE_TEST_FFF_DIR"] != nil {
                    print("  raw: offset \(match.byte_offset) line# \(match.line_number) len \(line.utf8.count) col \(match.col)")
                }
            }
            guard result.next_file_offset > 0, result.next_file_offset != offset else { break }
            offset = result.next_file_offset
        }
        return (hits, true)
    }

    /// The index for `folder`, built and scanned the first time it is asked
    /// for. Called with `lock` held.
    private func instance(for folder: URL) -> UnsafeMutableRawPointer? {
        let key = folder.standardizedFileURL.path
        if let existing = instances[key] { return existing }
        guard FileManager.default.fileExists(atPath: key) else { return nil }

        var options = FffCreateOptions()
        options.version = 2
        let base = strdup(key)
        defer { free(base) }
        options.base_path = UnsafePointer(base)
        // No frecency or query history: those are databases on disk, and a
        // search box that remembers what you typed was not asked for.
        options.enable_mmap_cache = false
        options.enable_content_indexing = false
        options.watch = true
        options.ai_mode = false
        options.follow_symlinks = false
        // Transcripts grow large — a long session is tens of megabytes — and
        // fff otherwise leaves anything past its default size out of a grep.
        options.cache_budget_max_file_size = 512 * 1024 * 1024

        guard let envelope = withUnsafePointer(to: &options, { create($0) }) else { return nil }
        defer { freeResult(envelope) }
        guard envelope.pointee.success, let handle = envelope.pointee.handle else { return nil }
        if let scanned = waitForScan(handle, 10_000) { freeResult(scanned) }
        instances[key] = handle
        return handle
    }
}

/// `RUNE_TEST_FFF=<query>`: run one transcript search both ways — fff and the
/// per-file scan — over this machine's real history, and print what each
/// found and how long it took. For checking the two agree.
enum FFFCheck {
    static func runIfRequested() {
        guard let query = ProcessInfo.processInfo.environment["RUNE_TEST_FFF"] else { return }
        if let dir = ProcessInfo.processInfo.environment["RUNE_TEST_FFF_DIR"], let fff = FFF.shared {
            for mode: UInt8 in [0, 1, 2] {
                let found = fff.grep(query, mode: mode, in: URL(fileURLWithPath: dir), perFile: 5, deadline: Date().addingTimeInterval(5))
                print("mode \(mode): " + found.hits.map { "\(($0.path as NSString).lastPathComponent): col \($0.column) ranges \($0.ranges) \($0.matched ?? "?")" }.joined(separator: " | "))
            }
            exit(0)
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let discovered = await AgentHistory.discover()
            let roots = AgentHistory.Roots()
            print("accounts: claude \(roots.claudeAccounts.map { $0.name ?? "default" }), codex \(roots.codexAccounts.map { $0.name ?? "default" })")
            print("sessions: \(discovered.sessions.count), alt: \(discovered.sessions.filter { $0.account != nil }.count)")
            print("fff loaded: \(FFF.shared != nil)")
            if let fff = FFF.shared {
                let t = Date()
                let shortlist = fff.candidates(matching: query, in: AgentHistory.transcriptFolders(roots).filter {
                    FileManager.default.fileExists(atPath: $0.path) })
                print(String(format: "  candidates: %d files, %d lines%@ in %.2fs", shortlist.lines.count,
                             shortlist.lines.values.map(\.count).reduce(0, +),
                             shortlist.complete ? "" : " (partial)", Date().timeIntervalSince(t)))
            }
            var start = Date()
            let fast = await AgentHistory.searchContent(query, sessions: discovered.sessions, grep: FFF.historyGrep)
            let fastTime = Date().timeIntervalSince(start)
            start = Date()
            let slow = await AgentHistory.searchContent(query, sessions: discovered.sessions)
            let slowTime = Date().timeIntervalSince(start)
            print(String(format: "fff:  %d matches in %.2fs%@", fast.sessions.count, fastTime, fast.incomplete ? " (partial)" : ""))
            print(String(format: "scan: %d matches in %.2fs%@", slow.sessions.count, slowTime, slow.incomplete ? " (partial)" : ""))
            let fastIDs = Set(fast.sessions.map(\.id)), slowIDs = Set(slow.sessions.map(\.id))
            print("only fff: \(fastIDs.subtracting(slowIDs).count), only scan: \(slowIDs.subtracting(fastIDs).count)")
            for session in slow.sessions where !fastIDs.contains(session.id) {
                if case .jsonl(let url)? = session.transcript { print("  missed:", url.path) } else { print("  missed (db):", session.title) }
            }
            for session in fast.sessions.prefix(12) {
                print("  [\(session.agent?.name ?? "?")] \(session.title.prefix(28)) excerpt: \(fast.excerpts[session.id] == nil ? "NONE" : "\(fast.excerpts[session.id]!.count) chars")")
            }
            print("-- scan list")
            for session in slow.sessions.prefix(12) {
                print("  [\(session.agent?.name ?? "?")] \(session.title.prefix(28)) excerpt: \(slow.excerpts[session.id] == nil ? "NONE" : "\(slow.excerpts[session.id]!.count) chars")")
            }
            print("-- opencode sessions in corpus: \(discovered.sessions.filter { $0.agent == .openCode }.count)")
            for session in fast.sessions.prefix(0) {
                let excerpt = (fast.excerpts[session.id] ?? "").replacingOccurrences(of: "\n", with: " ")
                let marked = AgentHistory.matchRanges(query, in: excerpt)?.map { String(excerpt[$0]) } ?? []
                print("  \(session.title.prefix(30)) :: \(marked.joined(separator: "·").prefix(60))")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
