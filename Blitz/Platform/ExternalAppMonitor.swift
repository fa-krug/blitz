import AppKit

/// The app the user was in before Blitz took the front, for anything that reads "their" app.
@MainActor
final class ExternalAppMonitor {
    private var last: NSRunningApplication?
    private var observer: NotificationToken?

    /// Frontmost when that is not Blitz, else the last other app to be; nil once it quit.
    var app: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isOwn(front) { return front }
        guard let last, !last.isTerminated else { return nil }
        return last
    }

    func start() {
        guard observer == nil else { return }
        record(NSWorkspace.shared.frontmostApplication)
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            // Delivered on the main queue, which `queue: .main` guarantees.
            MainActor.assumeIsolated { self?.record(app) }
        }
        observer = NotificationToken(token, center: center)
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app, !Self.isOwn(app) else { return }
        last = app
    }

    private static func isOwn(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == NSRunningApplication.current.processIdentifier
    }
}
