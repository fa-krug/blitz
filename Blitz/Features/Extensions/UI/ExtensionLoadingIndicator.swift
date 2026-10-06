import SwiftUI

/// Work behind rows that stay up: a symbol, since a `ProgressView` ignores every tint.
struct ExtensionLoadingIndicator: View {
    @Environment(\.metrics) private var metrics
    var label = "Loading"

    var body: some View {
        Image(systemName: "progress.indicator")
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
            .font(metrics.typography.menuIcon)
            .foregroundStyle(Theme.Colors.progress)
            .help(label)
            .accessibilityLabel(label)
    }
}
