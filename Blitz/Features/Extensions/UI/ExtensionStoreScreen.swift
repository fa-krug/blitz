import SwiftUI

/// The Raycast Store, searched from the palette: ↵ installs a result, or opens one already here.
struct ExtensionStoreScreen: PaletteScreen {
    let session: ExtensionStoreSession
    let extensions: ExtensionManager
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var rows: [ExtensionListing] { term.isEmpty ? [] : session.results }

    var primaryActionTitle: String {
        listing(at: vm.selection).flatMap(installed) == nil ? "Install Extension" : "Configure Extension"
    }

    private func listing(at selection: Int) -> ExtensionListing? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Keyed by manifest name, which is what the store listing and an install share.
    private func installed(_ listing: ExtensionListing) -> InstalledExtension? {
        extensions.installed.first { $0.manifest.name == listing.name }
    }

    func hasPrimaryAction(at selection: Int) -> Bool {
        guard let listing = listing(at: selection) else { return false }
        return !session.isInstalling(listing)
    }

    func hasActions(at selection: Int) -> Bool { actions(at: selection) != nil }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let listing = listing(at: selection) else { return nil }
        var items: [PopoverMenuItem] = []
        if let owner = installed(listing) {
            items.append(
                PopoverMenuItem(
                    title: "Configure Extension", systemImage: "slider.horizontal.3", shortcut: "↵"
                ) {
                    core.extensionCoordinator.showExtensionSettings(for: owner)
                })
        }
        if !session.isInstalling(listing) {
            let isInstalled = installed(listing) != nil
            items.append(
                PopoverMenuItem(
                    title: isInstalled ? "Reinstall Extension" : "Install Extension",
                    systemImage: "arrow.down.circle", shortcut: isInstalled ? nil : "↵"
                ) {
                    core.extensionCoordinator.installFromStore(listing)
                })
        }
        return items.isEmpty ? nil : PopoverMenuContent(header: listing.title, items: items)
    }

    func activate(at selection: Int) {
        guard let listing = listing(at: selection), !session.isInstalling(listing) else { return }
        if let owner = installed(listing) {
            core.extensionCoordinator.showExtensionSettings(for: owner)
        } else {
            core.extensionCoordinator.installFromStore(listing)
        }
    }

    func secondary(at selection: Int) -> Bool { false }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        if term.isEmpty { return AnyView(EmptyResults(text: "Search the Raycast Store")) }
        if case .failed(let message) = session.status { return AnyView(EmptyResults(text: message)) }
        let rows = rows
        if rows.isEmpty {
            let answered = session.status == .answered
            let text = answered ? "No extensions match “\(term)”" : "Searching…"
            return AnyView(EmptyResults(text: text))
        }
        return AnyView(
            ExtensionStoreList(
                listings: rows, selection: selection, scroll: scroll,
                state: { state(for: $0) },
                onSelect: { vm.selection = $0 },
                onActivate: activate(at:),
                onActions: { index in
                    vm.selection = index
                    openActions()
                }))
    }

    private func state(for listing: ExtensionListing) -> ExtensionStoreList.RowState {
        if let step = session.progress[listing.id] { return .installing(step.message) }
        if let failure = session.failures[listing.id] { return .failed(failure) }
        return installed(listing) == nil ? .available : .installed
    }
}
