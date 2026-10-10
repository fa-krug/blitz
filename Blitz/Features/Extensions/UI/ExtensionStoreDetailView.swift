import SwiftUI

/// One store extension's page: who made it, what it looks like, its README and what changed last.
struct ExtensionStoreDetailView: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.isDarkAppearance) private var isDark
    let detail: ExtensionStoreSession.Detail
    let state: ExtensionStoreList.RowState

    private static let iconSize: CGFloat = 48
    private static let titleSize: CGFloat = 17
    private static let screenshotHeight: CGFloat = 150

    private var listing: ExtensionListing { detail.shown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.xl) {
                header
                if !listing.categories.isEmpty { categories }
                if !listing.screenshotURLs.isEmpty { screenshots }
                readme
                if let change = listing.latestChange { changelog(change) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.spacing.lg)
            .padding(.vertical, metrics.spacing.md)
            .hideNativeScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgeDissolve()
        .thinScrollbar()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: metrics.spacing.lg) {
            ExtensionIconView(
                resolved: listing.iconURL(isDark: isDark).map {
                    ExtensionImage.Resolved(source: .remote($0))
                },
                size: metrics.scaled(Self.iconSize))
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(listing.title)
                    .font(.system(size: metrics.scaled(Self.titleSize), weight: .semibold))
                    .lineLimit(1)
                if !listing.summary.isEmpty {
                    Text(listing.summary)
                        .font(metrics.typography.rowTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(facts)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            badge
        }
        .accessibilityElement(children: .combine)
    }

    /// Author, installs, commands and age: what a row has no room to say.
    private var facts: String {
        var parts: [String] = []
        if !listing.author.isEmpty { parts.append(listing.author) }
        if let downloads = listing.downloadCount, downloads > 0 {
            parts.append("\(ExtensionListing.abbreviate(downloads)) installs")
        }
        if listing.commandCount > 0 {
            parts.append(listing.commandCount == 1 ? "1 command" : "\(listing.commandCount) commands")
        }
        if let updated = listing.updatedAt {
            parts.append("Updated \(updated.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .installing(let message):
            HStack(spacing: metrics.spacing.sm) {
                ExtensionLoadingIndicator(label: message)
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
                .tooltip(message, alignment: .trailing)
                .fixedSize()
        case .available:
            EmptyView()
        }
    }

    private var categories: some View {
        FlowLayout(spacing: metrics.spacing.xs) {
            ForEach(listing.categories, id: \.self) { category in
                Text(category)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.spacing.sm)
                    .padding(.vertical, metrics.spacing.xxs)
                    .background(Capsule().fill(ExtensionColors.detailCardFill))
            }
        }
    }

    private var screenshots: some View {
        ScrollView(.horizontal) {
            HStack(spacing: metrics.spacing.sm) {
                ForEach(listing.screenshotURLs, id: \.self) { url in
                    ExtensionStoreScreenshot(url: url, height: metrics.scaled(Self.screenshotHeight))
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityLabel("Screenshots")
    }

    @ViewBuilder
    private var readme: some View {
        if let text = detail.readme, !text.isEmpty {
            ExtensionMarkdownView(markdown: text)
        } else if detail.isLoading {
            HStack(spacing: metrics.spacing.sm) {
                ExtensionLoadingIndicator()
                Text("Loading…").foregroundStyle(.secondary)
            }
        } else {
            Text(listing.summary.isEmpty ? "This extension has no README." : listing.summary)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func changelog(_ change: ExtensionListing.Change) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Rectangle().fill(Theme.Colors.separator).frame(height: 1)
            Text(changeHeading(change))
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ExtensionMarkdownView(markdown: change.markdown)
        }
    }

    private func changeHeading(_ change: ExtensionListing.Change) -> String {
        ["What's New", change.title, change.date]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }
}

/// Downsampled at load, so a strip of full-resolution captures never sits decoded in memory.
private struct ExtensionStoreScreenshot: View {
    @Environment(\.metrics) private var metrics
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    /// Store captures are 16:10; the placeholder keeps that shape until the pixels arrive.
    private static let aspectRatio: CGFloat = 1.6

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous)
                    .fill(ExtensionColors.detailCardFill)
                    .frame(width: height * Self.aspectRatio)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous))
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = await ExtensionIconCache.loadThumbnailAsync(
                url, maxPixelSize: height * Self.aspectRatio * scale)
        }
        .accessibilityHidden(true)
    }
}
