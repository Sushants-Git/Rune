import Foundation

/// Who is actually running in a terminal, when the obvious answer is wrong.
///
/// `tcgetpgrp` gives the foreground process *group*, and Rune long treated its
/// leader as "the program". That holds when a shell can exec the thing you
/// asked for — `zsh -c "vim"` becomes vim — and fails the moment it cannot:
///
///     zsh -c "vim; true"    11468  /bin/zsh -c vim; true    ← leader, all Rune saw
///                           11469  vim                      ← the actual program
///
/// A wrapper of any kind does this: `fish -c "cd x && tmux new"`, `tmux` under
/// `tmuxp`, a launcher script. The program is right there in the same group,
/// one process along, and looking only at the leader misses it.
enum ProcessGroup {
    /// Every process in a foreground group, its leader first.
    ///
    /// One `sysctl`, no subprocess. The group is nearly always one or two
    /// processes, so the cost is the same as the single lookup it replaces.
    static func members(of pgid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }

        let found = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
            .filter { $0 > 0 }
        // The leader first, so a shell that *did* exec still answers first and
        // nothing about the common case changes.
        return found.sorted { a, _ in a == pgid }
    }

    /// Everything descended from `pid`, breadth-first, bounded.
    ///
    /// Used to look inside a tmux pane, where the agent is a grandchild of a
    /// shell Rune has no other route to. Bounded because this runs on a poll
    /// and a pane can hold an arbitrary tree.
    static func descendants(of pid: pid_t, limit: Int = 24) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }

        var children: [pid_t: [pid_t]] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let child = process.kp_proc.p_pid
            let parent = process.kp_eproc.e_ppid
            guard child > 0, parent > 0 else { continue }
            children[parent, default: []].append(child)
        }

        var found: [pid_t] = []
        var queue = children[pid] ?? []
        while !queue.isEmpty, found.count < limit {
            let next = queue.removeFirst()
            found.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return found
    }
}

/// What tmux is showing, asked of tmux.
///
/// tmux is the one wrapper scanning the process group cannot see through. Its
/// panes are children of a *server* — a daemon reparented to launchd — so from
/// the client Rune has in front of it there is no parent, child or sibling link
/// to whatever is running in the pane. Nothing in the process table connects
/// them. tmux knows, and will say, so Rune asks.
///
/// This is the only place Rune spawns a process to learn something, which is
/// worth being uncomfortable about. It is one call for every tmux terminal at
/// once rather than one per terminal, it costs about 8ms, and it is cached
/// between polls — a pane's contents do not change faster than that matters.
struct TmuxPanes {
    struct Pane {
        let pid: pid_t
        /// `vim`, `claude`, `zsh` — tmux's own name for what the pane is running.
        let command: String
        /// Where the pane actually is. OSC 7 from before tmux started goes
        /// stale the first time you `cd` inside it.
        let directory: String
    }

    private(set) var byClient: [pid_t: Pane] = [:]
    private var readAt: Date = .distantPast

    private static let interval: TimeInterval = 2

    /// Refresh if stale. Cheap and idempotent when there is no tmux around:
    /// the caller only asks once it has seen a tmux client.
    mutating func refresh(now: Date = Date()) {
        guard now.timeIntervalSince(readAt) >= Self.interval else { return }
        readAt = now
        byClient = Self.read()
    }

    private static func read() -> [pid_t: Pane] {
        // Every attached client in one call, rather than one call per terminal.
        guard let output = run([
            "list-clients", "-F",
            "#{client_pid}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}",
        ]) else { return [:] }

        var result: [pid_t: Pane] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let client = pid_t(fields[0]), let pane = pid_t(fields[1])
            else { continue }
            result[client] = Pane(
                pid: pane, command: String(fields[2]), directory: String(fields[3]))
        }
        return result
    }

    /// tmux is not on `PATH` for a GUI app, which is launched by the window
    /// server and inherits none of a login shell's environment.
    private static let executable: String? = {
        let candidates = [
            "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
            "/opt/local/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func run(_ arguments: [String]) -> String? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // No tmux server is the normal case, and it exits non-zero saying so.
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
