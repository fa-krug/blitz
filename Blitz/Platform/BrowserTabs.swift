import AppKit

/// Reads and focuses an already-running browser's tabs over AppleScript; never launches one.
@MainActor
enum BrowserTabs {
    /// The two scripting dictionaries in use; Arc speaks Chromium's but selects a tab its own way.
    private enum Dialect: Sendable {
        case safari
        case chromium
        case arc
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        /// macOS refused the Apple event (`-1743`), so the caller can offer Automation settings.
        let needsAutomationPermission: Bool

        var errorDescription: String? { message }
    }

    private static let dialects: [String: Dialect] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.kagi.kagimacOS": .safari,
        "com.kagi.kagimacOS.RC": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "company.thebrowser.Browser": .arc,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.microsoft.edgemac.Dev": .chromium,
        "com.microsoft.edgemac.Canary": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "org.chromium.Chromium": .chromium
    ]

    /// A hung browser must not hold the caller for AppleScript's default two minutes.
    private static let timeoutSeconds = 5

    static func isSupported(bundleID: String?) -> Bool {
        bundleID.map { dialects[$0] != nil } ?? false
    }

    /// The first candidate that is a supported browser, else the one with the frontmost window.
    static func browser(preferring candidates: [NSRunningApplication?]) -> NSRunningApplication? {
        for case let app? in candidates
        where !app.isTerminated && isSupported(bundleID: app.bundleIdentifier) {
            return app
        }
        return mostRecentBrowser()
    }

    /// The window list runs front to back, so its first browser window names the last one used.
    static func mostRecentBrowser() -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && isSupported(bundleID: $0.bundleIdentifier)
        }
        guard !running.isEmpty else { return nil }
        let windows =
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let app = running.first(where: { $0.processIdentifier == pid }) { return app }
        }
        return running.first
    }

    /// The front window's visible tab; nil when the browser has no window open.
    static func frontTab(of app: NSRunningApplication) async throws(Failure) -> BrowserTab? {
        guard case let (bundleID, dialect)? = target(app) else { return nil }
        let tab = dialect == .safari ? "current tab" : "active tab"
        let title = dialect == .safari ? "name" : "title"
        let source = script(
            bundleID,
            """
            if (count of windows) is 0 then return {}
            tell front window to return {URL of \(tab), \(title) of \(tab)}
            """)
        let fields = try await run(source, browser: app.localizedName)
        guard let url = fields.first, !url.isEmpty else { return nil }
        return BrowserTab(url: url, title: fields.count > 1 ? fields[1] : "")
    }

    /// Selects the first tab showing `url` and raises its window; false when none matches.
    static func focusTab(matching url: String, in app: NSRunningApplication) async throws(Failure)
        -> Bool
    {
        guard case let (bundleID, dialect)? = target(app) else { return false }
        let name = app.localizedName
        let listing = script(
            bundleID,
            """
            set rows to {}
            repeat with windowIndex from 1 to count of windows
                repeat with tabIndex from 1 to count of tabs of window windowIndex
                    set end of rows to (windowIndex as text) & " " & (tabIndex as text) & " " & ¬
                        (URL of tab tabIndex of window windowIndex)
                end repeat
            end repeat
            return rows
            """)
        let rows = try await run(listing, browser: name)
        guard case let (window, tab)? = firstMatch(of: url, in: rows) else { return false }
        let focus = focusCommand(dialect, window: window, tab: tab)
        _ = try await run(script(bundleID, focus), browser: name)
        return true
    }

    private static func target(_ app: NSRunningApplication) -> (String, Dialect)? {
        guard !app.isTerminated, let bundleID = app.bundleIdentifier,
            let dialect = dialects[bundleID]
        else { return nil }
        return (bundleID, dialect)
    }

    /// Rows read `window tab url`, so the URL is everything after the second space.
    private static func firstMatch(of url: String, in rows: [String]) -> (Int, Int)? {
        let key = BrowserTab.matchKey(for: url)
        for row in rows {
            let parts = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let window = Int(parts[0]), let tab = Int(parts[1]),
                BrowserTab.matchKey(for: String(parts[2])) == key
            else { continue }
            return (window, tab)
        }
        return nil
    }

    private static func focusCommand(_ dialect: Dialect, window: Int, tab: Int) -> String {
        switch dialect {
        case .safari:
            """
            set current tab of window \(window) to tab \(tab) of window \(window)
            set index of window \(window) to 1
            activate
            """
        case .chromium:
            """
            set active tab index of window \(window) to \(tab)
            set index of window \(window) to 1
            activate
            """
        case .arc:
            """
            tell tab \(tab) of window \(window) to select
            activate
            """
        }
    }

    /// Addressed by bundle ID, which comes from the fixed table above and never from a page.
    private static func script(_ bundleID: String, _ body: String) -> String {
        """
        with timeout of \(timeoutSeconds) seconds
        tell application id "\(bundleID)"
        \(body)
        end tell
        end timeout
        """
    }

    /// A cold browser answers slowly, so the send never happens on the main actor.
    private static func run(_ source: String, browser: String?) async throws(Failure) -> [String] {
        let result = await Task.detached(priority: .userInitiated) {
            execute(source, browser: browser ?? "the browser")
        }.value
        return try result.get()
    }

    private nonisolated static func execute(
        _ source: String, browser: String
    ) -> Result<[String], Failure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(
                Failure(message: "The browser automation could not be prepared.",
                    needsAutomationPermission: false))
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success(strings(in: result)) }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -1743 {
            return .failure(
                Failure(
                    message:
                        "Allow Blitz to control \(browser) in Automation settings, then try again.",
                    needsAutomationPermission: true))
        }
        let detail = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown automation error."
        return .failure(Failure(message: detail, needsAutomationPermission: false))
    }

    /// A list flattens to its items; `missing value` (a blank tab) reads as an empty string.
    private nonisolated static func strings(in descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.descriptorType == typeAEList else {
            return [descriptor.stringValue ?? ""]
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).map {
            descriptor.atIndex($0)?.stringValue ?? ""
        }
    }
}
