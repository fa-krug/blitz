import AppKit

/// Opens a resolved destination; every platform effect the feature has lives here.
@MainActor
enum QuicklinkLauncher {
    enum Failure: LocalizedError, Equatable {
        case unresolvable(String)
        case missingFile(String)
        case missingApplication(String)
        case openFailed(target: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .unresolvable(let link):
                return "“\(link)” isn't a URL, file path, or deeplink."
            case .missingFile(let path):
                return "Nothing exists at \(path) any more."
            case .missingApplication:
                return "The app this quicklink opens with isn't installed any more."
            case .openFailed(let target, let detail):
                return "macOS could not open \(target).\n\n\(detail)"
            }
        }

        /// A missing handler is the one failure with a usable second option — the system default.
        var missingApplicationBundleID: String? {
            if case .missingApplication(let bundleID) = self { return bundleID }
            return nil
        }
    }

    /// Chromium and Firefox accept this, Safari ignores it, so passing it always is safe.
    private static let newWindowArgument = "--new-window"

    /// What an open did; a refused tab lookup still opened, but the caller should say why.
    enum Outcome {
        case opened
        case focusedExistingTab
        case openedWithoutTabLookup(BrowserTabs.Failure)
    }

    /// `openWithBundleID` nil means the system default handler.
    @discardableResult
    static func open(
        _ link: String, openWithBundleID: String?, inNewWindow: Bool, prefersExistingTab: Bool
    ) async throws(Failure) -> Outcome {
        guard let destination = QuicklinkDestination.detect(link) else {
            throw .unresolvable(link)
        }
        let url: URL
        switch destination {
        case .web(let value), .network(let value), .deeplink(let value):
            url = value
        case .path(let path):
            // Checked first so a deleted folder names itself instead of failing as a silent no-op.
            guard FileManager.default.fileExists(atPath: path) else { throw .missingFile(path) }
            url = URL(fileURLWithPath: path)
        }

        var application: URL?
        if let openWithBundleID {
            application = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: openWithBundleID)
            guard application != nil else { throw .missingApplication(openWithBundleID) }
        }

        var refusal: BrowserTabs.Failure?
        if prefersExistingTab, case .web = destination,
            let browser = runningBrowser(handling: url, application: application)
        {
            do throws(BrowserTabs.Failure) {
                if try await BrowserTabs.focusTab(matching: url.absoluteString, in: browser) {
                    return .focusedExistingTab
                }
            } catch {
                // Anything but a refusal is a browser that couldn't answer, so it just opens.
                if error.needsAutomationPermission { refusal = error }
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        if inNewWindow { configuration.arguments = [newWindowArgument] }
        do {
            if let application {
                _ = try await NSWorkspace.shared.open(
                    [url], withApplicationAt: application, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            }
        } catch {
            throw .openFailed(
                target: destination.displayText, detail: error.localizedDescription)
        }
        return refusal.map(Outcome.openedWithoutTabLookup) ?? .opened
    }

    /// The browser the link would open in, if it is one Blitz can script and it is already running.
    private static func runningBrowser(
        handling url: URL, application: URL?
    ) -> NSRunningApplication? {
        guard let handler = application ?? NSWorkspace.shared.urlForApplication(toOpen: url),
            let bundleID = Bundle(url: handler)?.bundleIdentifier,
            BrowserTabs.isSupported(bundleID: bundleID)
        else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }
}
