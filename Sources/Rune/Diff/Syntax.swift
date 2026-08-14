import Cocoa

/// Enough syntax highlighting to read a diff by.
///
/// A hand-written scanner rather than tree-sitter, and rather than shelling out
/// to `delta`. Tree-sitter is grammars, queries, a theme mapping and incremental
/// parsing — weeks of work for a panel you glance at. `delta` would be better
/// than this at the cost of a dependency Rune cannot assume is installed, and a
/// diff that highlights on one machine and not another is worse than one that
/// looks the same everywhere.
///
/// What this does get right is the part that carries a diff: comments recede,
/// strings and numbers stand out, keywords anchor the structure. What it gets
/// wrong is anything needing context beyond the line — a `/* … */` spanning
/// lines, a nested interpolation. Those are wrong quietly, which is the only
/// acceptable way for a highlighter to be wrong.
enum Syntax {
    enum Token {
        case plain, keyword, string, comment, number, type

        @MainActor func color(in theme: DiffTheme) -> NSColor? {
            let palette = theme.syntax
            switch self {
            case .plain: return nil
            case .keyword: return palette.keyword
            case .string: return palette.string
            case .comment: return palette.comment
            case .number: return palette.number
            case .type: return palette.type
            }
        }
    }

    /// What the scanner needs to know about a file, which is much less than a
    /// language definition: how it starts a comment, whether it has types worth
    /// picking out, and its keywords.
    struct Language {
        let lineComments: [String]
        let keywords: Set<String>
        /// Whether a capitalised word is likely a type. True for Swift and
        /// friends, false for languages where capitals mean constants.
        let capitalsAreTypes: Bool

        static let none = Language(lineComments: [], keywords: [], capitalsAreTypes: false)
    }

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default",
        "do", "new", "delete", "class", "struct", "enum", "public", "private", "protected",
        "static", "const", "void", "int", "char", "bool", "true", "false", "null", "nil",
    ]

    private static let swift = Language(
        lineComments: ["//"],
        keywords: cFamily.union([
            "func", "let", "var", "guard", "import", "extension", "protocol", "init", "self",
            "override", "final", "throws", "try", "catch", "async", "await", "where", "some",
            "any", "in", "is", "as", "defer", "typealias", "associatedtype", "lazy", "weak",
        ]),
        capitalsAreTypes: true)

    private static let script = Language(
        lineComments: ["//"],
        keywords: cFamily.union([
            "function", "const", "let", "var", "async", "await", "export", "import", "from",
            "type", "interface", "extends", "implements", "of", "in", "typeof", "instanceof",
            "undefined", "this", "yield", "throw", "try", "catch", "finally",
        ]),
        capitalsAreTypes: true)

    private static let python = Language(
        lineComments: ["#"],
        keywords: [
            "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
            "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass",
            "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False",
            "self", "async", "await", "global", "nonlocal", "assert", "del",
        ],
        capitalsAreTypes: true)

    private static let shell = Language(
        lineComments: ["#"],
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
            "function", "return", "export", "local", "echo", "cd", "set", "in",
        ],
        capitalsAreTypes: false)

    static func language(forPath path: String) -> Language {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": script
        case "py": python
        case "sh", "bash", "zsh", "fish": shell
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "cs", "go", "rs", "zig":
            Language(lineComments: ["//"], keywords: cFamily, capitalsAreTypes: true)
        case "rb": Language(lineComments: ["#"], keywords: python.keywords, capitalsAreTypes: true)
        case "yml", "yaml", "toml", "conf", "gitignore":
            Language(lineComments: ["#"], keywords: [], capitalsAreTypes: false)
        default: .none
        }
    }

    /// Spans over the line's UTF-16, in order, non-overlapping.
    ///
    /// Only the runs worth colouring are returned; everything between them is
    /// plain, and the caller leaves it alone.
    static func spans(in line: String, language: Language) -> [(NSRange, Token)] {
        guard !language.keywords.isEmpty || !language.lineComments.isEmpty else { return [] }

        let characters = Array(line)
        var spans: [(NSRange, Token)] = []
        var index = 0

        /// UTF-16 length of everything before `position`, since the caller
        /// indexes an `NSAttributedString` and Swift characters are not that.
        func utf16Offset(_ position: Int) -> Int {
            String(characters[0..<position]).utf16.count
        }

        func append(_ start: Int, _ end: Int, _ token: Token) {
            let from = utf16Offset(start)
            let to = utf16Offset(end)
            spans.append((NSRange(location: from, length: to - from), token))
        }

        while index < characters.count {
            let character = characters[index]

            // A line comment takes the rest of the line and stops the scan.
            if let marker = language.lineComments.first(where: { starts(characters, index, $0) }) {
                _ = marker
                append(index, characters.count, .comment)
                break
            }

            if character == "\"" || character == "'" || character == "`" {
                let quote = character
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == quote { end += 1; break }
                    end += 1
                }
                append(index, min(end, characters.count), .string)
                index = min(end, characters.count)
                continue
            }

            if character.isNumber, index == 0 || !isWordCharacter(characters[index - 1]) {
                var end = index
                while end < characters.count,
                      characters[end].isHexDigit || characters[end] == "." || characters[end] == "x" {
                    end += 1
                }
                append(index, end, .number)
                index = end
                continue
            }

            if isWordCharacter(character), index == 0 || !isWordCharacter(characters[index - 1]) {
                var end = index
                while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                if language.keywords.contains(word) {
                    append(index, end, .keyword)
                } else if language.capitalsAreTypes, let first = word.first, first.isUppercase {
                    append(index, end, .type)
                }
                index = end
                continue
            }

            index += 1
        }
        return spans
    }

    private static func starts(_ characters: [Character], _ index: Int, _ marker: String) -> Bool {
        let needle = Array(marker)
        guard index + needle.count <= characters.count else { return false }
        return Array(characters[index..<(index + needle.count)]) == needle
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
