import SwiftUI

/// A pane whose list rows each open a page of its own; Back scrolls the list to the row again.
struct SettingsPagedPane<Library: View, Page: View>: View {
    /// False on the list, and for a page whose item is gone: Back may still reach one.
    let showsPage: Bool
    @ViewBuilder let page: () -> Page
    @ViewBuilder let library: () -> Library

    @Environment(SettingsNavigationState.self) private var navigation
    /// The row the list scrolls back to once a page closes, so a long list keeps its place.
    @State private var returning: String?

    var body: some View {
        Group {
            if showsPage {
                page()
            } else {
                ScrollViewReader { proxy in
                    library()
                        // Keyed: Back can close a page before or after the list mounts again.
                        .task(id: returning) {
                            guard let returning else { return }
                            // The list has just mounted, so let it lay the row out first.
                            await Task.yield()
                            proxy.scrollTo(returning, anchor: .center)
                            self.returning = nil
                        }
                }
            }
        }
        .onChange(of: navigation.page) { previous, page in
            if page == nil { returning = previous }
        }
    }
}

/// Lazy read-only rows in one `Form` row: with no AppKit control, a row is cheap to build.
struct SettingsPageRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// Fixed, to match the native `Form` row the list stands in for.
    let rowHeight: CGFloat
    /// The pane's page string for an item; it is also the row's id, so Back can scroll to it.
    let page: (Item) -> String
    let accessibilityName: (Item) -> String
    @ViewBuilder let row: (Item) -> Row

    @Environment(SettingsNavigationState.self) private var navigation

    /// How far a `Form` row pads its content above and below.
    private static var overhang: CGFloat { 10 }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    Divider().opacity(item.id == items.first?.id ? 0 : 1)
                    Button {
                        navigation.select(navigation.tab, page: page(item))
                    } label: {
                        row(item)
                            .frame(maxHeight: .infinity)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Configure \(accessibilityName(item))")
                }
                .frame(height: rowHeight)
                .id(page(item))
            }
        }
        // Into the Form row's own padding (and the filter's divider), where native rows would sit.
        .padding(.top, -Self.overhang - 1)
        .padding(.bottom, -Self.overhang)
    }
}

/// What a list row shows for the controls its page holds: the alias, the shortcut, a chevron.
struct SettingsEntryBadges: View {
    /// The owner's `preferenceKey`, as `AliasField` takes it.
    let aliasKey: String
    let action: HotKeyAction?

    @Environment(AliasStore.self) private var aliases
    @Environment(HotKeyManager.self) private var hotKeys

    var body: some View {
        if let alias = aliases.alias(for: aliasKey) {
            Text(alias)
                .font(Theme.Typography.keyCap)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .accessibilityLabel("Alias \(alias)")
        }
        if let keycaps = action.flatMap(hotKeys.binding(for:))?.keycaps {
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                    KeyCapChip(text: cap, style: .outline, scale: .compact)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Shortcut")
        }
        Image(systemName: "chevron.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// The badge a hidden-from-search item carries, for a row whose page holds the switch.
struct SettingsHiddenBadge: View {
    let help: String

    var body: some View {
        Image(systemName: "eye.slash")
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
    }
}
