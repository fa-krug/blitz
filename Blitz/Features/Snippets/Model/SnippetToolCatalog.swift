import Foundation

/// How a chat model lists the user's snippets and reads one, unexpanded.
enum SnippetToolCatalog {
    static let origin = "Snippets"
    static let listName = "snippets_list"
    static let readName = "snippets_read"
    /// Characters of a snippet's text a listing previews.
    static let previewLength = 80
    /// Bytes of UTF-8 a read hands back.
    static let readLimit = 64 * 1024

    private typealias Invalid = AIToolArguments.Invalid

    enum Request: Equatable, Sendable {
        case list(query: String?)
        case read(name: String)
    }

    static func handles(_ name: String) -> Bool { name == listName || name == readName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: listName,
                description: "List the user's Blitz snippets: each one's name, the keyword that "
                    + "expands it, and the start of its text. Use a name with \(readName) for the "
                    + "whole text. The user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(properties: [
                    "query": AIToolJSON.string(
                        "Only snippets whose name, keyword or text contains this.")
                ]),
                origin: origin, title: "List Snippets"),
            AITool(
                name: readName,
                description: "Read one of the user's snippets in full, as its template: "
                    + "placeholders such as {clipboard} or {date} are shown, not filled in. The "
                    + "user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "name": AIToolJSON.string("The snippet's name, as \(listName) gives it.")
                    ],
                    required: ["name"]),
                origin: origin, title: "Read Snippet")
        ]
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName: return .list(query: arguments.string("query"))
        case readName: return .read(name: try arguments.requiredString("name"))
        default: throw Invalid("There is no snippets tool named \u{201C}\(name)\u{201D}.")
        }
    }

    /// Every enabled snippet, as the launcher offers them; a disabled one is offered nowhere.
    static func listed(_ snippets: [Snippet], query: String?) -> [Snippet] {
        let enabled = snippets.filter(\.isEnabled)
        guard let query else { return enabled }
        return enabled.filter { snippet in
            [snippet.name, snippet.keyword ?? "", snippet.text].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    static func listing(_ snippets: [Snippet], query: String?) -> String {
        let shown = listed(snippets, query: query)
        guard !shown.isEmpty else {
            return query.map { "No snippet contains \u{201C}\($0)\u{201D}." }
                ?? "The user has no snippets."
        }
        let count = shown.count == 1 ? "1 snippet" : "\(shown.count) snippets"
        let rows = shown.map { snippet in
            let keyword = snippet.keyword.map { "keyword \($0)" } ?? "no keyword"
            return [snippet.name, keyword, preview(of: snippet.text)].joined(separator: "\t")
        }
        return ([count + ", tab-separated: name, keyword, start of text:"] + rows)
            .joined(separator: "\n")
    }

    /// One line: breaks and tabs are spaces, so a row stays a row.
    static func preview(of text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return AIToolJSON.clipped(flat, to: previewLength)
    }

    static func match(_ name: String, among snippets: [Snippet]) -> AgentNameMatch<Snippet> {
        AgentNameMatch.match(name, among: listed(snippets, query: nil)) {
            [$0.name] + ($0.keyword.map { [$0] } ?? [])
        }
    }

    /// The one snippet answering to the name or keyword, or a refusal naming near ones.
    static func snippet(
        named name: String, in snippets: [Snippet]
    ) throws(AIToolArguments.Invalid) -> Snippet {
        switch match(name, among: snippets) {
        case .found(let snippet): return snippet
        case .ambiguous(let found):
            let keywords = found.compactMap(\.keyword).map { "\u{201C}\($0)\u{201D}" }
                .joined(separator: ", ")
            let byKeyword = keywords.isEmpty ? "" : " Name one by its keyword: \(keywords)."
            throw Invalid("More than one snippet is called \u{201C}\(name)\u{201D}.\(byKeyword)")
        case .missing(let near):
            let similar = near.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            let guesses = near.isEmpty ? "" : " Snippets with a similar name: \(similar)."
            throw Invalid(
                "There is no snippet called \u{201C}\(name)\u{201D}.\(guesses) \(listName) lists "
                    + "them all.")
        }
    }

    static func answer(_ snippet: Snippet) -> String {
        let keyword = snippet.keyword.map { ", keyword \($0)" } ?? ""
        let header = "The snippet \u{201C}\(snippet.name)\u{201D}\(keyword)"
        let size = snippet.text.utf8.count
        guard size > readLimit else { return header + ":\n\n" + snippet.text }
        let shown = AIToolJSON.prefix(snippet.text, utf8Bytes: readLimit)
        return header + ", cut to its first \(shown.utf8.count) of \(size) bytes:\n\n" + shown
    }

    static func gone(_ name: String) -> String {
        "The snippet \u{201C}\(name)\u{201D} was changed or removed while the user was asked, so "
            + "nothing was read."
    }
}
