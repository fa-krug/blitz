import SwiftUI

/// One ordered pattern, shell or path: its field, any extra picker, a decision, order and remove.
struct AgentRuleRow<Rule: Identifiable<UUID>, Extra: View>: View {
    let rule: Rule
    let pattern: WritableKeyPath<Rule, String>
    let decision: WritableKeyPath<Rule, AgentDecision>
    let prompt: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: (Rule) -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    let focus: FocusState<UUID?>.Binding
    @ViewBuilder var extra: (Rule) -> Extra

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Pattern", text: field(pattern), prompt: Text(prompt))
                .labelsHidden()
                .font(Theme.Typography.inlineCode)
                .focused(focus, equals: rule.id)
            extra(rule)
            Picker("Decision", selection: field(decision)) {
                ForEach([AgentDecision.allow, .ask, .deny]) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            iconButton("chevron.up", label: "Move Up") { onMove(-1) }
                .settingsEnabled(canMoveUp)
            iconButton("chevron.down", label: "Move Down") { onMove(1) }
                .settingsEnabled(canMoveDown)
            iconButton("minus.circle", label: "Remove") { onRemove() }
        }
    }

    private func field<Value>(_ path: WritableKeyPath<Rule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: path] },
            set: { value in
                var edited = rule
                edited[keyPath: path] = value
                onChange(edited)
            })
    }

    private func iconButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

extension AgentRuleRow where Extra == EmptyView {
    init(
        rule: Rule, pattern: WritableKeyPath<Rule, String>,
        decision: WritableKeyPath<Rule, AgentDecision>, prompt: String, canMoveUp: Bool,
        canMoveDown: Bool, onChange: @escaping (Rule) -> Void, onMove: @escaping (Int) -> Void,
        onRemove: @escaping () -> Void, focus: FocusState<UUID?>.Binding
    ) {
        self.init(
            rule: rule, pattern: pattern, decision: decision, prompt: prompt,
            canMoveUp: canMoveUp, canMoveDown: canMoveDown, onChange: onChange, onMove: onMove,
            onRemove: onRemove, focus: focus, extra: { _ in EmptyView() })
    }
}
