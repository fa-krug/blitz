import Foundation

/// How a chat model adds to the agent's memory and takes something out of it.
enum MemoryToolCatalog {
    static let origin = "Memory"
    static let rememberName = "memory_remember"
    static let forgetName = "memory_forget"

    private typealias Invalid = AIToolArguments.Invalid

    enum Request: Equatable, Sendable {
        /// The text as it would be stored.
        case remember(String)
        case forget(Target)
    }

    enum Target: Equatable, Sendable {
        case id(Int)
        /// Matched as a duplicate is, ignoring case and whitespace.
        case text(String)
    }

    /// What answers a call without a dialog; `isError` is false for one that needs nothing done.
    struct Settled: Equatable, Sendable {
        let message: String
        let isError: Bool
    }

    static func handles(_ name: String) -> Bool { name == rememberName || name == forgetName }

    static func tools() -> [AITool] {
        [
            AITool(
                name: rememberName,
                description: "Remember one short fact or preference across chats, such as how "
                    + "the user likes answers written. It is added to your instructions in every "
                    + "later chat. Remember only what the user asks you to, or would clearly want "
                    + "kept, and never a password or other secret. The user may be asked to "
                    + "confirm, and may decline.",
                parameters: AIToolJSON.object(
                    properties: [
                        "text": AIToolJSON.string(
                            "What to remember, one short sentence of at most "
                                + "\(AgentMemory.textLimit) characters.")
                    ],
                    required: ["text"]),
                origin: origin, title: "Remember"),
            AITool(
                name: forgetName,
                description: "Forget one thing you were asked to remember, by the id your "
                    + "instructions show for it, such as m3, or by its exact text. The user may "
                    + "be asked to confirm, and may decline.",
                parameters: AIToolJSON.object(properties: [
                    "id": AIToolJSON.string("The memory's id, such as m3."),
                    "text": AIToolJSON.string("The memory's exact text, when no id is given.")
                ]),
                origin: origin, title: "Forget")
        ]
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case rememberName:
            let text = AgentMemory.cleaned(arguments.text("text") ?? "")
            guard !text.isEmpty else { throw Invalid("\u{201C}text\u{201D} is required.") }
            guard text.count <= AgentMemory.textLimit else { throw Invalid(tooLong(text.count)) }
            return .remember(text)
        case forgetName:
            if let handle = arguments.string("id") {
                guard let id = AgentMemory.id(fromHandle: handle) else {
                    throw Invalid("\u{201C}id\u{201D} is a memory\u{2019}s id, such as m3.")
                }
                return .forget(.id(id))
            }
            let text = AgentMemory.cleaned(arguments.text("text") ?? "")
            guard !text.isEmpty else {
                throw Invalid("Give \u{201C}id\u{201D} or \u{201C}text\u{201D}.")
            }
            return .forget(.text(text))
        default: throw Invalid("There is no memory tool named \u{201C}\(name)\u{201D}.")
        }
    }

    static func memory(for target: Target, in memories: [AgentMemory]) -> AgentMemory? {
        switch target {
        case .id(let id): memories.first { $0.id == id }
        case .text(let text): memories.first { AgentMemory.key($0.text) == AgentMemory.key(text) }
        }
    }

    /// Asked before the dialog and again after it, since Settings may have changed the memories.
    static func settled(_ request: Request, memories: [AgentMemory]) -> Settled? {
        switch request {
        case .remember(let text):
            switch AgentMemory.admission(of: text, into: memories) {
            case .accepted: return nil
            case .duplicate(let twin):
                return Settled(message: alreadyRemembered(twin), isError: false)
            case .full: return Settled(message: full, isError: true)
            case .empty: return Settled(message: "\u{201C}text\u{201D} is required.", isError: true)
            case .tooLong(let count): return Settled(message: tooLong(count), isError: true)
            }
        case .forget(let target):
            guard memory(for: target, in: memories) == nil else { return nil }
            return Settled(message: unknown(target, isEmpty: memories.isEmpty), isError: true)
        }
    }

    /// Nil only for a memory to forget that is not there, which `settled` has answered already.
    static func prompt(for request: Request, memories: [AgentMemory]) -> AgentPrompt? {
        switch request {
        case .remember(let text): .remember(text)
        case .forget(let target): memory(for: target, in: memories).map { .forget($0.text) }
        }
    }

    static func remembered(_ memory: AgentMemory) -> String {
        "Remembered as \(memory.handle). It is in your instructions in every chat from now on."
    }

    static func alreadyRemembered(_ memory: AgentMemory) -> String {
        "That is already remembered as \(memory.handle); nothing was added."
    }

    static func forgot(_ memory: AgentMemory) -> String {
        "Forgot \(memory.handle): \u{201C}\(memory.text)\u{201D}."
    }

    static let full =
        "Memory is full: it holds at most \(AgentMemory.countLimit) memories and "
        + "\(AgentMemory.byteLimit / 1024) KB of text. Nothing was remembered. Ask the user to "
        + "forget something first, with \(forgetName) or in Settings \u{2192} AI \u{2192} Memory."

    static let notSaved = "Memory could not be saved on this Mac, so nothing changed."

    static func changed(_ memory: AgentMemory) -> String {
        "\(memory.handle) was changed while the user was asked, so nothing was forgotten."
    }

    private static func tooLong(_ count: Int) -> String {
        "\u{201C}text\u{201D} holds at most \(AgentMemory.textLimit) characters, and this is "
            + "\(count). Shorten it."
    }

    private static func unknown(_ target: Target, isEmpty: Bool) -> String {
        guard !isEmpty else { return "Nothing is remembered, so there is nothing to forget." }
        switch target {
        case .id(let id):
            return "No memory is m\(id). Your instructions show each memory\u{2019}s id."
        case .text(let text): return "No memory reads \u{201C}\(text)\u{201D}."
        }
    }
}
