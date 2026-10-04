import SwiftUI

/// The draft the contact dialog edits; reference semantics are what let the caller read it back.
@MainActor
@Observable
final class ContactDraftState {
    var givenName: String
    var familyName: String
    var organization: String
    /// One blank row trails each list: the dialog is measured once, so it cannot grow a row later.
    var phones: [ContactDraft.Field]
    var emails: [ContactDraft.Field]

    init(draft: ContactDraft) {
        givenName = draft.givenName
        familyName = draft.familyName
        organization = draft.organization
        phones = draft.phones + [ContactDraft.Field(id: nil, label: nil, value: "")]
        emails = draft.emails + [ContactDraft.Field(id: nil, label: nil, value: "")]
    }

    /// Blank rows are dropped here, so an untouched dialog reads back as the draft it was given.
    var draft: ContactDraft {
        let filled = { (field: ContactDraft.Field) in !field.trimmedValue.isEmpty }
        return ContactDraft(
            givenName: givenName, familyName: familyName, organization: organization,
            phones: phones.filter(filled), emails: emails.filter(filled))
    }
}

struct ContactDraftFields: View {
    @Environment(\.metrics) private var metrics
    @Bindable var state: ContactDraftState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            VStack(spacing: metrics.spacing.md) {
                HStack(spacing: metrics.spacing.md) {
                    TextField("", text: $state.givenName, prompt: Text("First name"))
                        .focused($focused)
                        .dialogTextField()
                    TextField("", text: $state.familyName, prompt: Text("Last name"))
                        .dialogTextField()
                }
                TextField("", text: $state.organization, prompt: Text("Company"))
                    .dialogTextField()
            }
            ContactFieldList(fields: $state.phones, emptyPrompt: "Add phone number")
            ContactFieldList(fields: $state.emails, emptyPrompt: "Add email address")
        }
        .onAppear { focused = true }
    }
}

/// A list's rows, each prompted with its own label; clearing a row removes that value.
private struct ContactFieldList: View {
    @Environment(\.metrics) private var metrics
    @Binding var fields: [ContactDraft.Field]
    let emptyPrompt: String

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            ForEach(fields.indices, id: \.self) { index in
                TextField("", text: $fields[index].value, prompt: Text(prompt(at: index)))
                    .dialogTextField()
            }
        }
    }

    private func prompt(at index: Int) -> String {
        let field = fields[index]
        guard field.id != nil else { return emptyPrompt }
        return field.label?.capitalized ?? "No label"
    }
}
