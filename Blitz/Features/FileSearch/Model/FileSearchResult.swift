import Foundation

struct FileSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let parentPath: String
    /// The enclosing folder's own name, which is what tells two same-named folders apart.
    let parentName: String
    let isDirectory: Bool

    /// A favorite's stored key: a `file:///` URL, which no bundle ID or entry ID can spell.
    var favoriteKey: String {
        URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory).absoluteString
    }

    /// Nil for any other favorite key; the trailing slash carries the folder bit without a stat.
    init?(favoriteKey: String, homeDirectory: URL) {
        guard favoriteKey.hasPrefix("file:///"), let url = URL(string: favoriteKey),
            url.query == nil, url.fragment == nil
        else { return nil }
        self.init(url: url, isDirectory: url.hasDirectoryPath, homeDirectory: homeDirectory)
    }

    init(url: URL, isDirectory: Bool, homeDirectory: URL) {
        let url = url.standardizedFileURL
        let parent = url.deletingLastPathComponent()
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.parentPath = Self.abbreviate(
            parent.path, homePath: homeDirectory.standardizedFileURL.path)
        self.parentName = parent.lastPathComponent
        self.isDirectory = isDirectory
    }

    private static func abbreviate(_ path: String, homePath: String) -> String {
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
