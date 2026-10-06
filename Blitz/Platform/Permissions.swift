import AVFoundation
import AppKit
import Contacts
import EventKit
// `@preconcurrency` downgrades AX diagnostics: the option key is a constant C global.
@preconcurrency import ApplicationServices

enum Permissions {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns current trust state and prompts the user to grant it if needed.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The Keyboard pane, whose Keyboard Shortcuts… sheet holds Spotlight's own shortcut.
    @MainActor
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func calendarAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        // Write-only is the same as nothing here: Blitz only ever reads.
        default: return .denied
        }
    }

    /// The store is built and dropped here: a grant is process-wide, so nothing travels.
    nonisolated static func requestCalendarAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// EventKit's own three states, which reminders share with the calendar.
    static func remindersAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    nonisolated static func requestRemindersAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToReminders()) ?? false
    }

    /// Anything short of the whole address book reads as no access: Blitz lists every card.
    static func contactsAccess() -> CalendarAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    nonisolated static func requestContactsAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static func cameraAccess() -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// The one camera prompt, raised from the gesture that asked for it.
    nonisolated static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    @MainActor
    static func openCalendarSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openContactsSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openRemindersSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
