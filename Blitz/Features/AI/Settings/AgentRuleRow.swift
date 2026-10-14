import SwiftUI

/// Read-only, so it holds no AppKit control: the pattern, decision and order live on its page.
struct AgentRuleRow: View {
    let item: AgentRuleItem

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("\(item.position)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: SettingsListMetrics.iconSize, alignment: .trailing)
            if item.pattern.isEmpty {
                Text("Empty pattern")
                    .foregroundStyle(.tertiary)
            } else {
                Text(item.pattern)
                    .font(Theme.Typography.inlineCode)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if let access = item.access { AgentRuleBadge(title: access.title) }
            AgentRuleBadge(title: item.decision.title)
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct AgentRuleBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Capsule().fill(Theme.Colors.controlSurface))
    }
}
