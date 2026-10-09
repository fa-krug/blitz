import AppKit

/// The one funnel from a palette row or a global hotkey to the mover.
@MainActor
final class WindowCommandCoordinator {
    private let settings: AppSettings
    private let paletteCoordinator: PaletteCoordinator
    private let windowMover: WindowMover
    private let spaceSwitcher: SpaceSwitcher
    private let customSizes: CustomWindowSizeStore
    private unowned let core: AppCore

    init(
        settings: AppSettings, paletteCoordinator: PaletteCoordinator, windowMover: WindowMover,
        spaceSwitcher: SpaceSwitcher, customSizes: CustomWindowSizeStore, core: AppCore
    ) {
        self.settings = settings
        self.paletteCoordinator = paletteCoordinator
        self.windowMover = windowMover
        self.spaceSwitcher = spaceSwitcher
        self.customSizes = customSizes
        self.core = core
    }

    /// The one funnel for palette and hotkey alike. See docs/features/window-management.md#wiring.
    func runWindowCommand(id: WindowCommand.ID) {
        guard settings.windowManagementEnabled else { return }
        if let direction = SpaceDirection(id) {
            // Restoring focus reactivates an app elsewhere, pulling its Space forward.
            if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
            spaceSwitcher.perform(direction)
            return
        }
        report(
            windowMover.perform(
                id, target: handOffTarget(), gap: CGFloat(settings.windowGap),
                cycle: settings.windowCycle))
    }

    /// The same funnel for a custom size, so the feature switch gates it identically.
    func runCustomWindowSize(id: UUID) {
        guard settings.windowManagementEnabled, let size = customSizes.size(id: id) else { return }
        report(windowMover.perform(size, target: handOffTarget(), gap: CGFloat(settings.windowGap)))
    }

    /// A refused press would otherwise read as a dead shortcut; an unchanged one reads right.
    private func report(_ outcome: WindowMover.Outcome) {
        let message: String
        switch outcome {
        case .changed, .unchanged, .needsAccessibility: return
        case .noWindow: message = "No window to move"
        case .notMovable: message = "This window can't be moved"
        case .fullScreen: message = "Exit full screen to move this window"
        case .fullScreenRefused: message = "This window can't go full screen"
        }
        core.showMessage(message, tone: .neutral)
    }

    /// The window to place, read before the palette hides and hands focus back to it.
    private func handOffTarget() -> WindowTarget? {
        guard paletteCoordinator.isVisible else { return WindowTarget.current() }
        let target = WindowTarget.behindPalette(
            ownWindow: paletteCoordinator.previousOwnWindow, app: paletteCoordinator.targetApp)
        paletteCoordinator.hidePalette(restoreFocus: true)
        return target
    }
}
