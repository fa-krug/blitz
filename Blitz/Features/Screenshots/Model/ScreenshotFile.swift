import Foundation

/// A capture on disk, stamped with the modification time its recognized text was read at.
struct ScreenshotFile: Equatable, Sendable {
    let path: String
    let modified: Double

    /// Newest first, as listed: a file is read again only once it changed since it was last read.
    static func needingText(
        _ files: [ScreenshotFile], indexed: [String: Double], skipping failed: Set<String>
    ) -> [ScreenshotFile] {
        files.filter { file in
            !failed.contains(file.path) && indexed[file.path] != file.modified
        }
    }
}
