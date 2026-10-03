import Foundation

/// One open reminder, flattened out of EventKit so nothing EventKit-shaped reaches a view.
struct ReminderItem: Identifiable, Hashable, Sendable {
    /// EventKit's `calendarItemIdentifier`: stable across launches, and what Reminders.app opens.
    let id: String
    let title: String
    let notes: String?
    let due: ReminderDue?
    let listID: String
    let listName: String
    let listColor: ListColor?
}

extension ReminderItem {
    /// The owning list's colour as sRGB components, so the model stays free of AppKit.
    struct ListColor: Hashable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }
}
