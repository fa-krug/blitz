import Foundation
import OSLog

/// Reads the text of each capture in an idle lull, one bundled helper at a time.
@MainActor
final class ScreenshotIndexer {
    typealias Listing = @Sendable (URL) throws -> [ScreenshotFile]
    typealias Recognition = @Sendable (String) async throws -> String

    private let store: ScreenshotTextStore
    private let homeDirectory: URL
    private let canRun: () -> Bool
    private let list: Listing
    private let recognize: Recognition
    private let delay: Duration
    private let idleRecheck: Duration
    private var task: Task<Void, Never>?
    private var isEnabled = false
    private var rescanRequested = false
    /// Tried again on the next launch rather than retried in a loop inside this one.
    private var failed: Set<String> = []
    private static let logger = Logger(subsystem: "de.fa-krug.blitz", category: "ScreenshotText")

    init(
        store: ScreenshotTextStore, homeDirectory: URL, delay: Duration = .milliseconds(250),
        idleRecheck: Duration = .seconds(2), canRun: @escaping () -> Bool,
        list: @escaping Listing = ScreenshotService.listing,
        recognize: @escaping Recognition = ScreenshotService.recognize
    ) {
        self.store = store
        self.homeDirectory = homeDirectory
        self.delay = delay
        self.idleRecheck = idleRecheck
        self.canRun = canRun
        self.list = list
        self.recognize = recognize
    }

    isolated deinit {
        task?.cancel()
    }

    func start() {
        isEnabled = true
        schedule()
    }

    func stop() {
        isEnabled = false
        task?.cancel()
    }

    func waitUntilStopped() async {
        await task?.value
    }

    /// A pass already running finishes first; a request made meanwhile earns one more pass.
    func schedule() {
        guard isEnabled else { return }
        guard task == nil else {
            rescanRequested = true
            return
        }
        rescanRequested = false
        task = Task(priority: .background) { [weak self] in
            await self?.runPass()
            guard let self else { return }
            task = nil
            if rescanRequested { schedule() }
        }
    }

    private func runPass() async {
        let store = store
        let homeDirectory = homeDirectory
        let list = list
        let failed = failed
        let pending: [ScreenshotFile]
        do {
            pending = try await Task.detached(priority: .background) {
                let files = try list(homeDirectory)
                store.prune { !FileManager.default.fileExists(atPath: $0) }
                return ScreenshotFile.needingText(files, indexed: store.stamps(), skipping: failed)
            }.value
        } catch {
            Self.logger.error("Screenshot listing failed: \(String(describing: error), privacy: .public)")
            return
        }
        for file in pending {
            do { try await Task.sleep(for: delay) } catch { return }
            while isEnabled, !canRun() {
                do { try await Task.sleep(for: idleRecheck) } catch { return }
            }
            guard isEnabled, !Task.isCancelled else { return }
            guard await read(file) else { return }
        }
    }

    /// False only when cancelled; a failure is remembered and the pass moves on.
    private func read(_ file: ScreenshotFile) async -> Bool {
        let recognize = recognize
        let store = store
        let worker = Task.detached(priority: .background) { try await recognize(file.path) }
        do {
            let text = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            _ = await Task.detached(priority: .background) { store.record(file, text: text) }.value
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            Self.logger.error(
                "Screenshot text recognition failed: \(String(describing: error), privacy: .private)")
            failed.insert(file.path)
            return true
        }
    }
}
