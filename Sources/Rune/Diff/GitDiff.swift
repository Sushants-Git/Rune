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
        let hunks: [Hunk]
        /// Git said the contents are binary, so there is nothing to show.
        let isBinary: Bool

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

    // MARK: - Running

    enum Failure: Error {
        case notARepository
        case git(String)
    }

    /// Everything uncommitted: staged and unstaged together, which is what
    /// "what have I changed" means to someone who has not thought about the
    /// index. `HEAD` rather than no argument for exactly that reason — a plain
    /// `git diff` hides anything already staged, and a file you staged an hour
    /// ago vanishing from the list is not a useful answer.
    static func uncommitted(in directory: String) throws -> [File] {
        _ = try run(["rev-parse", "--is-inside-work-tree"], in: directory)
        let output = try run(
            ["diff", "HEAD", "--no-color", "--no-ext-diff", "-U3", "--find-renames"],
            in: directory)
        return parse(output)
    }

    /// The repository root, or nil if `directory` isn't in one.
    static func repositoryRoot(of directory: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ arguments: [String], in directory: String) throws -> String {
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
        try process.run()

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

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

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
