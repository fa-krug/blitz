import SwiftUI

/// The Store screen's results, drawn here rather than borrowed from a launcher list.
struct ExtensionStoreList: View {
    enum RowState: Equatable {
        case available
        case installing(String)
        case installed
        case failed(String)
    }

    @Environment(\.metrics) private var metrics
    let listings: [ExtensionListing]
    /// A heading above the rows, for the popular listing an empty query browses.
    let title: String?
    let isLoadingMore: Bool
    let selection: Int
    /// Changes only when the list should scroll, so mouse selection never yanks it.
    let scroll: ScrollIntent
    let state: (ExtensionListing) -> RowState
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void
    /// A row came into view or under the keyboard, which is what pages the listing further.
    let onReach: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let title {
                        Text(title)
                            .font(metrics.typography.sectionHeader)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, metrics.spacing.md)
                            .padding(.top, metrics.spacing.xs)
                            .padding(.bottom, metrics.spacing.sectionHeaderBottom)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(listings.enumerated()), id: \.element.id) { index, listing in
                        ExtensionStoreRow(
                            listing: listing, state: state(listing), selected: index == selection
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(index)
                            onActivate(index)
                        }
                        .onRightClick { onActions(index) }
                        .selectionFrame(index == selection)
                        .onAppear { onReach(index) }
                    }
                    if isLoadingMore {
                        ExtensionLoadingIndicator(label: "Loading more extensions")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, metrics.spacing.sm)
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: listings.indices.contains(selection) ? listings[selection].id : nil,
                atOrigin: selection == 0, proxy: proxy)
            .onChange(of: selection) { onReach(selection) }
        }
    }
}

private struct ExtensionStoreRow: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.isDarkAppearance) private var isDark
    let listing: ExtensionListing
    let state: ExtensionStoreList.RowState
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            ExtensionIconView(
                resolved: listing.iconURL(isDark: isDark).map {
                    ExtensionImage.Resolved(source: .remote($0))
                },
                size: metrics.size.resultRowIcon)
            Text(listing.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .layoutPriority(1)
            if !listing.summary.isEmpty {
                Text(listing.summary)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            trailing
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .installing(let message):
            HStack(spacing: metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .font(metrics.typography.rowTrailing)
            .foregroundStyle(.secondary)
            .fixedSize()
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
                .fixedSize()
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.orange)
                .help(message)
                .fixedSize()
        case .available:
            if let downloads = listing.downloadCount, downloads > 0 {
                Label(ExtensionListing.abbreviate(downloads), systemImage: "arrow.down.circle")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.tertiary)
                    .help("\(downloads.formatted()) installs")
                    .fixedSize()
            }
        }
    }
}
