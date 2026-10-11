import AppKit
import SwiftUI

/// Owns the standalone camera surface: one panel at a time, and the camera stops with it.
@MainActor
@Observable
final class CameraCoordinator {
    /// What the open panel is for: a photo to the clipboard, or reading a QR code.
    enum Mode {
        case photo
        case scan
    }

    /// A read payload, and the URL it opens when some app on this Mac handles its scheme.
    struct ScannedCode: Equatable {
        let payload: String
        let url: URL?
    }

    private(set) var mode = Mode.photo
    private(set) var feed: CameraSession.Feed = .noCamera
    private(set) var canSwitchCamera = false
    private(set) var scanned: ScannedCode?
    /// Remembered for the launch, so reopening the command keeps the framing you were happy with.
    var mirrored = true

    @ObservationIgnored private let photoSession = CameraSession(.capture)
    @ObservationIgnored private let scanSession = CameraSession(.scan)
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var panel: CameraPanel?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Held across the camera warm-up too, so a chord repeating into it cannot stack panels.
    @ObservationIgnored private var opening = false

    init(core: AppCore) {
        self.core = core
    }

    private var session: CameraSession {
        mode == .photo ? photoSession : scanSession
    }

    /// The camera settles first: a panel over a starting session shows a black stage.
    func show(_ mode: Mode = .photo) async {
        // A panel system UI left without key takes it back, so ↵ and Esc reach it again.
        if let panel {
            panel.makeKey()
            return
        }
        guard !opening else { return }
        opening = true
        defer { opening = false }
        self.mode = mode
        scanned = nil
        feed = await session.start()
        canSwitchCamera = session.hasMultipleDevices
        if mode == .scan { watchForCodes() }
        present()
    }

    func close() {
        guard let closing = panel else { return }
        panel = nil
        closing.onAction = nil
        scanTask?.cancel()
        scanTask = nil
        let closingSession = session
        // The camera goes with the panel, not before it: tearing it down mid-fade blanks the feed.
        closing.fadeOut(duration: Theme.Duration.exit) { [weak self] in
            // Unless a panel raised inside the fade already owns this camera.
            guard let self, !(session === closingSession && (opening || panel != nil)) else {
                return
            }
            closingSession.stop()
        }
    }

    func switchCamera() {
        Task { await session.switchToNextDevice() }
    }

    /// The panel goes with the shot: the command is done, and the camera light goes out with it.
    func takePhoto() {
        guard mode == .photo, case .live = feed else { return }
        let mirrored = mirrored
        Task {
            let png = await photoSession.capturePhoto(mirrored: mirrored)
            close()
            guard let png else {
                core.showMessage("Couldn't take the photo", tone: .danger)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            core.showMessage("Photo copied")
        }
    }

    func copyScanned() {
        guard let scanned else { return }
        close()
        Paster.copyPlainText(scanned.payload)
        core.showMessage("Copied")
    }

    func openScanned() {
        guard let url = scanned?.url else { return }
        close()
        if !NSWorkspace.shared.open(url) {
            core.showMessage("Couldn't open the link", tone: .danger)
        }
    }

    /// ↵ opens a link and copies anything else, the one action every payload has.
    private func activateScanned() {
        guard let scanned else { return }
        if scanned.url != nil { openScanned() } else { copyScanned() }
    }

    /// The newest code wins, so re-aiming at another one needs no reopen.
    private func watchForCodes() {
        guard let codes = scanSession.codes() else { return }
        scanTask = Task { [weak self] in
            for await payload in codes {
                guard let self else { return }
                guard scanned?.payload != payload else { continue }
                scanned = ScannedCode(payload: payload, url: Self.openableURL(payload))
            }
        }
    }

    /// Only a scheme some app claims becomes Open: `WIFI:` parses as a URL but nothing opens it.
    private static func openableURL(_ payload: String) -> URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme != nil, NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        else { return nil }
        return url
    }

    private func present() {
        let hosting = NSHostingView(rootView: CameraView(coordinator: self))
        hosting.setFrameSize(hosting.fittingSize)
        let panel = CameraPanel(content: hosting)
        panel.onAction = { [weak self] action in
            guard let self else { return }
            switch (action, mode) {
            case (.cancel, _): close()
            case (.primary, .photo): takePhoto()
            case (.primary, .scan): activateScanned()
            }
        }
        self.panel = panel
        panel.centerOnCursorScreen()
        // Non-activating like the palette: key focus without pulling the user out of their app.
        panel.fadeIn(duration: Theme.Duration.enter) {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }
}
