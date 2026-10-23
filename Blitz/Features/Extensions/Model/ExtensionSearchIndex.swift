import Foundation

/// Every row's title, subtitle and keywords folded once per tree, so a keystroke only matches.
struct ExtensionSearchIndex: Sendable {
    private let fields: [RenderNode.ID: [FuzzyMatch.Candidate]]

    /// The active root's rows and its sections' rows: the only nodes local filtering reads.
    init(_ tree: RenderTree) {
        var fields: [RenderNode.ID: [FuzzyMatch.Candidate]] = [:]
        for child in tree.activeRoot?.children ?? [] {
            fields[child.id] = Self.candidates(child)
            for grandchild in child.children { fields[grandchild.id] = Self.candidates(grandchild) }
        }
        self.fields = fields
    }

    func matches(_ item: RenderNode, _ needle: FuzzyMatch.Query) -> Bool {
        guard !needle.isEmpty else { return true }
        let candidates = fields[item.id] ?? Self.candidates(item)
        return candidates.contains { FuzzyMatch.score(needle, candidate: $0) != nil }
    }

    private static func candidates(_ item: RenderNode) -> [FuzzyMatch.Candidate] {
        var haystack = [FuzzyMatch.Candidate(item.string("title") ?? "")]
        if let subtitle = item.string("subtitle") { haystack.append(FuzzyMatch.Candidate(subtitle)) }
        for keyword in item.array("keywords").compactMap(\.stringValue) {
            haystack.append(FuzzyMatch.Candidate(keyword))
        }
        return haystack
    }
}
