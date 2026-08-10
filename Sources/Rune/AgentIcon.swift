import Cocoa

/// A coding agent Rune recognises by its running process, so ⌘K can show what
/// a workspace is actually doing rather than a generic terminal glyph.
enum AgentIcon: CaseIterable {
    case claude
    case codex
    case openCode

    /// Match a process's command line. Agents are usually launched through a
    /// JavaScript runtime, so `node /…/claude` has to resolve to Claude and not
    /// to node — hence the scan across arguments rather than just argv[0].
    static func detect(arguments: [String]) -> AgentIcon? {
        // The command's own name is the reliable signal, so try that first.
        for argument in arguments.prefix(6) {
            let name = (argument as NSString).lastPathComponent.lowercased()
            for agent in allCases where agent.matches(name) { return agent }
        }

        // Failing that, the install directory. A runtime wrapper hides the name
        // entirely — `node …/.claude/local/…/cli.js` is argv full of "node" and
        // "cli.js" — but the path it's running from still says who it is.
        let line = arguments.prefix(6).joined(separator: " ").lowercased()
        for agent in allCases where agent.markers.contains(where: line.contains) {
            return agent
        }
        return nil
    }

    private func matches(_ name: String) -> Bool {
        switch self {
        case .claude: name == "claude" || name.hasPrefix("claude-")
        case .codex: name == "codex" || name.hasPrefix("codex-")
        case .openCode: name == "opencode" || name.hasPrefix("opencode-")
        }
    }

    /// Path fragments that only appear for this agent's install.
    private var markers: [String] {
        switch self {
        case .claude: ["/.claude/", "claude-code", "@anthropic-ai/claude"]
        case .codex: ["/.codex/", "openai/codex", "@openai/codex"]
        case .openCode: ["/.opencode/", "opencode-ai", "sst/opencode"]
        }
    }

    var image: NSImage? { Self.cache[self] }

    /// Decoded once. NSImage reads SVG natively, so the markup can be kept
    /// verbatim rather than redrawn as bezier paths by hand.
    private static let cache: [AgentIcon: NSImage] = {
        var result: [AgentIcon: NSImage] = [:]
        for agent in allCases {
            guard let data = agent.svg.data(using: .utf8),
                  let image = NSImage(data: data)
            else { continue }
            image.isTemplate = false
            result[agent] = image
        }
        return result
    }()

    private var svg: String {
        switch self {
        case .claude:
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" \
            viewBox="2 5 20 15" preserveAspectRatio="xMidYMid meet">\
            <path fill="#D97757" d="M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15\
            v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949z"/>\
            <rect x="6" y="8.102" width="1.488" height="2.847" fill="black"/>\
            <rect x="16.51" y="8.102" width="1.49" height="2.847" fill="black"/></svg>
            """
        case .codex:
            // Arc flags spaced out on purpose: NSImage's SVG parser reads the
            // packed form (`a.637.637 0 000 1.272`) wrong and renders a mangled
            // blob with no cut-outs. See the note in the README.
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 24 24">\
            <path d="M19.503 0H4.496A4.496 4.496 0 0 0 0 4.496v15.007A4.496 4.496 0 0 0 4.496 24\
            h15.007A4.496 4.496 0 0 0 24 19.503V4.496A4.496 4.496 0 0 0 19.503 0z" fill="#fff"/>\
            <path fill="#4B63FF" d="M9.064 3.344 a4.578 4.578 0 0 1 2.285 -.312 c1 .115 1.891.54 2.673 \
            1.275.01.01.024.017.037.021 a.09 .09 0 0 0 .043 0 4.55 4.55 0 0 1 3.046 .275 \
            l.047.022.116.057 a4.581 4.581 0 0 1 2.188 2.399 c.209.51.313 1.041.315 1.595 a4.24 \
            4.24 0 0 1 -.134 1.223 .123 .123 0 0 0 .03 .115 c.594.607.988 1.33 1.183 2.17.289 \
            1.425-.007 2.71-.887 3.854 l-.136.166 a4.548 4.548 0 0 1 -2.201 1.388 .123 .123 0 0 \
            0 -.081 .076 c-.191.551-.383 1.023-.74 1.494-.9 1.187-2.222 1.846-3.711 \
            1.838-1.187-.006-2.239-.44-3.157-1.302 a.107 .107 0 0 0 -.105 -.024 \
            c-.388.125-.78.143-1.204.138 a4.441 4.441 0 0 1 -1.945 -.466 4.544 4.544 0 0 1 -1.61 \
            -1.335 c-.152-.202-.303-.392-.414-.617 a5.81 5.81 0 0 1 -.37 -.961 4.582 4.582 0 0 1 \
            -.014 -2.298 .124 .124 0 0 0 .006 -.056 .085 .085 0 0 0 -.027 -.048 4.467 4.467 0 0 \
            1 -1.034 -1.651 3.896 3.896 0 0 1 -.251 -1.192 5.189 5.189 0 0 1 .141 -1.6 \
            c.337-1.112.982-1.985 \
            1.933-2.618.212-.141.413-.251.601-.33.215-.089.43-.164.646-.227 a.098 .098 0 0 0 \
            .065 -.066 4.51 4.51 0 0 1 .829 -1.615 4.535 4.535 0 0 1 1.837 -1.388 z m3.482 \
            10.565 a.637 .637 0 0 0 0 1.272 h3.636 a.637 .637 0 1 0 0 -1.272 h-3.636 z M8.462 \
            9.23 a.637 .637 0 0 0 -1.106 .631 l1.272 2.224-1.266 2.136 a.636 .636 0 1 0 1.095 \
            .649 l1.454-2.455 a.636 .636 0 0 0 .005 -.64 L8.462 9.23 z"/></svg>
            """
        case .openCode:
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 240 300">\
            <path d="M180 240H60V120H180V240Z" fill="#CFCECD"/>\
            <path d="M180 60H60V240H180V60ZM240 300H0V0H240V300Z" fill="#211E1E"/></svg>
            """
        }
    }
}

/// The command line of a running process, for spotting which agent is in a
/// terminal. `KERN_PROCARGS2` is the only way to see arguments — the executable
/// path alone says "node" for half of them.
enum ProcessArguments {
    static func of(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return [] }

        // Layout: argc, the exec path, padding NULs, then argc NUL-terminated
        // arguments.
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(
                    start: source.baseAddress, count: MemoryLayout<Int32>.size))
            }
        }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        // No terminator to append or trim: the loop below only ever collects
        // non-NUL bytes, so what it hands over is already just the argument.
        func string(_ bytes: [CChar]) -> String {
            String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        var arguments: [String] = []
        var current: [CChar] = []
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                if !current.isEmpty {
                    arguments.append(string(current))
                    current = []
                }
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        if !current.isEmpty, arguments.count < Int(argc) {
            arguments.append(string(current))
        }
        return arguments
    }
}
