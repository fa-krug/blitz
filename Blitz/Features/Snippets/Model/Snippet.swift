import Foundation

struct Snippet: Sendable, Hashable {
    var name: String
    var text: String
    var keyword: String?
    var isEnabled: Bool
    var showsConfirmation: Bool

    init(
        name: String,
        text: String,
        keyword: String? = nil,
        isEnabled: Bool = true,
        showsConfirmation: Bool = false
    ) {
        self.name = name
        self.text = text
        self.keyword = keyword
        self.isEnabled = isEnabled
        self.showsConfirmation = showsConfirmation
    }

    /// How long a name taken from a clip's first line may run.
    static let draftNameLimit = 40

    /// A clip saved as a snippet: named by its title, else by its first line, and kept verbatim.
    static func draft(text: String, title: String?) -> Snippet {
        let titled = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstLine =
            text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let name = titled.isEmpty ? String(firstLine.prefix(draftNameLimit)) : titled
        return Snippet(name: name.trimmingCharacters(in: .whitespaces), text: text)
    }

    /// "Duplicate": a free "… Copy" name, and no keyword, since two snippets can't both answer one.
    func duplicate(takenNames: [String]) -> Snippet {
        let taken = Set(takenNames.map { $0.folding(options: .caseInsensitive, locale: nil) })
        var copy = self
        copy.name = name + " Copy"
        copy.keyword = nil
        var suffix = 2
        while taken.contains(copy.name.folding(options: .caseInsensitive, locale: nil)) {
            copy.name = "\(name) Copy \(suffix)"
            suffix += 1
        }
        return copy
    }
}

/// Fingerprint of a snippet file's bytes, detecting an external edit before a save or delete.
struct SnippetSourceRevision: Sendable, Hashable {
    private let value: String

    init(content: String) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var byteCount = 0
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            byteCount += 1
        }
        value = "\(byteCount):\(String(hash, radix: 16))"
    }
}

struct StoredSnippet: Identifiable, Sendable, Hashable {
    static let entryIDPrefix = "snippet:"

    let fileURL: URL
    var snippet: Snippet
    let sourceRevision: SnippetSourceRevision

    var id: String { fileURL.standardizedFileURL.path }

    var entryID: String { Self.entryIDPrefix + id }

    static func id(fromEntryID entryID: String) -> ID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return String(entryID.dropFirst(entryIDPrefix.count))
    }
}
