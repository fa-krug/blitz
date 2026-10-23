import AppKit

@MainActor
final class ClipboardManager {
    /// Marker we attach to the pasteboard when *we* write to it, so polling ignores our own pastes.
    static let internalType = NSPasteboard.PasteboardType("de.fa-krug.blitz.internal")

    /// Longest text captured; bigger copies are skipped, truncation losing the tail.
    static let maxTextLength = 32_000

    /// Markers put on secret copies by password managers, browsers and the OS.
    static let sensitiveTypes = Set(
        PasteboardSensitivity.markerTypes.map { NSPasteboard.PasteboardType($0) })

    private let store: ClipboardStore
    private let settings: AppSettings
    private var timer: Timer?
    private var sessionTokens: [NotificationToken] = []
    private var lastChangeCount = 0
    /// The last copy, app switch or summon, which keeps the poll on its fast tier.
    private var lastActivity = ContinuousClock.now
    private var screensAsleep = false
    /// The app in front until the latest switch; by the time a switch is reported, the new one is.
    private var frontmostBundleID: String?
    private var isCapturing = false
    private var isCapturePaused = false

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // Isolated so teardown can touch the main-actor timer; the poll block is already weak.
    isolated deinit {
        timer?.invalidate()
    }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        installObservers()
        startPolling()
    }

    /// Turning the feature off: the poller, the observers and the drain all go with it.
    func stop() {
        isCapturing = false
        sessionTokens = []
        stopPolling()
    }

    /// The poll's three tiers, by how long since anything suggested a copy might be coming.
    nonisolated static func pollInterval(
        sinceActivity elapsed: Duration, screensAsleep: Bool
    ) -> TimeInterval {
        if screensAsleep { return asleepInterval }
        return elapsed < activeWindow ? activeInterval : quietInterval
    }

    nonisolated static let activeInterval: TimeInterval = 0.5
    nonisolated static let quietInterval: TimeInterval = 2
    nonisolated static let asleepInterval: TimeInterval = 15
    nonisolated static let activeWindow = Duration.seconds(30)

    /// A summon reads the board at once, so a copy made on the slow tier is already listed.
    func paletteDidShow() {
        guard isCapturing else { return }
        poll()
        noteActivity()
    }

    // Every observer is on `.main`, which is what each `assumeIsolated` below relies on.
    private func installObservers() {
        guard sessionTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                    queue: .main
                ) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let bundleID = app?.bundleIdentifier
                    MainActor.assumeIsolated { self?.frontmostDidChange(to: bundleID) }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screensDidSleep(true) }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screensDidSleep(false) }
                }, center: center),
            // Fast user switching: another session's clipboard isn't ours, so stop waking for it.
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopPolling() }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startPolling() }
                }, center: center)
        ]
    }

    // Drained under the app that held the board, so a disabled app's copy can't leak on a switch.
    private func frontmostDidChange(to bundleID: String?) {
        if timer != nil { poll(attributingTo: frontmostBundleID) }
        frontmostBundleID = bundleID
        noteActivity()
    }

    private func screensDidSleep(_ asleep: Bool) {
        screensAsleep = asleep
        if !asleep, timer != nil { poll() }
        noteActivity()
    }

    private func noteActivity() {
        lastActivity = .now
        reschedule()
    }

    // Re-baselining first is what stops a clip made in another session reading as new on resume.
    private func startPolling() {
        guard isCapturing, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lastActivity = .now
        schedule(every: Self.activeInterval)
    }

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        poll()
        reschedule()
    }

    /// Only while polling: a stopped poller stays stopped whatever the board or the screens do.
    private func reschedule() {
        guard let timer else { return }
        let interval = Self.pollInterval(
            sinceActivity: .now - lastActivity, screensAsleep: screensAsleep)
        if timer.timeInterval != interval { schedule(every: interval) }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // Drain first: the real copy must reach history before we overwrite the pasteboard.
    func prepareForBlitzPasteboardMutation() {
        guard isCapturing else { return }
        poll()
    }

    /// For a ⌘C Blitz sends itself, whose copy is read and restored but never recorded.
    func pauseCapture() {
        prepareForBlitzPasteboardMutation()
        isCapturePaused = true
    }

    func resumeCapture() {
        isCapturePaused = false
    }

    // Load-bearing: a mismatched count means a foreign write the next poll must still see.
    func synchronizeAfterBlitzPasteboardMutation(changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        lastChangeCount = changeCount
    }

    /// A Finder select-all must not insert ten thousand rows on one poll tick.
    nonisolated static let maxCapturedFiles = 32

    /// Reclaimable roots, without the `/private` that `resolvingSymlinksInPath` strips.
    nonisolated static let volatileRoots = [
        "/tmp/", "/var/tmp/", "/var/folders/", NSHomeDirectory() + "/Library/Caches/"
    ]

    /// Both parameters are injected environment facts, so a harness can drive its own scratch.
    nonisolated static func fileURLs(
        on pasteboard: NSPasteboard, volatileRoots roots: [String] = volatileRoots
    ) -> [String]? {
        let durable = PasteboardFiles.urls(on: pasteboard, limit: maxCapturedFiles) {
            isDurable($0, roots: roots)
        }
        // Nil rather than empty, so a copied `http` URL falls through and stays a link.
        guard !durable.isEmpty else { return nil }
        // Reversed on insert, so the first file copied ends up leading the history.
        return durable.map(\.standardizedFileURL.path).reversed()
    }

    /// The styled flavours beside a text copy; one past `ClipboardRichFormat.maxBytes` is dropped.
    nonisolated static func richFormats(on pasteboard: NSPasteboard) -> [ClipboardRichFormat: Data] {
        var formats: [ClipboardRichFormat: Data] = [:]
        for format in ClipboardRichFormat.allCases {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(format.rawValue)),
                !data.isEmpty, data.count <= ClipboardRichFormat.maxBytes
            else { continue }
            formats[format] = data
        }
        return formats
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    nonisolated private static func isDurable(_ url: URL, roots: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var path = url.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return !roots.contains { path.hasPrefix($0) }
    }

    /// `previousApp` is the app a switch just left; otherwise the frontmost app owns the copy.
    private func poll(attributingTo previousApp: String? = nil) {
        let pb = NSPasteboard.general
        guard !isCapturePaused, pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        lastActivity = .now

        if pb.types?.contains(Self.internalType) == true { return }

        // Never record secrets: skip copies tagged sensitive by any of the marker owners.
        if let types = pb.types, !Set(types).isDisjoint(with: Self.sensitiveTypes) { return }

        // The pasteboard carries no source, so attribute it to the frontmost app.
        let sourceBundleID = previousApp ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceBundleID, settings.clipboardDisabledApps.contains(sourceBundleID) { return }

        // Ahead of the text branch: Finder puts the file's *name* on `.string` beside its URL.
        if let paths = Self.fileURLs(on: pb) {
            store.addFiles(paths, sourceBundleID: sourceBundleID)
            return
        }

        if let text = pb.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard text.count <= Self.maxTextLength else { return }
            let formats = Self.richFormats(on: pb)
            guard !formats.isEmpty else {
                store.addText(text, sourceBundleID: sourceBundleID)
                return
            }
            let store = store
            let directory = store.formatsDirectory
            // Like an image's PNG, the flavour files are written off the poll.
            Task.detached(priority: .utility) {
                let written = ClipboardStore.writeFormats(formats, into: directory)
                await store.addText(text, sourceBundleID: sourceBundleID, formats: written)
            }
            return
        }

        if let type = pb.availableType(from: [.png, .tiff]), let data = pb.data(forType: type) {
            let isPNG = type == .png
            let store = store
            // A big TIFF→PNG re-encode can take 100ms+, so keep the poll off that path.
            Task.detached(priority: .utility) {
                let png =
                    isPNG
                    ? data
                    : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                guard let png else { return }
                await store.addImage(png, sourceBundleID: sourceBundleID)
            }
        }
    }
}
