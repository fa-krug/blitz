import AppKit

@MainActor
@Observable
final class WindowSwitchSession {
    private(set) var snapshot: [WindowSwitchEntry] = []
    /// The rows the list reads: ranked once per query change, so one keystroke ranks once.
    private(set) var filtered: [WindowSwitchEntry] = []

    private var query = ""
    /// Live AX handles, so they are never observed and never outlive the show.
    @ObservationIgnored private var elements: [Int: WindowSwitchSweep.Element] = [:]
    /// Held only while rows are shown, so an app that quits takes its rows with it.
    @ObservationIgnored private var terminationObserver: NotificationToken?

    func present(_ snapshot: WindowSwitchSweep.Snapshot) {
        self.snapshot = WindowSwitchOrder.sorted(snapshot.entries)
        elements = snapshot.elements
        observeTerminations()
        applyQuery()
    }

    func element(for handle: Int) -> WindowSwitchSweep.Element? { elements[handle] }

    /// Settled in place, not re-swept: the app may still be animating or asking to save.
    func remove(_ handle: Int) {
        snapshot.removeAll { $0.handle == handle }
        elements[handle] = nil
        applyQuery()
    }

    func markMinimized(_ handle: Int) {
        guard let index = snapshot.firstIndex(where: { $0.handle == handle }) else { return }
        snapshot[index].isMinimized = true
        snapshot = WindowSwitchOrder.sorted(snapshot)
        applyQuery()
    }

    func reset() {
        terminationObserver = nil
        snapshot = []
        filtered = []
        elements = [:]
        query = ""
    }

    func filter(_ query: String) {
        self.query = query
        applyQuery()
    }

    private func observeTerminations() {
        guard terminationObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            // Delivered on the main queue, which `queue: .main` guarantees.
            MainActor.assumeIsolated { self?.removeWindows(of: pid) }
        }
        terminationObserver = NotificationToken(token, center: center)
    }

    private func removeWindows(of pid: pid_t) {
        let gone = Set(elements.compactMap { $0.value.app.processIdentifier == pid ? $0.key : nil })
        guard !gone.isEmpty else { return }
        for handle in gone { elements[handle] = nil }
        snapshot.removeAll { gone.contains($0.handle) }
        applyQuery()
    }

    private func applyQuery() {
        filtered = WindowSwitchQuery.rank(
            snapshot, for: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
