import AppKit
import SwiftUI

/// Identifies the editor to present; nil is "add", and the UUID keeps two opens distinct.
struct QuicklinkEditRequest: Identifiable {
    let id = UUID()
    var quicklink: Quicklink?
    /// Seeds a new quicklink's name and link from the browser tab Create Quicklink was run over.
    var browserTab: BrowserTab?
}

/// Add / edit panel for a single quicklink, presented from the Quicklinks pane.
struct QuicklinkEditorPanel: View {
    let quicklink: Quicklink?

    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppIndex.self) private var appIndex
    @Environment(AppCore.self) private var core
    @State private var name: String
    @State private var link: String
    @State private var iconSymbol: String?
    @State private var favicon: Data?
    @State private var faviconImage: NSImage?
    @State private var isFetchingFavicon = false
    @State private var openWithBundleID: String?
    @State private var showsInRootSearch: Bool
    @State private var isPinned: Bool
    @State private var errorMessage: String?
    @State private var showingAppPicker = false
    @State private var showingIconPicker = false
    @State private var isReadingBrowserTab = false
    @State private var tagList: String

    init(quicklink: Quicklink?, browserTab: BrowserTab? = nil) {
        self.quicklink = quicklink
        _name = State(initialValue: quicklink?.name ?? browserTab?.title ?? "")
        _link = State(initialValue: quicklink?.link ?? browserTab?.url ?? "")
        _iconSymbol = State(initialValue: quicklink?.iconSymbol)
        _favicon = State(initialValue: quicklink?.favicon)
        _faviconImage = State(initialValue: quicklink?.favicon.flatMap(NSImage.init(data:)))
        _openWithBundleID = State(initialValue: quicklink?.openWithBundleID)
        _showsInRootSearch = State(initialValue: quicklink?.showsInRootSearch ?? true)
        _isPinned = State(initialValue: quicklink?.isPinned ?? false)
        _tagList = State(initialValue: quicklink?.tags.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(title: quicklink == nil ? "Add Quicklink" : "Edit Quicklink")

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField("Search GitHub", text: $name)
                    .settingsEditorTextField()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Link")
                        .font(.callout.weight(.medium))
                    Spacer()
                    browserTabButton
                    insertMenu
                }
                TextField("https://github.com/search?q={argument}", text: $link)
                    .settingsEditorTextField()
                    .font(.body.monospaced())
                destinationPreview
            }

            HStack(spacing: Theme.Spacing.xl) {
                iconField
                openWithField
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Tags")
                    .font(.callout.weight(.medium))
                TextField("work, docs", text: $tagList)
                    .settingsEditorTextField()
                Text("Separate tags with commas. Search Quicklinks matches and filters by them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                optionToggle(
                    "Show in root search", isOn: $showsInRootSearch,
                    detail: "List this quicklink alongside apps and commands.")
                optionToggle(
                    "Pin to top", isOn: $isPinned,
                    detail: "Keep it above the other quicklinks.")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(name).isEmpty || trimmed(link).isEmpty)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    // MARK: - Fields

    /// The destination as it will be opened: all the feedback a templated link can give.
    @ViewBuilder
    private var destinationPreview: some View {
        let value = trimmed(link)
        if value.isEmpty {
            EmptyView()
        } else if QuicklinkDestination.containsPlaceholder(value) {
            Text("Resolved when you open it — placeholders are filled in first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let destination = QuicklinkDestination.detect(value) {
            Label(destination.displayText, systemImage: destination.defaultSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("This doesn't look like a URL, file path, or deeplink.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Reads the most recently used browser that is running; a title only fills an empty name.
    private var browserTabButton: some View {
        Button {
            useCurrentBrowserTab()
        } label: {
            if isReadingBrowserTab {
                ProgressView().controlSize(.small)
            } else {
                Text("Use Current Browser Tab")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isReadingBrowserTab)
        .help("Fill in the link from the front tab of Safari or a Chromium browser")
    }

    /// Only tokens meaningful in a destination; `{cursor}` and `{snippet:…}` stay literal.
    private var insertMenu: some View {
        Menu("Insert…") {
            Button("Argument") { insert("{argument}") }
            Button("Named Argument") { insert("{argument name=\"Query\"}") }
            Divider()
            Button("Clipboard") { insert("{clipboard}") }
            Button("Selected Text") { insert("{selection}") }
            Button("Browser Tab") { insert("{browser-tab}") }
            Divider()
            Button("Date") { insert("{date}") }
            Button("Time") { insert("{time}") }
            Button("Date & Time") { insert("{datetime}") }
            Button("Custom Date Format") { insert("{date format=\"yyyy-MM-dd\"}") }
            Divider()
            Button("UUID") { insert("{uuid}") }
            Button("Calculator") { insert("{calculator expression=\"2 * 21\"}") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private static let iconSymbols = [
        "globe", "folder", "doc.text", "link", "star", "bookmark", "magnifyingglass", "cart",
        "envelope", "message", "calendar", "clock", "checklist", "chart.bar", "hammer", "wrench",
        "ladybug", "terminal", "chevron.left.forwardslash.chevron.right", "cloud", "server.rack",
        "lock", "person.2", "building.2", "graduationcap", "book", "music.note", "play.rectangle",
        "photo", "paintbrush", "creditcard", "map"
    ]

    private var iconField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Icon")
                .font(.callout.weight(.medium))
            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    showingIconPicker = true
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        iconPreview
                        Text(iconTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 150)
                }
                .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                    SymbolPicker(
                        selection: $iconSymbol, fallback: automaticSymbol,
                        symbols: Self.iconSymbols
                    ) {
                        // Picking a symbol is choosing it over the favicon, so the favicon goes.
                        favicon = nil
                        faviconImage = nil
                        showingIconPicker = false
                    }
                }
                faviconButton
            }
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let faviconImage {
            Image(nsImage: faviconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
        } else {
            SymbolImage(name: resolvedSymbol, size: 14)
        }
    }

    private var iconTitle: String {
        if faviconImage != nil { return "Favicon" }
        return iconSymbol == nil ? "Automatic" : "Custom"
    }

    /// Disabled unless the link is a website: nothing else has a favicon to fetch.
    private var faviconButton: some View {
        Button(action: fetchFavicon) {
            Group {
                if isFetchingFavicon {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 16, height: 16)
        }
        .disabled(isFetchingFavicon || QuicklinkFavicon.siteURL(for: trimmed(link)) == nil)
        .help(faviconImage == nil ? "Fetch the site's favicon" : "Refetch the site's favicon")
        .accessibilityLabel(faviconImage == nil ? "Fetch Favicon" : "Refetch Favicon")
    }

    private var openWithField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Open With")
                .font(.callout.weight(.medium))
            Button {
                showingAppPicker = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if let openWithBundleID {
                        let app = AppPresentation.resolve(bundleID: openWithBundleID, in: appIndex)
                        Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                        Text(app.name).lineLimit(1)
                    } else {
                        Text("Default app")
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 180)
            }
            .popover(isPresented: $showingAppPicker, arrowEdge: .bottom) {
                AppPickerPopover(clearTitle: "Default app") { bundleID in
                    openWithBundleID = bundleID
                    showingAppPicker = false
                }
            }
        }
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Behaviour

    private var automaticSymbol: String {
        QuicklinkDestination.detect(trimmed(link))?.defaultSymbol ?? Quicklink.sfSymbol
    }

    private var resolvedSymbol: String { iconSymbol ?? automaticSymbol }

    /// The link is read once up front, so editing it mid-fetch can't mix two sites.
    private func fetchFavicon() {
        let site = trimmed(link)
        isFetchingFavicon = true
        errorMessage = nil
        Task {
            let fetched = await QuicklinkFaviconFetcher.fetch(for: site)
            isFetchingFavicon = false
            guard let fetched, let image = NSImage(data: fetched) else {
                let host = QuicklinkFavicon.siteURL(for: site)?.host() ?? "this link"
                errorMessage = "Couldn't find a favicon for \(host)."
                return
            }
            favicon = fetched
            faviconImage = image
        }
    }

    private func useCurrentBrowserTab() {
        errorMessage = nil
        guard let browser = BrowserTabs.mostRecentBrowser() else {
            errorMessage = "Open Safari or a Chromium browser first."
            return
        }
        isReadingBrowserTab = true
        Task {
            defer { isReadingBrowserTab = false }
            do throws(BrowserTabs.Failure) {
                guard let tab = try await BrowserTabs.frontTab(of: browser) else {
                    errorMessage = "\(browser.localizedName ?? "The browser") has no open tab."
                    return
                }
                link = tab.url
                if trimmed(name).isEmpty { name = tab.title }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func insert(_ token: String) {
        link += token
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        // Editing keeps the UUID, and with it the quicklink's shortcut, favorite and visibility.
        let existing = quicklink
        let draft = Quicklink(
            id: existing?.id ?? UUID(), name: name, link: link,
            openWithBundleID: openWithBundleID, iconSymbol: iconSymbol, favicon: favicon,
            // The pane's row owns the checkbox; an edit carries the flag rather than resetting it.
            isEnabled: existing?.isEnabled ?? true,
            showsInRootSearch: showsInRootSearch,
            // Re-pinning keeps the original stamp, so saving an edit doesn't move the row.
            pinnedAt: isPinned ? (existing?.pinnedAt ?? Date()) : nil,
            createdAt: existing?.createdAt ?? Date(),
            tags: Quicklink.tags(fromList: tagList))
        do {
            if existing == nil {
                try core.quicklinkCoordinator.addQuicklink(draft)
            } else {
                try core.quicklinkCoordinator.updateQuicklink(draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A small fixed grid, not a symbol browser; "Automatic" is first, being the better default.
