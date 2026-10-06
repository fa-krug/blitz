import Foundation

/// When the background extension update runs, and which extensions it may replace this time.
enum ExtensionUpdatePolicy {
    static let checkInterval: TimeInterval = 24 * 3600
    /// Shorter, so an offline launch or a deferred extension is picked up the same day.
    static let retryInterval: TimeInterval = 2 * 3600

    /// Measured from the last answered check, so relaunching never re-asks the store.
    static func isDue(lastCheckedAt: Date?, now: Date) -> Bool {
        remaining(since: lastCheckedAt, now: now) <= 0
    }

    /// A check that went unanswered leaves the stamp alone, so the retry interval governs it.
    static func nextWait(lastCheckedAt: Date?, now: Date, hasDeferred: Bool) -> TimeInterval {
        let remaining = remaining(since: lastCheckedAt, now: now)
        let wait = remaining > 0 ? remaining : retryInterval
        return hasDeferred ? min(wait, retryInterval) : wait
    }

    /// Replacing the folder a live command or menu run is reading from would pull it from under it.
    static func partition(
        _ names: [String], busy: Set<String>
    ) -> (ready: [String], deferred: [String]) {
        (names.filter { !busy.contains($0) }, names.filter { busy.contains($0) })
    }

    /// What one run did, and the one line a HUD says about it.
    struct Outcome: Equatable, Sendable {
        var answered = false
        var available = 0
        var updated = 0
        /// Titles, so the line can name them.
        var failed: [String] = []
        /// Manifest names, held back because something was using them.
        var deferred: [String] = []

        var isFailure: Bool { !failed.isEmpty || (!answered && updated == 0) }

        /// `installing` is false when only a check was asked for, so pending updates are offered.
        func summary(installing: Bool) -> String {
            if !failed.isEmpty {
                let names = failed.joined(separator: ", ")
                guard updated > 0 else { return "Couldn't update \(names)" }
                return "Updated \(Self.extensions(updated)); couldn't update \(names)"
            }
            if updated > 0 { return "Updated \(Self.extensions(updated))" }
            if !answered { return "Couldn't reach the Raycast Store" }
            if !deferred.isEmpty {
                let subject = deferred.count == 1 ? "1 extension is" : "\(deferred.count) extensions are"
                return "\(subject) in use and will update later"
            }
            if !installing, available > 0 {
                return available == 1
                    ? "1 extension update available" : "\(available) extension updates available"
            }
            return "Extensions are up to date"
        }

        private static func extensions(_ count: Int) -> String {
            count == 1 ? "1 extension" : "\(count) extensions"
        }
    }

    private static func remaining(since lastCheckedAt: Date?, now: Date) -> TimeInterval {
        // Clamped, so a future-stamped check can't park the loop past one interval.
        let age = max(0, lastCheckedAt.map { now.timeIntervalSince($0) } ?? .infinity)
        return checkInterval - age
    }
}
