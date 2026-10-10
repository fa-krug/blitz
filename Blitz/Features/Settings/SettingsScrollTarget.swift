import SwiftUI

extension View {
    /// Named by the pane: across a swap both are alive and `navigation.tab` reads the incoming one.
    func settingsScrollTarget(_ tab: SettingsTab) -> some View {
        modifier(SettingsScrollTarget(tab: tab))
    }

    /// A headerless `Section` a result can scroll to; with a header, use `SettingsSectionHeader`.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        id(SettingsTarget.section(anchor))
    }

    /// Narrows a filtered list to the row a jump names, when `lists` says the list holds it.
    func settingsFilterSeed(
        _ anchor: SettingsAnchor, query: Binding<String>, lists: @escaping (String) -> Bool
    ) -> some View {
        modifier(SettingsFilterSeed(anchor: anchor, query: query, lists: lists))
    }
}

private struct SettingsFilterSeed: ViewModifier {
    let anchor: SettingsAnchor
    @Binding var query: String
    let lists: (String) -> Bool
    @Environment(SettingsNavigationState.self) private var navigation

    func body(content: Content) -> some View {
        // Initial: Configure Command can open the window onto this pane with the request set.
        content.onChange(of: navigation.scrollRequest, initial: true) { _, request in
            guard case .row(anchor, let title)? = request?.target, lists(title) else { return }
            query = title
        }
    }
}

/// A pill behind the matched name only: a `Form` row's `.background` paints ragged blocks.
private struct SearchPill: ViewModifier {
    let target: SettingsTarget
    @Environment(SettingsNavigationState.self) private var navigation

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                Capsule().fill(navigation.flashing == target ? Theme.Colors.searchFlash : .clear)
            )
            // Given back, so the pill's own padding can't shift the label off its row's edge.
            .padding(.horizontal, -Theme.Spacing.sm)
            .padding(.vertical, -Theme.Spacing.xxs)
            .id(target)
    }
}

/// A `Section`'s name, and where a result that matched the whole group lands.
struct SettingsSectionHeader<Label: View>: View {
    let anchor: SettingsAnchor
    @ViewBuilder var label: Label

    var body: some View {
        label.modifier(SearchPill(target: .section(anchor)))
    }
}

extension SettingsSectionHeader where Label == Text {
    /// The title comes from the anchor, so a section's name and its breadcrumb are one string.
    init(_ anchor: SettingsAnchor) {
        self.init(anchor: anchor) { Text(anchor.title) }
    }
}

/// A setting's name in place of its label's `Text`: what a row-level result scrolls to and lights.
struct SettingsRowTitle: View {
    let anchor: SettingsAnchor
    let title: String

    init(_ anchor: SettingsAnchor, _ title: String) {
        self.anchor = anchor
        self.title = title
    }

    var body: some View {
        Text(title).modifier(SearchPill(target: .row(anchor, title)))
    }
}

private struct SettingsScrollTarget: ViewModifier {
    let tab: SettingsTab
    @Environment(SettingsNavigationState.self) private var navigation

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                // Keyed on the request, so a second jump cancels the first mid-pulse.
                .task(id: navigation.scrollRequest) { await reveal(with: proxy) }
        }
    }

    private func reveal(with proxy: ScrollViewProxy) async {
        guard let request = navigation.scrollRequest, request.target.tab == tab else { return }
        // This pane may have just mounted, so let its `Form` lay the anchor out before scrolling.
        await Task.yield()
        withAnimation(.easeOut(duration: Theme.Duration.settingsReveal)) {
            // A lazy row may not be built yet, so the jump lands on its section first.
            if case .row(let anchor, _) = request.target {
                proxy.scrollTo(SettingsTarget.section(anchor), anchor: .center)
            }
            proxy.scrollTo(request.target, anchor: .center)
        }
        navigation.beginFlash(request.target)
        // Cancelled means a later jump replaced this one, and it owns the light now.
        do {
            try await Task.sleep(for: .seconds(Theme.Duration.settingsFlash))
        } catch {
            return
        }
        withAnimation(.easeOut(duration: Theme.Duration.settingsFlashOut)) {
            navigation.endFlash(request.target)
        }
        // Released last: it keys this task, so clearing it earlier would cancel the reveal itself.
        navigation.clear(request)
    }
}
