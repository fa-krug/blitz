import AppKit

/// Hands a reminder to Reminders.app.
@MainActor
enum ReminderLauncher {
    private static let remindersBundleID = "com.apple.reminders"

    /// Reminders' own item scheme opens the reminder itself; with no handler, the app opens bare.
    @discardableResult
    static func show(_ id: ReminderItem.ID) -> Bool {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(id)"),
            workspace.urlForApplication(toOpen: url) != nil
        {
            return workspace.open(url)
        }
        guard let app = workspace.urlForApplication(withBundleIdentifier: remindersBundleID) else {
            return false
        }
        return workspace.open(app)
    }
}
