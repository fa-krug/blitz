import Foundation

/// How a chat model lists the user's quicklinks: names and link templates, nothing opened.
enum QuicklinkToolCatalog {
    static let origin = "Quicklinks"
    static let listName = "quicklinks_list"

    static func handles(_ name: String) -> Bool { name == listName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: listName,
                description: "List the user's Blitz quicklinks: each one's name, its link "
                    + "template, in which {argument} placeholders are filled when it is opened, "
                    + "and its tags. The user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(properties: [
                    "query": AIToolJSON.string("Only quicklinks whose name or a tag contains this.")
                ]),
                origin: origin, title: "List Quicklinks")
        ]
    }

    static func query(arguments: String) throws(AIToolArguments.Invalid) -> String? {
        try AIToolArguments(arguments).string("query")
    }

    /// Only enabled quicklinks, as Search Quicklinks lists them; a disabled one is offered nowhere.
    static func listing(_ quicklinks: [Quicklink], query: String?) -> String {
        let shown = quicklinks.filter { $0.isEnabled && (query.map($0.matches) ?? true) }
        guard !shown.isEmpty else {
            return query.map { "No quicklink\u{2019}s name or tag contains \u{201C}\($0)\u{201D}." }
                ?? "The user has no quicklinks."
        }
        let count = shown.count == 1 ? "1 quicklink" : "\(shown.count) quicklinks"
        let rows = shown.map { quicklink in
            ([quicklink.name, quicklink.link] + (quicklink.tags.isEmpty
                ? [] : [quicklink.tags.joined(separator: ", ")])).joined(separator: "\t")
        }
        return ([count + ", tab-separated: name, link, tags:"] + rows).joined(separator: "\n")
    }
}
