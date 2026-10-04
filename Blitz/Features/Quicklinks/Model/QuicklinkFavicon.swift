import Foundation

/// Where a website quicklink's favicon is looked for. docs/features/quicklinks.md#favicons
enum QuicklinkFavicon {
    /// Pixels a side once stored: sharp at the 64pt Search Quicklinks preview on a 2× display.
    static let pixelSide = 128
    /// Drawn below an app icon's extent, as extension artwork is; docs/features/extensions.md
    static let extent: CGFloat = 0.76
    /// Anything larger is not an icon, and the cap keeps a misbehaving server out of memory.
    static let maxImageBytes = 2 * 1024 * 1024
    /// Icons are declared in `<head>`, so only a page's opening bytes are searched.
    static let maxPageBytes = 512 * 1024

    private static let iconRels: Set<Substring> = [
        "icon", "apple-touch-icon", "apple-touch-icon-precomposed"
    ]

    /// The site's root; a placeholder is blanked first, since a link's host is rarely templated.
    static func siteURL(for link: String) -> URL? {
        let blanked = link.replacing(#/\{[^{}]*\}/#, with: "")
        guard case .web(let url) = QuicklinkDestination.detect(blanked),
            let host = url.host(), !host.isEmpty, !host.hasPrefix(".")
        else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    /// The conventional location, tried after every icon the page declares.
    static func conventionalURL(for site: URL) -> URL {
        site.appending(path: "favicon.ico")
    }

    /// The `<link>` icons a page declares, best first, resolved against the page's final URL.
    static func candidates(inHTML html: String, baseURL: URL) -> [URL] {
        var ranked: [(url: URL, score: Int)] = []
        for tag in html.matches(of: #/<[lL][iI][nN][kK]\b[^>]*>/#) {
            let attributes = Self.attributes(in: tag.output)
            let rel = Set(
                (attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace))
            guard !rel.isDisjoint(with: iconRels),
                let href = attributes["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                url.scheme == "https" || url.scheme == "http"
            else { continue }
            let rank = score(isIcon: rel.contains("icon"), attributes: attributes, url: url)
            ranked.append((url: url, score: rank))
        }
        var seen = Set<URL>()
        return ranked.enumerated()
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
            }
            .map(\.element.url)
            .filter { seen.insert($0).inserted }
    }

    /// Named by content, so a refetch moves the path and no icon cache can serve the old image.
    static func fileName(for png: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in png {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".png"
    }

    /// A vector scales to any size; a touch icon's padded tile ranks below a site's own large icon.
    private static func score(isIcon: Bool, attributes: [String: String], url: URL) -> Int {
        let sizes = (attributes["sizes"] ?? "").lowercased()
        if sizes.contains("any") || attributes["type"]?.lowercased() == "image/svg+xml"
            || url.pathExtension.lowercased() == "svg"
        {
            return 1024
        }
        guard isIcon else { return 96 }
        let declared = sizes.split(whereSeparator: \.isWhitespace).compactMap { size in
            size.split(separator: "x").first.flatMap { Int($0) }
        }
        return declared.max() ?? 32
    }

    private static func attributes(in tag: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in tag.matches(of: #/([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            attributes[match.output.1.lowercased()] = String(value)
        }
        return attributes
    }
}
