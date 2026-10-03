import SwiftUI

/// The draft the reminder dialog edits; reference semantics are what let the caller read it back.
@MainActor
@Observable
final class ReminderDraftState {
    enum DueKind: CaseIterable {
        case none
        case day
        case dayAndTime

        var title: String {
            switch self {
            case .none: "No Date"
            case .day: "Date"
            case .dayAndTime: "Date & Time"
            }
        }
    }

    var title: String
    var notes: String
    var dueKind: DueKind
    /// Kept while the kind is No Date, so switching back restores what was picked.
    var dueDate: Date

    init(draft: ReminderDraft, now: Date) {
        title = draft.title
        notes = draft.notes
        dueKind = draft.due.map { $0.time == nil ? .day : .dayAndTime } ?? .none
        dueDate =
            draft.due?.date(in: .current)
            ?? Calendar.current.dateInterval(of: .hour, for: now)?.end ?? now
    }

    var draft: ReminderDraft {
        let due: ReminderDue? =
            switch dueKind {
            case .none: nil
            case .day: ReminderDue(date: dueDate, includesTime: false, calendar: .current)
            case .dayAndTime: ReminderDue(date: dueDate, includesTime: true, calendar: .current)
            }
        return ReminderDraft(title: title, notes: notes, due: due)
    }
}

struct ReminderDraftFields: View {
    @Environment(\.metrics) private var metrics
    @Bindable var state: ReminderDraftState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            VStack(spacing: metrics.spacing.md) {
                TextField("", text: $state.title, prompt: Text("Title"))
                    .focused($focused)
                    .dialogTextField()
                TextField("", text: $state.notes, prompt: Text("Notes"))
                    .dialogTextField()
            }
            DialogChoiceRow(
                label: "Due", values: ReminderDraftState.DueKind.allCases, title: \.title,
                selection: $state.dueKind)
            // Laid out even when off: the dialog is measured once, as it is presented.
            DatePicker(
                "Due date", selection: $state.dueDate,
                displayedComponents: state.dueKind == .dayAndTime ? [.date, .hourAndMinute] : .date
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .disabled(state.dueKind == .none)
        }
        .onAppear { focused = true }
    }
}
