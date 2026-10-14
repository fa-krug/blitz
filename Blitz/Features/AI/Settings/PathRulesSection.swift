import SwiftUI

/// Settings → AI → Path rules: ordered patterns, each deciding the file paths it matches.
struct PathRulesSection: View {
    @Environment(AISettingsStore.self) private var settings
    @FocusState private var focusedRule: PathRule.ID?

    var body: some View {
        let rules = settings.agentRules.pathRules
        Section {
            ForEach(rules) { rule in
                AgentRuleRow(
                    rule: rule, pattern: \.pattern, decision: \.decision, prompt: "~/Projects/**",
                    canMoveUp: rule.id != rules.first?.id,
                    canMoveDown: rule.id != rules.last?.id,
                    onChange: settings.updatePathRule,
                    onMove: { settings.movePathRule(id: rule.id, by: $0) },
                    onRemove: { settings.removePathRule(id: rule.id) },
                    focus: $focusedRule
                ) { rule in
                    Picker("Applies to", selection: access(of: rule)) {
                        ForEach(PathRule.Access.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Button(action: addRule) {
                Label {
                    SettingsRowTitle(.aiPathRules, "Add Path Rule")
                } icon: {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            SettingsSectionHeader(.aiPathRules)
        } footer: {
            Text(
                "A matching Deny always wins; otherwise each path takes the first pattern it "
                    + "matches. ~ is your home folder, * stays within one folder and ** spans "
                    + "folders, so ~/Projects/** covers the folder and everything in it. Paths "
                    + "are checked once symlinks resolve, ignoring case. Read rules also weigh "
                    + "what the agent opens, but only a Deny or an Ask there changes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func access(of rule: PathRule) -> Binding<PathRule.Access> {
        Binding(
            get: { rule.access },
            set: { access in
                var edited = rule
                edited.access = access
                settings.updatePathRule(edited)
            })
    }

    private func addRule() {
        let rule = PathRule(pattern: "", decision: .allow)
        settings.addPathRule(rule)
        focusedRule = rule.id
    }
}
