import Foundation

/// The store links a README as GitHub's HTML page; what the detail page renders is the raw file.
enum ExtensionStoreReadme {
    private static let rawHost = "raw.githubusercontent.com"

    /// `github.com/o/r/{tree,blob,raw}/ref/path` → `raw.githubusercontent.com/o/r/ref/path`.
    static func rawURL(_ url: URL) -> URL? {
        if url.host == rawHost { return url }
        guard url.host == "github.com" || url.host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, ["tree", "blob", "raw"].contains(parts[2]) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = rawHost
        let path = [parts[0], parts[1]] + parts[3...]
        components.path = "/" + path.joined(separator: "/") + (url.hasDirectoryPath ? "/" : "")
        return components.url
    }

    /// The store writes the folder with a doubled trailing slash; one is what resolution expects.
    static func assetsBase(_ path: String) -> URL? {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/") else { return nil }
        return rawURL(url) ?? url
    }

    /// Relative image targets point at the extension's folder; absolute ones are left alone.
    static func resolvingRelativeImages(in markdown: String, base: URL) -> String {
        let image = #/(!\[[^\]]*\]\()([^)\s]+)/#
        let tag = #/(<img\b[^>]*?\bsrc=["'])([^"']+)(["'])/#
        let rewritten = markdown.replacing(image) { match in
            "\(match.output.1)\(resolve(String(match.output.2), base: base))"
        }
        return rewritten.replacing(tag) { match in
            "\(match.output.1)\(resolve(String(match.output.2), base: base))\(match.output.3)"
        }
    }

    private static func resolve(_ target: String, base: URL) -> String {
        guard URL(string: target)?.scheme == nil, !target.hasPrefix("#"), !target.hasPrefix("/"),
            let resolved = URL(string: target, relativeTo: base)?.absoluteURL
        else { return target }
        return resolved.absoluteString
    }
}
