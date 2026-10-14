import Foundation

/// How a chat model reads the note the Notes window shows and adds to its end.
enum NoteToolCatalog {
    static let origin = "Notes"
    static let readName = "note_read"
    static let appendName = "note_append"
    /// Bytes of UTF-8 a read hands back.
    static let readLimit = 64 * 1024
    /// Characters one addition may carry.
    static let appendLimit = 20_000

    private typealias Invalid = AIToolArguments.Invalid

    enum Request: Equatable, Sendable {
        case read
        case append(String)
    }

    static func handles(_ name: String) -> Bool { name == readName || name == appendName }

    static func tools(read: Bool, append: Bool) -> [AITool] {
        let reading = AITool(
            name: readName,
            description: "Read the note open in the user's Notes window, the floating note in "
                + "Blitz, as Markdown. The user may be asked to confirm, and may decline.",
            parameters: AIToolJSON.object(properties: [:]),
            origin: origin, title: "Read Note")
        let appending = AITool(
            name: appendName,
            description: "Add text to the end of the note open in the user's Notes window, on a "
                + "line of its own. Nothing already in the note changes. The user may be asked "
                + "to confirm, and may decline.",
            parameters: AIToolJSON.object(
                properties: [
                    "text": AIToolJSON.string(
                        "The Markdown to add, at most \(appendLimit) characters.")
                ],
                required: ["text"]),
            origin: origin, title: "Add to Note")
        return (read ? [reading] : []) + (append ? [appending] : [])
    }

    static func request(
        name: String, arguments: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case readName: return .read
        case appendName:
            guard let text = arguments.text("text"),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Invalid("\u{201C}text\u{201D} is required.") }
            guard text.count <= appendLimit else {
                throw Invalid("\u{201C}text\u{201D} holds at most \(appendLimit) characters.")
            }
            return .append(text)
        default: throw Invalid("There is no notes tool named \u{201C}\(name)\u{201D}.")
        }
    }

    /// What goes after `source`: on a line of its own, never run into the note's last line.
    static func addition(_ text: String, to source: String) -> String {
        source.isEmpty || source.hasSuffix("\n") ? text : "\n" + text
    }

    static func answer(title: String, source: String) -> String {
        guard !source.isEmpty else { return "The note \u{201C}\(title)\u{201D} is empty." }
        let size = source.utf8.count
        guard size > readLimit else { return "The note \u{201C}\(title)\u{201D}:\n\n" + source }
        let shown = AIToolJSON.prefix(source, utf8Bytes: readLimit)
        return "The note \u{201C}\(title)\u{201D}, cut to its first \(shown.utf8.count) of "
            + "\(size) bytes:\n\n" + shown
    }

    static func appended(_ text: String, title: String) -> String {
        let count = text.count == 1 ? "1 character" : "\(text.count) characters"
        return "Added \(count) to the end of \u{201C}\(title)\u{201D}."
    }

    static let noNote = "The user has no note in Notes."
    static let notSaved = "The addition could not be saved; the user has been told why."

    static func changed(_ title: String) -> String {
        "The note \u{201C}\(title)\u{201D} was switched away from while the user was asked, so "
            + "nothing was done."
    }
}
