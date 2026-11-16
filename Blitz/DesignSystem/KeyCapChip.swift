import SwiftUI

/// A single keycap chip: `.outline` for hotkey hints on rows, `.filled` for footer shortcuts.
struct KeyCapChip: View {
    enum Style {
        case outline
        case filled
    }

    /// Sanctioned cap sizes, so a bigger or smaller one is a named choice, not a stray frame.
    enum Scale {
        case compact
        case standard
        case hero

        func side(_ metrics: InterfaceMetrics) -> CGFloat {
            switch self {
            case .compact: metrics.size.compactKeyCap
            case .standard: metrics.size.keyCap
            case .hero: metrics.size.heroKeyCap
            }
        }

        @MainActor
        func font(_ metrics: InterfaceMetrics) -> Font {
            switch self {
            case .compact: metrics.typography.compactKeyCap
            case .standard: metrics.typography.keyCap
            case .hero: metrics.typography.heroKeyCap
            }
        }

        /// A step below the glyph, so a side letter reads as a label rather than a second key.
        @MainActor
        func prefixFont(_ metrics: InterfaceMetrics) -> Font {
            switch self {
            case .compact, .standard: metrics.typography.compactKeyCap
            case .hero: metrics.typography.keyCap
            }
        }
    }

    /// A cap's face: a sided modifier's small L or R sits before its glyph.
    struct Label: View {
        let text: String
        var prefix: String?
        var prefixFont: Font = Theme.Typography.compactKeyCap

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if let prefix { Text(prefix).font(prefixFont) }
                Text(text)
            }
        }
    }

    let text: String
    var style: Style = .filled
    var scale: Scale = .standard
    /// The side of a sided modifier, "L" or "R"; nil for every other cap.
    var prefix: String?
    @Environment(\.metrics) private var metrics

    /// "↵" falls back to another face that seats high, so nudge it render-only.
    private static let returnGlyphDrop: CGFloat = 1.1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
        Label(text: text, prefix: prefix, prefixFont: scale.prefixFont(metrics))
            .font(scale.font(metrics))
            .foregroundStyle(Theme.Colors.textSecondary)
            .offset(y: text == "↵" ? Self.returnGlyphDrop : 0)
            .padding(.horizontal, metrics.spacing.xs)
            .frame(minWidth: scale.side(metrics), minHeight: scale.side(metrics))
            .background {
                switch style {
                case .filled: shape.fill(Theme.Colors.controlSurface)
                case .outline: shape.strokeBorder(Theme.Colors.border, lineWidth: 1)
                }
            }
    }
}
