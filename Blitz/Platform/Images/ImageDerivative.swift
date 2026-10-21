import Foundation

/// A smaller copy of an immutable image blob, kept beside it so a tile never decodes the original.
struct ImageDerivative: Sendable {
    static let edges = [256, 1080]

    /// A GCD queue because a copy blocks on its helper; serial so a delete waits out that copy.
    static let queue = DispatchQueue(label: "de.fa-krug.blitz.image-derivative", qos: .userInitiated)

    let url: URL
    let edge: Int

    /// Nil past the largest edge, where only the original is sharp enough.
    static func covering(_ original: URL, maxPixel: Int) -> ImageDerivative? {
        edges.first { $0 >= maxPixel }.map { ImageDerivative(original, edge: $0) }
    }

    static func all(of original: URL) -> [ImageDerivative] {
        edges.map { ImageDerivative(original, edge: $0) }
    }

    static func removeCopies(of original: URL) {
        queue.async {
            for copy in all(of: original) { try? FileManager.default.removeItem(at: copy.url) }
        }
    }

    /// Copies whose blob is gone, which a quit before `removeCopies` ran leaves behind.
    static func removeOrphans(in directory: URL) {
        queue.async {
            let folder = directory.appending(path: ".thumbnails", directoryHint: .isDirectory)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let edge = name.lastIndex(of: "-") else { continue }
                let blob = directory.appending(path: String(name[..<edge]))
                guard !FileManager.default.fileExists(atPath: blob.path) else { continue }
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
    }

    static func folder(beside original: URL) -> URL {
        original.deletingLastPathComponent()
            .appending(path: ".thumbnails", directoryHint: .isDirectory)
    }

    /// Keyed by the whole file name, so `a.jpg` and `a.png` never share a copy.
    private init(_ original: URL, edge: Int) {
        url = Self.folder(beside: original)
            .appending(path: "\(original.lastPathComponent)-\(edge).png", directoryHint: .notDirectory)
        self.edge = edge
    }
}
