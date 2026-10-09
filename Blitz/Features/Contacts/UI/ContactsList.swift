import SwiftUI

/// The Search Contacts list, one header per letter.
struct ContactsList: View {
    @Environment(\.metrics) private var metrics
    let groups: [ContactGroup]
    let selectedID: ContactItem.ID?
    let searchableIDs: Set<String>
    let scroll: ScrollIntent
    let onActivate: (ContactItem) -> Void
    let onActions: (ContactItem) -> Void

    private enum Row: Identifiable {
        case header(ContactGroup)
        case contact(ContactItem)

        var id: String {
            switch self {
            case .header(let group): return "header-\(group.index)"
            case .contact(let contact): return contact.id
            }
        }
    }

    private var rows: [Row] {
        groups.flatMap { [.header($0)] + $0.contacts.map(Row.contact) }
    }

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == groups.first?.contacts.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let group):
                            SectionHeader(title: group.letter, isFirst: group.index == 0)
                        case .contact(let contact):
                            ContactRow(
                                contact: contact, selected: contact.id == selectedID,
                                searchable: searchableIDs.contains(contact.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(contact) }
                            .onRightClick { onActions(contact) }
                            .selectionFrame(contact.id == selectedID)
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct ContactRow: View {
    @Environment(\.metrics) private var metrics
    let contact: ContactItem
    let selected: Bool
    let searchable: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    /// The first way to reach the card, which is what ⌘↵ or ⌃⌘↵ would use.
    private var reach: String? {
        contact.phones.first?.value ?? contact.emails.first?.value
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            ContactMonogram(initials: contact.initials, size: metrics.size.resultRowIcon)
            Text(contact.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            if let subtitle = contact.subtitle {
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            HStack(spacing: metrics.spacing.md) {
                if let reach {
                    Text(reach)
                        .foregroundStyle(.secondary)
                }
                if searchable {
                    SymbolImage(name: "magnifyingglass", size: metrics.size.resultRowIcon * 0.5)
                        .foregroundStyle(.tertiary)
                        .tooltip("Shown in launcher search", alignment: .trailing)
                        .accessibilityLabel("Shown in launcher search")
                }
            }
            .font(metrics.typography.rowTrailing)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        let parts = [
            contact.title, contact.subtitle, reach, searchable ? "in launcher search" : nil
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// The card's initials in a disc, standing in for a photo Blitz never reads.
private struct ContactMonogram: View {
    @Environment(\.metrics) private var metrics
    let initials: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(metrics.typography.rowTrailing)
            .fontWeight(.semibold)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.Colors.controlSurface))
            .accessibilityHidden(true)
    }
}
