import Foundation

/// What the Mac will let Blitz reach: the calendar, reminders, contacts or the microphone.
enum CalendarAccess: Sendable {
    case notDetermined
    case granted
    /// Denied or restricted: only System Settings can undo it, so both read the same to us.
    case denied
}
