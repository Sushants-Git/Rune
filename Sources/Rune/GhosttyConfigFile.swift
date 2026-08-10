import Foundation

/// Reads and edits the Ghostty config file, in place.
///
/// This is a text editor with opinions, not a serialiser. Nobody's config is
/// only settings — it is settings with comments explaining them, in an order
/// that meant something to whoever wrote it, next to keys Rune has never heard
/// of. So nothing is ever regenerated: a change rewrites the one line it is
/// about and leaves every other byte where it was. A key Rune does not know is
/// a key Rune cannot damage.
struct GhosttyConfigFile {
    /// Where Ghostty looks, in the order it loads them. Later files win, so the
    /// last one that exists is the one worth editing — writing to an earlier
    /// one would be quietly overridden by a later one and look like a bug in
    /// the settings window.
    ///
    /// Ghostty 1.3 moved the XDG file to `config.ghostty` and kept reading the
    /// old name, so both are here.
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            xdg.appendingPathComponent("ghostty/config"),
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            support.appendingPathComponent("com.mitchellh.ghostty/config"),
            support.appendingPathComponent("com.mitchellh.ghostty/config.ghostty"),
        ]
    }

    /// The file to edit: the last one Ghostty loads that actually sets
    /// something, falling back to the last that exists, then to the modern XDG
    /// path where a new config belongs.
    ///
    /// The "sets something" part is load-bearing. Ghostty creates an *empty*
    /// config under Application Support on first run when no XDG file exists,
    /// and that file is loaded last — so a plain last-one-wins rule points the
    /// whole pane at a blank file and reports every setting unset while the
    /// user's real config sits one directory away. Precedence is preserved
    /// either way: writing to an earlier file still takes effect, because the
    /// later one is empty and overrides nothing.
    static var location: URL { resolve(candidates) }

    /// Split out from `location` so the ordering rule can be tested against a
    /// list the test controls. The real candidates include paths under
    /// Application Support, which no environment variable can redirect.
    static func resolve(_ candidates: [URL]) -> URL {
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing.last { GhosttyConfigFile(url: $0).setsAnything }
            ?? existing.last
            ?? candidates[1]
    }

    /// Does this file assign anything at all, as opposed to being empty or
    /// nothing but comments?
    var setsAnything: Bool {
        lines.contains { Self.key(ofLine: $0) != nil }
    }

    /// Config files that actually set something, beyond the one being edited.
    ///
    /// Only these are worth warning about. An empty file Ghostty made for
    /// itself is not a conflict, and saying it is would be crying wolf on every
    /// machine that has never had an XDG config.
    static var competingFiles: [URL] {
        let editing = location
        return candidates.filter {
            $0 != editing
                && FileManager.default.fileExists(atPath: $0.path)
                && GhosttyConfigFile(url: $0).setsAnything
        }
    }

    let url: URL
    private(set) var lines: [String]

    init(url: URL = GhosttyConfigFile.location) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // `split` would swallow the blank lines that give a config its shape.
        self.lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    // MARK: - Reading

    /// The value the file gives a key, or nil if it never mentions it.
    ///
    /// The *last* assignment, because that is the one Ghostty will use.
    func value(for key: String) -> String? {
        guard let index = indices(of: key).last else { return nil }
        return Self.value(ofLine: lines[index])
    }

    private func indices(of key: String) -> [Int] {
        lines.indices.filter { Self.key(ofLine: lines[$0]) == key }
    }

    /// The key a line assigns, or nil if the line is a comment, blank, or one
    /// of Ghostty's bare directives.
    static func key(ofLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    static func value(ofLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[trimmed.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Writing

    /// Set a key, or remove it entirely when `value` is nil.
    ///
    /// Setting rewrites the last assignment in place, keeping its indentation
    /// and its position among the comments around it. Removing takes out every
    /// assignment, not just the last: leaving an earlier one behind would mean
    /// "back to the Ghostty default" quietly left the key set.
    mutating func set(_ key: String, to value: String?) {
        let found = indices(of: key)

        guard let value else {
            for index in found.reversed() { lines.remove(at: index) }
            pruneEmptyHeading()
            return
        }

        if let last = found.last {
            let indent = lines[last].prefix { $0 == " " || $0 == "\t" }
            lines[last] = "\(indent)\(key) = \(value)"
            return
        }

        appendNew("\(key) = \(value)")
    }

    /// A key the file has never had joins a section at the end, under a heading
    /// that says where it came from — so someone opening the file in a month
    /// can tell what they wrote from what a settings window wrote for them.
    private mutating func appendNew(_ line: String) {
        // Everything goes in *before* the trailing blank lines rather than
        // after them. A file's last line is usually empty — that is its final
        // newline — and appending past it both loses the newline and grows a
        // blank line every time a key is added.
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }

        if let heading = lines.firstIndex(where: { $0.hasPrefix(Self.heading) }) {
            var insert = heading + 1
            while insert < end, Self.key(ofLine: lines[insert]) != nil { insert += 1 }
            lines.insert(line, at: insert)
            return
        }

        var block: [String] = []
        if end > 0 { block.append("") }
        block.append(Self.heading)
        block.append(line)
        lines.insert(contentsOf: block, at: end)
    }

    /// Take the heading away once the last key under it is gone. A section
    /// header with nothing beneath it is a leftover, and it would sit in the
    /// file forever claiming Rune had written something.
    private mutating func pruneEmptyHeading() {
        guard let heading = lines.firstIndex(where: { $0.hasPrefix(Self.heading) }) else { return }
        var next = heading + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            next += 1
        }
        if next < lines.count, Self.key(ofLine: lines[next]) != nil { return }

        lines.remove(at: heading)
        // And the blank line that introduced it, so removing the last key
        // leaves the file exactly as it was before the first one was added.
        if heading > 0, lines[heading - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: heading - 1)
        }
    }

    private static let heading = "# Written by Rune"

    /// Write the file back.
    ///
    /// Through a temporary file in the same directory and an atomic replace, so
    /// a crash or a full disk cannot leave a half-written config — which
    /// Ghostty would refuse to parse, on a file the user did not break.
    ///
    /// The first write also leaves a copy of the original alongside it. This is
    /// the one part of Rune that edits something a user wrote by hand.
    func save() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let backup = url.appendingPathExtension("rune-backup")
        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        // Exactly one trailing newline. Preserving whatever the file had
        // sounds more respectful, but it means a config that never had one
        // never gets one, and every tool that touches it afterwards — git,
        // an editor, `cat` — has an opinion about that.
        var output = lines
        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()
        }
        let text = output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
        let temporary = directory.appendingPathComponent(".rune-config-\(UUID().uuidString)")
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // `replaceItemAt` needs something to replace; a config that does not
            // exist yet is the ordinary first-run case, not a failure.
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
