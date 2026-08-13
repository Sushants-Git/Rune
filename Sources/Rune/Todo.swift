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

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.done = false
        self.created = Date()
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

    /// Undone first, each half in the order it was added.
    ///
    /// Sorted on read rather than on write so that ticking something off does
    /// not make it jump out from under the pointer: the list settles the next
    /// time the panel opens, which is when you are looking for what is left
    /// rather than at what you just finished.
    var ordered: [TodoItem] {
        items.filter { !$0.done } + items.filter(\.done)
    }

    var remaining: Int { items.filter { !$0.done }.count }

    // MARK: - Writing

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(text: trimmed))
        save()
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done.toggle()
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
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
