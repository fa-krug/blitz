import CoreServices
import Foundation

/// The Spotlight half of Search Screenshots; recognition stays in the bundled helper.
enum ScreenshotService {
    /// Where `screencapture` saves, when the user moved it; unset means the Desktop, inside home.
    nonisolated static func captureLocation() -> String? {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    }

    nonisolated static func search(
        query rawQuery: String, homeDirectory: URL, text: ScreenshotTextStore?
    ) throws -> [FileSearchResult] {
        try Signposts.interval("ScreenshotService.search") {
            let query = ScreenshotQuery(parsing: rawQuery)
            let paths = try paths(for: query, homeDirectory: homeDirectory)
            let textMatches = text?.paths(matching: query.terms) ?? []
            // Spotlight lags a delete, so a row is stat'd before it can be offered.
            return query.select(from: paths, textMatches: textMatches)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map {
                    FileSearchResult(
                        url: URL(fileURLWithPath: $0), isDirectory: false,
                        homeDirectory: homeDirectory)
                }
        }
    }

    /// Every listed capture with the modification time its text would be read at.
    nonisolated static func listing(homeDirectory: URL) throws -> [ScreenshotFile] {
        let paths = try paths(for: ScreenshotQuery(parsing: ""), homeDirectory: homeDirectory)
        return paths.compactMap { path in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .contentModificationDateKey
            ])
            guard let modified = values?.contentModificationDate else { return nil }
            return ScreenshotFile(path: path, modified: modified.timeIntervalSinceReferenceDate)
        }
    }

    nonisolated static func recognize(_ path: String) async throws -> String {
        try await ClipboardTextWorker.extract(
            at: URL(fileURLWithPath: path), isPDF: false,
            executable: ClipboardTextWorker.bundledHelper)
    }

    /// Newest first, and only the path is read: every other attribute costs a metadata fetch.
    private nonisolated static func paths(
        for query: ScreenshotQuery, homeDirectory: URL
    ) throws -> [String] {
        let scopes = ScreenshotQuery.scopes(
            homeDirectory: homeDirectory, captureLocation: captureLocation())
        let paths = try FileSearchService.execute(
            expression: query.expression, scopes: scopes,
            sortedBy: ScreenshotQuery.dateAttribute as CFString
        ) { spotlight, count in
            (0..<count).compactMap { FileSearchService.path(in: spotlight, at: $0) }
        }
        var seen = Set<String>()
        return paths.filter {
            ScreenshotQuery.isEligible($0, homeDirectory: homeDirectory) && seen.insert($0).inserted
        }
    }
}
