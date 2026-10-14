import SwiftUI

/// What the live plan's card asks of the chat.
enum ChatPlanInput: Equatable {
    /// The reader's edit of the plan's Markdown.
    case save(String)
    /// Carry the plan out, switching the chat to this mode first.
    case execute(AgentMode)
}

/// Where the chat's live plan sits in one reply, and whether its buttons may act right now.
struct ChatLivePlan: Equatable {
    let sequence: Int
    let isEnabled: Bool
}

/// A plan a reply wrote: the live one to read, edit and carry out; a replaced one folded away.
struct ChatPlanCard: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.chatTextHighlight) private var highlight
    let written: ChatWrittenPlan
    let isLive: Bool
    /// Off while a turn runs: the turn may still replace the plan the reader would act on.
    let isEnabled: Bool
    /// Nil where the surface carries no plan out; the card is then only a record.
    let onInput: ((ChatPlanInput) -> Void)?

    @State private var draft: String?
    @State private var expanded = false

    private var plan: ChatPlan { written.plan }

    /// A match inside a folded plan would be found and then invisible, so find unfolds it.
    private var isOpen: Bool {
        isLive || expanded
            || highlight.map {
                plan.markdown.range(of: $0.query, options: ChatFindIndex.options) != nil
            } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            header
            if isOpen {
                if let draft {
                    editor(draft)
                } else {
                    ChatMarkdownText(blocks: MarkdownBlock.parse(plan.markdown))
                        .transition(.opacity)
                }
            }
            if isLive, onInput != nil { actions }
        }
        .padding(metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLive ? "Plan: \(plan.title)" : "Replaced plan: \(plan.title)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
            Image(systemName: AgentMode.plan.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(plan.title)
                .font(metrics.typography.rowTitle.weight(.semibold))
                .foregroundStyle(isLive ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isLive {
                Text("Replaced")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            if isLive {
                if onInput != nil, draft == nil {
                    Button("Edit") { draft = plan.markdown }
                        .buttonStyle(.glass)
                        .disabled(!isEnabled)
                        .help("Edit the plan before carrying it out")
                }
            } else {
                foldButton
            }
        }
    }

    private var foldButton: some View {
        Button {
            withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Hide replaced plan" : "Show replaced plan")
    }

    private func editor(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: metrics.spacing.md) {
            TextEditor(text: Binding(get: { text }, set: { draft = $0 }))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(metrics.spacing.sm)
                .frame(height: Theme.Size.chatPlanEditor)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                        .fill(Theme.Colors.controlSurface)
                )
                .accessibilityLabel("Plan")
            HStack(spacing: metrics.spacing.md) {
                Button("Cancel") { draft = nil }
                    .buttonStyle(.glass)
                Button("Save") {
                    onInput?(.save(text))
                    draft = nil
                }
                .buttonStyle(.glassProminent)
                .disabled(!isEnabled || text.allSatisfy(\.isWhitespace))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if draft == nil {
            HStack(spacing: metrics.spacing.md) {
                Button {
                    onInput?(.execute(.manual))
                } label: {
                    Label("Execute", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help("Carry the plan out, asking before anything the rules ask about")
                Button {
                    onInput?(.execute(.auto))
                } label: {
                    Label("Execute in Auto", systemImage: AgentMode.auto.symbolName)
                }
                .buttonStyle(.glass)
                .help("Carry the plan out without asking; what the rules deny stays denied")
                Spacer(minLength: 0)
            }
            .disabled(!isEnabled)
        }
    }
}
