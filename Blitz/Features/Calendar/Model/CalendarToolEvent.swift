import Foundation

/// One occurrence as a chat model reads it: more than a row shows, as the model is asked about it.
struct CalendarToolEvent: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isDeclined: Bool
    let calendarName: String
    let location: String?
    let notes: String?
    let url: String?
}
