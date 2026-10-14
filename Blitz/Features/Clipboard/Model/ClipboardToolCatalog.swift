import Foundation

/// How a chat model reads the clipboard history, and what it is told of each entry.
enum ClipboardToolCatalog {
    static let origin = "Clipboard"
    static let historyName = "clipboard_history"
    static let defaultLimit = 10
    static let limitCap = 50
    /// Characters of one entry's text that come back.
    static let entryLimit = 2_000

    private typealias Invalid = AIToolArguments.Invalid

    struct Request: Equatable, Sendable {
        let query: String?
        let limit: Int
    }

    struct ImageSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    static func handles(_ name: String) -> Bool { name == historyName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: historyName,
                description: "Read what the user copied recently, newest first: each entry's "
                    + "text, when it was copied and the app it came from. Images and files are "
                    + "named, never shown. Searches the latest 1000 entries and the pinned ones. "
                    + "The user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(properties: [
                    "query": AIToolJSON.string("Only entries whose text or title contains this."),
                    "limit": AIToolJSON.integer(
                        "Most entries to return: \(defaultLimit) unless given, at most "
                            + "\(limitCap).")
                ]),
                origin: origin, title: "Read Clipboard History")
        ]
    }

    static func request(arguments: String) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        let query = arguments.string("query")
        guard arguments.contains("limit") else { return Request(query: query, limit: defaultLimit) }
        guard let limit = arguments.int("limit"), limit >= 1 else {
            throw Invalid("\u{201C}limit\u{201D} must be a whole number from 1.")
        }
        return Request(query: query, limit: min(limit, limitCap))
    }

    /// Newest first, leaving out anything copied in an app the history now ignores.
    static func entries(
        _ items: [ClipboardItem], query: String?, ignoredApps: Set<String>
    ) -> [ClipboardItem] {
        items
            .filter { item in
                !(item.sourceBundleID.map(ignoredApps.contains) ?? false)
                    && (query.map(item.matches) ?? true)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// `total` counts every entry that matched; `appNames` spells a source bundle ID.
    static func listing(
        _ shown: [ClipboardItem], request: Request, total: Int, imageSizes: [UUID: ImageSize],
        appNames: [String: String], calendar: Calendar
    ) -> String {
        guard !shown.isEmpty else {
            return request.query.map { "No clipboard entry contains \u{201C}\($0)\u{201D}." }
                ?? "The clipboard history is empty."
        }
        let matching = request.query.map { " containing \u{201C}\($0)\u{201D}" } ?? ""
        let entries = total == 1 ? "1 clipboard entry" : "\(total) clipboard entries"
        let header = "\(shown.count) of \(entries)\(matching), newest first:"
        let blocks = shown.enumerated().map { index, item in
            let copied = AIToolDate(date: item.createdAt, includesTime: true, calendar: calendar)
            var facts = [copied.text]
            if let source = item.sourceBundleID {
                facts.append("from \(appNames[source] ?? source)")
            }
            if item.isPinned { facts.append("pinned") }
            if let title = item.title { facts.append("titled \u{201C}\(title)\u{201D}") }
            let line = "\(index + 1). " + facts.joined(separator: " \u{00B7} ")
            return line + "\n" + content(of: item, size: imageSizes[item.id])
        }
        return ([header] + blocks).joined(separator: "\n\n")
    }

    private static func content(of item: ClipboardItem, size: ImageSize?) -> String {
        switch item.kind {
        case .image:
            return size.map { "[image] \($0.width) \u{00D7} \($0.height) pixels" } ?? "[image]"
        case .file: return "[file] " + (item.text ?? "")
        case .text:
            let text = item.text ?? ""
            guard text.count > entryLimit else { return text }
            return String(text.prefix(entryLimit))
                + "\u{2026} [\(text.count - entryLimit) more characters]"
        }
    }
}
