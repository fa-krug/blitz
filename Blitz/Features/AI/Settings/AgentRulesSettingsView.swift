import SwiftUI

/// Settings › AI › Rules: the shell and path patterns, each row opening the rule's own page.
struct AgentRulesSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AISettingsStore.self) private var settings
    @Environment(SettingsNavigationState.self) private var navigation

    /// The rule just added, whose page opens with its pattern field focused.
    @State private var adding: AgentRuleRoute?

    var body: some View {
        let shellRules = AgentRuleItem.shell(settings.agentRules.shellRules)
        let pathRules = AgentRuleItem.path(settings.agentRules.pathRules)
        let shown = navigation.page.flatMap { page in
            (shellRules + pathRules).first { $0.id == page }
        }
        SettingsPagedPane(showsPage: shown != nil) {
            if let shown {
                AgentRulePage(item: shown, focusesPattern: shown.route == adding)
                    .id(shown.route)
            }
        } library: {
            library(shell: shellRules, path: pathRules)
        }
        .onChange(of: navigation.page) {
            if navigation.page != adding?.page { adding = nil }
        }
    }

    private func library(shell: [AgentRuleItem], path: [AgentRuleItem]) -> some View {
        Form {
            AITurnedOffNotice()
            Group {
                Section {
                    rows(shell)
                    addButton(.shell) {
                        SettingsRowTitle(.agentRulesShellRules, "Add Shell Rule")
                    }
                } header: {
                    SettingsSectionHeader(.agentRulesShellRules)
                } footer: {
                    footer(.shell)
                }

                Section {
                    rows(path)
                    addButton(.path) {
                        SettingsRowTitle(.agentRulesPathRules, "Add Path Rule")
                    }
                } header: {
                    SettingsSectionHeader(.agentRulesPathRules)
                } footer: {
                    footer(.path)
                }
            }
            .settingsEnabled(appSettings.aiEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.agentRules)
    }

    /// Native rows rather than `SettingsPageRows`: the lists are short, and none holds a control.
    @ViewBuilder
    private func rows(_ items: [AgentRuleItem]) -> some View {
        if items.isEmpty {
            Text("None yet")
                .foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            Button {
                navigation.select(navigation.tab, page: item.route.page)
            } label: {
                AgentRuleRow(item: item)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Configure rule \(item.position), \(item.pattern.isEmpty ? "empty" : item.pattern)")
            .id(item.route.page)
        }
    }

    private func addButton<Title: View>(
        _ kind: AgentRuleKind, @ViewBuilder title: () -> Title
    ) -> some View {
        Button {
            add(kind)
        } label: {
            Label {
                title()
            } icon: {
                Image(systemName: "plus")
                    .foregroundStyle(.primary)
            }
        }
    }

    private func footer(_ kind: AgentRuleKind) -> some View {
        Text(kind.footer)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// An empty Allow pattern, matching nothing until its page gives it one.
    private func add(_ kind: AgentRuleKind) {
        let id: UUID
        switch kind {
        case .shell:
            let rule = ShellRule(pattern: "", decision: .allow)
            settings.addShellRule(rule)
            id = rule.id
        case .path:
            let rule = PathRule(pattern: "", decision: .allow)
            settings.addPathRule(rule)
            id = rule.id
        }
        let route = AgentRuleRoute(kind: kind, id: id)
        adding = route
        navigation.select(navigation.tab, page: route.page)
    }
}
