import Foundation

/// One Reminders list the user can switch off, flattened out of EventKit for the Settings list.
struct ReminderList: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The owning account, so two "Reminders" lists from different accounts stay tellable apart.
    let accountName: String
}
