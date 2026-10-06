import Foundation

/// One card on the tour's tips page, with the keys it teaches.
enum OnboardingTip: Hashable, Sendable {
    case actions
    case aliases
    case tab(TabDestination)

    /// Where ⇥ goes from the launcher's search field, so the card never promises another place.
    enum TabDestination: Hashable, Sendable {
        case quickAI
        case clipboard
        case nowhere

        init(_ action: PaletteTabAction) {
            switch action {
            case .ask: self = .quickAI
            case .carryQuery(.clipboard), .freshScreen(.clipboard): self = .clipboard
            case .carryQuery, .freshScreen: self = .nowhere
            }
        }
    }

    static func all(tab: TabDestination) -> [Self] {
        [.actions, .aliases, .tab(tab)]
    }

    var title: String {
        switch self {
        case .actions: "Every row has actions"
        case .aliases: "Give anything an alias"
        case .tab(.quickAI): "Ask Quick AI"
        case .tab(.clipboard): "Jump to your clipboard"
        case .tab(.nowhere): "Tab through fields"
        }
    }

    var message: String {
        switch self {
        case .actions:
            "Open the actions menu on any result to see all it can do, with a shortcut for each."
        case .aliases:
            "Open a row's settings to set a short alias. Type it and Space to jump into its fields."
        case .tab(.quickAI):
            "Type a question and press Tab to hand it to Quick AI."
        case .tab(.clipboard):
            "Press Tab to switch to Clipboard History. Turn on AI and Tab asks Quick AI instead."
        case .tab(.nowhere):
            "Tab moves between a command's fields. Turn on AI and Tab asks Quick AI instead."
        }
    }

    var keycaps: [String] {
        switch self {
        case .actions: ["⌘", "K"]
        case .aliases: ["⇧", "⌘", ","]
        case .tab: ["⇥"]
        }
    }

    /// The card links to Settings › AI, the one switch that sends ⇥ to Quick AI.
    var offersAISettings: Bool {
        switch self {
        case .tab(.clipboard), .tab(.nowhere): true
        case .actions, .aliases, .tab(.quickAI): false
        }
    }
}
