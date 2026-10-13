import Foundation

/// Each built-in row's own feature switch or grant, which the rule table can never reach past.
@MainActor
struct AgentFeatureCeiling {
    let settings: AppSettings
    let visibility: VisibilityStore
    /// Asked only for the row that needs it, since the gate reads the ceiling on every call.
    let isAccessibilityTrusted: () -> Bool

    func isAvailable(_ tool: AgentTool) -> Bool {
        requirement(for: tool)?.isMet ?? true
    }

    /// What a row held below its ceiling says in Settings; nil while it is available.
    func unavailableReason(for tool: AgentTool) -> String? {
        guard let requirement = requirement(for: tool), !requirement.isMet else { return nil }
        return requirement.reason
    }

    private func requirement(for tool: AgentTool) -> (isMet: Bool, reason: String)? {
        switch tool {
        case .calendarRead, .calendarWrite:
            (settings.calendarEnabled, "Turn on Calendar first.")
        case .remindersRead, .remindersWrite:
            (settings.remindersEnabled, "Turn on Reminders first.")
        case .contactsRead:
            (settings.contactsEnabled, "Turn on Contacts first.")
        case .noteRead, .noteWrite:
            (settings.notesEnabled, "Turn on Notes first.")
        case .clipboardRead:
            (settings.clipboardEnabled, "Turn on Clipboard history first.")
        case .snippetsRead:
            (
                settings.snippetsEnabled || settings.quicklinksEnabled,
                "Turn on Snippets or Quicklinks first."
            )
        case .shortcuts:
            (settings.appleShortcutsEnabled, "Turn on Apple Shortcuts first.")
        case .systemActions:
            (visibility.isKindEnabled(.systemAction), "Turn on System Actions first.")
        case .windowLayouts:
            (settings.windowManagementEnabled, "Turn on Window Management first.")
        case .selectedText:
            (isAccessibilityTrusted(), "Allow Blitz Accessibility access first.")
        case .shell, .filesRead, .filesWrite, .webSearch, .webFetch, .openItems, .frontmostApp,
            .currentClipboard, .mcp:
            nil
        }
    }
}
