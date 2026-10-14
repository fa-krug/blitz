import Foundation

/// How a chat model lists and runs the user's Apple Shortcuts, and what it is told back.
enum ShortcutToolCatalog {
    static let origin = "Shortcuts"
    static let listName = "shortcuts_list"
    static let runName = "shortcuts_run"
    /// Characters of input a call may hand a shortcut, and of output that comes back.
    static let inputLimit = 20_000
    static let outputLimit = 20_000

    private typealias Invalid = AIToolArguments.Invalid

    /// A call, already checked; a name is not yet known to be in the library.
    enum Request: Equatable, Sendable {
        case list(query: String?)
        case run(name: String, input: String?)
    }

    static func handles(_ name: String) -> Bool { name == listName || name == runName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: listName,
                description: "List the shortcuts in the user's Shortcuts app by name. Use a "
                    + "name with \(runName) to run one.",
                parameters: AIToolJSON.object(properties: [
                    "query": AIToolJSON.string("Only shortcuts whose name contains this text.")
                ]),
                origin: origin, title: "List Shortcuts"),
            AITool(
                name: runName,
                description: "Run one of the user's Apple Shortcuts by name, optionally with text "
                    + "as its input, and read back what it returns as text. A shortcut can do "
                    + "anything its actions do. The user may be asked to confirm, and may "
                    + "decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "name": AIToolJSON.string("The shortcut's name, as \(listName) gives it."),
                        "input": AIToolJSON.string(
                            "Optional text the shortcut receives as its input. At most "
                                + "\(inputLimit) characters.")
                    ],
                    required: ["name"]),
                origin: origin, title: "Run Shortcut")
        ]
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName: return .list(query: arguments.string("query"))
        case runName:
            let shortcut = try arguments.requiredString("name")
            let input = arguments.text("input").flatMap { $0.isEmpty ? nil : $0 }
            guard (input?.count ?? 0) <= inputLimit else {
                throw Invalid("\u{201C}input\u{201D} holds at most \(inputLimit) characters.")
            }
            return .run(name: shortcut, input: input)
        default: throw Invalid("There is no shortcuts tool named \u{201C}\(name)\u{201D}.")
        }
    }

    /// By name, or by the identifier `shortcuts list --show-identifiers` prints.
    static func match(_ name: String, among library: [AppleShortcut]) -> AgentNameMatch<AppleShortcut> {
        if let id = UUID(uuidString: name), let shortcut = library.first(where: { $0.id == id }) {
            return .found(shortcut)
        }
        return AgentNameMatch.match(name, among: library) { [$0.name] }
    }

    /// The one shortcut answering to the name, or a refusal naming what it might have meant.
    static func shortcut(
        named name: String, in library: [AppleShortcut]
    ) throws(AIToolArguments.Invalid) -> AppleShortcut {
        switch match(name, among: library) {
        case .found(let shortcut): return shortcut
        case .ambiguous(let shortcuts):
            let ids = shortcuts.map { $0.id.uuidString }.joined(separator: ", ")
            throw Invalid(
                "More than one shortcut is called \u{201C}\(name)\u{201D}. Name the one to run "
                    + "by its identifier: \(ids).")
        case .missing(let near):
            let similar = near.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            let guesses = near.isEmpty ? "" : " Shortcuts with a similar name: \(similar)."
            throw Invalid(
                "There is no shortcut called \u{201C}\(name)\u{201D}.\(guesses) \(listName) "
                    + "lists them all.")
        }
    }

    static func listing(_ library: [AppleShortcut], query: String?) -> String {
        let shown = query.map { query in
            library.filter { $0.name.localizedCaseInsensitiveContains(query) }
        } ?? library
        guard !shown.isEmpty else {
            return query.map { "No shortcut\u{2019}s name contains \u{201C}\($0)\u{201D}." }
                ?? "The Shortcuts app holds no shortcuts."
        }
        let count = shown.count == 1 ? "1 shortcut" : "\(shown.count) shortcuts"
        return ([count + ":"] + shown.map(\.name)).joined(separator: "\n")
    }

    static func prompt(for shortcut: AppleShortcut, input: String?) -> AgentPrompt {
        AgentPrompt.runShortcut(shortcut.name, input: input)
    }

    /// `output` is what the shortcut wrote, nil when it returned nothing.
    static func result(of shortcut: AppleShortcut, output: Data?) -> String {
        let ran = "Ran \u{201C}\(shortcut.name)\u{201D}."
        guard let output, !output.isEmpty else { return ran + " It returned nothing." }
        guard !output.contains(0), let text = String(data: output, encoding: .utf8) else {
            return ran + " What it returned is not text, so it is not shown."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > outputLimit else { return ran + " It returned:\n\n" + trimmed }
        return ran + " It returned, cut to its first \(outputLimit) of \(trimmed.count) "
            + "characters:\n\n" + trimmed.prefix(outputLimit)
    }

    static func failed(_ shortcut: AppleShortcut, reason: String) -> String {
        "\u{201C}\(shortcut.name)\u{201D} failed: \(reason)"
    }

    static let unreadable = "Blitz could not read the Shortcuts library just now."
}
