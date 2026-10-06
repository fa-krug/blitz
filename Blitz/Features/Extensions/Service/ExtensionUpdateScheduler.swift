import Foundation

/// The daily store check for extensions, and the updates it installs while nothing is using them.
@MainActor
final class ExtensionUpdateScheduler {
    typealias Outcome = ExtensionUpdatePolicy.Outcome

    /// Keeps the first check clear of the login rush, and of the extension scan it waits on.
    private static let startupDelay = Duration.seconds(60)

    /// A background run that installed or failed something; a quiet one says nothing.
    var onReport: ((Outcome) -> Void)?

    private let extensions: ExtensionManager
    private let fileURL: URL
    private var lastCheckedAt: Date?
    private var pump: Task<Void, Never>?
    private var isRunning = false

    init(
        extensions: ExtensionManager,
        fileURL: URL = AppPaths.caches().appendingPathComponent("extension-update-check.json")
    ) {
        self.extensions = extensions
        self.fileURL = fileURL
        lastCheckedAt = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }?.lastCheckedAt
    }

    deinit { pump?.cancel() }

    /// Replaces rather than bails: an exited loop leaves a non-nil task that would block a restart.
    func start() {
        pump?.cancel()
        pump = Task { [weak self] in
            try? await Task.sleep(for: Self.startupDelay)
            while !Task.isCancelled {
                // Optional-chained: the sleep must not retain the scheduler.
                guard let wait = await self?.advance() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    /// The command's path: always asks the store, and installs only when told to.
    func checkNow(installing: Bool) async -> Outcome {
        await run(checking: true, installing: installing)
    }

    /// Checks when due, installs whatever is pending, and answers how long to sleep.
    private func advance() async -> TimeInterval {
        let due = ExtensionUpdatePolicy.isDue(lastCheckedAt: lastCheckedAt, now: Date())
        let outcome = await run(checking: due, installing: true)
        if outcome.updated > 0 || !outcome.failed.isEmpty { onReport?(outcome) }
        return ExtensionUpdatePolicy.nextWait(
            lastCheckedAt: lastCheckedAt, now: Date(), hasDeferred: !outcome.deferred.isEmpty)
    }

    private func run(checking: Bool, installing: Bool) async -> Outcome {
        guard !isRunning, extensions.isEnabled else { return Outcome() }
        isRunning = true
        defer { isRunning = false }
        var outcome = Outcome()
        if checking {
            outcome.answered = await extensions.checkForUpdates()
            if outcome.answered {
                lastCheckedAt = Date()
                persist()
            }
        }
        let pending = extensions.updates.keys.sorted()
        outcome.available = pending.count
        guard installing, !pending.isEmpty else { return outcome }
        let (ready, deferred) = ExtensionUpdatePolicy.partition(
            pending, busy: Set(pending.filter(extensions.isBusy)))
        outcome.deferred = deferred
        guard !ready.isEmpty else { return outcome }
        outcome.failed = await extensions.update(ready)
        outcome.updated = ready.count - outcome.failed.count
        return outcome
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Cache(lastCheckedAt: lastCheckedAt)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Cache: Codable {
        var lastCheckedAt: Date?
    }
}
