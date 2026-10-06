import Foundation

/// The launcher's search history, kept on disk across restarts unless the user turns that off.
@MainActor
@Observable
final class LauncherQueryHistoryStore {
    private let fileURL: URL

    private(set) var history: LauncherQueryHistory
    /// Off keeps searches in memory only, and removes the file a previous session wrote.
    var persists: Bool {
        didSet {
            guard persists != oldValue else { return }
            persist()
        }
    }

    /// The in-flight persist, awaited by the next one so a burst can't land out of order.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(fileURL: URL, persists: Bool) {
        self.fileURL = fileURL
        self.persists = persists
        guard persists else {
            try? FileManager.default.removeItem(at: fileURL)
            history = LauncherQueryHistory()
            return
        }
        let stored =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        history = LauncherQueryHistory(queries: stored)
    }

    var isEmpty: Bool { history.queries.isEmpty }

    /// Awaits the pending persist. The launcher never needs it; reading the file back does.
    func flush() async {
        await writeTask?.value
    }

    func record(_ query: String, from origin: LauncherQueryHistory.Origin) {
        let previous = history
        history.record(query, from: origin)
        guard history != previous else { return }
        persist()
    }

    func clear() {
        guard !isEmpty else { return }
        history = LauncherQueryHistory()
        persist()
    }

    /// Replaces the list wholesale from a backup, dropping what a fresh search would.
    func replace(_ queries: [String]) {
        history = LauncherQueryHistory(queries: queries)
        persist()
    }

    private func persist() {
        // Off-main: this lands on ↵, in front of the launch. Chained, so writes stay ordered.
        let snapshot = persists ? history.queries : []
        let fileURL = fileURL
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
