import SwiftUI

/// Launcher dot for a scheduled extension command. The shared row embeds it but owns nothing of it.
struct ExtensionRefreshIndicator: View {
    let state: ExtensionRefreshState

    var body: some View {
        switch state {
        case .active:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .tooltip("Refreshes in the background", alignment: .trailing)
        case .idle:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.tertiary)
                .tooltip("Background refresh is off — enable it from Actions", alignment: .trailing)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .tooltip(message, alignment: .trailing)
        }
    }
}
