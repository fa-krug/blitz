import AppKit
import SwiftUI

/// `Form.LinkAccessory`: a web link a form carries in the header, opened in the default browser.
struct ExtensionLinkAccessory: View {
    @Environment(\.metrics) private var metrics
    let text: String
    let target: URL

    /// Web links only: an extension reaches any other scheme through `open()`, which routes it.
    init?(node: RenderNode?) {
        guard let node, node.type == "Form.LinkAccessory",
            let target = node.string("target").flatMap(URL.init(string:)),
            ["http", "https"].contains(target.scheme?.lowercased())
        else { return nil }
        text = node.string("text") ?? target.host() ?? target.absoluteString
        self.target = target
    }

    var body: some View {
        BarButton(chrome: .rounded, action: { NSWorkspace.shared.open(target) }) {
            HStack(spacing: metrics.spacing.sm) {
                Text(text)
                    .font(metrics.typography.bar)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(metrics.typography.disclosure)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .help(target.absoluteString)
        .accessibilityAddTraits(.isLink)
    }
}
