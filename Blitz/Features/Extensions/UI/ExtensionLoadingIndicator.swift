import SwiftUI

/// Work behind rows that stay up: a symbol, since a `ProgressView` ignores every tint.
struct ExtensionLoadingIndicator: View {
    @Environment(\.metrics) private var metrics
    var label = "Loading"
    /// `.bottom` in the palette header, where a label hung above would leave the window.
    var tooltipEdge: VerticalEdge = .top

    var body: some View {
        Image(systemName: "progress.indicator")
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
            .font(metrics.typography.menuIcon)
            .foregroundStyle(Theme.Colors.progress)
            .tooltip(label, alignment: .trailing, edge: tooltipEdge)
            .accessibilityLabel(label)
    }
}
