import SwiftUI

/// Settings' lifecycle, independent of the palette: neither surface opens or closes the other.
@MainActor
final class SettingsCoordinator {
    private lazy var window = AppWindowController(
        title: "Settings", contentSize: Theme.Size.settingsWindow, resizable: true,
        autosaveName: "SettingsWindow", activation: core.activationPolicy,
        keepsContentWhenClosed: true,
        // Hidden, not torn down, so an open editor panel would otherwise outlive the window.
        onClose: { [weak self] in self?.editorPresenter?.dismissAll() })
    /// Environment injection only — never for state this type owns.
    private unowned let core: AppCore
    /// The open window's session; the window's chrome and view tree own it, so this self-nils.
    private weak var navigation: SettingsNavigationState?
    /// The same session owns its transient editor stack; no panel survives the Settings window.
    private weak var editorPresenter: SettingsEditorPresenter?

    init(core: AppCore) {
        self.core = core
    }

    /// Mounts or navigates to `tab`, into history; nil keeps the last pane, even after a close.
    func showSettings(
        tab: SettingsTab? = nil, page: String? = nil, revealing target: SettingsTarget? = nil
    ) {
        if window.focus() {
            if let tab { navigation?.select(tab, page: page, revealing: target) }
            return
        }
        if let navigation, window.reopen() {
            navigation.restart(on: tab ?? navigation.tab, page: page, revealing: target)
            return
        }
        let navigation = SettingsNavigationState(tab: tab ?? .general)
        navigation.select(navigation.tab, page: page, revealing: target)
        let editorPresenter = SettingsEditorPresenter(core: core, navigation: navigation)
        self.navigation = navigation
        self.editorPresenter = editorPresenter
        let hosting = NSHostingController(
            rootView: SettingsRootView().settingsEnvironment(
                core: core, navigation: navigation, editorPresenter: editorPresenter))
        // Keep the window's size authoritative: an unconstrained fill would drive the frame.
        hosting.sizingOptions = []
        // The back/forward chevrons, the pane title and the sidebar's search field all ride on it.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.show(chrome: SettingsWindowChrome()) { hosting }
        editorPresenter.attach(to: hosting.view.window)
    }

    func showAbout() {
        showSettings(tab: .about)
    }

    func showBackupSettings() {
        showSettings(tab: .backup)
    }

    /// ⌘Q and the window's close button land here; the app itself keeps running.
    func closeSettings() {
        editorPresenter?.dismissAll()
        window.close()
    }

    func focusExisting() -> Bool {
        window.focus()
    }
}
