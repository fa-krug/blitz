import SwiftUI

/// One number or address on the card, the unit its page selects and acts on.
struct ContactCardRow: Identifiable, Hashable {
    enum Kind {
        case phone
        case email
    }

    let kind: Kind
    let field: ContactField

    var id: String { field.id }

    /// Numbers first, then addresses, as Contacts lays a card out; the query narrows either.
    static func rows(of contact: ContactItem, matching query: String) -> [Self] {
        let rows =
            contact.phones.map { Self(kind: .phone, field: $0) }
            + contact.emails.map { Self(kind: .email, field: $0) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.field.value.localizedStandardContains(needle)
                || ($0.field.label?.localizedStandardContains(needle) ?? false)
        }
    }
}

/// A contact's own page, inside the palette: ↵ calls or writes to the selected line.
struct ContactCardScreen: PaletteScreen {
    let store: ContactsStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var contact: ContactItem? { store.presented }

    var rows: [ContactCardRow] {
        contact.map { ContactCardRow.rows(of: $0, matching: vm.query) } ?? []
    }

    /// A card with no number or address still answers ↵, by opening the editor to add one.
    var actsWithoutRows: Bool { contact != nil }

    var primaryActionTitle: String {
        let rows = rows
        guard !rows.isEmpty else { return "Edit Contact" }
        let row = rows[min(max(vm.selection, 0), rows.count - 1)]
        return row.kind == .phone ? "Call" : "Send Email"
    }

    func hasPrimaryAction(at selection: Int) -> Bool { contact != nil }

    private func row(at selection: Int) -> ContactCardRow? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let contact else { return nil }
        return ContactActionsMenu.cardContent(contact: contact, row: row(at: selection), core: core)
    }

    func activate(at selection: Int) {
        guard let contact else { return }
        guard let row = row(at: selection) else {
            core.contactsCoordinator.edit(contact)
            return
        }
        ContactActionsMenu.reach(row, of: contact, coordinator: core.contactsCoordinator)
    }

    /// ⌘↵ — copy the selected line.
    func secondary(at selection: Int) -> Bool {
        guard let row = row(at: selection) else { return false }
        core.contactsCoordinator.copy(row.field)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let contact else { return false }
        let line = row(at: selection)
        switch shortcut {
        case .edit: core.contactsCoordinator.edit(contact)
        case .openInApp: core.contactsCoordinator.openInContacts(contact)
        case .copyFile:
            let number = line.flatMap { $0.kind == .phone ? $0.field : nil }
            core.contactsCoordinator.copyPhone(contact, number: number)
        case .copyName:
            let address = line.flatMap { $0.kind == .email ? $0.field : nil }
            core.contactsCoordinator.copyEmail(contact, address: address)
        default: return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        guard let contact else {
            return AnyView(EmptyResults(text: "This contact is no longer available"))
        }
        let rows = rows
        return AnyView(
            ContactCardView(
                contact: contact, rows: rows,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                isFiltered: !vm.query.trimmingCharacters(in: .whitespaces).isEmpty,
                scroll: scroll,
                onActivate: { row in
                    ContactActionsMenu.reach(row, of: contact, coordinator: core.contactsCoordinator)
                },
                onActions: { row in
                    if let index = rows.firstIndex(of: row) { vm.selection = index }
                    openActions()
                }))
    }
}

/// The card: its header, then every number and every address under a heading of its own.
private struct ContactCardView: View {
    @Environment(\.metrics) private var metrics
    let contact: ContactItem
    let rows: [ContactCardRow]
    let selectedID: ContactCardRow.ID?
    let isFiltered: Bool
    let scroll: ScrollIntent
    let onActivate: (ContactCardRow) -> Void
    let onActions: (ContactCardRow) -> Void

    private var phones: [ContactCardRow] { rows.filter { $0.kind == .phone } }
    private var emails: [ContactCardRow] { rows.filter { $0.kind == .email } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ContactCardHeader(contact: contact, subtitle: contact.subtitle)
                        .padding(.horizontal, metrics.spacing.md)
                        .padding(.bottom, metrics.spacing.md)
                    if rows.isEmpty {
                        Text(isFiltered ? "No matching details" : "No phone numbers or email addresses")
                            .font(metrics.typography.rowTitle)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(metrics.spacing.md)
                    }
                    section("Phone", phones, isFirst: true)
                    section("Email", emails, isFirst: phones.isEmpty)
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.md)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: selectedID == rows.first?.id, proxy: proxy)
        }
        // A different card starts at its header, not wherever the last one was scrolled to.
        .id(contact.id)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ContactCardRow], isFirst: Bool) -> some View {
        if !rows.isEmpty {
            SectionHeader(title: title, isFirst: isFirst)
            ForEach(rows) { row in
                ContactCardLine(row: row, selected: row.id == selectedID)
                    .id(row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { onActivate(row) }
                    .onRightClick { onActions(row) }
                    .selectionFrame(row.id == selectedID)
            }
        }
    }
}

private struct ContactCardLine: View {
    @Environment(\.metrics) private var metrics
    let row: ContactCardRow
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            SymbolImage(
                name: row.kind == .phone ? "phone" : "envelope",
                size: metrics.size.resultRowIcon * 0.6
            )
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text(row.field.value)
                .font(metrics.typography.rowTitle)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: metrics.spacing.md)
            if let label = row.field.label {
                Text(label.capitalized)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The card's monogram, name and one line under it; the card page and its editor both open on it.
struct ContactCardHeader: View {
    @Environment(\.metrics) private var metrics
    let contact: ContactItem
    let subtitle: String?

    var body: some View {
        HStack(spacing: metrics.spacing.xl) {
            ContactMonogram(
                initials: contact.initials, size: metrics.scaled(48),
                font: metrics.typography.rowTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text(contact.title)
                    .font(metrics.typography.calcResult.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .textSelection(.enabled)
    }
}
