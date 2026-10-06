import SwiftUI

/// The Raycast Store in the palette: popular until a query, ↵ installs, ⌘↵ shows details.
struct ExtensionStoreScreen: PaletteScreen {
    let session: ExtensionStoreSession
    let extensions: ExtensionManager
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An open detail page is one row, so ↵ and ⌘K act on the extension it shows.
    var rows: [ExtensionListing] {
        if let detail = session.detail { return [detail.shown] }
        return session.results
    }

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
        if session.detail == nil {
            items.append(
                PopoverMenuItem(title: "Show Details", systemImage: "info.circle", shortcut: "⌘↵") {
                    showDetail(at: selection)
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

    /// ⌘↵ opens the extension's store page; on that page there is nothing further to open.
    func secondary(at selection: Int) -> Bool {
        guard session.detail == nil, listing(at: selection) != nil else { return false }
        showDetail(at: selection)
        return true
    }

    private func showDetail(at selection: Int) {
        guard let listing = listing(at: selection) else { return }
        session.showDetail(listing, returning: selection)
        vm.selection = 0
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        if let detail = session.detail {
            return AnyView(
                ExtensionStoreDetailView(detail: detail, state: state(for: detail.shown)))
        }
        if case .failed(let message) = session.status { return AnyView(EmptyResults(text: message)) }
        let rows = rows
        if rows.isEmpty {
            return AnyView(EmptyResults(text: emptyText))
        }
        return AnyView(
            ExtensionStoreList(
                listings: rows, title: term.isEmpty ? "Popular" : nil,
                isLoadingMore: session.isLoadingMore, selection: selection, scroll: scroll,
                state: { state(for: $0) },
                onSelect: { vm.selection = $0 },
                onActivate: activate(at:),
                onActions: { index in
                    vm.selection = index
                    openActions()
                },
                onReach: { session.loadMore(reaching: $0) }))
    }

    private var emptyText: String {
        guard session.status == .answered else { return term.isEmpty ? "Loading…" : "Searching…" }
        return term.isEmpty ? "The Raycast Store listed nothing" : "No extensions match “\(term)”"
    }

    private func state(for listing: ExtensionListing) -> ExtensionStoreList.RowState {
        if let step = session.progress[listing.id] { return .installing(step.message) }
        if let failure = session.failures[listing.id] { return .failed(failure) }
        return installed(listing) == nil ? .available : .installed
    }
}
