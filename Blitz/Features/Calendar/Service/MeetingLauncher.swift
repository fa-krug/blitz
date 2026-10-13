import AppKit

enum MeetingLauncher {
    struct Browser: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// A missing `browserBundleID` app falls back to the default browser, never a failed join.
    @MainActor
    static func join(_ link: MeetingLink, browserBundleID: String?) async -> Bool {
        let workspace = NSWorkspace.shared
        if let appURL = link.appURL, workspace.urlForApplication(toOpen: appURL) != nil {
            return workspace.open(appURL)
        }
        return await openWeb(link.webURL, browserBundleID: browserBundleID)
    }

    /// Outlook's targets reach the meeting's day; an Outlook link nothing claims opens Calendar.
    @MainActor
    @discardableResult
    static func show(
        _ event: MeetingEvent, in target: CalendarOpenTarget, browserBundleID: String?
    ) async -> Bool {
        let workspace = NSWorkspace.shared
        switch (target, target.url(for: event.start, calendar: .current)) {
        case (.outlook, let url?) where workspace.urlForApplication(toOpen: url) != nil:
            return workspace.open(url)
        case (.outlookWeb, let url?):
            return await openWeb(url, browserBundleID: browserBundleID)
        default:
            return showInCalendar(event)
        }
    }

    /// Probes the scheme itself: the same check `show` makes before it falls back to Calendar.
    @MainActor
    static var isOutlookInstalled: Bool {
        guard let probe = URL(string: "ms-outlook://events") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    @MainActor
    private static func openWeb(_ url: URL, browserBundleID: String?) async -> Bool {
        let workspace = NSWorkspace.shared
        guard let browserBundleID,
            let browser = workspace.urlForApplication(withBundleIdentifier: browserBundleID)
        else { return workspace.open(url) }
        do {
            _ = try await workspace.open(
                [url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }

    /// Every app that opens `https`, one per bundle ID, sorted by name.
    @MainActor
    static func installedBrowsers() -> [Browser] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .compactMap { url -> Browser? in
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted
                else { return nil }
                return Browser(id: id, name: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Calendar.app's own handle; a recurring occurrence opens its series.
    @MainActor
    private static func showInCalendar(_ event: MeetingEvent) -> Bool {
        guard
            let url = URL(
                string: "ical://ekevent/\(event.calendarItemID)?method=show&options=more")
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}
