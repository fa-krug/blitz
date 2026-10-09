import AppKit

@MainActor
final class ScreenshotCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let textStore: ScreenshotTextStore
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private var textTask: Task<Void, Never>?
    private unowned let core: AppCore

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        textStore: ScreenshotTextStore, palette: PaletteState,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.textStore = textStore
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchScreenshots], settings.screenshotSearchEnabled)
        core.applyScreenshotTextSearch()
        guard !settings.screenshotSearchEnabled else { return }
        session.cancel()
        if palette.mode == .screenshots { palette.prepare(mode: .launcher) }
    }

    func show() {
        guard settings.screenshotSearchEnabled else { return }
        paletteCoordinator.togglePalette(mode: .screenshots)
    }

    func trash(_ result: FileSearchResult) {
        core.fileSearchCoordinator.trash(result, from: session)
    }

    /// The indexed text when it was read from the file as it is now, otherwise a fresh read.
    func copyText(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showProgress("Reading text…")
        let changeCount = NSPasteboard.general.changeCount
        let store = settings.screenshotTextSearchEnabled ? textStore : nil
        let path = result.id
        textTask?.cancel()
        textTask = Task {
            do {
                // A stat on an unmounted or network volume can stall, so it stays off main.
                let lookup = await Task.detached { () -> (exists: Bool, text: String?) in
                    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                        .contentModificationDateKey
                    ])
                    guard let modified = values?.contentModificationDate else { return (false, nil) }
                    let stamp = modified.timeIntervalSinceReferenceDate
                    return (true, store?.text(at: path, modified: stamp))
                }.value
                try Task.checkCancellation()
                guard lookup.exists else {
                    return core.showMessage("That screenshot is no longer available.", tone: .danger)
                }
                let text: String
                if let indexed = lookup.text {
                    text = indexed
                } else {
                    text = try await ScreenshotService.recognize(path)
                }
                guard !text.isEmpty else { return core.showMessage("No text found", tone: .neutral) }
                guard NSPasteboard.general.changeCount == changeCount else {
                    return core.showMessage("Clipboard changed, text not copied", tone: .neutral)
                }
                Paster.copyPlainText(text)
                core.showMessage("Copied text")
            } catch is CancellationError {
            } catch {
                core.showMessage("Couldn’t read the text", tone: .danger)
            }
        }
    }
}
