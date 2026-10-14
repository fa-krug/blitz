import Foundation

/// What a Mac tool found for a name the model gave: one item, several, or only near names.
enum AgentNameMatch<Item: Sendable>: Sendable {
    case found(Item)
    case ambiguous([Item])
    case missing(near: [Item])

    /// At most this many near names come back with a refusal, so it stays one short answer.
    static var nearLimit: Int { 5 }

    /// Exact once case, accents and width are folded; else the names that start with or hold it.
    static func match(
        _ query: String, among items: [Item], names: (Item) -> [String]
    ) -> AgentNameMatch<Item> {
        let wanted = folded(query)
        let exact = items.filter { names($0).contains { folded($0) == wanted } }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        guard !wanted.isEmpty else { return .missing(near: []) }
        func rank(_ item: Item) -> Int? {
            let spelled = names(item).map(folded)
            if spelled.contains(where: { $0.hasPrefix(wanted) }) { return 0 }
            if spelled.contains(where: { $0.contains(wanted) }) { return 1 }
            if spelled.contains(where: { $0.count >= 3 && wanted.contains($0) }) { return 2 }
            return nil
        }
        let near = items.enumerated()
            .compactMap { offset, item in rank(item).map { (rank: $0, offset: offset, item: item) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .prefix(nearLimit)
            .map(\.item)
        return .missing(near: Array(near))
    }

    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

extension AgentNameMatch: Equatable where Item: Equatable {}
