import SwiftUI

/// What a click on a waiting question's card asks of the chat.
enum ChatQuestionInput: Equatable {
    /// A single-choice option, which answers at once.
    case choose(Int)
    /// A multi-select option, picked or put back.
    case toggle(Int)
    /// The picked options of a multi-select question, as the answer.
    case send
}

/// A question the reply asked: its options as chips while it waits, then what the reader said.
struct ChatQuestionCard: View {
    @Environment(\.metrics) private var metrics
    let question: ChatQuestion
    /// Nil once the question is answered: the card is then a record, not a control.
    let onInput: ((ChatQuestionInput) -> Void)?

    private var asked: AskUserToolCatalog.Question { question.question }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
                Image(systemName: "questionmark.bubble")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(asked.question)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(metrics.typography.rowTitle)
            if question.isPending {
                waiting
            } else {
                answered
            }
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
        .accessibilityLabel("Question: \(asked.question)")
    }

    @ViewBuilder private var waiting: some View {
        ChatFlowLayout(spacing: metrics.spacing.sm) {
            ForEach(Array(asked.options.enumerated()), id: \.offset) { index, option in
                if asked.multiSelect {
                    let isOn = question.picked.contains(index)
                    ChatChoiceChip(
                        title: option, symbol: isOn ? "checkmark.circle.fill" : "circle", isOn: isOn
                    ) {
                        onInput?(.toggle(index))
                    }
                    .accessibilityLabel(option)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                } else {
                    ChatChoiceChip(title: option, symbol: "arrow.turn.down.right") {
                        onInput?(.choose(index))
                    }
                    .help("Answer “\(option)”")
                    .accessibilityLabel("Answer: \(option)")
                }
            }
        }
        .disabled(onInput == nil)
        HStack(spacing: metrics.spacing.md) {
            Text("Pick \(asked.multiSelect ? "any" : "one"), or type your own answer.")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer(minLength: 0)
            if asked.multiSelect {
                Button("Send") { onInput?(.send) }
                    .buttonStyle(.glassProminent)
                    .disabled(onInput == nil || question.picked.isEmpty)
                    .help("Answer with the picked options")
            }
        }
    }

    @ViewBuilder private var answered: some View {
        if question.wentUnanswered {
            Text("Not answered")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                if !question.chosenOptions.isEmpty {
                    ChatFlowLayout(spacing: metrics.spacing.sm) {
                        ForEach(question.chosenOptions, id: \.self) { option in
                            AnsweredOption(title: option)
                        }
                    }
                }
                if let typed = question.typedAnswer {
                    Text(typed)
                        .font(metrics.typography.rowTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Answered: "
                    + (question.chosenOptions + [question.typedAnswer].compactMap(\.self))
                    .joined(separator: ", "))
        }
    }
}

/// A chosen option once the question is answered: the chip's shape, no longer a control.
private struct AnsweredOption: View {
    @Environment(\.metrics) private var metrics
    let title: String

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Image(systemName: "checkmark")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.xxs)
        .background(Capsule().fill(Theme.Colors.controlSurface))
    }
}
