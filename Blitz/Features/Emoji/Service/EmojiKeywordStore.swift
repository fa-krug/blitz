import Foundation

/// The user's own search terms, kept out of the generated catalog so regenerating it keeps them.
@MainActor
@Observable
final class EmojiKeywordStore {
    private let fileURL: URL
    private(set) var keywords: [String: [String]]
    private(set) var revision = 0
    @ObservationIgnored var onChange: (([String: [String]]) -> Void)?
    @ObservationIgnored var onPersistenceFailure: (() -> Void)?

    init(fileURL: URL = AppPaths.applicationSupport().appendingPathComponent("emoji-keywords.json")) {
        self.fileURL = fileURL
        let decoded =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        keywords = EmojiKeywords.normalized(decoded)
    }

    func terms(for glyph: String) -> [String] {
        keywords[glyph] ?? []
    }

    /// No terms removes the glyph's entry, so emptying the field is how the user clears them.
    func setTerms(_ terms: [String], for glyph: String) {
        guard !glyph.isEmpty else { return }
        let normalized = EmojiKeywords.normalized(terms)
        guard normalized != self.terms(for: glyph) else { return }
        keywords[glyph] = normalized.isEmpty ? nil : normalized
        didChange()
    }

    /// Restores a backup's terms wholesale, under the same bounds a load applies.
    func replace(_ imported: [String: [String]]) {
        keywords = EmojiKeywords.normalized(imported)
        didChange()
    }

    func removeAll() {
        guard !keywords.isEmpty else { return }
        keywords = [:]
        didChange()
    }

    private func didChange() {
        revision &+= 1
        onChange?(keywords)
        do {
            let data = try JSONEncoder().encode(keywords)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            onPersistenceFailure?()
        }
    }
}
