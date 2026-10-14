import Foundation

/// How a chat model lists and applies the user's saved window layouts, and what it is told back.
enum WindowLayoutToolCatalog {
    static let origin = "Window Layouts"
    static let listName = "window_layouts_list"
    static let applyName = "window_layout_apply"

    private typealias Invalid = AIToolArguments.Invalid

    /// A saved layout as the tools see it; `summary` is its row's "3 windows · 2 displays".
    struct Layout: Equatable, Sendable {
        let id: UUID
        let name: String
        let summary: String
    }

    enum Request: Equatable, Sendable {
        case list
        case apply(name: String)
    }

    /// What one run did, as `WindowLayoutRunner.Outcome` counts it.
    struct Outcome: Equatable, Sendable {
        let placed: Int
        let opened: Int
        /// The launcher's own "1 display not connected · 1 app didn't open", nil when clean.
        let problems: String?
    }

    static func handles(_ name: String) -> Bool { name == listName || name == applyName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: listName,
                description: "List the window layouts the user saved in Blitz: each one's name "
                    + "and how many windows on how many displays it arranges.",
                parameters: AIToolJSON.object(properties: [:]),
                origin: origin, title: "List Window Layouts"),
            AITool(
                name: applyName,
                description: "Apply one of the user's saved window layouts by name: Blitz opens "
                    + "the apps it names that are not running, then moves and resizes their "
                    + "windows. The user may be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "name": AIToolJSON.string("The layout's name, as \(listName) gives it.")
                    ],
                    required: ["name"]),
                origin: origin, title: "Apply Window Layout")
        ]
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName: return .list
        case applyName: return .apply(name: try arguments.requiredString("name"))
        default: throw Invalid("There is no window layout tool named \u{201C}\(name)\u{201D}.")
        }
    }

    static func match(_ name: String, among layouts: [Layout]) -> AgentNameMatch<Layout> {
        if let id = UUID(uuidString: name), let layout = layouts.first(where: { $0.id == id }) {
            return .found(layout)
        }
        return AgentNameMatch.match(name, among: layouts) { [$0.name] }
    }

    /// The one layout answering to the name; names are unique, so ambiguity is a stale list.
    static func layout(
        named name: String, in layouts: [Layout]
    ) throws(AIToolArguments.Invalid) -> Layout {
        switch match(name, among: layouts) {
        case .found(let layout): return layout
        case .ambiguous:
            throw Invalid(
                "More than one layout is called \u{201C}\(name)\u{201D}; \(listName) lists them.")
        case .missing(let near):
            let similar = near.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            let guesses = near.isEmpty ? "" : " Layouts with a similar name: \(similar)."
            throw Invalid(
                "There is no window layout called \u{201C}\(name)\u{201D}.\(guesses) "
                    + "\(listName) lists them all.")
        }
    }

    static func listing(_ layouts: [Layout]) -> String {
        guard !layouts.isEmpty else { return "The user has saved no window layouts." }
        let count = layouts.count == 1 ? "1 window layout" : "\(layouts.count) window layouts"
        return ([count + ", as name and what it arranges:"]
            + layouts.map { "\($0.name)\t\($0.summary)" }).joined(separator: "\n")
    }

    static let needsAccessibility =
        "Blitz does not have Accessibility access, which moving windows needs. The user can "
        + "allow it in System Settings \u{2192} Privacy & Security \u{2192} Accessibility."

    static func gone(_ layout: Layout) -> String {
        "\u{201C}\(layout.name)\u{201D} was deleted, or Window Management turned off, while the "
            + "user was asked, so nothing was done."
    }

    static func prompt(for layout: Layout) -> AgentPrompt {
        AgentPrompt.applyWindowLayout(layout.name, summary: layout.summary)
    }

    /// A run that placed nothing is a failure; one that placed some says what it could not do.
    static func result(of layout: Layout, outcome: Outcome) -> (text: String, isError: Bool) {
        let name = "\u{201C}\(layout.name)\u{201D}"
        guard outcome.placed > 0 else {
            return ("Could not apply \(name): \(outcome.problems ?? "no window could be placed").", true)
        }
        let windows = outcome.placed == 1 ? "1 window" : "\(outcome.placed) windows"
        let apps = outcome.opened == 1 ? "1 app" : "\(outcome.opened) apps"
        let opened = outcome.opened > 0 ? ", opening \(apps)" : ""
        let problems = outcome.problems.map { " Not everything happened: \($0)." } ?? ""
        return ("Applied \(name): placed \(windows)\(opened).\(problems)", false)
    }
}
