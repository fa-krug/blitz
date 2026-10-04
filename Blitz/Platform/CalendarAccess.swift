import Foundation

/// What the Mac will let Blitz reach of the user's calendar, reminders or contacts.
enum CalendarAccess: Sendable {
    case notDetermined
    case granted
    /// Denied or restricted: only System Settings can undo it, so both read the same to us.
    case denied
}
