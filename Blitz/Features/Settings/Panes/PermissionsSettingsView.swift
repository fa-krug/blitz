import Combine
import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var calendarAccess = Permissions.calendarAccess()
    @State private var remindersAccess = Permissions.remindersAccess()
    @State private var contactsAccess = Permissions.contactsAccess()
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: accessibilityStatus.symbol)
                                .accessibilityHidden(true)
                            Text(accessibilityStatus.title)
                        }
                        .foregroundStyle(accessibilityStatus.tint)
                        Button(accessibilityTrusted ? "Open…" : "Grant Access…") {
                            Permissions.openAccessibilitySettings()
                        }
                        .help("Opens Privacy & Security › Accessibility.")
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        PermissionSettingsIcon(
                            path:
                                "/System/Library/ExtensionKit/Extensions/AccessibilitySettingsExtension.appex"
                        )
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.permissionsAccessibility, "Accessibility")
                            Text("Pastes into the app you were using.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.permissionsAccessibility)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: calendarStatus.symbol)
                                .accessibilityHidden(true)
                            Text(calendarStatus.title)
                        }
                        .foregroundStyle(calendarStatus.tint)
                        Button(calendarNeedsPrompt ? "Grant Access…" : "Open…") {
                            // Settings lists no app TCC was never asked about, so asking is the way in.
                            if calendarNeedsPrompt {
                                core.calendarCoordinator.setCalendarEnabled(true)
                            } else {
                                Permissions.openCalendarSettings()
                            }
                        }
                        .help(
                            calendarNeedsPrompt
                                ? "Turns the calendar on, then asks macOS for access."
                                : "Opens Privacy & Security › Calendars.")
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        PermissionSettingsIcon(
                            path: "/System/Applications/Calendar.app")
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.permissionsCalendars, "Calendars")
                            Text("Finds the join link for your next meeting.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.permissionsCalendars)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: Self.status(of: remindersAccess).symbol)
                                .accessibilityHidden(true)
                            Text(Self.status(of: remindersAccess).title)
                        }
                        .foregroundStyle(Self.status(of: remindersAccess).tint)
                        Button(remindersNeedsPrompt ? "Grant Access…" : "Open…") {
                            if remindersNeedsPrompt {
                                core.remindersCoordinator.setRemindersEnabled(true)
                            } else {
                                Permissions.openRemindersSettings()
                            }
                        }
                        .help(
                            remindersNeedsPrompt
                                ? "Turns Reminders on, then asks macOS for access."
                                : "Opens Privacy & Security › Reminders.")
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        PermissionSettingsIcon(path: "/System/Applications/Reminders.app")
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.permissionsReminders, "Reminders")
                            Text("Lists, edits and creates your reminders.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.permissionsReminders)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: Self.status(of: contactsAccess).symbol)
                                .accessibilityHidden(true)
                            Text(Self.status(of: contactsAccess).title)
                        }
                        .foregroundStyle(Self.status(of: contactsAccess).tint)
                        Button(contactsNeedsPrompt ? "Grant Access…" : "Open…") {
                            if contactsNeedsPrompt {
                                core.contactsCoordinator.setContactsEnabled(true)
                            } else {
                                Permissions.openContactsSettings()
                            }
                        }
                        .help(
                            contactsNeedsPrompt
                                ? "Turns Contacts on, then asks macOS for access."
                                : "Opens Privacy & Security › Contacts.")
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        PermissionSettingsIcon(path: "/System/Applications/Contacts.app")
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.permissionsContacts, "Contacts")
                            Text("Lists, edits, calls and emails your contacts.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.permissionsContacts)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.permissions)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private var calendarNeedsPrompt: Bool { calendarAccess == .notDetermined }
    private var remindersNeedsPrompt: Bool { remindersAccess == .notDetermined }
    private var contactsNeedsPrompt: Bool { contactsAccess == .notDetermined }

    private var accessibilityStatus: (title: String, symbol: String, tint: Color) {
        accessibilityTrusted
            ? ("Granted", "checkmark.circle.fill", .green)
            : ("Not granted", "exclamationmark.triangle.fill", .orange)
    }

    private var calendarStatus: (title: String, symbol: String, tint: Color) {
        Self.status(of: calendarAccess)
    }

    private static func status(of access: CalendarAccess) -> (
        title: String, symbol: String, tint: Color
    ) {
        switch access {
        case .granted: return ("Granted", "checkmark.circle.fill", .green)
        case .notDetermined: return ("Not asked yet", "questionmark.circle.fill", .secondary)
        case .denied: return ("Not granted", "exclamationmark.triangle.fill", .orange)
        }
    }

    private func refresh() {
        let trusted = Permissions.isAccessibilityTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let access = Permissions.calendarAccess()
        if access != calendarAccess { calendarAccess = access }
        let reminders = Permissions.remindersAccess()
        if reminders != remindersAccess { remindersAccess = reminders }
        let contacts = Permissions.contactsAccess()
        if contacts != contactsAccess { contactsAccess = contacts }
    }
}

private struct PermissionSettingsIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.icon(forFile: path))
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .id(IconCache.style.generation)
            .frame(
                width: SettingsListMetrics.iconSize,
                height: SettingsListMetrics.iconSize
            )
            .accessibilityHidden(true)
    }
}
