import SwiftUI

/// The sentence the Smart Reminder dialog collects, read back by the caller once it closes.
@MainActor
@Observable
final class SmartReminderState {
    var note = ""

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedNote.isEmpty }
}

struct SmartReminderFields: View {
    @Bindable var state: SmartReminderState
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $state.note, prompt: Text("Greg wants a cake tomorrow"))
            .focused($focused)
            .dialogTextField()
            .onAppear { focused = true }
    }
}
