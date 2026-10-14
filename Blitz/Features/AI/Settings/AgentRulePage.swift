import SwiftUI

/// Which list a rule sits in: the prefix of its page string, and the words its row and page use.
enum AgentRuleKind: String, Hashable {
    case shell
    case path

    var title: String {
        switch self {
        case .shell: "Shell Rule"
        case .path: "Path Rule"
        }
    }

    var prompt: String {
        switch self {
        case .shell: "git status *"
        case .path: "~/Projects/**"
        }
    }

    /// How the list matches, said under the list and again on each rule's page.
    var footer: String {
        switch self {
        case .shell:
            "A matching Deny always wins; otherwise each part of a command takes the first "
                + "pattern it matches. * matches anything. A command with $(…) or backticks "
                + "always asks. A Deny pattern is a backstop, not a sandbox."
        case .path:
            "A matching Deny always wins; otherwise each path takes the first pattern it "
                + "matches. ~ is your home folder, * stays within one folder and ** spans "
                + "folders, so ~/Projects/** covers the folder and everything in it. Paths "
                + "are checked once symlinks resolve, ignoring case. Read rules also weigh "
                + "what the agent opens, but only a Deny or an Ask there changes it."
        }
    }
}

/// One rule's page, `shell:<uuid>` or `path:<uuid>`.
struct AgentRuleRoute: Hashable {
    let kind: AgentRuleKind
    let id: UUID

    init(kind: AgentRuleKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    /// Nil for a string no rule writes, so a stale page falls back to the list.
    init?(page: String) {
        let parts = page.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = AgentRuleKind(rawValue: parts[0]),
            let id = UUID(uuidString: parts[1])
        else { return nil }
        self.init(kind: kind, id: id)
    }

    /// The pane's page string, also the list row's id so Back can scroll to it.
    var page: String { "\(kind.rawValue):\(id.uuidString)" }
}

/// One rule as the Rules pane shows it, so one row and one page serve both lists.
struct AgentRuleItem: Identifiable {
    let route: AgentRuleRoute
    /// From 1, in list order, since the first pattern that matches decides.
    let position: Int
    let count: Int
    let pattern: String
    let decision: AgentDecision
    /// Nil for a shell rule, which has no access to narrow.
    let access: PathRule.Access?

    var id: String { route.page }

    static func shell(_ rules: [ShellRule]) -> [Self] {
        rules.enumerated().map { index, rule in
            Self(
                route: AgentRuleRoute(kind: .shell, id: rule.id), position: index + 1,
                count: rules.count, pattern: rule.pattern, decision: rule.decision, access: nil)
        }
    }

    static func path(_ rules: [PathRule]) -> [Self] {
        rules.enumerated().map { index, rule in
            Self(
                route: AgentRuleRoute(kind: .path, id: rule.id), position: index + 1,
                count: rules.count, pattern: rule.pattern, decision: rule.decision,
                access: rule.access)
        }
    }
}

/// One rule's own page: its place in the list, then the controls that change it at once.
struct AgentRulePage: View {
    let item: AgentRuleItem
    /// Set for a rule just added, whose empty pattern is the first thing to fill in.
    let focusesPattern: Bool

    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(AISettingsStore.self) private var settings
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        Form {
            // The window's Back chevron leaves the page, as on a quicklink's.
            Section {
                SettingsRow(
                    title: item.route.kind.title, subtitle: "\(item.position) of \(item.count)"
                ) {
                    Button("Move Up") { move(by: -1) }
                        .disabled(item.position == 1)
                    Button("Move Down") { move(by: 1) }
                        .disabled(item.position == item.count)
                    Button("Delete…", role: .destructive, action: delete)
                }
            }

            Section {
                LabeledContent {
                    TextField("Pattern", text: pattern, prompt: Text(item.route.kind.prompt))
                        .labelsHidden()
                        .font(Theme.Typography.inlineCode)
                        .focused($isPatternFocused)
                } label: {
                    Text("Pattern")
                }
                Picker("Decision", selection: decision) {
                    ForEach([AgentDecision.allow, .ask, .deny]) { Text($0.title).tag($0) }
                }
                if item.access != nil {
                    Picker("Applies to", selection: access) {
                        ForEach(PathRule.Access.allCases) { Text($0.title).tag($0) }
                    }
                }
            } footer: {
                Text(item.route.kind.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsEnabled(appSettings.aiEnabled)
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
        .task {
            guard focusesPattern else { return }
            // The field has only just mounted, so give it a layout pass before it takes focus.
            await Task.yield()
            isPatternFocused = true
        }
    }

    private var pattern: Binding<String> {
        Binding(
            get: { item.pattern },
            set: { value in update(shell: { $0.pattern = value }, path: { $0.pattern = value }) })
    }

    private var decision: Binding<AgentDecision> {
        Binding(
            get: { item.decision },
            set: { value in update(shell: { $0.decision = value }, path: { $0.decision = value }) })
    }

    private var access: Binding<PathRule.Access> {
        Binding(
            get: { item.access ?? .readAndWrite },
            set: { value in update(shell: { _ in }, path: { $0.access = value }) })
    }

    private func update(shell: (inout ShellRule) -> Void, path: (inout PathRule) -> Void) {
        let id = item.route.id
        switch item.route.kind {
        case .shell:
            guard var rule = settings.agentRules.shellRules.first(where: { $0.id == id }) else {
                return
            }
            shell(&rule)
            settings.updateShellRule(rule)
        case .path:
            guard var rule = settings.agentRules.pathRules.first(where: { $0.id == id }) else {
                return
            }
            path(&rule)
            settings.updatePathRule(rule)
        }
    }

    private func move(by offset: Int) {
        switch item.route.kind {
        case .shell: settings.moveShellRule(id: item.route.id, by: offset)
        case .path: settings.movePathRule(id: item.route.id, by: offset)
        }
    }

    /// Asked first, as every page's Delete is; the pane falls back to its list once it is gone.
    private func delete() {
        let route = item.route
        let subject =
            item.pattern.isEmpty ? "this \(route.kind.title.lowercased())" : "“\(item.pattern)”"
        Task {
            guard
                await core.confirm(
                    title: "Delete \(subject)?",
                    message: "What it matched falls to the next pattern that matches, or to the "
                        + "tool's own decision.",
                    symbol: SettingsTab.agentRules.systemImage, confirmTitle: "Delete")
            else { return }
            switch route.kind {
            case .shell: settings.removeShellRule(id: route.id)
            case .path: settings.removePathRule(id: route.id)
            }
        }
    }
}
