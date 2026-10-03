import Foundation

/// What the reminder prompt collects, before anything touches Reminders.
struct ReminderDraft: Sendable, Equatable {
    var title = ""
    var notes = ""
    var due: ReminderDue?

    /// A blank title is the one thing that cannot be written; everything else may be empty.
    var isValid: Bool { !trimmedTitle.isEmpty }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nil rather than empty, so clearing the field clears the reminder's notes too.
    var trimmedNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ReminderDraft {
    init(editing reminder: ReminderItem) {
        self.init(title: reminder.title, notes: reminder.notes ?? "", due: reminder.due)
    }
}
