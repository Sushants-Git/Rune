import Foundation

/// A parsed unified diff.
///
/// Rune shells out to `git diff` rather than linking libgit2. The output is a
/// format that has not changed in twenty years, the parse is a hundred lines,
/// and it means the diff you are looking at is the diff git would print — same
/// renames, same binary detection, same submodule handling, and the user's own
/// `diff.algorithm` and `.gitattributes` already apply.
enum GitDiff {
    struct File {
        /// Nil when the file is new.
        let oldPath: String?
        /// Nil when the file was deleted.
        let newPath: String?
        var hunks: [Hunk]
        /// Git said the contents are binary, so there is nothing to show.
        var isBinary: Bool
        /// Where the change currently lives. A file can be in both — some
        /// hunks staged, the rest not — which is why these are not one enum.
        var staged = false
        var unstaged = false
        /// Git has never seen this file. `git diff` says nothing about those,
        /// which is the whole reason Rune used to call a dirty tree clean.
        var untracked = false

        /// What the header calls it: the new name, or the old one if it is gone.
        var displayPath: String { newPath ?? oldPath ?? "?" }

        var isRename: Bool {
            guard let oldPath, let newPath else { return false }
            return oldPath != newPath
        }

        var addedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var removedCount: Int {
            hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
        }
    }

    struct Hunk {
        /// The `@@ … @@` line verbatim, trailing section heading included — git
        /// puts the enclosing function there and it is worth keeping.
        let header: String
        let lines: [Line]

        /// The first line number on each side, read back out of the header.
        /// Parsed here rather than at parse time because only patch generation
        /// wants them, and the header is the authority either way.
        var oldStart: Int { Self.start(in: header, prefix: "-") }
        var newStart: Int { Self.start(in: header, prefix: "+") }

        private static func start(in header: String, prefix: Character) -> Int {
            guard let range = header.range(of: "@@ "), let end = header.range(of: " @@") else {
                return 1
            }
            let body = header[range.upperBound..<end.lowerBound]
            for field in body.split(separator: " ") where field.first == prefix {
                let digits = field.dropFirst().prefix { $0.isNumber }
                return Int(digits) ?? 1
            }
            return 1
        }
    }

    struct Line {
        enum Kind { case context, added, removed }
        let kind: Kind
        let text: String
        /// Where this line sits in each side, for the gutter. Nil on the side
        /// the line does not exist in.
        let oldNumber: Int?
        let newNumber: Int?
    }

    // MARK: - Staging part of a file

    /// A patch containing only the lines you picked out of a file.
    ///
    /// One patch for the whole file rather than one per hunk: applied
    /// separately, the second hunk's line numbers would already be stale from
    /// the first one landing, and git would be left matching on context to
    /// recover a position it should never have lost.
    ///
    /// The rules are the ones every partial-staging tool implements: a change
    /// you did not select has to leave the patch without moving anything around
    /// it, so an unselected addition is dropped and an unselected deletion
    /// becomes context — the line is still there in the version this patch
    /// applies to, which is exactly what a context line says.
    ///
    /// The counts in the header are left approximate on purpose; `git apply
    /// --recount` works them out from the body, and a hand-counted header is a
    /// second place for this to be subtly wrong.
    static func patch(
        for file: File, selecting selection: [(hunk: Hunk, lines: Set<Int>)]
    ) -> String? {
        var body: [String] = []

        for entry in selection {
            var hunkBody: [String] = []
            var oldCount = 0
            var newCount = 0

            for (index, line) in entry.hunk.lines.enumerated() {
                switch (line.kind, entry.lines.contains(index)) {
                case (.context, _):
                    hunkBody.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                case (.added, true):
                    hunkBody.append("+" + line.text)
                    newCount += 1
                case (.added, false):
                    continue
                case (.removed, true):
                    hunkBody.append("-" + line.text)
                    oldCount += 1
                case (.removed, false):
                    hunkBody.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                }
            }
            // Context only: the selection covered no change in this hunk, so it
            // contributes nothing rather than an empty hunk to fail on.
            guard hunkBody.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else {
                continue
            }
            body.append(
                "@@ -\(entry.hunk.oldStart),\(oldCount) +\(entry.hunk.newStart),\(newCount) @@")
            body.append(contentsOf: hunkBody)
        }
        guard !body.isEmpty else { return nil }

        // An untracked file is `add --intent-to-add`-ed first, which puts an
        // empty entry in the index — so by the time this applies, the old side
        // exists and naming it `/dev/null` would be rejected as "already
        // exists in index".
        let old = file.untracked
            ? "a/" + file.displayPath
            : file.oldPath.map { "a/" + $0 } ?? "/dev/null"
        let new = file.newPath.map { "b/" + $0 } ?? "/dev/null"
        var text = [
            "diff --git a/\(file.oldPath ?? file.displayPath) b/\(file.newPath ?? file.displayPath)",
            "--- \(old)",
            "+++ \(new)",
        ]
        text.append(contentsOf: body)
        return text.joined(separator: "\n") + "\n"
    }

    /// Feed a patch to the index. `--recount` because the header's counts are
    /// deliberately approximate; `--cached` because the working tree is already
    /// what the user wants and only the index is being edited.
    static func apply(
        patch: String, in directory: String, reverse: Bool = false
    ) throws {
        var arguments = ["apply", "--cached", "--recount", "--allow-empty"]
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        _ = try run(arguments, in: directory, input: patch)
    }

    /// Tell git a new file exists without staging its contents, so a patch
    /// has an index entry to land on rather than being told the path is
    /// unknown.
    static func intentToAdd(_ paths: [String], in directory: String) throws {
        guard !paths.isEmpty else { return }
        _ = try run(["add", "--intent-to-add", "--"] + paths, in: directory)
    }

    // MARK: - Running

    enum Failure: Error {
        case notARepository
        case git(String)
    }

    /// Everything uncommitted: staged, unstaged, and files git has never seen.
    ///
    /// `git diff HEAD` covers the first two — a plain `git diff` would hide
    /// anything already staged, and a file you staged an hour ago vanishing
    /// from the list is not a useful answer. It covers the third not at all,
    /// and that omission is why Rune reported a clean tree next to a lazygit
    /// listing two untracked files. An untracked file has no blob to diff
    /// against, so its contents are read and presented as one added hunk,
    /// which is what it is.
    static func uncommitted(in directory: String) throws -> [File] {
        _ = try run(["rev-parse", "--is-inside-work-tree"], in: directory)
        let output = try run(
            ["diff", "HEAD", "--no-color", "--no-ext-diff", "-U3", "--find-renames"],
            in: directory)
        var files = parse(output)

        // Where each change lives, so the list can say "staged" and the keys
        // know which direction to move it.
        let status = try? self.status(in: directory)
        for index in files.indices {
            guard let state = status?[files[index].displayPath] else { continue }
            files[index].staged = state.index != " " && state.index != "?"
            files[index].unstaged = state.worktree != " " && state.worktree != "?"
        }

        let root = repositoryRoot(of: directory) ?? directory
        for (path, state) in (status ?? [:]) where state.index == "?" {
            files.append(untrackedFile(at: path, root: root))
        }
        return files.sorted { $0.displayPath < $1.displayPath }
    }

    /// `git status --porcelain`, as index/worktree letters keyed by path.
    static func status(in directory: String) throws -> [String: (index: Character, worktree: Character)] {
        let output = try run(
            ["status", "--porcelain", "--untracked-files=all", "--no-renames"], in: directory)
        var result: [String: (Character, Character)] = [:]
        for line in output.split(separator: "\n") where line.count > 3 {
            let characters = Array(line)
            let path = String(characters[3...]).trimmingCharacters(in: .whitespaces)
            // Quoted when it has anything unusual in it; git's own escaping.
            let unquoted = path.hasPrefix("\"") && path.hasSuffix("\"")
                ? String(path.dropFirst().dropLast())
                : path
            result[unquoted] = (characters[0], characters[1])
        }
        return result
    }

    /// A file git has never seen, shown as though every line were added.
    private static func untrackedFile(at path: String, root: String) -> File {
        let full = (root as NSString).appendingPathComponent(path)
        guard let data = FileManager.default.contents(atPath: full) else {
            return File(oldPath: nil, newPath: path, hunks: [], isBinary: true, untracked: true)
        }
        // A NUL in the first block is what `git` itself treats as binary.
        if data.prefix(8000).contains(0) || data.count > 2_000_000 {
            return File(oldPath: nil, newPath: path, hunks: [], isBinary: true, untracked: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        var body = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A trailing newline splits into a final empty piece that is not a line.
        if body.last == "" { body.removeLast() }

        let lines = body.enumerated().map { index, content in
            Line(kind: .added, text: content, oldNumber: nil, newNumber: index + 1)
        }
        let hunk = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: lines)
        return File(
            oldPath: nil, newPath: path, hunks: lines.isEmpty ? [] : [hunk],
            isBinary: false, unstaged: true, untracked: true)
    }

    // MARK: - Changing things

    /// `git add`. On an untracked file this is what starts tracking it.
    static func stage(_ paths: [String], in directory: String) throws {
        guard !paths.isEmpty else { return }
        _ = try run(["add", "--"] + paths, in: directory)
    }

    /// Back out of the index, leaving the working tree alone.
    static func unstage(_ paths: [String], in directory: String) throws {
        guard !paths.isEmpty else { return }
        _ = try run(["restore", "--staged", "--"] + paths, in: directory)
    }

    /// Commit what is staged. Returns git's own summary line.
    static func commit(message: String, in directory: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.git("a commit needs a message") }
        return try run(["commit", "-m", trimmed], in: directory)
            .split(separator: "\n").first.map(String.init) ?? "committed"
    }

    static func stagedCount(in directory: String) -> Int {
        ((try? status(in: directory)) ?? [:])
            .filter { $0.value.index != " " && $0.value.index != "?" }.count
    }

    /// The repository root, or nil if `directory` isn't in one.
    static func repositoryRoot(of directory: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a process actually is.
    ///
    /// Rune's `pwd` comes from OSC 7, which only arrives if the shell has
    /// Ghostty's integration loaded — and plenty do not. Asking the kernel
    /// instead needs no cooperation from the shell at all, so the diff works in
    /// a terminal that has never emitted an escape sequence in its life. This
    /// is the fallback, not the primary: OSC 7 follows `cd` inside the shell
    /// and is the more accurate answer when it is there.
    static func workingDirectory(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(validatingCString: $0)
            }
        }
    }

    private static func run(
        _ arguments: [String], in directory: String, input: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // Or a repository with a pager configured hangs waiting for a terminal
        // that isn't there.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        try process.run()
        if let input {
            // Written and closed before anything is read back, because a patch
            // is small enough to fit the pipe buffer and git will not say a
            // word until it has seen the end of it.
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()
        }

        // Read before waiting: a diff larger than the pipe buffer fills it, git
        // blocks writing, and a `waitUntilExit` first would deadlock on any
        // change big enough to be worth looking at.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: problem, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw message.contains("not a git repository")
                ? Failure.notARepository
                : Failure.git(message.isEmpty ? "git exited \(process.terminationStatus)" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [File] {
        var files: [File] = []
        var oldPath: String?
        var newPath: String?
        var binary = false
        var hunks: [Hunk] = []
        var header: String?
        var lines: [Line] = []
        var oldNumber = 0
        var newNumber = 0

        func closeHunk() {
            guard let open = header else { return }
            hunks.append(Hunk(header: open, lines: lines))
            header = nil
            lines = []
        }

        func closeFile() {
            closeHunk()
            guard oldPath != nil || newPath != nil else { return }
            files.append(
                File(oldPath: oldPath, newPath: newPath, hunks: hunks, isBinary: binary))
            oldPath = nil
            newPath = nil
            binary = false
            hunks = []
        }

        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in rawLines.enumerated() {
            let line = String(raw)

            // The text ends with a newline, so splitting it leaves one empty
            // piece on the end that is not a line of anything. Counting it as
            // context invented a line the file does not have — invisible on
            // screen, and fatal to a generated patch, which git rejected for
            // describing nine lines where there were eight.
            if line.isEmpty, index == rawLines.count - 1 { continue }

            if line.hasPrefix("diff --git ") {
                closeFile()
                // The paths come off this line as well as off `---`/`+++`,
                // because a binary file has no `---`/`+++` at all — git says
                // "Binary files … differ" and moves on. Taking them only from
                // those two dropped every binary file on the floor.
                let rest = String(line.dropFirst("diff --git ".count))
                if let boundary = rest.range(of: " b/") {
                    oldPath = stripPrefix(String(rest[rest.startIndex..<boundary.lowerBound]))
                    newPath = stripPrefix(String(rest[boundary.lowerBound...].dropFirst()))
                }
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                binary = true
                continue
            }
            if line.hasPrefix("--- ") {
                let path = String(line.dropFirst(4))
                oldPath = path == "/dev/null" ? nil : stripPrefix(path)
                continue
            }
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                newPath = path == "/dev/null" ? nil : stripPrefix(path)
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                header = line
                (oldNumber, newNumber) = startNumbers(line)
                continue
            }
            // Everything before the first `@@` is git's own metadata: mode
            // changes, similarity scores, index lines. The header rows carry
            // what matters, so it is dropped rather than shown.
            guard header != nil else { continue }

            if line.hasPrefix("+") {
                lines.append(Line(
                    kind: .added, text: String(line.dropFirst()),
                    oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            } else if line.hasPrefix("-") {
                lines.append(Line(
                    kind: .removed, text: String(line.dropFirst()),
                    oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" belongs to the line above and
                // is not a line of the file.
                continue
            } else if line.hasPrefix(" ") || line.isEmpty {
                lines.append(Line(
                    kind: .context, text: line.isEmpty ? "" : String(line.dropFirst()),
                    oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
        }
        closeFile()
        return files
    }

    /// `a/src/main.swift` → `src/main.swift`.
    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// The two starting line numbers out of `@@ -12,7 +12,9 @@`.
    private static func startNumbers(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func number(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            let digits = token.dropFirst().prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (number(parts[safe: 1]), number(parts[safe: 2]))
    }
}
