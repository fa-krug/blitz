import Foundation

/// What the Search Screenshots field means: an optional `date:` prefix, then filename or text terms.
struct ScreenshotQuery: Equatable, Sendable {
    enum DateRange: String, CaseIterable, Sendable {
        case today
        case yesterday
        case week

        /// Spotlight's own day literals, so no clock is injected; `week` is today and the six before.
        var spotlightClause: String {
            let stamp = ScreenshotQuery.dateAttribute
            switch self {
            case .today: return "\(stamp) >= $time.today"
            case .yesterday: return "\(stamp) >= $time.yesterday && \(stamp) < $time.today"
            case .week: return "\(stamp) >= $time.today(-6)"
            }
        }
    }

    static let dateAttribute = "kMDItemContentCreationDate"
    static let datePrefix = "date:"
    /// A blank screen is a shortlist of the newest captures, not a browser.
    static let recentLimit = 30

    let terms: [String]
    let date: DateRange?

    init(parsing raw: String) {
        var terms = FileSearchQuery.terms(in: raw)
        var date: DateRange?
        if let first = terms.first, first.lowercased().hasPrefix(Self.datePrefix),
            let range = DateRange(rawValue: String(first.lowercased().dropFirst(Self.datePrefix.count)))
        {
            date = range
            terms.removeFirst()
        }
        self.terms = terms
        self.date = date
    }

    var expression: String {
        (["kMDItemIsScreenCapture == 1"] + (date.map { [$0.spotlightClause] } ?? []))
            .joined(separator: " && ")
    }

    /// Hidden folders and `~/Library` hold app caches and containers, never a capture worth finding.
    static func isEligible(_ path: String, homeDirectory: URL) -> Bool {
        let library = homeDirectory.standardizedFileURL.path + "/Library/"
        guard !path.hasPrefix(library) else { return false }
        return !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Home, plus wherever `screencapture` saves when the user moved it outside home.
    static func scopes(homeDirectory: URL, captureLocation: String?) -> [URL] {
        let home = homeDirectory.standardizedFileURL
        guard let captureLocation, !captureLocation.isEmpty else { return [home] }
        let expanded =
            captureLocation.hasPrefix("~")
            ? home.path + captureLocation.dropFirst() : captureLocation
        let location = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        guard location.path != home.path, !location.path.hasPrefix(home.path + "/") else {
            return [home]
        }
        return [home, location]
    }

    /// `paths` arrive newest first; a match keeps that order rather than a relevance one.
    func select(from paths: [String], textMatches: Set<String>) -> [String] {
        guard !terms.isEmpty else { return Array(paths.prefix(Self.recentLimit)) }
        let query = terms.joined(separator: " ")
        let matches = paths.filter { path in
            textMatches.contains(path)
                || FileSearchQuery.matches(
                    filename: (path as NSString).lastPathComponent, query: query)
        }
        return Array(matches.prefix(FileSearchQuery.resultLimit))
    }
}
