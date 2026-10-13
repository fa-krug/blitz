import SwiftUI

/// Settings → AI → Shell rules: ordered patterns, each deciding the command parts it matches.
struct ShellRulesSection: View {
    @Environment(AISettingsStore.self) private var settings
    @FocusState private var focusedRule: ShellRule.ID?

    var body: some View {
        let rules = settings.agentRules.shellRules
        Section {
            ForEach(rules) { rule in
                AgentRuleRow(
                    rule: rule, pattern: \.pattern, decision: \.decision, prompt: "git status *",
                    canMoveUp: rule.id != rules.first?.id,
                    canMoveDown: rule.id != rules.last?.id,
                    onChange: settings.updateShellRule,
                    onMove: { settings.moveShellRule(id: rule.id, by: $0) },
                    onRemove: { settings.removeShellRule(id: rule.id) },
                    focus: $focusedRule
                )
            }
            Button(action: addRule) {
                Label {
                    SettingsRowTitle(.aiShellRules, "Add Shell Rule")
                } icon: {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            SettingsSectionHeader(.aiShellRules)
        } footer: {
            Text(
                "A matching Deny always wins; otherwise each part of a command takes the first "
                    + "pattern it matches. * matches anything. A command with $(…) or backticks "
                    + "always asks. A Deny pattern is a backstop, not a sandbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addRule() {
        let rule = ShellRule(pattern: "", decision: .allow)
        settings.addShellRule(rule)
        focusedRule = rule.id
    }
}
