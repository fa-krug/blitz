import SwiftUI

/// The draft the New Event dialog edits; reference semantics are what let the caller read it back.
@MainActor
@Observable
final class EventDraftState {
    var draft = EventDraft()
}

struct EventDraftFields: View {
    @Environment(\.metrics) private var metrics
    @Bindable var state: EventDraftState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            TextField("", text: $state.draft.title, prompt: Text("Event title"))
                .focused($focused)
                .dialogTextField()
            DialogChoiceRow(
                label: "Starts", values: EventDraft.startOffsets,
                title: EventDraft.label(startOffset:), selection: $state.draft.startOffsetMinutes)
            DialogChoiceRow(
                label: "For", values: EventDraft.durations, title: EventDraft.label(duration:),
                selection: $state.draft.durationMinutes)
        }
        .onAppear { focused = true }
    }
}
