import Foundation

/// How a chat model lists, reads and archives the user's other chats, and what it is told back.
enum SessionToolCatalog {
    static let origin = "Chats"
    static let listName = "sessions_list"
    static let readName = "sessions_read"
    static let archiveName = "sessions_archive"
    static let unarchiveName = "sessions_unarchive"

    static let defaultListLimit = 20
    static let listLimit = 50
    /// UTF-8 bytes of transcript per call, so a long chat floods neither the context nor Blitz.
    static let readLimit = 64 * 1024

    private typealias Invalid = AIToolArguments.Invalid

    /// Which chats a listing covers: those in the sidebar, those archived, or both.
    enum Scope: String, CaseIterable, Equatable, Sendable {
        case recent, archived, all
    }

    /// A call, already checked; an id is a well-formed UUID, not yet known to exist.
    enum Request: Equatable, Sendable {
        case list(scope: Scope, query: String?, limit: Int)
        /// `fromMessage` counts from 1, as the transcript numbers its messages.
        case read(id: UUID, fromMessage: Int, limit: Int?)
        case archive(id: UUID)
        case unarchive(id: UUID)

        var tool: AgentTool {
            switch self {
            case .list, .read: .sessionsRead
            case .archive, .unarchive: .sessionsArchive
            }
        }

        var id: UUID? {
            switch self {
            case .list: nil
            case .read(let id, _, _), .archive(let id), .unarchive(let id): id
            }
        }
    }

    static func handles(_ name: String) -> Bool {
        [listName, readName, archiveName, unarchiveName].contains(name)
    }

    private static let consent =
        " Blitz supplies this tool with the user's permission: the user may be asked to confirm "
        + "and may decline."

    static func tools(read: Bool, archive: Bool) -> [AITool] {
        (read ? [list(), readChat()] : []) + (archive ? [archiveChat(), unarchiveChat()] : [])
    }

    private static let idHelp = "The chat's id, as sessions_list gives it."

    private static func list() -> AITool {
        AITool(
            name: listName,
            description: "List the user's other chats with Blitz's agent, newest first: each "
                + "one's id, title, when it was last active, how many messages it holds and "
                + "whether it is archived. This chat is never listed. Use an id with "
                + "\(readName) to read that chat." + consent,
            parameters: AIToolJSON.object(properties: [
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array(Scope.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "recent: the chats in the user's sidebar; archived: the chats the user "
                            + "put away; all: both. Default: recent.")
                ]),
                "query": AIToolJSON.string(
                    "Only chats whose title or last message contains this text."),
                "limit": AIToolJSON.integer(
                    "How many chats to return at most. Default: \(defaultListLimit); at most "
                        + "\(listLimit).")
            ]),
            origin: origin, title: "List Chats")
    }

    private static func readChat() -> AITool {
        AITool(
            name: readName,
            description: "Read one of the user's other chats as a transcript: each message "
                + "numbered, who said it and when, and one line for each web search, tool call, "
                + "question or plan in it. Attachments are named, not shown. At most "
                + "\(readLimit / 1024) KB comes back per call, and the answer says where to read "
                + "on with fromMessage." + consent,
            parameters: AIToolJSON.object(
                properties: [
                    "id": AIToolJSON.string(idHelp),
                    "fromMessage": AIToolJSON.integer(
                        "The first message to read, counting from 1. Default: 1."),
                    "limit": AIToolJSON.integer(
                        "How many messages to read at most. Default: as many as fit.")
                ],
                required: ["id"]),
            origin: origin, title: "Read Chat")
    }

    private static func archiveChat() -> AITool {
        AITool(
            name: archiveName,
            description: "Archive one of the user's other chats: it leaves the sidebar for "
                + "Archived, where the user can open it again. Nothing is deleted. A pinned "
                + "chat, a chat open in Blitz and a chat still answering are left alone."
                + consent,
            parameters: AIToolJSON.object(
                properties: ["id": AIToolJSON.string(idHelp)], required: ["id"]),
            origin: origin, title: "Archive Chat")
    }

    private static func unarchiveChat() -> AITool {
        AITool(
            name: unarchiveName,
            description: "Bring an archived chat back to the user's sidebar." + consent,
            parameters: AIToolJSON.object(
                properties: ["id": AIToolJSON.string(idHelp)], required: ["id"]),
            origin: origin, title: "Unarchive Chat")
    }

    // MARK: - Reading a call

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName: return try list(arguments)
        case readName:
            return .read(
                id: try id(arguments), fromMessage: try count("fromMessage", in: arguments) ?? 1,
                limit: try count("limit", in: arguments))
        case archiveName: return .archive(id: try id(arguments))
        case unarchiveName: return .unarchive(id: try id(arguments))
        default: throw Invalid("Blitz offers no tool named \(name).")
        }
    }

    private static func list(_ arguments: AIToolArguments) throws(Invalid) -> Request {
        var scope = Scope.recent
        if let named = arguments.string("scope") {
            guard let parsed = Scope(rawValue: named.lowercased()) else {
                throw Invalid("\u{201C}scope\u{201D} must be recent, archived or all.")
            }
            scope = parsed
        }
        let limit = try count("limit", in: arguments) ?? defaultListLimit
        return .list(scope: scope, query: arguments.string("query"), limit: min(limit, listLimit))
    }

    private static func id(_ arguments: AIToolArguments) throws(Invalid) -> UUID {
        let text = try arguments.requiredString("id")
        guard let id = UUID(uuidString: text) else {
            throw Invalid(
                "\u{201C}id\u{201D} must be a chat's id as \(listName) gives it, such as "
                    + "0F8E0D4A-6B9C-4E2B-9A7E-3C1D5F2A8B90.")
        }
        return id
    }

    /// Nil when the call left it out; a field sent must be a whole number from 1.
    private static func count(
        _ key: String, in arguments: AIToolArguments
    ) throws(Invalid) -> Int? {
        guard arguments.contains(key) else { return nil }
        guard let value = arguments.int(key), value >= 1 else {
            throw Invalid("\u{201C}\(key)\u{201D} must be a whole number from 1.")
        }
        return value
    }

    // MARK: - Asking

    static func prompt(for request: Request, title: String?) -> AgentPrompt {
        switch request {
        case .list: .sessions(reading: nil)
        case .read: .sessions(reading: title ?? "Untitled")
        case .archive: .archive(title: title ?? "Untitled", archiving: true)
        case .unarchive: .archive(title: title ?? "Untitled", archiving: false)
        }
    }

    // MARK: - Refusals and answers

    static let currentChat =
        "That id is this chat; its messages are already in this conversation, and a chat cannot "
        + "archive itself."

    static func unknown(_ id: UUID) -> String {
        "No saved chat has the id \(id.uuidString); call \(listName) for the ids there are."
    }

    static func answering(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} is answering right now, so it is left where it is."
    }

    static func openInBlitz(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} is open in Blitz right now, so it is left where it is; the user "
            + "can archive it from the sidebar."
    }

    static func pinned(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} is pinned, so it stays in the sidebar; the user can unpin it "
            + "first."
    }

    static func archived(_ title: String) -> String {
        "Archived \u{201C}\(title)\u{201D}. The user finds it under Archived at the bottom of the "
            + "AI Agent sidebar."
    }

    static func alreadyArchived(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} is already archived."
    }

    static func unarchived(_ title: String) -> String {
        "Unarchived \u{201C}\(title)\u{201D}; it is back in the sidebar."
    }

    static func notArchived(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} is not archived."
    }

    static func notSaved(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} could not be changed; it may have been deleted meanwhile."
    }
}
