import AVFoundation
import AppKit
import Contacts
import EventKit
import Synchronization
// `@preconcurrency` downgrades AX diagnostics: the option key is a constant C global.
@preconcurrency import ApplicationServices

enum Permissions {
    /// EventKit caches status per process: a grant made here reads `.notDetermined` until relaunch.
    private static let eventKitGrants = Mutex<Set<EKEntityType>>([])

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

    static func calendarAccess() -> CalendarAccess {
        eventKitAccess(for: .event)
    }

    /// The store is built and dropped here: a grant is process-wide, so nothing travels.
    nonisolated static func requestCalendarAccess() async -> Bool {
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        if granted { eventKitGrants.withLock { _ = $0.insert(.event) } }
        return granted
    }

    static func remindersAccess() -> CalendarAccess {
        eventKitAccess(for: .reminder)
    }

    nonisolated static func requestRemindersAccess() async -> Bool {
        let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        if granted { eventKitGrants.withLock { _ = $0.insert(.reminder) } }
        return granted
    }

    /// EventKit's own three states, which reminders share with the calendar.
    private static func eventKitAccess(for type: EKEntityType) -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .notDetermined:
            return eventKitGrants.withLock { $0.contains(type) } ? .granted : .notDetermined
        // Write-only is the same as nothing here: Blitz needs to read.
        default: return .denied
        }
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
