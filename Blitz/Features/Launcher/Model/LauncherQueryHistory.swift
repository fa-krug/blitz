import Foundation

/// The searches the launcher acted on, newest first, which ↑ walks back through as Raycast's does.
struct LauncherQueryHistory: Sendable, Equatable {
    static let limit = 20
    /// Caps pasted input, so one search cannot keep a paragraph.
    static let queryLimit = 256

    /// What ran a search: a shell line can carry a secret, so it is never kept.
    enum Origin: Sendable {
        case result
        case shellCommand
    }

    /// Where ↓ takes a walk: a newer search, or back to the empty field it started from.
    enum Forward: Equatable, Sendable {
        case recall(Int)
        case clear
    }

    private(set) var queries: [String] = []

    /// Oldest last, as stored; each passes the same rules a fresh search does.
    init(queries: [String] = []) {
        for query in queries.reversed() { record(query) }
    }

    subscript(index: Int) -> String { queries[index] }

    /// A repeated search moves to the front rather than appearing twice.
    mutating func record(_ query: String, from origin: Origin = .result) {
        guard origin != .shellCommand else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= Self.queryLimit else { return }
        queries.removeAll { $0 == term }
        queries.insert(term, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }

    /// Nil leaves ↑ to the list; `recalled` counts only while the field still shows it unedited.
    func older(than query: String, recalled: Int?) -> Int? {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return queries.isEmpty ? nil : 0
        }
        guard let recalled = unedited(recalled, showing: query) else { return nil }
        return queries.indices.contains(recalled + 1) ? recalled + 1 : nil
    }

    /// Nil leaves ↓ to the list, which is every case but an unedited recall.
    func newer(than query: String, recalled: Int?) -> Forward? {
        guard let recalled = unedited(recalled, showing: query) else { return nil }
        return recalled == 0 ? .clear : .recall(recalled - 1)
    }

    private func unedited(_ recalled: Int?, showing query: String) -> Int? {
        guard let recalled, queries.indices.contains(recalled), queries[recalled] == query else {
            return nil
        }
        return recalled
    }
}
