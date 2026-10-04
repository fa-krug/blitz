import Foundation

/// The searches the launcher acted on, newest first, which ↑ walks back through as Raycast's does.
struct LauncherQueryHistory: Sendable, Equatable {
    static let limit = 20
    /// Caps pasted input, so one search cannot keep a paragraph.
    static let queryLimit = 256

    private(set) var queries: [String] = []

    subscript(index: Int) -> String { queries[index] }

    /// A repeated search moves to the front rather than appearing twice.
    mutating func record(_ query: String) {
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
        guard let recalled, queries.indices.contains(recalled), queries[recalled] == query else {
            return nil
        }
        return queries.indices.contains(recalled + 1) ? recalled + 1 : nil
    }
}
