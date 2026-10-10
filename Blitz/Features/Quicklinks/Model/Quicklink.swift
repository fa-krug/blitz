import Foundation

/// A user-authored URL, search, file, folder or deeplink, surfaced as a launcher command.
struct Quicklink: Codable, Hashable, Identifiable, Sendable {
    static let entryIDPrefix = "quicklink:"
    /// Fallback glyph when there is no icon and the destination can't be detected.
    static let sfSymbol = "link"

    let id: UUID
    var name: String
    /// The raw destination template; may still contain `{argument}`-style placeholders.
    var link: String
    /// Bundle id of the app to open with, or nil for the system default handler.
    var openWithBundleID: String?
    /// SF Symbol override; nil takes the glyph the detected destination suggests.
    var iconSymbol: String?
    /// The site's icon as PNG, fetched on request; it wins over any symbol while set.
    var favicon: Data?
    /// Off keeps the row and everything attached to it, but nothing may offer or open it.
    var isEnabled: Bool
    var showsInRootSearch: Bool
    /// A stamp rather than a flag, so the pinned block is ordered by *when* you pinned.
    var pinnedAt: Date?
    var createdAt: Date
    /// Free-form labels Search Quicklinks matches and filters by, in `normalizedTags` form.
    var tags: [String]

    init(
        id: UUID = UUID(), name: String, link: String, openWithBundleID: String? = nil,
        iconSymbol: String? = nil, favicon: Data? = nil, isEnabled: Bool = true,
        showsInRootSearch: Bool = true, pinnedAt: Date? = nil, createdAt: Date = Date(),
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.openWithBundleID = openWithBundleID
        self.iconSymbol = iconSymbol
        self.favicon = favicon
        self.isEnabled = isEnabled
        self.showsInRootSearch = showsInRootSearch
        self.pinnedAt = pinnedAt
        self.createdAt = createdAt
        self.tags = tags
    }

    var isPinned: Bool { pinnedAt != nil }

    /// Search Quicklinks' filter: the name or any tag, so a tag finds what it labels.
    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.compare(tag, options: .caseInsensitive) == .orderedSame }
    }

    /// Trimmed, non-empty, unique ignoring case; line breaks fold, as the store keeps one per line.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }

    /// The editor's comma-separated spelling.
    static func tags(fromList list: String) -> [String] {
        normalizedTags(list.split(separator: ",").map(String.init))
    }

    /// Every tag the library uses, once each and alphabetical: the ⌘P filter's rows.
    static func allTags(in quicklinks: [Quicklink]) -> [String] {
        normalizedTags(quicklinks.flatMap { $0.tags })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The one glyph rule: the override, else what the detected destination suggests.
    var symbol: String {
        iconSymbol ?? QuicklinkDestination.detect(link)?.defaultSymbol ?? Self.sfSymbol
    }

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    /// The one display order, sorted through by both the store and the launcher slice.
    static func precedes(_ lhs: Quicklink, _ rhs: Quicklink) -> Bool {
        switch (lhs.pinnedAt, rhs.pinnedAt) {
        case (let left?, let right?):
            return left != right ? left < right : lhs.id.uuidString < rhs.id.uuidString
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none):
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order != .orderedSame
                ? order == .orderedAscending
                : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // Hand-written, so a hand-edited import needs only `name` and `link`.
    private enum CodingKeys: String, CodingKey {
        case id, name, link, openWithBundleID, iconSymbol, favicon, isEnabled, showsInRootSearch
        case pinnedAt, createdAt, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        link = try container.decode(String.self, forKey: .link)
        openWithBundleID = try container.decodeIfPresent(String.self, forKey: .openWithBundleID)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        favicon = try container.decodeIfPresent(Data.self, forKey: .favicon)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showsInRootSearch =
            try container.decodeIfPresent(Bool.self, forKey: .showsInRootSearch) ?? true
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        tags = Self.normalizedTags(
            try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }
}

/// What `{selection}` falls back to when the target app exposes no readable selection.
enum QuicklinkSelectionFallback: String, CaseIterable, Identifiable, Sendable {
    case ask
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask for it"
        case .clipboard: return "Use the clipboard"
        }
    }
}

enum QuicklinkError: LocalizedError, Equatable {
    case emptyName
    case emptyLink
    case duplicateName
    case unresolvableLink
    case invalidCharacter
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the quicklink."
        case .emptyLink: return "Enter a link to open."
        case .duplicateName: return "A quicklink with this name already exists."
        case .unresolvableLink:
            return "This doesn't look like a URL, file path, or deeplink."
        case .invalidCharacter: return "Names and links cannot contain null characters."
        case .storageUnavailable:
            return "The quicklinks database could not be opened, so changes can't be saved."
        }
    }
}
