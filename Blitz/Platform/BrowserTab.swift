import Foundation

/// A browser tab as AppleScript reports it; pure, so the snippet and quicklink harnesses share it.
struct BrowserTab: Equatable, Sendable {
    let url: String
    let title: String

    /// `[title](url)`, falling back to the URL when the page has no title.
    var markdownLink: String {
        let label = title.isEmpty ? url : title
        let escaped = label.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url))"
    }

    /// Scheme and host fold, the fragment and a trailing slash drop; the query must match exactly.
    static func matchKey(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            return String(trimmed.prefix { $0 != "#" })
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if let host = components.percentEncodedHost {
            components.percentEncodedHost = host.lowercased()
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.string ?? trimmed
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        matchKey(for: lhs) == matchKey(for: rhs)
    }
}
