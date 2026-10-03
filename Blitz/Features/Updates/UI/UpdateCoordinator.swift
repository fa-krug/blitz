import AppKit
import Sparkle

/// Sparkle owns the check, the prompt, EdDSA verification, the install and the relaunch.
@MainActor
final class UpdateCoordinator {
    private static let feedTokenKey = "BlitzUpdateFeedToken"
    private static let firstCheckDelay = Duration.seconds(30)
    private static let checkInterval = Duration.seconds(24 * 60 * 60)
    private static let busyRetryInterval = Duration.seconds(2 * 60)

    /// Nil unless CI injected the token that unlocks the private zip; such a build never updates.
    private let updater: SUUpdater?
    /// Environment injection and activity reads only — never for state this type owns.
    private unowned let core: AppCore
    private var pump: Task<Void, Never>?

    init(core: AppCore) {
        self.core = core
        let token = Bundle.main.object(forInfoDictionaryKey: Self.feedTokenKey) as? String ?? ""
        guard !token.isEmpty, let shared = SUUpdater.shared() else {
            updater = nil
            return
        }
        // The appcast is public; the enclosure is the private repo's Contents API, hence the token.
        shared.httpHeaders = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github.raw",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        // The pump below schedules checks, so Sparkle's own timer can never prompt mid-task.
        shared.automaticallyChecksForUpdates = false
        shared.automaticallyDownloadsUpdates = false
        updater = shared
    }

    /// A build that cannot update itself does not advertise the command either.
    func applyEnabled() {
        core.appIndex.setCommandsVisible([.checkForUpdates], updater != nil)
    }

    /// Daily, and deferred while the user is mid-task: Sparkle's prompt would land on top of it.
    func start() {
        guard updater != nil, pump == nil else { return }
        pump = Task {
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                if core.canInterruptUser {
                    updater?.checkForUpdatesInBackground()
                    try? await Task.sleep(for: Self.checkInterval)
                } else {
                    try? await Task.sleep(for: Self.busyRetryInterval)
                }
            }
        }
    }

    func checkForUpdates() {
        guard let updater else {
            Task {
                await core.showNotice(
                    title: "Updates Unavailable",
                    message: "Only builds published by the release workflow update themselves.",
                    symbol: "arrow.down.circle", tone: .neutral)
            }
            return
        }
        updater.checkForUpdates(nil)
    }
}
