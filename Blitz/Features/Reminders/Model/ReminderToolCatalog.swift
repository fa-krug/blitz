import Foundation

/// What a chat model may ask of Reminders, and how its calls and answers are spelled.
enum ReminderToolCatalog {
    static let origin = "Reminders"
    static let listName = "reminders_list"
    static let createName = "reminders_create"
    static let updateName = "reminders_update"
    static let completeName = "reminders_complete"
    /// More than this would crowd out the answer the model was asked for.
    static let maxReminders = 150
    static let maxNotesLength = 400
    private static let clearDue = "none"

    private typealias Invalid = AIToolArguments.Invalid

    enum Request: Equatable, Sendable {
        case list(query: String?)
        case create(ReminderDraft)
        case update(id: ReminderItem.ID, Edit)
        case complete(id: ReminderItem.ID)
    }

    /// An update names only what changes; every field left out keeps the reminder's own.
    struct Edit: Equatable, Sendable {
        var title: String?
        var notes: String?
        /// `.some(nil)` clears the due date, which `nil` would read as "keep".
        var due: ReminderDue??

        func applied(to draft: ReminderDraft) -> ReminderDraft {
            var draft = draft
            if let title { draft.title = title }
            if let notes { draft.notes = notes }
            if let due { draft.due = due }
            return draft
        }
    }

    static func handles(_ name: String) -> Bool {
        [listName, createName, updateName, completeName].contains(name)
    }

    /// Writing is offered only where the reader allowed it, so a read-only model never sees it.
    static func tools(canWrite: Bool, now: Date, calendar: Calendar) -> [AITool] {
        let now = AIToolDate.describeNow(now, calendar: calendar)
        let list = AITool(
            name: listName,
            description: "List the user's open reminders with their id, list and due date, "
                + "soonest first, in the user's local time. Now: \(now).",
            parameters: AIToolJSON.object(properties: [
                "query": AIToolJSON.string("Optional text to find in the title, notes or list name.")
            ]),
            origin: origin, title: "List Reminders")
        guard canWrite else { return [list] }
        let create = AITool(
            name: createName,
            description: "Add a reminder to the user's default list, in the user's local time. "
                + "Now: \(now). The result gives its id. To change a reminder, call "
                + "\(updateName) instead; never add a second one.",
            parameters: AIToolJSON.object(
                properties: [
                    "title": AIToolJSON.string("A short task to act on."),
                    "due": AIToolJSON.string(
                        "Optional. YYYY-MM-DD for a day, YYYY-MM-DDTHH:MM for a moment."),
                    "notes": AIToolJSON.string("Optional.")
                ],
                required: ["title"]),
            origin: origin, title: "Create Reminder")
        let update = AITool(
            name: updateName,
            description: "Change one open reminder, by the id \(listName) or \(createName) gave "
                + "it, in the user's local time. Now: \(now). Send only the fields that change.",
            parameters: AIToolJSON.object(
                properties: [
                    "id": AIToolJSON.string("The reminder's id."),
                    "title": AIToolJSON.string("Optional. The new title."),
                    "due": AIToolJSON.string(
                        "Optional. YYYY-MM-DD for a day, YYYY-MM-DDTHH:MM for a moment, "
                            + "\(clearDue) to remove the due date."),
                    "notes": AIToolJSON.string("Optional. The new notes.")
                ],
                required: ["id"]),
            origin: origin, title: "Update Reminder")
        let complete = AITool(
            name: completeName,
            description: "Mark one open reminder as completed, by the id \(listName) gave it. "
                + "The user confirms first.",
            parameters: AIToolJSON.object(
                properties: ["id": AIToolJSON.string("The reminder's id.")], required: ["id"]),
            origin: origin, title: "Complete Reminder")
        return [list, create, update, complete]
    }

    static func request(
        name: String, arguments: String, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listName:
            return .list(query: arguments.string("query"))
        case createName:
            let due = try arguments.date("due", calendar: calendar).map(ReminderDue.init)
            return .create(
                ReminderDraft(
                    title: try arguments.requiredString("title"),
                    notes: arguments.string("notes") ?? "", due: due))
        case updateName:
            let due: ReminderDue??
            if arguments.string("due")?.lowercased() == clearDue {
                due = .some(nil)
            } else if let date = try arguments.date("due", calendar: calendar) {
                due = ReminderDue(date)
            } else {
                due = nil
            }
            let edit = Edit(
                title: arguments.string("title"), notes: arguments.string("notes"), due: due)
            guard edit != Edit() else {
                throw Invalid("Name a new title, due date or notes to change.")
            }
            return .update(id: try arguments.requiredString("id"), edit)
        case completeName:
            return .complete(id: try arguments.requiredString("id"))
        default:
            throw Invalid("There is no reminders tool named \u{201C}\(name)\u{201D}.")
        }
    }

    /// What the model reads back: the matching reminders in due order, capped.
    static func render(
        _ reminders: [ReminderItem], query: String?, now: Date, calendar: Calendar
    ) -> String {
        let matched = ReminderAgenda.sorted(
            ReminderAgenda.matching(reminders, query: query ?? ""), calendar: calendar)
        var answer: [String: JSONValue] = [
            "reminders": .array(
                matched.prefix(maxReminders).map { record(of: $0, now: now, calendar: calendar) })
        ]
        if matched.count > maxReminders {
            answer["omitted"] = .number(Double(matched.count - maxReminders))
        }
        return AIToolJSON.text(.object(answer))
    }

    private static func record(
        of reminder: ReminderItem, now: Date, calendar: Calendar
    ) -> JSONValue {
        var record: [String: JSONValue] = [
            "id": .string(reminder.id),
            "title": .string(reminder.title),
            "list": .string(reminder.listName)
        ]
        if let due = reminder.due {
            record["due"] = .string(AIToolDate(due).text)
            if due.isOverdue(now: now, calendar: calendar) { record["overdue"] = .bool(true) }
        }
        if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            !notes.isEmpty
        {
            record["notes"] = .string(AIToolJSON.clipped(notes, to: maxNotesLength))
        }
        return .object(record)
    }

    /// What was saved, with the id a later update or completion names it by.
    static func saved(_ draft: ReminderDraft, id: ReminderItem.ID) -> String {
        var record: [String: JSONValue] = ["id": .string(id), "title": .string(draft.trimmedTitle)]
        if let due = draft.due { record["due"] = .string(AIToolDate(due).text) }
        if let notes = draft.trimmedNotes {
            record["notes"] = .string(AIToolJSON.clipped(notes, to: maxNotesLength))
        }
        return AIToolJSON.text(.object(["saved": .object(record)]))
    }
}

private extension AIToolDate {
    init(_ due: ReminderDue) {
        self.init(
            year: due.year, month: due.month, day: due.day,
            time: due.time.map { Time(hour: $0.hour, minute: $0.minute) })
    }
}
