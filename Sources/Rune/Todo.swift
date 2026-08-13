import Foundation

/// One thing to do.
///
/// `id` rather than position: rows are toggled and deleted while a list is on
/// screen, and an index that means one thing when a keystroke is dispatched and
/// another when it lands is how you delete the wrong row.
struct TodoItem: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var done: Bool
    let created: Date
    /// The task this one sits under, or nil for a task in its own right.
    ///
    /// Optional on purpose rather than a level number: a missing key decodes
    /// to nil, so a list written before there were sub-tasks loads as a list of
    /// roots instead of failing.
    var parent: UUID?

    init(text: String, parent: UUID? = nil) {
        self.id = UUID()
        self.text = text
        self.done = false
        self.created = Date()
        self.parent = parent
    }
}

/// The todo list, persisted.
///
/// Off unless you turn it on in Settings, and stored in `UserDefaults` beside
/// everything else Rune remembers rather than in a file of its own: it is a
/// short list of short strings, and a file would be a thing to find, migrate
/// and lose.
///
/// One list for the whole app, not one per workspace. A workspace is where you
/// are working; this is what you have to do, which is the question you ask
/// precisely when you are not sure which workspace to be in.
@MainActor
final class TodoStore {
    static let shared = TodoStore()

    static let changed = Notification.Name("RuneTodosChanged")

    private static let key = "RuneTodos"
    private let defaults = UserDefaults.standard

    private(set) var items: [TodoItem] = []

    private init() {
        load()
    }

    // MARK: - Reading

    /// A row as the list draws it: the task, how deep it sits, and whether it
    /// is the last of its parent's children — which is the only thing the
    /// branch glyph needs to know to come out as a tree.
    struct Row {
        let item: TodoItem
        let depth: Int
        let isLast: Bool
    }

    /// Roots in the order they were added, each followed by its children.
    ///
    /// Creation order, and no sorting of done to the bottom. A flat list can
    /// be re-sorted freely; a tree cannot, because moving a parent moves its
    /// children with it and the shape you are reading changes under you. Done
    /// tasks stay where they are and go quiet instead.
    var rows: [Row] {
        items.filter { $0.parent == nil }.flatMap { root -> [Row] in
            let children = self.children(of: root.id)
            return [Row(item: root, depth: 0, isLast: children.isEmpty)]
                + children.enumerated().map { index, child in
                    Row(item: child, depth: 1, isLast: index == children.count - 1)
                }
        }
    }

    func children(of parent: UUID) -> [TodoItem] {
        items.filter { $0.parent == parent }
    }

    var remaining: Int { items.filter { !$0.done }.count }

    // MARK: - Writing

    /// Only two levels. A sub-task handed another sub-task's id is attached to
    /// that one's parent instead, so pressing "add under this" on a child does
    /// the obvious thing rather than growing a third level nobody asked for.
    func add(_ text: String, parent: UUID? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var under = parent
        if let parent, let existing = items.first(where: { $0.id == parent }) {
            under = existing.parent ?? parent
        }
        items.append(TodoItem(text: trimmed, parent: under))
        save()
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done.toggle()
        save()
    }

    /// Takes the task's children with it. Leaving them behind would orphan
    /// them at a parent that no longer exists, which is a row the tree cannot
    /// draw and you cannot reach.
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id || $0.parent == id }
        save()
    }

    /// The task and everything under it, as text, ready for the clipboard.
    func copyText(for id: UUID) -> String? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        // A child copies as itself. Only a parent brings its list along, since
        // that is the thing you are pointing at when you ask for it.
        guard item.parent == nil else { return item.text }
        let children = self.children(of: id)
        guard !children.isEmpty else { return item.text }
        return ([item.text] + children.map { "  - \($0.text)" }).joined(separator: "\n")
    }

    func rename(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id })
        else { return }
        items[index].text = trimmed
        save()
    }

    func clearDone() {
        items.removeAll { $0.done }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([TodoItem].self, from: data)
        else { return }
        items = stored
    }

    private func save() {
        // A write failure here is not worth an alert: the list is still correct
        // in memory for this run, and the next change tries again.
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
