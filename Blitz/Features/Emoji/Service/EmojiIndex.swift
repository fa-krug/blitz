import Foundation

/// The parsed catalog: sections precomputed at load, search memoized one query deep.
@MainActor
@Observable
final class EmojiIndex {
    private(set) var entries: [EmojiEntry] = []
    private(set) var categorySections: [(category: EmojiCategory, entries: [EmojiEntry])] = []

    /// `order` is the catalog index, the tie-break that keeps equal scores in catalog order.
    private struct ScoredEntry {
        let entry: EmojiEntry
        let score: Int
        let order: Int
    }

    /// `joined` gates the per-keyword walk and answers multiword terms; `list` keeps each phrase.
    private struct FoldedKeywords: Sendable {
        let joined: FuzzyMatch.Candidate
        let list: [FuzzyMatch.Candidate]

        init(_ terms: [String]) {
            joined = FuzzyMatch.Candidate(terms.joined(separator: ","))
            list = terms.map(FuzzyMatch.Candidate.init)
        }
    }

    /// An entry's text folded once at load, so a keystroke folds only the query.
    private struct FoldedEntry: Sendable {
        let name: FuzzyMatch.Candidate
        let keywords: FoldedKeywords

        init(_ entry: EmojiEntry) {
            name = FuzzyMatch.Candidate(entry.name)
            keywords = FoldedKeywords(entry.keywords.split(separator: ",").map(String.init))
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let revision: Int
        let frequentID: ObjectIdentifier
        let frequentRevision: Int
        let limit: Int
    }

    private var byGlyph: [String: EmojiEntry] = [:]
    /// Parallel to `entries`.
    private var foldedEntries: [FoldedEntry] = []
    /// Keyed by glyph rather than parallel, so an edit never waits on or reparses the catalog.
    private var customKeywords: [String: FoldedKeywords] = [:]
    @ObservationIgnored private var searchMemo = Memo<SearchKey, [EmojiEntry]>()
    /// Bumped on each load and keyword edit, so the key above names the text it scored.
    private var revision = 0

    var isLoaded: Bool { !entries.isEmpty }

    /// `languages` pick which of the bundle's keyword packs join the catalog's English keywords.
    func load(_ raw: String = EmojiData.raw, languages: [String] = [], bundle: Bundle = .main) async {
        let (parsed, folded) = await Task.detached(priority: .utility) {
            let parsed = EmojiCatalog.parse(raw, localized: Self.keywordPacks(for: languages, in: bundle))
            return (parsed, parsed.map(FoldedEntry.init))
        }.value
        entries = parsed
        foldedEntries = folded
        var grouped: [EmojiCategory: [EmojiEntry]] = [:]
        for entry in parsed { grouped[entry.category, default: []].append(entry) }
        categorySections = EmojiCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
        byGlyph = Dictionary(parsed.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        revision &+= 1
    }

    /// Plain files, never `.lproj`: one would switch AppKit's own text out of English.
    private nonisolated static func keywordPacks(for languages: [String], in bundle: Bundle) -> [String] {
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: "EmojiKeywords") ?? []
        let byLanguage = Dictionary(
            urls.map { ($0.deletingPathExtension().lastPathComponent, $0) },
            uniquingKeysWith: { first, _ in first })
        return EmojiCatalog.keywordLanguages(available: byLanguage.keys.sorted(), preferred: languages)
            .compactMap { byLanguage[$0].flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
    }

    func entry(for glyph: String) -> EmojiEntry? { byGlyph[glyph] }

    /// The user's own terms, which outrank the catalog's keywords.
    func setCustomKeywords(_ keywords: [String: [String]]) {
        customKeywords = keywords.mapValues(FoldedKeywords.init)
        revision &+= 1
    }

    /// Ranked fuzzy matches over names and keywords; an empty query returns nothing.
    func search(_ query: String, frequent: FrequentEmojiStore, limit: Int = 320) -> [EmojiEntry] {
        let trimmed = FuzzyMatch.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped =
            trimmed.count > 2 && trimmed.first == ":" && trimmed.last == ":"
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        let words = unwrapped.split(whereSeparator: \.isWhitespace).map(String.init)
        let q = words.joined(separator: " ")
        guard !q.isEmpty, limit > 0 else { return [] }
        let key = SearchKey(
            query: q, revision: revision, frequentID: ObjectIdentifier(frequent),
            frequentRevision: frequent.revision, limit: limit)
        return searchMemo.value(for: key) {
            let query = FuzzyMatch.Query(q)
            let terms = words.count > 1 ? words : []
            let frequentGlyphs = frequent.top(Self.frecencyLimit)
            let frecency = Dictionary(
                frequentGlyphs.enumerated().map {
                    ($0.element, Self.frecencyLimit - $0.offset)
                }, uniquingKeysWith: max)
            var scored: [ScoredEntry] = []
            for (order, entry) in entries.enumerated() {
                let custom = customKeywords.isEmpty ? nil : customKeywords[entry.glyph]
                guard
                    let textScore = Self.textScore(
                        query, terms: terms, folded: foldedEntries[order], custom: custom)
                else { continue }
                let score = textScore + (frecency[entry.glyph] ?? 0)
                scored.append(ScoredEntry(entry: entry, score: score, order: order))
            }
            return
                scored
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
                .prefix(limit)
                .map(\.entry)
        }
    }

    /// Just under half a tier, so an equal-quality name match always wins.
    private static let keywordPenalty = 500
    private static let frecencyLimit = 100
    /// A complete leading name word scores just under this, which also caps any keyword.
    private static let leadingWordScore = 95_000
    /// Scattered query words rank below every literal phrase, name-only words first.
    private static let nameWordsScore = 60_000
    private static let mixedWordsScore = 50_000

    private static func textScore(
        _ query: FuzzyMatch.Query, terms: [String], folded: FoldedEntry, custom: FoldedKeywords?
    ) -> Int? {
        var nameOnly = true
        for term in terms where !containsWordStart(term, in: folded.name.text) {
            guard !term.contains(","),
                containsWordStart(term, in: folded.keywords.joined.text)
                    || custom.map({ containsWordStart(term, in: $0.joined.text) }) == true
            else { return nil }
            nameOnly = false
        }

        let nameMatch = FuzzyMatch.match(query, candidate: folded.name)
        if nameMatch?.tier == .exact { return nameMatch?.score }
        var best = nameMatch?.score
        if let nameMatch, nameMatch.tier == .prefix,
            let next = folded.name.text.dropFirst(nameMatch.queryLength).first,
            !next.isLetter && !next.isNumber
        {
            best = leadingWordScore - nameMatch.candidateLength
        }
        if !terms.isEmpty {
            let ordered = nameMatch?.tier == .subsequence ? nameMatch?.score ?? 0 : 0
            best = max(best ?? Int.min, (nameOnly ? nameWordsScore : mixedWordsScore) + ordered)
        }
        // Unpenalised, so the user's own term outranks a catalog keyword of the same quality.
        if let custom, let score = keywordScore(query, in: custom) {
            best = max(best ?? Int.min, score)
        }
        if let score = keywordScore(query, in: folded.keywords) {
            best = max(best ?? Int.min, score - keywordPenalty)
        }
        return best
    }

    /// Capped at a leading name word, so only the exact name outranks an exact keyword.
    private static func keywordScore(_ query: FuzzyMatch.Query, in keywords: FoldedKeywords) -> Int? {
        guard !keywords.list.isEmpty, FuzzyMatch.score(query, candidate: keywords.joined) != nil
        else { return nil }
        var best: Int?
        for keyword in keywords.list {
            guard let match = FuzzyMatch.match(query, candidate: keyword) else { continue }
            best = max(best ?? Int.min, min(match.score, leadingWordScore))
            if match.tier == .exact { break }
        }
        return best
    }

    private static func containsWordStart(_ term: String, in candidate: String) -> Bool {
        var start = candidate.startIndex
        while let range = candidate.range(of: term, range: start..<candidate.endIndex) {
            if range.lowerBound == candidate.startIndex { return true }
            let previous = candidate[candidate.index(before: range.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            start = candidate.index(after: range.lowerBound)
        }
        return false
    }
}
