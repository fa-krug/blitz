import SwiftUI

/// The text a rename or an edit dialog collects, read back by the caller once it closes.
@MainActor
@Observable
final class DialogTextState {
    var text: String
    let placeholder: String
    /// What VoiceOver calls the field, since the dialog shows no label beside it.
    let label: String

    init(text: String, placeholder: String = "", label: String) {
        self.text = text
        self.placeholder = placeholder
        self.label = label
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One line, or a scrolling box where Return is a newline and the panel saves on ⌘↵ instead.
struct DialogTextInput: View {
    @Environment(\.metrics) private var metrics
    @Bindable var state: DialogTextState
    let isMultiline: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isMultiline {
                TextEditor(text: $state.text)
                    .font(metrics.typography.rowTitle)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, metrics.spacing.md)
                    .padding(.vertical, metrics.spacing.sm)
                    .frame(height: metrics.size.dialogTextEditorHeight)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                            .fill(Theme.Colors.controlSurface))
            } else {
                TextField("", text: $state.text, prompt: Text(state.placeholder))
                    .dialogTextField()
            }
        }
        .accessibilityLabel(state.label)
        .focused($focused)
        .onAppear { focused = true }
    }
}
