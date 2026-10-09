import SwiftUI

/// Why a list is empty, what to try next, and — when one click can fix it — that click.
struct EmptyResults: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let text: String
    var symbol = "magnifyingglass"
    var hint: String?
    var action: Action?
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            SymbolImage(name: symbol, size: metrics.size.dialogIcon)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(text)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
            if let hint {
                Text(hint)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.modalAction(.standard, fillsWidth: false))
                    .padding(.top, metrics.spacing.xs)
            }
        }
        .multilineTextAlignment(.center)
        .padding(metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
