import Foundation
import SQLite3

/// Local, read-only history. All public I/O methods move their work off the main
/// actor and propagate cancellation to the worker. No transcript text is code.
enum AgentHistory {
    enum Agent: String, CaseIterable, Sendable {
        case claude, codex, openCode

        var name: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .openCode: "OpenCode"
            }
        }
    }

    /// One place an agent keeps its sessions — its config home.
    ///
    /// More than one per agent, because people run more than one account:
    /// `CLAUDE_CONFIG_DIR=~/.claude-alt claude` and `CODEX_HOME=~/.codex-alt
    /// codex` are the documented way to keep a second login, and ⌘L used to
    /// see only the default home, so every session in the other one was
    /// invisible — and one resumed from it would have started in the wrong
    /// account. A sibling directory named `.claude-<name>` or `.codex-<name>`
    /// that holds the agent's session folder is an account called `<name>`.
    struct Account: Hashable, Sendable {
        let home: URL
        /// `alt` for `~/.claude-alt`; nil for the default home.
        let name: String?
        /// What to set the agent's home variable to when resuming, or nil to
        /// leave it alone — the default home needs nothing set.
        let override: String?

        static func all(
            prefix: String, variable: String, marker: String,
            home: URL, environment: [String: String]
        ) -> [Account] {
            // The default home is always the default account. When Rune itself
            // was started with the variable set — from a terminal running the
            // other account, say — that home is one more account, and the
            // default gets the variable spelled out on resume, so it doesn't
            // inherit the other one from Rune's environment.
            let manager = FileManager.default
            let standard = home.appendingPathComponent(prefix)
            let inherited = environment[variable].flatMap { $0.hasPrefix("/") ? $0 : nil }
            var accounts = [Account(home: standard, name: nil,
                                    override: inherited == nil ? nil : standard.path)]
            var seen: Set<String> = [standard.standardizedFileURL.path]

            func add(_ url: URL, name: String) {
                var isDirectory: ObjCBool = false
                guard seen.insert(url.standardizedFileURL.path).inserted,
                      manager.fileExists(atPath: url.appendingPathComponent(marker).path,
                                         isDirectory: &isDirectory), isDirectory.boolValue
                else { return }
                accounts.append(Account(home: url, name: name, override: url.path))
            }
            let siblings = ((try? manager.contentsOfDirectory(atPath: home.path)) ?? [])
                .filter { $0.hasPrefix(prefix + "-") && $0.count > prefix.count + 1 }
                .sorted()
            for entry in siblings {
                add(home.appendingPathComponent(entry), name: String(entry.dropFirst(prefix.count + 1)))
            }
            if let inherited {
                let url = URL(fileURLWithPath: inherited)
                let last = url.lastPathComponent
                add(url, name: last.hasPrefix(prefix + "-") ? String(last.dropFirst(prefix.count + 1)) : last)
            }
            return accounts
        }

        static func claude(
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [Account] {
            all(prefix: ".claude", variable: "CLAUDE_CONFIG_DIR", marker: "projects",
                home: home, environment: environment)
        }

        static func codex(
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [Account] {
            all(prefix: ".codex", variable: "CODEX_HOME", marker: "sessions",
                home: home, environment: environment)
        }
    }

    struct Resume: Hashable, Sendable {
        let agent: Agent
        let sessionID: String
        let directory: String
        /// The account's home to point the agent at, when it isn't the default.
        let accountHome: String?

        /// Reject options, control characters and arbitrary commands at ingestion.
        /// Keep the original directory, not a display-sanitized version of it.
        init?(agent: Agent, sessionID: String, directory: String, accountHome: String? = nil) {
            let validID = !sessionID.isEmpty && sessionID.utf8.count <= 160
                && sessionID.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45 || $0 == 95
                } && sessionID.first != "-"
            guard validID, directory.hasPrefix("/"), directory.utf8.count < 16_384,
                  !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            if let accountHome {
                guard accountHome.hasPrefix("/"), accountHome.utf8.count < 4096,
                      !accountHome.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0) })
                else { return nil }
            }
            self.agent = agent
            self.sessionID = sessionID
            self.directory = directory
            self.accountHome = agent == .openCode ? nil : accountHome
        }

        /// The variable that points this agent at another home.
        private var homeVariable: String? {
            switch agent {
            case .claude: "CLAUDE_CONFIG_DIR"
            case .codex: "CODEX_HOME"
            case .openCode: nil
            }
        }

        var arguments: [String] {
            switch agent {
            case .claude: ["claude", "--resume", sessionID]
            case .codex: ["codex", "resume", sessionID]
            case .openCode: ["opencode", "--session", sessionID]
            }
        }

        /// Launch boundary for Ghostty's `exec -l <command>` shell wrapper. Send this, never a
        /// title/preview or an interpolated ID, to a NEW terminal. `&&` prevents
        /// resuming in the wrong project if its directory has disappeared.
        /// The controller decides whether/how to append the terminal's return.
        ///
        /// Run through the user's **login shell, interactively**, and that is
        /// the whole reason ⌘L used to open a dead terminal. libghostty runs a
        /// surface command as `login -fp … /bin/bash --noprofile --norc -c
        /// "exec -l <this>"`, so the process inherits whatever `PATH` the app
        /// was launched with — from the Dock, that is `/usr/bin:/bin:/usr/sbin:
        /// /sbin` and nothing else. Every one of these agents installs
        /// somewhere that only a shell startup file knows about
        /// (`~/.local/bin`, `~/.bun/bin`, Homebrew), so `exec claude` was
        /// `command not found` every time, and because a surface with a command
        /// implies `wait-after-command`, what you got was a terminal sitting
        /// there having already failed.
        ///
        /// `-l -i` is what loads the files that set `PATH`: login for
        /// `.zprofile`/`.bash_profile`, interactive for `.zshrc`/`.bashrc`,
        /// which is where most people actually put it. The script stays two
        /// words of POSIX — `cd … && exec …` — so it means the same thing in
        /// sh, bash, zsh and fish alike.
        var shellCommand: String {
            // A second account resumes through `env`, so the variable is set
            // for the agent alone and the same words work in every shell —
            // `VAR=value exec …` is not something fish, for one, accepts.
            var command = arguments
            if let accountHome, let variable = homeVariable {
                command = ["/usr/bin/env", "\(variable)=\(accountHome)"] + command
            }
            let script = "cd -- \(Self.quote(directory)) && exec "
                + command.map(Self.quote).joined(separator: " ")
            // The outer exec needs an executable, not the shell builtin `cd`.
            // Quote the entire script again for that outer shell's parse.
            return Self.quote(Self.loginShell) + " -l -i -c " + Self.quote(script)
        }

        /// The shell whose startup files hold the user's `PATH`.
        ///
        /// `RUNE_RESUME_SHELL` first, as an escape hatch and so the launch
        /// check can pin one; then `SHELL`, because that is what the user chose
        /// and what a terminal is expected to honour; then the account record,
        /// for the launch contexts that don't set it; `/bin/zsh` last, which is
        /// the macOS default and exists on every machine Rune runs on. Anything
        /// that isn't an absolute path to a real file is not a shell.
        static var loginShell: String {
            func usable(_ path: String?) -> String? {
                guard let path, path.hasPrefix("/"),
                      FileManager.default.isExecutableFile(atPath: path)
                else { return nil }
                return path
            }
            let environment = ProcessInfo.processInfo.environment
            if let shell = usable(environment["RUNE_RESUME_SHELL"]) { return shell }
            if let shell = usable(environment["SHELL"]) { return shell }
            if let record = getpwuid(getuid())?.pointee.pw_shell,
               let shell = usable(String(cString: record)) { return shell }
            return "/bin/zsh"
        }

        private static func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    enum Transcript: Hashable, Sendable {
        case jsonl(URL)
        case openCode(database: URL, sessionID: String)
        case openCodeLegacy(storage: URL, sessionID: String)
    }

    struct Session: Identifiable, Hashable, Sendable {
        let id: String
        var agent: Agent?
        var title: String
        var directory: String
        /// Which of the agent's accounts it belongs to — `alt` for
        /// `~/.claude-alt` — or nil for the default one.
        var account: String?
        var updatedAt: Date
        /// Controller contract: this is the exact terminal surface UUID, not a
        /// workspace index. Focus it across windows; NEVER resume a live row.
        /// IDs are `live:<UUID.uuidString>` and remain stable through filtering.
        var liveTarget: UUID?
        /// Optional exact saved identity on a live row lets merge() attach its
        /// transcript and suppress the duplicate. Never infer identity from cwd.
        var resume: Resume?
        var transcript: Transcript?

        var isLive: Bool { liveTarget != nil }

        static func live(
            target: UUID, title: String, directory: String, agent: Agent? = nil,
            updatedAt: Date = Date(), resume: Resume? = nil
        ) -> Session {
            Session(id: "live:\(target.uuidString)", agent: agent ?? resume?.agent,
                    title: title, directory: directory, account: nil, updatedAt: updatedAt,
                    liveTarget: target, resume: resume)
        }

        static func savedID(agent: Agent, sessionID: String) -> String {
            "\(agent.rawValue):\(sessionID)"
        }
    }

    /// Injectable roots for tests; respects the agents' home overrides.
    struct Roots: Sendable {
        /// Every account's home, the default first.
        var claudeAccounts: [Account]
        var codexAccounts: [Account]
        /// The default homes.
        var claude: URL { claudeAccounts[0].home }
        var codex: URL { codexAccounts[0].home }
        var openCode: URL
        var openCodeDatabase: URL

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
             environment: [String: String] = ProcessInfo.processInfo.environment) {
            func root(_ key: String, _ fallback: URL) -> URL {
                guard let path = environment[key], path.hasPrefix("/") else { return fallback }
                return URL(fileURLWithPath: path)
            }
            claudeAccounts = Account.claude(home: home, environment: environment)
            codexAccounts = Account.codex(home: home, environment: environment)
            openCode = root("XDG_DATA_HOME", home.appendingPathComponent(".local/share"))
                .appendingPathComponent("opencode")
            openCodeDatabase = root("RUNE_OPENCODE_DB", openCode.appendingPathComponent("opencode.db"))
        }
    }

    struct Discovery: Sendable {
        var sessions: [Session]
        var notes: [String]
    }

    struct ContentResults: Sendable {
        var sessions: [Session]
        /// Plain-text excerpts keyed by stable Session.id, including matches
        /// outside the bounded opening/recent preview window.
        var excerpts: [String: String]
        var incomplete: Bool
    }

    static func discover(roots: Roots = Roots()) async -> Discovery {
        await background { discoverSync(roots) }
    }

    static func preview(_ session: Session) async -> String {
        await background {
            guard let source = session.transcript else {
                return session.isLive ? "Live terminal. Return to focus it.\nNo saved transcript is linked."
                    : "No transcript is available."
            }
            var messages: [String] = []
            switch source {
            case .jsonl(let url):
                let head = window(url, bytes: 128 * 1024, tail: false)
                let tail = window(url, bytes: 256 * 1024, tail: true)
                let opening = head.objects.compactMap(messageText)
                messages = Array(opening.prefix(3))
                if tail.offset > 0 {
                    messages.append("[... recent transcript window ...]")
                    messages += tail.objects.compactMap(messageText).suffix(12)
                } else {
                    messages = tail.objects.compactMap(messageText)
                }
            case .openCode(let url, let id):
                _ = database(url) { db in
                    rows(db, """
                        SELECT substr(p.data,1,65536), json_extract(m.data,'$.role')
                        FROM part p LEFT JOIN message m ON m.id=p.message_id
                        WHERE p.session_id=? ORDER BY p.time_created DESC, p.id DESC LIMIT 80
                        """, parameter: id) { row in
                        if let text = openCodeText(text(row, 0)), !text.isEmpty {
                            messages.append("\(textValue(row, 1) ?? "message"):\n\(text)")
                        }
                        return !Task.isCancelled
                    }
                }
                messages.reverse()
            case .openCodeLegacy(let storage, let id):
                _ = legacyParts(storage, id: id) { object in
                    if object["type"] as? String == "text", let text = object["text"] as? String {
                        messages.append(text)
                    }
                    return messages.count < 40 && !Task.isCancelled
                }
            }
            let body = messages.isEmpty ? "No readable messages in the preview window." : messages.joined(separator: "\n\n")
            return display(body, limit: 24_000) + "\n\n[Bounded preview. Content search scans beyond this window.]"
        }
    }

    /// Explicit, literal, case-insensitive content query. Not invoked for each
    /// keystroke. Streaming is bounded to 2 MiB per record and 64 MiB per log;
    /// a 15-second overall budget prevents a large store monopolizing I/O.
    /// `incomplete` must be displayed: no match in a partial scan is not proof.
    /// A faster way to search JSONL transcripts: given the query and the
    /// folders they live in, the first matching line of each file that has
    /// one, keyed by the file's standardized path. See `FFF`.
    typealias Grep = @Sendable (_ query: String, _ folders: [URL])
        -> (lines: [String: String], complete: Bool)

    /// The folders every Claude and Codex account keeps its transcripts in.
    static func transcriptFolders(_ roots: Roots) -> [URL] {
        roots.claudeAccounts.map { $0.home.appendingPathComponent("projects") }
            + roots.codexAccounts.flatMap {
                [$0.home.appendingPathComponent("sessions"),
                 $0.home.appendingPathComponent("archived_sessions")]
            }
    }

    static func searchContent(
        _ query: String, sessions: [Session], grep: Grep? = nil, roots: Roots = Roots()
    ) async -> ContentResults {
        await background {
            let needle = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
            guard !needle.isEmpty else { return ContentResults(sessions: [], excerpts: [:], incomplete: false) }
            let deadline = Date().addingTimeInterval(15)
            var result = ContentResults(sessions: [], excerpts: [:], incomplete: false)

            // One grep over every JSONL transcript when there is a grep to
            // use; the per-file scan below is left with only what it can't
            // cover — OpenCode's database — or everything, when there isn't.
            var grepped: [String: String]?
            if let grep {
                let found = grep(needle, transcriptFolders(roots).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                })
                grepped = found.lines
                if !found.complete { result.incomplete = true }
            }

            for session in sessions {
                guard !Task.isCancelled, Date() < deadline else { result.incomplete = true; break }
                guard let source = session.transcript else { continue }
                if let grepped, case .jsonl(let url) = source {
                    if let line = grepped[url.standardizedFileURL.path] {
                        result.sessions.append(session)
                        result.excerpts[session.id] = excerpt(fromRecord: line, needle: needle)
                    }
                    continue
                }
                let scanned = scan(source, for: needle, deadline: deadline, result: &result)
                if let excerpt = scanned.excerpt {
                    result.sessions.append(session)
                    result.excerpts[session.id] = excerpt
                } else if !scanned.complete { result.incomplete = true }
            }
            return result
        }
    }

    /// The text around `needle` in a matching transcript record: the message
    /// itself when the match is in it, the record's raw text otherwise — a
    /// match can be in a tool's output, and a fuzzy one needn't contain the
    /// query verbatim at all.
    private static func excerpt(fromRecord line: String, needle: String) -> String {
        // The message when it holds the match; otherwise the record itself,
        // with JSON's escapes undone so it reads as text.
        var body = line
        if let message = json(Data(line.utf8)).flatMap(messageText),
           message.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            body = message
        } else {
            body = line.replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\t", with: " ")
        }
        // The whole query where it appears as written; otherwise its longest
        // word, since fff matches words separately and forgives typos.
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
            .sorted { $0.count > $1.count }
        guard let range = ([needle] + words).lazy.compactMap({ body.range(of: $0, options: options) }).first
        else { return display(String(body.prefix(480)), limit: 1_000) }
        let start = body.index(range.lowerBound, offsetBy: -160, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 320, limitedBy: body.endIndex) ?? body.endIndex
        return display(String(body[start..<end]), limit: 1_000)
    }

    /// Read one transcript looking for `needle`, the slow way.
    private static func scan(
        _ source: Transcript, for needle: String, deadline: Date, result: inout ContentResults
    ) -> (excerpt: String?, complete: Bool) {
        var excerpt: String?
        func match(_ body: String) -> Bool {
            if let range = body.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = body.index(range.lowerBound, offsetBy: -160, limitedBy: body.startIndex) ?? body.startIndex
                let end = body.index(range.upperBound, offsetBy: 320, limitedBy: body.endIndex) ?? body.endIndex
                excerpt = display(String(body[start..<end]), limit: 1_000)
                return false
            }
            return !Task.isCancelled && Date() < deadline
        }
        var complete = true
        switch source {
        case .jsonl(let url):
            complete = lines(url, limit: 64 * 1024 * 1024) { object in
                guard let body = messageText(object) else { return !Task.isCancelled && Date() < deadline }
                return match(body)
            }
        case .openCode(let url, let id):
            var bytes = 0
            complete = database(url, deadline: deadline) { db in
                rows(db, "SELECT data FROM part WHERE session_id=? ORDER BY time_created", parameter: id) { row in
                    let size = Int(sqlite3_column_bytes(row, 0))
                    bytes += size
                    guard bytes <= 64 * 1024 * 1024 else { return false }
                    // A part this big is a tool's output — a file read, a
                    // build log — not something said. Skipped as a matter of
                    // course, so not reported as a gap: it made every search
                    // on a machine with one say "partial scan".
                    guard size <= 2 * 1024 * 1024 else { return true }
                    return match(openCodeText(text(row, 0)) ?? "")
                }
            }
        case .openCodeLegacy(let storage, let id):
            complete = legacyParts(storage, id: id, deadline: deadline) { object in
                match(object["type"] as? String == "text" ? object["text"] as? String ?? "" : "")
            }
        }
        return (excerpt, complete)
    }

    /// Metadata-only matching; all whitespace-separated terms must match.
    ///
    /// Field by field, and not across the whole record run together. That
    /// concatenation was the bug behind "searching shows me everything": a term
    /// was accepted as a subsequence of title + full path + agent + session id,
    /// with no limit on how far apart the letters could be, so `rune` matched
    /// almost every session on the machine by picking an r, a u, an n and an e
    /// out of forty characters of `/Users/…/Workspace/…`. Every row came back,
    /// merely reordered, which is not a search.
    ///
    /// A term now has to be a substring of one field, or a *tight* subsequence
    /// of the name — one that starts at a word boundary and doesn't spread more
    /// than about three times its own length, so `sphr` still finds
    /// `Sapphire parser` and nothing finds everything.
    static func filter(_ sessions: [Session], query: String) -> [Session] {
        let terms = display(query, limit: 512).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return sessions }
        return sessions.compactMap { session -> (Session, Int)? in
            guard !Task.isCancelled else { return nil }
            let title = display(session.title, limit: 512).lowercased()
            let directory = display(session.directory, limit: 1024).lowercased()
            let project = String(directory.split(separator: "/").last ?? "")
            let agent = (session.agent?.name ?? "terminal").lowercased()
            let identifier = (session.resume?.sessionID ?? session.id).lowercased()
            let state = session.isLive ? "live" : "saved"

            var total = 0
            for term in terms {
                // Most specific field first: what a session is called beats
                // where it happens to live, which beats which agent ran it.
                let score: Int?
                if title.contains(term) { score = 140 + term.count }
                else if project.contains(term) { score = 110 }
                else if directory.contains(term) { score = 80 }
                else if identifier.contains(term) { score = 90 }
                else if agent.contains(term) { score = 60 }
                else if let account = session.account?.lowercased(), account.contains(term) { score = 60 }
                else if state == term { score = 40 }
                else if let gaps = tight(term, in: title) { score = max(1, 55 - gaps) }
                else if let gaps = tight(term, in: project) { score = max(1, 45 - gaps) }
                else { score = nil }
                guard let score else { return nil }
                total += score
            }
            return (session, total)
        }.sorted { $0.1 == $1.1 ? ordered($0.0, $1.0) : $0.1 > $1.1 }.map(\.0)
    }

    /// `term` as a subsequence of `haystack`, anchored at a word boundary and
    /// held to a span, or nil. Returns how many characters it had to skip, so a
    /// closer match can outrank a looser one.
    private static func tight(_ term: String, in haystack: String) -> Int? {
        let needle = Array(term), hay = Array(haystack)
        guard needle.count > 1, hay.count <= 512 else { return nil }
        // Three times the term's own length is roughly "inside one or two
        // words". Beyond that the letters are no longer a spelling of anything
        // — they are four letters that happen to appear in a sentence.
        let budget = needle.count * 3 + 2
        var best: Int?
        for start in hay.indices where hay[start] == needle[0] && boundary(hay, start) {
            var cursor = start
            var index = 0
            while index < needle.count, cursor < hay.count {
                if hay[cursor] == needle[index] { index += 1 }
                cursor += 1
            }
            guard index == needle.count else { continue }
            let span = cursor - start
            guard span <= budget else { continue }
            let gaps = span - needle.count
            if best == nil || gaps < best! { best = gaps }
        }
        return best
    }

    private static func boundary(_ hay: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = hay[index - 1]
        return !previous.isLetter && !previous.isNumber
    }

    static func merge(_ supplied: [Session], with saved: [Session]) -> [Session] {
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var represented = Set<String>()
        var result: [Session] = []
        var seen = Set<String>()
        for var session in supplied where seen.insert(session.id).inserted {
            if session.isLive, let resume = session.resume {
                let key = Session.savedID(agent: resume.agent, sessionID: resume.sessionID)
                represented.insert(key)
                session.transcript = session.transcript ?? savedByID[key]?.transcript
                session.account = session.account ?? savedByID[key]?.account
            }
            result.append(session)
        }
        result += saved.filter { !represented.contains($0.id) && seen.insert($0.id).inserted }
        return result.sorted(by: ordered)
    }

    /// AppKit gets plain text only. Strip C0/C1 controls and bidi overrides;
    /// never render Markdown/HTML, load attachments, or turn links into actions.
    static func display(_ text: String, limit: Int = 512) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit).filter {
            $0 == "\n" || $0 == "\t" || (!CharacterSet.controlCharacters.contains($0)
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value))
        }))
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func ordered(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private static func discoverSync(_ roots: Roots) -> Discovery {
        var sessions: [Session] = []
        var notes: [String] = []
        var titles: [String: String] = [:]
        for account in roots.codexAccounts {
            _ = lines(account.home.appendingPathComponent("session_index.jsonl"), limit: 8 * 1024 * 1024) { object in
                if let id = object["id"] as? String, let title = object["thread_name"] as? String { titles[id] = title }
                return !Task.isCancelled
            }
        }
        let stores: [(Agent, URL, Account)] =
            roots.claudeAccounts.map { (.claude, $0.home.appendingPathComponent("projects"), $0) }
            + roots.codexAccounts.flatMap { account in
                [(Agent.codex, account.home.appendingPathComponent("sessions"), account),
                 (.codex, account.home.appendingPathComponent("archived_sessions"), account)]
            }
        for (agent, root, account) in stores {
            let files = enumerate(root, extension: "jsonl", limit: 20_000)
            if files.limited { notes.append("\(agent.name) discovery reached its file limit.") }
            for url in files.urls {
                guard !Task.isCancelled else { break }
                // Claude subagents are not independently resumable conversations.
                if agent == .claude && (url.pathComponents.contains("subagents") || url.lastPathComponent.hasPrefix("agent-")) { continue }
                let header = window(url, bytes: 256 * 1024, tail: false).objects
                var id: String?
                var directory: String?
                var title: String?
                for object in header {
                    let payload = object["payload"] as? [String: Any] ?? [:]
                    if agent == .codex, object["type"] as? String == "session_meta" {
                        id = payload["id"] as? String
                        directory = payload["cwd"] as? String
                    } else if agent == .claude {
                        id = id ?? object["sessionId"] as? String
                        directory = directory ?? object["cwd"] as? String
                    }
                    if title == nil, let text = messageText(object), text.hasPrefix("user:\n") {
                        title = String(text.dropFirst(6).prefix(160))
                    }
                }
                if agent == .claude {
                    id = id ?? url.deletingPathExtension().lastPathComponent
                    for object in window(url, bytes: 64 * 1024, tail: true).objects {
                        if let custom = object["customTitle"] as? String { title = custom }
                        else if let summary = object["summary"] as? String { title = summary }
                    }
                }
                guard let id, let directory,
                      let resume = Resume(agent: agent, sessionID: id, directory: directory,
                                          accountHome: account.override)
                else { continue }
                let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                sessions.append(Session(id: Session.savedID(agent: agent, sessionID: id), agent: agent,
                    title: display((agent == .codex ? titles[id] : nil) ?? title ?? "\(agent.name) \(id.prefix(8))"),
                    directory: directory, account: account.name, updatedAt: updated,
                    resume: resume, transcript: .jsonl(url)))
            }
        }
        if FileManager.default.fileExists(atPath: roots.openCodeDatabase.path) {
            var count = 0
            let ok = database(roots.openCodeDatabase) { db in
                rows(db, "SELECT id,title,directory,time_updated FROM session ORDER BY time_updated DESC LIMIT 20001") { row in
                    guard !Task.isCancelled else { return false }
                    count += 1
                    if count > 20_000 { notes.append("OpenCode discovery reached its session limit."); return false }
                    guard let id = textValue(row, 0), let directory = textValue(row, 2),
                          let resume = Resume(agent: .openCode, sessionID: id, directory: directory) else { return true }
                    sessions.append(Session(id: Session.savedID(agent: .openCode, sessionID: id), agent: .openCode,
                        title: display(textValue(row, 1) ?? id), directory: directory, account: nil,
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3) / 1000),
                        resume: resume, transcript: .openCode(database: roots.openCodeDatabase, sessionID: id)))
                    return true
                }
            }
            if !ok && !Task.isCancelled { notes.append("OpenCode database could not be fully read (locked or unsupported schema).") }
        }
        let storage = roots.openCode.appendingPathComponent("storage")
        let legacy = enumerate(storage.appendingPathComponent("session"), extension: "json", limit: 20_000)
        if legacy.limited { notes.append("OpenCode legacy discovery reached its file limit.") }
        for url in legacy.urls {
            guard !Task.isCancelled else { break }
            guard let object = smallJSON(url), let id = object["id"] as? String,
                  let directory = object["directory"] as? String,
                  let resume = Resume(agent: .openCode, sessionID: id, directory: directory) else { continue }
            let time = object["time"] as? [String: Any]
            sessions.append(Session(id: Session.savedID(agent: .openCode, sessionID: id), agent: .openCode,
                title: display(object["title"] as? String ?? id), directory: directory, account: nil,
                updatedAt: Date(timeIntervalSince1970: (time?["updated"] as? Double ?? 0) / 1000),
                resume: resume, transcript: .openCodeLegacy(storage: storage, sessionID: id)))
        }
        return Discovery(sessions: merge([], with: sessions), notes: notes)
    }

    private static func enumerate(_ root: URL, extension ext: String, limit: Int) -> (urls: [URL], limited: Bool) {
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return ([], false) }
        var result: [URL] = []
        var visited = 0
        for case let url as URL in iterator {
            if Task.isCancelled { break }
            visited += 1
            if visited > 100_000 || result.count >= limit { return (result, true) }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if url.pathExtension == ext && values?.isRegularFile == true { result.append(url) }
        }
        return (result.sorted { $0.path < $1.path }, false)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func smallJSON(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2 * 1024 * 1024 + 1), data.count <= 2 * 1024 * 1024 else { return nil }
        return json(data)
    }

    private static func window(_ url: URL, bytes: Int, tail: Bool) -> (objects: [[String: Any]], offset: UInt64) {
        guard !Task.isCancelled, let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], 0) }
        let offset = tail && size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: bytes) else { return ([], offset) }
        var records = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0 && !records.isEmpty { records.removeFirst() }
        if offset + UInt64(data.count) < size && !records.isEmpty { records.removeLast() }
        return (records.compactMap { Task.isCancelled ? nil : json(Data($0)) }, offset)
    }

    /// Stream complete JSONL records, dropping oversized records without ever
    /// accumulating them. False means stopped early, unreadable, or truncated.
    private static func lines(_ url: URL, limit: Int, body: ([String: Any]) -> Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var pending = Data()
        var skipping = false
        var complete = true
        var total = 0
        while !Task.isCancelled && total < limit {
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(64 * 1024, limit - total)) ?? Data() }
            catch { return false }
            if chunk.isEmpty {
                if !pending.isEmpty {
                    guard let object = json(pending), body(object) else { return false }
                }
                return complete
            }
            total += chunk.count
            for piece in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                if piece.offset > 0 {
                    if !skipping && !pending.isEmpty {
                        if let object = json(pending) { if !body(object) { return false } }
                        else { complete = false }
                    }
                    pending.removeAll(keepingCapacity: true)
                    skipping = false
                }
                if !skipping {
                    if pending.count + piece.element.count > 2 * 1024 * 1024 {
                        pending.removeAll(keepingCapacity: true)
                        skipping = true
                        complete = false
                    } else { pending.append(contentsOf: piece.element) }
                }
            }
        }
        return false
    }

    private static func messageText(_ object: [String: Any]) -> String? {
        let type = object["type"] as? String
        let message: [String: Any]
        if type == "user" || type == "assistant" {
            message = object["message"] as? [String: Any] ?? [:]
        } else if type == "response_item", let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message" {
            message = payload
        } else if type == "event_msg", let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message", let text = payload["message"] as? String {
            return "user:\n" + text
        } else { return nil }
        let role = message["role"] as? String ?? type ?? "message"
        guard role == "user" || role == "assistant" else { return nil }
        if let text = message["content"] as? String { return "\(role):\n\(text)" }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : "\(role):\n\(text)"
    }

    private static func openCodeText(_ data: Data?) -> String? {
        guard let data, let object = json(data), object["type"] as? String == "text" else { return nil }
        return object["text"] as? String
    }

    private static func database(_ url: URL, deadline: Date = .distantFuture, body: (OpaquePointer) -> Bool) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        // Called on the same worker thread, including while SQLite sorts/scans.
        var end = deadline.timeIntervalSinceReferenceDate
        return withUnsafeMutablePointer(to: &end) { pointer in
            sqlite3_progress_handler(db, 1000, { context in
                let end = context!.assumingMemoryBound(to: TimeInterval.self).pointee
                return Task.isCancelled || Date.timeIntervalSinceReferenceDate >= end ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return body(db)
        }
    }

    @discardableResult
    private static func rows(_ db: OpaquePointer, _ sql: String, parameter: String? = nil,
                             body: (OpaquePointer) -> Bool) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        if let parameter {
            _ = parameter.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        while !Task.isCancelled {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return true }
            guard status == SQLITE_ROW, body(statement) else { return false }
        }
        return false
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_text(row, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column)))
    }

    private static func textValue(_ row: OpaquePointer, _ column: Int32) -> String? {
        text(row, column).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func legacyParts(_ storage: URL, id: String, deadline: Date = .distantFuture,
                                    body: ([String: Any]) -> Bool) -> Bool {
        let messages = enumerate(storage.appendingPathComponent("message").appendingPathComponent(id), extension: "json", limit: 5_000)
        var complete = !messages.limited
        for message in messages.urls {
            guard !Task.isCancelled, Date() < deadline else { return false }
            let parts = enumerate(storage.appendingPathComponent("part").appendingPathComponent(message.deletingPathExtension().lastPathComponent), extension: "json", limit: 2_000)
            complete = complete && !parts.limited
            for part in parts.urls {
                guard !Task.isCancelled, Date() < deadline else { return false }
                guard let object = smallJSON(part) else { complete = false; continue }
                if !body(object) { return false }
            }
        }
        return complete
    }
}
