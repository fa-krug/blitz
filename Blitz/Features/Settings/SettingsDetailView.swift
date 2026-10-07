import SwiftUI

/// The pane column: whichever pane the history currently points at.
struct SettingsDetailView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    /// Trails `navigation.tab` by a frame, so the sidebar's highlight moves before a pane builds.
    @State private var shown: SettingsTab?

    var body: some View {
        // Not a `TabView`: `NSTabView` re-hosts on selection and breaks the recorder.
        Group {
            switch shown ?? navigation.tab {
            case .general: GeneralSettingsView()
            case .applications: ApplicationsSettingsView()
            case .systemSettings: SystemSettingsSettingsView()
            case .systemActions: SystemActionsSettingsView()
            case .commands: CommandsSettingsView()
            case .quicklinks: QuicklinksSettingsView()
            case .appleShortcuts: AppleShortcutsSettingsView()
            case .fallbacks: FallbacksSettingsView()
            case .ai: AISettingsView()
            case .quickActions: QuickActionsSettingsView()
            case .fileSearch: FileSearchSettingsView()
            case .notes: NotesSettingsView()
            case .snippets: SnippetsSettingsView()
            case .navigation: NavigationSettingsView()
            case .windowManagement: WindowManagementSettingsView()
            case .clipboard: ClipboardSettingsView()
            case .emoji: EmojiSettingsView()
            case .calendar: CalendarSettingsView()
            case .reminders: RemindersSettingsView()
            case .contacts: ContactsSettingsView()
            case .extensions: ExtensionsSettingsView()
            case .permissions: PermissionsSettingsView()
            case .backup: BackupSettingsView()
            case .about: AboutView()
            }
        }
        // A reopened window keeps its shell, not the pane: appear hooks refresh what a pane shows.
        .id(navigation.session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Past the task's first suspension, so the frame with the new highlight commits first.
        .task(id: navigation.tab) {
            await Task.yield()
            shown = navigation.tab
        }
        // One host for every pane, above their scroll views so a callout is never clipped.
        .shortcutRecorderPopoverHost()
    }
}
