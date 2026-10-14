import Foundation

/// Which system actions a chat model may run, how it names them, and what it is told back.
enum SystemActionToolCatalog {
    static let origin = "System Actions"
    static let listName = "system_actions_list"
    static let runName = "system_action_run"

    private typealias Invalid = AIToolArguments.Invalid

    /// Never offered and refused by name: each ends work, loses something or cannot be undone.
    static let excluded: [SystemAction.ID: String] = [
        .restart: "it ends the session, closing every app and this chat",
        .shutDown: "it ends the session, closing every app and this chat",
        .logOut: "it ends the session, closing every app and this chat",
        .emptyTrash: "it deletes what is in the Trash for good",
        .quitAllApps: "it quits every app at once, and unsaved work may be lost",
        .ejectAllDisks: "a disk comes back only once someone plugs it in again",
        .toggleBluetooth: "turning Bluetooth off can cut off the keyboard and mouse that would "
            + "turn it back on",
        .dismissNotifications: "a dismissed notification cannot be brought back",
        .setVolume: "it asks for a level in a dialog of its own; the Set Volume to 0\u{2013}100% "
            + "actions set one directly"
    ]

    /// Catalog order, which is the launcher's.
    static let offered: [SystemAction] = SystemActionCatalog.all.filter { excluded[$0.id] == nil }

    enum Request: Equatable, Sendable {
        case list
        case run(SystemAction)
    }

    static func handles(_ name: String) -> Bool { name == listName || name == runName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: listName,
                description: "List the system actions Blitz can run for the user, such as "
                    + "locking the screen, sleeping, media keys, volume and dark mode: each "
                    + "one's id and name.",
                parameters: AIToolJSON.object(properties: [:]),
                origin: origin, title: "List System Actions"),
            AITool(
                name: runName,
                description: "Run one of Blitz's system actions by its id, as "
                    + "\(listName) gives it. Restarting, shutting down, logging out, emptying "
                    + "the Trash and the like are not available. The user may be asked to "
                    + "confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "id": .object([
                            "type": .string("string"),
                            "enum": .array(offered.map { .string($0.id.rawValue) }),
                            "description": .string("The action's id, such as lock-screen.")
                        ])
                    ],
                    required: ["id"]),
                origin: origin, title: "Run System Action")
        ]
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName: return .list
        case runName: return .run(try action(named: arguments.requiredString("id")))
        default: throw Invalid("There is no system action tool named \u{201C}\(name)\u{201D}.")
        }
    }

    /// By id, or by the name the launcher shows, so "Lock Screen" reads as lock-screen.
    private static func action(named text: String) throws(Invalid) -> SystemAction {
        let wanted = AgentNameMatch<SystemAction>.folded(text)
        let action = SystemActionCatalog.all.first {
            $0.id.rawValue == wanted || AgentNameMatch<SystemAction>.folded($0.name) == wanted
        }
        guard let action else {
            throw Invalid(
                "There is no system action \u{201C}\(text)\u{201D}; \(listName) lists their ids.")
        }
        if let reason = excluded[action.id] {
            throw Invalid("\u{201C}\(action.name)\u{201D} is not available to the agent: \(reason).")
        }
        return action
    }

    static func listing() -> String {
        (["\(offered.count) system actions, as id and name:"]
            + offered.map { "\($0.id.rawValue)\t\($0.name)" }).joined(separator: "\n")
    }

    static func prompt(for action: SystemAction) -> AgentPrompt {
        AgentPrompt.runSystemAction(action.name)
    }

    /// `feedback` is what the launcher's pill would say; most actions are their own feedback.
    static func result(of action: SystemAction, feedback: String?) -> String {
        let ran = "Ran \u{201C}\(action.name)\u{201D}."
        return feedback.map { "\(ran) \($0)." } ?? ran
    }

    static func failed(_ action: SystemAction, reason: String) -> String {
        "\u{201C}\(action.name)\u{201D} failed: \(reason)"
    }

    static let microphoneBusy =
        "The microphone is still switching from the last toggle; try again in a moment."
}
