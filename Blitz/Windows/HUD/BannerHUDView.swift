import SwiftUI

/// The banner: subject glyph, what was made and when, and one action, on the pill's recipe.
struct BannerHUDView: View {
    let title: String
    let detail: String
    let symbol: String
    let actionTitle: String
    let onAction: () -> Void
    let onHover: (Bool) -> Void
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            SymbolImage(name: symbol, size: metrics.size.dialogHeaderSymbol, monochrome: true)
                .foregroundStyle(DialogTone.success.tint)
                .frame(width: metrics.size.menuIcon, height: metrics.size.menuIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(title)
                    .font(metrics.typography.bar)
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: onAction)
                .buttonStyle(.modalAction(.standard, fillsWidth: false))
        }
        .padding(.leading, metrics.spacing.xl)
        .padding(.trailing, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.md)
        .frame(width: metrics.size.bannerWidth)
        // Not glass, as the pill isn't: with nothing behind it to lens, glass turns opaque.
        .background(Theme.Colors.panelScrim)
        .background(GlassEffectView())
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Theme.Colors.border, lineWidth: Theme.Size.hairline) }
        .onHover(perform: onHover)
    }
}
