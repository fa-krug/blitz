import SwiftUI

/// The editor page: the card's header, then a labelled field per name part, number and address.
struct ContactEditorView: View {
    @Environment(\.metrics) private var metrics
    /// Told when a field owns the keyboard, so a bare backspace edits instead of backing out.
    @Environment(PaletteState.self) private var palette
    @Bindable var state: ContactDraftState
    let contact: ContactItem
    let fields: [ContactEditorField]
    /// The focused field, as the flat index the palette navigates with.
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onSubmit: () -> Void
    @FocusState private var focused: ContactEditorField?

    private var labelWidth: CGFloat { metrics.scaled(110) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.spacing.md) {
                    ContactCardHeader(
                        contact: contact, subtitle: "Saved to every device the card syncs to.")
                        .padding(.bottom, metrics.spacing.md)
                    ForEach(fields) { field in
                        row(field)
                            .id(field.scrollID)
                            .selectionFrame(fields.firstIndex(of: field) == selection)
                    }
                }
                .padding(.horizontal, metrics.spacing.xxl)
                .padding(.top, metrics.spacing.md)
                .padding(.bottom, metrics.spacing.xxl)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: selection == 0, proxy: proxy)
        }
        .onAppear { focus(selection) }
        .onDisappear { palette.noteEditingField(false) }
        // The palette moves the selection with ↑/↓ and ⇥; focus follows it, and a click leads it.
        .onChange(of: selection) { focus(selection) }
        .onChange(of: focused) { _, field in
            palette.noteEditingField(field != nil)
            if let field, let index = fields.firstIndex(of: field), index != selection {
                onSelect(index)
            }
        }
    }

    private var selectedID: String? {
        fields.indices.contains(selection) ? fields[selection].scrollID : nil
    }

    private func focus(_ index: Int) {
        guard fields.indices.contains(index) else { return }
        focused = fields[index]
    }

    private func row(_ field: ContactEditorField) -> some View {
        HStack(spacing: metrics.spacing.lg) {
            Text(label(field))
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)
            TextField("", text: text(field), prompt: Text(prompt(field)))
                .dialogTextField()
                .focused($focused, equals: field)
                .onSubmit(onSubmit)
        }
    }

    private func text(_ field: ContactEditorField) -> Binding<String> {
        switch field {
        case .givenName: $state.givenName
        case .familyName: $state.familyName
        case .organization: $state.organization
        case .phone(let index):
            Binding(
                get: { state.phones.indices.contains(index) ? state.phones[index].value : "" },
                set: { state.setPhone($0, at: index) })
        case .email(let index):
            Binding(
                get: { state.emails.indices.contains(index) ? state.emails[index].value : "" },
                set: { state.setEmail($0, at: index) })
        }
    }

    private func label(_ field: ContactEditorField) -> String {
        switch field {
        case .givenName: "First name"
        case .familyName: "Last name"
        case .organization: "Company"
        case .phone(let index): Self.label(of: state.phones, at: index, fallback: "Phone")
        case .email(let index): Self.label(of: state.emails, at: index, fallback: "Email")
        }
    }

    private func prompt(_ field: ContactEditorField) -> String {
        switch field {
        case .givenName: "First name"
        case .familyName: "Last name"
        case .organization: "Company"
        case .phone(let index):
            Self.isAddRow(state.phones, at: index) ? "Add phone number" : "Phone number"
        case .email(let index):
            Self.isAddRow(state.emails, at: index) ? "Add email address" : "Email address"
        }
    }

    private static func label(
        of fields: [ContactDraft.Field], at index: Int, fallback: String
    ) -> String {
        guard fields.indices.contains(index) else { return fallback }
        return fields[index].label?.capitalized ?? fallback
    }

    private static func isAddRow(_ fields: [ContactDraft.Field], at index: Int) -> Bool {
        fields.indices.contains(index) && fields[index].id == nil
    }
}
