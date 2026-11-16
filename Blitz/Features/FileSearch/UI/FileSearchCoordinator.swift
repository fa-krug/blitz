import AppKit

@MainActor
@Observable
final class FileSearchCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let windowController: PaletteWindowController
    private unowned let core: AppCore
    /// Hidden rather than unfavorited, so a remounted volume brings its favorites back.
    private var missingFavorites: Set<String> = []

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        windowController: PaletteWindowController, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.windowController = windowController
        self.core = core
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchFiles], settings.fileSearchEnabled)
        guard !settings.fileSearchEnabled else { return }
        session.cancel()
        if palette.mode == .fileSearch { palette.prepare(mode: .launcher) }
    }

    func applyPolicy() {
        session.apply(
            scopes: settings.fileSearchScopes,
            ignorePatterns: settings.fileSearchEffectiveIgnorePatterns)
    }

    /// `query` is the fallback row's: the screen opens already narrowed to what was typed.
    func show(query: String = "") {
        guard settings.fileSearchEnabled else { return }
        paletteCoordinator.togglePalette(mode: .fileSearch, seeding: query.isEmpty ? nil : query)
    }

    var favoriteFiles: [FileSearchResult] {
        guard settings.fileSearchEnabled else { return [] }
        return core.favorites.files(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .filter { !missingFavorites.contains($0.id) }
    }

    func isFavorite(_ result: FileSearchResult) -> Bool { core.favorites.isFavorite(result) }

    func toggleFavorite(_ result: FileSearchResult) {
        missingFavorites.remove(result.id)
        core.favorites.toggle(result)
    }

    /// Once per launcher show and off the main actor: a `fileExists` per render is too much.
    func refreshFavoriteAvailability() {
        guard settings.fileSearchEnabled else { return }
        let paths = core.favorites.files(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .map(\.id)
        guard !paths.isEmpty || !missingFavorites.isEmpty else { return }
        Task {
            let missing = await Task.detached(priority: .userInitiated) { Self.missing(paths) }.value
            if missing != missingFavorites { missingFavorites = missing }
        }
    }

    nonisolated private static func missing(_ paths: [String]) -> Set<String> {
        Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
    }

    func open(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    result.url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                await core.showNotice(
                    title: "Couldn’t Open \(result.name)",
                    message: error.localizedDescription,
                    symbol: result.isDirectory ? "folder" : "doc", tone: .danger)
            }
        }
    }

    func showInFinder(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(result.url)
    }

    func share(_ result: FileSearchResult) {
        guard let provider = NSItemProvider(contentsOf: result.url),
            let anchor = paletteCoordinator.anchorView
        else { return }
        SharePicker.show([provider], from: anchor)
    }

    func copyPath(_ result: FileSearchResult) {
        Paster.copyPlainText(result.id)
        core.showMessage("Copied path")
    }

    func copyName(_ result: FileSearchResult) {
        Paster.copyPlainText(result.name)
        core.showMessage("Copied name")
    }

    /// The file itself rather than its path, so Finder and Mail paste a copy of it.
    func copyFile(_ result: FileSearchResult) {
        PasteboardFiles.write(result.url, to: .general)
        core.showMessage("Copied file")
    }

    /// Into whichever app the palette was summoned over, which is what the row's title names.
    func pasteFile(_ result: FileSearchResult) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteFile(result.url, previousApp: previous)
    }

    /// `session` is the list the row came from; Search Screenshots keeps a session of its own.
    func trash(_ result: FileSearchResult, from session: FileSearchSession? = nil) {
        let session = session ?? self.session
        Task {
            do {
                let trashed = try await Task.detached(priority: .userInitiated) {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: result.url, resultingItemURL: &trashed)
                    return trashed as URL?
                }.value
                session.remove(result)
                missingFavorites.insert(result.id)
                guard let trashed else {
                    core.showMessage("Moved to Trash")
                    return
                }
                core.showBanner(
                    title: "Moved to Trash", detail: result.name, symbol: "trash",
                    actionTitle: "Undo"
                ) { [self] in restore(result, from: trashed, into: session) }
            } catch {
                await core.showNotice(
                    title: "Couldn’t Move \(result.name) to Trash",
                    message: error.localizedDescription,
                    symbol: "trash", tone: .danger)
            }
        }
    }

    private func restore(
        _ result: FileSearchResult, from trashed: URL, into session: FileSearchSession
    ) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.moveItem(at: trashed, to: result.url)
                }.value
                missingFavorites.remove(result.id)
                session.refresh()
            } catch {
                await core.showNotice(
                    title: "Couldn’t Put Back \(result.name)",
                    message: error.localizedDescription,
                    symbol: "trash", tone: .danger)
            }
        }
    }
}
