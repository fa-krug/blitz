import AppKit

enum AppLauncher {

    /// Throws what Launch Services refused, so a caller whose palette already hid can say why.
    @MainActor
    static func launch(_ url: URL, allowsRunningApplicationSubstitution: Bool = true) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = allowsRunningApplicationSubstitution
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Hands the URL to whatever the system registers for its scheme, e.g. the default browser.
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        bringFileViewerForwardIfRefused()
    }

    /// While `.regular` and inactive, cooperative activation refuses the viewer's own activation.
    @MainActor
    private static func bringFileViewerForwardIfRefused() {
        guard NSApp.activationPolicy() == .regular, !NSApp.isActive,
            let viewer = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: fileViewerBundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: viewer, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The global `NSFileViewer` default is how a replacement file viewer takes over reveals.
    private static var fileViewerBundleID: String {
        UserDefaults.standard.string(forKey: "NSFileViewer") ?? "com.apple.finder"
    }

    /// No AppKit route for Get Info, so this drives Finder over Apple events — seconds when cold.
    static func showInfoInFinder(_ url: URL) async -> Bool {
        let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(url.path)" as alias)
            end tell
            """
        return await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return false }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            return errorInfo == nil
        }.value
    }

    /// Opens System Settings at the pane backed by the given extension bundle ID.
    @MainActor
    @discardableResult
    static func openSettingsPane(bundleID: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:" + bundleID) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Focus the app if it isn't frontmost, hide it if it is, launch it if it isn't running.
    @MainActor
    static func toggle(bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first
        if let running, running.isActive {
            running.hide()
            return
        }
        if let url = running?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            // Dock-click semantics; a bare `activate()` does none of it reliably.
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let running {
            // Running app whose bundle URL can't be resolved (moved or deleted since launch).
            running.unhide()
            running.activate()
        }
    }

    /// A nil `url` quits every instance; only an unforced quit lets unsaved work put up its sheet.
    @MainActor
    @discardableResult
    static func quit(bundleID: String, url: URL? = nil, force: Bool = false) -> Bool {
        let running = runningApplications(bundleID: bundleID, at: url)
        for app in running {
            if force { app.forceTerminate() } else { app.terminate() }
        }
        return !running.isEmpty
    }

    /// Long enough for any app to exit, short enough not to relaunch under the user.
    private static let exitGrace = Duration.seconds(5)

    /// A refused quit — a save sheet left standing — relaunches nothing.
    @MainActor
    static func restart(bundleID: String, url: URL) async {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        let running = runningApplications(bundleID: bundleID, at: target)
        guard !running.isEmpty, !Task.isCancelled, await quitAwaitingExit(running), !Task.isCancelled
        else { return }
        try? await launch(target, allowsRunningApplicationSubstitution: false)
    }

    /// True once nothing from that bundle at that path is left running, including nothing at all.
    @MainActor
    static func quitAwaitingExit(bundleID: String, url: URL) async -> Bool {
        await quitAwaitingExit(runningApplications(bundleID: bundleID, at: url))
    }

    /// Another installed copy shares the bundle ID, so only the bundle's own path names an instance.
    @MainActor
    private static func runningApplications(bundleID: String, at url: URL?) -> [NSRunningApplication] {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let target = url?.resolvingSymlinksInPath().standardizedFileURL else { return running }
        return running.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target }
    }

    /// Polls rather than observes: workspace exit notifications skip background and menu-bar apps.
    @MainActor
    private static func quitAwaitingExit(_ apps: [NSRunningApplication]) async -> Bool {
        guard !Task.isCancelled else { return false }
        for app in apps { app.terminate() }

        let deadline = ContinuousClock.now + exitGrace
        while apps.contains(where: { !$0.isTerminated }) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    /// Finder is never a Quit All target: `terminate()` only makes it relaunch.
    private static let quitAllExclusions: Set<String> = ["com.apple.finder"]

    /// Every app with a Dock presence, bar Finder and us; resolved once, so it can't drift.
    @MainActor
    static func quitAllTargets() -> [NSRunningApplication] {
        // By PID, not policy: About/Settings flips us to `.regular` temporarily.
        let ownPID = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.processIdentifier != ownPID
                && !quitAllExclusions.contains(app.bundleIdentifier ?? "")
        }
    }
}
